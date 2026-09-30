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

**A border is a margin when it is *uniform*, not when it is light or dark.** The crop read a
border's luminance and accepted it at either end of the scale — paper above 170, a printed or
rendered black edge below 85 — and refused everything between. That left a *coloured* frame
uncropped, because a mid-tone frame is neither: the page came back with its frame on, which is the
complaint that prompted this. What actually separates a margin from artwork is that the ring holds
nothing but border, so the test is now the span of the ring's own samples, against the same
26-level delta the content predicate uses; a uniform border is then a margin whatever colour it is,
and the reference is the middle of that ring. The band survives for borders that are *not* uniform,
which is exactly where refusing is the direction that cannot cut artwork.

The change is additive by construction and was measured as such: over 74 pages of the two chapters
plus four synthetic coloured frames (steel-blue, sepia, teal and warm-grey, luminances 93 to 132 —
all refused today), **the pages that move are exactly the pages refused today whose rings are
uniform** — the four frames and three flat grey divider pages — and **no page the crop already
cropped moves at all**. A ring whose span is under one delta cannot disagree with either percentile
about what content is, which is why the branch is safe rather than merely tested. The one thing it
does not do is see a border by *hue*: `lumaAt` is luminance, so a frame whose colour differs from
the artwork in hue alone, at the same luminance, is still invisible to the crop.
