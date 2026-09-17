# meguru

A KOReader plugin that turns OPDS-PSE page streams (Kavita, Suwayomi) into
ordinary KOReader "books". Each book is a small on-disk **marker** file; the
pages come off the network one at a time as they are read.

This is a from-scratch successor to `meguru.koplugin`, which lives beside it and
**is not to be modified**. The old plugin remains the reference for behaviour and
the fallback if this one misbehaves. There is no compatibility between the two:
different marker extension, different descriptor, different data. Orphaned
reading progress from the old plugin is accepted and intended.

**A marker carries what identifies its series, and the feed is asked for
everything else.** The old plugin copied the sibling list, the volume order and
the titles into every `.mgru`; a version of this one kept all of that in a local
SQLite catalog. Both are gone, and the reasoning is one sentence: a copy is
written once and never repaired, so it answers with the series as it was, for as
long as the file exists. The catalog fixed staleness by being authoritative and
paid for it with a whole subsystem — a schema, migrations, transactions, a sync
engine, a background walker — to maintain a materialised view of feeds that can
just be re-read. What is left is the smallest thing that works: the identity in
the file, the feed for everything else. "What comes next" is answered by walking
that feed **when the reader asks**, in a gesture that asked for it.

Wire-format findings, captured from live servers, are in [PROTOCOL.md](PROTOCOL.md).
Where that document and an assumption disagree, the observation wins.

## Environment

These are fixed and shape most of the design:

- **Lua 5.1 / LuaJIT.** No `//`, no bitwise operators, no `goto`. The device is
  the only place this code runs.
- **No test framework and no linter.** Verification is manual, in a running
  KOReader. `tools/check.py` (see Development) is the automated guard, covering
  eight failure modes.
- **Reuse KOReader's own machinery** rather than rebuilding it: `LuaSettings`,
  `DocSettings`, `DocumentRegistry`, and the built-in `plugins/opds.koplugin` for
  Atom parsing and the browser UI. That plugin is **read only** — wrapped at
  runtime, never edited.
- **Module names are global**, so everything lives under `meguru/`. Always
  `require("meguru/feed")`, never `require("meguru.feed")`: both resolve to the
  same file but occupy two different `package.loaded` keys.
- `require` of `opdsbrowser` / `opdsparser` must be **lazy, at the call site** —
  `pluginloader.lua` only adds plugin directories to `package.path` after the
  plugin itself has loaded.

## Layout

```
_meta.lua                 plugin metadata
main.lua                  plugin class: provider registration, menu dispatch, reader install

meguru/
  paths.lua               every path: markers, and the last-resort folder
  fs.lua                  filesystem predicates, directory creation, one raw write
  settings.lua            plugin-wide preferences in G_reader_settings
  association.lua         Meguru's claim on .cbz: the file-type reader association
  sources.lua             read-only view on settings/opds.lua (catalogs + credentials)
  net.lua                 HTTP GET, feed fetch + parse
  naming.lua              sanitizeComponent / deriveSeries / glyph / identity digest
  local.lua               the series a .cbz's folder and file name imply
  comicinfo.lua           the metadata a .cbz carries about itself
  marker.lua              marker read/write, naming, collision resolution, series context
  credential.lua          what a credential looks like in a URL: redact / restore
  seriescover.lua         the series' artwork, written once into its folder
  rowcover.lua            the "Meguru this series" row's own artwork, decoded once
  pse.lua                 OPDS-PSE: link extraction, template -> URL, page fetch
  feed.lua                reading a series feed: the rel=next walk, identity, order,
                          neighbour
  panel.lua               the panels on a page, and the order they are read in
  viewport.lua            the window over a page, for the panel view that crops nothing
  hook.lua                runtime wraps on OPDSBrowser (sniff, "Meguru this series")
  updater.lua             GitHub releases: check for one, download it, install it

  driver/
    base.lua              driver registry + pure shared helpers
    suwayomi.lua
    kavita.lua
    komga.lua

  doc/
    document.lua          Document subclass: the reading engine
    image.lua             MuPDF decoding with a size cap
    defaults.lua          per-book seeding of kopt_* from plugin preferences

  ui/
    open.lua              "Meguru this series": resume dialog, marker write, open
    reader.lua            everything grafted onto a running ReaderUI
    panelzoom.lua         the panel sequence viewer: nav, pre-warm, page boundary
    menu.lua              the two menu surfaces

assets/
  meguru-this-series.png  optional; the cover drawn on the series row

.github/workflows/release.yml   a tag builds meguru.koplugin.zip and publishes it
```

`assets/meguru-this-series.png` is the one file the plugin ships rather than
writes, and it is **optional** — `meguru/rowcover` answers nil without it and the
browser draws its ordinary placeholder. It is portrait, authored at 2:3 (what
zen-os fits a cover into by default); any size decodes, and a larger one costs
only bytes on disk. The plugin has had artwork before and it was deleted on
purpose — an error-page drawing whose headline named the wrong fault — so the
distinction is worth keeping: this file is the row's *identity*, not a claim
about something that went wrong.

`tools/check.py` is a development aid, not part of the plugin.

Not yet written: `driver/generic.lua` — the `kind = NULL` driver that can
only discover a series by title heuristic and cannot build a canonical
`catalogURL`, so there is no feed to walk for a neighbour. Until `generic.lua`
exists, an unrecognised server is handled by the absence of a driver rather than
by a driver that returns nothing useful.

**Nothing is written to disk but markers** — and one exception, named here
because the sentence above it is the kind that gets quoted: `meguru/seriescover`
leaves a `.cover.jpg` in a series folder, for whatever *outside* KOReader reads
it. It is not a cache and nothing reads it back; KOReader will not display it
either (`coverbrowser` draws a directory as a name and a count, and never looks
for a file beside a document), and the plugin never removes it — turning a server
off in the menu stops new files and leaves what is already written.

**The file's name is not its format, and the three servers disagree** — worth
knowing before someone "fixes" the extension:

| server | where the series artwork comes from | what arrives |
|---|---|---|
| Suwayomi | feed-level image on the chapter list | WebP 400x600 |
| Kavita | feed-level image on the series feed | **WebP** 639x908 |
| Komga | `driver.seriesCover` → REST, because OPDS has none | JPEG 211x300 |

Kavita's *volume* cover is a JPEG and its *series* cover is not — an earlier
version of this document and of `seriescover.lua` got that backwards and used it
to justify a Suwayomi-only rule. Which servers get the file is now the reader's
choice, in ⋮ → Meguru → Settings → `Covers for folders`, one switch per server,
all on by default.

Leaving that aside: there is no page cache, no cover cache and no database.
Pages live in a small RAM LRU, a cover is refetched on every call, and the panel
lists a long-press produces live in a four-entry RAM LRU on the document itself,
so they are dropped with the book.

`meguru.sqlite3` may still be sitting in `settings/` from a version that had one,
and `cache/meguru/pages` and `.../covers` from a version that wrote them. Nothing
reads them and nothing sweeps them; delete them by hand once. `Paths.cacheDir`
itself survives: it is the last-resort folder for a marker when the home folder
is unusable (`Marker.homeDir`).

