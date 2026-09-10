# What the servers actually emit

Observed wire format of the two v1 servers, captured against live instances
(2026-09-10) by walking the real feeds: **2776 Kavita series / 21217 feed
entries** and the full Suwayomi library. This is the evidence the drivers are
written against — where it disagrees with an assumption, the observation wins.

Credentials are never written here. Kavita's API key is shown as `<KEY>`; it is
a path segment (`/api/opds/<KEY>/...`) and appears inside every stream URL.

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
| `/series/{id}/chapters` | no | all chapters in one response |
| `/series/{id}/chapter/{n}/metadata` | no | a **feed with one entry** carrying the stream |
| `/history`, `/library-updates` | yes, 100/page, `rel=next` | chapter-level aggregates |

Every URL carries `?lang=`, including `rel=next` links — follow `rel=next`
verbatim and never rebuild the URL.

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

## Reading-progress glyphs (both servers)

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
