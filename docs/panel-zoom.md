# Panel zoom, and the panel sequence

The panel preference and its stock cascade, the detector, and the three views a long-press can open -- cropped panels, a window over the page, and the free view.

Part of the design record; [CLAUDE.md](../CLAUDE.md) is the map.

## Panel zoom, and the panel sequence

### The preference, and the stock cascade

**The stock cascade, left exactly where it is, with one answer of ours put underneath it.**
What a file gets is KOReader's own rule — the answer in the file's sidecar if it has one, and
otherwise the per-extension entry for its format:

```
the file's own answer (sidecar), if it has one
otherwise  the per-extension entry -- which has nothing to say for what this engine claims
```

The switch is ⋮ → **Panel zoom (manga/comic)** → *Allow panel zoom*, and it is the per-file one
that matters: an answer there is the reader looking at the page, and a file that answered keeps
its answer for good. `installPanelZoom`'s `onReadSettings` wrap is what fills the level below it
for a file nobody has answered for, and the answer it writes is **yes** — KOReader has no
per-extension entry for an extension it does not know, and "no entry" is not the same thing as
"no".

**There is no plugin-wide switch above that, and there was one.** A row (`Panel zoom in Meguru
books`) wrote `Settings.panel_zoom` and the wraps put it on every file that had not answered. It
was removed, by decision: it answered a question nobody asked twice, and the reader who wants no
long-press zoom in a book is looking at that book. What the row could do that the stock one
cannot is nothing the stock one does not already do better, so the choice is now only where it
matters. A `meguru_panel_zoom` key left in an old `settings.reader.lua` is read by nothing —
delete it or ignore it, the way `meguru.sqlite3` and `cache/meguru/` are handled.

**This replaced a design that named an extension, and the reason is a bug the naming
caused.** The row used to govern KOReader's per-*extension* entry for `meguru`, but
the plugin also opens `.cbz`, and the menu appears for those too, because the gate is
`doc.provider == "meguru"`. So a reader looking at a `.cbz` was shown the answer for
markers while the book in front of them followed the `cbz` entry: **the row said "off"
while the panels worked.** A preference for everything Meguru opens has no such gap.

Three wraps, and the third is the one that will be forgotten:

| wrap | job |
|---|---|
| `onReadSettings` | remember whether the file answered for itself, and when it did not, put **yes** where stock put the extension entry; the text-selection fallback is forced off |
| `onTogglePanelZoomSetting` | record that the reader just answered for **this** file |
| `onSaveSettings` | delete the per-file copy stock just wrote — unless that file answered for itself |

The ordering is what makes the first one possible at all: plugins load
(`readerui.lua:464`) **before** the `ReadSettings` event (`:484`), so the wrap is in
place before stock computes a value. `installPanelZoom` is called from
`Reader.install` for that reason.

**The line those wraps must not cross: a file that was only *opened* may not come
away with an answer of its own.** Stock writes the live field into the sidecar on
every save, so without that third wrap a book that was merely opened would come away
pinned on for good, and would ignore the reader turning it off for that book afterwards.
That is why "delete unless pinned" is not the same thing as the old unconditional
delete.

**Two costs are accepted here, deliberately, and neither is a defect to tidy:** a
file the reader switches with the stock row keeps a copy that outlives any change to
the preference; and a `.cbz` opened through Meguru can answer differently from the
same `.cbz` opened by KOReader's own reader, whenever nobody has answered for that
file. Both follow from "the preference is the fallback for everything Meguru opens",
which is what was asked for.

The preference's default is **on**, because that is KOReader's own default for
`cbz`/`cbt` and was this plugin's for markers: a long-press that silently does nothing
on a comic is a surprise rather than a neutral state. The fallback to text selection
is forced off with it: nothing on a streamed page is text, and that fallback reaches
`getImageFromPosition`, which no engine-less paging document answers.

**The `panel_zoom_enabled` entry for `meguru` that the old row wrote is now dead.**
Nothing reads it, and nothing sweeps it — delete it by hand or ignore it, the way
`meguru.sqlite3` and `cache/meguru/` are handled.

**Which plugin answers is decided by who patched the gesture last, and it is not this one.**
`pluginloader` sorts plugin directories by path, so `meguru.koplugin` loads — and `Reader.install`
wraps `hl.onPanelZoom` — *before* `panelsplus.koplugin` does. A plugin that wants this gesture
patches the same field and saves whatever it found as its "original", so Panels+ ends up
**outermost**, holding this plugin's wrapper as the handler it delegates to. That is the whole
mechanism, and it is why the cases come out the way they do:

| what is installed | who answers a long-press in a Meguru book |
|---|---|
| Panels+, **enabled** | **Panels+** — it is outermost and never calls down |
| Panels+, **disabled** | **this plugin** — Panels+ delegates to its saved original, which is ours |
| nothing else | this plugin |

**And this plugin never steps aside, which is what fixed the third row.** The wrapper used to
check whether Panels+ had patched the highlight and return to stock when it had — reading two of
that plugin's private fields to decide. Those fields are set when Panels+ *patches* and cleared
only when it *closes*, so they answer "has Panels+ taken this instance" rather than "will Panels+
answer this press". With Panels+ installed and switched off, the handler it saved is **Meguru's
wrapper**, and Meguru stood down on top of it: the reader got stock's single-region viewer, in
every book, and the two Meguru panel rows were hidden from them at the same time.

So the check is gone rather than corrected, and the wrapper does one thing: it handles the press.
Whether it is reached at all is then decided by the plugin that is above it — enabled, or off and
delegating — which is a fact about *their* state that they are the ones who can report.

**It reads nothing at all from the other plugin** — no name, no field, no `isEnabled()` — so a
rename or a rewrite on that side cannot make this wrong. What it *does* read off the class is
stock's own `onPanelZoom`, as the fallback for a press this detector cannot serve: a refused page
must land in stock's single-region viewer and never in a second sequence, or which engine ran
would depend on the page.

**There is no row for who owns the gesture, and that is a decision with a reason: one gesture
cannot have two owners.** Whoever wants Panels+ to answer says so by not having this engine open
that book — the two cannot both be the hand for one press, and a switch inside this plugin would
be a choice about code it does not own, drawn only while the rival is present, which is the shape
of row this file has already removed twice. The reader who wants Meguru's viewer instead is
uninstalling the other plugin, which is a change they can make and this one cannot.

**For the reader with both installed, that means:** Panels+ answers, and its own settings decide
how. Meguru's panel feature — through the ⋮ → Meguru rows and the file-manager surface — still
applies to the *preference* side of the cascade below, which is per file and independent of who
handles the press.

### The sequence

**A long-press shows the page's panels in reading order, one at a time.** It used to
show exactly one: the region under the finger, in a bare `ImageViewer`.

`meguru/panel.lua` is the detector, and it is pure: a decoded page goes in
(`Image.rasterFor`), ordered panels come out in **full native** coordinates. It
knows nothing about documents, pages or fetching — `MeguruDocument:getPanelsFromPage`
is the seam, and it hands over one decoded buffer and takes back a list.

**A panel is a quadrilateral, and its rectangle is only the box around it.** The
cut reasons about rectangles, because every projection and every gutter in it is
axis-aligned — but the panel a reader is shown is bounded by *lines*, and a panel
whose borders are slanted is the case this detector exists for. So a panel carries
both: `x, y, w, h` is the bounding rectangle, and `planes` is the four
half-planes of the quadrilateral inside it, `A*x + B*y + C <= 0` for the inside.
The two are the same rectangle on a page whose panels are square and differ by a
wedge wherever one is not, and that wedge is what a rectangle crop cannot help
showing — the strip of the panel next door that runs along the slant. `planes` is
what the crop is cut to and what a touch is tested against; the box is what MuPDF
is asked for, because a pixmap is a rectangle and a clip path is not available.

**The cut's own lines *are* the panel's borders, which is why this costs nothing
to know.** A sheared split puts its separator on the line of constant index in the
sheared projection — `y = split + slope * (x - xmid)` — and `xmid` is the region's
own mid-line, so the value the projection found *is* the separator's position
there. Measured against the reported page's ink map, column by column, that line
reproduces the tier separator to within half a cell, and at the region's two ends
it lands on 285 and 247 where the panel's own border does. So the geometry was
always there and the old code threw it away, keeping the integer `split`; `cut`
now carries the four edges down the recursion and a leaf keeps them. A side the
*trim* moved inward is the panel's own border and becomes that constant; a side
still sitting where the region's was was made by a split and keeps the split's
line.

