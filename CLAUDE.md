# meguru

A KOReader plugin that turns OPDS-PSE page streams (Kavita, Suwayomi) into
ordinary KOReader "books". Each book is a small on-disk **marker** file; the
pages come off the network one at a time as they are read.

This is a from-scratch successor to `meguru.koplugin`, which lives beside it and
**is not to be modified**. The old plugin remains the reference for behaviour and
the fallback if this one misbehaves. There is no compatibility between the two:
different marker extension, different descriptor, different data. Orphaned
reading progress from the old plugin is accepted and intended.

The single structural change is that **series state lives in a local SQLite
catalog**, not inside every marker file. The old plugin copied the sibling list,
the volume order and the titles into each `.mgru`, so "does this series have new
chapters?" was unanswerable without opening all of them. Here it is one
statement.

Wire-format findings, captured from live servers, are in [PROTOCOL.md](PROTOCOL.md).
Where that document and an assumption disagree, the observation wins.

## Environment

These are fixed and shape most of the design:

- **Lua 5.1 / LuaJIT.** No `//`, no bitwise operators, no `goto`. The device is
  the only place this code runs.
- **No test framework and no linter.** Verification is manual, in a running
  KOReader. The two scripts under `tools/` (see Development) are the automated
  guards, and they cover five failure modes between them.
- **Reuse KOReader's own machinery** rather than rebuilding it: `LuaSettings`,
  `DocSettings`, `DocumentRegistry`, the `lua-ljsqlite3` binding, and the
  built-in `plugins/opds.koplugin` for Atom parsing and the browser UI. That
  plugin is **read only** — wrapped at runtime, never edited.
- **Module names are global**, so everything lives under `meguru/`. Always
  `require("meguru/store")`, never `require("meguru.store")`: both resolve to the
  same file but occupy two different `package.loaded` keys.
- `require` of `opdsbrowser` / `opdsparser` must be **lazy, at the call site** —
  `pluginloader.lua` only adds plugin directories to `package.path` after the
  plugin itself has loaded.

## Layout

```
_meta.lua                 plugin metadata
main.lua                  plugin class: provider registration, menu dispatch, reader install

meguru/
  paths.lua               every path: database, markers
  fs.lua                  filesystem predicates and directory creation
  settings.lua            plugin-wide preferences in G_reader_settings
  store.lua               SQ3 connection (module-level), schema, migrations, transactions
  catalog.lua             every query and command against servers/series/items
  sources.lua             read-only view on settings/opds.lua (catalogs + credentials)
  net.lua                 HTTP GET, feed fetch + parse
  naming.lua              sanitizeComponent / deriveSeries / alias / glyph / identity digest
  marker.lua              marker read/write, naming, collision resolution
  pse.lua                 OPDS-PSE: link extraction, template -> URL, page fetch
  hook.lua                runtime wraps on OPDSBrowser (sniff, "Meguru this series")
  sync.lua                sync orchestration: prepare / walker / finish

  driver/
    base.lua              driver registry + pure shared helpers
    suwayomi.lua
    kavita.lua

  doc/
    document.lua          Document subclass: the reading engine
    image.lua             MuPDF decoding with a size cap
    defaults.lua          per-book seeding of kopt_* from plugin preferences

  ui/
    credential.lua        what a credential looks like in a URL: redact / restore
    open.lua              "Meguru this series": resume dialog, marker write, open,
                          plus the background series walk it starts
    syncjob.lua           cooperative sync with progress and Cancel, a silent mode, and the one-walk-per-series guard
    reader.lua            everything grafted onto a running ReaderUI
    menu.lua              the two menu surfaces
```

`tools/check.py` is a development aid, not part of the plugin.

Not yet written: `driver/komga.lua` (the driver contract accommodates it, but it
is out of v1 scope) and `driver/generic.lua` — the `kind = NULL` driver that can
only discover a series by title heuristic and cannot build a canonical
`catalogURL`, so a series sync is unavailable for it. Until `generic.lua` exists,
an unrecognised server is handled by the absence of a driver rather than by a
driver that returns nothing useful.

**Nothing is written to disk but markers and the database.** There is no page
cache and no cover cache: pages live in a small RAM LRU, and a cover is refetched
on every call. See the covers section below for what that costs the FileManager's
browsing.

The dependency graph is a DAG with no cycles, and it now has **no lazy edges**:
the two it used to need (`ui/library.lua` -> `ui/series.lua`, and `ui/menu.lua`
-> `ui/library.lua`) went with those views.

## The catalog

`meguru.sqlite3` in `DataStorage:getSettingsDir()`, WAL when
`Device:canUseWAL()` allows it, otherwise `TRUNCATE`. Migrations run off
`PRAGMA user_version`; `PRAGMA foreign_keys=ON` is set on every connection
because it is per-connection and defaults to off.

