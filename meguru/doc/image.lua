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

--- Whether this screen should get colour renders.
---
--- **`device.screen:isColorEnabled()` is KOReader's own answer, and following it
--- is the whole point.** It is the same source stock's `CanvasContext` reads to
--- set `is_color_rendering_enabled` (`canvascontext.lua:53`), so asking it here
--- means following the reader's existing colour setting rather than inventing a
--- second one. It is also **live**: it reads `G_reader_settings.color_rendering`
--- and falls back to what the screen can actually do (`device.lua:264-270`), so
--- a reader who turns colour off gets grayscale on the next decode with no
--- restart.
---
--- **Two conditions, not one.** Wanted colour is not the same as reachable
--- colour: the second half of this function refuses a framebuffer that would
--- flatten the result at blit time. See the note at the end for what it does and
--- does not close.
---
--- Asked at decode time and never cached — a value captured once would make that
--- toggle inert until the plugin reloaded.
---
--- False wherever the question cannot be answered: an absent device table, a
--- build whose screen has no such method, or a call that throws. False is both
--- the old hard-coded behaviour and the memory-cheap direction, so a surprise
--- here costs colour and never a crash.
function Image.colorEnabled()
    local ok, Device = pcall(require, "device")
    if not ok or type(Device) ~= "table" then
        return false
    end
    local scr = Device.screen
    if not (scr and type(scr.isColorEnabled) == "function") then
        return false
    end
    local ok_call, enabled = pcall(scr.isColorEnabled, scr)
    if not (ok_call and enabled) then
        return false
    end

    -- **And the destination has to be able to hold it.** `screen:isColorEnabled()`
    -- answers what the *reader* asked for; it says nothing about whether the
    -- bytes survive the blit. `BB_blit_to` dispatches on the target's type
    -- (`base/blitbuffer.c`), and an RGB source landing in an 8bpp target runs
    -- `RGB_To_A` — luminosity, colour discarded, irreversibly. On such a screen
    -- a colour decode costs three times the memory and ends as the grayscale it
    -- would have been anyway.
    --
    -- `fb_bpp` is the depth KOReader read from the kernel
    -- (`framebuffer_linux.lua`), so `8` is exactly the grayscale framebuffer.
    -- **nil is not 8**: a desktop/SDL build never sets the field, and a desktop
    -- is the one place colour is most obviously wanted and most obviously works.
    --
    -- This closes the case that is certain, and is honest about the one that is
    -- not: a device that reports colour, has a wide framebuffer, and still cannot
    -- show it — a Kindle Colorsoft, whose colour panel KOReader has no CFA
    -- handling for — passes this test and pays the memory. There is no clean
    -- signal for that in Lua: `hasKaleidoWfm`, the flag KOReader's own colour-UI
    -- gate uses, is false there *and* on a desktop, so it cannot tell them apart.
    -- The cost in that case is bounded by what stock already pays on the same
    -- device, since `is_color_capable` gives stock's own tiles RGB32 there too.
    return scr.fb_bpp ~= 8
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
-- every page that fits a screen is completely unaffected — a 1600x2400 page is
-- 3.8 Mpx and the default budget is 4 Mpx, so it is decoded as it is. What the
-- budget buys is the other shape of page: an 800x20000 strip used to be capped
-- on its LONG edge to 82 px of width; under this budget it keeps 410. What the
-- budget costs is resolution on an oversized page — a 2600x3700 spread (9.6
-- Mpx) loses 34% per axis, which is the trade `meguru/settings` records the
-- reasoning for. See `cappedDim` for the rule and `meguru/settings` for the
-- number.

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
                -- info, not dbg: this is the line that says whether the budget
                -- bit on this page at all. An oversized page and a page that
                -- fits show up here as different numbers, which is the only
                -- place the decode cost is visible without a profiler — and
                -- `budget` is only ever moved by hand (no menu writes it), so
                -- the log is how a reader checks that their edit took.
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

