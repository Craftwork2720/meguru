--[[--
Finding the panels on a page, and the order a reader meets them in.

This is the detector behind the panel *sequence*: a long-press opens the panel
under the finger and then walks the rest of the page in reading order. Nothing
here knows what a document is — it takes a decoded BlitBuffer and returns
rectangles in that buffer's own coordinates, and the caller owns the buffer, the
page and the fetch.

## How a panel is found

The page is scaled down to a small scan, and what comes out of that scan is an
**ink map**: a cell is ink when its luminance is far enough from the page's own
estimated background. The map is then sliced by a **recursive X-Y cut**: find the
widest empty band across the region, split there, and recurse into both halves
until a region has no empty band left. Comic and manga pages are laid out as
nested bands — a page splits into tiers, a tier into panels — so slicing on the
widest empty band reproduces that structure directly.

Two things complicate the cut, and both are ported:

* **Panels are not always square.** A gutter tilted by two degrees leaves no
  column empty from top to bottom, which stops the straight cut dead. When no
  straight gutter exists and something already looks part-empty, a ladder of
  slopes from 2 to 8 degrees either way is tried instead
  (`PANEL_SHEAR_SLOPES`), and the projection is taken along the slanted line.
  The split is then **one line through the middle of the empty run that
  projection found**, which is where the separator sits at the region's own
  mid-height. A rectangle cannot follow a slanted separator, so each child keeps
  a wedge of its neighbour on one side and gives one up on the other; what the
  cut must not do is land `drift` cells off the separator, which is where the
  band the run maps to put it.
* **A page furniture strip is not a panel.** A scanlation credit line clears both
  size floors comfortably and would be shown to the reader as a panel holding no
  artwork. `emitLeaf` rejects it on the *conjunction* of elongated and nearly
  inkless — neither test alone works, and the table in that function's comment is
  the measurement that says so.

## Why the thresholds matter more than the algorithm

The numbers below are **1.3's**, and they are not to be "tidied" towards the
reference's later ones: porting that version's cut *with that version's defaults*
is what produced two of this detector's device failures. The thresholds, the
failures and the reasoning live in **CLAUDE.md, "Panel zoom, and the panel
sequence"** — one copy, deliberately, because a second copy of a threshold is a
second answer waiting to happen.

The connected-component detector that later version switched to is deliberately
**not** ported. It keeps a component and the panel it sits inside as two separate
boxes, because it merges only boxes that entirely contain one another, and the
symptom a reader sees is the same panel appearing twice with slightly different
crops. The cut cannot produce that: its leaves are disjoint by construction, each
one a region no gutter divides.

## What is not ported

* **the drawn-border pass** (`segment_border_split`). It exists for western comics
  whose panels bleed edge to edge with only an artist's black stroke between
  them. It is off in 1.3's own defaults, and the source gives a good reason to
  leave it there: at ink-map resolution a shared border between two panels and a
  black line drawn *through* one panel — a horizon, a caption rule, a letterbox
  band — produce byte-identical maps, so the pass splits real panels in half on
  any page carrying such a line. Off, those pages read correctly and genuinely
  bled layouts fall back to "one panel instead of two", which costs the reader
  far less than a panel cut in half.
* **`component_holes`** and the whole component pipeline, for the reason above.
* **the Leptonica/K2PDFOpt fallback** the reference reaches for when a map cannot
  be built at all. Meguru's pages are always fixed-layout rasters of a known
  format, so a map that cannot be built is a page that cannot be decoded.

## A panel is a quadrilateral, and its rectangle is only the box around it

The cut reasons about rectangles because every projection and every gutter in it
is axis-aligned, but the panel a reader is shown is bounded by *lines* — and a
panel whose borders are slanted is the case this detector exists for. So a leaf
carries both: `x, y, w, h` is the bounding rectangle, and `planes` is the four
half-planes of the quadrilateral inside it, `A*x + B*y + C <= 0` for the inside.

The two are the same rectangle on a page whose panels are square, and differ by
a wedge wherever one is not — which is the wedge a rectangle crop cannot help
showing, and the reason the crop follows `planes` instead. `meguru/doc/image`
masks the rendered tile to them; `Panel.indexAt` tests a touch against them.

## The coordinate space

Panels come back in the **full native page** space — the space `self.dims` lives
in, and the space `drawPagePart` expects. The scan's own coordinates never escape
this module. Note the cell→native conversion in `segment` deliberately produces
floats; see the comment there.

## Two things about the ffi arrays

The ink map and the two projection accumulators — one per axis, reused by every
node of the recursion — are all `ffi.new` arrays, and this is the only place in
the plugin that reaches for one. That is deliberate: a map is dense (every cell
is read, many times), it must be **0-based** to keep the reference's index
arithmetic faithful, and a 480x720 scan as a Lua table would be megabytes of heap
on a device that already holds three decoded pages. Two consequences to keep in
mind when editing:

* **`#map.data` is not a length.** The length operator does not work on cdata
  arrays; `map.w` and `map.h` are the only sizes there are.
* **LuaJIT bounds-checks cdata only in debug builds.** A mis-clipped traversal
  corrupts the heap instead of raising, so the range arithmetic in `project` and
  the two sheared projections is not a style choice.
--]]

