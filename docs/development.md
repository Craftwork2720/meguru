# Development and verification

`tools/check.py`'s eleven passes and what each has actually caught, and the step-by-step checklist for verifying a change on a device.

Part of the design record; [CLAUDE.md](../CLAUDE.md) is the map.

## Development

```
python tools/check.py       # structure of the Lua
```

There is no Lua interpreter on the development machine, so `check.py` stands in for
one. It runs eleven passes:

1. **Block balance** — `function`/`if`/`for`/`while`/`do` against `end`/`until`, over
   comment- and string-stripped source.
2. **Cross-module member references** — every `Module.member` where `Module` came from
   a `require("meguru/...")` binding is checked against the members that module
   actually defines. A require naming a module that **does not exist** is an error
   rather than a skip: it used to fall through silently, which meant that once a module
   was deleted every reference to it became *unchecked* instead of reported — the worst
   possible failure for a pass whose whole job is catching references to things that no
   longer exist.
3. **Unbound module tables** — `Geom:new{...}` where `Geom` is never bound in the file.
4. **Lowercase calls not yet bound** — `handToReader(host, file)` where the only binding
   is a `local function` *below* the call. **Position is the whole pass**: a `local`
   enters scope from its own statement onwards, so a call above it resolves the name as
   a global and finds nil, while the binding is sitting right there for any
   position-blind check to find.
5. **A name read as a *value* that is not bound at or above its line** —
   `pcall(renderMuPDFPage, ...)`. Passes 3 and 4 both key on the shape of the *use*,
   so a name handed over as an argument or an operand slips past both. Its own trap is
   the **list of words it lets precede a value-use**: only forms whose next token is a
   binding or a keyword belong there. `return`, `not`, `and` and `or` were in that list
   and are not — what follows each is read — so `if not lead_index then` with the name
   misspelled was a name read as a value, bound nowhere and reported by nothing. The
   typo was injected while self-testing `meguru/local` and it came back clean, which is
   how the hole was found.
   **The pass was position-blind and that cost a shipped feature.** It asked only
   whether a name was bound *somewhere*, on the stated grounds that claiming the
   positional half "would report every forward reference in the codebase" — which
   confused two things. A forward reference to a `local` is not a legitimate pattern in
   Lua; Lua resolves a name at compile time against the locals in scope at that point
   in the source, so a `local function` defined *below* its use is a global read, and
   the pattern that does work — mutual recursion — declares `local b` before its first
   use and is therefore bound above it. `maskToQuad` was added below
   `Image.renderRegion`, which called it through `pcall(maskToQuad, ...)`; the pcall
   handler logged `panel crop mask failed: attempt to call a nil value` and the panel
   crop silently went unmasked on every page. It is now check 4's rule applied to
   value-uses as well, and **adding it reports nothing anywhere in the tree** — which
   is the measurement that settles the old objection rather than an argument about it.
   Six shapes were injected to self-test it: the forward reference (with and without a
   call), a forward declaration, a name bound nowhere, and the two shapes checks 4 and
   6 own.
6. **A lowercase name reached through a `.` or a `:`** — `data:byte(off + 1)` with no
   `local data` anywhere.
7. **The marker's field list.** `Marker.new` is the contract between the code that
   writes a marker and the code that reads one, and Lua checks neither end. A field read
   off a descriptor that `Marker.new` does not copy is nil on the device — and nil is a
   legitimate answer for several of them, so the failure surfaces as a feature that
   quietly does nothing rather than as an error.
8. **The same contract for a book's series**, against the one definition of that shape
   (`Marker.seriesContext`). Pass 7's failure, in a second place, and it shipped twice
   before the pass existed: `Marker.dirFor` read `series.name` while every caller passed
   a context with `series_name`, so **no series folder was ever created**; and
   `freshResumeTarget` filtered on `series.remote_id`, so the `▶` server-position button
   silently never appeared — and "the server has no opinion" is a legitimate state, so
   nothing reported it either.
9. **A `_()` call inside a `for _` loop.** Every file here opens with
   `local _ = require("gettext")` and every discarded loop index is written `_`, and
   those two conventions collide the moment a message is needed inside the loop: `_`
   is the *counter* for the length of the body, so the call is an attempt to call a
   number. **This one shipped**, in `meguru/updater`'s verification step, and was found
   by a device. Passes 5 and 6 both skip `_` by name — correctly, it is a global they
   must not report — so nothing covered the shape, and nothing could: the loop is
   idiomatic, the message is a message, and neither is wrong on its own.
   The loop's extent has to be found by **matching blocks**. A first attempt scanned
   forward for the next `end`, flagged two `for _` loops in `meguru/ui/menu` whose
   `_()` is *after* the loop, and was believed for a minute — which is the ordinary
   fate of this kind of check, and why it is worth saying that a body full of nested
   `function ... end` is the case that tells a real matcher from a rough one.
