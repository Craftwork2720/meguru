# Known open items

Open questions and unverified assumptions, each with what would settle it and what a wrong answer would cost.

Part of the design record; [CLAUDE.md](../CLAUDE.md) is the map.

## Known open items

- **A page is decoded at its file's stated density, not at its pixels.**
  `renderMuPDFPage` sizes the render from `page:getSize()`, which is `fz_bound_page` —
  points at 72 dpi — and for an *image document* MuPDF computes that box as `pixels x 72
  / density`, assuming **96** when the file says nothing. So a density-less 1600x2400
  scan is decoded at 1200x1800 — 25% below its pixels — and a scan carrying 300 dpi at a
  quarter, silently, because the budget below is an *area* cap and reports the same
  capped numbers either way. The `MuPDF page render WxH -> WxH` line cannot show it
  either: both of its sizes come from the same space. What keeps this from being visible
  today is that `renderRegionDirect` re-renders a magnified region from the source. It
  wants its own pass on a device: the fix is either teaching the decode the density (PNG
  `pHYs`, JPEG JFIF) or moving the plugin's whole coordinate space to pixels, and every
  geometry path shares that space.
- **The panel rotation direction is applied *after* `ImageWidget:new`, not passed to
  it.** `PanelViewer:_new_image_wg` relies on `ImageWidget` not having rendered yet —
  it defines no `init`, and `_render` is entered only from `getSize`/`paintTo`. That is
  how the direction is applied without forking ~30 lines of `_new_image_wg`, and it is
  a dependency on an upstream shape rather than on an upstream promise. The guard and
  its once-per-process `warn` are what make it checkable: if `panel rotation angle
  could not be applied` ever appears in a log, the panel fell back to stock's direction
  and the repair is the forked override — the failure is otherwise silent, which is
  checklist item 21.6.
- **The 90-vs-270 mapping was derived from stock's comment and was wrong.** It came from
  `imageviewer.lua:429`'s `rotate_clockwise and 270 or 90` with "unintuitive, but this
  does it" beside it, and it made panels turn *with* the device where the row names the
  device and the panel turns against it. Found on a device, fixed by crossing the two
  constants in `panelRotationAngle`. Now observed rather than derived, so treat it as
  settled — and note that the row's word is the one thing that never was.
- **The panel detector has a measurement harness, and it is the only way anything in
  it has ever been decided rather than argued.** `tools/panelprobe.py` is a faithful
  port of `meguru/panel.lua` - the ink predicate, both projections, the recursive cut,
  the sheared search, `emitLeaf`, the containment filter, and the bodies of ink a split
  may not run through - that runs on a page image
  with no Lua interpreter. Feed it a page from a real server and it prints every leaf's
  cells, ink density and position as a percentage of the page, plus what the
  containment filter drops and why, plus each body with its frame evidence and every
  candidate a body refused, and under each leaf the **crop box and its four
  edge slopes** - which is how a panel that is a quadrilateral gets told apart from
  one that is a rectangle without a device; its flags compare variants (`loose` for the
  sheared ratio before `PANEL_SHEAR_INK_RATIO`, `root` and `all` for the shear's depth,
  `noclip` for a projection that is not the plugin's, `noveto` for a body pass that
  refuses nothing). **Reach for it before touching
  anything here** - the
  two bugs above were both resolved by measuring, after several rounds of reasoning
  that were each confident and each wrong. **What it does not model**: Lua's evaluation rules (so
  it can settle arithmetic and never semantics), MuPDF's render, and the
  decode-then-resample two-step. A divergence it cannot see is a divergence it cannot
  rule out.
