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
  * reaching the end of a book opens the next one in the series — walked from
    the server's feed for a marker, listed out of the folder for a local `.cbz`;
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
local Font = require("ui/font")
local KoptOptions = require("ui/data/koptoptions")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local logger = require("logger")
local _ = require("gettext")
-- Not a global: every core file that uses `C_` declares it locally, so a plugin
-- file that skips this line gets a nil call only when the row is built.
local C_ = _.pgettext
local ffiutil = require("ffi/util")
local T = ffiutil.template

local Feed = require("meguru/feed")
local Defaults = require("meguru/doc/defaults")
local Local = require("meguru/local")
local Open = require("meguru/ui/open")
local Panel = require("meguru/panel")
local PanelZoom = require("meguru/ui/panelzoom")
local Settings = require("meguru/settings")

local Reader = {}

--- Monotonic milliseconds, for the panel-detection timing in the log line below.
--- The same clock `document.lua` measures with, and for the same reason: the
--- panel scan walks a page's pixels, so its cost is real seconds of a reader's
--- life and `os.clock` would report it as CPU time.
local function nowMs()
    local secs, usecs = ffiutil.gettime()
    return secs * 1000 + usecs / 1000
end

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
    logger.dbg("Meguru: wide page, screen rotation", cur, "->", mode)
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

-- Panel zoom -------------------------------------------------------------------

--- Meguru's own default for panel zoom, read and written from the menu row.
---
--- **A default, not an override.** What a file gets is KOReader's own cascade —
--- the answer in the file's sidecar if it has one, and this only when it does
--- not. So the stock ⋮ row keeps working exactly as it always has, one book at a
--- time, and this is what decides for the books nobody has answered for.
---
--- This was once KOReader's per-*extension* entry, which was wrong for a reason
--- worth keeping: the plugin opens `.cbz` too, so a reader looking at a `.cbz`
--- was being shown the answer for markers while the book in front of them
--- followed `cbz`. One preference for everything Meguru opens has no such gap.
function Reader.panelZoomEnabled()
    return Settings.get("panel_zoom") == true
end

--- Set it, live for the book on screen — unless that book answered for itself.
---
--- `panel_zoom_enabled` is the very field the stock row flips, so a book with no
--- answer of its own follows immediately rather than on the next open. A book
--- that *has* one keeps it: the preference is what it falls back to, and a
--- fallback that overrode the answer would not be one.
function Reader.setPanelZoom(ui, on)
    Settings.set("panel_zoom", on == true)
    local hl = ui and ui.highlight
    if hl and not hl._meguru_panel_zoom_pinned then
        hl.panel_zoom_enabled = on == true
    end
end

--- Which of the panel views a long-press opens: `"crop"`, `"window"` or `"zoom"`.
---
--- One preference for everything Meguru opens, like the toggle above it and for the
--- same reason — but this one is about the *view* and not about whether there is
--- one. The first two show the same panels in the same order and differ in whether the
--- page is cut up to do it; the third walks no steps at all. `meguru/viewport` is what
--- the windows are, and `ui/panelzoom` is what the free one is.
---
--- There is no per-book answer and no stock row behind this one, which is why it is
--- read straight from the preference every time rather than through a cascade.
function Reader.panelViewMode()
    local mode = Settings.get("panel_view")
    if mode == "window" or mode == "zoom" then
        return mode
    end
    return "crop"
end

--- The direction this book is read in, as `"manga"` or `"comic"`.
---
--- The panel sequence orders a page's panels by this and picks its tap and swipe
--- sides from it, and there is exactly one source: the same value `ReaderView`
--- turns pages with. `ui.view.inverse_reading_order` is KOReader's per-book
--- answer, and Meguru's `Manga mode` row and the plugin-wide `manga_order`
--- preference both end there — the document seeds the book's own key from the
--- preference at open time, before `ReadSettings`, and `onMeguruMangaRead` keeps
--- the live value current. So the cascade is already applied, and reading it
--- here cannot drift from what turning a page does.
---
--- A book that answered for itself therefore keeps its answer, which is the same
--- rule the panel-zoom preference follows.
function Reader.panelZoomMode(ui)
    local view = ui and ui.view
    if view and view.inverse_reading_order ~= nil then
        return view.inverse_reading_order and "manga" or "comic"
    end
    local configurable = ui and ui.document and ui.document.configurable
    if configurable and configurable.opdsbook_manga ~= nil then
        return configurable.opdsbook_manga == 1 and "manga" or "comic"
    end
    return Settings.get("manga_order") and "manga" or "comic"
end