10. **An assignment to `_`**, which is pass 9's collision seen from the other side. The
   same two conventions — `_` is gettext, `_` is a discarded value — meet in
   `panels, _, reason = doc:getPanelsFromPage(page, mode)`, and because that binding is
   **not** a `local` it writes straight through to the file's translate function:
   `_` became that call's second return, `accepted`, a boolean. **This one shipped too,
   and it cost a device crash** — `attempt to call upvalue '_' (a boolean value)` — on
   the page-boundary crossing of the window view, whose button row was the first
   `_(...)` this file had ever needed. The offending line was years older than the
   caller that found it out, which is why "nothing has ever gone wrong with it" is not
   evidence of anything here.
   The two shapes are reported differently because they reach differently. A plain
   assignment reaches the *file*, so every `_(...)` that runs after it anywhere is
   broken and it is always reported. A `local` shadows only to the end of its own
   block, so it is reported only when something in that block translates afterwards —
   five files here discard into `_` with no `_(...)` near them, and flagging those would
   be noise that teaches a reader to skim the pass. **The first version of this pass
   looked for the shape `_ =` and passed on the real bug**, because the assignment it
   exists for is `x, _, y =`; it was found by injecting the line back and watching the
   checker stay silent — the same self-test the paragraph below asks for, done late
   rather than first.
   The block extent comes from pass 9's matcher, extracted into `block_spans` so both
   passes ask one implementation the same question. What it cannot see is an assignment
   whose `=` sits on a later line than its targets; nothing here writes one.
11. **A field named after a method the host's widgets already define.** The free view
   declared its state as `free = nil` on a class extending `ImageViewer` — and
   `free` is `WidgetContainer:free(full)`, so `self.free` is a *function*, not the table
   that was put there. The second failure is the one that matters: the field read back
   fine at the point of assignment and only threw where it was *used*, which was inside a
   paint, so the plugin's own `pcall` around the button row caught the first one and the
   reader got a viewer whose gestures crashed. **This one shipped as well**, on the first
   device run of the view that introduced it, and the error names it exactly —
   `attempt to index field 'free' (a function value)`.
   The rule the file already had and this broke: **a field this plugin hangs on a stock
   widget is named so that it cannot collide** — `meguru_rotates`, `_meguru_warm` — and
   the one that collided was named for what it *was* rather than for whose it was. The
   pass reports field names only, so an override written as `function
   PanelViewer:onSwipe(...)` is left alone, which is right: that one *is* the file's own
   method and the two look nothing alike in the source.
   Its list of reserved names is short and deliberately so — the widget lifecycle and the
   viewer's event handlers — because a name on it is a claim that the host owns the name,
   and a wrong claim would be a false positive that teaches a reader to skim the pass.
   What it cannot see is the same collision reached any other way: an assignment
   `self.free = x` outside an `extend{}` or a `:new{}` table is not reported.

None of these is a parser. They are the failure modes that have actually bitten this
codebase, and that a reader cannot reliably catch by eye: a name or member that is fine
at load time and only explodes when a branch runs, on the device, in the reader's hands.
**The checker passes vacuously if its stripping or its patterns are wrong**, so each
pass was self-tested by injecting the real failure and confirming the checker reports it
— including at the right line. Do the same before trusting a green run, and this is not
a formality: of the passes written across this project, four were wrong on the first
attempt and passed on the very bug they existed to catch.

A Python mirror of Lua logic models values, not Lua's evaluation rules, and the
difference has shipped a crash. `meguru/credential.lua`'s `restoreTemplate` ended
`return (s:gsub(...))` — parentheses truncate a multi-value expression to one, so the
`count` its caller branches on was nil on exactly the *successful* path. Say which Lua
rules a mirror is modelling, and treat anything it does not model as untested rather
than as passed. The traps of the same shape: `and`/`or` folding (`x and f or nil`),
`nil` in a table constructor ending the array part, `#` on a table with holes, and
integer division or bitwise operators under 5.1.

**`tools/scan_sql.py` is gone**, with the SQL it guarded.

### Verifying on the device

No automated tests, so verification is a running KOReader. Run with `-d` or read
`crash.log`, filtering on `Meguru:`.

**A marker written by an older build is not a valid test surface.** A v1 marker is
still valid and still opens — that is a requirement, not a hope — but it carries none
of the series identity added since, so it has no neighbour until something reopens it
from a browser. Wipe the markers whenever a change touches the marker's shape.

**Installation must be a directory named `meguru.koplugin`.** `pluginloader.lua`
`_discover()` ignores any directory whose name does not end in `.koplugin` and strips
the suffix to get the plugin name, so `plugins/meguru/` is invisible. On this machine
it is a junction, not a copy, so the repository stays the single source of truth:

```
cmd /c mklink /J "<koreader>\plugins\meguru.koplugin" "C:\dev\projects\meguru"
```