The dependency graph is a DAG with no cycles and **exactly one lazy edge**:
`feed.lua` requires `meguru/naming` inside `Feed.ordered`, because the ordering is
the one thing both entry points share and an edge at load time would have made it
circular. (`ui/network/manager` is reached the same lazy way by `doc/document`
and `seriescover`, and `ui/renderimage` by `rowcover`, but they are KOReader's
modules, not ours — they are not edges in this graph, and each is deferred for a
reason of its own: the network manager is a *device* state that need not exist
where these modules are loaded, and the image backends are dead weight until a
row's artwork has actually been found on disk.) `ui/panelzoom` requires no `meguru/` module at all — it is handed panels
as arguments, and with them the reading direction and the rotation direction, both
as plain strings: the *domain* of those settings stays in `ui/reader` and the viewer
is told the word. The edges that do exist between the panel modules are `ui/reader` ->
`ui/panelzoom`, `doc/document` -> `panel`, `ui/panelzoom` -> `viewport`, and `panel` ->
`doc/image`. `doc/document`
and `ui/reader` both require `meguru/local` eagerly — it is a module of ours, it
loads nothing expensive, and `ui/menu` reaches it through `ui/reader` rather than
directly so the guard that answers "is this book a local one" exists once. The one
directory listing in the plugin lives there, and it is `util.findFiles`, KOReader's
own — not an edge in this graph, for the reason the network manager is not one
either.

## Series state, and where it lives

**There is no store. A marker and the server's own feed are the whole of it.**

A marker carries twelve fields plus a version: the identity of the book
(`server_name`, `series_remote_id`, `series_name`, `server_kind`, `item_key`),
what opens its stream (`template`, `count`, `last_read`), and what a feed can be
asked for when it is reachable (`lang`, `cover_url`, `series_cover_url`). The
first two groups are enough to open and read the book with no network and no
configuration; the third is enough to build the one URL that describes its series
and to say which translation is being read.

Everything else is asked of the feed, **when the reader asks for it**. That is the
design, not an optimisation, and the reason is in the intro: a copy is written once
and never repaired.

---

**`item_key` is the identity of a book, and there is exactly one function that
derives it.** It is never derived from a whole stream URL, because Kavita's
`stream_template` embeds the API key and Suwayomi's may carry `?token=`, so hashing
a URL would mean a key rotation renamed every book.

| Server | `item_key` |
|---|---|
| Kavita | the `chapterId` query parameter of the stream URL |
| Suwayomi | the chapter's `<id>` URN (`urn:suwayomi:chapter:16851`) |
| Komga | the `bookId` path segment of the stream URL (`…/books/{bookId}/pages/{pageNumber}`) |

Suwayomi's chapter *number* is not an identity: the same chapter shows three
different numbers across title, path and feed, because the path segment is a list
position and the title is renumbered on a metadata refresh. The `<id>` is stable,
and the one trap in it is recorded in PROTOCOL.md — the chapter-list feed and the
chapter's own metadata feed emit different ids for the same chapter
(`…:16851` vs `…:16851:metadata`), so `chapterKeyFromId` strips the suffix. Without
that strip, opening a book would match it against no entry in its own series' feed,
and "next chapter" would answer as though the reader were nowhere.

**A cover belongs to a book *and* to a series, and the marker holds both links.**
`series_cover_url` is the series' artwork; `cover_url` is the book's own, written
only when the feed the marker was built from published one. Kavita's series feed
does, on every entry, so every volume gets its own for nothing. Suwayomi's chapter
list does not — its entries carry only `rel=subsection` — and the chapter's own
artwork lives solely in its metadata feed, one request per chapter, which nothing
spends. So `driver/suwayomi.lua` sets none and its chapters fall back to the series
cover, deliberately.

**Both links go through the same redaction as the stream template, and they are
why that redaction needs two rules rather than one.** Kavita puts its key in the
path of its stream and every feed, but **in the query of its artwork** —
`/api/image/series-cover?seriesId=…&apiKey=…`, with no `/opds/` in it anywhere.
A rule that walked only the path left both cover fields untouched and wrote the
key into markers in plain text; `Credential.redactTemplate` has an `apiKey` rule
now, and PROTOCOL.md carries the evidence. A marker lives in the reader's *book*
folder rather than in `settings/`, so `CREDENTIAL_FIELDS` in `meguru/marker.lua`
lists all three, and a field added to `Marker.new` without being added there is
written to disk with the key in it.

`MeguruDocument:getCoverPageImage` resolves a book as **its own artwork → the
series' → page 1 of its stream**, so a missing item cover is not a missing cover,
it is the next best one, and the last step is the reason a book is never
cover-less. This is the seam the FileManager's mosaic and "Book info" go through,
and it is worth knowing what it costs: **there is no cover cache of any kind**, so
every call fetches over HTTP. Browsing a folder of `.meguru` files is one request
per book. That is deliberate — KOReader's own `BookInfoManager` remembers the
thumbnail it extracts, so a cover already has somewhere else to live, and a store
of our own would have made meguru write one. The last step goes through the page
pipeline, so it also warms the same byte store a page turn does.

A marker written before the two cover fields existed has neither, and falls through
to page 1 — which is what every book got before they were stored.

**Nothing cached is ever filed under a book's name.** That is a rule with a
history, and the history is worth keeping because it is the cheapest way to see why
it must not be undone. Page bytes lived on disk once, named after the marker's
basename; every Suwayomi chapter is titled "Chapter 1" and many Kavita volumes
"Volume 1", so **every such book on every series and every server shared one
file** — the second book to be opened was served the first one's bytes and its
cover alike. `Marker.pathFor`'s collision guard could not catch it: it
disambiguates only within one directory, and same-titled books normally land in
*different* series folders, where it never fires.

What survives of the lesson is `Marker.naturalKey` — `server_name |
series_remote_id | item_key`, never the title and never the template — which is
what `Marker.matches` and `Marker.pathFor` compare, and `Naming.digest64` is what a
marker with **no catalog series** hashes its stream URL into. The two hashes differ
in what a collision costs, which is why they differ in width: `Naming.keySuffix`'s
32 bits disambiguate a series folder *name*, while `digest64`'s two lanes carry a
marker's whole identity, where a collision collapses two unrelated books onto one
file. Lua 5.1 constrains the shape: every double intermediate must stay exact,
which rules out FNV-1a's `h * 16777619` (~2^56) and forces the two polynomials
(`*33`, `*65599`) that do.

**Page bytes live in the document, keyed by page number alone.** `self.page_bytes`
is a four-entry array, most-recent-first. A bare page number is unambiguous only
because exactly one document can reach the store: `self.file` is fixed and
`self.desc` is assigned once, so one instance never serves two books. **It must not
be made shared again** — a process-wide store would need the book's identity back
in the key, which is the whole apparatus this removed.

Its lifetime is the document's: `clearCaches` empties it on close. Two entries are
the floor — the page being rendered, plus the one `hintPage` warms ahead of it —
and the rest is room for ReaderHinting to ask two ahead. The number is not a memory
figure: these are the *compressed* bytes, orders of magnitude below the decoded
natives kept beside them (`max_cached_native`, three of them, each up to
`max_native_pixels` of 8bpp gray). It deliberately does not reuse `evictOldest`,
whose loop is `count >= cap` — it would turn four into three — and which stamps
through the `stamps` table `native` shares, keyed, as this is, by page number.

Three consequences that are easy to trip over:

- **A page is refetched, not re-read.** Anything past the four-entry cap costs a
  request, and so does everything after the book is closed. Offline reading of a
  page already seen is gone; offline reading of the page in front of you is not,
  because the decoded buffer is still in the native LRU.
- **The byte reads are guarded, and one of them was a bug.** `hasNative(pageno)`
  skips fetching bytes at all when the page is already decoded, because
  `decodeRegion` hands them to `ensureNativeBB`, which returns the cached buffer
  before it looks at them. Without that guard every tile miss — a zoom change, a
  crop toggle, a repaint during teardown — would pay a synchronous HTTP GET inside
  the paint for bytes nothing reads. The bug it also fixes: `renderPage` used to
  return nil and paint the gray placeholder when the bytes were missing but a
  perfectly good decoded page sat in the LRU. `getPageDims` is deliberately *not*
  guarded — it is the decoder, and a live native would have answered from
  `self.dims` before reaching it.
- **Files a previous version left in `cache/meguru/pages` and `.../covers` are
  nobody's problem.** Nothing reads them and nothing sweeps them — there is no
  "Clear cache" row any more, because with no disk cache it would have had nothing
  of its own to clear.

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

## The marker

Extension `.meguru`, provider key `"meguru"`. Serialised with `LuaSettings` as
`return { meguru = {...} }`, matching the `DocSettings` sidecar beside it.
`Marker.new` is the one place the shape lives.

`server_name` is the **catalog title**, which is the key credentials are looked up
by in `settings/opds.lua`. **No secret is stored in the marker** — `template`,
`cover_url` and `series_cover_url` have any credential-bearing path segment replaced
by `<redacted>` on the way to disk, and `Marker.load` puts it back from that catalog.
One list (`CREDENTIAL_FIELDS`) is read by both halves of the pair, so a URL field
cannot be redacted on the way out and forgotten on the way in.

The three fields that identify the series — `series_name`, `server_kind`, `lang` —
are what let a book opened from History, with no browser and no network, say which
series it belongs to and build the feed URL that would describe it. `server_kind` is
the load-bearing one: without a driver there is no canonical feed, so a book whose
marker lacks it has no neighbour — and the failure is silent, because the book
itself opens and reads perfectly. `Base.kindFromTemplate` is the rescue for markers
written before the field existed, reading the kind off the stream URL with the same
`streamSignatures` evidence `discover` uses, and refusing when two drivers claim it.

`item_id` is **gone**. It was the catalog's rowid, carried so an open could notice
the database had been rebuilt underneath the marker; there is no database to be
rebuilt. A file written before this still carries the number and nothing reads it.
`Marker.VERSION` is 2, and nothing reads that either — it is a note for whoever
finds an old file.

`Marker.seriesContext(desc)` is the projection of the fields above that describe the
series, and it is what every caller outside the marker module uses — the reader
menu, the resume dialog, the feed planner. A v1 marker answers nil for the fields it
lacks, and each reader of them already has a fallback.

`resolveStream` runs again whenever a page stream is about to be resolved from a
feed, with the stored `template` as the offline fallback. For Suwayomi this is
correctness rather than optimisation: the stored template carries a chapter number
that the server may have renumbered, and a stale one fetches a *different chapter*
while still answering 200.

## Reading a feed

`meguru/feed.lua` is the whole of the engine's network surface for a series, and **it
writes nothing**. It exists because three questions turn out to be one: walking a
`rel=next` chain, putting the entries in reading order, and naming the entry either
side of the one being read.

```
plan  = Feed.planForMarker(desc, opts)   -- marker -> driver + canonical feed URL
walker = Feed.walker(plan.url, plan.walker_opts)
while walker:step() do end               -- HTTP, one page per step
items = Feed.collect(walker, plan)       -- parse + dedupe
seq   = Feed.ordered(items)              -- reading order, and the length of the
                                         -- ordered prefix
next  = Feed.neighbor(seq, item_key, "next")
```

The rules that make a walk safe, each of which has a reason:

- **Pagination is followed by `rel=next`**, never by constructing `?page=N`.
  Kavita's next href is a bare query string and Suwayomi's carries `lang`, so a
  rebuilt URL would quietly walk a different feed than the one being paged.
- **`complete` is conservative** — false on any non-200, an unparseable body, the
  page cap, a repeated `rel=next`, or a cancellation. A walk that is not complete is
  not an answer, and every caller treats it that way rather than using what it got.
- **Two page caps, named for their caller.** `Feed.MAX_PAGES` bounds a walk nobody
  is waiting for; `Feed.TAP_PAGES` bounds one started by a gesture. A tap cannot
  spend half a minute of frozen e-ink, and six pages is 600 chapters — past the point
  where walking further to find a neighbour is plausible.
- **`opts.timeout` picks the `Net` preset.** A tap is `"resume"` (4s/8s), not the
  `"feed"` (10s/30s) a background job could afford. There are no background jobs any
  more, so this is always the short one in practice, and it is still a parameter
  because `Feed` does not decide who is waiting.
- **A driver never opens a socket.** Suwayomi's lazy per-chapter metadata fetch
  arrives as an injected `fetch` callback, so credentials, timeouts and log
  redaction stay in one place.
- **An empty feed is a feed, not a parse failure.** `Net.fetchFeed` returns
  `nil, "empty"` for a document that parsed but listed no entries, which is its own
  state and can be handled as one; `"http"` is for a real HTTP-level failure.
  Suwayomi answers `filter=unread` on a fully read series with a valid, empty feed,
  so conflating the two made the *normal* answer for a finished series look like a
  failure and sent both the row and the resume fetch down their degraded paths.

**Nothing is stored, so there is nothing to keep in step.** No transaction, no
generation sweep, no shrink gate, no TTL, no backoff, no resumable stepper driven
from a UI tick. All of that existed to maintain a materialised view of feeds, and
the view is what was removed.

**A repeated `item_key` is one book, and the copy that carries the server's page
is the one that describes it.** `Feed.dedupe` is the whole of that rule, and it
has exactly two callers: `Feed.collect`, which walks a chain, and `itemsFrom` in
`ui/open.lua`, which is the one place in that file where feed entries become
items — the three list-parsing sites (`freshResumeTarget`, and `seriesItems`
twice) go through it rather than through the driver, so the identity rule cannot
drift between them again.

*Why first-wins was wrong, which is what this replaced:* **Kavita's "Continue
From" entry** — behind *Include Continue From Entry*, in User Settings → OPDS — is
`CreateChapterFeedEntry` of the chapter the reader is on, with only its `Title`
replaced, and `GetSeriesDetail` puts it at the **top** of the series feed. So it
carries that chapter's own `chapterId`, stream and `p5:count`, and **no
`p5:lastRead`**, in front of the entry that carries the reader's page. Keeping the
first kept the copy that describes the book least, and the loss is not cosmetic:
`Feed.isFinished` is false without a `last_read`, so `firstUnfinished` read the
alias as *unfinished* and offered it, and `usablePage(nil)` had no page to put on
the button — a volume with no page, and the server's position never reaching the
dialog at all. PROTOCOL.md carries the capture.

**The survivor keeps its own place in the feed, and for Kavita that is the
neighbour relation.** `Feed.neighbor` walks the sequence by index, and Kavita's
feed order *is* its reading order — `Feed.ordered` has no path or title position
to sort on there (`positioned` is 0) — so an entry's index is its chapter's place
in the series. A survivor that inherited the slot of the copy it displaced would
put the chapter the reader is *in* at the head of the series, because that copy is
the feed's first entry: "next chapter" would answer the first volume, and
"previous" would say there is none. `Feed.dedupe` therefore sorts its survivors by
the index each was found at. It is the same defect as the lost page and it comes
from the same entry — the alias claiming a position that belongs to a book.

**And it reads no title, which is a requirement rather than a preference: these
OPDS switches are per user.** `Include Continue From Entry` decides whether the
alias exists at all, and `Embed Progress Indicator` / `... in Title` decide whether
titles carry a status glyph — set independently, in User Settings → OPDS, so the
same series feed has a different shape for each reader of it. The identifier and
the page are on the wire under every one of those shapes; the title is not, and
the alias prefix is further *translated* (`opds-continue-reading-title`), so
`Naming.ALIAS_PREFIX` matches an English Kavita UI and nothing else.

**`driverItemFor` is deliberately outside it** — that path matches one *stream* the
reader has already tapped, and it must answer with that entry even when the entry
is one of these copies. See "Known open items" for what that leaves open.

`Feed.ordered` is worth reading before touching anything that picks a chapter. It
orders by the server's own **list position** — the `{n}` in Suwayomi's
`/series/{id}/chapter/{n}/metadata` — and, **only for a driver that says its
titles can be trusted** (`Suwayomi.orderFromTitles`), falling back to the number
`Naming.deriveSeries` pulls from the title. Everything else gets feed order.

That driver flag is the fix for a bug that had no other shape. Kavita feeds are
already in reading order and routinely mix granularity, so numbering them by
title sorted `Volume 1…3, Chapter 1…3` into `1, 1, 2, 2, 3, 3` — 25 of 3473
series — and a title with no number in it (`Chapter 128x1`) was parked at the
end of the series. The title is a fallback for a server whose feed is
newest-first, which is Suwayomi and only Suwayomi. Its second return, the length
of the ordered prefix, is load-bearing
for any caller that looks *backwards*: the unpositioned tail is in feed order, which
for Suwayomi is the exact reverse of reading order.

`Feed.ordered` is also the one ordering both entry points share, **extracted rather
than copied**, because the bug it exists for was the two of them disagreeing:
`freshResumeTarget` took the last item of the parsed page with any progress —
correct only while the page is ascending — and the page the *browser* holds is
newest-first while `currentResumeTarget` fetches `sort=number_asc`. The same series
answered "furthest read" with the lowest-numbered chapter of the newest hundred on
one screen and the true furthest on the other.

Nothing rewrites other books. A marker is written only for the book being opened,
and the walk that finds a neighbour leaves every file alone — including the one it
was asked from. That is the whole difference from the design this replaced, where a
stale list was the only list there was.

## Drivers

Drivers are **pure functions over already-parsed feeds**. HTTP, pagination and
credentials stay in the engine — otherwise there are three copies of the `rel=next`
logic and three copies of the loop guard, and HTTP ends up inside a driver where it
cannot be read with understanding. The only I/O a driver genuinely needs is
Suwayomi's lazy metadata fetch, and that is handled by an injected callback.

```
authorSignatures                      -> lowercased needles matched against the
                                         feed-level <author>
discover(entry, stream, ctx)          -> series_remote_id, discovered_from
catalogURL(base_url, remote_id, ctx)  -> the canonical, paginated feed URL
parseCatalogPage(feed, base_url, ctx) -> normalised items
seriesName(feed, entry, ctx)
resolveStream(item, fetch, ctx)       -> template, count

seriesCover(feed, entry, base_url)    -> url, or nil to defer   [optional]
```

`seriesCover` is the one optional hook, and it exists because one server
publishes its series artwork somewhere the feed cannot reach: **Komga's series
feed carries no image at any level**, so the generic fallback would key a
series' artwork to whichever of its volumes happened to be opened first. A
driver that returns nothing — or has no such hook — falls through to the feed,
which is what Kavita and Suwayomi want, since both publish the series image at
feed level. It is asked by `Base.coverFromFeed`, whose fourth argument is the
driver.

`catalogURL` is a pure function of the server and the series id and is **never**
derived from whatever the user happened to be browsing. Kavita's History / On Deck /
Recently Added feeds are truncated and must never be the source of a sync. Kavita's
stream URL carries its own `seriesId` beside `chapterId`, which is where
`Kavita.discover` recovers it.

**Komga is the one server that puts the series id nowhere on the entry**, and the
consequence is the one thing `ctx` carries besides the language: `ctx.url`, the feed
the entry was read out of. `Komga.discover` peels `/series/{id}` off it, which is why
every site that calls `discover` — `registerBook`, `feedSeries`, `currentResumeTarget`
— has to put a feed URL in the context it hands over. It is not a convenience: without
it a Komga entry is unidentifiable, and refusing is the right answer, because guessing
a series from a title syncs a library against a feed that describes something else.
That refusal is also why **an aggregate is not openable on Komga** — `books/latest`,
`ondeck` and `keep-reading` list books across every series and carry no series id at
all — while browsing `/series` → volume works in full.

`discovered_from` distinguishes a series feed from an aggregate one. An entry
reached from an aggregate may not carry a recoverable series id, and an aggregate is
not a series. **Never silently sync the wrong series.**

Driver selection is by a **kind**, and a kind arrives one of four ways: the session's
author sniff, the book's own `server_kind` field, `Base.kindFor` — which asks each
driver's `discover` whether the entry is its own and takes the answer only when
exactly one driver claims it — and `Base.kindFromTemplate`, which exists for a
*marker* rather than for a browse: a file written before the descriptor carried
`server_kind` has no feed to sniff, so the stream URL it does carry is asked instead.

The inference is deliberately conservative — two claimants return nil — because a
wrong kind is worse than none: every feed URL built for that server then describes a
different series. That matters more here than it did in the old plugin, which only
*stored* `server_kind`, because the driver is what knows a series' canonical feed,
so an unknown kind means every book off that server has no neighbour — no next
chapter at all, forever, and silently, because the book itself opens and reads
perfectly.

**The manual override is gone, and this is what removing it cost.** There used to be
a strongest source above all of these: a kind set by hand from the
server-administration screen, which went with the Library/Servers views. So a
mis-sniffed server can no longer be corrected from the UI at all. The repair a
reader has left is to delete the book's markers, which loses nothing but their
directory placement: reading progress lives in the sidecars beside them.

## Where an open starts

**Reading progress is not mirrored anywhere.** It is read lazily, per book, from the
sidecar beside the marker: `DocSettings:findSidecarFile` then `openSettingsFile`,
reading `percent_finished`. That is the only place it lives, which is what makes a
marker safe to rewrite — there is no reader state in it to lose.
(`DocSettings:hasSidecarFile` is the cheaper, parse-free variant of the same test,
used where nothing needs reading.)

**The server's own progress is a separate thing, and it seeds a first open.** A
marker's `last_read` is the page the *server* says the reader stopped on. It is not
a mirror of local progress and never overrides it: `ui/open.lua`'s `offerResume`
asks whenever there is a choice.

- **Whether the book has been read here decides the wording, not whether to ask.**
  Gating the question on "never opened here" made the one case worth asking about
  unreachable: a reader who read volume 3 here and got to volume 5 elsewhere got no
  question at all. The gate is "is there anything to offer instead", and a book
  already being read with nothing further along opens where it was left, silently.
- **The dialog is gated on the server, not on "is there anything to show".** No
  server answer means no question — what the reader asked for needs none. That is
  also what keeps the dialog from ever having one button: the reader's own button is
  unconditional, so a server answer makes two, and no server answer means the dialog
  is not built.
- **The button for the book the reader clicked is always there, and removing it once
  broke the feature.** Clicking an unread volume 11 while the server said volume 5
  left a single button pointing at volume 5, and a tap past the dialog cancels — so
  volume 11 was unreachable. Choosing it for an unread book has to write page 1, or
  `MeguruDocument:init`'s silent seed would open at the server's page anyway and the
  server's answer would win a question the reader just answered.
- **Every button names the book it opens, and the title names the series.** The
  question is where in the *series* to carry on, so the title is `series.name`;
  because it cannot name both books, each button names its own. Two buttons reading
  "continue" while pointing at different books is worse than not asking. The name is
  the short form (`bookLabel`), because `display_title` overflows the button once a
  page number joins it.
- **The verb follows the situation.** A book never opened here says `Start reading`,
  not `Continue — page 1`, which reads as a contradiction. A book that has been read
  continues; one read without a recorded page continues too, and drops the number
  rather than claiming one.
- **The page on the leaving button is only named when the tap will land there.**
  `jumpPage` returns nil for a target this device has already read, because such a
  book resumes where KOReader left it. It is `nil` exactly when the target has a
  sidecar — coupled to `MeguruDocument:init`'s silent seed, so change one and you
  must change the other.
- **`▶` marks the server's answer**, because it is the one on the dialog that is not
  the reader's own doing; the local one carries no glyph. "Volume 2" and "Chapter 30"
  are **the server's own trailing tokens** as `Naming.deriveSeries` peeled them from
  the entry title — never abbreviations this code invents. The example: `"Now That
  We Draw - Volume 2"` → series `"Now That We Draw"`, label `"Volume 2"`, index `2`.

**The `▶` book is the first chapter the server has not finished — or, when it has
finished them all, the last one.** `freshResumeTarget(..., select)` takes a
selector:

- `firstUnfinishedOrLast` is the default, and all Kavita has. Reading the sequence
  forward it returns the first entry whose `last_read` has not reached its
  `page_count`; when every entry has, it returns the last entry. A chapter with no
  count is *unfinished* rather than finished — offering it again is a smaller
  mistake than skipping past it.
- `firstIn` is Suwayomi's, on a feed already filtered to the chapters the server
  flags unread. Every entry qualifies by construction, so it is `sequence[1]`.

They are the same *question* answered by different *means*, and the means are not
interchangeable: where a server publishes a read flag, the flag is right and the page
counter merely correlates with it. The "or the last one" half is not decoration: a
series read to the end has nothing unfinished, and "nowhere to continue" is not what
this button is for — a reader who finished chapter 177 and taps again is at chapter
177, and a button that vanished would be saying the series is empty. This replaced
"the last entry with any progress at all", which answered volume 3-4 for a reader who
had read 1-2 today and dipped two pages into 3-4 yesterday.

**`firstUnread` deliberately stops where the `▶` button carries on.** The row above
a series feed uses `firstUnfinished` alone and answers "nothing unread" for a fully
read series; the button uses `firstUnfinishedOrLast` and names its last chapter. That
is not an inconsistency to tidy away: the row offers to *open* a chapter, so with
none to open it says so, while the button offers to *say where the reader is*, and
for a finished series that is its end. `firstUnread` *calls* `firstUnfinished` rather
than restating its predicate, so the two cannot drift.

**Suwayomi tracks "read" as a flag of its own, and it is not the page counter.**
`pse:lastRead` and the `<summary>` prose count pages *within* a chapter; the flag is
set when a chapter is finished or explicitly marked read. The two disagree in **both**
directions — a chapter can be flagged read with its summary still saying `Postęp: 0 z
17`, and a chapter merely started carries progress while being flagged unread — so a
page-progress scan answers with a chapter the reader has not finished, and skips the
unread chapters in between that have no progress at all. The flag is in no entry's
data; only a feed *filtered* by it says anything. Hence `Suwayomi.unreadFilter =
"unread"`, and the canonical feed is asked only where the filtered one is **empty**
(the server answered: nothing is unread, and the flag outranks the counter) or
**failed** (we do not know what the server thinks, and there the counters are the
only evidence). Reading them as one is how `▶` came to name chapter 1 for a series
the server calls fully read.

**`seriesItems` returns `items, basis`.** `basis` is `"flag"` when the walk ran over
a feed the server filtered by read status, `"empty"` when that feed came back with
nothing, and `"counters"` when it fell back to the browser's own page — which the
server did **not** filter, and which for Suwayomi is the newest hundred chapters.
`firstUnread` uses it to decide whether the page counter may be consulted at all;
deriving it from the driver instead made `firstUnread` take `sequence[1]` of that
page, i.e. the newest chapter rather than the first unread. `seriesItems` retries
with the canonical feed when the filtered walk yields nothing, because a row that
promises "the first unread" cannot stand on the newest hundred chapters — that is how
it came to open chapter 78 for a reader whose series starts at chapter 1.

**A recorded page is used exactly as recorded; a *small* lead is simply ignored.**
Servers that track progress count pages *fetched*, and the reader fetches one page
beyond the one on screen (`MeguruDocument.prefetch_count`), so a book read here is
recorded a page ahead. That lead is **never subtracted**: a position recorded by
*another* reader has no such lead, and subtracting would have reopened a book left at
page 60 at page 57. It is instead *tolerated* — `PSE.samePlace(recorded, local)` is
true when the recording is not meaningfully ahead, and there the server's button is
not offered at all. The tolerance is `SERVER_PAGE_TOLERANCE`, a local in
`meguru/pse.lua`; widening it makes the question rarer and never changes a page that
is shown.

**A recorded 0 is not the same as no recording.** Kavita marks a chapter unread by
writing `lastRead="0"` rather than by dropping the attribute, and Suwayomi writes
"Progress: 0 of 31" the same way. Both readers therefore return **0**, not nil, and
the distinction is load-bearing: an empty feed entry, or a progress field that is
absent, has to read as "this feed does not publish progress" rather than as "unread".
Collapsing the two once let a volume marked unread on the server stay the
furthest-read one here for good. Returning 0 is safe by construction: every consumer
asks `> 0` or `> 1` before treating the number as a page.

**The flows that stay silent do so by decision.** A neighbour reached from the reader
— "find the next chapter", the automatic advance at the end of a volume — goes
through `Open.openItemSilently`, not `offerResume`. A tap on a named chapter is an
instruction, and the dialog answering it would be the dialog overriding what the
reader asked for. That was visible on "previous chapter": with the server sitting at
chapter 7, the only button on offer pointed *forward* to chapter 7 instead of opening
the chapter tapped.

**A tap past the dialog cancels — it opens nothing, and it writes nothing.**
`ButtonDialog` is dismissable by default, and the dialog deliberately sets no
`tap_close_callback`. An earlier version did, on the reasoning that a dismissal had
to "land somewhere", and opened the book. Tapping past a question is not a way of
answering it.

### Planning, writing, and handing over

**The marker is planned, not written, until the question is answered.** `planMarker`
resolves everything — the stream, the descriptor, the directory and the path — and
`commitMarker` writes it. The split exists because the dialog needs the marker's
*path* before the file exists, and because the marker is what puts a book in the
library and in History: writing it on the tap and then dismissing the dialog left a
phantom shelf entry for a book nobody chose.

**A dismissed dialog leaves no folder either, and that is `dirFor` being pure.** It
used to `FS.ensureDir` each component while it built the path, so the empty series
folder appeared on the tap and outlived the dismissal. An empty folder is not the
harmless leftover it looks like — it is indistinguishable from a series whose books
were all deleted, and nothing in the plugin removes it. `Marker.saveAt` creates the
folder now, at the moment there is a file to put in it, and degrades to the nearest
ancestor that can be made rather than losing the book. The outermost folder is the
one thing still created up front, because `Marker.baseDir()` is what answers "is this
folder usable": a `marker_dir` on unplugged media has to be rejected before anything
is planned around it.

Two consequences worth knowing. `Marker.saveAt` takes a path rather than recomputing
it through `pathFor`: the path was answered before the file existed, and `pathFor`
consults the directory it is about to write into. It returns nil when no folder could
be made, and both callers report that. And `openAsBook` does **not** go through
`commitMarker`, because that path remembers the credentials the reader just typed
into the OPDS form while `commitMarker` would look them up in `sources` — which is
precisely what has not been flushed yet.

Every button routes through a single `once(action)`, so a double tap cannot open two
books. **`once` is not what stops the dialog reopening after the open** — it is
per-dialog and dies with it.

**The dialog asked twice, and a one-shot keyed on the file is what fixed it.** Every
catalog open ends in `handToReader`, which calls `host.ui:switchDocument`, which
calls `ReaderUI.showReader` — the method `hook.lua` wraps in order to ask where to
start. So the wrap re-entered `offerResume` for the book the dialog had *just* been
answered about, and the reader saw the same question again.

`Open.noteHandoff(file)` arms a one-shot immediately before the handoff, and the wrap
reads *and clears* it before anything else. The shape is load-bearing in both halves:

- **One-shot, not a set and not a time window.** The re-entry is synchronous —
  `switchDocument` calls `showReader` in the same statement — while a per-session set
  of "files we have opened" cannot tell it apart from reopening the same book from
  History ten minutes later, which must still ask: the reader may have read on and
  the server may have moved. A timestamp cannot either, since the reopen that needs
  asking about is exactly the one seconds after a close.
- **Keyed on the path**, so it can only suppress the open it was armed for. A bare
  "we are opening something" flag would swallow an unrelated open.

Two callers arm it, and only two: `handToReader`, and the OPDS branch of `openAsBook`
that goes through the built-in plugin's own `manager:openDownloadedFile`. The
plain-download route is deliberately **not** armed, so a book opened from the
browser's own "Read now" still asks.

**The file-manager open is wrapped, because it is the only place left that can ask.**
`hook.lua` wraps `ReaderUI.showReader` so a marker opened from the file manager or
History gets the same dialog. Three rules keep that wrap from ever costing anyone a
book: non-`.meguru` files fall straight through before anything else; the whole offer
runs in a `pcall` whose failure opens normally; and the open is called at most once.
Two traps:

- **`showReader` is called both ways.** `switchDocument` does `self:showReader` and
  the file manager does `ReaderUI:showReader`, so `self` is sometimes the class and
  sometimes an instance. The file is whichever of the first two arguments is a string
  — never `self == ReaderUI`.
- **`switchDocument` routes through it too**, so our own neighbour opens land in the
  wrap. They are harmless (the one-shot suppresses the dialog), which is why the wrap
  must not assume it only ever sees file-manager opens.

That path has no browser feed, so its chapter target costs **one request** —
`currentResumeTarget`, gated on `NetworkMgr:isConnected()` and bounded by
`Net.RESUME_*` (4s/8s, not the 10s/30s a walk nobody waits for could afford), and
with no fallback on failure — nothing to fall back to. It passes the marker's own
`lang`, because Suwayomi selects between translations by `?lang=`, and a defaulted
language would report the progress of a translation the reader is not reading. That
is a property of the *book* rather than of the server, which is strictly better: a
library browsed in two languages used to report whichever was seen last.

**There is no degraded answer, and that is a decision rather than a gap.** The last
chapter any reading had touched, kept from the last walk, answered a *different
question* from the fresh read. With nothing stored there is nothing to be stale from,
so `currentResumeTarget` returns nil when the server has nothing to say, and the log
says so with its reason: `no resume point from the server ( … )`.

**It is fetched on every open, and deliberately not cached.** An earlier version
cached the answer per series for 45 seconds; close a book, read on, reopen it within
that window, and the dialog offered the position from *before* — the server's button
ten pages behind the truth, which is the one thing asking the server was supposed to
prevent. The cost bought back is one feed fetch per open, bounded by `Net.RESUME_*`
and only when the network is up.

**A starting page can only be set through the sidecar.** `ReaderUI:showReader` takes
no page, and `after_open_callback` / `registerPostReaderReadyCallback` both fire
*after* `ReaderReady` and the first render, so anything later shows page 1 and then
jumps. The one value that reaches the first paint is `last_page`, which
`readerpaging.lua:154` reads in its own `onReadSettings` — so `Open.seedLastPage`
writes it before the handoff. This is why `DocSettings:hasSidecarFile` must be asked
**before** any `DocSettings:open`: that call creates the sidecar being tested for.

**`MeguruDocument:init` keeps a silent seed as the safety net**, for any open that
reaches the reader without going through `showReader` at all — from the marker's own
`desc.last_read`, and with no network call, because `init` runs inside the document
open where a dead server would freeze the screen. A choice made in the dialog
therefore has to leave a sidecar behind, including the choice *not* to resume: "start
from the beginning" writes page 1, or the silent seed would quietly undo it a moment
later.

The three servers differ in where that progress comes from, and it is a wire format,
not a design choice: Kavita states `p5:lastRead` on every series-feed entry, so it
syncs for free; Komga states `pse:lastRead` the same way, but only once the book has
progress at all — an unread library publishes the attribute nowhere, which is what
makes a fresh Komga look like a server that tracks nothing; Suwayomi's chapter
entries carry no PSE attributes at all, so it is scraped out of the `<summary>`
prose — see PROTOCOL.md. All three end up in the same column, and a series whose
server says nothing simply offers no page.

**A marker opens and reads with no network and no configuration.** That is the
property everything else is built around: `template` and `count` are in the file, and
nothing else is consulted to render a page. What needs a feed is everything *around*
the book — a neighbour, the server's own position, a cover the marker did not carry —
and each of those fails on its own without touching the book.

**"No configuration" is a different thing, and the difference is one file.** A
marker's `template` is stored with its credential replaced by `<redacted>` and
restored at load from `settings/opds.lua` — so a Kavita marker reads with the
catalogue deleted, and cannot fetch its pages without it. The failure is loud and
self-describing: a 404 whose path says `<redacted>`, plus a warning naming the
missing catalog and the fields that stayed stuck.

## Next and previous in a folder of `.cbz`

**A local `.cbz` is known by the metadata it carries, not by its file name.**
`MeguruDocument:_localComicProps` reads the archive's own `ComicInfo.xml` —
ComicRack's schema, which comic libraries write and serve and which Rakuyomi
writes into every chapter it downloads — and falls back to the file's name only
when there is no such entry, or it will not parse. `meguru/comicinfo` is the
whole of that read, and it reads **into memory** (`Archiver.Reader:extractToMemory`)
rather than through `extractToPath`, because the disk-writing route would have
made merely opening a comic leave a file behind. This replaced a `{ title =
self:_localTitle() }` that returned the name unconditionally, and the reason is
worth keeping straight: **Rakuyomi was not broken, it stopped being called.** Its
own `CbzDocument:getDocumentProps` reads the same entry and merges it, so a file
it opened was titled properly — but the moment Meguru claims `.cbz` the document
is ours, that method never runs, and the file falls back to its name. Reading the
entry here is what makes the metadata survive whoever owns the extension, and it
needs Rakuyomi only to have written the file, never to be present at read time.

Two properties of it are load-bearing. **`title` is the file's own `Title` and
the series is a field beside it** — not folded, unlike the streamed path, because
`BookInfo.extendProps` puts `title` straight into `display_title` while `series`
is drawn on a line of its own, so folding would print the series twice; a marker
folds only because the descriptor it projects has no series *field* for the title
to sit beside. And **the entry is read once per document** (`self._comic_info`,
with `false` for "read, none there"), because it opens the archive.

**The whole schema is read and seven fields are used, because `doc_props` has
seven slots.** `ComicInfo` v2.1 declares about forty elements and `BookInfo`
draws exactly `title`, `authors`, `series`, `series_index`, `language`,
`keywords`, `description` — so "use the whole schema" cannot mean putting it into
`doc_props`. What it does mean is what `meguru/comicinfo` does: one pass collects
every non-empty element the entry has, and a `MAP` table decides which one
answers which key, so a field a newer writer adds is read without a change and
the mapping is one table to read rather than a `match` per property. Two entries
in that table are judgement calls and are named as such there: `keywords` takes
`Tags` then `Genre`, and `authors` takes `Writer`.

**Element names are matched case-insensitively, and that is a requirement.**
`ComicInfo.xsd` declares the language element as `LanguageISO` and declares no
second spelling — but the files in hand write `<LanguageIso/>`, lowercased, which
is ComicRack's spelling, so the divergence is the **writer's** rather than a
version of the schema. (An earlier draft of this paragraph said the schema had
renamed it between versions. It had not been checked; the XSD was, and it says
otherwise.) An exact match would have missed it on the very files this was
written for, and missed it silently. Measured against two synthetic archives, one
per spelling.

**The XSD carries no documentation at all** — no `xs:annotation`, so nothing
settles what `Genre` means against `Tags`, or whether `Writer` is the author.
That is why the two judgement calls in `MAP` are named as judgement calls rather
than defended: the schema is silent, so they are a reading, and they are one line
to change when a file turns up that fills both.

**`entry.size` from the archiver is a cdata `int64_t`, not a Lua number.** A
guard written as `type(entry.size) == "number"` is false for `754LL`, so it
refuses the entry and looks exactly like an archive that has none — which is what
the first version of this module did, and why a book opened through Rakuyomi kept
its hashed name while every part of the read was in fact working. Compare it to a
number directly; that is what LuaJIT's FFI does natively and `tonumber` does not.

**A book already opened keeps its old title on the FileManager's list until the
cache is refreshed.** The sidecar's `doc_props` is recomputed on every open and
is right immediately, but the list itself is drawn from `BookInfoManager`'s own
cache, which nothing in this plugin writes or invalidates — so
*Refresh cached book information* is what puts the new title on screen. An
earlier version of this paragraph claimed "nothing has to be migrated", which was
true of the sidecar and false of the thing the reader is actually looking at.

**A local `.cbz` has the same two rows a marker has, and its series is the folder
it is in.** `meguru/local.lua` is the whole of it: it lists the file's own folder,
orders the books by a **natural sort of the file name** — `2.cbz` before `10.cbz` —
and answers which file is either side. Nothing is read out of the name, nothing is
written, nothing is remembered, and no socket is opened: this path is offline by
construction, which is why its branch in `Reader.openNeighbor` sits **above** the
`NetworkMgr` gate rather than below it. `MeguruDocument:localSeries` is the seam,
deliberately a *second* method beside `seriesContext` rather than a branch inside
it: that one projects a marker and everything downstream branches on its nil, and
two answers that can never take each other's shape is what keeps the feed path and
the folder path from being confused.

### What this replaced, and what it cost

There was a **name grammar** here, and it is worth knowing what it was, because the
temptation to rebuild it is the obvious "improvement" to make. It read the series
out of the file name: volume tokens, bare trailing numbers, a leading number as a
position rather than a title, which bracketed group was a release tag and which was
part of the title, case-folding by hand so the device's locale could not move a key.
Every rule was defended by a real example and every rule was there to answer one
question the folder already answers — *are these two files the same series?* — in
order to survive a layout nobody has: one folder holding two series' books. It cost
a grammar no reader could predict, no test could reach (`tools/check.py` cannot see
into a name-keyed comparison), and an asymmetry that had to be explained in three
paragraphs.

**The trade is now explicit.** A folder that holds two titles will navigate from one
into the other: `next` on the last Berserk volume opens whatever sorts after it.
Nothing on disk tells that folder from a real series folder, so this does not
pretend to — and that is exactly why `Local.seriesOf` answers nil unless the folder
holds **a second book to move to**. A lone one-shot gets no navigation rows at all,
rather than two rows that could only say there is no next. A folder is still refused
outright when it cannot be listed, or when a listing loses the very file being read.

There is **no cap** on the folder. A long webtoon run is the case this exists for,
and any cap low enough to catch a library folder would refuse it too; the price is
one `lfs.attributes` per entry, on a menu build and on a tap.

`Naming.deriveSeries` and its helpers are **not** part of this — they are the
server path's, where a *title* really is all there is to go on, and `Feed.ordered`
still orders a feed by them. Nothing here calls them.

### The one piece that is not obvious: the sort key

`sortKey` encodes a digit run as the marker byte `\1`, its length (leading zeros
dropped) in three digits, and the digits themselves, so that plain string
comparison sorts naturally — `001` is less than `002` before a single digit is
compared, which is what puts `2` before `10`.

**A key rather than a comparison function, and that is not a style choice.** Walking
two names at once is how a natural sort is usually written and how `table.sort`
comes to throw `invalid order function for sorting` — from inside a tap, when the
walk turns out not to be a consistent order. A key is a function of *one* name, so
the comparison is `<` between two strings and cannot be inconsistent; the encoding
is also injective, so two different names never share a key. The mirror written to
check it found the one real bug here before a device could: the padding that keeps
`2`, `02` and `002` distinct sits **before** the rest of the name, so a `\0` pad
sorting "naturally" would actually sort `02` *before* `2` — the pad is `\255`,
above every byte a UTF-8 name holds, and fewer leading zeros sorts first.

### Log lines

Three, and the level each is at is the frequency rule: `dbg` for
`Meguru: local folder <dir> — <N> book(s), this one at <pos>`, which fires on every
menu build and every tap because it marks the *normal* path; `warn` for
`Meguru: cannot list the folder of <file> (…)`, which marks the failure; and
`info` for the tap that found nothing — `Meguru: no local neighbour of <name>
towards <which>` — worded to mirror the feed's `no neighbour of … towards …`,
because it is the same refusal on the other path.

**There is deliberately no line for the forced provider.** The open that worked
already prints the document's own `Meguru: local CBZ ready — …`, and that line is
*absent* when the provider was not Meguru — which makes it the test rather than the
thing needing a second line beside it. `Open.openLocalFile` forces it —
`switchDocument(path, nil, nil, provider, true)` — because the row belongs to a
Meguru book and promises the next volume *here*; a reader who has given `.cbz` back
to KOReader would otherwise be moved out of this engine mid-series. Forcing is
per-open and writes nothing: the per-file `provider` key in a sidecar is only ever
written by the "Open with…" dialog. `FS.exists` comes first, because
`switchDocument` closes the reader *before* it tries to open anything — a sibling
deleted between the listing and the tap would otherwise leave the reader torn down
with nothing in its place.

## Panel zoom, and the panel sequence

### The preference, and the stock cascade

**One preference, and the stock cascade left exactly where it is.** What a file gets
is KOReader's own rule — the answer in the file's sidecar if it has one, and otherwise
the fallback:

```
the file's own answer (sidecar), if it has one
otherwise  Settings.panel_zoom        -- the menu row, default on
```

The stock switch is ⋮ → **Panel zoom (manga/comic)** → *Allow panel zoom*, and
`ui/menu.lua`'s `Panel zoom in Meguru books` reads and writes the fallback through
`Reader.panelZoomEnabled` / `Reader.setPanelZoom`. The stock row therefore shows the
*resolved* value while flipping it answers for one file and never touches the
preference. Two rows, two different jobs, and neither owns the other.

**This replaced a design that named an extension, and the reason is a bug the naming
caused.** The row used to govern KOReader's per-*extension* entry for `meguru`, but
the plugin also opens `.cbz`, and the menu appears for those too, because the gate is
`doc.provider == "meguru"`. So a reader looking at a `.cbz` was shown the answer for
markers while the book in front of them followed the `cbz` entry: **the row said "off"
while the panels worked.** A preference for everything Meguru opens has no such gap.

Three wraps, and the third is the one that will be forgotten:

| wrap | job |
|---|---|
| `onReadSettings` | remember whether the file answered for itself, and when it did not, put the preference where stock put the extension entry; the text-selection fallback is forced off |
| `onTogglePanelZoomSetting` | record that the reader just answered for **this** file |
| `onSaveSettings` | delete the per-file copy stock just wrote — unless that file answered for itself |

The ordering is what makes the first one possible at all: plugins load
(`readerui.lua:464`) **before** the `ReadSettings` event (`:484`), so the wrap is in
place before stock computes a value. `installPanelZoom` is called from
`Reader.install` for that reason.

**The line those wraps must not cross: a file that was only *opened* may not come
away with an answer of its own.** Stock writes the live field into the sidecar on
every save, so without that third wrap a book opened while the preference was on
would be pinned on for good, and would survive the reader turning the preference off.
That is why "delete unless pinned" is not the same thing as the old unconditional
delete.

**Two costs are accepted here, deliberately, and neither is a defect to tidy:** a
file the reader switches with the stock row keeps a copy that outlives any change to
the preference; and a `.cbz` opened through Meguru can answer differently from the
same `.cbz` opened by KOReader's own reader, whenever nobody has answered for that
file. Both follow from "the preference is the fallback for everything Meguru opens",
which is what was asked for.

The preference's default is **on**, because that is KOReader's own default for
`cbz`/`cbt` and was this plugin's for markers: a long-press that silently does nothing
on a comic is a surprise rather than a neutral state. The fallback to text selection
is forced off with it: nothing on a streamed page is text, and that fallback reaches
`getImageFromPosition`, which no engine-less paging document answers.

**The `panel_zoom_enabled` entry for `meguru` that the old row wrote is now dead.**
Nothing reads it, and nothing sweeps it — delete it by hand or ignore it, the way
`meguru.sqlite3` and `cache/meguru/` are handled.

**Panels+ present means Meguru takes no part — and the test is per press.**
`hl._panels_plus_plugin` and `hl._panels_plus_original_panel_zoom` are that plugin's
own fields, set together when it takes the gesture and cleared together when it gives
it back. They answer the question that matters — *is Panels+ what will handle this
press* — where "is Panels+ installed" answers a different one. A reader who has it
installed but **switched off** is asking for someone else's panel zoom, and Panels+'
own wrapper delegates to the original handler in exactly that case; standing down on
mere presence would take panel zoom away from them. The check is per press and never
cached, because which plugin patches `onPanelZoom` first depends on the order their
directories sort in.

**The stand-down has to cover the three `panel_zoom_enabled` wraps too, not just the
viewer.** Those wraps put `Settings.panel_zoom` onto a book with no answer of its own
— so with the preference off they would set `panel_zoom_enabled` false, which is the
very field Panels+ gates its own handler on: Meguru would be switching off the plugin
that replaced it. So when Panels+ owns the gesture, `installPanelZoom` installs
nothing at all, and the `Panel zoom in Meguru books` row is hidden — Panels+ forces
`panel_zoom_enabled` on, so the row would be a control that reads one way while the
panels behave another.

### The sequence

**A long-press shows the page's panels in reading order, one at a time.** It used to
show exactly one: the region under the finger, in a bare `ImageViewer`.

`meguru/panel.lua` is the detector, and it is pure: a decoded page goes in
(`Image.rasterFor`), ordered panels come out in **full native** coordinates. It
knows nothing about documents, pages or fetching — `MeguruDocument:getPanelsFromPage`
is the seam, and it hands over one decoded buffer and takes back a list.

**A panel is a quadrilateral, and its rectangle is only the box around it.** The
cut reasons about rectangles, because every projection and every gutter in it is
axis-aligned — but the panel a reader is shown is bounded by *lines*, and a panel
whose borders are slanted is the case this detector exists for. So a panel carries
both: `x, y, w, h` is the bounding rectangle, and `planes` is the four
half-planes of the quadrilateral inside it, `A*x + B*y + C <= 0` for the inside.
The two are the same rectangle on a page whose panels are square and differ by a
wedge wherever one is not, and that wedge is what a rectangle crop cannot help
showing — the strip of the panel next door that runs along the slant. `planes` is
what the crop is cut to and what a touch is tested against; the box is what MuPDF
is asked for, because a pixmap is a rectangle and a clip path is not available.

**The cut's own lines *are* the panel's borders, which is why this costs nothing
to know.** A sheared split puts its separator on the line of constant index in the
sheared projection — `y = split + slope * (x - xmid)` — and `xmid` is the region's
own mid-line, so the value the projection found *is* the separator's position
there. Measured against the reported page's ink map, column by column, that line
reproduces the tier separator to within half a cell, and at the region's two ends
it lands on 285 and 247 where the panel's own border does. So the geometry was
always there and the old code threw it away, keeping the integer `split`; `cut`
now carries the four edges down the recursion and a leaf keeps them. A side the
*trim* moved inward is the panel's own border and becomes that constant; a side
still sitting where the region's was was made by a split and keeps the split's
line.

**A panel is a band of a page, and the cut finds it by slicing on the widest empty
band.** The page is scaled to a 480-pixel *width* scan; the background is the
**median luminance of the outer one-percent ring** — the median and not the mean,
because a ring that is three quarters paper and one quarter a bleed has a mean the
page does not contain anywhere — and a cell is ink when it departs from it by more
than `PANEL_INK_DELTA`. The map is then sliced recursively: find the widest empty band
across the region, split there, recurse into both halves, and stop when a region has
no empty band left. Comic and manga pages are laid out as nested bands — a page splits
into tiers, a tier into panels — so the cut reproduces that structure directly. The
one piece of the reference's background estimate that is not redundant is carried
over: a mid-grey median is overridden to white when some row or column of the page is
genuinely near-white, which recovers a paper colour dimmed by a scan.

**The map is 1.3's with that one exception, and "a faithful port of 1.3" was true of
the cut and not of the input to it.** The override comes from the *newer* reference,
which has a colour-aware map; 1.3's `_pagebitmap.lua` is 327 lines over a single
grayscale scalar with no colour path at all. The override is kept — it is earned on
dimmed scans — but it is named here so it is not mistaken for part of the port, and
it cannot have caused the pale-band failure above: its condition needs the ring
median in `[32, 224)`, and a page with a white band has a white border.

The one input that *was* wrong is the luminance, shared with the crop scan; see the
colour section for what the mean did to a tinted page and why the fix is a formula
rather than a threshold. **Anything that reads this map reads a luminance, and every
new reader of it must too** — a consumer that computes its own brightness is how the
divergence that produced a spurious panel got in.

Two things complicate the cut, and both are ported. Panels are rarely drawn square,
and a gutter tilted by two degrees leaves no column empty from top to bottom — enough
to stop the straight cut dead. When no straight gutter exists and an axis already has
a near-empty line, a ladder of slopes from under a degree to eight and a half either
way is tried instead and the projection is taken along the slanted line. **The split is then one line
through the middle of the empty run that projection found** — a run of empty *lines*
in the sheared projection is a run of empty *columns* through the region's own
mid-height, because `shift` is measured from the region's mid-line and is zero there —
and the two children are cut apart at it, so their crops do not overlap at all. A
rectangle cannot follow a slanted separator, so each child keeps a wedge of its
neighbour on one side and gives one up on the other; which way round that falls
depends on where on the page the reader is looking, and it is the price of the crop
being axis-aligned.

**The ladder's step is 0.015, and it was 0.035 — a reader found the reason.** They
reported that panels separated by a *slanted* gap merge more often than square ones,
and that is the shear's own arithmetic: `floor(slope * (x - xmid) + 0.5)` means a
ladder half a step off the true angle walks the gap across the region, and at 0.035
the drift over a 480-cell width is up to 8 cells. A separator two cells thick then
spreads over three or four projected lines and **none of them is empty**, which is
the one thing `PANEL_SHEAR_INK_RATIO` will not forgive. The measurement, on the
second chapter: a 0.005 step — six times the work — gives the *identical* panel
count on every page tried, so 0.015 is not a compromise; the finer ladder moves one
page (its 35, 3 panels to 4) and nothing else, including the first chapter's
reference page at 6 panels, whose tier separator sits at 0.115 and is therefore
nearer this ladder's 0.120 than its 0.105.

**Handing both children the whole projected band is what this replaced, and it is the
worst defect this detector has had.** Widening the run by `drift` at each end gives the
axis range the separator sweeps over the *whole* region; both children were given all of
it, so each crop overlapped the other by twice the drift and the cut itself landed up to
`drift` cells away from the separator. `drift` is `|slope| * extent / 2`, which on a page
whose tiers are tilted is not a wedge but most of a panel: on the reported Kavita page —
480-wide scan, 6.5 degrees, a 482-cell region — `drift` is 28 cells, a 5-cell run became
a 61-cell band, and a two-panel split cut 30 cells above the boundary left one child
holding the bottom of both tiers. That child then had the tier's black border line
running through it, which is ink where the *next* split needs emptiness, so it never
split again and came out as one panel where the page has two; and the child on the other
side of the band was carved into thin full-width strips by the recursion re-finding the
same band. The page went from `7 panels` to `6` and from one of them being right to five,
measured with `tools/panelprobe.py`.

The two ratios are separate constants (`PANEL_GUTTER_INK_RATIO` and
`PANEL_SHEAR_INK_RATIO`) and the reason is arithmetic rather than taste: the sheared
projection samples every `PANEL_SHEAR_STEP`-th column, so a line's count comes from half
as many cells and carries twice the variance, while its `span` is `width / step` — so
the same ratio buys the same cells of allowance on a noisier projection. Give it the
straight cut's ratio and a near-empty line *through white artwork* reads as a gutter; the
shear then splits a panel down the middle of its own drawing, each child re-finds that
line a little higher up (the found extent moves as the region shrinks), and the strip it
peels off at the end is emitted as a third panel that is really the gap. That is exactly
what a page of two panels divided by a skewed white band did: `2 panels` became `3`, the
middle one carrying the bottom of the upper panel and a strip of the lower. Requiring the
sheared line to be **empty** — the same standard the straight cut is named for — gives
two panels, and on a sample of two dozen pages it changes nothing else.

**A second rule guarded the band's other symptom, and it is now inert.**
`segment` drops **a leaf contained entirely in another leaf**, on the map's cells before
the conversion to native, where the comparison is exact. It was written for what the band
did next: a child split again on the band it had been handed left a strip behind whose
top reached back over the other child's box, so the reader saw the same artwork twice and
the lower panel lost its top. It was measured over two dozen pages of two chapters then,
and fired on two of them. With the split taken as a line the children are disjoint along
the axis they were split on and a trim only shrinks one, so no leaf can contain another —
across the 23-page sample it now drops nothing. It stays because that is a property of the
shape of the cut rather than of this code: it costs a few hundred integer comparisons on a
list capped at `PANEL_MAX_PANELS`, and the change that would make it live again is a change
to the cut. Removing it on the evidence of a sample where it does nothing is the exact
mistake its own history records — see the comment in `segment`.

The two rules cost different things and neither is free. The strict ratio could
regress a page whose separator is a real gutter carrying JPEG noise, since the sheared
line must now be genuinely empty. The containment rule drops an **inset panel** — a
small panel drawn inside a larger one — which is believed rare (the surround would
have to be a rectangle for the cut to produce one) and has not been measured on a page
that has one; if a small panel ever goes missing, that is the first thing to look at.
The other is page furniture: a scanlation
credit line clears both size floors comfortably, so `emitLeaf` rejects it on the
*conjunction* of elongated and nearly inkless. Neither test works alone, and that
function's comment carries the measurement that says so.

The scan targets the page's **width**, not its long side, and that is not cosmetic: a
1600x2400 page maps to 480x720 — one cell per 3.3 page pixels, so a 10-pixel printed
gutter is 3 cells wide. A ceiling on the long side would give 320x480, one cell per 5
pixels, and the same gutter 2 cells wide. `PANEL_SCAN_MAX_CELLS` then caps the cell
count, and it first bites past 5.2:1 — a webtoon strip, and only a webtoon strip.

**A separator one line thick is a separator, and the floor was refusing it.**
`min_gutter` was `max(2, floor(min_dimension * PANEL_GUTTER_RATIO))`, and on this scan
geometry the shorter side is the *width* — 480 for every page that fills the screen — so
`floor(480 * 0.005)` is 2 and the floor never bound. The second reported chapter has
nodes that merge with a line already *under* `PANEL_GUTTER_INK_RATIO`: a row with 2 ink
cells out of 450 against an allowance of 2.25, a column with 2 out of 198. They were
refused for being alone. **`PANEL_GUTTER_RATIO` is 0.004 and the floor is 1** — two
numbers because the floor alone cannot do it: 0.005 of 480 floors to 2 whatever the
floor says. Measured over 21 pages the change moves exactly two of them — `p33` 2→3 and
`p100` 1→2 — and leaves every other page identical, including all three full-page
illustrations, every dense action page, and both control sets. The other merged nodes on
those chapters have no such line at all (82 ink cells out of 480) and stay merged; see
Known open items for the three ways that was measured against.

**The thresholds are 1.3's, and this is the part to read before "improving" anything
here.** `panels_plus` ships this same cut; its later version loosened
`segment_gutter_ink_ratio` from 0.005 to 0.05, doubled the minimum panel area and
switched `segment_shear` off. Porting that later version's code *with its own numbers*
produced exactly what a reader would report: a panel cut in half on a white band
inside its own drawing, because at 0.05 anything faintly bright counted as empty; and
no cut at all on a skewed page, because the only answer to tilt had been turned off.

| | 1.3 — used here | later version |
|---|---|---|
| gutter ink ratio | **0.005** | 0.05 |
| shear | **on** | off |
| min panel area | **0.005** | 0.01 |
| live detector | this cut | connected components |
| what the components give | **a veto on a split** | the panels |

**The connected-component detector is deliberately not ported as a detector.** It
groups ink into connected bodies and keeps each one as a box, merging only boxes that
entirely contain one another. So a component and the panel it sits inside stay two
boxes, and the reader sees the same panel twice with slightly different crops. The cut
cannot produce that: its leaves are disjoint by construction. That is the whole
argument, and it is why "the reference's live detector" is not by itself a reason to
port something — the reference's live detector is whatever its authors last switched
on, not a verdict.

**Its bodies of ink *are* ported, as a veto on the cut — and that is what closes the
`05790d1` question rather than re-opening it.** `05790d1` replaced the cut with the
component detector on the grounds that a genuinely white band *inside* a panel was
being cut in two; `9c9f042` put the cut back, on the grounds that the component
detector showed the same panel twice — and neither commit had a device reading behind
it. Both were right about their own symptom and neither had to lose: the cut keeps the
detection and the crop, and the bodies say only where a panel's box *is*, so a split
can be refused when its band would run through one. So the thresholds are the part to
keep *and* the algorithm is not the part to swap — what came across is the evidence,
not the pipeline.

`meguru/panel`'s `collectBodies` is the reference's `collectComponents` and the frame
evidence it carries, and nothing else. Left behind, each for its own reason: the
containment rule (a box inside another is a *subset* of the veto it is already under,
so it would be dead weight), the sampled small-box frame test, the joining of floating
bodies to the framed neighbour or tier they belong to, and the tier grouping — none of
which the veto needs, because it wants a panel's box and not the final list of panels.
`lineSupport` and `frameSides` are 1:1, values included, and the five `PANEL_BODY_*`
constants are the reference's own; the prefix is this file's so that what they feed is
not mistaken for a detector. The one structural departure is that the scratch arrays
are allocated per call rather than held for the process with a `clearScratch` to release
them: a detection is a long-press, the peak is the same either way, and a second
lifecycle is one more thing to keep in step.

**The rule, and the drawn page that decides it.** A candidate split is refused when the
band it would cut on lies strictly inside a framed body's box on the cut axis *and* the
body spans the region on the other — a band at the body's own edge is that body's frame,
and cutting along a frame is what the cut is for. Refusing one candidate leaves the
other axis to be tried; refusing both leaves the region emitted as **one leaf**, and the
sheared search is not entered at all, because an empty line that ran through a detected
panel is evidence that the region *is* that panel and a slanted split of it is the same
mistake at an angle.

The page that proves the rule is drawn rather than found, and the arithmetic is why the
control that already existed could not do it: **a row of the band carries the panel
frame's two vertical strokes**, and a row counts as empty only while it holds at most
`PANEL_GUTTER_INK_RATIO * span` cells — 2.21 of the 443-cell span a 1600-px page maps
to, one cell being `native_w / 480` page pixels. A 5-px stroke is 2 cells a side, so
4 > 2.21 and `controls/02_white_band_inside` does **not** reproduce the failure: the cut
returns one leaf there, and always did. A one-cell frame does. On a 480x720 page, where
the scan *is* the page, a framed panel with a dense stipple and a full-width hole
through its own drawing gives **2 leaves without the veto and 1 with it** — the panel cut
in half at the hole, and then whole — while the same page with the hole stopped short of
one side gives 1 either way, which is the guard's other half: it must not fire where the
band was never a gutter. In the probe the whole thing is visible in three lines: the body
`19,19 443x683 sides=4`, `veto rows 345..374 runs through body 19,19 443x683`, and the
leaf count. `--noveto` is that same run with the body pass emptied, and it is byte for
byte the parent commit on every page tried.

**On the 15-page sample the veto changes nothing at all, and that is the honest result
rather than a reason to drop it.** All 15 come back with identical leaves — counts and
boxes both — before and after; two of them (p113, p115) refuse a candidate that the
other axis would have won anyway. The reason is that the cut on this chapter mostly
*merges*: p112 returns the whole page where the component detector returns four panels,
and merging is the one failure a veto cannot make worse. The rule is kept for the same
reason the containment filter is kept — it guards an invariant this sample does not
happen to exercise — and the drawn page above is the evidence that it lives.

Also not ported: the comic border-stroke plane (`segment_border_split`), off in 1.3's
own defaults and for a good reason — at map resolution a shared border between two
bled panels and a black line drawn *through* one panel produce byte-identical maps, so
the pass splits real panels in half on any page carrying such a line.

**There is one detector, and it replaced two.** `getPanelFromPage` used to carry its
own conservative gutter scan as the fallback; two detectors meant two different crops
for one page depending on which path asked. It is now a thin wrapper returning the
panel `Panel.indexAt` finds under the touch, and it passes a **constant** direction:
in the detector the mode orders the list and nothing else, and this function returns a
rectangle rather than an index, so the order cannot reach the answer.

**Order is a reading direction, and the direction is the book's.** The list is grouped
into rows by each panel's **top edge**, with a tolerance that shrinks with the
shortest member seen so far — measured against the row's *fixed* top and never chained
from the previous member, which is what stops a staircase of slightly lower panels
from growing one row down the page. Each row is then sorted left-to-right for a comic
and right-to-left for a manga, and a panel that sits beside a tall later-row neighbour
is held until after it (the `1,2,3,5,6,7,4` order). The direction comes from
`Reader.panelZoomMode(ui)`, which reads `ui.view.inverse_reading_order` — **not**
`Settings.get("manga_order")`. That preference is only the floor of KOReader's
cascade; the view holds the resolved value, which is what turning a page already
obeys. The document is told the mode rather than reading it, because a document has no
view.

**The viewer is four overrides on `ImageViewer`, and stock does the rest.**
`ui/panelzoom.lua` passes a list of **lazy functions** — `ImageViewer:init` and
`switchToImageNum` both call an entry that is a function — so panels the reader never
reaches are never rendered, and each render goes through `drawPagePart`, whose LRU
decides whether it is fresh work. `image_disposable = false` everywhere: those buffers
belong to the document's tile LRU, and `cacheTile` is what frees them.
`images_keep_pan_and_zoom = false` is what makes the navigation *classic*: a panel
opens at best fit instead of inheriting the previous panel's pinch.

**The viewer draws no chrome, and the last piece to go was stock's progress bar.** It
is turned off with `images_list_nb = 1` in `PanelZoom.open`, which is *not* a count:
stock builds, draws and frees the bar behind one `_images_list_nb > 1` test, so the
field is the switch and nothing else. That the reader shows no bar either is the reason
it went — Meguru hides the footer, and the progress bar lives in the footer.

**`images_list_nb` must not be read back as the panel count, and this is the edit that
would break panel navigation silently.** `onShowNextImage`, `onShowPrevImage` and
`meguruWarm` all bound themselves by `#self.panels`, which is the truth; with the field
at 1, a bound taken from it makes every forward gesture fall through to the page
boundary, so the second panel becomes unreachable and the symptom looks like broken
navigation rather than a hidden bar. **`tools/check.py` cannot see this**: it keys on
names, and a field reached through `self` is not one. The gesture is the test.

The four overrides are `switchToImageNum` (recompute `rotated` per panel, then release
the one left behind, then re-arm the warm), `onShowNextImage` / `onShowPrevImage`
(boundary past either end), and `onTap` / `onSwipe`. **Those last two exist for one
reason:** stock picks the sides from `BD.mirroredUILayout()` — the UI language — and a
manga read in a Polish UI gets stock's answer backwards. Everything else is delegated
to stock, including the tap outside the frame that closes the viewer and the
bottom-left screenshot corner, which are deliberate gestures this must not quietly
take over. The hardware keys come free: `ImageViewer:init` binds `PgFwd`/`PgBack` to
next/previous image and `Back` to close whenever `image` is a list.

**A panel is turned the book's way.** With `Rotate wide pages: left` the *page* goes
left, and a panel wider than the screen used to be able to go right: the page is
turned by `Screen:setRotationMode` in the setting's direction, while a panel is turned
through stock's `rotated` — a **boolean**, whose 90-vs-270 direction stock computes
*inside* `ImageViewer:_new_image_wg` from screen parity and two KOReader globals, with
no caller-facing input. So the direction has to come from somewhere, and it comes from
the same row.

**The two words map onto opposite quarters, and that is the part to get right.**
`Rotate wide pages: left 90°` names a turn of the **device** — the screen is rotated and
the reader turns along with it, so the row's word describes what happens to the hand,
not to the glass. A panel has no device to turn: it is rotated *inside* the screen the
reader is already holding, so the same reading position is reached by the opposite
quarter. Left in the row is a counter-clockwise device, so a **clockwise** panel.

That crossing was first derived the *other* way, from stock's own comment
(`rotate_clockwise and 270 or 90`, "unintuitive, but this does it"), and the device then
turned panels the wrong way — which is the cheapest possible lesson in why a mapping
read off upstream's prose is not an observation. The fix was the two constants in
`panelRotationAngle` and nothing else, which is the shape this was designed to fail in.

The two rotation questions are **split, and that split is the design**:

| question | answered by | source |
|---|---|---|
| *whether* this panel is turned | `panelRotations` + stock's `rotated` | the panel's shape against the screen's |
| *which way* | `panelRotationAngle(self.rotated, self.rotate)` | the book's `Rotate wide pages` |

`rotate` is `"left"`/`"right"`/nil, resolved once per press by `Reader.panelZoomDirection(ui)`
in `ui/reader.lua` — reading `configurable.rotate_wide_pages`, **never**
`Settings.get("rotate_wide")`, because that preference is only the floor and every book
already opened has written its own answer into its sidecar — and handed to `PanelZoom.open`
beside `mode`, including through the handoff, which is the half that is easy to forget and
fails only at a page boundary. nil is the row off, and then every rotation decision is
stock's, byte for byte.

**The Rotate button needed no change at all, and that is the proof the split is right.**
Stock's callback flips `self.rotated`; the resolver reads it. *Whether* belongs to stock,
*which way* to us, so the button keeps working, its `Rotate` / `No rotation` label stays
true, and nothing has to be kept in step. The same property gives "a tapped rotation lasts
one panel" for free: `switchToImageNum` already reassigns `rotated` from the automatic
decision on every change, so the press is scoped to the visit with no state to carry.

**Where the direction is applied is a correction after the fact, and it is worth knowing
why that is safe.** Passing an angle would mean copying `_new_image_wg`. It does not have
to be copied: `ImageWidget` defines no `init` (`Widget:new` calls one only when it exists),
and `_render` — the only reader of `rotation_angle` — is entered from `getSize`/`paintTo`
and returns at once when `_bb` is already set, which nothing does before the first layout.
So `PanelViewer:_new_image_wg` calls stock and then writes the angle, and between the
widget's construction and `update`'s first `resetLayout` that is equivalent to having
passed it. A guard plus a once-per-process `logger.warn` makes the assumption checkable;
if it ever fires, the repair is the forked override, and the device check that shows it is
item 21.6.

Rejected, each for a reason worth keeping: **pre-rotating the tile** (`BlitBuffer:rotatedCopy`)
— a buffer outside the document's tile LRU that the viewer would have to own and free,
and it would leave the automatic path on the boolean while the manual path used the tile,
two mechanisms for one outcome; **forking `_new_image_wg`** — ~30 lines of upstream that
then silently diverge as upstream gains parameters; **turning the screen**
(`Screen:setRotationMode`) — a rotation `rotate wide pages` already owns for pages, with
`session_wide_rotate` to keep in step, and it turns the whole UI rather than the panel;
and **writing `imageviewer_rotation_portrait_invert` / `..._landscape_invert`** around the
parent call so stock computes our direction — it mutates a reader's global settings, and
any save in that window persists it.

**Pre-warming is two machines, and neither is new.** The *panel* half reuses the tile
LRU: `drawPagePart` already stores what it renders under `page|panel|region`, so
rendering the next panel a moment after showing this one makes the swipe a cache hit.
The *page* half warms the next page's decode **and then its panel detection** — in
that order, and the order is load-bearing. `getPageDims` is the decoder and the thing
that fills `self.dims`; `getPanelsFromPage` prepares a page through `panelNativeFor`,
which fetches and decodes but never touches `self.dims`, so calling it first would
leave the dims cache empty and the page turn the reader is about to make would fetch
the same page again. Dims first means one fetch, one decode, a native-LRU hit for the
scan, and both memos filled. One scheduled action re-arms on every panel change, and
the delay is the point — a reader swiping quickly re-arms and unschedules faster than
it, so the warm never does work they did not ask for. The guard is
`UIManager:isWidgetShown(self)`, which is the whole bookkeeping: a viewer that has been
closed or handed off is off the stack, so its queued warm is a no-op. Both branches are
gated on `dead_pages` and the page branch on `hasConnection()`. **Do not add panel
detection to `analyseAhead`**: that runs inside every page turn, and a scan per turn
is exactly the cost this delay exists to keep out of the gesture.

**The panel cache is four entries, in RAM, keyed on the page *and the direction*.**
Detection walks a few hundred thousand cells, so the answer is worth keeping — but only
for the window a reader moves in from the panel viewer, which is "this page, the next
one, and back again". It caches the **refused** answer too: a refusal costs exactly
what an acceptance costs, and a refusal is a real answer now, so a splash-heavy book
would otherwise be rescanned at every press. The key carries the reading direction
because the direction reorders the list, and a Manga-mode flip mid-session must not be
answered from the other direction's order. It is a **self-ordering array, not
`evictOldest`** — that one stamps through `self.stamps`, which `native` shares and keys
by a bare page number — which is the same reason `page_bytes` is shaped that way. A
page that could not be *decoded* is deliberately not cached: `fetch_failed` and
`dead_pages` already remember the two ways a page goes missing, and a third answer
would be a third thing to keep in step.

**A page the detector cannot read opens the whole page, not nothing.** `Panel.detect`
returns `panels, accepted, reason`, and `panels` is never empty once the page was
readable: a refused page comes back as one rectangle covering the whole page with
`accepted` false and the failing test in `reason`. So a long-press always has something
to open, and the log can always say which of the two it is looking at — `K panels`
versus `K panels, whole page (<reason>)`. This is why the reader's gate is
`if not panels` rather than a count: `nil` means exactly one thing now, that the page
would not decode, and that is the single case that still falls through to stock. The
cost is that a page the detector *misjudges* shows the whole page where stock would
have cropped one region; the acceptance tests are what hold that back, and the reason
string is what makes it diagnosable when they don't.

**`releasePanelTile` is memory, not correctness — and the difference matters, because
the wrong reason has been written down once already.** `evictOldest` frees a tile's
buffer, so the fear was that it could free the bitmap the viewer is displaying. It
cannot: `drawPagePart` bumps on every hit and `cacheTile` bumps on insert, so the panel
on screen is always the most recent entry and eviction takes an older one. The real
cost is the other direction — one dead panel tile per step, up to seven of them at 8
entries, each bounded only by `max_native_pixels`, **and** the page tiles ReaderView
needs evicted alongside. Handing each panel back keeps the LRU at two: the one on
screen and the one warmed. The key is built by one function (`panelTileKey`) read by
both the write and the release, because a key that drifts frees nothing and says
nothing. The price is the one this design was asked for: **going back to a panel
re-renders it** — from bytes still in the page LRU, so still offline, but re-rendered.

**The page boundary is four statements in a fixed order.** At the last panel, forward
means the next page; at the first, back means the previous one, opened at its last
panel. Inside one `tickAfterNext`: resolve the next page's panels **first**, so a page
that will not decode leaves the reader where they were rather than dismissing their
viewer and handing them nothing; close the viewer **second**, before the turn, because
a page turn can reach `installEndOfBookHook` and swap the whole reader out — a viewer
still on the stack would float above a different book; then `GotoPage` (exact, unlike
`PageForward`, which is a "next view" that is a page only because this plugin forces
`page_scroll` off); then open the new viewer against the layout that resulted. The
panel lookup is gated on `hasConnection()`. The cost, accepted: the reader paints the
new page under the viewer, so a boundary crossing is one extra e-ink pass.

**Logging follows the frequency rule.** `Meguru: page N panel zoom: K panels, whole
page (<reason>) (mode) in X ms` — the milliseconds are the measurement of the scan, the
cut and the acceptance tests, and the only place their cost can be seen; the bracketed
form is what separates a refused page from a page that genuinely has one panel, and
those need opposite fixes. `... no page (<reason>)` is the one case with nothing to
open. The stand-down is `info` — a decision, once per process. A detection or handoff
that *throws* is `warn`, which is what `crash.log` is read for. There is deliberately
**no** separate "panel warmed" line: the existing `panel zoom on page N, region ...
rendered WxH` already fires once per panel render, including once per warm. The one
line that names the *view* is the viewer's own open line — `... (mode) window view,
step S of T` or `... (mode) cropped panels` — and the step count is deliberately not
`K panels`: the two are the same detection and different walks, which is the whole
point of the second view.

### The other view: a window over the page

**A long-press opens one of two views, and the preference picks which.** Cropped — the
panels cut out of the page, each its own image, quad-masked. Or *window*: the page
stays whole and a rectangle moves over it at one fixed zoom, anchored to the panel's
edges. `Panel view` is the row; `meguru/settings.lua`'s `panel_view` is the value; a
*refused* page ignores it, because a page the detector would not decompose is one
whole-page rectangle and a window would cut it into a top and a bottom nobody asked to
step through. Everything else — the detector, the reading order, `Panel.indexAt`,
navigation, the pre-warm, the page boundary — is one implementation for both, which is
what makes this a second view rather than a second feature.

**A step is a rectangle of the page, and nothing is cut.** Where the cropped view asks
`drawPagePart` for a panel at the region's own size, the window asks for a viewport at
*screen* size: `tw`/`th` are two optional arguments the cropped path passes as `nil`, so
its call is unchanged to the byte and `Panels+` — which calls `drawPagePart` directly —
never sees them. The tile is filed under `panelTileKey` **plus its size**, because the
same rectangle at another size is another picture and the size cannot be recovered from
the rectangle. That is also why `meguru/viewport` rounds its windows to whole page
pixels: the key formats the rectangle with `%d`, so a fractional window would be filed
under a key naming a rectangle it was not rendered from, and two windows a fraction
apart would share a tile. Rounding is what makes the render-path log line truthful too.

**The zoom is a scale, and it is the one number that had to change shape.** `Viewport`
used to hold a constant of its own; it now takes *screen pixels per page pixel* from its
caller, because that is what a level is once it stops being hardcoded:
`fitScale(dims, screen) * level`, with the level the reader's. Nothing in the geometry
stores or chooses it, and there is no constant left to move by accident.

What the scale decides is how many stops a panel takes — one for a panel the window
covers, two for one too big in one axis, four for one too big in both — so the level is
not cosmetic. Measured on a 1600x2400 page against a 1236x1648 screen: 1.4x covers
1286x1714 page pixels, 1.7x 1059x1412, 1.9x 947x1263, and the render is the screen's
pixels at every one of them, to within a pixel or two — the window is rounded to whole
page pixels (the tile key names it), and that rounding times the scale is the residual.
It is under a pixel until the scale passes 1, which is a page smaller than the screen.
The default is **1.7**, the middle of the three: a typical page then renders at about
1.16 screen pixels per page pixel, a mild magnification of the file rather than the 1.30
that 1.9 asks for.

**The zoom is chosen from the viewer's own button row, and stock's row had to be
rebuilt to hold it.** Stock's row is Scale/Original size, Rotate, Close, and in this
view two of the three mean nothing. *Scale* sets the *viewer's* scale factor, and every
step here is already a screen-sized render shown at best fit, so it changed nothing
while its label promised something else; *Rotate* turns a picture, and nothing turns in
this view — a window is the screen's shape, and a panel too wide for it is walked side to
side. So the row is rebuilt holding the zoom and Close, and what the reader gains is the
level right where they can see what it does: tapping it cycles 1.4, 1.7, 1.9 and writes
the preference, so the next page, the next book and the next start keep it. That is why
there is no menu row for the level — the choice moved into the viewer, the store did not,
and `ui/reader` still reads it and hands the number in.

Two details of the rebuild are load-bearing. Stock builds the table inside `init` and has
no way to take a button out of one, so the table and its container are replaced whole —
both stock's own widgets, with stock's own shape. And **`update` re-letters the two
buttons it expects by id, and does not check that they are there**, so a row without them
is a nil call inside a paint: they are answered by seeding `button_by_id` — the map those
lookups read — with buttons that are not in the row at all. None of stock's code is
patched, and if the table is not where it was the row stays stock's and a `warn` says so
once, the way the rotation angle does. **The whole rebuild is `pcall`ed**, because the
row is cosmetic: a failure there must cost the reader the zoom button and not the view.
That is the rule the crop mask already follows on the render path ("costs the crop and
not the panel"), and it is also what bounds the blast radius of exactly the crash this
was found by — a viewer built, then left unshown by a throw inside the row, with a
repaint still queued on it naming a frame the close then took away.

**The chain is a simulation of the forward gesture, not a list per panel.** Where the
next step lands depends on what is *already on screen*, not only on which panel the
reader is in — so `Viewport.steps` walks the page's panels once and emits the rectangles
the reader will actually visit:

- a panel **wholly inside the window as it stands** gets **no step**. The chain does not
  stop for it; the question moves to the panel after it, and one tap can pass several
  small panels at once. This is the case the mode exists for on a page with a grid of
  them beside a full-height one;
- a panel that does not fit gets a step, anchored to **its own edge**: the panel's start
  edge at the window's edge, then — if it still does not fit — the panel's end edge
  there. A panel that fits in an axis is *centred* on that axis, since a window larger
  than the panel cannot be flushed to anything;
- the entry is a long-press *point*: the view is centred on the finger and clamped to
  the panel, and it *takes the place* of one of that panel's own views rather than being
  inserted beside them — see the rule further down for which, and why the steps before
  the touched panel survive it. **A caller that names a panel with no point** — which is
  how the page boundary hands over, and the only way it does — gets that panel's own
  stops walked, the viewer opened at one of them, and the panel never skipped, since the
  caller named it. Which one is `entry.at_end`: the **first** stop going forward, and the
  **last** coming back, because a reader crossing back into a page arrives at it from
  below and the corner nearest where they came from is the end of its last panel. Two
  bugs lived here. Before the flag, crossing back asked for the last panel and opened at
  step 1 — the whole page, read from the top. Before the fix that introduced the flag,
  the first version of this opened at the first stop of the named panel and made the
  reader press forward to reach the bottom of a page they had just come *down* from.

**There is no stage to keep and no "read" flag to set.** A skipped panel is one the
chain never stopped at; the reader's place is the step index. State that nothing reads
is state that drifts, and the two things the design was asked to store — which stage of
a panel, which panels are read — are both already implied by the rectangle on screen.

**The stops inside a panel are its corners, and a panel too big in both axes gets
four of them.** One rule per axis — centred on an axis the panel fits, anchored to
both of its edges on an axis it overflows — crossed in reading order. That gives one
view for a panel the window covers, two for a panel overflowing one axis, and **four,
corner to corner, for a panel overflowing both**. The four is the one worth defending:
the first version anchored such a panel to its start corner and then its end corner,
which covers the middle twice and leaves the other two corners **never shown at all**.
A reader reported it, and the fix is the cross product rather than the pair.

**Which axis it is changes nothing, and that is worth saying because it is the one
asymmetry a reader would notice.** A panel **taller** than the window is walked from
its top edge to its bottom edge, exactly as a **wider** one is walked from its left to
its right, and the forward gesture takes both stops before the panel after it is
reached: a panel is not left half read because it was tall rather than wide. The two
differ in one place only — the horizontal pair swaps with the book's direction, and
the vertical pair does not, since both kinds of book are read down the page.

**The horizontal direction is a parameter, and it is the book's.** Which side of a
panel the window stops on first, and so the order of a row's two corners, follows
`mode` — left to right for a comic, right to left for a manga. The detector already
hands the panels over in reading order, so this is the only place in the plugin where
direction is not decided upstream of the view; it travels into `meguru/viewport` as a
boolean beside the panel list, resolved from the same `mode` `ui/reader` hands to
everything else. The vertical order needs no flag: both kinds of book are read down
the page.

**Where the reader tapped, their view stands for one of the panel's own.** On a
corner, it stands for that corner and the others follow; between corners, for the
first, which is the rule this has always followed and is why a tall panel tapped in
the middle goes straight to its lower edge rather than back up to a top they chose to
skip; and for **none** on a panel that fits, because there its one view is the only
thing that shows the whole of it — which is what keeps a tap the page's edge clamped
from leaving the panel half seen. What is left over: a tap *between* corners of a
panel too big in both axes stands for the first corner, and if the tap is near the
opposite one, that first corner's region is only partly covered by it. The views after
it are all there, and the corner they leave is a sliver of the panel rather than a
quarter — the alternative, resuming from the tap, is what lost corners in the first
place.

**What it reuses, unchanged.** `ImageViewer` and its four overrides: with the image
screen-sized and best fit still `scale_factor == 0`, `onSwipe`'s gate, `onTap`'s thirds,
the hardware keys and the close contract all behave exactly as they do for a panel. The
buffers are the document's tiles (`image_disposable = false`, released on the step just
left), so the pre-warm is the same one call the viewer is about to make, and
`images_keep_pan_and_zoom = false` gives "a pinch lasts one step" for free. The rotation
machinery is not used at all — a window is the screen's shape, so there is no wide-versus-
tall decision to make, and a panel too wide for it is walked in x instead.

## Reading options and the menus

Meguru books share KOReader's per-book `kopt_*` settings, so the bottom `ConfigDialog`
is **curated** rather than replaced: rows the engine does not implement (page margins,
auto-straighten, the reflow and zoom-matrix family) are dropped, because each would set
a value with no visible effect.

The one thing that must not be missed: KOReader's stock "set as default" writes a
**global** `G_reader_settings["kopt_<name>"]`, which would leak a choice made while
reading a stream into every PDF opened afterwards. `ui/reader.lua` redirects it onto
the plugin preference and swallows rows the plugin has no preference for — that
redirection is the reason that file exists.

Invariants when touching these rows:

- **A row's `values` stay in the row's own domain.** `trim_page` is `{3,1}`
  (none/auto), `rotate_wide_pages` is `0/1/2`, the toggles are `0/1`, `fit` is a
  string. `seedRowValue` copies the stored value through verbatim for exactly this
  reason: `0` is a valid choice *and* is truthy in Lua, so any normalising step
  (`value and 1 or 0`) silently turns "off" into "on" and "crop: none" into "crop:
  auto".
- **`sorting_hint` must name an existing menu item, in that surface's own order
  table.** `menusorter` does `findById(...)` and then indexes the result without
  checking, so a hint naming nothing throws out of the entire menu build and takes
  every other plugin's row with it. `ui/menu.lua` picks it in one place
  (`showUnderTools`, which falls back to no hint rather than a crash), and the hint is
  `"tools"`, which resolves unconditionally in both order tables.
- **A hint alone does not place a row at all.** It is appended to the end of that
  page's row list. Naming the id in that page's order list is what decides otherwise,
  and `showUnderTools` does it for both surfaces, putting `meguru` **directly above
  `read_timer`** — entry 1 of the stock list on both surfaces, so that is the head of
  the page (and index 1, where `read_timer` would have been, on a build without it).
  Position is named by neighbour rather than by index on purpose — everything above
  this row is whatever the user has enabled, so an index would land somewhere different
  on the next device. `profiles` was the neighbour before and sits far enough down the
  list to have stopped being a useful landmark.
- **`separator` and `checked_func` are `TouchMenu`-only; `mandatory` is
  plain-`Menu`-only.** Both menus Meguru registers are `TouchMenu`s on a touch device,
  so both fields are usable in these rows. `text_func` renders on either, which is why
  the destination rows carry their state in the text rather than in a `mandatory` value
  slot.
- **A `Settings` submenu on both surfaces** — the reader's holds eight rows (auto-open,
  panel zoom, panel view, hide status bar, save folder, per-server subfolder,
  `Covers for folders`,
  default reader for `.cbz`), the FileManager's the four that are not about a book
  already open. The FileManager's depth is a deliberate cost, paid so the two menus
  read the same. No `sorting_hint` exists below the top-level `meguru` item — the
  sorter only ever orders a page's own rows.
- **`Covers for folders` is the one thing below `Settings`, and it is an exception
  rather than a precedent.** Its three rows are switches for one feature, and as flat
  rows they would take `Settings` from six entries to nine while naming servers instead
  of the thing they belong to. The level is bought back by the row above them saying
  what the group *is* — which is the whole job `Settings` does one level up, and the
  reason "one level deep" existed. A second such submenu should have to make the same
  argument.
- **The separator is *under* the row that carries it** (`touchmenu.lua:714`), and is
  dropped when that row is last on a page (`touchmenu.lua:713`) — so a separator is a
  hint about the list, never a guarantee about the screen. Two lines split `Settings`
  into its three groups, and each sits on the row that *ends* a group: `Hide status
  bar` and `Subfolder per server`. The FileManager gets both but only the second has
  anything above it there.
- **The FileManager's `Meguru` submenu carries nothing but that `Settings` row.** Both
  surfaces use the key `meguru`, which is safe because the two `menu_items` tables are
  per-surface and never shared, and `Meguru:addToMainMenu` dispatches on whether a
  document is open — so only one is ever written. A saved menu order in `settings/`
  then means the same thing on both.
- **`meguru/association.lua` owns Meguru being the reader for `.cbz`, and it is a
  *claim* rather than a preference.** Meguru registers `cbz` at **weight 1**
  (`main.lua`), the lowest, so registration alone leaves MuPDF the default and this
  engine reachable only through "Open with…". The claim is KOReader's own **file-type
  association** — the same `G_reader_settings["provider"]["cbz"] = "meguru"` the stock
  dialog's "Always open with…" checkbox writes, read by `DocumentRegistry:getProvider`
  *before* it falls back to the highest-weighted provider
  (`documentregistry.lua:91-101`), which is the whole of why a weight-1 provider can
  win. Releasing is the same call with no provider, i.e. what "Reset default for …
  files" does.
  **It is claimed once, on first run** (`Association.claimOnce`, called from
  `registerProvider`), and given back from the menu row. The record of that is
  `Settings.cbz_default_claimed`, and the record is load-bearing: releasing leaves
  `provider.cbz` **absent**, which is byte for byte what a device that never chose a
  reader looks like — so "no association" cannot be read as "not yet claimed", and a
  rule of that shape would re-claim the extension on the next start after the reader
  turned the row off. The one case the record cannot tell apart is a device upgrading
  from the build that had the row and no record, where the claim is made once more; a
  one-tap surprise beats a row that turns itself back on forever.
  Two traps in the API itself: it takes a **file**, not an extension (it reads the
  suffix off the name, so the module passes a name with no file behind it), and
  `setProvider(file, nil, true)` means *reset* — so a provider the registry does not
  know yet would silently do the opposite of what was asked, which is why the claim
  looks it up first and refuses loudly. A per-file choice made in "Open with…" still
  wins: `getAssociatedProviderKey` reads the sidecar before the file type.

## Plugin lifecycle facts worth not rediscovering

- `ReaderUI:showReaderCoroutine` builds a **new** `ReaderUI`, so the plugin loop
  re-runs and instances are fresh for every document. `Reader.install` therefore runs
  once per book automatically.
- Plugin **modules** load once per process (`PluginLoader.enabled_plugins` is cached
  and never reset), so module-level flags persist for the whole session. That is what
  makes `Reader.installStatusBarHook`'s once-per-process guard correct, and what makes
  the `DocumentRegistry:addProvider` guard necessary — `addProvider` only ever appends,
  so a second call would list the provider twice.
- Every menu surface Meguru writes is a `TouchMenu`; the plugin no longer has a
  plain-`Menu` surface of its own.
- `C_` is **not** a global. Every core file declares `local C_ = _.pgettext`; a plugin
  file that omits it gets a nil call only when a row is built.

Three more, about the browser rather than the lifecycle.

**`OPDSParser:parse` returns the document wrapped under its own root element.**
`createFlatXTable` starts from `{}` and assigns the root's children under the root's
*name*, so an Atom feed comes back as `{ feed = { entry = {...}, author = {...} } }`
with nothing at the top level. Reading `.entry` or `.author` off the raw parse result
therefore finds nothing — and silently, because "a feed with no entries" and "a feed
that was never unwrapped" are the same nil. `Net.feedFrom` is the one unwrap, used by
both `Net.parseFeed` and `ui/open.lua`; the built-in browser compensates with
`local feed = catalog.feed or catalog`.

**`OPDSBrowser:parseFeed` parses more than browsable feeds.**
`genItemTableFromCatalog` parses the catalog's OpenSearch descriptor through that same
method, on the same navigation, immediately *after* the real feed. So a feed-retention
rule of "record it if it has entries, clear it otherwise" recorded the series feed and
cleared it again in the same breath. `ui/open.lua`'s `noteFeed` ignores a parse that
is not a feed of entries.

**The row at the top of a series feed is added by wrapping `genItemTableFromURL`, not
`switchItemTable`.** Both were tried; only the first is right. `switchItemTable` is
switched from four places — a navigation, a pagination append, a catalog edit on the
root list, and a search — and only one of them is a series feed, so the row appeared on
the others (a search result list, most visibly). `genItemTableFromURL` is *handed the
URL*, and the URL is what tells the four apart. The decision is made where the evidence
is rather than reconstructed from how the switch was called.

A row with no `acquisitions` is read by `onMenuSelect` as a **catalog link**, and it
navigates to the row's `url` — so a row of ours must carry a marker field and have
`onMenuSelect` wrapped to intercept it. The row buys nothing on its own.

The row is offered only when **every** entry of the feed discovers to the same series.
A feed listing *series* has entries with no stream at all, so they fail `discover` and
the row is not offered — which is why it appears on a list of a series' volumes and
nowhere else. It opens the **first unread** volume, ordered by the number
`Naming.deriveSeries` pulls from each title rather than by feed order, because Suwayomi
browses newest-first and feed order there is the reverse of reading order.

That fresh path also carries the "never silently sync the wrong series" guard: an entry
opened from `on-deck` or `recently-added` comes from a feed listing other series too,
so entries are kept only when `driver.discover` places them in the series being opened,
and the parser sees nothing else. **Filter, never reject the whole feed** — that was
the first version and it was wrong. A Kavita series feed also carries entries with no
stream link (a special, a cover-only row) that `discover` cannot place, so one of them
was enough to send every open back to a stale answer, producing exactly the symptom the
fresh read exists to remove.

### Another plugin may replace the wraps, so they are installed twice

**The four `OPDSBrowser` wraps are installed at plugin load *and* again every time a
browser is constructed.** The second one is the load-bearing one, and the reason is a
plugin called `zenos.koplugin`, which ships a patch of the OPDS browser.

The mechanics are about load order, and none of it is specific to zen-os.
`pluginloader.lua:289` sorts the enabled plugins **by path** before instantiating them,
so `meguru.koplugin` loads before `zenos.koplugin`. Meguru wraps first; zen-os then
replaces `OPDSBrowser.showDownloads` and `OPDSBrowser.parseFeed` **wholesale, without
calling the original** (its `opds.lua:1529` and `:1198`), once per process behind its own
`_zen_opds_patched` flag. Methods a later plugin replaces are methods our wrap is
silently gone from — and nothing reports it, because the browser still works.

**Losing `parseFeed` costs three features, not one**, and that is the part worth reading
before touching this. It is the only writer of `ui/open.lua`'s `last_feed`, and
`last_feed` is what the row above a series feed is built from (`seriesRow` → `feedSeries`
reads `last_feed[name]`) *and* what `openAsBook` reads for `ctx.url` — the feed the
reader is browsing, which for **Komga** is the only place a series id exists at all.

| what is lost | why |
|---|---|
| the button in the download dialog | the wrap on `showDownloads` is gone |
| the row above a series feed | `noteFeed` never runs, so `last_feed` is empty |
| Komga series attribution | `ctx.url` is nil, so `discover` refuses the entry |

The other two wraps — `genItemTableFromURL` and `onMenuSelect` — survive, because zen-os
does not override them; but with `last_feed` empty there is no row for them to place or
intercept. `ReaderUI:showReader` is on a different class and no OPDS patch touches it, so
a marker opened from the file manager or History was never affected.

**`init` is the seam, and it is order-proof in both directions.** Constructing a browser
is the last moment at which the class is settled: every plugin has loaded, every patch has
been applied, and nothing re-patches afterwards. A class-level re-install also reaches the
class the browser actually inherits from, where one done on the instance would not be the
same fix at all. It chains to the original, so it survives being wrapped by someone else:
`OPDSBrowser.init` is `Menu:init` through `__index` in stock, and a foreign patch captures
our wrap off the class and calls it — which is exactly why ours runs at all in that case.
An event was rejected instead of `init` because the OPDS plugin is not on the `UIManager`
stack and so never receives a broadcast.

One sentinel guards it, and **it is per method rather than for the set** — which is a
distinction that shipped as a bug. Four module-locals hold the wrapper we installed for
each method, and `installBrowserWraps` re-wraps only those that are no longer carrying it.
Asked this of the whole set at once — "is *any* of ours missing" — the second pass
re-wrapped the methods the other plugin had *never taken*, so `genItemTableFromURL`
carried two layers of our wrapper and **the row above a series feed appeared twice**. The
same plugin takes some methods and leaves others, so the question has to be asked per
method. That also makes a repeat a no-op (without it the second pass would call `noteFeed`
twice) and makes the whole thing **self-healing**, since any later replacement is repaired
at the next construction. The first repair logs once, at `info`:
`OPDSBrowser re-patched since load; OPDS hooks re-installed`. It deliberately **does not
name the plugin that did it**: detecting one by its private fields would tie this repair
to a foreign implementation we do not control, and the useful fact is that our hooks were
replaced, not by whom.

**Nothing else had to change, and that is the check that this is the right seam.**
`Open.injectBookRow` works against zen-os's dialog unchanged — it sets
`self.download_dialog` (`opds.lua:1738`) with a `.buttons` array and has
`ButtonDialog:reinit()`. **The row goes in at index 1**, above everything the
dialog offers, with a separator under it.

That position is the point, not a preference: the row used to be inserted just
above the dialog's *last* row, which on a build that leads with a download button
and a description made the action this plugin exists for the last thing a reader
reached — it read as an afterthought to the download rather than the reason the
dialog is open. It is also the position that costs nothing to hold: reaching it
by moving the last row meant the row's place depended on the dialog ending with
the row the code expected, and nothing about the rows already present is assumed
any more. The row above a feed renders too, because
zen-os's item widgets read `entry.title or entry.text` (`opds.lua:456`) and our row
carries `text`. Its own "Page stream" buttons, which stream PSE into KOReader's *native*
reader through `opdspse`, are a different feature and are left alone.

**One thing the row does have to carry, and it took a device to find.** A browser that
draws covers keys on `entry.cover_url` alone (`opds.lua:848`, `:916`) — and fills that
field itself in `genItemTableFromCatalog` (`opds.lua:1204`), which runs *inside* the call
the row is appended after. A row added there is one that pass has already gone by, so it
is the only row in a list of covers with none. `Open.seriesRow` therefore sets
`cover_bb` — a bitmap of the plugin's **own** mark, from `meguru/rowcover`, and
deliberately **not** the series' artwork and **not** `cover_url`:

- **Not the series' artwork**, because this row is not a book. Artwork published for the
  series, drawn beside a column of real volumes, reads as one more volume rather than as
  the thing that opens the series.
- **Not `cover_url`**, which is the field a browser *fetches*: that would put an HTTP
  request on this row, on a page already making one request per book for its cover. A
  `cover_bb` is already decoded, so the row costs the network nothing.

Neither `thumbnail` nor `image` would do either: those are what zen-os *converts* into
`cover_url` in that same pass, so setting them is asking a pass that has already run to
run again. And the insertion point must not be moved earlier to reach it — `genItemTableFromURL`
is the seam `switchItemTable` was replaced by precisely because the URL tells a series feed
apart from a search result and a pagination append, and moving it back re-opens that, for a
cover.

The repair a reader has if any of this ever breaks again is the same one a mis-sniffed
kind has: nothing in the UI reaches it, so it is fixed in `hook.lua` or not at all.

**The reader's bottom menu is the same story in a second place, and it is
`rakuyomi.koplugin` that tells it.** Its `MangaReader:addRakuOptionsToReader`
ends by assigning `ui.config.onShowConfigMenu` on the **instance**, wholesale and
without calling the original — its own comment reads `--patch
frontend/apps/reader/modules/readerconfig.lua` — and it does it from a
`registerPostInitCallback`, i.e. after every plugin has loaded. Plugins load by
sorted path, so `meguru.koplugin` is always *before* `rakuyomi.koplugin`: the wrap
`curateConfigMenu` installs at our init is gone before the reader is up, the menu
shows every stock row Meguru was supposed to drop, and nothing reports it.

Three things make the repair what it is, and each differs from the OPDSBrowser one:

- **The guard is the wrapper, not a flag.** `config._meguru_curated` held `true`,
  which stays true after a foreign assignment — so it could not tell "still ours"
  from "replaced". It holds the function we installed now, and a replacement is
  simply a different value in that field.
- **Per instance, never per class.** The replacement is an instance field, which
  shadows the class, so a class-level wrap would be invisible.
- **The seam is `registerPostReaderReadyCallback`.** `ReaderUI:init` fires
  `ReaderReady` and only *then* runs that list (`readerui.lua:517-522`), while a
  post-init callback has already run by the time init returns — so this is later
  than the thing it repairs, provably rather than by appearance. This is the
  `genItemTableFromURL`-not-`switchItemTable` lesson again: the decision is made
  where the evidence is.

Chaining is the other half, and it is why this is not a fight: `orig` is whatever
is in the field *now*, so Rakuyomi's own chapter bar among its buttons survives
ours. The first repair logs once per process —
`the config menu was replaced since load; curation re-installed` — and, as with
the OPDS repair, it deliberately does not name the plugin that did it.

## Updating

**One artifact, and both ends name it.** `.github/workflows/release.yml` builds
`meguru.koplugin.zip` and attaches it to a tag's release; `meguru/updater.lua`
asks `/releases/latest` for an asset called exactly that. There is no second
file anywhere in the flow, and that is the point of the arrangement rather
than an accident of it: an updater that fetches GitHub's own **source archive**
by tag — which `assistant.koplugin` does — is downloading something CI never
looked at, built by a different process, containing a different set of files,
and nothing anywhere reports it when the two disagree. The name is a constant
in two files and is never versioned; an asset called `meguru-1.2.0.zip` would
make every release after the first look like it had no downloadable file.

**The tag check is a failure, not a warning.** `_meta.lua`'s `version` is what
the updater compares a release against, so a release published with a stale one
there is a release that every device already running it will call "up to date",
for good and in silence. The workflow exits 1 on a mismatch, and
`pluginloader.lua:255-261` copies that field onto the plugin module, which is
how `main.lua` gets `self.version` to hand to the updater. **An absent version
is refused rather than defaulted** — pagenumbercrop's fallback of `"0.0.0"` is
below every release ever published, so it turns each check into "a new version
is available" forever.

It earned itself on `v0.9.2`, which was tagged one commit before the version
bump landed: the run failed at that step, skipped the build and created no
release. The recovery is to move the tag — `git push --delete origin v0.9.2`,
re-tag the right commit, push — because **a tag that already exists does not
re-run its workflow**. Re-pushing the same ref is not a push as far as Actions
is concerned, so a failed release whose cause you have just fixed stays failed
until the tag itself moves.

**`v0.9.1` is a build whose updater cannot install anything**, and that is worth
knowing as a fact about this feature rather than about that release: the crash
was in the updater's own verification step, and a device running it will fail
the same way at every later version, because the code that runs the install is
the code already on the device. The reader keeps working — the failure is before
anything moves — but OTA is dead on that copy until a new one is put there by
hand. **The updater is the one component an update cannot fix**, which is the
whole argument for testing this path on a device before tagging rather than
after.

**The archive is staged to get its `meguru.koplugin/` prefix, and staging is
also what keeps the developer material out.** The repository root *is* the
plugin — `main.lua`, `_meta.lua`, `meguru/` and `assets/` are at the top level,
where pagenumbercrop has them a directory down — so zipping the root would put
32 files under no folder at all, and would ship `CLAUDE.md`, `PROTOCOL.md`,
`tools/` and `docs/` to every device. `assets/` has to be in the staged copy
(`meguru/rowcover` reads it through `Paths.asset`), and so does `LICENSE`,
because the zip is a distribution of AGPL-licensed code.

### Installing one

`symlink → download → extract to staging → verify → rename ×2 → clean up`, and
each step exists because of something the one before it cannot catch.

**The new copy is unpacked into a staging directory and verified there**, so a
failed download or a truncated archive never touches the live plugin; the
verification is four required files plus the staged `_meta.lua`'s version
matching the release's, which is also the only proof that the asset served
under `ASSET_NAME` is the one this release built. Then the installed directory
is moved aside by **rename**, the staged tree is renamed into its place, and
anything that goes wrong after that puts the backup back.

**Nothing on disk but markers** now has an exception of a different shape than
`seriescover`'s: `<data>/ota/meguru/` holds the archive, the staged tree and the
backup for the length of one attempt, and `ota` is entirely ours, so every
failure path clears the whole directory in one `purgeDir` rather than picking
off what that stage happened to write. A 477 KB zip left on the card after a
failed attempt would be exactly the thing this codebase does not do.

Three things about that transaction are load-bearing and each is easy to
"tidy" away:

- **`os.remove` cannot delete a directory.** POSIX `remove()` is `rmdir` and
  fails `ENOTEMPTY` on a tree, which both `staging/` and `backup/` are. Every
  cleanup is `require("ffi/util").purgeDir`, which is what `pluginloader.lua`
  uses on a plugin it is deleting.
- **A `false` from `extractToPath` is advisory.** It compares against
  `ARCHIVE_OK` exactly (`archiver.lua:149`) while a disk writer returns
  `ARCHIVE_WARN` for something as ordinary as a permission it could not set on
  a FAT card, so treating it as fatal would fail installs on exactly the media
  a `.koplugin` most often lives on. Verification is the gate.
- **Nothing may happen between the two renames.** There is a moment where
  `plugins/meguru.koplugin` does not exist, and the rollback only runs if the
  function returns — a power loss in that window is not something this design
  recovers from, and the code says so rather than pretending otherwise. Two
  adjacent metadata syscalls is the whole mitigation.

**The symlink guard is a data-loss guard, not politeness.** `pluginloader`
accepts a symlinked plugin because `lfs.attributes` follows one, and on the
machine this is developed on `plugins/meguru.koplugin` *is* a symlink to the
repository. Without the guard the renames would move the link and install a
real directory in its place, orphaning the repo — and on the *second* update
`purgeDir` would be aimed at that link and delete the repository's contents,
because it recurses through the same following call. Installing is refused
before the download, so a development install does not pay 400 KB for it.

### `Net.getToFile`, and what it is not

The download cannot go through `Net.get`, and the reason is not the size.
`Net.get` collects its body with `ltn12.sink.table`, and `socketutil` enforces
its **total** timeout only inside its own sinks — the socket-level total is
reset on every poll, which `socketutil.lua:38-42` says outright. So everything
fetched through `Net.get` is bounded per read and not in wall-clock at all,
which is survivable for a feed page and not for a file a reader is watching
with a frozen UI. `socketutil.file_sink` is what makes the number mean
something, and writing to a file rather than to the heap is the other half.
The sink closes the handle itself on every terminating call, so the `pcall`d
`close` beside it covers only the request that died before the sink ever ran.

**`Net.get`'s own docstring is wrong about this**, and it is recorded rather
than fixed: it claims a feed page "has not finished in 30s, is not coming",
while its sink makes that untrue. The one-line repair is to give it
`socketutil.table_sink` too, and it wants its own decision — it touches the
reading path, and the walk is the only thing that has ever run through it.

### What is remembered, and why it is written on failure

`settings/meguru_update_cache.json` holds the last release found and a
`checked_at` timestamp. Two different clocks read it: the payload is reused for
an hour so a reader tapping the row twice spends one API call, and `checked_at`
gates a background check to once a week.

**`checked_at` is written on every completed check, including the failures, and
that is the whole reason it is a separate field from the payload.** A device
that is offline at every start would otherwise reach for the network on every
single start, forever — and on a Kindle, whose `isConnected()` is true whenever
wifi is on, "offline" is the ordinary case rather than the exception.

**A successful install rewrites the file rather than deleting it.** Deleting it
resets the weekly gate to "never checked", so the next start checks immediately
and so does every start after that until a check succeeds — which is
pagenumbercrop's behaviour and is the wrong shape.

### The row, and what it is not

*Check for updates* is the one row under `Settings` that is not a preference:
it stores nothing, and it is the only row there that can be *done* rather than
set. It is behind a `separator` on the `Set Meguru as default reader for .cbz`
row above it, and it is the reason the "one seam only" note on separators was
retired.

`Updater.checkForUpdates` goes through `NetworkMgr:runWhenOnline`, which asks
for a connection when there is none — the right thing for a tap, and the one
case it does not cover is a device that is **connected but not online**, where
it drops the callback rather than running it (`manager.lua:698-709`). Nothing
runs and nothing is said, which is why the "Checking…" message carries a
timeout; tapping again once the connection is real works. `checkSilentForUpdates`
gates on `isConnected` instead, because the one thing a background check must
never do is put a wifi prompt in front of a reader opening a book.

The result goes to `UIManager:askForRestart`, **not** `restartKOReader`. The
former defers through `event_handlers.Restart`, which shows the same
"Restart now" / "Restart later" prompt, broadcasts the `Restart` event first so
other plugins flush what they have open, and degrades to a message on a device
that cannot restart rather than quitting for nothing.

## Development

```
python tools/check.py       # structure of the Lua
```

There is no Lua interpreter on the development machine, so `check.py` stands in for
one. It runs ten passes:

1. **Block balance** — `function`/`if`/`for`/`while`/`do` against `end`/`until`, over
   comment- and string-stripped source.
2. **Cross-module member references** — every `Module.member` where `Module` came from
   a `require("meguru/...")` binding is checked against the members that module
   actually defines. A require naming a module that **does not exist** is an error
   rather than a skip: it used to fall through silently, which meant that once a module
   was deleted every reference to it became *unchecked* instead of reported — the worst
   possible failure for a pass whose whole job is catching references to things that no
   longer exist.
3. **Unbound module tables** — `Geom:new{...}` where `Geom` is never bound in the file.
4. **Lowercase calls not yet bound** — `handToReader(host, file)` where the only binding
   is a `local function` *below* the call. **Position is the whole pass**: a `local`
   enters scope from its own statement onwards, so a call above it resolves the name as
   a global and finds nil, while the binding is sitting right there for any
   position-blind check to find.
5. **A name read as a *value* that is not bound at or above its line** —
   `pcall(renderMuPDFPage, ...)`. Passes 3 and 4 both key on the shape of the *use*,
   so a name handed over as an argument or an operand slips past both. Its own trap is
   the **list of words it lets precede a value-use**: only forms whose next token is a
   binding or a keyword belong there. `return`, `not`, `and` and `or` were in that list
   and are not — what follows each is read — so `if not lead_index then` with the name
   misspelled was a name read as a value, bound nowhere and reported by nothing. The
   typo was injected while self-testing `meguru/local` and it came back clean, which is
   how the hole was found.
   **The pass was position-blind and that cost a shipped feature.** It asked only
   whether a name was bound *somewhere*, on the stated grounds that claiming the
   positional half "would report every forward reference in the codebase" — which
   confused two things. A forward reference to a `local` is not a legitimate pattern in
   Lua; Lua resolves a name at compile time against the locals in scope at that point
   in the source, so a `local function` defined *below* its use is a global read, and
   the pattern that does work — mutual recursion — declares `local b` before its first
   use and is therefore bound above it. `maskToQuad` was added below
   `Image.renderRegion`, which called it through `pcall(maskToQuad, ...)`; the pcall
   handler logged `panel crop mask failed: attempt to call a nil value` and the panel
   crop silently went unmasked on every page. It is now check 4's rule applied to
   value-uses as well, and **adding it reports nothing anywhere in the tree** — which
   is the measurement that settles the old objection rather than an argument about it.
   Six shapes were injected to self-test it: the forward reference (with and without a
   call), a forward declaration, a name bound nowhere, and the two shapes checks 4 and
   6 own.
6. **A lowercase name reached through a `.` or a `:`** — `data:byte(off + 1)` with no
   `local data` anywhere.
7. **The marker's field list.** `Marker.new` is the contract between the code that
   writes a marker and the code that reads one, and Lua checks neither end. A field read
   off a descriptor that `Marker.new` does not copy is nil on the device — and nil is a
   legitimate answer for several of them, so the failure surfaces as a feature that
   quietly does nothing rather than as an error.
8. **The same contract for a book's series**, against the one definition of that shape
   (`Marker.seriesContext`). Pass 7's failure, in a second place, and it shipped twice
   before the pass existed: `Marker.dirFor` read `series.name` while every caller passed
   a context with `series_name`, so **no series folder was ever created**; and
   `freshResumeTarget` filtered on `series.remote_id`, so the `▶` server-position button
   silently never appeared — and "the server has no opinion" is a legitimate state, so
   nothing reported it either.
9. **A `_()` call inside a `for _` loop.** Every file here opens with
   `local _ = require("gettext")` and every discarded loop index is written `_`, and
   those two conventions collide the moment a message is needed inside the loop: `_`
   is the *counter* for the length of the body, so the call is an attempt to call a
   number. **This one shipped**, in `meguru/updater`'s verification step, and was found
   by a device. Passes 5 and 6 both skip `_` by name — correctly, it is a global they
   must not report — so nothing covered the shape, and nothing could: the loop is
   idiomatic, the message is a message, and neither is wrong on its own.
   The loop's extent has to be found by **matching blocks**. A first attempt scanned
   forward for the next `end`, flagged two `for _` loops in `meguru/ui/menu` whose
   `_()` is *after* the loop, and was believed for a minute — which is the ordinary
   fate of this kind of check, and why it is worth saying that a body full of nested
   `function ... end` is the case that tells a real matcher from a rough one.
10. **An assignment to `_`**, which is pass 9's collision seen from the other side. The
   same two conventions — `_` is gettext, `_` is a discarded value — meet in
   `panels, _, reason = doc:getPanelsFromPage(page, mode)`, and because that binding is
   **not** a `local` it writes straight through to the file's translate function:
   `_` became that call's second return, `accepted`, a boolean. **This one shipped too,
   and it cost a device crash** — `attempt to call upvalue '_' (a boolean value)` — on
   the page-boundary crossing of the window view, whose button row was the first
   `_(...)` this file had ever needed. The offending line was years older than the
   caller that found it out, which is why "nothing has ever gone wrong with it" is not
   evidence of anything here.
   The two shapes are reported differently because they reach differently. A plain
   assignment reaches the *file*, so every `_(...)` that runs after it anywhere is
   broken and it is always reported. A `local` shadows only to the end of its own
   block, so it is reported only when something in that block translates afterwards —
   five files here discard into `_` with no `_(...)` near them, and flagging those would
   be noise that teaches a reader to skim the pass. **The first version of this pass
   looked for the shape `_ =` and passed on the real bug**, because the assignment it
   exists for is `x, _, y =`; it was found by injecting the line back and watching the
   checker stay silent — the same self-test the paragraph below asks for, done late
   rather than first.
   The block extent comes from pass 9's matcher, extracted into `block_spans` so both
   passes ask one implementation the same question. What it cannot see is an assignment
   whose `=` sits on a later line than its targets; nothing here writes one.

None of these is a parser. They are the failure modes that have actually bitten this
codebase, and that a reader cannot reliably catch by eye: a name or member that is fine
at load time and only explodes when a branch runs, on the device, in the reader's hands.
**The checker passes vacuously if its stripping or its patterns are wrong**, so each
pass was self-tested by injecting the real failure and confirming the checker reports it
— including at the right line. Do the same before trusting a green run, and this is not
a formality: of the passes written across this project, four were wrong on the first
attempt and passed on the very bug they existed to catch.

A Python mirror of Lua logic models values, not Lua's evaluation rules, and the
difference has shipped a crash. `meguru/credential.lua`'s `restoreTemplate` ended
`return (s:gsub(...))` — parentheses truncate a multi-value expression to one, so the
`count` its caller branches on was nil on exactly the *successful* path. Say which Lua
rules a mirror is modelling, and treat anything it does not model as untested rather
than as passed. The traps of the same shape: `and`/`or` folding (`x and f or nil`),
`nil` in a table constructor ending the array part, `#` on a table with holes, and
integer division or bitwise operators under 5.1.

**`tools/scan_sql.py` is gone**, with the SQL it guarded.

### Verifying on the device

No automated tests, so verification is a running KOReader. Run with `-d` or read
`crash.log`, filtering on `Meguru:`.

**A marker written by an older build is not a valid test surface.** A v1 marker is
still valid and still opens — that is a requirement, not a hope — but it carries none
of the series identity added since, so it has no neighbour until something reopens it
from a browser. Wipe the markers whenever a change touches the marker's shape.

**Installation must be a directory named `meguru.koplugin`.** `pluginloader.lua`
`_discover()` ignores any directory whose name does not end in `.koplugin` and strips
the suffix to get the plugin name, so `plugins/meguru/` is invisible. On this machine
it is a junction, not a copy, so the repository stays the single source of truth:

```
cmd /c mklink /J "<koreader>\plugins\meguru.koplugin" "C:\dev\projects\meguru"
```

**Read the whole log, not just the crash.** KOReader catches non-fatal errors inside
`pcall` and logs them as `warning: UNHANDLED EXCEPTION!` plus the message, then carries
on. So a line like that *before* the fatal crash is a **second, independent bug**. When
a message names nothing, the string is worth chasing to its source rather than guessing
— it is often a vendor library's:

```
grep -rn "<message>" <koreader>/            # which file, if it is Lua
grep -a -o -E "[ -~]{6,}" libs/libwrap-mupdf.so | grep -i "<message>"
```

That is how `argument error: missing file type` was traced to
`Mupdf.openDocumentFromText` and its non-optional second argument: the adjacent string
in the wrapper is `cannot find document handler for file type: '%s'`, which says a
*wrong* type fails loudly and differently, and makes supplying a guessed type safe.

Each step must pass before the next:

1. **The plugin with no network and no store.** FileManager → `Tools → Meguru` submenu
   — no crash. Then open a marker from History with the wifi off: it reads, and "Open
   next in series" says the series has no next chapter rather than opening the wrong
   book or hanging.
2. **A marker opens with nothing configured.** Open a book, then rename
   `settings/opds.lua` and reopen the marker from History — the book must open and read,
   and its pages must fail with a 404 whose path says `<redacted>` and a warning naming
   the fields that stayed stuck. Put the file back: pages fetch again.
3. **The marker names the right chapter.** Hand-edit `item_key` in a marker to another
   item's key — the open must land on whatever that key names. Then hand-edit
   `server_kind` to a wrong value: the book still opens and reads (the kind is only what
   builds a feed URL), and "Open next in series" reports that it cannot look rather than
   answering with a wrong chapter.
4. **Page fetching.** One log line per page with a rising `pageNumber` plus prefetch,
   and **no** fetch of a whole archive. `cache/meguru/` does not grow while reading.
   Alongside it, one `page N prepared`, one `MuPDF page render`, and one `page N paint
   via direct|scale` per rendered tile: on a manga page that fits the screen the render
   line shows the page uncapped and the paint line says `direct`; on an oversized scan
   the render line shows the reduced size — that pair is the whole check that the budget
   is doing what `meguru/settings` says. Then turn back one page and force a repaint
   (open/close ⋮, toggle a crop setting): **no fetch**, because the page's decoded buffer
   is still live. Turn back past the four-entry store and a fetch *is* expected — that is
   the trade this makes, not a regression. Then close the book and reopen it: the page it
   reopens on is fetched, because the store died with the document.
5. **Engine port.** On the same title as the old plugin: crop, page-number crop, panel
   zoom, night-mode invert, wide-page rotation, local `.cbz` via "Open with…" —
   behaviour identical to the old plugin.
6. **Concurrency.** Two windows (FileManager + ReaderUI): the provider registers once,
   and a walk started from one does not disturb the other. The UI must stay responsive
   while a walk runs — it is synchronous, so what keeps it bearable is the page cap and
   the short timeout.
7. **Two books, one title.** Open a "Chapter 1" from two different Suwayomi series. Each
   renders its own pages — impossible to confuse by construction, since the store is
   per-document and keyed by page number. What is still worth checking is that neither
   book's marker was adopted by the other.
8. **Nothing on disk but markers.** Read several pages, then confirm `cache/meguru/` is
   empty (or absent) and that no `meguru.sqlite3` reappears in `settings/` — including
   after browsing a folder of `.meguru` files in the mosaic, which *does* fetch each
   cover over HTTP and must still write nothing. In that same browse, the covers must
   actually appear: the book's own where its feed published one (a Kavita volume), else
   the series', else page 1 of its stream — and at most one fetch per book, since
   `BookInfoManager` remembers the thumbnail afterwards. With the wifi off, covers
   already extracted stay on screen and nothing crashes.
9. **The dialog asks once.** Tap a volume in a series feed, answer the dialog: the book
   opens and **no second dialog appears**. Then close it and reopen the same book from
   History — **the dialog comes back**, which is the half of the test that catches a
   guard that suppresses too much. Reopen a *different* book and confirm the earlier
   one's record is not swallowing it.
10. **The jump button does not re-ask.** With the server further along in another volume,
    tap its `▶` button: that volume opens with no dialog, and the page in the label is
    the page it lands on. Tap a jump onto a volume already read here: the label names no
    page, and the book resumes where KOReader left it.
11. **The silent opens stay silent.** ⋮ → Meguru → "Open next in series" on an unsynced
    series: the walk runs, the chapter opens, no dialog. Finish a volume with `Auto-open
    next in series` on: the next volume opens with no dialog.
12. **The menu lands where it should.** FileManager → Tools → `Meguru` directly above
    `Read timer`, holding a single `Settings` row and nothing else; the reader's ⋮ → Tools
    → `Meguru` holds `Open next in series`, `Open previous in series` and the same
    `Settings` row — the two rows on a marker whose series the feed can be walked, on a
    local `.cbz` whose name carries a series and a number, and on neither otherwise (item
    23). Above `Read timer` in both cases: with the AI Assistant plugin
    enabled that means the second row down, under `AI Assistant` and above `Read timer`;
    with it disabled the row is the first thing on the page. Turning the AI plugin on
    must move the row under it rather than leaving a second copy behind. Nothing
    anywhere offers a cover, a cache to clear, a library or a server list. Inside `Settings`, on both surfaces: `Auto-open next in series` (reader
    only), `Panel zoom in Meguru books` (reader only), `Hide status bar` + a line, `Main
    folder for .meguru streams: …`, `Subfolder per server` + a line, `Set Meguru as
    default reader for .cbz`. The folder row opens the picker and shows the new path
    afterwards; the toggle's checkbox survives a restart; a new book lands in
    `<base>/<server>/<series>` when the toggle is on. With a PDF open there is no Meguru
    row and nothing logs `menu id not found`.

    Then the `.cbz` row, which starts **on**. On a fresh install — no `provider` key in
    `settings.reader.lua`, no `meguru_cbz_default_claimed` — the first start must write
    `provider = { cbz = "meguru" }` and log `Meguru: is now the default reader for
    .cbz`; **every** `.cbz` then opens as a Meguru book. Then the half that matters
    more: turn the row off, restart, and it must **stay off** — `cbz` gone from
    `provider` and `meguru_cbz_default_claimed` true. Guard the other direction: with
    `provider.cbz` set to something else, the claim must leave it alone, while the row
    still reads ticked for a per-file choice and unticked for a file-type one that is
    not Meguru.
13. **No destination dialog anywhere.** `▶ Meguru this series` with the wifi off still
    prompts for a connection and then opens, straight into the resume dialog. Neither it
    nor the top-of-feed row ever asks for a folder.
14. **A dismissed dialog leaves nothing at all.** List the marker folder first. Tap a
    volume in a series feed, then tap *past* the resume dialog: no `.meguru` appears,
    **no series folder appears**, and nothing new appears in the library or in History.
    Do this on a series that has no markers yet — an existing series already has its
    folder, which is why the folder leak was easy to miss.
15. **The two entry points agree on the server's position.** On Suwayomi, read into
    chapter 40 of a 50-chapter series, then open an early chapter (say 3) from the OPDS
    browser: the `▶` button must name chapter 40, not chapter 1. Open that same early
    chapter's marker from History and the `▶` button must name the same chapter 40.
16. **The `▶` chapter is the first the server flags unread, and progress is not
    consulted.** Mark chapters 1–9 read, leave chapter 10 *started* (its summary says
    `2 z 22`), and mark 15–17 read. The `▶` button must name **chapter 10, page 3** —
    not 15 or 17. Then finish chapter 40 with 41–42 untouched and 43 started: the button
    must name **41**, with no page. The log must show a fetch carrying
    `filter=unread&sort=number_asc`. The same chapter must come from the row above the
    series list and from the same book opened from History — three entries into one
    answer.
17. **Panel zoom: the preference is the floor, and a file may stand on it.** Start from
    a device with `panel_zoom_enabled` removed from `settings.reader.lua` *and* from the
    sidecars of the books in play, so nothing has answered for anything:

    | situation | expected |
    |---|---|
    | preference off, a fresh marker | no zoom on long-press, and the **stock ⋮ row reads off too** |
    | same file, stock row tapped on | zoom works — and `Panel zoom in Meguru books` **still reads off** |
    | close and reopen that file | zoom **still works**: the file answered |
    | preference off, a *different* marker | no zoom |
    | preference on, a fresh file | zoom works |
    | …then preference off, reopen that file | **no zoom** |

    The last row is the one that matters, and it is the whole reason `onSaveSettings`
    still deletes something: a file that was only *opened* must not come away with an
    answer of its own. Confirm it on disk — open and close that file under the
    preference on, then check its sidecar has **no** `panel_zoom_enabled`. Also confirm
    the preference applies **live** to a file with no answer of its own, and does **not**
    to a file that has answered. Finally `.cbz`, where the two readings are allowed to
    differ: one opened through Meguru with no answer of its own follows the preference,
    while the same file opened by KOReader's own reader follows the `cbz` entry.
18. **Panel zoom is a crop of the page, not of the screen.** On a book whose pages are
    bigger than the screen (a Kavita volume; anything at or under 4 Mpx is not capped),
    long-press a panel that covers a good part of the page. In `-d` the `panel zoom on
    page N, region … rendered WxH` line must show an output larger than the screen, and
    the image must stay sharp when pinched in the viewer. A panel *smaller* than the
    screen still looks right (it comes back small and the viewer upscales it — intended,
    not a regression), and a long-press with the wifi off and the page's bytes aged out
    of the store still shows a panel, softer, through the `Document:drawPagePart`
    fallback.

    Then the same page in the **window view** (*Panel view: Pan & zoom*), which is the
    second half of this item because it is the same crop question asked the other way.
    Long-press a point in a large panel: the view must be centred on that point, and the
    panel's own edge must sit at the screen's edge — **never a strip of the page's
    margin**, which is what anchoring to the page would show. Forward once: the panel's
    far edge arrives and the panel is done — unless it is bigger than the window in
    *both* axes, where it must take **four** passes, one per corner, and the log's step
    count must say four. A panel **taller** than the window takes two passes and the
    next panel is not reached until its bottom edge has been shown, which is the half
    of this that no screenshot will show if it goes missing. Then the level, which lives
    in the viewer's button row rather than the menu (a middle tap reveals it): tapping the
    `1.7x` button must cycle 1.4 / 1.7 / 1.9, change how much of the page the window
    covers — narrower as the number rises — with the step count following it, and
    **remember the choice**, so the next page, the next book and the next start are at the
    level the reader landed on. The row must hold the zoom and *Close* and nothing else: a
    **Scale** or **Rotate** button in the window view is the bug, since neither means
    anything there. Then the skip:
    on a page
    with small panels beside a full-height one, position the window so they are all
    inside it and press forward — **one press must pass all of them** and land on the
    next panel the window does not cover, with the `-d` line showing a step count
    smaller than the panel count. Back from there must reach the panels *before* the
    one touched, not only the ones after it. **And the boundary in both directions**:
    swiping forward off the last panel opens the next page's **first** panel at its
    start, and swiping back off the first opens the previous page's **last** panel at
    its **end** — the bottom of it, the corner nearest where the reader came from. It
    used to open the previous page at its first panel, from the top, and then at the
    last panel's top, and both were wrong for the same reason. Then the
    direction: in Manga mode a panel too wide for the window must be walked from its
    **right** edge to its left, and in Comic mode from left to right — the same thing
    `Manga mode` already does to the panel order. And a splash page the detector refuses
    must open whole, cropped, whatever this preference says.
19. **A book that cannot get its pages says why, once, and stops asking.** With the wifi
    off, open a marker: the page area holds *Can't load this page / You're offline right
    now. Connect to Wi-Fi and try again.* Check the two cases that must not be confused:
    with the wifi *on* and the server stopped it must read *Kavita isn't responding…*,
    and with a marker whose catalog was deleted (a 404) *Kavita returned an error
    (404)…*. In `-d` the same two cases are `(no response)` and `(HTTP 404)`. Then the
    rest, which is about not asking twice: one `Meguru: no connection, cannot fetch page
    N` in the log rather than one per repaint; open the ⋮ menu and close it, zoom, toggle
    a crop setting — the page repaints but nothing is fetched and nothing more is
    logged; turn the page and back — one fresh attempt; turn the wifi on — the page fills
    in **without a page turn**, from `onNetworkConnected`. In the FileManager with the
    wifi off, open a folder of markers: no cover is fetched at all, and the mosaic fills
    in on the next browse once the wifi is back.
20. **The panel detector.** Five pages, and the first two are the failures this detector
    was chosen for — the two whose outcome once decided which detector lived here, so
    they are worth re-running before anything in this area is touched again.

    | page | expected |
    |---|---|
    | a panel carrying a full-width **white band inside its own drawing** | **ONE panel.** The band must not cut it in two. The page needs a *hairline* frame for this to bite at all: a row of the band is empty only while the frame's two strokes fit inside the gutter's allowance, `PANEL_GUTTER_INK_RATIO * span` — 2.21 cells of the 443 a 1600-px page maps to. A 5-px stroke is 2 cells a side, so the band never reads as empty and there is nothing for the veto to refuse; the panel chapter has the drawn page that does reproduce it |
    | a page of **tilted panels** — a skewed scan, or gutters that are not axis-aligned | **the panels, split** — `K panels` in the log with K what the eye counts. The reference page for this is Kavita `chapterId=197664`, `pageNumber=115`: `python tools/panelprobe.py <that page>` must print **6** kept leaves, and the one it gets wrong is `249,276 195x206` — two panels whose shared border is crossed by a speech bubble, which is a known limit and not a regression |
    | the same page, **long-pressed** | every panel opens showing **only itself**. Nothing of a neighbour is visible along a slanted edge, and no part of the panel is missing at one — the crop follows the border. In `-d` the `panel zoom on page N … tilt T` line names a non-zero `T` for the five panels whose borders are tilted and `0.000` for the bottom row, whose are square |
    | a normal manga page, 4–6 panels with hairline gutters | the same sequence, in the same reading order, as before |
    | a splash page with no panels at all | the viewer opens on **the whole page** (1 of 1), no progress bar, and a swipe forward **turns the page** |
    | a page the detector refuses | **no panel appears twice**, in either direction, and the count matches the eye |

    Then the mechanics. In `-d`, one `page N panel zoom: K panels … in X ms` per
    long-press; a refused page says `K panels, whole page (<reason>)` and the reason
    must name one of the four tests — `no panels`, `single partial panel`, `panels cover
    too little of the page`, `only N% of the covered area kept`. Compare the milliseconds
    against the `page N prepared in X ms` line on the same page: the scan sits on top of
    that decode and should be a fraction of it. Then the two chrome checks: **no progress
    bar**, and the panel centred in the full height rather than above a strip of nothing;
    and **a forward gesture from a middle panel stays on the page** and shows the next
    panel — if it turns the page instead, the navigation bound was taken from
    `_images_list_nb`, which is now the bar's switch and not a count, and nothing
    automated can catch that. Then **toggle Manga mode with a page open
    and long-press it twice** — the second press must give the mirrored order, which is
    the whole job of the cache key; and **long-press, close, long-press the same page** —
    the second must be instant and log the same count (the LRU hit), with nothing new on
    disk. Then cross a page boundary from the last panel: `getPageDims` for the next page
    must appear **once** (the warm) and not again during the crossing, and there must be
    no second `MuPDF page render` line for it — two mean the warm's call order is wrong.
    Cross back and forth three times: no fetch and no decode after the first. Finally a
    page that cannot be decoded (wifi off, bytes aged out) shows the page and **no
    viewer**, logging `no page (…)`.

21. **A turned panel turns the book's way.** One book with a wide spread *and* a page
    carrying a panel wider than the screen. The check is a **comparison**, so it cannot
    be fooled by how anyone reads the row's arrows:

    | setting | wide page | wide panel on a portrait screen | expected |
    |---|---|---|---|
    | `left 90°` | turned one way | **the same screen edge gets the top of the artwork** | they agree |
    | `right 90°` | the other way | the top on the other edge | they agree |
    | `off` | not turned | **exactly as before this existed** — the portrait default, and `Invert default rotation in portrait mode` still flips it | nothing moved |

    Then, in order:

    1. **`off` first.** It is the only row that can prove nothing else moved: the
       automatic turn, the button's toggle and its `Rotate` / `No rotation` label must be
       indistinguishable from the previous build.
    2. **The button with the setting on.** Middle-third tap to reveal the buttons; Rotate
       turns (and unturns) the panel in the setting's direction, and the label flips
       truthfully.
    3. **The press lasts one panel.** After it, move to the next panel — the automatic
       decision must be back. Then return to the one you pressed on: it re-decides, which
       is this design's reading of "one panel" (the press is scoped to the visit). If it
       should instead remember the choice while the viewer lives, that is three lines in
       `switchToImageNum`.
    4. **The handoff.** From the *last* panel, swipe forward: the viewer closes, the page
       turns, a new viewer opens on the next page's first panel, turned the book's way.
       This is the half that is easy to miss, and it fails **only** at a page boundary.
    5. **The turned screen.** On the wide page itself — screen already rotated by the
       setting — long-press a panel that needs turning, under both `left` and `right`. No
       panel angle can be simultaneously readable and device-space-consistent on a turned
       screen; judge whether it reads naturally.
    6. **The button, regression.** Pinch in, press Rotate, toggle *Scale*, press Rotate
       again: every `update()` rebuilds the `ImageWidget`, so the angle must survive all
       of them — and `-d` must show **no** `panel rotation angle could not be applied`
       warning.

22. **Another plugin that patches the OPDS browser.** `zenos.koplugin` is the one known
    to replace `showDownloads` and `parseFeed` wholesale; it is not in this repository,
    so this is a device check. First the half that proves nothing moved: **without it**,
    everything below behaves as before and `-d` shows **no** `OPDSBrowser re-patched`
    line. Then with it enabled and a restart:

    - a series feed carries **exactly one** **“▶ Meguru this series”** row at the top —
      two is the per-method guard having failed, and it will not announce itself any
      other way;
    - tapping a volume opens *its* dialog with our row above the last one, and its own
      “Page stream” / “Stream from page” buttons **still there**;
    - our row opens the resume dialog and the book;
    - `-d` shows `OPDSBrowser re-patched since load; OPDS hooks re-installed`
      **exactly once per process** — not once per browser, and not at all on a second
      open — and one `added "Meguru this series" button for …` per dialog.

    Then the two that a missing `parseFeed` breaks and that no picture of the dialog
    would show: open a book from a **Komga** series feed and confirm `-d` does **not**
    report `not catalogued: no retained entry matches this stream`; and cancel the
    resume dialog after tapping our row, confirming no `.meguru` and **no series folder**
    appear (item 14 still holds). Finally, with the network off, open a marker from
    History — the `ReaderUI:showReader` wrap is on another class and must be unaffected,
    asking once and opening.

23. **A folder of `.cbz` is a series, and the folder is the only rule.** Nothing in
    this one can be checked off the device: the ordering is a byte sort over real
    file names, and the sort key's encoding has never run anywhere but a device.

    1. **The rows appear only when there is somewhere to go.** A folder holding one
       `.cbz` — a one-shot, or an unnumbered book like `Berserk.cbz` — gets **no**
       Meguru navigation rows at all. Add a second `.cbz` of any name and both rows
       appear on both books.
    2. **The order is natural.** `1.cbz`, `2.cbz`, `10.cbz`, `20.cbz`: next walks
       them in that order and previous reverses it, with the message naming the
       folder at either end. The same for `Berserk v2.cbz` beside `Berserk v10.cbz`,
       and for `02.cbz` beside `2.cbz` (adjacent, either order — the leading-zero
       case is a tie-break, not a rule).
    3. **Offline.** Wi-Fi **off**: next and previous walk the run both ways and stop
       at the ends with the message. No Wi-Fi prompt anywhere on this path — if one
       appears, the local branch has slipped below the `NetworkMgr` gate.
    4. **The reader stays Meguru.** Give `.cbz` back to KOReader (*Set Meguru as
       default reader for .cbz* off, restart), open one volume through *Open with… →
       Meguru*, then take "next": `-d` must show `Meguru: local CBZ ready` for the
       **new** path. Then, on disk: the association is still off, the sibling's
       sidecar gained **no** `provider` key, and the folder gained no file.
    5. **Auto-open.** With the toggle on, finishing a local volume opens the next with
       no dialog; at the end of the run, stock's dialog. With it off, stock's
       throughout.
    6. **What is not a book.** One folder holding two `.cbz` plus a `.cbr`, a `.meguru`
       marker, a `.jpg` and an AppleDouble `._one.cbz`: only the two `.cbz` are ever
       opened, and the dotfile is never offered.
    7. **Two titles in one folder navigate into each other, and that is the accepted
       cost.** In a folder called `Comics`, put two different series' books: `next` on
       the last of one opens the first of the other. Confirm it reads as the price of
       the model and decide whether it is tolerable on a real card — that judgement is
       the one thing here a device can settle and this document cannot.
    8. **A folder that cannot be listed.** Unreadable media, or a folder deleted from
       under an open book: one `warn` naming the file, and no rows.
    9. **Non-ASCII.** `Zaginiony rozdział 01.cbz`/`02.cbz` and a CJK run both order and
       navigate. This is the only real test of the byte-exact sort.
    10. **The feed path is untouched.** In the same session, a marker book still walks
        its feed for both rows, and killing the Wi-Fi there still prompts as it always
        did.

24. **Kavita with *Include Continue From Entry* on.** The setting is per user, in
    User Settings → OPDS, and it puts a page-less copy of the chapter being read at
    the top of the series feed — see `Feed.dedupe` and PROTOCOL.md. Wipe the series'
    markers first: one written before this parse fix carries the alias's title and
    no `last_read`, so it is not a valid test surface.

    **Off first**, because it is the only row that can prove nothing else moved: ▶
    names the chapter with its page, next/previous are unchanged, and `-d` shows
    **no** `dropped duplicate feed entry` line. Then **on**, on a series read into
    the middle of a volume:

    | where | expected |
    |---|---|
    | `▶ Meguru this series` over the series feed | the chapter being read **and its page** |
    | the same book's marker, opened from History | the same chapter and the same page |
    | the marker on disk | `last_read` is the server's page, `series_name` is the series |
    | ⋮ → Meguru → **Open next in series**, on that chapter | **the next volume** — not the first one | 
    | ⋮ → Meguru → **Open previous in series**, on it | the previous volume — not "no previous" |

    The two neighbour rows are the half a lost `last_read` does not show, and they
    are the reason the survivor keeps its own index rather than the one it
    displaced: the alias sits at the head of the feed, so a survivor holding that
    slot puts the chapter being read *first in the series*, and next/previous then
    answer from there. Reading one page and turning one page are not enough to see
    it — **walk a neighbour in each direction.**

    Then the switches, which are per user and must change nothing. Turn
    `Embed Progress Indicator` and `... in Title` off (titles lose their glyph),
    then repeat the table: ▶, both neighbours and the row above the series list must
    answer exactly the same. That is the test that nothing rests on a title.

    Then the two halves that are about *frequency* and *scope*: the `-d` line appears
    **once per feed**, naming the alias title, and never once per page or per
    repaint; and the browser's own list **still shows the "Continue Reading from:"**
    row, which is Kavita's entry drawn by KOReader's OPDS plugin and not ours to
    remove — what changed is only which of the two Meguru treats as the book.

## Known open items

- **A page is decoded at its file's stated density, not at its pixels.**
  `renderMuPDFPage` sizes the render from `page:getSize()`, which is `fz_bound_page` —
  points at 72 dpi — and for an *image document* MuPDF computes that box as `pixels x 72
  / density`, assuming **96** when the file says nothing. So a density-less 1600x2400
  scan is decoded at 1200x1800 — 25% below its pixels — and a scan carrying 300 dpi at a
  quarter, silently, because the budget below is an *area* cap and reports the same
  capped numbers either way. The `MuPDF page render WxH -> WxH` line cannot show it
  either: both of its sizes come from the same space. What keeps this from being visible
  today is that `renderRegionDirect` re-renders a magnified region from the source. It
  wants its own pass on a device: the fix is either teaching the decode the density (PNG
  `pHYs`, JPEG JFIF) or moving the plugin's whole coordinate space to pixels, and every
  geometry path shares that space.
- **The panel rotation direction is applied *after* `ImageWidget:new`, not passed to
  it.** `PanelViewer:_new_image_wg` relies on `ImageWidget` not having rendered yet —
  it defines no `init`, and `_render` is entered only from `getSize`/`paintTo`. That is
  how the direction is applied without forking ~30 lines of `_new_image_wg`, and it is
  a dependency on an upstream shape rather than on an upstream promise. The guard and
  its once-per-process `warn` are what make it checkable: if `panel rotation angle
  could not be applied` ever appears in a log, the panel fell back to stock's direction
  and the repair is the forked override — the failure is otherwise silent, which is
  checklist item 21.6.
- **The 90-vs-270 mapping was derived from stock's comment and was wrong.** It came from
  `imageviewer.lua:429`'s `rotate_clockwise and 270 or 90` with "unintuitive, but this
  does it" beside it, and it made panels turn *with* the device where the row names the
  device and the panel turns against it. Found on a device, fixed by crossing the two
  constants in `panelRotationAngle`. Now observed rather than derived, so treat it as
  settled — and note that the row's word is the one thing that never was.
- **The panel detector has a measurement harness, and it is the only way anything in
  it has ever been decided rather than argued.** `tools/panelprobe.py` is a faithful
  port of `meguru/panel.lua` - the ink predicate, both projections, the recursive cut,
  the sheared search, `emitLeaf`, the containment filter, and the bodies of ink a split
  may not run through - that runs on a page image
  with no Lua interpreter. Feed it a page from a real server and it prints every leaf's
  cells, ink density and position as a percentage of the page, plus what the
  containment filter drops and why, plus each body with its frame evidence and every
  candidate a body refused, and under each leaf the **crop box and its four
  edge slopes** - which is how a panel that is a quadrilateral gets told apart from
  one that is a rectangle without a device; its flags compare variants (`loose` for the
  sheared ratio before `PANEL_SHEAR_INK_RATIO`, `root` and `all` for the shear's depth,
  `noclip` for a projection that is not the plugin's, `noveto` for a body pass that
  refuses nothing). **Reach for it before touching
  anything here** - the
  two bugs above were both resolved by measuring, after several rounds of reasoning
  that were each confident and each wrong. **What it does not model**: Lua's evaluation rules (so
  it can settle arithmetic and never semantics), MuPDF's render, and the
  decode-then-resample two-step. A divergence it cannot see is a divergence it cannot
  rule out.
