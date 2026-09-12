--[[--
Finding the panels on a page, and the order a reader meets them in.

This is the detector behind the panel *sequence*: a long-press opens the panel
under the finger and then walks the rest of the page in reading order. Nothing
here knows what a document is — it takes a decoded BlitBuffer and returns
rectangles in that buffer's own coordinates, and the caller owns the buffer, the
page and the fetch.

## How a panel is found

The page is scaled down to a small scan, and what comes out of that scan is an
**ink map**: a cell is ink when its luminance is far enough from the page's
*own* estimated background. Then the map is walked for **8-connected components**
— a panel is one connected body of ink — and each component's bounding box is
scored by how much of its own boundary is supported by a straight (possibly
tilted) line. Boxes inside bigger boxes are dropped, boxes with no supporting
side are merged into a framed neighbour, and the survivors are the panels.

## Why this and not the recursive X-Y cut

This module used to cut the page on white gutters, recursively. That algorithm
is the one `panels_plus` ships *and does not use* — it is unreachable there
(`ComponentDetector` is hard-forced in three places and `Segmenter.detectPage`
has no caller), and the reference's own live detector is the one ported here.
Two failures made that visible on a device, and both are structural rather than
a matter of tuning:

* **A white band inside a drawing read as a gutter.** The cut splits wherever a
  band is clean across the whole region, and a bright sky strip or a white rule
  through a title card is exactly that — so a panel came back cut in two, on
  white, with no panel boundary anywhere near it. A component cannot be split
  that way: the ink runs around the band, so the band is inside one component
  and is never a boundary.
* **Tilted panels were not split at all.** The cut needs axis-aligned gutters,
  and the reference's only answer to skew (`segment_shear`) is off by default
  and was never ported. Connectivity does not know about axes.

So the fix for a tilted page is **connectivity, not a slope search** — worth
saying, because the obvious next move is to port the shear.

## What is not ported

* **the recursive cut**, for the reasons above — it is dead code in the
  reference and wrong here;
* **`component_holes`**, the optional pass that treats enclosed white regions as
  panels. It is off in the reference's own defaults, and its whole step — an
  inverted map, a second component walk, the nesting and edge-alignment tests —
  is omitted. That is the reference's default being honoured, not a judgement;
* **the comic border plane** (`segment_border_split`), also off by default;
* everything the reference hangs off its own live detector for *other* document
  kinds: the Leptonica/K2PDFOpt fallback for reflowable pages, and the embedded
  image path for EPUBs. Meguru's pages are always fixed-layout rasters.

## The coordinate space

Panels come back in the **full native page** space — the space `self.dims`
lives in, and the space `drawPagePart` expects. The scan's own coordinates never
escape this module. Note the conversion in `segment` deliberately produces
floats; see the comment there.

## Two things about the ffi arrays

`data`, `seen` and the BFS queue are `ffi.new` arrays, and this is the only
place in the plugin that reaches for one. That is deliberate — a map is dense
(every cell is read, by `hasFrame`, by the ink-share tests), it must be
**0-based** to keep the reference's index arithmetic faithful, and a 480x720
scan as two Lua tables would be ~8 MB of Lua heap on a device that already holds
three decoded pages. Two consequences to keep in mind when editing:

* **`#map.data` is not a length.** The length operator does not work on cdata
  arrays; `map.w` and `map.h` are the only sizes there are.
* **LuaJIT bounds-checks cdata only in debug builds.** A mis-clipped neighbour
  walk corrupts the heap instead of raising, so the column clipping in
  `collectComponents` is not a micro-optimisation to tidy away.
--]]

local ffi = require("ffi")
local RenderImage = require("ui/renderimage")

local Image = require("meguru/doc/image")

local Panel = {}

-- The scan's *width*, not its long side. The reference renders at
-- `zoom = min(1, segment_target_width / native.w)` and the difference is
-- load-bearing: a 1600x2400 page maps to 480x720, one cell per 3.3 page pixels,
-- so a 10-pixel printed gutter is 3 cells wide and survives 8-connectivity. A
-- cap on the long side would map it to 320x480 — one cell per 5 pixels, the
-- same gutter 2 cells wide, and diagonal bridging starts to close it.
local PANEL_SCAN_WIDTH = 480

-- A ceiling on the scan's cell count, and the only deviation from the
-- reference's sizing. With the width rule above, cells = 230400 * (h / w), so
-- this begins to bite past a 5.2:1 page — a manga page is 1.5:1 and a spread
-- 0.7:1, so the only shape it touches is a webtoon strip. Without it an
-- 800x20000 strip scans at 480x12000: 5.8 MB of map, as much again of `seen`
-- and 23 MB of queue, against a plugin whose whole native budget is 12 MB. With
-- it, that strip scans at 219x5477 — about 3.7 page pixels per cell — and a
-- strip is the one shape whose answer is "one panel, the whole page" anyway.
local PANEL_SCAN_MAX_CELLS = 1200000

