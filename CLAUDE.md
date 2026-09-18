# meguru

A KOReader plugin that turns OPDS-PSE page streams (Kavita, Suwayomi) into
ordinary KOReader "books". Each book is a small on-disk **marker** file; the
pages come off the network one at a time as they are read. It is a from-scratch
successor to the `meguru.koplugin` beside it — which is the reference for
behaviour, the fallback if this one misbehaves, and **not to be modified**.

## Environment

These are fixed and shape most of the design:

- **Lua 5.1 / LuaJIT.** No `//`, no bitwise operators, no `goto`. The device is
  the only place this code runs.
- **No test framework and no linter.** Verification is manual, in a running
  KOReader. `tools/check.py` (see Development) is the automated guard, covering
  eleven failure modes.
- **Reuse KOReader's own machinery** rather than rebuilding it: `LuaSettings`,
  `DocSettings`, `DocumentRegistry`, and the built-in `plugins/opds.koplugin` for
  Atom parsing and the browser UI. That plugin is **read only** — wrapped at
  runtime, never edited.
- **Module names are global**, so everything lives under `meguru/`. Always
  `require("meguru/feed")`, never `require("meguru.feed")`: both resolve to the
  same file but occupy two different `package.loaded` keys.
- `require` of `opdsbrowser` / `opdsparser` must be **lazy, at the call site** —
  `pluginloader.lua` only adds plugin directories to `package.path` after the
  plugin itself has loaded.

## Layout

```
_meta.lua                 plugin metadata
main.lua                  plugin class: provider registration, menu dispatch, reader install

meguru/
  paths.lua               every path: markers, and the last-resort folder
  fs.lua                  filesystem predicates, directory creation, one raw write
  settings.lua            plugin-wide preferences in G_reader_settings
  association.lua         Meguru's claim on .cbz: the file-type reader association
  sources.lua             read-only view on settings/opds.lua (catalogs + credentials)
  net.lua                 HTTP: GET, the one PATCH, feed fetch + parse
  naming.lua              sanitizeComponent / deriveSeries / glyph / identity digest
  local.lua               the series a .cbz's folder and file name imply
  comicinfo.lua           the metadata a .cbz carries about itself
  marker.lua              marker read/write, naming, collision resolution, series context
  credential.lua          what a credential looks like in a URL: redact / restore
  seriescover.lua         the series' artwork, written once into its folder
  rowcover.lua            the "Meguru this series" row's own artwork, decoded once
  progress.lua            the reader's position, sent back to the server
  pse.lua                 OPDS-PSE: link extraction, template -> URL, page fetch
  feed.lua                reading a series feed: the rel=next walk, identity, order,
                          neighbour
  panel.lua               the panels on a page, and the order they are read in
  viewport.lua            the window over a page, for the panel view that crops nothing
  hook.lua                runtime wraps on OPDSBrowser (sniff, "Meguru this series")
  updater.lua             GitHub releases: check for one, download it, install it

  driver/
    base.lua              driver registry + pure shared helpers
    suwayomi.lua
    kavita.lua
    komga.lua

  doc/
    document.lua          Document subclass: the reading engine
    image.lua             MuPDF decoding with a size cap
    defaults.lua          per-book seeding of kopt_* from plugin preferences

  ui/
    open.lua              "Meguru this series": resume dialog, marker write, open
    reader.lua            everything grafted onto a running ReaderUI
    panelzoom.lua         the panel sequence viewer: nav, pre-warm, page boundary
    menu.lua              the two menu surfaces

assets/
  meguru-this-series.png  optional; the cover drawn on the series row

.github/workflows/release.yml   a tag builds meguru.koplugin.zip and publishes it
```

`assets/meguru-this-series.png` is the one file the plugin ships rather than
writes, and it is **optional** — `meguru/rowcover` answers nil without it and the
browser draws its ordinary placeholder. It is portrait, authored at 2:3 (what
zen-os fits a cover into by default); any size decodes, and a larger one costs
only bytes on disk. The plugin has had artwork before and it was deleted on
purpose — an error-page drawing whose headline named the wrong fault — so the
distinction is worth keeping: this file is the row's *identity*, not a claim
about something that went wrong.

`tools/check.py` is a development aid, not part of the plugin.

Not yet written: `driver/generic.lua` — the `kind = NULL` driver that can
only discover a series by title heuristic and cannot build a canonical
`catalogURL`, so there is no feed to walk for a neighbour. Until `generic.lua`
exists, an unrecognised server is handled by the absence of a driver rather than
by a driver that returns nothing useful.

**Nothing is written to disk but markers** — and one exception, named here
because the sentence above it is the kind that gets quoted: `meguru/seriescover`
leaves a `.cover.jpg` in a series folder, for whatever *outside* KOReader reads
it. It is not a cache and nothing reads it back; KOReader will not display it
either (`coverbrowser` draws a directory as a name and a count, and never looks
for a file beside a document), and the plugin never removes it — turning a server
off in the menu stops new files and leaves what is already written.

**The counterpart is true of the network, and it is the one thing sent outward.**
`meguru/progress` sends the reader's position back to the server the book came
from — **Komga only**, one switch per server in ⋮ → Meguru → Settings, on by
default. Suwayomi is already told by its own page fetches (its stream template
carries `?updateProgress=true`) and Kavita's write API wants a login this plugin
does not make, so neither is given a report. It is a position and not a book: a
page number goes out, the credential rides in the Basic header a page
fetch already sends, and nothing the server answers is written anywhere. See
`docs/reading-position.md`.

