--[[--
Finding the panels on a page, and the order a reader meets them in.

This is the detector behind the panel *sequence*: the long-press that used to
open one crop now opens the panel under the finger and then walks the rest of
the page in reading order. `meguru/doc/document.lua` keeps its own, older
detector for the single-region case and this module does not replace it — see
"Two detectors" below, which is the one thing worth reading before changing
anything here.

Nothing in this module knows what a document is. It takes a decoded BlitBuffer
and returns rectangles in that buffer's own coordinates; the caller (`the
document`) owns the buffer, the page, and the fetch.

## How a panel is found

The page is rendered down to a small working scan once, and what comes out of
that scan is an **ink map**: a cell is ink when its luminance is far enough from
the page's *own* background. The recursive X-Y cut then splits the page on the
widest gutter it can find, splits each half again, and stops when a region has
no gutter left in it. That is the classic algorithm for this job, and it is the
one `panels_plus` reaches for too.

## Two detectors, deliberately

`MeguruDocument:getPanelFromPage` answers "which single region is under the
finger", and it is the *fallback*: it runs precisely when this module has said
there is no sequence. Its 256-pixel scan and its `paper * 0.85` threshold are
tuned so that it never guesses — a gutter it cannot see degrades to "no panel",
and a long-press that finds nothing does nothing. That is the right failure for
a fallback.

This scan is the opposite trade. A recursive cut that cannot see a gutter does
not give up, it **merges two panels into one**, so the scan has to be fine
enough to see the smallest gutter worth splitting on. The gutter floor here is
`PANEL_MIN_GUTTER_FRAC * min(w, h)` of the scan, which makes the scan's
resolution *the* smallest detectable gutter — that is why this renders at
`PANEL_ZOOM_SCAN_TARGET` and not at 256. A 1600x2400 page with a 10-pixel
printed gutter is 1.06 cells wide at 256 (missed) and 2.0 cells at 480 (found).
`panels_plus` arrived at the same 480 the same way.

The two share the raster accessor (`Image.rasterFor`) and the page-preparation
preamble in the document. They do **not** share the classification, and that is
the point: merging them would make the fallback inherit a sensitivity it does
not want.

## What was left out of the reference, and one thing knowingly

Dropped from `panels_plus/src/_segmenter.lua`, each for its own reason and all
of them recorded rather than discovered later:

* **the shear search** (~185 lines) — a slanted split is a guess about a page
  the straight cuts already failed to read, and the reference ships it off by
  default because it is expensive;
* **the comic border split** — it needs a whole second plane in the ink map
  (drawn frame strokes thresholded by absolute luminance), and that second plane
  is the single biggest reason the reference's map is two planes instead of one;
* **the 4-koma centre split** (~80 lines for one layout);
* **the connected-component detector**, which the reference actually uses live.
  It handles irregular layouts the recursive cut cannot, and it is also an
  order of magnitude more code than everything in this file.

**Knowingly left out: `looksLikePageFurnitureLayout`.** A contents or credits
page — one tall illustration with a sparse stack of text beside it — can pass
the acceptance tests below and be accepted as a bogus sequence. The escape is a
swipe down to dismiss, and the `dbg` line the caller writes names the page and
the panel count, so it is diagnosable from a log. Porting the test would mean
walking the whole ink map again for a layout that is rare in a manga library,
and this is the one place where the reduced version is knowingly worse than the
reference.

## Coordinates

Panels come back in the **full native page** space — the space `self.dims`
lives in, and the space `drawPagePart` expects. The scan's coordinate system
never escapes this module.
--]]

local RenderImage = require("ui/renderimage")

local Image = require("meguru/doc/image")

local Panel = {}

-- The long side of the working scan. See "Two detectors" above: this number is
-- the smallest gutter the cut can see, so it is not a performance knob dressed
-- up as one.
local PANEL_ZOOM_SCAN_TARGET = 480

-- How far a cell's luminance has to be from the page's own background before it
-- counts as ink. Relative rather than absolute — this is what lets a
-- white-on-black page map identically to a black-on-white one, and it is why
-- there is no "the page is too dark to read" bail here.
local PANEL_INK_DELTA = 40

-- The outer ring the background is sampled from, as a fraction of the shorter
-- side. The border of a page is the one place guaranteed to be background
-- rather than artwork.
local PANEL_BG_RING_FRAC = 0.01

-- What fraction of a gutter's span may still carry ink and stay a gutter. Manga
-- panels tile edge to edge and leave hairline separators, so the manga figure
-- is the stricter of the two and the comic figure is the looser.
local PANEL_GUTTER_INK_MANGA = 0.04
local PANEL_GUTTER_INK_COMIC = 0.05

-- A run at or below this fraction of its span is *clean* — a real separator
-- rather than a noisy valley — and clean runs are preferred over merely wide
-- ones, without a length cap.
local PANEL_CLEAN_INK_FRAC = 0.015
-- A run carrying more ink than that is capped at this many cells, so noise a
-- few cells long cannot outscore a genuinely clean but shorter gutter.
local PANEL_NOISY_RUN_MAX = 30

-- The thinnest separator worth splitting on, as a fraction of the shorter side
-- of the region. Comic pages get a floor of one cell instead (see `gutterFloor`).
local PANEL_MIN_GUTTER_FRAC = 0.005

-- A leaf smaller than either of these is not a panel: it is a rule, a caption
-- tick, or scan noise.
local PANEL_MIN_SIDE_FRAC = 0.03
local PANEL_MIN_AREA_FRAC = 0.01

-- ...and a leaf that is both very elongated and almost inkless is page
-- furniture (a page number, a running head). The test is a *conjunction* on
-- purpose: a long thin panel full of ink is a real panel.
local PANEL_SLIVER_ASPECT = 4
local PANEL_SLIVER_INK_FRAC = 0.02

local PANEL_MAX_DEPTH = 6
local PANEL_MAX_PANELS = 40

-- Acceptance. Both are about "did the cut find a page layout, or did it find
-- noise": the panels have to cover at least this much of the page between them,
-- and they have to retain at least this much of the area they cover.
local PANEL_PAGE_COVERAGE_MIN = 0.4
local PANEL_COVERAGE_MIN = 0.5

-- ---------------------------------------------------------------------------
-- The ink map
-- ---------------------------------------------------------------------------

-- What this page's background is, taken as the median luminance of its outer
-- ring.
--
-- The median and not the mean: a ring that is three quarters paper and one
-- quarter a bleed of artwork has a mean somewhere in between, which is a
-- background colour the page does not contain. The median ignores the minority
-- entirely. 256 bins is exact for an 8-bit channel, so no interpolation is
-- needed to land on a real value.
local function borderMedian(raster)
    local w, h = raster.w, raster.h
    local ring = math.max(1, math.floor(math.min(w, h) * PANEL_BG_RING_FRAC))
    local bins = {}
    local total = 0
    local function sample(x, y)
        local v = math.floor(raster.luma(y, x))
        if v < 0 then v = 0 elseif v > 255 then v = 255 end
        bins[v] = (bins[v] or 0) + 1
        total = total + 1
    end
    for y = 0, h - 1 do
        local edge_row = (y < ring) or (y >= h - ring)
        if edge_row then
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
            return v
        end
    end
    return 255
end

-- A flat 0/1 map over the scan, indexed `y * w + x + 1`.
--
-- A Lua table and not an `ffi` array, deliberately: this plugin reaches for ffi
-- only where a buffer genuinely has to be one, and the map is built, read and
-- dropped inside a single call. A 320x480 scan is 153,600 cells, which under
-- LuaJIT costs about 1.2 MB while it lives — against the three decoded pages
-- (up to 4 Mpx each) the document is already holding. It is garbage the moment
-- `Panel.detect` returns, and it is never written anywhere.
local function buildInkMap(raster, bg)
    local w, h = raster.w, raster.h
    local map = {}
    local ink = 0
    local luma = raster.luma
    for y = 0, h - 1 do
        local base = y * w
        for x = 0, w - 1 do
            local v = luma(y, x)
            local d = v - bg
            if d < 0 then d = -d end
            if d > PANEL_INK_DELTA then
                map[base + x + 1] = 1
                ink = ink + 1
            end
        end
    end
    return { w = w, h = h, data = map, ink = ink }
end

-- ---------------------------------------------------------------------------
-- Projections and gutters
-- ---------------------------------------------------------------------------

-- Per-row and per-column ink counts over one region. `rows` and `cols` are
-- scratch tables owned by the caller and reused between nodes of the recursion:
-- a fresh pair per node would allocate on every branch of every level, and this
-- runs while a finger is held down.
--
-- The counts are taken over the region as it arrived, not over the trimmed
-- content box (see `cut`). The index *range* the gutter search then looks at is
-- the trimmed one, so a margin at the region's edge is excluded from the search
-- without changing what a "clean row" is measured against.
local function project(map, x0, y0, x1, y1, rows, cols)
    local w = map.w
    local data = map.data
    local width = x1 - x0
    local height = y1 - y0
    for i = 1, height do
        rows[i] = 0
    end
    for i = 1, width do
        cols[i] = 0
    end
    for y = y0, y1 - 1 do
        local base = y * w
        local cnt = 0
        for x = x0, x1 - 1 do
            if data[base + x + 1] == 1 then
                cnt = cnt + 1
                cols[x - x0 + 1] = cols[x - x0 + 1] + 1
            end
        end
        rows[y - y0 + 1] = cnt
    end
end

-- The first and last index in [from, to] that carries any ink at all, or nil
-- when the range is empty. A run touching the region's edge is margin, never a
-- separator, and to a cut that means the same thing as no ink.
--
-- `base` is the index the projection's first cell stands for. It is passed
-- rather than assumed to be `from`, because the range searched is the *trimmed*
-- one while the array is based on the region as it arrived — conflating the two
-- silently reads the wrong cells, which would put a gutter in the wrong place
-- rather than fail.
local function trimRange(proj, base, from, to)
    local lo, hi
    for i = from, to do
        if proj[i - base + 1] > 0 then
            if not lo then
                lo = i
            end
            hi = i
        end
    end
    return lo, hi
end

-- The widest gutter inside [from, to]: a run of indices whose projected ink
-- count stays at or below `span * ink_ratio`.
--
-- Three rules, each of which exists because of a way the simple version went
-- wrong:
--
--   * a run that touches either end of the range is **not** a candidate — that
--     is the margin around the content, and splitting there would cut a panel
--     off at its own edge;
--   * a one-cell run has to be genuinely empty (`proj == 0`), because a single
--     cell that is merely below the tolerance is inside artwork as often as it
--     is between two panels;
--   * a **clean** run outranks a merely wide one and has no length cap, while a
--     run carrying real ink is capped at `PANEL_NOISY_RUN_MAX` cells — so a
--     broad smudge across a drawing cannot beat a hairline separator.
--
-- `span` is the region's extent on the *perpendicular* axis (the width, for a
-- row projection), because that is what a row's ink count is a fraction of, and
-- `base` is the index the projection's first cell stands for — see `trimRange`
-- for why it is a parameter and not `from`.
local function findWidestGutter(proj, base, from, to, span, ink_ratio, min_length)
    local max_ink = math.max(1, math.floor(span * ink_ratio))
    local clean_ink = span * PANEL_CLEAN_INK_FRAC
    local best_start, best_stop, best_score
    local i = from
    while i <= to do
        if proj[i - base + 1] <= max_ink then
            local start = i
            local clean = true
            while i <= to and proj[i - base + 1] <= max_ink do
                if proj[i - base + 1] > clean_ink then
                    clean = false
                end
                i = i + 1
            end
            local stop = i - 1
            local length = stop - start + 1
            local interior = start > from and stop < to
            if interior and length >= min_length
                and (length > 1 or proj[start - base + 1] == 0) then
                local score
                if clean then
                    score = length + 1000
                else
                    score = math.min(length, PANEL_NOISY_RUN_MAX)
                end
                if not best_score or score > best_score then
                    best_score, best_start, best_stop = score, start, stop
                end
            end
        else
            i = i + 1
        end
    end
    if not best_start then
        return nil
    end
    return best_start, best_stop
end

-- How thick a separator has to be to be worth cutting on. Comic pages get a
-- single cell: their panels are drawn with a frame stroke between them, so the
-- separator is a real line rather than a gap, and demanding two cells of it
-- would refuse to cut at all. Manga gets a proportional floor.
local function gutterFloor(min_dim, manga)
    if not manga then
        return 1
    end
    return math.max(2, math.floor(min_dim * PANEL_MIN_GUTTER_FRAC))
end

-- ---------------------------------------------------------------------------
-- The cut
-- ---------------------------------------------------------------------------

local function leafInk(map, x0, y0, x1, y1)
    local w = map.w
    local data = map.data
    local n = 0
    for y = y0, y1 - 1 do
        local base = y * w
        for x = x0, x1 - 1 do
            if data[base + x + 1] == 1 then
                n = n + 1
            end
        end
    end
    return n
end

-- A region with no gutter left in it is a panel — unless it is too small to be
-- one, or it is page furniture.
--
-- The box handed here is the **trimmed** one, not the region as it arrived.
-- That deviates from the reference, which emits the untrimmed region and then
-- inflates every cell by one. Trimming first is what makes a strict crop
-- actually strict: the crop the reader gets is the panel's own edge, not the
-- panel plus whatever margin the split happened to leave around it.
local function emitLeaf(map, x0, y0, x1, y1, ctx, out)
    local w = x1 - x0
    local h = y1 - y0
    if w < ctx.min_side or h < ctx.min_side then
        return
    end
    if w * h < ctx.min_area then
        return
    end
    local short = w < h and w or h
    local long = w < h and h or w
    local ink = leafInk(map, x0, y0, x1, y1)
    if ink == 0 then
        return
    end
    if long >= short * PANEL_SLIVER_ASPECT
        and ink < ctx.total_ink * PANEL_SLIVER_INK_FRAC then
        return
    end
    ctx.found = ctx.found + 1
    if ctx.found > PANEL_MAX_PANELS then
        return
    end
    out[#out + 1] = { x0 = x0, y0 = y0, x1 = x1, y1 = y1, ink = ink }
end

local function cut(map, x0, y0, x1, y1, depth, ctx, out)
    if x1 - x0 < ctx.min_side or y1 - y0 < ctx.min_side then
        return
    end
    if ctx.found > PANEL_MAX_PANELS then
        return
    end
    project(map, x0, y0, x1, y1, ctx.rows, ctx.cols)
    -- `cols` is based on x0 and `rows` on y0 — the region as it arrived — while
    -- the ranges searched are the trimmed content extent.
    local cx0, cx1 = trimRange(ctx.cols, x0, x0, x1 - 1)
    local cy0, cy1 = trimRange(ctx.rows, y0, y0, y1 - 1)
    if not cx0 or not cy0 then
        return -- no ink at all in this region
    end

    -- Out of depth: take what is left, through the same trimmed terminal the
    -- no-gutter case uses. Returning the region *untrimmed* here would hand the
    -- reader a crop bigger than its panel, which is the one failure mode this
    -- detector is not allowed to have.
    if depth > PANEL_MAX_DEPTH then
        emitLeaf(map, cx0, cy0, cx1 + 1, cy1 + 1, ctx, out)
        return
    end

    local min_dim = math.min(cx1 - cx0 + 1, cy1 - cy0 + 1)
    local min_gutter = gutterFloor(min_dim, ctx.manga)

    local row_a, row_b = findWidestGutter(ctx.rows, y0, cy0, cy1, x1 - x0,
        ctx.ink_ratio, min_gutter)
    local col_a, col_b = findWidestGutter(ctx.cols, x0, cx0, cx1, y1 - y0,
        ctx.ink_ratio, min_gutter)

    local row_len = row_a and (row_b - row_a + 1) or 0
    local col_len = col_a and (col_b - col_a + 1) or 0

    if row_len > 0 and row_len >= col_len then
        cut(map, x0, y0, x1, row_a, depth + 1, ctx, out)
        cut(map, x0, row_b + 1, x1, y1, depth + 1, ctx, out)
        return
    elseif col_len > 0 then
        cut(map, x0, y0, col_a, y1, depth + 1, ctx, out)
        cut(map, col_b + 1, y0, x1, y1, depth + 1, ctx, out)
        return
    end

    emitLeaf(map, cx0, cy0, cx1 + 1, cy1 + 1, ctx, out)
end

-- ---------------------------------------------------------------------------
-- Reading order
-- ---------------------------------------------------------------------------

-- Group the panels into rows by their top edge and order each row across.
--
-- Grouping is measured against the row's own **fixed** top, never chained from
-- the previous member: with a chain, a staircase of slightly lower panels grows
-- one row all the way down the page. The tolerance shrinks with the shortest
-- member seen so far, so a row of small panels cannot swallow a tall neighbour.
local function buildRows(panels)
    local sorted = {}
    for i, p in ipairs(panels) do
        sorted[i] = p
    end
    table.sort(sorted, function(a, b)
        if a.y0 ~= b.y0 then
            return a.y0 < b.y0
        end
        return a.x0 < b.x0
    end)
    local rows = {}
    local row
    for _, p in ipairs(sorted) do
        local h = p.y1 - p.y0
        if row then
            local tol = math.min(h, row.min_h) * 0.35
            if p.y0 - row.top > tol then
                row = nil
            end
        end
        if not row then
            row = { top = p.y0, min_h = h, members = {} }
            rows[#rows + 1] = row
        end
        if h < row.min_h then
            row.min_h = h
        end
        row.members[#row.members + 1] = p
    end
    return rows
end

-- Is every part of `p` on the leading side of `q`? For a comic (left to right)
-- the leading side is the left, for a manga it is the right.
local function isLeadingOf(p, q, manga)
    if manga then
        return p.x0 >= q.x1
    end
    return p.x1 <= q.x0
end

-- The reading order, with the deferred trailing panel.
--
-- A panel that is not its row's first can sit *beside* a tall neighbour in a
-- later row rather than above it — a wide strip at the top of the layout, with
-- the stack it belongs after running down one side. Emitting row by row would
-- put it before that stack; holding it until the last later row it overlaps
-- puts it after, which is the order the page is actually read in
-- (1,2,3,5,6,7,4 rather than 1,2,3,4,5,6,7).
local function sortReadingOrder(panels, manga)
    local rows = buildRows(panels)
    local order = {}
    local held = {} -- held[row_index] = panels to flush after that row
    for r = 1, #rows do
        local members = rows[r].members
        table.sort(members, function(a, b)
            if manga then
                if a.x0 ~= b.x0 then
                    return a.x0 > b.x0
                end
            elseif a.x0 ~= b.x0 then
                return a.x0 < b.x0
            end
            return a.y0 < b.y0
        end)
        for j, p in ipairs(members) do
            local hold_until
            if j > 1 then
                local bottom = p.y1
                for r2 = r + 1, #rows do
                    if rows[r2].top >= bottom then
                        break -- later rows start below this panel: no overlap
                    end
                    for _, q in ipairs(rows[r2].members) do
                        if isLeadingOf(q, p, manga) then
                            hold_until = r2
                            break
                        end
                    end
                end
            end
            if hold_until then
                held[hold_until] = held[hold_until] or {}
                table.insert(held[hold_until], p)
            else
                order[#order + 1] = p
            end
        end
        if held[r] then
            for _, p in ipairs(held[r]) do
                order[#order + 1] = p
            end
            held[r] = nil
        end
    end
    -- A panel held past the last row it could be flushed after (which the loop
    -- above cannot produce, but a future edit to the hold rule could) still has
    -- to come out somewhere rather than vanish.
    for r = 1, #rows do
        if held[r] then
            for _, p in ipairs(held[r]) do
                order[#order + 1] = p
            end
        end
    end
    return order
end

-- ---------------------------------------------------------------------------
-- The module
-- ---------------------------------------------------------------------------

-- The ordered panels of one page, in full native coordinates, or nil and the
-- reason why there is no sequence.
--
-- `native_bb` is the document's decoded page and is **not** freed here — it
-- belongs to the document's native LRU. The scan copy this makes is freed on
-- every path out.
--
-- There is no sequence for a page with fewer than two panels. That is not a
-- formality: the single-region detector is what a long-press falls back to, and
-- a "sequence" of one would replace that fallback with a viewer that has
-- nothing to navigate. So a splash page, a page whose gutter the cut could not
-- see, and a page that failed to decode all end in the same place.
function Panel.detect(native_bb, manga)
    local raster = Image.rasterFor(native_bb)
    if not raster then
        return nil, "unreadable page buffer"
    end
    local native_w, native_h = raster.w, raster.h

    local scan = native_bb
    local sw, sh = native_w, native_h
    if native_w > PANEL_ZOOM_SCAN_TARGET or native_h > PANEL_ZOOM_SCAN_TARGET then
        local scale = PANEL_ZOOM_SCAN_TARGET / math.max(native_w, native_h)
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
        return nil, "unreadable page scan"
    end

    local bg = borderMedian(scan_raster)
    local map = buildInkMap(scan_raster, bg)
    if map.ink == 0 then
        return nil, "page has no ink against its own background"
    end

    local ctx = {
        rows = {},
        cols = {},
        manga = manga and true or false,
        total_ink = map.ink,
        ink_ratio = (manga and PANEL_GUTTER_INK_MANGA or PANEL_GUTTER_INK_COMIC),
        min_side = math.max(4, math.floor(math.min(sw, sh) * PANEL_MIN_SIDE_FRAC)),
        min_area = math.floor(sw * sh * PANEL_MIN_AREA_FRAC),
        found = 0,
    }
    local leaves = {}
    cut(map, 0, 0, sw, sh, 0, ctx, leaves)

    if #leaves == 0 then
        return nil, "no panels found"
    end
    if #leaves < 2 then
        return nil, "single panel"
    end

    -- Coverage: did the cut find a page layout, or did it find noise?
    local min_x, min_y, max_x, max_y = sw, sh, 0, 0
    local kept_area = 0
    for _, l in ipairs(leaves) do
        if l.x0 < min_x then min_x = l.x0 end
        if l.y0 < min_y then min_y = l.y0 end
        if l.x1 > max_x then max_x = l.x1 end
        if l.y1 > max_y then max_y = l.y1 end
        kept_area = kept_area + (l.x1 - l.x0) * (l.y1 - l.y0)
    end
    local page_area = sw * sh
    local covered = (max_x - min_x) * (max_y - min_y)
    if covered < page_area * PANEL_PAGE_COVERAGE_MIN then
        return nil, string.format("panels cover only %d%% of the page",
            math.floor(covered / page_area * 100 + 0.5))
    end
    if kept_area < covered * PANEL_COVERAGE_MIN then
        return nil, string.format("only %d%% of the covered area kept",
            math.floor(kept_area / covered * 100 + 0.5))
    end

    local ordered = sortReadingOrder(leaves, ctx.manga)

    -- Cell -> native, inflating by one cell on each side to undo the
    -- quantisation: a cell is up to `scale` native pixels wide, so the content's
    -- true edge can be up to one cell beyond the last inked cell.
    local scale_x = native_w / sw
    local scale_y = native_h / sh
    local panels = {}
    for i, l in ipairs(ordered) do
        local x = math.max(0, math.floor((l.x0 - 1) * scale_x + 0.5))
        local y = math.max(0, math.floor((l.y0 - 1) * scale_y + 0.5))
        local right = math.min(native_w, math.floor((l.x1 + 1) * scale_x + 0.5))
        local bottom = math.min(native_h, math.floor((l.y1 + 1) * scale_y + 0.5))
        local w = math.max(1, right - x)
        local h = math.max(1, bottom - y)
        panels[i] = { x = x, y = y, w = w, h = h }
    end
    return panels
end

-- Which panel a point falls in, or the nearest one when it falls in a gutter.
--
-- "Nearest" is by centre distance, and it has to exist: a long-press that lands
-- on a separator is a reader aiming at a panel, and refusing to answer would
-- turn the gesture into a no-op for no better reason than that they missed.
-- Returns nil only when there are no panels at all.
function Panel.indexAt(panels, x, y)
    if not (panels and #panels > 0) then
        return nil
    end
    if not (x and y) then
        return nil
    end
    local nearest, nearest_d
    for i, p in ipairs(panels) do
        if x >= p.x and x < p.x + p.w and y >= p.y and y < p.y + p.h then
            return i
        end
        local cx = p.x + p.w / 2
        local cy = p.y + p.h / 2
        local dx, dy = x - cx, y - cy
        local d = dx * dx + dy * dy
        if not nearest_d or d < nearest_d then
            nearest, nearest_d = i, d
        end
    end
    return nearest
end

return Panel