- **The window view's geometry is measured the same way, by a mirror and drawn
  layouts.** `meguru/viewport.lua` is pure — panels, page size and screen size in, a
  list of rectangles out — so a Python transcription of its `steps` runs the same walk
  over layouts whose truth is known because they were drawn (six equal panels, a tall
  one with a grid of small ones beside it, a panel that fits, one that overflows both
  axes, one starting mid-page, an entry into the third of six). It is what settled that
  a panel already on screen contributes **no** step, that the window's left edge is the
  *panel's* (300 in the drawn case) and not the page's (0), that a panel too big in
  both axes is four corners and not a diagonal pair, and that the same wide panel's two
  stops swap sides with the direction. It is not in the
  repository yet — the generator lives in the session's scratch directory with the
  control pages — and what it cannot model is anything about rendering, which is what
  the device item is for. **Unmeasured on a real page:** the 1.27 screen-pixels-per-page-
  pixel that `1.85` comes to on a 1600x2400 scan against a 1236x1648 screen, and so how
  soft the window looks on a page whose `fit` is near 1; whether the skip ever passes a
  panel a reader wanted to stop at; and the whole thing on a page whose panels are
  quadrilaterals rather than rectangles, where the cropped view's mask has no counterpart
  and the window simply shows the neighbour at its edge — by design, and still unseen.

