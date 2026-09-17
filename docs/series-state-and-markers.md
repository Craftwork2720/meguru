# Series state, and the marker

The marker's fields, the identity rules behind `item_key`, and what a marker does and does not store.

Part of the design record; [CLAUDE.md](../CLAUDE.md) is the map.

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

