--[[--
The panel sequence viewer: one panel at a time, and the reader's own way on.

A long-press on a Meguru page asks the document for its panels
(`MeguruDocument:getPanelsFromPage`), and this shows them one after another in
reading order. It is KOReader's own `ImageViewer` with four methods changed,
because stock already has almost all of it: a list of images with lazy
entries, a progress bar, pinch and spread, hardware page keys, a Close button
and a dismissal contract the reader already knows from the single-panel viewer
this replaces.

## What "classic" means here

`nav classic` is panels_plus's name for the alternative it is not: moving to the
next panel swaps the picture and nothing else — no camera pan, no framebuffer
animation. Two things follow from it and neither is decoration:

* `images_keep_pan_and_zoom` is off, so a panel opens at best fit rather than
  inheriting the previous panel's pinch. Panels are different pictures; carrying
  one's zoom into the next is how a reader ends up looking at a corner of
  artwork they never chose.
* The picture itself is rendered for the panel's own size, by the document. A
  panel is not a screen-shaped thing, and handing the viewer screen-sized pixels
  would make a pinch magnify a resample of the file rather than the file.

## The pre-warm, and why there is no cache

`MeguruDocument:drawPagePart` already keeps the panels it renders in the
document's tile LRU, so the way to make a swipe instant is to *render the next
panel before the reader asks for it* — the swipe then lands on a tile-cache hit.
That is reuse of a cache the document already has, not a new one: nothing here
holds a bitmap, and moving past a panel releases its tile
(`MeguruDocument:releasePanelTile`), so a reader who goes back pays a re-render
from the current page's bytes — which are still in the page LRU, so still
offline.

The warming is one scheduled action, re-armed on every panel change, and what it
warms depends on where the reader is: the next panel in the middle of a page, and
the next *page* at the end of one, so crossing a page boundary does not pay a
fetch and a decode inside the gesture.

`UIManager:isWidgetShown` is the whole guard. A viewer that has been closed or
handed off is no longer on the stack, so its queued warm is a no-op with no
bookkeeping of ours.

## The page boundary

At the last panel, forward means the next page — the viewer closes, the reader
turns, and a new viewer opens on panel 1 (or on the previous page's last panel,
going back). See `meguruHandoff` for why the order inside that is what it is.
--]]

local _ = require("gettext")

local ButtonTable = require("ui/widget/buttontable")
local CanvasContext = require("document/canvascontext")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local ImageViewer = require("ui/widget/imageviewer")
local Settings = require("meguru/settings")
local UIManager = require("ui/uimanager")
local Viewport = require("meguru/viewport")
local logger = require("logger")

local Screen = Device.screen

local PanelZoom = {}

-- How long the gesture that moved to this panel has to be over before the
-- pre-warm runs. A reader swiping quickly through a page re-arms and
-- unschedules faster than this, so the warm never runs and never does work they
-- did not ask for; a reader who settles on a panel gets it. Long enough to be
-- after the repaint, short enough to be before they read the panel.
local WARM_DELAY = 0.4

-- Is the next panel to the right of this one? A comic reads left to right and a
-- manga right to left, and the value comes from the *book* — resolved in
-- `meguru/ui/reader.lua` and passed in — rather than from `BD.mirroredUILayout`,
-- which is what stock `ImageViewer:onTap` consults. The UI language has nothing
-- to say about which way a manga page is read, so a Polish UI reading a manga
-- gets stock's answer backwards, and that is the whole reason these two
-- overrides exist.
local function nextIsRight(mode)
    return mode ~= "manga"
end

-- The lazy entry `ImageViewer` wants for each step.
--
-- Lazy on purpose in both directions: steps the reader never reaches are never
-- rendered, and each render goes through `drawPagePart`, whose own LRU decides
-- whether this is a fresh render or the pre-warm landing.
--
-- **One body for both views.** A cropped panel carries no size, so the document
-- renders the region at its own size in the page's pixels; a window carries the
-- pixels it has to arrive as, and gets them. The call with neither is byte for byte
-- the one the cropped sequence has always made, and `Panels+` — which goes through
-- `drawPagePart` directly — is untouched by either.
--
-- **The output size is clamped to what stock says the picture may be, and that is not a
-- nicety.** A viewer given a *function* as its image keeps it as `_scaled_image_func`
-- (`imageviewer.lua:160`) and builds the widget around it with `scale_factor = 1` (`:451`) —
-- so the tile is drawn **1:1**, and one pixel wider than the picture area is one pixel painted
-- under the button row. The window views' tiles are shaped like the *screen*, and the row takes
-- a strip of it, so without this the bottom of every window sits behind the buttons. Clamping
-- the output rather than the region keeps the step the same rectangle, rendered smaller.
local function stepImage(doc, page, rect)
    return function(_, max_w, max_h)
        local tw, th = rect.out_w, rect.out_h
        if tw and th and max_w and max_h then
            local shrink = math.min(max_w / tw, max_h / th, 1)
            tw = math.max(1, math.floor(tw * shrink + 0.5))
            th = math.max(1, math.floor(th * shrink + 0.5))
        end
        return doc:drawPagePart(page, rect, 0, tw, th)
    end
end

-- Which panels the viewer should display turned on their side.
--
-- `drawPagePart` answers this for the panel it is rendering, but `ImageViewer`
-- keeps `rotated` on the *viewer* rather than per image, so the decision has to
-- be available before the render — hence the same predicate, here and in
-- `drawPagePart`, from the same setting. It is about the panel's shape against
-- the screen's: a wide spread on a portrait screen is turned, a tall panel is
-- not.
local function panelRotations(panels)
    local rotates = {}
    local g = rawget(_G, "G_reader_settings")
    if not (g and type(g.isTrue) == "function") then
        return rotates
    end
    if not g:isTrue("imageviewer_rotate_auto_for_best_fit") then
        return rotates
    end
    local canvas = CanvasContext:getSize()
    local landscape = canvas.w > canvas.h
    for i, rect in ipairs(panels) do
        rotates[i] = (landscape ~= (rect.w > rect.h))
    end
    return rotates
end

-- The angle a turned panel gets, or nil when turning is stock's business.
--
-- **This is the whole of "a panel turns the book's way".** ImageWidget measures
-- its angle as 270 clockwise and 90 anti-clockwise — stock's own
-- `rotate_clockwise and 270 or 90` — so the book's two words map onto it as a
-- pair of quarters.
--
-- **The pair is crossed, and that is the part to get right.** `Rotate wide pages:
-- left 90°` names a turn of the *device*: the screen is rotated and the reader
-- turns along with it, so the setting's word describes what happens to the hand,
-- not to the glass. A panel has no device to turn — it is rotated *inside* the
-- screen the reader is already holding — so the same reading position is reached
-- by the opposite quarter. Left in the row is a counter-clockwise device, which
-- is a clockwise panel.
--
-- That crossing was derived once, wrong, from stock's comment, and then observed
-- on a device turning panels the wrong way; the two constants are the whole fix,
-- which is why they are the one thing here worth touching without a plan.
--
-- `turned` is stock's `self.rotated` — *whether* a panel should be turned, which
-- stock decides from the panel's shape against the screen's. This answers only
-- *which way*. Keeping those two questions apart is what lets the Rotate button
-- stay stock's: its callback flips the boolean, and the boolean's meaning here
-- changes with it, with nothing in between to keep in step.
local function panelRotationAngle(turned, rotate)
    if not (turned and rotate) then
        return nil
    end
    return rotate == "left" and 270 or 90
end

local PanelViewer = ImageViewer:extend{
    ui = nil,             -- the ReaderUI; UIManager:show does not set it
    page = nil,           -- the book page these steps came from
    -- **The things this viewer walks, in order.** A cropped panel in the first
    -- view; a window over the page in the second. The name says steps rather than
    -- panels because that is the one thing true of both, and because the second
    -- view's chain is not one entry per panel — a panel already on screen when the
    -- chain reaches it contributes none.
    steps = nil,
    -- The detector's panel rects for this page, kept only so that the button below
    -- can re-open the viewer on the same page: `steps` cannot be walked back to
    -- panels, since a window is not a panel and some panels contribute no step.
    panel_rects = nil,
    mode = nil,           -- "manga" | "comic"
    -- nil for the cropped sequence, or `{ window = true }` for the window view.
    -- Read here and in `meguruHandoff`, which must pass it on: the same trap
    -- `mode` and `rotate` carry a note about, and it fails only at a page boundary.
    view = nil,
    -- `{ dims, screen, scale }` in the free view, nil in the other two. Its presence is
    -- the mode switch for every override below: what it means is that this viewer walks
    -- no steps at all — one window, moved and scaled by the reader's own gestures.
    meguru_free = nil,
    -- "left" | "right" | nil — the book's `Rotate wide pages`, resolved by
    -- `ui/reader.lua` and handed in like `mode`. Not to be confused with the two
    -- rotation fields beside it: `rotated` (stock) is *whether*, and
    -- `meguru_rotates` is *whether*, per panel. This is the only one that knows
    -- a direction, and nil means the reader never asked for one — every
    -- rotation is then stock's, exactly as before this existed.
    rotate = nil,
    meguru_rotates = nil, -- per panel, from panelRotations above
    _meguru_warm = nil,   -- the pending pre-warm action, for unscheduling
    _meguru_handoff_pending = nil,
}

