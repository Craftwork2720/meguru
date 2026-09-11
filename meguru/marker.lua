--[[--
The marker file: a small book-shaped stand-in for a page stream.

A marker is what KOReader opens, what lands in History and what DocSettings
keeps reading progress for. It therefore has to be able to open a book with no
database at all, which is why `template` and `count` are in the file rather than
looked up: the catalog can be deleted, rebuilt or restored from a backup
independently of the books on disk, and every marker keeps working when it is.

**No secret is in the file, and that is enforced here rather than assumed.**
`saveAt` strips the credential out of `template` on the way to disk and `load`
puts it back — for Kavita the API key is a path segment, and the marker lives in
the reader's *book* folder (an SD card, a folder something syncs), not in
`settings/`. See `meguru/credential`.

Two consequences worth knowing, because both are load-bearing:

  * "no database" is not the same as "no configuration". A redacted template is
    restored from `settings/opds.lua`, so a marker opens and reads with the
    catalog deleted, and cannot fetch its pages with the *OPDS catalog* deleted.
    The failure is loud and self-describing — a 404 whose path says
    `<redacted>` — rather than a book that will not open.
  * a marker written before this existed still carries the key, and nothing
    rewrites it. Markers are not scrubbed in place: rewriting a book file the
    reader did not ask to have rewritten is worse than a stale copy in a folder
    they control. Delete and re-add such books if that matters to you.

What is deliberately *not* in the file: any series metadata. Volume order,
titles, whether a series has new chapters — all of that is the catalog's, in one
place. The old sibling plugin duplicated a sibling list into every marker, which
meant nothing could answer a question about a series without opening all of them.

Serialized with LuaSettings, so a marker is an ordinary Lua file and any code
that can open DocSettings can read it.
--]]

local Device = require("device")
local LuaSettings = require("luasettings")
local logger = require("logger")

local Credential = require("meguru/credential")
local FS = require("meguru/fs")
local Naming = require("meguru/naming")
local Paths = require("meguru/paths")
local Settings = require("meguru/settings")
local Sources = require("meguru/sources")

local Marker = {}

--- Key the descriptor is stored under inside the marker file. Also the test
--- for "is this file ours" on read, so a stray file with the same extension
--- opened from History never turns into a bogus stream.
Marker.SETTINGS_KEY = Paths.MARKER_EXT

Marker.VERSION = 1

--- Build a descriptor, keeping the shape in one place.
---
---   server_name       catalog title from KOReader's OPDS settings — the key
---                     credentials are looked up by, never a secret itself
---   series_remote_id  the series' id at the provider, for catalog lookup
---   item_key          authoritative identity of this item within its series
---   item_id           catalog rowid — a *hint only*, validated before use
---   title             as shown to the reader
---   template, count   enough to open and read with no database
---   last_read         server-reported, cosmetic
---
--- **`template` here is the live URL, secret and all** — this builds the
--- in-memory descriptor, not the file. `saveAt` redacts it on the way out and
--- `load` restores it on the way in, so a caller that builds a descriptor, saves
--- it and reads the file back gets the same string it started with, and a caller
--- that inspects `desc.template` after a save still has the real one.
function Marker.new(fields)
    return {
        version          = Marker.VERSION,
        server_name      = fields.server_name,
        series_remote_id = fields.series_remote_id,
        item_key         = fields.item_key,
        item_id          = fields.item_id,
        title            = fields.title,
        template         = fields.template,
        count            = fields.count,
        last_read        = fields.last_read,
    }
end

--- A descriptor complete enough to open a book from.
---
--- Deliberately a predicate over the descriptor alone, and it does **not** test
--- for an unrestored `<redacted>` in the template. Two reasons: a validity test
--- that depended on whether a catalog happens to be configured would be a
--- different kind of test than this one, and this one is also the "is this file
--- ours at all" check that keeps a stray `.meguru` from becoming a bogus stream.
--- A marker whose catalog is missing is *valid* — it opens, and its pages fail
--- to fetch with a URL that says why.
function Marker.isValid(desc)
    return type(desc) == "table"
        and type(desc.template) == "string" and desc.template ~= ""
        and type(desc.item_key) == "string" and desc.item_key ~= ""
