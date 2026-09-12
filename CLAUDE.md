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
  fs.lua                  filesystem predicates and directory creation
  settings.lua            plugin-wide preferences in G_reader_settings
  association.lua         Meguru's claim on .cbz: the file-type reader association
  sources.lua             read-only view on settings/opds.lua (catalogs + credentials)
  net.lua                 HTTP GET, feed fetch + parse
  naming.lua              sanitizeComponent / deriveSeries / alias / glyph / identity digest
  marker.lua              marker read/write, naming, collision resolution, series context
  credential.lua          what a credential looks like in a URL: redact / restore
  pse.lua                 OPDS-PSE: link extraction, template -> URL, page fetch
  feed.lua                reading a series feed: the rel=next walk, order, neighbour
  panel.lua               the panels on a page, and the order they are read in
  hook.lua                runtime wraps on OPDSBrowser (sniff, "Meguru this series")

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
```

`tools/check.py` is a development aid, not part of the plugin.

Not yet written: `driver/generic.lua` — the `kind = NULL` driver that can
only discover a series by title heuristic and cannot build a canonical
`catalogURL`, so there is no feed to walk for a neighbour. Until `generic.lua`
exists, an unrecognised server is handled by the absence of a driver rather than
by a driver that returns nothing useful.

**Nothing is written to disk but markers**, plus the sidecar file KOReader keeps
beside every document it opens. There is no page cache, no cover cache and no
database: pages live in a small RAM LRU, a cover is refetched on every call, and
the panel lists a long-press produces live in a four-entry RAM LRU on the
document itself, so they are dropped with the book.

`meguru.sqlite3` may still be sitting in `settings/` from a version that had one,
and `cache/meguru/pages` and `.../covers` from a version that wrote them. Nothing
reads them and nothing sweeps them; delete them by hand once. `Paths.cacheDir`
itself survives: it is the last-resort folder for a marker when the home folder
is unusable (`Marker.homeDir`).

The dependency graph is a DAG with no cycles and **exactly one lazy edge**:
`feed.lua` requires `meguru/naming` inside `Feed.ordered`, because the ordering is
the one thing both entry points share and an edge at load time would have made it
circular. `ui/panelzoom` requires no `meguru/` module at all — it is handed panels
as arguments. The edges that do exist between the panel modules are `ui/reader` ->
`ui/panelzoom`, `doc/document` -> `panel`, and `panel` -> `doc/image`.

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

**Both links go through the same redaction as the stream template.** Kavita puts
its API key in the path of every URL it emits, covers included, and a marker lives
in the reader's *book* folder rather than in `settings/` — so `CREDENTIAL_FIELDS`
in `meguru/marker.lua` lists all three, and a field added to `Marker.new` without
being added there is written to disk with the key in it.

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

**A decoded page is 8bpp grayscale, and the dither is forced on anyway.** Both
halves are one story, and the second half is a decision with a cost — recorded here
so it is not "corrected" a third time without knowing what it is.
`Mupdf.openDocumentFromText` never sets `doc.color`, and `decodeNativeMupdf` calls
`setColorRendering(false)` besides, so the cached tiles are BB8 — not the RGB24 an
earlier comment here and in `meguru/doc/image` claimed. That mattered because the
false premise was the whole justification for forcing `sw_dithering = true` and
calling `ditherblitFrom` with no branch: a *converting* blit is what dithering is
for, and ours is a same-format copy. On a BB8 destination `ditherblitFrom` runs
`dither_o8x8` (blitbuffer.c), which quantises a full 8-bit page to **16 levels on a
fixed 8x8 pattern** — a burnt-in dot grid and four bits of tone gone, on every
pixel of every page.

Reading the flag from `Screen.sw_dithering` — `framebuffer.lua`'s `setupDithering`
answer — would be the more defensible arrangement, and it is **not** what this
does: `init` sets `self.sw_dithering = true`, unconditionally, by decision. The
dithered look is what these pages have always had here. On a device whose
controller dithers properly, this re-quantises a page the hardware was about to
dither correctly. One line in `init` is the whole switch, and `Screen.sw_dithering`
is the answer it would take back. The `if self.sw_dithering` branch in
`drawPage`/`drawPageInverted` must stay: a tile that is ever colour again reaches a
grayscale screen through a real conversion, and there the dither earns its keep.

The night-mode invert stays on the *destination* (`target:invertRect`) rather than
`invertblitFrom` on the tile. With BB8 tiles the latter would now be legal, but the
destination route cannot be affected by the tile's format at all — an "incompatible
bb" throw out of blitbuffer.c lands mid-paint.

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
- `Meguru: panel zoom on page N, region X,Y+WxH rendered WxH` — one per long-press,
  and the only line that says what the viewer was actually handed. The first pair is
  the region in the space `self.dims` lives in and the second is what came back, so
  a panel rendered *smaller* than its region is the budget having bitten and a panel
  rendered smaller than the screen is the ordinary case, not a fault. It is the
  fourth of these lines; a fourth `dbg` line is not a drift in the rule below,
  because a long-press is a gesture rather than a page turn.

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

`Feed.ordered` is worth reading before touching anything that picks a chapter. It
orders by the server's own **list position** — the `{n}` in Suwayomi's
`/series/{id}/chapter/{n}/metadata` — falling back to the number
`Naming.deriveSeries` pulls from the title, and to feed order only for entries with
neither. The title alone is not enough: `Prologue 1` carries no chapter token, so
ordering by title parks it *after* every numbered chapter, when a prologue belongs
before them. Its second return, the length of the ordered prefix, is load-bearing
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
```

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
(`Image.rasterFor`), ordered rectangles come out in **full native** coordinates. It
knows nothing about documents, pages or fetching — `MeguruDocument:getPanelsFromPage`
is the seam, and it hands over one decoded buffer and takes back a list.

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