--- Which way this book wants wide things turned: `"left"`, `"right"`, or nil.
---
--- The panel viewer turns a panel that is wider than the screen, and it must turn
--- it the same way the *page* is turned — otherwise a manga the reader has told
--- to go left goes left, and its panels go right. So this reads the very setting
--- that turns the page, `Rotate wide pages`, and hands the word to the viewer:
--- one direction for both, which is the whole point.
---
--- **It reads `configurable`, never `Settings.get("rotate_wide")`.** That
--- preference is only the floor: `Defaults.seedGeometry` writes it into the book's
--- field and its sidecar at open time, so every book already opened has an answer
--- of its own and re-reading the preference here would answer for a book that
--- disagrees with it. (`Reader.panelZoomMode` above reads its cascade for the same
--- reason.)
---
--- nil means the row is off, and then the viewer makes every rotation decision the
--- way it did before this existed.
function Reader.panelZoomDirection(ui)
    local configurable = ui and ui.document and ui.document.configurable
    if not (configurable and configurable.rotate_wide_pages ~= nil) then
        return nil
    end
    -- The row's domain is 0 = off, 1 = right, 2 = left, but a stored value can be
    -- the string form, which is why `wideRotateIsLeft` is reused rather than the
    -- comparison being written out again here.
    local value = configurable.rotate_wide_pages
    if wideRotateIsLeft(value) then
        return "left"
    end
    if value == ROTATE_RIGHT or value == tostring(ROTATE_RIGHT) then
        return "right"
    end
    return nil
end

--- Leave KOReader's own cascade alone, and put Meguru's preference underneath it.
---
--- The switch is the stock "⋮ → Panel zoom (manga/comic) → Allow panel zoom", and
--- stock keeps its answer on two levels: a per-file copy in the sidecar, and a
--- per-extension entry that answers for every file that has none. **Both levels
--- stay exactly where they are.** All this changes is what the second one is: for
--- a file Meguru opened, "nobody has answered for this" resolves to
--- `Settings.panel_zoom` rather than to whatever KOReader has for the extension.
---
--- That is the whole of it, and the reason it is this small is worth keeping from
--- the design it replaces. An earlier version made the extension entry
--- authoritative for markers — read on open, written the moment the row was
--- flipped, and the sidecar copy deleted so nothing could contradict it. That
--- gave one answer for all of a series' chapters, which is right, but it did it
--- by naming an *extension*, and this engine opens `.cbz` too: a reader looking
--- at a `.cbz` was shown the answer for markers while the book in front of them
--- followed `cbz`. A preference for everything Meguru opens has no such gap, and
--- costs no machinery.
---
--- The line the wraps below must not cross: a file that was only *opened* may not
--- come away with an answer of its own. Stock writes the live field into the
--- sidecar on every save, so without the third wrap a book opened while the
--- preference was on would be pinned on for good, and would survive the reader
--- turning it off — which is precisely the failure the design above was built to
--- avoid, arriving from the other side.
--- Is another plugin the one currently sitting on the long-press?
---
--- The fields are `Panels+`'s own, set together when it takes the gesture over
--- and cleared together when it gives it back (`restoreNativePanelZoom`, from
--- its `onCloseWidget`). They answer the question that matters — not "is
--- Panels+ installed", but "is Panels+ the thing that will handle this press" —
--- and they are the only signal that does.
---
--- That distinction has teeth. A reader who has Panels+ installed but switched
--- *off* in the plugin manager is asking for someone else's panel zoom, and
--- Panels+' own wrapper delegates to the original handler in exactly that case.
--- Standing down on the mere presence of the plugin would take panel zoom away
--- from them; standing down on this leaves it working.
---
--- Read per press and never cached, because whichever plugin patches
--- `onPanelZoom` first depends on the order their directories sort in, and this
--- has to be right in both.
local function panelsPlusOwnsGesture(hl)
    if not hl then
        return false
    end
    return (hl._panels_plus_plugin or hl._panels_plus_original_panel_zoom) and true or false
end

--- Logged once per process, not once per press: a stand-down is a decision a
--- reader might ask about, and the answer to "why is Meguru's viewer not
--- showing" is worth one line — not one per long-press for a whole session.
local panel_zoom_standdown_logged = false