- **A rule measured on one page is not a measured rule, and this cost a commit.** The
  leaf-containment rule was added, then removed on the evidence of a single page where it
  dropped nothing, then restored when the next page found needed exactly it. The honest
  reading of "it removes nothing here" is *it does not fix this page* — and the
  difference between that and "it does nothing" is the whole of the mistake. It has since
  been made inert by the shear's line cut, on a 23-page sample, and it is **kept** rather
  than deleted for exactly this reason.
- **The veto that refuses a split through a detected panel has two conditions, and only
  one of them is measured.** *Coverage* — the body has to span the region on the
  perpendicular axis — is what ships, and `blocked` names its price: two framed panels
  side by side with a white band across both leave neither body spanning, so no veto
  fires and the cut still runs through them. A plain *overlap* catches that case and
  refuses more legitimate splits with it. On the 15-page sample neither choice changes a
  leaf, because neither fires on a candidate that wins its node — so the sample cannot
  settle it, and the conservative condition ships until a page does. What could regress
  in the other direction: `PANEL_BODY_FRAME_MIN` is **1**, the reference's own rule for
  calling a body framed, so a body spanning several panels with one straight edge vetoes
  the split between them and they arrive merged. Both are worth re-measuring on a page
  that has either shape, and neither shape has been seen yet.
