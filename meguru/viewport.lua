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
were and a page's worth of artwork arrives in two windows. One number for the whole
mode — not per panel, not per page, not adjusted to the panel in front of them —
because a zoom that moved with the layout would make "one more click" mean
something different on every page.

The guarantee the number buys is arithmetic rather than a rule: a panel is never
bigger than the page, and two windows reach `2/1.85 = 1.08` of the page in each
axis, so **no panel ever needs a third step**. Nothing enforces that; it falls out
of 1.85 < 2, and it is why the constant is not free to raise.

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

-- The magnification over fit-to-screen. See the header: the two-window guarantee
-- is `2 / ZOOM >= the page in each axis`, so anything at or above 2 is a different
-- promise, not a tuning.
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

-- Where the window sits for a panel, per axis: **centred when the panel fits, and
-- flush to the panel's edge when it does not.**
--
-- The per-axis split is the whole rule, and it is why the two anchors are one
-- function. A panel narrower than the window cannot be flushed to anything — the
-- window is bigger than it — so it is centred, and that is the "equal margins"
-- view of a panel that fits. A panel wider than the window has two positions
-- worth stopping at, and `at_end` picks between them: the panel's start edge at
-- the window's edge, or its end edge there.
--
-- **The anchor is the panel's edge and never the page's.** A panel rarely begins at
-- the page's border, so anchoring to the page would show a strip of the neighbour
-- and cut the panel's own first column off — the failure this rule exists for.
-- The clamp to the page is a separate, last step: it can only move the window when
-- the panel is against the page's own edge, where there is nothing else to show.
local function anchor(panel, w, h, dims, at_end)
    local x = panel.x + (panel.w - w) / 2
    if panel.w > w then
        x = at_end and (panel.x + panel.w - w) or panel.x
    end
    local y = panel.y + (panel.h - h) / 2
    if panel.h > h then
        y = at_end and (panel.y + panel.h - h) or panel.y
    end
    return {
        x = clampAxis(round(x), w, 0, dims.w),
        y = clampAxis(round(y), h, 0, dims.h),
        w = w,
        h = h,
    }
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
-- for a reader who long-pressed a point: that panel's *arrival* view is replaced
-- by the view they asked for, and everything after it is simulated from there.
-- Replacing rather than inserting is what keeps the steps before the touched panel
-- reachable — a tap in the middle of a page must not cut off everything above it —
-- and it is why the entry is found by the panel it belongs to and not by position.
--
-- Returns the step list and the index the viewer should open at, or nil when there
-- is nothing to walk.
function Viewport.steps(panels, dims, screen, entry)
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
            cur = touched
            push(i, cur)
            open_at = #steps
        elseif cur and contains(cur, panel) then
            -- Wholly visible already: read, and not a step. This is the skip.
        else
            cur = anchor(panel, w, h, dims, false)
            push(i, cur)
        end
        -- The part of this panel still unseen, before anything later is considered.
        -- Guarded on the view actually differing: a touch that landed on the panel's
        -- end corner is already there, and a step that moves nothing would make the
        -- forward gesture look broken.
        if not contains(cur, panel) then
            local last = anchor(panel, w, h, dims, true)
            if not samePlace(last, cur) then
                cur = last
                push(i, cur)
            end
        end
    end

    return steps, open_at
end

return Viewport