**Read the whole log, not just the crash.** KOReader catches non-fatal errors inside
`pcall` and logs them as `warning: UNHANDLED EXCEPTION!` plus the message, then carries
on. So a line like that *before* the fatal crash is a **second, independent bug**. When
a message names nothing, the string is worth chasing to its source rather than guessing
— it is often a vendor library's:

```
grep -rn "<message>" <koreader>/            # which file, if it is Lua
grep -a -o -E "[ -~]{6,}" libs/libwrap-mupdf.so | grep -i "<message>"
```

That is how `argument error: missing file type` was traced to
`Mupdf.openDocumentFromText` and its non-optional second argument: the adjacent string
in the wrapper is `cannot find document handler for file type: '%s'`, which says a
*wrong* type fails loudly and differently, and makes supplying a guessed type safe.

Each step must pass before the next:

1. **The plugin with no network and no store.** FileManager → `Tools → Meguru` submenu
   — no crash. Then open a marker from History with the wifi off: it reads, and "Open
   next in series" says the series has no next chapter rather than opening the wrong
   book or hanging.
2. **A marker opens with nothing configured.** Open a book, then rename
   `settings/opds.lua` and reopen the marker from History — the book must open and read,
   and its pages must fail with a 404 whose path says `<redacted>` and a warning naming
   the fields that stayed stuck. Put the file back: pages fetch again.
3. **The marker names the right chapter.** Hand-edit `item_key` in a marker to another
   item's key — the open must land on whatever that key names. Then hand-edit
   `server_kind` to a wrong value: the book still opens and reads (the kind is only what
   builds a feed URL), and "Open next in series" reports that it cannot look rather than
   answering with a wrong chapter.
4. **Page fetching.** One log line per page with a rising `pageNumber` plus prefetch,
   and **no** fetch of a whole archive. `cache/meguru/` does not grow while reading.
   Alongside it, one `page N prepared`, one `MuPDF page render`, and one `page N paint
   via direct|scale` per rendered tile: on a manga page that fits the screen the render
   line shows the page uncapped and the paint line says `direct`; on an oversized scan
   the render line shows the reduced size — that pair is the whole check that the budget
   is doing what `meguru/settings` says. Then turn back one page and force a repaint
   (open/close ⋮, toggle a crop setting): **no fetch**, because the page's decoded buffer
   is still live. Turn back past the four-entry store and a fetch *is* expected — that is
   the trade this makes, not a regression. Then close the book and reopen it: the page it
   reopens on is fetched, because the store died with the document.
5. **Engine port.** On the same title as the old plugin: crop, page-number crop, panel
   zoom, night-mode invert, wide-page rotation, local `.cbz` via "Open with…" —
   behaviour identical to the old plugin.
6. **Concurrency.** Two windows (FileManager + ReaderUI): the provider registers once,
   and a walk started from one does not disturb the other. The UI must stay responsive
   while a walk runs — it is synchronous, so what keeps it bearable is the page cap and
   the short timeout.
7. **Two books, one title.** Open a "Chapter 1" from two different Suwayomi series. Each
   renders its own pages — impossible to confuse by construction, since the store is
   per-document and keyed by page number. What is still worth checking is that neither
   book's marker was adopted by the other.
8. **Nothing on disk but markers.** Read several pages, then confirm `cache/meguru/` is
   empty (or absent) and that no `meguru.sqlite3` reappears in `settings/` — including
   after browsing a folder of `.meguru` files in the mosaic, which *does* fetch each
   cover over HTTP and must still write nothing. In that same browse, the covers must
   actually appear: the book's own where its feed published one (a Kavita volume), else
   the series', else page 1 of its stream — and at most one fetch per book, since
   `BookInfoManager` remembers the thumbnail afterwards. With the wifi off, covers
   already extracted stay on screen and nothing crashes.
9. **The dialog asks once.** Tap a volume in a series feed, answer the dialog: the book
   opens and **no second dialog appears**. Then close it and reopen the same book from
   History — **the dialog comes back**, which is the half of the test that catches a
   guard that suppresses too much. Reopen a *different* book and confirm the earlier
   one's record is not swallowing it.
10. **The jump button does not re-ask.** With the server further along in another volume,
    tap its `▶` button: that volume opens with no dialog, and the page in the label is
    the page it lands on. Tap a jump onto a volume already read here: the label names no
    page, and the book resumes where KOReader left it.
11. **The silent opens stay silent.** ⋮ → Meguru → "Open next in series" on an unsynced
    series: the walk runs, the chapter opens, no dialog. Finish a volume with `Auto-open
    next in series` on: the next volume opens with no dialog.