local ffi = require("ffi")
local RenderImage = require("ui/renderimage")

local Image = require("meguru/doc/image")

local Panel = {}

-- The scan's *width*, not its long side. The reference renders at
-- `zoom = min(1, segment_target_width / native.w)` and the difference is
-- load-bearing: a 1600x2400 page maps to 480x720, one cell per 3.3 page pixels,
-- so a 10-pixel printed gutter is 3 cells wide and survives as a detectable
-- band. A cap on the long side would map it to 320x480 — one cell per 5 pixels,
-- the same gutter 2 cells wide, and against a `min_gutter` of 2 the cut starts
-- losing them.
local PANEL_SCAN_WIDTH = 480

-- A ceiling on the scan's cell count, and the only deviation from the
-- reference's sizing. With the width rule above, cells = 230400 * (h / w), so
-- this begins to bite past a 5.2:1 page — a manga page is 1.5:1 and a spread
-- 0.7:1, so the only shape it touches is a webtoon strip. Without it an
-- 800x20000 strip scans at 480x12000, some 35 MB of arrays, on a plugin whose
-- whole native budget is 12 MB. With it, that strip scans at 219x5477 — about
-- 3.7 page pixels per cell — and a strip is the one shape whose answer is "one
-- panel, the whole page" anyway.
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

-- **The number this detector lives or dies by.** What fraction of a line's span
-- may still carry ink and have the line count as empty. 1.3's 0.005 is ten times
-- stricter than the later version's 0.05, and the difference is a white band
-- inside a drawing: at 0.05 a faintly bright strip reads as a gutter and the cut
-- splits the panel in half, and at 0.005 it has to be genuinely empty to count.
local PANEL_GUTTER_INK_RATIO = 0.005
-- The thinnest band worth splitting on, as a fraction of the map's shorter side,
-- floored at two cells. A fraction of the *map*, so it stays a fixed fraction of
-- the page whatever the scan resolution is — raising the resolution alone does
-- not make narrower gutters detectable, the ratio has to come down with it.
local PANEL_GUTTER_RATIO = 0.005

-- A leaf smaller than either of these is not a panel: it is a rule, a caption
-- tick, or scan noise.
local PANEL_MIN_SIDE_FRAC = 0.03
local PANEL_MIN_AREA_FRAC = 0.005
-- ...and a leaf that is both very elongated and almost inkless is page
-- furniture. The test is a *conjunction* on purpose; `emitLeaf` carries the
-- measurement that shows why neither half works alone.
local PANEL_SLIVER_ASPECT = 4
local PANEL_SLIVER_INK_FRAC = 0.02

local PANEL_MAX_DEPTH = 6
local PANEL_MAX_PANELS = 40

-- Acceptance. A lone panel is believed when it covers this much of the page;
-- otherwise the cut latched onto one blob and missed the rest. Then the panels
-- have to cover at least this much of the page between them, and retain at least
-- this much of the area they cover.
local PANEL_SINGLE_PANEL_RATIO = 0.6
local PANEL_PAGE_COVERAGE_MIN = 0.4
local PANEL_COVERAGE_MIN = 0.5

-- Slopes tried when no straight gutter exists, as dx per unit y.
--
-- Panels are rarely drawn perfectly square, and a gutter tilted by even two
-- degrees leaves no column empty from top to bottom, which is enough to stop the
-- straight cut entirely. The ladder covers 2 to 8 degrees either way, and the
-- spacing matters: a coarser ladder straddles 5 degrees and misses the most
-- common case. 1.3 ships this search **on**, and that is what a skewed page
-- needs; the later version turned it off, which is one of the two failures this
-- module has already been through.
local PANEL_SHEAR_SLOPES = {
    0.035, -0.035,   -- 2.0 degrees
    0.061, -0.061,   -- 3.5
    0.087, -0.087,   -- 5.0
    0.115, -0.115,   -- 6.5
    0.141, -0.141,   -- 8.0
}
-- The slanted search runs only this deep, and only where an axis already has a
-- near-empty line: a splash page has no such line, and the search cannot succeed
-- on one anyway.
local PANEL_SHEAR_MAX_DEPTH = 4
local PANEL_SHEAR_TRIGGER = 0.35
-- Every `step`-th line is sampled in the sheared projections. Only the axis the
-- slope runs along may be stepped — the other must be visited in full, or the
-- lines that were skipped read as empty and become phantom gutters.
local PANEL_SHEAR_STEP = 2