end

--- Identity of the book a descriptor names, for comparing and for deriving
--- names that must be stable. Never includes the template: a template can carry
--- a rotated API key or a renumbered chapter, and neither may count as a
--- different book.
function Marker.naturalKey(desc)
    return table.concat({
        desc.server_name or "",
        desc.series_remote_id or "",
        desc.item_key or "",
    }, "|")
end

--- Put the credential back into a descriptor read off disk.
---
--- The file stores a placeholder rather than the key (`saveAt` put it there),
--- so this is the inverse half of one pair, and the pair has exactly one member
--- on each side. Every caller of `Marker.load` therefore sees a descriptor whose
--- `template` is the real stream URL, and none of them has to know the file is
--- redacted at all — which is the point of doing it here rather than at the
--- call sites. `ui/open.lua` alone reads a marker from four places, and a
--- fifth added later would not know to restore.
---
--- **A marker with no catalog configured still loads.** It is a valid marker —
--- `isValid` asks whether the file is ours and complete, not whether the world
--- is configured — and refusing it would cost the reader the book with a message
--- that misdescribes its own file. What it cannot do is fetch: the placeholder
--- stays, the URL 404s, and the log says why. See `MeguruDocument:init`.
local function restoreCredential(desc)
    if type(desc.template) ~= "string"
        or not desc.template:find(Credential.PLACEHOLDER, 1, true) then
        -- Nothing to do, and this is the common path — every Suwayomi marker,
        -- and every Kavita one written before this existed. Silent on purpose:
        -- a line here would be a line per book opened.
        return desc
    end
    local conn = Sources.connection(desc.server_name)
    local restored, count = Credential.restoreTemplate(desc.template, conn and conn.url)
    if count == 0 then
        -- The placeholder survived: no catalog of that title, or one whose root
        -- no longer matches this template's prefix (a renamed entry, a second
        -- server sharing the title, a server that moved host). Both are worth
        -- saying out loud — this is the line the reader pastes into a report,
        -- and without it the diagnosis needs them to know that a `<redacted>`
        -- in a URL is not what the server sent.
        logger.warn("Meguru: the marker for", desc.title or "?", "has a redacted"
            .. " stream URL and no usable catalog named",
            tostring(desc.server_name), "- it will open but cannot fetch pages")
        return desc
    end
    if count > 1 then
        -- The credential sat in more than one path position, and both were
        -- filled with the same value. Right for every shape the supported
        -- servers emit, unverified for one nobody has seen.
        logger.dbg("Meguru: restored", count, "credentials in the marker for",
            desc.title or "?")
    end
    desc.template = restored
    return desc
end

--- Read a descriptor back from a marker file, or nil when the file is missing
--- or does not hold one of ours.
---
--- The descriptor comes back as the book it names, not as the file it came
--- from: `template` has its credential restored — see `restoreCredential`.
function Marker.load(path)
    if not FS.exists(path) then
        return nil
    end
    -- LuaSettings.open is a *colon* method. pcall must forward both arguments,
    -- so it needs a closure: a bare pcall(LuaSettings.open, path) would bind
    -- path to `self` and leave file_path nil, silently reading an empty table.
    local ok, ls = pcall(function()
        return LuaSettings:open(path)
    end)
    if not ok or not ls then
        return nil
    end
    local desc = ls:readSetting(Marker.SETTINGS_KEY)
    if not Marker.isValid(desc) then
        return nil
    end
    return restoreCredential(desc)
end

--- Does the marker at `path` describe the same book as `desc`?
---
--- Read back only when a title is already taken — never on the fresh-write path,
--- which is the common one.
function Marker.matches(path, desc)
    local existing = Marker.load(path)
    return existing ~= nil and Marker.naturalKey(existing) == Marker.naturalKey(desc)
end

--- Where a marker write should land.
---
--- The user's chosen folder when one is set and usable, otherwise the KOReader
--- home folder — the folder the file browser opens in. A stale choice (a folder
--- on media that was unplugged) falls back rather than losing the marker.
function Marker.baseDir()
    local dir = Settings.get("marker_dir")
    if type(dir) == "string" and dir ~= "" then
        if FS.ensureDir(dir) then
            return dir
        end
        logger.warn("Meguru: marker folder unusable (", dir,
            "), falling back to the home folder")
    end
    return Marker.homeDir()