-- Render `data` (the raw bytes of a streamed page) through MuPDF into a
-- BlitBuffer of the whole page, reduced until it fits the pixel budget. Returns
-- nil on any failure (decodeNative then falls back to the classic RenderImage
-- path below).
--
-- NOTE: the buffer page:draw_new hands back is an **8bpp grayscale (BB8)** one,
-- not a colour tile. `draw_new` picks its buffer type from `doc.color`, and the
-- document is opened with the flag turned off here — so a page reaches a
-- grayscale screen through a same-format blit, and nothing is converted on the
-- way. That is the premise the dither decision in `document.lua`'s init rests
-- on, and an earlier version of this comment had it backwards (it claimed
-- RGB24, which is what `doc.color` true would have produced) — which is how a
-- re-quantising software dither came to look justified.
--
-- The night-mode "Invert Document" path in `document.lua` inverts the
-- destination region rather than calling invertblitFrom on the tile. That is
-- correct for a tile of any format; it is no longer *required* by this one.
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
    -- Colour where the screen can show it, grayscale where it cannot. The
    -- answer is the reader's own colour setting, read live (see
    -- `Image.colorEnabled`) — and on an e-ink panel it is exactly the `false`
    -- that used to be hard-coded here, so nothing about that path moves.
    --
    -- The decision has to be *set*, not merely left alone: `draw_new` allocates
    -- `BlitBuffer.TYPE_BB8` whenever `doc.color` is falsy, and
    -- `Mupdf.openDocumentFromText` never sets the field, so doing nothing would
    -- pin every decode to grayscale on every screen.
    if doc.setColorRendering then
        doc:setColorRendering(Image.colorEnabled())
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

-- Render ONE REGION of a page into a buffer of the size the caller actually
-- wants, in a single pass and straight from the source.
--
-- This is the shape stock KOReader's MuPDF path has: `Document:renderPage`
-- renders the requested rect at the full zoom, in one call, and blits the result
-- to the screen 1:1. The alternative — and what this plugin did — is to render
-- the whole page at the capped working size and then rescale a crop of it, which
-- resamples every painted pixel twice and, on a page the cap has already
-- reduced, magnifies a buffer smaller than the file it came from.
--
-- **How the region is located.** `page:draw_new(dc, w, h, ox, oy)` builds a CTM
-- of `scale(dc.zoom)` and a pixmap whose origin is the *device* point `(ox, oy)`
-- — the page point `p` lands on device `zoom * p`. So the window
-- `(ox, oy, ox + w, oy + h)` is exactly "the page region whose device
-- coordinates fall inside it", and putting the region's own start at the window
-- origin is what crops:
--
--     ox = zoom * nx        and        ox + tw = zoom * (nx + nw)
--
-- so `zoom = tw / nw` makes both ends land. **`dc.offset_*` must stay zero**: it
-- is a second, independent translation, and the whole-page render below leaves
-- it at origin.
--
-- **The coordinate space, which is the trap.** `nx, ny, nw, nh` arrive in the
-- space `self.dims` lives in — the *capped* working size, which for an oversized
-- page is smaller than MuPDF's own page. The factor between the two is
-- recomputed here with the very same `cappedDim` the decode used rather than
-- passed in, so the two cannot drift apart: were they to, the crop would land
-- somewhere else on the page, silently and by however much the cap moved.
--
-- **`tw`/`th` are the size of the buffer to produce — leave both out (`nil`) and
-- the region is rendered at its own size in page pixels**, bounded by the same
-- budget the whole-page decode gets. That is what panel zoom wants and what a
-- paint does not: a paint is going to a known screen rectangle and wants exactly
-- that many pixels, while the ImageViewer is going to magnify what it is given,
-- so handing it the region's own pixels is the difference between magnifying the
-- file and magnifying a picture of the screen. The size is derived here, from
-- the same `f`, rather than by the caller — the one place that knows how far the
-- caller's space is from the page's.
--
-- **`planes`/`bg` are a panel's crop, and they are the one exception to "the
-- region is a rectangle".** Panel zoom asks for a region that is not axis-aligned
-- — a panel's border follows the artwork's own tilt — and `nw`/`nh` here are that
-- quadrilateral's *bounding* box, with `planes` saying where its edges run. The
-- tile is cut down to them on the way out (`maskToQuad`), inside this function
-- rather than at the call site, so the buffer the tile LRU keeps is already the
-- panel and no reader of a cached tile has to know about the shape. Absent —
-- which is every caller that is not panel zoom — nothing is masked and the
-- region means exactly what it always did.
--
-- Returns a BlitBuffer, or nil on any failure (the caller then falls back to the
-- saved working-resolution decode, which is always correct, just softer).
function Image.renderRegion(doc, pageno, nx, ny, nw, nh, tw, th, planes, bg)
    if not Mupdf or not doc then
        return nil
    end
    if not (nx and ny and nw and nh) or nw < 1 or nh < 1 then
        return nil
    end
    if (tw ~= nil and tw < 1) or (th ~= nil and th < 1) then
        return nil
    end
    local ok_page, page = pcall(doc.openPage, doc, pageno)
    if not ok_page or not page then
        logger.dbg("Meguru: region render openPage failed:", tostring(page))
        return nil
    end
    local bb
    local ok_size, pw, ph = pcall(page.getSize, page, DrawContext.new())
    if ok_size and pw and ph and pw > 0 and ph > 0 then
        local fw = math.max(1, math.floor(pw + 0.5))
        local fh = math.max(1, math.floor(ph + 0.5))
        -- The caller's space, rederived exactly as the decode derived it.
        local budget = Settings.get("max_native_pixels")
        local space_w = cappedDim(fw, fh, budget)
        if space_w and space_w > 0 then
            local f = fw / space_w -- caller's space -> the MuPDF page's own
            local out_w, out_h = tw, th
            if not (out_w and out_h) then
                out_w = math.max(1, math.floor(nw * f + 0.5))
                out_h = math.max(1, math.floor(nh * f + 0.5))
                out_w, out_h = cappedDim(out_w, out_h, budget)
            end
            local zoom = out_w / (nw * f)
            if zoom > 0 then
                local dc = DrawContext.new()
                dc:setZoom(zoom)
                local ox = math.floor(zoom * nx * f + 0.5)
                local oy = math.floor(zoom * ny * f + 0.5)
                local ok_draw, rendered = pcall(page.draw_new, page, dc, out_w, out_h, ox, oy)
                if ok_draw and rendered then
                    bb = rendered
                    if planes then
                        -- Guarded like everything else on this path: a mask that
                        -- raises must cost the crop and not the panel, and the
                        -- unmasked tile is still the region the reader pressed.
                        local ok_mask, err = pcall(maskToQuad,
                            bb, planes, bg, nx, ny, nw, nh, out_w, out_h)
                        if not ok_mask then
                            logger.warn("Meguru: panel crop mask failed:", tostring(err))
                        end
                    end
                else
                    logger.dbg("Meguru: region render failed:", tostring(rendered))
                end
            end
        end
    else
        logger.dbg("Meguru: region page size lookup failed")
    end
    page:close()
    return bb