Three tables — `servers`, `series`, `items`, plus a small `meta` key/value. The
DDL is the `SCHEMA` literal in `meguru/store.lua`, commented column by column
where the reason for a column is not obvious from its name; it is not duplicated
here. The parts that matter to anyone touching this code:

**Never hand a SQL script to `db:exec`.** ljsqlite3's `conn:exec` splits its
argument on **every** `;` with no understanding of SQL, so a semicolon inside a
`--` comment cuts a statement in half and `sqlite3_prepare_v2` reports the
fragment as `incomplete input` — an error naming no file, no line and no
statement. That is not hypothetical: it is what killed the very first run of this
schema, because two column comments contained a semicolon. Multi-statement SQL
goes through `execScript` in `store.lua`, which skips over comments and quoted
literals; single statements go through `Store.exec` / `Store.prepare`.
`tools/scan_sql.py` gates the trap.

**`items.item_key` is the identity.** One pure function derives it, used by both
discovery and every sync. If those two paths ever diverge, each sync duplicates
the whole library. It is never derived from a whole stream URL: Kavita's
`stream_template` embeds the API key and Suwayomi's may carry `?token=`, so
hashing a URL would mean a key rotation duplicates every book.

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
that strip, every book opened would insert a second, never-reconcilable row for
its chapter alongside the one sync created.

**`items.ordinal` never degrades.** If the stored `ordinal_source` is `chapter`
or `volume` and a later sync can only offer `feed`, the old value stays.
Promotion only.

**`items.feed_index` is `NOT NULL` and the engine owns it.** Drivers never set
it, because only the engine knows what the whole of a series is, so
`Catalog.numberPositions` is the single place the rule lives: a sync numbers the
deduped walk (positions with no gaps), an open numbers the page it was opened
from (provisional, and overwritten by the next sync, which binds
`feed_index = excluded.feed_index` with no COALESCE for exactly that reason).
The single definition is load-bearing. While numbering lived in the sync's
`dedupe` alone, the open path — which calls a driver directly and so never
passes through `dedupe` — inserted a nil and died on the constraint, *after* the
series row had already been written, so the failure left a series with no items.

**A cover belongs to a book *and* to a series, the catalog holds both, and
nothing about either is cached.** `series.cover_url` is the series' artwork;
`items.cover_url` is the book's own, written only by a driver whose feed
publishes one. Kavita's series feed does, on every entry, so every volume gets
its own at sync time for free. Suwayomi's chapter list does not — its entries
carry only `rel=subsection` — and the chapter's own artwork lives solely in its
metadata feed, one request per chapter, which the sync rules forbid spending. So
`driver/suwayomi.lua` sets none and its chapters fall back to the series cover,
deliberately. Neither link goes into the marker: the marker carries only what
opens the stream offline.

`MeguruDocument:getCoverPageImage` resolves a book as **item → series → page 1 of
its stream**, so a NULL item cover is not a missing cover, it is the next best
one, and the last step is the reason a book is never cover-less. This is the
seam the FileManager's mosaic and "Book info" go through, and it is worth
knowing what it costs: **there is no cover cache of any kind**, so every call
fetches over HTTP. Browsing a folder of `.meguru` files is one request per book.
That is deliberate — KOReader's own `BookInfoManager` remembers the thumbnail it
extracts, so a cover already has somewhere else to live, and a store of our own
would have made meguru the only thing it writes to disk besides markers. The
last step goes through the page pipeline, so it also warms the same byte store a
page turn does, and page 1 is the one entry in it that can be for a page other
than the one on screen.

`series.new_since` is a **legacy column**: its only readers were the library
view's new-chapter counts, and that view is gone, so nothing reads or writes it
now. It is not dropped because dropping a column means rebuilding the table, a
real migration on the device, which is a worse price than an unused column.
`items.first_seen_at` is still written, because it is `NOT NULL`.

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

**A decoded page is 8bpp grayscale, and `sw_dithering` is the device's call, not
ours.** Both halves are one story. `Mupdf.openDocumentFromText` never sets
`doc.color`, and `decodeNativeMupdf` calls `setColorRendering(false)` besides, so
`page:draw_new` takes its `or BlitBuffer.TYPE_BB8` arm and the cached tiles are
BB8 — not the RGB24 an earlier comment here and in `meguru/doc/image` claimed.
That mattered because the false premise was the whole justification for forcing
`sw_dithering = true` and calling `ditherblitFrom` with no branch: a *converting*
blit is what dithering is for, and ours is a same-format copy. On a BB8
destination `ditherblitFrom` runs `dither_o8x8` (blitbuffer.c), which quantises a
full 8-bit page to **16 levels on a fixed 8x8 pattern** — a burnt-in dot grid and
four bits of tone gone, on every pixel of every page. The flag is now read from
`Screen.sw_dithering`, which is `framebuffer.lua`'s `setupDithering` answer: on
only where there is no hardware dither, off where the controller does it — the
same machinery `PicDocument` and `ReaderView:onDitheringUpdate` defer to. The
`if self.sw_dithering` branch in `drawPage`/`drawPageInverted` must stay; a tile
that is ever colour again reaches a grayscale screen through a real conversion,
and there the dither earns its keep.

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
nil, and why `renderPage`'s diagnostic prints it. A caught throw that silently
degrades to a slower path is survivable and invisible at the same time; the two
must not both be true, so the reason travels rather than being logged at a level
nobody is reading.