**The file's name is not its format, and the three servers disagree** — worth
knowing before someone "fixes" the extension:

| server | where the series artwork comes from | what arrives |
|---|---|---|
| Suwayomi | feed-level image on the chapter list | WebP 400x600 |
| Kavita | feed-level image on the series feed | **WebP** 639x908 |
| Komga | `driver.seriesCover` → REST, because OPDS has none | JPEG 211x300 |

Kavita's *volume* cover is a JPEG and its *series* cover is not — an earlier
version of this document and of `seriescover.lua` got that backwards and used it
to justify a Suwayomi-only rule. Which servers get the file is now the reader's
choice, in ⋮ → Meguru → Settings → `Covers for folders`, one switch per server,
all on by default.

Leaving that aside: there is no page cache, no cover cache and no database.
Pages live in a small RAM LRU, a cover is refetched on every call, and the panel
lists a long-press produces live in a four-entry RAM LRU on the document itself,
so they are dropped with the book.

`meguru.sqlite3` may still be sitting in `settings/` from a version that had one,
and `cache/meguru/pages` and `.../covers` from a version that wrote them. Nothing
reads them and nothing sweeps them; delete them by hand once. `Paths.cacheDir`
itself survives: it is the last-resort folder for a marker when the home folder
is unusable (`Marker.homeDir`).

The dependency graph is a DAG with no cycles and **exactly one lazy edge**:
`feed.lua` requires `meguru/naming` inside `Feed.ordered`, because the ordering is
the one thing both entry points share and an edge at load time would have made it
circular. (`ui/network/manager` is reached the same lazy way by `doc/document`
and `seriescover`, and `ui/renderimage` by `rowcover`, but they are KOReader's
modules, not ours — they are not edges in this graph, and each is deferred for a
reason of its own: the network manager is a *device* state that need not exist
where these modules are loaded, and the image backends are dead weight until a
row's artwork has actually been found on disk.) `ui/panelzoom` requires no `meguru/` module at all — it is handed panels
as arguments, and with them the reading direction and the rotation direction, both
as plain strings: the *domain* of those settings stays in `ui/reader` and the viewer
is told the word. The edges that do exist between the panel modules are `ui/reader` ->
`ui/panelzoom`, `doc/document` -> `panel`, `ui/panelzoom` -> `viewport`, and `panel` ->
`doc/image`. `doc/document`
and `ui/reader` both require `meguru/local` eagerly — it is a module of ours, it
loads nothing expensive, and `ui/menu` reaches it through `ui/reader` rather than
directly so the guard that answers "is this book a local one" exists once. The one
directory listing in the plugin lives there, and it is `util.findFiles`, KOReader's
own — not an edge in this graph, for the reason the network manager is not one
either.


## Where the detail lives

This file is the map: the environment, the file layout, and a way into the rest. The
design record itself was moved out of it, one subject per file, so that neither a reader
nor an agent has to load 3500 lines to find one answer. Read the one you need.

- [docs/design-decisions.md](docs/design-decisions.md) — why the design is what it is: no
  local catalog, a marker carrying only its series' identity, and what two earlier designs
  cost.
- [docs/series-state-and-markers.md](docs/series-state-and-markers.md) — the marker's
  fields, the identity rules behind `item_key`, and what a marker does and does not store.
- [docs/render-path.md](docs/render-path.md) — how a page is decoded, painted and cached;
  the four log lines; and what a page that could not be loaded says.
- [docs/driver-notes.md](docs/driver-notes.md) — reading a series feed (the `rel=next`
  walk, ordering, neighbours) and what Kavita, Suwayomi and Komga each do differently.
- [docs/opening-a-book.md](docs/opening-a-book.md) — where an open starts: the resume
  dialog, the server's own position, the silent opens, and the marker planned before it is
  written.
- [docs/reading-position.md](docs/reading-position.md) — the same position going the other
  way: what is sent, when, and the one rule that keeps a server from being walked back.
- [docs/local-cbz.md](docs/local-cbz.md) — a folder of `.cbz` treated as a series: the
  natural sort, and why the name grammar was removed.
- [docs/panel-zoom.md](docs/panel-zoom.md) — the panel preference and its stock cascade,
  the detector, and the three views a long-press can open.
- [docs/menus-and-lifecycle.md](docs/menus-and-lifecycle.md) — the menu rows, the curated
  config dialog, the plugin lifecycle facts, and the plugins that replace our wraps.
- [docs/updating.md](docs/updating.md) — the GitHub release updater: the one artifact both
  ends name, the install transaction, and what is remembered between checks.
- [docs/development.md](docs/development.md) — `tools/check.py`'s eleven passes, and the
  on-device checklist for verifying a change.
- [docs/known-issues.md](docs/known-issues.md) — open questions and unverified
  assumptions, each with what would settle it.
- [docs/security-notes.md](docs/security-notes.md) — how credentials are redacted in
  markers and log lines, and what is deliberately never scrubbed.
- [PROTOCOL.md](PROTOCOL.md) — wire-format findings captured from live servers; where that
  document and an assumption disagree, the observation wins.