end

-- Cut a rendered tile down to a panel's own quadrilateral.
--
-- The render can only produce a rectangle — `page:draw_new` is handed a pixmap
-- box and MuPDF clips to it — but a panel's borders are not always axis-aligned,
-- so the region asked for is the quad's *bounding* rectangle and what lies
-- outside the quad is painted over here. **What lies outside is the panel next
-- door along the slant**, which is the whole reason this exists: a crop that
-- cannot follow a tilted border shows the reader a wedge of its neighbour. On a
-- page whose panels are square the box and the panel are the same thing and
-- nothing is painted.
--
-- `planes` are four half-planes in the caller's coordinate space — the space
-- `nx, ny, nw, nh` live in — each `{ A, B, C }` meaning "inside is
-- `A*x + B*y + C <= 0`", which is the shape `meguru/panel` builds a panel's crop
-- from. Substituting `x = nx + tx * nw / tw` and `y = ny + ty * nh / th` turns
-- each of them into one in `tx`/`ty`, so no per-pixel transform is needed and
-- the tile is walked by row.
--
-- **Rows are painted in runs**, because a panel with straight sides has the same
-- span on every row: the common case is two `paintRect` calls for the whole tile
-- and only a slanted edge pays per row. A run is flushed when its span changes,
-- and a row that is entirely inside paints nothing at all.
--
-- `bg` is the page's own estimated background, 0-255, and is the only honest
-- thing to put outside the panel — it is the paper the ink predicate already
-- decided on, and on a white-on-black page it is dark.
local function maskToQuad(bb, planes, bg, nx, ny, nw, nh, tw, th)
    if not (planes and #planes > 0) or tw < 1 or th < 1 then
        return
    end
    local EPS = 1e-9
    local mapped = {}
    for i = 1, #planes do
        local plane = planes[i]
        mapped[i] = {
            A = plane.A * nw / tw,
            B = plane.B * nh / th,
            C = plane.A * nx + plane.B * ny + plane.C,
        }
    end
    local color = Blitbuffer.Color8(bg or 255)

    local run_lo, run_hi, run_from
    local function flush(upto)
        if not run_lo or upto <= run_from then
            return
        end
        local rows = upto - run_from
        if run_hi < run_lo then
            bb:paintRect(0, run_from, tw, rows, color)
            return
        end
        if run_lo > 0 then
            bb:paintRect(0, run_from, run_lo, rows, color)
        end
        if run_hi < tw - 1 then
            bb:paintRect(run_hi + 1, run_from, tw - run_hi - 1, rows, color)
        end
    end

    for ty = 0, th - 1 do
        local lo, hi = 0, tw - 1
        local yc = ty + 0.5
        for i = 1, #mapped do
            local plane = mapped[i]
            local v = plane.B * yc + plane.C
            if plane.A > EPS then
                -- A*(tx + 0.5) + v <= 0, so the largest tx inside is this.
                local cand = math.floor(-v / plane.A - 0.5)
                if cand < hi then
                    hi = cand
                end
            elseif plane.A < -EPS then
                local cand = math.ceil(-v / plane.A - 0.5)
                if cand > lo then
                    lo = cand
                end
            elseif v > 0 then
                lo, hi = tw, -1 -- the whole row is outside this half-plane
                break
            end
        end
        if lo < 0 then lo = 0 end
        if hi > tw - 1 then hi = tw - 1 end
        if lo ~= run_lo or hi ~= run_hi then
            flush(ty)
            run_lo, run_hi, run_from = lo, hi, ty
        end
    end
    flush(th)
end

-- A cheap per-pixel luminance accessor over a BlitBuffer's raw bytes.
--
-- This is the bottom of every scan that asks a question about a page's *pixels*
-- rather than about its geometry: the auto content-box pass, its native
-- refinement, and the panel gutter scan. It lives here, beside the decoder,
-- because it is the one answer to "what is this buffer's byte layout" — it used
-- to live in `document.lua`, which left the panel segmenter unable to read a
-- buffer without importing a document.
--
-- Returns `{ w, h, luma(y, x) }`, or nil for anything it cannot read: a
-- degenerate size, a pixel type this module has no bytes-per-pixel for, or a
-- buffer whose byte count does not cover the stride it reports.
--
-- `luma` returns 0-255 in every case, because the three pixel shapes it handles
-- are reduced to one number here rather than by each caller: BB8 is already the
-- value; BB8A takes the *darker* of its two channels (the alpha channel of a
-- PNG is not a brightness, and taking the minimum keeps a translucent white
-- from reading as content); RGB takes the **Rec.601 luminance**, which is the
-- conversion KOReader itself runs into a BB8 target — see the note at that
-- branch, because the obvious alternative is a different function by up to 65.
-- `getInverse()` is
-- honoured, so an inverted buffer reads as what the reader sees rather than as
-- what the file stores — that is what makes an inverted (white-on-black) page
-- scan the same way as a normal one, and it is why the panel detector no longer
-- has to give up on a dark page entirely.
--
-- The closure reads through `data:byte`, so the whole buffer is copied into a
-- Lua string once per call to this function. That is deliberate: the scan runs
-- tens of thousands of reads, and one copy beats one ffi cast per read.
local function rasterFor(bb)
    if not (bb and bb.getWidth and bb.getHeight) then
        return nil
    end
    local w = bb:getWidth()
    local h = bb:getHeight()
    if not w or not h or w < 2 or h < 2 then
        return nil
    end
    local bpp = bbBytesPerPixel(bb:getType())
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
            -- **Rec.601 luminance, and not the mean of the three channels.**
            -- This is the conversion KOReader runs whenever an RGB source lands
            -- in a BB8 target — `RGB_To_A`, `base/blitbuffer.c` — which is what
            -- a colour page became here for as long as this document decoded
            -- greyscale, and what `toGreyscale` still does in the reference
            -- panel detector's ink map.
            --
            -- The mean is a *different function*, and the two disagree by up to
            -- 65 — more than the 40 the panel detector calls ink. The family
            -- they disagree on is light-and-slightly-tinted (lavender, cream,
            -- pale yellow): `(255,150,255)` is 193 here and 220 there, ink by
            -- one measure and background by the other. That matters because
            -- "background" is what a gutter is made of, so the mean silently
            -- invents gutters across a pale band between two darker panels.
            --
            -- Everything that reads this raster — the panel detector's ink map,
            -- the auto-crop, the page-number strip, the blank-page test — was
            -- calibrated against the luminance, because before this document
            -- could decode in colour there was no other answer to give.
            --
            -- A double holds `255 * 16385` exactly, so no intermediate here
            -- loses precision under Lua 5.1.
            local r = data:byte(off + 1)
            local g = data:byte(off + 2)
            local b = data:byte(off + 3)
            lum = math.floor((4898 * r + 9618 * g + 1869 * b) / 16384)
        end
        if inv then
            lum = 255 - lum
        end
        return lum
    end
    return { w = w, h = h, luma = luma }
end
Image.rasterFor = rasterFor

Image.DECODE_TOO_LARGE = DECODE_TOO_LARGE
-- Exported because document.lua logs it: the line that explains why a lossless
-- page is being skipped quotes the limit, and it had no way to reach it. It
-- named the local directly, which resolves to a global reading nil, so the
-- arithmetic on it raised instead of explaining anything.
Image.MAX_LOSSLESS_NATIVE_PIXELS = MAX_LOSSLESS_NATIVE_PIXELS
Image.bytesPerPixel = bbBytesPerPixel
-- document.lua opens a one-page MuPDF document for a streamed page's bytes
-- itself, and `openDocumentFromText` needs the sniffed type; the sniffer lives
-- here so there is one answer to "what is this page".
Image.magicFor = documentMagic
Image.renderMupdfPage = renderMuPDFPage
Image.decode = decodeNative

return Image
