# What the servers actually emit

Observed wire format of the three v1 servers, captured against live instances by
walking the real feeds: **2776 Kavita series / 21217 feed entries** and the full
Suwayomi library (2026-09-10), and Komga (2026-09-12, cross-checked against its
source). **Kavita was re-walked on 2026-09-12 — all 3473 series of a larger
library** — and the sections that changed carry that date. This is the evidence
the drivers are written against — where it disagrees with an assumption, the
observation wins.

Credentials are never written here. Kavita's API key is shown as `<KEY>`; it is
a path segment (`/api/opds/<KEY>/...`) and appears inside every stream URL.
**Komga has no such segment** — it authenticates with HTTP Basic — so its URLs
here are exactly what is on the wire.

`meguru` therefore stores a stream template with that segment replaced by
`<redacted>`, and restores it at load from the catalog root in
`settings/opds.lua`. So `<KEY>` on the wire, `<redacted>` in a marker file and
`<redacted>` in `crash.log` are the same position in the same URL, seen at three
different points. See `meguru/credential`.

## Kavita

Navigation: `root → /libraries → /libraries/{id} → /series/{id}`.

| Feed | Paginates | Notes |
|---|---|---|
| `/` (root) | no | sections: `on-deck`, `recently-updated`, `recently-added`, `reading-list`, `want-to-read`, `libraries`, `collections`. `smart-filters` appears on some builds and not others — **read the root, never a fixed list** |
| `/libraries` | no | the libraries themselves (5 here), `entry.id` = library id |
| `/libraries/{id}` | **yes**, 20/page, `rel=next` = `?pageNumber=2` | the canonical series list |
| `/series/{id}` | **no** (0/3473 checked) | the whole series in one response |

### The canonical series list is the only authoritative one

`on-deck`, `recently-added` etc. list **series**, not books — each entry is a
`rel=subsection` link to `/series/{id}` with no stream at all. So they are safe
to browse, but a sync must never be built from them: they are truncated.

### Series feed entries are one book each

A series feed entry is a *chapter row in Kavita's model*, which is either a
collected volume or a loose chapter. Either way it carries its own
`chapterId` and its own stream, so **entry ↔ stream is 1:1**:

```
entry.id   296595                       <- opaque; NOT the chapterId
title      '⭘ Are You Okay ... - Chapter 1'
updated    2026-09-10T15:28:22
summary    'File Type: x-cbz - 520.51 MB'
extent     '520.51 MB'    (dcterms)     <- decoration; nothing reads these
format     'Archive'      (dcterms)
content    'application/x-cbz'

link rel=http://opds-spec.org/image/thumbnail
     href /api/image/chapter-cover?chapterId=176915&apiKey=<KEY>
link rel=http://opds-spec.org/image
     href /api/image/chapter-cover?chapterId=176915&apiKey=<KEY>
link rel=http://opds-spec.org/acquisition/open-access
     href /api/opds/<KEY>/series/…/volume/114712/chapter/176915/download/<name>.cbz
     p5:count=207 type=application/x-cbz     <- yes, the count is on this one too
link rel=http://vaemendis.net/opds-pse/stream
     href /api/opds/<KEY>/image?libraryId=39&seriesId=17086&volumeId=114712
                              &chapterId=176915&pageNumber={pageNumber}
     p5:count=207 type=image/jpeg
```

Three different numbers, none interchangeable:

| | value | role |
|---|---|---|
| `entry.id` | `296595` | opaque; do not use |
| `volumeId` | `114712` | **not unique** — 132/2776 series put many entries on one volume (re-checked 2026-09-12: 6 of 127) |
| `chapterId` | `176915` | unique per real chapter — **this is `item_key`** |

### The API key is in the path, and once more in a query parameter

The stream and every feed carry the key as a path segment
(`/api/opds/<KEY>/…`). **The artwork does not** — it carries it as `apiKey=`:

```
rel=http://opds-spec.org/image  (book)
  /api/image/chapter-cover?chapterId=175451&apiKey=<KEY>
rel=http://opds-spec.org/image  (feed level, i.e. the series cover)
  /api/image/series-cover?seriesId=16872&apiKey=<KEY>
```