local function installPanelZoom(ui)
    local hl = ui and ui.highlight
    if not (hl and ui.paging) then
        return false
    end
    if hl._meguru_panel_zoom_installed then
        return true
    end
    hl._meguru_panel_zoom_installed = true

    -- Panels+ handles the long-press for this document, so Meguru takes no part
    -- in it at all — and that has to include the three wraps below, not just
    -- the viewer. An `onReadSettings` wrap that put `Settings.panel_zoom` onto
    -- a book with no answer of its own would turn `panel_zoom_enabled` *off*
    -- when the preference is off, and Panels+ gates its own handler on that
    -- very field: Meguru would be switching off the plugin that replaced it.
    if panelsPlusOwnsGesture(hl) then
        if not panel_zoom_standdown_logged then
            panel_zoom_standdown_logged = true
            logger.info("Meguru: Panels+ owns panel zoom; Meguru's panel viewer stands down")
        end
        return false
    end

    -- `config` is named rather than reached through `...`, because the cascade
    -- turns on `config:has(...)`. The rest is still forwarded, so a build that
    -- hands this one an extra argument does not lose it here.
    local orig_read = hl.onReadSettings
    hl.onReadSettings = function(self, config, ...)
        if type(orig_read) == "function" then
            orig_read(self, config, ...)
        end
        -- Did this file answer for itself? Stock has just said so, and its answer
        -- is the one that keeps winning.
        local own = type(config) == "table" and type(config.has) == "function"
            and config:has("panel_zoom_enabled")
        -- Remembered for `onSaveSettings` below, which needs to know whether this
        -- file is allowed to keep a copy. A file answered in an earlier session
        -- counts exactly as much as one answered in this one.
        self._meguru_panel_zoom_pinned = own and true or false
        -- Re-asked here, not only at install: a Panels+ that patched the
        -- long-press *after* this wrap went in would otherwise have its own gate
        -- (`panel_zoom_enabled`) switched off by the line below whenever the
        -- Meguru preference is off — Meguru disabling the plugin that replaced
        -- it. The three wraps stay installed in that ordering; they just stop
        -- having a vote about what Panels+ does.
        if not own and not panelsPlusOwnsGesture(self) then
            -- Stock put the per-extension entry here. This preference is the only
            -- default this plugin recognises.
            self.panel_zoom_enabled = Settings.get("panel_zoom")
        end
        -- Nothing on a streamed page is text, and the fallback reaches
        -- `getImageFromPosition`, which no engine-less paging document
        -- answers — a hold that found no panel would land in a text selection
        -- that cannot exist here. Off is what stock does for a `.cbz` too.
        self.panel_zoom_fallback_to_text_selection = false
    end

    -- The stock row flips the live field and nothing else — and that flip is the
    -- reader answering for *this* file. The one place that is worth knowing from.
    local orig_toggle = hl.onTogglePanelZoomSetting
    hl.onTogglePanelZoomSetting = function(self, ...)
        if type(orig_toggle) == "function" then
            orig_toggle(self, ...)
        end
        self._meguru_panel_zoom_pinned = true
    end

    -- Stock writes the live field into the sidecar on every save, so a file
    -- nobody switched would be pinned to whatever the preference happened to be
    -- at the moment it was opened, and would hold that answer after the
    -- preference moved. The copy is kept only by the file that answered for
    -- itself; the rest fall back to the preference, every time.
    local orig_save = hl.onSaveSettings
    hl.onSaveSettings = function(self, ...)
        if type(orig_save) == "function" then
            orig_save(self, ...)
        end
        if not self._meguru_panel_zoom_pinned then
            local ds = self.ui and self.ui.doc_settings
            if ds and type(ds.delSetting) == "function" then
                ds:delSetting("panel_zoom_enabled")
            end
        end
    end

    -- The long-press itself.
    --
    -- Stock's `onPanelZoom` renders the one region `getPanelFromPage` answered
    -- with and shows it in a bare `ImageViewer`. This replaces that with the
    -- panel *sequence* when the page has one, and calls stock's own handler
    -- every other time — so a page with no panel grid behaves exactly as it did
    -- before this existed, and the two detectors back each other up rather than
    -- one being a rewrite of the other.
    --
    -- Stock's `onHold` has already gated on `self.panel_zoom_enabled` by the
    -- time this runs, so the preference is not re-checked here.
    local orig_zoom = hl.onPanelZoom
    hl.onPanelZoom = function(self, arg, ges)
        local function stock()
            if type(orig_zoom) == "function" then
                return orig_zoom(self, arg, ges)
            end
            return false
        end

        -- Panels+ is on this gesture: let it through rather than showing a
        -- second viewer on top of its own. Asked per press, so a Panels+ closed
        -- mid-session hands the gesture straight back.
        if panelsPlusOwnsGesture(self) then
            return stock()
        end
        local ui = self.ui
        local doc = ui and ui.document
        if not (doc and doc.provider == "meguru"
            and type(doc.getPanelsFromPage) == "function") then
            return stock()
        end
        self:clear()
        local view = ui.view
        local pos = view and type(view.screenToPageTransform) == "function"
            and view:screenToPageTransform(ges.pos)
        -- `page` as well as the point: the document below will happily try to
        -- fetch page `nil`, which is a socket call rather than an error.
        if not (pos and pos.page) then
            return stock()
        end

        local mode = Reader.panelZoomMode(ui)
        -- Resolved per press, like `mode`: the row can be changed with the viewer
        -- closed and the next open follows it.
        local direction = Reader.panelZoomDirection(ui)
        local t_start = nowMs()
        -- **The free view asks no detector**, and that is a property of the view rather
        -- than a shortcut: it walks no steps, so it has no use for panels, and a page the
        -- detector would have refused opens in it like any other. What it does need is the
        -- page's own size — and `getPageDims` *is* the fetch and the decode, so asking it
        -- puts the bytes in hand that the render will want anyway.
        if Reader.panelViewMode() == "zoom" then
            local ok_dims, dims = pcall(doc.getPageDims, doc, pos.page)
            if not ok_dims or not dims then
                logger.dbg("Meguru: page", pos.page, "panel zoom: no page ("
                    .. tostring(dims) .. ")")
                return stock()
            end
            logger.dbg(string.format(
                "Meguru: page %d panel zoom: free view (%s) in %d ms",
                pos.page, mode, nowMs() - t_start))
            local ok_free, shown_free = pcall(PanelZoom.open, ui, pos.page, nil, nil,
                mode, direction, {
                    free = true,
                    tap = { x = pos.x, y = pos.y },
                    level = Settings.get("panel_zoom_level"),
                })
            if not ok_free or not shown_free then
                logger.warn("Meguru: panel zoom viewer failed:",
                    ok_free and "not shown" or tostring(shown_free))
                return stock()
            end
            return
        end
        -- Four values: `getPanelsFromPage` returns panels, accepted and reason,
        -- and `pcall` adds its own. A missing slot here does not fail — it
        -- shifts `accepted` into `reason` and the reason into nothing, and the
        -- feature still works — so the count is worth counting.
        local ok_detect, panels, accepted, reason = pcall(doc.getPanelsFromPage,
            doc, pos.page, mode)
        if not ok_detect then
            logger.warn("Meguru: panel zoom detection failed:", panels)
            return stock()
        end
        if not panels then
            -- One meaning only: the page itself could not be decoded, so there
            -- is neither a sequence nor a page to show as one. `dbg` because a
            -- book read offline repeats it per press, the same frequency
            -- argument the crop-skip line lost on.
            logger.dbg("Meguru: page", pos.page, "panel zoom: no page ("
                .. tostring(reason) .. ")")
            return stock()
        end
        -- The count alone cannot tell a real sequence from the whole-page
        -- fallback, and those need opposite fixes, so a refused page says so and
        -- names the test that refused.
        logger.dbg(string.format(
            "Meguru: page %d panel zoom: %d panels%s (%s) in %d ms",
            pos.page, #panels,
            accepted and "" or (", whole page (" .. tostring(reason) .. ")"),
            mode, nowMs() - t_start))

        local start = Panel.indexAt(panels, pos.x, pos.y) or 1
        -- **A refused page is shown cropped whatever the preference says.** A page
        -- the detector would not decompose comes back as one rectangle covering it,
        -- and the window view would cut that rectangle into a top and a bottom —
        -- two steps through a splash nobody asked to be stepped through. Cropping
        -- a whole-page rectangle shows the whole page, which is what a refusal has
        -- always meant here.
        local opts = {
            window = Reader.panelViewMode() == "window" and accepted == true,
            -- In page coordinates, and the reason it travels: the window view opens
            -- centred on the finger rather than at the panel's own edge. `pos` is
            -- already the page point — `screenToPageTransform` above — so nothing
            -- is converted again here.
            tap = { x = pos.x, y = pos.y },
            -- The magnification over fit-to-screen, read here and written back by the
            -- viewer's own button: the *store* is the preference, and the view is
            -- handed the number rather than the preference's name, like the direction
            -- and the mode beside it.
            level = Settings.get("panel_zoom_level"),
        }
        local ok_show, shown = pcall(PanelZoom.open, ui, pos.page, panels, start,
            mode, direction, opts)
        if not ok_show or not shown then
            logger.warn("Meguru: panel zoom viewer failed:",
                ok_show and "not shown" or tostring(shown))
            return stock()
        end
        return true
    end

    return true
