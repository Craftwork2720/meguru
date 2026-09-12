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
long as the file exists.

So a marker holds nine small fields — enough to open and read the book offline,
and enough to build the one URL that describes its series. "What comes next" is
answered by walking that feed **when the reader asks**, in a gesture that asked
for it. Nothing is stored that a feed could be asked instead.

This is the third design for the same problem, and the history is worth keeping,
because each one failed for a different reason. The old plugin's copies went
quadratic and stale — and it copied one forward into every marker an auto-open
created, so a chain of them described the series as it was when the first was
written. The catalog fixed staleness by being authoritative, and paid for it with
a whole subsystem — a schema, migrations, transactions, a sync engine, a
background walker — to keep a materialised view of feeds that could always just
be re-read. What is left is the smallest thing that works: the identity in the
file, the feed for everything else.

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
  fs.lua                  filesystem predicates and directory creation
  settings.lua            plugin-wide preferences in G_reader_settings
  sources.lua             read-only view on settings/opds.lua (catalogs + credentials)
  net.lua                 HTTP GET, feed fetch + parse
  naming.lua              sanitizeComponent / deriveSeries / alias / glyph / identity digest
  marker.lua              marker read/write, naming, collision resolution, series context
  credential.lua          what a credential looks like in a URL: redact / restore
  pse.lua                 OPDS-PSE: link extraction, template -> URL, page fetch
  feed.lua                reading a series feed: the rel=next walk, order, neighbour
  hook.lua                runtime wraps on OPDSBrowser (sniff, "Meguru this series")

  driver/
    base.lua              driver registry + pure shared helpers
    suwayomi.lua
    kavita.lua

  doc/
    document.lua          Document subclass: the reading engine
    image.lua             MuPDF decoding with a size cap
    defaults.lua          per-book seeding of kopt_* from plugin preferences

  ui/
    open.lua              "Meguru this series": resume dialog, marker write, open
    reader.lua            everything grafted onto a running ReaderUI
    menu.lua              the two menu surfaces