Neither contains `/opds/` anywhere, which matters because
`Credential.redactTemplate` used to look only there — so a marker written before
2026-09-12 stored both cover URLs with the key in plain text. It has a second
rule for the `apiKey` parameter now.

Two things this settles for anyone tempted to "just drop the parameter":

- **`apiKey` is not removable.** `/api/image/series-cover?seriesId=…` without it
  answers **401 even with HTTP Basic credentials supplied** — the query parameter
  is the whole authentication for that endpoint. The key has to be redacted and
  restored, not deleted.
- **`crash.log` was never the leak.** `Net.redactUrl` reduces a query to its byte
  count (`…?97 bytes of query`), so no log line ever printed it.

### `seriesId` is recoverable from the stream URL

The stream href carries `seriesId`, `volumeId` and `chapterId` as query
parameters. The plan assumed Kavita's `seriesId` appears *only* in the browse
path and had to be threaded through as `ctx.paths`; it does not. `discover()`
reads it straight off the stream link, so a book opened from any feed — including
an aggregate — resolves to its series without extra context.

### Byte-identical duplicate entries

151/2776 series emit each chapter **twice**: same `entry.id`, same `title`, same
`updated`, same `chapterId`, same stream, back to back — a rate the 2026-09-12
re-check confirms but does not reproduce exactly (2 series of a 127-series
sample). Not an alias and not distinguishable by any field.

Nothing de-duplicates these in code any more. The catalog collapsed them with
`UNIQUE(series_id, item_key)` at insert, and there is no catalog; `Feed.collect`
drops a repeated `item_key` per walk instead, which is where the reader's own
arithmetic needs it.

### The feed is already in reading order

**Measured, not assumed:** across all 3473 series of a live library, 0 feeds are
out of ascending order, so a walk's own order is the reading order and nothing
needs to be derived.

This is what `Feed.ordered` gets wrong if it is left to guess. Kavita feeds
routinely **mix granularity** — 116 series (3,3 %) put `Volume N` and `Chapter N`
in one feed, and `Moimon` is the clean case:

```
Volume 1, Volume 2, Volume 3, Chapter 1, Chapter 2, Chapter 3   <- feed order
1, 1, 2, 2, 3, 3                                                 <- numbered by title
```

25 series change order that way. Titles are also not always numberable at all, and
those are parked at the **end**: `Chapter 128x1` yields nothing, and so does a
volume whose name is followed by nothing but release groups
(`The Liminal Zone (2022) (Digital) (1r0n)`). `Volume 22-24` does *not* — it
yields 22, because an omnibus indexes from its first number.
`driver/kavita.lua` therefore leaves
`orderFromTitles` unset, and only Suwayomi sets it, because only Suwayomi
publishes its feed newest-first.

### Alias entries

Kavita emits, beside the entry for the volume last read, a second entry whose
title is prefixed `Continue Reading from: ` (and, on the wire, often two spaces
after the colon). It carries the **same stream** as the real entry, so the two
describe one book. `Naming.stripAliasPrefix` drops the prefix for naming and
series derivation so both map to one marker; the stream is what makes them the
same file, not the title.

