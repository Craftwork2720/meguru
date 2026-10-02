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

local Blitbuffer = require("ffi/blitbuffer")
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
local Icons = require("meguru/icons")
local Defaults = require("meguru/doc/defaults")
local Image = require("meguru/doc/image")
local Local = require("meguru/local")
local Open = require("meguru/ui/open")
local Panel = require("meguru/panel")
local PanelZoom = require("meguru/ui/panelzoom")
local Progress = require("meguru/progress")
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

--- Re-derive the page box when the two-page view starts or stops.
---
--- **Nothing else has to happen on a page turn**, and that is worth saying because
--- it looks like an omission: the document answers "one page or two" from the
--- live mode and the live orientation every time it is asked (`spreadActive`), so
--- turning a page picks up the pair on its own. What does *not* happen on its own
--- is a re-layout at the moment the answer changes — a rotation, or the reader
--- flipping the row. The page box the reader derived a moment ago is the old
--- shape, and it stays the old shape until something asks it to derive again;
--- `ReZoom` is that verb, and the one the crop rows and `Defaults.apply` use.
---
--- The last answer is kept on the reader UI so this fires on a change and not on
--- every rotation of every book.
local function syncSpread(ui)
    local doc = ui and ui.document
    if not (doc and doc.provider == "meguru"
        and type(doc.spreadActive) == "function") then
        return
    end
    local active = doc:spreadActive() and true or false
    if active == (ui._meguru_spread_active or false) then
        return
    end
    ui._meguru_spread_active = active
    if type(ui.handleEvent) == "function" then
        ui:handleEvent(Event:new("ReZoom"))
    end
    logger.dbg("Meguru: two-page view", active and "on" or "off")
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
    -- A rotation is the one thing that starts or stops the two-page view by
    -- itself (in "auto" it is the whole of the condition), so the box has to be
    -- derived again after one. This is the plugin's own rotation; the reader's
    -- own goes through `ReaderView:rotate` and is caught by `installSpread`.
    syncSpread(ui)
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
    if not (view and configurable and document.pageIsWide) then
        return
    end
    if view.flipping_visible or view.page_scroll then
        return
    end
    if view.state and view.state.page ~= nil and view.state.page ~= page then
        return
    end
    -- **While two pages are showing, this does nothing at all** — it neither
    -- turns nor restores. In landscape the pair is already the shape a wide page
    -- wants, so a turn would be pointless; and an undo would take the screen to
    -- portrait, which stops the pair, which makes the next page narrow again,
    -- which undoes the undo. That flip-flop is the whole reason for the guard,
    -- and it is why the two features can share a book without fighting.
    if type(document.spreadActive) == "function" and document:spreadActive() then
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

    -- **One page's shape, never the pair's.** `getNativePageDimensions` answers
    -- with the pair while two pages are showing, and a pair is wider than tall by
    -- construction — so asking it here would turn the screen for two pages that
    -- are only wide because they are lying side by side.
    if not document:pageIsWide(page) then
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
        if enabled and type(document.pageIsWide) == "function" then
            keep = document:pageIsWide(page)
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

--- Install the two-page view's seams for this ReaderUI. Once per reader.
---
--- **One gesture turns a whole spread, and this is the whole of how.** KOReader's
--- counter moves by one page and knows nothing about pairs; left alone, a reader
--- on a spread would spend a turn on the second page of it and see the same two
--- pages painted again. So the target is passed through the document's
--- imposition, which answers with the page that *unit* starts at — `spreadSnap`,
--- which also says what a jump means, and what the end of the book looks like
--- when the last unit is a pair.
---
--- The other seam here is rotation. The reader's own rotation never comes through
--- this plugin's `rotateTo` — it goes through ReaderView's own machinery — so the
--- re-derivation `syncSpread` does is hung on `ReaderView:rotate`, which is where
--- that rotation's geometry change lands. Both are needed: `rotateTo` catches the
--- plugin's own wide-page turns, this catches the reader's hand.
local function installSpread(ui)
    local paging, view = ui and ui.paging, ui and ui.view
    if not (paging and view) then
        return false
    end
    if ui._meguru_spread_installed then
        return true
    end
    ui._meguru_spread_installed = true

    if not paging._meguru_spread_patched then
        paging._meguru_spread_patched = true
        local orig_goto = paging._gotoPage
        paging._gotoPage = function(pg, number, orig_mode)
            local doc = ui.document
            if number ~= nil and doc and type(doc.spreadSnap) == "function" then
                local target, finished = doc:spreadSnap(number, pg.current_page)
                if finished then
                    -- The last unit is on screen and the reader turned past the
                    -- end of the book. `onGotoPageRel` announces that itself only
                    -- when the counter passes the last page, which it never does
                    -- while the last unit is a pair — so nothing else would.
                    ui:handleEvent(Event:new("EndOfBook"))
                    return true
                end
                if target ~= nil then
                    number = target
                    -- Warm the page the pair needs *before* the reader lays the
                    -- page out: that pass asks the document for the pair's box,
                    -- and a fetch from in there would freeze the paint.
                    if type(doc.prepareSpread) == "function" then
                        doc:prepareSpread(number)
                    end
                end
            end
            return orig_goto(pg, number, orig_mode)
        end
    end

    if not view._meguru_spread_rotate_patched and type(view.rotate) == "function" then
        view._meguru_spread_rotate_patched = true
        local orig_rotate = view.rotate
        view.rotate = function(vw, ...)
            local ret = orig_rotate(vw, ...)
            syncSpread(ui)
            return ret
        end
    end

    -- And the other way the answer can change without a page turn: continuous
    -- scroll switches the two-page view off (see `spreadActive`), so the box has
    -- to be derived again when the reader leaves or enters it.
    if not view._meguru_spread_scroll_patched
        and type(view.onSetScrollMode) == "function" then
        view._meguru_spread_scroll_patched = true
        local orig_scroll = view.onSetScrollMode
        view.onSetScrollMode = function(vw, page_scroll)
            local ret = orig_scroll(vw, page_scroll)
            syncSpread(ui)
            return ret
        end
    end

    -- Whether two pages are on is decided by `spreadActive`, from the book's own
    -- value and the screen — so nothing has to be *pushed* here. What this does
    -- need is a first look, and it is taken at `ReaderReady` and not here:
    -- `ReadSettings` has not run yet at this point, so a book whose `spread` the
    -- seeding is about to write still reads as off. See the callback in
    -- `Reader.install`.
    return true
end

--- Apply a new two-page value to the live document and this book's own settings,
--- then lay the page out again in the new shape.
---
--- The value is written where the couple that reads it will find it — the
--- document's configurable, which is the live answer, and the book's sidecar,
--- which is the one it opens with next time — and `syncSpread` is what turns the
--- change into a re-layout. The stored domain is the row's own: "off", "auto",
--- "on".
local function setSpread(ui, value, text)
    local configurable = ui and ui.document and ui.document.configurable
    if not (configurable and configurable.spread ~= nil) then
        return false
    end
    configurable.spread = value
    if ui.doc_settings then
        ui.doc_settings:saveSetting("kopt_spread", value)
        ui.doc_settings:flush()
    end
    syncSpread(ui)
    if text then
        UIManager:show(Notification:new{ text = text, timeout = 2 })
    end
    return true
end

--- What the offset switch says when it flips, in the two places that flip it: the
--- *Pair offset* row's own event, and the Dispatcher action a reader can bind a
--- gesture to (`main.lua`). One function so the two cannot come to describe the
--- same setting differently.
local function spreadOffsetNotice(on)
    return on and _("Pair offset: from here") or _("Pair offset: off")
end

--- The offset beside it. Its value is the **page the offset is anchored at** (0
--- for off) rather than a flag — the rule is in `meguru/spread`, and what this
--- does is write it where the document reads it: the live configurable and the
--- book's own sidecar.
---
--- It needs no re-layout of its own beyond the `ReZoom` below: the anchor changes
--- *which* pages a unit holds, never the shape of a unit, so the page box the
--- reader derived is still the right one.
local function setSpreadOffset(ui, anchor, text)
    local configurable = ui and ui.document and ui.document.configurable
    if not (configurable and configurable.spread_offset ~= nil) then
        return false
    end
    configurable.spread_offset = anchor
    if ui.doc_settings then
        ui.doc_settings:saveSetting("kopt_spread_offset", anchor)
        ui.doc_settings:flush()
    end
    -- The unit under the reader has almost certainly changed — pairing from a
    -- different page is the whole of the setting — so the page is laid out again.
    if type(ui.handleEvent) == "function" then
        ui:handleEvent(Event:new("ReZoom"))
    end
    if text then
        UIManager:show(Notification:new{ text = text, timeout = 2 })
    end
    return true
end

