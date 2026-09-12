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

local CanvasContext = require("document/canvascontext")
local Device = require("device")
local Event = require("ui/event")
local ImageViewer = require("ui/widget/imageviewer")
local UIManager = require("ui/uimanager")
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

-- The lazy entry `ImageViewer` wants for each image in its list.
--
-- Lazy on purpose in both directions: panels the reader never reaches are never
-- rendered, and each render goes through `drawPagePart`, whose own LRU decides
-- whether this is a fresh render or the pre-warm landing.
local function panelImage(doc, page, rect)
    return function()
        return doc:drawPagePart(page, rect, 0)
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
    page = nil,           -- the book page these panels were cut from
    panels = nil,         -- the ordered rects, kept: the handoff needs them
    mode = nil,           -- "manga" | "comic"
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

-- Hand a panel's tile back to the document.
--
-- Called for the panel just left and for the one on screen when the viewer
-- closes, which is what keeps the tile LRU at the two entries this design needs
-- (the panel shown and the panel warmed) rather than one per panel visited. See
-- `MeguruDocument:releasePanelTile` for the arithmetic.
function PanelViewer:meguruRelease(index)
    local doc = self.ui and self.ui.document
    local rect = self.panels and self.panels[index]
    if not (doc and rect and type(doc.releasePanelTile) == "function") then
        return false
    end
    return doc:releasePanelTile(self.page, rect)
end

-- Arm the pre-warm, replacing any warm still queued from the panel before.
function PanelViewer:meguruArmWarm()
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
    if not (doc and self.panels) then
        return
    end
    local cur = self._images_list_cur
    if cur < #self.panels then
        if not doc.dead_pages[self.page] then
            local ok, err = pcall(doc.drawPagePart, doc, self.page,
                self.panels[cur + 1], 0)
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

function PanelViewer:onShowNextImage()
    if self._images_list_cur < self._images_list_nb then
        self:switchToImageNum(self._images_list_cur + 1)
        return true
    end
    return self:meguruHandoff("next")
end

function PanelViewer:onShowPrevImage()
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

-- A horizontal swipe moves through the panels, but only while the panel is at
-- best fit.
--
-- Once the reader has pinched in, a horizontal drag is how they move around the
-- panel they are looking at, and taking that away to change panels would make
-- zooming useless. That is stock's own precedent for the swipe that closes the
-- viewer, which is gated on the same condition.
function PanelViewer:onSwipe(arg, ges)
    local direction = ges.direction
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
            if doc:hasConnection() then
                -- `accepted` is not interesting here: a page the detector
                -- refused opens the whole page as one panel, and a crossing is a
                -- crossing either way. Only a page that would not decode has no
                -- panels at all, and that is what the `else` log line says.
                panels, _, reason = doc:getPanelsFromPage(page, mode)
            else
                reason = "no connection"
            end
            UIManager:close(this)
            ui:handleEvent(Event:new("GotoPage", page))
            if panels then
                local index = (direction == "next") and 1 or #panels
                PanelZoom.open(ui, page, panels, index, mode, rotate)
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
    -- Stock first: it may still touch the ImageWidget holding this panel's
    -- bytes, and the bytes are freed a line later.
    ImageViewer.onCloseWidget(self)
    self:meguruRelease(self._images_list_cur)
end

-- Show the panels of one page, starting at `index`.
--
-- `mode` and `rotate` are two adjacent strings of the same shape — the reading
-- direction, and `"left"`/`"right"`/nil from the book's `Rotate wide pages` —
-- so the order is worth naming: **mode, then rotate**. Swapping them is silent,
-- and shows as panels in mirrored order or turned the wrong way.
--
-- A nil `rotate` means this viewer is exactly the one that existed before
-- directions did: every rotation decision is stock's.
--
-- Returns false when there is nothing to show, which is what lets the caller
-- fall back to the single-region viewer rather than opening an empty one.
function PanelZoom.open(ui, page, panels, index, mode, rotate)
    local doc = ui and ui.document
    if not (doc and panels and #panels > 0) then
        return false
    end
    local images = {}
    for i, rect in ipairs(panels) do
        images[i] = panelImage(doc, page, rect)
    end
    -- The buffers belong to the document's tile LRU, so the viewer must never
    -- free one — `cacheTile` is what frees them, on eviction or on close, and a
    -- BlitBuffer is malloc'd outside the Lua heap, so a buffer freed here would
    -- be freed twice.
    images.image_disposable = false
    local rotates = panelRotations(panels)

    local viewer = PanelViewer:new{
        ui = ui,
        page = page,
        panels = panels,
        mode = mode,
        rotate = rotate,
        meguru_rotates = rotates,
        image = images,
        images_list_nb = #panels,
        image_disposable = false,
        images_keep_pan_and_zoom = false,
        with_title_bar = false,
        fullscreen = true,
        buttons_visible = false,
        rotated = rotates[1] or false,
    }

    -- `show` dispatches the `Show` event, which is where the pre-warm is armed;
    -- nothing is armed here.
    UIManager:show(viewer)
    -- `init` has already rendered panel 1 to fill `self.image`; a long-press
    -- that landed on panel 4 gets there through the same switch a swipe uses,
    -- which also hands panel 1's tile back and re-arms the warm.
    if index and index > 1 and index <= #panels then
        viewer:switchToImageNum(index)
    end
    -- The direction is named because this is the only place the resolved answer
    -- appears, and a panel turned the wrong way is otherwise indistinguishable
    -- in a log from a panel that was never meant to turn.
    logger.dbg("Meguru: panel zoom opened on page", page, "panel", index or 1,
        "of", #panels, "(" .. tostring(mode) .. ")",
        rotate and ("turned " .. rotate) or "no turn direction")
    return true
end

return PanelZoom
