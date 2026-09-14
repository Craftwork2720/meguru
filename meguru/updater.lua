--[[--
Checking GitHub for a newer Meguru, and installing it.

Three public entry points, and the difference between them is who is waiting:

  * `Updater.checkForUpdates()` — a tap. Always says something, including when
    the answer is "you are up to date" or "GitHub would not answer".
  * `Updater.checkSilentForUpdates()` — nobody is waiting. Says nothing when
    offline and nothing when up to date; speaks only when there is a version to
    offer.
  * `Updater.checkAtStartup()` — called from `Meguru:init`, which runs once for
    the FileManager and once per opened book. It is the weekly gate in front of
    the silent check, and it is a no-op on all but one start a week.

**The archive that is installed is the archive this downloads.** There is no
second artifact anywhere in the flow: `.github/workflows/release.yml` builds
one zip and the updater fetches the release asset *by name* (`ASSET_NAME`,
below). An updater that instead pulls GitHub's own source archive by tag is
fetching a file CI never looked at, and nothing reports it when the two
disagree — which is the one design mistake in this area worth naming, because
copying it would be invisible until it bit someone.

The install is a transaction, and the parts that make it one are the parts that
are easy to leave out:

  * the new copy is unpacked into a **staging** directory and verified there, so
    a failed download or a truncated archive never touches the live plugin;
  * the live plugin is moved aside by **rename**, never overwritten in place;
  * anything that goes wrong after that point puts the backup back;
  * the backup, the staged tree and the archive are removed only once the swap
    has been confirmed.

@module meguru.updater
--]]

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local _ = require("gettext")

local FFIUtil = require("ffi/util")
local T = FFIUtil.template

local FS = require("meguru/fs")
local Net = require("meguru/net")
local Paths = require("meguru/paths")

local Updater = {}

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

local GITHUB_OWNER = "Craftwork2720"
local GITHUB_REPO = "meguru"

--- The name of the zip attached to every GitHub Release, and the name this
--- updater looks the asset up by. **The two ends have to agree**, so it is a
--- constant in the workflow and a constant here, and neither carries a version
--- number: an asset named `meguru-1.2.0.zip` would make every release after the
--- first look like it had no downloadable file.
local ASSET_NAME = "meguru.koplugin.zip"

--- How long a fetched release's details are reused, so a reader tapping the row
--- twice does not spend two API calls. A *manual* check ignores this — someone
--- who asks must see the real latest release, not an hour-old one.
local CACHE_TTL = 3600

--- How long between background checks. Weekly: this is a courtesy, not a
--- notification service, and the row is there for anyone who wants an answer
--- sooner.
local SILENT_INTERVAL = 7 * 24 * 60 * 60

--- The one directory inside the archive, which the workflow stages so the
--- extracted tree can be dropped straight into the plugins directory.
local ARCHIVE_ROOT = "meguru.koplugin"

--- What the staged tree must contain before anything is moved aside.
---
--- A handful rather than one, because `main.lua` alone would not notice an
--- archive that shipped the entry point and none of the modules — which loads,
--- and then fails on the first tap. These are `/`-separated and only ever
--- joined to a device path, so there is no separator question here.
local REQUIRED_FILES = {
    "main.lua",
    "_meta.lua",
    "meguru/updater.lua",
    "meguru/net.lua",
}

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

--- The installed version, handed over once from `main.lua`.
---
--- Not read from `_meta.lua` on every check, and *never* defaulted: a fallback
--- like `"0.0.0"` is the trap here, because a version older than every release
--- makes each check answer "a new version is available" for good.
local installed_version

--- Once per process. `Meguru:init` runs for the FileManager and again for every
--- book opened, and each of those would otherwise arm another background check.
local startup_scheduled = false

-- ---------------------------------------------------------------------------
-- Where things live
-- ---------------------------------------------------------------------------

local function apiUrl()
    return string.format("https://api.github.com/repos/%s/%s/releases/latest",
        GITHUB_OWNER, GITHUB_REPO)
end

--- The remembered release, beside `settings/opds.lua` and the other plugin
--- state outside the plugin folder.
local function cachePath()
    return DataStorage:getSettingsDir() .. "/meguru_update_cache.json"
end