**A panel is a band of a page, and the cut finds it by slicing on the widest empty
band.** The page is scaled to a 480-pixel *width* scan; the background is the
**median luminance of the outer one-percent ring** — the median and not the mean,
because a ring that is three quarters paper and one quarter a bleed has a mean the
page does not contain anywhere — and a cell is ink when it departs from it by more
than `PANEL_INK_DELTA`. The map is then sliced recursively: find the widest empty band
across the region, split there, recurse into both halves, and stop when a region has
no empty band left. Comic and manga pages are laid out as nested bands — a page splits
into tiers, a tier into panels — so the cut reproduces that structure directly. The
one piece of the reference's background estimate that is not redundant is carried
over: a mid-grey median is overridden to white when some row or column of the page is
genuinely near-white, which recovers a paper colour dimmed by a scan.

**The map is 1.3's with that one exception, and "a faithful port of 1.3" was true of
the cut and not of the input to it.** The override comes from the *newer* reference,
which has a colour-aware map; 1.3's `_pagebitmap.lua` is 327 lines over a single
grayscale scalar with no colour path at all. The override is kept — it is earned on
dimmed scans — but it is named here so it is not mistaken for part of the port, and
it cannot have caused the pale-band failure above: its condition needs the ring
median in `[32, 224)`, and a page with a white band has a white border.

The one input that *was* wrong is the luminance, shared with the crop scan; see the
colour section for what the mean did to a tinted page and why the fix is a formula
rather than a threshold. **Anything that reads this map reads a luminance, and every
new reader of it must too** — a consumer that computes its own brightness is how the
divergence that produced a spurious panel got in.

Two things complicate the cut, and both are ported. Panels are rarely drawn square,
and a gutter tilted by two degrees leaves no column empty from top to bottom — enough
to stop the straight cut dead. When no straight gutter exists and an axis already has
a near-empty line, a ladder of slopes from under a degree to eight and a half either
way is tried instead and the projection is taken along the slanted line. **The split is then one line
through the middle of the empty run that projection found** — a run of empty *lines*
in the sheared projection is a run of empty *columns* through the region's own
mid-height, because `shift` is measured from the region's mid-line and is zero there —
and the two children are cut apart at it, so their crops do not overlap at all. A
rectangle cannot follow a slanted separator, so each child keeps a wedge of its
neighbour on one side and gives one up on the other; which way round that falls
depends on where on the page the reader is looking, and it is the price of the crop
being axis-aligned.

**The ladder's step is 0.015, and it was 0.035 — a reader found the reason.** They
reported that panels separated by a *slanted* gap merge more often than square ones,
and that is the shear's own arithmetic: `floor(slope * (x - xmid) + 0.5)` means a
ladder half a step off the true angle walks the gap across the region, and at 0.035
the drift over a 480-cell width is up to 8 cells. A separator two cells thick then
spreads over three or four projected lines and **none of them is empty**, which is
the one thing `PANEL_SHEAR_INK_RATIO` will not forgive. The measurement, on the
second chapter: a 0.005 step — six times the work — gives the *identical* panel
count on every page tried, so 0.015 is not a compromise; the finer ladder moves one
page (its 35, 3 panels to 4) and nothing else, including the first chapter's
reference page at 6 panels, whose tier separator sits at 0.115 and is therefore
nearer this ladder's 0.120 than its 0.105.

**Handing both children the whole projected band is what this replaced, and it is the
worst defect this detector has had.** Widening the run by `drift` at each end gives the
axis range the separator sweeps over the *whole* region; both children were given all of
it, so each crop overlapped the other by twice the drift and the cut itself landed up to
`drift` cells away from the separator. `drift` is `|slope| * extent / 2`, which on a page
whose tiers are tilted is not a wedge but most of a panel: on the reported Kavita page —
480-wide scan, 6.5 degrees, a 482-cell region — `drift` is 28 cells, a 5-cell run became
a 61-cell band, and a two-panel split cut 30 cells above the boundary left one child
holding the bottom of both tiers. That child then had the tier's black border line
running through it, which is ink where the *next* split needs emptiness, so it never
split again and came out as one panel where the page has two; and the child on the other
side of the band was carved into thin full-width strips by the recursion re-finding the
same band. The page went from `7 panels` to `6` and from one of them being right to five,
measured with `tools/panelprobe.py`.

The two ratios are separate constants (`PANEL_GUTTER_INK_RATIO` and
`PANEL_SHEAR_INK_RATIO`) and the reason is arithmetic rather than taste: the sheared
projection samples every `PANEL_SHEAR_STEP`-th column, so a line's count comes from half
as many cells and carries twice the variance, while its `span` is `width / step` — so
the same ratio buys the same cells of allowance on a noisier projection. Give it the
straight cut's ratio and a near-empty line *through white artwork* reads as a gutter; the
shear then splits a panel down the middle of its own drawing, each child re-finds that
line a little higher up (the found extent moves as the region shrinks), and the strip it
peels off at the end is emitted as a third panel that is really the gap. That is exactly
what a page of two panels divided by a skewed white band did: `2 panels` became `3`, the
middle one carrying the bottom of the upper panel and a strip of the lower. Requiring the
sheared line to be **empty** — the same standard the straight cut is named for — gives
two panels, and on a sample of two dozen pages it changes nothing else.

**A second rule guarded the band's other symptom, and it is now inert.**
`segment` drops **a leaf contained entirely in another leaf**, on the map's cells before
the conversion to native, where the comparison is exact. It was written for what the band
did next: a child split again on the band it had been handed left a strip behind whose
top reached back over the other child's box, so the reader saw the same artwork twice and
the lower panel lost its top. It was measured over two dozen pages of two chapters then,
and fired on two of them. With the split taken as a line the children are disjoint along
the axis they were split on and a trim only shrinks one, so no leaf can contain another —
across the 23-page sample it now drops nothing. It stays because that is a property of the
shape of the cut rather than of this code: it costs a few hundred integer comparisons on a
list capped at `PANEL_MAX_PANELS`, and the change that would make it live again is a change
to the cut. Removing it on the evidence of a sample where it does nothing is the exact
mistake its own history records — see the comment in `segment`.

The two rules cost different things and neither is free. The strict ratio could
regress a page whose separator is a real gutter carrying JPEG noise, since the sheared
line must now be genuinely empty. The containment rule drops an **inset panel** — a
small panel drawn inside a larger one — which is believed rare (the surround would
have to be a rectangle for the cut to produce one) and has not been measured on a page
that has one; if a small panel ever goes missing, that is the first thing to look at.
The other is page furniture: a scanlation
credit line clears both size floors comfortably, so `emitLeaf` rejects it on the
*conjunction* of elongated and nearly inkless. Neither test works alone, and that
function's comment carries the measurement that says so.

The scan targets the page's **width**, not its long side, and that is not cosmetic: a
1600x2400 page maps to 480x720 — one cell per 3.3 page pixels, so a 10-pixel printed
gutter is 3 cells wide. A ceiling on the long side would give 320x480, one cell per 5
pixels, and the same gutter 2 cells wide. `PANEL_SCAN_MAX_CELLS` then caps the cell
count, and it first bites past 5.2:1 — a webtoon strip, and only a webtoon strip.

**A separator one line thick is a separator, and the floor was refusing it.**
`min_gutter` was `max(2, floor(min_dimension * PANEL_GUTTER_RATIO))`, and on this scan
geometry the shorter side is the *width* — 480 for every page that fills the screen — so
`floor(480 * 0.005)` is 2 and the floor never bound. The second reported chapter has
nodes that merge with a line already *under* `PANEL_GUTTER_INK_RATIO`: a row with 2 ink
cells out of 450 against an allowance of 2.25, a column with 2 out of 198. They were
refused for being alone. **`PANEL_GUTTER_RATIO` is 0.004 and the floor is 1** — two
numbers because the floor alone cannot do it: 0.005 of 480 floors to 2 whatever the
floor says. Measured over 21 pages the change moves exactly two of them — `p33` 2→3 and
`p100` 1→2 — and leaves every other page identical, including all three full-page
illustrations, every dense action page, and both control sets. The other merged nodes on
those chapters have no such line at all (82 ink cells out of 480) and stay merged; see
Known open items for the three ways that was measured against.

