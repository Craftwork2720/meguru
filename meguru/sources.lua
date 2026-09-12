--[[--
Read-only view of the catalogs the user configured for KOReader's built-in
OPDS plugin, in `settings/opds.lua`.

That file is the one place a secret was ever configured, so it is where
credentials are read from — and it is only ever read. Nothing here writes to
it, and nothing here is persisted: a marker stores `server_name` (a catalog
title, not a secret) and the password is looked up at the moment a page has to
be fetched.

It is also where the *other* secret is read from — Kavita's API key, which is a
path segment of the root URL rather than a password. A marker stores a stream
template with that segment replaced by a placeholder, and `Marker.load` puts it
back by reading this file; see `meguru/credential`. So "the marker holds no
secret" is true because of what is done to it on the way out, not because a
template has nothing secret in it.

The catalog title is also the identity a server is stored under in the
catalog, which is why it is `server_name` everywhere rather than a URL: Kavita's
URL changes when the API key rotates, and every rotation would otherwise fork a
second server row.
--]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger = require("logger")

local FS = require("meguru/fs")

local Sources = {}

--- Per-run cache of credentials, keyed by marker path.
---
--- A book opened straight out of the catalog must fetch immediately, which can
--- be before the built-in OPDS plugin has flushed `opds.lua` to disk — so the
--- credentials that were just used are kept in memory for the session. It also
--- deliberately outranks the file: a password changed in this run should win
--- over the one still on disk.
local session = {}

function Sources.remember(marker_path, username, password)
    if marker_path and (username ~= nil or password ~= nil) then
        session[marker_path] = { username = username, password = password }
    end
end

function Sources.settingsFile()
    return DataStorage:getSettingsDir() .. "/opds.lua"
end

--- Every configured catalog, in the order the user sees them, or an empty list.
---
--- Returns the raw entries; callers that only want one should use `find`.
function Sources.list()
    local file = Sources.settingsFile()
    if not FS.exists(file) then
        return {}
    end
    -- LuaSettings.open is a colon method: `path` binds to self and the file
    -- path is lost unless pcall gets a closure.
    local ok, ls = pcall(function()
        return LuaSettings:open(file)
    end)
    if not ok or not ls then
        logger.warn("Meguru: could not read", file)
        return {}
    end
    local servers = ls:readSetting("servers")
    return type(servers) == "table" and servers or {}
end

--- One configured catalog by its title, or nil.
function Sources.find(title)
    if type(title) ~= "string" or title == "" then
        return nil
    end
    for _, entry in ipairs(Sources.list()) do
        if type(entry) == "table" and entry.title == title then
            return entry
        end
    end
    return nil
end

--- The root URL and credentials to reach `title`, or nil when no such catalog
--- is configured.
---
--- Separate from `find` because the root URL is a secret-bearing value: callers
--- keep it in a local and must not store it. `servers.root_url` holds only the
--- redacted form, for diagnostics.
function Sources.connection(title)
    local entry = Sources.find(title)
    if not entry then
        return nil
    end
    return {
        name     = entry.title,
        url      = entry.url,
        username = entry.username,
        password = entry.password,
    }
end

--- Credentials a document should fetch its pages with.
---
--- Resolution order: what this session already used for this marker, then the
--- configured catalog. Returns `nil` when neither has anything, which is the
--- normal case for a catalog with no authentication.
function Sources.credentials(server_name, marker_path)
    local cached = marker_path and session[marker_path]
    if cached then
        return cached.username, cached.password
    end
    local entry = Sources.find(server_name)
    if entry then
        return entry.username, entry.password
    end
    return nil
end

return Sources
