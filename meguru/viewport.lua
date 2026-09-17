--[[--
Where the window sits over a page, for the view that does not crop.

The panel view has two modes. The first cuts each panel out of the page and shows
it as its own image — `meguru/ui/panelzoom` hands `drawPagePart` a panel's
rectangle and gets back a crop of it. This module is for the second: the page
stays whole and only a **window** moves over it, at one fixed zoom, anchored to
the *panel's* edges rather than to the page's.

Nothing here renders, fetches or owns anything. It takes the ordered panel rects
the detector already produced, the page's dimensions and the screen's, and returns
a list of rectangles in page space — which is all the viewer needs, because
`MeguruDocument:drawPagePart` already renders an arbitrary rectangle of a page at
a requested pixel size.

## The zoom, and why it is anchored to the page

The zoom is **screen pixels per page pixel**, and the caller passes it in: a *level* —
1.4, 1.7, 1.9 — is a multiple of the page's width on the screen, so the scale is
`fitScale(dims, screen) * level`, where the `1` of that is "a page exactly as wide as
the screen". Which is what makes a level mean the same thing on every page and in every
orientation, and therefore worth remembering: **the button row inside the viewer says
which level the reader is on, the preference stores it, and this module neither stores
nor chooses it.** See `fitScale` for the definition and for the one it replaced.

That is the reader's number and it is what every panel is shown at, with **one
exception**: a panel the window misses by a few percent is *eased* to fit rather than
costing a whole extra stop to show a sliver of itself. See `PANEL_WINDOW_TOLERANCE`.

One measure in here is *not* a level and is worth naming before it is mistaken for one:
`pageFitScale`, the scale at which the whole page is on the screen. It is not
interchangeable with a level — a page taller than the screen is never one level wide, so
the whole page sits *below* 1.0 — and the only caller is the free view's floor.

That is the reader's number and it is what every panel is shown at, with **one
exception**: a panel the window misses by a few percent is *eased* to fit rather than
costing a whole extra stop to show a sliver of itself. See `PANEL_WINDOW_TOLERANCE`.

What the scale decides is how many stops a panel takes. A panel never wider than
the window is one stop, centred; one too wide for it is two, its two edges; one too
wide in *both* axes is four, its four corners — see `positions`. The last is the one
to keep in mind when moving the scale: the closer in, the more stops a big panel
costs. The easing above can only ever *remove* stops from that count, and only from a
panel it can fit in one.

The window is shaped like the screen and clamped to the page, so on a page smaller
than the window the request shrinks with it and the viewer letterboxes rather than
stretching — which is why a step carries its own `out_w`/`out_h` rather than
assuming the screen's size.

## The chain, and the skip

Steps are not "each panel, one or two views of it". They are a **simulation of the
forward gesture**, run once over the page, because where the next step lands
depends on what is *already visible* and not only on which panel the reader is in:

> before moving to the next panel in reading order, ask whether that panel is
> already wholly inside the window as it stands. If it is, do not move at all —
> that panel is read, and the question moves on to the one after it. One tap can
> therefore pass several small panels at once, which is what happens on a page with
> a grid of them beside a full-height one.

So a panel that fits beside the current view gets **no step**, and the number of
taps on a page is not `#panels` times anything. That also means there is no
"stage" to keep and no "read" flag to set: a skipped panel is simply one the chain
never stopped at, and the reader's place is the step index. State that nothing
reads is state that drifts; this has none.

## What is a step

```
{ x, y, w, h,        -- the window, in the page space `self.dims` lives in
  out_w, out_h,      -- the pixels to render it at
  panel = i }        -- which panel of the list this step is in
```

`panel` is what lets the caller open at the right step and what a log can say; the
geometry never uses it.

**`w`/`h` are the panel's and not the page's**, so two steps of one page may sit at two
zooms: an eased panel's window is larger in page pixels, and the same screenful of pixels
covers more page. Nothing downstream has to know — every reader of a step reads the step —
and that is the property to keep when adding one.

`out_w`/`out_h` are the screen's own size, and an eased panel's are too — its *window* is
what grew, so the same screenful of pixels is simply covering more page, and the panel
reads smaller inside it. They fall short of the screen in exactly one case: a page too
small to fill the window, where the window is clamped to the page and the viewer
letterboxes. See `frameFor`.
--]]

