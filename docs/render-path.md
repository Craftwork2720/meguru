# The render path

How a page is decoded, painted and cached; the four log lines that make the path decidable from a device log; and what a page that could not be loaded says.

Part of the design record; [CLAUDE.md](../CLAUDE.md) is the map.

## The render path

**A page is grayscale on a grayscale screen and colour on a colour one, and the
answer is the reader's own setting.** `Image.colorEnabled()` asks
`device.screen:isColorEnabled()` — stock KOReader's own answer, the same source
`CanvasContext` reads to set `is_color_rendering_enabled`
(`canvascontext.lua:53`) — and the three places that decode a page through MuPDF
set `doc.color` from it rather than forcing `false`. **It is asked at decode time
and never cached**, because that function is live: it reads
`G_reader_settings.color_rendering` (the reader's stock colour toggle) and falls
back to what the screen can do (`device.lua:264-270`). A cached answer would make
that toggle inert until a restart.

The distinction is not cosmetic and it is not new behaviour on e-ink: on a Kindle
`color_rendering` is unset and the screen reports no colour, so the predicate is
`false` and the grayscale path is **exactly what it always was**. What the change
fixes is a colour framebuffer, where the plugin used to decode colour away and a
reader had no way to tell why.

**The predicate has a second condition, and it is not about what the reader
asked for but about what survives the blit.** `screen:isColorEnabled()` alone
says only that colour is *wanted*; `BB_blit_to` dispatches on the **target's**
type (`base/blitbuffer.c`), and an RGB source landing in an 8bpp target runs
`RGB_To_A` — luminosity, colour discarded, irreversibly. So
`Image.colorEnabled()` also requires `screen.fb_bpp ~= 8`, which is the depth
KOReader read from the kernel. `nil` is not 8: a desktop build never sets the
field, and a desktop is where colour most obviously works.

**Colour here is only ever as good as KOReader's road to the panel, and that road
is Kobo-only — which is why a Kindle Colorsoft will stay grayscale.** The
Colorsoft is recognised and sets `hasColorScreen = yes` (`kindle/device.lua`),
and that is *all* it sets: no `hasKaleidoWfm` (assigned only in
`kobo/device.lua`), no colour waveform modes and no CFA flag (both Kobo-only
branches of `framebuffer_mxcfb.lua`, and `ffi/mxcfb_kindle_h.lua` has no CFA
constants at all), and no equivalent of the Kobo launcher's `fbdepth` call that
forces a 32-bpp framebuffer. `mtk-kobo.h` states the consequence plainly: without
CFA processing the controller renders the panel black and white. **There is no
clean test for that case in Lua** — `hasKaleidoWfm`, the flag KOReader's own
colour-UI gate uses, is false on a Colorsoft *and* on a desktop, so it cannot
tell them apart — so this refuses only what it can prove and leaves the rest
alone, where the cost is bounded by what stock already pays: `is_color_capable`
gives stock's own tiles RGB32 on the same device.

**Where to check which branch a device took: the `init` log line**, which prints
`fb_bpp` beside the branch it chose. "Is there colour here" is a question for the
log, not for the code.

**On the grayscale branch a decoded page is 8bpp and the dither is still forced
on.** Both halves are one story, and the second half is a decision with a cost —
recorded here so it is not "corrected" a third time without knowing what it is.
`Mupdf.openDocumentFromText` never sets `doc.color` and `draw_new` allocates BB8
whenever the field is falsy, so a page that *is* decoded grayscale ends up BB8 —
not the RGB24 an earlier comment here and in `meguru/doc/image` claimed. That
mattered because the false premise was the whole justification for forcing
`sw_dithering = true` and calling `ditherblitFrom` with no branch: a *converting*
blit is what dithering is for, and ours is a same-format copy. On a BB8
destination `ditherblitFrom` runs `dither_o8x8` (blitbuffer.c), which quantises a
full 8-bit page to **16 levels on a fixed 8x8 pattern** — a burnt-in dot grid and
four bits of tone gone, on every pixel of every page.

Reading the flag from `Screen.sw_dithering` — `framebuffer.lua`'s `setupDithering`
answer — would be the more defensible arrangement *there*, and it is **not** what
this does: `init` sets `self.sw_dithering = true` on that branch by decision. The
dithered look is what these pages have always had here. On a device whose
controller dithers properly, this re-quantises a page the hardware was about to
dither correctly. `Screen.sw_dithering` is the answer it would take back. The
`if self.sw_dithering` branch in `drawPage`/`drawPageInverted` must stay: it is the
whole switch, and the colour branch reaches it as `false`.

**On the colour branch the flag is `Screen.sw_dithering`, and the argument above
does not apply** — it is about a same-format grayscale copy, and there the tiles
are RGB and the destination is RGB. `init` logs which branch it took, once, and
that line is the only place a log says whether colour is on.

**What colour costs is memory, and it is the one number this change does not
touch.** `max_native_pixels` counts **pixels, not bytes** — `cappedDim` has no
bytes-per-pixel factor — so 4 Mpx is ~4 MB retained as BB8 and ~12 MB as RGB24,
and with `max_cached_native` at three that is ~36 MB rather than ~12. Kept
pixel-based deliberately, so sharpness is unchanged and the price is paid only
where colour exists. Everything else on the render path was already
format-tolerant and needed no change: `bbBytesPerPixel` knows all four types,
**`rasterFor` collapses RGB to its Rec.601 luminance** — and the first version of
this paragraph said it collapsed it to *the mean of three channels*, claiming the
panel detector, the auto-crop and the blank check would then "read the same
luminance they always did". **They would not, and that sentence is what let the
bug through.** The mean is a different function from the luminance, and the two
disagree by up to **65** — more than the 40 the panel detector calls ink. The
family they disagree on is precisely *light and slightly tinted*: lavender
`(255,150,255)` is 193 by luminance and 220 by mean, i.e. ink by one measure and
background by the other, and "background" is what a gutter is made of. So on a
colour screen the mean silently invented a gutter across a pale band between two
darker panels, and the panel sequence gained a panel that was really the gap. It
was found on a page of exactly that shape, and by comparison against the
reference plugin, whose ink map is grayscale-only and so always read a luminance.

The luminance is the right answer for four independent reasons, which is why it
is not a preference: it is the conversion KOReader itself runs when an RGB source
lands in a BB8 target (`RGB_To_A`, `base/blitbuffer.c`); it is what this document
produced for as long as it decoded grayscale, so every reader of the raster —
the panel detector, the auto-crop, the page-number strip, the blank test — was
calibrated against it; it is what the reference panel detector's
`toGreyscale` produces; and it is what the newer reference calls `luminance`
explicitly. The formula appears in three places (`Image.rasterFor` and twice in
`doc/document.lua`'s crop scan) and they must move together — a fourth copy that
kept the mean would reintroduce exactly this, one consumer at a time.

`decodeRegion` builds its tiles in the source's own type, and
`decodeNativeRenderImage` was already colour — which is how a fallback and a
primary could disagree about colour before this.

The night-mode invert stays on the *destination* (`target:invertRect`) rather than
`invertblitFrom` on the tile. With grayscale tiles the latter would be legal and
with colour tiles it would throw, which is exactly why this shape was chosen: the
destination route cannot be affected by the tile's format at all, and an
"incompatible bb" throw out of blitbuffer.c lands mid-paint.

**A painted tile is rendered from the page's own bytes whenever it would otherwise
be magnified — one render, at the size the screen asked for.** `renderPage` chooses
between two paths on a single test, `tw > cw or th > ch`: whether the tile wants
more pixels than the region it covers holds.

- **Above it**, `renderRegionDirect` renders the region in **one pass** at exactly
  `tw x th`, straight from the source (`Image.renderRegion`). The crop is expressed
  by putting the region's own start at MuPDF's device-space window origin —
  `draw_new(dc, tw, th, ox, oy)` builds a CTM of `scale(dc.zoom)` and a pixmap
  rooted at the *device* point `(ox, oy)`, so `ox = zoom * nx` makes the window and
  the region coincide. `dc.offset_*` must stay zero; it is a second, independent
  translation.
- **Below it**, the tile is a slice-and-scale of the saved working decode
  (`decodeRegion`), unchanged.

The old shape was the second path for *every* paint, and that is what made a page
narrower than the screen look soft: a 960x1378 page on a ~1236-px screen is
*always* an upscale, and there every painted pixel was a resample of a buffer that
was itself a resample — the working decode — rather than of the file. Stock
KOReader never does this, which is what "MuPDF renders it well" means:
`Document:renderPage` renders the requested rect at the full zoom in one call, and
that is the shape `renderRegionDirect` restores. Below the threshold the saved
decode holds more pixels than the tile needs, so a downscale invents nothing, and a
slice of a cached buffer is far cheaper than a second open-and-render — which
matters because a tile miss is a pan or a zoom step as often as a page turn.

**The threshold is about the paint, not the page, and the two are not the same
test.** A page that is downscaled as a whole takes the slice-and-scale path at
fit-to-screen, but a paint that magnifies *part* of it (a zoom past 1, a panel, a
crop box) crosses back over and goes direct, on a page whose whole-page cost is
still that of a shrunk page. Nothing in the predicate is a statement about the
page, and reading it as one is how "large pages use the old engine" comes to be
true only while nobody zooms.

**For a page being shrunk, what a paint costs is set by the decode budget, not by
the path.** The retained decode is what `decodeRegion` slices and what every
analysis reads — the margin scan (`autoContentBox`), the page-number strip, the
blank check — so `max_native_pixels` (`meguru/settings`) is the per-page cost of a
large page, paid on every turn whatever the reader does. `db39a93` replaced an
earlier long-edge cap with an area budget, correctly, because a long-edge cap
punished a tall strip without measure. The default is **4 Mpx**; pages at or under
it — every page that fits a screen — come back at natural size and are untouched,
so the direct render above still works from real pixels where it matters.

`Image.renderRegion` rederives the coordinate space rather than taking it. Its
`nx, ny, nw, nh` arrive in the space `self.dims` lives in, which for an oversized
page is the *capped* size — smaller than MuPDF's own page. It recomputes the factor
between them with the same `cappedDim` the decode used, so the two cannot drift:
were they to, the crop would land on a different part of the page, silently and by
however much the cap had moved.

**Panel zoom is its third caller, and asks for a size the other two do not.**
`Image.renderRegion`'s `tw`/`th` are the buffer to produce; leaving both out asks
for **the region's own size in page pixels**, bounded by `max_native_pixels`. A
paint always knows the rectangle it is painting to and wants exactly that many
pixels, so it always passes a size — but the ImageViewer magnifies what it is
given, so the size it should be given is the region's own. Stock's
`Document:drawPagePart` picks `zoom = min(canvas / rect)` — the largest zoom that
still fits the panel on screen — so the tile arrives screen-sized, which for a
document behind an engine is the right trade. A streamed page is a *bitmap*: a
panel bigger than the screen reached the reader already reduced to the screen's
pixels, so magnifying it in the viewer was magnifying a resample of the file. Now
it is a crop of it, and pinching in reaches 1:1 with the page rather than 1:1 with
the screen. **A panel smaller than the screen comes back smaller than it used to**
and is upscaled by the viewer instead of by MuPDF — the same pixels either way,
which is why the change is invisible on them, and worth knowing before anyone
"fixes" the size back.

**It is also the one caller whose region is not a rectangle.** A panel's borders
are lines and are slanted wherever the artwork is, so `nw`/`nh` are the
quadrilateral's *bounding* box and `planes` — a panel's four edges — says where
inside it the panel actually runs. `maskToQuad` paints over everything outside,
which is the panel next door along the slant; on a page whose panels are square
nothing is painted at all. It lives **inside `renderRegion`** rather than at the
call site so that the buffer the tile LRU keeps is already the panel: every reader
of a cached tile gets the crop, and none of them has to know the shape exists. It
walks the tile by row and paints in *runs*, so a panel with straight sides costs
two `paintRect` calls for the whole tile and only a slanted edge pays per row.
Guarded like everything else on the path — a mask that raises costs the crop and
not the panel.

**What it paints is white, and that is a decision rather than a default.** The
obvious candidate is the page's own background, and it was the first thing tried;
it is the median luminance of the page's **outer ring** (`backgroundFor`), and it
is measurably wrong on exactly the pages a panel crop is for — the ones whose
artwork bleeds to the edges, where the ring is black and the paper is not. On one
chapter of the reported series it returns **46, 70, 137, 154 and 169 on five pages
whose paper is 254**, so masking to it puts a block of near-black beside a white
page. A crop is a panel shown on its own and what is outside a panel is paper, so
the answer is the constant and the estimate is not carried at all: `panel.bg` was
plumbed from `Panel.detect` through `drawPagePart` and `renderRegionDirect` for
one commit and is gone.

One thing it does not reach, and it is the same soft degradation as below: the
tile is masked, the **fallback** is not. When the page's bytes have aged out of
the store, `drawPagePart` hands the gesture to stock's `Document:drawPagePart`,
which cuts the panel out of the saved working decode with a rectangle — so an
offline long-press on a page with tilted panels shows the neighbour's wedge
again, softer. Painting it there would mean masking stock's buffer in place,
which is stock's document and not ours to write on.

Two things about it are load-bearing and not tidiness. The tile goes through this
document's own LRU: the viewer is handed `image_disposable = false` and never frees
what it is given, so a buffer rendered outside `cacheTile` would be lost —
BlitBuffers are malloc'd outside the Lua heap. And when there is no source to
render from, it falls back to stock's screen-fit shape rather than to nothing: a
long-press that does nothing is a worse failure than a softer panel.

`decodeRegion` stays, and stays first-class: it is still the only path for
`_meguruAnalysisBB`, where a strip wants a cut of a page *already decoded* and must
not pay a fresh open and render per strip.

`_regionSource` opens a streamed page's one-page document **from the byte LRU and
only from it** — `readCachedPage`, never `fetchPage`. A fetch here would be a
synchronous HTTP GET inside a paint, the exact thing `hasNative` exists to keep out
of the render path. A miss falls through to `decodeRegion`, so the failure costs
quality and never a stalled screen.

That document holds **one page, numbered 1** — not the book's page number. It is
opened from the single page's bytes, so `openPage(book_pageno)` throws for
everything past the first page, and the throw is caught. Passing the book's number
is what made the entire direct path a silent fallback for every streamed book on
the first device run, while the local-cbz case — the one place the two numbers
coincide — was the only one that could ever have worked. Hence the rule for
anything reaching a streamed page through a fresh document: **the page number is 1,
and the page is identified by the bytes, never by a number.**

That failure is also why `renderRegionDirect` returns a *reason* alongside its nil,
and why `renderPage`'s paint line prints it. A caught throw that silently degrades
to a slower path is survivable and invisible at the same time; the two must not both
be true, so the reason travels (`[direct failed: no bytes cached]`) rather than
being logged at a level nobody is reading.

### Log lines

Four lines make the render path decidable from a device log. **All four are at
`dbg`, and were at `info` for as long as they were being used** — a line that fires
once per page or per paint is worth reading while the render path is under a
microscope and is noise afterwards, and `-d` is what brings them back:

- `Meguru: page N prepared in X ms, fetch F ms (decode D ms, WxH)` — what a page
  turn waited for, split into the two costs with different fixes: the fetch is the
  server's and the only one a reader cannot tune; the decode is
  `max_native_pixels`. The fetch field sits *outside* the parentheses and is absent
  entirely for a local cbz page (which would read as instant at 0). F + D adds up to
  X by construction — the line is logged before the `collectgarbage` that follows
  the decode, precisely so it keeps meaning fetch-plus-decode.
- `Meguru: page N paint via direct|scale in X ms (zoom, page, region, tile)` — one
  per *rendered* tile, not per repaint, because a tile-cache hit returns before it.
  Which is why it is also the line that says whether a given paint crossed the
  threshold, with the numbers the predicate compared — and the millisecond count is
  what `direct` costs against `scale` on that device.
- `Meguru: MuPDF page render WxH -> WxH (budget N px)` — whether the decode budget
  bit on this page at all, which is the only way to check a hand-edited
  `meguru_max_native_pixels` took effect (no menu writes it, and a stored value wins
  over the default).
- `Meguru: panel zoom on page N, region X,Y+WxH tilt T rendered WxH` — one per
  long-press, and the only line that says what the viewer was actually handed. The
  first pair is the region in the space `self.dims` lives in and the second is what
  came back, so a panel rendered *smaller* than its region is the budget having
  bitten and a panel rendered smaller than the screen is the ordinary case, not a
  fault. **`tilt` is the steepest of the crop's four edges, and it is the one number
  that says whether the region printed here is the panel or only its bounding
  box** — a panel with square sides has every edge at 0 and the two are the same
  rectangle. It is the fourth of these lines; a fourth `dbg` line is not a drift in
  the rule below, because a long-press is a gesture rather than a page turn.

The millisecond fields come from `ffi/util`'s `gettime` and not `os.clock`, which is
CPU time and would miss the network wait — the one cost a reader cannot do anything
about — entirely.

**What stays at `info` and `warn` is the other half of the rule.** A line goes to
`dbg` when it fires on the *normal* path and repeats — per page, per paint, per
decode: the render-path lines above, the whole of the crop and page-number analysis
(`crop skip`, `no page number`, `mostly blank`), and the `hooked …` notes `hook.lua`
writes once at load. It stays at `info`/`warn` when it marks a **decision, a refusal
or a failure** — every fetch and decode failure, every refused open, every "the feed
has nothing to say" — because that is the line someone reads a `crash.log` for, and
it is usually the only trace of it.

The one that was argued the other way and lost is `crop skip`. It was `warn` on the
grounds that the symptom is reader-visible so the line should be too, which is a
good argument about *importance* and a bad one about *frequency*: a book whose pages
are full-bleed has no light border to find on any of them, so it fires once per page
for the whole book and buries the warnings that are rare. Frequency wins.

### A page that could not be loaded

There are four ways to have no page — no connection, a server that never answered, a
server that answered 404, a page that arrived and would not decode — and each one
says so in the place the page would be.

- **No socket is opened without a connection.** `MeguruDocument:hasConnection` gates
  `fetchPage` and `getCoverPageImage`. It is a *device* state, not a probe: Wi-Fi
  off can only fail, and on some backends it fails only after sitting through the
  socket timeout with the UI thread blocked. It says nothing about a server that is
  down with Wi-Fi up — that is the case the timeout and the memo below are for. The
  cover path matters most here: browsing a folder of `.meguru` files is one request
  per book, made while the FileManager waits to draw its mosaic.
- **A failed fetch is remembered, and not attempted again until something clears
  it.** `self.fetch_failed[pageno]` holds `{ reason, code }`. This is not tidiness:
  `ReaderView:drawSinglePage` reaches `document:drawPage` on *every* repaint, so a
  page that failed once paid a socket timeout — and logged a line — on every menu
  opening, zoom step and crop toggle, against a server that had already said no.
  `clearFetchFailures` is the whole of the retry story, and exactly two things call
  it: a page turn (`plugin.onPageUpdate`, which is the reader asking for a page
  again) and the connection coming back (`plugin.onNetworkConnected`, which also
  repaints if anything had failed — the event fires once at startup too, hence the
  return value). A **page turn is the retry**; there is no button, and no dialog.
- **The page is replaced by a sentence that names the reason.** The document paints
  the box and passes the `fetch_failed` entry to `self.missing_painter`, installed by
  `ui/reader.lua` — the wording, the font and the layout live there, so a document
  with no reader in front of it (the mosaic's cover path) still gets its plain box.
  One sentence per reason, because the fixes differ: connecting Wi-Fi does nothing
  about a 404, and waiting does nothing about Wi-Fi that is off. It is *in the page*
  rather than over it, which is what a browser does and what needs no dismissing —
  the reader can carry on turning pages.

**There was a drawing here — Meguru-chan lying across a big "404" — and it was
removed deliberately.** The reason is the one thing a picture cannot carry, and the
picture's own claim was wrong: a 404 is the internet's shorthand for "broken page",
and in Meguru's four cases it is literally right in exactly one (the server answered
404) and wrong for the two commonest, which never had an HTTP status to show at all.
An error page whose headline is the wrong error is worse than a line of prose. The
asset was deleted with the code that drew it.

`paintMissingPage` no longer logs. It runs on every repaint of a broken page, and
the failure was already logged once where it happened (`fetchPage`,
`ensureNativeBB`) — the same frequency argument that moved `crop skip`.