**The thresholds are 1.3's, and this is the part to read before "improving" anything
here.** `panels_plus` ships this same cut; its later version loosened
`segment_gutter_ink_ratio` from 0.005 to 0.05, doubled the minimum panel area and
switched `segment_shear` off. Porting that later version's code *with its own numbers*
produced exactly what a reader would report: a panel cut in half on a white band
inside its own drawing, because at 0.05 anything faintly bright counted as empty; and
no cut at all on a skewed page, because the only answer to tilt had been turned off.

| | 1.3 — used here | later version |
|---|---|---|
| gutter ink ratio | **0.005** | 0.05 |
| shear | **on** | off |
| min panel area | **0.005** | 0.01 |
| live detector | this cut | connected components |
| what the components give | **a veto on a split** | the panels |

**The connected-component detector is deliberately not ported as a detector.** It
groups ink into connected bodies and keeps each one as a box, merging only boxes that
entirely contain one another. So a component and the panel it sits inside stay two
boxes, and the reader sees the same panel twice with slightly different crops. The cut
cannot produce that: its leaves are disjoint by construction. That is the whole
argument, and it is why "the reference's live detector" is not by itself a reason to
port something — the reference's live detector is whatever its authors last switched
on, not a verdict.

**Its bodies of ink *are* ported, as a veto on the cut — and that is what closes the
`05790d1` question rather than re-opening it.** `05790d1` replaced the cut with the
component detector on the grounds that a genuinely white band *inside* a panel was
being cut in two; `9c9f042` put the cut back, on the grounds that the component
detector showed the same panel twice — and neither commit had a device reading behind
it. Both were right about their own symptom and neither had to lose: the cut keeps the
detection and the crop, and the bodies say only where a panel's box *is*, so a split
can be refused when its band would run through one. So the thresholds are the part to
keep *and* the algorithm is not the part to swap — what came across is the evidence,
not the pipeline.

`meguru/panel`'s `collectBodies` is the reference's `collectComponents` and the frame
evidence it carries, and nothing else. Left behind, each for its own reason: the
containment rule (a box inside another is a *subset* of the veto it is already under,
so it would be dead weight), the sampled small-box frame test, the joining of floating
bodies to the framed neighbour or tier they belong to, and the tier grouping — none of
which the veto needs, because it wants a panel's box and not the final list of panels.
`lineSupport` and `frameSides` are 1:1, values included, and the five `PANEL_BODY_*`
constants are the reference's own; the prefix is this file's so that what they feed is
not mistaken for a detector. The one structural departure is that the scratch arrays
are allocated per call rather than held for the process with a `clearScratch` to release
them: a detection is a long-press, the peak is the same either way, and a second
lifecycle is one more thing to keep in step.

**The rule, and the drawn page that decides it.** A candidate split is refused when the
band it would cut on lies strictly inside a framed body's box on the cut axis *and* the
body spans the region on the other — a band at the body's own edge is that body's frame,
and cutting along a frame is what the cut is for. Refusing one candidate leaves the
other axis to be tried; refusing both leaves the region emitted as **one leaf**, and the
sheared search is not entered at all, because an empty line that ran through a detected
panel is evidence that the region *is* that panel and a slanted split of it is the same
mistake at an angle.

The page that proves the rule is drawn rather than found, and the arithmetic is why the
control that already existed could not do it: **a row of the band carries the panel
frame's two vertical strokes**, and a row counts as empty only while it holds at most
`PANEL_GUTTER_INK_RATIO * span` cells — 2.21 of the 443-cell span a 1600-px page maps
to, one cell being `native_w / 480` page pixels. A 5-px stroke is 2 cells a side, so
4 > 2.21 and `controls/02_white_band_inside` does **not** reproduce the failure: the cut
returns one leaf there, and always did. A one-cell frame does. On a 480x720 page, where
the scan *is* the page, a framed panel with a dense stipple and a full-width hole
through its own drawing gives **2 leaves without the veto and 1 with it** — the panel cut
in half at the hole, and then whole — while the same page with the hole stopped short of
one side gives 1 either way, which is the guard's other half: it must not fire where the
band was never a gutter. In the probe the whole thing is visible in three lines: the body
`19,19 443x683 sides=4`, `veto rows 345..374 runs through body 19,19 443x683`, and the
leaf count. `--noveto` is that same run with the body pass emptied, and it is byte for
byte the parent commit on every page tried.

**On the 15-page sample the veto changes nothing at all, and that is the honest result
rather than a reason to drop it.** All 15 come back with identical leaves — counts and
boxes both — before and after; two of them (p113, p115) refuse a candidate that the
other axis would have won anyway. The reason is that the cut on this chapter mostly
*merges*: p112 returns the whole page where the component detector returns four panels,
and merging is the one failure a veto cannot make worse. The rule is kept for the same
reason the containment filter is kept — it guards an invariant this sample does not
happen to exercise — and the drawn page above is the evidence that it lives.

Also not ported: the comic border-stroke plane (`segment_border_split`), off in 1.3's
own defaults and for a good reason — at map resolution a shared border between two
bled panels and a black line drawn *through* one panel produce byte-identical maps, so
the pass splits real panels in half on any page carrying such a line.

**There is one detector, and it replaced two.** `getPanelFromPage` used to carry its
own conservative gutter scan as the fallback; two detectors meant two different crops
for one page depending on which path asked. It is now a thin wrapper returning the
panel `Panel.indexAt` finds under the touch, and it passes a **constant** direction:
in the detector the mode orders the list and nothing else, and this function returns a
rectangle rather than an index, so the order cannot reach the answer.

**Order is a reading direction, and the direction is the book's.** The list is grouped
into rows by each panel's **top edge**, with a tolerance that shrinks with the
shortest member seen so far — measured against the row's *fixed* top and never chained
from the previous member, which is what stops a staircase of slightly lower panels
from growing one row down the page. Each row is then sorted left-to-right for a comic
and right-to-left for a manga, and a panel that sits beside a tall later-row neighbour
is held until after it (the `1,2,3,5,6,7,4` order). The direction comes from
`Reader.panelZoomMode(ui)`, which reads `ui.view.inverse_reading_order` — **not**
`Settings.get("manga_order")`. That preference is only the floor of KOReader's
cascade; the view holds the resolved value, which is what turning a page already
obeys. The document is told the mode rather than reading it, because a document has no
view.

**The viewer is four overrides on `ImageViewer`, and stock does the rest.**
`ui/panelzoom.lua` passes a list of **lazy functions** — `ImageViewer:init` and
`switchToImageNum` both call an entry that is a function — so panels the reader never
reaches are never rendered, and each render goes through `drawPagePart`, whose LRU
decides whether it is fresh work. `image_disposable = false` everywhere: those buffers
belong to the document's tile LRU, and `cacheTile` is what frees them.
`images_keep_pan_and_zoom = false` is what makes the navigation *classic*: a panel
opens at best fit instead of inheriting the previous panel's pinch.

**The viewer draws no chrome, and the last piece to go was stock's progress bar.** It
is turned off with `images_list_nb = 1` in `PanelZoom.open`, which is *not* a count:
stock builds, draws and frees the bar behind one `_images_list_nb > 1` test, so the
field is the switch and nothing else. That the reader shows no bar either is the reason
it went — Meguru hides the footer, and the progress bar lives in the footer.

**`images_list_nb` must not be read back as the panel count, and this is the edit that
would break panel navigation silently.** `onShowNextImage`, `onShowPrevImage` and
`meguruWarm` all bound themselves by `#self.panels`, which is the truth; with the field
at 1, a bound taken from it makes every forward gesture fall through to the page
boundary, so the second panel becomes unreachable and the symptom looks like broken
navigation rather than a hidden bar. **`tools/check.py` cannot see this**: it keys on
names, and a field reached through `self` is not one. The gesture is the test.

