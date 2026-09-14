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

--- The directory the plugin itself is installed in, as pluginloader assigned it
--- (`pluginloader.lua:248`). Nothing here can derive it — the plugin may live on
--- removable media, under any name ending in `.koplugin` — so it is handed over
--- once, from `main.lua`, before anything can ask for a file inside it.
local plugin_dir

--- Remember where the plugin lives. Called from `Meguru:init`, which runs when
--- the plugin starts and therefore before any browse can want an asset.
function Paths.setPluginDir(dir)
    plugin_dir = type(dir) == "string" and dir or nil
end

--- The directory the plugin is installed in, or nil when it is not known yet.
---
--- `Paths.asset` derives from the same local, and that is the whole reason this
--- getter exists: the updater has to move, replace and read from that directory
--- itself, and reaching into `plugin.path` from another module would be a second
--- owner of the same fact. Nil is an ordinary answer — the plugin can be
--- required before `Meguru:init` has run — so every caller checks.
function Paths.pluginDir()
    if type(plugin_dir) ~= "string" or plugin_dir == "" then
        return nil
    end
    return plugin_dir
end

--- Where a file shipped inside the plugin lives, or nil when that directory is
--- not known.
---
--- **Whether the file is actually there is the caller's question**, not this
--- one: this module is pure derivation and touches no filesystem (`meguru/fs`
--- does that). A build that ships no `assets/` is not a broken build, so the
--- caller must treat "no file" as an ordinary answer rather than a failure.
function Paths.asset(name)
    if type(plugin_dir) ~= "string" or plugin_dir == "" then
        return nil
    end
    return plugin_dir .. "/assets/" .. name
end

return Paths
