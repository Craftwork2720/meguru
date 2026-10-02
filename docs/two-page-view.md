# Two pages at once

The landscape two-page view: the imposition that decides which pages are shown together, the pair presented to the reader as one page, and the one interaction it has with the wide-page rotation.

Part of the design record; [CLAUDE.md](../CLAUDE.md) is the map.

## The imposition

**Which pages are shown together is decided by an imposition, and the imposition starts again after every wide page.** `meguru/spread.lua` is the whole of it, and it is pure: a page number, the page count, the ascending list of pages this session has found to be wider than tall, and the page the offset is anchored at go in; the unit that page belongs to comes out — `{ a = n }` for a page shown alone, `{ a = n, b = m }` for a pair.

Three rules, and the third is the one that makes it worth having:

- A page drawn as one wide image is a spread already. It is shown **alone**.
- So is a page whose *neighbour* is wide — a printed spread is never cut in half across two screens. Both fall out of the same test rather than being two cases.
- **The pairing starts again after a wide page.** Reading forward: (1,2), (3,4) … until page 9 is wide, and then 9 alone, **(10,11)**, (12,13) — the offset off, which is the default. A wide page consumes one slot and the run continues from the page after it.

The unit a page belongs to is therefore *not* a function of the page's own parity — it is a function of the last wide page before it, which is why `unitFor` takes the wide-page list rather than a page number's parity. There is no walk: the run start is the greatest known wide page below `n`, found by binary search.

**The offset is held as the page it is anchored at, and it is the run that page belongs to which is offset.** A switch cannot carry that, so the row *shows* the live answer (`spreadOffsetHere`) while the book *stores* a page — which is what makes one switch do both halves of what a reader asked for:

- **A wide page ends the offset by itself.** Anchored at the front, a book with page 9 wide reads: 1 alone, 2+3, 4+5, 6+7, 8 alone, **9** (the spread), then **(10,11)**, (12,13). The run after a spread is not offset, because the anchor is not in it — a printed spread has already shifted the pairing by the one page an offset exists to correct, and carrying it across would put the rest of the book out by one instead.
- **The reader can anchor it again from where they are.** Setting the row on page 10 anchors it *there*: 1+2, 3+4, 5+6, 7+8, 9, **10 alone**, (11,12), (13,14). That is the whole of "the reader has control" — the offset applies to the run it was set in and to no other.

The rejected rule was a flag that offsets **every** run, which reads 9 (spread), 10 alone, (11,12) — a reader who set the offset at the front of a book being told that every spread after a printed one goes out by a page as well. And the rule before *that* — "the offset shapes only the run that holds page 1" — left a reader past the first wide page turning the row and watching nothing happen, which is the one thing a row may not do. `tools/spreadcheck.py` prints these walks and checks that the offset reaches exactly one run.

Where a re-anchored offset meets the wide page before it, there are two single pages in a row: 9 is the spread, 10 is the run's first page. That is the shape to look at if the pairing after a wide page ever reads wrong.

It is also the reader's correction for the approximate case below, and the flip is what KOReader's gesture editor is offered (under *Fixed layout documents*, as *Toggle pair offset*) — a reader who meets a spread that has come out a page out is looking at the page, not at a menu.

**What the imposition cannot know is everything it was not shown.** The feed carries no page dimensions at all: a page's size is known only once its image has been fetched and decoded (`MeguruDocument:getPageDims`). Reading in order is exact — by the time a page is reached, it and its neighbour have been decoded — but a *jump* can land past wide pages nobody saw, and the run is then the one page 1 would have given. What the reader sees is a **parity flip**: two spreads shown the other way round, each page individually correct, until the next known wide page re-anchors the run. What settles it is the offset row, which moves the pairing of the run it is set in by one page.

## The page the reader is shown

**A pair is presented to the reader as one page, twice as wide, and then split as it is drawn.** KOReader has no two-page mode for a paged document — `getVisiblePageCount` is a reflow engine's and `ReaderPaging` never asks for two — so the alternative was to drive the layout from here. Instead the document answers the reader's geometry questions with the pair's box and splits the one rectangle it is asked to draw.

Which question matters is worth naming, because it decides the whole shape:

- `ReaderView:getPageArea` lays the page out from `getUsedBBoxDimensions` or `getPageDimensions` — exactly one of the two, by `use_bbox` — and those are the two seams that answer with the pair (`document.lua`).
- `ReaderZooming:getZoom` measures the fit from `getNativePageDimensions` and **refuses a bounding box larger than it**. So the *full* pair size has to be reported there too: a document reporting one page would have its pair-sized box rejected and the view fitted to a single page, and the reader would pan across a spread instead of seeing two pages.
- Neither box the reader lays out is faked. The **cropped** pair is what `getPageArea` is handed, the **full** pair is what the fit is measured against, and the crop being the smaller of the two is what keeps a cropped book cropped in the pair as well.

Everything else about a page keeps answering for one page, through `_pageGeom`: the blank-page rule and the page-number strip measure a band of the *printed* page, and a pair's box would move that band up the other page's height; the panel detector's probe grid is a page's. The process-wide `getNativePageDimensions` shim answers one page for the same reason in the other direction — an external plugin asking a page's shape to decide whether to turn the screen for a wide page must not be told that two pages lying side by side are one wide page.

`drawPage` is then a dispatcher. It cuts the window at the seam, translates each half back into its own page's coordinates, and hands each to the ordinary single-page path — so tone, dithering, night mode's invert, the tile cache and the "could not load" placeholder are all unchanged and all per half. A half that failed to fetch shows its own placeholder beside a page that loaded; the two halves land in distinct tile-cache slots because the key names the page.

Two decisions inside that are worth keeping:

- **Which page goes on the left is the reading direction's.** In a right-to-left book — manga, this plugin's default — the earlier page of a pair is the right-hand one. The document keeps its own copy of the answer (`spread_rtl`), seeded from the same sidecar key `ReaderView` reads and kept in step by the *Reading direction* row, because the document is the one that draws the pair and the document is opened before the reader exists.
- **Two pages cropped to different heights are top-aligned**, and the taller one sets the box. A single rectangle cannot express "this page cropped *and* that one cropped differently" *vertically* without per-page offsets in the split maths — the horizontal half of that problem is the gutter, below; two pages of one scan are the same size, and the mixed case is where to look if a seam ever looks wrong.

*A combined bitmap was rejected*: building one `BlitBuffer` twice as wide and blitting it once costs a full-page allocation per pair, needs its own cache and its own key, and gives nothing the two blits into the target do not — the split is strictly better on e-ink memory.

## The gutter

**The crop trims the pages' inner margins away, and the pair puts them back — as much of them as the screen has room for, and never more than the page had.** A page cropped tight to its artwork has nothing between it and the other page of a spread, so the two pages butt together at the middle; a printed book has white there, on the side that goes into the binding. This is the one place the pair's drawing is not simply two crops side by side.

**The row *Flexible gutter*, under *Two pages*, is whether the rule is asked at all** — on by default, because two pages butted together at the middle is the thing this exists to undo; off, a pair is drawn exactly as the crop left it. `MeguruDocument:_pairLayout` is the one place that asks, so the four sentences below are unchanged either way.

The rule is `Spread.gutter` (`meguru/spread.lua`), and **the order of its four sentences is the whole of it**:

1. The **outer** edges stay tight to the artwork. They are the crop's business and this does not touch them.
2. The **scale comes first**, and it is the fit of the artwork *alone* — the two cropped pages side by side, fitted to the screen. The gutter is not part of that sum, so it can never make the artwork smaller.
3. The **gutter is the leftover**: whatever horizontal space is still spare once the artwork is at that scale.
4. It is **clamped to the margins the pages actually have** — each half to its own page's inner margin. A screen with more slack than that leaves the excess at the sides rather than widening a margin the source has not got.

The two margins are read off the crop rather than assumed: `getPageDims` reports the *full* page and `getPageBBox` the content, so `dims.w - (box.x + box.w)` is exactly the margin the crop took off the left page's inner edge, and `box.x` is the right page's. **Nothing is assumed about which side of a scan carries a margin** — the commonest case of all is a margin on the inner edge of one page of the pair and none on the other, where the whole gutter lands on that page's side of the seam because the split is proportional to the two margins.

**Two cases answer zero without being special-cased, and both are right.** A page whose crop came back whole — "Crop: none", a mostly-blank page, a page that failed to load and was given the screen's own size as a stand-in — has its content edge *at* its page edge, so it has no margin to give. And a pair whose artwork already fills the screen width leaves no slack for a gutter to take.