-- How far a cell's luminance must depart from the page's own background to
-- count as ink. Relative, never absolute: this is what lets a white-on-black
-- page map the same way as a black-on-white one.
local PANEL_INK_DELTA = 40

-- The outer ring the background is sampled from, as a fraction of the shorter
-- side. A page's border is the one place guaranteed to be background.
local PANEL_BG_RING_FRAC = 0.01
-- The mid-grey band. A median background inside it may be an average of paper
-- and artwork rather than a colour the page contains, which is what the
-- near-white separator test below recovers from.
local PANEL_BG_MID_LO = 32
local PANEL_BG_MID_HI = 224
-- What "near-white" means to that test, how much of a row or column must be
-- that white to count as spanning, and how much of each axis is excluded as
-- interior margin.
local PANEL_SEPARATOR_MIN_LUMA = 245
local PANEL_SEPARATOR_FRAC = 0.80
local PANEL_SEPARATOR_EDGE_FRAC = 0.03

-- A component's boundary is "supported" when 80% of it lies within `tolerance`
-- of one straight line, and a line is only a candidate while its slope stays
-- under 0.35 cells per cell. The slope cap is the tilt limit — and because a
-- rejected slope simply means "this side does not count", a genuinely skewed
-- panel comes out with fewer supported sides and is treated as floating. That
-- is fine and is why connectivity, not a slope search, is what handles skew.
local PANEL_LINE_SLOPE_MAX = 0.35
local PANEL_LINE_ACCEPT = 0.80
-- The support tolerance, as a fraction of the map's shorter side, floored at
-- one cell.
local PANEL_FRAME_TOL_FRAC = 0.003

-- What counts as a component at all: a share of the map's width and height, and
-- of its area.
local PANEL_MIN_SIDE = 0.02
local PANEL_MIN_AREA = 0.002

-- A small box — below any of these — has to show a frame to be believed, and
-- `hasFrame` looks this many cells in from each edge.
local PANEL_SMALL_W_FRAC = 0.10
local PANEL_SMALL_H_FRAC = 0.10
local PANEL_SMALL_AREA_FRAC = 0.01
local PANEL_FRAME_BAND = 3
local PANEL_HAS_FRAME_FRAC = 0.8

-- A box with at least this many supported sides is "framed"; the rest are
-- "floating" and get merged into one.
local PANEL_COMPONENT_FRAME_MIN = 1
-- A floating box joins a framed one it overlaps vertically by at least this
-- share of its own height, and stands no further than this share of the map's
-- width away horizontally.
local PANEL_MERGE_OVERLAP = 0.7
local PANEL_MERGE_GAP_FRAC = 0.08

local PANEL_MAX_PANELS = 40

-- Acceptance. A lone panel is believed when it covers this much of the page, or
-- holds this much of the page's ink; otherwise the rest of the page was missed.
local PANEL_SINGLE_PANEL_RATIO = 0.6
local PANEL_SINGLE_INK_FRAC = 0.70
-- The furniture test: a contents or credits page is one near-full-height strip
-- beside a sparse stack. It needs this many candidates, that strip's height and
-- width bands, every other candidate entirely on the opposite side, and this
-- much ink-share and density contrast.
local PANEL_FURNITURE_MIN = 6
local PANEL_FURNITURE_STRIP_H = 0.90
local PANEL_FURNITURE_STRIP_WLO = 0.20
local PANEL_FURNITURE_STRIP_WHI = 0.50
local PANEL_FURNITURE_INK_FRAC = 0.75
local PANEL_FURNITURE_DOM_DENS = 0.60
local PANEL_FURNITURE_REST_DENS = 0.30
-- Coverage of the panels between them, and of the area they cover.
local PANEL_PAGE_COVERAGE_MIN = 0.4
local PANEL_COVERAGE_MIN = 0.5

-- ---------------------------------------------------------------------------
-- Small shared helpers
-- ---------------------------------------------------------------------------

local function rectUnion(a, b)
    local x = math.min(a.x, b.x)
    local y = math.min(a.y, b.y)
    local right = math.max(a.x + a.w, b.x + b.w)
    local bottom = math.max(a.y + a.h, b.y + b.h)
    return { x = x, y = y, w = right - x, h = bottom - y }
end

-- ---------------------------------------------------------------------------
-- The ink map
-- ---------------------------------------------------------------------------

