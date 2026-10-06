-- Seeds a book's per-book settings on first open; a stored value always wins.

local logger = require("logger")

local Settings = require("meguru/settings")

local Defaults = {}

-- Semantic fit -> zoom mode; the "content" modes crop through the document box.
local FIT_TO_ZOOM_MODE = {
    full   = "content",
    width  = "contentwidth",
    height = "contentheight",
}
Defaults.FIT_TO_ZOOM_MODE = FIT_TO_ZOOM_MODE

-- The one mapping of kopt_ row names to plugin preferences; a row's own domain.
Defaults.PREFERENCE_FOR = {
    trim_page             = "trim_page",
    panel_view            = "panel_view",
    rotate_wide_pages     = "rotate_wide",
    page_scroll           = "page_scroll",
    opdsbook_fit          = "fit",
    opdsbook_manga        = "manga_order",
    rotation_mode         = "rotation_mode",
    contrast              = "contrast",
    saturation            = "saturation",
    derainbow             = "derainbow",
    sw_dithering          = "dither",
    spread                = "spread",
    spread_offset         = "spread_offset",
    spread_gutter         = "spread_gutter",
}
local PREFERENCE_FOR = Defaults.PREFERENCE_FOR

-- The book's own value from the sidecar, else the preference, then stored back.
-- Read the sidecar, not configurable: that holds global kopt_* defaults.
-- Pass the value through untouched; 0 is valid and truthy, so never normalise.
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

-- Fixed layout always: a streamed page is a picture and must not reflow.
function Defaults.seedLayout(ui, configurable)
    configurable.text_wrap = 0
    if ui.doc_settings then
        ui.doc_settings:saveSetting("kopt_text_wrap", 0)
    end
end

-- Seeds the geometry rows; spread and offset are strings/numbers, not booleans.
function Defaults.seedGeometry(ui, configurable)
    local ds = ui.doc_settings
    for _, name in ipairs{
        "trim_page", "rotate_wide_pages", "panel_view",
        "spread", "spread_offset", "spread_gutter",
    } do
        local value = seedRowValue(ds, name)
        if value ~= nil then
            configurable[name] = value
        end
    end
end

-- Overwrites the tone a global kopt_* may have put in, from the preference.
function Defaults.seedTone(ui, configurable)
    for _, name in ipairs{ "contrast", "saturation" } do
        local value = seedRowValue(ui.doc_settings, name)
        if value ~= nil then
            configurable[name] = value
        end
    end
end

-- Always has a preference and no stock key, so there is no global to displace.
function Defaults.seedDerainbow(ui, configurable)
    local value = seedRowValue(ui.doc_settings, "derainbow")
    if value ~= nil then
        configurable.derainbow = value
    end
end

-- Three answers: seeds from the value the page is actually being drawn with.
function Defaults.seedDither(ui, configurable)
    local ds = ui.doc_settings
    local doc = ui.document
    local value = ds and ds:readSetting("kopt_sw_dithering")
    if value == nil then
        value = Settings.get("dither")
        if value ~= nil and ds then
            ds:saveSetting("kopt_sw_dithering", value)
        end
    end
    if value ~= nil then
        -- Normalise by comparison, never "and 1 or 0", which reads 0 as "on".
        value = (value == 1 or value == true) and 1 or 0
    end
    if value == nil then
        -- Nothing chosen: show the device's own answer, not a stock 0.
        configurable.sw_dithering = (doc and doc.sw_dithering) and 1 or 0
        return
    end
    -- Row domain is 0/1, the document field boolean; converted here only.
    configurable.sw_dithering = value
    if doc then
        doc.sw_dithering = value == 1
    end
end

-- Page view, not stock continuous scroll; the live view must be switched too.
function Defaults.seedScrollMode(ui, configurable)
    local ds = ui.doc_settings
    local value = ds and ds:readSetting("kopt_page_scroll")
    if value == nil then
        -- Already 0 or 1; 0 is truthy in Lua, so pass it through unchanged.
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

-- Only for a reader who chose one: unset keeps whatever KOReader decided.
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

-- Forced every open: ReaderConfig may have loaded an old stored "off".
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

-- A book keeps its own zoom; only one with none takes the plugin-wide fit.
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

-- Applies every seed; a no-op for any non-Meguru document.
function Defaults.apply(ui, doc)
    if not (ui and doc and doc.provider == "meguru" and doc.configurable) then
        return false
    end
    local configurable = doc.configurable
    Defaults.seedLayout(ui, configurable)
    Defaults.seedGeometry(ui, configurable)
    Defaults.seedTone(ui, configurable)
    Defaults.seedDerainbow(ui, configurable)
    Defaults.seedDither(ui, configurable)
    Defaults.seedScrollMode(ui, configurable)
    Defaults.seedRotation(ui, configurable)
    Defaults.seedNightMode(ui, configurable)
    Defaults.seedFit(ui)

    -- The reader derived the page's box before these seeds; re-derive it now.
    if type(ui.handleEvent) == "function" then
        local Event = require("ui/event")
        ui:handleEvent(Event:new("ReZoom"))
    end

    logger.dbg("Meguru: seeded per-book defaults for", doc.file)
    return true
end

return Defaults