Two things complicate the cut, and both are ported. Panels are rarely drawn square,
and a gutter tilted by two degrees leaves no column empty from top to bottom — enough
to stop the straight cut dead. When no straight gutter exists and an axis already has
a near-empty line, a ladder of slopes from 2 to 8 degrees either way is tried instead
and the projection is taken along the slanted line; both children then get the whole
projected band, so each panel keeps its own artwork and gains a thin wedge of its
neighbour rather than losing a corner. The other is page furniture: a scanlation
credit line clears both size floors comfortably, so `emitLeaf` rejects it on the
*conjunction* of elongated and nearly inkless. Neither test works alone, and that
function's comment carries the measurement that says so.

The scan targets the page's **width**, not its long side, and that is not cosmetic: a
1600x2400 page maps to 480x720 — one cell per 3.3 page pixels, so a 10-pixel printed
gutter is 3 cells wide. A ceiling on the long side would give 320x480, one cell per 5
pixels, and the same gutter 2 cells wide. `PANEL_SCAN_MAX_CELLS` then caps the cell
count, and it first bites past 5.2:1 — a webtoon strip, and only a webtoon strip.

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

**The connected-component detector is deliberately not ported.** It groups ink into
connected bodies and keeps each one as a box, merging only boxes that entirely contain
one another. So a component and the panel it sits inside stay two boxes, and the
reader sees the same panel twice with slightly different crops. The cut cannot produce
that: its leaves are disjoint by construction. That is the whole argument, and it is
why "the reference's live detector" is not by itself a reason to port something — the
reference's live detector is whatever its authors last switched on, not a verdict.

That argument was once contested from the other side, and the contest is settled.
`05790d1` replaced the cut with the component detector on the grounds that a genuinely
white band *inside* a panel was being cut in two; `9c9f042` put the cut back, on the
grounds that the component detector showed the same panel twice — and neither commit
had a device reading behind it. The cut has since been exercised on a device and stands,
so **the thresholds are the part to keep and the algorithm is not the part to swap**.
Anyone reaching for the component pipeline again is re-litigating a settled question.
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