The four overrides are `switchToImageNum` (recompute `rotated` per panel, then release
the one left behind, then re-arm the warm), `onShowNextImage` / `onShowPrevImage`
(boundary past either end), and `onTap` / `onSwipe`. **Those last two exist for one
reason:** stock picks the sides from `BD.mirroredUILayout()` — the UI language — and a
manga read in a Polish UI gets stock's answer backwards. Everything else is delegated
to stock, including the tap outside the frame that closes the viewer and the
bottom-left screenshot corner, which are deliberate gestures this must not quietly
take over. The hardware keys come free: `ImageViewer:init` binds `PgFwd`/`PgBack` to
next/previous image and `Back` to close whenever `image` is a list.

**A panel is turned the book's way.** With `Rotate wide pages: left` the *page* goes
left, and a panel wider than the screen used to be able to go right: the page is
turned by `Screen:setRotationMode` in the setting's direction, while a panel is turned
through stock's `rotated` — a **boolean**, whose 90-vs-270 direction stock computes
*inside* `ImageViewer:_new_image_wg` from screen parity and two KOReader globals, with
no caller-facing input. So the direction has to come from somewhere, and it comes from
the same row.

**The two words map onto opposite quarters, and that is the part to get right.**
`Rotate wide pages: left 90°` names a turn of the **device** — the screen is rotated and
the reader turns along with it, so the row's word describes what happens to the hand,
not to the glass. A panel has no device to turn: it is rotated *inside* the screen the
reader is already holding, so the same reading position is reached by the opposite
quarter. Left in the row is a counter-clockwise device, so a **clockwise** panel.

That crossing was first derived the *other* way, from stock's own comment
(`rotate_clockwise and 270 or 90`, "unintuitive, but this does it"), and the device then
turned panels the wrong way — which is the cheapest possible lesson in why a mapping
read off upstream's prose is not an observation. The fix was the two constants in
`panelRotationAngle` and nothing else, which is the shape this was designed to fail in.

The two rotation questions are **split, and that split is the design**:

| question | answered by | source |
|---|---|---|
| *whether* this panel is turned | `panelRotations` + stock's `rotated` | the panel's shape against the screen's |
| *which way* | `panelRotationAngle(self.rotated, self.rotate)` | the book's `Rotate wide pages` |

`rotate` is `"left"`/`"right"`/nil, resolved once per press by `Reader.panelZoomDirection(ui)`
in `ui/reader.lua` — reading `configurable.rotate_wide_pages`, **never**
`Settings.get("rotate_wide")`, because that preference is only the floor and every book
already opened has written its own answer into its sidecar — and handed to `PanelZoom.open`
beside `mode`, including through the handoff, which is the half that is easy to forget and
fails only at a page boundary. nil is the row off, and then every rotation decision is
stock's, byte for byte.

**The Rotate button needed no change at all, and that is the proof the split is right.**
Stock's callback flips `self.rotated`; the resolver reads it. *Whether* belongs to stock,
*which way* to us, so the button keeps working, its `Rotate` / `No rotation` label stays
true, and nothing has to be kept in step. The same property gives "a tapped rotation lasts
one panel" for free: `switchToImageNum` already reassigns `rotated` from the automatic
decision on every change, so the press is scoped to the visit with no state to carry.

**Where the direction is applied is a correction after the fact, and it is worth knowing
why that is safe.** Passing an angle would mean copying `_new_image_wg`. It does not have
to be copied: `ImageWidget` defines no `init` (`Widget:new` calls one only when it exists),
and `_render` — the only reader of `rotation_angle` — is entered from `getSize`/`paintTo`
and returns at once when `_bb` is already set, which nothing does before the first layout.
So `PanelViewer:_new_image_wg` calls stock and then writes the angle, and between the
widget's construction and `update`'s first `resetLayout` that is equivalent to having
passed it. A guard plus a once-per-process `logger.warn` makes the assumption checkable;
if it ever fires, the repair is the forked override, and the device check that shows it is
item 21.6.

Rejected, each for a reason worth keeping: **pre-rotating the tile** (`BlitBuffer:rotatedCopy`)
— a buffer outside the document's tile LRU that the viewer would have to own and free,
and it would leave the automatic path on the boolean while the manual path used the tile,
two mechanisms for one outcome; **forking `_new_image_wg`** — ~30 lines of upstream that
then silently diverge as upstream gains parameters; **turning the screen**
(`Screen:setRotationMode`) — a rotation `rotate wide pages` already owns for pages, with
`session_wide_rotate` to keep in step, and it turns the whole UI rather than the panel;
and **writing `imageviewer_rotation_portrait_invert` / `..._landscape_invert`** around the
parent call so stock computes our direction — it mutates a reader's global settings, and
any save in that window persists it.

**Pre-warming is two machines, and neither is new.** The *panel* half reuses the tile
LRU: `drawPagePart` already stores what it renders under `page|panel|region`, so
rendering the next panel a moment after showing this one makes the swipe a cache hit.
The *page* half warms the next page's decode **and then its panel detection** — in
that order, and the order is load-bearing. `getPageDims` is the decoder and the thing
that fills `self.dims`; `getPanelsFromPage` prepares a page through `panelNativeFor`,
which fetches and decodes but never touches `self.dims`, so calling it first would
leave the dims cache empty and the page turn the reader is about to make would fetch
the same page again. Dims first means one fetch, one decode, a native-LRU hit for the
scan, and both memos filled. One scheduled action re-arms on every panel change, and
the delay is the point — a reader swiping quickly re-arms and unschedules faster than
it, so the warm never does work they did not ask for. The guard is
`UIManager:isWidgetShown(self)`, which is the whole bookkeeping: a viewer that has been
closed or handed off is off the stack, so its queued warm is a no-op. Both branches are
gated on `dead_pages` and the page branch on `hasConnection()`. **Do not add panel
detection to `analyseAhead`**: that runs inside every page turn, and a scan per turn
is exactly the cost this delay exists to keep out of the gesture.

**The panel cache is four entries, in RAM, keyed on the page *and the direction*.**
Detection walks a few hundred thousand cells, so the answer is worth keeping — but only
for the window a reader moves in from the panel viewer, which is "this page, the next
one, and back again". It caches the **refused** answer too: a refusal costs exactly
what an acceptance costs, and a refusal is a real answer now, so a splash-heavy book
would otherwise be rescanned at every press. The key carries the reading direction
because the direction reorders the list, and a Manga-mode flip mid-session must not be
answered from the other direction's order. It is a **self-ordering array, not
`evictOldest`** — that one stamps through `self.stamps`, which `native` shares and keys
by a bare page number — which is the same reason `page_bytes` is shaped that way. A
page that could not be *decoded* is deliberately not cached: `fetch_failed` and
`dead_pages` already remember the two ways a page goes missing, and a third answer
would be a third thing to keep in step.

**A page the detector cannot read opens the whole page, not nothing.** `Panel.detect`
returns `panels, accepted, reason`, and `panels` is never empty once the page was
readable: a refused page comes back as one rectangle covering the whole page with
`accepted` false and the failing test in `reason`. So a long-press always has something
to open, and the log can always say which of the two it is looking at — `K panels`
versus `K panels, whole page (<reason>)`. This is why the reader's gate is
`if not panels` rather than a count: `nil` means exactly one thing now, that the page
would not decode, and that is the single case that still falls through to stock. The
cost is that a page the detector *misjudges* shows the whole page where stock would
have cropped one region; the acceptance tests are what hold that back, and the reason
string is what makes it diagnosable when they don't.

**`releasePanelTile` is memory, not correctness — and the difference matters, because
the wrong reason has been written down once already.** `evictOldest` frees a tile's
buffer, so the fear was that it could free the bitmap the viewer is displaying. It
cannot: `drawPagePart` bumps on every hit and `cacheTile` bumps on insert, so the panel
on screen is always the most recent entry and eviction takes an older one. The real
cost is the other direction — one dead panel tile per step, up to seven of them at 8
entries, each bounded only by `max_native_pixels`, **and** the page tiles ReaderView
needs evicted alongside. Handing each panel back keeps the LRU at two: the one on
screen and the one warmed. The key is built by one function (`panelTileKey`) read by
both the write and the release, because a key that drifts frees nothing and says
nothing. The price is the one this design was asked for: **going back to a panel
re-renders it** — from bytes still in the page LRU, so still offline, but re-rendered.