--- The gutter switch beside the offset. It decides whether `Spread.gutter` is
--- asked at all (`document.lua`'s `_pairLayout`), so the pair's box changes shape
--- and the page has to be laid out again — the same `ReZoom` the offset fires.
local function setSpreadGutter(ui, value, text)
    local configurable = ui and ui.document and ui.document.configurable
    if not (configurable and configurable.spread_gutter ~= nil) then
        return false
    end
    configurable.spread_gutter = value
    if ui.doc_settings then
        ui.doc_settings:saveSetting("kopt_spread_gutter", value)
        ui.doc_settings:flush()
    end
    if type(ui.handleEvent) == "function" then
        ui:handleEvent(Event:new("ReZoom"))
    end
    if text then
        UIManager:show(Notification:new{ text = text, timeout = 2 })
    end
    return true
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
--- Which of the panel views a long-press opens: `"crop"`, `"window"` or `"zoom"`.
---
--- **The book's own answer, seeded from the plugin-wide preference** — the same
--- cascade as the Fit row and Crop, read from the configurable the way its
--- sibling `panelZoomDirection` below reads the reading direction and for the same
--- reason: `meguru/doc/defaults` writes the book's value at open, so the preference
--- is what a book with no answer of its own gets, not what every book is stuck
--- with. The first two views show the same panels in the same order and differ in
--- whether the page is cut up to do it; the third walks no steps at all.
--- `meguru/viewport` is what the windows are, and `ui/panelzoom` is what the free
--- one is.
---
--- **Asked only when there *is* a panel view.** Whether there is one is a different
--- question with a different answer — KOReader's own per-book `panel_zoom_enabled`,
--- which the *Reading* tab's *Panel view* row and KOReader's own row both write, and which
--- refuses the press before this is reached (`meguruPanelZoomWanted`). So the three
--- values are the whole domain here, and anything else is a store this build does
--- not know and gets the default.
--- Whether `mode` is one of the three views — the one place the domain is spelled
--- out, asked by `panelViewMode` below and by the *Reading* tab's *Panel view* row, which
--- carries a fourth answer (Off) that is not a view at all.
local function panelViewIsView(mode)
    return mode == "crop" or mode == "window" or mode == "zoom"
end

function Reader.panelViewMode(ui)
    local configurable = ui and ui.document and ui.document.configurable
    local mode = configurable and configurable.panel_view
    if panelViewIsView(mode) then
        return mode
    end
    local seeded = Settings.get("panel_view")
    if panelViewIsView(seeded) then
        return seeded
    end
    -- A stored value neither place knows — a newer version's view, or a corrupt
    -- store — and the answer is **the default and not the original view**, so that
    -- this line and `Settings.DEFAULTS.panel_view` cannot come to say different
    -- things. They are two places and they must move together.
    return "window"
end

--- The direction this book is read in, as `"manga"` or `"comic"`.
---
--- The panel sequence orders a page's panels by this and picks its tap and swipe
--- sides from it, and there is exactly one source: the same value `ReaderView`
--- turns pages with. `ui.view.inverse_reading_order` is KOReader's per-book
--- answer, and the *Reading direction* row and the plugin-wide `manga_order`
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

--- Stock's own `ReaderHighlight:onPanelZoom`, or nil on a build that moved it.
---
--- **Read off the class and never off the instance.** The instance field is the thing every
--- plugin that wants this gesture overwrites, and whoever installs second captures the other's
--- wrapper as its own "original" — so the class method is the only handle on stock that does
--- not depend on the order the plugin directories sort in. It is what every wrapper here falls
--- back to: a page this detector refuses must land in stock's single-region viewer, never in a
--- second sequence, or which engine ran would depend on the page.
---
--- Lazy and `pcall`ed: it is reached at `ReaderReady` or on a press, when the module is
--- necessarily loaded, and a build that moved it must cost the fallback and not the feature.
local function nativePanelZoom()
    local ok, ReaderHighlight = pcall(require, "apps/reader/modules/readerhighlight")
    if ok and type(ReaderHighlight) == "table"
        and type(ReaderHighlight.onPanelZoom) == "function" then
        return ReaderHighlight.onPanelZoom
    end
    return nil
end

--- Whether the file in front of the reader wants a panel zoom at all.
---
--- **A book has one unless the book itself says otherwise**, which is what `_meguru_panel_zoom_pinned`
--- records — the reader answering for *this* file with KOReader's own row. There is no plugin-wide
--- switch to consult: the per-file answer is the only one there is, and a file nobody has answered
--- for is the reason the default is yes.
---
--- **Asked here rather than read off `panel_zoom_enabled`, and the difference is the whole reason
--- this function exists.** That field is stock's gate and `ReaderHighlight:onHold` reads it *before*
--- any handler runs, so whichever engine answers the press has to have won it — and another plugin
--- answering the same gesture wins it last, on every `ReadSettings`. A handler that trusted the
--- field would be reading that plugin's answer. `_meguru_panel_zoom_answer` is the file's own
--- answer, stashed by the `onReadSettings` wrap below because the live field it came from is not
--- reliably ours by the time a press arrives.
local function meguruPanelZoomWanted(hl)
    if hl._meguru_panel_zoom_pinned then
        return hl._meguru_panel_zoom_answer == true
    end
    return true
end

--- The body of Meguru's own long-press handling.
---
--- Split out of the wrapper below because there are now two wrappers that reach it: the one
--- `installPanelZoom` installs at plugin init, and the one `installOuterPanelZoom` puts on
--- top of a foreign plugin's at `ReaderReady`. A second copy of this body is how the two
--- engines would come to drift a page apart, with only one of them ever exercised.
---
--- `fallback` is the handler a press belongs to when this plugin has nothing to show, and
--- every caller passes **stock's** `onPanelZoom` — never another plugin's. A page this
--- detector refuses must not be handed to a second detector: which engine ran would then
--- depend on the page, which is a failure that cannot be reported.
---
--- It arrives as an argument rather than being captured here because the two wrappers sit at
--- different depths of the same field: what counts as "the original" depends on who installed
--- when, and only the wrapper that *is* the outermost knows what it displaced.
local function meguruPanelZoom(self, arg, ges, fallback)
    local ui = self.ui
    local doc = ui and ui.document
    if not (doc and doc.provider == "meguru"
        and type(doc.getPanelsFromPage) == "function") then
        fallback(self, arg, ges)
    end
    self:clear()
    local view = ui.view
    local pos = view and type(view.screenToPageTransform) == "function"
        and view:screenToPageTransform(ges.pos)
    -- `page` as well as the point: the document below will happily try to
    -- fetch page `nil`, which is a socket call rather than an error.
    if not (pos and pos.page) then
        fallback(self, arg, ges)
    end
    -- **The press belongs to the page under the finger.** `pos` is measured in
    -- the space the view laid out, which with two pages showing is the pair's —
    -- so page `pos.page` is the unit's first page and `pos.x` runs across both.
    -- The document maps the point onto the page it is really on, which is the
    -- page whose panels, page size and crop box everything below then asks for.
    -- With one page showing this answers what it was handed.
    if pos and type(doc.spreadPageAt) == "function" then
        pos.page, pos.x, pos.y = doc:spreadPageAt(pos.page, pos.x, pos.y)
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
    if Reader.panelViewMode(ui) == "zoom" then
        local ok_dims, dims = pcall(doc.getPageDims, doc, pos.page)
        if not ok_dims or not dims then
            logger.dbg("Meguru: page", pos.page, "panel zoom: no page ("
                .. tostring(dims) .. ")")
            fallback(self, arg, ges)
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
            fallback(self, arg, ges)
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
        fallback(self, arg, ges)
    end
    if not panels then
        -- One meaning only: the page itself could not be decoded, so there
        -- is neither a sequence nor a page to show as one. `dbg` because a
        -- book read offline repeats it per press, the same frequency
        -- argument the crop-skip line lost on.
        logger.dbg("Meguru: page", pos.page, "panel zoom: no page ("
            .. tostring(reason) .. ")")
        fallback(self, arg, ges)
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
        window = Reader.panelViewMode(ui) == "window" and accepted == true,
        -- In page coordinates, and the reason it travels: the window view opens
        -- centred on the finger rather than at the panel's own edge. `pos` is
        -- already the page point — `screenToPageTransform` above — so nothing
        -- is converted again here.
        tap = { x = pos.x, y = pos.y },
        -- The multiple of the page's width on the screen — see `Viewport.fitScale` for
        -- what that means and for the measure it replaced, and `meguru/settings` for
        -- where the reader sets it. Read here and written back by the viewer's own
        -- button: the *store* is the preference, and the view is handed the number
        -- rather than the preference's name, like the direction and the mode beside it.
        level = Settings.get("panel_zoom_level"),
    }
    local ok_show, shown = pcall(PanelZoom.open, ui, pos.page, panels, start,
        mode, direction, opts)
    if not ok_show or not shown then
        logger.warn("Meguru: panel zoom viewer failed:",
            ok_show and "not shown" or tostring(shown))
        fallback(self, arg, ges)
    end
    return true
end

