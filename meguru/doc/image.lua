--[[--
Turning page bytes into a BlitBuffer, with a ceiling on how much of it is kept.

Every page this plugin renders at *native* resolution comes through `decode`
here — for geometry, for the pan/zoom crops and for the content-box scan.

MuPDF goes first because it renders through its *page* pipeline (`page:draw_new`
on a document opened from the raw bytes) and decimates an oversized JPEG while
decoding. The full-resolution buffer KOReader's RenderImage/TurboJPEG path would
force — 5405x3840 and larger on some servers — therefore never exists, which is
what makes monster spreads survivable on a low-RAM e-ink device. `RenderImage`
stays as the fallback for bytes MuPDF cannot open and for builds without the
binding; it is the one path where a full-resolution decode can still happen.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local DrawContext = require("ffi/drawcontext")
local RenderImage = require("ui/renderimage")
local logger = require("logger")

local Settings = require("meguru/settings")

-- Guarded: every KOReader that can run this plugin ships the binding, but a
-- build without it degrades to the RenderImage path rather than failing to
-- load the document at all.
local Mupdf
do
    local ok, mupdf = pcall(require, "ffi/mupdf")
    if ok and mupdf and mupdf.openDocumentFromText and mupdf.openDocument then
        Mupdf = mupdf
    end
end

local Image = {}

-- Blitbuffer pixel type -> bytes per pixel, or nil for anything this
-- module will not decode. Decoders give us one of these: grayscale BB8
-- on e-ink, RGB24/RGB32 on colour, BB8A for a PNG with an alpha channel.
local function bbBytesPerPixel(bb_type)
    if bb_type == Blitbuffer.TYPE_BB8 then
        return 1
    elseif bb_type == Blitbuffer.TYPE_BB8A then
        return 2
    elseif bb_type == Blitbuffer.TYPE_BBRGB24 then
        return 3
    elseif bb_type == Blitbuffer.TYPE_BBRGB32 then
        return 4
    end
    return nil
end

-- Every place this document decodes a page at its *native* resolution (to
-- discover geometry, to keep a native decode for pan/zoom crops and for the
-- auto content-box scan) funnels through decodeNative below.
-- Pages are rendered by MuPDF's *page* pipeline (page:draw_new on a document
-- opened from the raw page bytes): like a CBZ/PDF page, the image is painted
-- straight into a pixmap the size of the target, and MuPDF decimates oversized
-- JPEGs *while* decoding — the full-resolution buffer that KOReader's
-- RenderImage/TurboJPEG path forced for every scan (5405x3840, >7 MB, and up
-- to ~6900x4913 on some servers) never exists at all. That was the change
-- needed to page through monster spreads on a low-RAM e-ink device.
--
-- The render is asked to produce a buffer that fits the configured pixel
-- budget, so everything downstream — the native LRU (up to 3 pages), the
-- whole-page crop intermediates, and the pan/zoom sub-rectangle copies — has a
-- bound on what it can hold. The budget therefore only limits *retained*
-- resolution (and RAM); the decode peak itself is set by MuPDF's subsampling,
-- not by it. Lossless formats (PNG, GIF, ...) are still decoded at full size
-- inside MuPDF before being subsampled — the same one-transient profile the old
-- path had, never worse.
--
-- Pages that already fit the budget come back at their natural resolution, so
-- normal-sized books are completely unaffected — a 2600x3700 spread is 9.5 Mpx
-- and the default budget is 8, which costs it 9%. What the budget buys is the
-- other shape of page: an 800x20000 strip used to be capped on its LONG edge to
-- 82 px of width; under the same budget it keeps 566. See `cappedDim`.

-- The working size of one decoded page: its own size, reduced until it fits the
-- budget — or unchanged, if it already does.
--
-- The reduction is by AREA, not by the longest edge, and that difference is the
-- whole point of this function. A long-edge cap punishes a tall page without
-- measure: an 800x20000 manhwa strip and a 4000x5000 scan are both capped on
-- their longest side, so the strip loses 9.8x of its WIDTH while the scan loses
-- 2.4x — and width is the only thing a reader ever sees of a strip, because it
-- is scrolled, not shrunk to fit. Capping the area reduces both axes by the same
-- factor instead, so no page is treated worse than another, and the memory a
-- page can take is bounded absolutely (the budget) rather than by cap squared.
--
-- `budget` is in pixels; the caller reads it from the `max_native_pixels`
-- preference.
local function cappedDim(w, h, budget)
    if not w or not h or w < 1 or h < 1 then
        return w, h
    end
    local area = w * h
    if area <= budget then
        return w, h
    end
    local s = math.sqrt(budget / area)
    return math.max(1, math.floor(w * s + 0.5)),
           math.max(1, math.floor(h * s + 0.5))
end

-- Sentinel returned by decodeNativeMupdf (and decodeNative) when a page's
-- *lossless* source is so large that decoding it would need a full-resolution
-- transient this class of device cannot afford. Distinct from a plain nil
-- ("could not decode") so callers can refuse such a page up front instead of
-- falling through to a second, equally doomed full-res attempt (that second
-- attempt is the ~100 MB malloc that OOM-kills the process on low-memory
-- devices).
local DECODE_TOO_LARGE = {}

-- MuPDF subsamples oversized *JPEG* sources while decoding (DCT), so a huge
-- JPEG page never exists at full resolution in RAM, no matter how big it is.
-- Every other format (PNG, BMP, TIFF, ...) is decoded at its full native size
-- first and only then scaled down to the capped working resolution — so a
-- very large lossless page forces a transient of native_w * native_h * 3-4
-- bytes that MuPDF cannot avoid. MAX_LOSSLESS_NATIVE_PIXELS bounds that
-- transient (roughly 60-80 MB at 20 Mpx): lossless pages above it are refused
-- before the decode is even attempted. Regular-sized scans, and oversized
-- JPEGs of any size, are unaffected.
local MAX_LOSSLESS_NATIVE_PIXELS = 20 * 1024 * 1024 -- 20 Mpx
local JPEG_MAGIC = "\255\216\255" -- FF D8 FF

local function isJpegBytes(data)
    return type(data) == "string" and #data >= 3 and data:sub(1, 3) == JPEG_MAGIC
end

local PNG_MAGIC = "\137PNG\r\n\26\n" -- 89 50 4E 47 0D 0A 1A 0A

--- The document type to hand MuPDF for a streamed page's bytes.
---
--- `openDocumentFromText(text, magic)` — `magic` is not optional, even though it
--- reads as a hint. Passing nil raises `argument error: missing file type` from
--- libwrap-mupdf: a message that names no call site, arrives as a non-fatal
--- UNHANDLED EXCEPTION before whatever crashes next, and is easy to read as
--- noise. It is not noise; it means the page never got decoded.
---
--- A type that is present but wrong is a *different* error — the wrapper says
--- `cannot find document handler for file type: '<x>'`, naming the value. So a
--- sniff that guesses badly is loud rather than silent, which is what makes
--- guessing here safe.
---
--- Only types the wrapper's own handler table lists are claimed — every one
--- below is in it (`grep -a -o 'image/[a-z0-9+.-]*' libs/libwrap-mupdf.so` on
--- the runtime); `image/webp` is not, so a WEBP page deliberately falls through
--- to the RenderImage fallback instead of claiming a handler this build lacks.
local function documentMagic(data)
    if type(data) ~= "string" or #data < 12 then
        return nil
    end
    if data:sub(1, 3) == JPEG_MAGIC then
        return "image/jpeg"
    end
    if data:sub(1, 8) == PNG_MAGIC then
        return "image/png"
    end
    if data:sub(1, 4) == "GIF8" then
        return "image/gif"
    end
    if data:sub(1, 2) == "BM" then
        return "image/bmp"
    end
    local tiff = data:sub(1, 4)
    if tiff == "II*\0" or tiff == "MM\0*" then
        return "image/tiff"
    end
    return nil
end

-- Render one page (`pageno`, 1-based) of an ALREADY-OPEN MuPDF `doc` into a
-- whole-page BlitBuffer whose long edge is at most the native cap — the core
-- both the streamed-bytes decode and the local-cbz render share. `doc` is
-- owned by the caller (the streamed path opens and closes a one-page document
-- per page; the local-cbz path keeps one open for the book's lifetime and
-- passes the reader's page number, which MuPDF numbers exactly like the stock
-- DocumentMuPDF numbers the same file, so page order/count always agree
-- between the two engines).
--
-- `refuse_oversize` is an optional function(fw, fh) returning true when the
-- page must NOT be rendered (its full-size decode transient would be fatal on
-- this device). Only the streamed path can supply one: it knows the source
-- format from the bytes (a >20 Mpx LOSSless page — never an oversized JPEG,
-- which MuPDF subsamples in-stream — see MAX_LOSSLESS_NATIVE_PIXELS). A local
-- cbz page passes nil: there are no entry bytes to sniff the format, and
-- refusing by size alone would wrongly reject oversized *JPEG* cbz entries
-- (the currently-safe common case). So a huge PNG-in-cbz keeps its transient
-- full-res decode inside MuPDF, then the retained native is capped and RAM
-- returns to baseline — exactly the stock DocumentMuPDF profile for the same
-- file (the one place local rendering is less guarded than the streamed path).
-- Returns a BlitBuffer, nil on failure, or DECODE_TOO_LARGE when
-- `refuse_oversize` refused the page.
local function renderMuPDFPage(doc, pageno, refuse_oversize)
    local budget = Settings.get("max_native_pixels")
    local ok_page, page = pcall(doc.openPage, doc, pageno)
    local bb
    if ok_page and page then
        -- Native page size at zoom 1 (floats; a bare-image document measures
        -- in pixels, possibly with an EXIF-quadrant turn already applied).
        local ok_size, pw, ph = pcall(page.getSize, page, DrawContext.new())
        if ok_size and pw and ph and pw > 0 and ph > 0 then
            local fw = math.max(1, math.floor(pw + 0.5))
            local fh = math.max(1, math.floor(ph + 0.5))
            if refuse_oversize and refuse_oversize(fw, fh) then
                page:close()
                return DECODE_TOO_LARGE
            end
            local cw, ch = cappedDim(fw, fh, budget)
            if cw < 1 then cw = 1 end
            if ch < 1 then ch = 1 end
            -- Uniform zoom maps the whole (native) page onto the capped box;
            -- the offset stays (0,0), so the box is the full page, nothing
            -- cropped. MuPDF then decodes the (oversized, JPEG) source only
            -- as far as ~this target resolution requires.
            local dc = DrawContext.new()
            dc:setZoom(cw / fw)
            local ok_draw, rendered = pcall(page.draw_new, page, dc, cw, ch, 0, 0)
            if ok_draw and rendered then
                bb = rendered
                logger.dbg(string.format(
                    "Meguru: MuPDF page render %dx%d -> %dx%d (budget %d px)",
                    fw, fh, cw, ch, budget))
            else
                logger.dbg("Meguru: MuPDF page render failed:", tostring(rendered))
            end
        else
            logger.dbg("Meguru: MuPDF page size lookup failed")
        end
        page:close()
    else
        logger.dbg("Meguru: MuPDF openPage failed:", tostring(page))
    end
    return bb
end

-- Render `data` (raw bytes of a streamed page / cover) through MuPDF into a
-- BlitBuffer of the whole page whose long edge is at most the cap. Returns nil
-- on any failure (decodeNative then falls back to the classic RenderImage path
-- below). NOTE: the buffer page:draw_new hands back is a colour (RGB24) one,
-- not an 8bpp grayscale tile — it reaches an e-ink screen only through the
-- converting, dithered blit in drawPage (ditherblitFrom, always on — see init),
-- and that is exactly why the night-mode "Invert Document" path inverts the
-- destination region instead of calling invertblitFrom on the tile (see
-- drawPage).
local function decodeNativeMupdf(data)
    if not Mupdf then
        return nil
    end
    local magic = documentMagic(data)
    if not magic then
        return nil
    end
    local ok_doc, doc = pcall(Mupdf.openDocumentFromText, data, magic)
    if not ok_doc or not doc then
        logger.dbg("Meguru: MuPDF cannot open page bytes:", tostring(doc))
        return nil
    end
    -- Ask MuPDF for a grayscale pixmap where it honours the flag (a colour page
    -- is then converted on the way in). The returned buffer is still an RGB24
    -- BlitBuffer — the final conversion to the 8bpp e-ink screen happens in the
    -- converting blit in drawPage, not here.
    if doc.setColorRendering then
        doc:setColorRendering(false)
    end
    -- Oversized-lossless refusal is decided from the raw bytes (the JPEG sniff
    -- can only run here, on the streamed source); the shared render core just
    -- applies the decision. A huge JPEG is always exempt (subsampled in-stream).
    local res = renderMuPDFPage(doc, 1, function(fw, fh)
        return not isJpegBytes(data) and fw * fh > MAX_LOSSLESS_NATIVE_PIXELS
    end)
    doc:close()
    return res
end

-- Classic fallback: decode through RenderImage (TurboJPEG for JPEGs) and, when
-- the decode is over the cap, downscale it. This keeps a working path for the
-- (rare) bytes MuPDF cannot open, and for KOReader builds without the MuPDF
-- binding. Note it is the one place a full-resolution decode can still happen.
local function decodeNativeRenderImage(data)
    local ok, bb = pcall(RenderImage.renderImageData, RenderImage, data, #data, false)
    if not ok or not bb then
        return nil
    end
    local budget = Settings.get("max_native_pixels")
    local w, h = bb:getWidth(), bb:getHeight()
    local cw, ch = cappedDim(w, h, budget)
    if cw == w and ch == h then
        return bb -- within the budget: return the decode untouched
    end
    logger.dbg(string.format(
        "Meguru: page decode %dx%d over the %dpx budget, downscaling to %dx%d",
        w, h, budget, cw, ch))
    -- Scale with free_orig_bb=false: RenderImage:scaleBlitBuffer never frees
    -- its input then, so ownership of `bb` stays unambiguously with this
    -- function on every path (it is ours — a fresh decode, not yet cached).
    -- On a scaling failure the original is still ours and untouched — returning
    -- it is safer than crashing, even though it defeats the cap for this page.
    local ok2, scaled = pcall(RenderImage.scaleBlitBuffer, RenderImage, bb, cw, ch, false)
    if not ok2 then
        logger.warn("Meguru: downscale to", cw, "x", ch,
            "failed, keeping native decode:", tostring(scaled))
        return bb
    end
    if scaled ~= bb then
        bb:free() -- a distinct bounded copy exists; release the full-res input
        return scaled
    end
    return bb
end

-- Decode a page at working ("native") resolution. MuPDF first: it downscales
-- oversized JPEGs *while* decoding, so no full-resolution buffer is ever held
-- (the change that stops the OOM on huge scans). On a MuPDF failure
-- (unrecognised format, missing binding) fall back to the classic RenderImage
-- decode + downscale above. Returns nil on any failure, or DECODE_TOO_LARGE
-- for an oversized lossless page that must not be decoded on this device (the
-- RenderImage fallback is skipped for it: it would only repeat the same doomed
-- full-resolution decode).
local function decodeNative(data)
    if Mupdf then
        local res = decodeNativeMupdf(data)
        if res == DECODE_TOO_LARGE then
            return DECODE_TOO_LARGE
        end
        if res then
            return res
        end
    end
    return decodeNativeRenderImage(data)
end

Image.DECODE_TOO_LARGE = DECODE_TOO_LARGE
Image.bytesPerPixel = bbBytesPerPixel
Image.cappedDim = cappedDim
Image.isJpeg = isJpegBytes
Image.renderMupdfPage = renderMuPDFPage
Image.decode = decodeNative

return Image