**`Image.renderRegion` rederives the coordinate space rather than taking it.**
Its `nx, ny, nw, nh` arrive in the space `self.dims` lives in, which for an
oversized page is the *capped* size — smaller than MuPDF's own page. It recomputes
the factor between them with the same `cappedDim` the decode used, so the two
cannot drift: were they to, the crop would land on a different part of the page,
silently and by however much the cap had moved.

**Reading progress is not mirrored into the catalog.** It is read lazily, per
book, from the sidecar: `DocSettings:findSidecarFile` then `openSettingsFile`,
reading `percent_finished`. This works only because `items.marker_path` exists —
a path pointing at a missing file means "not opened", with no fallback to a name
search. (`DocSettings:hasSidecarFile` is the cheaper, parse-free variant of the
same test and is what the resume path below uses, where nothing needs reading.)
The per-series sweep that used to walk these sidecars to annotate a series list
went with that list; nothing reads progress in bulk any more.

**The server's own progress is a separate thing, and it seeds a first open.**
`items.last_read` is the page the *server* says the reader stopped on. It is not
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
the distinction is load-bearing: `Catalog.upsertItem` writes progress with
`COALESCE(excluded.last_read, items.last_read)`, so a nil leaves whatever was
stored — which meant a volume marked unread on the server stayed the
furthest-read one *here* for good, and the resume dialog went on offering to
continue from it. Nil now means only "this feed does not publish progress", which
correctly refuses to overwrite a better feed's record.

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
to `Catalog.resumeTarget`, whose knowledge ends at the last sync, so the same tap
gave two different chapters a moment apart: the first before the background walk
landed (the last *row* the catalogue had, not the last chapter), the second after.

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
answers that request with a **non-200**, which `Sync.walk` reports as `"http"`
and the resume fetch as no feed at all. Handling only the empty case left the
canonical feed unasked exactly where it was needed, so the answer came from
`Catalog.resumeTarget` — the last *row* the catalogue knew rather than the last
chapter — and the same tap gave two different chapters a moment apart, the first
before the background walk landed and the second after. The canonical feed is now
always asked when the filtered one yields nothing, by either route.

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

**And `seriesItems` retries with the URL a sync uses** when the filtered walk
yields nothing: no filter, and `Catalog.serverLang` rather than the browser's
language. The filtered feed is an optimisation and this row cannot stand on it
alone — the fallback above answers from the newest hundred chapters, which is how
a row that promises "the first unread" came to open chapter 78 for a reader whose
series starts at chapter 1. The retry fails only if the sync would fail too,
which is the whole test of whether the row has a real answer.

`Catalog.resumeTarget` answers a **different question** and keeps its own rule
("the last row anything was read into"), deliberately. It is the degraded answer,
reached only when the fresh read fails, and for Suwayomi it *cannot* do better:
the read flag is not stored, and `page_count` is NULL until a stream is resolved,
so a "first unfinished" predicate there would be true of every row and the
fallback would confidently answer "chapter 1" after every failed fetch. Do not
"fix" it to match — the difference is the point, and it is visible in the log as
`resume point from the catalog, not the feed ( … )`.

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

The same ordering feeds `Catalog.numberPositions` there. Numbering the page as
it arrived wrote a `feed_index` that ran backwards on the browser path, and
`Catalog.orderedItems` sorts on exactly that — so `resumeTarget` and `neighbors`
read a reversed position until the next sync overwrote it.

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

**The catalog is the wrong place to ask, and the feed is the right one.** It has
to be said plainly because the obvious implementation is wrong in a way that only
shows on a real library: `items.last_read` is a snapshot from the last *sync*,
and the only thing that refreshes a row in between is opening that very chapter —
`registerBook` re-upserts the item from whatever feed the browser had fetched. So
the catalog is fresh exactly where the reader has clicked and stale everywhere
else, and the furthest item *known* is routinely not the furthest item *read*.
Reading to chapter 7 in a browser, then opening volume 3, would offer volume 5.
`Open.freshResumeTarget` therefore asks the feed `OPDSBrowser` has *just* fetched
to draw the list — free, and current — and `Catalog.resumeTarget` is only the
fallback for when there is no such feed. The two are not interchangeable.

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
`Net.RESUME_*` (4s/8s, not the 10s/30s a sync walk gets), with the catalog as the
fallback on any failure. It must pass `Catalog.serverLang`, because Suwayomi
selects between translations by `?lang=` and a defaulted language would report
the progress of a translation the reader is not reading.

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

