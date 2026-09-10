--[[--
Seeding a book's own settings the first time it is opened.

KOReader reads per-book settings from the sidecar, and for a streamed book most
of them mean something different than they do for a PDF: the pages are a fixed
layout that must not reflow, the fit is against a *cropped* box, and the reader
expects page-turn navigation rather than continuous scroll. ReaderConfig and
ReaderKoptListener have already run by the time this does, so each value is
re-asserted here rather than merely defaulted.

The rule every seed follows: **a book that already carries a value keeps it.**
The plugin-wide preference only ever fills a gap, which is why each one is
written back into the book's sidecar — doing so freezes the choice per book and
stops a later change to a *global* `kopt_*` (from a PDF opened in the same
session, say) from leaking in on the next open.

There is no migration here. Markers are `.meguru` and nothing predates them, so
every sidecar this runs against was written by this plugin.
--]]

local logger = require("logger")

local Settings = require("meguru/settings")

local Defaults = {}

--- Semantic fit -> KOReader's zoom mode. "content" and friends crop through the
--- document's bounding box, which is where this plugin's auto-crop lives; the
--- bare "page"/"pagewidth"/"pageheight" modes ignore the box and would undo it.
---
--- Exported because `ui/reader.lua`'s Fit row needs the same mapping to read the
--- live zoom mode back out of the reader.
local FIT_TO_ZOOM_MODE = {
    full   = "content",
    width  = "contentwidth",
    height = "contentheight",
}
Defaults.FIT_TO_ZOOM_MODE = FIT_TO_ZOOM_MODE

--- Which plugin-wide preference backs which `kopt_*` row. They are named
--- separately on purpose: the row names are KOReader's, and the plugin's own
--- keys should not have to spell themselves the way KOReader does.
---
--- The single place this mapping lives. It is read here, to seed a book that has
--- no value of its own, and by `ui/reader.lua`, to carry a long-press "set as
--- default" on a curated row to the same preference — two things that would
--- otherwise drift apart, one of them silently.
---
--- The values are stored in the row's *own* domain, not as booleans: the crop
--- rows are 0/1, `trim_page` is 1-or-3, `rotate_wide_pages` is 0/1/2, and `fit`
--- is a string — exactly what `Settings.DEFAULTS` declares and what
--- `ConfigDialog` writes into a book's sidecar. `seedRowValue` therefore copies
--- a preference verbatim rather than normalising it.
Defaults.PREFERENCE_FOR = {
    trim_page             = "trim_page",
    page_number_crop_auto = "page_number_crop",
    no_crop_blank_pages   = "no_crop_blank",
    rotate_wide_pages     = "rotate_wide",
    page_scroll           = "page_scroll",
    opdsbook_fit          = "fit",
    opdsbook_manga        = "manga_order",
    rotation_mode         = "rotation_mode",
}
local PREFERENCE_FOR = Defaults.PREFERENCE_FOR

--- One `kopt_*` value: the book's own if it has one, otherwise the plugin-wide
--- preference, written back so the book owns it from now on.
---
--- Read from the *sidecar*, never from `configurable`: that table has already
--- been filled from the global `kopt_*` defaults by ReaderConfig, so treating it
--- as the book's own would freeze a global value into this book and lock the
--- plugin preference out for good.
---
--- The value is passed through untouched, in whatever domain the row uses. The
--- explicit `~= nil` is load-bearing for exactly that reason: 0 is a valid
--- choice for several of these rows *and* is truthy in Lua, so any normalising
--- step is a chance to corrupt it. An earlier `value and 1 or 0` here turned a
--- stored `0` (meaning "off") into `1` and a stored `3` ("crop: none") into `1`
--- ("crop: auto") — a book that had deliberately chosen either came back wrong.
local function seedRowValue(ds, name)
    local current = ds and ds:readSetting("kopt_" .. name)
    if current ~= nil then
        return current
    end

    local value = Settings.get(PREFERENCE_FOR[name] or name)
    if value == nil then
        return nil
    end
    if ds then
        ds:saveSetting("kopt_" .. name, value)
    end
    return value
end

-- ---------------------------------------------------------------------------
-- The seeds
-- ---------------------------------------------------------------------------

--- Fixed layout, always. A streamed page is a picture; letting reflow in from a
--- global default would re-typeset artwork.
function Defaults.seedLayout(ui, configurable)
    configurable.text_wrap = 0
    if ui.doc_settings then
        ui.doc_settings:saveSetting("kopt_text_wrap", 0)
    end