12. **The menu lands where it should.** FileManager → Tools → `Meguru` directly above
    `Read timer`, holding a single `Settings` row and nothing else; the reader's ⋮ → Tools
    → `Meguru` holds `Open next in series`, `Open previous in series` and the same
    `Settings` row — the two rows on a marker whose series the feed can be walked, on a
    local `.cbz` whose name carries a series and a number, and on neither otherwise (item
    23). Above `Read timer` in both cases: with the AI Assistant plugin
    enabled that means the second row down, under `AI Assistant` and above `Read timer`;
    with it disabled the row is the first thing on the page. Turning the AI plugin on
    must move the row under it rather than leaving a second copy behind. Nothing
    anywhere offers a cover, a cache to clear, a library or a server list. Inside `Settings`, on both surfaces: `Auto-open next in series` (reader
    only), `Panel zoom in Meguru books` (reader only), `Hide status bar` + a line, `Main
    folder for .meguru streams: …`, `Subfolder per server` + a line, `Set Meguru as
    default reader for .cbz`. The folder row opens the picker and shows the new path
    afterwards; the toggle's checkbox survives a restart; a new book lands in
    `<base>/<server>/<series>` when the toggle is on. With a PDF open there is no Meguru
    row and nothing logs `menu id not found`.

    Then the `.cbz` row, which starts **on**. On a fresh install — no `provider` key in
    `settings.reader.lua`, no `meguru_cbz_default_claimed` — the first start must write
    `provider = { cbz = "meguru" }` and log `Meguru: is now the default reader for
    .cbz`; **every** `.cbz` then opens as a Meguru book. Then the half that matters
    more: turn the row off, restart, and it must **stay off** — `cbz` gone from
    `provider` and `meguru_cbz_default_claimed` true. Guard the other direction: with
    `provider.cbz` set to something else, the claim must leave it alone, while the row
    still reads ticked for a per-file choice and unticked for a file-type one that is
    not Meguru.
13. **No destination dialog anywhere.** `▶ Meguru this series` with the wifi off still
    prompts for a connection and then opens, straight into the resume dialog. Neither it
    nor the top-of-feed row ever asks for a folder.
14. **A dismissed dialog leaves nothing at all.** List the marker folder first. Tap a
    volume in a series feed, then tap *past* the resume dialog: no `.meguru` appears,
    **no series folder appears**, and nothing new appears in the library or in History.
    Do this on a series that has no markers yet — an existing series already has its
    folder, which is why the folder leak was easy to miss.
15. **The two entry points agree on the server's position.** On Suwayomi, read into
    chapter 40 of a 50-chapter series, then open an early chapter (say 3) from the OPDS
    browser: the `▶` button must name chapter 40, not chapter 1. Open that same early
    chapter's marker from History and the `▶` button must name the same chapter 40.
16. **The `▶` chapter is the first the server flags unread, and progress is not
    consulted.** Mark chapters 1–9 read, leave chapter 10 *started* (its summary says
    `2 z 22`), and mark 15–17 read. The `▶` button must name **chapter 10, page 3** —
    not 15 or 17. Then finish chapter 40 with 41–42 untouched and 43 started: the button
    must name **41**, with no page. The log must show a fetch carrying
    `filter=unread&sort=number_asc`. The same chapter must come from the row above the
    series list and from the same book opened from History — three entries into one
    answer.
17. **Panel zoom: the preference is the floor, and a file may stand on it.** Start from
    a device with `panel_zoom_enabled` removed from `settings.reader.lua` *and* from the
    sidecars of the books in play, so nothing has answered for anything:

    | situation | expected |
    |---|---|
    | preference off, a fresh marker | no zoom on long-press, and the **stock ⋮ row reads off too** |
    | same file, stock row tapped on | zoom works — and `Panel zoom in Meguru books` **still reads off** |
    | close and reopen that file | zoom **still works**: the file answered |
    | preference off, a *different* marker | no zoom |
    | preference on, a fresh file | zoom works |
    | …then preference off, reopen that file | **no zoom** |

    The last row is the one that matters, and it is the whole reason `onSaveSettings`
    still deletes something: a file that was only *opened* must not come away with an
    answer of its own. Confirm it on disk — open and close that file under the
    preference on, then check its sidecar has **no** `panel_zoom_enabled`. Also confirm
    the preference applies **live** to a file with no answer of its own, and does **not**
    to a file that has answered. Finally `.cbz`, where the two readings are allowed to
    differ: one opened through Meguru with no answer of its own follows the preference,
    while the same file opened by KOReader's own reader follows the `cbz` entry.