-- Is there a near-white line running across (or down) the page?
--
-- The interior margins are excluded — a page's own edge is not a separator —
-- and the early exits are what keep this cheap: once enough of a line has been
-- seen it answers yes, and once the cells left cannot reach the threshold it
-- stops looking at that line. Both bounds use `>=` against a count that can
-- only grow, so neither can skip a qualifying line.
local function hasWhiteSeparator(raster)
    local w, h = raster.w, raster.h
    local luma = raster.luma
    local x_margin = math.max(1, math.floor(w * PANEL_SEPARATOR_EDGE_FRAC))
    local y_margin = math.max(1, math.floor(h * PANEL_SEPARATOR_EDGE_FRAC))
    local row_required = math.ceil(w * PANEL_SEPARATOR_FRAC)
    local col_required = math.ceil(h * PANEL_SEPARATOR_FRAC)
    for y = y_margin, h - 1 - y_margin do
        local bright = 0
        for x = 0, w - 1 do
            if luma(y, x) >= PANEL_SEPARATOR_MIN_LUMA then
                bright = bright + 1
            end
            if bright >= row_required then
                return true
            end
            if bright + w - 1 - x < row_required then
                break
            end
        end
    end
    for x = x_margin, w - 1 - x_margin do
        local bright = 0
        for y = 0, h - 1 do
            if luma(y, x) >= PANEL_SEPARATOR_MIN_LUMA then
                bright = bright + 1
            end
            if bright >= col_required then
                return true
            end
            if bright + h - 1 - y < col_required then
                break
            end
        end
    end
    return false
end

-- The page's background: the median luminance of its outer ring, with one
-- correction.
--
-- Median and not mean, because a ring that is three quarters paper and one
-- quarter a bleed has a mean somewhere in between — a colour the page does not
-- contain anywhere. The correction covers the other failure: a mid-grey median
-- may be paper dimmed by a scan, and if some row or column of the page is
-- genuinely near-white, that white is the paper and the median is a lie. Seeing
-- one spanning near-white line is the evidence for it.
local function backgroundFor(raster)
    local w, h = raster.w, raster.h
    local ring = math.max(1, math.floor(math.min(w, h) * PANEL_BG_RING_FRAC))
    local bins = {}
    local total = 0
    local luma = raster.luma
    local function sample(x, y)
        local v = math.floor(luma(y, x))
        if v < 0 then v = 0 elseif v > 255 then v = 255 end
        bins[v] = (bins[v] or 0) + 1
        total = total + 1
    end
    for y = 0, h - 1 do
        if y < ring or y >= h - ring then
            for x = 0, w - 1 do
                sample(x, y)
            end
        else
            for x = 0, ring - 1 do
                sample(x, y)
            end
            for x = w - ring, w - 1 do
                sample(x, y)
            end
        end
    end
    if total == 0 then
        return 255
    end
    local half = total / 2
    local seen = 0
    for v = 0, 255 do
        seen = seen + (bins[v] or 0)
        if seen >= half then
            if v >= PANEL_BG_MID_LO and v < PANEL_BG_MID_HI
                and hasWhiteSeparator(raster) then
                return 255
            end
            return v
        end
    end
    return 255
end

-- The ink map over the scan, as a dense 0-based byte array.
--
-- `native_w`/`native_h` are the *page's* size, not the scan's: `scale_x` and
-- `scale_y` are what turn a cell back into page pixels, and the scan is one
-- step on the way rather than the thing being measured.
local function buildInkMap(raster, bg, native_w, native_h)
    local w, h = raster.w, raster.h
    local data = ffi.new("uint8_t[?]", w * h)
    local luma = raster.luma
    local ink = 0
    for y = 0, h - 1 do
        local base = y * w
        for x = 0, w - 1 do
            local d = luma(y, x) - bg
            if d < 0 then d = -d end
            if d > PANEL_INK_DELTA then
                data[base + x] = 1
                ink = ink + 1
            end
        end
    end
    return {
        w = w,
        h = h,
        data = data,
        ink = ink,
        native_w = native_w,
        native_h = native_h,
        scale_x = native_w / w,
        scale_y = native_h / h,
    }
end

-- ---------------------------------------------------------------------------
-- Connected components
-- ---------------------------------------------------------------------------

-- The fraction of `values[first..last]` that lies within `tolerance` of one
-- straight line, with the line's slope drawn from two anchors rather than
-- searched.
--
-- Pairs of well-separated anchors, not a least-squares fit: a speech balloon
-- poking through one corner of a panel should not drag the line, and a curve
-- (a face, a balloon outline) supports no straight line across most of its
-- extent, which is exactly what this is meant to say no to.
--
-- The 0.35 slope cap is the tilt limit, and it is deliberately generous: a
-- printed frame on a slightly skewed scan is still a frame.
local function lineSupport(values, first, last, tolerance)
    local span = last - first
    if span <= 0 then
        return 0
    end
    local best = 0
    for a = 0, 4 do
        for b = a + 3, 8 do
            local i = first + math.floor(span * a / 8)
            local j = first + math.floor(span * b / 8)
            local slope = (values[j] - values[i]) / (j - i)
            if math.abs(slope) <= PANEL_LINE_SLOPE_MAX then
                local count = 0
                for k = first, last do
                    if math.abs(values[k] - values[i] - (k - i) * slope) <= tolerance then
                        count = count + 1
                    end
                end
                local ratio = count / (span + 1)
                if ratio > best then
                    best = ratio
                    if best >= PANEL_LINE_ACCEPT then
                        return best
                    end
                end
            end
        end
    end
    return best
end

