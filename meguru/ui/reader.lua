--[[--
Everything that has to be grafted onto a running ReaderUI for a Meguru book.

None of this is the engine. The engine reads a page; this file makes the *reader
around it* behave, which means replacing parts of KOReader's own machinery for
one document and leaving them pristine for every other:

  * the bottom `ConfigDialog` opens with a curated option set — the stock one
    offers a page-margin and reflow matrix that means nothing for a picture;
  * the status bar is hidden on open if the reader asked for that;
  * a page wider than it is tall turns the screen 90° (the standalone version of
    what `pagenumbercrop.koplugin` does, used when that plugin is absent);
  * reaching the end of a book opens the next one in the series;
  * long-pressing a curated row sets that book's value as the plugin-wide
    default instead of writing a global `kopt_*`.

The last one is the single most important thing here. KOReader's stock
"set as default" writes `G_reader_settings["kopt_<name>"]` — a *global* default
that would leak a choice made on a stream book into every PDF opened afterwards.
Redirecting it is not a nicety; it is the reason this file exists.

## Two shapes of installation

`Reader.install(plugin)` is per-open and assigns the event handlers onto the
plugin *instance*, so a PDF opened in the same session never sees them at all.
`Reader.installStatusBarHook()` is class-level and per-process, because
`ReaderFooter.onReaderReady` belongs to the class and there is no instance to
hang it on — which is why it is guarded by a module flag.
--]]

local ConfirmBox = require("ui/widget/confirmbox")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local KoptOptions = require("ui/data/koptoptions")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local logger = require("logger")
local _ = require("gettext")
-- Not a global: every core file that uses `C_` declares it locally, so a plugin
-- file that skips this line gets a nil call only when the row is built.
local C_ = _.pgettext
local T = require("ffi/util").template

local Catalog = require("meguru/catalog")
local Cache = require("meguru/doc/cache")
local Defaults = require("meguru/doc/defaults")
local Open = require("meguru/ui/open")
local Settings = require("meguru/settings")
local SyncJob = require("meguru/ui/syncjob")

local Reader = {}

--- Off / clockwise / counter-clockwise, as stored in `kopt_rotate_wide_pages`.
local ROTATE_OFF, ROTATE_RIGHT, ROTATE_LEFT = 0, 1, 2

--- A wide-page rotation that a *previous* Meguru book in this session left
--- active. KOReader keeps one screen for the whole session, so a book closed
--- mid-spread leaves the next one rotated unless someone reconciles it. Module
--- level because it has to outlive the ReaderUI that set it.
local session_wide_rotate = {}

-- Status bar -------------------------------------------------------------------

--- The footer instance for a reader UI. Current KOReader hangs it off
--- `ReaderView`; older builds had it as a ReaderUI module. Both are probed so
--- either layout works.
local function getStatusBarFooter(ui)
    if not ui then
        return nil
    end
    local view = ui.view
    if view and view.footer then
        return view.footer
    end
    return ui.footer
end

--- Hide the footer through the stock machinery.
---
--- `applyFooterMode` flips `view.footer_visible`, swaps the text generator to
--- "empty" and — but only when visibility actually *changes* — re-lays-out the
--- view to reclaim the bar's height. An external hid-status-bar patch that ran
--- first has already flipped the flag, so that reclaim would be skipped and the
--- bar's strip would stay reserved until the next page turn. Replicating the
--- reclaim here is what makes the first page paint full-screen.
local function hideStatusBar(footer)
    if not (footer and footer.mode_list and footer.view) then
        return
    end
    local was_visible = footer.view.footer_visible
    if type(footer.applyFooterMode) == "function" then
        footer:applyFooterMode(footer.mode_list.off)
    else
        footer.mode = footer.mode_list.off
        footer.view.footer_visible = false
    end
    if was_visible ~= nil and footer.view.footer_visible == was_visible then
        if type(footer.updateFooterContainer) == "function" then
            footer:updateFooterContainer()
        end
        if type(footer.resetLayout) == "function" then
            footer:resetLayout(true)
        end
        footer.visibility_change = true
    end
    if type(footer.onUpdateFooter) == "function" then
        footer:onUpdateFooter(true, true)
    end
end

