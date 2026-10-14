# Design decisions

Why the design is what it is, and what earlier designs cost. Settled questions, kept so they are not reopened.

Part of the design record; [CLAUDE.md](../CLAUDE.md) is the map.

This is a from-scratch successor to `meguru.koplugin`, which lives beside it and
**is not to be modified**. The old plugin remains the reference for behaviour and
the fallback if this one misbehaves. There is no compatibility between the two:
different marker extension, different descriptor, different data. Orphaned
reading progress from the old plugin is accepted and intended.

**A marker carries what identifies its series, and the feed is asked for
everything else.** The old plugin copied the sibling list, the volume order and
the titles into every `.mgru`; a version of this one kept all of that in a local
SQLite catalog. Both are gone, and the reasoning is one sentence: a copy is
written once and never repaired, so it answers with the series as it was, for as
long as the file exists. The catalog fixed staleness by being authoritative and
paid for it with a whole subsystem — a schema, migrations, transactions, a sync
engine, a background walker — to maintain a materialised view of feeds that can
just be re-read. What is left is the smallest thing that works: the identity in
the file, the feed for everything else. "What comes next" is answered by walking
that feed **when the reader asks**, in a gesture that asked for it.

Settled and worth not re-litigating: `Settings.DEFAULTS.rotate_wide = 1` is correct. The
old plugin's fallback *row* carries `default_value = 0`, which looks like a conflict, but
that value only applies when the pagenumbercrop plugin is absent — the book itself is
seeded by `perBookGeometryDefaults`, whose classic default is right-turning. The new
plugin seeds 1, which matches what a fresh book actually got.

**The crop does not skip marks near the edge, and that was settled by measurement.** An earlier
attempt at dark-border support (the `fix/autocrop` branch) came with four heuristics whose job was
to move a crop edge inwards past a short mark standing alone near the edge, so a page number in
the margin would fall outside the box. On the two books to hand the guards were never what did
that work — a number in a white margin is *content*, the page-number strip below removes it — and
what they did instead was cut speech bubbles, bubble tails and small drawn elements standing in a
white margin: something a reader can see, traded for a strip of blank they cannot. What is here
instead is the border's own colour as the reference, light or dark, with the edge at the outermost
content pixel — the rule the crop has always had, asked about the other side of the midpoint where
the light side refuses. The strip carries the same polarity, which is what makes it work on a
black margin at all.

**The page-number strip takes a number or it takes nothing, and the branch that fires most often
was the one asking no questions.** The analysis ported from `pagenumbercrop` calls any short ink
band in the bottom margin a printed number as long as it is under 60% of the page's width — a
*panel* test, not a number test — and the branch that fires when artwork reaches the bottom of the
page returned the artwork's own bottom edge and discarded **everything** below it, whatever was
there. That is the ordinary shape, not an exotic one: a margin crop normally ends at the artwork,
so the artwork is in the strip. On Kavita chapter 197622 (library 39) it removed the sound-effect
line "THE DARK MAGI!!!" on the reader's page 29 — 28% of the page's width — and the boxed title
"Chapter 0: Prologue" on page 3, at 19%. A printed number is a few glyphs: a corner "24" measures
2.6% of the page's width, a big "128" 7%, even a wide footer "Page 128" only 10% — and both of those
false positives were found by running a transcription of the analysis over 46 pages of that
chapter, neither page having been looked at first. The bound is now `max_number_span` (12% of the
width): a band wider than it is not a candidate, a strip holding one yields no crop at all, and the
artwork branch finally runs the same short-band, clean-gutter and content-above tests the other
branch always ran. **It is the port's second deliberate deviation** (the first is the ink's
polarity, above). The reference plugin still behaves as it did — that is its own to change — but
it no longer decides this on a Meguru book: a plugin that patches the same seam is one version of
this analysis *without* the bound, so its patch is taken back rather than yielded to
(`takeBackPageBBox`, from the `ReaderReady` seam `Reader.install` registers). A reader who has both installed gets the
corrected crop. What stays the plugin's is its wide-page rotation, whose wrappers cannot be
unwrapped and which must not run twice.