-- How many of a component's four sides are supported by a straight line, 0-4.
--
-- Built from the *extents* of the component's pixels — the leftmost and
-- rightmost x per row, the topmost and bottommost y per column — so what is
-- measured is the component's own outline, not a drawn frame. That is what lets
-- a borderless panel be framed: its artwork is a rectangle, so its own edges
-- support lines even though nothing was drawn around it.
--
-- `queue` holds the component's pixel indices and `count` how many of them
-- there are; both are left exactly as `collectComponents` built them.
local function frameSides(queue, count, map_width, box, tolerance)
    -- A finite "no pixel here" sentinel rather than `math.huge`, because these
    -- values are subtracted from each other inside `lineSupport`: two infinite
    -- ones would produce a `nan` and a `nan` comparison is false everywhere, so
    -- the failure would be a side silently never counting rather than an error.
    -- The sentinel can never actually survive — every row between a component's
    -- top and bottom holds one of its pixels, since an 8-connected path steps a
    -- row at a time — but relying on that proof to keep arithmetic finite is not
    -- a trade worth making.
    local NONE = 100000000
    local left, right, top, bottom = {}, {}, {}, {}
    for y = box.y, box.y + box.h - 1 do
        left[y], right[y] = NONE, -1
    end
    for x = box.x, box.x + box.w - 1 do
        top[x], bottom[x] = NONE, -1
    end
    for index = 0, count - 1 do
        local p = queue[index]
        local y = math.floor(p / map_width)
        local x = p - y * map_width
        if x < left[y] then
            left[y] = x
        end
        if x > right[y] then
            right[y] = x
        end
        if y < top[x] then
            top[x] = y
        end
        if y > bottom[x] then
            bottom[x] = y
        end
    end
    local sides = 0
    if lineSupport(left, box.y, box.y + box.h - 1, tolerance) >= PANEL_LINE_ACCEPT then
        sides = sides + 1
    end
    if lineSupport(right, box.y, box.y + box.h - 1, tolerance) >= PANEL_LINE_ACCEPT then
        sides = sides + 1
    end
    if lineSupport(top, box.x, box.x + box.w - 1, tolerance) >= PANEL_LINE_ACCEPT then
        sides = sides + 1
    end
    if lineSupport(bottom, box.x, box.x + box.w - 1, tolerance) >= PANEL_LINE_ACCEPT then
        sides = sides + 1
    end
    return sides
end