```

`tools/check.py` is a development aid, not part of the plugin.

Not yet written: `driver/komga.lua` (the driver contract accommodates it, but it
is out of v1 scope) and `driver/generic.lua` — the `kind = NULL` driver that can
only discover a series by title heuristic and cannot build a canonical
`catalogURL`, so there is no feed to walk for a neighbour. Until `generic.lua`
exists, an unrecognised server is handled by the absence of a driver rather than
by a driver that returns nothing useful.

**Nothing is written to disk but markers.** There is no page cache, no cover
cache and no database: pages live in a small RAM LRU, and a cover is refetched on
every call. See the covers section below for what that costs the FileManager's
browsing.

`meguru.sqlite3` may still be sitting in `settings/` from a version that had one.
Nothing reads it and nothing sweeps it; delete it by hand once, the way the older
`cache/meguru/` subdirectories have to be.

The dependency graph is a DAG with no cycles, and it now has **no lazy edges**:
the two it used to need (`ui/library.lua` -> `ui/series.lua`, and `ui/menu.lua`
-> `ui/library.lua`) went with those views.

## Series state, and where it lives

**There is no store. A marker and the server's own feed are the whole of it.**

A marker carries nine fields: the identity of the book (`server_name`,
`series_remote_id`, `item_key`), what opens its stream (`template`, `count`,
`last_read`), and what identifies its series to a feed (`series_name`,
`server_kind`, `lang`). The first two groups are enough to open and read the book
with no network and no configuration; the third is enough to build the one URL
that describes its series.

Everything else is asked of the feed, **when the reader asks for it**. That is
the design, not an optimisation, and the reason is in the intro: a copy is
written once and never repaired.

---

**`item_key` is the identity of a book, and there is exactly one function that
derives it.** It is not stored anywhere any more — the marker holds it and
`Feed.neighbor` matches on it — but the rule is unchanged and still load-bearing:
it is never derived from a whole stream URL, because Kavita's `stream_template`
embeds the API key and Suwayomi's may carry `?token=`, so hashing a URL would
mean a key rotation renamed every book.

| Server | `item_key` |
|---|---|
| Kavita | the `chapterId` query parameter of the stream URL |
| Suwayomi | the chapter's `<id>` URN (`urn:suwayomi:chapter:16851`) |

Suwayomi's chapter *number* is not an identity: the same chapter shows three
different numbers across title, path and feed, because the path segment is a list
position and the title is renumbered on a metadata refresh. The `<id>` is stable,
and the one trap in it is recorded in PROTOCOL.md — the chapter-list feed and the
chapter's own metadata feed emit different ids for the same chapter
(`…:16851` vs `…:16851:metadata`), so `chapterKeyFromId` strips the suffix. Without
that strip, opening a book would match it against no entry in its own series'
feed, and "next chapter" would answer as though the reader were nowhere.

**A cover belongs to a book *and* to a series, and the marker holds both links.**
`series_cover_url` is the series' artwork; `cover_url` is the book's own, written
only when the feed the marker was built from published one. Kavita's series feed
does, on every entry, so every volume gets its own for nothing. Suwayomi's
chapter list does not — its entries carry only `rel=subsection` — and the
chapter's own artwork lives solely in its metadata feed, one request per
chapter, which nothing spends. So `driver/suwayomi.lua` sets none and its
chapters fall back to the series cover, deliberately.

**Both links go through the same redaction as the stream template.** Kavita puts
its API key in the path of every URL it emits, covers included, and a marker
lives in the reader's *book* folder rather than in `settings/` — so
`CREDENTIAL_FIELDS` in `meguru/marker.lua` lists all three, and a field added to
`Marker.new` without being added there is written to disk with the key in it.

`MeguruDocument:getCoverPageImage` resolves a book as **its own artwork → the
series' → page 1 of its stream**, so a missing item cover is not a missing
cover, it is the next best one, and the last step is the reason a book is never
cover-less. This is the seam the FileManager's mosaic and "Book info" go
through, and it is worth knowing what it costs: **there is no cover cache of any
kind**, so every call fetches over HTTP. Browsing a folder of `.meguru` files is
one request per book. That is deliberate — KOReader's own `BookInfoManager`
remembers the thumbnail it extracts, so a cover already has somewhere else to
live, and a store of our own would have made meguru write one. The last step goes
through the page pipeline, so it also warms the same byte store a page turn does,
and page 1 is the one entry in it that can be for a page other than the one on
screen.

A marker written before the two cover fields existed has neither, and falls
through to page 1 — which is what every book got before they were stored.

**Nothing cached is ever filed under a book's name.** That is a rule with a
history, and the history is worth keeping because it is the cheapest way to see
why it must not be undone. Page bytes lived on disk once, named after the
marker's basename; every Suwayomi chapter is titled "Chapter 1" and many Kavita
volumes "Volume 1", so **every such book on every series and every server shared
one file** — the second book to be opened was served the first one's bytes and
its cover alike. `Marker.pathFor`'s collision guard could not catch it: it
disambiguates only within one directory, and same-titled books normally land in
*different* series folders, where it never fires. (That old key was
`Marker.cacheKey`, and the read it fed was `getCoverPageImage`'s page-1
fallback; both are gone.)

What survives of the lesson is `Marker.naturalKey` — `server_name | series_remote_id
| item_key`, never the title and never the template — which is what
`Marker.matches` and `Marker.pathFor` compare, and `Naming.digest64` is what a
marker with **no catalog series** hashes its stream URL into. The two hashes
differ in what a collision costs, which is why they differ in width:
`Naming.keySuffix`'s 32 bits disambiguate a series folder *name*, while
`digest64`'s two lanes carry a marker's whole identity, where a collision
collapses two unrelated books onto one file — and a single lane reaches that
with a few percent probability over a large library. Lua 5.1 constrains the
shape: every double intermediate must stay exact, which rules out FNV-1a's
`h * 16777619` (~2^56) and forces the two polynomials (`*33`, `*65599`) that do.

**Page bytes live in the document, keyed by page number alone.**
`self.page_bytes` is a four-entry array, most-recent-first. A bare page number
is unambiguous only because exactly one document can reach the store: `self.file`
is fixed and `self.desc` is assigned once, so one instance never serves two
books. **It must not be made shared again** — a process-wide store would need
the book's identity back in the key, which is the whole apparatus this removed.

Its lifetime is the document's: `clearCaches` empties it on close. Two entries
are the floor — the page being rendered, plus the one `hintPage` warms ahead of
it, and nothing in `document.lua` ever holds two pages' worth at once — and the
rest is room for ReaderHinting to ask two ahead. The number is not a memory
figure: these are the *compressed* bytes, orders of magnitude below the decoded
natives kept beside them (`max_cached_native`, three of them, each up to
`max_native_pixels` of 8bpp gray — the decode is grayscale, see below). It
deliberately does not reuse `evictOldest`,
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
  crop toggle, a repaint during teardown — would pay a synchronous HTTP GET
  inside the paint for bytes nothing reads. The bug it also fixes: `renderPage`
  used to return nil and paint the gray placeholder when the bytes were missing
  but a perfectly good decoded page sat in the LRU. `getPageDims` is
  deliberately *not* guarded — it is the decoder, and a live native would have
  answered from `self.dims` before reaching it.
- **Files a previous version left in `cache/meguru/pages` and `.../covers` are
  nobody's problem.** Nothing reads them and nothing sweeps them — there is no
  "Clear cache" row any more, because with no disk cache it would have had
  nothing of its own to clear. Delete the two subdirectories by hand once.
  `Paths.cacheDir` itself survives: it is the last-resort folder for a marker
  when the home folder is unusable (`Marker.homeDir`).

**A decoded page is 8bpp grayscale, and the dither is forced on anyway.** Both
halves are one story, and the second half is a decision with a cost — recorded
here so it is not "corrected" a third time without knowing what it is.
`Mupdf.openDocumentFromText` never sets `doc.color`, and `decodeNativeMupdf`
calls `setColorRendering(false)` besides, so `page:draw_new` takes its
`or BlitBuffer.TYPE_BB8` arm and the cached tiles are BB8 — not the RGB24 an
earlier comment here and in `meguru/doc/image` claimed. That mattered because
the false premise was the whole justification for forcing `sw_dithering = true`
and calling `ditherblitFrom` with no branch: a *converting* blit is what
dithering is for, and ours is a same-format copy. On a BB8 destination
`ditherblitFrom` runs `dither_o8x8` (blitbuffer.c), which quantises a full 8-bit
page to **16 levels on a fixed 8x8 pattern** — a burnt-in dot grid and four bits
of tone gone, on every pixel of every page.

`d40e52e` therefore read the flag from `Screen.sw_dithering`, which is
`framebuffer.lua`'s `setupDithering` answer: on only where there is no hardware
dither, off where the controller does it — the same machinery `PicDocument` and
`ReaderView:onDitheringUpdate` defer to. That remains the more defensible
arrangement, and it is **not** what this document does: `init` sets
`self.sw_dithering = true`, unconditionally, by decision — the dithered look is
what these pages have always had here. On the reporting device the two coincide
(`hw_dither=false`, so `Screen.sw_dithering` was true), which is why the change
is invisible there; on a device whose controller dithers, this now re-quantises
a page the hardware was about to dither properly. One line in `init` is the
whole switch, and `Screen.sw_dithering` is the answer it would take back.

The `if self.sw_dithering` branch in `drawPage`/`drawPageInverted` must stay; a
tile that is ever colour again reaches a grayscale screen through a real
conversion, and there the dither earns its keep.

The night-mode invert stays on the *destination* (`target:invertRect`) rather
than `invertblitFrom` on the tile. With BB8 tiles the latter would now be legal,
but the destination route cannot be affected by the tile's format at all — an
"incompatible bb" throw out of blitbuffer.c lands mid-paint.

**A painted tile is rendered from the page's own bytes whenever it would
otherwise be magnified — one render, at the size the screen asked for.**
`renderPage` chooses between two paths on a single test, `tw > cw or th > ch`:
whether the tile wants more pixels than the region it covers holds.

- **Above it**, `renderRegionDirect` renders the region in **one pass** at
  exactly `tw x th`, straight from the source (`Image.renderRegion`). The crop
  is expressed by putting the region's own start at MuPDF's device-space window
  origin — `draw_new(dc, tw, th, ox, oy)` builds a CTM of `scale(dc.zoom)` and a
  pixmap rooted at the *device* point `(ox, oy)`, so `ox = zoom * nx` makes the
  window and the region coincide. `dc.offset_*` must stay zero; it is a second,
  independent translation.
- **Below it**, the tile is a slice-and-scale of the saved working decode
  (`decodeRegion`), unchanged.

The old shape was the second path for *every* paint, and that is what made a
page narrower than the screen look soft: a 960x1378 page on a ~1236-px screen is
*always* an upscale, and there every painted pixel was a resample of a buffer
that was itself a resample — the working decode — rather than of the file. Stock
KOReader never does this, which is what "MuPDF renders it well" means:
`Document:renderPage` renders the requested rect at the full zoom in one call,
and that is the shape `renderRegionDirect` restores.

The threshold sits where the quality difference is, not where the code is.
Below it the saved decode holds more pixels than the tile needs, so a downscale
invents nothing, and a slice of a cached buffer is far cheaper than a second
open-and-render. That matters because a tile miss is a pan or a zoom step as
often as it is a page turn.

**The threshold is about the paint, not the page, and the two are not the same
test.** A page that is downscaled as a whole takes the slice-and-scale path at
fit-to-screen — that is what `tw > cw` being false means — but a paint that
magnifies *part* of it (a zoom past 1, a panel, a crop box) crosses back over
and goes direct, on a page whose whole-page cost is still that of a shrunk page.
Nothing in the predicate is a statement about the page, and reading it as one is
how "large pages use the old engine" comes to be true only while nobody zooms.
What the page-level questions actually need is the next paragraph.

**For a page being shrunk, what a paint costs is set by the decode budget, not
by the path.** The retained decode is what `decodeRegion` slices and what every
analysis reads — the margin scan (`autoContentBox`), the page-number strip, the
blank check — so `max_native_pixels` (`meguru/settings`) is the per-page cost of
a large page, paid on every turn whatever the reader does. Its history is worth
one line: `adb6445` capped the long edge at 2048 px, `db39a93` replaced that
with an area budget — correctly, because a long-edge cap punished a tall strip
without measure — and raised the retained size for an oversized scan with it.
The default is now **4 Mpx**, which puts an oversized page back near the 2048
cap's work (a 3000x4500 page: 1365x2048 then, 1633x2450 now, 2366x3549 at 8.39)
while the area rule keeps a 800x20000 strip at 410 px of width, against 82 under
the cap it replaced. Pages at or under 4 Mpx — which is every page that fits a
screen — come back at natural size and are unaffected, so the direct render
above still works from real pixels where it matters.

Four log lines make both of those decidable from a device log. **All four are at
`dbg`, and were at `info` for as long as they were being used** — a line that
fires once per page or per paint is worth reading while the render path is under
a microscope and is noise afterwards, and `-d` is what brings them back:

- `Meguru: page N prepared in X ms (fetch F ms, decode D ms, WxH)` — what a page
  turn waited for, split into the two costs with different fixes: the fetch is
  the server's and the only one a reader cannot tune; the decode is
  `max_native_pixels`. `F + D` adds up to `X` by construction — the line is
  logged before the `collectgarbage` that follows the decode, precisely so it
  keeps meaning fetch-plus-decode. A local cbz page has no fetch, so the field
  is absent rather than 0 (which would read as instant).
- `Meguru: page N paint via direct|scale in X ms (zoom, page, region, tile)` —
  one per *rendered* tile, not per repaint, because a tile-cache hit returns
  before it. Which is why it is also the line that says whether a given paint
  crossed the threshold, with the numbers the predicate compared — and the
  millisecond count is what `direct` costs against `scale` on that device, which
  is the only thing that can say whether the threshold is set right.
- `Meguru: MuPDF page render WxH -> WxH (budget N px)` — whether the decode
  budget bit on this page at all, which is the only way to check a hand-edited
  `meguru_max_native_pixels` took effect (no menu writes it, and a stored value
  wins over the default).
- `Meguru: panel zoom on page N, region X,Y+WxH rendered WxH` — one per
  long-press, and the only line that says what the viewer was actually handed.
  The first pair is the region in the space `self.dims` lives in and the second
  is what came back, so a panel rendered *smaller* than its region is the budget
  having bitten and a panel rendered smaller than the screen is the ordinary
  case, not a fault. It is the fourth of these lines; a fourth `dbg` line is not
  a drift in the rule above, because a long-press is a gesture rather than a page
  turn.

The millisecond fields come from `ffi/util`'s `gettime` and not `os.clock`,
which is CPU time and would miss the network wait — the one cost a reader cannot
do anything about — entirely.

When the direct render is *wanted* and fails, its reason rides out on the paint
line (`[direct failed: no bytes cached]`) rather than dying in the render itself.
A caught throw that quietly degrades to a slower render is how the page-number
bug below survived its own first run on a device.

**What stays at `info` and `warn` is the other half of that rule.** A line goes
to `dbg` when it fires on the *normal* path and repeats — per page, per paint,
per decode: that is the render-path lines above, the whole of the crop and
page-number analysis (`crop skip`, `no page number`, `mostly blank`), the paint
and prepare timings, and the `hooked …` notes `hook.lua` writes once at load. It
stays at `info`/`warn` when it marks a **decision, a refusal or a failure** —
every fetch and decode failure, every refused open, every "the feed has nothing
to say" — because that is the line someone reads a `crash.log` for, and it is
usually the only trace of it.

The one that was argued the other way and lost is `crop skip`. It was `warn` on
the grounds that the symptom is reader-visible so the line should be too, which
is a good argument about *importance* and a bad one about *frequency*: a book
whose pages are full-bleed has no light border to find on any of them, so it
fires once per page for the whole book and buries the warnings that are rare.
Frequency wins; see the comment on `cropSkipLog`.

`decodeRegion` stays, and stays first-class: it is still the only path for
`_meguruAnalysisBB`, where a strip wants a cut of a page *already decoded* and
must not pay a fresh open and render per strip.

`_regionSource` opens a streamed page's one-page document **from the byte LRU
and only from it** — `readCachedPage`, never `fetchPage`. A fetch here would be
a synchronous HTTP GET inside a paint, the exact thing `hasNative` exists to
keep out of the render path. A miss falls through to `decodeRegion`, so the
failure costs quality and never a stalled screen.

That document holds **one page, numbered 1** — not the book's page number. It is
opened from the single page's bytes, so `openPage(book_pageno)` throws for
everything past the first page, and the throw is caught. Passing the book's
number is what made the entire direct path a silent fallback for every streamed
book on the first device run, while the local-cbz case — the one place the two
numbers coincide — was the only one that could ever have worked. Hence the rule
for anything reaching a streamed page through a fresh document: **the page
number is 1, and the page is identified by the bytes, never by a number.**

That failure is also why `renderRegionDirect` returns a *reason* alongside its
nil, and why `renderPage`'s paint line prints it. A caught throw that silently
degrades to a slower path is survivable and invisible at the same time; the two
must not both be true, so the reason travels rather than being logged at a level
nobody is reading.

**`Image.renderRegion` rederives the coordinate space rather than taking it.**
Its `nx, ny, nw, nh` arrive in the space `self.dims` lives in, which for an
oversized page is the *capped* size — smaller than MuPDF's own page. It recomputes
the factor between them with the same `cappedDim` the decode used, so the two
cannot drift: were they to, the crop would land on a different part of the page,
silently and by however much the cap had moved.

**Panel zoom is its third caller, and asks for a size the other two do not.**
`Image.renderRegion`'s `tw`/`th` are the buffer to produce; leaving both out asks
for **the region's own size in page pixels**, bounded by `max_native_pixels`. A
paint always knows the rectangle it is painting to and wants exactly that many
pixels, so it always passes a size — but the ImageViewer magnifies what it is
given, so the size it should be given is the region's own. The derivation lives
in the same function, from the same `f`, because that is the only place that
knows how far the caller's space is from the page's.

`MeguruDocument:drawPagePart` is why. Stock's `Document:drawPagePart` picks
`zoom = min(canvas / rect)` — the largest zoom that still fits the panel on
screen — so the tile arrives screen-sized, which for a document behind an engine
is the right trade (rasterising costs the same at any target size, and the viewer
fits it to the screen anyway). A streamed page is a *bitmap*: a panel bigger than
the screen — a splash page, a spread, a large art panel — reached the reader
already reduced to the screen's pixels, so magnifying it in the viewer was
magnifying a resample of the file. Now it is a crop of it, and pinching in
reaches 1:1 with the page rather than 1:1 with the screen. **A panel smaller than
the screen comes back smaller than it used to** and is upscaled by the viewer
instead of by MuPDF — the same pixels either way, which is why the change is
invisible on them, and worth knowing before anyone "fixes" the size back.

Two things about it are load-bearing and not tidiness. The tile goes through this
document's own LRU: the viewer is handed `image_disposable = false` and never
frees what it is given, so a buffer rendered outside `cacheTile` would be lost —
BlitBuffers are malloc'd outside the Lua heap. And when there is no source to
render from (the page's bytes have aged out of the store), it falls back to
stock's screen-fit shape rather than to nothing: a long-press that does nothing
is a worse failure than a softer panel. That path is `pcall`ed for the same
reason every other wrap here is.

**A page that could not be loaded says so, in the place the page would be.**
There are four ways to have no page — no connection, a server that never
answered, a server that answered 404, a page that arrived and would not decode —
and until this they were one gray rectangle and one `warn` per repaint. Three
things changed, and each is small on its own:

- **No socket is opened without a connection.** `MeguruDocument:hasConnection`
  (the same check `analyseAhead` had inlined) gates `fetchPage` and
  `getCoverPageImage`. It is a *device* state, not a probe: Wi-Fi off can only
  fail, and on some backends it fails only after sitting through the socket
  timeout with the UI thread blocked. It says nothing about a server that is
  down with Wi-Fi up — that is the case the timeout and the memo below are for.
  The cover path matters most here: browsing a folder of `.meguru` files is one
  request per book, made while the FileManager waits to draw its mosaic.
- **A failed fetch is remembered, and not attempted again until something clears
  it.** `self.fetch_failed[pageno]` holds `{ reason, code }`. This is not
  tidiness: `ReaderView:drawSinglePage` reaches `document:drawPage` on *every*
  repaint, so a page that failed once paid a socket timeout — and logged a line
  — on every menu opening, zoom step and crop toggle, against a server that had
  already said no. `clearFetchFailures` is the whole of the retry story, and
  exactly two things call it: a page turn (`plugin.onPageUpdate`, which is the
  reader asking for a page again) and the connection coming back
  (`plugin.onNetworkConnected`, which also repaints if anything had failed —
  the event fires once at startup too, hence the return value). A **page turn is
  the retry**; there is no button, and no dialog.
- **The page is replaced by a sentence that names the reason.** The document
  paints the box and passes the `fetch_failed` entry to `self.missing_painter`,
  installed by `ui/reader.lua` — the wording, the font and the layout live there,
  so a document with no reader in front of it (the mosaic's cover path) still
  gets its plain box. One sentence per reason, because the fixes differ:
  connecting Wi-Fi does nothing about a 404, and waiting does nothing about
  Wi-Fi that is off. It is *in the page* rather than over it, which is what a
  browser does and what needs no dismissing — the reader can carry on turning
  pages, and the pages that do load keep loading.
  **There was a drawing here — Meguru-chan lying across a big "404" — and it was
  removed deliberately.** The reason is the one thing a picture cannot carry, and
  the picture's own claim was wrong: a 404 is the internet's shorthand for
  "broken page", and in Meguru's four cases it is literally right in exactly one
  (the server answered 404) and wrong for the two commonest, which never had an
  HTTP status to show at all — no Wi-Fi, and a server that never answered. An
  error page whose headline is the wrong error is worse than a line of prose, and
  a second line of prose under it to say what the picture just got wrong is worse
  still. The asset was deleted with the code that drew it: nothing here keeps a
  file because it might be wanted again (it is in the history), and the whole
  episode is worth knowing because the same four sentences were written for it,
  and they are what is left.
`paintMissingPage` no longer logs. It runs on every repaint of a broken page,
and the failure was already logged once where it happened (`fetchPage`,
`ensureNativeBB`) — the same frequency argument that moved `crop skip`, and the
one line of that rule this change had to apply rather than remove.

**Reading progress is not mirrored anywhere.** It is read lazily, per book, from
the sidecar beside the marker: `DocSettings:findSidecarFile` then
`openSettingsFile`, reading `percent_finished`. That is the only place it lives,
which is what makes a marker safe to rewrite — there is no reader state in it to
lose. (`DocSettings:hasSidecarFile` is the cheaper, parse-free variant of the
same test and is what the resume path below uses, where nothing needs reading.)

**The server's own progress is a separate thing, and it seeds a first open.**
A marker's `last_read` is the page the *server* says the reader stopped on. It is not
a mirror of local progress and never overrides it: `ui/open.lua`'s `offerResume`
asks whenever there is a choice, and offers up to three things — start at page 1,
continue (where the local position is, or the server's page when there is none),
or jump to a later chapter the server says is further along ("furthest in reading
order", deliberately not "most recent", so re-reading an early chapter cannot
move the answer backwards).

**Whether the book has been read here decides the wording, not whether to ask.**
Gating the question on "never opened here" — which is how this started — made the
one case worth asking about unreachable: a reader who has read volume 3 on this
device and got to volume 5 elsewhere got no question at all, because their local
position was treated as a reason not to ask rather than as one of the answers.
The gate is now "is there anything to offer instead", and a book already being
read with nothing further along in its series opens where it was left, silently,
because there is genuinely nothing to decide.

**The reader's page and the server's are both offered, and the server's is one
button with two readings.** A book read to page 30 here and left at page 60
elsewhere has two honest answers, and only the reader knows which they want — so
suppressing the server's page for a book read locally (the first version of this)
threw one away. What the server's position cannot do is be two things at once: it
is either *inside this book*, and then it is a page, or *outside it*, and then it
is a book to open. Hence one button whose label follows:

```
Start reading — Volume 1          the book being opened, never read here
Continue — Volume 1, page 30      the book being opened, where it was left
▶  Continue — Volume 1, page 60 (Server)   the server's position, in this book
   or
