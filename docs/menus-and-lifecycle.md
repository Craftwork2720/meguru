# Menus, and plugin lifecycle

The menu rows and the curated config dialog, the plugin lifecycle facts worth not rediscovering, and the two plugins that replace Meguru's wraps.

Part of the design record; [CLAUDE.md](../CLAUDE.md) is the map.

## Reading options and the menus

Meguru books share KOReader's per-book `kopt_*` settings, so the bottom `ConfigDialog`
is **curated** rather than replaced: rows the engine does not implement (page margins,
auto-straighten, the reflow and zoom-matrix family) are dropped, because each would set
a value with no visible effect.

**The four tabs carry this plugin's icons, and a PDF's carry KOReader's**, which is
worth knowing before anyone "simplifies" it. `meguru/icons` gives the tabs names of
its own (`meguru.rotation`) and wraps `IconWidget` to resolve *only those names* to
the SVGs in `assets/icons/`; a PDF's dialog asks for the stock `appbar.*` names and
never reaches the branch, so one process-wide wrap touches no book but a Meguru
one. The alternative — dropping the files into the icon directory KOReader searches
first, `<data dir>/icons` — is the documented drop-in way and it is wrong twice
over: it replaces those icons for every document, and it makes a plugin write to the
user's storage at startup for something it already ships. The artwork itself is
optional, like the series row's: `Icons.tab` answers the stock name when a file is
missing, so an install without the SVGs draws KOReader's own icons, and `FALLBACK`
in that module is the table that says which of KOReader's each tab wears — our names
and KOReader's are not interchangeable, so a tab of ours has to name its own. The
Info entry below is the case that proves it: `info` is not an `appbar.*` name at all,
because KOReader has no `appbar.info` — the nearest glyph it draws for that meaning is
the bare `info` it gives `InfoMessage` — so a kind whose fallback was left unset would
silently wear `appbar.pageview`, which is the *Reading* tab's.

**Four tabs come back, and they are this plugin's own rather than stock's:**

- **Reading** — what a page turn does, how many pages are on the screen, and what a
  long-press does: the reading direction, the two-page view with its pair offset and
  its gutter beside it, and the panel view. See
  [docs/two-page-view.md](two-page-view.md).
- **Page** — the page's own shape: fit, *View mode* (stock's `page_scroll` row — how
  much of the page is on the screen, and whether the next one is beside it or below it
  — directly under *Fit*, the same question asked of the other axis) and crop.
- **Rotation** — rotation mode and the wide-page rotation.
- **Tone** — contrast, saturation, dithering and Derainbow: what the page *looks like*,
  where the three before it are about its shape. It had a tab of its own before the rows
  were regrouped, was folded into *Page* for a while, and is back — a reader who knows a
  PDF's contrast tab looks for these in one place, and the crop is not one of them. The
  first three are stock's own wiring; Derainbow is this plugin's and is the one row here
  that needs something installed beside us ([derainbow](derainbow.md)), below.

**One more icon sits beside them and is not a tab.** It opens the Info popup — the page,
how far through the book that is, and what the book says about itself — and it carries no
panel at all. The dialog offers no other way to put a *button* in that bar: the bar is
built from `config_options`, one `IconButton` per entry, and every one of them dispatches
the same `ShowConfigPanel` event. So the entry is added and the event is answered for it
— `installInfoPanel`, a wrap on the dialog *instance* installed in `curateConfigMenu`
right after `redirectDefaults`, and for the same reason (the dialog is built fresh inside
`orig`, so there is nothing to accumulate and nothing outliving the menu). The ordering
is load-bearing: `ReaderConfig:onShowConfigMenu` calls `onShowConfigPanel(last_panel_index)`
itself, to reopen on the remembered tab, and that call has to reach the stock method —
installed any earlier, a book that remembered its last tab would open its menu on the
popup. The wrapper shows the popup and returns true, and **writes no `panel_index`**: the
highlight stays on the tab the reader was on, dismissing the popup leaves them there, and
`config_panel_index` can never be saved as an index that names no panel. That is also why
the clamp below counts *panels* (`CURATED_PANELS`) rather than entries: a book read with
stock KOReader can carry an index anywhere up to that dialog's seven.

