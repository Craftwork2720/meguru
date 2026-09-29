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