**The database degrades gracefully.** A marker needs nothing from it to open and
read — `template` and `count` are in the file. Without the database, only
next/previous and the new-chapter counts are unavailable. That is why the
database can live in `settings/` and be restored from backup independently of the
books.

**"No database" is not "no configuration", and the difference is one file.** A
marker's `template` is stored with its credential removed and restored at load
from `settings/opds.lua` — so a Kavita marker reads with the database deleted and
cannot fetch its pages with the *OPDS catalog* deleted. The failure is loud and
self-describing (a 404 whose path says `<redacted>`, plus a warning naming the
missing catalog), and it is narrower than it sounds: with the database present,
`MeguruDocument:init` takes the template from the catalog row and the marker's
redacted copy is never consulted. See `meguru/credential`.

## The marker

Extension `.meguru`, provider key `"meguru"`. Serialised with `LuaSettings` as
`return { meguru = {...} }`, matching the `DocSettings` sidecar beside it.

```
server_name, series_remote_id, item_key, item_id,
title, template, count, last_read
```

`server_name` is the **catalog title**, which is the key credentials are looked
up by in `settings/opds.lua`. No secret is stored in the marker — `template` on
disk has any credential-bearing path segment replaced by `<redacted>`, and
`Marker.load` restores it from that catalog. What was in the file before this is
covered under Security notes, including the markers it does not reach backwards
to.

`item_id` is a *hint*, not authority. A rowid is reassigned when the database is
rebuilt, and a rebuilt database can give an old `item_id` to a **different
chapter** — which would open the wrong book with no error. Every read validates
it against `item_key` first and falls back to a natural-key lookup on mismatch.

`resolveStream` runs again on every open when the catalog is available, with the
stored `template` as the offline fallback. For Suwayomi this is correctness
rather than optimisation: the stored template carries a chapter number that may
have changed.

## Sync

```
pages, complete = walk(series, cap = MAX_PAGES)     -- HTTP, NO transaction
if not complete:                record sync_error; zero writes; return
if #pages < previous item_count * 0.5:
                                record sync_error; return
BEGIN IMMEDIATE
  upsert each item by (series_id, item_key), last_seen_at = now, removed_at = NULL
  tombstone where last_seen_at < sync_started
  update series counters
COMMIT
```

The rules that make that safe, each of which has a reason:

- **The transaction never spans the network.** A walk on a Kindle is tens of
  seconds. `BEGIN`/`COMMIT` wraps only the write loop.
- **The sweep runs on `last_seen_at < sync_started`, not on absence from the
  result.** That is what makes a partial walk harmless: nothing advances a
  generation, so nothing is tombstoned.
- **`complete` is conservative** — false on any non-200, an empty body, hitting
  `MAX_PAGES`, a repeated `rel=next`, or a parse error. The real failure mode is
  not a dropped connection but a 200 with a truncated body from an expired
  session, and that is what the 50% gate catches.
- **Pagination only via `rel=next`**, never by constructing `?page=N`.
- **One transaction per series**, never one for the whole library.
- **One module-level connection**, not open/close per operation.
- **Never `INSERT OR REPLACE`** — that is delete+insert and changes the rowid.
  Upserts use `INSERT ... ON CONFLICT(series_id, item_key) DO UPDATE`.
- **Sync never fetches per item.** A lazy item keeps `template = NULL` until it
  is first opened; otherwise 500 chapters means 500 HTTP requests per sync.

Sync is cooperative, not blocking. `socket.http` is synchronous and there are no
threads, so a 25-page walk would freeze the e-ink display for 25 seconds. The
walker yields one slice per `UIManager:nextTick`, which is why `Sync.run` is
decomposed into `prepare` / `walker` / `finish` with `run` rebuilt from them.
A **cancelled** walk is deliberately exempt from `recordSyncFailure`'s backoff —
otherwise a few impatient taps push the next automatic attempt out by most of a
day.

Sync is triggered four ways, all gated on `NetworkMgr:isConnected()`:

- **in the background, right after either OPDS add** — `ui/open.lua`'s
  `startBackgroundSync`, called from `openAsBook` once the book has been handed
  to the reader, and from `openFirstUnread` after the row's own open.
  `registerBook` writes **one** item on purpose (a walk must never sit between a
  tap and a book opening), and with one item there is no *next*: the reader menu
  offers "Find the next chapter" instead of the chapter, the "auto-open next at
  the end" toggle is not even built — it is gated on there being somewhere to go
  — and finishing the volume falls back to KOReader's own end-of-book dialog.
  All three are downstream of the same single row, so this is where it is
  repaired. Gated by `Sync.plan` with `settings.sync_ttl_seconds`, and **never
  `force`**: the backoff half of that gate is what stops a server whose walk just
  failed from being walked again on the next book added from it.
  Silent — no dialog, no Cancel, no repaint — which makes it uncancellable, and
  bounded instead by `timeout = "resume"`. Killing KOReader stops it safely:
  nothing is written until the last page.

  **Both OPDS entry points start it, and nothing else in the UI does.**
  `openFirstUnread` pays for two walks over one feed on its first tap per TTL —
  its own bounded read to answer "which chapter", then this one to fill the
  series — and that was weighed against leaving it out, which left the row's
  reader with a one-item series and no way out but "Find the next chapter". The
  trigger is deliberately **not** in `openCatalogItem`, the funnel the file
  manager and History reach too: they have no feed in hand to walk.
- an explicit manual action — the `⟳ Check for new chapters` row, which lived in
  the series view and went with it. What remains of this trigger is the reader's
  own-menu request below, which is the same call.
- **on demand, from the reader, when a neighbour the catalog does not have is
  asked for** — `Reader.openNeighbor`. The reader menu grows a "Find the next
  chapter" row when there is no neighbour, and the sync it starts is
  **attempted once**: a successful walk that still turns up no neighbour is an
  answer, and re-walking the same feed would not change it.
  The open that follows the walk — and the direct one when the neighbour is
  already known — goes through `Open.openItemSilently`, not `openCatalogItem`:
  the reader named a chapter, so there is nothing left to ask. See the
  resume-dialog section above.

**The reader menu is built once per document, and the Meguru rows are derived
from the catalog** — so a walk that lands after that build changes nothing on
screen. `ReaderMenu:onShowMenu` calls `setUpdateItemTable` only while
`tab_item_table` is nil, and nothing clears it but a new document or a keyboard
reconnection: closing and reopening ⋮ does **not** rebuild it. Our neighbour rows
come from `Catalog.neighbors`, which is exactly what the background walk changes,
so `Open.refreshReaderMenu` rebuilds the table when a walk succeeds. It reaches
the instance through `ReaderUI.instance` rather than through `ui/reader.lua`,
which requires `ui/open.lua` — requiring it back would be a cycle, and
`registerModule("menu", …)` is what makes the instance reachable anyway.

The same staleness applies to every other way the catalog can change under an
open book (a background walk landing), and it is worth knowing for any future row
built from catalog state: the menu's *structure* is decided once, so a row that
should appear later will not.

**One guard, in `SyncJob`, keyed on the series id** — not one per caller. It
refuses (`"busy"`) rather than joining, because joining would fire the joiner's
completion callback, which on the reader's path opens a document. It is not
redundant with `Sync.plan`: `synced_at` is written when a walk *ends*, so a
second request arriving mid-walk finds the series looking exactly as stale as
before. It lives here because this is the only module both UI walkers pass
through — `ui/reader.lua` used to keep its own scalar and that was worse in both
directions, refusing a request for one series because a walk was running for
another, and blind to the walks the browser path starts.

**A walk that hits `MAX_PAGES` writes nothing at all**, which is why a
background walk may not be made cheap by capping it: `complete = false` means
zero writes, so a short walk would repair nothing. It must run to the end or not
start.

**The reader's "Find the next chapter" row is the only manual trigger left.** The
series view's `⟳ Check for new chapters` row offered the same thing and went with
the view. Note that it called `SyncJob.run` directly, bypassing `Sync.plan`'s TTL
— which is why it could repair a series whose `synced_at` was still fresh. That
escape hatch is gone with it, so the reader's row is now the only way to force a
walk.

**Never in the plugin's `init()`**: at that point there is neither connectivity
nor a UI.

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

Driver selection is by `servers.kind`, decided in this order: the session's
author sniff, the kind the server was last recorded with, and — only when both
are silent — `Base.kindFor`, which asks each driver's `discover` whether the
entry is its own and takes the answer only when exactly one driver claims it.

That last step is not decoration. A server whose feeds sign themselves with an
`<author>` no driver recognises used to be a soft failure, because the old plugin
only *stored* `server_kind`; here the driver is what knows a series' canonical
feed, so an unknown kind means every book off that server is uncatalogued — no
next chapter at all, forever. `kind_source` records which of the three decided
(`author` / `inferred`).