`meguru/ui/info` draws it, and it is the one surface in this plugin handed a plain table:
`Reader.infoFields` does the gathering, so that "the page on screen" keeps its single
answer here (`ui/reader`'s own `currentPage`, which the progress report is built on) and
the popup module requires no `meguru/` module at all. It shows the title, `Page N of M`, a
progress bar with the percentage under it, and the metadata the document can answer —
series, volume, author, language and server — the *kind* of server, `Kavita`, and not
the catalogue's own title, which is the key its credentials live under rather than
anything about the book — plus the ComicInfo summary for a
local `.cbz`. **Absent values are absent rows**: a streamed book has no author to show
and a local one no server, and neither is worth a row saying so.

**The description is the one row that is not just read.** It is capped and the excerpt
takes a tap, which opens the whole thing in KOReader's own `TextViewer` — the window the
file manager already opens a book's description in. The popup cannot scroll it: a
`ButtonDialog` scrolls only its button table and never the title group an added widget
lives in, so an unbounded description would push the Close button off the screen. The tap
needs a widget of its own for the same reason the cap exists — a `TextBoxWidget` takes no
events, so a tap on the text would fall through to the dialog's tap-outside and *close*
the popup, the opposite of what tapping the text means. `SummaryItem` in `ui/info` is that
widget, and it is laid out by the same rule as everything else here: it knows its own box
and claims the tap inside it.

**A local `.cbz` is not given its folder as a series**, and that is the one place this
popup refuses a value the plugin has to hand. `Local.seriesOf` — the same answer the ⋮
menu's "open next in series" rows are drawn on — names any folder holding two books of the
same extension, because for navigation that is exactly the question. As *metadata* it
answers `Series: Books` for a flat library, and on a folder that happens to be called
`empty` it produced a row that reads as a placeholder rather than as a name. What the
popup reports is what the file carries, so a `.cbz` with no ComicInfo has no series to
show — and the folder name stays where it means something, in the navigation rows.

Nothing is written and nothing is fetched — no sidecar key, no
marker field, no request — and dismissing it is `ButtonDialog`'s own tap-outside. The
popup consumes every tap while it is up, which is also why that icon cannot open a second
one.

**The split between *Page* and *Tone* is the one thing to keep straight when moving a
row**: the three tabs before *Tone* are about the *shape* of what is shown — how it is
turned, what is fitted, what is cut off — and *Tone* is the only one about the picture,
which is also where stock puts a PDF's. Stock's page-margin and reflow tabs have
nothing here to hold. Stock's tabs are still **where the rows come
from** (`buildCuratedOptions` lifts `rotation_mode` and `page_scroll` out of them by
name) — a tab is a place to find a row, not a shape to reuse — which is why the
lookup still happens even though none of stock's tab objects is handed back. The crop
is no longer lifted at all: its row is this plugin's, name and all (`Crop`, where
stock calls it "Page Crop", the tab already being the page's).

**The two rows under "Two pages" belong to it and are dimmed until it is on, and
that is as close to a group as this menu can come.** *The bottom menu has no
sub-items at all*: `sub_item_table` is the ⋮ menu's, `ui/widget/menu.lua` and
`touchmenu.lua` implement it, and `ConfigDialog` implements none of it. So a parent
and its children can be ordered and gated here, never indented — the ordering and
the two `enabled_func`s are the grouping.

The three stock tone rows leave `name` and `event` alone, so none has a handler in this
plugin at all: `ReaderKoptListener` writes the row's value into the configurable and
`ReaderView` is what acts on the event (see `docs/render-path.md` for what each does).
**The fourth is not stock's and is the exception**, below.

- **Contrast** is stock's contrast row with the presets stopped at 3.0, where stock's run
  to 50 for a badly scanned text page — the one curated row written here for its *values*
  rather than its wiring.
- **Saturation** is stock's `saturation` row unchanged, presets and all: `0.2` to `2.0`
  already describes what a reader would do to a comic page. It is offered only where the
  pages are decoded in colour — the one predicate `Image.colorEnabled()`, which is what
  the decode itself asks — because a saturation on a grayscale tile is a no-op
  (`adjustSaturation` returns early for the gray types).
- **Dithering** is stock's `sw_dithering` row unchanged, and it is **offered only where a
  dither can be honoured** — `Screen.fb_bpp == 8`, the same test `Image.colorEnabled`
  uses — because `BB_dither_blit_to` dithers an 8-bit destination and is a plain blit for
  every other one. Its default is neither on nor off but "whatever this device decided"
  (`Settings.dither` is deliberately unset), which is why the row reads back the value the
  page is actually drawn with rather than a stored one.
- **Derainbow** is this plugin's own row, on its own `MeguruDerainbowUpdate` event, and it
  is the only row in the whole dialog that can be **absent because something is not
  installed**: it needs `derainbowify.koplugin` beside us, and it is offered only where
  `Derainbow.available()` says its libraries are there *and* `Image.colorEnabled()` says
  the pages are decoded in colour. It cannot borrow that plugin's own switch — that one is
  inserted into `KoptOptions`, which a Meguru book never reads, and its handler reaches for
  a `rolling` view this reader does not have. See [derainbow](derainbow.md).

**The crop is one row of the *Page* tab, and it is `none` or
`auto`; `auto` is the whole of the feature: the margin box, the printed page number and the
blank-page rule (`document.lua`'s `getPageBBox`). "Page Number Crop" and "No crop on
blank pages" used to be rows of their own — the stock ones `pagenumbercrop.koplugin`
injects when it is installed, this plugin's own copies when it is not — and folding them
in is deliberate: what a reader wants from this tab is "crop the page or not", and the
three rules are what cropping a page means here. The cost is that neither can be had
alone, and that a book carrying `kopt_page_number_crop_auto` or `kopt_no_crop_blank_pages`
from an earlier version keeps the key and gets the rule back — nothing reads either again.

**The *Panel view* row — the last of the *Reading* tab — is the first row in this dialog
that is not one value in one key.** Its three views are the book's `kopt_panel_view` — the switch inside the
panel viewer writes the same one, so the two controls cannot disagree — and its fourth answer,
`off`, is KOReader's own per-book `panel_zoom_enabled`, which is a different question with a
different owner. `current_func` reads the two as one value and `onMeguruPanelViewUpdate` writes
them as one, including putting the book's view back into the view key when `off` is chosen,
because the dialog has already written the chosen value there by the time the row's event fires.
It is seeded from the `panel_view` preference like every other row here, and its long-press sets
that preference as on every other row — with one value it refuses: `off` is not a view, so no
preference could hold it, and `redirectDefaults` answers for that case with a notification
instead of writing a word nothing reads. Whether there is a panel view is the per-file answer by
design, and that is the one place in this dialog where "set as default" is declined rather than
performed.

**One row is also offered to KOReader's gesture editor**, where a reader binds a tap, a swipe or a key to it instead: *Toggle pair offset (two-page view)*, registered by `main.lua` as `meguru_pair_offset` and listed under **Fixed layout documents**, beside *Toggle page flipping* and *Toggle panel zoom*. It fires `MeguruPairOffsetToggle`, and the handler for it is installed per reader like every other handler in `ui/reader.lua` — which is what makes the action safe to leave bound outside a Meguru book: the event arrives, no instance has the method, and nothing happens. The section is a list rather than a gate, so every fixed-layout document is *offered* it for the same reason.

Its behaviour is the row's, exactly: off when the run the reader is in is already offset, anchored *here* when it is not. The two write through one function (`setSpreadOffset`) and announce through one (`spreadOffsetNotice`), so a gesture and a menu row cannot come to describe the same setting differently. Anything else here could be offered the same way — `Dispatcher:registerAction` is one table per action and the handler is one method — but a gesture is worth binding for the row a reader reaches for *while looking at the page*, and that is this one.

The one thing that must not be missed: KOReader's stock "set as default" writes a
**global** `G_reader_settings["kopt_<name>"]`, which would leak a choice made while
reading a stream into every PDF opened afterwards. `ui/reader.lua` redirects it onto
the plugin preference and swallows rows the plugin has no preference for — that
redirection is the reason that file exists.

Invariants when touching these rows:

- **A row's `values` stay in the row's own domain.** `trim_page` is `{3,1}`
  (none/auto), `rotate_wide_pages` is `0/1/2`, the toggles are `0/1`, `fit` is a
  string. `seedRowValue` copies the stored value through verbatim for exactly this
  reason: `0` is a valid choice *and* is truthy in Lua, so any normalising step
  (`value and 1 or 0`) silently turns "off" into "on" and "crop: none" into "crop:
  auto".
- **`sorting_hint` must name an existing menu item, in that surface's own order
  table.** `menusorter` does `findById(...)` and then indexes the result without
  checking, so a hint naming nothing throws out of the entire menu build and takes
  every other plugin's row with it. `ui/menu.lua` picks it in one place
  (`showUnderTools`, which falls back to no hint rather than a crash), and the hint is
  `"tools"`, which resolves unconditionally in both order tables.
- **A hint alone does not place a row at all.** It is appended to the end of that
  page's row list. Naming the id in that page's order list is what decides otherwise,
  and `showUnderTools` does it for both surfaces, putting `meguru` **directly above
  `read_timer`** — entry 1 of the stock list on both surfaces, so that is the head of
  the page (and index 1, where `read_timer` would have been, on a build without it).
  Position is named by neighbour rather than by index on purpose — everything above
  this row is whatever the user has enabled, so an index would land somewhere different
  on the next device. `profiles` was the neighbour before and sits far enough down the
  list to have stopped being a useful landmark.
- **`separator` and `checked_func` are `TouchMenu`-only; `mandatory` is
  plain-`Menu`-only.** Both menus Meguru registers are `TouchMenu`s on a touch device,
  so both fields are usable in these rows. `text_func` renders on either, which is why
  the destination rows carry their state in the text rather than in a `mandatory` value
  slot.
- **A `Settings` submenu on both surfaces** — the reader's holds the rows that are about
  a book being read (auto-open next in series, report reading progress, hide status bar,
  save folder, subfolder per server, `Covers for folders`, default reader for `.cbz`,
  check for updates), the FileManager's the ones that are not. **No panel row is among
  them**, and that is a decision rather than an omission: the panel choices are per book,
  and a preference row here would be a plugin-wide answer to a per-book question. Two live
  in the viewer's own button row, where the reader can see what they do while looking at
  the page they do it to, and the view is the bottom dialog's *Panel view* row — see
  `docs/panel-zoom.md`. The FileManager's depth is a deliberate
  cost, paid so the two menus read the same. No `sorting_hint` exists below the top-level
  `meguru` item — the sorter only ever orders a page's own rows.
- **`Covers for folders` is the one thing below `Settings`, and it is an exception
  rather than a precedent.** Its three rows are switches for one feature, and as flat
  rows they would take `Settings` from six entries to nine while naming servers instead
  of the thing they belong to. The level is bought back by the row above them saying
  what the group *is* — which is the whole job `Settings` does one level up, and the
  reason "one level deep" existed. A second such submenu should have to make the same
  argument. **The position report is the case that did not make it**: one server accepts
  a write, so its row is flat — a submenu would cost a tap to say less than the row says
  by itself. A second driver with a write path converts it into one, and that is the
  argument it will have to make.
- **The separator is *under* the row that carries it** (`touchmenu.lua:714`), and is
  dropped when that row is last on a page (`touchmenu.lua:713`) — so a separator is a
  hint about the list, never a guarantee about the screen. Two lines split `Settings`
  into its three groups, and each sits on the row that *ends* a group: `Hide status
  bar` and `Subfolder per server`. The FileManager gets both but only the second has
  anything above it there.
- **The FileManager's `Meguru` submenu carries nothing but that `Settings` row.** Both
  surfaces use the key `meguru`, which is safe because the two `menu_items` tables are
  per-surface and never shared, and `Meguru:addToMainMenu` dispatches on whether a
  document is open — so only one is ever written. A saved menu order in `settings/`
  then means the same thing on both.
- **`meguru/association.lua` owns Meguru being the reader for `.cbz`, and it is a
  *claim* rather than a preference.** Meguru registers `cbz` at **weight 1**
  (`main.lua`), the lowest, so registration alone leaves MuPDF the default and this
  engine reachable only through "Open with…". The claim is KOReader's own **file-type
  association** — the same `G_reader_settings["provider"]["cbz"] = "meguru"` the stock
  dialog's "Always open with…" checkbox writes, read by `DocumentRegistry:getProvider`
  *before* it falls back to the highest-weighted provider
  (`documentregistry.lua:91-101`), which is the whole of why a weight-1 provider can
  win. Releasing is the same call with no provider, i.e. what "Reset default for …
  files" does.
  **It is claimed once, on first run** (`Association.claimOnce`, called from
  `registerProvider`), and given back from the menu row. The record of that is
  `Settings.cbz_default_claimed`, and the record is load-bearing: releasing leaves
  `provider.cbz` **absent**, which is byte for byte what a device that never chose a
  reader looks like — so "no association" cannot be read as "not yet claimed", and a
  rule of that shape would re-claim the extension on the next start after the reader
  turned the row off. The one case the record cannot tell apart is a device upgrading
  from the build that had the row and no record, where the claim is made once more; a
  one-tap surprise beats a row that turns itself back on forever.
  Two traps in the API itself: it takes a **file**, not an extension (it reads the
  suffix off the name, so the module passes a name with no file behind it), and
  `setProvider(file, nil, true)` means *reset* — so a provider the registry does not
  know yet would silently do the opposite of what was asked, which is why the claim
  looks it up first and refuses loudly. A per-file choice made in "Open with…" still
  wins: `getAssociatedProviderKey` reads the sidecar before the file type.

## Plugin lifecycle facts worth not rediscovering

- `ReaderUI:showReaderCoroutine` builds a **new** `ReaderUI`, so the plugin loop
  re-runs and instances are fresh for every document. `Reader.install` therefore runs
  once per book automatically.
- Plugin **modules** load once per process (`PluginLoader.enabled_plugins` is cached
  and never reset), so module-level flags persist for the whole session. That is what
  makes `Reader.installStatusBarHook`'s once-per-process guard correct, and what makes
  the `DocumentRegistry:addProvider` guard necessary — `addProvider` only ever appends,
  so a second call would list the provider twice.
- **The plugin's `ReadSettings` runs *after* the reader has derived the page's box, so
  `Defaults.apply` ends by firing `ReZoom`.** `ReaderView`/`ReaderZooming` derive the box
  for the page a book opens on inside their own `ReadSettings` handler — that is where
  `use_bbox` is set and the margin crop applied — and the core modules are dispatched
  before the plugins. `trim_page` is still at its stock value at that moment — the row's
  own default, or the *global* `kopt_trim_page` — because this plugin writes a reader's
  choice into the **book** and never into the global `kopt_*` that would otherwise have
  filled the configurable. So the page a book opened on came back **uncropped** (every
  crop rule rides that one row now), until something derived the box again: the crop
  appeared on the next page turned to, and on the first page only once a turn back had
  re-derived its box. `ReZoom` is the reader's own "the box may have changed" verb (the
  one the crop rows fire), and it lands before the first paint, so nothing is drawn
  twice. **Anything else seeded here that the geometry depends on needs the same
  treatment.** A book opened a *second* time does not show the fault, and that is the same
  mechanism rather than an exception: its own stored `kopt_trim_page` is loaded into the
  configurable before the derivation, so only a book's **first** open has the row's
  default standing where the reader's choice should be.
- **`pagenumbercrop.koplugin` patches a Meguru document in its own init, and this plugin
  takes the crop seam back on `ReaderReady`.** That plugin's init gates on
  `document.koptinterface` — the sentinel this engine exposes for `ReaderConfig` — and then
  assigns `document.getPageBBox` **onto the instance**, seeds its own `_pagenum_cache`
  tables, and wraps `paging.onPageUpdate` and `view.onSetScrollMode`.
  `Reader.install` runs on `ReaderReady`, later than every plugin's init, and calls
  `takeBackPageBBox`: clearing the instance field is the whole restore, because ours is the
  class method. Its memo tables are reset to **empty tables** rather than removed, because
  its own `_pagenum_strip`, `_page_mostly_blank` and Dispatcher action still index them —
  a nil there would be an index error raised inside a gesture, and the empty tables also
  keep that plugin's page-turn wrapper working, warming the next page with *its* analysis
  into *its* tables where nobody reads it (the price of not unwrapping a closure). Two
  consequences worth keeping: its **wide-page rotation stays**, since those two wrappers
  cannot be unwrapped — `ui/reader.lua` installs this plugin's own rotation only for a
  document that plugin has not patched, reading its markers at install time; and its
  **`rotate_wide_pages` row stays**, because that one drives that rotation and is a
  `KoptOptions` entry the curated dialog reads from there in preference to its own. Its
  two crop toggles are not read by anything here any more — they are rules of this
  engine, folded into *Crop* (`document.lua`'s getPageBBox). The take-back fires
  `ReZoom` when it took something back — the box for the page a book opens on is derived
  during `ReadSettings`, with the plugin's wrapper already in place.
- Every menu surface Meguru writes is a `TouchMenu`; the plugin no longer has a
  plain-`Menu` surface of its own.
- `C_` is **not** a global. Every core file declares `local C_ = _.pgettext`; a plugin
  file that omits it gets a nil call only when a row is built.

Three more, about the browser rather than the lifecycle.

**`OPDSParser:parse` returns the document wrapped under its own root element.**
`createFlatXTable` starts from `{}` and assigns the root's children under the root's
*name*, so an Atom feed comes back as `{ feed = { entry = {...}, author = {...} } }`
with nothing at the top level. Reading `.entry` or `.author` off the raw parse result
therefore finds nothing — and silently, because "a feed with no entries" and "a feed
that was never unwrapped" are the same nil. `Net.feedFrom` is the one unwrap, used by
both `Net.parseFeed` and `ui/open.lua`; the built-in browser compensates with
`local feed = catalog.feed or catalog`.

**`OPDSBrowser:parseFeed` parses more than browsable feeds.**
`genItemTableFromCatalog` parses the catalog's OpenSearch descriptor through that same
method, on the same navigation, immediately *after* the real feed. So a feed-retention
rule of "record it if it has entries, clear it otherwise" recorded the series feed and
cleared it again in the same breath. `ui/open.lua`'s `noteFeed` ignores a parse that
is not a feed of entries.

**The row at the top of a series feed is added by wrapping `genItemTableFromURL`, not
`switchItemTable`.** Both were tried; only the first is right. `switchItemTable` is
switched from four places — a navigation, a pagination append, a catalog edit on the
root list, and a search — and only one of them is a series feed, so the row appeared on
the others (a search result list, most visibly). `genItemTableFromURL` is *handed the
URL*, and the URL is what tells the four apart. The decision is made where the evidence
is rather than reconstructed from how the switch was called.

A row with no `acquisitions` is read by `onMenuSelect` as a **catalog link**, and it
navigates to the row's `url` — so a row of ours must carry a marker field and have
`onMenuSelect` wrapped to intercept it. The row buys nothing on its own.

The row is offered only when **every** entry of the feed discovers to the same series.
A feed listing *series* has entries with no stream at all, so they fail `discover` and
the row is not offered — which is why it appears on a list of a series' volumes and
nowhere else. It opens the **first unread** volume, ordered by the number
`Naming.deriveSeries` pulls from each title rather than by feed order, because Suwayomi
browses newest-first and feed order there is the reverse of reading order.

That fresh path also carries the "never silently sync the wrong series" guard: an entry
opened from `on-deck` or `recently-added` comes from a feed listing other series too,
so entries are kept only when `driver.discover` places them in the series being opened,
and the parser sees nothing else. **Filter, never reject the whole feed** — that was
the first version and it was wrong. A Kavita series feed also carries entries with no
stream link (a special, a cover-only row) that `discover` cannot place, so one of them
was enough to send every open back to a stale answer, producing exactly the symptom the
fresh read exists to remove.

### Another plugin may replace the wraps, so they are installed twice

**The four `OPDSBrowser` wraps are installed at plugin load *and* again every time a
browser is constructed.** The second one is the load-bearing one, and the reason is a
plugin called `zenos.koplugin`, which ships a patch of the OPDS browser.

The mechanics are about load order, and none of it is specific to zen-os.
`pluginloader.lua:289` sorts the enabled plugins **by path** before instantiating them,
so `meguru.koplugin` loads before `zenos.koplugin`. Meguru wraps first; zen-os then
replaces `OPDSBrowser.showDownloads` and `OPDSBrowser.parseFeed` **wholesale, without
calling the original** (its `opds.lua:1529` and `:1198`), once per process behind its own
`_zen_opds_patched` flag. Methods a later plugin replaces are methods our wrap is
silently gone from — and nothing reports it, because the browser still works.

**Losing `parseFeed` costs three features, not one**, and that is the part worth reading
before touching this. It is the only writer of `ui/open.lua`'s `last_feed`, and
`last_feed` is what the row above a series feed is built from (`seriesRow` → `feedSeries`
reads `last_feed[name]`) *and* what `openAsBook` reads for `ctx.url` — the feed the
reader is browsing, which for **Komga** is the only place a series id exists at all.

| what is lost | why |
|---|---|
| the button in the download dialog | the wrap on `showDownloads` is gone |
| the row above a series feed | `noteFeed` never runs, so `last_feed` is empty |
| Komga series attribution | `ctx.url` is nil, so `discover` refuses the entry |

The other two wraps — `genItemTableFromURL` and `onMenuSelect` — survive, because zen-os
does not override them; but with `last_feed` empty there is no row for them to place or
intercept. `ReaderUI:showReader` is on a different class and no OPDS patch touches it, so
a marker opened from the file manager or History was never affected.

**`init` is the seam, and it is order-proof in both directions.** Constructing a browser
is the last moment at which the class is settled: every plugin has loaded, every patch has
been applied, and nothing re-patches afterwards. A class-level re-install also reaches the
class the browser actually inherits from, where one done on the instance would not be the
same fix at all. It chains to the original, so it survives being wrapped by someone else:
`OPDSBrowser.init` is `Menu:init` through `__index` in stock, and a foreign patch captures
our wrap off the class and calls it — which is exactly why ours runs at all in that case.
An event was rejected instead of `init` because the OPDS plugin is not on the `UIManager`
stack and so never receives a broadcast.

One sentinel guards it, and **it is per method rather than for the set** — which is a
distinction that shipped as a bug. Four module-locals hold the wrapper we installed for
each method, and `installBrowserWraps` re-wraps only those that are no longer carrying it.
Asked this of the whole set at once — "is *any* of ours missing" — the second pass
re-wrapped the methods the other plugin had *never taken*, so `genItemTableFromURL`
carried two layers of our wrapper and **the row above a series feed appeared twice**. The
same plugin takes some methods and leaves others, so the question has to be asked per
method. That also makes a repeat a no-op (without it the second pass would call `noteFeed`
twice) and makes the whole thing **self-healing**, since any later replacement is repaired
at the next construction. The first repair logs once, at `info`:
`OPDSBrowser re-patched since load; OPDS hooks re-installed`. It deliberately **does not
name the plugin that did it**: detecting one by its private fields would tie this repair
to a foreign implementation we do not control, and the useful fact is that our hooks were
replaced, not by whom.

**Nothing else had to change, and that is the check that this is the right seam.**
`Open.injectBookRow` works against zen-os's dialog unchanged — it sets
`self.download_dialog` (`opds.lua:1738`) with a `.buttons` array and has
`ButtonDialog:reinit()`. **The row goes in at index 1**, above everything the
dialog offers, with a separator under it.

That position is the point, not a preference: the row used to be inserted just
above the dialog's *last* row, which on a build that leads with a download button
and a description made the action this plugin exists for the last thing a reader
reached — it read as an afterthought to the download rather than the reason the
dialog is open. It is also the position that costs nothing to hold: reaching it
by moving the last row meant the row's place depended on the dialog ending with
the row the code expected, and nothing about the rows already present is assumed
any more. The row above a feed renders too, because
zen-os's item widgets read `entry.title or entry.text` (`opds.lua:456`) and our row
carries `text`. Its own "Page stream" buttons, which stream PSE into KOReader's *native*
reader through `opdspse`, are a different feature and are left alone.

**One thing the row does have to carry, and it took a device to find.** A browser that
draws covers keys on `entry.cover_url` alone (`opds.lua:848`, `:916`) — and fills that
field itself in `genItemTableFromCatalog` (`opds.lua:1204`), which runs *inside* the call
the row is appended after. A row added there is one that pass has already gone by, so it
is the only row in a list of covers with none. `Open.seriesRow` therefore sets
`cover_bb` — a bitmap of the plugin's **own** mark, from `meguru/rowcover`, and
deliberately **not** the series' artwork and **not** `cover_url`:

- **Not the series' artwork**, because this row is not a book. Artwork published for the
  series, drawn beside a column of real volumes, reads as one more volume rather than as
  the thing that opens the series.
- **Not `cover_url`**, which is the field a browser *fetches*: that would put an HTTP
  request on this row, on a page already making one request per book for its cover. A
  `cover_bb` is already decoded, so the row costs the network nothing.

Neither `thumbnail` nor `image` would do either: those are what zen-os *converts* into
`cover_url` in that same pass, so setting them is asking a pass that has already run to
run again. And the insertion point must not be moved earlier to reach it — `genItemTableFromURL`
is the seam `switchItemTable` was replaced by precisely because the URL tells a series feed
apart from a search result and a pagination append, and moving it back re-opens that, for a
cover.

The repair a reader has if any of this ever breaks again is the same one a mis-sniffed
kind has: nothing in the UI reaches it, so it is fixed in `hook.lua` or not at all.

**The reader's bottom menu is the same story in a second place, and it is
`rakuyomi.koplugin` that tells it.** Its `MangaReader:addRakuOptionsToReader`
ends by assigning `ui.config.onShowConfigMenu` on the **instance**, wholesale and
without calling the original — its own comment reads `--patch
frontend/apps/reader/modules/readerconfig.lua` — and it does it from a
`registerPostInitCallback`, i.e. after every plugin has loaded. Plugins load by
sorted path, so `meguru.koplugin` is always *before* `rakuyomi.koplugin`: the wrap
`curateConfigMenu` installs at our init is gone before the reader is up, the menu
shows every stock row Meguru was supposed to drop, and nothing reports it.

Three things make the repair what it is, and each differs from the OPDSBrowser one:

- **The guard is the wrapper, not a flag.** `config._meguru_curated` held `true`,
  which stays true after a foreign assignment — so it could not tell "still ours"
  from "replaced". It holds the function we installed now, and a replacement is
  simply a different value in that field.
- **Per instance, never per class.** The replacement is an instance field, which
  shadows the class, so a class-level wrap would be invisible.
- **The seam is `registerPostReaderReadyCallback`.** `ReaderUI:init` fires
  `ReaderReady` and only *then* runs that list (`readerui.lua:517-522`), while a
  post-init callback has already run by the time init returns — so this is later
  than the thing it repairs, provably rather than by appearance. This is the
  `genItemTableFromURL`-not-`switchItemTable` lesson again: the decision is made
  where the evidence is.

Chaining is the other half, and it is why this is not a fight: `orig` is whatever
is in the field *now*, so Rakuyomi's own chapter bar among its buttons survives
ours. The first repair logs once per process —
`the config menu was replaced since load; curation re-installed` — and, as with
the OPDS repair, it deliberately does not name the plugin that did it.

