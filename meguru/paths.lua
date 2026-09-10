--[[--
Where the plugin puts things.

Pure derivation only — no mkdir, no writes (that is `meguru/fs`). If something
lands in the wrong directory, this file is the only place to look.
--]]

local DataStorage = require("datastorage")

local Paths = {}

function Paths.dbFile()
    return DataStorage:getSettingsDir() .. "/meguru.sqlite3"
end

function Paths.cacheDir()
    return DataStorage:getDataDir() .. "/cache/meguru"
end

function Paths.pageCacheDir()
    return Paths.cacheDir() .. "/pages"
end

function Paths.coverCacheDir()
    return Paths.cacheDir() .. "/covers"
end

--- Absolute path of the marker file for `title` inside `dir`.
function Paths.markerFile(dir, title)
    return dir .. "/" .. title .. "." .. Paths.MARKER_EXT
end

--- Extension of the marker file. Deliberately *not* the sibling plugin's
--- `mgru`: the two have different payloads and different providers, and
--- DocumentRegistry does not de-duplicate registrations, so sharing an
--- extension would make which-provider-wins depend on install order.
Paths.MARKER_EXT = "meguru"

return Paths
