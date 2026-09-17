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

`ZOOM` is the magnification over fit-to-screen: at 1.85 the window covers
`1/1.85` of the *fitted* page, so the reader is about 1.85 times closer than they
were. One number for the whole mode — not per panel, not per page, not adjusted to
the panel in front of them — because a zoom that moved with the layout would make
"one more click" mean something different on every page.

What the number decides is how many stops a panel takes. A panel never wider than
the window is one stop, centred; one too wide for it is two, its two edges; one too
wide in *both* axes is four, its four corners — see `positions`. The last is the one
to keep in mind when changing `ZOOM`: the closer in, the more stops a big panel
costs, and 1.85 is what makes a page's worth of artwork arrive in two windows.

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
  out_w, out_h,      -- the pixels to render it at (the screen, unless clipped)
  panel = i }        -- which panel of the list this step is in
```

`panel` is what lets the caller open at the right step and what a log can say; the
geometry never uses it.
--]]

local Viewport = {}

-- The magnification over fit-to-screen. See the header: it is what decides how many
-- stops a panel too big for the window takes — two when it overflows one axis, four
-- when it overflows both — so moving it moves that count, and it is not a taste.
Viewport.ZOOM = 1.85

-- How far two window positions may differ and still count as the same place.
-- Only positions are compared — a page's steps all share one size — and the
-- tolerance exists for float noise in the centre-then-clamp arithmetic, not to
-- forgive a deliberate move.
local SAME_EPSILON = 0.5

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
local function windowFor(dims, screen)
    local fit = math.min(screen.w / dims.w, screen.h / dims.h)
    local scale = fit * Viewport.ZOOM
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

local function samePlace(a, b)
    return math.abs(a.x - b.x) < SAME_EPSILON and math.abs(a.y - b.y) < SAME_EPSILON
end

-- The window the reader asked for by touching a point on a panel.
--
-- Centred on the finger, then clamped to the panel on each axis the panel
-- overflows. When the panel fits, there is nothing to clamp to — the window is
-- larger than the panel — so the view stays centred where they touched, as asked.
-- The page clamp still applies, because a touch near the page's edge would
-- otherwise ask for a window that reaches past it.
function Viewport.entryView(panels, dims, screen, index, x, y)
    local panel = panels and panels[index] and whole(panels[index])
    if not (panel and dims and screen and x and y) then
        return nil
    end
    local w, h = windowFor(dims, screen)
    local view = centred(x, y, w, h, dims)
    if panel.w > w then
        view.x = clampAxis(view.x, w, panel.x, panel.x + panel.w)
    end
    if panel.h > h then
        view.y = clampAxis(view.y, h, panel.y, panel.y + panel.h)
    end
    return view
end

-- The page's steps, in the order the forward gesture reaches them.
--
-- `entry` is nil for a plain start at the first panel, or `{ panel = i, x, y }`
-- for a reader who long-pressed a point: that panel's *first* view is replaced by
-- the view they asked for, and the rest of its views follow. Replacing rather than
-- inserting is what keeps the steps before the touched panel reachable — a tap in
-- the middle of a page must not cut off everything above it — and it is why the
-- entry is found by the panel it belongs to and not by position.
--
-- `right_to_left` is the book's reading direction, and it is a parameter because
-- this is the one place in the plugin where direction is not already decided
-- upstream: the panel *order* comes out of the detector ordered, but which side of
-- a panel the window stops on first is this module's to know, and a manga reads
-- those the other way round. It orders the x positions and the corners of a row.
--
-- Returns the step list and the index the viewer should open at, or nil when there
-- is nothing to walk.
function Viewport.steps(panels, dims, screen, entry, right_to_left)
    if not (panels and #panels > 0 and dims and screen) then
        return nil
    end
    local w, h, scale = windowFor(dims, screen)
    local out_w = math.max(1, math.floor(w * scale + 0.5))
    local out_h = math.max(1, math.floor(h * scale + 0.5))
    local steps = {}
    local open_at = 1
    local cur

    local function push(index, view)
        steps[#steps + 1] = {
            x = view.x, y = view.y, w = w, h = h,
            out_w = out_w, out_h = out_h,
            panel = index,
        }
    end

    for i = 1, #panels do
        local panel = whole(panels[i])
        local touched = entry and entry.panel == i
            and Viewport.entryView(panels, dims, screen, i, entry.x, entry.y)
        if touched then
            push(i, touched)
            cur = touched
            open_at = #steps
            -- **Which of the panel's views the reader's own view stands for**, and
            -- the whole of the entry rule:
            --
            --   * on a corner — that corner. Pushing it as well would show the
            --     reader the view they are standing on, and dropping the wrong one
            --     would leave a corner of the panel unseen;
            --   * between corners — the first, which is the rule this has always
            --     followed: a tall panel tapped in the middle goes straight to its
            --     lower edge rather than back up to a top the reader has chosen to
            --     skip;
            --   * a panel that fits — none, because its one view is the only thing
            --     that shows the whole of it. That is what keeps a tap the page's
            --     edge clamped from leaving the panel half seen.
            --
            -- Nothing at all is pushed for a panel the entry already shows in full,
            -- which is the same question the skip below asks of a panel the window
            -- happens to cover.
            local views = positions(panel, w, h, dims, right_to_left)
            local stands_for
            for k = 1, #views do
                if samePlace(views[k], touched) then
                    stands_for = k
                    break
                end
            end
            if not stands_for and #views > 1 then
                stands_for = 1
            end
            if not contains(touched, panel) then
                for k = 1, #views do
                    if k ~= stands_for then
                        push(i, views[k])
                        cur = views[k]
                    end
                end
            end
        elseif cur and contains(cur, panel) then
            -- Wholly visible already: read, and not a step. This is the skip.
        else
            for _, view in ipairs(positions(panel, w, h, dims, right_to_left)) do
                push(i, view)
                cur = view
            end
        end
    end

    return steps, open_at
end

return Viewport