▶  Continue — Volume 2, page 2 (Server)    the server's position, in another book
▶  Continue — Volume 2 (Server)            …and no page, when that book is
                                           already read here and will resume
                                           where KOReader left it
```

The `▶` book is the **first chapter the server has not finished**, not the one
anything was read into most recently, and not the last chapter either unless
every chapter is finished — see `firstUnfinishedOrLast` under the Suwayomi
heading for why that distinction has teeth, and where the row above a series feed
deliberately differs.

**Every button names the book it opens, and the title names the series.** The
title is `series.name` — the question is where in the *series* to carry on — and
because it cannot name both books, the buttons each name their own. Before this
the title carried the book (`bookLabel(item)`) and the buttons did not, which is
the arrangement that made two "continue" buttons ambiguous. The book on a button
is still the short form: `bookLabel`, i.e. `volume_label` or the token
`Naming.deriveSeries` peels from the title. `dialogTitle` falls back to that
same short form when there is no `series` — a marker opened from History after a
database rebuild — because there the book is all there is to name.

**The page on the leaving button is only named when the tap will land there.**
`jumpPage` returns nil for a target this device has already read, because such a
book resumes where KOReader left the reader, not at the server's page — naming
one would promise a page the tap does not deliver. It is `nil` exactly when the
target has a sidecar. This is coupled to `MeguruDocument:init`'s silent seed,
which is what lands an unseeded target on the server's page: **change one and
you must change the other.**

**The verb follows the situation, because one verb cannot be true of both.** A
book never opened here used to get `Continue — page 1`, which reads as a
contradiction — there is nothing to continue yet — so it says `Start reading`. A
book that *has* been read continues; one read without a recorded page continues
too, and drops the number rather than claiming one, because it resumes wherever
KOReader left it. A book never opened here shows no page either, though page 1 is
still written to its sidecar.

**The flows that stay silent do so by decision, not by accident of the data.**
A neighbour reached from the reader — "find the next chapter", the automatic
advance at the end of a volume — does not come through `offerResume` at all; it
goes through `Open.openItemSilently`, which prepares the marker and hands it
over. A tap on a named chapter is an instruction, and the dialog answering it
would be the dialog overriding what the reader asked for. That was visible on
"previous chapter": with the server sitting at chapter 7, the only button on
offer pointed *forward* to chapter 7 instead of opening the chapter tapped.

**A recorded page is used exactly as recorded; a *small* lead is simply
ignored.** Servers that track progress count pages *fetched*, and the reader
fetches one page beyond the one on screen (`MeguruDocument.prefetch_count`), so a
book read here is recorded a page ahead of where its reader stopped.

That lead is **never subtracted**. An earlier version did, and it was wrong in the
case that matters most: a position recorded by *another* reader has no such lead —
read on a tablet to page 60 and meguru would have reopened at 57, walking back
three pages already read. The lead is instead *tolerated*: `PSE.samePlace(recorded,
local)` is true when the recording is not meaningfully ahead, and there the
server's button is not offered at all. Read to 23 with the server saying 24: same
place, no button, no dialog, opens at 23. Read to 5 here and left at 60 elsewhere:
page 60, exactly as recorded.

`PSE.SERVER_PAGE_TOLERANCE` is the whole knob — how much of a lead still counts as
the same place. Widening it makes the question rarer; it never changes a page that
is shown.

**A recorded 0 is not the same as no recording.** Kavita marks a chapter unread by
writing `lastRead="0"` rather than by dropping the attribute, and Suwayomi writes
"Progress: 0 of 31" the same way. Both readers therefore return **0**, not nil, and
the distinction is load-bearing: an empty feed entry, or a progress field that
is absent, has to read as "this feed does not publish progress" rather than as
"unread". Collapsing the two is what once let a volume marked unread on the
server stay the furthest-read one here for good, and the resume dialog go on
offering to continue from it.

Returning 0 is safe by construction: every consumer asks `> 0` or `> 1` before
treating the number as a page, so 0 reads as "no progress" everywhere it is used
and still overwrites a stale value on the way into the database.

**The button for the book the reader clicked is always there, and removing it once
broke the feature.** The reasoning for removing it was sound as far as it went —
"start over" is odd wording, and page 1 is not a position anyone is at — but with
the server's answer on the table it is the *only* way back to the book that was
clicked: clicking an unread volume 11 while the server said volume 5 left a single
button pointing at volume 5, and a tap past the dialog cancels. Volume 11 was
simply unreachable.

Two things follow from that button existing:

- **The dialog is gated on the server, not on "is there anything to show".** No
  server answer means no question — what the reader asked for needs none. That is
  also what keeps the dialog from ever having one button: the reader's own button
  is unconditional, so a server answer makes two, and no server answer means the
  dialog is not built.
- **Choosing it for an unread book has to write page 1.** `MeguruDocument:init`
  seeds the server's page into a book with no sidecar, so leaving it unsaid would
  open at the server's page anyway — the server's answer winning a question the
  reader just answered. A book read here but with no page recorded keeps the
  button without a number rather than claiming page 1.

`▶` marks the server's answer because it is the one on the dialog that is not the
reader's own doing; the local one carries no glyph. "Volume 2" and "Chapter 30"
are **the server's own trailing tokens** as `Naming.deriveSeries` peeled them from
the entry title — never abbreviations this code invents. The
`Naming.deriveSeries` example: `"Now That We Draw - Volume 2"` → series
`"Now That We Draw"`, label `"Volume 2"`, index `2`.

Two buttons reading "continue" while pointing at *different books* is worse than
not asking — that was the first wording, where "continue where I left off" was
equally true of the book being opened and of the one OPDS pointed at. Naming the
book in each button fixed the meaning; it is `buttonLabel`, and the name is the
short form because `display_title` — the whole cleaned entry title — overflows the
button once a page number joins it. The marker descriptor has no `volume_label`,
so the file path derives the token from its title with the same function, rather
than showing a full title.

The local page comes from the sidecar (`localLastPage`, only ever called when a
sidecar already exists — `DocSettings:open` creates the file, so calling it for a
new book would invent the evidence). The server's comes from `freshResumeTarget`
on the browser path and `currentResumeTarget` on the file path — and the second
of those is now where both end, see below.

**Suwayomi tracks "read" as a flag of its own, and it is not the page counter.**
This is the single fact behind three separate deviations below, so it is worth
stating once. `pse:lastRead` and the `<summary>` prose count pages *within* a
chapter; the flag is set when a chapter is finished or explicitly marked read.
The two disagree in **both** directions, and each direction broke something:

- a chapter can be flagged **read** with its summary still saying `Postęp: 0 z
  17` — invisible to a page-progress scan, which answered with a chapter the
  reader had not finished instead;
- a chapter merely **started** carries progress while being flagged unread like
  its neighbours — so a scan racing to the furthest progress skips the unread
  chapters in between that have no progress at all.

The flag is in no entry's data; only a feed *filtered* by it says anything. Hence
`Suwayomi.unreadFilter = "unread"` — the driver naming the `filter=` value that
lists exactly those chapters — and three things that follow from it:

**The `▶` button names the first chapter the server has not finished — or, when
it has finished them all, the last one.** `freshResumeTarget(..., select)` takes
a selector:

- `firstUnfinishedOrLast` is the default, and all Kavita has. Reading the sequence
  forward it returns the first entry whose `last_read` has not reached its
  `page_count`; when every entry has, it returns the last entry. A chapter with no
  count is *unfinished* rather than finished — offering it again is a smaller
  mistake than skipping past it.
- `firstIn` is Suwayomi's, on a feed already filtered to the chapters the server
  flags unread. Every entry qualifies by construction, so it is `sequence[1]`.

They are the same *question* answered by different *means*, and the means are not
interchangeable: where a server publishes a read flag, the flag is right and the
page counter merely correlates with it, which is the whole reason `unreadFilter`
exists. See `firstIn` for the case where they disagree.

**The "or the last one" half is not decoration.** A series read to the end has
nothing unfinished, and "nowhere to continue" is not what this button is for — a
reader who finished chapter 177 and taps again is at chapter 177, and a button
that vanished would be saying the series is empty. That case used to fall through
to the stored answer, whose knowledge ended at the last walk, so the same tap
gave two different chapters a moment apart: the first before a background walk
landed (the last *row* it had, not the last chapter), the second after.

This replaced "the last entry with any progress at all", and that difference is
not academic either. A reader who had read volume 1-2 *today* and dipped two pages
into volume 3-4 *yesterday*: the old rule said 3-4, the new rule says 1-2, and 1-2
is where they are. Worse, the two entry points each had their **own** rule — the
browser answered "first unfinished", the file answered "furthest with progress" —
so the same book gave two answers depending on which button opened it. One rule,
one function: `firstUnread` (the row above a series feed) *calls* `firstUnfinished`
rather than restating its predicate, so the two cannot drift apart again. The page
on the label still comes from that chapter's own progress — that is presentation,
not selection.

**`firstUnread` deliberately stops where the `▶` button carries on.** The row
above a series feed uses `firstUnfinished` alone and answers "nothing unread" for
a fully read series; the button uses `firstUnfinishedOrLast` and names its last
chapter. That is not an inconsistency to tidy away: the row offers to *open* a
chapter, so with none to open it says so, while the button offers to *say where
the reader is*, and for a finished series that is its end.

That makes `currentResumeTarget` the single answer for the dialog, and it is
fetched on **both** paths: `registerBook` declines to answer when the driver has
an `unreadFilter`, because the feed the browser holds cannot, and `openAsBook`
fills it in. So an OPDS open on Suwayomi costs one request where it used to reuse
a feed already fetched — the price of an answer the feed on screen cannot give.

**The filtered feed is an optimisation, and it comes up short in two ways.** It
can be **empty** (nothing unread) or it can **fail** — and on a series read to the
end Suwayomi does the second: it has nothing to list under `filter=unread` and
answers that request with a **non-200**, which `Feed.walk` reports as `"http"`
and the resume fetch as no feed at all. Handling only the empty case left the
canonical feed unasked exactly where it was needed, so the answer came from a
stored row rather than from the last chapter, and the same tap gave two different
chapters a moment apart. The canonical feed is now always asked when the filtered
one yields nothing, by either route.

The tell in a log is `series walk unusable ( http )` with a sync of the same
series succeeding seconds either side: same server, same series, one feed
filtered and one not.

**Empty and failed are different answers, and reading them as one is how `▶`
came to name chapter 1 for a series the server calls fully read.** "Empty" means
**the server answered**: nothing is unread, and a read *flag* outranks the page
counter everywhere else in this file — so the canonical feed is asked only where
the series *ends* (`lastIn`), never `firstUnfinishedOrLast`, which would let a
single chapter with four pages of progress outvote the flag and pull the answer
back to chapter 1. "Failed" means we do not know what the server thinks, and
there the counters are the only evidence there is.

The same split runs through the row: an **empty** filtered walk is the row's
answer ("nothing unread", no chapter to open), while a **failed** one sends it to
the canonical feed. Conflating them made the row offer chapter 1 from counters
for a series the server had already said was finished.

**An empty feed is a feed, not a parse failure — and calling it one cost two
symptoms.** `Net.parseFeed` used to reject a document that parsed but listed no
entries, so `Net.fetchFeed` reported it as `"http"`: an HTTP-level failure with
**no status code to find**, because there had been no HTTP error. Suwayomi
answers `filter=unread` on a fully read series with exactly that — a valid, empty
feed — so the misreport was the *normal* answer for a finished series, and it
sent both the row and the resume fetch down their degraded paths. `fetchFeed` now
returns `nil, "empty"` for it, which is its own state and can be handled as one.

**`seriesItems` returns `items, filtered`, and the flag is load-bearing.**
`firstUnread` uses it to decide whether the page counter may be consulted at all,
and `seriesItems`' own fallback hands back the **browser's page**, which the
server did not filter by read status — for Suwayomi, the newest hundred chapters.
Deriving the flag from the driver instead made `firstUnread` take `sequence[1]` of
that page, i.e. the newest chapter rather than the first unread: the same
confusion the ordering apparatus exists to remove, arriving through the degraded
path where nobody would look for it.

**And `seriesItems` retries with the canonical feed** when the filtered walk
yields nothing: no filter, and the marker's own language rather than the
browser's. The filtered feed is an optimisation and this row cannot stand on it
alone — the fallback above answers from the newest hundred chapters, which is how
a row that promises "the first unread" came to open chapter 78 for a reader whose
series starts at chapter 1. The retry is the same URL `Feed.planForMarker` would
build for a walk, so it fails only if every other way of reaching that series
would fail too, which is the whole test of whether the row has a real answer.

**There is no degraded answer, and that is a decision rather than a gap.** There
used to be one — the last chapter any reading had touched, kept from the last
walk — and it answered a *different question* from the fresh read. It was worth
having while it existed, because a stale position beat a dialog with no server
button at all. With nothing stored there is nothing to be stale from, so
`currentResumeTarget` returns nil when the server has nothing to say and the
dialog offers no server position. The log says so, with its reason:
`no resume point from the server ( … )`.

**`firstUnread` takes a `filtered` flag, because "unread" is two different
questions.** With a server that flags chapters, the feed already answered it and
the earliest entry is the answer, page count untouched. Without one, "unread" has
to mean *not finished*, which is what it has always meant for Kavita. The flag is
a property of the *feed* that was fetched, not of any entry in it, which is why
it is passed rather than re-derived.

**`seriesItems` walks the unread feed**, so the row above a series list offers
the same chapter the dialog would — and the walk still runs over the whole chain,
because a filtered feed is only as ordered as the server's `sort` was honoured.


**Both of those go through `readingOrder`, and the one that did not is why the
two entry points disagreed.** `freshResumeTarget` took the last item of the
parsed page with any progress — correct only while the page is ascending.
`currentResumeTarget` fetches `driver.catalogURL`, which asks Suwayomi for
`sort=number_asc`; the page the *browser* holds is `number_desc`, newest first.
So the same function, on the same series, answered "furthest read" with the
lowest-numbered chapter of the newest hundred on one screen and the true
furthest on the other. Hence "▶ Meguru this series opens volume 1 although a lot
more has been read" alongside "opening the same book from the file gets it
right". `readingOrder` is `firstUnread`'s ordering, extracted rather than copied,
and its `positioned` return is load-bearing: the unpositioned tail is *feed*
order, so a backwards scan must not read past it — on Suwayomi that tail is
empty, and on Kavita feed order is reading order, which is why the fallback is
only consulted when no ordered item has progress at all.

The same ordering decides *which* entry is the resume point, and nothing is
written down from it any more.

That is the second half of a longer story, and the shorter version is this: the
ordering was once *stored*, one number per chapter, and every open path numbered
whatever page it happened to be holding. Each of those pages is a slice that does
not start at the series' beginning — the browser's page is newest-first,
Suwayomi's `filter=unread` walk *begins* at the first unread chapter, and a
chapter's metadata feed is one entry deep. So a reader at chapter 41 of a run
they had read up to 40 watched chapter 41 take chapter 1's position, the
tiebreak decided which of the two came first, and "Open next in series" carried
them from chapter 41 to **chapter 2**. Reversing the page before numbering fixed
the direction and left the deeper fault: a page's positions are places *in the
page*. There is nothing to collide with now, because the order is derived per
walk and stored nowhere — and `Feed.neighbor` returns nil rather than a guess
when the key is not in the feed it just read.

**A tap past the dialog cancels — it opens nothing, and it writes nothing.**
`ButtonDialog` is dismissable by default, and the dialog deliberately sets no
`tap_close_callback`. An earlier version did, on the reasoning that a dismissal
had to "land somewhere", and opened the book: tapping past a question is not a
way of answering it, and the reader who does it is saying no.

**The marker is planned, not written, until the question is answered.**
`planMarker` resolves everything — the stream, the descriptor, the directory and
the path — and `commitMarker` writes it. The split exists because the dialog
needs the marker's *path* before the file exists: `neverOpened`, `localLastPage`
and `seedLastPage` are all keyed on the sidecar a path implies (`getSidecarDir`
is pure derivation plus a stat, so a path with no file behind it answers
correctly), and the one thing that needs the file itself is the handoff to the
reader.

This is not tidiness. The marker is what puts a book in the library and in
History, so writing it on the tap and then dismissing the dialog left a phantom
shelf entry for a book nobody chose — the earlier "a cancelled open costs a file
on disk and nothing else" was only true while a file was cheap, and a book in
the library is not.

**A dismissed dialog leaves no folder either, and that is `dirFor` being pure.**
It used to `FS.ensureDir` each component while it built the path, which was
correct while the caller was about to write and became wrong the moment the write
moved to the end of the dialog: the empty series folder appeared on the tap and
outlived the dismissal. An empty folder is not the harmless leftover it looks
like — it is indistinguishable from a series whose books were all deleted, and
nothing in the plugin removes it. `Marker.saveAt` creates the folder now, at the
moment there is a file to put in it, and degrades to the nearest ancestor that
can be made rather than losing the book — the walk is bounded by
`Marker.baseDir()`, which has already vouched for itself.

The outermost folder is the one thing still created up front, because
`Marker.baseDir()` is what answers "is this folder usable": a `marker_dir` on
unplugged media has to be rejected before anything is planned around it.

Two consequences worth knowing. `Marker.saveAt` takes a path rather than
recomputing it through `pathFor`: the path was answered before the file existed,
and `pathFor` consults the directory it is about to write into, so recomputing
could produce a second, different answer. It returns nil when no folder could be
made, and both callers report that rather than opening a path with no file
behind it. And `openAsBook` does **not** go through `commitMarker`, because that
path remembers the credentials the reader just typed into the OPDS form while
`commitMarker` would look them up in `sources` — which is precisely what has not
been flushed yet.

Every button still routes through a single `once(action)`, so a double tap cannot
open two books. **`once` is not what stops the dialog reopening after the open** —
it is per-dialog and dies with it. Worth knowing while touching this:
`ButtonDialog`'s `tap_close_callback` fires from `onClose`, which a button's
`UIManager:close` does **not** reach — that sends `CloseWidget`, a different
event — so the two routes are separable, and a button's own `UIManager:close`
can never re-enter it.

**The dialog asked twice, and a one-shot keyed on the file is what fixed it.**
Every catalog open ends in `handToReader`, which calls `host.ui:switchDocument`,
which calls `ReaderUI.showReader` — the method `hook.lua` wraps in order to ask
where to start. So the wrap re-entered `offerResume` for the book the dialog had
*just* been answered about, and the reader saw the same question again; tapping
its button repeated the cycle. `once` cannot cover this, because `once` makes one
dialog act once and the failure is a *second* dialog.

`Open.noteHandoff(file)` arms a one-shot immediately before the handoff, and the
wrap reads *and clears* it before anything else. The shape is load-bearing in both
halves:

- **One-shot, not a set and not a time window.** The re-entry is synchronous —
  `switchDocument` calls `showReader` in the same statement — while a per-session
  set of "files we have opened" cannot tell it apart from reopening the same book
  from History ten minutes later, which must still ask: the reader may have read
  on and the server may have moved. A timestamp cannot either, since the reopen
  that needs asking about is exactly the one seconds after a close.
- **Keyed on the path**, so it can only suppress the open it was armed for. A bare
  "we are opening something" flag would swallow an unrelated open.

Read-and-clear is what bounds the leak: any later call to the wrap clears the
record whatever that open turns out to be. And nothing is armed when the dialog
is cancelled — nothing is handed over — so "a tap past the dialog cancels" is
untouched by this.

Two callers arm it, and only two: `handToReader`, and the OPDS branch of
`openAsBook` that goes through the built-in plugin's own
`manager:openDownloadedFile`, which does not pass through `handToReader`. The
plain-download route (`showFileDownloadedDialog` → `openDownloadedFile`) is
deliberately **not** armed, so a book opened from the browser's own "Read now"
still asks. Arm it there instead of at the call sites and that question
disappears.

**A stored answer is the wrong answer, and the feed is the right one.** It bears
saying plainly because the obvious implementation is wrong in a way that only
shows on a real library, and it *was* the implementation: a position kept from
the last walk is fresh exactly where the reader has clicked since and stale
everywhere else, so the furthest item *known* is routinely not the furthest item
*read*. Reading to chapter 7 in a browser and then opening volume 3 offered
volume 5.

`Open.freshResumeTarget` therefore asks the feed `OPDSBrowser` has *just* fetched
to draw the list — free, and current — and `currentResumeTarget` fetches the
canonical feed when there is no such feed. There is no third, degraded answer
any more: with nothing stored there is nothing to fall back *to*, so a server
with nothing to say gets a dialog with no server button, which is the honest
thing to show.

That fresh path also carries the "never silently sync the wrong series" guard:
an entry opened from `on-deck` or `recently-added` comes from a feed listing other
series too, so entries are kept only when `driver.discover` places them in the
series being opened, and the parser sees nothing else. **Filter, never reject the
whole feed** — that was the first version and it was wrong. A Kavita series feed
also carries entries with no stream link (a special, a cover-only row) that
`discover` cannot place, so one of them was enough to send every open back to the
stale catalog, producing exactly the symptom the fresh read exists to remove:
opening volume 1 offered volume 4, the last one meguru itself had opened.

When the fresh read is unavailable, each path says so in the log with its reason.
That matters more than it looks: a stale answer and a fresh one present
identically — as a chapter button — and they need opposite fixes.

**It is fetched on every open, and deliberately not cached.** An earlier version
cached the answer per series for 45 seconds, to spare a reader tapping through
several volumes a fetch each time. That window is longer than reading a few pages:
close a book, read on, reopen it within 45s, and the dialog offered the position
from *before* — the server's button ten pages behind the truth, which is the one
thing asking the server was supposed to prevent. The cost bought back is one feed
fetch per open, bounded by `Net.RESUME_*` and only when the network is up.

**The file-manager open is wrapped, because it is the only place left that can
ask.** `hook.lua` wraps `ReaderUI.showReader` — the same runtime-wrap technique it
already uses on `OPDSBrowser` — so a marker opened from the file manager or
History gets the same dialog. Three rules keep that wrap from ever costing anyone
a book: non-`.meguru` files fall straight through before anything else; the whole
offer runs in a `pcall` whose failure opens normally; and the open is called at
most once, so a throw after it cannot open twice.

The wrap asks only for opens that did **not** come from `offerResume`, and that
is what closes the loop the `once` guard could not — see the one-shot keyed on
`Open.noteHandoff` above. It also clears that record before the extension test, so
a record that outlived its open cannot survive the next document anyone opens.
Two traps are worth knowing:

- **`showReader` is called both ways.** `switchDocument` does `self:showReader`
  and the file manager does `ReaderUI:showReader`, so `self` is sometimes the
  class and sometimes an instance. The file is whichever of the first two
  arguments is a string — never `self == ReaderUI`.
- **`switchDocument` routes through it too**, so our own neighbour opens land in
  the wrap. They are harmless (the one-shot below suppresses the dialog), but it
  is why the wrap must not assume it only ever sees file-manager opens.

That path has no browser feed, so its chapter target costs **one request** —
`currentResumeTarget`, gated on `NetworkMgr:isConnected()` and bounded by
`Net.RESUME_*` (4s/8s, not the 10s/30s a walk nobody waits for could afford),
and with no fallback on failure — nothing to fall back to. It passes the
marker's own `lang`, because Suwayomi selects between translations by `?lang=`
and a defaulted language would report the progress of a translation the reader is
not reading. That is now a property of the *book* rather than of the server,
which is strictly better: a library browsed in two languages used to report
whichever was seen last.

**`MeguruDocument:init` keeps a silent seed as the safety net**, for any open that
reaches the reader without going through `showReader` at all — from the marker's
own `desc.last_read`, and with no network call, because `init` runs inside the
document open where a dead server would freeze the screen. A choice made in the
dialog therefore has to leave a sidecar behind, including the choice *not* to
resume: "start from the beginning" writes page 1, or the silent seed would
quietly undo it a moment later.

**A starting page can only be set through the sidecar.** `ReaderUI:showReader`
takes no page, and `after_open_callback` / `registerPostReaderReadyCallback` both
fire *after* `ReaderReady` and the first render, so anything later shows page 1
and then jumps. The one value that reaches the first paint is `last_page`, which
`readerpaging.lua:154` reads in its own `onReadSettings` — so
`Open.seedLastPage` writes it before the handoff. This is why
`DocSettings:hasSidecarFile` must be asked **before** any `DocSettings:open`:
that call creates the sidecar being tested for.

The two servers differ in where that progress comes from, and it is a wire
format, not a design choice: Kavita states `p5:lastRead` on every series-feed
entry, so it syncs for free; Suwayomi's chapter entries carry no PSE attributes
at all, so it is scraped out of the `<summary>` prose — see PROTOCOL.md. Both
end up in the same column, and a series whose server says nothing simply offers
no page.

**A marker opens and reads with no network and no configuration.** That is the
property everything else is built around: `template` and `count` are in the
file, and nothing else is consulted to render a page. What needs a feed is
everything *around* the book — a neighbour, the server's own position, a cover
the marker did not carry — and each of those fails on its own without touching
the book.

**"No configuration" is a different thing, and the difference is one file.** A
marker's `template` is stored with its credential replaced by `<redacted>` and
restored at load from `settings/opds.lua` — so a Kavita marker reads with the
catalogue deleted, and cannot fetch its pages without it. The failure is loud and
self-describing: a 404 whose path says `<redacted>`, plus a warning naming the
missing catalog and the fields that stayed stuck. See `meguru/credential` and
`restoreCredential`.

## The marker

Extension `.meguru`, provider key `"meguru"`. Serialised with `LuaSettings` as
`return { meguru = {...} }`, matching the `DocSettings` sidecar beside it.
`Marker.new` is the one place the shape lives.

```
server_name, series_remote_id, item_key,
title, template, count, last_read,
series_name, server_kind, lang, cover_url, series_cover_url
```

`server_name` is the **catalog title**, which is the key credentials are looked
up by in `settings/opds.lua`. **No secret is stored in the marker** — the three
URL fields (`template`, `cover_url`, `series_cover_url`) have any
credential-bearing path segment replaced by `<redacted>` on the way to disk, and
`Marker.load` puts it back from that catalog. One list
(`CREDENTIAL_FIELDS`) is read by both halves of the pair, so a URL field cannot
be redacted on the way out and forgotten on the way in. What was in files before
this is covered under Security notes, including the markers it does not reach
backwards to.

The three fields that identify the series — `series_name`, `server_kind`,
`lang` — are what let a book opened from History, with no browser and no network,
say which series it belongs to and build the feed URL that would describe it.
`server_kind` is the load-bearing one: without a driver there is no canonical
feed, so a book whose marker lacks it has no neighbour — and the failure is
silent, because the book itself opens and reads perfectly.
`Base.kindFromTemplate` is the rescue for markers written before the field
existed, reading the kind off the stream URL with the same `streamSignatures`
evidence `discover` uses, and refusing when two drivers claim it.

`item_id` is **gone**. It was the catalog's rowid, carried so an open could
notice the database had been rebuilt underneath the marker; there is no database
to be rebuilt. A file written before this still carries the number and nothing
reads it. `Marker.VERSION` is 2, and nothing reads that either — it is a note for
whoever finds an old file.

`Marker.seriesContext(desc)` is the projection of the fields above that describe
the series, and it is what every caller outside the marker module uses — the
reader menu, the resume dialog, the feed planner. A v1 marker answers nil for the
fields it lacks, and each reader of them already has a fallback.

`resolveStream` runs again whenever a page stream is about to be resolved from a
feed, with the stored `template` as the offline fallback. For Suwayomi this is
correctness rather than optimisation: the stored template carries a chapter
number that the server may have renumbered, and a stale one fetches a *different
chapter* while still answering 200.

## Reading a feed

`meguru/feed.lua` is the whole of the engine's network surface for a series, and
**it writes nothing**. It exists because three questions turn out to be one:
walking a `rel=next` chain, putting the entries in reading order, and naming the
entry either side of the one being read.

```
plan  = Feed.planForMarker(desc, opts)   -- marker -> driver + canonical feed URL
walker = Feed.walker(plan.url, plan.walker_opts)
while walker:step() do end               -- HTTP, one page per step
items = Feed.collect(walker, plan)       -- parse + dedupe
seq   = Feed.ordered(items)              -- reading order
next  = Feed.neighbor(seq, item_key, "next")
```

The rules that make a walk safe, each of which has a reason:

- **Pagination is followed by `rel=next`**, never by constructing `?page=N`.
  Kavita's next href is a bare query string and Suwayomi's carries `lang`, so a
  rebuilt URL would quietly walk a different feed than the one being paged.
- **`complete` is conservative** — false on any non-200, an unparseable body,
  the page cap, a repeated `rel=next`, or a cancellation. A walk that is not
  complete is not an answer, and every caller treats it that way rather than
  using what it got.
- **Two page caps, named for their caller.** `Feed.MAX_PAGES` bounds a walk
  nobody is waiting for; `Feed.TAP_PAGES` bounds one started by a gesture. A tap
  cannot spend half a minute of frozen e-ink, and six pages is 600 chapters —
  past the point where walking further to find a neighbour is plausible.
- **`opts.timeout` picks the `Net` preset.** A tap is `"resume"` (4s/8s), not
  the `"feed"` (10s/30s) a background job could afford. There are no background
  jobs any more, so this is always the short one in practice, and it is still a
  parameter because `Feed` does not decide who is waiting.
- **A driver never opens a socket.** Suwayomi's lazy per-chapter metadata fetch
  arrives as an injected `fetch` callback, so credentials, timeouts and log
  redaction stay in one place.

**Nothing is stored, so there is nothing to keep in step.** No transaction, no
generation sweep, no shrink gate, no TTL, no backoff, no resumable stepper
driven from a UI tick. All of that existed to maintain a materialised view of
feeds, and the view is what was removed.

`Feed.ordered` is worth reading before touching anything that picks a chapter.
It orders by the server's own **list position** — the `{n}` in Suwayomi's
`/series/{id}/chapter/{n}/metadata` — falling back to the number
`Naming.deriveSeries` pulls from the title, and to feed order only for entries
with neither. The title alone is not enough: `Prologue 1` carries no chapter
token, so ordering by title parks it *after* every numbered chapter, when a
prologue belongs before them. And `positioned`, the length of the ordered
prefix, is load-bearing for any caller that looks *backwards*: the unpositioned
tail is in feed order, which for Suwayomi is the exact reverse of reading order.

Nothing rewrites other books. A marker is written only for the book being
opened, and the walk that finds a neighbour leaves every file alone — including
the one it was asked from. That is the whole difference from the design this
replaced, where a stale list was the only list there was.

## Drivers

Drivers are **pure functions over already-parsed feeds**. HTTP, pagination,
transactions and credentials stay in the engine — otherwise there are three
copies of the `rel=next` logic and three copies of the loop guard, and HTTP ends
up inside a driver where it cannot be read with understanding. The only I/O a
driver genuinely needs is Suwayomi's lazy metadata fetch, and that is handled by
an injected callback.

```
Base:discover(entry, stream, ctx)        -> series_remote_id, discovered_from
Base:catalogURL(server, series_remote_id) -> the canonical, paginated feed URL
Base:parseCatalogPage(feed, base_url)    -> normalised items
Base:seriesName(feed, entry, ctx)
Base:resolveStream(item, fetch)          -> template, count
Base:folderName(series)
```

`catalogURL` is a pure function of `(server, series_id)` and is **never** derived
from whatever the user happened to be browsing. Kavita's History / On Deck /
Recently Added feeds are truncated and must never be the source of a sync.
`ctx.paths` is required because Kavita's `seriesId` does not appear in a chapter
stream URL — it is only recoverable from the browsing path.

`discovered_from` distinguishes a series feed from an aggregate one. An entry
reached from an aggregate may not carry a recoverable series id, and an aggregate
is not a series. **Never silently sync the wrong series** — that failure class is
documented in the old plugin's `meguru_hook.lua:837-850`.

Driver selection is by a **kind**, and a kind arrives one of three ways: the
session's author sniff, the book's own `server_kind` field, and — only when both
are silent — `Base.kindFor`, which asks each driver's `discover` whether the
entry is its own and takes the answer only when exactly one driver claims it.

That last step is not decoration. A server whose feeds sign themselves with an
`<author>` no driver recognises used to be a soft failure, because the old plugin
only *stored* `server_kind`; here the driver is what knows a series' canonical
feed, so an unknown kind means every book off that server has no neighbour — no
next chapter at all, forever, and silently, because the book itself opens and
reads perfectly.

`Base.kindFromTemplate` is the fourth way to arrive at a kind, and it exists for
a *marker* rather than for a browse: a file written before the descriptor carried
`server_kind` has no feed to sniff, so the stream URL it does carry is asked
instead. It is deliberately conservative in the same way — two drivers claiming a
template returns nil, because a wrong kind is worse than none.

**The manual override is gone, and this is what removing it cost.** There used to
be a strongest source above all of these: a kind set by hand from the
server-administration screen, which went with the Library/Servers views. So a
mis-sniffed server can no longer be corrected from the UI at all. The reason the
override existed is unchanged — a wrong kind picks the wrong driver, and every
feed URL built for that server then describes a different series — which is why
the inference still refuses an ambiguous entry rather than guessing. The repair a
reader has left is to delete the book's markers, which loses nothing but their
directory placement: reading progress lives in the sidecars beside them.

## Reading options

Meguru books share KOReader's per-book `kopt_*` settings, so the bottom
`ConfigDialog` is **curated** rather than replaced: rows the engine does not
implement (page margins, auto-straighten, the reflow and zoom-matrix family) are
dropped, because each would set a value with no visible effect.

The one thing that must not be missed: KOReader's stock "set as default" writes a
**global** `G_reader_settings["kopt_<name>"]`, which would leak a choice made
while reading a stream into every PDF opened afterwards. `ui/reader.lua`
redirects it onto the plugin preference and swallows rows the plugin has no
preference for — that redirection is the reason that file exists.

Two invariants when touching these rows:

- **A row's `values` stay in the row's own domain.** `trim_page` is `{3,1}`
  (none/auto), `rotate_wide_pages` is `0/1/2`, the toggles are `0/1`, `fit` is a
  string. `seedRowValue` copies the stored value through verbatim for exactly
  this reason: `0` is a valid choice *and* is truthy in Lua, so any normalising
  step (`value and 1 or 0`) silently turns "off" into "on" and "crop: none" into
  "crop: auto".
- **`sorting_hint` must name an existing menu item, in that surface's own order
  table.** `menusorter` does `findById(...)` and then indexes the result without
  checking, so a hint naming nothing throws out of the entire menu build and takes
  every other plugin's row with it. `ui/menu.lua` picks it in one place
  (`showUnderTools`, which falls back to no hint rather than a crash), and the
  hint is `"tools"`, which resolves unconditionally in both order tables.
- **A hint alone does not place a row at all.** It is appended to the end of
  that page's row list — for `tools`, below `more_tools`, i.e. below Developer
  options. Naming the id in that page's order list is what decides otherwise,
  and `showUnderTools` does it for both surfaces, putting `meguru` **directly
  below `profiles`** (or at the top where a build has no such id). That is also
  the mechanism core ships (`ui/plugin/insert_menu.lua`), though it targets
  `more_tools`, the position being avoided here. Both edits are safe: an order id
  with no matching item is skipped by the sorter, and a duplicate insert is inert.
  Position is named by neighbour rather than by index on purpose — everything
  above this row is whatever the user has enabled, so an index would land
  somewhere different on the next device.
- **`separator` and `checked_func` are `TouchMenu`-only; `mandatory` is
  plain-`Menu`-only.** Both menus Meguru registers are `TouchMenu`s on a touch
  device — the reader ⋮ menu and the FileManager's, which falls back to the plain
  widget only on a keyboard-only build (`filemanagermenu.lua:1043`) — so both
  fields are usable in these rows. `text_func` renders on either
  (`TouchMenuItem` goes through `Menu.getMenuText`), which is why the destination
  rows carry their state in the text rather than in a `mandatory` value slot.
  (Meguru used to have three plain-`Menu` surfaces of its own — library, series,
  servers — and with them went the reason `separator` was ever unsafe here.)
- **A `Settings` submenu, one level deep, on both surfaces** — the reader's holds
  four rows (auto-open, hide status bar, save folder, per-server subfolder), the
  FileManager's the two destination rows. The FileManager's depth is a deliberate
  cost, paid so the two menus read the same. Nothing nestles deeper, and no
  `sorting_hint` exists below the top-level `meguru` item — the sorter only ever
  orders a page's own rows.
- **The separator is *under* the row that carries it** (`touchmenu.lua:714`), and
  is dropped when that row is last on a page (`touchmenu.lua:713`) — so a
  separator is a hint about the list, never a guarantee about the screen. Two
  lines used to split the reader's submenu into three groups before `Settings`
  existed; one survives, on `Hide status bar`, marking the seam between the
  behaviour rows and the destination rows *inside* `Settings`.
- **The FileManager's `Meguru` submenu carries nothing but that `Settings` row.**
  Both surfaces use the key `meguru`, which is safe because the two `menu_items`
  tables are per-surface and never shared, and `Meguru:addToMainMenu` dispatches
  on whether a document is open — so only one is ever written. A saved menu order
  in `settings/` then means the same thing on both.

### Panel zoom is KOReader's switch, and it is the *reader's*

Meguru adds no row for it. The switch is the stock one — ⋮ →
**Panel zoom (manga/comic)** → *Allow panel zoom* — and `ui/reader.lua`'s
`installPanelZoom` only decides what that row reads and where its answer is
written. What it looks like in the menu, and the long-press that sets an
extension's default, stay KOReader's.

Stock keeps the answer on two levels: a global keyed by **file extension**
(`G_reader_settings:getSettingForExt("panel_zoom_enabled", ext)`) and a copy in
the book's sidecar that **shadows** it from the moment a book has one. The second
level is the wrong level here, and this is the whole of the change. A streamed
book is one chapter of one series, so a per-book copy answers for that one file
and leaves every other one to the global it was shadowing — which is why panel
zoom was on in exactly the book it had last been switched on in. So the global is
read on open, **written the moment the row is flipped**, and never copied into a
sidecar — the copy-written-once failure this plugin exists to avoid, in its
smallest form. Three wraps, one job each:

| wrap | job |
|---|---|
| `onReadSettings` | the value is the global, **after** stock read the sidecar; the text-selection fallback is forced off |
| `onTogglePanelZoomSetting` | the flip is persisted to the extension setting immediately |
| `onSaveSettings` | the per-book copy stock just wrote is deleted, so nothing on disk contradicts the setting |

The ordering is what makes it possible at all: plugins load
(`readerui.lua:464`) **before** the `ReadSettings` event (`:484`), so both the
instance wrap and the reader's first look at the value are in place before stock
computes one. `installPanelZoom` is called from `Reader.install` for that reason,
and it matters no less for the `.cbz` this engine also opens: there the extension
is `cbz`, whose stock default is already on, and the two readers of that file
agree because the suffix is read off the file rather than assumed to be a
marker's.

**The default is on, because it is the default `cbz`/`cbt` get.** A marker is a
stream of page images, which is what an archive of page images is, and a
long-press that silently does nothing on a comic is a surprise rather than a
neutral state. An extension that has never been switched reads as on; only an
explicit `false` — written by the row — turns it off.

The fallback to text selection is forced off with it: nothing on a streamed page
is text, and that fallback reaches `getImageFromPosition`, which no engine-less
paging document answers. A hold that found no panel would land in a text
selection that cannot exist here.

## Plugin lifecycle facts worth not rediscovering

- `ReaderUI:showReaderCoroutine` builds a **new** `ReaderUI`, so the plugin loop
  re-runs and instances are fresh for every document. `Reader.install` therefore
  runs once per book automatically.
- Plugin **modules** load once per process (`PluginLoader.enabled_plugins` is
  cached and never reset), so module-level flags persist for the whole session.
  That is what makes `Reader.installStatusBarHook`'s once-per-process guard
  correct, and what makes the `DocumentRegistry:addProvider` guard necessary —
  `addProvider` only ever appends, so a second call would list the provider twice.
- Every menu surface Meguru writes is a `TouchMenu`; the plugin no longer has a
  plain-`Menu` surface of its own.
- `C_` is **not** a global. Every core file declares `local C_ = _.pgettext`; a
  plugin file that omits it gets a nil call only when a row is built.

Two more, about the browser rather than the lifecycle.

**`OPDSParser:parse` returns the document wrapped under its own root element.**
`createFlatXTable` starts from `{}` and assigns the root's children under the
root's *name*, so an Atom feed comes back as
`{ feed = { entry = {...}, author = {...} } }` with nothing at the top level.
Reading `.entry` or `.author` off the raw parse result therefore finds nothing —
and silently, because "a feed with no entries" and "a feed that was never
unwrapped" are the same nil. `Net.feedFrom` is the one unwrap, used by both
`Net.parseFeed` and `ui/open.lua`; the built-in browser compensates in
`genItemTableFromCatalog` with `local feed = catalog.feed or catalog`. The
asymmetry is what made this survive: `net.lua` unwrapped, so **sync** worked,
while `open.lua` did not, so **opening a book** never catalogued anything — flat
marker, no series folder, no next chapter, and an author sniff that never once
succeeded on a feed that does carry `<author><name>Kavita</name></author>`.

**`OPDSBrowser:parseFeed` parses more than browsable feeds.**
`genItemTableFromCatalog` parses the catalog's OpenSearch descriptor through that
same method, on the same navigation, immediately *after* the real feed. So a
feed-retention rule of "record it if it has entries, clear it otherwise" recorded
the series feed and cleared it again in the same breath. `ui/open.lua`'s
`noteFeed` ignores a parse that is not a feed of entries.

**The row at the top of a series feed is added by wrapping `genItemTableFromURL`,
not `switchItemTable`.** Both were tried; only the first is right. `switchItemTable`
is switched from four places — a navigation, a pagination append, a catalog edit on
the root list, and a search — and only one of them is a series feed, so the row
appeared on the others (a search result list, most visibly, because the retained
feed is still the last series browsed). `genItemTableFromURL` is *handed the URL*,
and the URL is what tells the four apart: a search is a different URL, the next
page is `hrefs.next`, and the root list never comes through here. The decision is
made where the evidence is rather than reconstructed from how the switch was
called.

A row with no `acquisitions` is read by `onMenuSelect` as a **catalog link**, and it
navigates to the row's `url` — so a row of ours must carry a marker field and have
`onMenuSelect` wrapped to intercept it. The row buys nothing on its own.

The row is offered only when **every** entry of the feed discovers to the same
series, the test `freshResumeTarget` already uses. A feed listing *series* has
entries with no stream at all, so they fail `discover` and the row is not offered —
which is why it appears on a list of a series' volumes and nowhere else. It opens
the **first unread** volume, ordered by the number `Naming.deriveSeries` pulls from
each title rather than by feed order, because Suwayomi browses newest-first and
feed order there is the reverse of reading order.

## Development

```
python tools/check.py       # structure of the Lua
```

**A Python mirror of Lua logic models values, not Lua's evaluation rules, and the
difference has shipped a crash.** `meguru/credential.lua`'s `restoreTemplate`
ended `return (s:gsub(...))` — parentheses truncate a multi-value expression to
one, so the `count` its caller branches on was nil on exactly the *successful*
path, where `count == 0` is false and the caller's `count > 1` compared a number
with nil and took the document open down. A harness that returns a tuple cannot
see that; only a harness that models the parenthesisation can. So when a mirror
is written — and it is worth writing, it found nothing wrong in that same file —
say which Lua rules it is modelling, and treat anything it does not model as
untested rather than as passed. The other traps of the same shape: `and`/`or`
folding (`x and f or nil`), `nil` in a table constructor ending the array part,
`#` on a table with holes, and integer division or bitwise operators under 5.1.