-- **How empty a sheared line has to be, and it has to be empty.** The straight
-- cut allows a line `PANEL_GUTTER_INK_RATIO` of its span, which on a 480-wide
-- scan is 2.4 cells — slack for the hair of JPEG noise a printed gutter carries.
-- The sheared projection must not be given the same slack, and the reason is
-- arithmetic rather than taste: it samples every `PANEL_SHEAR_STEP`-th column, so
-- a line's count is drawn from half as many cells and its variance is that much
-- wider, while `span` here is `width / step` — so the same ratio buys the same
-- 1.2 cells of allowance on a projection with twice the noise. A near-empty line
-- *through white artwork* then reads as a gutter, the shear splits a panel down
-- the middle of its own drawing, and the piece it cuts off is a strip of that
-- drawing with a wedge of its neighbour — a third panel that is really the gap.
--
-- Zero is not a tuned-down number: it is the same standard the straight cut is
-- named for ("a complete white gutter"), and it is the one thing the sheared
-- projection can honestly claim, because a real separator on a skewed page is
-- empty there by construction. Measured on a twelve-page sample it changes
-- nothing except the page it fixes.
local PANEL_SHEAR_INK_RATIO = 0

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
-- `scale_y` are what turn a cell back into page pixels, and the scan is one step
-- on the way rather than the thing being measured.
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
-- Projections
-- ---------------------------------------------------------------------------

-- Ink counts per row and per column over a sub-rectangle, in the caller's two
-- accumulators.
--
-- **Inclusive on all four bounds**, and indexed by the *absolute* cell number
-- rather than by an offset from the region. Both are the reference's shape and
-- both matter: `trimRange` and `findWidestGutter` below take the same absolute
-- indices, so an accumulator based at the region's corner would have every
-- index off by however far the region starts from the page edge.
--
-- The accumulator is sized to the whole map and reused by every node of the
-- recursion, so a node zeroes exactly the span it is about to fill and reads
-- only within it.
local function project(map, x0, y0, x1, y1, rows, cols)
    local data, map_w = map.data, map.w
    for x = x0, x1 do
        cols[x] = 0
    end
    for y = y0, y1 do
        local base = y * map_w
        local count = 0
        for x = x0, x1 do
            if data[base + x] == 1 then
                count = count + 1
                cols[x] = cols[x] + 1
            end
        end
        rows[y] = count
    end
end

-- Shrink a range to the first and last line that carry ink.
local function trimRange(projection, from, to)
    while from <= to and projection[from] == 0 do
        from = from + 1
    end
    while to >= from and projection[to] == 0 do
        to = to - 1
    end
    return from, to
end

-- The widest interior run of near-empty lines, or nil and a length of 0.
--
-- Runs touching either end of the range are page or panel margins, not
-- separators between two siblings, so they are never split points — and a run
-- that reaches the far end of the range is never closed by the loop at all,
-- which is the same rule by construction rather than by a second test.
--
-- `span` is the region's extent on the *perpendicular* axis, since that is what
-- a line's ink count is a fraction of, and `ink_ratio` is
-- `PANEL_GUTTER_INK_RATIO`. Note `max_ink` is deliberately **not** floored to a
-- count of one: at a ratio this strict, a single inked cell on an otherwise
-- empty line has to keep the line out of the running, and an integer floor would
-- hand that line back as a gutter.
local function findWidestGutter(projection, from, to, span, ink_ratio, min_length)
    local max_ink = span * ink_ratio
    local best_start, best_stop, best_length = nil, nil, 0
    local run_start = nil
    for index = from, to do
        if projection[index] <= max_ink then
            if not run_start then
                run_start = index
            end
        else
            if run_start and run_start > from then
                local length = index - run_start
                if length >= min_length and length > best_length then
                    best_start, best_stop, best_length = run_start, index - 1, length
                end
            end
            run_start = nil
        end
    end
    return best_start, best_stop, best_length
end

local function byLengthDesc(a, b)
    return a.length > b.length
end

-- Every interior gutter run in a projection, widest first.
--
-- The slanted search cannot just take the widest run, which is why this exists
-- beside `findWidestGutter`: a run whose cut would land on the region's own edge
-- is no use even when it is the longest one there, and a narrower run further in
-- is. It also has to be able to look past a gutter it has already split on, now
-- sitting against the region's edge.
local function collectGutters(projection, from, to, span, ink_ratio, min_length)
    local max_ink = span * ink_ratio
    local gutters = {}
    local run_start = nil
    for index = from, to do
        if projection[index] <= max_ink then
            if not run_start then
                run_start = index
            end
        else
            if run_start and run_start > from then
                local length = index - run_start
                if length >= min_length then
                    table.insert(gutters, {
                        from = run_start,
                        to = index - 1,
                        length = length,
                    })
                end
            end
            run_start = nil
        end
    end
    table.sort(gutters, byLengthDesc)
    return gutters