-- Hand a step's tile back to the document.
--
-- Called for the step just left and for the one on screen when the viewer closes,
-- which is what keeps the tile LRU at the two entries this design needs (the step
-- shown and the step warmed) rather than one per step visited. See
-- `MeguruDocument:releasePanelTile` for the arithmetic.
--
-- The size travels with the rectangle, because a window tile is filed under both:
-- releasing a window by its rectangle alone would free nothing.
function PanelViewer:meguruRelease(index)
    local doc = self.ui and self.ui.document
    local rect = self.steps and self.steps[index]
    if not (doc and rect and type(doc.releasePanelTile) == "function") then
        return false
    end
    return doc:releasePanelTile(self.page, rect, rect.out_w, rect.out_h)
end

-- Arm the pre-warm, replacing any warm still queued from the panel before.
function PanelViewer:meguruArmWarm()
    if self.meguru_free then
        -- Nothing to warm: there is no next step, and the page branch would fetch the
        -- next page's dims and panels — work for a page turn this view does not do.
        return
    end
    if self._meguru_warm then
        UIManager:unschedule(self._meguru_warm)
        self._meguru_warm = nil
    end
    local action = function()
        self:meguruWarm()
    end
    self._meguru_warm = action
    UIManager:scheduleIn(WARM_DELAY, action)
end

-- Warm what the reader is about to ask for.
--
-- Two targets, and the branch is the same question — "is there another panel
-- after this one". Mid-page it is the next panel, and the call that warms it is
-- the very call the viewer will make when the reader gets there, which is what
-- makes it a tile-cache hit rather than a second render. At the end of a page it
-- is the next page's decode *and* its panel detection, in that order, so the
-- boundary crossing pays for a page turn and a repaint and nothing else.
--
-- `pcall` on both: nothing is waiting on this, and a throw has to cost a warm,
-- not the reader. The buffer, if there is one, belongs to the document's LRU —
-- both return values are dropped.
function PanelViewer:meguruWarm()
    self._meguru_warm = nil
    if not UIManager:isWidgetShown(self) then
        return -- dismissed, or handed off to another page's viewer
    end
    local doc = self.ui and self.ui.document
    if not (doc and self.steps) then
        return
    end
    local cur = self._images_list_cur
    if cur < #self.steps then
        if not doc.dead_pages[self.page] then
            local next_step = self.steps[cur + 1]
            local ok, err = pcall(doc.drawPagePart, doc, self.page, next_step, 0,
                next_step.out_w, next_step.out_h)
            if not ok then
                logger.dbg("Meguru: panel prewarm failed:", err)
            end
        end
        return
    end
    -- The page branch needs a connection for the reason `analyseAhead`
    -- documents: offline, the fetch inside `getPageDims` would sit through its
    -- timeout with the UI thread blocked, which is worse than the stall it was
    -- avoiding. A local cbz has no bytes to fetch and says so through
    -- `hasConnection`.
    --
    -- **The two calls and their order are the whole point.** `getPageDims` is
    -- the decoder: it is what fills `self.dims` for the page. `getPanelsFromPage`
    -- prepares the page through `panelNativeFor`, which fetches and decodes but
    -- never touches `self.dims`, so calling it first would leave the dims cache
    -- empty and the page turn the reader is about to make would fetch the same
    -- page again. Dims first means one fetch, one decode, a native-LRU hit for
    -- the panel scan, and both memos filled — which is what makes the boundary
    -- crossing in `meguruHandoff` a cache hit rather than a scan inside a
    -- gesture. That is the entire reason the panel cache exists.
    --
    -- Note `max_cached_native` is 3: warming N+1 while N is live and N-1 may be
    -- too sits exactly on the cap, so backing up through the viewer can evict
    -- N-1's decode. That is the existing trade, not a new one.
    local next_page = doc:getNextPage(self.page)
    if next_page and next_page > 0 and not doc.dead_pages[next_page]
        and doc:hasConnection() then
        pcall(doc.getPageDims, doc, next_page)
        pcall(doc.getPanelsFromPage, doc, next_page, self.mode)
    end
end

-- Move to another panel: display it, hand the one left behind back, and re-arm
-- the warm for whatever is next to *it*.
--
-- Reassigning `self.rotated` here is also the whole of "a tapped rotation lasts
-- one panel": it overwrites the reader's press with the automatic decision on
-- **every** change, so the next panel — and coming back to this one later —
-- starts from the automatic answer without anything having to remember the press.
function PanelViewer:switchToImageNum(image_num)
    local previous = self._images_list_cur
    self.rotated = self.meguru_rotates[image_num] or false
    ImageViewer.switchToImageNum(self, image_num)
    if previous and previous ~= image_num then
        self:meguruRelease(previous)
    end
    self:meguruArmWarm()
end

-- Logged once per process: the window below closing is an upstream change, not a
-- per-zoom-step event, and a line per rebuild would bury everything else.
local panel_rotate_warned = false

-- Stock builds the ImageWidget with its own idea of the angle; this replaces the
-- angle, and only the angle, when the book has said which way to turn.
--
-- **Why this is a correction after the fact rather than an argument.** Stock has
-- no caller-facing direction input — `self.rotated` is a boolean and the 90-vs-270
-- choice is a local inside `ImageViewer:_new_image_wg`, computed from screen
-- parity and two KOReader globals. Passing a direction would mean copying that
-- body. It does not have to be copied, because `ImageWidget` defines no `init`
-- (`Widget:new` calls one only when it exists) and `_render` — the only reader of
-- `rotation_angle` — is entered from `getSize`/`paintTo` and returns at once when
-- `_bb` is already set, which nothing does before the first layout. So between
-- the widget's construction and `ImageViewer:update`'s first `resetLayout` the
-- angle is still unwritten, and setting it here is equivalent to having passed it.
--
-- The guard is that assumption made checkable. If upstream ever renders at
-- construction, the angle is missed, the panel turns stock's way, and the warning
-- says so once; the repair is a forked `_new_image_wg`, which is what this avoids.
function PanelViewer:_new_image_wg()
    ImageViewer._new_image_wg(self)
    local angle = panelRotationAngle(self.rotated, self.rotate)
    if not angle then
        return -- no direction from the book, or nothing to turn: stock's angle stands
    end
    if self._image_wg and not self._image_wg._bb then
        self._image_wg.rotation_angle = angle
        return
    end
    if not panel_rotate_warned then
        panel_rotate_warned = true
        logger.warn("Meguru: panel rotation angle could not be applied; "
            .. "ImageWidget rendered before _new_image_wg returned")
    end
end

-- The bound is `#self.steps`, **not** `self._images_list_nb` — see the note on
-- `images_list_nb = 1` in `PanelZoom.open`. Stock's field is the chrome switch and
-- no longer counts anything, so bounding navigation by it would send every
-- forward gesture to the page boundary.
function PanelViewer:onShowNextImage()
    if self.meguru_free then
        -- No steps to walk and no boundary to cross: page turning is off in this view,
        -- which is what its reader asked for. The hardware keys bound to this and to
        -- `onShowPrevImage` are therefore inert too.
        return true
    end
    if self._images_list_cur < #self.steps then
        self:switchToImageNum(self._images_list_cur + 1)
        return true
    end
    return self:meguruHandoff("next")
end

function PanelViewer:onShowPrevImage()
    if self.meguru_free then
        return true
    end
    if self._images_list_cur > 1 then
        self:switchToImageNum(self._images_list_cur - 1)
        return true
    end
    return self:meguruHandoff("previous")
end

function PanelViewer:onShow()
    self:meguruArmWarm()
    return ImageViewer.onShow(self)
end

-- The left and right thirds move through the panels; every other tap is stock.
--
-- Stock already does thirds, but it picks the sides from `BD.mirroredUILayout`
-- (see `nextIsRight`). Everything else is deliberately left to it: a tap outside
-- the frame closes the viewer, a middle tap toggles the button row, and on a
-- device without multitouch the bottom-left corner saves a screenshot — a
-- deliberate gesture this must not quietly take over.
function PanelViewer:onTap(arg, ges)
    if self.meguru_free then
        -- **A tap closes this view.** It has no thirds to walk and its row is permanent, so
        -- the gesture a reader reaches for first was doing nothing at all; closing is what
        -- stock's own viewer does with a tap outside its frame, and it is the way out that
        -- needs no aim. Moving the centre to the point tapped was tried first and was the
        -- wrong shape: it reads as a jump, and it needs the absolute mapping below to be
        -- right before it can be trusted at all.
        self:onClose()
        return true
    end
    if self._images_list and ges.pos:intersectWith(self.main_frame.dimen) then
        local screen_w = Screen:getWidth()
        if ges.pos.x < screen_w/3 or ges.pos.x > screen_w*2/3 then
            local screenshot_corner = not Device:hasMultitouch()
                and not self.buttons_visible
                and ges.pos.x < screen_w/10
                and ges.pos.y > Screen:getHeight()*9/10
            if not screenshot_corner then
                local tapped_right = ges.pos.x > screen_w*2/3
                if tapped_right == nextIsRight(self.mode) then
                    self:onShowNextImage()
                else
                    self:onShowPrevImage()
                end
                return true
            end
        end
    end
    return ImageViewer.onTap(self, arg, ges)
