# Next and previous in a folder of `.cbz`

A folder of `.cbz` treated as a series: the natural sort, why the name grammar was removed, and what that cost.

Part of the design record; [CLAUDE.md](../CLAUDE.md) is the map.

## Next and previous in a folder of `.cbz`

**A local `.cbz` is known by the metadata it carries, not by its file name.**
`MeguruDocument:_localComicProps` reads the archive's own `ComicInfo.xml` —
ComicRack's schema, which comic libraries write and serve and which Rakuyomi
writes into every chapter it downloads — and falls back to the file's name only
when there is no such entry, or it will not parse. `meguru/comicinfo` is the
whole of that read, and it reads **into memory** (`Archiver.Reader:extractToMemory`)
rather than through `extractToPath`, because the disk-writing route would have
made merely opening a comic leave a file behind. This replaced a `{ title =
self:_localTitle() }` that returned the name unconditionally, and the reason is
worth keeping straight: **Rakuyomi was not broken, it stopped being called.** Its
own `CbzDocument:getDocumentProps` reads the same entry and merges it, so a file
it opened was titled properly — but the moment Meguru claims `.cbz` the document
is ours, that method never runs, and the file falls back to its name. Reading the
entry here is what makes the metadata survive whoever owns the extension, and it
needs Rakuyomi only to have written the file, never to be present at read time.

Two properties of it are load-bearing. **`title` is the file's own `Title` and
the series is a field beside it** — not folded, unlike the streamed path, because
`BookInfo.extendProps` puts `title` straight into `display_title` while `series`
is drawn on a line of its own, so folding would print the series twice; a marker
folds only because the descriptor it projects has no series *field* for the title
to sit beside. And **the entry is read once per document** (`self._comic_info`,
with `false` for "read, none there"), because it opens the archive.

**The whole schema is read and seven fields are used, because `doc_props` has
seven slots.** `ComicInfo` v2.1 declares about forty elements and `BookInfo`
draws exactly `title`, `authors`, `series`, `series_index`, `language`,
`keywords`, `description` — so "use the whole schema" cannot mean putting it into
`doc_props`. What it does mean is what `meguru/comicinfo` does: one pass collects
every non-empty element the entry has, and a `MAP` table decides which one
answers which key, so a field a newer writer adds is read without a change and
the mapping is one table to read rather than a `match` per property. Two entries
in that table are judgement calls and are named as such there: `keywords` takes
`Tags` then `Genre`, and `authors` takes `Writer`.

**Element names are matched case-insensitively, and that is a requirement.**
`ComicInfo.xsd` declares the language element as `LanguageISO` and declares no
second spelling — but the files in hand write `<LanguageIso/>`, lowercased, which
is ComicRack's spelling, so the divergence is the **writer's** rather than a
version of the schema. (An earlier draft of this paragraph said the schema had
renamed it between versions. It had not been checked; the XSD was, and it says
otherwise.) An exact match would have missed it on the very files this was
written for, and missed it silently. Measured against two synthetic archives, one
per spelling.

**The XSD carries no documentation at all** — no `xs:annotation`, so nothing
settles what `Genre` means against `Tags`, or whether `Writer` is the author.
That is why the two judgement calls in `MAP` are named as judgement calls rather
than defended: the schema is silent, so they are a reading, and they are one line
to change when a file turns up that fills both.

**`entry.size` from the archiver is a cdata `int64_t`, not a Lua number.** A
guard written as `type(entry.size) == "number"` is false for `754LL`, so it
refuses the entry and looks exactly like an archive that has none — which is what
the first version of this module did, and why a book opened through Rakuyomi kept
its hashed name while every part of the read was in fact working. Compare it to a
number directly; that is what LuaJIT's FFI does natively and `tonumber` does not.

**A book already opened keeps its old title on the FileManager's list until the
cache is refreshed.** The sidecar's `doc_props` is recomputed on every open and
is right immediately, but the list itself is drawn from `BookInfoManager`'s own
cache, which nothing in this plugin writes or invalidates — so
*Refresh cached book information* is what puts the new title on screen. An
earlier version of this paragraph claimed "nothing has to be migrated", which was
true of the sidecar and false of the thing the reader is actually looking at.

