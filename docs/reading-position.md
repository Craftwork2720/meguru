# The position, sent back

How the page the reader has reached gets to the server the book came from: what is sent, when, and the one rule that keeps a server from being walked backwards.

Part of the design record; [CLAUDE.md](../CLAUDE.md) is the map.

## The position, sent back

**The loop was open at the write end, and that is the whole reason "Komga does not sync"
looked true.** A Komga book's progress was only ever *read*: `pse:lastRead` off the
series feed, which Komga publishes from `readProgress?.page` and only once a book has
some. Nothing in this plugin sent one, so `readProgress` stayed empty, so the attribute
never appeared on the feed, so the read half — [opening-a-book](opening-a-book.md)'s
resume offer and `MeguruDocument:init`'s silent seed — had nothing to read. Every
symptom of a server that tracks nothing came from the missing direction, and the reading
half needed no change at all.

### What goes out, and where

```
PATCH {prefix}/api/v1/books/{bookId}/read-progress
Content-Type: application/json
{"page":<n>}                             → 204
```

`Komga.progressRequest` builds it; `meguru/progress` sends it; `Net.patch` is the only
write in the plugin.

**The method and the body were both wrong in the first version, and a device said so.**
It was a `PUT` carrying `{"page":N,"completed":B}`, derived from the shape of Komga's API
rather than from a request to a server. The first real report was answered **405 Method
Not Allowed** — Komga 1.27.0 accepts `PATCH` and `DELETE` on that path and nothing else,
which its own OpenAPI at `/v3/api-docs` states outright. And `completed` is **the
server's to answer**: `ReadProgressUpdateDto` documents it as optional and derived,
"set accordingly depending on the page passed and the total number of pages in the book"
— so Komga computes it from the only page count that is authoritative, where ours is a
snapshot in a marker and would have called a replaced book finished. The lesson is the
one this file keeps relearning: an endpoint derived from a shape is a guess, and a 405 or
a silently wrong field is what a guess costs. Ask the server.

`prefix` and `bookId` come out of the marker's stream `template` with the prefix
**taken rather than rebuilt**, the same call `Komga.seriesCover` makes and for the same
reason: a Komga behind a reverse proxy keeps its path prefix on both of its surfaces.

**Two numbers, two bases.** The page in a stream URL is zero-based — `doc/document.lua`
passes `pageno - 1` — and the page here is one-based, as the reader pages and as
`readProgress.page` counts. Nothing converts either. A driver that "unified" them would
be off by one on one surface or the other.

**And the base was measured, not argued**, which is what `PROTOCOL.md` had been waiting
for: a report of page 57 was sent and the series feed then published
`pse:lastRead="57"` for that book. The number goes out as the reader's own page and comes
back as the same number, so the two ends of the loop agree — which is the only thing
this plugin needs to be true, and is now observed rather than inferred.

**Not Komga's OPDS v2 `progression` link**, which looks like the natural home for this
and is not one: it is the Readium surface, aimed at EPUB readers, and Komga does not feed
it back into the `readProgress` that produces `pse:lastRead`. Writing there would move
the open end rather than close it.

**Suwayomi and Kavita are absent, for two different reasons.** Suwayomi must not be given
this: its own stream template carries `?updateProgress=true`, so its server is told by
the page fetch the reader already makes — the one server whose loop was never open, by
accident of its wire format. Kavita's write API is a different surface from its OPDS one
and wants a JWT from a login rather than the API key its URLs already carry; that is a
second authentication path, and this plugin does not carry one.

### The account is the feature

**A report lands on whichever user the catalogue in `settings/opds.lua` authenticates
as.** Komga keeps `readProgress` per user, so a catalogue pointing at an account nobody
reads as will accept every write, store it against that account, and publish nothing the
reader ever sees — the write path is working perfectly and looks like it is not. This is
the first thing to check when the feature appears dead, and it is not a client bug:
[development.md](development.md)'s step 26 is where it is caught.

### When it fires

On every page turn, behind a **trailing-edge debounce of 1.5s**, plus a flush at every
seam that ends a session — `onCloseDocument`, `onClose`, `onFlushSettings`, `onSuspend`.

