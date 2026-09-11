--[[--
Turning page bytes into a BlitBuffer.

One operation, and everything this document paints is one of it: render a
rectangle of a page into a buffer of a chosen size. A screen tile and the
low-resolution copy a content heuristic scans are the same call with different
arguments — there is no second path, no whole-page decode and no resolution cap,
so no buffer can ever differ from what its caller asked for.

MuPDF does the work through its *page* pipeline (`page:draw_new` on a document
opened from the page's bytes): like a CBZ or PDF page, the image is painted
straight into a pixmap the size of the target, and MuPDF decimates an oversized
JPEG *while* decoding. The full-resolution buffer KOReader's TurboJPEG path
would force — 5405x3840 and larger on some servers — therefore never exists,
which is what makes monster spreads survivable on a low-RAM e-ink device.

The pixmap is sized by the caller and windowed onto the source rectangle, which
is exactly what stock's `Document:renderPage` does when it renders a region: the
already-scaled `rect.x`/`rect.y` become the pixmap's bounding box and the context
is left at a plain zoom. See the note in `renderRegion` for why the translation
belongs to the window and not to the context.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local DrawContext = require("ffi/drawcontext")
local RenderImage = require("ui/renderimage")
local logger = require("logger")

-- Guarded: every KOReader that can run this plugin ships the binding, but a
-- build without it degrades rather than failing to load the document.
local Mupdf
do
    local ok, mupdf = pcall(require, "ffi/mupdf")
    if ok and mupdf and mupdf.openDocumentFromText and mupdf.openDocument then
        Mupdf = mupdf
    end
end

local Image = {}

-- Blitbuffer pixel type -> bytes per pixel, or nil for anything this module
-- will not read as pixels. The content scans walk raw bytes, so they need this.
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

-- ---------------------------------------------------------------------------
-- Opening page bytes
-- ---------------------------------------------------------------------------

local JPEG_MAGIC = "\255\216\255" -- FF D8 FF
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
--- to the RenderImage path below rather than claiming a handler this build
--- lacks.
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

-- Open a streamed page's bytes as a one-page MuPDF document, or nil.
--
-- One document per call, closed again by the caller: the streamed path holds no
-- document between pages, because the bytes it would hold it for are fetched
-- per page and dropped as soon as they are used.
local function openPageBytes(data)
    if not Mupdf then
        return nil
    end
    local magic = documentMagic(data)
    if not magic then
        return nil
    end
    local ok, doc = pcall(Mupdf.openDocumentFromText, data, magic)
    if not ok or not doc then
        logger.dbg("Meguru: MuPDF cannot open page bytes:", tostring(doc))
        return nil
    end
    -- Ask MuPDF for a grayscale pixmap where it honours the flag (a colour page
    -- is then converted on the way in). The buffer comes back RGB24 all the
    -- same — the conversion to the 8bpp e-ink screen happens in the converting
    -- blit in drawPage, which is also why night mode inverts the *destination*
    -- region there instead of calling invertblitFrom on the tile.
    if doc.setColorRendering then
        doc:setColorRendering(false)
    end
    return doc
end

-- ---------------------------------------------------------------------------
-- The RenderImage fallback
-- ---------------------------------------------------------------------------
--
-- KOReader's own decoder, which reaches formats MuPDF cannot (WEBP above all)
-- and is the only path left on a build without the MuPDF binding. Both helpers
-- below are the *only* place that can hold a full-resolution buffer: a format
-- with no random access has to be decoded whole before it can be scaled or even
-- measured, so an oversized lossless page of one is the single case a document
-- built on this module cannot bound.
--
-- Kept knowingly. Dropping it would silently end WEBP support — `documentMagic`
-- deliberately does not claim `image/webp` — and a server serving its artwork
-- as WEBP would simply show blank pages, with nothing in the log to say why.

-- Dimensions of an image MuPDF will not open. There is no cheaper way to ask
-- TurboJPEG/pic for dimensions alone, hence the whole decode.
local function sizeWithRenderImage(data)
    local ok, bb = pcall(RenderImage.renderImageData, RenderImage, data, #data, false)
    if not ok or not bb then
        return nil
    end
    local w, h = bb:getWidth(), bb:getHeight()
    -- Malloc'd outside the Lua heap, like every BlitBuffer here: nothing will
    -- reclaim it, and only the size was wanted.
    bb:free()
    return w, h
end

-- The same for painting. Decode straight to the tile size so the scaler is the
-- decoder's own. There is no region crop on this path — a format without random
-- access has no region to give — so the whole image is scaled to the window the
-- caller asked for, which is the same buffer it would have got from a crop.
local function renderWithRenderImage(data, tw, th)
    local ok, bb = pcall(RenderImage.renderImageData, RenderImage, data, #data, false, tw, th)
    if not ok or not bb then
        return nil
    end
    return bb
end

-- ---------------------------------------------------------------------------
-- Measuring a page
-- ---------------------------------------------------------------------------

-- The page's size in pixels, without decoding it. `doc` is already open; only
-- the page object is opened and closed here.
local function measure(doc, pageno)
    local ok_page, page = pcall(doc.openPage, doc, pageno)
    if not (ok_page and page) then
        logger.dbg("Meguru: MuPDF openPage failed:", tostring(page))
        return nil
    end
    -- Page size at zoom 1 (floats; a bare-image document measures in pixels,
    -- possibly with an EXIF-quadrant turn already applied).
    local ok_size, pw, ph = pcall(page.getSize, page, DrawContext.new())
    page:close()
    if not (ok_size and pw and ph and pw > 0 and ph > 0) then
        logger.dbg("Meguru: MuPDF page size lookup failed")
        return nil
    end
    return math.max(1, math.floor(pw + 0.5)), math.max(1, math.floor(ph + 0.5))
end

--- The pixel size of a streamed page, from its raw bytes. nil when there is no
--- page to show (an unopenable format, or no MuPDF binding at all).
---
--- This is what stock does (`Document:getNativePageDimensions` -> `page:getSize`)
--- and the reason a page turn no longer pays a whole-page decode just to learn
--- how big the page is. Bytes for a format MuPDF cannot open fall back to a
--- real decode — see `sizeWithRenderImage`.
function Image.pageSizeOfBytes(data)
    local doc = openPageBytes(data)
    if not doc then
        return sizeWithRenderImage(data)
    end
    local w, h = measure(doc, 1)
    doc:close()
    return w, h
end

--- The pixel size of page `pageno` of an open document (a local cbz). A cbz
--- cannot be measured by the fallback: the page is inside the archive, not in
--- a byte string, and only MuPDF can reach it.
function Image.pageSizeOfDoc(doc, pageno)
    if not Mupdf or not doc then
        return nil
    end
    return measure(doc, pageno)
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

-- The one render. Paints the native rectangle (sx, sy, sw, sh) of `pageno` into
-- a buffer of exactly tw x th. `doc` is open and owned by the caller.
local function renderRegion(doc, pageno, sx, sy, sw, sh, tw, th)
    local ok_page, page = pcall(doc.openPage, doc, pageno)
    if not (ok_page and page) then
        logger.dbg("Meguru: MuPDF openPage failed:", tostring(page))
        return nil
    end
    local dc = DrawContext.new()
    -- The LARGER of the two axis scales, so the source rectangle always COVERS
    -- the tile — the sliver of over-cover on the other axis is clipped away
    -- rather than letterboxed into background bars. It also means the tile is
    -- never short of content at a page edge, where clamping the region can
    -- leave the two axis ratios slightly apart.
    local z = math.max(tw / sw, th / sh)
    dc:setZoom(z)
    -- The window, not the context.
    --
    -- `draw_new`'s offset arguments go straight into the pixmap's `fz_irect`
    -- and never touch the CTM, so they are in *device* units with nothing to
    -- interpret: the window covers [z*sx, z*sx + tw), and page point sx lands
    -- exactly on its first pixel. This is stock's own arrangement —
    -- Document:renderPage renders a region by putting the already-scaled
    -- `rect.x`/`rect.y` in the pixmap bbox and leaving the context alone.
    --
    -- It was moved into the context before, as `dc:setOffset(-sx * z, -sy * z)`,
    -- on the reading that a context offset is in output units. It is not:
    -- `fz_pre_translate` multiplies a matrix, so the offset is in SOURCE units
    -- and the zoom was applied to it a second time. The window then sat at
    -- `sx * z` instead of `sx`, and every render started away from the page's
    -- origin was displaced by `(sx, sy) * (z - 1)` — invisible near z = 1, and
    -- ruinous where z is not: the page-number strip renders at z = 2 with
    -- sy = 1275, which put the whole strip 1275 page pixels below its own
    -- pixmap, so it came back blank white, no page number was ever found, and
    -- the bottom gutter was never trimmed.
    local ok_draw, bb = pcall(page.draw_new, page, dc, tw, th,
        math.floor(z * sx), math.floor(z * sy))
    page:close()
    if not ok_draw or not bb then
        logger.dbg("Meguru: MuPDF render failed:", tostring(bb))
        return nil
    end
    return bb
end

--- Render the page rectangle (sx, sy, sw, sh) of a streamed page's bytes into a
--- buffer of exactly tw x th. nil when the bytes cannot be opened or drawn.
function Image.renderRegion(data, sx, sy, sw, sh, tw, th)
    local doc = openPageBytes(data)
    if not doc then
        return renderWithRenderImage(data, tw, th)
    end
    local bb = renderRegion(doc, 1, sx, sy, sw, sh, tw, th)
    doc:close()
    return bb
end

--- The same for page `pageno` of an open document. Never closes `doc`: it lives
--- for the book's lifetime and is shared with the cover renderer and with every
--- other page of the book.
function Image.renderRegionFromDoc(doc, pageno, sx, sy, sw, sh, tw, th)
    if not Mupdf or not doc then
        return nil
    end
    return renderRegion(doc, pageno, sx, sy, sw, sh, tw, th)
end

Image.bytesPerPixel = bbBytesPerPixel

return Image