end

-- A horizontal swipe moves through the steps, but only while the step is at its
-- natural size.
--
-- Once the reader has pinched in, a horizontal drag is how they move around the panel
-- they are looking at, and taking that away to change panels would make zooming
-- useless. That is stock's own precedent for the swipe that closes the viewer, which
-- is gated on the same condition — and it holds in the window view too: a pinch there
-- magnifies the tile the reader is looking at, and panning it is what they asked for.
function PanelViewer:onSwipe(arg, ges)
    local direction = ges.direction
    if self.meguru_free then
        -- **The finger's own path, not the direction it was classified as**, and that is the
        -- difference between a drag that works and one that does not. The detector names a
        -- diagonal as a *compound* direction — `northwest`, `southeast` — and the four single
        -- names below can express neither that nor its two halves: a diagonal drag was moving
        -- one axis, and a compound one was moving nothing at all, because the chain fell through
        -- to the `return true` at the end. The event carries both ends of the gesture
        -- (`gesturedetector.lua:949-951`), so the movement is read directly and the direction is
        -- not consulted for it.
        --
        -- **Every direction pans, including south.** Stock closes the viewer on a swipe south
        -- while the picture is at best fit, because there is no use for panning then — but here
        -- there is: a vertical drag is how the reader moves the window, and the way out is Close
        -- in the row. The signs are stock's own, unchanged (the travel negated, as every one of
        -- its own callers passes it); which way the page then ends up moving is `panBy`'s to
        -- decide, and its note says why.
        local from, to = ges.pos, ges.end_pos
        if from and to and (to.x ~= from.x or to.y ~= from.y) then
            return self:panBy(from.x - to.x, from.y - to.y)
        end
        -- No path on this event — a build that stopped sending one, or a test that made one up.
        -- The four directions are the fallback, and they are everything this view could do
        -- before the path was read.
        local distance = ges.distance or 0
        if direction == "west" then
            return self:panBy(distance, 0)
        elseif direction == "east" then
            return self:panBy(-distance, 0)
        elseif direction == "north" then
            return self:panBy(0, distance)
        elseif direction == "south" then
            return self:panBy(0, -distance)
        end
        return true
    end
    if self.scale_factor == 0 and (direction == "west" or direction == "east") then
        local forward = (self.mode == "manga") and "east" or "west"
        if direction == forward then
            self:onShowNextImage()
        else
            self:onShowPrevImage()
        end
        return true
    end
    return ImageViewer.onSwipe(self, arg, ges)
end

-- The end of a page, in either direction.
--
-- The order of the four statements inside the tick is the whole of it:
--
--   1. the *next* page's panels are resolved **before** anything is dismissed,
--      so a page with no sequence leaves the reader where they were rather than
--      closing their viewer and giving them nothing;
--   2. the viewer is closed **before** the page turns. A page turn reaches
--      `installEndOfBookHook`, which at the end of a book swaps the whole
--      reader out — and a viewer still on the stack would float above a
--      different book entirely. Closing first makes that impossible by
--      construction rather than by a guard;
--   3. `GotoPage` and not `PageForward`. `GotoPage` is exact; `PageForward` is a
--      "next view", which is a page only because this plugin forces
--      `page_scroll` off. A boundary crossing should not rest on a setting the
--      plugin is fighting;
--   4. the new viewer is built after the turn, against the layout that resulted
--      — including any wide-page screen rotation the reader applies.
--
-- The whole body is `pcall`ed because a throw inside `UIManager:run` takes the
-- reader with it, and `tickAfterNext` means nothing is waiting on the answer.
function PanelViewer:meguruHandoff(direction)
    if self._meguru_handoff_pending then
        return true
    end
    local ui = self.ui
    local doc = ui and ui.document
    if not doc then
        return true
    end
    local page = (direction == "next") and doc:getNextPage(self.page)
        or doc:getPrevPage(self.page)
    if not page or page == 0 then
        return true -- nothing that way: stay where we are, like stock does
    end
    self._meguru_handoff_pending = true

    local this = self
    local mode = self.mode
    -- Read here, beside `mode` and outside the tick, for the same reason: the
    -- viewer this is handed off from may be gone by the time the tick runs. The
    -- next viewer would otherwise be built with no direction and silently turn
    -- stock's way — and only at a page boundary, which is the one place nobody
    -- looks.
    local rotate = self.rotate
    -- The view travels for the third time and for the same reason — and with one
    -- part dropped: the tap that opened *this* page says nothing about the next
    -- one, so a fresh page starts at its first panel's own arrival rather than
    -- centred on a point of a page nobody is looking at. The level the reader chose
    -- travels with it, so a page boundary does not quietly put the zoom back.
    local view = self.view and {
        window = self.view.window,
        level = self.view.level,
    } or nil
    -- Read outside the tick with `mode` and `rotate`, for the same reason: the viewer
    -- this is handed off from is closed before the new one is built.
    local show_buttons = self.buttons_visible
    UIManager:tickAfterNext(function()
        local ok, err = pcall(function()
            if not UIManager:isWidgetShown(this) then
                return
            end
            -- The next page's panels are cut from its decoded buffer, and that
            -- buffer may not exist yet — asking for it here would be a
            -- synchronous HTTP fetch inside a UI tick, which is the one thing
            -- this plugin keeps out of the interactive path. Offline, the
            -- crossing still turns the page and the panel viewer simply does
            -- not reopen; the reader is on the right page either way, and
            -- Meguru's own page-error painting says why it is empty. Same gate,
            -- and the same reasoning, as `analyseAhead` and the page warm.
            local panels, reason
            -- **`accepted` needs a local of its own here, and that is not tidiness.**
            -- This used to be `panels, _, reason = ...`, and `_` is this file's
            -- gettext — a plain assignment with no `local` writes straight through to
            -- it, so the next button label built in this file was a call on a boolean.
            -- The line is older than the `_(...)` that found it out, which is why
            -- nothing noticed until the window view's button row existed. Discarding a
            -- value needs a name nothing else uses; `check.py` now says so.
            local accepted
            if doc:hasConnection() then
                -- `accepted` is not interesting here: a page the detector
                -- refused opens the whole page as one panel, and a crossing is a
                -- crossing either way. Only a page that would not decode has no
                -- panels at all, and that is what the `else` log line says.
                panels, accepted, reason = doc:getPanelsFromPage(page, mode)
            else
                reason = "no connection"
            end
            UIManager:close(this)
            ui:handleEvent(Event:new("GotoPage", page))
            if panels then
                local index = (direction == "next") and 1 or #panels
                -- **Coming back, the reader arrives at the page from below it**, so the
                -- page's last panel is entered at its *end* — the corner nearest where
                -- they came from — and going forward the first panel is entered at its
                -- start. Same call, one flag, and it is a flag on this call rather than
                -- on the carried view: it describes the crossing, not the reader's
                -- settings, and the step after them must not inherit it.
                local opts = view and {
                    window = view.window,
                    level = view.level,
                    at_end = direction == "previous",
                    -- The row stays where the reader left it, for the same reason the
                    -- zoom button keeps it: a boundary crossing is not a reason to take
                    -- the buttons out from under a finger that was just using them.
                    buttons_visible = show_buttons,
                } or nil
                PanelZoom.open(ui, page, panels, index, mode, rotate, opts)
            else
                -- Only reachable when the page would not decode: a page the
                -- detector refused comes back as the whole page, so the
                -- crossing still opens a viewer on it.
                logger.dbg("Meguru: panel zoom crossed to page", page,
                    "with no page to show:", tostring(reason))
            end
        end)
        if not ok then
            logger.warn("Meguru: panel handoff failed:", err)
        end
    end)
    return true
end

function PanelViewer:onCloseWidget()
    if self._meguru_warm then
        UIManager:unschedule(self._meguru_warm)
        self._meguru_warm = nil
    end
    -- **The free view's zoom is remembered here, once, rather than where it changes.**
    -- `Settings.set` flushes — it is a write to the card — and this zoom changes on every
    -- pinch and every drag, so remembering it where it moves would be a disk write per
    -- gesture event. Closing is where the reader's answer is final, and it happens once
    -- per viewer whether they close it, switch views, or let a page boundary take it.
    if self.meguru_free then
        Settings.set("free_zoom_scale", self.meguru_free.scale)
    end
    -- Stock first: it may still touch the ImageWidget holding this panel's
    -- bytes, and the bytes are freed a line later.
    ImageViewer.onCloseWidget(self)
    self:meguruRelease(self._images_list_cur)
end

-- The levels the button cycles, in the order it cycles them. Written here and read by
-- nothing else: the preference stores whichever one the reader landed on, and the
-- geometry is handed the scale that comes of it.
local ZOOM_LEVELS = { 1.4, 1.7, 1.9 }

-- The next level above `level`, wrapping back to the first, from a given list.
--
-- **It walks *up* from wherever the reader is rather than looking the value up**, and that
-- stopped being a style choice the moment `-`/`+` existed in either view: they leave levels
-- that are on no list, so a lookup would miss and drop the reader at the bottom of the cycle
-- — 1.8 would answer 1.4. Past the top it starts again, which is what a cycle does.
--
-- One function for both views' lists, because the two buttons differ in their numbers and not
-- in this rule — see `freeStepAfter` below.
local function levelAfter(list, level)
    for i = 1, #list do
        if list[i] > level + 0.001 then
            return list[i]
        end
    end
    return list[1]