The consequence to look for on a wide screen: **when the spare space is larger than the page's own margin, the margin is all the gutter gets and the rest is letterbox at the sides.** The artwork is never scaled up to fill a gutter the source does not have.

*Rejected: making the gutter part of the fit.* Fitting the pair *with* its margins would let a book with wide inner margins shrink its own artwork to make room for paper — the reader would lose page size to a margin. Ordering the scale first is exactly what makes the two impossible to disagree: the gutter is a consequence of the fit, not a term in it.

The screen the gutter is measured against is `CanvasContext:getSize()` — the framebuffer's *rotated* surface — because a pair laid out in landscape must be measured against a landscape screen. Being killed by the wrong one of the two is the whole difference between them, and it is the same source `meguru/ui/panelzoom` uses for its own orientation decisions.

It is the whole screen and not the area a visible status bar leaves, so a reader who keeps the footer gets a pair measured very slightly too wide: the reader then fits it by width, which scales the gutter down along with the artwork. Nothing is violated — the gutter only ever gets smaller than the margin it is clamped to — and the plugin hides the status bar by default, which is why this is a sentence and not a seam.

The pair's geometry is decided in one place, `MeguruDocument:_pairLayout`, and `_pairGeom` (the box the reader lays out), `drawPage` (the split) and `spreadPageAt` (the long-press) all ask it — they have to agree about where the seam is to the pixel, and asking one function is how they do. The seam is already visible in the existing paint line: each half's `region` is the widened one, so a log shows the extension the gutter added without a line of its own.

## Turning the page

**One gesture turns a whole spread, and the counter is what makes that necessary.** `ReaderPaging` moves `current_page` by one and knows nothing about pairs; left alone, a reader on a spread would spend a turn on its second page and see the same two pages painted again. So `_gotoPage` is wrapped (`ui/reader`'s `installSpread`) and the target goes through `spreadSnap`:

- a turn that stops **inside the unit already on screen** is a relative step — the reader's gesture, not a jump — and it means the neighbouring unit;
- a turn to a page **outside** the current unit is a jump (a table of contents, a percentage, a resume) and lands on the start of the unit holding it.

**The page number on screen, in the sidecar and in the progress report is the unit's first page.** `current_page` therefore never holds the second page of a pair, `meguru/progress` needed no change at all, and a resume lands on a pair rather than beside it. The flip side is the case `spreadSnap` cannot tell apart — a *jump* to the second page of the spread already showing reads as "one further" — which is in `docs/known-issues.md`.

At the end of the book the counter never passes the last page while the last unit is a pair, so nothing would announce the end; the wrapper says `EndOfBook` itself when a forward step has no unit to land on.

## Turning the screen

**While two pages are showing, `rotate_wide` does nothing at all** — it neither turns nor restores (`ui/reader`'s `updatePageRotation`). In landscape the pair is already the shape a wide page wants, so a turn would be pointless; and an undo would take the screen to portrait, which stops the pair, which makes the next page narrow again, which undoes the undo.

The rotation also reads `pageIsWide`, never `getNativePageDimensions`: that seam answers with the pair, and a pair is wider than tall by construction, so asking it would turn the screen for two pages that are only wide because they are lying side by side.

The shape this leaves is the one worth stating: in **portrait** with the view on "landscape", nothing about this feature is active and `rotate_wide` behaves exactly as it did before it existed — a wide page still turns the screen. In **landscape** the pair is what the screen is for, and the wide page inside it is simply shown whole.

Two other live conditions switch the view off, both because "two pages" would not mean what it says: **continuous scroll**, where pages are laid out one after another in a strip and would be a page in two slots, and any value of the row other than the three it names.

`syncSpread` is what turns a change in any of that into a re-layout — `ReZoom`, the same verb the crop rows and `Defaults.apply` fire. It is hung on the plugin's own `rotateTo`, on `ReaderView:rotate` (the reader's own rotation never comes through the plugin's), on `onSetScrollMode`, on the two rows, and on `ReaderReady` — that last one because `ReadSettings` has not run when the seams are installed, so a book the plugin preference gives "on" to still reads as off at that moment.
