--[[--
The marker file: a small book-shaped stand-in for a page stream.

A marker is what KOReader opens, what lands in History and what DocSettings
keeps reading progress for. It therefore has to be able to open a book with no
database at all, which is why `template` and `count` are in the file rather than
looked up: the catalog can be deleted, rebuilt or restored from a backup
independently of the books on disk, and every marker keeps working when it is.

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

local FS = require("meguru/fs")
local Naming = require("meguru/naming")
local Paths = require("meguru/paths")
local Settings = require("meguru/settings")

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

--- Read a descriptor back from a marker file, or nil when the file is missing
--- or does not hold one of ours.
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
    return desc
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
--- keeps its reading progress and its page cache. Only when a *different* book
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
    local ls = LuaSettings:open(path)
    ls:saveSetting(Marker.SETTINGS_KEY, desc)
    ls:flush()
    logger.info("Meguru: marker written to", path)
    return path
end

--- The name a document's cached pages and covers are filed under.
---
--- Derived from the natural key, *not* from the marker path. This used to be the
--- marker's basename, which is why the cache was shared between books: the
--- basename is the title, two series routinely title a chapter the same way,
--- and the guard that disambiguates a second book with the same title
--- (`pathFor` above) only ever looks inside one directory — so two "Volume 1"s
--- in two series folders each kept the plain name and each wrote to the same
--- cache file. Identity is the one thing that cannot collide, and reading it
--- from the descriptor rather than from the path also means moving or renaming
--- a marker keeps its cache, which is what `doc/cache.lua` has always claimed.
function Marker.cacheKey(desc)
    return Naming.cacheKey(Marker.naturalKey(desc), desc.title)
end

return Marker