end

-- The three levels the zoom button cycles, and **levels only**: a preset is a multiple of the
-- fit, while Original is a *scale* — one page pixel to one screen pixel — so a list holding both
-- would hold two units and a reader asked for the levels alone. Original is not lost with it:
-- a pinch reaches that scale, and the label says so when it does. See `meguru/settings` for the
-- scale this view remembers across opens.
local FREE_LEVELS = { 1.5, 2, 2.5 }

-- The fine control: how far one press of `-` or `+` moves, and the range it moves in.
-- Separate from the list above, because the two answer different questions — the list is what
-- the zoom button *cycles*, Original included, and this is what a reader nudges with. It steps
-- from wherever they are rather than snapping to the list, which is why 2.4x goes to 2.65x, and
-- the range starts at the fit itself, so the whole page is the bottom of it. The ceiling is the
-- one `Viewport.scaleBounds` uses, so the buttons cannot outrun a pinch.
local FREE_STEP = 0.25
local FREE_MIN_LEVEL = 1
local FREE_MAX_LEVEL = 4

-- The window view's fine control: the same two buttons as the free view's above, and
-- **deliberately not the same numbers**. That range is bounded by `Viewport.scaleBounds`
-- because a pinch has to stay inside it; this view has no pinch, so its range is a choice.
-- The step is 0.1, which is what a reader asked for: a nudge rather than the jump between
-- presets that the value button beside these two makes.
--
-- **The ceiling is the top of `ZOOM_LEVELS`**, so the two controls agree on where the view
-- ends: `+` stops where the cycle stops, and a reader can never be at a level the value
-- button would answer by jumping back down to the bottom of the cycle. The floor is the fit,
-- where the window is the whole page and `-` reaches it.
local WINDOW_STEP = 0.1
local WINDOW_MIN_LEVEL = 1
local WINDOW_MAX_LEVEL = ZOOM_LEVELS[#ZOOM_LEVELS]

-- The next level above a scale, wrapping back to the first, as a scale.
local function freeStepAfter(scale, fit)
    return levelAfter(FREE_LEVELS, scale / fit) * fit
end

-- What the zoom button says: `1x` for the file's own pixels, a multiple of the fit otherwise.
--
-- **The two are different units in one row, and that is deliberate.** The levels are levels —
-- 1.5x is one and a half times the fitted page — while 1:1 is one page pixel to one screen
-- pixel and cannot be written as a level at all. A reader asked for the word every other image
-- viewer uses for that scale, and `1x` is it; the alternative, spelling out the ratio, was
-- longer and still needed to be read.
--
--- **Two decimals at most, and a trailing zero dropped**, which a step of a quarter is what asked
--- for: `%.1f` would print 1.75 as `1.8×` — a label lying by five hundredths about the one number
--- it exists to report — and `%.2f` alone would print a level of 1.7 as `1.70×`. The zero is the
--- only thing dropped, so `2.0×` keeps its decimal and reads like the levels beside it.
local function freeLabel(scale, fit)
    if math.abs(scale - 1) < 0.001 then
        return "1×"
    end
    local text = string.format("%.2f", scale / fit):gsub("0$", "")
    return text .. "×"
end

-- The fit the free view's *levels* are measured against: the content's width on the screen's,
-- which is the same measure every other view's levels use.
--
-- **`free.dims` is the page and this is the content, and they are two different things.** The
-- dims are what the window is clamped to, so the reader can pan onto a margin; the fit is what
-- a level is a multiple of, so a margin is not in the denominator. One field could not be both,
-- and using the page's dims for the levels is a bug that shows as a button reading one level
-- while the picture sits at another — which is why every reader of the fit goes through here
-- rather than calling `fitScale` on whatever dims it happens to have to hand.
local function freeFit(free)
    return Viewport.fitScale(free.content or free.dims, free.screen)
end

-- Where the page is actually drawn, and how big one page pixel is on the glass.
--
-- **None of this is the screen's own while the button row is up.** The row takes a strip of
-- the screen, so the tile is drawn in what is left of it and best fit scales the tile to fit
-- *that* — a little under 1:1, and shifted up by half the strip. Distances *between* two
-- screen points are immune to where the picture sits, which is why dragging felt right while
-- a tap, and a spread's about-point, landed somewhere else: those are the two conversions
-- that need an absolute origin, and the screen's corner is not it.
function PanelViewer:meguruFreeMapping()
    local cur = self.steps and self.steps[1]
    if not cur then
        return nil
    end
    local padding = self.image_padding or 0
    local w = (self.width or Screen:getWidth()) - 2 * padding
    local h = (self.img_container_h or Screen:getHeight()) - 2 * padding
    local fit = math.min(w / cur.out_w, h / cur.out_h, 1)
    return fit,
        padding + (w - cur.out_w * fit) / 2,
        padding + (h - cur.out_h * fit) / 2
end

-- The page point under a screen point, or nil before the first layout.
function PanelViewer:meguruFreePageAt(pos)
    local free = self.meguru_free
    local cur = free and self.steps and self.steps[1]
    local fit, x0, y0 = self:meguruFreeMapping()
    if not (cur and fit and pos) then
        return nil
    end
    local drawn = free.scale * fit
    return cur.x + (pos.x - x0) / drawn, cur.y + (pos.y - y0) / drawn
end

-- The free view's window: where it is, how close it is, and the one place either moves.
--
-- **The step is mutated in place, and that is not an optimisation.** Each step's image is
-- a lazy closure over the step table, and `ImageViewer` resolves it through
-- `switchToImageNum`, which returns early when the number has not changed. Writing the
-- new rectangle into the same table and calling `update()` is what makes the closure see
-- it; a fresh table would be a step nobody re-resolves.
--
-- The tile LRU follows from the same place: a window is keyed by its rectangle *and* its
-- output size, so returning to a scale the reader was at before is a cache hit rather
-- than a second render.
function PanelViewer:meguruFreeWindow(scale, cx, cy)
    local free = self.meguru_free
    local cur = free and self.steps and self.steps[1]
    if not cur then
        return false
    end
    local lo, hi = Viewport.scaleBounds(free.dims, free.screen, free.content)
    free.scale = math.max(lo, math.min(hi, scale))
    local step = Viewport.windowAt(free.dims, free.screen, free.scale, cx, cy)
    if not step then
        return false
    end
    for key, value in pairs(step) do
        cur[key] = value
    end
    -- **`self.image` is what the paint reads, and `update()` never re-resolves it** — it
    -- only rebuilds the widget around whatever is in that field. A step change refreshes it
    -- by resolving the new *entry*, which is why the other two views move; this view changes
    -- the rectangle under one entry, so it has to resolve that entry again itself and put the
    -- result where the paint will look. Without this the label moved and the picture did not,
    -- which is exactly what a reader reported. A render that fails leaves the old buffer
    -- alone: a stale picture is better than a blank one.
    local entry = self._images_list and self._images_list[self._images_list_cur]
    if type(entry) == "function" then
        local image = entry()
        if image then
            self.image = image
        end
    end
    -- The reader's own zoom is remembered — but **not here**: `Settings.set` flushes, and
    -- this runs on every pinch and every drag. It is written once, in `onCloseWidget`, and
    -- the label is what carries the live value until then.
    self:meguruFreeLabel()
    self:update()
    return true
end

-- Re-letter the zoom button, which is the only place the current scale is written down.
function PanelViewer:meguruFreeLabel()
    local free = self.meguru_free
    local buttons = self.button_table
    local button = buttons and type(buttons.getButtonById) == "function"
        and buttons:getButtonById("zoom_level")
    if free and type(button) == "table" then
        button:setText(freeLabel(free.scale, freeFit(free)), button.width)
    end
end

-- Pan by a number of *screen* pixels, whatever gesture asked for it.
--
-- `ImageViewer:panBy` is the one seam every panning gesture in stock goes through —
-- `onSwipe`, `onCursorPan`, `onHoldRelease` and `onPanRelease` all end here — so the free
-- view gets its panning by answering this one call, with stock's own signs.
--
-- **The window moves the way stock's argument says, and the picture therefore moves the way
-- it does not** — which is the half that has to be got right, because it is the difference
-- between a touchscreen and a trackpad. Stock's `panBy(x, y)` moves the *image* by `(x, y)`,
-- and every one of its callers passes the finger's travel negated: a swipe west (`x_diff < 0`
-- in `gesturedetector.lua:331`, so the finger went left) arrives here as `panBy(+distance)`,
-- and a drag right arrives as `panBy(-travel)`. So the picture there always moves *against*
-- the finger, which is a swipe's feel and not a drag's.
--
-- Following the argument into the window — the picture and the window move opposite ways —
-- would therefore land the page against the finger as well, and a reader reported exactly
-- that: "panning works backwards". So the window takes the argument **as it stands**: the
-- picture it shows moves the other way, which is with the finger, and both of stock's calling
-- conventions reach the same place without either of them being second-guessed.
function PanelViewer:panBy(x, y)
    local free = self.meguru_free
    local cur = free and self.steps and self.steps[1]
    if not cur then
        return ImageViewer.panBy(self, x, y)
    end
    local fit = self:meguruFreeMapping()
    local drawn = free.scale * (fit or 1)
    return self:meguruFreeWindow(free.scale,
        cur.x + cur.w / 2 + x / drawn,
        cur.y + cur.h / 2 + y / drawn)