**The page boundary is four statements in a fixed order.** At the last panel, forward
means the next page; at the first, back means the previous one, opened at its last
panel. Inside one `tickAfterNext`: resolve the next page's panels **first**, so a page
that will not decode leaves the reader where they were rather than dismissing their
viewer and handing them nothing; close the viewer **second**, before the turn, because
a page turn can reach `installEndOfBookHook` and swap the whole reader out — a viewer
still on the stack would float above a different book; then `GotoPage` (exact, unlike
`PageForward`, which is a "next view" that is a page only because this plugin forces
`page_scroll` off); then open the new viewer against the layout that resulted. The
panel lookup is gated on `hasConnection()`. The cost, accepted: the reader paints the
new page under the viewer, so a boundary crossing is one extra e-ink pass.

**Logging follows the frequency rule.** `Meguru: page N panel zoom: K panels, whole
page (<reason>) (mode) in X ms` — the milliseconds are the measurement of the scan, the
cut and the acceptance tests, and the only place their cost can be seen; the bracketed
form is what separates a refused page from a page that genuinely has one panel, and
those need opposite fixes. `... no page (<reason>)` is the one case with nothing to
open. The stand-down is `info` — a decision, once per process. A detection or handoff
that *throws* is `warn`, which is what `crash.log` is read for. There is deliberately
**no** separate "panel warmed" line: the existing `panel zoom on page N, region ...
rendered WxH` already fires once per panel render, including once per warm. The one
line that names the *view* is the viewer's own open line — `... (mode) window view,
step S of T`, `... (mode) cropped panels`, or `free zoom opened on page N (mode, level)`
— and the step count is deliberately not
`K panels`: the two are the same detection and different walks, which is the whole
point of the second view. **The free view has its own line rather than a branch of that
one**, because a line written for the other two reads `#panels` — a value that became
optional the moment a view without panels existed, and which shipped as `attempt to get
length of local 'panels' (a nil value)` on the first device run. It is also logged
**before** `UIManager:show`, and every path out of `open` should be: nothing after that
call may throw, or a viewer is left on the stack while the caller is told the open failed
— and the caller falls back to stock with a Meguru viewer still up.

### The other view: a window over the page

**A long-press opens one of two views, and the preference picks which.** Cropped — the
panels cut out of the page, each its own image, quad-masked. Or *window*: the page
stays whole and a rectangle moves over it at one fixed zoom, anchored to the panel's
edges. `meguru/settings.lua`'s `panel_view` is the value, and **the only control for it is the
switch at the front of the viewer's own button row** — there is no menu row, which is argued
below. The switch names the three views `Panel Cut`, `Pan & Zoom` and `Free View`; this document
calls them the cropped view, the window view and the free view, and they are the same three — the
label is what a reader reads and the prose is what the code is called, so neither is a rename of
the other.
**Window is the default** — a choice rather than a measurement: it shows the page as it
is, so a panel the detector merged, or a border it read wrongly, still shows the artwork
that is there, at the price of a strip of the neighbour at the window's edge, where the
cropped view would have cut it away. A *refused* page ignores the preference, because a
page the detector would not decompose is one whole-page rectangle and a window would cut
it into a top and a bottom nobody asked to step through. Everything else — the detector, the reading order, `Panel.indexAt`,
navigation, the pre-warm, the page boundary — is one implementation for both, which is
what makes this a second view rather than a second feature.

**Both window views work their zoom out from the page's *content*, not from its raw scan.** A
scan usually carries a white border, and a fit that counted it gives magnification away to
paper: a tenth of the page in margins is a tenth of the zoom lost, and a panel that only just
fails to fit the window costs a whole extra stop for the strip of blank it is missing. So the
**fit** is measured against the content box — the `1` that a level is a multiple of, and the
floor of the free view's range. The crop decides how close a level is, and nothing else.

**The window is still the whole page, and that is the half that matters.** Nothing is rewritten
into another coordinate space: the panels, the windows and the reader's finger all stay in the
page's own coordinates, so a stop is anchored to the panel it names with nothing in between to
get an origin wrong. The margin is not taken from the reader either — the window stays clamped
to the *page*, so it can be moved onto a margin, and a panel whose border sits in one still
anchors to it. This replaced a version that measured **in** the box, moving the panels and the
touch point into it and the steps back out; that one made the margins unreachable and put every
stop one origin mistake away from naming the wrong rectangle, for no gain the fit alone does not
give.

**The box comes from `getPageBBox`, and that is the reader's own answer rather than ours.**
That seam is `autoContentBox`'s margin scan when *Page Crop* is auto, a detected page-number
strip when that row is on, and **the whole page when the reader has cropping off** — so the
two views follow the setting instead of second-guessing it, and switch themselves off exactly
when the reader asked for no crop. `contentDims` is the whole of it, and its three refusals are
what keep the change inert where it has nothing to do: no crop, a page the scan refused, and a
box that is simply the whole page. A box it cannot *read* is refused too, `pcall`ed, because
that seam may be `pagenumbercrop`'s and a foreign plugin's throw must cost the crop and never
the long-press. Since only the box's **ratio** to the page is used, the units it arrives in stop
mattering — native pixels, a foreign plugin's, anything proportional measures the same.

**The same level is therefore closer than it was before the crop, and that is accepted rather
than overlooked.** A tenth of the page in margins was a tenth of the magnification the fit was
giving away, so taking it out of the fit shortens the whole ladder: at the level a reader was
on, the window covers *less* page than it did, and a panel that fitted in one pass can now need
two or four. Measured on a 1600x2400 page with a 1500x2200 content box, a 1000x1400 panel at
1.7 goes from **1 pass to 4**. The trade is the bottom of the range — at 1.0 the window covers
the artwork rather than the artwork plus its paper, so a fat-margined scan is no longer
permanently under-magnified — and the reader who wants the framing they had presses `-` once.
**Nothing here is to be "fixed" back**: the level a reader lands on is remembered by
`meguru/settings`, so the adjustment is once per reader and not once per page, and the default
level is left where it was rather than bent to hide the shift.

One consequence of the same kind, in the free view: its remembered zoom is a *scale*, screen
pixels per page pixel, so a crop that moves the fit does not move what the reader asked for —
1:1 stays 1:1 and a remembered magnification stays what it was, while the same scale is now a
smaller multiple of the fit.

**A step is a rectangle of the page, and nothing is cut.** Where the cropped view asks
`drawPagePart` for a panel at the region's own size, the window asks for a viewport at
*screen* size: `tw`/`th` are two optional arguments the cropped path passes as `nil`, so
its call is unchanged to the byte and `Panels+` — which calls `drawPagePart` directly —
never sees them. The tile is filed under `panelTileKey` **plus its size**, because the
same rectangle at another size is another picture and the size cannot be recovered from
the rectangle. That is also why `meguru/viewport` rounds its windows to whole page
pixels: the key formats the rectangle with `%d`, so a fractional window would be filed
under a key naming a rectangle it was not rendered from, and two windows a fraction
apart would share a tile. Rounding is what makes the render-path log line truthful too.

**The zoom is a scale, and it is the one number that had to change shape.** `Viewport`
used to hold a constant of its own; it now takes *screen pixels per page pixel* from its
caller, because that is what a level is once it stops being hardcoded:
`fitScale(dims, screen) * level`, with the level the reader's. The geometry does not store
it — but it is no longer true that it never *chooses* one, and the exception is the next
paragraph.

**And `fitScale` is the page's width on the screen's width, not "the whole page fits".** A
level is therefore always "how much wider than the screen the page is": 1.0 is a page exactly
as wide as the screen, 1.4 one forty percent wider, and the definition reads the same on a
portrait screen, a landscape one, and a page of any shape. `dims` is the page's **content**
where the reader's crop gives one, so a margin is not part of what a level is a multiple *of*.

