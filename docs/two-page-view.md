# Two pages at once

The landscape two-page view: the imposition that decides which pages are shown together, the pair presented to the reader as one page, and the one interaction it has with the wide-page rotation.

Part of the design record; [CLAUDE.md](../CLAUDE.md) is the map.

## The imposition

**Which pages are shown together is decided by an imposition, and the imposition starts again after every wide page.** `meguru/spread.lua` is the whole of it, and it is pure: a page number, the page count, the ascending list of pages this session has found to be wider than tall, and the offset answer go in; the unit that page belongs to comes out — `{ a = n }` for a page shown alone, `{ a = n, b = m }` for a pair.

Three rules, and the third is the one that makes it worth having:

- A page drawn as one wide image is a spread already. It is shown **alone**.
- So is a page whose *neighbour* is wide — a printed spread is never cut in half across two screens. Both fall out of the same test rather than being two cases.
- **The pairing starts again after a wide page.** Reading forward: (1,2), (3,4) … until page 9 is wide, and then 9 alone, **(10,11)**, (12,13) — the offset off, which is the default. A wide page consumes one slot and the run continues from the page after it.

The unit a page belongs to is therefore *not* a function of the page's own parity — it is a function of the last wide page before it, which is why `unitFor` takes the wide-page list rather than a page number's parity. There is no walk: the run start is the greatest known wide page below `n`, found by binary search.

**The offset answer shifts every run by one page — a wide page's run included.** Off pairs from the run's first page — (1,2), (3,4), and (10,11) after a wide page 9. On leaves that first page standing alone and pairs (2,3), (4,5) — so a reader on page 7 sees 6+7, and page 9 wide gives 10 alone, **(11,12)**, (13,14). Two things follow, and both are deliberate:

- It is a shift of the whole book rather than a correction for its front. The rejected rule — "the offset shapes only the run that holds page 1" — left a reader past the first wide page turning the row and watching *nothing happen*, which is the one thing a row may not do.
- Where a wide page meets the offset there are **two single pages in a row** (9 alone, then 10 alone). That is the honest shape of "this run's first page stands alone, and this run starts at a spread", and it is where to look if the pairing after a wide page ever reads wrong.

It is also the reader's correction for the approximate case below.

**What the imposition cannot know is everything it was not shown.** The feed carries no page dimensions at all: a page's size is known only once its image has been fetched and decoded (`MeguruDocument:getPageDims`). Reading in order is exact — by the time a page is reached, it and its neighbour have been decoded — but a *jump* can land past wide pages nobody saw, and the run is then the one page 1 would have given. What the reader sees is a **parity flip**: two spreads shown the other way round, each page individually correct, until the next known wide page re-anchors the run. What settles it is the offset row, which moves every pairing by one page.

## The page the reader is shown

**A pair is presented to the reader as one page, twice as wide, and then split as it is drawn.** KOReader has no two-page mode for a paged document — `getVisiblePageCount` is a reflow engine's and `ReaderPaging` never asks for two — so the alternative was to drive the layout from here. Instead the document answers the reader's geometry questions with the pair's box and splits the one rectangle it is asked to draw.

Which question matters is worth naming, because it decides the whole shape:

- `ReaderView:getPageArea` lays the page out from `getUsedBBoxDimensions` or `getPageDimensions` — exactly one of the two, by `use_bbox` — and those are the two seams that answer with the pair (`document.lua`).
- `ReaderZooming:getZoom` measures the fit from `getNativePageDimensions` and **refuses a bounding box larger than it**. So the *full* pair size has to be reported there too: a document reporting one page would have its pair-sized box rejected and the view fitted to a single page, and the reader would pan across a spread instead of seeing two pages.
- Neither box the reader lays out is faked. The **cropped** pair is what `getPageArea` is handed, the **full** pair is what the fit is measured against, and the crop being the smaller of the two is what keeps a cropped book cropped in the pair as well.