end

-- A pinch or a spread: the scale they ask for, about the point they happened at.
--
-- Stock's own arithmetic is `ges.distance / min(screen, image)` — how far the fingers
-- travelled over the smaller of the screen and the picture. Every tile in this view *is*
-- the screen's size, so the denominator is simply the screen's dimension along the
-- gesture, and the feel stays stock's. What cannot be borrowed is the rest: stock's
-- `onZoomIn`/`onZoomOut` multiply `self.scale_factor`, and that same field is what
-- `ImageWidget` scales the tile by — so the view keeps its own scale and leaves the field
-- at best fit, which is what lets the tile stay a render *of the page*.
--
-- A spread zooms about the point under the fingers, as stock does; a pinch keeps the
-- centre, which stock also does and says why.
function PanelViewer:meguruFreeZoom(ges, closer)
    local free = self.meguru_free
    local cur = free and self.steps and self.steps[1]
    if not cur or not ges then
        return false
    end
    local dim
    if ges.direction == "vertical" then
        dim = free.screen.h
    elseif ges.direction == "horizontal" then
        dim = free.screen.w
    else
        dim = math.sqrt(free.screen.w ^ 2 + free.screen.h ^ 2)
    end
    local amount = (ges.distance or 0) / dim
    local target = free.scale * (closer and (1 - amount) or (1 + amount))
    local cx, cy = cur.x + cur.w / 2, cur.y + cur.h / 2
    if not closer and ges.pos then
        -- Whatever page point is under the fingers stays under them: the window's centre
        -- moves by the difference between where that point sat at the old scale and where
        -- it sits at the new one. The point itself comes from `meguruFreePageAt`, because
        -- the screen's own centre is not where the picture is.
        local lo, hi = Viewport.scaleBounds(free.dims, free.screen, free.content)
        local scale = math.max(lo, math.min(hi, target))
        local px, py = self:meguruFreePageAt(ges.pos)
        if px then
            cx = cx + (px - cx) * (1 - free.scale / scale)
            cy = cy + (py - cy) * (1 - free.scale / scale)
        end
        target = scale
    end
    return self:meguruFreeWindow(target, cx, cy)
end

function PanelViewer:onPinch(arg, ges)
    if self.meguru_free then
        return self:meguruFreeZoom(ges, true)
    end
    return ImageViewer.onPinch(self, arg, ges)
end

function PanelViewer:onSpread(arg, ges)
    if self.meguru_free then
        return self:meguruFreeZoom(ges, false)
    end
    return ImageViewer.onSpread(self, arg, ges)
end

-- Move the zoom on to the next preset, from wherever the reader is.
function PanelViewer:meguruCycleFreeZoom()
    local free = self.meguru_free
    local cur = free and self.steps and self.steps[1]
    if not cur then
        return
    end
    local fit = freeFit(free)
    logger.dbg("Meguru: free zoom", freeLabel(freeStepAfter(free.scale, fit), fit),
        "on page", self.page)
    self:meguruFreeWindow(freeStepAfter(free.scale, fit), cur.x + cur.w / 2,
        cur.y + cur.h / 2)
end

-- One press of `-` or `+`: a quarter of a level, inside the range the buttons work in.
--
-- It moves from wherever the reader *is* rather than snapping to the cycle button's list, so
-- a pinch to 2.4x answers `+` with 2.65x — nudging what they are looking at instead of throwing
-- it to the nearest preset. The level is the unit here because that is what a reader reads off
-- the button — and the bottom of the range is the fit, so `-` reaches the whole page. The
-- window is then built from the scale that level means on this page.
function PanelViewer:meguruFreeStepZoom(direction)
    local free = self.meguru_free
    local cur = free and self.steps and self.steps[1]
    if not cur then
        return
    end
    local fit = freeFit(free)
    local level = free.scale / fit + direction * FREE_STEP
    level = math.max(FREE_MIN_LEVEL, math.min(FREE_MAX_LEVEL, level))
    -- Logged because these are the gestures a reader reports on, and a line per *button press*
    -- is a deliberate act rather than the per-event chatter a pinch would be. If a press says
    -- `2.0x` here and the picture does not move, the fault is downstream of the zoom; if there
    -- is no line at all, the press never reached this view.
    logger.dbg("Meguru: free zoom", freeLabel(level * fit, fit), "on page", self.page)
    self:meguruFreeWindow(level * fit, cur.x + cur.w / 2, cur.y + cur.h / 2)
end

-- Re-open the window view at a level, keeping the reader's place and the row.
--
-- **The remembered part is the whole point.** The level is a preference, so a reader
-- who likes 1.9 gets 1.9 on the next page, the next book and the next start — and
-- setting it from here rather than from a menu row is what lets them see what it does
-- while looking at the page it does it to. The value is written through
-- `meguru/settings` directly because it is a plain preference with no cascade behind
-- it; the *reading* side is still `ui/reader`'s, which passes the number in.
--
-- The switch itself is a close-and-reopen, the same shape the rest of this file uses
-- for anything that changes the step list: the reader's place is the **corner of the window
-- they are on**, handed over as `opts.keep`, and `Viewport.stepNearest` finds that same
-- corner again in the walk the new level produces. It used to be a *point* the view was
-- re-opened on; a point stopped being enough when a named panel began opening at its own
-- first stop rather than at the one built around the finger, and the corner is the better
-- thing to carry anyway — it is what the stops are anchored to, so it survives a scale
-- change instead of approximating it.
--
-- **Both buttons come through here** — the cycle and the `-`/`+` pair — so that a step
-- and a cycle cannot come to re-open differently, which is the kind of drift that shows
-- as one of them losing the reader's place and the other not.
function PanelViewer:meguruReopenAtLevel(level)
    local view = self.view
    local cur = self.steps and self.steps[self._images_list_cur]
    -- Read before anything is closed: the viewer this is called from is gone by the
    -- time the next statement's work is done, which is the same reason `meguruHandoff`
    -- reads `mode` and `rotate` outside its tick.
    local panels = self.panel_rects
    local ui, page = self.ui, self.page
    local mode, rotate = self.mode, self.rotate
    local show_buttons = self.buttons_visible
    if not (view and view.window and cur and panels and ui) then
        return
    end
    Settings.set("panel_zoom_level", level)
    UIManager:close(self)
    -- **`pcall`ed, and that is about the *next* event rather than this one.** By now the old
    -- viewer is gone, so a throw out of the open would leave the reader with nothing — but it
    -- would also leave a viewer that was built and never painted, and that is the half that
    -- bites later: `ImageViewer:update` pushes its repaint closure onto `UIManager`'s refresh
    -- stack, which is a plain list and **not keyed by widget**, so closing the viewer does not
    -- take the closure with it. The closure reads `main_frame.dimen`, which a viewer that was
    -- never painted has not got, and the next repaint dies on it — `imageviewer.lua:384`,
    -- `attempt to index field 'dimen'`, one event away from whatever threw. See
    -- docs/known-issues.md.
    local ok, err = pcall(PanelZoom.open, ui, page, panels, cur.panel, mode, rotate, {
        window = true,
        level = level,
        -- The reader's place is the corner of the window they are on, and `keep` is what
        -- carries it across the new walk: a level change rebuilds the stops, so an index
        -- would not survive it and the panel's first stop would be a jump to the top of a
        -- panel they were halfway down. See `Viewport.stepNearest`.
        keep = { x = cur.x, y = cur.y },
        -- **The row stays open, which is the whole point of pressing this button.** A
        -- reader comparing two levels would otherwise have to middle-tap to get the
        -- buttons back between every pair — and this button can only be pressed while
        -- the row is up, so carrying its state through is what makes a second press
        -- possible at all.
        buttons_visible = show_buttons,
    })
    if not ok then
        logger.warn("Meguru: the window view could not be re-opened:", err)
    end
end

-- Move the zoom on to the next preset of the cycle, and remember it.
function PanelViewer:meguruCycleZoomLevel()
    local level = self.view and self.view.level
    if level then
        self:meguruReopenAtLevel(levelAfter(ZOOM_LEVELS, level))
    end
end