| | the measure this replaced | now |
|---|---|---|
| what 1.0 means | the whole page fits | a page as wide as the screen |
| the same level on a page of another shape | a different magnification | the same |
| same level after rotating the device | **22% closer standing up than lying down** | 29% closer in landscape, because a wider screen is more room |

That 22% was the bug that produced the change, and it is worth keeping the shape of: a
*minimum* over two ratios is the page's height on a portrait screen and its width on a
landscape one, so a wider screen lowered the fit instead of raising it. Neither property was
chosen; both fell out of taking a minimum. The cost is named and accepted: **the whole page is
now below 1.0**, so these two views can never show it at once — a page taller than the screen is
never one level wide. The free view is where that lives, and its floor is the whole-page
measure, not a level: see `pageFitScale` and `Viewport.scaleBounds`.

What the scale decides is how many stops a panel takes — one for a panel the window
covers, two for one too big in one axis, four for one too big in both — so the level is
not cosmetic. Measured on a 1600x2400 page against a 1236x1648 screen, where the width-fit is
1236/1600 = 0.7725: 1.4x covers 1143x1524 page pixels, 1.7x 941x1255, 1.9x 842x1123, and the
render is the screen's pixels at every one of them, to within a pixel or two — the window is
rounded to whole page pixels (the tile key names it), and that rounding times the scale is the
residual. It is under a pixel until the scale passes 1, which is a page narrower than the
screen. The default is **1.7**, the middle of the three: a typical page then renders at about
1.31 screen pixels per page pixel — a mild magnification of the file, where 1.9 asks 1.47.

### A panel the window *nearly* holds is eased, not stepped

**A panel the window misses by a few percent is shown whole at a slightly smaller zoom,
rather than costing a whole extra stop to show a sliver of itself.** `PANEL_WINDOW_TOLERANCE`
(0.18) is the whole of the setting and `frameForPanel` the whole of the mechanism: an axis
the panel overflows by no more than that fraction of the window is fitted by shrinking the
scale **for that panel alone**, so the panel arrives complete in one centred stop where it
used to cost two.

Measured on the 1600x2400 page against the 1236x1648 screen at 1.7x, where the reader's
window is 1059x1412 page pixels: a panel eight percent too wide goes from **2 stops to 1**,
its window growing to 1144x1525 — which renders at 1236x1648, the whole screen, at 92.6% of
the reader's zoom. The output size does not change: the same screenful of pixels simply
covers more page, and the panel reads smaller inside it.

Four things about it are the design rather than the arithmetic:

- **The easing is decided per axis and the scale is one number.** The window keeps the
  screen's shape, so one scale has to serve both axes, and the strictest *eased* axis sets
  it. A panel five percent too wide and fifty percent too tall is therefore eased on x only:
  one centred stop across, and its two y stops at that reduced scale — **2 stops where there
  were 4**. That mixed case is the one the two rules in the request disagreed about, and it
  was settled by asking: the failing axis keeps its full stops beside an eased one rather
  than dragging the whole panel back to four corners.
- **An axis past the tolerance contributes nothing**, because no scale within it could have
  fitted that axis. A panel past it in *both* axes gets the reader's frame exactly, which is
  the behaviour this had before any of it — measured, four corners either way.
- **It can only ever remove stops.** Per panel that is arithmetic, since a larger window
  gives `positions` no more views than a smaller one; across a page it is the A/B over ten
  drawn layouts against `PANEL_WINDOW_TOLERANCE = 0`, which also holds that a layout where
  *no* panel can ease comes out identical — every window, every output size, the same order.
  That second half is the one that matters on a real book: most pages have nothing near the
  edge, and on those the mechanism has to be inert.
- **The price is that the scale is no longer one number for the page.** A panel eased to fit
  is shown up to 15% smaller than the one beside it, and a panel eased in one axis only is
  shown at that smaller scale for all of its stops. That is what was bought, and the
  tolerance is what bounds it.

**Nothing downstream has to know, and that is not an accident of this change.** Every step
already carried its own `w`/`h`, `out_w`/`out_h` and `panel` — that is why a step carries
them at all — so the viewer, the tile key, the pre-warm and the render-path log line read
the step and cannot tell an eased panel from a page whose steps simply differ. `entryView`
is the one caller that has to be told: `steps` hands it the panel's **own** scale, or a tap
on an eased panel would open at the reader's zoom and jump to another one a press later.

The constant is a guess at where a reader stops noticing the shrink and starts wanting the
zoom, and it is the one number to move if that judgement is wrong. **Zero switches the whole
mechanism off**, which is what to reach for first if a page ever looks wrong here.

**The row has two shapes, one per view, and both carry the view switch.** *Pan & Zoom*
holds `[Pan & Zoom] [-] [1.7x] [+] [Close]`; *Panel Cut* keeps stock's three and gains the
switch in front — `[Panel Cut] [Rotate] [Close]`. **The switch's
label names the view the reader is in**, not the one the press leads to: it is the shape
the zoom button beside it already has (that one shows the level it is on) and the shape
the menu row that used to carry it had, so the button and the setting name the same
thing. The first version named the destination, which is defensible for a button and was
not what a reader wanted — three controls saying different things about one state is the
thing to avoid. The zoom button is
the level right where a reader can see what it does: tapping it cycles 1.4, 1.7, 1.9 and
writes the preference, so the next page, the next book and the next start keep it. That is
why there is no menu row for the level — the choice moved into the viewer, the store did
not, and `ui/reader` still reads it and hands the number in.

**The two buttons beside that one are the same pair Free View has, with this view's own step and
its own range.** `-` and `+` move the level by a **tenth**, so a reader can reach 1.5 or 2.1 rather
than only the three presets; the value button still *cycles*, and because a tenth leaves
numbers that are on no list it walks **up** from wherever the reader is — 1.8 answers 1.9,
and past the top the cycle starts again, which is what a cycle does. The range is 1 to 1.9 —
the floor being the fit, where the page's content is as wide as the screen, and **the ceiling the top of the
cycle**, so `+` stops exactly where the value button stops and a reader can never sit at a
level that button would answer by jumping back to the bottom. Four things about it are worth
naming rather than discovering:

- **The step is a level and not a scale**, like the value button's, because a level is what
  the button between them reads off and what the preference stores.
- **The new level is rounded to one decimal before anything reads it.** 1.7 + 0.1 is
  1.7999999999999998 in binary, which the cycle's comparison would miss — that rounding is
  what keeps the two buttons agreeing, and it is why the label is `%.1f` rather than
  `tostring`, which would print the seventeen digits of a raw double.
- **`-` and `+` do not have the free view's range or its reason for it.** That pair is bounded
  by `Viewport.scaleBounds` so a pinch cannot outrun it; this view has no pinch, so 1..4 here
  is a choice. The two share `levelAfter` and nothing else.
- **Both buttons re-open through one function** (`meguruReopenAtLevel`), so a step and a cycle
  cannot come to re-open differently — which is the kind of drift that shows as one of them
  losing the reader's place and the other not.

**The cropped view's row keeps Rotate and has dropped Scale / Original size.** Rotate means what
it says there — a panel wider than the screen is turned — and it is **forwarded, not
re-implemented**: `Button` calls `self.callback`, so the existing object is read out of the table
before it is replaced and its callback passed straight back in, which is no upstream logic copied
and upstream's own `update` re-letters it by id so its label stays true. Scale went for the reason
the row above gives at length — what it sets is the *viewer's* `scale_factor`, and a panel is
already rendered at the panel's own size — and it applies here most directly, since a panel *is*
the size that button was claiming to change. The removal was first asked for in Pan & Zoom; this
is the same argument reaching the view it fits best.

Dropping it has one requirement that is not optional. `ImageViewer:update` re-letters the buttons
it expects **by id and without checking that they are there**, so a row without one is a nil call
inside a paint: `installRow` seeds the map those lookups read with a sink for every button its row
does not carry — `scale` here, and both of them in the two views that have neither. The switch writes
the same `panel_view` the menu's row does, from a close-and-reopen that keeps the reader's
panel, which is `steps[cur].panel` in the window view and the bare step index in the crop
one — read from *that* view's shape rather than from the step, whose `panel` field is nil
in the crop view and would make `and/or` pick the right answer by accident.