--- Leave KOReader's own cascade alone, and give its per-file level the answer this engine wants.
---
--- The switch is the stock ⋮ → Panel zoom (manga/comic) → Allow panel zoom, and stock keeps its
--- answer on two levels: a per-file copy in the sidecar, and a per-extension entry that answers
--- for every file that has none. **Both levels stay exactly where they are.** All this changes is
--- what the second one is: KOReader has nothing at all for the extensions this engine claims, so
--- a file nobody has answered for is told `true` here rather than left to an extension table that
--- does not mention it.
---
--- **There is no plugin-wide switch above that, and there was one.** It was a menu row, and it is
--- gone because it answered a question nobody asked twice: a reader who wants no long-press zoom
--- in a book turns it off *in that book*, with the page in front of them. That per-file level is
--- the one that has always been the interesting one, and it is still stock's own row.
---
--- That is the whole of it, and the reason it is this small is worth keeping from the design it
--- replaces. An earlier version made the extension entry authoritative for markers — read on
--- open, written the moment the row was flipped, and the sidecar copy deleted so nothing could
--- contradict it. That gave one answer for all of a series' chapters, which is right, but it did
--- it by naming an *extension*, and this engine opens `.cbz` too: a reader looking at a `.cbz`
--- was shown the answer for markers while the book in front of them followed `cbz`. One answer
--- for everything this engine opens has no such gap, and costs no machinery.
---
--- The line the wraps below must not cross: a file that was only *opened* may not come away with
--- an answer of its own. Stock writes the live field into the sidecar on every save, so without
--- the third wrap a book opened while the field said on would be pinned on for good, and would
--- survive the reader turning it off — which is precisely the failure the design above was built
--- to avoid, arriving from the other side.
local function installPanelZoom(ui)
    local hl = ui and ui.highlight
    if not (hl and ui.paging) then
        return false
    end
    if hl._meguru_panel_zoom_installed then
        return true
    end
    hl._meguru_panel_zoom_installed = true

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
        -- The file's own answer, kept beside the flag that says it answered: the live field it
        -- was read from is written over by a rival plugin later in this same event, so the
        -- press asks this instead. See `meguruPanelZoomWanted`.
        -- Written as a branch and not as `own and self.panel_zoom_enabled or nil`: that idiom
        -- collapses the file's "off" to nil, which happens to read the same way through
        -- `meguruPanelZoomWanted` and is the shape this codebase warns about elsewhere — a
        -- normalising step that turns one valid answer into another.
        if own then
            self._meguru_panel_zoom_answer = self.panel_zoom_enabled == true
        else
            self._meguru_panel_zoom_answer = nil
        end
        -- **Written unconditionally now, where it used to stand aside for a rival.**
        -- The field is stock's gate and `ReaderHighlight:onHold` reads it *before* any
        -- handler runs — so a rival that pins it true (Panels+ does, after every
        -- `ReadSettings`) would otherwise have Meguru's own preference overruled by a
        -- plugin the reader may not even have enabled. Writing it here and letting the
        -- rival write over it costs nothing: the press is decided at the handler, and
        -- `meguruPanelZoomWanted` asks *this* cascade there rather than the field.
        if not own then
            -- Stock put the per-extension entry here, and it has nothing to put there for these
            -- extensions — `.meguru` is not a format it knows and `.cbz` is one it reads with
            -- another engine. A file nobody has answered for is told yes, so that the long-press
            -- works at all; the per-file row is what can say no.
            self.panel_zoom_enabled = true
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
        -- Stock's row is the reader answering for *this* file, mid-session, and the stash above
        -- would otherwise still hold the answer the file was opened with.
        self._meguru_panel_zoom_answer = self.panel_zoom_enabled
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
    -- Stock's `onHold` has already gated on `self.panel_zoom_enabled` by the time this runs, so
    -- the field is not re-read here — see `meguruPanelZoomWanted` for what *is* asked, and why.
    --
    -- **One wrapper, installed once, and it never steps aside.** That last part is the whole of
    -- how two plugins share this gesture without either reading the other's state: a plugin that
    -- wants it too patches the same field *later* (directories sort, and this one sorts first), so
    -- it ends up outermost and answers; when it is switched off it delegates to the handler it
    -- saved, which is this one — and this one simply handles the press rather than checking who
    -- is above it. Whichever plugin is installed and enabled is therefore the one that answers,
    -- and the other is never consulted either way.
    --
    -- The fallback for a press this detector cannot serve is stock's own handler
    -- (`nativePanelZoom`), never the other plugin's, so the engine a *refused page* lands in stays
    -- a property of this plugin rather than of the page.
    --
    local function press(self, arg, ges)
        if not meguruPanelZoomWanted(self) then
            -- `false` and not stock: the reader turned the panel zoom off for this file, and
            -- stock would open the single region under the finger, which is the thing they
            -- turned off. `onHold` reads that false with the text-selection fallback pinned off,
            -- so the press does nothing at all — which is what the row promises.
            return false
        end
        local native = nativePanelZoom()
        if native == nil then
            -- Nothing to fall back to on a build that moved that module, and doing nothing is
            -- the only honest answer: a page this detector refuses would otherwise be handed to
            -- whatever else holds the gesture, which is the wrong engine chosen silently.
            return false
        end
        return meguruPanelZoom(self, arg, ges, native)
    end
    hl.onPanelZoom = press

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

-- Reading progress -------------------------------------------------------------

--- How long a burst of page turns collapses into one report.
---
--- **Not a save frequency — the window that collapses a burst.** A reader who
--- flicks through ten pages has one position, not ten, and only the newest is
--- worth sending: a queue would be a backlog of pages nobody is on any more.
---
--- **And a delay rather than `nextTick`, which is the load-bearing half.**
--- `UIManager:nextTick` is `scheduleIn(0, …)`, and `handleInput` runs its due
--- tasks *before* it repaints — so a task armed with no delay runs in the very
--- iteration that is about to paint the page the reader just turned to, and the
--- request would block that paint. A task armed at `now + 1.5` runs in an
--- iteration that begins long after the page is on screen.
local PROGRESS_DEBOUNCE_S = 1.5

--- How many consecutive failures retire reporting for the rest of the book.
---
--- The request is synchronous, so a server that is up but refusing — or a route
--- that black-holes it — would otherwise cost the reader the request's whole
--- timeout *every page, for as long as they read*. Three is where "unlucky"
--- stops being the better explanation. The count lives on the plugin instance,
--- so it is per book: it costs nothing, it heals on the next one, and it dies
--- with the UI it describes.
local PROGRESS_MAX_FAILURES = 3

--- Send whatever position is waiting, if there is one.
---
--- The whole of the failure policy is here, and it is one sentence: **nothing
--- below may throw, and nothing below shows the reader anything.**
local function reportPending(plugin, st)
    if st.sending or not st.pending then
        return
    end
    local page = st.pending
    if not Progress.moved(st.floor, page) then
        st.pending = nil
        return
    end
    st.sending = true
    -- pcall'd around the call rather than trusted: this runs from a UI task or
    -- from an event handler, and a throw in either is a broken book, not a lost
    -- page number.
    local ok, sent, reason = pcall(Progress.report, st.file, st.desc, page, st.total)
    st.sending = false
    if not ok then
        logger.warn("Meguru: could not report the position:", tostring(sent))
        return
    end
    if sent then
        -- The floor rises with the server, which is what makes the next turn
        -- below it a no-op and a duplicate impossible.
        st.floor, st.pending, st.failures = page, nil, 0
        return
    end
    -- Refused. The position stays, so the closing flush can try it once more, and
    -- nothing is re-armed here: the next page turn is what asks again.
    --
    -- `off`, `offline` and `behind` are not the server's fault and must not count
    -- towards the breaker. An offline device is asked whether it is online once
    -- per turn, which costs nothing, and the answer changing is how reporting
    -- comes back. `behind` never arrives from here — both callers ask
    -- `Progress.moved` before arming — and it is named anyway so that a caller
    -- which one day forgets cannot retire the feature by asking for a page the
    -- server is already past.
    if reason ~= "off" and reason ~= "offline" and reason ~= "behind" then
        st.failures = st.failures + 1
    end
end

--- The per-book state of the position report, or nil when there is nothing to
--- report from.
---
--- Kept on the plugin instance because a plugin instance belongs to one
--- `ReaderUI`, which belongs to one book — the same reason the wide-page rotation
--- state lives there. Nothing about it is written anywhere: `meguru/progress` has
--- why the marker is not a place for it.
---
--- Declared after `reportPending` because `st.pump` closes over it; the reverse
--- order would make the name resolve as a global and find nothing.
local function progressState(plugin)
    local st = plugin._meguru_progress
    if st then
        return st
    end
    local doc = plugin.ui and plugin.ui.document
    if not (doc and doc.provider == "meguru" and type(doc.desc) == "table") then
        return nil
    end
    local total = doc.getPageCount and doc:getPageCount() or doc.desc.count
    total = tonumber(total)
    if not total or total < 1 then
        return nil
    end
    st = {
        file     = doc.file,
        desc     = doc.desc,
        total    = total,
        -- The server's own position as the floor, so the page the reader lands
        -- on can never move it backwards. See `Progress.floorFor`.
        floor    = Progress.floorFor(doc.desc, total),
        pending  = nil,
        -- The page the closing flush has already tried, so one exit does not pay
        -- for the same request three times — see `flushProgress`.
        flushed  = nil,
        sending  = false,
        failures = 0,
    }
    -- **One stable reference**, because `UIManager:unschedule` matches a task by
    -- identity: a fresh closure per page turn would leave orphaned tasks behind
    -- and report the same position twice.
    st.pump = function()
        reportPending(plugin, st)
    end
    plugin._meguru_progress = st
    return st