**A local `.cbz` has the same two rows a marker has, and its series is the folder
it is in.** `meguru/local.lua` is the whole of it: it lists the file's own folder,
orders the books by a **natural sort of the file name** — `2.cbz` before `10.cbz` —
and answers which file is either side. Nothing is read out of the name, nothing is
written, nothing is remembered, and no socket is opened: this path is offline by
construction, which is why its branch in `Reader.openNeighbor` sits **above** the
`NetworkMgr` gate rather than below it. `MeguruDocument:localSeries` is the seam,
deliberately a *second* method beside `seriesContext` rather than a branch inside
it: that one projects a marker and everything downstream branches on its nil, and
two answers that can never take each other's shape is what keeps the feed path and
the folder path from being confused.

### What this replaced, and what it cost

There was a **name grammar** here, and it is worth knowing what it was, because the
temptation to rebuild it is the obvious "improvement" to make. It read the series
out of the file name: volume tokens, bare trailing numbers, a leading number as a
position rather than a title, which bracketed group was a release tag and which was
part of the title, case-folding by hand so the device's locale could not move a key.
Every rule was defended by a real example and every rule was there to answer one
question the folder already answers — *are these two files the same series?* — in
order to survive a layout nobody has: one folder holding two series' books. It cost
a grammar no reader could predict, no test could reach (`tools/check.py` cannot see
into a name-keyed comparison), and an asymmetry that had to be explained in three
paragraphs.

**The trade is now explicit.** A folder that holds two titles will navigate from one
into the other: `next` on the last Berserk volume opens whatever sorts after it.
Nothing on disk tells that folder from a real series folder, so this does not
pretend to — and that is exactly why `Local.seriesOf` answers nil unless the folder
holds **a second book to move to**. A lone one-shot gets no navigation rows at all,
rather than two rows that could only say there is no next. A folder is still refused
outright when it cannot be listed, or when a listing loses the very file being read.

There is **no cap** on the folder. A long webtoon run is the case this exists for,
and any cap low enough to catch a library folder would refuse it too; the price is
one `lfs.attributes` per entry, on a menu build and on a tap.

`Naming.deriveSeries` and its helpers are **not** part of this — they are the
server path's, where a *title* really is all there is to go on, and `Feed.ordered`
still orders a feed by them. Nothing here calls them.

### The one piece that is not obvious: the sort key

`sortKey` encodes a digit run as the marker byte `\1`, its length (leading zeros
dropped) in three digits, and the digits themselves, so that plain string
comparison sorts naturally — `001` is less than `002` before a single digit is
compared, which is what puts `2` before `10`.

**A key rather than a comparison function, and that is not a style choice.** Walking
two names at once is how a natural sort is usually written and how `table.sort`
comes to throw `invalid order function for sorting` — from inside a tap, when the
walk turns out not to be a consistent order. A key is a function of *one* name, so
the comparison is `<` between two strings and cannot be inconsistent; the encoding
is also injective, so two different names never share a key. The mirror written to
check it found the one real bug here before a device could: the padding that keeps
`2`, `02` and `002` distinct sits **before** the rest of the name, so a `\0` pad
sorting "naturally" would actually sort `02` *before* `2` — the pad is `\255`,
above every byte a UTF-8 name holds, and fewer leading zeros sorts first.

### Log lines

Three, and the level each is at is the frequency rule: `dbg` for
`Meguru: local folder <dir> — <N> book(s), this one at <pos>`, which fires on every
menu build and every tap because it marks the *normal* path; `warn` for
`Meguru: cannot list the folder of <file> (…)`, which marks the failure; and
`info` for the tap that found nothing — `Meguru: no local neighbour of <name>
towards <which>` — worded to mirror the feed's `no neighbour of … towards …`,
because it is the same refusal on the other path.

**There is deliberately no line for the forced provider.** The open that worked
already prints the document's own `Meguru: local CBZ ready — …`, and that line is
*absent* when the provider was not Meguru — which makes it the test rather than the
thing needing a second line beside it. `Open.openLocalFile` forces it —
`switchDocument(path, nil, nil, provider, true)` — because the row belongs to a
Meguru book and promises the next volume *here*; a reader who has given `.cbz` back
to KOReader would otherwise be moved out of this engine mid-series. Forcing is
per-open and writes nothing: the per-file `provider` key in a sidecar is only ever
written by the "Open with…" dialog. `FS.exists` comes first, because
`switchDocument` closes the reader *before* it tries to open anything — a sibling
deleted between the listing and the tap would otherwise leave the reader torn down
with nothing in its place.

