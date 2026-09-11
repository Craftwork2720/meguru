--[[--
A virtual, streaming document: the thing KOReader actually opens for a Meguru
book.

In *streamed* mode `self.file` is a marker — a small Lua file holding a stream
template and a page count — and pages are fetched one at a time over HTTP.
Raw bytes live in a small on-disk LRU, decoded buffers in two small in-memory
ones. ReaderUI's page N is template index N-1, because OPDS-PSE counts pages
from zero.

In *local archive* mode (`local_cbz`) `self.file` is a real .cbz the user routed
here through KOReader's "Open with…". One MuPDF handle renders every page
through the same pipeline as a streamed page, and every HTTP seam is bypassed.
Meguru registers the extension at a low weight so MuPDF stays the default.

There is no engine instance behind this document (`_document` is nil), so every
Document virtual ReaderPaging / ReaderZooming / ReaderView / ReaderHinting would
otherwise reach for the engine is overridden here: geometry is presented the way
a KOpt document presents it, with the crop living in the bounding box rather
than in the page size.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Document = require("document/document")
local DrawContext = require("ffi/drawcontext")
local Geom = require("ui/geometry")
local Screen = require("device").screen
local Device = require("device")
-- MuPDF binding (koreader-base ffi/mupdf). Guarded: every KOReader that can
-- run this plugin ships it, but should a build ever lack it the fallback lives
-- in the module that owns the render — see meguru/doc/image.lua — rather than
-- failing to load the whole document module.
local Mupdf
do
    local ok, mupdf = pcall(require, "ffi/mupdf")
    if ok and mupdf and mupdf.openDocumentFromText and mupdf.openDocument then
        Mupdf = mupdf
    end
end
local logger = require("logger")
local Cache = require("meguru/doc/cache")
local FS = require("meguru/fs")
local Image = require("meguru/doc/image")
local Marker = require("meguru/marker")
local Naming = require("meguru/naming")
local Paths = require("meguru/paths")
local PSE = require("meguru/pse")
local Settings = require("meguru/settings")
local Sources = require("meguru/sources")
local util = require("util")

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

-- ---------------------------------------------------------------------------
-- Auto page crop (white-margin detection)
-- ---------------------------------------------------------------------------
--
-- OPDS-PSE servers (and some scanners) deliver pages with a uniform white /
-- cream border around the actual artwork. Cropping such a page is done like a
-- KOpt-engine document would: the page size stays the page's own size and the
-- crop lives only in the document's bounding box. `getPageBBox`
-- (below) returns the trimmed content box when the "Page Crop" ConfigDialog
-- choice is "auto" (configurable.trim_page == 1) and the full page otherwise,
-- and ReaderZooming/ReaderView crop through that box for every "content" fit
-- mode ("content", "contentwidth", "contentheight"), which is what this
-- plugin's Fit menu now maps onto.
--
-- Detection is one pass, on the page rendered at 1:1 — the resolution stock's
-- own auto-crop scans at, and the reason it needs no second, finer pass to
-- land on the artwork: a margin one pixel wide is a margin one pixel wide, and
-- nothing has blurred it away. scanContentBounds reads raw pixels
-- (Blitbuffer.tostring gives us the bytes, the same route TileCacheItem uses to
-- serialize a tile), finds the first and last row and column that differ from
-- the uniform light border, and also decides which pages to leave alone:
-- blank, dark full-bleed art, a drawn dark frame. computeContentBox turns that
-- into the box getPageBBox hands out, and applies stock's rule for when to
-- believe it.
--
-- The 1:1 render is the one thing here that can be refused rather than
-- approximated: a page too large to scan at that size is cropped not at all
-- (AUTOCROP_MAX_SCAN_PIXELS). A crop guessed from a downscale is a crop that
-- can cut into the artwork, and stock's own answer when it cannot trust its
-- detection is the whole page.
--
-- The two finer crops a KOReader CBZ user gets from the pagenumbercrop plugin
-- — removing a printed page number from the bottom gutter, and "no crop on
-- blank pages" — are built in here (see the "Page-number / blank-page
-- analysis" section below and the rewritten getPageBBox): with the plugin
-- absent they run straight off this document's own getPageBBox, and its
-- bottom-menu rows (see main.lua) toggle them. When the plugin IS installed it
-- drives both (plus its screen-level "Rotate wide pages") by wrapping this
-- document's getPageBBox, exactly as it wraps a KOpt engine's, and this
-- document's body yields only the plain margin/full box below (see the
-- _pagenum_cache gate in getPageBBox) — so the two never double-crop.

-- Long edge of the buffer the panel detector scans (see panelScanBuffer). The
-- margin auto-crop does *not* use this — it scans the page at 1:1, which is
-- what stock does, because a margin is only a pixel or two wide and a downscale
-- is exactly what blurs one away.
local PANEL_SCAN_TARGET = 256

local AUTOCROP_MIN_BG_LUMA = 170 -- only treat a light border as a margin
local AUTOCROP_LUMA_DELTA = 26   -- how much a pixel may differ from the border

-- How far inside the page edge the background ring is sampled, in pixels. See
-- the ring loop in scanContentBounds for why it is not zero.
local AUTOCROP_RING_INSET = 2

-- How much of its span a row or column must carry to count as the start of
-- content: 0.2% of it, i.e. "more than an isolated speck".
--
-- This figure is not invented here. It is the bar the native-resolution fine
-- pass used, whose whole job was to pin a coarse edge to the exact outermost
-- content pixel — a corner of an illustration, the tip of a speech bubble, a
-- thin drawn frame line, all of which carry far less than a fiftieth of the
-- span. The coarse pass that fed it used 2% and could afford to, because the
-- fine pass corrected it afterwards.
--
-- That pass is gone (the scan is 1:1 now, so there is nothing left to refine)
-- and 2% stayed behind in sole charge of the decision — which is why the crop
-- cut into the top and the side of pages: any outermost row or column carrying
-- less than 2% of the span was ignored and the box started past it.
local AUTOCROP_EDGE_MIN_FRAC = 0.002

-- The largest page the auto-crop will scan at 1:1, in pixels.
--
-- Stock has no such line: `KoptInterface:getAutoBBox` renders the page whole at
-- zoom 1.0 and takes whatever the bitmap costs — ~48 MB for a manhwa strip
-- 800x20000, which is the sort of allocation a low-RAM device answers by
-- swapping or dying. Above this the crop is declined and the page is shown
-- untrimmed, which is the same answer stock itself gives when its detected box
-- is too small to believe.
--
-- Budgeted in pixels because that is what the page is measured in, but the cost
-- is per byte and runs to roughly twice the pixel count: the streamed render is
-- asked for grayscale (image.lua's `setColorRendering(false)`), so it is one
-- byte per pixel, and `Blitbuffer.tostring` in the scan takes a second copy of
-- it. 8 Mpx is therefore ~16 MB of transient against a 2000x3000 scan, which
-- has room to spare.
local AUTOCROP_MAX_SCAN_PIXELS = 8 * 1024 * 1024


-- Blitbuffer pixel type -> bytes per pixel. Decoders give us one of these
-- (grayscale BB8 on e-ink devices, RGB24/RGB32 on color ones; BB8A for PNGs
-- with an alpha channel). Anything else (BB4, exotic) makes us bail out.

-- Diagnostic: a page is being kept as-is although the crop refused (visible
-- as "the white frame stays"). Logged at warn level (not dbg) so it shows up
-- in crash.log without -d; pageno (when known) makes the line matchable to a
-- "fetching page …?pageNumber=N" log.
local function cropSkipWarn(pageno, ...)
    if pageno then
        logger.warn("Meguru: crop skip (page", pageno, "):", ...)
    else
        logger.warn("Meguru: crop skip:", ...)
    end
end

-- Scan a small BlitBuffer for the content bounding box. Returns
-- { left, top, right, bottom } (inclusive pixel indices, small-image
-- coordinates) or nil when the page is blank / unsupported / has no light
-- uniform margin.
local function scanContentBounds(bb, pageno)
    local w = bb:getWidth()
    local h = bb:getHeight()
    if not w or not h or w < 3 or h < 3 then
        return nil
    end
    if bb:getRotation() and bb:getRotation() ~= 0 then
        return nil -- raw rows are not axis-aligned; refuse rather than mis-scan
    end
    local bpp = Image.bytesPerPixel(bb:getType())
    if not bpp then
        return nil
    end
    local inverse = bb:getInverse() == true
    local data = Blitbuffer.tostring(bb)
    local stride = tonumber(bb.stride)
    if not stride or stride < w * bpp then
        stride = w * bpp
    end
    if #data < stride * h then
        -- Some builds hand back tightly packed rows without the per-row
        -- stride padding; fall back to the compact layout before giving up.
        stride = w * bpp
        if #data < stride * h then
            return nil -- unexpected layout, refuse rather than mis-scan
        end
    end

    local function lumaAt(y, x)
        local off = y * stride + x * bpp
        local lum
        if bpp == 1 then
            lum = data:byte(off + 1)
        elseif bpp == 2 then
            -- BB8A: gray + alpha. Using min() keeps transparent (alpha 0)
            -- texels as "content", i.e. we never crop away transparent frame
            -- areas of a PNG; opaque near-white texels stay background.
            local a = data:byte(off + 1)
            local b = data:byte(off + 2)
            lum = a < b and a or b
        else
            lum = (data:byte(off + 1) + data:byte(off + 2) + data:byte(off + 3)) * (1/3)
        end
        if inverse then
            lum = 255 - lum
        end
        return lum
    end

    -- Reference background = the *lightest typical* luminance of the outer
    -- ring (85th percentile), not its mean. A mean is easily dragged down by
    -- dark content bleeding onto one edge/corner or by a scan vignette; when
    -- it drops far enough below the true white margin, |margin − bg| exceeds
    -- the delta below and the white margins themselves get classified as
    -- "content" (the whole page then looks edge-to-edge full). A high
    -- percentile tracks the light border as long as the border makes up even a
    -- minority of the ring samples, which is exactly the "has a white margin"
    -- case.
    -- The ring is sampled a couple of pixels in, never on the very edge.
    --
    -- This runs on the page at its own resolution now, and at that size the
    -- outermost row and column are exactly the scanner's edge: a one-pixel dark
    -- line around a scan is common, and sampling it would make EVERY ring
    -- sample dark, push `bg` under AUTOCROP_MIN_BG_LUMA and switch the crop off
    -- for the whole book — silently, since "no crop" is also the answer for a
    -- page that genuinely has no margin. (On the downscale this used to run on,
    -- that line averaged into its neighbours and disappeared; the inset is what
    -- replaces that accidental tolerance, deliberately rather than by luck.)
    local inset = math.min(AUTOCROP_RING_INSET, math.floor((math.min(w, h) - 1) / 2))
    local rx0, rx1 = inset, w - 1 - inset
    local ry0, ry1 = inset, h - 1 - inset
    local samples = {}
    for x = rx0, rx1 do
        samples[#samples + 1] = lumaAt(ry0, x)
        samples[#samples + 1] = lumaAt(ry1, x)
    end
    for y = ry0 + 1, ry1 - 1 do
        samples[#samples + 1] = lumaAt(y, rx0)
        samples[#samples + 1] = lumaAt(y, rx1)
    end
    table.sort(samples)
    local bg = samples[math.max(1, math.floor(#samples * 0.85))]

    if bg < AUTOCROP_MIN_BG_LUMA then
        -- Even the lightest-typical ring sample is dark: the page truly has no
        -- light border to anchor on (full-bleed dark page / dark frame). The
        -- crop refuses so it never crops *into* artwork.
        cropSkipWarn(pageno, "border not light enough (bg=",
            math.floor(bg), ") — page kept as-is")
        return nil -- dark border / full-bleed dark page: keep it untouched
    end

    -- Project content pixels onto rows and columns.
    local row_cnt = {}
    local col_cnt = {}
    for y = 0, h - 1 do
        local base = y * stride
        local rcount = 0
        for x = 0, w - 1 do
            local off = base + x * bpp
            local lum
            if bpp == 1 then
                lum = data:byte(off + 1)
            elseif bpp == 2 then
                local a = data:byte(off + 1)
                local b = data:byte(off + 2)
                lum = a < b and a or b
            else
                lum = (data:byte(off + 1) + data:byte(off + 2) + data:byte(off + 3)) * (1/3)
            end
            if inverse then
                lum = 255 - lum
            end
            if math.abs(lum - bg) > AUTOCROP_LUMA_DELTA then
                rcount = rcount + 1
                col_cnt[x] = (col_cnt[x] or 0) + 1
            end
        end
        row_cnt[y] = rcount
    end

    -- A candidate row/column must contain more than a couple of speck pixels
    -- to count as the start of actual content — see AUTOCROP_EDGE_MIN_FRAC,
    -- which is the figure the deleted fine pass used for this same call.
    local row_min = math.max(2, math.floor(w * AUTOCROP_EDGE_MIN_FRAC))
    local col_min = math.max(2, math.floor(h * AUTOCROP_EDGE_MIN_FRAC))

    local left, top, right, bottom
    for y = 0, h - 1 do
        if row_cnt[y] >= row_min then
            top = y
            break
        end
    end
    for y = h - 1, 0, -1 do
        if row_cnt[y] >= row_min then
            bottom = y
            break
        end
    end
    for x = 0, w - 1 do
        if (col_cnt[x] or 0) >= col_min then
            left = x
            break
        end
    end
    for x = w - 1, 0, -1 do
        if (col_cnt[x] or 0) >= col_min then
            right = x
            break
        end
    end
    if not (left and top and right and bottom) then
        -- A light border but no row/column clears the content bar anywhere: the
        -- whole page reads as uniform background (or the content bar is too
        -- low — see row_min/col_min). This is the "blank page" case.
        cropSkipWarn(pageno, "no content found anywhere (page blank?)")
        return nil -- blank page
    end
    -- Suspicious case worth flagging: a *light* border (bg above) yet the
    -- detected content still spans the entire small image edge-to-edge. When
    -- this box comes back whole, computeContentBox has nothing left to trim and
    -- the page is kept as-is — i.e. the exact "whole frame stays" symptom.
    if left == 0 and top == 0 and right == w - 1 and bottom == h - 1 then
        cropSkipWarn(pageno, "detected content spans the whole page",
            "(bg=", math.floor(bg), ", ", w, "x", h, ") — nothing to trim")
    end
    -- `bg` (the reference border luminance) rides along so a caller can reuse
    -- the same content predicate this scan used.
    return { left, top, right, bottom, bg = bg }
end

-- Compute the native auto content box of a decoded (working-resolution) page.
-- Returns { x0, y0, x1, y1 } in native pixels, or nil when the page should be
-- left as-is (no detectable light margin, blank, or any scan hiccup — a crop
-- must never be worse than no crop). This is the *plain margin* crop only;
-- the finer page-number / blank-page refinements used to be layered on top
-- here but now live in the pagenumbercrop plugin, which wraps getPageBBox.
--
-- Maximal on every side: top, bottom, left and right are each trimmed right
-- up to the detected white margin, whatever lies between the content and the
-- page edge is cut. The left and right margins are detected independently, so
-- an asymmetric frame is trimmed asymmetrically (never centered): the result
-- is the smallest box that contains the artwork on all four sides.
--
-- `page_bb` is the page at 1:1 — the resolution stock scans at, and the reason
-- this needs no second pass: a margin one pixel wide survives a scan taken at
-- the page's own size, and is exactly what a downscale erases. Callers that
-- cannot afford a 1:1 buffer decline the crop rather than passing a smaller
-- one (see autoContentBox).
--
-- The result feeds getPageBBox (the bbox ReaderZooming/ReaderView crop
-- through), cached per page in self.crops. It is never baked into the page
-- size: getPageDims reports the page's own size.
local function computeContentBox(page_bb, pageno)
    -- Returns { x0,y0,x1,y1 } in page pixels, or nil for "nothing to trim".
    --
    -- `page_bb` belongs to the caller, so nothing here frees it, and the scan
    -- allocates nothing: it is a pure read of a buffer someone else owns.
    local ok, box = pcall(function()
        local w = page_bb:getWidth()
        local h = page_bb:getHeight()
        if not w or not h or w < 1 or h < 1 then
            return nil
        end
        local bounds = scanContentBounds(page_bb, pageno)
        if not bounds then
            return nil
        end
        -- `right` and `bottom` are inclusive pixel indices; the box is exclusive.
        local x0 = math.max(0, bounds[1])
        local y0 = math.max(0, bounds[2])
        local x1 = math.min(w, bounds[3] + 1)
        local y1 = math.min(h, bounds[4] + 1)
        if x0 == 0 and y0 == 0 and x1 == w and y1 == h then
            return nil
        end
        -- Stock's acceptance rule, verbatim in meaning if not in code
        -- (KoptInterface:getAutoBBox): believe the detected box only when it
        -- spans more than a tenth of the page in SOME direction, and keep the
        -- whole page otherwise. It is a "is this a page or is this noise" test,
        -- not a "did we trim enough" one — a legitimately thin strip of artwork
        -- down the middle of a page passes, which an area-based rule would
        -- reject.
        if (x1 - x0) / w <= 0.1 and (y1 - y0) / h <= 0.1 then
            cropSkipWarn(pageno, "detected box under a tenth of the page in",
                "both axes — keeping the whole page")
            return nil
        end
        -- One line per cropped page: the box, the page it was measured on, and
        -- the background it was measured against. A crop that cuts into the
        -- artwork and a crop that leaves a margin look identical on the screen
        -- and are opposite faults, so they have to be told apart by numbers
        -- rather than by eye. The refusals already log themselves.
        logger.info(string.format(
            "Meguru: crop page %d: %d,%d+%dx%d of %dx%d (bg=%d)",
            pageno, x0, y0, x1 - x0, y1 - y0, w, h, math.floor(bounds.bg or 0)))
        return { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
    end)
    if not ok then
        logger.warn("Meguru: auto-crop scan failed:", box)
        return nil
    end
    return box
end

-- ---------------------------------------------------------------------------
-- Panel zoom (getPanelFromPage)
-- ---------------------------------------------------------------------------
--
-- KOReader's "Panel zoom (manga/comic)" (ReaderHighlight:onPanelZoom, a
-- long-press) asks the document for the panel under the finger via
-- Document:getPanelFromPage. Engine-backed paged documents answer with kopt's
-- full page segmentation; this document has no engine, so without an override
-- the call would be nil and the reader would crash. This is a light,
-- conservative stand-in:
--
--   * on a downscaled copy of the page we look for *full-span gutters*: rows
--     that stay within a few percent of the page's paper white across the whole
--     content width, and columns that do the same across the whole content
--     height (that is what separates manga/comic panels that tile edge to
--     edge);
--   * the touch point is then assigned to the gutter-bounded cell around it;
--   * pages with no readable grid (single splash images, dark paper) return
--     nil, exactly like kopt when it cannot find a panel — the long-press then
--     does nothing or falls back to text selection instead of crashing.
--
-- Coordinates: ReaderView hands the touch in *full native* page space — the
-- space getNativePageDimensions/getPageDims report. A margin crop only makes
-- ReaderView zoom in; it never shifts tap coordinates (content sits at the
-- bbox origin, already accounted for by ReaderView), so both the touch point
-- and the returned {x,y,w,h} are plain native page coordinates, and the
-- returned rect is what drawPagePart expects. There is no rotation in this
-- plugin anymore, so no page is ever turned here.
--
-- The detector is intentionally strict: it only ever splits on *complete*
-- white gutters, never on interior white of a single drawing, so a wrong guess
-- degrades to "no panel", never to a mangled crop.

local PANEL_GUTTER_FRAC = 0.85 -- gutter pixels must stay above 85% of paper white
local PANEL_MIN_GUTTER_FRAC = 0.004 -- ignore separators thinner than 0.4% of the span
local PANEL_MIN_CELL_FRAC = 0.05 -- never report a panel under 5% of the page area

-- Cheap raster accessor over a BlitBuffer's raw bytes (same layout handling as
-- the auto-crop scan above).
local function makeRaster(bb)
    local w = bb:getWidth()
    local h = bb:getHeight()
    if not w or not h or w < 2 or h < 2 then
        return nil
    end
    local bpp = Image.bytesPerPixel(bb:getType())
    if not bpp then
        return nil
    end
    local inv = bb:getInverse() == true
    local data = Blitbuffer.tostring(bb)
    local stride = tonumber(bb.stride)
    if not stride or stride < w * bpp then
        stride = w * bpp
    end
    if #data < stride * h then
        stride = w * bpp
        if #data < stride * h then
            return nil
        end
    end
    local function luma(y, x)
        local off = y * stride + x * bpp
        local lum
        if bpp == 1 then
            lum = data:byte(off + 1)
        elseif bpp == 2 then
            local a = data:byte(off + 1)
            local b = data:byte(off + 2)
            lum = a < b and a or b
        else
            lum = (data:byte(off + 1) + data:byte(off + 2) + data:byte(off + 3)) * (1/3)
        end
        if inv then
            lum = 255 - lum
        end
        return lum
    end
    return { w = w, h = h, luma = luma }
end


-- Consecutive runs of indices (in [a0, a1)) where clean(i) is true.
local function collectCleanBands(a0, a1, clean)
    local bands = {}
    local start
    for i = a0, a1 - 1 do
        if clean(i) then
            if not start then
                start = i
            end
        elseif start then
            bands[#bands + 1] = { a = start, b = i - 1 }
            start = nil
        end
    end
    if start then
        bands[#bands + 1] = { a = start, b = a1 - 1 }
    end
    return bands
end

-- Keep only the bands that are fully interior to the content span (i.e. real
-- separators, not the white margin at an edge) and at least `min_thick` thick.
local function keepInteriorBands(bands, c0, c1, min_thick)
    local kept = {}
    for _, b in ipairs(bands) do
        if b.a > c0 and b.b < c1 - 1 and b.b - b.a + 1 >= min_thick then
            kept[#kept + 1] = b
        end
    end
    return kept
end

-- Gutter-bounded cell around (tap_x, tap_y). `cont` is the content rectangle in
-- small-image coordinates (x1/y1 exclusive). Returns { x0, y0, x1, y1 }
-- (x1/y1 exclusive, same coordinate space) or nil when there is no grid.
local function findPanelBounds(raster, cont, tap_x, tap_y)
    local paper = 0
    for y = cont.y0, cont.y1 - 1 do
        for x = cont.x0, cont.x1 - 1 do
            local lum = raster.luma(y, x)
            if lum > paper then
                paper = lum
            end
        end
    end
    if paper < 150 then
        return nil -- dark paper: gutters cannot be told apart from artwork
    end
    local threshold = paper * PANEL_GUTTER_FRAC
    local row_dark = {}
    local col_dark = {}
    for y = cont.y0, cont.y1 - 1 do
        local cnt = 0
        for x = cont.x0, cont.x1 - 1 do
            if raster.luma(y, x) <= threshold then
                cnt = cnt + 1
                col_dark[x] = (col_dark[x] or 0) + 1
            end
        end
        row_dark[y] = cnt
    end
    -- A separator row/column may contain a hair of scan/JPEG noise, but nothing
    -- more than ~1% of its span.
    local row_tol = math.max(1, math.floor((cont.x1 - cont.x0) * 0.01))
    local col_tol = math.max(1, math.floor((cont.y1 - cont.y0) * 0.01))
    local h_bands = collectCleanBands(cont.y0, cont.y1,
        function(y) return (row_dark[y] or 0) <= row_tol end)
    local v_bands = collectCleanBands(cont.x0, cont.x1,
        function(x) return (col_dark[x] or 0) <= col_tol end)
    local min_h = math.max(1, math.floor((cont.y1 - cont.y0) * PANEL_MIN_GUTTER_FRAC + 0.5))
    local min_w = math.max(1, math.floor((cont.x1 - cont.x0) * PANEL_MIN_GUTTER_FRAC + 0.5))
    h_bands = keepInteriorBands(h_bands, cont.y0, cont.y1, min_h)
    v_bands = keepInteriorBands(v_bands, cont.x0, cont.x1, min_w)
    if #h_bands == 0 and #v_bands == 0 then
        return nil -- splash page / single drawing / plain margins only
    end
    -- Narrow the cell down to the nearest gutter above/below and left/right of
    -- the tap (only gutters that do not contain the tap itself are considered).
    local top = cont.y0
    local bottom = cont.y1 - 1
    local left = cont.x0
    local right = cont.x1 - 1
    for _, b in ipairs(h_bands) do
        if b.b < tap_y then
            top = math.max(top, b.b + 1)
        elseif b.a > tap_y then
            bottom = math.min(bottom, b.a - 1)
        end
    end
    for _, b in ipairs(v_bands) do
        if b.b < tap_x then
            left = math.max(left, b.b + 1)
        elseif b.a > tap_x then
            right = math.min(right, b.a - 1)
        end
    end
    if top > bottom or left > right then
        return nil
    end
    return { x0 = left, y0 = top, x1 = right + 1, y1 = bottom + 1 }
end

-- ---------------------------------------------------------------------------
-- Native decode resolution cap
-- ---------------------------------------------------------------------------
--
-- The pagenumbercrop plugin renders its crop-analysis strips by calling the
-- *base* `Document.renderPage` method slot directly (it is a standalone plugin
-- that patches engine module code, and for a PdfDocument the engine-backed
-- renderPage is an instance override of exactly that slot). For this virtual
-- document — _document == nil — the base slot would crash on the missing
-- engine (document.lua:514), so the slot is redirected once per process: our
-- own documents delegate to their renderPage (which already implements the
-- prescaled contract pagenumbercrop relies on), every other document keeps the
-- pristine base behaviour.
local _render_page_shim_installed = false
local function installRenderPageShim()
    if _render_page_shim_installed then
        return
    end
    _render_page_shim_installed = true
    local base_render_page = Document.renderPage
    Document.renderPage = function(self, pageno, rect, zoom, rotation, ...)
        if self.provider == "meguru" then
            return self:renderPage(pageno, rect, zoom, rotation, ...)
        end
        return base_render_page(self, pageno, rect, zoom, rotation, ...)
    end
end
installRenderPageShim()

-- External manga-panel plugins that drive KOReader's native KOPT detector
-- directly (e.g. Panels+) reach the document's geometry the same way
-- pagenumbercrop reaches renderPage: they call the *base*
-- `Document.getNativePageDimensions` slot explicitly — dot form,
-- `Document.getNativePageDimensions(doc, page)` — never through the instance,
-- so this document's getNativePageDimensions override is bypassed. For this
-- virtual document that base slot would crash on the missing engine
-- (_document is nil: document.lua "attempt to index field '_document'"). The
-- slot is redirected once per process, exactly like the renderPage shim above:
-- our own documents answer from their getNativePageDimensions override (the
-- full native page — the coordinate space the plugin's probe grid and our
-- getPanelFromPage share), every other document keeps the pristine base
-- behaviour bit-for-bit. With the slot answered, the plugin's batched KOPT
-- path bails out on its own `not document._document` guard and falls back to
-- probing `document:getPanelFromPage` — this document's conservative panel
-- detector — so panel zoom works on a streamed book instead of crashing.
local _native_page_dimensions_shim_installed = false
local function installNativePageDimensionsShim()
    if _native_page_dimensions_shim_installed then
        return
    end
    _native_page_dimensions_shim_installed = true
    local base_get_native_page_dimensions = Document.getNativePageDimensions
    Document.getNativePageDimensions = function(self, pageno, ...)
        if self.provider == "meguru" then
            return self:getNativePageDimensions(pageno, ...)
        end
        return base_get_native_page_dimensions(self, pageno, ...)
    end
end
installNativePageDimensionsShim()

local MeguruDocument = Document:extend{
    _document = nil, -- we have no engine instance
    provider = "meguru",
    -- Label shown for this provider in KOReader's stock "Open with…" picker
    -- (the dialog lists DocumentRegistry providers by provider.provider_name).
    -- It covers both extensions this class registers: the .meguru stream markers
    -- and the opt-in local .cbz routing.
    provider_name = "Meguru",
    dc_null = DrawContext.new(),

    -- Local-archive mode (a .cbz opened through this engine — see init):
    -- when set, the book is rendered page-by-page from one persistent MuPDF
    -- handle (self.mupdf_doc) instead of being fetched over HTTP, and every
    -- byte-consuming seam is bypassed.
    local_cbz = false,
    mupdf_doc = nil,

    -- Number of following pages fetched in the background after a repaint
    -- (via ReaderHinting -> Document:hintPage).
    prefetch_count = 1,
    -- Maximum number of decoded/scaled tiles kept in RAM per document.
    max_cached_tiles = 8,
    -- Maximum number of downscaled whole-page scan buffers kept in RAM for the
    -- panel detector (see panelScanBuffer). The auto-crop's 1:1 scan is
    -- transient and never lands here — it is a whole page at native size.
    max_cached_scans = 3,
    -- Maximum number of page-byte files kept on disk (global LRU, shared by all docs).
    max_disk_pages = 240,

    tiles = nil,    -- decoded tile LRU, key = "pageno|w x h"
    scans = nil,    -- whole-page scan LRU, key = pageno
    stamps = nil,   -- key -> recency stamp for both LRUs
    stamp = 0,
    dims = nil,     -- pageno -> {w=, h=} the page's own size, measured by
                    --            page:getSize (never cropped)
    crops = nil,    -- pageno -> auto content box {x0,y0,x1,y1} in native px
                    --            (plain margin scan, see computeContentBox),
                    --            cached for getPageBBox / getPanelFromPage;
                    --            false == full page (no margin trimmed); a nil
                    --            *returned* box means the same (see autoContentBox)
    desc = nil,     -- the stream descriptor read from the marker file
}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

-- Open a local .cbz for this document. Returns the open MuPDF document, or nil
-- (with a logged reason). This mirrors how the stock DocumentMuPDF opens the
-- same file, so page order and page count always agree between the two
-- engines. Local rendering cannot fall back to RenderImage (there are no entry
-- bytes to decode), so a missing MuPDF binding must fail the open here rather
-- than crash mid-render on the first page.
function MeguruDocument:_openLocalArchive()
    if not Mupdf then
        logger.warn("Meguru: MuPDF binding unavailable; cannot open a local CBZ")
        return nil
    end
    local ok_doc, doc = pcall(Mupdf.openDocument, self.file)
    if not ok_doc or not doc then
        logger.warn("Meguru: MuPDF cannot open", self.file, ":", tostring(doc))
        return nil
    end
    -- Ask MuPDF for a grayscale pixmap, exactly like a streamed page
    -- (image.lua sets the same flag), so a local cbz looks bit-for-bit like a
    -- .meguru book on every screen.
    if doc.setColorRendering then
        doc:setColorRendering(false)
    end
    return doc
end

function MeguruDocument:init()
    self.tiles = {}
    self.scans = {}
    self.stamps = {}
    self.stamp = 0
    self.dims = {}
    self.crops = {}
    -- Pages whose decode has failed (or that were refused as too large to
    -- decode on this device) are remembered so a doomed full-resolution decode
    -- is never attempted more than once per page — re-attempting it every
    -- paint is what turned a single failed ~100 MB malloc into the repeated
    -- OOM kill.
    self.dead_pages = {}

    self.mod_time = FS.mtime(self.file)

    -- Two opening modes, chosen by the file suffix BEFORE anything is parsed —
    -- a binary cbz must never be handed to LuaSettings / marker loading:
    --
    --  * .meguru  -> a streamed book: `self.file` is a marker holding the stream
    --    descriptor (server, template URL, count); pages are fetched one at a
    --    time over HTTP through the fetch seams below.
    --  * .cbz   -> a local archive the user routed through this engine with
    --    KOReader's stock "Open with…". desc stays nil for the book's whole
    --    life (every desc-based reader-side feature in main.lua is nil-safe:
    --    next-volume rows, end-of-book auto-open and the ⋮ stream rows simply
    --    stay inert), and the HTTP seams are bypassed — each page is rendered
    --    from the single open handle below.
    local desc
    if util.getFileNameSuffix(self.file):lower() == "cbz" then
        desc = nil
        self.local_cbz = true
        self.mupdf_doc = self:_openLocalArchive()
        if not self.mupdf_doc then
            -- Nothing was opened, so there is no partial document to leak; the
            -- error is caught by DocumentRegistry:openDocument and the file is
            -- simply not opened (it stays with native MuPDF next time).
            error("Meguru: cannot open local CBZ as a Meguru book: "
                .. tostring(self.file))
        end
    else
        desc = Marker.load(self.file)
        if not desc then
            error("Meguru: not a valid stream marker: " .. tostring(self.file))
        end
    end
    self.desc = desc

    -- The catalog row behind this marker, if there is one. Its template wins
    -- over the marker's snapshot — the snapshot is whatever was saved when the
    -- book was first opened, while the catalog's is what the last sync saw.
    -- The marker's stays as the fallback, which is the point of it carrying a
    -- template at all: a book opens and reads with no database. That fallback is
    -- already a *restored* template by the time it gets here — `Marker.load`
    -- puts the credential back from `settings/opds.lua`, so the marker sitting
    -- in the book folder holds a `<redacted>` one and this never sees it. Which
    -- is why the fallback needs the catalog *configured* rather than only the
    -- database absent; see `meguru/credential`.
    --
    -- Nothing here goes to the network. A catalog row with no template is a
    -- chapter that was synced but never opened; it is resolved when the series
    -- view opens it, not here — opening a book from History must not depend on
    -- being online.
    local item = self:_catalog()
    if item and type(item.template) == "string" and item.template ~= "" then
        desc.template = item.template
    end

    local count
    if self.local_cbz then
        -- MuPDF counts and orders the pages of the archive; these are the same
        -- 1-based numbers the stock DocumentMuPDF uses for the identical file,
        -- so page order and count always agree between the two engines. A
        -- 0-page archive is clamped to 1, mirroring the streamed clamp below.
        local ok_pages, n = pcall(self.mupdf_doc.getPages, self.mupdf_doc)
        count = ok_pages and tonumber(n) or 1
        if not count or count < 1 then
            count = 1
        end
    else
        count = tonumber(desc.count)
        if not count or count < 1 then
            count = 1
        end
    end

    -- Present the stock bottom ConfigDialog + ReaderConfig/ReaderKoptListener
    -- surface (see main.lua: the dialog is curated to only what this document
    -- and the pagenumbercrop plugin implement). info.configurable = true gates
    -- ReaderUI's "config" module (ReaderConfig) and, together with has_pages,
    -- the "koptlistener" (ReaderKoptListener); koptinterface = {} is the
    -- sentinel ReaderConfig checks to pick the KOpt option set over the CRE
    -- one, and the one pagenumbercrop gates its own init on (see its main.lua).
    -- The numeric configurable fields (trim_page, text_wrap, ...) are filled in
    -- right after this by ReaderConfig:init -> loadDefaults(KoptOptions), then
    -- overridden per book from the marker's DocSettings; main.lua's
    -- onReadSettings re-asserts the plugin defaults on top.
    self.info = {
        has_pages = true,
        number_of_pages = count,
        configurable = true,
    }
    self.koptinterface = {}
    self.configurable.writing_direction = 0 -- LTR
    self.render_mode = 0
    self.is_open = true

    -- We cannot know beforehand how big pages are, so we scale decoded
    -- BlitBuffers to the requested size.
    self:updateColorRendering()
    -- Dither every tile->screen blit, unconditionally. The pages we decode are
    -- full pictures whose cached tiles are colour (RGB24) buffers, so on a
    -- grayscale screen every paint is a colour->gray *converting* blit — and
    -- the dithered variant (ditherblitFrom, used in drawPage/drawPageInverted
    -- below) is what keeps smooth gradients from banding. Unlike PicDocument
    -- this is deliberately NOT restricted to 8bpp e-ink screens without HW
    -- dithering: KOReader's ditherblitFrom only honours the dither when the
    -- destination is BB8 and otherwise falls back to a plain blit (blitbuffer.c
    -- "BB_dither_blit_to"), so enabling it always is safe on every screen —
    -- a colour one gets a plain blit no-op — and the dithered look is
    -- guaranteed wherever it can help.
    self.sw_dithering = true
    logger.info(string.format(
        "Meguru: tile->screen dithering forced ON (sw_dithering; eink=%s, fb_bpp=%s, hw_dither=%s)",
        tostring(Device:hasEinkScreen()), tostring(Screen.fb_bpp),
        tostring(Device:canHWDither())))

    if self.local_cbz then
        logger.info(string.format(
            "Meguru: local CBZ ready — \"%s\", %d page(s) at %s",
            self:_localTitle(), count, self.file))
    else
        logger.info(string.format(
            "Meguru: stream ready — \"%s\", %d page(s), cached at %s",
            desc.title or "?", count, self.file))
    end

    -- Two things are seeded into this book's own DocSettings, and they want the
    -- same sidecar.
    --
    -- 1. The plugin-wide "Manga mode" (invert read) choice — KOReader's
    --    ReaderView only reads "inverse_reading_order" per book, falling back to
    --    its *global* default otherwise, a global this plugin deliberately never
    --    touches. Books that already carry an explicit reading order (set
    --    through the bottom-menu Manga mode row or elsewhere) are left alone;
    --    only books with none are seeded, so existing markers honour the plugin
    --    setting too. The bottom-menu Manga mode toggle keeps this key in sync.
    --
    -- 2. The page the *server* says the reader stopped on — but **only** for a
    --    book never opened on this device, because a book opened before carries
    --    KOReader's own position, which is finer-grained, and seeding over it
    --    would move the reader backwards.
    --
    --    This is the only way to land on a page at the first paint:
    --    `ReaderUI:showReader` takes no page, and both of its post-open callbacks
    --    fire *after* the first render. `ReaderPaging:onReadSettings` reads
    --    `last_page` out of this sidecar, and this runs before that — the
    --    document is opened before `ReaderUI:init` even loads the settings.
    --
    --    Silent on this path, deliberately. `ui/open.lua` asks instead, but only
    --    when it is the one doing the opening; a book opened from the file
    --    manager or History reaches the reader with no moment to ask in.
    --
    -- `hasSidecarFile` is asked first and must stay first: the `DocSettings:open`
    -- below creates the very file it looks for, so asking afterwards would make
    -- every book look like a first open.
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if ok_ds then
        local opened_before = DocSettings:hasSidecarFile(self.file)
        local ok_seed, err = pcall(function()
            local ds = DocSettings:open(self.file)
            if ds:readSetting("inverse_reading_order") == nil then
                ds:saveSetting("inverse_reading_order", Settings.get("manga_order"))
                ds:flush()
            end
            -- The recorded page is used exactly as recorded. It is *not* trimmed
            -- back past the prefetch lead, even though a book read here is
            -- recorded a page ahead: a position recorded by another reader has no
            -- such lead, and trimming would walk the reader back pages they had
            -- already read. This only runs for a book never opened here, so there
            -- is no local page to weigh it against — the recording is all there is.
            local page = not opened_before and tonumber(desc.last_read) or nil
            if page and page > 1 and page <= count then
                ds.data.last_page = math.floor(page)
                ds:flush()
                logger.info("Meguru: starting", self.file, "at page", page,
                    "(the server's position)")
            end
        end)
        if not ok_seed then
            logger.warn("Meguru: could not seed the book's sidecar:", err)
        end
    end
    return true
end

function MeguruDocument:close()
    local DocumentRegistry = require("document/documentregistry")
    if self.is_open then
        local refcount
        local ok = pcall(function()
            refcount = DocumentRegistry:closeDocument(self.file)
        end)
        if not ok then
            refcount = 0
        end
        if refcount == 0 then
            self:clearCaches()
            -- Local cbz: release the persistent MuPDF document (and forget it,
            -- so close stays idempotent for a stray second call).
            if self.local_cbz and self.mupdf_doc then
                pcall(self.mupdf_doc.close, self.mupdf_doc)
                self.mupdf_doc = nil
            end
            self.is_open = false
            return true
        end
        logger.dbg("Meguru: stream refcount down to", refcount, "for", self.file)
        return false
    end
    logger.warn("Tried to close an already closed document:", self.file)
    return nil
end

function MeguruDocument:clearCaches()
    for _, cache in ipairs({ self.tiles or {}, self.scans or {} }) do
        for _, item in pairs(cache) do
            if item.bb and item.bb_free ~= true then
                item.bb:free()
                item.bb_free = true
            end
        end
    end
    self.tiles = {}
    self.scans = {}
    self.stamps = {}
end

-- ---------------------------------------------------------------------------
-- LRU helpers (RAM: tiles & native pages)
-- ---------------------------------------------------------------------------

local function bump(self, key)
    self.stamp = self.stamp + 1
    self.stamps[key] = self.stamp
end

local function evictOldest(self, cache, cap)
    local count = 0
    for _ in pairs(cache) do
        count = count + 1
    end
    while count >= cap do
        local oldest_key, oldest_stamp
        for k, _ in pairs(cache) do
            if oldest_key == nil or (self.stamps[k] or 0) < oldest_stamp then
                oldest_key = k
                oldest_stamp = self.stamps[k] or 0
            end
        end
        if oldest_key == nil then
            break
        end
        local item = cache[oldest_key]
        cache[oldest_key] = nil
        self.stamps[oldest_key] = nil
        if item and item.bb and item.bb_free ~= true then
            item.bb:free()
            item.bb_free = true
        end
        count = count - 1
    end
end

function MeguruDocument:cacheTile(key, tile)
    if self.tiles[key] then
        self.tiles[key].bb_free = true
        self.tiles[key].bb:free()
    end
    tile.bb_free = false
    self.tiles[key] = tile
    bump(self, key)
    evictOldest(self, self.tiles, self.max_cached_tiles)
end

-- ---------------------------------------------------------------------------
-- Bytes on disk (fetch page N, keep in a disk LRU)
-- ---------------------------------------------------------------------------

-- The book identity every cache file of this document is filed under.
--
-- Computed from the descriptor each time rather than captured at init, so a
-- descriptor refreshed from the catalog (the template is, at `init`) cannot
-- leave a stale copy behind — and so there is one derivation, not two.
function MeguruDocument:cacheKey()
    return Marker.cacheKey(self.desc)
end

-- Delegates rather than rebuilding the name: this method owns the *key*, the
-- cache module owns the *tail* of the name, and two spellings of either would
-- drift apart the moment one of them changed — taking the prune with it.
function MeguruDocument:pageCachePath(pageno)
    return Cache.pagePath(self:cacheKey(), pageno)
end

function MeguruDocument:readPageFromDisk(pageno)
    return Cache.read(self:pageCachePath(pageno))
end

function MeguruDocument:pruneDiskCache()
    Cache.prune(Paths.pageCacheDir(), self.max_disk_pages)
end

-- Credentials to fetch pages and the cover with.
--
-- Resolved at the moment of use and never stored: the marker holds the catalog
-- *title*, not a secret, and `meguru/sources` looks the credentials up in the
-- session's cache or read-only in KOReader's own settings/opds.lua.
--
-- "Not a secret" is about *these* credentials, and it is also true of the other
-- one: the stream template in `desc` had Kavita's API key stripped before it was
-- written and restored by `Marker.load`. Two different secrets, one file, and
-- neither of them in it.
function MeguruDocument:streamCredentials()
    local desc = self.desc or {}
    return Sources.credentials(desc.server_name, self.file)
end

-- Make sure the raw bytes of `pageno` are available (fetched over HTTP if not
-- cached on disk yet). Returns the bytes, or nil on failure.
function MeguruDocument:fetchPageToDisk(pageno)
    local data = self:readPageFromDisk(pageno)
    if data then
        return data
    end
    local url = self.desc.template
        and PSE.pageURL(self.desc.template, pageno - 1,
            Screen:getWidth(), Screen:getHeight())
        or nil
    if not url then
        return nil
    end
    local user, pass = self:streamCredentials()
    local ok, bytes, code = pcall(PSE.fetchPage, url, { username = user, password = pass })
    if not ok or not bytes then
        if ok then
            logger.warn("Meguru: failed to fetch page", pageno,
                "(HTTP " .. tostring(code) .. ")")
        else
            logger.warn("Meguru: failed to fetch page", pageno,
                "(error: " .. tostring(bytes) .. ")")
        end
        return nil
    end
    local path = self:pageCachePath(pageno)
    Cache.write(path, bytes)
    self:pruneDiskCache()
    return bytes
end

function MeguruDocument:prefetchPage(pageno)
    if pageno < 1 or pageno > self.info.number_of_pages then
        return
    end
    local ok, data = pcall(self.fetchPageToDisk, self, pageno)
    if ok and data then
        logger.dbg("Meguru: prefetched page", pageno, "to disk cache")
    end
end

-- ---------------------------------------------------------------------------
-- Page geometry (what ReaderZooming / ReaderView ask for)
-- ---------------------------------------------------------------------------

-- Local cbz documents have no stream descriptor; the book's title is derived
-- from the archive's own file name (basename without the suffix) — what a
-- native engine open of the same file would report.
function MeguruDocument:_localTitle()
    local name = self.file:match("([^/\\]+)$") or self.file
    return (name:gsub("%.[^.]*$", ""))
end

--- The catalog rows behind this marker: the item and its series, or nil.
---
--- Nil is an ordinary answer, not a failure — no database, a series that was
--- never synced, or a catalog rebuilt underneath the marker. Everything that
--- calls this must read as if the catalog were simply not there.
---
--- Resolved at most once per document: the open path asks several times, and
--- each miss costs three queries plus, on a cold start, opening the database.
function MeguruDocument:_catalog()
    if self.catalog_checked then
        return self.catalog_item, self.catalog_series
    end
    self.catalog_checked = true

    local desc = self.desc
    if not desc then
        return nil
    end
    -- pcall: this runs inside an open, and a missing sqlite binding or a
    -- corrupt database must cost the reader its next/prev rows, not the book.
    local ok, item, series, server = pcall(function()
        local Catalog = require("meguru/catalog")
        local found, found_series = Catalog.resolveMarker(desc.server_name,
            desc.series_remote_id, desc.item_key, desc.item_id)
        if not found_series then
            return found, found_series
        end
        return found, found_series, Catalog.server(found_series.server_id)
    end)
    if not ok then
        logger.info("Meguru: catalog unavailable for this book:", tostring(item))
        return nil
    end
    if item and item.hint_mismatch then
        -- The rowid in the marker is not the row its item_key names, so the
        -- database was rebuilt and rowids moved. The key decided; this is just
        -- the paper trail.
        logger.warn("Meguru: marker item_id disagrees with item_key; using the key")
    end
    self.catalog_item, self.catalog_series = item, series
    self.catalog_server = server
    return item, series
end

--- The item, series and server behind this book, or nil when the marker's
--- series was never catalogued. For callers outside the engine — the reader
--- menu's navigation rows, the end-of-book hook — which need the same rows the
--- engine resolved without repeating the lookup.
function MeguruDocument:catalogContext()
    local item, series = self:_catalog()
    if not (item and series) then
        return nil
    end
    return { item = item, series = series, server = self.catalog_server }
end

function MeguruDocument:getDocumentProps()
    if self.local_cbz then
        return { title = self:_localTitle() }
    end
    local desc = self.desc or {}
    -- A server-faithful title carries bookkeeping the reader should not see in
    -- History: a leading reading-progress glyph (Kavita's ◕/◔, Suwayomi's ⭕)
    -- or a "Continue Reading from:" resume prefix. Stripped exactly as the
    -- marker's file name already strips them. KOReader recomputes doc_props on
    -- every open, so this needs no migration to reach existing books.
    local title = desc.title and Naming.cleanTitle(desc.title)

    -- A Suwayomi chapter is titled after the chapter alone ("Chapter 84"), so
    -- History would list a bare "Chapter 84" with no manga to place it. The
    -- series name comes from the catalog, since the marker deliberately carries
    -- no series metadata, and is used only when the title does not already
    -- start with it — a Kavita volume title names its own series.
    local _, series = self:_catalog()
    local name = series and series.name
    if type(name) == "string" and name ~= ""
        and type(title) == "string" and title ~= ""
        and title:sub(1, #name) ~= name then
        title = name .. " - " .. title
    end

    -- No authors, deliberately. The catalog does not store them, and both
    -- supported servers stamp placeholders ("Unknown", "Unknown Author") often
    -- enough that a guessed author would be worse than an empty field.
    return { title = title }
end

-- Book cover, returned as a BlitBuffer exactly like any other KOReader
-- Document. This is the seam FileManager ("Book info"/mosaic), coverimage-like
-- plugins and coverbrowser all go through, so exposing it here makes a
-- streamed book show its OPDS-provided cover wherever covers normally appear.
--
-- The cover is the series' artwork, looked up in the catalog: it is fetched
-- once over HTTP and cached on disk next to the page cache, never through the
-- page pipeline, so building a cover downloads no streamed page. A series with
-- no cover recorded falls back to the first streamed page, mirroring how a CBZ
-- treats its first image as the cover — and so does a
-- marker whose stored cover link can no longer be fetched, so a book is never
-- left cover-less over a stale/moved cover URL.
-- The size a cover is rendered at: fitted to the screen, and never upscaled —
-- a small source stays small rather than being blown up to fill it.
--
-- Shared by both cover paths, because both used to render the page whole and
-- then downscale the result with a second buffer. Asking the renderer for the
-- final size instead means no oversized intermediate exists at all, and so
-- nothing to free.
local function coverSize(w, h)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    if w <= sw and h <= sh then
        return w, h
    end
    local s = math.min(sw / w, sh / h)
    return math.max(1, math.floor(w * s + 0.5)), math.max(1, math.floor(h * s + 0.5))
end

-- Cover of a local cbz = the archive's first page, like any CBZ.
function MeguruDocument:_localCoverPageImage()
    local w, h = Image.pageSizeOfDoc(self.mupdf_doc, 1)
    if not (w and h) then
        logger.warn("Meguru: could not measure local cbz cover")
        return nil
    end
    local tw, th = coverSize(w, h)
    return Image.renderRegionFromDoc(self.mupdf_doc, 1, 0, 0, w, h, tw, th)
end

function MeguruDocument:getCoverPageImage()
    if self.local_cbz then
        return self:_localCoverPageImage()
    end
    -- Both cover links come from the catalog, not the marker: a cover belongs
    -- to a book and to a series, and the catalog is where each of those lives,
    -- so neither is copied into every marker. Without a catalog the fallback
    -- below — page 1 of the stream, which on OPDS-PSE servers is usually the
    -- cover — still applies.
    --
    -- The book's own artwork wins. Most feeds publish only a series image, so
    -- for them this changes nothing; Kavita publishes one per volume, and
    -- preferring the series there is what made every book of a series render
    -- with the same picture.
    local item, series = self:_catalog()
    local cover_url
    for _, candidate in ipairs{ item and item.cover_url, series and series.cover_url } do
        if type(candidate) == "string" and candidate ~= "" then
            cover_url = candidate
            break
        end
    end

    local data
    if cover_url then
        local path = Cache.coverPath(self:cacheKey(), cover_url)
        data = Cache.read(path)
        if not data then
            local user, pass = self:streamCredentials()
            local ok, bytes, code = pcall(PSE.fetchPage, cover_url,
                { username = user, password = pass })
            if ok and bytes then
                data = bytes
                Cache.write(path, bytes)
            else
                -- The stored cover link could not be fetched (moved/changed on
                -- the server, a transient auth/network hiccup, a server that
                -- only answers its own page URLs). Do not leave the book
                -- cover-less: fall through to the first streamed page below —
                -- the same fallback a marker *without* a stored cover link
                -- already takes, and the very path that makes the "next
                -- volume" markers show a cover. The failed link is not cached,
                -- so a later call retries it before falling back again.
                if ok then
                    logger.warn("Meguru: failed to fetch cover (HTTP "
                        .. tostring(code) .. "), falling back to page 1")
                else
                    logger.warn("Meguru: failed to fetch cover ("
                        .. tostring(bytes) .. "), falling back to page 1")
                end
            end
        end
    end
    if not data then
        -- No stored cover link (marker written before covers were captured) or
        -- the stored one failed to fetch above: page 1 of the stream, which on
        -- OPDS-PSE servers is usually the cover.
        --
        -- Reached through this book's own key, unlike the version of this that
        -- keyed on the marker's basename: there it read whatever page 1 the
        -- book with the same title had cached, so a series whose chapters are
        -- all called "Chapter 1" gave every volume one shared cover.
        data = self:readPageFromDisk(1)
        if not data then
            data = self:fetchPageToDisk(1)
        end
    end
    if not data then
        return nil
    end

    -- The cover is rendered straight to the size the screen can use, so a
    -- server handing out a full-resolution image as its "cover" never produces
    -- a full-resolution buffer here — the renderer scales as it decodes, and
    -- there is no intermediate to free.
    local w, h = Image.pageSizeOfBytes(data)
    if not (w and h) then
        logger.warn("Meguru: could not read cover image")
        return nil
    end
    local tw, th = coverSize(w, h)
    return Image.renderRegion(data, 0, 0, w, h, tw, th)
end

function MeguruDocument:getToc()
    return {}
end

function MeguruDocument:getPageText()
    return nil
end

function MeguruDocument:getNativePageDimensions(pageno)
    local dims = self:getPageDims(pageno)
    return Geom:new{ w = dims.w, h = dims.h }
end

-- Used-BBox is the *full* page. Cropping is never baked into geometry: the
-- page size stays the full native page and any crop lives only in the
-- bounding box getPageBBox returns (below) — the base
-- Document:getUsedBBoxDimensions goes through getPageBBox, so returning the
-- whole page here is simply the "nothing cropped" fallback (e.g. when
-- "Page Crop" is "none", trim_page == 3).
function MeguruDocument:getUsedBBox(pageno)
    local dims = self:getPageDims(pageno)
    return { x0 = 0, y0 = 0, x1 = dims.w, y1 = dims.h }
end

-- The bounding box ReaderZooming/ReaderView crop through ("used bbox"
-- mechanism): the auto content box when the bottom-menu "Page Crop" choice is
-- "auto" (configurable.trim_page == 1), else the whole page. This is what
-- makes a KOpt-style crop work while the page size (getPageDims) stays the
-- full native page. The base getUsedBBoxDimensions mutates the table it is
-- handed, so a *fresh* table is returned on every call.
--
-- This is also the hook the pagenumbercrop plugin wraps — its own init
-- replaces document.getPageBBox on the instance — to apply its page-number
-- strip crop, its "no crop on blank pages", and (through its own option
-- events) its whole-screen wide-page rotation. When that plugin is present it
-- stamps `document._pagenum_cache = {}` *before* swapping the method, so every
-- time this body then runs — as the pagenumbercrop wrapper's captured `orig` —
-- `self._pagenum_cache ~= nil` is already true and we yield ONLY the plain
-- margin/full box below (`_basePageBBox`): pagenumbercrop drives the finer
-- crops and double-cropping is impossible.
--
-- When pagenumbercrop is NOT installed, the finer crops are built in here
-- (see the "Page-number / blank-page analysis" section below), mirroring that
-- plugin exactly: with "Page Crop" at "auto" and "Page Number Crop" on
-- (page_number_crop_auto), a detected printed page-number band trims the
-- bbox's bottom edge; with "No crop on blank pages" on (no_crop_blank_pages),
-- a page whose content area is below the mostly-blank threshold is left as the
-- *full* native page (the margin crop is discarded too). Both are two
-- independent toggles over one combined "active" state, exactly as
-- pagenumbercrop treats them.
function MeguruDocument:getPageBBox(pageno)
    -- pagenumbercrop owns this seam: it replaced getPageBBox and stamped
    -- doc._pagenum_cache before doing so, so this body runs as its `orig`
    -- only to yield the base box. Never run the built-in crop/blank below
    -- while it is driving.
    if self._pagenum_cache ~= nil then
        return self:_basePageBBox(pageno)
    end
    if self._meguru_pagenum_analysis_flag then
        -- An analysis render is in flight. The flag guards the (theoretical)
        -- re-entry of one — none of this document's render paths call back into
        -- getPageBBox — and it is tested *before* the box is derived, not after:
        -- the margin scan is a whole page rendered at 1:1, so letting it run
        -- here would nest one full-page render inside another. The uncropped
        -- page is the right answer anyway, since an analysis knows what it is
        -- looking for and does not want a crop under it.
        local dims = self:getPageDims(pageno)
        return { x0 = 0, y0 = 0, x1 = dims.w, y1 = dims.h }
    end
    local bbox = self:_basePageBBox(pageno)
    if not bbox then
        return bbox
    end
    local c = self.configurable
    if not c then
        return bbox
    end
    local auto_crop = c.text_wrap ~= 1 and c.trim_page == 1
    local crop_active = auto_crop
        and (c.page_number_crop_auto == 1 or c.page_number_crop_auto == "1")
    local blank_active = auto_crop
        and (c.no_crop_blank_pages == 1 or c.no_crop_blank_pages == "1")
    if not (crop_active or blank_active) then
        return bbox
    end
    -- Blank pages are left ENTIRELY uncropped (the margin crop discarded too),
    -- like pagenumbercrop: a chapter divider / title page must not zoom into a
    -- small element.
    if blank_active and self:_meguruPageMostlyBlank(pageno) then
        local page_size = self:getNativePageDimensions(pageno)
        return { x0 = 0, y0 = 0, x1 = page_size.w, y1 = page_size.h }
    end
    if crop_active then
        local crop_y = self:_meguruPagenumStrip(pageno)
        if crop_y and crop_y > bbox.y0 and crop_y < bbox.y1 then
            local page_size = self:getNativePageDimensions(pageno)
            local min_removal = page_size and math.max(1, page_size.h * 0.001) or 1
            if bbox.y1 - crop_y >= min_removal then
                local out = { x0 = bbox.x0, y0 = bbox.y0, x1 = bbox.x1, y1 = bbox.y1 }
                out.y1 = crop_y
                return out
            end
        end
    end
    return bbox
end

-- The plain margin/full-page box, shared by getPageBBox above and by
-- pagenumbercrop's wrapper when it calls this body as its `orig`. Returns a
-- fresh table on every call (the base getUsedBBoxDimensions mutates the table
-- it is handed).
function MeguruDocument:_basePageBBox(pageno)
    local configurable = self.configurable
    if configurable and configurable.trim_page == 1 then
        local crop = self:autoContentBox(pageno)
        if crop then
            return { x0 = crop.x0, y0 = crop.y0, x1 = crop.x1, y1 = crop.y1 }
        end
    end
    local dims = self:getPageDims(pageno)
    return { x0 = 0, y0 = 0, x1 = dims.w, y1 = dims.h }
end

-- The buffer a whole-page content heuristic scans, and the page rectangle it is
-- a picture of.
--
-- Returns `bb, full_w, full_h`: the whole page rendered down to
-- PANEL_SCAN_TARGET on its long edge, and the page size that buffer is a
-- downscale of. `bb` is never the page itself, and the caller maps its findings
-- back through `full_w`/`full_h` rather than through the buffer's own
-- dimensions (`getPanelFromPage` at its `full_w/sw`), so any scan resolution
-- works.
--
-- Cached in self.scans: the panel detector runs on a long-press, possibly
-- several times per page, and the scan it needs is small — a second render of
-- the same page to answer the same question would be pure waste. This is *not*
-- the auto-crop's buffer: that one has to be 1:1 and is transient, see
-- autoContentBox.
function MeguruDocument:panelScanBuffer(pageno)
    local dims = self:getPageDims(pageno)
    if not (dims and dims.w > 0 and dims.h > 0) then
        return nil
    end
    local item = self.scans[pageno]
    if item and item.bb_free ~= true then
        bump(self, pageno)
        return item.bb, dims.w, dims.h
    end
    self.scans[pageno] = nil
    local z = math.min(PANEL_SCAN_TARGET / dims.w, PANEL_SCAN_TARGET / dims.h, 1)
    local sw = math.max(1, math.floor(dims.w * z + 0.5))
    local sh = math.max(1, math.floor(dims.h * z + 0.5))
    local bb = self:pageRegion(pageno, 0, 0, dims.w, dims.h, sw, sh)
    if not bb then
        return nil
    end
    self.scans[pageno] = { bb = bb, bb_free = false }
    bump(self, pageno)
    evictOldest(self, self.scans, self.max_cached_scans)
    return bb, dims.w, dims.h
end

-- Compute and cache the auto content box of `pageno` (see computeContentBox).
--
-- The page is rendered at 1:1 for the scan and the buffer is freed as soon as
-- the box is read off it: what is kept is the box, in `self.crops`, for the
-- page's lifetime. Holding the bitmap instead would mean holding a full page at
-- native resolution for every open book, which is the buffer this document
-- deliberately no longer has — so the render is transient even though it is
-- dearer that way.
--
-- Three ways out, and they are different answers that must not be confused:
--
--   * too large to scan at 1:1 → the crop is off, and that is remembered;
--   * the render failed, or the page never measured → off too, and remembered,
--     because a 1:1 render is far too expensive to retry on every page turn in
--     the hope that this one comes out differently;
--   * the scan ran and found nothing to trim → nil, cached as `false`, which is
--     the same "nothing trimmed" mark a full-bleed page gets.
--
-- A `false` here is decided once and holds for the rest of the session: nothing
-- invalidates self.crops — not even "Clear cache", which empties the *disk*
-- cache and leaves this table alone. Reopening the book is what retries it. That
-- is a deliberate trade against re-rendering a whole page at native resolution
-- on every getPageBBox, but it does mean a page that failed once for a passing
-- reason stays uncropped until the book is closed.
--
-- Either way the page is shown whole, which is the answer stock itself gives
-- whenever it cannot trust its detection.
function MeguruDocument:autoContentBox(pageno)
    local cached = self.crops[pageno]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end
    -- Only a page that was really measured can be cropped. `self.dims[pageno]`
    -- holds that fact: it is written when the page's own size is known, and left
    -- alone when the fetch failed and getPageDims handed back the screen size
    -- for that one call. Scanning that fallback would produce a box in the
    -- wrong space entirely, which is worse than not cropping.
    local dims = self:getPageDims(pageno)
    if not self.dims[pageno] then
        cropSkipWarn(pageno, "page size unknown (the fetch failed) — kept as-is")
        return nil
    end
    if self.dead_pages[pageno] or not (dims and dims.w > 0 and dims.h > 0) then
        return nil
    end
    if dims.w * dims.h > AUTOCROP_MAX_SCAN_PIXELS then
        cropSkipWarn(pageno, "page too large to scan at 1:1 (", dims.w, "x", dims.h,
            ") — kept as-is")
        self.crops[pageno] = false
        return nil
    end
    local bb = self:pageRegion(pageno, 0, 0, dims.w, dims.h, dims.w, dims.h)
    if not bb then
        cropSkipWarn(pageno, "could not render the page at 1:1 for the margin scan",
            "— kept as-is")
        self.crops[pageno] = false
        return nil
    end
    local box = computeContentBox(bb, pageno)
    -- Malloc'd outside the Lua heap, like every BlitBuffer here: nothing will
    -- reclaim it, and the scan read everything it had to say.
    bb:free()
    self.crops[pageno] = box or false
    return box
end

-- ---------------------------------------------------------------------------
-- Page-number / blank-page analysis (standalone, no pagenumbercrop needed)
-- ---------------------------------------------------------------------------
--
-- The two finer crops the pagenumbercrop plugin would apply by wrapping
-- getPageBBox — cropping a detected printed page-number band off the bottom,
-- and leaving mostly-blank pages entirely uncropped — are reimplemented here
-- as a faithful port of that plugin's analysis (its main.lua), renamed
-- `_meguru*`. They are only ever consulted from getPageBBox, and only when the
-- standalone gate there holds: "Page Crop" at auto + the row's toggle on, and
-- `self._pagenum_cache == nil` (the real plugin absent — when it is present it
-- owns `getPageBBox` and this body runs as its `orig`, so none of the code
-- below executes).
--
-- All state is per-page memo tables (`_meguru_pagenum_cache` etc.), created
-- lazily on first use so a book with the features off allocates nothing. The
-- analysis renders the *raw native* page in native coordinates and never
-- depends on trim_page or the margin box, so — exactly like pagenumbercrop —
-- there is no cross-toggle invalidation: toggling a row only flips the
-- `active` flag in getPageBBox and a warm per-page memo is reused. Meguru
-- field names (`_meguru_*`) never collide with pagenumbercrop's `_pagenum_*`
-- (and never tripping its coexistence probe: writing `_pagenum_cache` itself
-- would disable the standalone gate).
--
-- Cost: the strip and the blank check are region renders of the page
-- (decodeRegion), so a page turn adds two small ones — no extra network fetch,
-- matching what pagenumbercrop does to this document through the base
-- Document.renderPage shim. On a page the cap had to reduce they come from the
-- source like every other tile, so the analysis sees the sharp page rather
-- than the retained reduction; on every other page they cut and scale from the
-- cached whole-page render, exactly as they always did.

local MEGURU_BLANK_RENDER_MAX_PX = 256
local MEGURU_BLANK_MAX_CONTENT_AREA = 0.10

-- Analyze a bottom-strip render for a page-number band. Ported verbatim from
-- pagenumbercrop's PageNumberCrop.analyzeStrip. `bb` is the downscaled strip;
-- `y_start_override` (0 here) pins the scan to the strip's own bottom. Returns
-- (crop_y, detail[, suspicious]): crop_y is the band's top in *strip-image*
-- pixels (0 = no page number), detail a human log, and the third value flags
-- "only noise bands" so the caller retries at fallback zoom. Heuristics: the
-- band must be short and narrow-ish, sit above a clean gutter, leave content
-- above it, and never touch the page edges like real artwork would.
local function meguruAnalyzeStrip(bb, y_start_override)
    local w, h = bb:getWidth(), bb:getHeight()
    if not w or not h or w < 20 or h < 40 then
        return 0, "tiny page"
    end

    local y_start = y_start_override
        or math.max(0, math.floor(h * (1 - 0.15)))

    local ink_threshold = 0.002
    local dark_threshold = 128
    local x_step = 2

    local function isDark(color)
        return color:getColor8().a < dark_threshold
    end

    local ink = {}
    local span = {}
    local cols = math.ceil(w / x_step)
    local function scanRow(y)
        local count = 0
        local xmin, xmax = w, -1
        for x = 0, w - 1, x_step do
            if isDark(bb:getPixel(x, y)) then
                count = count + 1
                if x < xmin then xmin = x end
                if x > xmax then xmax = x end
            end
        end
        ink[y] = count / cols
        span[y] = (xmax >= xmin) and (xmax - xmin + 1) or 0
    end
    local function inkAt(y)
        if ink[y] == nil then
            scanRow(y)
        end
        return ink[y]
    end

    local max_row_ink = 0.30
    local max_band_span = w * 0.60
    local max_band_h = math.max(2, h * 0.04)
    local max_big_band_h = math.max(3, h * 0.15)
    local min_gutter_h = math.max(1, math.floor(h * 0.01))
    local min_band_span = math.max(3, math.floor(w * 0.005))

    -- Skip the empty run at the very bottom of the page.
    local y = h - 1
    while y >= y_start and inkAt(y) <= ink_threshold do
        y = y - 1
    end
    if y < y_start then
        return 0, "no ink at the bottom"
    end

    -- Walk ink bands from the bottom up.
    local bands = {}
    local descr = {}
    while y >= y_start do
        local bottom = y
        local top = y
        local b_ink, b_span = 0, 0
        local panel_like = false
        while y >= y_start and inkAt(y) > ink_threshold do
            top = y
            if ink[y] > b_ink then b_ink = ink[y] end
            if span[y] > b_span then b_span = span[y] end
            if not panel_like and (b_ink > max_row_ink or b_span > max_band_span) then
                -- Artwork reaches the bottom: this is not a page-number band.
                panel_like = true
                y = y - 1
                break
            end
            y = y - 1
        end

        local h_str = tostring(bottom - top + 1)
        if panel_like then h_str = ">=" .. h_str end
        table.insert(descr, string.format("h=%s ink=%.2f span=%d%%%s",
            h_str, b_ink, math.floor(b_span / w * 100), panel_like and " PANEL" or ""))

        if b_span >= min_band_span then
            if panel_like then
                local detail = "bands(" .. #descr .. ") " .. table.concat(descr, ", ")
                if #bands == 0 then
                    return 0, "panel reaches the bottom [" .. detail .. "]"
                end
                local log_detail = string.format("crop_y=%d %s", bottom, detail)
                return bottom, log_detail
            end
            table.insert(bands, { top = top, bottom = bottom, row_ink = b_ink, span = b_span })
        end

        while y >= y_start and inkAt(y) <= ink_threshold do
            y = y - 1
        end
    end

    local detail = "bands(" .. #descr .. ") " .. table.concat(descr, ", ")
    if #bands == 0 then
        return 0, "only noise bands [" .. detail .. "]", true
    end
    local first = bands[1]

    -- Merge a small stack of thin bands (one page number often renders as a
    -- few adjacent digit bands separated by sub-gutter whitespace).
    local stack_top = first.top
    local prev_top = first.top
    for i = 2, #bands do
        local gap = prev_top - bands[i].bottom - 1
        if gap <= math.max(min_gutter_h, h * 0.02) then
            stack_top = bands[i].top
            prev_top = bands[i].top
        else
            break
        end
    end
    local band_h = first.bottom - stack_top + 1

    -- The clean white gutter right above the stack separates the number from
    -- the page content; the crop cut lands at its top.
    local gutter_len = 0
    local yy = stack_top - 1
    while yy >= y_start and ink[yy] <= ink_threshold do
        gutter_len = gutter_len + 1
        yy = yy - 1
    end

    local fallback_detail = string.format("band_h=%d row_ink=%.2f span=%d%% gutter=%dpx",
        band_h, first.row_ink, math.floor(first.span / w * 100), gutter_len)

    local glued = gutter_len < min_gutter_h
    if band_h > max_band_h and (glued or band_h > max_big_band_h) then
        return 0, "band too tall (" .. band_h .. " px) [" .. fallback_detail .. "]"
    end

    local has_content = false
    for ry = y_start, math.max(y_start, yy) do
        if ink[ry] > ink_threshold then
            has_content = true
            break
        end
    end
    if not has_content then
        return 0, "no content above the band [" .. fallback_detail .. "]"
    end

    local crop_y = stack_top - gutter_len
    local log_detail = string.format("crop_y=%d %s", crop_y, fallback_detail)
    return crop_y, log_detail
end

-- Mostly-blank check on a full-page downscale: true when the dark content
-- spans less than ~10% of the page area (a chapter divider, a title page).
-- Ported verbatim from pagenumbercrop's PageNumberCrop.pageMostlyBlank.
local function meguruPageMostlyBlank(bb)
    local w, h = bb:getWidth(), bb:getHeight()
    if not w or not h or w < 20 or h < 20 then
        return false
    end

    local dark_threshold = 128
    local x_step, y_step = 2, 2
    local total_area = w * h
    local max_blank_area = MEGURU_BLANK_MAX_CONTENT_AREA * total_area

    local found = false
    local xmin, ymin, xmax, ymax = w, h, -1, -1
    for y = 0, h - 1, y_step do
        for x = 0, w - 1, x_step do
            if bb:getPixel(x, y):getColor8().a < dark_threshold then
                found = true
                if x < xmin then xmin = x end
                if x > xmax then xmax = x end
                if y < ymin then ymin = y end
                if y > ymax then ymax = y end
                -- Early exit: content already spans >= 10% of the page.
                if (xmax - xmin + 1) * (ymax - ymin + 1) >= max_blank_area then
                    return false
                end
            end
        end
    end
    if not found then
        return true
    end
    local content_area = (xmax - xmin + 1) * (ymax - ymin + 1) / total_area
    return content_area < MEGURU_BLANK_MAX_CONTENT_AREA
end

-- Ensure the per-page analysis memos exist on `self`.
local function meguruPagenumCaches(self)
    if self._meguru_pagenum_cache == nil then
        self._meguru_pagenum_cache = {}
        self._meguru_pagenum_blank_cache = {}
        self._meguru_pagenum_history = {}
    end
end

-- Render a native-coordinate analysis rectangle, downscaled by `zoom`, and
-- return the bare BlitBuffer (or nil). Unlike renderPage this never enters the
-- tile LRU — the caller analyzes and frees the buffer right away, so a ~700px
-- strip or a ~256px blank preview never lingers as a large cached tile. The
-- region is cut+scaled from the LRU-cached native decode (no extra
-- fetch/decode for a page whose geometry is already known). The analysis flag
-- is set across the render (defensive: this document's render paths never call
-- back into getPageBBox).
function MeguruDocument:_meguruAnalysisBB(pageno, x, y, w, h, zoom)
    self._meguru_pagenum_analysis_flag = true
    local ok, bb = pcall(function()
        if self.dead_pages[pageno] then
            return nil -- a doomed page is never decoded again
        end
        local dims = self:getPageDims(pageno)
        if not (dims and dims.w > 0 and dims.h > 0) then
            return nil
        end
        local tw = math.max(1, math.floor(w * zoom + 0.5))
        local th = math.max(1, math.floor(h * zoom + 0.5))
        return self:decodeRegion(pageno, x, y, w, h, tw, th)
    end)
    self._meguru_pagenum_analysis_flag = false
    if ok and bb then
        return bb
    end
    return nil
end

-- Bottom 15% strip: how far up the page a printed page-number band sits.
-- Returns (crop_y, detail) in *native* page coordinates: the native y of the
-- band's top, or 0 when no page-number-like band is found. Ported from
-- pagenumbercrop's `_pagenum_strip`, minus its manual force-crop and prewarm.
function MeguruDocument:_meguruPagenumStrip(pageno)
    meguruPagenumCaches(self)
    local cached = self._meguru_pagenum_cache[pageno]
    if cached ~= nil then
        return cached
    end
    self._meguru_pagenum_cache[pageno] = 0 -- "busy / none yet" mark
    local page_size = self:getNativePageDimensions(pageno)
    if not (page_size and page_size.w > 0 and page_size.h > 0) then
        logger.info("Meguru: page", pageno, "no page number [no render: page size]")
        return 0
    end

    local strip_h_nat = math.max(1, math.floor(page_size.h * 0.15))
    local strip_y0_nat = page_size.h - strip_h_nat

    local function renderAndAnalyze(zoom)
        local bb = self:_meguruAnalysisBB(pageno, 0, strip_y0_nat,
            page_size.w, strip_h_nat, zoom)
        if not bb then
            return 0, "render returned no tile", false
        end
        local ok, rel_y, rel_detail, rel_suspicious = pcall(meguruAnalyzeStrip, bb, 0)
        bb:free()
        if not ok or type(rel_y) ~= "number" then
            return 0, "analysis error", false
        end
        if rel_y > 0 then
            -- meguruAnalyzeStrip reports the band top in strip-image pixels;
            -- map back to native page y.
            rel_y = strip_y0_nat + rel_y / zoom
        end
        return rel_y, rel_detail or "", rel_suspicious or false
    end

    local zoom_fast = math.min(700 / strip_h_nat, 2.0)
    local crop_y, detail, suspicious = renderAndAnalyze(zoom_fast)
    local used_fallback = false

    if crop_y == 0 and suspicious then
        -- The fast render found only noise bands: retry at higher zoom before
        -- giving up (a page number that small is below the fast resolution).
        local zoom_fallback = math.min(1000 / strip_h_nat, 2.5)
        local crop_y2, detail2 = renderAndAnalyze(zoom_fallback)
        used_fallback = true
        if crop_y2 > 0 then
            crop_y, detail = crop_y2, detail2 .. " [fallback zoom]"
        else
            detail = detail .. " | fallback zoom: " .. detail2
        end
    end

    if crop_y > 0 then
        -- Cross-page sanity filter: a band whose height is an outlier against
        -- the rolling history of page-number heights is re-checked at fallback
        -- zoom, and dropped when it still does not fit (it is probably part of
        -- the artwork, not a page number).
        local history = self._meguru_pagenum_history
        local frac = crop_y / page_size.h
        if #history >= 3 then
            local sorted = {}
            for _, f in ipairs(history) do
                sorted[#sorted + 1] = f
            end
            table.sort(sorted)
            local median = sorted[math.ceil(#sorted / 2)]
            local tolerance = 0.03
            if math.abs(frac - median) > tolerance then
                if not used_fallback then
                    local zoom_fallback = math.min(1000 / strip_h_nat, 2.5)
                    local crop_y2, detail2 = renderAndAnalyze(zoom_fallback)
                    local frac2 = crop_y2 > 0 and (crop_y2 / page_size.h) or nil
                    if frac2 and math.abs(frac2 - median) <= tolerance then
                        crop_y, detail, frac = crop_y2,
                            detail2 .. " [fallback zoom, matched history]", frac2
                    else
                        crop_y = 0
                    end
                else
                    crop_y = 0
                end
            end
        end
        if crop_y > 0 then
            table.insert(history, frac)
            if #history > 30 then
                table.remove(history, 1)
            end
        end
    end

    if crop_y > 0 then
        logger.info("Meguru: page", pageno, "page-number crop y =",
            string.format("%.1f", crop_y))
    else
        logger.info("Meguru: page", pageno, "no page number [", detail, "]")
    end
    self._meguru_pagenum_cache[pageno] = crop_y
    return crop_y
end

-- Mostly-blank check (content below ~10% of the page area): such a page — a
-- chapter divider, a title page — is left entirely uncropped by getPageBBox.
-- Renders the whole native page downscaled to at most MEGURU_BLANK_RENDER_MAX_PX.
-- Result memoised per page.
function MeguruDocument:_meguruPageMostlyBlank(pageno)
    meguruPagenumCaches(self)
    local cached = self._meguru_pagenum_blank_cache[pageno]
    if cached ~= nil then
        return cached
    end
    self._meguru_pagenum_blank_cache[pageno] = false
    local page_size = self:getNativePageDimensions(pageno)
    if not (page_size and page_size.w > 0 and page_size.h > 0) then
        logger.info("Meguru: page", pageno, "blank check skipped [no render: page size]")
        return false
    end
    local zoom = math.min(
        MEGURU_BLANK_RENDER_MAX_PX / page_size.w,
        MEGURU_BLANK_RENDER_MAX_PX / page_size.h,
        1.0)
    local bb = self:_meguruAnalysisBB(pageno, 0, 0, page_size.w, page_size.h, zoom)
    if not bb then
        return false
    end
    local ok, mostly_blank = pcall(meguruPageMostlyBlank, bb)
    bb:free()
    if ok and type(mostly_blank) == "boolean" then
        self._meguru_pagenum_blank_cache[pageno] = mostly_blank
        if mostly_blank then
            logger.info("Meguru: page", pageno, "mostly blank -> no crop")
        end
        return mostly_blank
    end
    return false
end

-- Panel under a touch point, for KOReader's manga/comic "panel zoom" (see the
-- comment block above getPanelFromPage's helpers). Coordinates are in *full
-- native* page space: pos.x/pos.y come from ReaderView already in that space
-- (a margin crop only zooms through the bbox, it never shifts the tap), and
-- the returned {x,y,w,h} is a native rect, exactly what drawPagePart expects.
-- Returns nil when no grid is found (single-panel page, dark paper, decode
-- failure), which lets ReaderHighlight fall through gracefully instead of
-- crashing.
function MeguruDocument:getPanelFromPage(pageno, pos)
    if not pos then
        return nil
    end
    local px, py = tonumber(pos.x), tonumber(pos.y)
    if not px or not py then
        return nil
    end
    local dims = self:getPageDims(pageno)
    if px < 0 or py < 0 or px >= dims.w or py >= dims.h then
        return nil
    end
    -- The gutter scan reads the shared downscale (panelScanBuffer), so no
    -- second copy is made here and nothing is freed: the buffer belongs to
    -- that cache.
    -- The content rectangle is the whole page — edge margins only add white at
    -- the frame, which the interior-gutter filter (keepInteriorBands) already
    -- discards, and gutters that separate panels span the full content width
    -- regardless of any margin crop.
    local scan_bb, full_w, full_h = self:panelScanBuffer(pageno)
    if not scan_bb then
        return nil
    end
    if not full_w or not full_h or full_w < 1 or full_h < 1 then
        return nil
    end
    local ok_raster, raster = pcall(makeRaster, scan_bb)
    if not ok_raster or not raster then
        return nil
    end
    local sw, sh = scan_bb:getWidth(), scan_bb:getHeight()
    local sx0, sy0 = 0, 0
    local sx1, sy1 = sw, sh
    local tap_x = clamp(math.floor(px * sw / full_w), sx0, sx1 - 1)
    local tap_y = clamp(math.floor(py * sh / full_h), sy0, sy1 - 1)
    local cell = findPanelBounds(raster, { x0 = sx0, y0 = sy0, x1 = sx1, y1 = sy1 },
        tap_x, tap_y)
    if not cell then
        return nil
    end
    -- The cell is in scan pixels; the reader wants page pixels.
    local cx0 = math.max(0, math.floor(cell.x0 * full_w / sw))
    local cy0 = math.max(0, math.floor(cell.y0 * full_h / sh))
    local cx1 = math.min(full_w, math.ceil(cell.x1 * full_w / sw))
    local cy1 = math.min(full_h, math.ceil(cell.y1 * full_h / sh))
    local cw, ch = cx1 - cx0, cy1 - cy0
    if cw < 1 or ch < 1 then
        return nil
    end
    if cw * ch < PANEL_MIN_CELL_FRAC * full_w * full_h then
        return nil
    end
    return { x = cx0, y = cy0, w = cw, h = ch }
end

function MeguruDocument:getPageDims(pageno)
    local cached = self.dims[pageno]
    if cached then
        return cached
    end
    -- The page size, measured *without* decoding the page: `page:getSize`, which
    -- is what stock's `Document:getNativePageDimensions` does, and the reason a
    -- page turn no longer pays a whole-page decode just to learn how big the
    -- page is.
    --
    -- This is the SOURCE's size, and it is the reader's page geometry: every
    -- crop, every tile and every content scan is expressed in it. Reporting the
    -- size of some *retained* buffer instead is what once turned a manhwa strip
    -- 800x20000 into a page 82x2048, with every tile a ~13x upscale of those 82
    -- columns. Nothing is retained whole any more — see decodeRegion.
    --
    -- Cropping is deliberately NOT baked in: any auto-crop lives in the
    -- bounding box getPageBBox returns, so page turns and zoom recomputes never
    -- re-derive a crop-dependent size (and the bbox, being a pure margin scan,
    -- is stable for a page's lifetime).
    local fallback = { w = Screen:getWidth(), h = Screen:getHeight() }
    local w, h
    if self.local_cbz then
        w, h = Image.pageSizeOfDoc(self.mupdf_doc, pageno)
    else
        local data = self:fetchPageToDisk(pageno)
        if not data then
            -- A missing fetch is transient, so this fallback is returned for
            -- THIS call only and deliberately not stored. Caching it is what
            -- made a page's geometry the screen size for good: the next look
            -- would see a "measured" page and crop, scan and render against
            -- 1072x1448 instead of the page — and since the box is then handed
            -- to the reader in page coordinates, the crop came out displaced
            -- towards the top-left, cutting the top and the left of the artwork
            -- and leaving the right and bottom margins untouched.
            --
            -- Not cached also means the callers can tell the two apart: an
            -- entry in self.dims is a page that was really measured, and its
            -- absence is a page whose size is not known yet.
            return fallback
        end
        w, h = Image.pageSizeOfBytes(data)
        -- Drop the bytes before the collect below: on a big scan this is a
        -- multi-MB Lua allocation and, still referenced by this local, a
        -- collect right now would not reclaim it.
        data = nil
    end
    if not (w and h) then
        -- Unlike the fetch failure above, this one IS stored — the page is not
        -- coming back, `dead_pages` says so, and every consumer refuses a dead
        -- page before it can read this size. Storing it only stops the measure
        -- being retried on every call.
        logger.warn("Meguru: cannot measure page", pageno)
        self.dead_pages[pageno] = true
        self.dims[pageno] = fallback
        return fallback
    end
    local dims = { w = math.max(1, w), h = math.max(1, h) }
    self.dims[pageno] = dims
    -- Force a GC here so the Lua-side garbage is reclaimed before the next page
    -- is fetched, instead of piling up until the device runs out of RAM a few
    -- pages in (the built-in page-stream viewer survives exactly because it
    -- holds only one page's worth). BlitBuffers are freed explicitly; it is the
    -- byte strings this reclaims.
    pcall(collectgarbage, "collect")
    return dims
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

local function round(v)
    return math.floor(v + 0.5)
end

-- (There is no "get the whole page as a buffer" step any more. Every buffer
-- this document holds was asked for by somebody at a size they chose — see
-- decodeRegion for the painted ones, panelScanBuffer for the scanned ones, and
-- autoContentBox for the one buffer that exists only long enough to be read.)

-- Render the rectangle (sx, sy, sw, sh) of page `pageno`, at `tw` x `th`.
--
-- The one place that knows where a page's pixels come from, which is why no
-- caller branches on `local_cbz` any more. The two books really are different —
-- a local page lives in an archive that stays open for the book's life, and
-- whose document must not be closed (the cover renderer shares it); a streamed
-- page's bytes are read back from the disk cache or fetched — but that
-- difference belongs here, once, rather than in every caller.
--
-- The fetch lives here for the same reason: it was copy-pasted into each of
-- them, along with the same `readPageFromDisk or fetchPageToDisk` spelling.
-- Returns a fresh BlitBuffer of exactly tw x th, or nil.
function MeguruDocument:pageRegion(pageno, sx, sy, sw, sh, tw, th)
    if self.local_cbz then
        return Image.renderRegionFromDoc(self.mupdf_doc, pageno, sx, sy, sw, sh, tw, th)
    end
    local bytes = self:readPageFromDisk(pageno) or self:fetchPageToDisk(pageno)
    if not bytes then
        return nil
    end
    return Image.renderRegion(bytes, sx, sy, sw, sh, tw, th)
end

-- Render a page rectangle into a tile.
--
-- `cx, cy, cw, ch` are in page coordinates — the space `getPageDims` reports —
-- already mapped back from zoomed page space by renderPage. `tw`/`th` is the
-- size the caller wants the buffer in and it always gets exactly that size.
-- `data` must be the page's raw bytes for a streamed page; a local cbz has none
-- and renders from its open archive instead.
--
-- There is one path here, and it is stock's: MuPDF paints the requested
-- rectangle into a pixmap of the requested size, decimating an oversized JPEG
-- *while* it decodes. Nothing whole-page is decoded, nothing is retained between
-- tiles, and no page is treated differently from any other — a manhwa strip and
-- a paperback scan are the same call with different rectangles.
--
-- The trade is that a redraw of a crop is a fresh render rather than a slice of
-- a cached buffer, so a page turn costs one render per tile instead of one per
-- page. The tile LRU in renderPage is what covers the repeat case, and stock's
-- answer to the same problem is its DocCache-backed whole-page render — which is
-- precisely the retained buffer this document gave up, in exchange for never
-- having to reduce a page's resolution to bound what it holds.
function MeguruDocument:decodeRegion(pageno, cx, cy, cw, ch, tw, th)
    local dims = self.dims[pageno] or self:getPageDims(pageno)
    if self.dead_pages[pageno] then
        return nil
    end
    -- Clamp to the page: a request that runs off the edge (a rect rounded past
    -- the last row, a pan at the margin) is pulled back rather than refused, so
    -- the tile shows the page's edge rather than a gap.
    local x0 = clamp(round(cx), 0, dims.w)
    local y0 = clamp(round(cy), 0, dims.h)
    local x1 = clamp(round(cx + cw), x0 + 1, dims.w)
    local y1 = clamp(round(cy + ch), y0 + 1, dims.h)
    tw = math.max(1, round(tw))
    th = math.max(1, round(th))
    local bb = self:pageRegion(pageno, x0, y0, x1 - x0, y1 - y0, tw, th)
    if not bb then
        -- Deliberately not memoised as a dead page: a render fails for
        -- transient reasons too (a cut-short fetch, a busy device), and the
        -- next paint should be free to try again.
        logger.warn("Meguru: render failed for page", pageno)
        return nil
    end
    return bb
end

function MeguruDocument:renderPage(pageno, rect, zoom, rotation, gamma, saturation, hinting)
    -- We don't care about gamma/saturation for streamed images (the source is
    -- a ready-made bitmap), but they are accepted for API compatibility.
    -- KOReader's per-page document rotation parameter is never set nowadays
    -- (that code path was removed upstream); landscape-page turns live outside
    -- this document (the pagenumbercrop screen rotation), so a non-zero
    -- rotation is simply ignored here.

    local safe_zoom = (zoom and zoom > 0) and zoom or 1
    local is_prescaled = rect and rect.scaled_rect ~= nil or false

    -- Determine the native crop region, the output tile size, and where in
    -- page (zoomed) coordinates the tile origin sits.
    local nx, ny, nw, nh  -- native region
    local tw, th          -- output tile size
    local excerpt_x, excerpt_y

    if is_prescaled then
        -- drawPagePart: rect is already a native crop, rect.scaled_rect holds
        -- the desired output size.
        local sr = rect.scaled_rect
        nx, ny, nw, nh = rect.x, rect.y, rect.w, rect.h
        tw, th = sr.w, sr.h
        excerpt_x, excerpt_y = 0, 0
    elseif rect then
        -- Standard ReaderView call: rect is the visible area expressed in
        -- *zoomed* page coordinates (it fits within the zoomed page).
        nx = rect.x / safe_zoom
        ny = rect.y / safe_zoom
        nw = rect.w / safe_zoom
        nh = rect.h / safe_zoom
        tw, th = rect.w, rect.h
        excerpt_x, excerpt_y = rect.x, rect.y
    else
        -- No rect (thumbnail/hint-ish call): render the whole page at the
        -- requested zoom.
        local page_size = self:getPageDimensions(pageno, safe_zoom, rotation or 0)
        nx = page_size.x / safe_zoom
        ny = page_size.y / safe_zoom
        nw = page_size.w / safe_zoom
        nh = page_size.h / safe_zoom
        tw, th = page_size.w, page_size.h
        excerpt_x, excerpt_y = 0, 0
    end

    -- Clamp the crop to the actual page dimensions.
    local dims = self.dims[pageno] or self:getPageDims(pageno)
    local cx = clamp(round(nx), 0, dims.w)
    local cy = clamp(round(ny), 0, dims.h)
    local cx2 = clamp(round(nx + nw), cx + 1, dims.w)
    local cy2 = clamp(round(ny + nh), cy + 1, dims.h)
    local cw = cx2 - cx
    local ch = cy2 - cy
    tw = math.max(1, round(tw))
    th = math.max(1, round(th))

    -- Cache key must capture the actual crop (content), not only its size,
    -- otherwise panning/zoom slices of the same dimensions would collide.
    local key = string.format("%d|%dx%d|%d,%d+%dx%d", pageno, tw, th, cx, cy, cw, ch)
    local tile = self.tiles[key]
    if tile and tile.bb_free ~= true then
        bump(self, key)
        return tile
    end
    self.tiles[key] = nil

    local bb = self:decodeRegion(pageno, cx, cy, cw, ch, tw, th)
    if not bb then
        return nil
    end

    tile = {
        bb = bb,
        excerpt = Geom:new{
            x = excerpt_x,
            y = excerpt_y,
            w = tw,
            h = th,
        },
        pageno = pageno,
        doc_path = self.file,
    }
    self:cacheTile(key, tile)
    return tile
end

function MeguruDocument:hintPage(pageno, zoom, rotation, gamma, saturation)
    -- A local cbz is on disk: nothing to prefetch ahead of the page turn (each
    -- page renders on demand from the open archive), and
    -- the on-disk page cache is not used in this mode anyway.
    if self.local_cbz then
        return true
    end
    for i = 1, self.prefetch_count do
        local target = pageno + i
        if target <= self.info.number_of_pages then
            self:prefetchPage(target)
        end
    end
    return true
end

-- drawPage / drawPageInverted: same as Document's, but our renderPage may
-- return nil (network/decode failure), in which case we paint a neutral tile
-- instead of crashing the UI.
--
-- drawPage also honours the "Invert Document" setting
-- (configurable.nightmode_document), mirroring the dispatch KoptInterface:drawPage
-- does for a MuPDF book (koptinterface.lua): KOReader inverts the whole display
-- while night mode is on, so a page drawn normally would *appear* inverted (the
-- artwork's stark negative). Meguru forces the choice ALWAYS on — it is not a
-- bottom-menu row any more (main.lua's onReadSettings sets
-- configurable.nightmode_document = 1 on every open), so whenever night mode is
-- on, the page is drawn with its
-- usual blit and the freshly drawn *target* region is then inverted in place
-- (target:invertRect) — the two inversions cancel and the page keeps its
-- original (light-page) look, like a MuPDF book with "Invert Document" on.
--
-- The inversion is applied to the destination, not through invertblitFrom on the
-- tile, on purpose: our cached tiles are the colour (RGB24) buffers MuPDF's
-- page:draw_new returns, which reach an 8bpp grayscale e-ink screen only through
-- a converting blit (the dithered ditherblitFrom the day-mode path below always
-- uses). KOReader's invertblitFrom cannot blit a BBRGB24 source onto a BB8
-- target ("incompatible bb", blitbuffer.c) — using it here froze the renderer
-- the first time night mode was switched on. Inverting the just-blitted target
-- region instead is format-safe (the target is always BB8, invertRect works
-- in place), costs no extra buffer, is visually identical to inverting the
-- source for a matching format, and leaves the shared cached tile untouched —
-- exactly as KoptInterface relies on. KoptInterface's own drawContextPage
-- inverts the same way (blit, then target:invertRect).
function MeguruDocument:drawPage(target, x, y, rect, pageno, zoom, rotation, gamma, saturation)
    local tile = self:renderPage(pageno, rect, zoom, rotation, gamma, saturation)
    if not tile then
        self:paintMissingPage(target, rect, x, y)
        return
    end
    local dx = rect.x - tile.excerpt.x
    local dy = rect.y - tile.excerpt.y
    local configurable = self.configurable
    local invert = configurable and configurable.nightmode_document == 1 and Screen.night_mode
    -- Dither unconditionally — there is deliberately no `sw_dithering` branch
    -- here (the flag is still set true in init for anything that reads it):
    -- nothing, in this document or in KOReader's own machinery, may switch this
    -- paint back to a plain blit. The colour tile reaches a grayscale screen
    -- only through a converting blit, and ditherblitFrom is what keeps smooth
    -- gradients from banding there. On any screen whose destination is not BB8
    -- the C implementation ignores the dither and does a plain blit
    -- (blitbuffer.c "BB_dither_blit_to"), so an unconditional call is safe
    -- everywhere.
    target:ditherblitFrom(tile.bb, x, y, dx, dy, rect.w, rect.h)
    if invert then
        target:invertRect(x, y, rect.w, rect.h)
    end
end

-- Explicit inverted draw (a caller asking for the page's negative on the target
-- regardless of night mode): same format-safe route as drawPage's invert branch
-- — the normal blit, then the drawn target region is inverted in place.
function MeguruDocument:drawPageInverted(target, x, y, rect, pageno, zoom, rotation, gamma, saturation)
    local tile = self:renderPage(pageno, rect, zoom, rotation, gamma, saturation)
    if not tile then
        self:paintMissingPage(target, rect, x, y)
        return
    end
    local dx = rect.x - tile.excerpt.x
    local dy = rect.y - tile.excerpt.y
    -- Same unconditional dither as drawPage (see its comment): no sw_dithering
    -- branch, so no later writer of the flag can make this a banding plain blit.
    target:ditherblitFrom(tile.bb, x, y, dx, dy, rect.w, rect.h)
    target:invertRect(x, y, rect.w, rect.h)
end

function MeguruDocument:paintMissingPage(target, rect, x, y)
    logger.warn("Meguru: page unavailable, painting placeholder")
    if not rect then
        return
    end
    local w = rect.w or 1
    local h = rect.h or 1
    target:paintRect(x, y, w, h, Blitbuffer.COLOR_LIGHT_GRAY)
end

return MeguruDocument