-- Nudge the zoom by one step, and remember it.
--
-- The unit is the *level* and not the scale, because a level is what the button between these
-- two reads off and what the preference stores; the geometry is handed the scale that comes of
-- it, as everywhere else here. It moves from wherever the reader is rather than snapping to the
-- cycle's list, so 1.8 answers `+` with 1.9.
--
-- **Two lines of that are load-bearing and neither is tidiness.** The rounding to one decimal
-- is what keeps `-`/`+` and the cycle button agreeing: 1.7 + 0.1 is 1.7999999999999998 in
-- binary, which `levelAfter` would miss. And the clamp is what stops a held finger marching the
-- window down to a sliver of a page, or in past a level the geometry still has an answer for.
--
-- Logged because these are the gestures a reader reports on, and a line per *button press* is a
-- deliberate act rather than the per-event chatter a pinch would be — the same argument the
-- free view's stepper makes.
function PanelViewer:meguruStepZoomLevel(direction)
    local view = self.view
    local level = view and (view.level or WINDOW_MIN_LEVEL)
    if not level then
        return
    end
    local current = level
    level = level + direction * WINDOW_STEP
    level = math.floor(level * 10 + 0.5) / 10
    level = math.max(WINDOW_MIN_LEVEL, math.min(WINDOW_MAX_LEVEL, level))
    -- **A press that changes nothing does nothing**, and that is not tidiness: the re-open
    -- below is a teardown and a fresh viewer, so a no-op press would pay a whole close, a
    -- rebuild and a repaint to arrive at the page already on screen. It is also the press a
    -- reader leaning on the button makes most — at the top and bottom of the range, where the
    -- clamp has just swallowed the step.
    if level == current then
        return
    end
    logger.dbg("Meguru: panel zoom", string.format("%.1f×", level), "on page", self.page)
    self:meguruReopenAtLevel(level)
end

-- Show the same page the way the next view shows it.
--
-- Three views now, so this cycles rather than toggles: cropped panels, the window over
-- the page, and the free one. The same close-and-reopen as the zoom button, and for the
-- same reason: what changes is how the page is cut up, which is a different step list,
-- and the reader's place has to survive it. Their place is a *panel* — the crop view's
-- step list is the panel list, so its step index is a panel index, and the window view
-- carries the panel each of its windows belongs to — and a point to re-enter the two
-- window-shaped views at, which is the middle of whatever they are looking at.
--
-- The preference is written here for the same reason the level is: it is a plain
-- preference with no cascade, and the menu's *Panel view* row reads and writes the same
-- one, so the two controls cannot disagree.
function PanelViewer:meguruCycleView()
    local view = self.view
    local cur = self.steps and self.steps[self._images_list_cur]
    -- Read before the close, like the zoom button and the handoff: the viewer this was
    -- called from is gone by the time the call that follows has done anything.
    local panels = self.panel_rects
    local ui, page = self.ui, self.page
    local doc = ui and ui.document
    local mode, rotate = self.mode, self.rotate
    if not (view and cur and ui and doc) then
        return
    end
    local kind = self.meguru_free and "zoom" or (view.window and "window" or "crop")
    kind = ({ crop = "window", window = "zoom", zoom = "crop" })[kind]
    -- **The free view has no panels to hand over**, because it never asked the detector —
    -- that is the whole point of a view that walks no steps. Leaving it for either *panel*
    -- view therefore needs them asked for now, and asked for **before** anything is
    -- closed: a page whose panels cannot be had would otherwise take the viewer down and
    -- give the reader nothing in its place. Same order as `meguruHandoff`, same reason.
    if not panels and kind ~= "zoom" then
        local ok, got = pcall(doc.getPanelsFromPage, doc, page, mode)
        panels = ok and got or nil
        if not panels then
            logger.info("Meguru: cannot leave the free view for", kind,
                "- no panels for page", page)
            return
        end
    end
    Settings.set("panel_view", kind)
    -- Which panel the reader is on, read from the *old* view's shape: the crop view's
    -- step list is the panel list, so its step index is the panel index, while a step in
    -- either window-shaped view carries the panel it belongs to. The free view has none,
    -- and nothing on the way out of it needs one.
    local panel
    if not self.meguru_free then
        panel = view.window and cur.panel or self._images_list_cur
    end
    UIManager:close(self)
    -- pcall'd for the reason `meguruReopenAtLevel` spells out: a viewer built and never
    -- painted leaves `ImageViewer:update`'s repaint closure on a stack that closing does not
    -- reach, and the next repaint dies reading a `main_frame.dimen` that was never laid out.
    local ok, err = pcall(PanelZoom.open, ui, page, panels, panel, mode, rotate, {
        window = kind == "window",
        free = kind == "zoom",
        level = view.level,
        buttons_visible = true,
        -- Both window-shaped views are told where the reader already was, and each reads the
        -- half it needs: the free one opens *centred* on the point, the window one opens at
        -- the stop nearest the corner. The cropped view has no place of its own — its step
        -- index is a panel index, which is what `panel` above already carried.
        tap = kind ~= "crop" and { x = cur.x + cur.w / 2, y = cur.y + cur.h / 2 } or nil,
        keep = kind == "window" and { x = cur.x, y = cur.y } or nil,
    })
    if not ok then
        logger.warn("Meguru: the next view could not be opened:", err)
    end
end

-- The row, and it has two shapes: one per view, because what is worth a button differs.
--
-- **Pan & Zoom** holds the zoom and Close. Stock's *Scale / Original size* sets the
-- *viewer's* scale factor — one image pixel to one screen pixel — and every step in this
-- view is already a screen-sized render shown at best fit, so it changed nothing while
-- its label promised something else; *Rotate* turns a picture, and nothing turns here,
-- since a window is the screen's shape and a panel too wide for it is walked side to
-- side. What a reader of this view actually wants to change is how close the window
-- sits, so that is what the row holds.
--
-- **Panel Cut keeps stock's three**, because there they mean what they say: the
-- tile is the panel at its own size, so Original size is the panel's own pixels, and a
-- wide panel is one a Rotate can turn. They are *forwarded* rather than re-implemented —
-- `Button` calls `self.callback`, so the existing objects are read out of the table
-- before it is replaced and their callbacks passed straight back in. Nothing of
-- upstream's logic is copied, and upstream's own `update` re-letters them by id, so
-- their labels stay true.
--
-- Both shapes carry the view switch, which writes the same preference the *Panel view*
-- row in the menu does.
--
-- Stock builds the table inside `init` and has no way to take a button out of one, so
-- the table and its container are rebuilt — both stock's own widgets, with stock's own
-- shape. Two details are load-bearing:
--
--   * **`update` has to run afterwards.** `init` builds `main_frame` and calls
--     `update()` itself, before any of this, so the frame it built holds *stock's*
--     container; `ImageViewer:onShow` does not rebuild it, so a viewer that opens with
--     the row already visible — which is every re-open — would paint stock's row. The
--     reader's middle tap is what hid that until now: it calls `update()` after the
--     swap, so a row summoned by hand was always the right one.
--   * **`update` also re-letters `scale` and `rotate` by id without checking that they
--     are there**, so a row without them is a nil call inside a paint. They are answered
--     by seeding `button_by_id` — the map those lookups read — with a plain table that
--     has the two fields stock touches. Not a Button: that was the only widget this file
--     built itself on this path, and it is not needed to swallow `setText`.
--
-- Guarded like the rest of this file: if the table is not where it was, the row stays
-- stock's and the warning says so once.
local buttons_warned = false