end

-- ---------------------------------------------------------------------------
-- The slanted search
-- ---------------------------------------------------------------------------

-- Column ink counts taken along lines sheared by `slope`.
--
-- **Only the y loop may be stepped.** Every x must still be visited, or the
-- columns that were skipped read as empty and become phantom gutters — which is
-- the one way this projection fails silently rather than obviously.
--
-- `shift` is the shear expressed in cells at this row, measured from the
-- region's vertical centre so the band rotates about the middle rather than
-- sliding off one end. A cell found at `x` is counted at `x - shift`, which is
-- where it would sit on the un-sheared axis.
local function projectColumnsSheared(map, x0, y0, x1, y1, slope, cols, step)
    for x = x0, x1 do
        cols[x] = 0
    end
    local data, map_w = map.data, map.w
    local ymid = math.floor((y0 + y1) / 2)
    for y = y0, y1, step do
        local shift = math.floor(slope * (y - ymid) + 0.5)
        local base = y * map_w
        local lo = x0 + shift
        if lo < x0 then
            lo = x0
        end
        local hi = x1 + shift
        if hi > x1 then
            hi = x1
        end
        for x = lo, hi do
            if data[base + x] == 1 then
                local target = x - shift
                cols[target] = cols[target] + 1
            end
        end
    end
end

-- Row ink counts taken along lines sheared by `slope` — the mirror of the column
-- pass, so here only the *x* loop may be stepped.
local function projectRowsSheared(map, x0, y0, x1, y1, slope, rows, step)
    for y = y0, y1 do
        rows[y] = 0
    end
    local data, map_w = map.data, map.w
    local xmid = math.floor((x0 + x1) / 2)
    for y = y0, y1 do
        local base = y * map_w
        for x = x0, x1, step do
            if data[base + x] == 1 then
                local target = y - math.floor(slope * (x - xmid) + 0.5)
                if target >= y0 and target <= y1 then
                    rows[target] = rows[target] + 1
                end
            end
        end
    end
end

local function minInRange(projection, from, to)
    local smallest = math.huge
    for index = from, to do
        if projection[index] < smallest then
            smallest = projection[index]
        end
    end
    return smallest
end

-- Try one slope, returning the axis it splits on and **the line to cut on**.
--
-- The cut is a line, not the band the run maps back to. `shift` is measured from
-- the region's own mid-line, so at that line the sheared projection's axis *is*
-- the page's axis: a run of empty lines in the projection is a run of empty
-- columns (or rows) through the middle of the region, and the separator lies
-- somewhere inside that run. Its middle is where the line is taken.
--
-- **The band, and the two children it used to be handed to, is the defect this
-- replaces.** Widening the run by `drift` at each end gives the axis range the
-- separator sweeps over the *whole* region, and both children were given all of
-- it — so each crop overlapped the other by twice the drift, and the cut itself
-- landed up to `drift` cells away from the separator. On a page whose tiers are
-- tilted that is not a wedge, it is most of a panel: measured on a 480-wide scan
-- at 6.5 degrees over a 482-cell region, `drift` is 28 cells, a 5-cell run
-- becomes a 61-cell band, and a two-panel split cut 30 cells above the boundary
-- left one child holding the bottom of both tiers — which then blocked every
-- later split inside it and came out as `1 panel` where the page has two.
--
-- The interior test is the straight search's own rule — a run that touches an
-- end of the range is a margin, not a separator — and `collectGutters` has
-- already enforced it on the run; what is left to check is that the *cut* is
-- inside, which `split > left and split < right` says directly.
local function trySlope(map, left, top, right, bottom, ctx, slope)
    local width = right - left + 1
    local height = bottom - top + 1
    local step = ctx.shear_step

    projectColumnsSheared(map, left, top, right, bottom, slope, ctx.cols, step)
    for _, gutter in ipairs(collectGutters(ctx.cols, left, right, height / step,
            PANEL_SHEAR_INK_RATIO, ctx.min_gutter)) do
        local split = math.floor((gutter.from + gutter.to) / 2)
        if split > left and split < right then
            return "cols", split
        end
    end

    projectRowsSheared(map, left, top, right, bottom, slope, ctx.rows, step)
    for _, gutter in ipairs(collectGutters(ctx.rows, top, bottom, width / step,
            PANEL_SHEAR_INK_RATIO, ctx.min_gutter)) do
        local split = math.floor((gutter.from + gutter.to) / 2)
        if split > top and split < bottom then
            return "rows", split
        end
    end

    return nil
end