- **The window view's geometry is measured the same way, by a mirror and drawn
  layouts.** `meguru/viewport.lua` is pure — panels, page size and screen size in, a
  list of rectangles out — so a Python transcription of its `steps` runs the same walk
  over layouts whose truth is known because they were drawn (six equal panels, a tall
  one with a grid of small ones beside it, a panel that fits, one that overflows both
  axes, one starting mid-page, an entry into the third of six). It is what settled that
  a panel already on screen contributes **no** step, that the window's left edge is the
  *panel's* (300 in the drawn case) and not the page's (0), that a panel too big in
  both axes is four corners and not a diagonal pair, and that the same wide panel's two
  stops swap sides with the direction. It is not in the
  repository yet — the generator lives in the session's scratch directory with the
  control pages — and what it cannot model is anything about rendering, which is what
  the device item is for. **Unmeasured on a real page:** the 1.30 screen-pixels-per-page-
  pixel that the top level, `1.9`, comes to on a 1600x2400 scan against a 1236x1648 screen,
  and so how soft the window looks on a page whose `fit` is near 1; whether the skip ever passes a
  panel a reader wanted to stop at; and the whole thing on a page whose panels are
  quadrilaterals rather than rectangles, where the cropped view's mask has no counterpart
  and the window simply shows the neighbour at its edge — by design, and still unseen.

  **The easing tolerance is measured the same way and settled the same way.** The mirror
  was extended for it: the same layouts, sized relative to the reader's own window, run at
  8%, 18% and beyond it in each axis and in both, plus an entry onto an eased panel, plus
  the page the window is clamped to. It is what established that a panel eight percent too
  wide is 1 stop where it was 2, that the mixed case is 2 where it was 4, that both axes
  past the tolerance are 4 either way, and — the half that matters on a real book — that
  the A/B against `PANEL_WINDOW_TOLERANCE = 0` over ten layouts is identical wherever no
  panel can ease. What it cannot say is how any of it *looks*, so the judgement the
  constant encodes — whether 18% is where a reader stops noticing the shrink — is unmeasured
  anywhere and is the first thing to revisit if a page reads oddly.

- **A rule measured on one page is not a measured rule, and this cost a commit.** The
  leaf-containment rule was added, then removed on the evidence of a single page where it
  dropped nothing, then restored when the next page found needed exactly it. The honest
  reading of "it removes nothing here" is *it does not fix this page* — and the
  difference between that and "it does nothing" is the whole of the mistake. It has since
  been made inert by the shear's line cut, on a 23-page sample, and it is **kept** rather
  than deleted for exactly this reason.
- **The veto that refuses a split through a detected panel has two conditions, and only
  one of them is measured.** *Coverage* — the body has to span the region on the
  perpendicular axis — is what ships, and `blocked` names its price: two framed panels
  side by side with a white band across both leave neither body spanning, so no veto
  fires and the cut still runs through them. A plain *overlap* catches that case and
  refuses more legitimate splits with it. On the 15-page sample neither choice changes a
  leaf, because neither fires on a candidate that wins its node — so the sample cannot
  settle it, and the conservative condition ships until a page does. What could regress
  in the other direction: `PANEL_BODY_FRAME_MIN` is **1**, the reference's own rule for
  calling a body framed, so a body spanning several panels with one straight edge vetoes
  the split between them and they arrive merged. Both are worth re-measuring on a page
  that has either shape, and neither shape has been seen yet.
- **The veto is invisible in a device log, by construction.** It can only *merge*, so it
  changes neither `accept`'s verdict nor the `K panels` count that reports it — and
  `meguru/panel.lua` has no logger by design, since it is handed a buffer and returns
  rectangles. So "two panels arrived as one" is a question for `tools/panelprobe.py`,
  which prints the bodies with their frame evidence, every refused candidate and the body
  that refused it, and behind `--noveto` the same page with the body pass emptied for the
  A/B. The device's own line is unchanged, and deliberately so.
- **Both skewed-page rules are samples, not proofs.** `PANEL_SHEAR_INK_RATIO` changes the
  leaf count on exactly the pages that were broken and on none of the others, where the
  shear never fires at all (`shear 0/3` - the straight cut handles them). The line cut is
  measured over 23 pages — two chapters of a manga whose panels are drawn at visibly
  different angles, and eight pages of a western comic with clean rectangular ones — and
  it changes the leaf count on one page of the 23, the reported one, where it is also the
  difference between five right panels and one. **The quadrilateral crop changes no leaf
  count at all on those 23** — it is geometry, not detection — so the same sample can say
  only that it is inert, and what justifies it is the measurement on the reported page:
  four of its six panels had a neighbour's content in the crop (2.6% and 1.8% of two of
  them) or their own art cut off (7.8% of one, 19.2% of the merged pair), and after the
  change the crops follow the borders and what remains outside them is the one-cell
  expansion every crop has always had. What could still regress: a page whose
  separator is a real gutter carrying JPEG noise, since the sheared line must be genuinely
  empty (that page would come back as one panel rather than several); a page with an inset
  panel, which the containment rule would drop if it ever fires again; and a page whose
  tiles are tilted enough that the wedge a line cut gives up at a panel's corner is
  visible — the one case no sample here contains, because it needs a slope past the 8
  degrees the ladder reaches. Neither of the first two has been seen. The three constants
  are the first thing to look at if any of those shapes of page misbehaves.
