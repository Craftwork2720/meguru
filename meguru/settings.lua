--[[--
Plugin-wide preferences, stored in KOReader's global `G_reader_settings` under
`meguru_`-prefixed keys.

Per-book options are *not* here — they live in each book's DocSettings sidecar,
the way KOReader keeps `kopt_*` for a PDF. Nothing here may ever write a global
`kopt_*`.
--]]

local logger = require("logger")

local Settings = {}

-- Sentinel for "this preference is unset by default". A plain `nil` default
-- would not survive the table literal (Lua drops keys assigned nil), which
-- would make the known-key check below silently wrong.
local UNSET = {}
Settings.UNSET = UNSET

local DEFAULTS = {
    marker_dir        = UNSET,        -- base folder for new markers; unset => home folder
    marker_server_dir = false,        -- nest markers under a per-catalog folder
    hide_status_bar   = true,
    auto_next_item    = true,
    manga_order       = true,
    sync_enabled      = true,
    -- How stale a series may get before the background walk after an OPDS add
    -- will re-walk it. Read by `ui/open.lua`'s `startBackgroundSync` and handed
    -- to `Sync.plan`, which is why it is no longer a preference that decides
    -- nothing.
    sync_ttl_seconds  = 6 * 60 * 60,
    -- Pixel budget for one decoded page. The page is reduced by AREA (both
    -- axes by the same factor) until it fits, so the memory is bounded
    -- absolutely rather than by the square of a per-axis cap. Capping the
    -- longest edge instead punished tall pages without measure: an 800x20000
    -- strip lost 9.8x of its width while a 4000x5000 scan lost 2.4x, and width
    -- is all a reader sees of a strip.
    --
    -- 8 Mpx keeps three of the largest pages in RAM under 25 MB, and leaves a
    -- 2600x3700 spread effectively untouched (a 9% reduction).
    max_native_pixels = 8 * 1024 * 1024,

    -- How the page is fitted to the screen. Semantic rather than KOReader's own
    -- zoom_mode names, because the mapping is what changes when the crop
    -- changes, not the reader's intent.
    fit               = "full",       -- "full" | "width" | "height"

    -- Reading geometry. These are the plugin-wide fallbacks a book with no
    -- value of its own picks up; once written into a book's sidecar the book
    -- keeps its own and is never touched again.
    page_scroll       = 0,            -- 0 = page view, 1 = continuous
    trim_page         = 1,            -- 1 = auto margin crop, 3 = none
    page_number_crop  = 1,            -- cut a printed page number from the gutter
    no_crop_blank     = 1,            -- leave blank pages uncropped
    rotate_wide       = 1,            -- 0 = off, 1 = right, 2 = left
    night_mode        = true,         -- pre-invert pages instead of a stark negative

    -- Deliberately unset: a book with no stored rotation keeps KOReader's own
    -- behaviour until the reader actually chooses a rotation, so the plugin
    -- never imposes one nobody asked for. `Settings.get` returns nil for this.
    rotation_mode     = UNSET,
}

-- G_reader_settings is created by KOReader during startup. Reads also happen
-- from the render path and from early plugin init, so every accessor tolerates
-- it being absent instead of erroring.
local function readStore()
    local s = rawget(_G, "G_reader_settings")
    if s and type(s.readSetting) == "function" then
        return s
    end
    return nil
end

function Settings.get(name)
    local default = DEFAULTS[name]
    if default == nil then
        logger.warn("Meguru: unknown setting", name)
        return nil
    end
    if default == UNSET then
        default = nil
    end

    local s = readStore()
    if not s then
        return default
    end
    local value = s:readSetting("meguru_" .. name)
    if value == nil then
        return default
    end
    return value
end

function Settings.set(name, value)
    if DEFAULTS[name] == nil then
        logger.warn("Meguru: unknown setting", name)
        return false
    end
    local s = readStore()
    if not s then
        return false
    end
    s:saveSetting("meguru_" .. name, value)
    s:flush()
    return true
end

function Settings.toggle(name)
    local value = not Settings.get(name)
    Settings.set(name, value)
    return value
end

return Settings
