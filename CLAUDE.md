# meguru

KOReader plugin that turns OPDS-PSE page streams (Kavita, Suwayomi, Komga) into
ordinary KOReader books. A book is a small on-disk marker file; pages come off
the network as they are read. Successor to `meguru.koplugin`, which is the
behaviour reference and fallback.

## Environment

- Lua 5.1 / LuaJIT only: no `//`, no bitwise operators, no `goto`.
- No test framework, no linter. Run `python tools/check.py` after every change.
  Behaviour is verified manually on the device.
- `meguru.koplugin` and KOReader's `plugins/opds.koplugin` are read only.
- Reuse KOReader machinery (`LuaSettings`, `DocSettings`, `DocumentRegistry`,
  opds.koplugin) instead of rebuilding it.
- Always `require("meguru/x")`, never `require("meguru.x")` (two `package.loaded` keys).
- `require` of `opdsbrowser` / `opdsparser` must be lazy, at the call site.

## Layout

```
main.lua            plugin class: provider registration, menu dispatch, reader install
meguru/             core modules (paths, fs, settings, net, feed, marker, pse, panel, ...)
meguru/driver/      per-server drivers: base, suwayomi, kavita, komga
meguru/doc/         Document subclass, image decoding, per-book defaults
meguru/ui/          open, reader, panelzoom, info, menu, catalog
assets/             optional artwork and tab icons
libs/               vendored moire filter (not ours, unmodified, pinned; see libs/README.md)
tools/check.py      automated guard, not part of the plugin
```

Not yet written: `driver/generic.lua`. An unrecognised server has no driver.

## Invariants

- Module graph is a DAG. The only lazy edge is `feed.lua` -> `meguru/naming`.
- `ui/panelzoom` and `ui/info` require no `meguru/` module; they are handed plain data.
- `meguru/spread` and `meguru/derainbow` are leaves.
- Only markers are written to disk, plus `.cover.jpg` from `meguru/seriescover`.
- Reading position is sent to the server for Komga only, and is opt-out per server.
- Never modify `libs/` by hand.

## Docs

Read the one you need, not all of them.

- `PROTOCOL.md`: wire-format findings from live servers. Observation beats assumption.
- `docs/design-decisions.md`: why the design is what it is.
- `docs/series-state-and-markers.md`: marker fields and `item_key` identity rules.
- `docs/render-path.md`: decode, paint, cache, tone rows, log lines.
- `docs/driver-notes.md`: feed walking, ordering, per-server differences.
- `docs/opening-a-book.md`: resume dialog, silent opens, marker planning.
- `docs/reading-position.md`: what is sent back to the server and when.
- `docs/local-cbz.md`: local folder of `.cbz` as a series.
- `docs/panel-zoom.md`: panel detection and the three long-press views.
- `docs/two-page-view.md`: landscape imposition, gutter, wide-page rotation.
- `docs/menus-and-lifecycle.md`: menu rows, config dialog, plugin lifecycle.
- `docs/updating.md`: GitHub release updater.
- `docs/derainbow.md`: borrowed moire filter and its pinning.
- `docs/development.md`: `tools/check.py` passes and the on-device checklist.
- `docs/known-issues.md`: open questions and unverified assumptions.
- `docs/security-notes.md`: credential redaction in markers and logs.

## Docs rules

- Never write journals, changelogs, status notes or "what I did" files. Git history is the log.
- Do not create new .md files. Edit an existing one only when a lasting fact changes.
- Docs hold only what the code cannot show: server behaviour, quirks, open questions,
  security rules. No history ("previously", "was removed"), no restating code.

## Commits

- Conventional Commits, subject line only: `feat:`, `fix:`, `refactor:`, `docs:`, `chore:`, `test:`.
- One line, max 60 characters, imperative mood, lowercase after the prefix, no trailing period.
- No body, no bullet lists, no trailer lines (no `Co-Authored-By`, no "Generated with"), no emoji.
- Describe the effect, not the process. Good: `fix: skip /proc in empty-folder scan`.
  Bad: `fix: updated browser.lua to try to handle some edge cases`.
- One logical change per commit. Never bundle unrelated edits.
- Never commit unless asked.

## Comments

- English only.
- Explain WHY, never WHAT. If the code says it, do not repeat it.
- One line per comment, max ~80 characters. No multi-line blocks, banners or section dividers.
- Never write notes to yourself: no TODO/FIXME/NOTE of your own, no reasoning traces,
  no alternatives you considered, no references to the task or conversation.
- Never describe changes: no "added", "changed", "now uses", "fixed", "previously", "refactored".
- No comment on obvious code (`-- increment counter`, `-- return result`).
- Do not delete or rewrite existing comments unless the code they describe is removed or changed.
- If in doubt, write no comment.