end

--- A page turn: remember where the reader is and arm the debounce.
local function notePageTurn(plugin, page)
    local st = progressState(plugin)
    if not st or st.failures >= PROGRESS_MAX_FAILURES then
        return
    end
    page = math.floor(tonumber(page) or 0)
    if page < 1 or page == st.pending then
        return
    end
    -- At or below the server's own position: not a report, and not a task
    -- either. This is the half that keeps a finished book finished.
    if not Progress.moved(st.floor, page) then
        return
    end
    st.pending = page
    -- A page the reader has moved on to is one the closing flush has not tried,
    -- whatever it tried before it.
    st.flushed = nil
    UIManager:unschedule(st.pump)
    UIManager:scheduleIn(PROGRESS_DEBOUNCE_S, st.pump)
end

--- Send the page on screen now, because the book is ending.
---
--- The page is read from the UI rather than from `st.pending`, because the
--- debounce may never have fired for it — and the last page of a session is the
--- one most worth having.
---
--- **Deduplicated, because one exit reaches three of these.** Backing out of the
--- reader sends `Close`, and that reaches `onClose`, `onCloseDocument` *and*
--- `onFlushSettings` within a few lines of each other; on a server that is down,
--- a flush without this check would spend three block timeouts on one page. The
--- breaker is bypassed here on purpose — a closing book is the one moment where
--- one blocked request is affordable — so `flushed` is what stands in its place.
local function flushProgress(plugin)
    local st = progressState(plugin)
    if not st then
        return
    end
    -- `plugin.ui` is guarded even though a close handler should always have one:
    -- `currentPage` indexes it directly, and the one thing this path may never do
    -- is throw — an exception here would come out of a close event, where the
    -- reader's book is the thing being closed.
    local ui = plugin.ui
    local page = math.floor(tonumber(ui and currentPage(ui)) or 0)
    if Progress.moved(st.floor, page) then
        st.pending = page
    end
    if not st.pending or st.pending == st.flushed then
        return
    end
    st.flushed = st.pending
    -- Also the cleanup: a task armed 1.5s ago would otherwise outlive the book
    -- and report a position for a document that is gone.
    UIManager:unschedule(st.pump)
    st.failures = 0
    reportPending(plugin, st)
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

--- The standalone wide-page-rotation row, used only when
--- `pagenumbercrop.koplugin` is absent — its own row is preferred when it is
--- there, because that row drives that plugin's rotation.
---
--- The values match that plugin's own row exactly — `{off, left, right}` — so a
--- book switched between the two keeps identical behaviour and the stored
--- numbers never change meaning. The event is namespaced, so this plugin can
--- never swallow the real plugin's event.
---
--- **The two rows this used to sit beside are gone.** "Page Number Crop" and
--- "No crop on blank pages" were independent toggles over rules that only mean
--- anything together — what a reader wants is "crop the page or not", and all
--- three rules are what cropping a page means here (`document.lua`'s
--- getPageBBox). Their values are therefore no longer read from anywhere: a book
--- that had either turned off keeps the key in its sidecar and gets the rule back.
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

--- Page tone. A row written here rather than lifted from the stock table — which
--- on this menu is not unusual (`Fit`, `Reading direction` and the crop row are ours
--- too), but this is the only one whose *values* are the reason: stock's presets
--- are the wrong shape for a streamed page.
---
--- Its presets stop at 3.0 where stock's run to 50: those are aimed at a badly
--- scanned text page, where crushing everything to black and white is the point,
--- and on artwork they simply burn the picture. Everything else about the row is
--- stock's on purpose, down to the `name` and the `event`, because those two are
--- what stock's own plumbing already listens for:
---
---  * the value goes to `document.configurable.contrast` through `ConfigChange`
---    (`ReaderKoptListener:onConfigChange`, which repaints on it), and *that* is
---    the value the document renders at — in the reader view and in every panel
---    view alike, since a panel never passes through the reader (`document.lua`'s
---    `contrast()`);
---  * the `event` fires `GammaUpdate`, which updates `ReaderView.state.gamma`
---    (which is what invalidates the reader's own page buffer) and shows the
---    stock "Contrast set to: %1." notification.
---
--- So this row carries no handler of its own in this plugin. Nothing it does
--- needs one: the two things it triggers are already handled, by stock.
local CONTRAST_ROW = {
    name = "contrast",
    name_text = _("Contrast"),
    buttonprogress = true,
    values = { 0.8, 1.0, 1.2, 1.5, 1.8, 2.2, 3.0 },
    args = { 0.8, 1.0, 1.2, 1.5, 1.8, 2.2, 3.0 },
    labels = { 0.8, 1.0, 1.2, 1.5, 1.8, 2.2, 3.0 },
    default_pos = 2,
    default_value = 1.0,
    event = "GammaUpdate",
    -- The fine-tune spinner, which is how a reader reaches a value the presets
    -- do not name. Its own bounds match the presets rather than stock's 0.8-50,
    -- for the reason above.
    more_options = true,
    more_options_param = {
        value_step = 0.1, value_hold_step = 0.5,
        value_min = 0.8, value_max = 3.0,
        precision = "%.1f",
    },
    help_text = _([[Page tone, applied by the renderer: above 1.0 darkens and hardens the page, below it lifts and flattens it. It applies to panels as well. Long-press this row to set what new Meguru books start at.]]),
}

--- Whether the page is dithered as it is written to the screen.
---
--- Stock's row, stock's name and stock's event, for the reason the Contrast row
--- above gives: `ConfigChange` is what writes `configurable.sw_dithering`, and
--- `SWDitheringUpdate` is what `ReaderView:onSWDitheringUpdate` already listens
--- for — it assigns `document.sw_dithering` and shows the notification. That is
--- the very field this document's blit reads (`drawPage` picks `ditherblitFrom`
--- or `blitFrom` from it), so this row needs no handler here either.
---
--- **`args` are booleans where the row's own `values` are 0/1, and that is
--- load-bearing rather than stylistic.** The event's payload goes straight into
--- `document.sw_dithering`, and `0` is truthy in Lua: passing the stored domain
--- through would leave the page dithered at "off". Stock's row carries booleans
--- in `args` for exactly this reason, while the value the configurable and the
--- sidecar keep stays 0/1.
---
--- Not `advanced = true`, unlike stock's: `advanced` rows are hidden until the
--- reader turns advanced options on, and this menu is curated rather than
--- layered — a row offered here is a row meant to be seen.
local DITHERING_ROW = {
    name = "sw_dithering",
    name_text = _("Dithering"),
    toggle = { C_("Dithering", "off"), C_("Dithering", "on") },
    values = { 0, 1 },
    default_value = 0,
    event = "SWDitheringUpdate",
    args = { false, true },
    help_text = _([[Dithers the page into sixteen grey levels as it is written to the screen, which is how a scanned page has been shown here so far. Off writes each pixel flat instead — smoother on a screen whose controller dithers an 8-bit framebuffer itself, banded on one that does not. Remembered for this book; long-press this row to set what new Meguru books start at.]]),
}

