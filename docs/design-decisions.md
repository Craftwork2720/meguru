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