-- Every substantial 8-connected body of ink, as a bounding box with its
-- supported-side count.
--
-- The map is never modified: `seen` is a separate byte array used as both the
-- "already queued" flag and the visited mask, set at **enqueue** time. That one
-- detail is load-bearing twice over — it is what makes a pixel reachable from
-- two neighbours queue only once, and it is why the queue can be sized to the
-- map's ink count rather than to the whole map (see the allocation below).
--
-- The neighbour walk clips the column range once per dequeued pixel instead of
-- once per neighbour. That is not tidying: the inner loop then runs over a
-- contiguous range, and — more to the point — mis-clipping it is a heap
-- corruption rather than an error, because release LuaJIT does not bounds-check
-- cdata.
local function collectComponents(map, min_side, min_area)
    local width, height, data = map.w, map.h, map.data
    local seen = ffi.new("uint8_t[?]", width * height)
    -- Sized to the ink count, not to the map. The BFS only ever enqueues a cell
    -- with `data[i] == 1`, and it marks `seen` as it does, so the queue can
    -- never hold more than the number of ink cells in the whole page — not per
    -- component, which is why one queue serves the entire scan. **If `seen` is
    -- ever moved to dequeue time this becomes an overrun**, so the reason has to
    -- travel with the allocation and not just the number.
    local queue = ffi.new("int32_t[?]", math.max(1, map.ink + 1))
    local components = {}
    local tolerance = math.max(1, math.min(width, height) * PANEL_FRAME_TOL_FRAC)

    for index = 0, width * height - 1 do
        if data[index] == 1 and seen[index] == 0 then
            local head, tail = 0, 1
            queue[0], seen[index] = index, 1
            local left, right, top, bottom = width, 0, height, 0
            while head < tail do
                local position = queue[head]
                head = head + 1
                local y = math.floor(position / width)
                local x = position - y * width
                if x < left then
                    left = x
                end
                if x > right then
                    right = x
                end
                if y < top then
                    top = y
                end
                if y > bottom then
                    bottom = y
                end
                local first_x = math.max(0, x - 1)
                local last_x = math.min(width - 1, x + 1)
                for ny = math.max(0, y - 1), math.min(height - 1, y + 1) do
                    local row = ny * width
                    for neighbor = row + first_x, row + last_x do
                        if seen[neighbor] == 0 and data[neighbor] == 1 then
                            seen[neighbor] = 1
                            queue[tail] = neighbor
                            tail = tail + 1
                        end
                    end
                end
            end
            local w, h = right - left + 1, bottom - top + 1
            if w >= width * min_side and h >= height * min_side and w * h >= min_area then
                local box = { x = left, y = top, w = w, h = h }
                box.frame_sides = frameSides(queue, tail, width, box, tolerance)
                components[#components + 1] = box
            end
        end
    end
    return components
end

-- Does a small box have ink along all four of its edges?
--
-- The rule that keeps a large letter or an isolated face from qualifying on
-- size alone. Each edge is sampled across a band a few cells wide, so a box
-- whose content merely touches the corner is not framed.
local function hasFrame(map, box)
    local top, bottom, left, right = 0, 0, 0, 0
    local band = math.min(PANEL_FRAME_BAND, box.w, box.h)
    local data, map_w = map.data, map.w
    for x = box.x, box.x + box.w - 1 do
        for offset = 0, band - 1 do
            if data[(box.y + offset) * map_w + x] == 1 then
                top = top + 1
                break
            end
        end
        for offset = 0, band - 1 do
            if data[(box.y + box.h - 1 - offset) * map_w + x] == 1 then
                bottom = bottom + 1
                break
            end
        end
    end
    for y = box.y, box.y + box.h - 1 do
        for offset = 0, band - 1 do
            if data[y * map_w + box.x + offset] == 1 then
                left = left + 1
                break
            end
        end
        for offset = 0, band - 1 do
            if data[y * map_w + box.x + box.w - 1 - offset] == 1 then
                right = right + 1
                break
            end
        end
    end
    return top > box.w * PANEL_HAS_FRAME_FRAC and bottom > box.w * PANEL_HAS_FRAME_FRAC
        and left > box.h * PANEL_HAS_FRAME_FRAC and right > box.h * PANEL_HAS_FRAME_FRAC
end

-- ---------------------------------------------------------------------------
-- Acceptance
-- ---------------------------------------------------------------------------

-- A contents or credits page is a tall illustration with a sparse stack of text
-- beside it, which is a shape a panel detector can honestly mistake for a
-- panel and a column of panels. It is told apart by ink: the illustration owns
-- nearly all of it and the "panels" are almost empty.
--
-- Deliberately narrow — six candidates, one near-full-height strip of a
-- particular width, every other candidate entirely on the opposite side, and a
-- wide density contrast — so a real manga page cannot match it. The gate sits
-- after ordinary detection rather than inside it, so no normal panel boundary
-- is ever changed by it.
local function looksLikePageFurnitureLayout(panels, map)
    if #panels < PANEL_FURNITURE_MIN or not map.data or not map.ink or map.ink <= 0 then
        return false
    end

    local page_w, page_h = map.native_w, map.native_h
    local dominant_index, dominant = nil, nil
    for index, panel in ipairs(panels) do
        if panel.h >= page_h * PANEL_FURNITURE_STRIP_H
            and panel.w >= page_w * PANEL_FURNITURE_STRIP_WLO
            and panel.w <= page_w * PANEL_FURNITURE_STRIP_WHI
            and (not dominant or panel.w * panel.h > dominant.w * dominant.h)
        then
            dominant_index, dominant = index, panel
        end
    end
    if not dominant then
        return false
    end

    local strip_on_left = (dominant.x + dominant.w / 2) < page_w / 2
    for index, panel in ipairs(panels) do
        if index ~= dominant_index then
            if strip_on_left then
                if panel.x < dominant.x + dominant.w * 0.90 then
                    return false
                end
            elseif panel.x + panel.w > dominant.x + dominant.w * 0.10 then
                return false
            end
        end
    end

    -- A panel's rectangle is one cell wider than the box it came from (see the
    -- expansion in `segment`), so this mapping can reach past the map on both
    -- ends and has to be clamped at each.
    local function panelInk(panel)
        local x0 = math.max(0, math.floor(panel.x / map.scale_x))
        local y0 = math.max(0, math.floor(panel.y / map.scale_y))
        local x1 = math.min(map.w - 1, math.floor((panel.x + panel.w) / map.scale_x))
        local y1 = math.min(map.h - 1, math.floor((panel.y + panel.h) / map.scale_y))
        local ink = 0
        for y = y0, y1 do
            local base = y * map.w
            for x = x0, x1 do
                if map.data[base + x] == 1 then
                    ink = ink + 1
                end
            end
        end
        return ink, math.max(1, (x1 - x0 + 1) * (y1 - y0 + 1))
    end

    local dominant_ink, dominant_cells = panelInk(dominant)
    if dominant_ink / map.ink < PANEL_FURNITURE_INK_FRAC
        or dominant_ink / dominant_cells < PANEL_FURNITURE_DOM_DENS then
        return false
    end

    local minor_ink, minor_cells = 0, 0
    for index, panel in ipairs(panels) do
        if index ~= dominant_index then
            local ink, cells = panelInk(panel)
            minor_ink = minor_ink + ink
            minor_cells = minor_cells + cells
        end
    end
    return minor_cells > 0 and minor_ink / minor_cells < PANEL_FURNITURE_REST_DENS
end

