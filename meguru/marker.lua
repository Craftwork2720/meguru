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

--- 2: the marker carries the series identity a feed needs (`series_name`,
--- `server_kind`, `lang`) and the book's own artwork, so an open needs nothing
--- but the file. Nothing reads this field — it is a note for whoever finds an
--- old file, not a gate: a v1 marker is still valid and still reads.
Marker.VERSION = 2

--- Build a descriptor, keeping the shape in one place.
---
---   server_name        catalog title from KOReader's OPDS settings — the key
---                      credentials are looked up by, never a secret itself
---   series_remote_id   the series' id at the provider
---   series_name        the series as it is named to the reader: the History
---                      title, the dialog title, and the folder component
---   server_kind        which driver reads this server's feeds. Without it a
---                      book opened from History has no feed URL to build, so
---                      it has no next chapter — ever, not just until a sync
---   item_key           authoritative identity of this item within its series
---   title              as shown to the reader
---   template, count    enough to open and read with no database
---   last_read          server-reported, cosmetic
---   lang               the translation Suwayomi serves (`?lang=`); nil means
---                      its default, exactly as a nil `ctx.lang` does today
---   cover_url          this book's own artwork, where its feed published one
---   series_cover_url   the series' artwork, the step before page 1
---
--- **The URLs here are the live ones, secrets and all** — this builds the
--- in-memory descriptor, not the file. `saveAt` redacts them on the way out and
--- `load` restores them on the way in, so a caller that builds a descriptor,
--- saves it and reads the file back gets the same strings it started with, and
--- a caller that inspects `desc.template` after a save still has the real one.
---
--- `item_id` is gone: it was the catalog's rowid, carried so an open could
--- notice the database had been rebuilt underneath the marker. There is no
--- database to be rebuilt, so there is nothing for it to guard. A v1 file keeps
--- carrying the number; nothing reads it.
function Marker.new(fields)
    return {
        version          = Marker.VERSION,
        server_name      = fields.server_name,
        series_remote_id = fields.series_remote_id,
        series_name      = fields.series_name,
        server_kind      = fields.server_kind,
        item_key         = fields.item_key,
        title            = fields.title,
        template         = fields.template,
        count            = fields.count,
        last_read        = fields.last_read,
        lang             = fields.lang,
        cover_url        = fields.cover_url,
        series_cover_url = fields.series_cover_url,
    }
end

--- The fields above that hold a URL a credential can sit inside.
---
--- One list, read by both halves of the redaction pair below. A field added to
--- `Marker.new` and not added here is written to disk **with the API key in
--- it** — which is what CLAUDE.md's security note exists to prevent, and what
--- the marker's whole redaction apparatus was built for. `Kavita` puts its key
--- in a path segment of every URL it emits, covers included.
local CREDENTIAL_FIELDS = { "template", "cover_url", "series_cover_url" }

--- What this marker knows about its series, for callers that need the context
--- rather than the book.
---
--- The v1 fallbacks live here and only here, so no caller has to know which
--- fields an older file might be missing: a marker written before `series_name`
--- existed answers with nil and every reader of it already falls back (History
--- shows the book's own title, the dialog falls back to the book label). The
--- one field with no fallback is `server_kind`, and that is honest — without a
--- driver there is no feed URL, so there are no neighbours.
function Marker.seriesContext(desc)
    if type(desc) ~= "table" then
        return nil
    end
    return {
        server_name      = desc.server_name,
        server_kind      = desc.server_kind,
        series_remote_id = desc.series_remote_id,
        series_name      = desc.series_name,
        -- The book's own identity within that series, which is how a feed
        -- answers "which entry is this one" without a rowid: it is the same
        -- key the drivers derive, so a walk and a marker cannot disagree
        -- about which chapter a book is.
        item_key         = desc.item_key,
        lang             = desc.lang,
        cover_url        = desc.cover_url,
        series_cover_url = desc.series_cover_url,
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
    -- Is there anything to do at all? Answered first and once: the common path
    -- is a marker with no placeholder anywhere (every Suwayomi one, and every
    -- Kavita one written before this existed), and a line per book opened
    -- because of it would be noise.
    local pending = false
    for _, field in ipairs(CREDENTIAL_FIELDS) do
        local value = desc[field]
        if type(value) == "string" and value:find(Credential.PLACEHOLDER, 1, true) then
            pending = true
            break
        end
    end
    if not pending then
        return desc
    end

    local conn = Sources.connection(desc.server_name)
    -- Named, and warned once for the whole marker rather than once per field: a
    -- Kavita marker whose catalog is missing has three placeholders in it, and
    -- three identical warnings would read as three separate faults.
    local stuck = {}
    local restored_count = 0
    for _, field in ipairs(CREDENTIAL_FIELDS) do
        local value = desc[field]
        if type(value) == "string" and value:find(Credential.PLACEHOLDER, 1, true) then
            local restored, count = Credential.restoreTemplate(value, conn and conn.url)
            if count == 0 then
                stuck[#stuck + 1] = field
            else
                desc[field] = restored
                restored_count = restored_count + count
            end
        end
    end
    if #stuck > 0 then
        -- The placeholder survived: no catalog of that title, or one whose root
        -- no longer matches this URL's prefix (a renamed entry, a second server
        -- sharing the title, a server that moved host). Both are worth saying
        -- out loud — this is the line the reader pastes into a report, and
        -- without it the diagnosis needs them to know that a `<redacted>` in a
        -- URL is not what the server sent. The field names matter: a stuck
        -- `cover_url` costs a cover, a stuck `template` costs the book.
        logger.warn("Meguru: the marker for", desc.title or "?", "still has"
            .. " redacted URLs in", table.concat(stuck, ", "), "and no usable"
            .. " catalog named", tostring(desc.server_name),
            "- it opens, but those fetches cannot")
    end
    if restored_count > 1 then
        -- The credential sat in more than one path position, and both were
        -- filled with the same value. Right for every shape the supported
        -- servers emit, unverified for one nobody has seen.
        logger.dbg("Meguru: restored", restored_count, "credentials in the"
            .. " marker for", desc.title or "?")
    end
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
    -- Every URL, not just the stream template: Kavita puts the same key in the
    -- path of the artwork it publishes, so a cover left unredacted is the same
    -- secret in the same file. The list is one place, so a URL field added to
    -- `Marker.new` cannot be redacted on the way out and forgotten on the way
    -- in — see `CREDENTIAL_FIELDS`.
    for _, field in ipairs(CREDENTIAL_FIELDS) do
        if type(stored[field]) == "string" then
            stored[field] = Credential.redactTemplate(stored[field])
        end
    end
    local ls = LuaSettings:open(path)
    ls:saveSetting(Marker.SETTINGS_KEY, stored)
    ls:flush()
    logger.info("Meguru: marker written to", path)
    return path
end

return Marker