- **A page the cut cannot decompose at all is still one panel, and that is most of one
  chapter of the reported series.** Eleven of the fifteen pages sampled from the reported
  chapter come back as a single whole-page rectangle — accepted, because a lone rectangle
  over 60% of the page is treated as a splash — because those pages have **no full-width
  or full-height empty line anywhere**. They are action pages: panels at angles, speed
  lines crossing everything, artwork off every edge. That is the XY-cut's own limitation
  and not a defect in it, and the fix for it is a different algorithm, which is the
  question this project has already settled twice (see the connected-component argument
  above). What is worth knowing is that the reported page is *not* one of those — it has
  clean empty gutters and the cut finds five of its six panels — so a reader who sees
  whole-page "panels" on those pages is looking at a different problem.
- **Page numbers in these notes are the *URL's*, not the reader's, and they differ by
  one.** Kavita's `pageNumber=N` returns what the reader's own paging calls page N+1, so
  every `p32`/`p87`/`p100` in this file is the page a reader would call 33/88/101. The
  measurements were taken from one numbering and the complaints from the other, and
  matching them cost a wrong diagnosis — three of five "failing" pages were not the
  pages being complained about. Quote the `pageNumber` when a page has to be identified.
- **A *second* chapter of that series merges panels, and chasing it is worth keeping
  whole.** Its mergers are mostly *partial* — a tier's two panels left as one — and their
  boundaries are neither an empty gutter nor a drawn line but simply the artwork stopping.
  Four things were measured against them, and only one paid:
  - **The shear's trigger is not the blocker.** Instrumenting every failing node: the
    precondition (`minInRange <= 0.35` of the span) fires at all of them. The sheared
    search is also **strictly stricter than the straight one by construction** — a
    straight gutter may carry `PANEL_GUTTER_INK_RATIO` of its span in ink, a slanted one
    must be *exactly* empty — and that asymmetry is why a slanted separation is missed
    more often than a square one. It is deliberate: the zero on the shear was bought with
    a device bug (a panel split down the middle of its own drawing by a faintly bright
    band), and the arithmetic argument for it is in `meguru/panel`.
  - **Thickness was the blocker, and is fixed** — the `min_gutter` change recorded under
    "The sequence" above. Three of the five failing nodes had a line already under the
    ink threshold, refused for being *one* line where `min_gutter` wanted two.
  - **The reference's own `segment_border_split`**, whose source is on this machine at
    `/c/dev/github/panelplus`. Its plane is not the ink map: a cell is a border candidate
    at luminance ≤ 60, and a separator is a run ≥ **97%** of such cells, thin. On the
    reported pages the densest line reaches 98% on exactly one page, 93–96% on another and
    27–57% on the rest, so **porting it fixes none of them**. Porting it with the ratio
    lowered to 0.90 — which would catch the second — shreds instead: a five-panel page
    came back as twenty-four.
  - **Relaxing `PANEL_GUTTER_INK_RATIO` to 0.15**, shipped behind a preference and then
    withdrawn. It fixed four pages (2→5, 5→6, 3→7, 1→7) and left every illustration alone,
    and it built the failure the threshold is named for: dense pages split further, the
    first chapter's own reference page **6→13** and a dense action page 1→7. **A reader
    reported it as "it splits too much", which is the 0.05 failure one order of magnitude
    out** — and a switch whose good and bad settings are the same pages is not a switch.
    The work is `27a0b4b` in this history, reachable by hash.
  
  What is still merged after all four is genuinely merged: no threshold, plane or
  algorithm available here separates those pages from the full-page illustrations that
  must *not* be split — 10.4% ink and a 5-cell dark stroke against 45% and 6, on pages
  whose right answers are opposite.