**And the height a band may have is one number, not two.** The port refuses a band taller than
`max_band_h` (4% of the strip) *when a clean gutter does not separate it from the content above*,
and allows up to `max_big_band_h` (15%) only when one does — so a printed number touching the
artwork's edge, which is what a tight margin gives, is read as artwork. Measured on a device, on
one page with one printed "6": analysed from MuPDF's grayscale render the number sat **1 px** below
the artwork's black edge and was refused as `band too tall (19 px)`, and analysed from its colour
render — the same page, the same size — it had more gutter than the test wants and was cropped. A
reader turning colour rendering off lost the crop and put it down to colour; a few pixels between
two decodes of one page were deciding it. There is one allowance now, whichever side of the gutter
test a band falls on, which is what the reference already grants a band it *can* separate. Measured
over the same corpus as the deviations above: **no page that cropped before moved**, and the two
false positives the width bound exists for are refused by it either way.

**The analysis is done on bands, and the page-number strip is no longer magnified sideways.** Two
of the ported pass's costs were its shape rather than its rules. `refineAutoCrop` rasterised the
*whole* page into a Lua string — 3.8 MB for a 1600x2400 scan, per page turn — to serve four walks
that read a few dozen rows and columns of it; it now rasterises each walk's own rectangle, through
the same `Image.rasterFor` conversion on a copy of exactly the pixels that walk reads, so every
comparison it makes is the one it made before. And the page-number strip's `zoom` — which exists to
give a band's *height* enough rows — was applied to the width as well, rendering `page_w * zoom`
(2.2 Mpx, up to 3.6 Mpx on the fallback) for a band a few percent of that wide; the two axes scale
independently now and the horizontal one is capped at 1:1. Measured over the same corpus: **562.9 M
→ 251.4 M strip pixels rendered** across the 91 pages, the same one fallback retry, and **not one
verdict moved** — the four drawn numbers still crop at the same cuts, the two real false positives
and the two drawn refusal shapes still refuse, and the 82 uncropped pages stay uncropped.

**Not taken: a strip at its own resolution.** Dropping the vertical zoom too is another ~half, and
on this corpus it also moves nothing — the crops it returns differ by the sub-pixel rounding the
zoom introduced (2300.3 → 2300.0), which is the *same* cut. It is not taken because this corpus
cannot argue it: its page numbers are all 29-54 px tall, and the zoom is what the reference chose
for the case it cannot test — a *small* printed number, where a native-resolution strip is one or
two pixels of ink and the fallback retry only fires once the fast pass has already called the page
suspicious. The horizontal cap is free on the same evidence and costs no resolution that any
threshold reads.

**And both of the ported rules are the crop, not rows beside it.** They were two toggles of their
own — "Page Number Crop" and "No crop on blank pages" — mirroring that plugin's rows one for one;
they are now what *Crop* at `auto` means, so the *Page* tab has a single row and there is no way
to have the margin trim without the other two. The argument is the one this file keeps making
about what a reader is choosing: nobody wants a printed number back, and nobody wants a chapter
divider zoomed into a title, so offering those separately was offering the *symptom* as a
preference. What it costs is a reader who had deliberately turned one off — they get it back, with
the key still in their book's sidecar and nothing left to read it.

