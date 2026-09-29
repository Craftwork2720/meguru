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
black margin at all. Its known over-eagerness travels with it: a short band above a clean gutter is
cut whether or not it is a page number (a printed title line under a panel goes the same way on a
white page), and that is unchanged from before — it now applies to dark margins too.

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