- **The veto is invisible in a device log, by construction.** It can only *merge*, so it
  changes neither `accept`'s verdict nor the `K panels` count that reports it — and
  `meguru/panel.lua` has no logger by design, since it is handed a buffer and returns
  rectangles. So "two panels arrived as one" is a question for `tools/panelprobe.py`,
  which prints the bodies with their frame evidence, every refused candidate and the body
  that refused it, and behind `--noveto` the same page with the body pass emptied for the
  A/B. The device's own line is unchanged, and deliberately so.
- **Both skewed-page rules are samples, not proofs.** `PANEL_SHEAR_INK_RATIO` changes the
  leaf count on exactly the pages that were broken and on none of the others, where the
  shear never fires at all (`shear 0/3` - the straight cut handles them). The line cut is
  measured over 23 pages — two chapters of a manga whose panels are drawn at visibly
  different angles, and eight pages of a western comic with clean rectangular ones — and
  it changes the leaf count on one page of the 23, the reported one, where it is also the
  difference between five right panels and one. **The quadrilateral crop changes no leaf
  count at all on those 23** — it is geometry, not detection — so the same sample can say
  only that it is inert, and what justifies it is the measurement on the reported page:
  four of its six panels had a neighbour's content in the crop (2.6% and 1.8% of two of
  them) or their own art cut off (7.8% of one, 19.2% of the merged pair), and after the
  change the crops follow the borders and what remains outside them is the one-cell
  expansion every crop has always had. What could still regress: a page whose
  separator is a real gutter carrying JPEG noise, since the sheared line must be genuinely
  empty (that page would come back as one panel rather than several); a page with an inset
  panel, which the containment rule would drop if it ever fires again; and a page whose
  tiles are tilted enough that the wedge a line cut gives up at a panel's corner is
  visible — the one case no sample here contains, because it needs a slope past the 8
  degrees the ladder reaches. Neither of the first two has been seen. The three constants
  are the first thing to look at if any of those shapes of page misbehaves.