- **The background estimate is wrong on six of those fifteen pages, and fixing it changed
  nothing.** `backgroundFor` takes the **median** of the outer 1% ring, and on a page whose
  artwork bleeds to every edge that ring is bimodal — black at the page's border, paper
  just inside — so the median lands in the valley between them. Measured: the paper can be
  `255` while the estimate comes back `147`, `187`, `196`, `200`, `203` or `210`, and
  `PANEL_INK_DELTA` is a *symmetric* band, so paper 47 above the estimate reads as **ink**
  and 68–76% of the page maps as ink. The near-white override exists for this and its gate
  is `hasWhiteSeparator`, which these pages fail. Replacing the median with the ring's
  dominant mode gets `253` on 22 of the 23 pages and `2` on the one where black really does
  dominate, against `255` on 16 of 23 for the median — a real improvement, and **not made
  here**, because forcing the estimate to `255` on all six leaves every one of them at one
  panel anyway (49–63% ink, still no empty line). It is a correctness fix with no measured
  payoff on the only sample there is, so it wants its own page and its own evidence.
- **The panel scan is not the reference's scan, and three measured differences are
  live.** They are named as *measured* rather than suspected, so nobody re-derives
  them, and none of them is known to matter on a normal page:
  - **Geometry rounds differently.** The reference renders at `480/native.w` and takes
    `ceil(x - 0.001)`; this plugin computes `floor(x + 0.5)` from the already-decoded
    buffer. The two are **one row apart whenever the fractional part is under 0.5** —
    about half of all pages — and agree exactly on the 1600x2400 that everything here
    was measured on.
  - **`PANEL_SCAN_MAX_CELLS` coarsens strips.** It first bites past 5.2:1, where this
    plugin's cells become 2.2x the reference's — an 800x20000 page maps at 219x5474
    against the reference's 480x12000. A gutter under ~5 page pixels is then below
    `min_gutter` here and not there. Deliberate (the 35 MB the uncapped scan costs),
    and a strip's answer is "one panel, the whole page" regardless.
  - **The resample happens twice here and once there.** The reference renders small
    through MuPDF, straight from the source; this plugin decodes at the capped native
    size and *then* scales. On a page over the 4 Mpx budget that is two lossy steps
    against one, in the direction of losing thin light features — which is the
    direction that invents gutters, and `legacy_image_scaling` (a KOReader setting,
    off by default) turns the second step into nearest-neighbour and makes it worse.
- **Kavita granularity** is resolved in PROTOCOL.md (entry ↔ stream is 1:1).
  `driver/generic.lua` is not written yet; see Layout.
- **Komga's `pse:lastRead` has never been seen carrying a value.** Every capture was
  of a library nobody had read, so `readProgress?.page` was absent on every entry and
  the feed looked like a server that tracks nothing — it does. PROTOCOL.md has the
  source line; what is unverified is only whether that page is one-based, as Komga's
  own numbering is. Wants a device check against a book with progress: a zero-based
  value would offer a page one early, and `PSE.samePlace`'s tolerance would hide it.

- **The bottom menu in a Meguru book belongs to zen-os, and this plugin does not
  contest it.** Taking the gesture back was tried (`4a0f395`) and deliberately reverted:
  it is a fight for a gesture with another plugin, and code that can break someone
  else's books is not worth a cosmetic gain. What that attempt ran into is the reason
  it is not merely unfinished — wrapping `ReaderConfig.onSwipeShowConfigMenu` and
  `onTapShowConfigMenu` is not enough, because zen-os takes the bottom of the screen
  **three** independent ways: a touch zone (`zen_page_browser_reader`,
  `page_browser.lua:2564`) that calls its page browser without ever reaching the
  method, re-registered on **every** document open; the two method replacements, which
  do not chain; and `zen_mode.lua:240-248`, which swallows `onShowConfigMenu` as well,
  so even a method that *is* reached opens nothing while `features.reader_bottom_menu`
  is false — its default. Any future attempt has to answer all three, and the middle
  one is what makes the failure **silent** rather than wrong: the gesture opens the
  wrong thing, which from the reader's side is indistinguishable from one that was
  never bound. `curateConfigMenu` still curates the rows and is untouched; with zen-os
  installed they are reached by whatever zen-os offers in the gesture's place.
  **It was also verified on a surface that could not show the failure**, and that pair
  of results is the evidence: the repair passed in a development KOReader under WSL and
  failed on the Kindle. Every one of the three mechanisms above needs zen-os present, so
  a session without it exercises only the stock path — where the repair does exactly what
  it says. A repair aimed at a foreign plugin has to be verified where that plugin is
  installed, and this is what it costs when it is not.

