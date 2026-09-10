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
  guards, and they cover three failure modes between them.
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
  paths.lua               every path: database, markers, page/cover caches
  fs.lua                  filesystem helpers
  settings.lua            plugin-wide preferences in G_reader_settings
  store.lua               SQ3 connection (module-level), schema, migrations, transactions
  catalog.lua             every query and command against servers/series/items
  sources.lua             read-only view on settings/opds.lua (catalogs + credentials)
  net.lua                 HTTP GET, feed fetch + parse
  naming.lua              sanitizeComponent / deriveSeries / alias / glyph
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
    cache.lua             on-disk LRU for pages and covers
    image.lua             MuPDF decoding with a size cap
    defaults.lua          per-book seeding of kopt_* from plugin preferences

  ui/
    open.lua              "Meguru this series": dialog, marker write, open
    library.lua           series list from the catalog, with new-chapter counts
    series.lua            items of one series, open, manual sync
    syncjob.lua           cooperative sync with progress and Cancel
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

The dependency graph is a DAG with no cycles. Two edges are deliberately lazy to
keep it that way: `ui/library.lua` -> `ui/series.lua` and `ui/menu.lua` ->
`ui/library.lua` are `require`d inside the callback, not at module load.

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
| Suwayomi | the chapter number from `/chapter/{n}/page/` |

Suwayomi's key is a chapter *number*, not a stable id — numbers are renumbered
when metadata is refreshed and can repeat across scanlators. The consciously
chosen failure mode is that a renumber **updates a row in place** rather than
duplicating a chapter.

**`items.ordinal` never degrades.** If the stored `ordinal_source` is `chapter`
or `volume` and a later sync can only offer `feed`, the old value stays.
Promotion only.

**Reading progress is not mirrored into the catalog.** It is read lazily per
series: `DocSettings:hasSidecarFile(marker_path)` is the free "never opened"
test, and `percent_finished` is read only for items that have both a
`marker_path` and a sidecar. This works only because `items.marker_path` exists;
a path pointing at a missing file means "not opened", with no fallback to a name
search.

**The database degrades gracefully.** A marker needs nothing from it to open and
read — `template` and `count` are in the file. Without the database, only
next/previous and the new-chapter counts are unavailable. That is why the
database can live in `settings/` and be restored from backup independently of the
books.

## The marker

Extension `.meguru`, provider key `"meguru"`. Serialised with `LuaSettings` as
`return { meguru = {...} }`, matching the `DocSettings` sidecar beside it.

```
server_name, series_remote_id, item_key, item_id,
title, template, count, last_read
```

`server_name` is the **catalog title**, which is the key credentials are looked
up by in `settings/opds.lua`. No secret is stored in the marker.

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

Sync is triggered by a lazy TTL on opening a series, gated on
`NetworkMgr:isConnected()`, plus an explicit manual action. **Never in the
plugin's `init()`**: at that point there is neither connectivity nor a UI.

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

Driver selection is by `servers.kind`, set by an author sniff with a **user
override in the menu**. A sniff is a heuristic, and one wrong classification
makes a server unsyncable for good, which is why the override exists and why
`Catalog.clearServerKind` clears `kind_source` along with `kind` — `upsertServer`
treats `kind_source = 'manual'` as final specifically so a browsing session
cannot undo the user's choice.

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
- **`sorting_hint` must name an existing menu item.** The sorter dereferences the
  lookup without checking, so a hint naming nothing crashes the entire menu
  build; it is set only when the id is present. `separator = true` works in
  `TouchMenu` (the reader ⋮ menu) but **not** in the plain `Menu` widget the
  library and series views use.

## Plugin lifecycle facts worth not rediscovering

- `ReaderUI:showReaderCoroutine` builds a **new** `ReaderUI`, so the plugin loop
  re-runs and instances are fresh for every document. `Reader.install` therefore
  runs once per book automatically.