- **A page the cut cannot decompose at all is still one panel, and that is most of one
  chapter of the reported series.** Eleven of the fifteen pages sampled from the reported
  chapter come back as a single whole-page rectangle — accepted, because a lone rectangle
  over 60% of the page is treated as a splash — because those pages have **no full-width
  or full-height empty line anywhere**. They are action pages: panels at angles, speed
  lines crossing everything, artwork off every edge. That is the XY-cut's own limitation
  and not a defect in it, and the fix for it is a different algorithm, which is the
  question this project has already settled twice (see the connected-component argument
  above). What is worth knowing is that the reported page is *not* one of those — it has
  clean empty gutters and the cut finds five of its six panels — so a reader who sees
  whole-page "panels" on those pages is looking at a different problem.
- **Page numbers in these notes are the *URL's*, not the reader's, and they differ by
  one.** Kavita's `pageNumber=N` returns what the reader's own paging calls page N+1, so
  every `p32`/`p87`/`p100` in this file is the page a reader would call 33/88/101. The
  measurements were taken from one numbering and the complaints from the other, and
  matching them cost a wrong diagnosis — three of five "failing" pages were not the
  pages being complained about. Quote the `pageNumber` when a page has to be identified.
- **A *second* chapter of that series merges panels, and chasing it is worth keeping
  whole.** Its mergers are mostly *partial* — a tier's two panels left as one — and their
  boundaries are neither an empty gutter nor a drawn line but simply the artwork stopping.
  Four things were measured against them, and only one paid:
  - **The shear's trigger is not the blocker.** Instrumenting every failing node: the
    precondition (`minInRange <= 0.35` of the span) fires at all of them. The sheared
    search is also **strictly stricter than the straight one by construction** — a
    straight gutter may carry `PANEL_GUTTER_INK_RATIO` of its span in ink, a slanted one
    must be *exactly* empty — and that asymmetry is why a slanted separation is missed
    more often than a square one. It is deliberate: the zero on the shear was bought with
    a device bug (a panel split down the middle of its own drawing by a faintly bright
    band), and the arithmetic argument for it is in `meguru/panel`.
  - **Thickness was the blocker, and is fixed** — the `min_gutter` change recorded under
    "The sequence" above. Three of the five failing nodes had a line already under the
    ink threshold, refused for being *one* line where `min_gutter` wanted two.
  - **The reference's own `segment_border_split`**, whose source is on this machine at
    `/c/dev/github/panelplus`. Its plane is not the ink map: a cell is a border candidate
    at luminance ≤ 60, and a separator is a run ≥ **97%** of such cells, thin. On the
    reported pages the densest line reaches 98% on exactly one page, 93–96% on another and
    27–57% on the rest, so **porting it fixes none of them**. Porting it with the ratio
    lowered to 0.90 — which would catch the second — shreds instead: a five-panel page
    came back as twenty-four.
  - **Relaxing `PANEL_GUTTER_INK_RATIO` to 0.15**, shipped behind a preference and then
    withdrawn. It fixed four pages (2→5, 5→6, 3→7, 1→7) and left every illustration alone,
    and it built the failure the threshold is named for: dense pages split further, the
    first chapter's own reference page **6→13** and a dense action page 1→7. **A reader
    reported it as "it splits too much", which is the 0.05 failure one order of magnitude
    out** — and a switch whose good and bad settings are the same pages is not a switch.
    The work is `27a0b4b` in this history, reachable by hash.
  
  What is still merged after all four is genuinely merged: no threshold, plane or
  algorithm available here separates those pages from the full-page illustrations that
  must *not* be split — 10.4% ink and a 5-cell dark stroke against 45% and 6, on pages
  whose right answers are opposite.