-- Look for a split along slanted lines.
--
-- Whichever slope worked last is overwhelmingly likely to work again on the same
-- page — a page is skewed by one angle, not by a different one in each corner —
-- so the hint is tried before the rest of the ladder, and the ladder skips it.
local function findShearedSplit(map, left, top, right, bottom, ctx)
    if ctx.slope_hint then
        local axis, split = trySlope(map, left, top, right, bottom, ctx, ctx.slope_hint)
        if axis then
            return axis, split
        end
    end
    for _, slope in ipairs(PANEL_SHEAR_SLOPES) do
        if slope ~= ctx.slope_hint then
            local axis, split = trySlope(map, left, top, right, bottom, ctx, slope)
            if axis then
                ctx.slope_hint = slope
                return axis, split
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- The cut
-- ---------------------------------------------------------------------------

-- Record a terminal region as a panel candidate, in map cells.
--
-- The size floors alone do not describe a panel. A scanlation credit strip, a
-- footer rule or a row of page furniture clears both of them comfortably — on a
-- 480x720 map a 182x20 credit line is 3640 cells against a 1728-cell area floor,
-- and both its sides beat the 14-cell side floor — and then gets shown to the
-- reader as a panel holding no artwork.
--
-- Neither half of what gives it away is sufficient alone. Measured against a
-- typical page:
--
-- | leaf | ink share | aspect | |
-- | --- | --- | --- | --- |
-- | credit strip 182x20 | 0.96% | 9.1:1 | furniture |
-- | inset panel 60x60 | 1.51% | 1:1 | panel |
-- | letterbox panel 458x60 | 7.95% | 7.6:1 | panel |
-- | strip panel 40x600 | 6.94% | 15:1 | panel |
--
-- An ink floor on its own would take the inset panel (1.51%) before it took the
-- credit strip (0.96%); an aspect limit on its own would take both legitimately
-- elongated panels. Only the *conjunction* isolates furniture: a leaf has to be
-- both stretched out and nearly empty to be rejected, which is what a strip of
-- page furniture is and what none of the real panels are.
--
-- The ink floor is a share of the *page's* ink rather than an absolute count, so
-- a mostly-blank page with one small drawing still gives that drawing ~100% of
-- the page's ink and keeps it.
--
-- `edges` rides along with the rectangle and is what the *crop* is built from:
-- the box is the region the cut reasoned about, and the edges are the panel's
-- own four borders, which are slanted wherever a sheared split found them. See
-- the note on `cut`.
local function emitLeaf(x0, y0, x1, y1, ink, ctx, out, edges)
    local w = x1 - x0 + 1
    local h = y1 - y0 + 1
    if w < ctx.min_side or h < ctx.min_side or w * h < ctx.min_area then
        return
    end
    local long_side, short_side = w, h
    if h > w then
        long_side, short_side = h, w
    end
    if long_side >= short_side * PANEL_SLIVER_ASPECT and ink < ctx.sliver_ink then
        return
    end
    table.insert(out, { x = x0, y = y0, w = w, h = h, edges = edges })
end