- Plugin **modules** load once per process (`PluginLoader.enabled_plugins` is
  cached and never reset), so module-level flags persist for the whole session.
  That is what makes `Reader.installStatusBarHook`'s once-per-process guard
  correct, and what makes the `DocumentRegistry:addProvider` guard necessary —
  `addProvider` only ever appends, so a second call would list the provider twice.
- The reader menu is a `TouchMenu`; the library and series views are plain
  `Menu`. They do not support the same row fields.
- `C_` is **not** a global. Every core file declares `local C_ = _.pgettext`; a
  plugin file that omits it gets a nil call only when a row is built.

## Development

```
python tools/check.py       # structure of the Lua
python tools/scan_sql.py    # semicolons inside SQL comments
```

There is no Lua interpreter on the development machine, so `check.py` stands in
for one. It runs three passes:

1. **Block balance** — `function`/`if`/`for`/`while`/`do` against `end`/`until`,
   over comment- and string-stripped source.
2. **Cross-module member references** — every `Module.member` where `Module` came
   from a `require("meguru/...")` binding is checked against the members that
   module actually defines.
3. **Unbound module tables** — `Geom:new{...}` where `Geom` is never bound in the
   file. KOReader declares no global of this shape, so the name is nil when the
   line runs.

None of the three is a parser. They are the failure modes that have actually
bitten this codebase, and that a reader cannot reliably catch by eye: a name or
member that is fine at load time and only explodes when a branch runs, on the
device, in the reader's hands. **The checker passes vacuously if its stripping or
its patterns are wrong**, so each pass was self-tested by injecting the real
failure and confirming the checker reports it — including at the right line. Do
the same before trusting a green run; two of the three passes were written
wrongly the first time and passed on the very bug they existed to catch.

`scan_sql.py` is narrow on purpose: it only looks for a `;` inside a SQL comment
in a Lua string. That one shape is a hard crash with an error message that names
nothing — see the `db:exec` rule above.

### Verifying on the device

No automated tests, so verification is a running KOReader. Run with `-d` or read
`crash.log`, filtering on `Meguru:`.

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
2. **Database with no network.** Open the library from an empty catalog — no
   crash, empty list.
3. **Suwayomi sync.** One series: item count in the database equals the chapter
   count in the service; the log shows the walk via `rel=next` across all pages
   and **one** `BEGIN`/`COMMIT`. Sync again: `item_count` unchanged and
   `SELECT COUNT(*)` unchanged (zero duplicates — this is the `item_key`
   identity test).
4. **Truncation resistance.** Force a failure mid-walk (drop the network, or
   point a page at a bad URL) — the database is unchanged, `sync_error` is
   recorded, zero tombstones. This is the `complete` gate plus the generation
   sweep.
5. **New chapters.** After a sync that adds a chapter the library shows a count;
   opening the series clears it.
6. **A marker opens without the database.** Open a book, rename
   `meguru.sqlite3`, reopen the same marker from History — the book must open and
   read, with no next/previous. Restore the database — next/previous returns.
7. **The marker does not lie.** Hand-edit `item_id` in a marker to another item's
   rowid — the open must land on the **correct** chapter via the natural key, not
   the substituted one.
8. **Page fetching.** One log line per page with a rising `pageNumber` plus
   prefetch, and **no** fetch of a whole archive.
9. **Engine port.** On the same title as the old plugin: crop, page-number crop,
   panel zoom, night-mode invert, wide-page rotation, local `.cbz` via "Open
   with…" — behaviour identical to the old plugin.
10. **Concurrency.** Two windows (FileManager + ReaderUI): the provider registers
    once, the same series does not sync twice, the UI never freezes and Cancel
    works during a walk.

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

- No secret is ever part of a marker descriptor. `server_name` is the catalog
  title, which is the credential key in `settings/opds.lua`.
- Credentials are resolved only when a page actually has to be fetched.
- `servers.root_url` and the derived `catalogURL` are **redacted** — no API key,
  no token.
- Kavita's stream `template` unavoidably embeds the API key; that is what opens
  the book. This is a knowingly accepted risk bounded to one column, in
  `settings/`, which is the user's private directory.
- `settings/opds.lua` is read **only**, never written.