There is no Lua interpreter on the development machine, so `check.py` stands in
for one. It runs eight passes:

1. **Block balance** — `function`/`if`/`for`/`while`/`do` against `end`/`until`,
   over comment- and string-stripped source.
2. **Cross-module member references** — every `Module.member` where `Module` came
   from a `require("meguru/...")` binding is checked against the members that
   module actually defines. A require naming a module that **does not exist** is
   an error rather than a skip: it used to fall through silently, which meant
   that once a module was deleted every reference to it became *unchecked*
   instead of reported — the worst possible failure for a pass whose whole job is
   catching references to things that no longer exist, landing exactly when a
   refactor is deleting modules. A module this pass merely cannot read is left
   alone; `doc/document.lua` is a `Document:extend{...}` subclass with no members
   to check and is required perfectly legitimately.
3. **Unbound module tables** — `Geom:new{...}` where `Geom` is never bound in the
   file. KOReader declares no global of this shape, so the name is nil when the
   line runs.
4. **Lowercase calls not yet bound** — `handToReader(host, file)` where the only
   binding is a `local function` *below* the call. **Position is the whole
   pass**: a `local` enters scope from its own statement onwards, so a call above
   it resolves the name as a global and finds nil, while the binding is sitting
   right there in the file for any position-blind check to find. `ui/open.lua`
   shipped exactly that, from three call sites, with a comment nearby correctly
   describing the rule it was breaking.
