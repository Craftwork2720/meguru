# Feeds and drivers

Reading a series feed -- the `rel=next` walk, the reading order, the neighbour -- and the driver contract, with what each server does differently.

Part of the design record; [CLAUDE.md](../CLAUDE.md) is the map.

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
- **A driver never opens a socket.** Two hooks take an injected callback rather
  than a socket: Suwayomi's lazy per-chapter metadata fetch arrives as
  `resolveStream`'s `fetch`, which answers with a **parsed feed**, and Komga's
  `resolveSeries` takes a `fetch_json` that answers with a **decoded body**.
  Credentials, timeouts and log redaction stay in one place either way, and a
  driver reads no bytes in both.
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
resolveSeries(entry, stream, ctx, fetch_json)
                                      -> { series_remote_id, series_name?,
                                           discovered_from }, or nil   [optional]
```

`seriesCover` was the first optional hook, and it exists because one server
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
That refusal is also why a Komga **aggregate** cannot be resolved *from the feed* —
`books/latest`, `ondeck` and `keep-reading` list books across every series and carry
no series id at all. It is no longer the end of the story: `resolveSeries` asks the
server about the one book being opened, which is one request for one open and not one
per entry, and that is the whole reason it is a second hook rather than a request
inside `discover`. Browsing `/series` → volume is untouched and pays nothing extra.
Without the hook a book still opens — it simply has no series, and so no folder and
no neighbours, which is what an aggregate gave before this existed.

`discovered_from` records where an identity came from: a series feed, the entry's own
stream, or an aggregate whose series had to be asked for. An aggregate is not a series,
and an entry reached from one may carry no recoverable series id at all — the case
`resolveSeries` exists for. **Never silently sync the wrong series.**

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