end

-- The page a failed fetch leaves behind ----------------------------------------

--- What happened, and what to do about it: one sentence per reason.
---
--- The reasons have different fixes and a reader can only act on the one they
--- have — connecting Wi-Fi does nothing about a server that answered 404, and
--- waiting does nothing about Wi-Fi that is off — which is why there are four of
--- these and no single generic one to fall back on.
---
--- The `reason` is the document's, from the fetch that failed (`fetch_failed`);
--- nil means no fetch failed at all — the page arrived and could not be decoded
--- — which is why it has its own sentence rather than borrowing the network's.
local function pageMessageBody(reason, code, server)
    if reason == "offline" then
        return _("You're offline right now.\nConnect to Wi-Fi and try again.")
    elseif reason == "http" and code then
        return T(_("%1 returned an error (%2).\nTry again in a moment."),
            server, tostring(code))
    elseif reason == "network" then
        return T(_("%1 isn't responding.\nMake sure the server is running, then try again."), server)
    end
    return _("Something went wrong loading this page.\nTry again in a moment.")
end

--- The whole message: a title that says nothing and a reason that says
--- everything, in that order, because "Can't load this page" is what a reader
--- reads first and the second line is what they act on. Built from
--- `pageMessageBody` rather than beside it so the two cannot drift.
local function pageMessageText(reason, code, server)
    return _("Can't load this page") .. "\n\n" .. pageMessageBody(reason, code, server)