local Viewport = {}

-- The scale a *level* is a multiple of: **the page's width on the screen's width** — the `1`
-- of "1.7x".
--
-- A level is therefore always "how much wider than the screen the artwork is": 1.0 is a page
-- exactly as wide as the screen, 1.4 one forty percent wider, and a level reads the same on a
-- portrait screen, a landscape one, and a page of any shape.
--
-- **The definition this replaced was the *smaller* of the two ratios**, so 1.0 meant "the whole
-- page fits" — friendlier to describe and wrong in two ways a reader actually met. It made one
-- level mean a different magnification on every *page* shape, since the smaller ratio is the
-- page's height on a portrait screen and its width on a landscape one; and it made **rotating
-- the device change the magnification**, the same 1.9 coming out 22% closer standing up than
-- lying down, because a wider screen lowered the ratio instead of raising it. Neither is a
-- property anyone chose; both fall straight out of taking a minimum.
--
-- `dims` is the page's **content** wherever the reader's crop gives one (see `contentDims` in
-- `meguru/ui/panelzoom`), so a margin is not part of what a level is a multiple *of*.
function Viewport.fitScale(dims, screen)
    return screen.w / dims.w
end

-- The scale at which the whole of `dims` is on the screen at once.
--
-- Exactly one caller needs it — the free view's floor — because that view is "the page, with
-- nothing in the way" and its `-` has to be able to reach the whole page, which is the one
-- thing a level cannot name: a page taller than the screen is never one level wide. Everything
-- that talks about a level uses `fitScale` above, **including that view's own step buttons**,
-- so the two are not interchangeable and the difference between them is the point.
function Viewport.pageFitScale(dims, screen)
    return math.min(screen.w / dims.w, screen.h / dims.h)
end

-- How far past the window a panel may reach and still be *eased* to fit instead of costing an
-- extra stop, as a fraction of the window's own dimension — so 0.18 means a panel up to eighteen
-- percent too wide or too tall is shown slightly smaller and whole, rather than shown at the
-- reader's scale in two stops.
--
-- The figure is a guess at where a reader stops noticing the shrink and starts wanting the zoom;
-- it is a ratio and not a length, so it reads the same on any screen, and it is the one number to
-- move if that judgement turns out to be wrong. **Zero disables the whole mechanism**, which is
-- what to reach for if it ever misbehaves.
local PANEL_WINDOW_TOLERANCE = 0.18

-- Nearest whole page pixel. See `windowFor` for why the geometry works in them.
local function round(value)
    return math.floor(value + 0.5)
end

-- A panel rect in whole page pixels.
--
-- **The detector works in floats and this is the last place they are needed.**
-- Panels come out of `meguru/panel` as fractions of a page pixel — the cell
-- conversion there deliberately produces them — and every window is anchored to
-- one and clamped against one. Rounding here, once, is what keeps the windows
-- integral: a clamp against a fractional edge would put a fraction straight back
-- into the rectangle the tile key is built from.
local function whole(panel)
    return {
        x = round(panel.x),
        y = round(panel.y),
        w = round(panel.w),
        h = round(panel.h),
    }
end

-- The window's size in page pixels, and the pixels-per-page-pixel it implies.
--
-- Clamped to the page: a page smaller than the fitted window would otherwise ask
-- for a rectangle that reaches past its own edge, and `Image.renderRegion` has no
-- defined content out there.
--
-- **Whole page pixels, and that is not tidiness.** The rectangle is what the
-- document's tile key is built from, and that key formats it with `%d` — so a
-- fractional window would be cached under a key naming a *different* rectangle
-- than the one it was rendered from, and two windows a fraction apart would share
-- a tile. Rounding here is also what makes the render-path log line truthful: it
-- prints the region with `%d` too.
local function windowFor(dims, screen, scale)
    return round(math.min(dims.w, screen.w / scale)),
        round(math.min(dims.h, screen.h / scale)), scale