end

--- The folder the file browser opens in, resolved the way KOReader's own
--- filemanagerutil.getHomeFolder does — except that when neither the configured
--- nor the device default is usable it falls back to the plugin cache dir
--- rather than KOReader's bare ".", which would point at the process working
--- directory and hide the marker somewhere nobody will find it.
function Marker.homeDir()
    local dir
    local g = rawget(_G, "G_reader_settings")
    local configured = g and type(g.readSetting) == "function" and g:readSetting("home_dir")
    if type(configured) == "string" and configured ~= "" then
        dir = configured
    elseif type(Device.home_dir) == "string" and Device.home_dir ~= "" then
        dir = Device.home_dir
    end
    if type(dir) == "string" and dir ~= "" and FS.ensureDir(dir) then
        return dir
    end
    logger.warn("Meguru: home folder unusable, falling back to the plugin cache dir")
    return FS.ensureDir(Paths.cacheDir()) or Paths.cacheDir()
end

--- Folder the "save as a book" picker should start in: the last choice while it
--- is still a real directory, otherwise the home folder, so a stored folder
--- whose volume is gone never leaves the picker on a dead path.
function Marker.pickerStartDir()
    local dir = Settings.get("marker_dir")
    if type(dir) == "string" and dir ~= "" and FS.isDir(dir) then
        return dir
    end
    return Marker.homeDir()
end

--- The folder a marker for this book belongs in: `<base>[/<Server>]/<Series>`.
---
--- `series` is `{ name = ..., remote_id = ... }` or nil. The
--- `series_folder_claimed` option says a *different* series on this server
--- already owns the plain series component; the newcomer is then suffixed
--- rather than sharing a folder with it.
---
--- The claim is passed in rather than looked up here so this module needs no
--- database — and so a marker write still works when the catalog is gone.
---
--- Suffixing only ever affects the book being saved now. A series that already
--- has markers keeps its folder even when it is the one that "should" have been
--- suffixed, because moving it would orphan the DocSettings sidecars that hold
--- its reading progress. A collision that goes unnoticed (no catalog to ask) is
--- therefore harmless: two series share a folder, exactly as the old plugin did,
--- and no file is ever overwritten.
---
--- **Pure: it returns where a marker would go and creates nothing.** It used to
--- `FS.ensureDir` each component as it built the path, which was right while the
--- caller was about to write — and wrong the moment the write moved to the end of
--- the resume dialog. Tapping a book and then tapping past the question left the
--- series folder behind, empty, and an empty folder is not the harmless leftover
--- it looks like: it is indistinguishable from a series whose books were all
--- deleted, and it survives a "Clear cache" the way nothing else here does.
--- Creating it is now `saveAt`'s, at the moment there is a file to put in it.
---
--- The one thing that is *not* deferred is the outermost folder: `base_dir`
--- defaults to `Marker.baseDir()`, which does create it, because "is this folder
--- usable" is the question it exists to answer and a path on unplugged media has
--- to be rejected before anything is planned around it.
function Marker.dirFor(desc, series, opts)
    opts = opts or {}
    local dir = opts.base_dir or Marker.baseDir()

    if opts.server_folder and type(desc.server_name) == "string" and desc.server_name ~= "" then
        local server = Naming.sanitizeComponent(desc.server_name)
        if server ~= "stream" then
            dir = dir .. "/" .. server
        end
    end

    if type(series) == "table" and type(series.name) == "string" and series.name ~= "" then
        local component = Naming.sanitizeComponent(series.name)
        if component ~= "stream" then
            if opts.series_folder_claimed and series.remote_id then
                component = Naming.disambiguated(component, series.remote_id)
            end
            dir = dir .. "/" .. component
        end
    end

    return dir
end