-- Split a region on its widest gutter, recursing until none remains.
--
-- Inclusive bounds throughout, and the region handed on to a child is the
-- **trimmed** one — so a page margin is excluded once, at the level that found
-- it, rather than being carried down and re-trimmed at every step.
--
-- ## The second thing a region carries: its four edges
--
-- The bounds above are what the recursion reasons about, and they are axis
-- aligned because every projection and every gutter in this file is. The panel
-- they describe is not: a sheared split put its separator on a *line*, and that
-- line is the panel's own border — the crop has to follow it or the reader sees
-- a wedge of the panel next door along the slant. So `edges` carries the four
-- borders this region has been given so far, each one a line rather than a
-- number:
--
-- * `l` and `r` are vertical sides, `x = a + b*y`
-- * `t` and `bo` are horizontal ones, `y = a + b*x`
-- * `b = 0` is a straight edge, and is what every edge starts as
--
-- A split replaces the one edge it made, for both of its children — the same
-- line for each, so the two crops meet exactly on the separator instead of
-- overlapping by a row. The line a sheared split leaves is `split + slope *
-- (x - xmid)`, which is the definition of the constant index that projection
-- found: `projectRowsSheared` counts a cell at `x` under `x - shift`, and
-- `shift` is zero at the region's own mid-line, so the run's index *is* the
-- separator's position there.
--
-- The trim has the last word on a side it moved: a bound the trim pulled inward
-- is the panel's own border, and the edge becomes that constant. A bound still
-- sitting where the region's did was made by a split, and keeps the split's
-- line. That is the whole of the rule, and it is what makes the crop exact in
-- both directions at once — a panel whose border the flat cut ran past gets the
-- rows back, and one it ran short of gives them up.
local function cut(map, x0, y0, x1, y1, edges, depth, ctx, out)
    if x1 < x0 or y1 < y0 or #out >= PANEL_MAX_PANELS then
        return
    end

    project(map, x0, y0, x1, y1, ctx.rows, ctx.cols)
    local top, bottom = trimRange(ctx.rows, y0, y1)
    local left, right = trimRange(ctx.cols, x0, x1)
    if bottom < top or right < left then
        return -- region is entirely background
    end

    local el = left == x0 and edges.l or { a = left, b = 0 }
    local er = right == x1 and edges.r or { a = right, b = 0 }
    local et = top == y0 and edges.t or { a = top, b = 0 }
    local ebo = bottom == y1 and edges.bo or { a = bottom, b = 0 }

    -- Summed here, while the projections still describe *this* region: the
    -- sheared search below overwrites both buffers, and the recursive calls
    -- overwrite them again. Rows outside the trimmed range carry no ink by
    -- definition, so this is the region's exact ink count.
    local region_ink = 0
    for y = top, bottom do
        region_ink = region_ink + ctx.rows[y]
    end

    if depth < PANEL_MAX_DEPTH then
        local width = right - left + 1
        local height = bottom - top + 1
        local row_start, row_stop, row_length =
            findWidestGutter(ctx.rows, top, bottom, width, ctx.ink_ratio, ctx.min_gutter)
        local col_start, col_stop, col_length =
            findWidestGutter(ctx.cols, left, right, height, ctx.ink_ratio, ctx.min_gutter)

        -- Every value needed below is already a local, so the children are free
        -- to overwrite the shared projection buffers.
        if row_length > 0 and row_length >= col_length then
            cut(map, left, top, right, row_start - 1,
                { l = el, r = er, t = et, bo = { a = row_start - 1, b = 0 } },
                depth + 1, ctx, out)
            cut(map, left, row_stop + 1, right, bottom,
                { l = el, r = er, t = { a = row_stop + 1, b = 0 }, bo = ebo },
                depth + 1, ctx, out)
            return
        elseif col_length > 0 then
            cut(map, left, top, col_start - 1, bottom,
                { l = el, r = { a = col_start - 1, b = 0 }, t = et, bo = ebo },
                depth + 1, ctx, out)
            cut(map, col_stop + 1, top, right, bottom,
                { l = { a = col_stop + 1, b = 0 }, r = er, t = et, bo = ebo },
                depth + 1, ctx, out)
            return
        end

        -- Nothing straight. The panels may simply not be square, so look along
        -- slanted lines -- but only when something already looks part-empty. A
        -- splash page has no such line and skips a search that cannot succeed.
        --
        -- The split is one line through the middle of the empty run the sheared
        -- projection found, and the children do not share it: the separator is
        -- slanted and their crops are rectangles, so each keeps a wedge of its
        -- neighbour on one side and gives one up on the other, and which way
        -- round that falls is decided by where on the page the reader is
        -- looking. What it is not is a cut placed `drift` cells off the
        -- separator with both children given the whole band, which is what
        -- `trySlope` above carries the measurement of.
        if depth <= PANEL_SHEAR_MAX_DEPTH
            and (minInRange(ctx.cols, left, right) <= height * PANEL_SHEAR_TRIGGER
                or minInRange(ctx.rows, top, bottom) <= width * PANEL_SHEAR_TRIGGER) then
            local axis, split = findShearedSplit(map, left, top, right, bottom, ctx)
            if axis then
                -- The line the separator actually lies on, and the same one for
                -- both children: the value the projection found is that line at
                -- the region's mid, and `xmid`/`ymid` are recomputed exactly as
                -- `projectRowsSheared`/`projectColumnsSheared` computed them.
                local slope = ctx.slope_hint
                if axis == "cols" then
                    local ymid = math.floor((top + bottom) / 2)
                    local line = { a = split - slope * ymid, b = slope }
                    cut(map, left, top, split, bottom,
                        { l = el, r = line, t = et, bo = ebo }, depth + 1, ctx, out)
                    cut(map, split + 1, top, right, bottom,
                        { l = line, r = er, t = et, bo = ebo }, depth + 1, ctx, out)
                else
                    local xmid = math.floor((left + right) / 2)
                    local line = { a = split - slope * xmid, b = slope }
                    cut(map, left, top, right, split,
                        { l = el, r = er, t = et, bo = line }, depth + 1, ctx, out)
                    cut(map, left, split + 1, right, bottom,
                        { l = el, r = er, t = line, bo = ebo }, depth + 1, ctx, out)
                end
                return
            end
        end
    end

    emitLeaf(left, top, right, bottom, region_ink, ctx, out,
        { l = el, r = er, t = et, bo = ebo })
end