- **The background estimate is wrong on six of those fifteen pages, and fixing it changed
  nothing.** `backgroundFor` takes the **median** of the outer 1% ring, and on a page whose
  artwork bleeds to every edge that ring is bimodal — black at the page's border, paper
  just inside — so the median lands in the valley between them. Measured: the paper can be
  `255` while the estimate comes back `147`, `187`, `196`, `200`, `203` or `210`, and
  `PANEL_INK_DELTA` is a *symmetric* band, so paper 47 above the estimate reads as **ink**
  and 68–76% of the page maps as ink. The near-white override exists for this and its gate
  is `hasWhiteSeparator`, which these pages fail. Replacing the median with the ring's
  dominant mode gets `253` on 22 of the 23 pages and `2` on the one where black really does
  dominate, against `255` on 16 of 23 for the median — a real improvement, and **not made
  here**, because forcing the estimate to `255` on all six leaves every one of them at one
  panel anyway (49–63% ink, still no empty line). It is a correctness fix with no measured
  payoff on the only sample there is, so it wants its own page and its own evidence.
- **The panel scan is not the reference's scan, and three measured differences are
  live.** They are named as *measured* rather than suspected, so nobody re-derives
  them, and none of them is known to matter on a normal page:
  - **Geometry rounds differently.** The reference renders at `480/native.w` and takes
    `ceil(x - 0.001)`; this plugin computes `floor(x + 0.5)` from the already-decoded
    buffer. The two are **one row apart whenever the fractional part is under 0.5** —
    about half of all pages — and agree exactly on the 1600x2400 that everything here
    was measured on.
  - **`PANEL_SCAN_MAX_CELLS` coarsens strips.** It first bites past 5.2:1, where this
    plugin's cells become 2.2x the reference's — an 800x20000 page maps at 219x5474
    against the reference's 480x12000. A gutter under ~5 page pixels is then below
    `min_gutter` here and not there. Deliberate (the 35 MB the uncapped scan costs),
    and a strip's answer is "one panel, the whole page" regardless.
  - **The resample happens twice here and once there.** The reference renders small
    through MuPDF, straight from the source; this plugin decodes at the capped native
    size and *then* scales. On a page over the 4 Mpx budget that is two lossy steps
    against one, in the direction of losing thin light features — which is the
    direction that invents gutters, and `legacy_image_scaling` (a KOReader setting,
    off by default) turns the second step into nearest-neighbour and makes it worse.