**There was a fourth, strongest source and it was deliberately removed: a manual
override set from the server-administration screen.** That screen went with the
Library/Servers views, so `kind_source = 'manual'` now has no writer, and the two
`CASE ... WHEN servers.kind_source = 'manual'` arms that used to protect it are
gone from `UPSERT_SERVER`. The cost is real and was accepted knowingly: a
mis-sniffed server can no longer be corrected from the UI at all, only by clearing
its row in `meguru.sqlite3` and letting a book re-register it. The reason the
override existed is unchanged and worth restating — a wrong kind picks the wrong
driver, and every later sync then re-keys the series against feeds that do not
describe it — which is why the inference still refuses an ambiguous entry. If the
override is ever wanted back, this is the paragraph that says what removing it
cost.

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
- **A hint alone does not put a row at the top of its page.** It is appended to
  the end of that page's row list — for `tools`, below `more_tools`, i.e. below
  Developer options. Landing above them means naming the id in that page's order
  list, which is what `showUnderTools` does for both surfaces. That is also the
  mechanism core ships (`ui/plugin/insert_menu.lua`), though it targets
  `more_tools`, the position being avoided here. Both edits are safe: an order id
  with no matching item is skipped by the sorter, and a duplicate insert is inert.
- **`separator` and `checked_func` are `TouchMenu`-only; `mandatory` is
  plain-`Menu`-only.** Both menus Meguru registers are `TouchMenu`s on a touch
  device — the reader ⋮ menu and the FileManager's, which falls back to the plain
  widget only on a keyboard-only build (`filemanagermenu.lua:1043`) — so both
  fields are usable in these rows. `text_func` renders on either
  (`TouchMenuItem` goes through `Menu.getMenuText`), which is why the destination
  rows carry their state in the text rather than in a `mandatory` value slot.
  (Meguru used to have three plain-`Menu` surfaces of its own — library, series,
  servers — and with them went the reason `separator` was ever unsafe here.)
