# Where an open starts

The resume dialog and the server's own progress, the opens that stay silent, and how a marker is planned before it is written.

Part of the design record; [CLAUDE.md](../CLAUDE.md) is the map.

## Where an open starts

**Local reading progress is not mirrored into a book, and the server's direction is
a separate thing.** The reader's own place is read lazily, per book, from the
sidecar beside the marker: `DocSettings:findSidecarFile` then `openSettingsFile`,
reading `percent_finished`. That is the only place it lives, which is what makes a
marker safe to rewrite — there is no reader state in it to lose.
(`DocSettings:hasSidecarFile` is the cheaper, parse-free variant of the same test,
used where nothing needs reading.)

**But progress *is* written now, in the other direction.** `meguru/progress` sends
the page the reader has reached back to the server the book came from — Komga only,
on by default, one switch per server — so the server's own apps keep the place. It
sends a page number and nothing else, it never writes anything back into the book
or its sidecar, and it is why the server's position below exists at all. See
`docs/reading-position.md`.

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

