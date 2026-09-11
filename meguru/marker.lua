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
function Marker.dirFor(desc, series, opts)
    opts = opts or {}
    local dir = opts.base_dir or Marker.baseDir()

    if opts.server_folder and type(desc.server_name) == "string" and desc.server_name ~= "" then
        local server = Naming.sanitizeComponent(desc.server_name)
        if server ~= "stream" then
            dir = FS.ensureDir(dir .. "/" .. server) or dir
        end
    end

    if type(series) == "table" and type(series.name) == "string" and series.name ~= "" then
        local component = Naming.sanitizeComponent(series.name)
        if component ~= "stream" then
            if opts.series_folder_claimed and series.remote_id then
                component = Naming.disambiguated(component, series.remote_id)
            end
            dir = FS.ensureDir(dir .. "/" .. component) or dir
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

--- Persist a descriptor and return the marker file path.
function Marker.save(desc, dir)
    dir = (dir and FS.ensureDir(dir)) or Marker.baseDir()
    local path = Marker.pathFor(dir, desc)
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