- **The delay is load-bearing, not cosmetic.** `UIManager:nextTick` is
  `scheduleIn(0, …)`, and `handleInput` runs its due tasks *before* it repaints — so a
  task armed with no delay would run in the very iteration about to paint the page the
  reader just turned to, and the request would block that paint. `Net.patch` is
  synchronous; the device has no threads.
- **Only the newest page is kept.** `pending` is one number, never a queue: a queue is
  how a slow server accumulates a backlog of pages nobody is on any more.
- **One stable closure** for the scheduled task, because `UIManager:unschedule` matches
  by identity — a fresh closure per turn would leave orphaned tasks behind and report
  twice.
- **The flush reads the page off the screen**, not `pending`, because the debounce may
  never have fired for it; and it is **deduplicated**, because one exit reaches three of
  those seams within a few lines of each other and a server that is down would otherwise
  cost three block timeouts for one page.
- **The breaker is per book**, since the state lives on the plugin instance and a plugin
  instance belongs to one `ReaderUI`. Three consecutive failures retire reporting until
  the next book; the flush ignores the count, because a closing book is the one moment
  where a blocked request is affordable.

### The one rule

**A report never lowers the position the server already has.** Everything else follows
from that sentence and the floor it is computed against — `Progress.floorFor`, seeded
from the marker's `last_read` (the *server's* number, never the sidecar's) and raised with
every accepted report:

- a finished book cannot be un-finished — Komga records its last page, so the floor is
  the last page and every report is refused;
- a position that has not moved is not re-sent;
- a page already accepted is not reported again.

It is clamped to `count`, so a page count that shrank under a stale recorded page cannot
lock a book out of reporting for ever, and it is **base-agnostic on purpose**: whether a
server counts its recorded page from zero or from one needs no answer here, because a
floor one page too low can only permit a report that could have been refused, and can
never move a server backwards.

**Two floors, and neither is redundant.** The caller's rises with every accepted report
and stops duplicates within a session; the sender's is the marker's snapshot and is what
makes `Progress.report` a function no caller can misuse. The caller's is the stricter of
the two, so the sender's never refuses a report the caller would have sent.

### Failure

**Silent to the reader, always.** No dialog, no notification, no throw, no retry of its
own: a report that does not land is a lost page number, not a lost book, and the reader
is turning pages.

- Offline is asked **before** the request, so reading on a train costs nothing rather
  than one timeout per page turn.
- `"http"` and `"network"` are kept apart, the way `Net.fetchFeed` keeps them apart: a
  caller that hears "http" for a dead route goes looking for a status code that does not
  exist. Neither `"off"`, `"offline"` nor `"behind"` counts against the breaker — they
  are not the server's fault, and the answer changing is how reporting comes back.
- **Nothing the server answers is logged.** Its refusal text is genuinely useful and is
  still not printed: a `crash.log` gets pasted into bug reports, a response is text
  nobody here controls, and a misconfigured proxy echoing the request would put the Basic
  header into it. See [security-notes](security-notes.md).

### What it must not do

1. **Nothing is written to disk.** The floor lives in RAM and dies with the book.
   Rewriting the marker at close would turn `last_read` from "the page the server
   reported" into "the page we sent" — the very field the floor is computed from,
   answering a different question.
2. **Nothing flows back into the book.** The report is not a mirror; `meguru/progress`
   sends and stores nothing.
3. **No second assignment to `plugin.onPageUpdate`.** The handlers in `ui/reader.lua` are
   assigned, not chained, and the new one is chained onto whatever the failed-page
   installer left — a second assignment would quietly erase it. It is chained rather than
   merged into that installer because the installer returns early for a document with no
   `paintMissingPage`, and a page turn is not a painter's business.

### The holes, named

1. **A marker with no `last_read` has no floor**, so opening a finished Komga book this
   plugin has never seen and turning to page 2 would report a page the server is past and
   move it back. This is not a new hole: it is the one [known-issues](known-issues.md)
   already records for `driverItemFor` writing a marker from a tapped "Continue From" row,
   arriving with a second symptom, and the repair belongs there rather than here.
2. **A stale floor across a reopen.** A marker written from the browser carries a current
   `last_read`; one reopened from History carries whatever it was written with. Turning
   back *within* a session is refused; turning back after a reopen may not be. The
   expensive fix — re-walking the series feed on every open — is not worth a request per
   open, and a reader who turns back and stops there has, in Komga's model, put
   themselves there.