-- Is this segmentation worth showing to a reader?
--
-- Returns `true`, or `false` and the test that refused — the reason reaches the
-- log, which is the only way to tell a page that genuinely has one panel from
-- one the detector failed on.
local function accept(panels, map)
    local count = #panels
    if count == 0 then
        return false, "no panels"
    end

    local page_area = map.native_w * map.native_h
    local total_area, largest_area = 0, 0
    local min_x, min_y = math.huge, math.huge
    local max_x, max_y = 0, 0
    for _, panel in ipairs(panels) do
        local area = panel.w * panel.h
        total_area = total_area + area
        if area > largest_area then
            largest_area = area
        end
        min_x = math.min(min_x, panel.x)
        min_y = math.min(min_y, panel.y)
        max_x = math.max(max_x, panel.x + panel.w)
        max_y = math.max(max_y, panel.y + panel.h)
    end

    -- One panel, decided before anything else. A rectangle covering most of the
    -- page is the right answer twice over: it is what a splash page is, and it
    -- is the best any detector can do on a layout with no way in — so refusing
    -- it would only cost a full-resolution render to reach the same rectangle.
    -- A *small* lone rectangle is different: the detector latched onto one blob
    -- and missed the rest, which is worth saying no to.
    if count == 1 then
        if largest_area >= page_area * PANEL_SINGLE_PANEL_RATIO then
            return true
        end
        if map.ink and map.ink > 0 and map.data then
            local panel = panels[1]
            local mx0 = math.max(0, math.floor(panel.x / map.scale_x))
            local my0 = math.max(0, math.floor(panel.y / map.scale_y))
            local mx1 = math.min(map.w - 1, math.floor((panel.x + panel.w) / map.scale_x))
            local my1 = math.min(map.h - 1, math.floor((panel.y + panel.h) / map.scale_y))
            local p_ink = 0
            for y = my0, my1 do
                local base = y * map.w
                for x = mx0, mx1 do
                    if map.data[base + x] == 1 then
                        p_ink = p_ink + 1
                    end
                end
            end
            -- Almost all the page's ink inside the one box means the rest of
            -- the page is blank margin — an omake, a bonus strip, a chapter-end
            -- illustration — rather than a layout that went unfound.
            if p_ink >= map.ink * PANEL_SINGLE_INK_FRAC then
                return true
            end
        end
        return false, "single partial panel"
    end

    if looksLikePageFurnitureLayout(panels, map) then
        return false, "page furniture mistaken for panels"
    end

    local covered_area = (max_x - min_x) * (max_y - min_y)
    if covered_area < page_area * PANEL_PAGE_COVERAGE_MIN then
        return false, "panels cover too little of the page"
    end
    if total_area < covered_area * PANEL_COVERAGE_MIN then
        return false, string.format("only %d%% of the covered area kept",
            math.floor(total_area * 100 / covered_area))
    end

    return true
end

-- ---------------------------------------------------------------------------
-- The detector
-- ---------------------------------------------------------------------------