end

--- The laid-out message, rebuilt only when it would say something else.
---
--- This runs from a *paint*: a pan, a zoom step and a menu opening all repaint
--- the page, so laying the text out each time would be work per repaint for a
--- message that cannot have changed. One slot is enough — the message is a
--- property of the page on screen, and a page shows one reason at a time.
local function pageMessageWidget(state, key, text, width)
    local cached = state.message
    if cached and cached.key == key and cached.width == width then
        return cached.widget
    end
    local widget = TextBoxWidget:new{
        text = text,
        face = Font:getFace("cfont", 22),
        width = width,
        alignment = "center",
    }
    state.message = { key = key, width = width, widget = widget }
    return widget
end

--- Install the message, and the two resets that make a retry possible.
---
--- The document paints the box and hands over the reason; the wording, the font
--- and the layout are here, which is the same split as everything else in this
--- file — the engine does not know what a reader reads. The painter returns
--- nothing and its answer is not consulted: a document with no painter gets the
--- plain box, and that is a state (the cover path), not a failure.
---
--- **The sentence is the whole of it, and the reason is the point of it.** There
--- was an error *drawing* here for a while — Meguru-chan lying across a big "404"
--- — and it was removed deliberately: the reason is the one thing a picture
--- cannot carry, and that picture claimed the wrong one. A 404 is the internet's
--- shorthand for "broken page", and in Meguru's four cases it is literally right
--- in exactly one (the server answered 404) while being wrong for the two
--- commonest, which never had an HTTP status to show at all. So what a reader
--- gets is the four sentences below, and the asset went with the code that drew
--- it rather than sitting unused beside it.
---
--- There is no Retry button, and that is the design rather than a gap: a page
--- turn *is* the reader asking again, and it is the only gesture that always
--- means it. Turning away and back clears the failed fetches, so the page is
--- fetched once more; a Wi-Fi connection arriving repaints the page under the
--- reader's eyes. What there is not, deliberately, is a dialog: the reader asked
--- for a page and got an explanation in its place, which is the same thing a
--- browser does and does not need dismissing before the book can be read.
local function installPageErrorPage(plugin)
    local ui = plugin.ui
    local doc = ui and ui.document
    if not (doc and type(doc.paintMissingPage) == "function") then
        return false
    end
    -- The state the painter carries: the laid-out sentence. Nothing else holds
    -- it — the closure below is what keeps it alive, and it lives exactly as long
    -- as the document does.
    local state = {}

    doc.missing_painter = function(target, rect, x, y, failure)
        local box_w = rect.w or Screen:getWidth()
        local box_h = rect.h or Screen:getHeight()
        local reason = failure and failure.reason
        local code = failure and failure.code
        local server = tostring((doc.desc and doc.desc.server_name) or _("The server"))
        -- A little narrower than the box, so no line ends against the page edge.
        -- The box is the visible area, so this width is the screen's and stays
        -- that way through a pan or a zoom — which is what lets the layout below
        -- be cached at all.
        local width = math.max(1, math.floor(box_w * 0.8))
        local widget = pageMessageWidget(state,
            table.concat({ tostring(reason), tostring(code), server }, "|"),
            pageMessageText(reason, code, server), width)
        local size = widget:getSize()
        widget:paintTo(target,
            x + math.floor((box_w - size.w) / 2),
            y + math.floor((box_h - size.h) / 2))
    end

    -- A page turn is the reader asking for a page again, so it is what starts a
    -- new attempt at one that failed. `ReaderPaging:onPageUpdate` returns
    -- nothing, so the event does reach a plugin module registered after it —
    -- which is the whole reason this can be a module handler rather than another
    -- wrap on the paging module.
    plugin.onPageUpdate = function(self)
        local d = self.ui and self.ui.document
        if d and type(d.clearFetchFailures) == "function" then
            d:clearFetchFailures()
        end
    end

    -- The connection came back while the reader stayed on the page: clear the
    -- failures and repaint, so what they are looking at fills in without a
    -- page turn. Deferred out of the event, which can arrive from inside a
    -- network callback. Nothing is repainted when nothing had failed — this
    -- event also fires once at startup on a device that is already online.
    plugin.onNetworkConnected = function(self)
        local d = self.ui and self.ui.document
        if not (d and type(d.clearFetchFailures) == "function") then
            return
        end
        if d:clearFetchFailures() then
            UIManager:nextTick(function()
                local u = self.ui
                if u and u.dialog then
                    UIManager:setDirty(u.dialog, "full")
                end
            end)
        end
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