- **Kavita granularity** is resolved in PROTOCOL.md (entry ↔ stream is 1:1).
  `driver/generic.lua` is not written yet; see Layout.
- **Komga's `pse:lastRead` has never been seen carrying a value.** Every capture was
  of a library nobody had read, so `readProgress?.page` was absent on every entry and
  the feed looked like a server that tracks nothing — it does. PROTOCOL.md has the
  source line; what is unverified is only whether that page is one-based, as Komga's
  own numbering is. Wants a device check against a book with progress: a zero-based
  value would offer a page one early, and `PSE.samePlace`'s tolerance would hide it.

- **The bottom menu in a Meguru book belongs to zen-os, and this plugin does not
  contest it.** Taking the gesture back was tried (`4a0f395`) and deliberately reverted:
  it is a fight for a gesture with another plugin, and code that can break someone
  else's books is not worth a cosmetic gain. What that attempt ran into is the reason
  it is not merely unfinished — wrapping `ReaderConfig.onSwipeShowConfigMenu` and
  `onTapShowConfigMenu` is not enough, because zen-os takes the bottom of the screen
  **three** independent ways: a touch zone (`zen_page_browser_reader`,
  `page_browser.lua:2564`) that calls its page browser without ever reaching the
  method, re-registered on **every** document open; the two method replacements, which
  do not chain; and `zen_mode.lua:240-248`, which swallows `onShowConfigMenu` as well,
  so even a method that *is* reached opens nothing while `features.reader_bottom_menu`
  is false — its default. Any future attempt has to answer all three, and the middle
  one is what makes the failure **silent** rather than wrong: the gesture opens the
  wrong thing, which from the reader's side is indistinguishable from one that was
  never bound. `curateConfigMenu` still curates the rows and is untouched; with zen-os
  installed they are reached by whatever zen-os offers in the gesture's place.
  **It was also verified on a surface that could not show the failure**, and that pair
  of results is the evidence: the repair passed in a development KOReader under WSL and
  failed on the Kindle. Every one of the three mechanisms above needs zen-os present, so
  a session without it exercises only the stock path — where the repair does exactly what
  it says. A repair aimed at a foreign plugin has to be verified where that plugin is
  installed, and this is what it costs when it is not.

- **A marker written from a tapped "Continue From" row carries no `last_read`.**
  `driverItemFor` matches one stream and answers with the entry the reader tapped,
  which for Kavita's alias is the copy without the page — so the marker is written
  with `last_read = nil` and `MeguruDocument:init`'s silent seed opens it at page 1
  on a later open from History. What is *not* broken is the dialog on that first
  open: it is asked about the book, and the server's page comes through
  `freshResumeTarget`, which does collapse the duplicate. The repair, if it is
  wanted, is to let `driverItemFor` take the survivor of a collapse whose
  `item_key` matches the stream — the two copies share a template, so the match
  survives the replacement — and it was left out of the change that introduced
  `Feed.dedupe` by decision rather than by oversight. Not measured on a device: no
  marker has been written from an alias row and then reopened from History.

Settled and worth not re-litigating: `Settings.DEFAULTS.rotate_wide = 1` is correct. The
old plugin's fallback *row* carries `default_value = 0`, which looks like a conflict, but
that value only applies when the pagenumbercrop plugin is absent — the book itself is
seeded by `perBookGeometryDefaults`, whose classic default is right-turning. The new
plugin seeds 1, which matches what a fresh book actually got.

## Security notes

- **No secret is in a marker file, and `Marker.saveAt` is what enforces it.**
  `server_name` is a catalog title; Kavita's API key is a path segment of the stream
  template **and of every feed** — but in the **query** of the artwork
  (`/api/image/series-cover?…&apiKey=…`). Both positions are redacted, by the two rules
  in `Credential.redactTemplate`, so all three URL fields go to disk as `<redacted>` and
  come back through `Marker.load` from `settings/opds.lua`. One list
  (`CREDENTIAL_FIELDS`) names the fields both halves walk, so a URL field added to
  `Marker.new` cannot be redacted out and forgotten back — and one *list of positions*
  is what the `apiKey` rule was missing when covers were first declared covered.
  `restoreTemplate`'s guard is an **origin** comparison, not a prefix one, because the
  cover's prefix (`…/api/image/…`) has nothing in common with the root's
  (`…/api/opds/…`); it still refuses a key whose catalogue has moved to another host.
- **On Komga the same machinery redacts an API version, and that is not a bug to
  fix.** Komga authenticates with HTTP Basic, so there is no secret in any of its
  URLs — but its paths read `…/opds/v1.2/books/…`, and `Credential.redactTemplate`
  replaces whatever sits after `/opds/`, because on Kavita that is the key. So a
  Komga marker stores `…/opds/<redacted>/books/…` and `Marker.load` puts `v1.2`
  back. It round-trips, for the reason that module gives: the positional rule
  replaces only what it can name and names it back the same way, and the prefix
  guard refuses when the catalogue root has moved. Teaching it to skip a segment
  that *looks* like a version would be the guess `credential.lua` argues against.
- **A marker written before that pair existed still carries the key, forever.** Markers
  are not scrubbed in place: rewriting a book file the reader did not ask to have
  rewritten is worse than a stale copy in a folder they control. So "markers hold no
  secret" is true of new ones; delete and re-add the old books if it matters.
- **`crash.log` is a file too, and `Net.redactUrl` is the only thing a log line may print
  a URL through.** It strips the credential-bearing path segment, so the four failure
  lines in `Net.get` never write Kavita's key out on a 404. The query is reduced to its
  byte count and `user:pass@host` never reaches the output; both are load-bearing and
  neither should be "simplified". The one place that had escaped this — `noteFeed`'s
  `feed parsed` line, which printed the browsed catalog URL raw — now goes through it
  too.
- **Credentials are read from `settings/opds.lua` and go nowhere else.** A marker with a
  `<redacted>` field resolves the credential at load so the book can be read at all;
  nothing sends one except a page fetch.
- The derived `catalogURL` is never stored — it is built at call time from
  `settings/opds.lua` and kept in a local. Every URL that does reach a log line goes
  through `Net.redactUrl`.
- Kavita's stream `template` in a marker unavoidably embeds the API key; that is what
  opens the book. It is bounded to that one field in a file the reader controls, and to
  `settings/opds.lua`, where the key already lives. The markers that carry it in
  plaintext are the ones written before the redaction pair existed; nothing scrubs them,
  by the rule above.
- `settings/opds.lua` is read **only**, never written.