- **The FileManager has one `Meguru` submenu, not flat rows**, and it carries
  nothing but the two destination rows (save folder, per-catalog subfolder) —
  the same two the reader's carries. Both surfaces use the key `meguru`, which is
  safe because the two `menu_items` tables are per-surface and never shared, and
  `Meguru:addToMainMenu` dispatches on whether a document is open — so only one is
  ever written. A saved menu order in `settings/` then means the same thing on
  both.

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
python tools/scan_sql.py    # semicolons inside SQL comments
```

**A Python mirror of Lua logic models values, not Lua's evaluation rules, and the
difference has shipped a crash.** `Meguru/credential.lua`'s `restoreTemplate`
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
for one. It runs five passes:

1. **Block balance** — `function`/`if`/`for`/`while`/`do` against `end`/`until`,
   over comment- and string-stripped source.
2. **Cross-module member references** — every `Module.member` where `Module` came
   from a `require("meguru/...")` binding is checked against the members that
   module actually defines.
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
5. **The item upsert stays in step** — `Catalog.upsertItems` is the one statement
   every sync and every open writes through, and it is spread over four places
   that must agree: the `INSERT` column list, the `?` placeholders, the
   positional `stmt:bind(...)`, and the `DO UPDATE SET` list. Lua checks none of
   them, and a mismatch is not a load-time error — it is `NOT NULL constraint
   failed` or `no such column` on the first sync, on the device. Scope is one
   statement, named on purpose: a general "every bind matches its SQL" pass would
   have to pair each `prepare` with its `bind` across files, which is a much
   larger and much more false-positive-prone job than the failure this prevents.

None of the five is a parser. They are the failure modes that have actually
bitten this codebase, and that a reader cannot reliably catch by eye: a name or
member that is fine at load time and only explodes when a branch runs, on the
device, in the reader's hands. **The checker passes vacuously if its stripping or
its patterns are wrong**, so each pass was self-tested by injecting the real
failure and confirming the checker reports it — including at the right line. Do
the same before trusting a green run; four of the five passes were written
wrongly the first time and passed on the very bug they existed to catch — pass 4
included, whose first draft bound a name anywhere in the file and so found
nothing.

`scan_sql.py` is narrow on purpose: it only looks for a `;` inside a SQL comment
in a Lua string. That one shape is a hard crash with an error message that names
nothing — see the `db:exec` rule above.

### Verifying on the device

No automated tests, so verification is a running KOReader. Run with `-d` or read
`crash.log`, filtering on `Meguru:`.

**A catalog written by a previous build is not a valid test surface.** This is
worth stating because it cost an afternoon: `Catalog.orderedItems` sorts on
`feed_index`, and `feed_index` is derived by rules this codebase has changed more
than once (reading order rather than feed order; a provisional position written
by an open rather than by a walk). Rows written before such a change keep
positions computed by the superseded rule, so `Catalog.neighbors` answers from
them and a series can look like it has no next chapter when its feed plainly
contains one — and `synced_at` from an earlier successful walk then blocks the
repairing walk for `sync_ttl_seconds`. Nothing on the device distinguishes that
from a live bug. So: **wipe `meguru.sqlite3` and the marker folders whenever a
change touches ordering**, and re-test on that clean state before believing any
symptom. The repair path for a reader who does get there is one tap —
`⟳ Check for new chapters` calls `SyncJob.run` directly and so bypasses
`Sync.plan`'s TTL — but it is not a substitute for a valid test.

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

1. **Schema.** `sqlite3 meguru.sqlite3 .schema` after the first start;
   `user_version` present; no SQ3 errors in the log. A restart does not duplicate
   rows.
2. **Database with no network.** With an empty catalog, open the FileManager's
   `Tools → Meguru` submenu — no crash, and it holds the two destination rows and
   nothing else.
3. **Suwayomi sync.** One series: item count in the database equals the chapter
   count in the service; the log shows the walk via `rel=next` across all pages
   and **one** `BEGIN`/`COMMIT`. Sync again: `item_count` unchanged and
   `SELECT COUNT(*)` unchanged (zero duplicates — this is the `item_key`
   identity test).
4. **Truncation resistance.** Force a failure mid-walk (drop the network, or
   point a page at a bad URL) — the database is unchanged, `sync_error` is
   recorded, zero tombstones. This is the `complete` gate plus the generation
   sweep.
5. **New chapters are gone as a feature.** Nothing counts or displays them any
   more — `series.new_since` has no reader and no writer. Confirm instead that a
   sync that adds a chapter simply raises `SELECT COUNT(*) FROM items`, and that
   nothing in the log mentions a count.
6. **A marker opens without the database.** Open a book, rename
   `meguru.sqlite3`, reopen the same marker from History — the book must open and
   read, with no next/previous. Restore the database — next/previous returns.
7. **The marker does not lie.** Hand-edit `item_id` in a marker to another item's
   rowid — the open must land on the **correct** chapter via the natural key, not
   the substituted one.
8. **Page fetching.** One log line per page with a rising `pageNumber` plus
   prefetch, and **no** fetch of a whole archive. `cache/meguru/` does not grow
   while reading — nothing is written there at all any more. Then turn back one
   page and force a repaint (open/close ⋮, toggle a crop setting): **no fetch**,
   because the page's decoded buffer is still live and the bytes are not needed
   for it. Turn back past the four-entry store and a fetch *is* expected — that
   is the trade this makes, not a regression. Then close the book and reopen it:
   the page it reopens on is fetched, because the store died with the document.
9. **Engine port.** On the same title as the old plugin: crop, page-number crop,
   panel zoom, night-mode invert, wide-page rotation, local `.cbz` via "Open
   with…" — behaviour identical to the old plugin.
10. **Concurrency.** Two windows (FileManager + ReaderUI): the provider registers
    once, the same series does not sync twice, the UI never freezes and Cancel
    works during a walk.
11. **Two books, one title.** Open a "Chapter 1" from two different Suwayomi
    series (or two Kavita volumes both titled "Volume 1"). Each renders its own
    pages — the failure this guards against was one book being served another's
    *bytes*, which is now impossible by construction, since the store is
    per-document and keyed by page number. What is still worth checking is that
    neither book's marker was adopted by the other: each opens the chapter it
    names, and both markers exist in their own folders.
12. **Nothing on disk but markers and the database.** Read several pages, then
    confirm `cache/meguru/` is empty (or absent) — including after browsing a
    folder of `.meguru` files in the mosaic, which *does* fetch each cover over
    HTTP and must still write nothing. In that same browse, the covers must
    actually appear: the book's own where its feed published one (a Kavita
    volume), else the series', else page 1 of its stream — and at most one fetch
    per book, since `BookInfoManager` remembers the thumbnail afterwards. With
    the wifi off, covers already extracted stay on screen and nothing crashes.
    The two subdirectories a previous version wrote (`pages`, `covers`) are not
    cleaned by anything: delete them by hand once and confirm they stay gone.
13. **The dialog asks once.** Tap a volume in a series feed, answer the dialog:
    the book opens and **no second dialog appears**. Then close it and reopen the
    same book from History — **the dialog comes back**, which is the half of the
    test that catches a guard that suppresses too much. Reopen a *different* book
    and confirm the earlier one's record is not swallowing it.
14. **The jump button does not re-ask.** With the server further along in another
    volume, tap its `▶` button: that volume opens with no dialog, and the page in
    the label is the page it lands on. Tap a jump onto a volume already read here:
    the label names no page, and the book resumes where KOReader left it.
15. **The silent opens stay silent.** ⋮ → Meguru → "Find the next chapter" on an
    unsynced series: the walk runs, the chapter opens, no dialog. Finish a volume
    with `auto-next at the end` on: the next volume opens with no dialog.
16. **The menu lands where it should.** FileManager → Tools → `Meguru` at the top
    of the page, holding `Save books in: …` and the subfolder toggle and nothing
    else; the reader's ⋮ → Tools → `Meguru` likewise, plus its navigation rows.
    Nothing anywhere offers a cover, a cache to clear, a library or a server list.
    The folder row opens the picker and shows the new path afterwards; the
    toggle's checkbox survives a restart; a new book lands in
    `<base>/<catalog>/<series>` when it is on. With a PDF open there is no Meguru
    row and nothing logs `menu id not found`.
17. **No destination dialog anywhere.** `▶ Meguru this series` with the wifi off
    still prompts for a connection and then opens, straight into the resume
    dialog. Neither it nor the top-of-feed row ever asks for a folder.
18. **A dismissed dialog leaves nothing at all.** List the marker folder first.
    Tap a volume in a series feed, then tap *past* the resume dialog: no
    `.meguru` appears, **no series folder appears**, and nothing new appears in
    the library or in History. Answer the dialog on a second try and both the
    folder and the marker do appear, in the place the first tap would have used.
    Do this on a series that has no markers yet — an existing series already has
    its folder, which is why the folder leak was easy to miss.
19. **The two entry points agree on the server's position.** On Suwayomi, read
    into chapter 40 of a 50-chapter series, then open an early chapter (say 3)
    from the OPDS browser: the `▶` button must name chapter 40, not chapter 1.
    Open that same early chapter's marker from History and the `▶` button must
    name the same chapter 40. Before this, the browser answered chapter 1 and the
    file answered chapter 40 for the same series, because one feed is
    `number_desc` and the other `number_asc`.
20. **An OPDS add populates its series.** Add a volume via `▶ Meguru this series`
    from a series whose catalog row is empty, and answer the dialog. The book
    opens; do nothing else. The log must show `background sync started for …`
    then `Meguru: synced … - N items in M page(s)` with `N` equal to the real
    chapter count, and `SELECT item_count, synced_at FROM series …` must agree.
    **No dialog may appear at any point** — that is the silent mode, and it also
    means an uncancellable walk, so turn several pages while it runs and confirm
    they are prompt. Then: ⋮ → Meguru shows `Open next in series: <title>` and the
    `Auto-open next at the end` toggle, and finishing the volume opens the next
    one. The same series added twice inside `sync_ttl_seconds` must log
    `not due ( fresh )` and **not** walk again.
21. **A refused background walk is not a broken series.** Point one at a feed
    that fails: the log shows the start, then `did not complete - <reason>`, and
    `sync_fail_count` becomes 1; the next add from that server logs
    `not due ( backoff )`. With the wifi off, the add logs `no connection` and
    `sync_fail_count` stays 0 — a dropped connection must never be recorded as a
    server's fault. **Every gate on the trigger logs its decision**, and the
    refusals are the point: `Sync.prepare`'s three — an unknown kind, an
    unconfigured server, no catalog feed — write only to `series.sync_error`
    and return nil, so without `SyncJob.run`'s own line a background walk that
    could not start would leave no trace anywhere at all. Reading a log for a
    walk, expect exactly one of: `background sync started for …`,
    `not due ( fresh|backoff )`, `no connection - not syncing …`, `nothing to
    sync in the background`, `cannot start ( <reason> )`, or `the background
    sync could not be started: <error>`. Opening a book from **file manager or
    History** must log **no** start line: the trigger hangs on the browser's own
    two entries, not on the shared open path. Tapping the `▶ Meguru this series`
    row **above a series list** must log one, and its reader must end up with the
    neighbour rows and the auto-open toggle like the dialog button's does.
22. **The `▶` chapter is the first the server flags unread, and progress is not
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

## Known open items

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
  stream template, and it is replaced by `<redacted>` on the way to disk and put
  back by `Marker.load` from `settings/opds.lua`. One member of the pair on each
  side — see `meguru/credential`.
- **A marker written before that pair existed still carries the key, forever.**
  Markers are not scrubbed in place: rewriting a book file the reader did not ask
  to have rewritten is worse than a stale copy in a folder they control. So
  "markers hold no secret" is true of new ones; delete and re-add the old books
  if it matters. Saying this plainly matters more than the fact, because the
  opposite reads as settled.
- Credentials are resolved only when a page actually has to be fetched.
- `servers.root_url` and the derived `catalogURL` are **redacted** — no API key,
  no token.
- **`crash.log` is a file too, and `Net.redactUrl` is the only thing a log line
  may print a URL through.** It strips the credential-bearing path segment, so
  the four failure lines in `Net.get` no longer write Kavita's key out on every
  404. The query is reduced to its byte count and `user:pass@host` never reaches
  the output; both are load-bearing and neither should be "simplified".
- Kavita's stream `template` in `items.template` unavoidably embeds the API key;
  that is what opens the book. Bounded to one column in `settings/meguru.sqlite3`,
  the user's private directory — and to `settings/opds.lua`, where the key
  already lives.
- `settings/opds.lua` is read **only**, never written.