--- Reported once per process, not once per repair: the second installation is a
--- decision a reader might ask about ("why does this menu look different"), and
--- the answer is worth one line rather than one per book.
local config_menu_repair_logged = false

--- Swap the stock bottom-menu handler for one that opens a curated dialog.
---
--- Modules init before plugins and this wrap is installed at plugin init, so
--- every later open of the bottom menu goes through it. The original handler is
--- called unchanged, so persistence, the remembered panel index and everything
--- else about the flow is untouched.
---
--- **The guard is the wrapper itself rather than a flag, and that is the whole
--- of what makes a second installation possible.** `rakuyomi.koplugin` assigns
--- `ui.config.onShowConfigMenu` on the *instance*, wholesale and without calling
--- the original — its own comment reads `--patch
--- frontend/apps/reader/modules/readerconfig.lua` — and it does it from a
--- `registerPostInitCallback`, which is later than every plugin's init. Plugins
--- load by sorted path, so `meguru.koplugin` always comes *before* it and
--- whatever this installs at our init is gone before the reader is up. A flag
--- saying "we installed once" cannot see that, because it stays true; holding
--- the function we installed can, because a foreign assignment is then simply a
--- different value in the field.
---
--- Chaining is the other half: `orig` is whatever is in the field *now*, so a
--- replacement's own work — Rakuyomi's chapter bar among its buttons — survives
--- ours. Returns whether it installed, which is what the caller logs on.
local function curateConfigMenu(plugin)
    local config = plugin.ui and plugin.ui.config
    if not (config and type(config.onShowConfigMenu) == "function") then
        return false
    end
    if config._meguru_curated == config.onShowConfigMenu then
        return false
    end
    local orig = config.onShowConfigMenu
    local wrapper = function(cfg, ...)
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
    config._meguru_curated = wrapper
    config.onShowConfigMenu = wrapper
    return true
end

-- Next and previous in the series ----------------------------------------------

--- The item, series and server of the book on screen, or nil when its series was
--- never catalogued — a marker opened with no database behind it still reads, it
--- just has no neighbours.
local function seriesContext(ui)
    local doc = ui and ui.document
    if not (doc and type(doc.seriesContext) == "function") then
        return nil
    end
    local context = doc:seriesContext()
    if not (context and context.server_name) then
        return nil
    end
    return context
end

--- The folder this book shares with its neighbours, or nil when it has none.
---
--- The other source of "where am I in the series", and nil for every book whose
--- series is a feed's: only a `.cbz` opened through Meguru answers. Exported
--- because the reader menu needs the same answer to decide whether to draw the
--- two rows at all, and two copies of this guard is two places for the two
--- surfaces to disagree about which books have them.
---
--- It lists the folder — that is the only way to know whether there is a second
--- book to move to — so it is a question for a menu build and for a tap, never
--- for a paint.
function Reader.localSeriesOf(ui)
    local doc = ui and ui.document
    if not (doc and type(doc.localSeries) == "function") then
        return nil
    end
    return doc:localSeries()
end