**It is the first entry of the feed, it is behind a setting, and it carries no
progress.** Captured 2026-09-14 from `/api/opds/<KEY>/series/14849` with *Include
Continue From Entry* on (Kavita **User Settings → OPDS**; the tooltip reads
"Insert a *Continue From X* entry in OPDS fields to avoid finding your last
reading point"). Two adjacent entries, cut to the attributes that matter:

```
entry 1  <title>Continue Reading from: ◕ Asobi Asobase - Volume 6</title>
         rel=stream href=…/image?libraryId=39&seriesId=14849&volumeId=102272
                                 &chapterId=161389&pageNumber={pageNumber}
                       p5:count="156"        <- and no p5:lastRead at all

entry 2  <title>⬤ Asobi Asobase - Volume 1</title>
         rel=stream href=…&volumeId=102267&chapterId=161384&pageNumber={pageNumber}
                       p5:count="162" p5:lastRead="162"
                       p5:lastReadDate="2026-09-14T05:49:44"
```

**That capture is one reader's configuration, and these switches are per user.**
All three sit together in User Settings → OPDS, each is set independently, and each
changes the shape of the *same* series feed as that reader receives it:

| switch | what it changes on the wire |
|---|---|
| `Embed Progress Indicator` | the status glyph at the head of `<title>` (`⬤` `◕` `◑` …) |
| `Embed Progress Indicator in Title` | the same glyph, in its other variant |
| `Include Continue From Entry` | whether the entry above exists at all |

So a **feed describes the reader's settings, not the server** — one series answers
differently for two accounts on the same instance, and a reader who turns the glyph
off gets the entries above with no `◕` in them at all. Nothing in Meguru may rest
on a glyph being there or on the alias being present; the identifier and the page
are the two facts every one of those shapes states.

Three things follow, and the third is the one that bit:

- **It duplicates the entry it points at.** Kavita builds it with
  `CreateChapterFeedEntry(series, continueVolume, continueChapter, …)` — see
  `Kavita.Services/OpdsService.cs`, `GetSeriesDetail` → `CreateContinueReadingEntryAsync`,
  which overwrites **only `Title`**. So `chapterId`, stream href and `p5:count` are
  that chapter's own, and the reader finds the same book twice under one key.
- **It sits at the top.** `GetSeriesDetail` inserts it before the loop that
  appends the chapters, so it precedes every real entry rather than sitting beside
  the one it duplicates.
- **It carries no `p5:lastRead`**, while the entry it duplicates carries the
  reader's page. The `◕` in its title is Kavita's own glyph for *partially read*
  and is inherited from the real entry's title, so the two describe the same
  progress and only one of them states it. `CreateChapterFeedEntry` sets
  `link.LastRead = chapter.PagesRead` conditionally, and the chapter the continue
  point resolves to does not carry it.

So an entry with the alias prefix is **not a book**: it is the same book, without
the position, in front of the copy that has it. Anything that collapses a feed by
`item_key` must therefore not simply keep the first — see `Feed.dedupe`, and the
`dropped duplicate feed entry` line it feeds.

The prefix is the *translated* string (`localizationService.TranslateAsync`, key
`opds-continue-reading-title`), so `Naming.ALIAS_PREFIX`'s English spelling
matches an English Kavita UI and nothing else. This is why the collapse above
rests on the shared `item_key` and on `last_read`, and **not** on the title: the
title is a convenience for display, and the identity is on the wire.

Note what this is *not*: the duplicated entries above are a different thing, and
carry no prefix at all.

### Series name

The series-feed `<title>` is `<Series> - Storyline`. Strip the ` - Storyline`
suffix. (The `deriveSeries` fallback on entry titles still applies to aggregate
feeds, where there is no series feed title.)

## Suwayomi

Navigation: `root → /library/series → /series/{mangaId}/chapters → per-chapter metadata`.

| Feed | Paginates | Notes |
|---|---|---|
| `/` (root) | no | `library/series`, `sources`, `categories`, `genres`, `statuses`, `languages`, `explore`, `library-updates`, `history` |
| `/library/series` | **not established** — see below | the canonical series list |
| `/series/{id}/chapters` | **yes**, 100/page, `rel=next` = `?pageNumber=2` | `rel=first`/`rel=last` too; `thr:count` carries all three facet totals |
| `/series/{id}/chapter/{n}/metadata` | no | a **feed with one entry** carrying the stream |
| `/history`, `/library-updates` | yes, 100/page, `rel=next` | chapter-level aggregates |

Every URL carries `?lang=`, including `rel=next` links — follow `rel=next`
verbatim and never rebuild the URL. Confirmed again 2026-09-12: the chain keeps
the `sort` and the `filter` it was entered with (`…?pageNumber=2&sort=number_asc&filter=all&lang=en`).

### `/library/series` was said not to paginate, and that was never provable

This document claimed 11 entries was the whole library. It is 16 now, still with
no `rel=next` — but that is not evidence of anything: the page size is 100, and
both numbers are far below it. The feed's own `<id>` ends in `page1`
(`urn:suwayomi:feed:library:series:en:page1:`), which is a shape that *has* a page
2 to name. So the honest entry in the table above is "not established", and a
library that grows past 100 series is what would settle it.

### `thr:count` states all three facets, always

Not "the active facet's total" — the feed emits the same three numbers whatever
`filter` asked for, and the order is `all`, `unread`, `read`:

```
filter=all    -> 36 entries,  thr:count="36" "1" "35"
filter=unread ->  1 entry,    thr:count="36" "1" "35"
filter=read   -> 35 entries,  thr:count="36" "1" "35"
```

So the first is the series' total either way, and the other two are a free
independent check: `unread + read == all` (1 + 35 = 36, and 0 + 177 = 177 on a
series that is entirely read). Nothing reads them today — `Feed` counts what it
walked — but they are the second opinion that first caught the pagination
question.

### The chapters feed paginates, and this document said it did not

It looked like a single response because every series checked here was under the
page size. A 67-chapter series returned all 67 entries and a 58-chapter one all
58, and the active `filter=all` facet's `thr:count` agreed with the entry count
(the `unread` plus `read` facets summing to the same total — a second,
independent check, and one that still holds). So the conclusion "no pagination
needed" was drawn from evidence that could not have shown otherwise.

At **403** chapters the same feed returns **100 entries** and advertises all
three:

```
rel=self   /api/opds/v1.2/series/13/chapters?pageNumber=1&sort=number_desc&filter=all&lang=pl
rel=first  …?pageNumber=1…        rel=next  …?pageNumber=2…        rel=last  …?pageNumber=5…
```

Page size 100, so 5 pages for 403 — and `thr:count="403"` still states the total.
The feed's own `<id>` says the same thing in one string, page and sort included:
`urn:suwayomi:feed:series:13:chapters:pl:page1:sort_number_desc:filter_all`.

**The pagination links inherit the current `sort` and `filter`**, and that is the
trap rather than a detail. The default order is `number_desc` — newest first —
so `rel=next` followed from the feed as browsed walks *backwards* through the
series: page 1 of Berserk is chapter 386 down to 288. `sort=number_asc`, which
`driver/suwayomi.lua`'s `catalogURL` asks for, yields a chain running from
chapter 1 upwards, and that is the only ordering from which the first unread
chapter is near the start. Following `rel=next` is right; following it from
whatever page the reader happens to be on is not.

Entry `<summary>` on this feed carries the progress prose
(`… | Chapter 288| Przez Official| Postęp: 0 z 20`), so a page of it is enough to
tell a finished chapter from a started one — see `progressFromSummary`.

### `entry.id` is a stable identity, and the chapter number is not

This was the open question Zadanie 0 existed to settle, and the plan's
assumption — "Suwayomi identifies a chapter by number, so `item_key` is the
number" — is **wrong**. Three different numbers per chapter, and the feed
disagrees with itself:

```
entry.id    urn:suwayomi:chapter:16851
title       '⭕  Kaiju Girl Caramelise: Chapter 56.5'
subsection  /series/5572/chapter/58/metadata
```

The title says 56.5, the path says 58 (a list position, not a chapter number).
Chapter numbers are renumbered on a metadata refresh and can repeat between
scanlators; the path segment is an index. **`item_key` = the `entry.id` URN**,
which is stable and unique. Series ids come the same way: `urn:suwayomi:manga:3649`.

### Progress is in the summary prose, and only there

The chapter-list entry carries no PSE attributes at all — no stream link, so
nowhere for them to sit — but it does state per-chapter progress, inside the
human-readable `<summary>`:

```
<summary type="text">My Girlfriend is 8 Meters Tall | Chapter 63| Przez Unknown| Postęp: 0 z 31</summary>
```

Four `|`-separated fields: **series name**, chapter label, author, progress. The
progress is the **last** field, and `?lang=` localises its prose without touching
its digits — so the last two integers of that field are `read` and `total`
whichever language was asked for, and `driver/suwayomi.lua` reads only the
digits. (The second number is also the chapter's page count, but it is
deliberately *not* taken as `page_count`: `pse:count` states that authoritatively
once the stream is resolved, and a figure scraped out of prose must not displace
one the server said.)

**The first field is the series, not the chapter, and its prefix changes with the
language** — which is more than localised prose, and is the one thing here that
a reader of this document could not have guessed:

```
lang=en  Series: Apocalypse Bringer Mynoghra - World Conquest … | Chapter 33.1| By Unknown| Progress: 0 of 25
lang=pl  Apocalypse Bringer Mynoghra - World Conquest … | Chapter 33.1| Przez Unknown| Postęp: 0 z 25
```

`Series: ` is present in English and absent in Polish; two spaces follow the
colon in one and one in the other. Nothing in the driver depends on it —
`progressFromSummary` takes the *last* field, and `Naming.stripSeriesLabel`
already tolerates the prefix where a name is read — but a parser that keyed on
field *position* would have to be right in both languages and would not be.

A chapter's own cover *is* reachable — from the metadata feed only:
`rel=http://opds-spec.org/image` → `/api/v1/manga/{id}/chapter/{n}/page/0`.
Nothing spends it, deliberately (one request per chapter — see `CLAUDE.md`), and
the chapter-list entry carries no image at all. Recorded so that absence is not
read as a gap in the extraction.

Kavita needs none of this — its series feed puts `p5:lastRead` on every entry,
machine-readable, which is why `items.last_read` is populated for one server and
had to be scraped for the other.

### Chapters have no stream — they point at a metadata feed

A chapter entry carries only `rel=subsection` → `/series/{id}/chapter/{n}/metadata`.
That endpoint returns a feed containing **one entry** which holds the stream:

```
rel=http://vaemendis.net/opds-pse/stream
     href /api/v1/manga/3649/chapter/35/page/{pageNumber}?updateProgress=true&opds=true
     type=image/jpeg pse:count=35 pse:lastRead=34 pse:lastReadDate=2026-09-02T05:15:49Z
```

The href is path-only, so it must be made absolute against the metadata URL's
base. This is the lazy per-chapter fetch the plan anticipated: `resolveStream`
is an I/O operation for Suwayomi and a no-op for Kavita, which is why it takes
the `fetch` callback.

**`pse:lastRead` is conditional, and this document showed it unconditionally.**
It appears only once the chapter has progress — the example above is a chapter
sitting at 34 of 35, which is why it has one. A chapter nobody has opened
publishes `pse:count` alone. Nothing depends on the distinction here (the
chapter list's `<summary>` is where Suwayomi's progress is read, and the driver
never takes `last_read` off this link), but the attribute's absence is not a
server that tracks nothing. Komga behaves the same way for the same reason — see
its section.

**The `subsection` href is absolute against the *host*, not against the catalog
root** — it reads `/api/opds/v1.2/series/3649/chapter/1/metadata?lang=en`,
repeating the API prefix the catalog root already carries. Joining it onto the
catalog root yields a doubled prefix and a 404 page that still answers 200 with
a feed titled "Suwayomi". A leading `/` is what makes `url.absolute` do the right
thing here; constructing the URL by concatenation does not.

### The same chapter has two different `<id>`s

Observed by fetching both feeds for one chapter:

| Feed | `entry.id` |
|---|---|
| `/series/3649/chapters` | `urn:suwayomi:chapter:9345` |
| `…/chapter/1/metadata` | `urn:suwayomi:chapter:9345:metadata` |

This is load-bearing. A sync builds keys from the chapter list, while an open is
always on the metadata feed (a chapter-list entry has no stream, so the button
appears one level deeper) — so the two would derive **different `item_key`s for
the same chapter**, and every book opened would insert a second, never
reconcilable row for its chapter alongside the one the sync created. The driver
strips the `:metadata` suffix; `PROTOCOL.md` records it because the rule is
invisible from either feed alone.

### The metadata feed's `<title>` is not a series title

```
'Apocalypse Bringer Mynoghra - World Conquest Begins with the Civilization of Ruin | Chapter 1 | Details'
```

The chapters feed says `<Manga> Chapters`; this one says
`<Manga> | Chapter N | Details`. A driver that only knew the first shape would
find no series name here and name the series after the chapter. The first
`|`-separated field is the manga name, which is what `mangaNameFromFeedTitle`
extracted in the old plugin.

### Canonical catalog URL and ordering

`/series/{mangaId}/chapters?lang=<lang>&sort=number_asc&filter=all`

The default order is **descending** (newest first). `sort=number_asc` is
honoured and reverses it — verified by fetching both ways and comparing the
first and last five titles. The driver must supply it; the plan's guess about
these exact parameters turned out to be right.

### Series name

The chapters feed `<title>` is `<Manga> Chapters` — strip the ` Chapters`
suffix. On aggregates there is no such title, so `deriveSeries` on the entry
title is the fallback. Its format varies by source and cannot be assumed:

```
'⌛  Lucky Mia!: Ch. 5'                              <- "Ch."
'⭕  They Are Still Being Shaken This Morning: Chapter 51'   <- "Chapter"
'⭕  Kaiju Girl Caramelise: Chapter 56.5'              <- decimal
```

`VOLUME_TOKENS` already carries both `Chapter` and `Ch`, and tolerates the
decimal.

## Komga

Observed 2026-09-12 against a live instance, and cross-checked against the
source (`gotson/komga`, `interfaces/api/opds/v1/`) — line numbers below are that
file's, and they are cited because two of these findings look like bugs in the
*reading* code and are not.

Authentication is **HTTP Basic**, not a key in the URL. There is therefore no
secret anywhere in a Komga URL, and nothing for `meguru/credential` to strip —
see the note on `<redacted>` in a Komga marker below.

Navigation: `root → /series → /series/{seriesId}`.

| Feed | Paginates | Notes |
|---|---|---|
| `/catalog` | no | sections: `keep-reading`, `ondeck`, `series`, `series/latest`, `books/latest`, `libraries`, `collections`, `readlists`, `publishers` |
| `/series` | **yes**, 20/page, `rel=next` = `?page=1` (0-based) | the canonical series list |
| `/series/{id}` | **yes**, 20/page | that series' books; feed `<title>` = the series title |
| `/books/latest`, `/ondeck`, `/keep-reading` | yes | **books across every series** — see "No series id" below |

### The page number is zero based

`/opds/v1.2/books/{bookId}/pages/{pageNumber}`, and the first page is
`{pageNumber}=0`. Verified directly: `pages/0` returns the scan named `…-1.png`,
`pages/197` on a book with `pse:count="197"` returns
`400 Page number does not exist`.

The source states it outright — the endpoint converts before delegating:

```kotlin
// OpdsController.kt:727
commonBookController.getBookPageInternal(bookId, pageNumber + 1, convertTo, …)
```

**This needs no correction in `meguru`.** `PSE.pageURL` is handed a zero-based
index (`doc/document.lua` calls it as `pageURL(template, pageno - 1, …)`), so a
Komga template goes into a marker verbatim. A driver that "fixed" the off-by-one
would skip page 1 and 400 on the last page.

### Progress is published — but only once there is some

```kotlin
// OpdsController.kt:756
OpdsLinkPageStreaming(mediaTypes.first(), uriBuilder("books/$id/pages/")…,
                      media.pageCount, readProgress?.page, readProgress?.readDate)
```

So a book entry's stream link carries `pse:lastRead` (`readProgress.page`) and
`pse:lastReadDate` alongside `pse:count`. A library nobody has read looks like a
server that tracks nothing at all, because the attribute is simply absent —
which is why the first capture of this feed had no progress in it anywhere.

The page is `readProgress.page`, i.e. in Komga's own one-based numbering, which
is the same numbering `pse:lastRead` uses on Kavita. **This has not been
re-verified against a book that has progress** — `/keep-reading` and `/ondeck`
were both empty on the instance captured. The check is step 5 of the device
list; a zero-based value would show up as an offer one page early, and
`PSE.samePlace`'s tolerance would hide it.

### No series id on a book entry

`BookDto.toOpdsEntry` (`OpdsController.kt:760`) builds exactly four links and
none of them names a series:

```
books/{bookId}/thumbnail/small   rel=http://opds-spec.org/image/thumbnail
books/{bookId}/thumbnail         rel=http://opds-spec.org/image
books/{bookId}/file/{name}.cbz   rel=http://opds-spec.org/acquisition
books/{bookId}/pages/{pageNumber}  rel=http://vaemendis.net/opds-pse/stream
```

`<id>` is the **book** id. This is the opposite of Kavita, where `seriesId` rides
along in the stream URL's query — so `Komga.discover` reads the series id out of
the **feed's own URL** instead (`/series/([^/?]+)`), which the engine passes as
`ctx.url`.

The consequence used to be that an aggregate could not be opened from.
`books/latest`, `ondeck` and `keep-reading` list books from every series and
carry no series id in any entry, so there was nothing in the feed to identify the
series by, and `discover` refuses rather than guessing — the same refusal that
keeps a browse of `recently-added` from syncing the wrong series on Kavita.

**The id is one request away, and that is where it is now asked for.** The book
id rides in the entry's own stream template (`/books/{id}/pages/{pageNumber}`),
and `GET {prefix}/api/v1/books/{bookId}` answers with Komga's `BookDto`, which
carries `seriesId` and `seriesTitle`. `Komga.resolveSeries` makes that request
once per *book*, which is the only place it is affordable: `discover` is called
in a loop over a whole feed, so a request there would turn a tap into a walk of
the network rather than of the feed. The browse that does work is unchanged and
pays nothing — `/series` is a feed that names its series, so `discover` answers
and the hook is never reached.

### Series name

The series feed's `<title>` is the series title and nothing else — no
`" - Storyline"` suffix and no `" Chapters"` suffix, unlike the other two. On an
aggregate the same element holds `"Latest books"`, so the driver only trusts it
when the feed URL is a series URL; otherwise it falls back to `deriveSeries` on
the entry title, which Komga writes as:

```
'Tis Time for 'Torture,' Princess v01 (Digital-Compilation) (Antrill-Oak)
→ series "'Tis Time for 'Torture,' Princess", label "v01", index 1
```

`stripTrailingReleaseGroups` and the `"v"` token in `VOLUME_TOKENS` already
exist for this shape.

### A Komga marker has no `<redacted>` in it

`Credential.redactTemplate` replaces the segment after `/opds/`, because that is
where Kavita's key sits. In `…/opds/v1.2/books/…` that segment is `v1.2` — so
Komga's URLs are redacted to `…/opds/<redacted>/books/…` on the way to disk, and
`restoreTemplate` puts `v1.2` back from the same catalogue root on the way in.

It round-trips, and it is safe for the reason `meguru/credential` gives: the
positional rule replaces only what it can name and names it back the same way,
and the prefix guard refuses when the root's host has moved. But it is worth
knowing that on Komga the "credential" being redacted is an API version, and
that the mechanism is doing nothing protective there — Basic auth means there is
no secret in the URL to protect.

## Reading-progress glyphs (Kavita and Suwayomi)

The leading glyph is server bookkeeping marking reading state, and it is
attached to the real entry — there is no separate alias entry to peel. The full
repertoire seen across both servers:

```
⭘ U+2B58  ⬤ U+2B24  ◔ U+25D4  ◑ U+25D1  ◕ U+25D5   (Kavita)
⌛ U+231B  ✅ U+2705  ⭕ U+2B55                       (Suwayomi)
```

All fall inside `GLYPH_RANGES`. The old `READING_GLYPHS` list — the nine
codepoints known in the field — is a strict subset, which is the argument for
matching ranges rather than an enumerated list: a server build that picks a new
status icon is still handled without a code change. `READING_GLYPHS` is
documentation only and was not ported.

## OPDS-PSE namespace prefix is not stable

Kavita spells the namespace prefix `p5:` (`p5:count`), Suwayomi spells it
`pse:` (`pse:count`), and the old code's note about matching attributes by key
*suffix* (`:count`, `:lastRead`) is therefore load-bearing, not defensive. A
prefix-stable match would silently see `count = nil` on one of the two servers
and produce a document with no page count.
