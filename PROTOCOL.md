# What the servers actually emit

Observed wire format of the three v1 servers, captured against live instances by
walking the real feeds: **2776 Kavita series / 21217 feed entries** and the full
Suwayomi library (2026-09-10), and Komga (2026-09-12, cross-checked against its
source). This is the evidence the drivers are written against — where it
disagrees with an assumption, the observation wins.

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
| `/` (root) | no | sections: `on-deck`, `recently-updated`, `recently-added`, `reading-list`, `want-to-read`, `libraries`, `collections`, `smart-filters` |
| `/libraries` | no | the libraries themselves (5 here), `entry.id` = library id |
| `/libraries/{id}` | **yes**, 20/page, `rel=next` = `?pageNumber=2` | the canonical series list |
| `/series/{id}` | **no** (0/46 checked) | the whole series in one response |

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
link rel=http://vaemendis.net/opds-pse/stream
     href /api/opds/<KEY>/image?libraryId=39&seriesId=17086&volumeId=114712
                              &chapterId=176915&pageNumber={pageNumber}
     p5:count=207 type=image/jpeg
```

Three different numbers, none interchangeable:

| | value | role |
|---|---|---|
| `entry.id` | `296595` | opaque; do not use |
| `volumeId` | `114712` | **not unique** — 132/2776 series put many entries on one volume |
| `chapterId` | `176915` | unique per real chapter — **this is `item_key`** |

### `seriesId` is recoverable from the stream URL

The stream href carries `seriesId`, `volumeId` and `chapterId` as query
parameters. The plan assumed Kavita's `seriesId` appears *only* in the browse
path and had to be threaded through as `ctx.paths`; it does not. `discover()`
reads it straight off the stream link, so a book opened from any feed — including
an aggregate — resolves to its series without extra context.

### Byte-identical duplicate entries

151/2776 series emit each chapter **twice**: same `entry.id`, same `title`, same
`updated`, same `chapterId`, same stream, back to back. Not an alias and not
distinguishable by any field — `title` never begins with "Continue Reading
from: " in any of the 21217 entries examined.

Nothing needs to de-duplicate these in code: `UNIQUE(series_id, item_key)` on
`chapterId` collapses them at insert. The old plugin de-duplicated by template
in Lua; the schema does it for free.

**Consequence for sync:** `series.item_count` must be set from the number of
**distinct items**, not from the number of entries walked — otherwise the 50%
shortening gate compares a duplicate-inflated denominator against a later
de-duplicated walk and reads a healthy sync as a catastrophic shrink.

### The feed is already in reading order

0/46 series were out of ascending order, so `feed_index` is the honest ordering
key. Titles mix granularity in 1/46 series (`Volume N` and `Chapter N` in the
same feed), so numbers parsed out of titles would risk *reordering* a list the
server already ordered correctly. Kavita therefore uses
**`ordinal_source = 'feed'`** (ordinal NULL), not `'volume'`/`'chapter'`.

### Series name

The series-feed `<title>` is `<Series> - Storyline`. Strip the ` - Storyline`
suffix. (The old `deriveSeries` fallback on entry titles still applies to
aggregate feeds, where there is no series feed title.)

## Suwayomi

Navigation: `root → /library/series → /series/{mangaId}/chapters → per-chapter metadata`.

| Feed | Paginates | Notes |
|---|---|---|
| `/` (root) | no | `library/series`, `sources`, `categories`, `genres`, `statuses`, `languages`, `explore`, `library-updates`, `history` |
| `/library/series` | **no** — 11 entries is the whole library | the canonical series list |
| `/series/{id}/chapters` | **yes**, 100/page, `rel=next` = `?pageNumber=2` | `rel=first`/`rel=last` too; `thr:count` on the active facet is the total |
| `/series/{id}/chapter/{n}/metadata` | no | a **feed with one entry** carrying the stream |
| `/history`, `/library-updates` | yes, 100/page, `rel=next` | chapter-level aggregates |

Every URL carries `?lang=`, including `rel=next` links — follow `rel=next`
verbatim and never rebuild the URL.

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

Four `|`-separated fields: title, chapter label, author, progress. The progress
is the **last** field, and `?lang=` localises its prose without touching its
digits — so the last two integers of that field are `read` and `total` whichever
language was asked for, and `driver/suwayomi.lua` reads only the digits. (The
second number is also the chapter's page count, but it is deliberately *not*
taken as `page_count`: `pse:count` states that authoritatively once the stream is
resolved, and a figure scraped out of prose must not displace one the server
said.)

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

The consequence is that an aggregate cannot be opened from. `books/latest`,
`ondeck` and `keep-reading` list books from every series and carry no series id
in any entry, so there is nothing to identify the series by and `discover`
refuses rather than guessing — the same refusal that keeps a browse of
`recently-added` from syncing the wrong series on Kavita. Browsing `/series` and
opening a volume works in full.

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