The four overrides are `switchToImageNum` (recompute `rotated` per panel, then release
the one left behind, then re-arm the warm), `onShowNextImage` / `onShowPrevImage`
(boundary past either end), and `onTap` / `onSwipe`. **Those last two exist for one
reason:** stock picks the sides from `BD.mirroredUILayout()` — the UI language — and a
manga read in a Polish UI gets stock's answer backwards. Everything else is delegated
to stock, including the tap outside the frame that closes the viewer and the
bottom-left screenshot corner, which are deliberate gestures this must not quietly
take over. The hardware keys come free: `ImageViewer:init` binds `PgFwd`/`PgBack` to
next/previous image and `Back` to close whenever `image` is a list.

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
rendered WxH` already fires once per panel render, including once per warm.

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
  and `showUnderTools` does it for both surfaces, putting `meguru` **directly below
  `profiles`** (or at the top where a build has no such id). Position is named by
  neighbour rather than by index on purpose — everything above this row is whatever
  the user has enabled, so an index would land somewhere different on the next device.
- **`separator` and `checked_func` are `TouchMenu`-only; `mandatory` is
  plain-`Menu`-only.** Both menus Meguru registers are `TouchMenu`s on a touch device,
  so both fields are usable in these rows. `text_func` renders on either, which is why
  the destination rows carry their state in the text rather than in a `mandatory` value
  slot.
- **A `Settings` submenu, one level deep, on both surfaces** — the reader's holds six
  rows (auto-open, panel zoom, hide status bar, save folder, per-server subfolder,
  default reader for `.cbz`), the FileManager's the three that are not about a book
  already open. The FileManager's depth is a deliberate cost, paid so the two menus
  read the same. Nothing nestles deeper, and no `sorting_hint` exists below the
  top-level `meguru` item — the sorter only ever orders a page's own rows.
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

## Development

```
python tools/check.py       # structure of the Lua
```

There is no Lua interpreter on the development machine, so `check.py` stands in for
one. It runs eight passes:

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
5. **A name read as a *value* that is bound nowhere** — `pcall(renderMuPDFPage, ...)`.
   Passes 3 and 4 both key on the shape of the *use*, so a name handed over as an
   argument or an operand slips past both.
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
12. **The menu lands where it should.** FileManager → Tools → `Meguru` directly below
    `Profiles`, holding a single `Settings` row and nothing else; the reader's ⋮ → Tools
    → `Meguru` holds `Open next in series`, `Open previous in series` and the same
    `Settings` row. Nothing anywhere offers a cover, a cache to clear, a library or a
    server list. Inside `Settings`, on both surfaces: `Auto-open next in series` (reader
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
    | a panel carrying a full-width **white band inside its own drawing** | **ONE panel.** The band must not cut it in two |
    | a page of **tilted panels** — a skewed scan, or gutters that are not axis-aligned | **the panels, split** — `K panels` in the log with K what the eye counts |
    | a normal manga page, 4–6 panels with hairline gutters | the same sequence, in the same reading order, as before |
    | a splash page with no panels at all | the viewer opens on **the whole page** (1 of 1), no progress bar, and a swipe forward **turns the page** |
    | a page the detector refuses | **no panel appears twice**, in either direction, and the count matches the eye |

    Then the mechanics. In `-d`, one `page N panel zoom: K panels … in X ms` per
    long-press; a refused page says `K panels, whole page (<reason>)` and the reason
    must name one of the four tests — `no panels`, `single partial panel`, `panels cover
    too little of the page`, `only N% of the covered area kept`. Compare the milliseconds
    against the `page N prepared in X ms` line on the same page: the scan sits on top of
    that decode and should be a fraction of it. Then **toggle Manga mode with a page open
    and long-press it twice** — the second press must give the mirrored order, which is
    the whole job of the cache key; and **long-press, close, long-press the same page** —
    the second must be instant and log the same count (the LRU hit), with nothing new on
    disk. Then cross a page boundary from the last panel: `getPageDims` for the next page
    must appear **once** (the warm) and not again during the crossing, and there must be
    no second `MuPDF page render` line for it — two mean the warm's call order is wrong.
    Cross back and forth three times: no fetch and no decode after the first. Finally a
    page that cannot be decoded (wifi off, bytes aged out) shows the page and **no
    viewer**, logging `no page (…)`.

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
- **Kavita granularity** is resolved in PROTOCOL.md (entry ↔ stream is 1:1).
  `driver/generic.lua` is not written yet; see Layout.
- **Komga's `pse:lastRead` has never been seen carrying a value.** Every capture was
  of a library nobody had read, so `readProgress?.page` was absent on every entry and
  the feed looked like a server that tracks nothing — it does. PROTOCOL.md has the
  source line; what is unverified is only whether that page is one-based, as Komga's
  own numbering is. Wants a device check against a book with progress: a zero-based
  value would offer a page one early, and `PSE.samePlace`'s tolerance would hide it.

Settled and worth not re-litigating: `Settings.DEFAULTS.rotate_wide = 1` is correct. The
old plugin's fallback *row* carries `default_value = 0`, which looks like a conflict, but
that value only applies when the pagenumbercrop plugin is absent — the book itself is
seeded by `perBookGeometryDefaults`, whose classic default is right-turning. The new
plugin seeds 1, which matches what a fresh book actually got.

## Security notes

- **No secret is in a marker file, and `Marker.saveAt` is what enforces it.**
  `server_name` is a catalog title; Kavita's API key is a path segment of the stream
  template — **and of every URL it publishes, covers included** — so all three URL fields
  are replaced with `<redacted>` on the way to disk and put back by `Marker.load` from
  `settings/opds.lua`. One member of the pair on each side, and one list
  (`CREDENTIAL_FIELDS`) naming the fields both halves walk, so a URL field added to
  `Marker.new` cannot be redacted out and forgotten back.
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