local function installRow(viewer)
    if type(viewer.button_table) ~= "table" then
        if not buttons_warned then
            buttons_warned = true
            logger.warn("Meguru: the viewer's button table was not found; "
                .. "the panel view keeps stock's row")
        end
        return false
    end
    local free = viewer.meguru_free ~= nil
    local window = not free and viewer.view and viewer.view.window
    -- `or 1` for the same reason the scale's own arithmetic uses it: a caller that
    -- hands no level means fit-to-screen, and the label should say what the view does.
    local level = (viewer.view and viewer.view.level) or 1
    local close = {
        id = "close",
        text = _("Close"),
        callback = function()
            viewer:onClose()
        end,
    }
    local switch = {
        id = "view",
        -- **The label names the view the reader is *in*.** It is the shape the zoom
        -- button beside it already has — that one shows the level it is on — and the
        -- shape the menu's *Panel view* row has, so the two controls and the row all
        -- name the same thing rather than one of them naming the destination. With three
        -- views it also has to cycle rather than toggle.
        text = free and _("Free View")
            or (window and _("Pan & Zoom") or _("Panel Cut")),
        callback = function()
            viewer:meguruCycleView()
        end,
    }
    local entries = { switch }
    if free then
        -- The free view's zoom is three buttons: `-`, the value, `+`. The value is the one
        -- that *cycles* — through the presets and Original, which is a scale and not a level
        -- and so is unreachable by stepping — while the two beside it nudge by a quarter
        -- and stop at the ends of the range.
        entries[#entries + 1] = {
            id = "zoom_out",
            text = "-",
            callback = function()
                viewer:meguruFreeStepZoom(-1)
            end,
        }
        entries[#entries + 1] = {
            id = "zoom_level",
            text = freeLabel(viewer.meguru_free.scale,
                freeFit(viewer.meguru_free)),
            callback = function()
                viewer:meguruCycleFreeZoom()
            end,
        }
        entries[#entries + 1] = {
            id = "zoom_in",
            text = "+",
            callback = function()
                viewer:meguruFreeStepZoom(1)
            end,
        }
        entries[#entries + 1] = close
    elseif window then
        -- The same three buttons the free view has, and for the same reason: the value *cycles*
        -- through the presets, while `-` and `+` nudge from wherever the reader is — which is
        -- the only way to reach a level between them, and the reader asked for this one to move
        -- by a tenth. The label is `%.1f` rather than `tostring` because the levels are now
        -- arbitrary tenths and a raw double would print seventeen digits of one.
        entries[#entries + 1] = {
            id = "zoom_out",
            text = "-",
            callback = function()
                viewer:meguruStepZoomLevel(-1)
            end,
        }
        entries[#entries + 1] = {
            id = "zoom_level",
            text = string.format("%.1f×", level),
            callback = function()
                viewer:meguruCycleZoomLevel()
            end,
        }
        entries[#entries + 1] = {
            id = "zoom_in",
            text = "+",
            callback = function()
                viewer:meguruStepZoomLevel(1)
            end,
        }
        entries[#entries + 1] = close
    else
        -- **Rotate, and not the Scale / Original size button beside it.** What that one sets is
        -- the *viewer's* `scale_factor` — one image pixel to one screen pixel — and every step in
        -- this view is a panel rendered at the panel's own size and shown at best fit, so it
        -- scaled a picture that was already fitted and its label promised a size the panel never
        -- took. It was removed from this row for the same reason it was removed from the window
        -- one; that row's own note carries the argument, and this view is where it applies most
        -- directly, because a panel *is* the size the row was claiming to change.
        --
        -- The button is forwarded rather than re-implemented, so the reader gets stock's own
        -- object with stock's own callback. See the sink below for the half of that which is not
        -- optional: stock re-letters this button by id.
        local rotate_button = viewer.button_table:getButtonById("rotate")
        if rotate_button then
            entries[#entries + 1] = {
                id = "rotate",
                text = rotate_button.text,
                callback = rotate_button.callback,
            }
        end
        entries[#entries + 1] = close
    end

    local table_ = ButtonTable:new{
        width = viewer.width - 2 * viewer.button_padding,
        buttons = { entries },
        zero_sep = true,
        show_parent = viewer,
    }
    -- **`ImageViewer:update` re-letters the buttons it expects by id and does not check that they
    -- are there** — a nil call inside a paint, which is a crash rather than a wrong label. The map
    -- those lookups read is seeded with a sink for every button this row does not carry: both of
    -- them in the two views that have neither, and only `scale` in the cropped one, where
    -- `rotate` is a real button and seeding it would leave the label stock keeps truthful
    -- pointing at a sink instead.
    local sink = { width = 0, setText = function() end }
    if window or free then
        table_.button_by_id.scale = sink
        table_.button_by_id.rotate = sink
    else
        table_.button_by_id.scale = sink
    end
    viewer.button_table = table_
    viewer.button_container = CenterContainer:new{
        dimen = Geom:new{
            w = viewer.width,
            h = table_:getSize().h,
        },
        table_,
    }
    -- The frame `init` built holds the old container; this is what puts the new one in
    -- it. Safe because it is the call stock's own `init` ends with.
    viewer:update()
    return true
end

-- The page's content box, as a **size** — what the two window-shaped views compute their zoom
-- against.
--
-- **The zoom is worked out from the content and the window is still the whole page**, and that
-- distinction is the whole design. A level then buys the same magnification whatever white
-- border the scanner left — a tenth of the page given away to margins is a tenth of the
-- magnification lost, and at 1.0 the window covers the content rather than the content plus its
-- paper — *without* taking the margin away from the reader: the window is still clamped to the
-- page, so it can be moved there, and a panel whose edge sits in the margin still anchors to
-- it. This replaced a version that measured **in** the box, moving panels and touch points into
-- it and the steps back out; that one made the margins unreachable and put every step one
-- origin mistake away from naming the wrong rectangle.
--
-- **Nothing here is rewritten into another coordinate space**, which is also why the box's own
-- units stop mattering: only its *ratio* to the page is used, so a crop from `getPageBBox`
-- (native pixels), from a foreign `pagenumbercrop`, or from anywhere else measures the same.
--
-- It comes from `getPageBBox`, and that is a decision rather than a convenience: that seam is
-- the reader's own answer — `autoContentBox`'s margin scan when *Page Crop* is auto, a detected
-- page-number strip when that row is on, and the whole page whenever the reader has cropping
-- off — so this follows the setting instead of second-guessing it, and switches itself off
-- exactly when the reader asked for no crop.
--
-- Returns nil when there is nothing to do — no crop, a page the scan refused, or a box that is
-- simply the whole page — and every caller then measures byte for byte as it did before this
-- existed.
local function contentDims(doc, page, dims)
    if not (doc and page and dims and type(doc.getPageBBox) == "function") then
        return nil
    end
    -- pcall'd because that seam may be a foreign plugin's: `pagenumbercrop` replaces
    -- `getPageBBox` outright, and it is not ours to constrain. A box this cannot read has to
    -- cost the crop and never the long-press.
    local ok, box = pcall(doc.getPageBBox, doc, page)
    if not ok or type(box) ~= "table" then
        return nil
    end
    local x0, y0 = tonumber(box.x0), tonumber(box.y0)
    local x1, y1 = tonumber(box.x1), tonumber(box.y1)
    if not (x0 and y0 and x1 and y1) then
        return nil
    end
    local w, h = x1 - x0, y1 - y0
    if w <= 0 or h <= 0 then
        return nil
    end
    -- A box as big as the page is no crop at all, and saying so here is what keeps every
    -- caller's arithmetic identical to the pre-crop version rather than merely equal to it.
    if w >= dims.w and h >= dims.h then
        return nil
    end
    return { w = w, h = h }
end

-- Show the steps of one page, starting at `index`.
--
-- `mode` and `rotate` are two adjacent strings of the same shape — the reading
-- direction, and `"left"`/`"right"`/nil from the book's `Rotate wide pages` —
-- so the order is worth naming: **mode, then rotate**. Swapping them is silent,
-- and shows as panels in mirrored order or turned the wrong way.
--
-- A nil `rotate` means this viewer is exactly the one that existed before
-- directions did: every rotation decision is stock's.
--
-- `opts` is the view: nil for the cropped sequence, `{ window = true }` for the window one,
-- or `{ free = true }` for the free one. Two optional fields say where to open, and each is
-- read by the view that can use it — **the window view never opens on a point**: a named
-- panel is walked from its own beginning, and a caller that was already looking at something
-- passes `keep = { x, y }`, the corner it wants back (`Viewport.stepNearest`). `free`'s
-- `tap = { x, y }` is the reader's finger in page coordinates, and that view *is* centred on
-- it, because it has no stops for a corner to be found among. `index` is a *panel*, and only
-- the two panel views have one: the window view turns it into a step through `Viewport`,
-- which is also what decides how many steps the page has at all, while the free view walks
-- no steps and needs neither panels nor a detector.
--
-- Returns false when there is nothing to show, which is what lets the caller
-- fall back to the single-region viewer rather than opening an empty one.
function PanelZoom.open(ui, page, panels, index, mode, rotate, opts)
    local doc = ui and ui.document
    local free = opts and opts.free
    if not (doc and (free or (panels and #panels > 0))) then
        return false
    end
    local window = opts and opts.window
    local steps, start = panels, index
    local screen
    local free_state
    -- What the two window-shaped views measured, for the one line below. **Every number the
    -- geometry used is here**, because a window that comes out the wrong shape is otherwise
    -- indistinguishable in a log from a page that is the wrong shape, and the four possible
    -- culprits — the screen we read, the page's dims, the content box, the level — are only
    -- separable by printing them side by side. The cropped view leaves it nil: it measures
    -- nothing against the screen.
    local geom
    if free then
        -- One window and no walk. The page's dimensions are all this view needs — the
        -- caller fetched and decoded the page for them (`getPageDims` is the decoder), so
        -- the bytes the render wants are in hand, and the detector has not been asked at
        -- all: there are no panels in a view that walks none, and a page the detector
        -- would have refused opens here like any other.
        local dims = doc:getPageDims(page)
        screen = CanvasContext:getSize()
        if not (dims and screen) then
            return false
        end
        -- The range the reader's zoom may move in, and its floor in particular is what the
        -- reader's own crop is for: it is measured against the *content*, so 1.0 is the page's
        -- artwork on the screen rather than the artwork plus whatever white border the scanner
        -- left. The window itself is still the page's, and is clamped to it — a margin is
        -- something this view can be moved onto, not something it refuses to show.
        local content = contentDims(doc, page, dims)
        local lo, hi = Viewport.scaleBounds(dims, screen, content)
        -- **The zoom is remembered**, and this is where it is read back: a scale rather than
        -- a level, because Original is scale 1 and a level is a magnification of the fit. With
        -- nothing stored the view starts at the level the other views use, so there is no
        -- second default to choose anywhere.
        --
        -- The stored scale is screen pixels per *page* pixel, so a crop moving the fit does not
        -- move what the reader asked for: 1:1 stays 1:1, and a remembered magnification stays
        -- the magnification it was, while the same scale is now a smaller multiple of the fit.
        local stored = Settings.get("free_zoom_scale")
        local scale = (type(stored) == "number" and stored > 0) and stored
            or Viewport.fitScale(content or dims, screen) * (opts.level or 1)
        scale = math.max(lo, math.min(hi, scale))
        local step = Viewport.windowAt(dims, screen, scale, opts.tap and opts.tap.x,
            opts.tap and opts.tap.y)
        if not step then
            return false
        end
        steps, start = { step }, 1
        free_state = { dims = dims, content = content, screen = screen, scale = scale }
        geom = { dims = dims, content = content, screen = screen, scale = scale }
    elseif window then
        -- The page's own size, in the space the panel rects are in. The bytes are
        -- already in hand — `getPanelsFromPage` fetched and decoded them to find
        -- the panels — so this is a lookup rather than a fetch, and a page with no
        -- bytes at all is one that has already failed above.
        --
        -- Two things go on into the geometry that this viewer cannot know by itself.
        -- `mode` is one: the detector hands the panels over in reading order, but
        -- which side of a panel the window stops on first is the geometry's to know,
        -- and a manga reads those the other way round. The zoom is the other, and it
        -- arrives as a *scale* — screen pixels per page pixel — because that is the
        -- one number that expresses both a level and 1:1.
        --
        -- The third is the reader's own crop, and it reaches only the *fit* below: the walk
        -- itself stays in the page's own coordinates, panels and touch point alike, so a stop
        -- is anchored to the panel it names with nothing in between to get an origin wrong.
        -- See `contentDims`; with no crop to honour it is nil and this is the line it has
        -- always been.
        local dims
        dims, screen = doc:getPageDims(page), CanvasContext:getSize()
        local content = contentDims(doc, page, dims)
        local scale = Viewport.fitScale(content or dims, screen) * (opts.level or 1)
        -- **The tap point is not handed to the walk**, and that is the entry rule rather
        -- than an omission: it chose the *panel* (upstream, through `Panel.indexAt`) and
        -- nothing else. The panel is walked from its own first view, so a long-press
        -- anywhere on it starts at its beginning — see `Viewport.steps`.
        steps, start = Viewport.steps(panels, dims, screen,
            index and { panel = index, at_end = opts.at_end },
            mode == "manga", scale)
        if not steps then
            return false
        end
        -- **A caller that was already looking at something says where.** The zoom buttons
        -- and the view switch change the walk under the reader and re-open it, and "the
        -- reader's place" is not the panel's first stop but the corner of it they were on —
        -- which is the one thing that survives a scale change. A long-press passes no
        -- `keep`, and opens at the beginning as it should.
        if opts.keep and index then
            start = Viewport.stepNearest(steps, index, opts.keep.x, opts.keep.y) or start
        end
        geom = { dims = dims, content = content, screen = screen, scale = scale }
    end
    local images = {}
    for i, rect in ipairs(steps) do
        images[i] = stepImage(doc, page, rect)
    end
    -- The buffers belong to the document's tile LRU, so the viewer must never
    -- free one — `cacheTile` is what frees them, on eviction or on close, and a
    -- BlitBuffer is malloc'd outside the Lua heap, so a buffer freed here would
    -- be freed twice.
    images.image_disposable = false
    -- Nothing turns in either of the window-shaped views, and that is not a gap: a window
    -- is the screen's shape, so there is no wide-versus-tall decision to make. Stock's own
    -- `rotated` stays false throughout, which is what the overrides above expect — and the
    -- free view has no panels to ask about at all, which is why it is named here and not
    -- left to `panelRotations`.
    local rotates = (window or free) and {} or panelRotations(panels)

    local viewer = PanelViewer:new{
        ui = ui,
        page = page,
        steps = steps,
        panel_rects = panels,
        mode = mode,
        rotate = rotate,
        view = opts,
        meguru_free = free_state,
        meguru_rotates = rotates,
        image = images,
        -- **One, and deliberately not the step count.** Stock builds, draws and
        -- frees its progress bar behind a single `_images_list_nb > 1` test, so
        -- this is the switch that turns the bar off — the last piece of chrome
        -- this window still drew, after the title bar and the button row. The
        -- reader shows no bar either: Meguru hides the footer, and the bar lives
        -- in it.
        --
        -- It is not a count any more, and nothing here treats it as one —
        -- `onShowNextImage`, `onShowPrevImage` and `meguruWarm` all bound
        -- themselves by `#self.steps`, which is the truth. Reading the count
        -- back off this field is the one edit that would silently break the
        -- sequence: with it at 1, every forward gesture would fall through to
        -- the page boundary and the second step would be unreachable.
        images_list_nb = 1,
        image_disposable = false,
        images_keep_pan_and_zoom = false,
        with_title_bar = false,
        fullscreen = true,
        -- Chrome is the reader's to summon and their state to keep: a re-open that the
        -- reader asked for — the zoom button, a page boundary — must not hide the row
        -- they were just using. See `meguruCycleZoomLevel` and `meguruHandoff`. The free
        -- view is the one that *asks* for its row to be permanent, since it is the only
        -- view whose reader cannot summon it back with a middle tap.
        buttons_visible = (opts and opts.buttons_visible == true) or free == true,
        rotated = rotates[1] or false,
    }
    -- **The row is cosmetic, so a failure to build it must cost the buttons and not the
    -- view.** This calls into stock's widget constructors, and a stock that moves under
    -- it should not take the panel view down — which is the rule the crop mask already
    -- follows on the render path ("costs the crop and not the panel"). It is also the
    -- difference between a reader seeing a viewer with the wrong buttons and a reader
    -- seeing nothing at all: the viewer is built by now, and an unshown one leaves a
    -- queued repaint behind that names a frame it never finished — the second half of
    -- the crash this was found by.
    local ok, err = pcall(installRow, viewer)
    if not ok then
        logger.warn("Meguru: the panel view's button row was not built:", err)
    end

    -- The direction is named because this is the only place the resolved answer
    -- appears, and a panel turned the wrong way is otherwise indistinguishable
    -- in a log from a panel that was never meant to turn. **The free view gets its own
    -- line** rather than a branch of this one: it has no panel count and no step count to
    -- report, and a line written for the other two views reads back a `nil` the moment one
    -- of its fields becomes optional — which is exactly how this one shipped.
    --
    -- **It is logged before `show`, and that is the point of it being here.** Nothing after
    -- that call may throw: a throw leaves a viewer on the stack while the caller is told
    -- the open failed, and the caller falls back to stock with a Meguru viewer still up.
    -- Everything the line needs is known by now, so it goes first and the invariant holds.
    if geom then
        -- One line, and it is the only place the geometry can be read back. `screen` is the
        -- size the *plugin* was handed, which is the thing to compare against what the
        -- device is actually showing: `CanvasContext:getSize()` follows a rotation (the
        -- framebuffer's `bb:getWidth` swaps on an odd rotation mode), so a line here whose
        -- screen is portrait while the reader is looking at a landscape panel is the whole
        -- diagnosis — and one whose screen is landscape moves the fault off this line and
        -- onto `dims` or `content` beside it.
        local c = geom.content
        logger.dbg("Meguru: window geometry page", page,
            "screen", geom.screen.w .. "x" .. geom.screen.h,
            "rotation", tostring(Screen:getRotationMode()),
            "page", geom.dims.w .. "x" .. geom.dims.h,
            "content", c and (c.w .. "x" .. c.h) or "none",
            "level", tostring(opts and opts.level),
            "scale", string.format("%.4f", geom.scale))
    end
    if free then
        logger.dbg("Meguru: free zoom opened on page", page,
            "(" .. tostring(mode) .. ", " .. freeLabel(free_state.scale,
                freeFit(free_state)) .. ")")
    else
        logger.dbg("Meguru: panel zoom opened on page", page, "panel", index or 1,
            "of", #panels, "(" .. tostring(mode) .. ")",
            window and ("window view, step " .. (start or 1) .. " of " .. #steps)
                or "cropped panels",
            rotate and ("turned " .. rotate) or "no turn direction")
    end

    -- **Fill the frame's `dimen` before the viewer is ever shown, or a viewer that is built and
    -- never painted takes the session down one repaint later.** `FrameContainer:paintTo` is the
    -- only thing that assigns it, and `ImageViewer:update` queues a repaint closure that
    -- *indexes* it — so the closure of a viewer that never reached the screen reads nil
    -- (`imageviewer.lua:384`, `attempt to index field 'dimen'`), and `UIManager:close` cannot
    -- reach it because `_refresh_func_stack` is a plain list and not keyed by widget.
    --
    -- What makes this safe rather than a guess is that the value below is **exactly** the one
    -- that `paintTo` would compute: it is `self:getSize()` and nothing else, so setting it early
    -- changes no layout — `paintTo` then takes its `else` branch and rewrites only `x`/`y`.
    -- Every step of these views is a screen-shaped tile, so the size cannot move between here
    -- and the paint either; where it could, the cost would be a stale refresh region and not a
    -- wrong picture.
    --
    -- This is a guard and not the cause. See `meguruReopenAtLevel` for what puts a viewer in
    -- that state at all, and docs/known-issues.md for the mechanism in full.
    do
        local frame = viewer.main_frame
        if frame and not frame.dimen then
            local size = frame:getSize()
            frame.dimen = Geom:new{ x = 0, y = 0, w = size.w, h = size.h }
        end
    end
    -- `show` dispatches the `Show` event, which is where the pre-warm is armed;
    -- nothing is armed here.
    UIManager:show(viewer)
    -- `init` has already rendered the first step to fill `self.image`; a long-press
    -- that landed on panel 4 gets there through the same switch a swipe uses,
    -- which also hands the first step's tile back and re-arms the warm.
    if start and start > 1 and start <= #steps then
        viewer:switchToImageNum(start)
    end
    return true
end

return PanelZoom