**And the row must be re-installed *after* `init`, because `init` has already built the
frame around stock's.** `ImageViewer:init` builds `main_frame` and calls `update()` as its
last statement, and `update()` is what puts `button_container` into the frame;
`ImageViewer:onShow` does *not* rebuild it. So swapping the table and the container after
`new{}` leaves the frame holding stock's, and a viewer that opens with the row already
**visible** — which is every re-open this file does — paints stock's row. What hid that
until a reader reported it is the middle tap: it calls `update()` itself, so a row
summoned by hand was always the right one, and only the re-opens showed the wrong one. The
repair is one `viewer:update()` after the swap. The general shape is worth keeping: **a
widget that replaces parts of itself after its constructor has to re-run whatever puts
those parts into its layout**, and the failure is invisible in every path where something
else happens to call it later.

**The row stays open across the re-opens, and that is what makes the button usable.**
Changing the level is a close-and-reopen, and the new viewer would start with its chrome
hidden — so a reader comparing two levels had to middle-tap to bring the buttons back
between every pair, and the button can only be pressed while the row is up. Its state
travels with the re-open, on the call rather than on the carried view, exactly as
`at_end` does; the page boundary carries it too, since a crossing is not a reason to take
the buttons out from under a finger that was using them. Both are read *before* the close
that precedes the reopen, which is the rule the handoff already follows for `mode` and
`rotate` — and one of them was first written reading `self.buttons_visible` inside the
tick, which is after the close, and would have worked by luck rather than by design.

Two details of the rebuild are load-bearing. Stock builds the table inside `init` and has
no way to take a button out of one, so the table and its container are replaced whole —
both stock's own widgets, with stock's own shape. And **`update` re-letters the two
buttons it expects by id, and does not check that they are there**, so a row without them
is a nil call inside a paint: they are answered by seeding `button_by_id` — the map those
lookups read — with buttons that are not in the row at all. None of stock's code is
patched, and if the table is not where it was the row stays stock's and a `warn` says so
once, the way the rotation angle does. **The whole rebuild is `pcall`ed**, because the
row is cosmetic: a failure there must cost the reader the zoom button and not the view.
That is the rule the crop mask already follows on the render path ("costs the crop and
not the panel"), and it is also what bounds the blast radius of exactly the crash this
was found by — a viewer built, then left unshown by a throw inside the row, with a
repaint still queued on it naming a frame the close then took away.

**The chain is a simulation of the forward gesture, not a list per panel.** Where the
next step lands depends on what is *already on screen*, not only on which panel the
reader is in — so `Viewport.steps` walks the page's panels once and emits the rectangles
the reader will actually visit:

- a panel **wholly inside the window as it stands** gets **no step**. The chain does not
  stop for it; the question moves to the panel after it, and one tap can pass several
  small panels at once. This is the case the mode exists for on a page with a grid of
  them beside a full-height one;
- a panel that does not fit gets a step, anchored to **its own edge**: the panel's start
  edge at the window's edge, then — if it still does not fit — the panel's end edge
  there. A panel that fits in an axis is *centred* on that axis, since a window larger
  than the panel cannot be flushed to anything;
- the entry is a panel **named**, and nothing more: a long-press decides *which* panel the
  reader wants and the walk then shows it from its own first stop, exactly as if they had
  pressed forward into it. The panel is never skipped — the caller named it — and which of
  its stops the viewer opens at is `entry.at_end`: the **first** going forward, and the
  **last** coming back, because a reader crossing back into a page arrives at it from below
  and the corner nearest where they came from is the end of its last panel. Two bugs lived
  here. Before the flag, crossing back asked for the last panel and opened at
  step 1 — the whole page, read from the top. Before the fix that introduced the flag,
  the first version of this opened at the first stop of the named panel and made the
  reader press forward to reach the bottom of a page they had just come *down* from.

**There is no stage to keep and no "read" flag to set.** A skipped panel is one the
chain never stopped at; the reader's place is the step index. State that nothing reads
is state that drifts, and the two things the design was asked to store — which stage of
a panel, which panels are read — are both already implied by the rectangle on screen.

**The stops inside a panel are its corners, and a panel too big in both axes gets
four of them.** One rule per axis — centred on an axis the panel fits, anchored to
both of its edges on an axis it overflows — crossed in reading order. That gives one
view for a panel the window covers, two for a panel overflowing one axis, and **four,
corner to corner, for a panel overflowing both**. The four is the one worth defending:
the first version anchored such a panel to its start corner and then its end corner,
which covers the middle twice and leaves the other two corners **never shown at all**.
A reader reported it, and the fix is the cross product rather than the pair.

**Which axis it is changes nothing, and that is worth saying because it is the one
asymmetry a reader would notice.** A panel **taller** than the window is walked from
its top edge to its bottom edge, exactly as a **wider** one is walked from its left to
its right, and the forward gesture takes both stops before the panel after it is
reached: a panel is not left half read because it was tall rather than wide. The two
differ in one place only — the horizontal pair swaps with the book's direction, and
the vertical pair does not, since both kinds of book are read down the page.

**The horizontal direction is a parameter, and it is the book's.** Which side of a
panel the window stops on first, and so the order of a row's two corners, follows
`mode` — left to right for a comic, right to left for a manga. The detector already
hands the panels over in reading order, so this is the only place in the plugin where
direction is not decided upstream of the view; it travels into `meguru/viewport` as a
boolean beside the panel list, resolved from the same `mode` `ui/reader` hands to
everything else. The vertical order needs no flag: both kinds of book are read down
the page.

**Where the reader tapped decides which panel they meant, and nothing else.** The panel is
then walked from its own beginning, so a long-press anywhere on it starts at its top-left
stop — `Viewport.entryView` and the "which of the panel's views the reader's own view stands
for" rule beside it are gone, and `steps` has one walk for every panel.

That replaced a rule that let the finger replace one of the panel's own stops: on a corner,
that corner, and between corners the first. It read as respectful of where the reader put
their finger and it was wrong in the case that matters, which is a panel taller than the
window — measured on a 1000x2200 panel in a 1059x1412 window, a press three quarters of the
way down **opened at the panel's bottom stop**, y=828, and showed the panel's top *second*.
The reader asked for a panel, not for a corner of it, and the two window views now also
agree with the cropped one, which has always shown a panel from its start. What the rule was
protecting — that a tap near a panel's edge, clamped to the page, does not leave the panel
half seen — is kept by the walk itself: every stop of the panel is pushed, in order.

**What it reuses, unchanged.** `ImageViewer` and its four overrides: with the image
screen-sized and best fit still `scale_factor == 0`, `onSwipe`'s gate, `onTap`'s thirds,
the hardware keys and the close contract all behave exactly as they do for a panel. The
buffers are the document's tiles (`image_disposable = false`, released on the step just
left), so the pre-warm is the same one call the viewer is about to make, and
`images_keep_pan_and_zoom = false` gives "a pinch lasts one step" for free. The rotation
machinery is not used at all — a window is the screen's shape, so there is no wide-versus-
tall decision to make, and a panel too wide for it is walked in x instead.

### The third view: the page, with nothing in the way

**The free view walks no steps and asks no detector.** A long-press opens the whole page with
pinch and drag, centred on the finger; there are no panels, no stops and no page turning, and
the button row is permanent — under it the reader is simply *looking at the page*, which is
what the other two views are alternatives to. The gesture asks `getPageDims` and not
`getPanelsFromPage` for exactly that reason, and it costs nothing: `getPageDims` **is** the
fetch and the decode, so the bytes the render wants are in hand either way, and a page the
detector would have refused opens in this view like any other.

**Every gesture ends in one of three stock seams, each read in the source rather than
assumed:**

| gesture | seam | what this view does |
|---|---|---|
| pinch / spread | `ImageViewer:onPinch` / `onSpread` | the scale changes, about `ges.pos` for a spread |
| drag | `ImageViewer:panBy(x, y)` — `onSwipe`, `onCursorPan`, `onHoldRelease` and `onPanRelease` all end here | the window moves by `(-x/scale, -y/scale)` page pixels |
| horizontal swipe | `PanelViewer:onSwipe` | the other views walk the chain; here every direction is a drag, the signs stock's own |