18. **Panel zoom is a crop of the page, not of the screen.** On a book whose pages are
    bigger than the screen (a Kavita volume; anything at or under 4 Mpx is not capped),
    long-press a panel that covers a good part of the page. In `-d` the `panel zoom on
    page N, region … rendered WxH` line must show an output larger than the screen, and
    the image must stay sharp when pinched in the viewer. A panel *smaller* than the
    screen still looks right (it comes back small and the viewer upscales it — intended,
    not a regression), and a long-press with the wifi off and the page's bytes aged out
    of the store still shows a panel, softer, through the `Document:drawPagePart`
    fallback.

    Then the same page in the **window view** (*Panel view: Pan & zoom*), which is the
    second half of this item because it is the same crop question asked the other way.
    Long-press a point in a large panel: the view must be centred on that point, and the
    panel's own edge must sit at the screen's edge — **never a strip of the page's
    margin**, which is what anchoring to the page would show. Forward once: the panel's
    far edge arrives and the panel is done — unless it is bigger than the window in
    *both* axes, where it must take **four** passes, one per corner, and the log's step
    count must say four. A panel **taller** than the window takes two passes and the
    next panel is not reached until its bottom edge has been shown, which is the half
    of this that no screenshot will show if it goes missing. Then the level, which lives
    in the viewer's button row rather than the menu (a middle tap reveals it): tapping the
    `1.7x` button must cycle 1.4 / 1.7 / 1.9, change how much of the page the window
    covers — narrower as the number rises — with the step count following it, and
    **remember the choice**, so the next page, the next book and the next start are at the
    level the reader landed on. Then the `-` and `+` beside it, which move by a **tenth**:
    from 1.7, `+` twice must read `1.9×`, and a third press `2.0×` — a level that is on no
    preset, and the one that catches a stepping path sharing no state with the cycle. The
    label must follow every press, and the window must visibly change with it. From a level
    *between* the presets, the `1.7x` button must walk **up** rather than snapping down —
    at `1.8×` it gives 1.9 — and the range must stop at `1.0×` and `1.9×` rather than
    running away, with the window at `1.0×` being the whole page letterboxed and `+` at
    `1.9×` doing nothing at all. `-`/`+` write
    the same preference the cycle does, so a level reached by nudging must survive the next
    page and the next book.

    Then the **content crop**, which these two views work their zoom out from and the cropped
    view does not touch at all. With *Page Crop* at `auto` (⋮ → **Page crop** → *auto*),
    long-press the same page and compare it against the same page with the crop off:
    **the same level is now closer.** A tenth of the page given to margins was a tenth of the
    magnification the fit was giving away, so at the level the reader was on the window covers
    *less* page — which means a panel that fitted in one pass can need two or four, and that is
    the price rather than a defect: the same *on-screen* size is reached about a notch lower.
    What the crop buys is the bottom of the range — at `1.0×` the window covers the artwork
    rather than the artwork plus its paper, so a panel inside the content box still fits in one
    pass at the floor and a scan with fat margins is no longer permanently under-magnified.
    **The margin must still be reachable**: pan the free view towards a page edge and the paper
    must come into view, because only the fit was cropped and the window is still the page's.
    Then set *Page Crop* to `none` and long-press again: everything must be **exactly** as it
    was before this existed — same steps, same count, the same level buying the same
    magnification — because the mechanism is required to be inert when the reader asked for no
    crop. The free view carries the same pair: with the crop on, its bottom stop is the content;
    with it off nothing moved, and since its remembered zoom is a scale rather than a level,
    1:1 must still be 1:1 either way. **The row must still be there after the tap**: two levels
    are compared by pressing twice, and a viewer that came back with its chrome hidden
    would send the reader to the middle of the screen between every pair. **And it must
    still be *Meguru's* row** — the re-open paints the row it was built with, so a
    `[1.7x]` that turns into `[Original size]` is the `update()`-after-the-swap bug, not a
    preference going missing. The **view switch** sits at the front of the row in both
    views and names the view the reader is **in** — `Pan & zoom` while in pan & zoom,
    `Cropped panels` while cropped — the same thing the menu's *Panel view* row says;
    pressing it changes what the page is cut into, keeps the panel the reader is
    on, leaves the row open, and must agree with the menu's *Panel view* row afterwards,
    since both write the same preference. The *cropped* row is the one place
    **Scale**/*Original size* and **Rotate** belong: pressing them there must still work,
    which is the check that they were forwarded rather than dropped.

    Then the **easing** (*A panel the window nearly holds is eased, not stepped*, above),
    which is the part of this view a log can confirm and a screenshot cannot. On a page
    with a panel the window very nearly holds — a full-width panel a little wider than the
    window, or a tier whose edge just misses — the forward gesture must reach past it in
    **one** press, showing the whole panel at a slightly smaller zoom, where it used to take
    two and the second showed a strip. The `-d` line `window view, step S of T` is the check,
    and the A/B is the **level**: raising *Panel zoom level* in the row shrinks the window in
    page pixels, so the same panel that is eased at 1.4x must not be at 1.9x. Two more, and
    they are the ones the mixed case is for: a panel nearly fitting across but clearly too
    tall must take **two** passes rather than four, both at the reduced zoom; and a panel
    past the tolerance in **both** axes must be untouched — four corners at the reader's own
    zoom, exactly as before. Then the half that is easy to get wrong: the zoom button must
    still read the reader's chosen level throughout, because the easing is per panel and
    must never write the preference. The boundary itself is not a device question — it is a
    fraction of the window, and it lands between whole page pixels — so the way to see that
    it is the mechanism moving rather than the page is to set `PANEL_WINDOW_TOLERANCE` to
    **0** and re-read the same panel: the step count must go back to what it was.

    Then the third view (*Panel view: Zoom only*, or the row's switch twice). Long-press a
    point: the page must open **centred on that point**, sharp at 2× and 3× — it is a render
    from the file, not a magnified tile — and then: pinch changes the scale ✓, drag moves the
    window ✓ **in every direction including down** (which must *not* close the viewer ✓),
    and the page must move **with the finger** — dragging right carries the artwork right, the
    way a map does, not against it ✓ —
    a **tap closes the view** ✓ — the way out that needs no aim —
    the row is up from the first paint and a middle tap does **not** hide it ✓, PgFwd/PgBack
    and a swipe in any direction do **not** turn the page ✓, and the zoom is three buttons:
    `-` and `+` move by half a level, stop at 1x and 4x, and step from wherever the reader is
    (pinch to 2.4x, press `+`, get 2.9x ✓), while the value between them cycles
    1.5 → 2 → 2.5 → 1.5 ✓, and a **pinch** down to the file's own pixels must make that button
    read `1×` ✓ (on a page smaller than the screen: at its true size in the middle, not filled
    out to the edges ✓).
    A pinch to something off the list — say 2.4× — must make the button **read 2.4×** ✓, the
    **picture must change with it** ✓ (a number that moves while the page stands still is the
    callback that forgot to re-resolve `self.image`, and it is the bug this view shipped
    first), and closing and re-opening must come back **at 2.4×** ✓ — this zoom is remembered,
    written once at close. Then the switch out: from the free view it must land in
    *both* other views ✓, keeping the reader's place, and land back ✓.
    Then the skip: on a page
    with small panels beside a full-height one, position the window so they are all
    inside it and press forward — **one press must pass all of them** and land on the
    next panel the window does not cover, with the `-d` line showing a step count
    smaller than the panel count. Back from there must reach the panels *before* the
    one touched, not only the ones after it. **And the boundary in both directions**:
    swiping forward off the last panel opens the next page's **first** panel at its
    start, and swiping back off the first opens the previous page's **last** panel at
    its **end** — the bottom of it, the corner nearest where the reader came from. It
    used to open the previous page at its first panel, from the top, and then at the
    last panel's top, and both were wrong for the same reason. Then the
    direction: in Manga mode a panel too wide for the window must be walked from its
    **right** edge to its left, and in Comic mode from left to right — the same thing
    `Manga mode` already does to the panel order. And a splash page the detector refuses
    must open whole, cropped, whatever this preference says.
19. **A book that cannot get its pages says why, once, and stops asking.** With the wifi
    off, open a marker: the page area holds *Can't load this page / You're offline right
    now. Connect to Wi-Fi and try again.* Check the two cases that must not be confused:
    with the wifi *on* and the server stopped it must read *Kavita isn't responding…*,
    and with a marker whose catalog was deleted (a 404) *Kavita returned an error
    (404)…*. In `-d` the same two cases are `(no response)` and `(HTTP 404)`. Then the
    rest, which is about not asking twice: one `Meguru: no connection, cannot fetch page
    N` in the log rather than one per repaint; open the ⋮ menu and close it, zoom, toggle
    a crop setting — the page repaints but nothing is fetched and nothing more is
    logged; turn the page and back — one fresh attempt; turn the wifi on — the page fills
    in **without a page turn**, from `onNetworkConnected`. In the FileManager with the
    wifi off, open a folder of markers: no cover is fetched at all, and the mosaic fills
    in on the next browse once the wifi is back.
20. **The panel detector.** Five pages, and the first two are the failures this detector
    was chosen for — the two whose outcome once decided which detector lived here, so
    they are worth re-running before anything in this area is touched again.

    | page | expected |
    |---|---|
    | a panel carrying a full-width **white band inside its own drawing** | **ONE panel.** The band must not cut it in two. The page needs a *hairline* frame for this to bite at all: a row of the band is empty only while the frame's two strokes fit inside the gutter's allowance, `PANEL_GUTTER_INK_RATIO * span` — 2.21 cells of the 443 a 1600-px page maps to. A 5-px stroke is 2 cells a side, so the band never reads as empty and there is nothing for the veto to refuse; the panel chapter has the drawn page that does reproduce it |
    | a page of **tilted panels** — a skewed scan, or gutters that are not axis-aligned | **the panels, split** — `K panels` in the log with K what the eye counts. The reference page for this is Kavita `chapterId=197664`, `pageNumber=115`: `python tools/panelprobe.py <that page>` must print **6** kept leaves, and the one it gets wrong is `249,276 195x206` — two panels whose shared border is crossed by a speech bubble, which is a known limit and not a regression |
    | the same page, **long-pressed** | every panel opens showing **only itself**. Nothing of a neighbour is visible along a slanted edge, and no part of the panel is missing at one — the crop follows the border. In `-d` the `panel zoom on page N … tilt T` line names a non-zero `T` for the five panels whose borders are tilted and `0.000` for the bottom row, whose are square |
    | a normal manga page, 4–6 panels with hairline gutters | the same sequence, in the same reading order, as before |
    | a splash page with no panels at all | the viewer opens on **the whole page** (1 of 1), no progress bar, and a swipe forward **turns the page** |
    | a page the detector refuses | **no panel appears twice**, in either direction, and the count matches the eye |

    Then the mechanics. In `-d`, one `page N panel zoom: K panels … in X ms` per
    long-press; a refused page says `K panels, whole page (<reason>)` and the reason
    must name one of the four tests — `no panels`, `single partial panel`, `panels cover
    too little of the page`, `only N% of the covered area kept`. Compare the milliseconds
    against the `page N prepared in X ms` line on the same page: the scan sits on top of
    that decode and should be a fraction of it. Then the two chrome checks: **no progress
    bar**, and the panel centred in the full height rather than above a strip of nothing;
    and **a forward gesture from a middle panel stays on the page** and shows the next
    panel — if it turns the page instead, the navigation bound was taken from
    `_images_list_nb`, which is now the bar's switch and not a count, and nothing
    automated can catch that. Then **toggle Manga mode with a page open
    and long-press it twice** — the second press must give the mirrored order, which is
    the whole job of the cache key; and **long-press, close, long-press the same page** —
    the second must be instant and log the same count (the LRU hit), with nothing new on
    disk. Then cross a page boundary from the last panel: `getPageDims` for the next page
    must appear **once** (the warm) and not again during the crossing, and there must be
    no second `MuPDF page render` line for it — two mean the warm's call order is wrong.
    Cross back and forth three times: no fetch and no decode after the first. Finally a
    page that cannot be decoded (wifi off, bytes aged out) shows the page and **no
    viewer**, logging `no page (…)`.

21. **A turned panel turns the book's way.** One book with a wide spread *and* a page
    carrying a panel wider than the screen. The check is a **comparison**, so it cannot
    be fooled by how anyone reads the row's arrows:

    | setting | wide page | wide panel on a portrait screen | expected |
    |---|---|---|---|
    | `left 90°` | turned one way | **the same screen edge gets the top of the artwork** | they agree |
    | `right 90°` | the other way | the top on the other edge | they agree |
    | `off` | not turned | **exactly as before this existed** — the portrait default, and `Invert default rotation in portrait mode` still flips it | nothing moved |

    Then, in order:

    1. **`off` first.** It is the only row that can prove nothing else moved: the
       automatic turn, the button's toggle and its `Rotate` / `No rotation` label must be
       indistinguishable from the previous build.
    2. **The button with the setting on.** Middle-third tap to reveal the buttons; Rotate
       turns (and unturns) the panel in the setting's direction, and the label flips
       truthfully.
    3. **The press lasts one panel.** After it, move to the next panel — the automatic
       decision must be back. Then return to the one you pressed on: it re-decides, which
       is this design's reading of "one panel" (the press is scoped to the visit). If it
       should instead remember the choice while the viewer lives, that is three lines in
       `switchToImageNum`.
    4. **The handoff.** From the *last* panel, swipe forward: the viewer closes, the page
       turns, a new viewer opens on the next page's first panel, turned the book's way.
       This is the half that is easy to miss, and it fails **only** at a page boundary.
    5. **The turned screen.** On the wide page itself — screen already rotated by the
       setting — long-press a panel that needs turning, under both `left` and `right`. No
       panel angle can be simultaneously readable and device-space-consistent on a turned
       screen; judge whether it reads naturally.
    6. **The button, regression.** Pinch in, press Rotate, toggle *Scale*, press Rotate
       again: every `update()` rebuilds the `ImageWidget`, so the angle must survive all
       of them — and `-d` must show **no** `panel rotation angle could not be applied`
       warning.

22. **Another plugin that patches the OPDS browser.** `zenos.koplugin` is the one known
    to replace `showDownloads` and `parseFeed` wholesale; it is not in this repository,
    so this is a device check. First the half that proves nothing moved: **without it**,
    everything below behaves as before and `-d` shows **no** `OPDSBrowser re-patched`
    line. Then with it enabled and a restart:

    - a series feed carries **exactly one** **“▶ Meguru this series”** row at the top —
      two is the per-method guard having failed, and it will not announce itself any
      other way;
    - tapping a volume opens *its* dialog with our row above the last one, and its own
      “Page stream” / “Stream from page” buttons **still there**;
    - our row opens the resume dialog and the book;
    - `-d` shows `OPDSBrowser re-patched since load; OPDS hooks re-installed`
      **exactly once per process** — not once per browser, and not at all on a second
      open — and one `added "Meguru this series" button for …` per dialog.

    Then the two that a missing `parseFeed` breaks and that no picture of the dialog
    would show: open a book from a **Komga** series feed and confirm `-d` does **not**
    report `not catalogued: no retained entry matches this stream`; and cancel the
    resume dialog after tapping our row, confirming no `.meguru` and **no series folder**
    appear (item 14 still holds). Finally, with the network off, open a marker from
    History — the `ReaderUI:showReader` wrap is on another class and must be unaffected,
    asking once and opening.

23. **A folder of `.cbz` is a series, and the folder is the only rule.** Nothing in
    this one can be checked off the device: the ordering is a byte sort over real
    file names, and the sort key's encoding has never run anywhere but a device.

    1. **The rows appear only when there is somewhere to go.** A folder holding one
       `.cbz` — a one-shot, or an unnumbered book like `Berserk.cbz` — gets **no**
       Meguru navigation rows at all. Add a second `.cbz` of any name and both rows
       appear on both books.
    2. **The order is natural.** `1.cbz`, `2.cbz`, `10.cbz`, `20.cbz`: next walks
       them in that order and previous reverses it, with the message naming the
       folder at either end. The same for `Berserk v2.cbz` beside `Berserk v10.cbz`,
       and for `02.cbz` beside `2.cbz` (adjacent, either order — the leading-zero
       case is a tie-break, not a rule).
    3. **Offline.** Wi-Fi **off**: next and previous walk the run both ways and stop
       at the ends with the message. No Wi-Fi prompt anywhere on this path — if one
       appears, the local branch has slipped below the `NetworkMgr` gate.
    4. **The reader stays Meguru.** Give `.cbz` back to KOReader (*Set Meguru as
       default reader for .cbz* off, restart), open one volume through *Open with… →
       Meguru*, then take "next": `-d` must show `Meguru: local CBZ ready` for the
       **new** path. Then, on disk: the association is still off, the sibling's
       sidecar gained **no** `provider` key, and the folder gained no file.
    5. **Auto-open.** With the toggle on, finishing a local volume opens the next with
       no dialog; at the end of the run, stock's dialog. With it off, stock's
       throughout.
    6. **What is not a book.** One folder holding two `.cbz` plus a `.cbr`, a `.meguru`
       marker, a `.jpg` and an AppleDouble `._one.cbz`: only the two `.cbz` are ever
       opened, and the dotfile is never offered.
    7. **Two titles in one folder navigate into each other, and that is the accepted
       cost.** In a folder called `Comics`, put two different series' books: `next` on
       the last of one opens the first of the other. Confirm it reads as the price of
       the model and decide whether it is tolerable on a real card — that judgement is
       the one thing here a device can settle and this document cannot.
    8. **A folder that cannot be listed.** Unreadable media, or a folder deleted from
       under an open book: one `warn` naming the file, and no rows.
    9. **Non-ASCII.** `Zaginiony rozdział 01.cbz`/`02.cbz` and a CJK run both order and
       navigate. This is the only real test of the byte-exact sort.
    10. **The feed path is untouched.** In the same session, a marker book still walks
        its feed for both rows, and killing the Wi-Fi there still prompts as it always
        did.

24. **Kavita with *Include Continue From Entry* on.** The setting is per user, in
    User Settings → OPDS, and it puts a page-less copy of the chapter being read at
    the top of the series feed — see `Feed.dedupe` and PROTOCOL.md. Wipe the series'
    markers first: one written before this parse fix carries the alias's title and
    no `last_read`, so it is not a valid test surface.

    **Off first**, because it is the only row that can prove nothing else moved: ▶
    names the chapter with its page, next/previous are unchanged, and `-d` shows
    **no** `dropped duplicate feed entry` line. Then **on**, on a series read into
    the middle of a volume:

    | where | expected |
    |---|---|
    | `▶ Meguru this series` over the series feed | the chapter being read **and its page** |
    | the same book's marker, opened from History | the same chapter and the same page |
    | the marker on disk | `last_read` is the server's page, `series_name` is the series |
    | ⋮ → Meguru → **Open next in series**, on that chapter | **the next volume** — not the first one | 
    | ⋮ → Meguru → **Open previous in series**, on it | the previous volume — not "no previous" |

    The two neighbour rows are the half a lost `last_read` does not show, and they
    are the reason the survivor keeps its own index rather than the one it
    displaced: the alias sits at the head of the feed, so a survivor holding that
    slot puts the chapter being read *first in the series*, and next/previous then
    answer from there. Reading one page and turning one page are not enough to see
    it — **walk a neighbour in each direction.**

    Then the switches, which are per user and must change nothing. Turn
    `Embed Progress Indicator` and `... in Title` off (titles lose their glyph),
    then repeat the table: ▶, both neighbours and the row above the series list must
    answer exactly the same. That is the test that nothing rests on a title.

    Then the two halves that are about *frequency* and *scope*: the `-d` line appears
    **once per feed**, naming the alias title, and never once per page or per
    repaint; and the browser's own list **still shows the "Continue Reading from:"**
    row, which is Kavita's entry drawn by KOReader's OPDS plugin and not ours to
    remove — what changed is only which of the two Meguru treats as the book.

