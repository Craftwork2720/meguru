--[[--
The artwork on the "Meguru this series" row.

A browser that draws covers draws one for every row of a feed, and this row has
none to draw: it is not a book, so no feed publishes artwork for it. Left alone
it renders as the browser's empty placeholder — the same grey box a book gets
when its cover fails to load, which is the one thing this row must not look
like. It is the row that says "Meguru" and it has to say so at a glance.

So the plugin ships one small file and this module hands it over. **The file is
optional**: a build without it answers nil and the browser draws exactly what it
drew before. That is deliberate, and it is what keeps this module from being the
thing that breaks a plain install.

**A bitmap, and never a URL.** The field a cover-drawing browser fetches is a
URL, and handing it one would put an HTTP request on the row — on a page that is
already making one request per book for its cover. `cover_bb` is a bitmap that
has already been decoded, so the row costs the network nothing.

**Decoded once per process, and shared by every build of the row.** The row is
rebuilt on every navigation, and a BlitBuffer is malloc'd outside the Lua heap,
so decoding per row would leak one buffer per browse. One buffer is held here
for the life of the process. It is never given away as disposable: the browser
is told `image_disposable = false`, so the widget does not free it, and nothing
else holds a reference to free it either.

**Handed over as authored, and the widget is left to do what it does.** That
sounds like it needs no saying, and it did: an earlier version of this module
pre-inverted the bitmap in night mode, because the row had been reported from a
device as arriving like a negative. It had not — the reader was describing the
browser's own *selection highlight*, which inverts whatever row is focused, and
the artwork was right in both modes. So the fix was written against a symptom
that was never observed, and this is the note that stops it being written again.

What is *checked*, and what is not, because the difference decides whether
removing it was right:

- **Checked** — `ImageWidget` inverts a bitmap itself in night mode, gated on
  `original_in_nightmode`, which is `true` by default and set to `false` in
  exactly one place in KOReader (`frontend/ui/widget/imagewidget.lua`,
  `pagebrowserwidget.lua`). If the widget this row is drawn into is built with
  that default left alone, pre-inverting here **cancels it** and produces the
  negative it was written to prevent.
- **Not checked** — how that widget is actually built. It is not stock: the
  fields this row fills (`cover_bb`) and the function that builds it
  (`build_cover_widget`) live in **zen-os's** `opds.lua`, not in
  `plugins/opds.koplugin/opdsbrowser.lua`, and that plugin is not in this
  repository. If it sets `original_in_nightmode = false`, the stock default does
  not apply and the case above does not hold.

So the honest statement is: the inversion was removed because nothing justified
it, not because it was proven wrong. **A device check settles it** — night mode
on, this row on screen: the artwork should read as authored. If it arrives as a
negative, the widget is being built with that flag off and the inversion belongs
back, with that observation beside it instead of a report of a highlight.

A failure to decode is not fatal and is not retried — it is logged once, and the
row falls back to the browser's placeholder. Retrying would mean a file read and
a decode inside every menu build, for a picture that is not going to change.
--]]

local logger = require("logger")

local FS = require("meguru/fs")
local Paths = require("meguru/paths")

local RowCover = {}

--- The file this looks for, under the plugin's `assets/`.
---
--- Author it portrait, at zen-os's default cover ratio (2:3 — a `uniform_cover_ratio`
--- setting), which is the shape both of its display modes fit a cover into. Any
--- size works: it is decoded at its own size and the widget scales it to the
--- slot, so a larger file costs nothing but bytes on disk.
RowCover.FILE = "meguru-this-series.png"

--- The decoded bitmap, or false once we have looked and found nothing usable.
--- False rather than nil so that "looked, and there is none" is remembered
--- differently from "not looked yet".
local cached

--- The row's own artwork as a BlitBuffer, or nil when there is none to draw.
function RowCover.bitmap()
    if cached == nil then
        cached = false

        local path = Paths.asset(RowCover.FILE)
        if not path or not FS.exists(path) then
            -- Once, at `info`: a missing file is a state somebody has to be able
            -- to see, and it is the answer to "why has this row no cover". Not a
            -- `warn` — the plugin works, and shipping no artwork is allowed.
            logger.info("Meguru: no row artwork at", path or RowCover.FILE,
                "- the series row uses the browser's placeholder")
            return nil
        end

        local ok, bb = pcall(function()
            -- Lazy: this pulls in the image backends, and none of it is needed
            -- until a file has actually been found.
            local RenderImage = require("ui/renderimage")
            return RenderImage:renderImageFile(path)
        end)
        -- Two messages rather than one, and spelled out rather than folded into
        -- an `and`/`or`: `ok and nil or bb` reads as "the error, or nothing" and
        -- evaluates to `bb` in both cases, which is the trap worth not writing.
        if not ok then
            logger.warn("Meguru: could not decode the row artwork at", path, "-", bb)
            return nil
        end
        if not bb then
            logger.warn("Meguru: the row artwork at", path, "decoded to nothing")
            return nil
        end

        cached = bb
    end

    if not cached then
        return nil
    end

    -- Returned as authored. `ImageWidget` handles night mode itself — see the
    -- module docblock for the inversion that was written here and removed.
    return cached
end

return RowCover