Everything else about a page keeps answering for one page, through `_pageGeom`: the blank-page rule and the page-number strip measure a band of the *printed* page, and a pair's box would move that band up the other page's height; the panel detector's probe grid is a page's. The process-wide `getNativePageDimensions` shim answers one page for the same reason in the other direction — an external plugin asking a page's shape to decide whether to turn the screen for a wide page must not be told that two pages lying side by side are one wide page.

`drawPage` is then a dispatcher. It cuts the window at the seam, translates each half back into its own page's coordinates, and hands each to the ordinary single-page path — so tone, dithering, night mode's invert, the tile cache and the "could not load" placeholder are all unchanged and all per half. A half that failed to fetch shows its own placeholder beside a page that loaded; the two halves land in distinct tile-cache slots because the key names the page.

Two decisions inside that are worth keeping:

- **Which page goes on the left is the reading direction's.** In a right-to-left book — manga, this plugin's default — the earlier page of a pair is the right-hand one. The document keeps its own copy of the answer (`spread_rtl`), seeded from the same sidecar key `ReaderView` reads and kept in step by the Manga mode row, because the document is the one that draws the pair and the document is opened before the reader exists.
- **Two pages cropped to different heights are top-aligned**, and the taller one sets the box. A single rectangle cannot express "this page cropped *and* that one cropped differently" without per-page offsets in the split maths; two pages of one scan are the same size, and the mixed case is where to look if a seam ever looks wrong.

*A combined bitmap was rejected*: building one `BlitBuffer` twice as wide and blitting it once costs a full-page allocation per pair, needs its own cache and its own key, and gives nothing the two blits into the target do not — the split is strictly better on e-ink memory.

## Turning the page

**One gesture turns a whole spread, and the counter is what makes that necessary.** `ReaderPaging` moves `current_page` by one and knows nothing about pairs; left alone, a reader on a spread would spend a turn on its second page and see the same two pages painted again. So `_gotoPage` is wrapped (`ui/reader`'s `installSpread`) and the target goes through `spreadSnap`:

- a turn that stops **inside the unit already on screen** is a relative step — the reader's gesture, not a jump — and it means the neighbouring unit;
- a turn to a page **outside** the current unit is a jump (a table of contents, a percentage, a resume) and lands on the start of the unit holding it.

**The page number on screen, in the sidecar and in the progress report is the unit's first page.** `current_page` therefore never holds the second page of a pair, `meguru/progress` needed no change at all, and a resume lands on a pair rather than beside it. The flip side is the case `spreadSnap` cannot tell apart — a *jump* to the second page of the spread already showing reads as "one further" — which is in `docs/known-issues.md`.

At the end of the book the counter never passes the last page while the last unit is a pair, so nothing would announce the end; the wrapper says `EndOfBook` itself when a forward step has no unit to land on.

## Turning the screen

**While two pages are showing, `rotate_wide` does nothing at all** — it neither turns nor restores (`ui/reader`'s `updatePageRotation`). In landscape the pair is already the shape a wide page wants, so a turn would be pointless; and an undo would take the screen to portrait, which stops the pair, which makes the next page narrow again, which undoes the undo.

The rotation also reads `pageIsWide`, never `getNativePageDimensions`: that seam answers with the pair, and a pair is wider than tall by construction, so asking it would turn the screen for two pages that are only wide because they are lying side by side.

The shape this leaves is the one worth stating: in **portrait** with the view on "in landscape", nothing about this feature is active and `rotate_wide` behaves exactly as it did before it existed — a wide page still turns the screen. In **landscape** the pair is what the screen is for, and the wide page inside it is simply shown whole.

Two other live conditions switch the view off, both because "two pages" would not mean what it says: **continuous scroll**, where pages are laid out one after another in a strip and would be a page in two slots, and any value of the row other than the three it names.

`syncSpread` is what turns a change in any of that into a re-layout — `ReZoom`, the same verb the crop rows and `Defaults.apply` fire. It is hung on the plugin's own `rotateTo`, on `ReaderView:rotate` (the reader's own rotation never comes through the plugin's), on `onSetScrollMode`, on the two rows, and on `ReaderReady` — that last one because `ReadSettings` has not run when the seams are installed, so a book the plugin preference gives "on" to still reads as off at that moment.
