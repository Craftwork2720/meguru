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
--- The values are stored in the row's *own* domain, not as booleans: `trim_page`
--- is 1-or-3, `rotate_wide_pages` is 0/1/2, and `fit` is a string — exactly what
--- `Settings.DEFAULTS` declares and what `ConfigDialog` writes into a book's
--- sidecar. `seedRowValue` therefore copies a preference verbatim rather than
--- normalising it.
---
--- **Only rows that still exist are here.** The two page-number/blank toggles
--- used to be, and the argument for them was the same one as for `trim_page`:
--- they were rows of the curated crop tab. They are rules of the engine now
--- (`document.lua`'s getPageBBox), not rows, so there is no value to seed into a
--- book and nothing that would read one — a book that carries
--- `kopt_page_number_crop_auto` keeps it and is never asked about it again.
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
    sw_dithering          = "dither",
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

--- The crop itself, wide-page rotation, and which view a long-press opens. All
--- three are rows of the curated dialog; the page-number and blank-page rules used
--- to be rows too and are now part of what "Page Crop: auto" means, so there is
--- nothing to seed for them.
---
--- **`panel_view` seeds from the preference of the same name**, which is why it
--- needs no entry in `PREFERENCE_FOR` to be seeded — `seedRowValue` falls back to
--- the row's own name. It carries an entry anyway, for the mapping's other job:
--- the long-press "set as default". What that default holds is one of the three
--- *views*; the row's fourth answer, Off, is not a view but KOReader's own per-book
--- `panel_zoom_enabled`, and a preference cannot hold it — `ui/reader.lua`'s
--- `redirectDefaults` answers for that one case rather than writing it.
function Defaults.seedGeometry(ui, configurable)
    local ds = ui.doc_settings
    for _, name in ipairs{
        "trim_page", "rotate_wide_pages", "panel_view",
    } do
        local value = seedRowValue(ds, name)
        if value ~= nil then
            configurable[name] = value
        end
    end
end

--- The two MuPDF tone values, seeded like the geometry rows and for one more
--- reason besides.
---
--- `contrast` and `saturation` are both stock `kopt_*` rows, and
--- `Configurable:loadDefaults` fills them from the *global* settings table before
--- this runs — so a tone set on a PDF earlier in the same session would otherwise
--- be the starting tone of every Meguru book opened afterwards. Seeding them from
--- the plugin's own preferences (which always have a value:
--- `Settings.DEFAULTS.contrast` and `.saturation`) overwrites whatever the global
--- put there and writes the book's own, which is the same rule the rows above
--- follow.
---
--- One loop rather than two functions because there is nothing to say about one
--- of them that is not true of the other — they are applied at the same two draw
--- sites, invalidated by the same one method (`document.lua`'s `syncTone`) and
--- answered from the same `configurable` table. A difference between them that
--- matters lives where it matters: on the *screen* (saturation is a colour
--- operation and is dropped on a grayscale one), which `saturation()` handles and
--- which is not a seeding question.
function Defaults.seedTone(ui, configurable)
    for _, name in ipairs{ "contrast", "saturation" } do
        local value = seedRowValue(ui.doc_settings, name)
        if value ~= nil then
            configurable[name] = value
        end
    end
end

--- Whether the page is dithered, and the one seed here that may decide nothing.
---
--- **Three answers, not two, and the third is the point.** The document settles
--- this for itself when it opens — forced on for a grayscale framebuffer, the
--- screen's own answer otherwise (`document.lua`'s init) — and KOReader settles it
--- again a moment later from `configurable.sw_dithering`
--- (`ReaderView:onDitheringUpdate`, fired by `ReaderKoptListener` during
--- ReadSettings). Both run before this does, which is the one place the ordering
--- is load-bearing rather than merely convenient: it means the value read back
--- here is the one the page is *actually* being drawn with, not the one the
--- document first computed. The row is seeded from that, so the switch shows the
--- truth on a device where the two disagree.
---
--- The plugin preference behind it is unset by default (`Settings.UNSET`), so a
--- book with no choice of its own — which is every book until the reader taps the
--- row — keeps exactly the answer it had before the row existed, whatever this
--- device's answer is. Only a tap (which writes the sidecar) or a long-press
--- (which writes the preference) turns that into a stored decision.
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
        -- The row's domain is 0/1: that is what the dialog matches its `values`
        -- against and what the sidecar holds. Normalised here rather than with
        -- `value and 1 or 0`, which reads a stored 0 — truthy in Lua — as "on"
        -- (the trap `seedRowValue` above documents at length). The left side of
        -- this one is a comparison, so it cannot be a truthy 0 itself.
        value = (value == 1 or value == true) and 1 or 0
    end
    if value == nil then
        -- Nothing chosen anywhere: the screen's answer stands, untouched — and
        -- the row is shown it rather than the 0 that `Configurable:loadDefaults`
        -- put in the configurable from the global `kopt_sw_dithering` or the
        -- row's own default. Without this line the switch would read "off" on a
        -- device that is dithering every page.
        configurable.sw_dithering = (doc and doc.sw_dithering) and 1 or 0
        return
    end
    -- The row's domain is 0/1 (that is what the dialog matches and what the
    -- sidecar holds); the document's field is a boolean (that is what its blit
    -- tests). The two are converted here and nowhere else.
    configurable.sw_dithering = value
    if doc then
        doc.sw_dithering = value == 1
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
    Defaults.seedTone(ui, configurable)
    Defaults.seedDither(ui, configurable)
    Defaults.seedScrollMode(ui, configurable)
    Defaults.seedRotation(ui, configurable)
    Defaults.seedNightMode(ui, configurable)
    Defaults.seedFit(ui)

    -- **And the page's box has to be derived again, because the reader derived
    -- it before any of this ran.** The reader's own modules handle `ReadSettings`
    -- before the plugins do, and `ReaderView`/`ReaderZooming` derive the box for
    -- the page a book opens on inside their own handler: `use_bbox` is set, the
    -- crop is applied from whatever the configurable held at that moment, and the
    -- result is cached in the view. `trim_page` was still at its stock value when
    -- that happened — the row's own default, or the *global* `kopt_trim_page`,
    -- because this plugin writes a reader's choice into the **book** and never
    -- into the global that would otherwise have filled the configurable — so the
    -- page the book opened on came back uncropped until something derived the box
    -- again. Nothing does that unless the fit changes, which is why the crop
    -- appeared on the next page turned to and on the first one again only after a
    -- turn back had re-derived it. Every rule this plugin crops with rides that
    -- one row now, so this is the whole of the crop's behaviour at open.
    --
    -- **A book that has been opened before does not show it**, and that is this
    -- same mechanism rather than an exception: its own stored `kopt_trim_page` is
    -- loaded into the configurable before that derivation, so the row is already
    -- right by then. Only a book with no stored value — a book's *first* open —
    -- has the default standing where the reader's choice should be.
    --
    -- `ReZoom` is the reader's own "the box may have changed" verb, and the one
    -- the crop rows themselves fire. It lands here well before the first paint,
    -- so nothing is drawn twice.
    if type(ui.handleEvent) == "function" then
        local Event = require("ui/event")
        ui:handleEvent(Event:new("ReZoom"))
    end

    logger.dbg("Meguru: seeded per-book defaults for", doc.file)
    return true
end

return Defaults