5. **A name read as a *value* that is bound nowhere** — `pcall(renderMuPDFPage,
   ...)`, or `MAX_X / 1024`. Passes 3 and 4 both key on the shape of the *use*,
   so a name handed over as an argument or an operand slips past both.
6. **A lowercase name reached through a `.` or a `:`** — `data:byte(off + 1)`
   with no `local data` anywhere. A refactor deleted a buffer local and left four
   `data:byte` call sites behind it, and nothing said a word.

And one pass that is not about names:

7. **The marker's field list.** `Marker.new` is the contract between the code
   that writes a marker and the code that reads one, and Lua checks neither end.
   A field read off a descriptor that `Marker.new` does not copy is nil on the
   device — and nil is a legitimate answer for several of them, so the failure
   surfaces as a feature that quietly does nothing rather than as an error. That
   is what happens the first time a field is added to a reader and not to the
   writer, which has now happened once.
8. **The same contract for a book's series**, against the one definition of that
   shape (`Marker.seriesContext`). Pass 7's failure, in a second place, and it
   shipped twice before the pass existed: `Marker.dirFor` read `series.name`
   while every caller passed a context with `series_name`, so **no series folder
   was ever created** and every marker landed beside its series rather than
   inside it; and `freshResumeTarget` filtered on `series.remote_id`, so nothing
   matched and the `▶` server-position button silently never appeared — and
   "the server has no opinion" is a legitimate state, so nothing reported it
   either. Both are the same shape of mistake, and both are invisible on the
   device.