end

--- Crop, page-number removal, blank-page handling and wide-page rotation.
function Defaults.seedGeometry(ui, configurable)
    local ds = ui.doc_settings
    for _, name in ipairs{
        "trim_page", "page_number_crop_auto", "no_crop_blank_pages", "rotate_wide_pages",
    } do
        local value = seedRowValue(ds, name)
        if value ~= nil then
            configurable[name] = value
        end
    end
end

--- Page view rather than the stock KOpt default of continuous scroll.
---
--- ReaderView has already resolved the absent key to `view.page_scroll == true`,
--- so the live view has to be switched back, not just the setting.
function Defaults.seedScrollMode(ui, configurable)
    local ds = ui.doc_settings
    local value = ds and ds:readSetting("kopt_page_scroll")
    if value == nil then
        -- Already 0 or 1 in `Settings`; `and 1 or 0` here would read 0 — which
        -- is truthy in Lua — as "on" and store continuous scroll in a book that
        -- never asked for it.
        value = Settings.get("page_scroll")
        if ds then
            ds:saveSetting("kopt_page_scroll", value)
        end
    end
    configurable.page_scroll = value

    local view = ui.view
    if value == 0 and view and view.page_scroll
        and type(view.onSetScrollMode) == "function" then
        view:onSetScrollMode(false)
    end
end

--- Screen rotation, but only for a reader who has actually chosen one.
---
--- `rotation_mode` is unset by default, and an unset preference means the book
--- keeps whatever KOReader decided — the plugin does not impose a rotation
--- nobody asked for. Writing it per book also stops the global
--- `kopt_rotation_mode` fallback from reaching a stream book.
function Defaults.seedRotation(ui, configurable)
    local ds = ui.doc_settings
    if ds and ds:readSetting("kopt_rotation_mode") ~= nil then
        return
    end
    local mode = Settings.get("rotation_mode")
    if mode == nil then
        return
    end
    configurable.rotation_mode = mode
    if ds then
        ds:saveSetting("kopt_rotation_mode", mode)
    end

    local view = ui.view
    local locked = false
    local g = rawget(_G, "G_reader_settings")
    if g and type(g.isTrue) == "function" then
        locked = g:isTrue("lock_rotation")
    end
    if not locked and view and type(view.onSetRotationMode) == "function" then
        view:onSetRotationMode(mode)
    end
end

--- Night mode pre-inverts each page inside the render path rather than letting
--- the screen invert the finished result, which is what keeps artwork from
--- showing as a stark negative. Forced on every open, not just seeded, because
--- ReaderConfig loads the book's stored value first and it may be an old "off".
function Defaults.seedNightMode(ui, configurable)
    if not Settings.get("night_mode") then
        return
    end
    configurable.nightmode_document = 1
    local ds = ui.doc_settings
    if ds and ds:readSetting("kopt_nightmode_document") ~= 1 then
        ds:saveSetting("kopt_nightmode_document", 1)
    end
end

--- How the page is fitted. A book keeps its own zoom; only one with none gets
--- the plugin-wide fit.
function Defaults.seedFit(ui)
    local zooming = ui.zooming
    if not (zooming and type(zooming.setZoomMode) == "function") then
        return
    end
    local ds = ui.doc_settings
    local desired = ds and ds:readSetting("zoom_mode")
    if desired == nil then
        desired = FIT_TO_ZOOM_MODE[Settings.get("fit")]
    end
    if desired and zooming.zoom_mode ~= desired then
        zooming:setZoomMode(desired)
        if ds then
            ds:saveSetting("zoom_mode", desired)
        end
    end
end

--- Apply every seed to a book that is being opened. A no-op for any other
--- document, so this is safe to call from a plugin-wide `onReadSettings`.
function Defaults.apply(ui, doc)
    if not (ui and doc and doc.provider == "meguru" and doc.configurable) then
        return false
    end
    local configurable = doc.configurable
    Defaults.seedLayout(ui, configurable)
    Defaults.seedGeometry(ui, configurable)
    Defaults.seedScrollMode(ui, configurable)
    Defaults.seedRotation(ui, configurable)
    Defaults.seedNightMode(ui, configurable)
    Defaults.seedFit(ui)
    logger.dbg("Meguru: seeded per-book defaults for", doc.file)
    return true
end

return Defaults