--- Scratch for one update attempt: the downloaded archive, the tree extracted
--- from it, and the copy of the plugin moved aside to make room.
---
--- All three sit in the same directory, one level under the pre-created `ota`,
--- so a single `purgeDir` clears a failed attempt and nothing accumulates. That
--- they are all under the data directory — and not, say, in `cache/meguru` —
--- is deliberate: this has to be able to *host* the plugin directory by rename,
--- so it must be on the same filesystem as the plugins folder.
local function otaDir()
    return DataStorage:getFullDataDir() .. "/ota/meguru"
end

-- ---------------------------------------------------------------------------
-- The remembered release
-- ---------------------------------------------------------------------------

local function readCache()
    local handle = io.open(cachePath(), "r")
    if not handle then
        return nil
    end
    local raw = handle:read("*a")
    handle:close()
    local ok_json, json = pcall(require, "json")
    if not ok_json then
        return nil
    end
    local ok_decode, data = pcall(json.decode, raw)
    if not ok_decode or type(data) ~= "table" then
        return nil
    end
    return data
end

local function writeCache(data)
    local ok_json, json = pcall(require, "json")
    if not ok_json then
        return
    end
    local ok_encode, encoded = pcall(json.encode, data)
    if not ok_encode then
        return
    end
    if not FS.writeFile(cachePath(), encoded) then
        -- Not worth telling the reader: the next check simply asks GitHub
        -- again.
        logger.warn("Meguru: could not write the update cache")
    end
end

--- Record that a check happened, whatever it found.
---
--- **Written on failure too, and that is the whole point of it.** The weekly
--- gate reads this timestamp, so a device that is offline at every start would
--- otherwise reach for the network on every single start, forever.
local function noteCheck(fields)
    local data = readCache() or {}
    data.checked_at = os.time()
    for key, value in pairs(fields or {}) do
        data[key] = value
    end
    writeCache(data)
end

--- What the last check found, if that was recent enough to reuse.
local function cachedRelease()
    local data = readCache()
    if not data or not data.checked_at or not data.version then
        return nil
    end
    if (os.time() - data.checked_at) > CACHE_TTL then
        return nil
    end
    return data
end

local function silentCheckDue()
    local data = readCache()
    if not data or not data.checked_at then
        return true
    end
    return (os.time() - data.checked_at) > SILENT_INTERVAL
end

-- ---------------------------------------------------------------------------
-- Versions
-- ---------------------------------------------------------------------------

local function currentVersion()
    if installed_version then
        return installed_version
    end
    -- `Meguru:init` hands the version over before anything can ask for it, so
    -- this is the fallback for a caller that did not: read it off the installed
    -- `_meta.lua`, which is where pluginloader read it from in the first place.
    local dir = Paths.pluginDir()
    if not dir then
        return nil
    end
    local ok, meta = pcall(dofile, dir .. "/_meta.lua")
    if ok and type(meta) == "table" and type(meta.version) == "string"
        and meta.version ~= "" then
        return meta.version
    end
    return nil
end

--- A tag is `v1.2.0` and `_meta.lua` is `1.2.0`. Both sides go through here, so
--- the comparison and the "is this the release I asked for" check in `install`
--- cannot disagree about which form is canonical — and so a tag compared raw
--- against a `_meta.lua` would not fail every install with "the downloaded file
--- is not the release it was asked for", which is a maximally confusing way to
--- be wrong.
---
--- The parentheses are load-bearing: `gsub` returns the string *and* a count,
--- and only the string is wanted.
local function canonical(version)
    return (tostring(version or ""):gsub("^v", ""))
end