None of these is a parser. They are the failure modes that have actually bitten
this codebase, and that a reader cannot reliably catch by eye: a name or member
that is fine at load time and only explodes when a branch runs, on the device, in
the reader's hands. **The checker passes vacuously if its stripping or its
patterns are wrong**, so each pass was self-tested by injecting the real failure
and confirming the checker reports it — including at the right line. Do the same
before trusting a green run, and this is not a formality: of the passes written
across this project, four were wrong on the first attempt and passed on the very
bug they existed to catch. Pass 4 bound a name anywhere in the file and so found
nothing; pass 7's first draft captured `[a-z_]+`, so an injected `desc.seriesXX`
was reported as `desc.series` — the right verdict for the wrong reason, and
silent for any typo whose lowercase prefix is a real field name.

**`tools/scan_sql.py` is gone**, with the SQL it guarded. It looked for a `;`
inside a SQL comment in a Lua string, which is a hard crash under ljsqlite3
(`conn:exec` splits on every `;`) — there is no connection and no statement now.

### Verifying on the device

No automated tests, so verification is a running KOReader. Run with `-d` or read
`crash.log`, filtering on `Meguru:`.

**A marker written by an older build is not a valid test surface.** A v1 marker
is still valid and still opens — that is a requirement, not a hope — but it
carries none of the series identity added since, so it has no neighbour until
something reopens it from a browser. Confirming that a v1 file *opens* is worth
doing once; testing anything about neighbours against one is not, because a v1
book's inability to find a next chapter is the documented behaviour rather than a
bug. Wipe the markers whenever a change touches the marker's shape.