end

-- Move a window along one axis until it sits inside `lo..hi`.
local function clampAxis(position, size, lo, hi)
    if size >= hi - lo or position < lo then
        return lo
    end
    if position + size > hi then
        return hi - size
    end
    return position
end

-- A window centred on a point and kept inside the page.
local function centred(x, y, w, h, dims)
    return {
        x = clampAxis(round(x - w / 2), w, 0, dims.w),
        y = clampAxis(round(y - h / 2), h, 0, dims.h),
        w = w,
        h = h,
    }
end

-- Where the window stops inside one panel, in reading order.
--
-- One rule per axis: **the panel is centred on an axis it fits, and anchored to
-- both of its edges on an axis it overflows.** The panel's views are the cross
-- product of the two axes' positions, in reading order, so the count is 1, 2 or
-- **4** — and the four is the case worth saying out loud. A panel too big in *both*
-- axes anchored to its start corner and then its end corner covers the middle
-- twice and leaves the other two corners unseen, which is not coverage; four
-- corners in reading order is. A panel too big in one axis only is two views, and
-- that has not changed.
--
-- `right_to_left` is the book's direction and it orders the sides: between the two
-- x positions, and so between the corners of a row. A manga's four corners are
-- top-right, top-left, bottom-right, bottom-left — the same page walked the way
-- the book is read. The vertical order does not need the flag: both kinds of book
-- are read down the page.
local function positions(panel, w, h, dims, right_to_left)
    local xs = {}
    if panel.w <= w then
        xs[1] = round(panel.x + (panel.w - w) / 2)
    elseif right_to_left then
        xs[1], xs[2] = round(panel.x + panel.w - w), round(panel.x)
    else
        xs[1], xs[2] = round(panel.x), round(panel.x + panel.w - w)
    end
    local ys = {}
    if panel.h <= h then
        ys[1] = round(panel.y + (panel.h - h) / 2)
    else
        ys[1], ys[2] = round(panel.y), round(panel.y + panel.h - h)
    end
    local views = {}
    for i = 1, #ys do
        for j = 1, #xs do
            local view = {
                x = clampAxis(xs[j], w, 0, dims.w),
                y = clampAxis(ys[i], h, 0, dims.h),
                w = w,
                h = h,
            }
            -- A panel that overflows an axis by **less than a pixel** has two
            -- positions that round to the same one, and the second is not a stop.
            -- Dropping it here is what lets the walk below push every view it is
            -- given: distinctness is this function's to guarantee, not its callers'.
            local previous = views[#views]
            if not (previous and previous.x == view.x and previous.y == view.y) then
                views[#views + 1] = view
            end
        end
    end
    return views
end

-- Is the whole of `rect` inside `view`?
--
-- This is the test the skip rests on: a panel that is *entirely* visible is one
-- the reader has already seen, so the chain does not stop for it. Its sibling
-- `not contains(...)` is the other half — a panel the window does **not** cover
-- in full still has a part unseen, and that part is what the next step shows.
local function contains(view, rect)
    return view.x <= rect.x and view.y <= rect.y
        and view.x + view.w >= rect.x + rect.w
        and view.y + view.h >= rect.y + rect.h
end

-- One scale's window: its size in page pixels, and the pixels to render it to.
--
-- **The one place the output size is derived from a scale**, so a step's `out_w`/`out_h` cannot
-- disagree with the `w`/`h` beside it — which matters more than it looks, because the tile LRU
-- keys on the rectangle *and* that size, and two that drifted would be two entries for one
-- picture. `Viewport.windowAt` goes through it for the same reason.
local function frameFor(dims, screen, scale)
    local w, h = windowFor(dims, screen, scale)
    return {
        w = w,
        h = h,
        scale = scale,
        out_w = math.max(1, math.floor(w * scale + 0.5)),
        out_h = math.max(1, math.floor(h * scale + 0.5)),
    }
end

-- Whether one axis may be eased: the panel overflows the window on it, but by little enough that
-- the scale which fits it stays within the tolerance of the reader's.
local function eases(overflow, room)
    return overflow > room and overflow <= room * (1 + PANEL_WINDOW_TOLERANCE)
end

-- The frame one panel is shown in: the reader's, unless a slight easing lets the panel fit whole.
--
-- A panel that misses the window by a few percent costs a whole extra stop, and that stop shows a
-- sliver rather than new artwork — which is the whole reason this exists. **The easing is decided
-- per axis and the answer is one scale**, because the window keeps the screen's shape: an axis is
-- eased when its *own* overflow is within the tolerance, and the strictest eased axis sets the
-- scale for both. The other axes of that decision are what keep it honest:
--
--   * an axis past the tolerance is left alone. No scale within the tolerance could have fitted
--     it, so nothing is given up by not trying — and it keeps its full stops below;
--   * a panel past the tolerance in **both** axes gets the reader's frame exactly, which is the
--     behaviour this had before any of it. Nowhere does it cost a stop the reader did not
--     already have — it only ever answers with fewer.
--
-- What it costs: the scale is no longer one number for the page. A panel eased to fit is shown
-- slightly smaller than the one beside it, and a panel eased in one axis only is shown at that
-- smaller scale for *all* of its stops. That is the price of not making a reader press in order
-- to see a strip, and the tolerance is what bounds it.
local function frameForPanel(panel, dims, screen, scale)
    if PANEL_WINDOW_TOLERANCE <= 0 then
        return frameFor(dims, screen, scale)
    end
    local frame = frameFor(dims, screen, scale)
    local eased = scale
    if eases(panel.w, frame.w) then
        eased = math.min(eased, screen.w / panel.w)
    end
    if eases(panel.h, frame.h) then
        eased = math.min(eased, screen.h / panel.h)
    end
    if eased >= scale then
        return frame
    end
    return frameFor(dims, screen, eased)
end

-- The step of `panel` nearest a point, or nil when that panel has none.
--
-- This is how a **re-open keeps the reader's place** now that the walk always starts a named
-- panel at its own beginning — the zoom buttons change the window under the reader and then
-- rebuild the walk, and a step *index* does not survive that (a different scale means a
-- different number of stops per panel), while the corner they were looking at does. It is
-- the step's own start corner that is compared, because that is what `positions` anchors a
-- stop to, so the answer is stable across a scale change rather than approximate.
function Viewport.stepNearest(steps, panel, x, y)
    local best, best_d
    for i, step in ipairs(steps or {}) do
        if step.panel == panel then
            local dx, dy = step.x - x, step.y - y
            local d = dx * dx + dy * dy
            if not best_d or d < best_d then
                best, best_d = i, d
            end
        end
    end
    return best
end

-- The scale the free view may move between, as `min, max` in screen pixels per page
-- pixel.
--
-- **The floor is a whole page and the ceiling is a number of levels, and that they are two
-- different measures is the whole of it.** The floor comes from `pageFitScale`, because this
-- view has to be able to show the whole page whatever shape it is; the ceiling is four levels,
-- because the range a reader steps through is the one the buttons beside them label. A single
-- measure could not do both: the whole page is below one level on any page taller than the
-- screen, so a floor taken from `fitScale` would put the page out of reach.
--
-- Both are floored at 1 for **original size** — one page pixel to one screen pixel, the one
-- scale in that view that is not a magnification of anything. A page smaller than the screen
-- has both measures above 1, so this is the case the floor at 1 is for.
function Viewport.scaleBounds(dims, screen)
    return math.min(Viewport.pageFitScale(dims, screen), 1),
        math.max(Viewport.fitScale(dims, screen) * 4, 1)
end

-- One window, centred on a point of the page and clamped to the **page**.
--
-- This is the free view's whole geometry: no panels, no stops, and the only thing that
-- bounds the window is the page's own edge. The step comes back in the same shape the
-- walk produces, so the document, the tile key and the LRU cannot tell the two modes
-- apart.
function Viewport.windowAt(dims, screen, scale, cx, cy)
    if not (dims and screen and scale) then
        return nil
    end
    local frame = frameFor(dims, screen, scale)
    local view = centred(cx or dims.w / 2, cy or dims.h / 2, frame.w, frame.h, dims)
    return {
        x = view.x,
        y = view.y,
        w = frame.w,
        h = frame.h,
        out_w = frame.out_w,
        out_h = frame.out_h,
    }
end

-- The page's steps, in the order the forward gesture reaches them.
--
-- `entry` is nil for a plain start, or `{ panel = i }` for a caller that wants the walk to
-- **open at a named panel**. Which panel is the only thing it decides: the reader then walks
-- that panel the way it has always been walked, from its own first view, so a long-press
-- anywhere on a panel starts at the panel's beginning rather than at the point under the
-- finger. Two things fall out of that and both are the point of it: the panel's top is never
-- skipped — a reader who pressed the lower half of a tall panel used to be shown the view
-- their finger stood for and never the top at all — and the two window views now agree with
-- the cropped one, which has always shown a panel from its start.
--
-- `entry.at_end` asks for the panel's **last** view instead, which is what a caller working
-- *backwards* through the book wants: the page boundary crossing back asks for the previous
-- page's last panel, and the reader is arriving from below it.
--
-- `right_to_left` is the book's reading direction and `scale` is the reader's zoom —
-- screen pixels per page pixel, `fitScale` times a level. Both arrive as arguments
-- because this module decides neither: the direction is the book's and the zoom is the
-- reader's, and nothing here has the standing to guess either. The one scale this
-- *does* choose is a panel's own, and only ever a smaller one — see `frameForPanel`.
--
-- Returns the step list and the index the viewer should open at, or nil when there
-- is nothing to walk.
function Viewport.steps(panels, dims, screen, entry, right_to_left, scale)
    if not (panels and #panels > 0 and dims and screen and scale) then
        return nil
    end
    local steps = {}
    local open_at = 1
    local cur

    -- **The frame is the panel's and not the page's.** Every step carries the window it was
    -- walked in, so a panel the easing has fitted pushes its own larger `w`/`h` and its own
    -- smaller `out_w`/`out_h` beside it, and the viewer, the tile key and the log line all read
    -- the step rather than a scale — which is what lets one page's steps hold two zooms.
    local function push(index, view, frame)
        steps[#steps + 1] = {
            x = view.x, y = view.y, w = view.w, h = view.h,
            out_w = frame.out_w, out_h = frame.out_h,
            panel = index,
        }
    end

    for i = 1, #panels do
        local panel = whole(panels[i])
        local frame = frameForPanel(panel, dims, screen, scale)
        local w, h = frame.w, frame.h
        -- The panel the caller named, if any. It decides only *which* panel the viewer
        -- opens at: the walk below is one walk for every panel, so a named one is shown
        -- from its own beginning exactly as it would be if the reader had arrived by
        -- pressing forward. That is the whole of the entry rule now, and it replaced one
        -- that let the finger's position replace the panel's first view — which meant a
        -- long-press on the lower half of a tall panel never showed the reader its top.
        local wanted = entry and entry.panel == i
        if not wanted and cur and contains(cur, panel) then
            -- Wholly visible already: read, and not a step. This is the skip.
        else
            -- **A panel the caller named always gets its stops**, and the skip does not get
            -- to drop it: the caller asked for it by name, and crossing *back* a page names
            -- the previous page's last panel — which the skip would otherwise swallow on a
            -- page whose window happens to cover it.
            local views = positions(panel, w, h, dims, right_to_left)
            for _, view in ipairs(views) do
                push(i, view, frame)
                cur = view
            end
            if wanted then
                -- The first stop, or the last when the caller is reading backwards:
                -- arriving at the bottom of the last panel is arriving where the
                -- content the reader just left continues.
                open_at = entry.at_end and #steps or (#steps - #views + 1)
            end
        end
    end

    return steps, open_at
end

return Viewport