--- The one refusal, in the one wording, for both ways of having no neighbour.
---
--- Shared rather than written twice, for the reason `openPrepared` gives about
--- its own message: the same situation reaching the reader with two different
--- texts is how a bug in one of them becomes invisible.
local function showNoNeighbor(which, name)
    UIManager:show(InfoMessage:new{
        text = which == "next"
            and T(_("%1 has no next chapter."), tostring(name or ""))
            or T(_("%1 has no previous chapter."), tostring(name or "")),
    })
end

--- Ask this series' own feed for the item either side of the one being read.
---
--- **The feed is the only source, and it is read on the ask.** A marker holds no
--- sibling list: the design that put one there is the one this plugin replaced,
--- and it failed for a reason that has nothing to do with where the list lived.
--- A copy is written once and never repaired, so it answers with the series as
--- it was — silently, for as long as the file exists, and in the old plugin it
--- was copied forward into every marker an auto-open created. Asking the feed
--- cannot go stale, and it costs one walk in a gesture that asked for one.
---
--- `Feed.planForMarker` turns the marker into a driver and a canonical feed URL
--- (falling back to the stream template for a marker that predates
--- `server_kind`), `Feed.walk` fetches it, `Feed.ordered` puts it in reading
--- order and `Feed.neighbor` picks. Nothing is written: the neighbour gets a
--- marker of its own when it is opened, and this book's is left as it was.
---
--- Bounded like the row above a series feed bounds its own walk, because this
--- runs inside a tap and a walk is a run of synchronous HTTP requests.
---
--- Returns the item, or nil plus a reason.
local function neighborFromFeed(doc, context, which)
    local plan, reason = Feed.planForMarker(doc.desc, {
        max_pages = Feed.TAP_PAGES,
        timeout   = "resume",
        on_failure = function(why)
            logger.info("Meguru: cannot look for a neighbour of",
                tostring(context.series_name), "-", why)
        end,
    })
    if not plan then
        return nil, reason
    end
    local walker = Feed.walker(plan.url, plan.walker_opts)
    while walker:step() do end
    if not walker.complete then
        return nil, tostring(walker.reason)
    end
    -- `title_order` comes off the driver: whether this server's feed is already
    -- in reading order is its answer to give, not this function's to guess.
    local sequence = Feed.ordered(Feed.collect(walker, plan),
        { title_order = plan.driver and plan.driver.orderFromTitles })
    return Feed.neighbor(sequence, context.item_key, which)
end

--- Open the neighbour this reader asked for, from the series' own feed.
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
--- A `false` return means "nothing was opened" — there is no chapter that way,
--- the walk failed, or there is no connection. It never means "try again later
--- on your own": the walk is synchronous and its answer is final.
---
--- The feed is asked every time, so there is no state here to go stale and no
--- guard to keep two walks apart. What replaced the old per-series guard is that
--- there are no longer two walkers: the background walk an OPDS add used to
--- start is gone with the catalog it was filling.
function Reader.openNeighbor(plugin, which)
    local ui = plugin and plugin.ui
    local doc = ui and ui.document

    -- A local archive first, and **before the connection test below**. Its
    -- series is a folder listing, so this path is offline by construction:
    -- asking for Wi-Fi here would be prompting for something it does not need,
    -- and would then re-run the whole thing through the manager for nothing.
    local spot = Reader.localSeriesOf(ui)
    if spot then
        local path, why = Local.neighbor(doc.file, which)
        if not path then
            logger.info("Meguru: no local neighbour of", spot.name, "towards",
                which, "-", tostring(why))
            showNoNeighbor(which, spot.name)
            return false
        end
        return Open.openLocalFile(plugin, path) ~= nil
    end

    local context = seriesContext(ui)
    -- No context: the marker carries no series identity. There is nothing to
    -- walk — no server, no series id, so no feed URL can be built for it. This
    -- is the marker-written-without-a-catalog case, and it is meant to read
    -- without neighbours rather than prompt for anything.
    if not context then
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
    local item, reason = neighborFromFeed(doc, context, which)
    if not item then
        logger.info("Meguru: no neighbour of", tostring(context.series_name),
            "towards", which, "-", tostring(reason))
        showNoNeighbor(which, context.series_name)
        return false
    end
    -- openItemSilently reports its own failures, in more detail than a caller
    -- could; all that is wanted back here is whether it worked.
    return Open.openItemSilently(plugin, context, item) ~= nil
end