**Installation must be a directory named `meguru.koplugin`.** `pluginloader.lua`
`_discover()` ignores any directory whose name does not end in `.koplugin` and
strips the suffix to get the plugin name, so `plugins/meguru/` is invisible and
`plugins/meguru.koplugin/` is what loads. On this machine it is a junction, not a
copy, so the repository stays the single source of truth:

```
cmd /c mklink /J "<koreader>\plugins\meguru.koplugin" "C:\dev\projects\meguru"
```

A copy works too, but then the copy is what runs and edits to the repository do
nothing until it is refreshed.

**Read the whole log, not just the crash.** KOReader catches non-fatal errors
inside `pcall` and logs them as `warning: UNHANDLED EXCEPTION!` plus the message,
then carries on. So a line like that *before* the fatal crash is a **second,
independent bug**, and the crash below it is not necessarily the first thing that
went wrong. Both of the first two device failures were of this shape: the fatal
one named its file and line, and the one above it named neither.

When a message names nothing, the string is worth chasing to its source rather
than guessing — it is often a vendor library's, and the string next to it in the
binary explains the rest:

```
grep -rn "<message>" <koreader>/            # which file, if it is Lua
grep -a -o -E "[ -~]{6,}" libs/libwrap-mupdf.so | grep -i "<message>"
```

That is how `argument error: missing file type` was traced to
`Mupdf.openDocumentFromText` and its non-optional second argument: the adjacent
string in the wrapper is `cannot find document handler for file type: '%s'`,
which says a *wrong* type fails loudly and differently, and makes supplying a
guessed type safe. Two messages, no debugger, no device round-trip.

Each step must pass before the next:

1. **The plugin with no network and no store.** Open the FileManager's
   `Tools → Meguru` submenu — no crash, and it holds the two destination rows and
   nothing else. Then open a marker from History with the wifi off: it reads, and
   "Open next in series" says the series has no next chapter rather than
   opening the wrong book or hanging.

2. **A marker opens with nothing configured.** Open a book, then rename
   `settings/opds.lua` and reopen the marker from History — the book must open and
   read, and its pages must fail with a 404 whose path says `<redacted>` and a
   warning naming the fields that stayed stuck. Put the file back: pages fetch
   again. This is the pair `meguru/credential` exists to keep in step.

3. **The marker names the right chapter.** Hand-edit `item_key` in a
   marker to another item's key — the open must land on whatever that key names,
   because the key is the whole of a book's identity and nothing else is
   consulted. Then hand-edit `server_kind` to a wrong value: the book still opens
   and reads (the kind is only what builds a feed URL), and "Open next in series"
   reports that it cannot look rather than answering with a wrong chapter.

4. **Page fetching.** One log line per page with a rising `pageNumber` plus
   prefetch, and **no** fetch of a whole archive. `cache/meguru/` does not grow
   while reading — nothing is written there at all any more. Alongside it, one
   `Meguru: page N prepared in X ms (fetch F ms, decode D ms, WxH)` per page
   turn, one `Meguru: MuPDF page render WxH -> WxH (budget N px)` per *decoded*
   page, and one `Meguru: page N paint via direct|scale in X ms` per rendered
   tile: on a manga page that fits the screen the render line shows the page
   uncapped and the paint line says `direct`; on an oversized scan the render
   line shows the reduced size — that pair is the whole check that the budget is
   doing what `meguru/settings` says, and the two millisecond counts say what
   the budget is worth on that device. Then turn back one
   page and force a repaint (open/close ⋮, toggle a crop setting): **no fetch**,
   because the page's decoded buffer is still live and the bytes are not needed
   for it. Turn back past the four-entry store and a fetch *is* expected — that
   is the trade this makes, not a regression. Then close the book and reopen it:
   the page it reopens on is fetched, because the store died with the document.

5. **Engine port.** On the same title as the old plugin: crop, page-number crop,
   panel zoom, night-mode invert, wide-page rotation, local `.cbz` via "Open
   with…" — behaviour identical to the old plugin.