--- Show the footer again, live.
---
--- Restores the mode from the untouched global `reader_footer_mode`. An explicit
--- "show" should always show, so when the user keeps the footer off globally the
--- fallback is page progress rather than re-applying "off".
local function showStatusBar(footer)
    if not (footer and footer.mode_list and footer.view) then
        return
    end
    local g = rawget(_G, "G_reader_settings")
    local mode = g and type(g.readSetting) == "function"
        and g:readSetting("reader_footer_mode")
    if mode == nil or mode == footer.mode_list.off then
        mode = footer.mode_list.page_progress
    end
    if type(footer.applyFooterMode) == "function" then
        footer:applyFooterMode(mode)
    else
        footer.mode = mode
        footer.view.footer_visible = mode ~= footer.mode_list.off
    end
    if type(footer.onUpdateFooter) == "function" then
        footer:onUpdateFooter(true, true)
    end
end

-- Installed exactly once per process: the hook is on the ReaderFooter class and
-- there is no instance to hang it on. The FileManager plugin instance installs
-- it as soon as the plugin loads, so it is in place before any book opens.
local status_bar_hook_installed = false

function Reader.installStatusBarHook()
    if status_bar_hook_installed then
        return
    end
    local ok, ReaderFooter = pcall(require, "apps/reader/modules/readerfooter")
    if not ok or type(ReaderFooter) ~= "table"
        or type(ReaderFooter.onReaderReady) ~= "function" then
        -- Deliberately left false so a later host can retry.
        return
    end
    status_bar_hook_installed = true
    local orig = ReaderFooter.onReaderReady
    ReaderFooter.onReaderReady = function(self, ...)
        orig(self, ...)
        local doc = self.ui and self.ui.document
        -- Only this plugin's documents, and only when asked: a PDF in the same
        -- session opens exactly as stock.
        if not (doc and doc.provider == "meguru") then
            return
        end
        if not Settings.get("hide_status_bar") then
            return
        end
        -- pcall keeps a build-specific footer quirk from ever costing the open.
        pcall(hideStatusBar, self)
    end
end

-- Wide pages -------------------------------------------------------------------

local function wideRotateIsLeft(value)
    return value == ROTATE_LEFT or value == tostring(ROTATE_LEFT)
end

--- The screen mode one step clockwise (right) or counter-clockwise (left) of
--- `base`. Rotation modes are numbered in quarters, so this is modular
--- arithmetic on 0..3.
local function wideRotateTarget(base, left)
    return left and (base + 3) % 4 or (base + 1) % 4
end

--- The page on screen. `ReaderUI` has no `getCurrentPage`; the paging module is
--- where the number lives, and it is absent entirely for a reflowed document.
local function currentPage(ui)
    return ui.paging and ui.paging.current_page
end

--- Turn the screen to `mode` through KOReader's own rotation machinery — the
--- same shape as `ReaderView:onSetRotationMode`, minus the notification. A
--- change of portrait/landscape *parity* is a real geometry change, so the UI
--- is asked to re-measure and rebuild its page states; the same parity is just
--- a re-orientation in place.
local function rotateTo(ui, mode)
    local cur = Screen:getRotationMode()
    if mode == cur then
        return
    end
    Screen:setRotationMode(mode)
    UIManager:setDirty(nil, "full")
    if (mode % 2) ~= (cur % 2) and ui then
        local new_size = Screen:getSize()
        ui:handleEvent(Event:new("SetDimensions", new_size))
        if ui.onScreenResize then
            ui:onScreenResize(new_size)
        end
        ui:handleEvent(Event:new("InitScrollPageStates"))
    end
    logger.info("Meguru: wide page, screen rotation", cur, "->", mode)
end

--- Return the screen to the base orientation this session left it in, but only
--- while it is *still* on the wide-rotated mode — never fight a rotation the
--- reader made by hand in the meantime.
local function restoreWideRotate(state, ui)
    local base, active = state.base, state.active
    state.base, state.active = nil, nil
    if base ~= nil and Screen:getRotationMode() == active then
        rotateTo(ui, base)
    end
end