--- Mark a finished book complete, the way the stock handler we are standing in
--- for would have.
---
--- Shared by both branches below rather than written into each: it is the half
--- of "auto-open the next one" that has nothing to do with *finding* the next
--- one, and two copies of it would be two chances to drop it on one path only —
--- silently, and only for the reader who has `end_document_auto_mark` on.
local function autoMarkFinished(ui, status)
    local g = rawget(_G, "G_reader_settings")
    if not (g and type(g.isTrue) == "function"
        and g:isTrue("end_document_auto_mark")) then
        return
    end
    pcall(function()
        if ui.doc_settings and ui.doc_settings:readSetting("summary")
            and type(status.markBook) == "function" then
            status:markBook(true)
        end
    end)
end

--- Run `open` on the next UI tick, at most once per end-of-book.
---
--- This handler runs in the middle of a page-turn gesture, and switching
--- documents there would tear the reader down underneath that gesture. Hence the
--- defer; hence also the guard, so a second EndOfBook arriving before the tick
--- cannot switch twice.
local function deferOpen(status, open)
    if status._meguru_auto_pending then
        return
    end
    status._meguru_auto_pending = true
    UIManager:nextTick(function()
        status._meguru_auto_pending = false
        open()
    end)
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
        -- **This walks, and that reverses an earlier refusal.** It used to take
        -- only the neighbour the catalog already held, on the grounds that
        -- reaching the end of a volume would otherwise start a network walk
        -- nobody asked for. That reasoning rested on the catalog: a background
        -- walk after an OPDS add meant the neighbour was normally already there,
        -- so falling through cost nothing but a stock dialog.
        --
        -- With no catalog there is nothing to already hold, so keeping the
        -- refusal would not preserve the behaviour — it would make the toggle
        -- govern something that can never happen. And the walk here *is* asked
        -- for: the reader turned `auto_next_item` on and finished a volume.
        -- The cost is one bounded walk per finished book, and only for a reader
        -- who opted in.
        --
        -- Anything short of "there is a next chapter" falls through to
        -- KOReader's own dialog rather than reporting: an end-of-book is not the
        -- moment for a popup saying the series has no more.
        --
        -- A local `.cbz` is asked first and asked *differently*: its next volume
        -- is a file beside it, so there is no feed to walk and no connection to
        -- need. The listing is one `lfs.dir`, and a folder that offers nothing
        -- is the same "short of a next chapter" as an exhausted feed.
        local spot = Reader.localSeriesOf(ui)
        if spot then
            local path = Local.neighbor(ui.document.file, "next")
            if not path then
                return orig(status_self, ev)
            end
            autoMarkFinished(ui, status_self)
            deferOpen(status_self, function()
                pcall(Open.openLocalFile, plugin, path)
            end)
            return true
        end

        local context = seriesContext(ui)
        if not (context and NetworkMgr:isConnected()) then
            return orig(status_self, ev)
        end
        local ok_walk, next_item = pcall(neighborFromFeed, ui.document, context, "next")
        if not (ok_walk and next_item) then
            return orig(status_self, ev)
        end
        autoMarkFinished(ui, status_self)
        deferOpen(status_self, function()
            -- Opened from the item the walk already returned, not through
            -- `Reader.openNeighbor`: that would walk the same feed a second
            -- time and, finding nothing, put a popup over a reader who has
            -- just finished a book. Opens the item itself; do not switch
            -- again here.
            pcall(Open.openItemSilently, plugin, context, next_item)
        end)
        return true
    end
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

    -- Installed here, before the `ReadSettings` event reaches ReaderHighlight,
    -- so the value the reader sees is the one this decides and not the one
    -- stock read out of the book's sidecar a moment later.
    installPanelZoom(ui)

    -- Also before the first paint: the painter is what stands between a failed
    -- page and a reader looking at a gray rectangle with nothing to read.
    installPageErrorPage(plugin)

    curateConfigMenu(plugin)

    -- And again once the reader is up, because a plugin can replace the method
    -- *after* ours is in place — see `curateConfigMenu`. `ReaderReady` is the
    -- seam that is provably later than that: `ReaderUI:init` fires the event and
    -- only *then* runs its `postReaderReadyCallback` list
    -- (`readerui.lua:517-522`), while a replacement installed from a post-init
    -- callback has already happened by the time init returns. Without this the
    -- reader sees the stock, uncrated dialog — and nothing reports it, because
    -- the menu still works.
    if type(ui.registerPostReaderReadyCallback) == "function" then
        ui:registerPostReaderReadyCallback(function()
            if curateConfigMenu(plugin) and not config_menu_repair_logged then
                config_menu_repair_logged = true
                logger.info("Meguru: the config menu was replaced since load;"
                    .. " curation re-installed")
            end
        end)
    end

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