--- The marker file path for a descriptor inside `dir`.
---
--- Normally `<dir>/<title>.<ext>`, so a re-open finds the existing marker and
--- keeps its reading progress. Only when a *different* book
--- already owns that title (two volumes that share a title, two servers) is a
--- deterministic suffix of the natural key appended — distinct books never
--- clobber each other, and each always resolves back to the same file.
function Marker.pathFor(dir, desc)
    local base = Naming.markerBaseName(desc.title)
    local plain = dir .. "/" .. base .. "." .. Paths.MARKER_EXT
    if not FS.exists(plain) or Marker.matches(plain, desc) then
        return plain
    end
    return dir .. "/" .. Naming.disambiguated(base, Marker.naturalKey(desc))
        .. "." .. Paths.MARKER_EXT
end

--- Create `dir`, or the nearest ancestor that can be made.
---
--- Degrading is the behaviour `dirFor` used to have, one component at a time,
--- while it was also the thing creating the path: a subfolder that cannot be
--- made must cost the reader a folder level, not the book. The walk stops at
--- `Marker.baseDir()`, which has already vouched for itself, so this always
--- terminates on something usable rather than climbing to the filesystem root.
---
--- Returns the folder that was made, or nil when even the base is unusable.
local function ensureDirOrAncestor(dir)
    local base = Marker.baseDir()
    local candidate = dir
    while true do
        if FS.ensureDir(candidate) then
            return candidate
        end
        if #candidate <= #base then
            return nil
        end
        candidate = candidate:match("^(.*)/[^/]+$") or base
    end
end

--- Persist a descriptor at a path already decided by `pathFor`.
---
--- Separate from a plain write because the path has to be known *before* the
--- file exists. The resume dialog reads a marker's sidecar to decide what to say
--- ("Start reading" or "Continue — page 30"), and a sidecar is a path-derived
--- thing: `DocSettings:hasSidecarFile` and `localLastPage` both work on a path
--- that has no marker behind it yet. So the caller resolves everything, asks,
--- and only then writes — and it must write to the path it asked about, which
--- is why this does not call `pathFor` again. Recomputing would be a second
--- answer to a question already answered, and `pathFor` consults the directory
--- it is about to write into, so the two could disagree.
---
--- The folder is created here and only here, which is what keeps a dismissed
--- dialog from leaving an empty series folder behind — see `dirFor`.
---
--- **The descriptor is written with its credential removed, and the caller's
--- table is left alone.** Kavita's API key is a path segment, so the marker
--- file — which lives in the reader's *book* folder, not in `settings/` — would
--- otherwise carry it in plaintext, onto an SD card or into whatever syncs that
--- folder. `Marker.load` puts it back; the pair has exactly this one member on
--- each side. See `meguru/credential`.
---
--- A copy rather than an edit, and the reason is mechanical as well as
--- hygienic: `LuaSettings:saveSetting` stores the table *by reference* and only
--- serialises at `flush()`, so a table shared with this function is a live
--- object the caller could still change underneath the write. Nothing reads
--- `desc.template` after a save today, which is exactly when an invariant like
--- this is cheap to establish and expensive to retrofit.
---
--- The copy goes through `pairs` rather than an explicit field list: a list is
--- how a field added to `Marker.new` later gets silently dropped on the way to
--- disk.
---
--- Returns the path written, or nil when no folder could be made. A caller that
--- gets nil reports it; nothing is silently dropped.
function Marker.saveAt(path, desc)
    local dir = path:match("^(.*)/[^/]+$")
    if dir then
        local usable = ensureDirOrAncestor(dir)
        if not usable then
            logger.warn("Meguru: no usable folder for", path, "- the marker was not written")
            return nil
        end
        if usable ~= dir then
            logger.warn("Meguru: could not create", dir,
                "- the marker goes in", usable)
            path = usable .. "/" .. (path:match("([^/]+)$") or path)
        end
    end
    local stored = {}
    for key, value in pairs(desc) do
        stored[key] = value
    end
    stored.template = Credential.redactTemplate(desc.template)
    local ls = LuaSettings:open(path)
    ls:saveSetting(Marker.SETTINGS_KEY, stored)
    ls:flush()
    logger.info("Meguru: marker written to", path)
    return path
end

return Marker