--- Whether `a` names an older version than `b`.
---
--- Numeric dotted comparison: every run of digits becomes a number and the two
--- lists are walked in step, a missing part counting as zero, so `1.2.10` is
--- above `1.2.9` where a string comparison would put it below. A trailing
--- non-numeric part (`-beta`) is ignored, and that is a real limitation rather
--- than a simplification: this plugin has never published a prerelease, and the
--- alternative — a full SemVer precedence implementation — would be a hundred
--- lines of precedence rules to order tags nobody writes.
local function versionLessThan(a, b)
    local function parts(version)
        local out = {}
        for digits in tostring(version or ""):gmatch("(%d+)") do
            out[#out + 1] = tonumber(digits)
        end
        return out
    end
    local one, two = parts(a), parts(b)
    for i = 1, math.max(#one, #two) do
        local left, right = one[i] or 0, two[i] or 0
        if left < right then
            return true
        end
        if left > right then
            return false
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Messages
-- ---------------------------------------------------------------------------

local function toast(text, timeout)
    local widget = InfoMessage:new{ text = text, timeout = timeout or 4 }
    UIManager:show(widget)
    -- `UIManager:show` only marks the region dirty; painting happens in the
    -- input loop. Without this the message would stay invisible for the whole
    -- of the blocking fetch that follows it, which is exactly the stretch of
    -- time it exists to cover.
    UIManager:forceRePaint()
    return widget
end

local function closeWidget(widget)
    if widget then
        UIManager:close(widget)
    end
end

--- One sentence per reason, because the fixes differ: connecting Wi-Fi does
--- nothing about a release that was never published, and waiting does nothing
--- about a connection that is off.
local function failureText(reason)
    if reason == "network" then
        return _("Couldn't reach GitHub. Check the connection and try again.")
    end
    if reason == "norelease" then
        return _("Meguru has no published release yet.")
    end
    if reason == "ratelimited" then
        return _("GitHub is refusing requests from this device right now. Try again later.")
    end
    if reason == "noasset" then
        return _("The latest release has no downloadable file.")
    end
    if reason == "unreadable" then
        return _("GitHub answered with something Meguru could not read.")
    end
    return _("Couldn't check for updates.")
end

-- ---------------------------------------------------------------------------
-- Asking GitHub
-- ---------------------------------------------------------------------------

local function parseRelease(body)
    local ok_json, json = pcall(require, "json")
    if not ok_json then
        return nil, "unreadable"
    end
    local ok_decode, data = pcall(json.decode, body)
    if not ok_decode or type(data) ~= "table" or type(data.tag_name) ~= "string" then
        return nil, "unreadable"
    end
    local download_url
    for _, asset in ipairs(data.assets or {}) do
        -- By name, and exactly: the workflow attaches one asset under a
        -- constant name, so a fuzzy match would only ever find the wrong file.
        if asset.name == ASSET_NAME then
            download_url = asset.browser_download_url
            break
        end
    end
    return {
        version = canonical(data.tag_name),
        download_url = download_url,
        html_url = data.html_url,
    }
end

--- The latest release, or `nil` plus one of the reasons `failureText` words.
---
--- Every path out of here records that a check happened, including the failures
--- — see `noteCheck`.
local function fetchRelease(use_cache)
    if use_cache ~= false then
        local cached = cachedRelease()
        if cached then
            logger.dbg("Meguru: using the cached release info")
            return cached
        end
    end
    local code, _, body = Net.get(apiUrl(), {
        -- The API's own media type. `application/octet-stream` would be the
        -- *asset* type and is the wrong one to ask a JSON endpoint for.
        accept = "application/vnd.github+json",
        timeout = "resume",
    })
    if code ~= 200 or not body then
        noteCheck()
        if not code then
            return nil, "network"
        end
        if code == 404 then
            -- GitHub answers 404 for `releases/latest` on a repository with no
            -- releases at all, which is a fact about Meguru rather than a
            -- failure to reach it. Reporting it as "couldn't check" would send
            -- the reader looking for a network problem that is not there.
            return nil, "norelease"
        end
        if code == 403 then
            return nil, "ratelimited"
        end
        return nil, "http"
    end
    local release, reason = parseRelease(body)
    if not release then
        noteCheck()
        return nil, reason
    end
    noteCheck({
        version = release.version,
        download_url = release.download_url,
        html_url = release.html_url,
    })
    return release
end

-- ---------------------------------------------------------------------------
-- Installing
-- ---------------------------------------------------------------------------

--- Unpack `archive` into `staging`, leaving `staging/<ARCHIVE_ROOT>/`.
---
--- `ffi/archiver` is required here rather than at the top of the file on
--- purpose. Its module body loads libarchive, and a build without it would
--- otherwise take down the whole plugin at load — every menu row, every open —
--- rather than one row most readers never tap. `Net.parseFeed` defers
--- `opdsparser` for the same shape of reason.
local function extractInto(archive, staging)
    local ok_archiver, Archiver = pcall(require, "ffi/archiver")
    if not ok_archiver or type(Archiver) ~= "table" or not Archiver.Reader then
        return nil, _("This build of KOReader has no archive support.")
    end
    local reader = Archiver.Reader:new()
    if not reader:open(archive) then
        return nil, tostring(reader.err or "could not open the archive")
    end
    local root = staging .. "/" .. ARCHIVE_ROOT
    for entry in reader:iterate() do
        -- Regular files only, which is what `archiveviewer.koplugin` extracts
        -- and for the same reason: a zip's directory entries are implied by the
        -- paths of its files. The leading-slash test is not paranoia about our
        -- own archive — libarchive's SECURE_NODOTDOT stops `..` but not an
        -- absolute path, and SECURE_SYMLINKS is not set either, so a path that
        -- starts at the root would be honoured.
        if entry.mode == "file" and entry.path:sub(1, 1) ~= "/" then
            local dest = root .. "/" .. entry.path
            -- Created rather than assumed. `archive_write_disk` does create
            -- missing parents, but that is a property of libarchive version and
            -- of its options rather than of anything promised here, and being
            -- wrong about it costs a silently half-empty staging tree.
            local folder = util.splitFilePathName(dest)
            FS.ensureDir(folder)
            if not reader:extractToPath(entry.path, dest) then
                -- Advisory, not fatal. `extractToPath` compares against
                -- ARCHIVE_OK exactly, while a disk writer returns ARCHIVE_WARN
                -- for something as ordinary as a permission it could not set on
                -- a FAT card — and the verification that follows is the real
                -- gate.
                logger.warn("Meguru: could not extract", entry.path, ":",
                    tostring(reader.err))
            end
        end
    end
    reader:close()
    return true
end

--- Whether the staged tree really is the release we asked for.
---
--- Two questions, and they catch different lies: that the files are there at
--- all, and that they are the *right* version — which is also the only proof
--- that the asset served under `ASSET_NAME` is the one this release built.
local function stagedLooksRight(staging, expected_version)
    local root = staging .. "/" .. ARCHIVE_ROOT
    for _, relative in ipairs(REQUIRED_FILES) do
        if not FS.exists(root .. "/" .. relative) then
            return nil, _("The downloaded file is not a Meguru release.")
        end
    end
    local ok, meta = pcall(dofile, root .. "/_meta.lua")
    if not ok or type(meta) ~= "table"
        or canonical(meta.version) ~= canonical(expected_version) then
        return nil, _("The downloaded file is not the release it was asked for.")
    end
    return true
end

--- Download the release, unpack it, and put it where the plugin is.
---
--- Returns `true`, or `nil` plus a sentence to show the reader. Every failure
--- leaves the installed plugin exactly as it was — either untouched, or put
--- back.
local function install(release)
    local plugin_dir = Paths.pluginDir()
    if not plugin_dir then
        return nil, _("Meguru does not know where it is installed, so it cannot update itself.")
    end

    -- A development install. `pluginloader` accepts a symlink because
    -- `lfs.attributes` follows one, so a symlinked plugin reaches this code
    -- looking like an ordinary directory — and the renames below would move the
    -- *link* and install a real directory in its place, orphaning whatever it
    -- pointed at. On the next update `purgeDir` would then be aimed at the link
    -- and delete the target's contents, because it recurses through the same
    -- following call. Refusing is the only safe answer, and it comes before the
    -- download so a development install does not pay for it.
    --
    -- The table form of the call, which is the one already used in-tree on this
    -- device (`plugins/timesync.koplugin/main.lua`), rather than the
    -- `(path, "mode")` one that `lfs.attributes` takes in `meguru/fs`.
    local link = lfs.symlinkattributes(plugin_dir)
    if link and link.mode == "link" then
        return nil, _("Meguru is installed as a symlink to its source, so it cannot update itself. Update it there instead.")
    end

    local ota = otaDir()
    local staging = ota .. "/staging"
    local backup = ota .. "/backup"
    local archive = ota .. "/" .. ASSET_NAME
    local staged_plugin = staging .. "/" .. ARCHIVE_ROOT

    -- Leftovers from an attempt that did not finish. Cleared first rather than
    -- checked for, so a half-written tree from last time can never be mistaken
    -- for this one's.
    --
    -- `ota` is entirely ours — the archive, the staged tree and the backup are
    -- all under it — so every failure below clears the whole directory in one
    -- call rather than picking off what this particular stage happened to
    -- write. A failed attempt must not leave half a megabyte of zip on the
    -- card, and nothing else sweeps this. The one path that must not call it is
    -- the stranded one at the end, where the backup is the only copy left.
    FFIUtil.purgeDir(ota)
    if not FS.ensureDir(staging) then
        return nil, T(_("Could not create %1."), staging)
    end

    if not Net.getToFile(release.download_url, archive,
        { accept = "application/octet-stream", timeout = "download" }) then
        -- `getToFile` has already removed its own partial file; this clears the
        -- staging directory it was going to be unpacked into.
        FFIUtil.purgeDir(ota)
        return nil, _("Could not download the update.")
    end

    local ok_extract, extract_err = extractInto(archive, staging)
    if not ok_extract then
        FFIUtil.purgeDir(ota)
        return nil, T(_("Could not unpack the update: %1"), tostring(extract_err))
    end

    local ok_staged, staged_err = stagedLooksRight(staging, release.version)
    if not ok_staged then
        FFIUtil.purgeDir(ota)
        return nil, staged_err
    end

    local ok_backup, backup_err = os.rename(plugin_dir, backup)
    if not ok_backup then
        FFIUtil.purgeDir(ota)
        return nil, T(_("Could not move the installed copy aside: %1"), tostring(backup_err))
    end

    -- **Nothing may happen between these two renames.** There is a moment here
    -- in which `plugins/meguru.koplugin` does not exist, and a power loss in it
    -- leaves the plugin gone with no code of ours loaded to put it back — the
    -- rollback below only runs if this function returns. Two adjacent metadata
    -- syscalls is the whole mitigation, so: no logging that could flush, no
    -- cleanup, nothing.
    local ok_swap, swap_err = os.rename(staged_plugin, plugin_dir)

    if ok_swap and not FS.exists(plugin_dir .. "/main.lua") then
        -- The rename worked, so what is at `plugin_dir` is the staged tree,
        -- incomplete. It has to go before the backup can come back, since a
        -- rename onto a non-empty directory fails.
        FFIUtil.purgeDir(plugin_dir)
        ok_swap, swap_err = nil, "the unpacked copy was incomplete"
    end

    if not ok_swap then
        -- The reverse of a rename that just succeeded, so it is expected to
        -- work; if it does not, the copy is still on disk and the reader is told
        -- where rather than left with silence.
        if not os.rename(backup, plugin_dir) then
            logger.warn("Meguru: the update failed and the previous copy could"
                .. " not be restored; it is at", backup)
            return nil, T(_("The update failed and the previous copy of Meguru could not be put back. It is in %1."), backup)
        end
        FFIUtil.purgeDir(ota)
        logger.warn("Meguru: update failed while installing:", tostring(swap_err))
        return nil, T(_("Could not install the update: %1"), tostring(swap_err))
    end

    -- Confirmed, and only now is anything deleted. The whole scratch directory
    -- goes, not just the three things in it: nothing outside an update attempt
    -- reads anything under here.
    FFIUtil.purgeDir(ota)
    noteCheck({
        version = release.version,
        download_url = release.download_url,
        html_url = release.html_url,
    })
    logger.info("Meguru: updated to", release.version)
    return true
end

--- Run the transaction with a message on screen, and report what happened.
local function installAndReport(release)
    local progress = toast(T(_("Downloading Meguru %1…"), release.version), 120)
    -- Deferred so the message is painted before the download blocks the UI
    -- thread for as long as it takes.
    UIManager:nextTick(function()
        local ok, err = install(release)
        closeWidget(progress)
        if not ok then
            logger.warn("Meguru: update failed:", err)
            toast(err, 8)
            return
        end
        -- Not `UIManager:restartKOReader()`: this one broadcasts the Restart
        -- event first, so every other plugin gets to flush what it has open,
        -- and it degrades to a message on a device that cannot restart rather
        -- than quitting for nothing. It is also the prompt the brief asks for —
        -- "Restart now" over "Restart later".
        UIManager:askForRestart(T(_("Meguru was updated to %1."), release.version))
    end)
end

--- A release worth offering, or nil. The one place the two checks agree.
local function offerIfNewer(release)
    local version = currentVersion()
    if not version then
        return nil
    end
    if not release or not release.download_url then
        return nil
    end
    if not versionLessThan(version, release.version) then
        return nil
    end
    return version
end

local function showInstallDialog(release, version)
    UIManager:show(ConfirmBox:new{
        text = T(_("Meguru %1 is available (you have %2).\n\nInstall it now?"),
            release.version, version),
        ok_text = _("Install now"),
        cancel_text = _("Later"),
        ok_callback = function()
            installAndReport(release)
        end,
    })
end

-- ---------------------------------------------------------------------------
-- The entry points
-- ---------------------------------------------------------------------------

--- Check now, and answer no matter what. For the menu row.
function Updater.checkForUpdates()
    local checking = toast(_("Checking for updates…"), 15)

    local function report(release, reason)
        closeWidget(checking)
        local version = currentVersion()
        if not version then
            toast(_("This build of Meguru does not declare a version, so there is nothing to compare."), 8)
            return
        end
        if not release then
            toast(failureText(reason), 8)
            return
        end
        if not release.download_url then
            -- The release exists and this updater cannot install from it. The
            -- release page is where a reader can do something about it.
            UIManager:show(ConfirmBox:new{
                text = failureText("noasset") .. "\n\n"
                    .. _("Open the release page?"),
                ok_text = _("Open"),
                cancel_text = _("Later"),
                ok_callback = function()
                    local Device = require("device")
                    local target = release.html_url or string.format(
                        "https://github.com/%s/%s/releases/latest",
                        GITHUB_OWNER, GITHUB_REPO)
                    -- Stock's own pair, in stock's own order
                    -- (`readerlink.lua:173`). The `pcall` is here because this
                    -- runs from a dialog callback, where a throw lands in the
                    -- event loop rather than anywhere a reader can act on, and
                    -- opening a release page is not worth that.
                    pcall(function()
                        if Device:canOpenLink() then
                            Device:openLink(target)
                        end
                    end)
                end,
            })
            return
        end
        if not versionLessThan(version, release.version) then
            logger.dbg("Meguru: up to date (" .. version .. ")")
            toast(T(_("Meguru is up to date (%1)."), version), 4)
            return
        end
        logger.info("Meguru: a new version is available:", release.version)
        showInstallDialog(release, version)
    end

    local function run()
        -- `false`: a reader who asked must see the real latest release, not
        -- whatever an earlier check remembered.
        local release, reason = fetchRelease(false)
        UIManager:nextTick(function()
            report(release, reason)
        end)
    end

    local ok_manager, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_manager and NetworkMgr and NetworkMgr.runWhenOnline then
        -- Asks for a connection when there is none, which is what a tap on a
        -- row like this should do. One case it does not cover, and the reason
        -- the message above carries a timeout: a device that is *connected* but
        -- not online takes the branch that drops the callback, so nothing runs
        -- and nothing is said. Tapping again once the connection is real works.
        NetworkMgr:runWhenOnline(run)
    else
        run()
    end
end

--- Check with no UI of its own, and speak only when there is a version to
--- offer. For a background check nobody is waiting for.
function Updater.checkSilentForUpdates()
    local ok_manager, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_manager and NetworkMgr and NetworkMgr.isConnected
        and not NetworkMgr:isConnected() then
        -- Silent includes silent about this. The one thing that must not
        -- happen here is a Wi-Fi prompt because the reader opened a book.
        return
    end
    local release = fetchRelease()
    local version = offerIfNewer(release)
    if not version then
        return
    end
    logger.info("Meguru: a new version is available:", release.version)
    showInstallDialog(release, version)
end

--- Arm the background check, once per process, and only when the last one is
--- old enough to be worth repeating.
---
--- Called from `Meguru:init`, which runs for the FileManager at startup and
--- again for every book opened, so the once-per-process flag and the weekly
--- timestamp are both doing work: without the first, every book opened would
--- schedule another check.
function Updater.checkAtStartup()
    if startup_scheduled then
        return
    end
    startup_scheduled = true
    if not Paths.pluginDir() then
        -- `Meguru:init` sets that immediately before calling this, so reaching
        -- here means a caller that did not — not a state to guess a path from.
        return
    end
    if not silentCheckDue() then
        return
    end
    -- Deferred, so the startup paint is not waiting on a socket.
    UIManager:scheduleIn(10, function()
        pcall(Updater.checkSilentForUpdates)
    end)
end

--- Hand over the installed version. Called once from `Meguru:init`, beside
--- `Paths.setPluginDir` — the same shape for the same reason: neither can be
--- derived from inside this module.
function Updater.setInstalledVersion(version)
    if type(version) == "string" and version ~= "" then
        installed_version = version
    end
end

return Updater