**Stock's scale arithmetic cannot be borrowed, and that is the one real constraint.**
`onZoomIn`/`onZoomOut` multiply `self.scale_factor`, and that same field is what `ImageWidget`
scales the tile by — so a view that wants a render *of the page* at every zoom has to keep its
own number and leave the field at best fit. What it does borrow is the shape of the gesture,
`ges.distance / min(screen, image)`, whose denominator collapses to the screen here because
every tile in this view already is the screen's size. A spread zooms about the point under the
fingers and a pinch keeps the centre, which is what stock does and says why.

**The step is mutated in place rather than replaced, and the image has to be resolved again
by hand.** A step's image is a lazy closure over the step table, and `switchToImageNum`
returns early when the number has not changed, so writing the new rectangle into the same
table and calling `update()` is what makes the closure see it. The tile LRU follows for free
— a window is keyed by its rectangle *and* its size — so coming back to a scale the reader
was already at is a cache hit rather than a second render.

**But `update()` never re-resolves that closure.** `ImageViewer:_new_image_wg` rebuilds the
widget around **`self.image`**, the buffer it already holds, and only refreshes it through
`_scaled_image_func`, which this plugin does not set. The other two views move because
`switchToImageNum` resolves the *new entry* into `self.image`; this view changes the
rectangle under one entry, so it has to resolve that entry again itself and put the result
where the paint will look. That is what shipped first: **the label moved and the picture did
not**, a reader reported exactly that, and the line above this one had said the closure
"sees" the new rectangle — which it did, and nobody asked it again.

**The zoom is remembered, in a scale, and written once.** Each open starts at the scale the
last one closed on; with nothing stored it starts at the *Panel zoom level* × fit, the number
the other views use. The button cycles 1.5, 2 and 2.5 — levels, all three, because that
is what a reader asked for and because a list mixing levels with Original would hold two units
— and because a pinch leaves numbers on no list, the button walks *up* from wherever the reader
is rather than
looking the value up.

**It is written at close, not where it changes**, and that is about the card rather than
tidiness: `Settings.set` flushes, and this number changes on every pinch event and every drag,
so remembering it where it moves would be a disk write per gesture. `onCloseWidget` is where
the reader's answer is final and it happens once per viewer — whether they close it, switch
views, or a page boundary takes it. The label carries the live value until then.

**The floor is a whole page and the ceiling is four *levels*, and that they are two different
measures is the point.** The floor is `pageFitScale` **of the page**, the smaller of the two
ratios, so the whole page is reachable whatever its shape, which is the one thing a level
cannot name. The ceiling is four levels **of the content**, because a level is a multiple of
the content's width — so `scaleBounds` takes both dims, and a caller that hands it just one is
asking for a floor and a ceiling measured in different things. A single measure could not do
both: on any page taller than the screen the whole page sits *below* 1.0, so a floor taken from
`fitScale` would put it out of reach. Both are floored at 1 for **original size** — one page
pixel to one screen pixel — because a page *smaller* than the screen has both measures above 1
and Original would otherwise be below the minimum.

**That two-dims requirement is not hypothetical, and the bug it prevents was measured.** The
free view used to pass `content or dims` for both, so its floor was the whole *content* rather
than the whole page, and — the half a reader sees — `free.dims` is the page while the scale it
opened at was measured against the content: the level ladder was read against the page's fit.
Opening at `1.7×` on a page with margins **labelled itself `2.0×`**, off by exactly the ratio
between the page's width and the content's. Every reader of the free view's fit now goes through
one `freeFit(free)`, so the six of them cannot drift apart again — the same rule this file
applies to the level buttons, where one `meguruReopenAtLevel` serves both.

Measured for a 1600x2400 page against a 1236x1648 screen: **0.687 .. 3.090**. The floor is the
whole page, and at it the window is the whole page letterboxed — the only scale whose request is
*not* the screen's pixels, because the window had to shrink to the page. The ceiling is
`4 * 1236/1600`, four page-widths on the screen.

**Four ways to set the zoom, and they answer four different questions.** The value button
*cycles*: 1.5, 2 and 2.5, wrapping back to 1.5 — levels, and the reason this view works in
*scales* underneath while the other two work in levels is Original, which is one page pixel to
one screen pixel and is not a level at all. `-` and `+` beside it nudge by **a quarter of a level inside 1x to 4x** — the
bottom of that range is the whole page, so `-` reaches the fit without pinching —
and they step from wherever the reader *is* rather than snapping to that list, so a pinch to
2.4x answers `+` with 2.65x. A pinch changes the scale about the fingers. And a drag or a tap
moves the window. The two lists are separate on purpose: Original has no level, and a stepper
that could reach it would have to have an opinion about what half a step below it means.

**And the scale a pinch reaches says `1x`.** The levels are multiples of the fit, so `1.5x`
beside them means one and a half times the fitted page — while the file's own pixels are
one page pixel to one screen pixel and cannot be written as a level at all. That is the
scale every other image viewer calls 100%, and `1x` is the word for it; the first version
spelled out `Original 1:1` instead, and a reader asked for the shorter one. So the row does
hold two units, deliberately, and the reason the levels are not labelled as percentages is
that a percentage of *what* would then need saying.

**The screen is not where the page is drawn, and the picture area is smaller than it.** The
button row takes a strip of the screen, and a tile shaped like the screen does not fit beside it
— nor is it clipped politely: **a viewer given a *function* as its image keeps that function as
`_scaled_image_func` (`imageviewer.lua:160`) and builds the widget around it with
`scale_factor = 1` (`:451`), so the tile is drawn 1:1 and what overflows is painted *under* the
button row.** `stepImage` therefore clamps its output to the size stock hands the image to fit
into, which is the picture area. In the free view — where the row is always up — a screen-sized
tile is a tile whose top and bottom the reader never sees, and that is what a reader reported as
the zoom not working at all.

`meguruFreeMapping` is the other half: one page pixel is `scale x shrink` screen pixels, where
that clamp is `shrink`, and the origin is where the fitted tile sits inside the area. It was
written from a reader's report — **dragging felt right and a tap landed somewhere else** — which
are both true at once, because a *distance* between two screen points is unaffected by where the
picture sits while an *origin* is not. The two conversions that need an origin are a tap and a
spread's about-point; the pan needs the factor as well, which it takes from the same place. The
tap no longer needs any of it — see below — but the spread does.

**A tap closes this view.** The row is permanent here and there are no steps for the thirds to
walk, so the gesture a reader reaches for first was doing nothing; closing is what stock's own
viewer does with a tap outside its frame, and it is the way out that needs no aim. Moving the
centre to the point tapped was tried first and was the wrong shape: it reads as a jump, and it
needs the mapping above to be right before it can be trusted at all.

**Panning carries the page with the finger, and that is a decision about stock's convention
rather than about signs.** `ImageViewer:panBy(x, y)` moves the *image* by `(x, y)`, and every
caller of it passes the finger's travel negated: a swipe **west** is `x_diff < 0` in
`gesturedetector.lua:331` — so the finger went *left* — and stock arrives with
`panBy(+distance)`, while a drag right arrives as `panBy(-travel)`. The picture in stock's
viewer therefore always moves *against* the finger, which is a swipe's feel and is not a drag's.
Following the argument into the window — picture and window move opposite ways — lands the page
against the finger as well, and that is what shipped: a reader reported "panning works
backwards". The window now takes the argument **as it stands**, so the page moves with the
finger, and both of stock's calling conventions reach the same place without either being
second-guessed.

**Three things are off here, each for a reason rather than by omission.** Page turning,
because the reader asked for a page and not a book — the step methods are inert, and the
hardware keys bound to them with it. The middle-tap toggle, because the row is meant to be
permanent, and this is the only view whose reader cannot summon the buttons back themselves;
**a tap closes the view instead**, which is the way out that needs no aim. And the pre-warm,
because
there is no next step and its page branch would fetch the next page's dims *and panels* to
prepare a turn that cannot happen.

**Leaving it is the one place that costs a detector scan.** The free view has no panels to
hand over, so cycling out of it into either panel view asks for them — *before* anything is
closed, the order `meguruHandoff` already follows, so a page whose panels cannot be had
leaves the reader where they were instead of closing their viewer onto nothing.

