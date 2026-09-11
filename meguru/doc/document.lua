--[[--
A virtual, streaming document: the thing KOReader actually opens for a Meguru
book.

In *streamed* mode `self.file` is a marker — a small Lua file holding a stream
template and a page count — and pages are fetched one at a time over HTTP.
Raw bytes live in a small in-memory LRU on this document, decoded buffers in two
more beside it — nothing is written to disk. ReaderUI's page N is template index
N-1, because OPDS-PSE counts pages from zero.

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
local RenderImage = require("ui/renderimage")
local Screen = require("device").screen
local Device = require("device")
-- MuPDF binding (koreader-base ffi/mupdf). Guarded: every KOReader that can
-- run this plugin ships it, but should a build ever lack it we degrade to the
-- RenderImage path instead of failing to load the whole document module.
local Mupdf
do
    local ok, mupdf = pcall(require, "ffi/mupdf")
    if ok and mupdf and mupdf.openDocumentFromText and mupdf.openDocument then
        Mupdf = mupdf
    end
end
local logger = require("logger")
local FS = require("meguru/fs")
local Image = require("meguru/doc/image")
local Marker = require("meguru/marker")
local Naming = require("meguru/naming")
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
-- KOpt-engine document would: the page size stays the *full* (capped) native
-- page and the crop lives only in the document's bounding box. `getPageBBox`
-- (below) returns the trimmed content box when the "Page Crop" ConfigDialog
-- choice is "auto" (configurable.trim_page == 1) and the full page otherwise,
-- and ReaderZooming/ReaderView crop through that box for every "content" fit
-- mode ("content", "contentwidth", "contentheight"), which is what this
-- plugin's Fit menu now maps onto.
--
-- Detection is two-stage. A cheap pass reads raw pixels of a small downscaled
-- copy of the decoded page (Blitbuffer.tostring gives us the raw bytes, the
-- same route TileCacheItem uses to serialize tiles), finds the first/last row &
-- column that differ from the uniform light border, and maps that back onto
-- native coordinates — this also decides which pages to leave alone (blank,
-- dark full-bleed art, a drawn dark frame). The top/bottom are trimmed
-- maximally, flush with the detected content edge; the left/right margins are
-- trimmed just as maximally (see computeContentBox). A second, native-resolution
-- pass (refineAutoCrop) then pins each edge to the *exact* outermost content
-- pixel, so the crop ends flush with the panel/artwork and leaves no white
-- frame — even on a page whose only boundary is a thin printed frame line the
-- downscale would have blurred away.
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

local AUTOCROP_SCAN_TARGET = 128 -- max dimension of the scanned downscale
local AUTOCROP_MIN_BG_LUMA = 170 -- only treat a light border as a margin
local AUTOCROP_LUMA_DELTA = 26   -- how much a pixel may differ from the border
-- Degenerate-crop floor: whatever the options say, never let a scan shrink a
-- page below this fraction of its area (guards against a pathological scan).
local AUTOCROP_MIN_KEEP_FRAC = 0.02


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
-- `page_w`/`page_h` are the PAGE's dimensions, which are not the same thing as
-- `bb`'s: the caller scans a downscale (AUTOCROP_SCAN_TARGET), so the buffer is
-- smaller than the page and the message below has to say which is which. It
-- printed the buffer alone once, and a 6883x4913 spread reported itself as
-- "128 x 91" — which reads as a page that size, i.e. as a bug in the cap.
local function scanContentBounds(bb, pageno, page_w, page_h)
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
    local samples = {}
    for x = 0, w - 1 do
        samples[#samples + 1] = lumaAt(0, x)
        samples[#samples + 1] = lumaAt(h - 1, x)
    end
    for y = 1, h - 2 do
        samples[#samples + 1] = lumaAt(y, 0)
        samples[#samples + 1] = lumaAt(y, w - 1)
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
    -- to count as the start of actual content.
    local row_min = math.max(2, math.floor(w * 0.02))
    local col_min = math.max(2, math.floor(h * 0.02))

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
        -- Both sizes, because both are the answer to a different question: the
        -- page says how much margin there was to find, the scanned size says how
        -- much resolution there was to find it with. A page scanned at 128 px
        -- across is a page whose margins were judged coarsely, and that is not
        -- visible from the page size alone.
        cropSkipWarn(pageno, "detected content spans the whole page",
            "(bg=", math.floor(bg), ", page ", page_w, "x", page_h,
            ", scanned at ", w, "x", h, ") — nothing to trim")
    end
    -- `bg` (the reference border luminance) rides along so the native fine pass
    -- in refineAutoCrop reuses the exact same content predicate as this scan.
    return { left, top, right, bottom, bg = bg }
end

-- Native fine pass; assigned below (after makeRaster), see its definition.
local refineAutoCrop

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
-- is the smallest box that contains the artwork on all four sides. The scan is
-- two-stage: a cheap ~128px projection (scanContentBounds) finds the box and
-- decides blank/dark/full-bleed pages, then a native-resolution fine pass
-- (refineAutoCrop) pins each edge to the exact outermost content pixel, so a
-- page comes out of the crop flush with its artwork — no white frame left.
--
-- The result feeds getPageBBox (the bbox ReaderZooming/ReaderView crop
-- through), cached per page in self.crops. It is never baked into the page
-- size: getPageDims reports the full native page.
local function computeContentBox(native_bb, full_w, full_h, pageno)
    -- Returns { x0,y0,x1,y1 } in native pixels, or nil. The only C-side
    -- (BlitBuffer) allocation made here is the ~128px scan copy `scan_bb`;
    -- BlitBuffers are malloc'd outside the Lua heap and are NOT reclaimed by
    -- Lua GC, so an exception between an allocation and its free would leak
    -- the buffer permanently. That is why the allocation, the (pcall-guarded)
    -- pixel work and the free are kept as separate steps, with the free done
    -- unconditionally right after the work.
    local ok, box = pcall(function()
        local bw = native_bb:getWidth()
        local bh = native_bb:getHeight()
        if not bw or not bh or bw < 1 or bh < 1 then
            return nil
        end
        -- Downscale before scanning: ~128px across the long edge is plenty to
        -- find a border, and keeps the Lua pixel loop tiny.
        local sw, sh = bw, bh
        local scan_bb = native_bb
        if bw > AUTOCROP_SCAN_TARGET or bh > AUTOCROP_SCAN_TARGET then
            local scale = AUTOCROP_SCAN_TARGET / math.max(bw, bh)
            sw = math.max(1, math.floor(bw * scale + 0.5))
            sh = math.max(1, math.floor(bh * scale + 0.5))
            local ok_scale, scaled = pcall(RenderImage.scaleBlitBuffer,
                RenderImage, native_bb, sw, sh, false)
            if ok_scale and scaled and scaled ~= native_bb then
                scan_bb = scaled
            else
                return nil -- could not make the scan copy: leave the page as-is
            end
        end
        -- Scan for the content bounding box in its own pcall so `scan_bb` is
        -- freed even if the pixel scanner hits a pathological page and throws.
        local bounds
        local ok_scan, scan_err = pcall(function()
            bounds = scanContentBounds(scan_bb, pageno, full_w, full_h)
        end)
        if scan_bb ~= native_bb then
            scan_bb:free()
        end
        if not ok_scan then
            logger.warn("Meguru: auto-crop scan failed:", scan_err)
            return nil
        end
        if not bounds then
            return nil
        end
        local left, top, right, bottom = bounds[1], bounds[2], bounds[3], bounds[4]
        local bg = bounds.bg
        local sc_x = full_w / sw
        local sc_y = full_h / sh
        -- Coarse content extent in native coordinates. Maximal on every side:
        -- top, bottom, left and right are each trimmed right up to the detected
        -- white margin, independently (scanContentBounds), so an asymmetric
        -- frame is trimmed asymmetrically; nothing but white margin is removed.
        local x0 = math.max(0, math.floor(left * sc_x))
        local y0 = math.max(0, math.floor(top * sc_y))
        local x1 = math.min(full_w, math.ceil((right + 1) * sc_x))
        local y1 = math.min(full_h, math.ceil((bottom + 1) * sc_y))

        if x0 == 0 and y0 == 0 and x1 == full_w and y1 == full_h then
            return nil
        end
        -- Pin each edge to the *exact* outermost content pixel. The coarse scan
        -- above ran on a ~128px downscale, so its box is only flush to a scan
        -- pixel and, worse, the downscale blurs thin boundary features away (a
        -- 1-2px printed frame line right where the panel art starts averages to
        -- near-background and is missed), which leaves a visible white frame
        -- around the panel. The fine pass re-scans a narrow native-resolution
        -- band around each coarse edge with a hair-trigger threshold, so every
        -- trimmed side ends flush with the real content — no margin is left.
        x0, y0, x1, y1 = refineAutoCrop(native_bb, x0, y0, x1, y1, bg,
            math.max(8, math.ceil(sc_x * 3)),
            math.max(8, math.ceil(sc_y * 3)))
        if x0 == 0 and y0 == 0 and x1 == full_w and y1 == full_h then
            return nil
        end
        -- Degenerate-crop guard: whatever happened above, never let a scan
        -- shrink a page below a tiny fraction of its area. (The pagenumbercrop
        -- plugin is what keeps genuinely blank pages uncropped; this is only a
        -- last line of defence against a pathological scan.)
        if (x1 - x0) * (y1 - y0) < AUTOCROP_MIN_KEEP_FRAC * full_w * full_h then
            return nil
        end
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

local PANEL_SCAN_TARGET = 256
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

-- Tighten the coarse auto-crop box to the *exact* outermost content pixel (see
-- computeContentBox for where the coarse box comes from). The coarse scan runs
-- on a ~128px downscale, so its box is only flush to a scan pixel; and the
-- downscale *blurs away* thin boundary features — a 1-2px printed frame line
-- right where the panel art starts averages to near-background in a 128px cell
-- and is missed entirely, so the coarse box can sit a few scan pixels INSIDE
-- the true art and a visible white frame stays around the panel. This pass
-- re-scans a narrow native-resolution band around each coarse edge with a
-- hair-trigger threshold and pins the edge to the first pixel that is actually
-- content. Printed frame lines are full-width features, so the moment the scan
-- reaches one it lights up the whole row/column — every trimmed side ends
-- flush with the real content, with no margin left on any side that has one.
-- Falls back to the coarse box on any hiccup (a crop must never be worse than
-- the coarse one). Returns four tightened numbers in native coordinates.
refineAutoCrop = function(native_bb, x0, y0, x1, y1, bg, pad_x, pad_y)
    if not (native_bb and native_bb.getWidth) then
        return x0, y0, x1, y1
    end
    if native_bb:getRotation() and native_bb:getRotation() ~= 0 then
        return x0, y0, x1, y1 -- raw rows are not axis-aligned: keep the coarse box
    end
    local raster = makeRaster(native_bb)
    if not raster then
        return x0, y0, x1, y1
    end
    local w, h = raster.w, raster.h
    if w < 2 or h < 2 then
        return x0, y0, x1, y1
    end
    local luma = raster.luma
    local delta = AUTOCROP_LUMA_DELTA
    -- Content = a pixel that departs from the border reference luminance (the
    -- very predicate the coarse scan used). Only a row/column with more than
    -- scattered specks counts: ~0.2% of its span (~4px at a 2048px native)
    -- separates a real edge — or a thin printed frame line — from isolated JPEG
    -- noise, and is far below the coarse 2%-of-span bar because this pass only
    -- looks where the coarse scan already proved content is nearby.
    local row_bar = math.max(2, math.floor(w * 0.002))
    local col_bar = math.max(2, math.floor(h * 0.002))

    local function isContent(y, x)
        return math.abs(luma(y, x) - bg) > delta
    end

    -- Top: walk rows from the outward band edge downward; margin rows are
    -- blank, so the first row that clears the bar is the true topmost content.
    local top = y0
    for y = math.max(0, y0 - pad_y), math.min(h - 1, y0 + pad_y) do
        local cnt = 0
        for x = 0, w - 1 do
            if isContent(y, x) then
                cnt = cnt + 1
                if cnt >= row_bar then
                    break
                end
            end
        end
        if cnt >= row_bar then
            top = y
            break
        end
    end

    -- Bottom: the mirror walk, from below the coarse bottom edge upward.
    local bottom = y1 - 1
    for y = math.min(h - 1, y1 - 1 + pad_y), math.max(0, y1 - 1 - pad_y), -1 do
        local cnt = 0
        for x = 0, w - 1 do
            if isContent(y, x) then
                cnt = cnt + 1
                if cnt >= row_bar then
                    break
                end
            end
        end
        if cnt >= row_bar then
            bottom = y
            break
        end
    end

    -- Left: a column counts only when content runs down enough of its height.
    local left = x0
    for x = math.max(0, x0 - pad_x), math.min(w - 1, x0 + pad_x) do
        local cnt = 0
        for y = 0, h - 1 do
            if isContent(y, x) then
                cnt = cnt + 1
                if cnt >= col_bar then
                    break
                end
            end
        end
        if cnt >= col_bar then
            left = x
            break
        end
    end

    -- Right: the mirror column walk, from the far side inward.
    local right = x1 - 1
    for x = math.min(w - 1, x1 - 1 + pad_x), math.max(0, x1 - 1 - pad_x), -1 do
        local cnt = 0
        for y = 0, h - 1 do
            if isContent(y, x) then
                cnt = cnt + 1
                if cnt >= col_bar then
                    break
                end
            end
        end
        if cnt >= col_bar then
            right = x
            break
        end
    end

    local nx0, ny0 = math.max(0, left), math.max(0, top)
    local nx1, ny1 = math.min(w, right + 1), math.min(h, bottom + 1)
    if nx0 >= nx1 or ny0 >= ny1 then
        return x0, y0, x1, y1 -- sanity: the fine pass went sideways, keep coarse
    end
    return nx0, ny0, nx1, ny1
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

    -- How many pages ahead to warm after a repaint, counting the one hintPage is
    -- handed (via ReaderHinting -> Document:hintPage). One is the page the
    -- reader is about to turn to.
    prefetch_count = 1,
    -- Maximum number of decoded/scaled tiles kept in RAM per document.
    max_cached_tiles = 8,
    -- Maximum number of *native* decoded pages kept in RAM (for pan/zoom crops).
    max_cached_native = 3,
    -- Maximum number of raw page-byte entries kept in RAM, per document.
    --
    -- Two is the floor: the page being rendered and the one `hintPage` warms
    -- ahead of it — no path in this file holds two pages' bytes at once, so
    -- nothing ever thrashes a store this size. The rest is room for
    -- ReaderHinting to ask for two pages ahead. It is not a memory figure: these
    -- bytes are the *compressed* page, orders of magnitude below what
    -- `max_cached_native` holds decoded beside them.
    max_cached_pages = 4,

    tiles = nil,    -- decoded tile LRU, key = "pageno|w x h"
    native = nil,   -- native decode LRU, key = pageno
    stamps = nil,   -- key -> recency stamp for `tiles` and `native` ONLY. The
                    --            page-byte store below is a self-ordering array
                    --            and must never be stamped: it is keyed by the
                    --            same numbers `native` is, so a shared stamp
                    --            would let a byte eviction erase a live native's
                    --            recency and free a buffer the renderer holds.
    stamp = 0,
    page_bytes = nil, -- raw page bytes, most-recent-first: { pageno =, bytes = }
    dims = nil,     -- pageno -> {w=, h=} full (capped) native page size, as
                    --            delivered by decodeNative (never cropped)
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
    -- Ask MuPDF for a grayscale pixmap, exactly like the streamed decode
    -- (decodeNativeMupdf sets the same flag per page), so a local cbz looks
    -- bit-for-bit like a .meguru book on every screen.
    if doc.setColorRendering then
        doc:setColorRendering(false)
    end
    return doc
end

function MeguruDocument:init()
    self.tiles = {}
    self.native = {}
    self.stamps = {}
    self.stamp = 0
    self.page_bytes = {}
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
    for _, tile in pairs(self.tiles or {}) do
        if tile.bb and tile.bb_free ~= true then
            tile.bb:free()
            tile.bb_free = true
        end
    end
    for _, item in pairs(self.native or {}) do
        if item.bb and item.bb_free ~= true then
            item.bb:free()
            item.bb_free = true
        end
    end
    self.tiles = {}
    self.native = {}
    self.stamps = {}
    -- No BlitBuffer work for the byte store: its entries are Lua strings, so
    -- dropping the table drops the last references and the GC reclaims them
    -- with nothing here having to be told to.
    self.page_bytes = {}
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

function MeguruDocument:cacheNative(pageno, bb)
    if self.native[pageno] then
        local old = self.native[pageno]
        if old.bb and old.bb_free ~= true then
            old.bb:free()
            old.bb_free = true
        end
    end
    self.native[pageno] = { bb = bb, bb_free = false }
    bump(self, pageno)
    evictOldest(self, self.native, self.max_cached_native)
end

-- True when this page's decoded native is already in the LRU.
--
-- Every render/analysis path below starts by obtaining the page's raw bytes and
-- hands them to `decodeRegion`, which passes them straight to `ensureNativeBB` —
-- and `ensureNativeBB` returns the cached buffer *before* it ever looks at them.
-- So when this is true the bytes are read and thrown away.
--
-- That was affordable while they were a file. With the store in RAM, sized to a
-- handful of pages, the read is a real risk: a repaint whose page has been
-- evicted — a zoom or crop change, a repaint during teardown — would pay a
-- synchronous HTTP GET inside the paint for bytes the render is about to
-- ignore. Skipping it costs nothing:
-- with the native live `ensureNativeBB` cannot fail, so `decodeRegion`'s
-- last-resort branch (the one that genuinely needs `data`) is unreachable.
--
-- It also fixes a plain bug. Today, if the bytes are gone and the native is
-- live, `renderPage` returns nil and the reader is shown the gray placeholder
-- while a perfectly good decoded page sits in the LRU.
function MeguruDocument:hasNative(pageno)
    local item = self.native and self.native[pageno]
    return item ~= nil and item.bb_free ~= true
end

-- ---------------------------------------------------------------------------
-- Page bytes in RAM (fetch page N, keep an LRU)
-- ---------------------------------------------------------------------------
--
-- The store is per-document and keyed by nothing but the page number, which is
-- only unambiguous because exactly one document can reach it — `self.file` is
-- fixed and `self.desc` is assigned once, so one instance never serves two
-- books. A shared store would need the book's identity in the key; this one must
-- not have one, and must never be made shared.
--
-- Its lifetime is the document's: `clearCaches` empties it on close, so opening
-- a book again fetches its pages again.

-- The one read of the byte store, and a hit is moved to the front.
function MeguruDocument:readCachedPage(pageno)
    for i = 1, #self.page_bytes do
        local entry = self.page_bytes[i]
        if entry.pageno == pageno then
            if i > 1 then
                table.remove(self.page_bytes, i)
                table.insert(self.page_bytes, 1, entry)
            end
            return entry.bytes
        end
    end
    return nil
end

-- Keep `bytes` for one page, evicting the least recently read beyond the cap.
--
-- Deliberately not `evictOldest`: its loop is `count >= cap`, so it holds one
-- fewer than its cap reads, and it stamps through the `stamps` table `native`
-- also uses — keyed, as this is, by page number.
function MeguruDocument:cachePage(pageno, bytes)
    for i = 1, #self.page_bytes do
        if self.page_bytes[i].pageno == pageno then
            table.remove(self.page_bytes, i)
            break
        end
    end
    table.insert(self.page_bytes, 1, { pageno = pageno, bytes = bytes })
    -- Dropping the tail drops the last reference to those bytes, so the GC
    -- reclaims them without anything here having to be told to.
    while #self.page_bytes > self.max_cached_pages do
        table.remove(self.page_bytes)
    end
end

-- Credentials to fetch pages with.
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
-- in the byte LRU yet). Returns the bytes, or nil on failure.
function MeguruDocument:fetchPage(pageno)
    local data = self:readCachedPage(pageno)
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
    -- Stored only once the fetch has succeeded, so a failed one writes nothing.
    self:cachePage(pageno, bytes)
    return bytes
end

function MeguruDocument:prefetchPage(pageno)
    if pageno < 1 or pageno > self.info.number_of_pages then
        return
    end
    local ok, data = pcall(self.fetchPage, self, pageno)
    if ok and data then
        logger.dbg("Meguru: prefetched page", pageno, "to the page cache")
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
-- streamed book show its cover wherever covers normally appear.
--
-- **Nothing is cached.** The artwork is fetched over HTTP on every call, so
-- browsing a folder costs one request per book. That is the whole price of
-- having covers at all here, and it is deliberate: a cover already has
-- somewhere else to live — KOReader's own `BookInfoManager` remembers the
-- thumbnail it extracts — so this plugin does not need a store of its own, and
-- with one it would be the only thing meguru wrote to disk.
--
-- The link comes from the catalog, not from the marker: a cover belongs to a
-- book and to a series, and the catalog is where each of those lives, so
-- neither is copied into every marker. A book with no recorded artwork falls
-- back to the first page of its stream, mirroring how a CBZ treats its first
-- image as the cover — and so does a book whose stored link can no longer be
-- fetched, so it is never left cover-less over a stale or moved URL.
--
-- Cover of a local cbz = the archive's first page (like any CBZ). Rendered
-- into a *fresh* capped buffer and bounded to the screen, so the cover never
-- aliases the LRU-cached native of page 1 (that buffer is cache-owned and
-- freed on eviction) nor lingers as an oversized bitmap.
function MeguruDocument:_localCoverPageImage()
    if self.dead_pages[1] then
        return nil
    end
    -- `Image.renderMupdfPage`, not a bare `renderMuPDFPage`: that name is a
    -- file-local of meguru/doc/image.lua and reads as nil here, and
    -- `pcall(nil, ...)` returns false rather than raising — so the whole body
    -- below was unreachable and every local cbz reported "could not render
    -- local cbz cover" whether or not the render would have worked.
    local ok, bb = pcall(Image.renderMupdfPage, self.mupdf_doc, 1, nil)
    if not ok or not bb or bb == Image.DECODE_TOO_LARGE then
        logger.warn("Meguru: could not render local cbz cover")
        return nil
    end
    local w, h = bb:getWidth(), bb:getHeight()
    if w and h and (w > Screen:getWidth() or h > Screen:getHeight()) then
        local scale = math.min(Screen:getWidth() / w, Screen:getHeight() / h)
        local ok_s, scaled = pcall(RenderImage.scaleBlitBuffer, RenderImage, bb,
            math.max(1, math.floor(w * scale + 0.5)),
            math.max(1, math.floor(h * scale + 0.5)), false)
        if ok_s and scaled then
            if scaled ~= bb then
                bb:free() -- bounded cover made; release the full-res render
            end
            return scaled
        end
    end
    return bb
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
        local user, pass = self:streamCredentials()
        local ok, bytes, code = pcall(PSE.fetchPage, cover_url,
            { username = user, password = pass })
        if ok and bytes then
            data = bytes
        else
            -- The stored cover link could not be fetched (moved/changed on the
            -- server, a transient auth/network hiccup, a server that only
            -- answers its own page URLs). Do not leave the book cover-less:
            -- fall through to the first streamed page below — the same fallback
            -- a marker *without* a stored cover link already takes. Nothing was
            -- written, so a later call simply retries the link.
            if ok then
                logger.warn("Meguru: failed to fetch cover (HTTP "
                    .. tostring(code) .. "), falling back to page 1")
            else
                logger.warn("Meguru: failed to fetch cover ("
                    .. tostring(bytes) .. "), falling back to page 1")
            end
        end
    end
    if not data then
        -- No stored cover link, or the stored one failed above: page 1 of the
        -- stream, which on OPDS-PSE servers is usually the cover.
        --
        -- No `hasNative` guard here, unlike the render paths: this decodes the
        -- bytes itself rather than handing them to `decodeRegion`, so it
        -- genuinely needs them. Page 1 is also a page number of its own — the
        -- one entry the byte store can hold that is for a page other than the
        -- one on screen.
        data = self:fetchPage(1)
    end
    if not data then
        return nil
    end

    -- Decode the cover. decodeNative bounds oversized artwork to the cap, so a
    -- server handing out a full-res image as its "cover" is not fully decoded
    -- into RAM either (it would otherwise be another giant transient). A cover
    -- refused as too large (Image.DECODE_TOO_LARGE: huge lossless artwork) simply
    -- has no cover.
    local res = Image.decode(data)
    if not res or res == Image.DECODE_TOO_LARGE then
        logger.warn("Meguru: could not decode cover image")
        return nil
    end
    local bb = res
    -- Bound memory like the MuPDF/kopt cover path: never hand back a larger
    -- bitmap than the screen can use (the raw OPDS cover can be full-res).
    -- free_orig_bb=false: `bb` is owned here (fresh decode), so the scaler
    -- must not free it — we release it only when a distinct bounded copy was
    -- actually produced; when it returns `bb` itself (or a decode failure is
    -- reported via ok_s=false) the buffer is still ours to hand back.
    local w, h = bb:getWidth(), bb:getHeight()
    if w and h and (w > Screen:getWidth() or h > Screen:getHeight()) then
        local scale = math.min(Screen:getWidth() / w, Screen:getHeight() / h)
        local ok_s, scaled = pcall(RenderImage.scaleBlitBuffer, RenderImage, bb,
            math.max(1, math.floor(w * scale + 0.5)),
            math.max(1, math.floor(h * scale + 0.5)), false)
        if ok_s and scaled then
            if scaled ~= bb then
                bb:free() -- bounded cover made; release the full-res decode
            end
            return scaled
        end
    end
    return bb
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
    local bbox = self:_basePageBBox(pageno)
    if not bbox or self._meguru_pagenum_analysis_flag then
        -- The analysis flag guards the (theoretical) re-entry of an analysis
        -- render; none of this document's render paths call back into
        -- getPageBBox, but the guard mirrors pagenumbercrop's and is free.
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

-- Compute and cache the auto content box of `pageno` (see computeContentBox).
-- It is derived from the very native decode that establishes the page size,
-- so it never costs an extra fetch; it is cached in self.crops[pageno] for the
-- page's lifetime (the plain margin scan is trim-independent, so the box is
-- stable while a page is open). nil is cached as "no margin trimmed".
function MeguruDocument:autoContentBox(pageno)
    local cached = self.crops[pageno]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end
    self:getPageDims(pageno) -- decodes & caches the native page into the LRU
    local item = self.native[pageno]
    if not (item and item.bb and item.bb_free ~= true) then
        return nil
    end
    local bb = item.bb
    local box = computeContentBox(bb, bb:getWidth(), bb:getHeight(), pageno)
    -- Store false as the "nothing trimmed" mark: a box table is cached as-is,
    -- a nil result (full page) as false, so a full-bleed page is scanned once
    -- and not re-derived on every getPageBBox / panel-zoom call.
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
-- Cost: the strip and the blank check cut+scale from the per-page cached
-- native decode that getPageDims already keeps (the same render the margin
-- scan and every pan/zoom tile use), so a page turn adds two small region
-- renders — no extra network fetch, matching what pagenumbercrop does to this
-- document through the base Document.renderPage shim.

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
        -- Bytes are only for decodeRegion's *decode* path. A local cbz page has
        -- none (it renders from the open archive, ensureNativeBB's local
        -- branch), and a streamed page whose native is already decoded does not
        -- need them either — see `hasNative`. So `data` staying nil is expected
        -- on both, and the render below must still run. This is a bypass, not a
        -- nil no-op.
        local data
        if not self.local_cbz and not self:hasNative(pageno) then
            data = self:fetchPage(pageno)
            if not data then
                return nil
            end
        end
        return self:decodeRegion(pageno, x, y, w, h, tw, th, data)
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
    -- Bytes are only for the *decode* path: a local cbz page has none (it
    -- renders from the open archive), and a page whose native is already decoded
    -- does not need them — see `hasNative`. `data` staying nil is expected on
    -- both, and the render must run regardless. Bypass, not a nil no-op.
    local data
    if not self.local_cbz and not self:hasNative(pageno) then
        data = self:fetchPage(pageno)
        if not data then
            return nil
        end
    end
    local native_bb = self:ensureNativeBB(pageno, data)
    if not native_bb then
        return nil
    end
    local full_w, full_h = native_bb:getWidth(), native_bb:getHeight()
    if not full_w or not full_h or full_w < 1 or full_h < 1 then
        return nil
    end
    -- Downscale for the gutter scan. The content rectangle is the whole page:
    -- edge margins only add white at the frame, which the interior-gutter
    -- filter (keepInteriorBands) already discards, and gutters that separate
    -- panels span the full content width regardless of any margin crop.
    local small = native_bb
    local sw, sh = full_w, full_h
    if full_w > PANEL_SCAN_TARGET or full_h > PANEL_SCAN_TARGET then
        local scale = PANEL_SCAN_TARGET / math.max(full_w, full_h)
        sw = math.max(1, math.floor(full_w * scale + 0.5))
        sh = math.max(1, math.floor(full_h * scale + 0.5))
        small = RenderImage:scaleBlitBuffer(native_bb, sw, sh, false)
        if not small then
            return nil
        end
    end
    local ok_raster, raster = pcall(makeRaster, small)
    if small ~= native_bb then
        small:free() -- scan copy is C-side owned; free even if makeRaster threw
    end
    if not ok_raster or not raster then
        return nil
    end
    local sx0, sy0 = 0, 0
    local sx1, sy1 = sw, sh
    local tap_x = clamp(math.floor(px * sw / full_w), sx0, sx1 - 1)
    local tap_y = clamp(math.floor(py * sh / full_h), sy0, sy1 - 1)
    local cell = findPanelBounds(raster, { x0 = sx0, y0 = sy0, x1 = sx1, y1 = sy1 },
        tap_x, tap_y)
    if not cell then
        return nil
    end
    -- Map the cell (whole small page == whole native page) back to native.
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
    -- Fetch (if needed) and decode the page once to learn its size. The size
    -- reported is the *full* (capped) native page — decodeNative downscales
    -- oversized scans to the cap, so the decode never holds a huge buffer.
    -- Cropping is deliberately NOT baked into this size: any auto-crop lives
    -- in the bounding box getPageBBox returns, so page turns / zoom recomputes
    -- never re-derive a crop-dependent size (and the bbox, being a pure margin
    -- scan, is stable for a page's lifetime).
    if self.local_cbz then
        -- Local cbz: geometry comes from rendering the page once out of the
        -- open archive, capped exactly like decodeNative caps a streamed page.
        -- ensureNativeBB marks a failed page in self.dead_pages, so a doomed
        -- page is never re-rendered on later lookups; the native LRU keeps the
        -- very buffer whose size is reported here, so geometry, every pan/zoom
        -- tile and the auto content-box scan share one render — the same
        -- one-whole-page-render profile as the streamed mode.
        local native_bb = self:ensureNativeBB(pageno)
        if not native_bb then
            local fallback = { w = Screen:getWidth(), h = Screen:getHeight() }
            self.dims[pageno] = fallback
            return fallback
        end
        local dims = {
            w = math.max(1, native_bb:getWidth()),
            h = math.max(1, native_bb:getHeight()),
        }
        self.dims[pageno] = dims
        pcall(collectgarbage, "collect")
        return dims
    end
    -- Fetched unconditionally, with no `hasNative` guard: this is the decoder,
    -- and a live native would have answered from `self.dims` at the top.
    local data = self:fetchPage(pageno)
    local fallback = { w = Screen:getWidth(), h = Screen:getHeight() }
    if not data then
        self.dims[pageno] = fallback
        return fallback
    end
    local res = Image.decode(data)
    if res == nil or res == Image.DECODE_TOO_LARGE then
        if res == Image.DECODE_TOO_LARGE then
            logger.warn(string.format(
                "Meguru: page %d is a very large lossless image that MuPDF would have to decode at full size (above the %d-Mpx safety limit); skipping it",
                pageno, Image.MAX_LOSSLESS_NATIVE_PIXELS / 1024 / 1024))
        else
            logger.warn("Meguru: cannot decode page", pageno)
        end
        self.dead_pages[pageno] = true
        self.dims[pageno] = fallback
        return fallback
    end
    local bb = res
    local dims = {
        w = math.max(1, bb:getWidth()),
        h = math.max(1, bb:getHeight()),
    }
    self.dims[pageno] = dims

    -- Keep the working-resolution decode (capped by decodeNative) so every
    -- later render of this page reuses it instead of re-rendering the scan:
    -- one capped MuPDF whole-page render per new page covers the geometry, the
    -- auto content box (autoContentBox -> computeContentBox) and every
    -- pan/zoom tile (decodeRegion). This is safe precisely because the buffer
    -- is the *capped* one from Image.decode (never more than `max_native_pixels`
    -- on its long edge), so the native LRU can never
    -- hold a huge scan at full res.
    self:cacheNative(pageno, bb)
    -- Drop this local's reference to the page's raw bytes before forcing the GC
    -- below: it is a multi-MB Lua allocation on a big scan and, still referenced,
    -- a collect right now would not reclaim it. What is kept by this file is the
    -- capped native decode, now cached. The bytes themselves are *not* dropped
    -- wholesale any more — `self.page_bytes` holds those of the last
    -- `max_cached_pages` pages on purpose, so they can be re-decoded without a
    -- fetch. That is a bounded, deliberate holding.
    data = nil
    -- Force a GC right here so the Lua-side garbage is reclaimed *before* the
    -- next page is decoded, instead of piling up until the device runs out of
    -- RAM a few pages in (the built-in page-stream viewer survives exactly
    -- because it holds only one page's worth; without this, e-ink devices with
    -- tight RAM die on the second or third big page). What this reclaims is the
    -- byte strings of pages that have aged past the store's cap; the ones it
    -- still holds are the reason it holds them, and the count is fixed. One full
    -- collect per new page is cheap next to the decode it follows; BlitBuffers
    -- are freed explicitly, so it is the Lua-side garbage this targets.
    pcall(collectgarbage, "collect")
    return dims
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

local function round(v)
    return math.floor(v + 0.5)
end

-- Ensure a working-resolution (native unless capped by decodeNative) BlitBuffer
-- for `pageno` is available, decoding `data` if it is not in the native LRU
-- yet. Returns the BlitBuffer.
function MeguruDocument:ensureNativeBB(pageno, data)
    if self.dead_pages[pageno] then
        return nil -- decode already failed once (or was refused as too large)
    end
    local item = self.native[pageno]
    if item and item.bb_free ~= true then
        bump(self, pageno)
        return item.bb
    end
    self.native[pageno] = nil
    local res
    if self.local_cbz then
        -- Local cbz: no raw bytes to decode — render the page straight from
        -- the open archive, through the same capped renderer the streamed
        -- decode uses. A local page cannot be refused up front as too large
        -- (there are no entry bytes to sniff the format), so Image.DECODE_TOO_LARGE
        -- never comes back here: a huge PNG-in-cbz page keeps its transient
        -- full-res decode inside MuPDF, exactly like the stock DocumentMuPDF
        -- path for the same file (see renderMuPDFPage).
        res = Image.renderMupdfPage(self.mupdf_doc, pageno, nil)
    else
        res = Image.decode(data)
    end
    if res == nil or res == Image.DECODE_TOO_LARGE then
        -- A page that failed to decode once with these bytes will fail again
        -- identically; remembering it keeps a doomed full-resolution decode
        -- (or the RenderImage repeat of it) from running again on every paint.
        if res == Image.DECODE_TOO_LARGE then
            logger.warn(string.format(
                "Meguru: page %d skipped: its lossless source is above the %d-Mpx decode safety limit",
                pageno, Image.MAX_LOSSLESS_NATIVE_PIXELS / 1024 / 1024))
        else
            logger.warn("Meguru: decode failed for page", pageno)
        end
        self.dead_pages[pageno] = true
        return nil
    end
    self:cacheNative(pageno, res)
    return res
end

-- Decode (and, when needed, crop+scale) a page region.
-- `cx, cy, cw, ch` are in *full native* page coordinates (already mapped back
-- from zoomed page space by renderPage, and clamped to the page size); the
-- crop ReaderView applies lives purely in the bounding box it zooms through
-- (getPageBBox), so it never shifts the region requested here. `tw`/`th` is
-- the output tile size. `data` must be the cached raw bytes. Returns a
-- BlitBuffer.
function MeguruDocument:decodeRegion(pageno, cx, cy, cw, ch, tw, th, data)
    local dims = self.dims[pageno] or self:getPageDims(pageno)
    local whole_page = cx <= 0 and cy <= 0 and cx + cw >= dims.w and cy + ch >= dims.h
        and cw >= dims.w and ch >= dims.h

    -- Note: there is deliberately no "whole page → decode straight to the tile
    -- size" fast path. The paths below reuse the LRU-cached, cap-bounded
    -- native render instead (getPageDims keeps one per page), so a page turn
    -- costs a single MuPDF whole-page render, and every subsequent paint of the
    -- page is a slice/scale of that cached buffer — not another whole-page
    -- render.
    local native_bb = self:ensureNativeBB(pageno, data)
    if not native_bb then
        -- No cached/decodable native. ensureNativeBB has already logged and
        -- memoised a decode failure (self.dead_pages), so nothing here retries
        -- a doomed decode on every paint — that repeated ~full-res attempt is
        -- what OOM-killed the process. On the very first failure of a *whole
        -- page* only, a single last-resort direct decode at the tile size is
        -- still worth trying (it can salvage a page whose native capped render
        -- failed for a non-memory reason); any sub-region request must keep
        -- the nil behaviour — a wrong region is worse than a gray tile. Guarded
        -- on `data` too: a local cbz page has no raw bytes for a direct decode.
        if whole_page and not self.dead_pages[pageno] and data ~= nil then
            local ok, bb = pcall(RenderImage.renderImageData, RenderImage, data, #data, false, tw, th)
            if ok and bb then
                return bb
            end
            logger.warn("Meguru: decode/scale failed for page", pageno)
            self.dead_pages[pageno] = true
        end
        return nil
    end
    local fw, fh = native_bb:getWidth(), native_bb:getHeight()
    local nx0 = clamp(round(cx), 0, fw)
    local ny0 = clamp(round(cy), 0, fh)
    local nx1 = clamp(round(cx + cw), nx0 + 1, fw)
    local ny1 = clamp(round(cy + ch), ny0 + 1, fh)
    local rw = nx1 - nx0
    local rh = ny1 - ny0
    -- Scale the requested region out of the native bitmap. When the request is
    -- the *whole* page and the output is not 1:1 (tw/th differ from the native
    -- size), there is nothing to cut out first: scaleBlitBuffer must then
    -- allocate a new buffer, so the scale can run straight on the LRU-cached
    -- native — a no-copy fast path. The cache-ownership rule is what makes the
    -- 1:1 case fall through to the copy: if the output size matched the input,
    -- the scaler could hand back `native_bb` itself, and a tile that aliases
    -- the cache-owned native would then be freed behind the LRU's back on
    -- eviction. Every other request — a pan/zoom sub-rectangle, or a 1:1
    -- whole-page paint — needs a region copy first.
    local cropped
    if nx0 == 0 and ny0 == 0 and rw == fw and rh == fh
            and (tw ~= fw or th ~= fh) then
        cropped = nil
    else
        cropped = Blitbuffer.new(rw, rh, native_bb:getType())
        cropped:blitFrom(native_bb, 0, 0, nx0, ny0, rw, rh)
    end
    -- free_orig_bb=false: scaleBlitBuffer never frees its input, so `cropped`
    -- (when built) is an intermediate owned here — it must be freed
    -- explicitly, or every cropped render leaks one region buffer until a GC
    -- happens (KOReader BlitBuffers are malloc'd outside the Lua heap — see
    -- the bb:free() convention). Handing it over with free_orig_bb=true would
    -- free it inside the call, turning this free into a double-free on every
    -- path where scaling actually happened. The cached `native_bb` is never
    -- consumed by the scaler nor freed here. scaleBlitBuffer may return the
    -- very same buffer when the sizes already match, so only free when
    -- distinct.
    local ok, scaled = pcall(RenderImage.scaleBlitBuffer, RenderImage,
        cropped or native_bb, tw, th, false)
    if cropped and scaled ~= cropped then
        cropped:free()
    end
    if not ok or not scaled then
        logger.warn("Meguru: crop/scale failed for page", pageno)
        return nil
    end
    return scaled
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

    -- Bytes are only for decodeRegion's *decode* path. A local cbz page has none
    -- (it renders from the open archive, ensureNativeBB's local branch), and a
    -- page whose native is already decoded does not need them — see `hasNative`.
    -- `data` staying nil is expected on both, and the render below must still
    -- run, or every page would paint the gray placeholder.
    --
    -- This is the read that matters: it runs on every tile miss — a zoom
    -- change, a crop toggle, a rotation — not just on a page turn.
    local data
    if not self.local_cbz and not self:hasNative(pageno) then
        data = self:fetchPage(pageno)
        if not data then
            return nil
        end
    end

    local bb = self:decodeRegion(pageno, cx, cy, cw, ch, tw, th, data)
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
    -- Counted from `pageno`, not from the page after it: ReaderHinting already
    -- offsets what it hands over (ReaderView passes `state.page + i`), and
    -- stock's own documents treat the argument as the page itself — see
    -- PdfDocument:hintPage, which renders exactly `pageno`. Counting from it
    -- fetched the page AFTER the next one, so the page the reader was about to
    -- turn to had nothing waiting and paid for its fetch on the turn.
    for i = 0, self.prefetch_count - 1 do
        local target = pageno + i
        if target <= self.info.number_of_pages then
            -- A local cbz needs no prefetch: each page renders on demand from
            -- the open archive, and the byte store is not used in that mode.
            -- The analysis below still applies to it.
            if not self.local_cbz then
                self:prefetchPage(target)
            end
            self:analyseAhead(target)
        end
    end
    return true
end

-- Warm everything getPageBBox will be asked about `pageno`, before the reader
-- gets there.
--
-- ReaderView emits HintPage through `UIManager:nextTick`, so this runs on the
-- tick after the current page is already painted — the reader is looking at it,
-- not waiting on a blank screen — and ReaderView unschedules that tick when the
-- view is torn down, so closing the reader drops the work rather than queueing
-- it.
--
-- One call does the lot, because getPageBBox is the single seam all of it hangs
-- off: the margin box, the blank check and the page-number strip are reached
-- from it, and each memoises its answer. Its first step is `getPageDims`, which
-- fetches the page and decodes it into the native LRU — the expensive part of a
-- page turn, and the part this exists to move. That the analyses themselves no
-- longer render (they read the retained buffer) does not make this pointless:
-- the DECODE is still per page, and it is still what a turn waits for.
--
-- Guarded on both sides. Skipped when the crop is off, since nothing it would
-- compute is ever consulted, and for a streamed page when there is no
-- connection — the fetch inside would otherwise sit through its timeout with
-- the UI thread blocked, which is worse than the slow page turn this avoids,
-- and an offline page could not be rendered anyway.
function MeguruDocument:analyseAhead(pageno)
    local c = self.configurable
    if not (c and c.text_wrap ~= 1 and c.trim_page == 1) then
        return
    end
    if self.dead_pages[pageno] then
        return
    end
    if not self.local_cbz then
        local ok, NetworkMgr = pcall(require, "ui/network/manager")
        if not ok or not NetworkMgr or not NetworkMgr:isConnected() then
            return
        end
    end
    -- pcall: this runs in an event nothing is waiting on, so a throw in a
    -- heuristic must cost a crop, not the book.
    pcall(self.getPageBBox, self, pageno)
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