-- Candidate panel rectangles, in native coordinates, unordered.
--
-- The policy, in order, and each step is one of the reference's:
--
--   1. components below `min_side`/`min_area` never became boxes at all;
--   2. a box inside a bigger one is dropped — that removes a speech balloon
--      held inside a frame, at the cost of also removing an intentional inset;
--   3. a *small* box has to show a frame to be believed, or all four of its
--      edges need ink within a few cells;
--   4. boxes with a supported side are "framed", the rest "floating", and with
--      none framed at all there is nothing to stand on — the page is refused;
--   5. a floating box is unioned into the framed box it best overlaps, or, if
--      it overlaps none, grouped with the other floaters at the same height and
--      unioned per group.
--
-- Returns `{}` — not a partial page — when there are more than `PANEL_MAX_PANELS`
-- panels, so the caller falls back rather than showing half a page's panels.
local function segment(map)
    local components = collectComponents(map, PANEL_MIN_SIDE, map.w * map.h * PANEL_MIN_AREA)
    local cells = {}
    for _, box in ipairs(components) do
        local keep = true
        for _, other in ipairs(components) do
            if other ~= box
                and other.w * other.h > box.w * box.h
                and box.x >= other.x - 1
                and box.y >= other.y - 1
                and box.x + box.w <= other.x + other.w + 1
                and box.y + box.h <= other.y + other.h + 1
            then
                keep = false
                break
            end
        end
        if keep and (box.w < map.w * PANEL_SMALL_W_FRAC
            or box.h < map.h * PANEL_SMALL_H_FRAC
            or box.w * box.h < map.w * map.h * PANEL_SMALL_AREA_FRAC) then
            -- Reassigned, not narrowed: a fully framed small box is believed
            -- without the edge scan, which is the cheaper of the two tests.
            keep = box.frame_sides == 4 or hasFrame(map, box)
        end
        if keep then
            cells[#cells + 1] = box
        end
    end

    local framed, floating = {}, {}
    for _, box in ipairs(cells) do
        if box.frame_sides >= PANEL_COMPONENT_FRAME_MIN then
            framed[#framed + 1] = box
        else
            floating[#floating + 1] = box
        end
    end
    if #framed == 0 then
        return {}
    end

    local groups = {}
    for _, box in ipairs(floating) do
        local target, distance
        for _, other in ipairs(framed) do
            local overlap = math.max(0,
                math.min(box.y + box.h, other.y + other.h) - math.max(box.y, other.y))
            local gap = math.max(0, other.x - box.x - box.w, box.x - other.x - other.w)
            if overlap >= box.h * PANEL_MERGE_OVERLAP
                and gap <= map.w * PANEL_MERGE_GAP_FRAC
                and (not distance or gap < distance) then
                target, distance = other, gap
            end
        end
        if target then
            -- The union is written back into the framed box, so a box that has
            -- already absorbed one floater can absorb another, and a merged box
            -- can end up containing one that survived beside it. That is why
            -- `Panel.indexAt` prefers the smallest containing panel.
            local union = rectUnion(target, box)
            target.x, target.y, target.w, target.h = union.x, union.y, union.w, union.h
        else
            local above = 0
            for _, other in ipairs(framed) do
                if other.y + other.h <= box.y then
                    above = above + 1
                end
            end
            groups[above] = groups[above] and rectUnion(groups[above], box) or box
        end
    end
    for _, box in pairs(groups) do
        framed[#framed + 1] = box
    end

    -- Cell -> native, expanding one cell on every side first: a cell is up to
    -- `scale` page pixels wide, so the content's true edge can sit up to a cell
    -- beyond the cells the component was found in. **The expansion stays in the
    -- result** — there is no compensating step — which is why the ink-share
    -- tests above clamp their mapping back into the map.
    --
    -- These are floats, and deliberately not rounded: everything downstream
    -- compares or multiplies them, and the one place a rect becomes a string —
    -- `panelTileKey` — formats with `%d`, so two rects a fraction apart cannot
    -- mint two keys for one tile.
    local panels = {}
    for _, box in ipairs(framed) do
        local x = math.max(0, (box.x - 1) * map.scale_x)
        local y = math.max(0, (box.y - 1) * map.scale_y)
        local right = math.min(map.native_w, (box.x + box.w + 1) * map.scale_x)
        local bottom = math.min(map.native_h, (box.y + box.h + 1) * map.scale_y)
        panels[#panels + 1] = { x = x, y = y, w = right - x, h = bottom - y }
    end
    if #panels > PANEL_MAX_PANELS then
        return {}
    end
    return panels
end

-- ---------------------------------------------------------------------------
-- Reading order
-- ---------------------------------------------------------------------------

-- Group the panels into rows by their top edge.
--
-- Every member is measured against the row's own **fixed** top and never
-- chained from the previous member: with a chain, a staircase of slightly lower
-- panels grows one row all the way down the page. The tolerance shrinks with
-- the shortest member seen so far, so a row of small panels cannot swallow a
-- tall neighbour — and a borderless panel's ink often starts below its framed
-- neighbour's top edge, which is the offset this tolerance exists to forgive.
local function buildRows(panels)
    local sorted = {}
    for i, p in ipairs(panels) do
        sorted[i] = p
    end
    table.sort(sorted, function(a, b)
        if a.y ~= b.y then
            return a.y < b.y
        end
        return a.x < b.x
    end)

    local rows = {}
    for _, p in ipairs(sorted) do
        local height = math.max(1, p.h)
        local best_row, best_distance
        for _, row in ipairs(rows) do
            local distance = math.abs(p.y - row.top)
            local tolerance = math.min(height, row.min_h) * 0.35
            if distance <= tolerance and (not best_distance or distance < best_distance) then
                best_row, best_distance = row, distance
            end
        end
        if not best_row then
            best_row = { top = p.y, min_h = height, members = {} }
            rows[#rows + 1] = best_row
        else
            best_row.min_h = math.min(best_row.min_h, height)
        end
        best_row.members[#best_row.members + 1] = p
    end
    return rows
end

-- Is every part of `later` on the leading side of `panel`? The leading side is
-- the left for a comic and the right for a manga.
local function isLeadingOf(later, panel, manga)
    if manga then
        return later.x >= panel.x + panel.w
    end
    return later.x + later.w <= panel.x
end

-- The reading order, with the deferred trailing panel.
--
-- A panel that is not its row's first can sit *beside* a tall neighbour in a
-- later row rather than above it — a wide strip at the top of the layout with
-- the stack it belongs after running down one side. Emitting row by row would
-- put it before that stack; holding it until the last later row it overlaps
-- puts it after, which is the order the page is read in
-- (1,2,3,5,6,7,4 rather than 1,2,3,4,5,6,7).
local function sortReadingOrder(panels, manga)
    local rows = buildRows(panels)
    local sorted = {}
    local deferred = {}
    for row_index, row in ipairs(rows) do
        table.sort(row.members, function(a, b)
            if a.x == b.x then
                return a.y < b.y
            end
            if manga then
                return a.x > b.x
            end
            return a.x < b.x
        end)
        for item_index, panel in ipairs(row.members) do
            local defer_until = row_index
            if item_index > 1 then
                local bottom = panel.y + math.max(1, panel.h)
                for later_index = row_index + 1, #rows do
                    if rows[later_index].top >= bottom then
                        break -- later rows start below this panel: no overlap
                    end
                    for _, later in ipairs(rows[later_index].members) do
                        if isLeadingOf(later, panel, manga) then
                            defer_until = later_index
                            break
                        end
                    end
                end
            end
            if defer_until > row_index then
                deferred[defer_until] = deferred[defer_until] or {}
                table.insert(deferred[defer_until], panel)
            else
                sorted[#sorted + 1] = panel
            end
        end
        if deferred[row_index] then
            for _, panel in ipairs(deferred[row_index]) do
                sorted[#sorted + 1] = panel
            end
            deferred[row_index] = nil
        end
    end
    -- Every hold is bounded by a later row index, so the loop above flushes all
    -- of them; this is here so that a future change to the hold rule ends with
    -- the panel somewhere rather than nowhere.
    for row_index = 1, #rows do
        if deferred[row_index] then
            for _, panel in ipairs(deferred[row_index]) do
                sorted[#sorted + 1] = panel
            end
            deferred[row_index] = nil
        end
    end
    for i, panel in ipairs(sorted) do
        panels[i] = panel
    end
    return panels
end

-- ---------------------------------------------------------------------------
-- The module
-- ---------------------------------------------------------------------------

-- The panels of one page, in reading order.
--
-- Returns `panels, accepted, reason`, and **`panels` is never empty once
-- `native_bb` was readable**: a page the detector could not make sense of comes
-- back as a single rectangle covering the whole page, with `accepted` false and
-- the failing test in `reason`. The caller can therefore always open something,
-- and the log can always say which of the two it is looking at. `nil` means one
-- thing only — there was no page buffer to read.
--
-- `native_bb` belongs to the document's native LRU and is **not** freed here.
-- The scan copy this makes is freed on every path out.
function Panel.detect(native_bb, manga)
    if not native_bb then
        return nil, false, "no page buffer"
    end
    local raster = Image.rasterFor(native_bb)
    if not raster then
        return nil, false, "unreadable page buffer"
    end
    local native_w, native_h = raster.w, raster.h

    local scan = native_bb
    local sw, sh = native_w, native_h
    local scale = math.min(1,
        PANEL_SCAN_WIDTH / native_w,
        math.sqrt(PANEL_SCAN_MAX_CELLS / (native_w * native_h)))
    if scale < 1 then
        sw = math.max(2, math.floor(native_w * scale + 0.5))
        sh = math.max(2, math.floor(native_h * scale + 0.5))
        local ok_scale, scaled = pcall(RenderImage.scaleBlitBuffer,
            RenderImage, native_bb, sw, sh, false)
        if ok_scale and scaled then
            scan = scaled
        else
            sw, sh = native_w, native_h -- best effort: scan the page as it is
        end
    end

    local ok_raster, scan_raster = pcall(Image.rasterFor, scan)
    if scan ~= native_bb then
        -- The scan copy is C-side owned, so it is freed here whatever the
        -- raster accessor did with it.
        scan:free()
    end
    if not ok_raster or not scan_raster then
        return nil, false, "unreadable page scan"
    end

    local map = buildInkMap(scan_raster, backgroundFor(scan_raster), native_w, native_h)
    local panels = segment(map)
    local accepted, reason = accept(panels, map)
    if not accepted then
        return { { x = 0, y = 0, w = native_w, h = native_h } }, false, reason
    end
    return sortReadingOrder(panels, manga and true or false), true
end

-- Which panel a point falls in, or the nearest one when it falls in a gutter.
--
-- The **smallest** containing panel wins rather than the first in reading
-- order, because the floating merge unions boxes in place and a merged box can
-- therefore contain one that survived beside it. The union is the bigger
-- rectangle; the panel it swallowed is the more specific answer to "which panel
-- is under the finger".
--
-- The nearest-by-centre fallback has to exist: a press that lands on a
-- separator is a reader aiming at a panel, and refusing to answer would turn
-- the gesture into a no-op for no better reason than that they missed.
-- Returns nil only when there are no panels at all.
function Panel.indexAt(panels, x, y)
    if not (panels and #panels > 0) then
        return nil
    end
    if not (x and y) then
        return nil
    end
    local inside, inside_area
    local nearest, nearest_d
    for i, p in ipairs(panels) do
        if x >= p.x and x <= p.x + p.w and y >= p.y and y <= p.y + p.h then
            local area = p.w * p.h
            if not inside_area or area < inside_area then
                inside, inside_area = i, area
            end
        end
        local dx = x - (p.x + p.w / 2)
        local dy = y - (p.y + p.h / 2)
        local d = dx * dx + dy * dy
        if not nearest_d or d < nearest_d then
            nearest, nearest_d = i, d
        end
    end
    return inside or nearest
end

return Panel