- **A marker written from a tapped "Continue From" row carries no `last_read`.**
  `driverItemFor` matches one stream and answers with the entry the reader tapped,
  which for Kavita's alias is the copy without the page — so the marker is written
  with `last_read = nil` and `MeguruDocument:init`'s silent seed opens it at page 1
  on a later open from History. What is *not* broken is the dialog on that first
  open: it is asked about the book, and the server's page comes through
  `freshResumeTarget`, which does collapse the duplicate. The repair, if it is
  wanted, is to let `driverItemFor` take the survivor of a collapse whose
  `item_key` matches the stream — the two copies share a template, so the match
  survives the replacement — and it was left out of the change that introduced
  `Feed.dedupe` by decision rather than by oversight. Not measured on a device: no
  marker has been written from an alias row and then reopened from History.

- **A viewer that is built and never painted crashes the next repaint, and the crash is one
  event away from whatever caused it.** `attempt to index field 'dimen' (a nil value)` at
  `imageviewer.lua:384` — and **that line is `ImageViewer:update()`'s queued repaint closure**,
  `self.main_frame.dimen:combine(orig_dimen)` (`orig_dimen` read at `:329`), not the one in
  `onCloseWidget` this entry used to blame. That one (`:889`) writes `self.main_frame.dimen`
  without indexing it, so it can only ever fail on `main_frame` itself — it cannot produce this
  message, and the repair this note used to suggest ("close the viewer without its parent
  `onCloseWidget`, or give it a frame that cannot go away") was aimed at the wrong closure. The
  second half of it is also **actively unsafe**: `WidgetContainer:paintTo` assigns `dimen` only
  `if not self.dimen`, so a frame pre-set by us is the size that viewer keeps for good.

  The chain, all of it read in the stock source rather than inferred:

  - `main_frame.dimen` **is assigned lazily inside `WidgetContainer:paintTo`**. A viewer that
    has never been painted has no `dimen` at all.
  - `UIManager:setDirty(widget, fn)` pushes `fn` onto `_refresh_func_stack` — **a plain list,
    not keyed by widget**. `UIManager:close` clears `_dirty[widget]` and does not touch the
    list; only `_repaint` empties it, and only after running it.
  - `ImageViewer:init` **ends with `self:update()`**, so merely constructing a viewer queues
    that closure — which is why this is not specific to Meguru. Our `installRow` calls
    `update()` a second time, and it does it **before `UIManager:show`**, so every Meguru open
    queues a closure for a viewer that is not yet on the window stack. That is harmless exactly
    as long as `show` follows and the repaint at the end of the event paints it.

  So the precondition is precise: **a viewer whose `update()` ran and which was never painted
  before the repaint that consumed the queue.** Nothing else produces this error.

  **And the producer is found: two input events in one batch.** `UIManager:handleInput` waits
  and then dispatches **the whole batch** before it repaints —
  `for __, ev in ipairs(input_events) do self:handleInputEvent(ev) end` — so two taps that
  arrive together are handled back to back with a *single* repaint after both. A Meguru viewer
  is torn down and rebuilt per press (`meguruReopenAtLevel`), so with `+`/`-` pressed quickly
  the first press builds a viewer, the second closes it before it has ever been painted, and
  the repaint then runs that dead viewer's queued closure against a nil `dimen`. Hence the
  report's shape exactly: **only with a rapid press, and only in the window views** — the free
  view's steps are mutated in place (`meguruFreeWindow`), so it never builds a second viewer
  and never reproduced it.

  No throw is involved, which is the part this note got wrong for two rounds of looking: it
  insisted on a failure above the traceback, and the log above it was clean because there was
  nothing to log. The `pcall`s around the two re-opens are still right for what they were
  written for, but they were never the fix.

  **The guard is in `PanelZoom.open`**: `main_frame.dimen` is filled with `frame:getSize()`
  before `UIManager:show`, which is *exactly* what `FrameContainer:paintTo` would compute — so a
  viewer that never reaches the screen still has a frame the queued closure can read, and
  `paintTo` later only rewrites `x`/`y`. The cost is one wasted refresh of a phantom region.
  What would remove the class rather than the instance is not rebuilding at all: `-`/`+` could
  replace the step list in place the way the free view already does, which is the same change
  that would make a rapid press cheap on e-ink instead of a teardown per tenth.