6. **Concurrency.** Two windows (FileManager + ReaderUI): the provider registers
    once, and a walk started from one does not disturb the other. The UI must stay
    responsive while a walk runs — it is synchronous, so what keeps it bearable is
    the page cap and the short timeout, and a tap that walks must be visibly
    bounded rather than merely explained.

7. **Two books, one title.** Open a "Chapter 1" from two different Suwayomi
    series (or two Kavita volumes both titled "Volume 1"). Each renders its own
    pages — the failure this guards against was one book being served another's
    *bytes*, which is now impossible by construction, since the store is
    per-document and keyed by page number. What is still worth checking is that
    neither book's marker was adopted by the other: each opens the chapter it
    names, and both markers exist in their own folders.

8. **Nothing on disk but markers.** Read several pages, then confirm
    `cache/meguru/` is empty (or absent) and that no `meguru.sqlite3` reappears in
    `settings/` — including after browsing a folder of `.meguru` files in the
    mosaic, which *does* fetch each cover over HTTP and must still write nothing.
    In that same browse, the covers must actually appear: the book's own where its
    feed published one (a Kavita volume), else the series', else page 1 of its
    stream — and at most one fetch per book, since `BookInfoManager` remembers the
    thumbnail afterwards. With the wifi off, covers already extracted stay on
    screen and nothing crashes. The two subdirectories a previous version wrote
    (`pages`, `covers`) are not cleaned by anything: delete them by hand once and
    confirm they stay gone.

9. **The dialog asks once.** Tap a volume in a series feed, answer the dialog:
    the book opens and **no second dialog appears**. Then close it and reopen the
    same book from History — **the dialog comes back**, which is the half of the
    test that catches a guard that suppresses too much. Reopen a *different* book
    and confirm the earlier one's record is not swallowing it.

10. **The jump button does not re-ask.** With the server further along in another
    volume, tap its `▶` button: that volume opens with no dialog, and the page in
    the label is the page it lands on. Tap a jump onto a volume already read here:
    the label names no page, and the book resumes where KOReader left it.

11. **The silent opens stay silent.** ⋮ → Meguru → "Open next in series" on an
    unsynced series: the walk runs, the chapter opens, no dialog. Finish a volume
    with `Auto-open next in series` on: the next volume opens with no dialog.

12. **The menu lands where it should.** FileManager → Tools → `Meguru` directly
    below `Profiles` (and at the top where the build has no `Profiles` row),
    holding a single `Settings` row and nothing else; the reader's ⋮ → Tools →
    `Meguru` holds `Open next in series`, `Open previous in series` and the same
    `Settings` row. Nothing anywhere offers a cover, a cache to clear, a library
    or a server list.
    Inside `Settings`, on both surfaces: `Auto-open next in series` (reader only,
    and only when the marker names a series), `Hide status bar`, a line,
    `Main folder for .meguru streams: …`, `Subfolder per server`. The folder row
    opens the picker and shows the new path afterwards; the toggle's checkbox
    survives a restart and so does the folder; a new book lands in
    `<base>/<server>/<series>` when the toggle is on. Holding `Auto-open next in
    series` or `Subfolder per server` shows its `help_text` — the other rows have
    none, and that one line is the only separator left. With a PDF open there is
    no Meguru row and nothing logs `menu id not found`.

13. **No destination dialog anywhere.** `▶ Meguru this series` with the wifi off
    still prompts for a connection and then opens, straight into the resume
    dialog. Neither it nor the top-of-feed row ever asks for a folder.

14. **A dismissed dialog leaves nothing at all.** List the marker folder first.
    Tap a volume in a series feed, then tap *past* the resume dialog: no
    `.meguru` appears, **no series folder appears**, and nothing new appears in
    the library or in History. Answer the dialog on a second try and both the
    folder and the marker do appear, in the place the first tap would have used.
    Do this on a series that has no markers yet — an existing series already has
    its folder, which is why the folder leak was easy to miss.

15. **The two entry points agree on the server's position.** On Suwayomi,
    read into chapter 40 of a 50-chapter series, then open an early chapter (say
    3) from the OPDS browser: the `▶` button must name chapter 40, not chapter 1.
    Open that same early chapter's marker from History and the `▶` button must
    name the same chapter 40. Both paths now end at `currentResumeTarget` with the
    marker's `series_remote_id` and `lang`; before, one feed was `number_desc` and
    the other `number_asc`, and the two answered differently.

16. **The `▶` chapter is the first the server flags unread, and progress is not
    consulted.** On Suwayomi, set up exactly the state that tells the two rules
    apart: mark chapters 1–9 read, leave chapter 10 *started* (its summary says
    `2 z 22`), and mark 15–17 read. The `▶` button must name **chapter 10, page
    3** — not 15 or 17, which the page-progress scan would reach first. Then
    finish chapter 40 with 41–42 untouched and 43 started: the button must name
    **41**, with no page. The log must show a fetch carrying
    `filter=unread&sort=number_asc`; if it shows `filter=all`, `unreadFilter` did
    not reach `catalogURL`. The same chapter must come from the row above the
    series list (`firstUnread`'s `filtered` branch) and from the same book opened
    from History — three entries into one answer.

17. **Panel zoom is one switch for every Meguru book.** With no
    `panel_zoom_enabled` entry for `meguru` in `settings.reader.lua`, open a
    book and long-press a panel: it zooms, without anything having been turned
    on first. Turn it off in ⋮ → *Panel zoom (manga/comic)* → *Allow panel
    zoom*, close the book, and check that `meguru` is now `false` in
    `settings.reader.lua` **and that the book's own sidecar has no
    `panel_zoom_enabled` at all** — that key is the copy this does not keep.
    Open a *different* Meguru book: off, which is the half that a per-book
    answer would have got wrong. Also worth one line: open a `.cbz` through
    "Open with… → Meguru" and confirm it reports what the same file opened by
    MuPDF does, since both read the `cbz` entry.

18. **Panel zoom is a crop of the page, not of the screen.** On a book whose
    pages are bigger than the screen (a Kavita volume; anything at or under
    4 Mpx is not capped and is the same picture either way), long-press a panel
    that covers a good part of the page. In `-d` the `panel zoom on page N,
    region … rendered WxH` line must show an output larger than the screen — for
    a panel that is half the page, roughly half the page's own size — and the
    image must stay sharp when pinched in the viewer, which is the whole point:
    before this it was handed a screen-sized resample and had nothing left to
    magnify. Two things to check while there: a panel *smaller* than the screen
    still looks right (it comes back small and the viewer upscales it — that is
    the intended shape, not a regression), and a long-press with the wifi off
    and the page's bytes aged out of the store still shows a panel, softer,
    through the `Document:drawPagePart` fallback.

19. **A book that cannot get its pages says why, once, and stops asking.** With
    the wifi off, open a marker: the page area holds *Can't load this page /
    You're offline right now. Connect to Wi-Fi and try again.* — the reason, in
    the place the page would be. Check the two cases that must not be confused:
    with the wifi *on* and the server stopped it must read *Kavita isn't
    responding…*, and with a marker whose catalog was deleted (a 404) *Kavita
    returned an error (404)…*. In `-d` the same two cases are `(no response)`
    and `(HTTP 404)`. Then the rest, which is about not asking twice: one
    `Meguru: no connection, cannot fetch page N` in the log rather than one per
    repaint; open the ⋮ menu and close it, zoom, toggle a crop setting — the
    page repaints but nothing is fetched and nothing more is logged; turn the
    page and back — one fresh attempt, so `fetchPage` runs again and fails
    again; turn the wifi on — the page fills in **without a page turn**, from
    `onNetworkConnected`. In the FileManager with the wifi off, open a folder of
    markers: no cover is fetched at all (no log lines from `getCoverPageImage`),
    and the mosaic fills in on the next browse once the wifi is back. Nothing
    was written to disk through any of it.

## Known open items

- **A page is decoded at its file's stated density, not at its pixels.**
  `renderMuPDFPage` sizes the render from
  `page:getSize()`, which is `fz_bound_page` — points at 72 dpi — and for an
  *image document* MuPDF computes that box as `pixels x 72 / density`, assuming
  **96** when the file says nothing. Measured on a 768-square PNG: 768 pt at
  72 dpi, 576 with no density, 184 at 300 dpi. So a density-less 1600x2400 scan
  is decoded at 1200x1800 — 25% below its pixels — and a scan carrying 300 dpi
  at a quarter, silently, because the budget below is an *area* cap and reports
  the same capped numbers either way. The `MuPDF page render WxH -> WxH` line
  cannot show it either: both of its sizes come from the same space. What keeps
  this from being visible today is that `renderRegionDirect` re-renders a
  magnified region from the source, and a fit-to-screen page is usually still
  covered at 75% — which is exactly why it should be measured before it is
  "fixed": the fix is either teaching the decode the density (PNG `pHYs`, JPEG
  JFIF) or moving the plugin's whole coordinate space to pixels, and every
  geometry path shares that space. It wants its own pass on a device.
- **Kavita granularity** is resolved in PROTOCOL.md (entry ↔ stream is 1:1).
  `driver/komga.lua` and `driver/generic.lua` are not written yet; see Layout.

Settled and worth not re-litigating: `Settings.DEFAULTS.rotate_wide = 1` is
correct. The old plugin's fallback *row* carries `default_value = 0`, which looks
like a conflict, but that value only applies when the pagenumbercrop plugin is
absent — the book itself is seeded by `perBookGeometryDefaults`, whose classic
default is right-turning (`meguru_marker.lua:373-386`). The new plugin seeds 1,
which matches what a fresh book actually got.

## Security notes

- **No secret is in a marker file, and `Marker.saveAt` is what enforces it.**
  `server_name` is a catalog title; Kavita's API key is a path segment of the
  stream template — **and of every URL it publishes, covers included** — so all
  three URL fields are replaced with `<redacted>` on the way to disk and put back
  by `Marker.load` from `settings/opds.lua`. One member of the pair on each side,
  and one list (`CREDENTIAL_FIELDS`) naming the fields both halves walk, so a URL
  field added to `Marker.new` cannot be redacted out and forgotten back — see
  `meguru/credential`.
- **A marker written before that pair existed still carries the key, forever.**
  Markers are not scrubbed in place: rewriting a book file the reader did not ask
  to have rewritten is worse than a stale copy in a folder they control. So
  "markers hold no secret" is true of new ones; delete and re-add the old books
  if it matters. Saying this plainly matters more than the fact, because the
  opposite reads as settled.
- Credentials are resolved only when a page actually has to be fetched.
- The derived `catalogURL` is never stored or logged — no API key, no token. It
  is built at call time from `settings/opds.lua` and kept in a local.
- **`crash.log` is a file too, and `Net.redactUrl` is the only thing a log line
  may print a URL through.** It strips the credential-bearing path segment, so
  the four failure lines in `Net.get` no longer write Kavita's key out on every
  404. The query is reduced to its byte count and `user:pass@host` never reaches
  the output; both are load-bearing and neither should be "simplified".
- Kavita's stream `template` in a marker unavoidably embeds the API key; that is
  what opens the book. It is bounded to that one field in a file the reader
  controls, and to `settings/opds.lua`, where the key already lives. The markers
  that carry it in plaintext are the ones written before the redaction pair
  existed; nothing scrubs them, by the rule above.
- `settings/opds.lua` is read **only**, never written.