--- Colour intensity, for the screens that can show it.
---
--- Stock's row again, and its own preset list kept as it is — where the Contrast
--- row's had to be narrowed for artwork, stock's saturation presets (`0.2` to
--- `2.0`) already describe what a reader would want to do to a comic page, so
--- there is nothing to correct. `event = "SaturationUpdate"` is stock's, and
--- `ReaderView:onSaturationUpdate` is what answers it: the notification, and
--- `state.saturation` for the reader view's own copy. The document reads its
--- `configurable` instead (see its `saturation()`), for the reason Contrast
--- documents — a panel never passes through `ReaderView`.
---
--- **Offered only where the pages are decoded in colour**, which is one predicate
--- and not two: `Image.colorEnabled()` is the answer the decode itself asks for
--- (the reader's colour setting *and* a framebuffer that can hold it), so on a
--- grayscale screen this row would set a value that `adjustSaturation` returns
--- early on — a switch that does nothing, which is what this curated menu exists
--- to keep out. Stock gates the same row on `hasColorScreen()` and
--- `isColorEnabled()`, which is the same pair of questions asked in two places.
local SATURATION_ROW = {
    name = "saturation",
    name_text = _("Saturation"),
    buttonprogress = true,
    values = { 0.2, 0.5, 1.0, 1.2, 1.4, 1.6, 1.8, 2.0 },
    args = { 0.2, 0.5, 1.0, 1.2, 1.4, 1.6, 1.8, 2.0 },
    labels = { 0.2, 0.5, 1.0, 1.2, 1.4, 1.6, 1.8, 2.0 },
    default_pos = 3,
    default_value = 1.0,
    event = "SaturationUpdate",
    more_options = true,
    more_options_param = {
        value_step = 0.1, value_hold_step = 0.2,
        value_min = 0.2, value_max = 2.0,
        precision = "%.1f",
    },
    help_text = _([[Colour intensity of the page: below 1.0 the colours are drained towards grey, above it they are pushed further apart, and 1.0 is the file's own colour. It applies to panels as well. Remembered for this book; long-press this row to set what new Meguru books start at.]]),
}

--- Whether the Dithering row is worth offering at all.
---
--- `BB_dither_blit_to` honours the dither for a **BB8 destination and is a plain
--- blit for every other one** (`base/blitbuffer.c`), so on a colour screen the
--- switch would change nothing at all — and a row that sets a value with no
--- visible effect is what this curated menu exists to keep out. `fb_bpp == 8` is
--- the same test `Image.colorEnabled` uses, read live: the framebuffer depth
--- KOReader read from the kernel, and the one description of "the destination is
--- the 8-bit one".
---
--- Read when the dialog is built rather than at module load, because it is a
--- property of the session's screen and every other live question in this file is
--- asked the same way.
local function ditheringOffered()
    return Screen ~= nil and Screen.fb_bpp == 8
end

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
    -- The stock tabs are found for the rows they hold — by their **icons**, which
    -- is the only name `KoptOptions` gives them — and for nothing else. The dialog
    -- that comes back is three tabs of this plugin's own (see the return below),
    -- so a stock tab is a place to lift a row from, not a shape to reuse.
    --
    -- **There is no fallback to the whole of `KoptOptions` any more**, and there
    -- was one: it answered a stock layout we did not recognise with everything,
    -- on the grounds that a wrong menu beat an empty one. It cannot be wrong now
    -- in that way — the crop row, the fit row, the tone rows and the two-page rows
    -- are this file's, so the dialog is never empty — and stock's rows are exactly
    -- what this function exists to keep out of a streamed book. A tab that is not
    -- found costs exactly the rows lifted from it — `stockOptionRow` is nil-safe,
    -- and every one of those lookups already tolerates nil — and costs them
    -- silently, which is the price of the rows this file owns being enough to
    -- build a working menu without it.
    local rotation_tab, pageview_tab
    for _, tab in ipairs(KoptOptions) do
        if tab.icon == "appbar.rotation" and not rotation_tab then
            rotation_tab = tab
        elseif tab.icon == "appbar.pageview" and not pageview_tab then
            pageview_tab = tab
        end
    end

    local rotation_options = {}
    local rotation_mode = stockOptionRow(rotation_tab, "rotation_mode")
    if rotation_mode then
        rotation_options[#rotation_options + 1] = rotation_mode
    end
    rotation_options[#rotation_options + 1] =
        stockOptionRow(rotation_tab, "rotate_wide_pages") or ROTATE_WIDE_ROW

    -- **Page**: the page's own shape and its picture. How it is fitted, what is
    -- cut off it, and the three tone rows — which had a tab of their own until the
    -- tabs were regrouped into these three, and belong here because every one of
    -- them is about the page rather than about how many of them are on the screen.
    --
    -- Contrast is the one tone row that is always offered; the other two are each
    -- about *this screen* rather than about the page — saturation is a colour
    -- operation, and a dither is how the page is written to an 8-bit framebuffer —
    -- so each appears only where the screen can honour it. Their order is stock's
    -- own (`appbar.contrast` lists them Contrast, Saturation, ... Dithering), so a
    -- reader who knows a PDF's tone tab finds the same things in the same places.
    --
    local page_options = {
        -- Computed live from the reader's own zoom mode, so the row reflects what
        -- the book is actually showing even after a manual pinch, and falls back
        -- to the plugin preference when the current zoom is one of the three fits
        -- does not name (a manual pinch, "page", ...).
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
        -- Our own *Crop* row, not the stock one: the stock row carries the
        -- semi-manual define-an-area flow, which needs a crop box to persist and a
        -- streamed page has none. Only the two states the engine realises are
        -- offered, and both fire the core "ReZoom" so the new box applies to the
        -- page on screen immediately.
        --
        -- "Page Number Crop" and "No crop on blank pages" were rows here — the
        -- stock ones `pagenumbercrop.koplugin` injects when it is installed, this
        -- file's own copies when it is not — and they are folded into "auto"
        -- instead: the engine no longer reads either value (`document.lua`'s
        -- getPageBBox), so their help text lives on this row now, which is the only
        -- place a reader can still learn what the crop does.
        {
            name = "trim_page",
            -- **"Crop", not "Page Crop"**: the tab this row is on is already the
            -- page's, so the word was saying it twice.
            name_text = _("Crop"),
            toggle = { C_("Crop", "none"), C_("Crop", "auto") },
            values = { 3, 1 },
            args = { 3, 1 },
            default_value = 1,
            event = "ReZoom",
            help_text = _([[Trims the empty margins around the artwork. "auto" also removes a printed page number from the bottom gutter when one is found, and leaves an almost-blank page — a chapter divider, a title page — entirely uncropped instead of zooming into a small element. Nothing is cropped if nothing is found.]]),
        },
        CONTRAST_ROW,
    }
    if Image.colorEnabled() then
        page_options[#page_options + 1] = SATURATION_ROW
    end
    if ditheringOffered() then
        page_options[#page_options + 1] = DITHERING_ROW
    end

    -- **Reading**: what a page turn does, how many pages are on the screen, and
    -- what a long-press does.
    --
    -- The two rows below "Two pages" belong to it and are dimmed until it is on,
    -- which is as close as this menu can come to the group a reader would draw:
    -- **the bottom menu has no sub-items at all** — `sub_item_table` is the ⋮
    -- menu's (`ui/widget/menu.lua`), and `ConfigDialog` implements none of it — so
    -- a parent and its children can be ordered and gated here, never indented.
    local reading_options = {}
    reading_options[#reading_options + 1] = {
        name = "opdsbook_manga",
        -- **Named for the question, not for one of its two answers**: the row was
        -- "Invert read (manga mode)", which told a reader who reads manga what they
        -- already knew and told everyone else nothing. `values` and `args` are
        -- unchanged — 0 is left to right, 1 is manga — so nothing stored moves.
        name_text = _("Reading direction"),
        toggle = {
            C_("Reading direction", "left to right"),
            C_("Reading direction", "manga (right to left)"),
        },
        values = { 0, 1 },
        args = { false, true },
        default_value = 1,
        event = "MeguruMangaRead",
        help_text = _([[Which way the pages are read. "left to right" is a western book; "manga (right to left)" is a Japanese one, where the pages turn the other way and the earlier page of a spread is the right-hand one. Remembered for this book; new Meguru books start in manga order — long-press this row to change that default.]]),
    }
    local page_view = stockOptionRow(pageview_tab, "page_scroll")
    if page_view then
        reading_options[#reading_options + 1] = page_view
    end

    -- **The two-page group, in the order a reader meets it.** "Two pages" is the
    -- switch; the two rows under it are what it makes available, and both are
    -- inert while it is off (`enabled_func`) — which is the only thing telling a
    -- reader they belong to it, this menu having no way to indent them (see the
    -- note on the tab above).
    --
    -- **"off" is the default**, so nothing about an existing book changes until a
    -- reader asks.
    reading_options[#reading_options + 1] = {
        name = "spread",
        name_text = _("Two pages"),
        toggle = {
            C_("Two pages", "off"),
            C_("Two pages", "in landscape"),
            C_("Two pages", "always"),
        },
        values = { "off", "auto", "on" },
        args = { "off", "auto", "on" },
        default_value = "off",
        event = "MeguruSpreadUpdate",
        help_text = _([[Shows two pages side by side, the way a printed book falls open. "in landscape" does it only while the screen is turned on its side, "always" in either orientation. A page the artist drew as one wide image is always shown whole and on its own, and the pairing starts again after it, so a printed spread never lands halfway through a pair. Remembered for this book; long-press this row to set what new Meguru books start at.]]),
    }
    reading_options[#reading_options + 1] = {
        name = "spread_offset",
        -- **"Pair", not "Page"**: what the row moves is where a *pair* starts, and
        -- a reader who has just read "Two pages" above it needs the word that ties
        -- the two together.
        name_text = _("Pair offset"),
        toggle = {
            C_("Pair offset", "off"),
            C_("Pair offset", "on"),
        },
        values = { 0, 1 },
        args = { 0, 1 },
        default_value = 0,
        event = "MeguruSpreadOffsetUpdate",
        -- **The row shows the run the reader is in, not the value in the book.**
        -- The stored answer is a *page* (see `meguru/spread`), and it says nothing
        -- by itself about the pages on screen: a wide page ends an offset without
        -- the stored value changing at all. So the switch is answered live, which
        -- is what makes "the offset ended" something the reader can see rather
        -- than something they have to infer from the pairing.
        current_func = function()
            local doc = ui and ui.document
            local page = ui and ui.paging and ui.paging.current_page
            if not (doc and page and type(doc.spreadOffsetHere) == "function") then
                return 0
            end
            return doc:spreadOffsetHere(page) and 1 or 0
        end,
        -- Inert while there is only ever one page on the screen — a switch that
        -- changes nothing is what this curated menu exists to keep out.
        enabled_func = function(configurable)
            return configurable.spread ~= nil and configurable.spread ~= "off"
        end,
        help_text = _([[Shifts the pairs of the run you are reading one page back: off pairs 1+2, 3+4; on leaves the run's first page standing alone and pairs 2+3, 4+5, so on page 7 you see 6+7 rather than 7+8. It applies from where you set it. A page the artist drew as one wide image ends it by itself — the pairs after a spread are as they fall unless you set it again there — which is also the row's way of telling you where you are. Turn it on for a book whose spreads read one page out: a cover or a title page that is its own page, or a printed spread the file counts as one.]]),
    }
    reading_options[#reading_options + 1] = {
        name = "spread_gutter",
        name_text = _("Flexible gutter"),
        toggle = { C_("Flexible gutter", "off"), C_("Flexible gutter", "on") },
        values = { 0, 1 },
        args = { 0, 1 },
        default_value = 1,
        event = "MeguruSpreadGutterUpdate",
        -- Inert with nothing showing two pages, like the offset above and for the
        -- same reason.
        enabled_func = function(configurable)
            return configurable.spread ~= nil and configurable.spread ~= "off"
        end,
        help_text = _([[The crop trims each page's inner margin, which would butt the two pages of a spread together at the middle. With this on, the space left over once the artwork is fitted to the screen goes back into that gutter — never more than the margin the page itself has, and never enough to make the artwork smaller. With it off, a pair is drawn exactly as the crop left it. Remembered for this book; long-press this row to set what new Meguru books start at.]]),
    }

    -- **One row for the three views and Off**, and Off is not a fourth view at all
    -- but KOReader's own per-book answer for whether there is a panel zoom — which
    -- is why neither the display nor the write here is a plain assignment; see
    -- `current_func` and `onMeguruPanelViewUpdate`.
    --
    -- One row for both questions because that is the question a reader has: what
    -- happens when I hold on a page. Splitting them is how a row ends up showing a
    -- view while the long-press does nothing. Last in this tab because it is what
    -- a *touch* does, where the rows above are what a page turn does.
    reading_options[#reading_options + 1] = {
        name = "panel_view",
        -- **Named for what it sets, not for the gesture that sets it**: "Long-press"
        -- named the way in, which the row's own help text has to explain anyway, and
        -- said nothing to a reader who had not tried it. Its three answers are the
        -- views' own names, and lower case as they are written here: they are the
        -- values of a switch, not headings. The switch inside the viewer carries the
        -- same three words, letter for letter, so a reader who learns one of them in
        -- either place recognises it in the other.
        name_text = _("Panel view"),
        toggle = {
            C_("Panel view", "off"),
            C_("Panel view", "panel cut"),
            C_("Panel view", "pan & zoom"),
            C_("Panel view", "free view"),
        },
        values = { "off", "crop", "window", "zoom" },
        args = { "off", "crop", "window", "zoom" },
        default_value = "window",
        event = "MeguruPanelViewUpdate",
        -- The two keys this row answers for, read as one value: the book's own
        -- answer for whether there is a panel zoom (its stash, not the live
        -- field — see `meguruPanelZoomWanted` for why), and then the view.
        current_func = function()
            local hl = ui and ui.highlight
            if hl and not meguruPanelZoomWanted(hl) then
                return "off"
            end
            return Reader.panelViewMode(ui)
        end,
        help_text = _([[What holding on a page does. "panel cut" shows the panels the detector found, one at a time; "pan & zoom" keeps the page whole and moves a window over it; "free view" shows the page alone. "off" leaves the long-press to KOReader, and applies to this book only. Long-press this row to make a view the default for new books. This is Meguru's own panel view — a panel plugin that answers the long-press itself is its own.]]),
    }

    -- **Three tabs of this plugin's own, and the order is a reader's**: what a
    -- page turn does, what the page looks like, and how a page is turned. Stock's
    -- four do not come back — the crop and the three tone rows are one tab here,
    -- because a reader changing how a page is *shown* is not served by having the
    -- crop and the contrast two tabs apart — and neither do stock's icons, which
    -- is the other thing `meguru/icons` is for.
    return {
        prefix = "kopt",
        { icon = Icons.tab("reading"), options = reading_options },
        { icon = Icons.tab("page"), options = page_options },
        { icon = Icons.tab("rotation"), options = rotation_options },
    }
end

--- Long-press a curated row to set it as the default for *future* Meguru books.
---
--- Without this the stock handler would write a global `kopt_*`, leaking a
--- choice made while reading a stream into every PDF opened afterwards. Rows
--- this plugin has no preference for get no "set as default" at all — the stock
--- handler is swallowed rather than allowed to fall through — and a row whose
--- *value* is not the thing a preference holds declines that one value the same
--- way, saying so rather than writing something meaningless (the long-press row's
--- Off, below).
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
        -- **The one row with a value a preference cannot hold.** The long-press row's
        -- first answer, Off, is not a view: it is KOReader's own per-book
        -- `panel_zoom_enabled`, and whether there is a panel view is per-book by
        -- design (`meguruPanelZoomWanted`: "the per-file answer is the only one there
        -- is"). So there is no default to set for it, and saying so is better than a
        -- ConfirmBox that writes a view called "off" and leaving `Settings` to hold a
        -- word nothing reads. The three views below it are ordinary defaults.
        if name == "panel_view" and value == "off" then
            UIManager:show(Notification:new{
                text = _("Off applies to this book only — a default is one of the three views."),
                timeout = 2,
            })
            return true
        end
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

--- Whether the page being drawn is inverted for night mode — the question
--- `MeguruDocument:drawPage` asks itself before it cancels the inversion over the
--- region it drew. The surround has to answer it the same way the page does, or
--- one of the two reads as the other's negative.
local function pageIsInverted(document)
    local configurable = document and document.configurable
    return configurable ~= nil and configurable.nightmode_document == 1
        and Screen.night_mode == true
end

--- Rec.601 luminance, the same weights `lumaAt` in the document measures with —
--- this file asks the same question about a colour, so it uses the same answer.
local function lumaOf(r, g, b)
    return math.floor((4898 * r + 9618 * g + 1869 * b) / 16384)
end

--- Whether a margin reads as *paper* rather than as a colour: light on every
--- channel and near-neutral. The night rule below takes paper to the black the
--- screen already is, and must leave a coloured margin alone — the inverse of a
--- yellow frame is blue, which is not a darker version of it but a different
--- colour, and a reader with a yellow-bordered volume did not ask for a blue one.
---
--- The two bounds are a definition, and both sides are chosen deliberately. A
--- colour is *excluded* by one channel being dark (a yellow frame's blue is 0) or
--- by a spread no paper has; everything light and neutral is *included*, cream
--- paper among it. That is the safe direction: what this rule does to a paper
--- margin is make it dark, which is what a margin wants on a dark screen, while
--- the cost of including an off-white *tint* is only that it darkens too — a
--- pale-blue paper margin goes dark rather than glowing, which is not the
--- surprise that turning a yellow border blue would be.
local PAPER_MIN_CHANNEL = 200
local PAPER_MAX_SPREAD = 48
local function isPaper(r, g, b)
    local lo = math.min(r, math.min(g, b))
    local hi = math.max(r, math.max(g, b))
    return lo >= PAPER_MIN_CHANNEL and hi - lo <= PAPER_MAX_SPREAD
end

--- Set the reader's two surround fields from a margin colour (`{r, g, b}`), or
--- back to what the reader had when there is no margin to match.
---
--- The fields are KOReader's own (`ReaderView.outer_page_color`, painted by
--- `drawPageSurround`, and `page_bgcolor`, its continuous-mode twin) and any
--- Blitbuffer colour is legal in them: a grayscale screen converts it to its
--- luminance by the same weights, so a grey margin and a coloured one take the
--- same road and only a colour screen can tell them apart.
---
--- **Night mode asks for the darker of the colour and its inverse, and then
--- inverts what it paints.** The first half is the rule: on a page being read in
--- the dark the letterbox must not become a light band, so a black margin stays
--- black and a white one comes out the black the screen already is (the
--- comparison is by luminance; the inversion is per channel). The second half is
--- the display's own inversion of every fill under night mode, which the page
--- cancels for itself by inverting the region it drew — so the colour painted
--- here is the one that will *come out* as the colour chosen above.
local function setCropMarginColor(plugin, ui, margin)
    local view = ui and ui.view
    local stock = plugin._meguru_view_color
    if not (view and stock and stock.outer) then
        return
    end
    local color
    plugin._meguru_surround = nil
    if margin then
        -- The margin's own colour, per page and unrounded. Rounding it to the grid
        -- the page is dithered on was tried and is *worse*: a margin drifting
        -- between 247 and 248 lands on two different levels of that grid, so the
        -- letterbox jumps a whole step instead of moving a level. What the drift
        -- needs is the honest value, not a coarser one.
        local r, g, b = margin.r, margin.g, margin.b
        if pageIsInverted(ui.document) then
            if isPaper(r, g, b) then
                -- Paper goes to the black the screen already is, so a
                -- white-margined page stops being a band brighter than everything
                -- around it.
                r, g, b = 255 - r, 255 - g, 255 - b
            end
            -- A colour is left where it is: the reader sees the margin they have,
            -- in the dark as in the light. What follows is the display's own
            -- inversion of every fill under night mode, which the page cancels for
            -- itself by inverting the region it drew — so this hands over the
            -- colour that will *come out* as the one chosen above.
            r, g, b = 255 - r, 255 - g, 255 - b
        end
        -- What the two stock fields get is a *grey* of the same brightness, for
        -- the one path that still paints them (continuous mode). The colour
        -- itself goes through `_meguru_surround`, painted below.
        color = Blitbuffer.gray(1 - lumaOf(r, g, b) / 255)
        plugin._meguru_surround = { r = r, g = g, b = b }
    end
    view.outer_page_color = color or stock.outer
    view.page_bgcolor = color or stock.page
end

--- Ask the document for the margin this page's crop took off, remember it, and
--- paint the surround with it. Called on a page turn and once at install.
---
--- Inert wherever the crop is not: with "Crop" off, or on a page the scan
--- refused or found no margin on, `cropMarginColor` answers nil and the reader's
--- own surround colour is restored. That is also what keeps this from arguing
--- with `meguru/doc/image`, whose panel mask is white by a written decision — the
--- colour here is only trusted on a page the crop actually trimmed.
---
--- The *asking* happens here, on a turn, and deliberately not in the paint that
--- follows: a cold crop means a decode, and a decode inside a paint is the one
--- thing this document's render path exists to avoid. The remembered value is
--- what the paint then re-derives from.
local function applyCropMarginColor(plugin, ui, page)
    local document = ui and ui.document
    local configurable = document and document.configurable
    local margin
    if configurable and configurable.trim_page == 1 and type(page) == "number"
        and type(document.cropMarginColor) == "function" then
        margin = document:cropMarginColor(page)
    end
    plugin._meguru_margin_color = margin
    if margin then
        logger.dbg("Meguru: page surround from crop margin",
            lumaOf(margin.r, margin.g, margin.b),
            string.format("(%d,%d,%d)", margin.r, margin.g, margin.b),
            pageIsInverted(document) and "(night)" or "")
    end
    setCropMarginColor(plugin, ui, margin)
end

--- Re-derive the surround on every paint, from the margin a turn remembered.
---
--- **This is the seam that makes night mode come out right, and it cannot be the
--- page turn.** Night mode is toggled between turns — the reader's own
--- `DeviceListener` flips the screen and then dirties the whole view
--- (`Screen:toggleNightMode` then `UIManager:setDirty("all", "full")`), with no
--- turn anywhere in it — so a level decided on the turn is one inversion out of
--- date by the time that repaint runs, and a black-bordered book shows a *white*
--- band around the page. The page itself has no such gap because `drawPage` asks
--- its question while drawing; this asks `pageIsInverted` in the same place, one
--- call above the surround's own paint. Nothing is computed from the page here —
--- the remembered margin is a number, and the rest is two field writes.
local function installCropMarginColor(plugin, ui)
    local view = ui and ui.view
    if not (view and type(view.paintTo) == "function") then
        return
    end
    local orig_paint_to = view.paintTo
    view.paintTo = function(self, ...)
        setCropMarginColor(plugin, ui, plugin._meguru_margin_color)
        return orig_paint_to(self, ...)
    end
end

--- Paint the letterbox in the margin's colour, after stock has painted it grey.
---
--- **The colour cannot travel in `outer_page_color`.** Stock's `drawPageSurround`
--- fills with `bb:paintRect`, whose value goes through a Color8 first — a grey
--- whatever colour it is handed — so a yellow margin came out light grey, which is
--- the bug this fixes. `paintRectRGB32` is the fill that carries channels, and it
--- honours the target's inverse flag exactly as the plain one does, so the
--- night-mode colour computed above is still the one to hand it.
---
--- The whole view rectangle is filled and stock's own fills are left underneath
--- it: `ReaderView:paintTo` draws the page immediately after this, so the page
--- covers itself and what is left showing is the letterbox. Continuous mode does
--- not come through here at all — it paints `page_bgcolor` from
--- `drawPageBackground` — so there the grey in that field is what shows.
local function installCropMarginPaint(plugin, ui)
    local view = ui and ui.view
    if not (view and type(view.drawPageSurround) == "function") then
        return
    end
    local orig_draw_surround = view.drawPageSurround
    view.drawPageSurround = function(self, bb, x, y)
        orig_draw_surround(self, bb, x, y)
        local c = plugin._meguru_surround
        if c then
            bb:paintRectRGB32(x, y, self.dimen.w, self.dimen.h,
                Blitbuffer.ColorRGB32(c.r, c.g, c.b, 0xFF))
        end
    end
end

--- Graft everything reader-side onto `plugin` for the document it has open.
--- A no-op for any other document, so a PDF in the same session never grows a
--- Meguru row or a wrapped seam.
function Reader.install(plugin)
    local ui = plugin and plugin.ui
    local doc = ui and ui.document
    if not (doc and doc.provider == "meguru") then
        return false
    end

    -- What the surround was before this plugin touched it. Captured once per
    -- reader, before anything here writes the fields, which is the idiom stock's
    -- own cropping module uses for the same two fields (`readercropping`).
    if ui.view and not plugin._meguru_view_color then
        plugin._meguru_view_color = {
            outer = ui.view.outer_page_color,
            page = ui.view.page_bgcolor,
        }
    end
    installCropMarginColor(plugin, ui)
    installCropMarginPaint(plugin, ui)

    local rotate_state = {}
    plugin._meguru_rotate_state = rotate_state

    -- Standalone wide-page rotation, unless pagenumbercrop.koplugin is already
    -- driving this document — one owner of a screen's rotation, not two. Both of
    -- its markers are probed, since either may be present depending on which of
    -- its patches applied.
    --
    -- **Read here, which is as early as this plugin gets**, and the two plugins
    -- are constructed in path order (`pluginloader.lua:289`), so a plugin whose
    -- init runs *after* this one has not patched yet and neither marker is set:
    -- then both rotations are installed. That is redundant rather than wrong —
    -- `updatePageRotation` reconciles against the screen's own rotation instead
    -- of toggling it, so the second call is a no-op — and it is unobservable
    -- either way, which is why this is a note and not a guard.
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

    -- The two-page view's own seams, and unlike the rotation above this is
    -- installed whatever else is: it is not a second answer to a question
    -- another plugin answers, it is a question nothing else asks at all.
    --
    -- **One interaction is left open and is recorded in `docs/known-issues.md`:**
    -- with `pagenumbercrop.koplugin` installed *and* the two-page view on, that
    -- plugin's own wide-page rotation reads a pair through this document's
    -- geometry, sees something wider than tall, and turns the screen — which
    -- stops the pair, which makes the next page narrow again. Our guard cannot
    -- catch it, because that path never comes through our rotation.
    installSpread(ui)

    -- Installed here, before the `ReadSettings` event reaches ReaderHighlight,
    -- so the value the reader sees is the one this decides and not the one
    -- stock read out of the book's sidecar a moment later.
    installPanelZoom(ui)

    -- Also before the first paint: the painter is what stands between a failed
    -- page and a reader looking at a gray rectangle with nothing to read.
    installPageErrorPage(plugin)

    -- **Chained, not merged into the installer above**, which is where it would
    -- otherwise belong: `installPageErrorPage` returns early for a document with
    -- no `paintMissingPage`, and a page turn is not a painter's business —
    -- hanging the position report on that guard would stop it silently on the
    -- day the guard changes. Chaining is this file's own idiom (see
    -- `installPanelZoom` and `curateConfigMenu`), and the captured handler is
    -- whatever the field holds *now*, so the failed-page retry survives.
    --
    -- A turn that arrives without a page number falls back to the page on screen,
    -- which is where the paging module keeps it.
    local page_error_handler = plugin.onPageUpdate
    plugin.onPageUpdate = function(self, page)
        if type(page_error_handler) == "function" then
            page_error_handler(self, page)
        end
        local turned = page or (self.ui and currentPage(self.ui))
        notePageTurn(self, turned)
        applyCropMarginColor(plugin, self.ui or ui, turned)
    end

    -- And the page the book opens on, which no page turn announces.
    applyCropMarginColor(plugin, ui, currentPage(ui))

    -- And whenever the crop moves with no turn in it. The Crop row fires the
    -- reader's own `ReZoom` rather than a page turn, so switching it — `none` to
    -- `auto` most visibly — left the newly cropped page inside the colour the
    -- *uncropped* one answered: invisible on a white margin, where the reader's own
    -- surround already matches, and on a coloured one it reads as the crop not
    -- working at all.
    --
    -- Wrapped on the handler that derives the box, so the crop is warm by the time
    -- the colour is asked for — which is what keeps the asking off the paint, where
    -- a cold crop would be a decode. A plugin `onReZoom` would not do:
    -- `ReaderZooming:onReZoom` returns true and consumes the event.
    local zooming = ui.zooming
    if zooming and type(zooming.onReZoom) == "function" then
        local zooming_rezoom = zooming.onReZoom
        zooming.onReZoom = function(self, ...)
            local handled = zooming_rezoom(self, ...)
            applyCropMarginColor(plugin, ui, currentPage(ui))
            return handled
        end
    end

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

        -- **And the page-number crop is this plugin's, whatever else is
        -- installed.** `pagenumbercrop.koplugin` patches the same seam from its
        -- own init, and its analysis is the one this plugin was ported from —
        -- without the width bound that keeps a sound effect or a boxed title
        -- from being removed as if it were a number. A reader who has both
        -- installed gets this plugin's crop.
        --
        -- This is the seam for it, and *not* the install above: plugins are
        -- constructed one after another in `ReaderUI:init`, so a take-back done
        -- there is only as late as this plugin's own turn — whichever of the two
        -- inits runs last would decide it. `postReaderReadyCallback` is provably
        -- later than all of them: `ReaderUI:init` fires `ReaderReady` and only
        -- then runs that list (`readerui.lua:517-522`), and the reader's first
        -- paint comes after init returns. Taking it back here also re-derives the
        -- box (below), which is still before that paint — so nothing is drawn
        -- twice.
        ui:registerPostReaderReadyCallback(function()
            if type(doc.takeBackPageBBox) ~= "function" or not doc:takeBackPageBBox() then
                return
            end
            logger.info("Meguru: took the crop seam back from pagenumbercrop")
            -- It had patched, so its answer may be in the box already derived
            -- for the page this book opened on: that box is derived during
            -- `ReadSettings`, which runs after every plugin's init. Derive it
            -- again, for the same reason the seeded rows do
            -- (`meguru/doc/defaults`).
            ui:handleEvent(Event:new("ReZoom"))
        end)

        -- And the two-page view's first look, here rather than at install for
        -- the reason the take-back above is here: every plugin's seeding has run
        -- by now, so a book the plugin preference gives "on" to is laid out two-
        -- up from its first paint instead of staying one page until something
        -- else asks. `syncSpread` fires nothing when the answer is off, which is
        -- every book that has not asked for it.
        ui:registerPostReaderReadyCallback(function()
            syncSpread(ui)
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

    plugin.onMeguruSpreadUpdate = function(self, value)
        if value ~= "off" and value ~= "auto" and value ~= "on" then
            value = "off"
        end
        local texts = {
            off = _("Two pages: off"),
            auto = _("Two pages: in landscape"),
            on = _("Two pages: always"),
        }
        setSpread(self.ui, value, texts[value])
        return true
    end

    -- The offset row, whose value is *where* rather than *whether*.
    --
    -- The row is a switch — off and on — and "on" means **from here**: the offset
    -- is anchored at the page the reader is on, so it applies to the run they are
    -- reading and no other. That single rule is what makes it do both things the
    -- reader asked for at once: a wide page ends the offset by itself (the anchor
    -- is not in the new run), and setting the row again past one anchors it there.
    -- See `meguru/spread` for the rule and what was rejected in its place.
    --
    -- Compared, never tested: `value` arrives in the row's 0/1 domain and `0` is
    -- truthy in Lua, so `value and …` would read a stored "off" as on — the trap
    -- `meguru/doc/defaults`' `seedRowValue` documents at length.
    plugin.onMeguruSpreadOffsetUpdate = function(self, value)
        local ui = self.ui
        local anchor = 0
        if value == 1 or value == "1" or value == true then
            anchor = (ui and ui.paging and ui.paging.current_page) or 1
        end
        setSpreadOffset(ui, anchor, spreadOffsetNotice(anchor > 0))
        return true
    end

    -- The same flip, for a reader who would rather have a gesture than a menu: the
    -- Dispatcher action `main.lua` registers fires this event, and what it does is
    -- exactly what the row's switch does — off when the run the reader is in is
    -- already offset, and anchored *here* when it is not.
    --
    -- **Installed per reader, like every handler in this block**, which is what
    -- makes the Dispatcher action safe to leave bound outside a Meguru book: the
    -- event arrives, no instance has the method, and nothing happens.
    plugin.onMeguruPairOffsetToggle = function(self)
        local ui = self.ui
        local doc = ui and ui.document
        local page = currentPage(ui)
        if not (doc and page and type(doc.spreadOffsetHere) == "function") then
            return true
        end
        local on = not doc:spreadOffsetHere(page)
        setSpreadOffset(ui, on and page or 0, spreadOffsetNotice(on))
        return true
    end

    plugin.onMeguruSpreadGutterUpdate = function(self, value)
        -- Compared, never tested: 0 is truthy in Lua (see the row).
        value = (value == 1 or value == "1" or value == true) and 1 or 0
        setSpreadGutter(self.ui, value,
            value == 1 and _("Flexible gutter: on") or _("Flexible gutter: off"))
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
        -- **And the document is told, because it is the one that draws a pair.**
        -- Which page of a pair goes on which side is the reading direction's
        -- business, and the document cannot read `view.inverse_reading_order`
        -- (it is not a configurable, and the document is opened before the
        -- reader exists) — so it keeps its own copy, seeded from the same
        -- sidecar key at open and kept in step here.
        local doc = self.ui and self.ui.document
        if doc then
            doc.spread_rtl = enabled
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

    -- The *Reading* tab's *Panel view* row: one of the three views, or off.
    --
    -- **Two keys, one answer, which is why this is more than an assignment.**
    -- `panel_view` holds a view and nothing else, so Off cannot be stored in it —
    -- and it has already been written there by the time this runs, because the
    -- dialog writes the chosen value through `ReaderKoptListener:onConfigChange`
    -- and fires the row's own event after it. The Off branch therefore puts the
    -- reader's own view back: that is a deliberate, narrow normalisation of the
    -- kind this codebase distrusts — one row, one value, one direction — and the
    -- alternative was a view key that could also mean "no view", i.e. two keys
    -- answering the same question and parting company the moment KOReader's own
    -- *Allow panel zoom* row was used.
    --
    -- Whether there *is* a panel zoom is KOReader's `panel_zoom_enabled`, whose only
    -- stock setter is a toggle that ignores its argument
    -- (`ReaderHighlight:onTogglePanelZoomSetting`). So the field is first put where
    -- that flip has to start from, and the flip then leaves it on the wanted answer
    -- — and sets the pin and the book's own answer from it, in the wrap
    -- `installPanelZoom` installs, which is what `meguruPanelZoomWanted` reads at
    -- the press. Both halves are needed: a rival panel plugin moves the field on
    -- every `ReadSettings`, and the row would otherwise name a view while the press
    -- went nowhere.
    plugin.onMeguruPanelViewUpdate = function(self, value)
        local ui = self.ui
        local doc = ui and ui.document
        local configurable = doc and doc.configurable
        if not (configurable and configurable.panel_view ~= nil) then
            return true
        end
        local view = panelViewIsView(value) and value or nil
        if not view and value ~= "off" then
            return true
        end

        local hl = ui.highlight
        local want = view ~= nil
        if hl and (meguruPanelZoomWanted(hl) ~= want
                or hl.panel_zoom_enabled ~= want) then
            hl.panel_zoom_enabled = not want
            hl:onTogglePanelZoomSetting()
        end

        if view then
            configurable.panel_view = view
            if ui.doc_settings then
                ui.doc_settings:saveSetting("kopt_panel_view", view)
                ui.doc_settings:flush()
            end
        else
            local ds = ui.doc_settings
            local stored = ds and ds:readSetting("kopt_panel_view")
            configurable.panel_view = panelViewIsView(stored) and stored
                or Reader.panelViewMode(ui)
        end
        return true
    end

    -- The rotation is restored first and the position reported last, so the
    -- screen is the right way up before anything waits on a socket.
    plugin.onCloseDocument = function(self)
        if self._meguru_wide_rotate_installed then
            restoreWideRotate(self._meguru_rotate_state, self.ui)
            self._meguru_wide_rotate_installed = false
        end
        flushProgress(self)
    end

    plugin.onClose = function(self)
        if self._meguru_wide_rotate_installed then
            restoreWideRotate(self._meguru_rotate_state, self.ui)
            self._meguru_wide_rotate_installed = false
        end
        flushProgress(self)
    end

    -- **The two seams that end a session without closing the book**, and both are
    -- needed: closing the lid runs `UIManager:flushSettings()` and *then*
    -- broadcasts `Suspend`, so both arrive a moment apart and the second finds
    -- nothing left to send — which is what `flushed` is for. Backing out to the
    -- FileManager reaches `onCloseDocument` and neither of these.
    --
    -- Assigned rather than chained because neither is assigned anywhere else in
    -- this plugin; the four that were already assigned above are extended in
    -- place for the opposite reason — a second assignment to any of them would
    -- silently replace the first.
    plugin.onFlushSettings = function(self)
        flushProgress(self)
    end

    plugin.onSuspend = function(self)
        flushProgress(self)
    end

    return true
end

return Reader