**What the bound costs is a crop, never a page.** Every page that cropped before still crops, at the
same place to the pixel: the artwork branch's cut is returned exactly as it was, and the tests added
to it can only refuse. That was measured, not argued — the before and after cuts over 84 real pages
(chapter 197622, Invincible #1, 20th Century Boys vol. 1) and seven drawn controls, with the shipped
Lua's own `meguruAnalyzeStrip` run over every one of them beside the transcription and agreeing with
it band for band (`lupa`; the device's 5.1 is not what it was loaded in, so the arithmetic is what
this settles and the syntax is not). What stops cropping is a margin holding anything wider than a
number: a caption line, a sound effect, a boxed title, a vertical column. The white number in a
black margin — the case the device checklist walks for the dark side — is 3% of the width and is
untouched.

**The crop reads a border's luma, never its hue.** `lumaAt` is luminance, which is what the
content predicate and the panel detector are calibrated on, so a frame whose colour differs from the
artwork in hue alone, at the same luminance, is invisible to the crop — something that is neither
pale nor dark is never a margin here, whatever its hue says to the eye. Brightness *alone* is not
the test either: paper above 170 and ink below 85 was the first rule, and it came back with a
*coloured* frame uncropped, a mid-tone frame being neither. Measurement is what settled that — over
74 pages of two chapters plus four drawn coloured frames (steel-blue, sepia, teal, warm-grey,
luminances 93 to 132, all refused at the time), the pages that moved were exactly the ones whose
rings were uniform, which is how the shape of a line rather than its colour became the question.

**A margin is the page's surface, a frame, or a bar down a side.** The surface is read off the whole
ring: its light pole — the 85th percentile of the ring's own samples — is paper wherever any margin
is, while a *single line* fails a uniformity test flat as soon as the drawing touches it, and on a
real page the drawing touches. Measured on a Kavita page of 1502x2048 whose left 212 pixels are a
scan's black bar: every line but the bar's own was drawn on, the crop answered "no margin on any
edge", and the page came back whole — the surface has to be read from the ring, not a line at a time. So the margins are: the surface wherever it is found (paper, light
and near-neutral, at the ring's pole or on an edge line); a **frame**, a colour three or four sides are
drawn in, since a drawing reaches two sides of a page and never three; and a **bar down a side** that
is one colour, clearly not the surface, and shallow — its colour ends within a quarter of the page,
which is what separates a scan's bar (14% on that page, and the crop took exactly its 212 pixels) from
a panel that bleeds off the page. Nothing else is a margin at all: a page whose drawing reaches every
edge keeps all of it, and the bars are looked for on the sides only, because a page's panels run to its
top and bottom edges.

**No edge may lose more than a quarter of its dimension, whatever the scan was sure of.** A
pale patch of drawing is paper to every test there is, and the cap is what keeps such a patch from
eating the page: the trim stops there even when the content test would go deeper, so what is left is
a pale border rather than a lost drawing. The other half of not being invasive is what the trim may
never cross, and it is the same rule seen from the inside: ink, tone and colour are never background,
so the box stops on a panel's frame, on a speech bubble's outline, on a caption — on anything drawn.
Measured on drawn pages: a caption placed in the left margin keeps its column and the margin behind
it, a panel running into the bottom corner keeps the panel and loses only the paper around it, a black
margin a fifth of the page wide is trimmed like paper — scan beds and pages shot on a black desk
reach that far in — and one past a quarter of the page is left alone, being the drawing then.

**The letterbox is painted in the margin the crop took off**, in one order: a trimmed **black bar**
first, because the reader who asked for a black margin to be cut asked for the screen to go black with
it; then a **dark frame's** colour, a black-bordered page letterboxing in black — dark only, since
three shaded margins of a scan agree with each other as readily as a drawn border does, and a page
letterboxed in their grey reads as a white margin on a grey ground; then the **palest paper** found in
the ring (its 95th percentile, not the 85th the crop itself uses) or on the edge lines, so an ordinary
page reads as its own margins continuing to the screen's edge — which is what makes a cropped page look full-screen; and nothing at all when there is
none of the three (art to every edge, a colour spread), leaving the reader's own surround in place
rather than inventing a colour out of the artwork. The bar has to be *dark* to answer: a grey or pale
band over paper is shading or a frame the page is read *inside*, and letterboxing a white page in it is
what turned the background grey. Measured on drawn pages: the black-bar pages letterbox in black over
paper and over bleeding art alike, a saturated red band in its own red, the grey and dark-grey strips
and the white-margined pages in paper, and a mid-grey frame on three sides in that grey. Measured on a
Suwayomi page of 960x1376 whose own margins are shaded to 249: the colour is the paper's 255 rather
than the shaded grey, which is what the reader saw as "a very light grey behind a white margin".