-- Segment a page ink map into panel rectangles in native page coordinates.
local function segment(map)
    local min_dimension = math.min(map.w, map.h)
    local ctx = {
        -- Absolute-indexed, sized to the whole map, and reused by every node.
        rows = ffi.new("int32_t[?]", map.h),
        cols = ffi.new("int32_t[?]", map.w),
        ink_ratio = PANEL_GUTTER_INK_RATIO,
        min_gutter = math.max(2, math.floor(min_dimension * PANEL_GUTTER_RATIO)),
        min_side = math.max(4, math.floor(min_dimension * PANEL_MIN_SIDE_FRAC)),
        min_area = math.floor(map.w * map.h * PANEL_MIN_AREA_FRAC),
        -- Zero when the map did not report its ink total, which disables the
        -- content floor rather than rejecting every sliver on the page.
        sliver_ink = math.floor((map.ink or 0) * PANEL_SLIVER_INK_FRAC),
        shear_step = PANEL_SHEAR_STEP,
        slope_hint = nil,
    }

    local cells = {}
    cut(map, 0, 0, map.w - 1, map.h - 1,
        { l = { a = 0, b = 0 }, r = { a = map.w - 1, b = 0 },
          t = { a = 0, b = 0 }, bo = { a = map.h - 1, b = 0 } },
        0, ctx, cells)

    -- A rectangle lying entirely inside another is a *piece of it*, not a panel.
    --
    -- **The symptom this was written for is gone, and the rule is kept as a guard
    -- on the invariant rather than as a fix for it.** The sheared split used to
    -- hand both children the whole projected band, so a child split again on that
    -- same band left a strip of it behind whose top reached back over the other
    -- child's box — the upper panel's bottom rows, the band, and a sliver of the
    -- lower panel. That rectangle sat inside the upper panel's, so the reader saw
    -- the same artwork twice and the lower panel arrived with its top cut off.
    -- (*This* rule and `PANEL_SHEAR_INK_RATIO` were both needed for it, on
    -- different pages, and neither alone fixed both.)
    --
    -- With the split taken as one line through the middle of the run — see
    -- `trySlope` — the two children are disjoint along the axis they were split
    -- on and a trim only ever shrinks one, so no leaf can contain another. That
    -- is a property of the shape of the cut rather than of this code, and it is
    -- why the rule is not deleted with the text above it: it costs a few hundred
    -- integer comparisons on a list capped at `PANEL_MAX_PANELS`, and the change
    -- that would make it live again is a change to the cut. Measured across the
    -- 23-page sample it now drops nothing, where it used to drop that strip.
    --
    -- The test is on the map's cells, before the conversion to native, because in
    -- cells the comparison is exact: the conversion expands every rectangle by a
    -- cell on each side and works in floats, either of which could separate two
    -- boxes that contain one another here.
    --
    -- The history is worth keeping because it is the same mistake twice over: an
    -- earlier version had the rule and dropped it on the evidence of a single page
    -- where it removed nothing, and the honest reading of that was "it does not
    -- fix *this* page", not "the rule does nothing".
    --
    -- The one thing it costs is an inset panel — a small panel drawn inside a larger
    -- one is a contained rectangle and would be dropped. That needs the cut to have
    -- separated the surround from the inset, and a surround is not a rectangle, so
    -- it is believed rare; it has not been measured on a page that has one.
    local kept = {}
    for i, cell in ipairs(cells) do
        local contained = false
        for j, other in ipairs(cells) do
            if j ~= i
                and other.w * other.h > cell.w * cell.h -- strict: a tie keeps both
                and cell.x >= other.x and cell.y >= other.y
                and cell.x + cell.w <= other.x + other.w
                and cell.y + cell.h <= other.y + other.h
            then
                contained = true
                break
            end
        end
        if not contained then
            kept[#kept + 1] = cell
        end
    end
    cells = kept

    -- Cell -> native, growing every edge by one cell *outward*: a cell is several
    -- page pixels, and without the expansion the quantisation would shave the
    -- outermost artwork off the crop. It is applied to the edges rather than to
    -- the box, so the box and the shape agree — a panel whose sides are all
    -- straight comes out byte for byte the rectangle this used to return. These
    -- are floats, and deliberately not rounded: everything downstream compares or
    -- multiplies them, and `panelTileKey` is where they become integers.
    --
    -- **`planes` is what the crop is, and it replaces the rectangle as the panel's
    -- shape.** Four half-planes, `A*x + B*y + C <= 0` for the inside, in native
    -- page coordinates — the space `Image.renderRegion` masks in and the space
    -- `Panel.indexAt` tests a touch against. A rectangle cannot follow a slanted
    -- border, and a panel whose border is slanted is the whole reason this exists:
    -- the crop has to be the quadrilateral the cut's four lines bound, or the
    -- reader is shown a wedge of the panel next door along the slant.
    --
    -- The box is the *bounding* one, taken by evaluating each edge over the span
    -- the region covers rather than by intersecting the lines with each other.
    -- Every edge is monotonic, so its extremes are at the ends of that span, and a
    -- parallel pair — which a page's near-vertical sides are — has no intersection
    -- to find at all. It can only ever come out bigger than the quad, and the quad
    -- is what the mask cuts to.
    local panels = {}
    for _, cell in ipairs(cells) do
        local e = cell.edges
        local x0n, x1n = cell.x * map.scale_x, (cell.x + cell.w - 1) * map.scale_x
        local y0n, y1n = cell.y * map.scale_y, (cell.y + cell.h - 1) * map.scale_y
        -- A vertical edge is x = a + b*y and a horizontal one y = a + b*x, both in
        -- cells; converting a line is converting its coefficients, not two points.
        local l = { a = e.l.a * map.scale_x - map.scale_x,
                    b = e.l.b * map.scale_x / map.scale_y }
        local r = { a = e.r.a * map.scale_x + map.scale_x,
                    b = e.r.b * map.scale_x / map.scale_y }
        local t = { a = e.t.a * map.scale_y - map.scale_y,
                    b = e.t.b * map.scale_y / map.scale_x }
        local bo = { a = e.bo.a * map.scale_y + map.scale_y,
                     b = e.bo.b * map.scale_y / map.scale_x }

        local left = math.max(0, math.min(l.a + l.b * y0n, l.a + l.b * y1n))
        local right = math.min(map.native_w, math.max(r.a + r.b * y0n, r.a + r.b * y1n))
        local top = math.max(0, math.min(t.a + t.b * x0n, t.a + t.b * x1n))
        local bottom = math.min(map.native_h, math.max(bo.a + bo.b * x0n, bo.a + bo.b * x1n))
        if right - left >= 1 and bottom - top >= 1 then
            table.insert(panels, {
                x = left,
                y = top,
                w = right - left,
                h = bottom - top,
                planes = {
                    { A = -1, B = l.b, C = l.a },
                    { A = 1, B = -r.b, C = -r.a },
                    { A = t.b, B = -1, C = t.a },
                    { A = -bo.b, B = 1, C = -bo.a },
                },
            })
        end
    end

    return panels
end

-- ---------------------------------------------------------------------------
-- Acceptance
-- ---------------------------------------------------------------------------

-- Is this segmentation worth showing to a reader?
--
-- Returns `true`, or `false` and the test that refused — the reason reaches the
-- log, which is the only way to tell a page that genuinely has one panel from
-- one the cut failed on.
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
    -- is the best the cut can do on a layout with no straight gutters (a
    -- diagonal split, say), so refusing it would only cost a full-resolution
    -- render to reach the same rectangle. A *small* lone rectangle is different:
    -- the cut latched onto one blob and missed the rest, which is worth saying
    -- no to.
    if count == 1 then
        if largest_area >= page_area * PANEL_SINGLE_PANEL_RATIO then
            return true
        end
        return false, "single partial panel"
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
-- `native_bb` was readable**: a page the cut could not make sense of comes back
-- as a single rectangle covering the whole page, with `accepted` false and the
-- failing test in `reason`. The caller can therefore always open something, and
-- the log can always say which of the two it is looking at. `nil` means one
-- thing only — there was no page buffer to read.
--
-- The background this page was mapped against is a local and stops here: what
-- the crop paints outside a panel is white, and `meguru/doc/image` says why the
-- page's own estimate is not it.
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

    local bg = backgroundFor(scan_raster)
    local map = buildInkMap(scan_raster, bg, native_w, native_h)
    local panels = segment(map)
    local accepted, reason = accept(panels, map)
    if not accepted then
        -- A whole-page panel is a rectangle, and its mask is the page: naming the
        -- four edges explicitly rather than leaving `planes` nil keeps the one
        -- shape every consumer reads.
        return { { x = 0, y = 0, w = native_w, h = native_h,
                   planes = { { A = -1, B = 0, C = 0 },
                              { A = 1, B = 0, C = -native_w },
                              { A = 0, B = -1, C = 0 },
                              { A = 0, B = 1, C = -native_h } } } }, false, reason
    end
    return sortReadingOrder(panels, manga and true or false), true
end

-- Which panel a point falls in, or the nearest one when it falls in a gutter.
--
-- The **smallest** containing panel wins rather than the first in reading
-- order. The cut's leaves are disjoint, so this can only matter for panels that
-- a caller handed over itself — a sheared split used to be able to produce two
-- neighbours overlapping by a wedge, and the more specific answer to "which
-- panel is under the finger" is then the smaller rectangle rather than the
-- larger one that merely includes it.
--
-- **The test is the panel's own quadrilateral**, not its bounding box. Those
-- differ along every slanted border, and the bounding box is the wrong answer
-- there in the direction that matters: a press just outside a tilted panel, in
-- the corner its box covers and the panel does not, belongs to the neighbour.
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
        local hit = false
        if p.planes then
            hit = true
            for _, plane in ipairs(p.planes) do
                if plane.A * x + plane.B * y + plane.C > 0 then
                    hit = false
                    break
                end
            end
        else
            hit = x >= p.x and x <= p.x + p.w and y >= p.y and y <= p.y + p.h
        end
        if hit then
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