--- Turn the screen for `page` if it is a wide spread, and back if it is not.
---
--- The skip conditions are checked in this order deliberately: a page flip in
--- progress or continuous scroll mode means the page number is not yet settled,
--- so acting on it would rotate for the wrong page. The base orientation is
--- captured lazily — on the first wide page actually shown — so whatever the
--- reader had (their own rotation, or this plugin's seeded `rotation_mode`) is
--- inherited rather than fought.
local function updatePageRotation(state, ui, page)
    local document = ui and ui.document
    local view = ui and ui.view
    local configurable = document and document.configurable
    if not (view and configurable and document.getNativePageDimensions) then
        return
    end
    if view.flipping_visible or view.page_scroll then
        return
    end
    if view.state and view.state.page ~= nil and view.state.page ~= page then
        return
    end

    local value = configurable.rotate_wide_pages
    local enabled = configurable.text_wrap ~= 1
        and (value == ROTATE_RIGHT or value == ROTATE_LEFT
            or value == tostring(ROTATE_RIGHT) or value == tostring(ROTATE_LEFT))
    if not enabled or type(page) ~= "number" then
        restoreWideRotate(state, ui)
        return
    end

    local size = document:getNativePageDimensions(page)
    if not (size and size.w > 0 and size.h > 0) then
        return
    end
    if size.w <= size.h then
        restoreWideRotate(state, ui)
        return
    end

    local cur = Screen:getRotationMode()
    local left = wideRotateIsLeft(value)
    if cur % 2 == 1 then
        -- Already in a turned orientation: reconcile against what this wide
        -- page expects rather than rotating a second time from it.
        if state.active == cur then
            local expected = wideRotateTarget(state.base, left)
            if expected ~= cur then
                state.active = expected
                session_wide_rotate.base, session_wide_rotate.active = state.base, expected
                rotateTo(ui, expected)
            end
        else
            state.base, state.active = nil, nil
            session_wide_rotate.base, session_wide_rotate.active = nil, nil
        end
        return
    end

    if state.base == nil then
        state.base = cur
    end
    local target = wideRotateTarget(cur, left)
    state.active = target
    session_wide_rotate.base, session_wide_rotate.active = state.base, target
    if target ~= cur then
        rotateTo(ui, target)
    end
end

--- Reconcile a rotation a previous book left active against the page this book
--- opens on: keep it when that page is itself a wide spread wanting the same
--- turn, otherwise put the screen back.
local function reconcileWideRotation(state, ui)
    local base, active = session_wide_rotate.base, session_wide_rotate.active
    session_wide_rotate.base, session_wide_rotate.active = nil, nil
    if base == nil or Screen:getRotationMode() ~= active then
        return
    end

    local document = ui and ui.document
    local view = ui and ui.view
    local configurable = document and document.configurable
    local page = ui and ui.paging and ui.paging.current_page
    local keep = false
    if document and configurable and page and view and not view.page_scroll then
        local value = configurable.rotate_wide_pages
        local enabled = configurable.text_wrap ~= 1
            and (value == ROTATE_RIGHT or value == ROTATE_LEFT
                or value == tostring(ROTATE_RIGHT) or value == tostring(ROTATE_LEFT))
        if enabled and document.getNativePageDimensions then
            local size = document:getNativePageDimensions(page)
            keep = size ~= nil and size.w > size.h
        end
    end
    if keep then
        state.base, state.active = base, active
    else
        pcall(rotateTo, ui, base)
    end
end

--- Wrap the page-turn and scroll-mode seams for this ReaderUI so wide pages are
--- rotated and restored as the reader reads. Once per ReaderUI.
local function installWideRotate(state, ui)
    local paging, view = ui.paging, ui.view
    if not (paging and view) then
        return
    end
    if not paging._meguru_wide_rotate_patched then
        paging._meguru_wide_rotate_patched = true
        local orig = paging.onPageUpdate
        paging.onPageUpdate = function(pg, new_page, orig_mode)
            local ret = orig(pg, new_page, orig_mode)
            -- Only page turns carry a page to evaluate; in continuous mode the
            -- scroll-mode wrapper below is what restores.
            if orig_mode ~= "scrolling" then
                updatePageRotation(state, ui, new_page)
            end
            return ret
        end
    end
    if not view._meguru_wide_rotate_view_patched then
        view._meguru_wide_rotate_view_patched = true
        local orig = view.onSetScrollMode
        view.onSetScrollMode = function(vw, page_scroll)
            local ret = orig(vw, page_scroll)
            local this_paging = ui.paging
            if not this_paging then
                return ret
            end
            if page_scroll then
                -- Rotation is per-page and meaningless while scrolling.
                restoreWideRotate(state, ui)
            else
                updatePageRotation(state, ui, this_paging.current_page)
            end
            return ret
        end
    end
end

--- Apply a new wide-page rotation value to the live document and this book's own
--- settings, then re-evaluate the current page.
local function setWideRotate(state, ui, value, text)
    local configurable = ui and ui.document and ui.document.configurable
    if not (configurable and configurable.rotate_wide_pages ~= nil) then
        return false
    end
    configurable.rotate_wide_pages = value
    if ui.doc_settings then
        ui.doc_settings:saveSetting("kopt_rotate_wide_pages", value)
    end
    updatePageRotation(state, ui, currentPage(ui))
    if text then
        UIManager:show(Notification:new{ text = text, timeout = 2 })
    end
    return true
end

-- Curated ConfigDialog ---------------------------------------------------------

--- One stock KOpt row by name, or nil.
local function stockOptionRow(tab, name)
    for _, option in ipairs(tab and tab.options or {}) do
        if option.name == name then
            return option
        end
    end
    return nil
end

--- Standalone rows for the page-number-crop family, used only when
--- `pagenumbercrop.koplugin` is absent.
---
--- The values match that plugin's own rows exactly — `{0, 1}` for the two
--- toggles and `{off, left, right}` for the rotation — so a book switched
--- between the two keeps identical behaviour and the stored numbers never change
--- meaning. The only difference is the rotation row's event, which is namespaced
--- so this plugin can never swallow the real plugin's event.
local PAGE_NUMBER_CROP_ROW = {
    name = "page_number_crop_auto",
    name_text = _("Page Number Crop"),
    toggle = { C_("Page Number Crop", "off"), C_("Page Number Crop", "on") },
    values = { 0, 1 },
    default_value = 0,
    enabled_func = function(configurable)
        return configurable.text_wrap ~= 1 and configurable.trim_page == 1
    end,
    event = "ReZoom",
    args = { 0, 1 },
    help_text = _([[Automatically removes the printed page number when "Page Crop" is "auto". Nothing is cropped if no number is found.]]),
}

local NO_CROP_BLANK_ROW = {
    name = "no_crop_blank_pages",
    name_text = _("No crop on blank pages"),
    toggle = { C_("No crop on blank pages", "off"), C_("No crop on blank pages", "on") },
    values = { 0, 1 },
    default_value = 1,
    enabled_func = function(configurable)
        return configurable.text_wrap ~= 1 and configurable.trim_page == 1
    end,
    event = "ReZoom",
    args = { 0, 1 },
    help_text = _([[Keeps almost-blank pages (chapter dividers, title pages) uncropped instead of zooming into a small element.]]),
}

local ROTATE_WIDE_ROW = {
    name = "rotate_wide_pages",
    name_text = _("Rotate wide pages"),
    toggle = {
        C_("Rotate wide pages", "off"),
        C_("Rotate wide pages", "left 90°"),
        C_("Rotate wide pages", "right 90°"),
    },
    values = { ROTATE_OFF, ROTATE_LEFT, ROTATE_RIGHT },
    default_value = ROTATE_OFF,
    enabled_func = function(configurable)
        return configurable.text_wrap ~= 1
    end,
    event = "MeguruRotateWideUpdate",
    args = { ROTATE_OFF, ROTATE_LEFT, ROTATE_RIGHT },
    help_text = _([[Automatically rotates the whole view by 90° when the current page is wider than tall (e.g. a double-page spread stored as one big horizontal image), and back when a normal page is shown again.]]),
}

--- The option set the bottom menu opens with for a streamed book.
---
--- Rows are pulled *live* from the global `KoptOptions` table rather than from a
--- snapshot: `pagenumbercrop.koplugin` injects its rows into that table when it
--- initialises, which may be after this plugin did, and reading it here is what
--- makes them appear regardless of init order.
---
--- Only options this engine actually implements are kept. The deliberately
--- omitted stock rows (page margins, auto-straighten, the whole reflow and
--- zoom-matrix family) would each set a value with no visible effect, which is
--- worse than not offering them.
local function buildCuratedOptions(ui)
    local rotation_tab, crop_tab, pageview_tab
    for _, tab in ipairs(KoptOptions) do
        if tab.icon == "appbar.rotation" and not rotation_tab then
            rotation_tab = tab
        elseif tab.icon == "appbar.crop" and not crop_tab then
            crop_tab = tab
        elseif tab.icon == "appbar.pageview" and not pageview_tab then
            pageview_tab = tab
        end
    end
    -- If the stock layout is ever not what we expect, show everything rather
    -- than an empty dialog.
    if not (rotation_tab and crop_tab) then
        return KoptOptions
    end

    local rotation_options = {}
    local rotation_mode = stockOptionRow(rotation_tab, "rotation_mode")
    if rotation_mode then
        rotation_options[#rotation_options + 1] = rotation_mode
    end
    rotation_options[#rotation_options + 1] =
        stockOptionRow(rotation_tab, "rotate_wide_pages") or ROTATE_WIDE_ROW

    -- Our own "Page Crop" row, not the stock one: the stock row carries the
    -- semi-manual define-an-area flow, which needs a crop box to persist and a
    -- streamed page has none. Only the two states the engine realises are
    -- offered, and both fire the core "ReZoom" so the new box applies to the
    -- page on screen immediately.
    local stock_trim = stockOptionRow(crop_tab, "trim_page")
    local crop_options = {
        {
            name = "trim_page",
            name_text = (stock_trim and stock_trim.name_text) or _("Page Crop"),
            toggle = { C_("Page crop", "none"), C_("Page crop", "auto") },
            values = { 3, 1 },
            args = { 3, 1 },
            default_value = 1,
            event = "ReZoom",
            help_text = stock_trim and stock_trim.help_text or nil,
        },
    }
    crop_options[#crop_options + 1] =
        stockOptionRow(crop_tab, "page_number_crop_auto") or PAGE_NUMBER_CROP_ROW
    crop_options[#crop_options + 1] =
        stockOptionRow(crop_tab, "no_crop_blank_pages") or NO_CROP_BLANK_ROW

    local reading_options = {
        {
            name = "opdsbook_fit",
            name_text = _("Fit"),
            toggle = {
                C_("Fit mode", "full"),
                C_("Fit mode", "width"),
                C_("Fit mode", "height"),
            },
            values = { "full", "width", "height" },
            args = { "full", "width", "height" },
            default_value = "full",
            event = "MeguruSetFit",
            -- Computed live from the reader's own zoom mode, so the row reflects
            -- what the book is actually showing even after a manual pinch, and
            -- falls back to the plugin preference when the current zoom is one
            -- of the three fits does not name (a manual pinch, "page", ...).
            current_func = function()
                local zooming = ui and ui.zooming
                local mode = zooming and zooming.zoom_mode
                if mode then
                    for fit, zoom_mode in pairs(Defaults.FIT_TO_ZOOM_MODE) do
                        if zoom_mode == mode then
                            return fit
                        end
                    end
                end
                return Settings.get("fit")
            end,
            help_text = _([[How a page is zoomed to the screen: full shows the whole cropped page, width fills the screen width, height fills the screen height.]]),
        },
    }
    local page_view = stockOptionRow(pageview_tab, "page_scroll")
    if page_view then
        reading_options[#reading_options + 1] = page_view
    end
    reading_options[#reading_options + 1] = {
        name = "opdsbook_manga",
        name_text = _("Invert read (manga mode)"),
        toggle = { C_("Manga mode", "off"), C_("Manga mode", "on") },
        values = { 0, 1 },
        args = { false, true },
        default_value = 1,
        event = "MeguruMangaRead",
        help_text = _([[Right-to-left page turning, so the book reads like Japanese manga. Remembered for this book; new Meguru books start with it on — long-press this row to change that default.]]),
    }

    return {
        prefix = "kopt",
        { icon = rotation_tab.icon, options = rotation_options },
        { icon = crop_tab.icon, options = crop_options },
        {
            icon = (pageview_tab and pageview_tab.icon) or "appbar.pageview",
            options = reading_options,
        },
    }
end

--- Long-press a curated row to set it as the default for *future* Meguru books.
---
--- Without this the stock handler would write a global `kopt_*`, leaking a
--- choice made while reading a stream into every PDF opened afterwards. Rows
--- this plugin has no preference for get no "set as default" at all — the stock
--- handler is swallowed rather than allowed to fall through.
local function redirectDefaults(config)
    local dialog = config and config.config_dialog
    if not (dialog and type(dialog.onMakeDefault) == "function") then
        return
    end
    if dialog._meguru_defaults_hooked then
        return
    end
    dialog._meguru_defaults_hooked = true
    dialog.onMakeDefault = function(self, name, name_text, values, labels, position)
        local preference = Defaults.PREFERENCE_FOR[name]
        if not preference then
            return true
        end
        local value = values and values[position]
        -- Every row is stored in its own domain, which is what `Settings`
        -- declares and what `seedRowValue` copies back verbatim. The manga row
        -- is the exception: it carries 0/1 because a boolean would be swallowed
        -- by the `or` ConfigDialog uses to fall back on `configurable`, while
        -- the preference behind it is a real boolean.
        if name == "opdsbook_manga" then
            value = value == 1
        end
        UIManager:show(ConfirmBox:new{
            text = T(_("Set default %1 to %2?"), name_text or "",
                (labels and labels[position]) or ""),
            ok_text = _("Set as default"),
            ok_callback = function()
                Settings.set(preference, value)
            end,
        })
        return true
    end
end

--- Swap the stock bottom-menu handler for one that opens a curated dialog.
---
--- Modules init before plugins and this wrap is installed at plugin init, so
--- every later open of the bottom menu goes through it. The original handler is
--- called unchanged, so persistence, the remembered panel index and everything
--- else about the flow is untouched.
local function curateConfigMenu(plugin)
    local config = plugin.ui and plugin.ui.config
    if not (config and type(config.onShowConfigMenu) == "function") then
        return
    end
    if config._meguru_curated then
        return
    end
    config._meguru_curated = true
    local orig = config.onShowConfigMenu
    config.onShowConfigMenu = function(cfg, ...)
        local stock_options = cfg.options
        -- `cfg.ui` is this ReaderUI; the dialog is built from this table inside
        -- `orig`, so the Fit row's live highlight gets it through the closure.
        cfg.options = buildCuratedOptions(cfg.ui)
        -- The remembered panel index was stored against the *full* stock list,
        -- so an index past the end of the curated one would show the wrong tab
        -- or crash.
        if type(cfg.last_panel_index) ~= "number" or cfg.last_panel_index < 1 then
            cfg.last_panel_index = 1
        elseif cfg.last_panel_index > #cfg.options then
            cfg.last_panel_index = #cfg.options
        end
        local ret = orig(cfg, ...)
        redirectDefaults(cfg)
        -- The dialog keeps its own reference to the curated set; hand the
        -- module's field back so nothing else ever sees the subset.
        cfg.options = stock_options
        return ret
    end
end

-- Next and previous in the series ----------------------------------------------

--- The item, series and server of the book on screen, or nil when its series was
--- never catalogued — a marker opened with no database behind it still reads, it
--- just has no neighbours.
local function seriesContext(ui)
    local doc = ui and ui.document
    if not (doc and type(doc.catalogContext) == "function") then
        return nil
    end
    local context = doc:catalogContext()
    if not (context and context.server) then
        return nil
    end
    return context
end

--- `context, neighbours` for the book on screen, either of which may be nil.
--- `Catalog.neighbors` is nil only when the item itself is absent from the
--- catalog — a row removed underneath a book that is already open.
local function neighborsOf(ui)
    local context = seriesContext(ui)
    if not context then
        return nil, nil
    end
    return context, Catalog.neighbors(context.series.id, context.item.item_key)
end

--- The series currently being synced on demand, if any.
---
--- Module level because the walk outlives the tap that started it: the reader
--- can still turn pages while it runs, and a second tap on the same series must
--- not start a second walk over the same feed.
local on_demand_sync = nil

--- Sync `context`'s series, then hand `which`'s neighbour to the reader.
---
--- Called when the reader asks for a neighbour the catalog does not have yet —
--- which is the normal state of a series catalogued from the OPDS browser, since
--- opening a book records only that book. Without this, "next chapter" is
--- unreachable for every series until it is synced by hand from the library
--- view, which is not a step a reader would guess at.
---
--- The completion runs on the tick the walk ends, with SyncJob's dialog already
--- closed and the database already written to, so the requery below sees the
--- rows the walk just added. Only **one** sync is attempted: a series whose
--- canonical feed genuinely has no neighbour after a successful sync has none,
--- and retrying would walk the same feed again for the same answer.
local function syncThenOpen(plugin, context, which)
    local ui = plugin.ui
    local series = context.series
    on_demand_sync = series.id
    SyncJob.run(context.server, series, function(ok)
        on_demand_sync = nil
        -- The reader this was asked for may be gone by now (the walk is tens of
        -- seconds and the plugin instance is per-document). Switching documents
        -- then would replace whatever is on screen with a book nobody asked for.
        if plugin.ui ~= ui then
            return
        end
        if not ok then
            -- SyncJob has already said why, in more detail than is available
            -- here. A second popup would only repeat it.
            return
        end
        local refreshed = Catalog.series(series.id) or series
        local after = Catalog.neighbors(series.id, context.item.item_key)
        local item = after and after[which] or nil
        if not item then
            UIManager:show(InfoMessage:new{
                text = which == "next"
                    and T(_("Meguru: %1 has no next chapter."), refreshed.name)
                    or T(_("Meguru: %1 has no previous chapter."), refreshed.name),
            })
            return
        end
        -- Deferred for the same reason the tap that got here was: opening
        -- replaces the document, and this runs inside the walk's own tick.
        --
        -- Silent, like the direct path below: this is the same neighbour the
        -- reader asked for, arriving a sync later. Asking now would put a
        -- question in front of a request that was not one.
        UIManager:nextTick(function()
            Open.openItemSilently(plugin, context.server, refreshed, item)
        end)
    end)
end

--- Open the item before or after this one in the series. Returns whether the
--- document was handed to the reader **on this call**.
---
--- **This replaces the document.** `Open.openItemSilently` writes the marker and
--- switches the reader to it, so a caller must not switch again afterwards, and
--- must call this from a point where tearing the reader down is safe — never
--- directly inside a handler that belongs to the reader being replaced.
---
--- **It does not ask, and that is deliberate.** Tapping "find the next chapter"
--- names one specific book, so there is no question to put: the resume dialog
--- belongs where the reader opens a *series* view and the server may disagree
--- about where they got to. Before this, the tap went through `openCatalogItem`
--- and the dialog could answer with a different chapter than the one tapped —
--- most visibly on "previous chapter" while the server sat further along.
---
--- A `false` return therefore means "nothing was opened *now*", not "there is
--- nothing there": when the series has no such neighbour yet, this syncs it and
--- opens the neighbour from the sync's completion, a tick or a walk later.
---
--- This is where the catalog pays for itself: the old plugin kept a copy of the
--- sibling list inside every marker and had to scan it by volume number, with a
--- special case for the alias entry that shared the real volume's stream. Here
--- the next item is one query, and identity is the same `item_key` the sync
--- uses, so an alias cannot exist to be skipped.
function Reader.openNeighbor(plugin, which)
    local context = seriesContext(plugin.ui)
    -- No context: the marker carries no series identity. There is nothing to
    -- sync — the series is not known, so no feed can be built for it. This is
    -- the marker-written-without-a-database case, and it is meant to read
    -- without neighbours rather than prompt for anything.
    if not context then
        return false
    end
    local found = Catalog.neighbors(context.series.id, context.item.item_key)
    -- `neighbors` is nil only when the *current* item is itself absent from the
    -- catalog — a row deleted underneath a book that is open. Syncing would
    -- re-add it, but the requery after the walk keys on that same missing row,
    -- so there is no neighbour to be found at the end of it.
    if not found then
        return false
    end
    if found[which] then
        -- openItemSilently reports its own failures, in more detail than a caller
        -- could; all that is wanted back here is whether it worked.
        return Open.openItemSilently(plugin, context.server, context.series, found[which]) ~= nil
    end
    -- Reachable when the reader is asked twice before the connection prompt is
    -- answered: both re-runs land on the same tick, and the second must join the
    -- first walk rather than start a second one over the same feed.
    if on_demand_sync then
        logger.dbg("Meguru: series sync already running; ignoring request for",
            context.series.id, which)
        return false
    end

    -- A walk is a run of HTTP requests, so it needs a connection the same way a
    -- page fetch does; the manager prompts for one rather than letting the walk
    -- fail on its first request, and only re-runs this once one exists.
    if not NetworkMgr:isConnected() then
        NetworkMgr:willRerunWhenConnected(function()
            Reader.openNeighbor(plugin, which)
        end)
        return false
    end

    syncThenOpen(plugin, context, which)
    return false
end

--- When a book reaches its end, open the next one instead of showing KOReader's
--- stock end-of-book dialog.
---
--- Installed on this ReaderUI's own ReaderStatus instance, so any other book
--- keeps the pristine behaviour and the wrap dies with its UI.
local function installEndOfBookHook(plugin)
    local ui = plugin.ui
    local status = ui and ui.status
    if not (status and type(status.onEndOfBook) == "function") then
        return
    end
    if status._meguru_eob_wrapped then
        return
    end
    status._meguru_eob_wrapped = true
    local orig = status.onEndOfBook
    status.onEndOfBook = function(status_self, ev)
        if not Settings.get("auto_next_item") then
            return orig(status_self, ev)
        end
        -- Deliberately only the neighbour the catalog already has. This is not
        -- a tap: reaching the end of the last known chapter would otherwise
        -- start a network walk nobody asked for, every time the book is
        -- finished. Asking for a neighbour the catalog lacks is a menu row.
        local _, found = neighborsOf(ui)
        if not (found and found.next) then
            return orig(status_self, ev)
        end
        -- Replicate the auto-marking the stock handler would have done, so the
        -- finished book is still recorded as complete.
        local g = rawget(_G, "G_reader_settings")
        if g and type(g.isTrue) == "function"
            and g:isTrue("end_document_auto_mark") then
            pcall(function()
                if ui.doc_settings and ui.doc_settings:readSetting("summary")
                    and type(status_self.markBook) == "function" then
                    status_self:markBook(true)
                end
            end)
        end
        -- This runs in the middle of a page-turn gesture; switching documents
        -- here would tear the reader down underneath that handler. Defer, and
        -- guard so a second EndOfBook before the tick cannot switch twice.
        if not status_self._meguru_auto_pending then
            status_self._meguru_auto_pending = true
            UIManager:nextTick(function()
                status_self._meguru_auto_pending = false
                -- Opens the next item itself; do not switch again here.
                pcall(Reader.openNeighbor, plugin, "next")
            end)
        end
        return true
    end
end

-- Cache ------------------------------------------------------------------------

function Reader.clearCache()
    return Cache.clear()
end

-- Installation -----------------------------------------------------------------

--- Graft everything reader-side onto `plugin` for the document it has open.
--- A no-op for any other document, so a PDF in the same session never grows a
--- Meguru row or a wrapped seam.
function Reader.install(plugin)
    local ui = plugin and plugin.ui
    local doc = ui and ui.document
    if not (doc and doc.provider == "meguru") then
        return false
    end

    local rotate_state = {}
    plugin._meguru_rotate_state = rotate_state

    -- Standalone wide-page rotation, unless pagenumbercrop.koplugin is already
    -- driving this document — wrapping paging twice would rotate a wide spread
    -- twice. Both of its markers are probed, since either may be present
    -- depending on which of its patches applied.
    local pagenumbercrop_owns = doc._pagenum_cache ~= nil
        or (ui.paging and ui.paging._page_number_crop_patched)
    if not pagenumbercrop_owns then
        installWideRotate(rotate_state, ui)
        plugin._meguru_wide_rotate_installed = true
        -- A previous Meguru book may have left the screen rotated for a wide
        -- spread. Reconcile once layout has settled.
        if session_wide_rotate.base ~= nil then
            UIManager:scheduleIn(0.1, function()
                pcall(reconcileWideRotation, rotate_state, ui)
            end)
        end
    end

    curateConfigMenu(plugin)
    installEndOfBookHook(plugin)

    plugin.onMeguruRotateWideUpdate = function(self, value)
        if type(value) ~= "number" then
            value = ROTATE_OFF
        end
        local texts = {
            _("Rotate wide pages: off"),
            _("Rotate wide pages: right 90°"),
            _("Rotate wide pages: left 90°"),
        }
        setWideRotate(rotate_state, self.ui, value, texts[value + 1])
        return true
    end

    plugin.onMeguruSetFit = function(self, key)
        if not Defaults.FIT_TO_ZOOM_MODE[key] then
            return true
        end
        local zooming = self.ui and self.ui.zooming
        if zooming and type(zooming.setZoomMode) == "function" then
            local desired = Defaults.FIT_TO_ZOOM_MODE[key]
            zooming:setZoomMode(desired)
            if self.ui.doc_settings then
                self.ui.doc_settings:saveSetting("zoom_mode", desired)
            end
        end
        return true
    end

    plugin.onMeguruMangaRead = function(self, enabled)
        enabled = enabled == true
        local configurable = self.ui and self.ui.document
            and self.ui.document.configurable
        if configurable then
            configurable.opdsbook_manga = enabled and 1 or 0
        end
        if self.ui.doc_settings then
            self.ui.doc_settings:saveSetting("inverse_reading_order", enabled)
            self.ui.doc_settings:flush()
        end
        -- The same live path the built-in menu uses: flips the flag, re-maps
        -- the touch zones and notifies.
        local view = self.ui.view
        if view and type(view.onToggleReadingOrder) == "function" then
            view:onToggleReadingOrder(enabled)
        end
        return true
    end

    plugin.onMeguruHideStatusBar = function(self, hide)
        local footer = getStatusBarFooter(self.ui)
        if hide then
            hideStatusBar(footer)
        else
            showStatusBar(footer)
        end
        return true
    end

    plugin.onCloseDocument = function(self)
        if self._meguru_wide_rotate_installed then
            restoreWideRotate(self._meguru_rotate_state, self.ui)
            self._meguru_wide_rotate_installed = false
        end
    end

    plugin.onClose = function(self)
        if self._meguru_wide_rotate_installed then
            restoreWideRotate(self._meguru_rotate_state, self.ui)
            self._meguru_wide_rotate_installed = false
        end
    end

    return true
end

return Reader
