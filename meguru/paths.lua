--[[--
Where the plugin puts things.

Pure derivation only — no mkdir, no writes (that is `meguru/fs`). If something
lands in the wrong directory, this file is the only place to look.
--]]

local DataStorage = require("datastorage")

local Paths = {}

--- The last-resort folder for a marker, when neither the configured nor the
--- device home folder can be used (see `Marker.homeDir`). It is the only
--- directory the plugin can create unilaterally, so it must stay derivable.
---
--- It held the page and cover caches once, under `pages/` and `covers/`. Neither
--- exists: pages are in RAM and there are no covers. Files a previous version
--- left in those two subdirectories are never read again and nothing sweeps
--- them, so delete them by hand if they are still there.
function Paths.cacheDir()
    return DataStorage:getDataDir() .. "/cache/meguru"
end

--- Extension of the marker file. Deliberately *not* the sibling plugin's
--- `mgru`: the two have different payloads and different providers, and
--- DocumentRegistry does not de-duplicate registrations, so sharing an
--- extension would make which-provider-wins depend on install order.
Paths.MARKER_EXT = "meguru"

return Paths
