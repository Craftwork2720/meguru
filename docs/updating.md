# Updating

The GitHub release updater: the one artifact both ends name, the install transaction, and what is remembered between checks.

Part of the design record; [CLAUDE.md](../CLAUDE.md) is the map.

## Updating

**One artifact, and both ends name it.** `.github/workflows/release.yml` builds
`meguru.koplugin.zip` and attaches it to a tag's release; `meguru/updater.lua`
asks `/releases/latest` for an asset called exactly that. There is no second
file anywhere in the flow, and that is the point of the arrangement rather
than an accident of it: an updater that fetches GitHub's own **source archive**
by tag — which `assistant.koplugin` does — is downloading something CI never
looked at, built by a different process, containing a different set of files,
and nothing anywhere reports it when the two disagree. The name is a constant
in two files and is never versioned; an asset called `meguru-1.2.0.zip` would
make every release after the first look like it had no downloadable file.

**The tag check is a failure, not a warning.** `_meta.lua`'s `version` is what
the updater compares a release against, so a release published with a stale one
there is a release that every device already running it will call "up to date",
for good and in silence. The workflow exits 1 on a mismatch, and
`pluginloader.lua:255-261` copies that field onto the plugin module, which is
how `main.lua` gets `self.version` to hand to the updater. **An absent version
is refused rather than defaulted** — pagenumbercrop's fallback of `"0.0.0"` is
below every release ever published, so it turns each check into "a new version
is available" forever.

It earned itself on `v0.9.2`, which was tagged one commit before the version
bump landed: the run failed at that step, skipped the build and created no
release. The recovery is to move the tag — `git push --delete origin v0.9.2`,
re-tag the right commit, push — because **a tag that already exists does not
re-run its workflow**. Re-pushing the same ref is not a push as far as Actions
is concerned, so a failed release whose cause you have just fixed stays failed
until the tag itself moves.

**`v0.9.1` is a build whose updater cannot install anything**, and that is worth
knowing as a fact about this feature rather than about that release: the crash
was in the updater's own verification step, and a device running it will fail
the same way at every later version, because the code that runs the install is
the code already on the device. The reader keeps working — the failure is before
anything moves — but OTA is dead on that copy until a new one is put there by
hand. **The updater is the one component an update cannot fix**, which is the
whole argument for testing this path on a device before tagging rather than
after.

**The archive is staged to get its `meguru.koplugin/` prefix, and staging is
also what keeps the developer material out.** The repository root *is* the
plugin — `main.lua`, `_meta.lua`, `meguru/` and `assets/` are at the top level,
where pagenumbercrop has them a directory down — so zipping the root would put
32 files under no folder at all, and would ship `CLAUDE.md`, `PROTOCOL.md`,
`tools/` and `docs/` to every device. `assets/` has to be in the staged copy
(`meguru/rowcover` reads it through `Paths.asset`), and so does `LICENSE`,
because the zip is a distribution of AGPL-licensed code.

### Installing one

`symlink → download → extract to staging → verify → rename ×2 → clean up`, and
each step exists because of something the one before it cannot catch.

**The new copy is unpacked into a staging directory and verified there**, so a
failed download or a truncated archive never touches the live plugin; the
verification is four required files plus the staged `_meta.lua`'s version
matching the release's, which is also the only proof that the asset served
under `ASSET_NAME` is the one this release built. Then the installed directory
is moved aside by **rename**, the staged tree is renamed into its place, and
anything that goes wrong after that puts the backup back.

**Nothing on disk but markers** now has an exception of a different shape than
`seriescover`'s: `<data>/ota/meguru/` holds the archive, the staged tree and the
backup for the length of one attempt, and `ota` is entirely ours, so every
failure path clears the whole directory in one `purgeDir` rather than picking
off what that stage happened to write. A 477 KB zip left on the card after a
failed attempt would be exactly the thing this codebase does not do.

Three things about that transaction are load-bearing and each is easy to
"tidy" away:

- **`os.remove` cannot delete a directory.** POSIX `remove()` is `rmdir` and
  fails `ENOTEMPTY` on a tree, which both `staging/` and `backup/` are. Every
  cleanup is `require("ffi/util").purgeDir`, which is what `pluginloader.lua`
  uses on a plugin it is deleting.
- **A `false` from `extractToPath` is advisory.** It compares against
  `ARCHIVE_OK` exactly (`archiver.lua:149`) while a disk writer returns
  `ARCHIVE_WARN` for something as ordinary as a permission it could not set on
  a FAT card, so treating it as fatal would fail installs on exactly the media
  a `.koplugin` most often lives on. Verification is the gate.
- **Nothing may happen between the two renames.** There is a moment where
  `plugins/meguru.koplugin` does not exist, and the rollback only runs if the
  function returns — a power loss in that window is not something this design
  recovers from, and the code says so rather than pretending otherwise. Two
  adjacent metadata syscalls is the whole mitigation.

**The symlink guard is a data-loss guard, not politeness.** `pluginloader`
accepts a symlinked plugin because `lfs.attributes` follows one, and on the
machine this is developed on `plugins/meguru.koplugin` *is* a symlink to the
repository. Without the guard the renames would move the link and install a
real directory in its place, orphaning the repo — and on the *second* update
`purgeDir` would be aimed at that link and delete the repository's contents,
because it recurses through the same following call. Installing is refused
before the download, so a development install does not pay 400 KB for it.

### `Net.getToFile`, and what it is not

The download cannot go through `Net.get`, and the reason is not the size.
`Net.get` collects its body with `ltn12.sink.table`, and `socketutil` enforces
its **total** timeout only inside its own sinks — the socket-level total is
reset on every poll, which `socketutil.lua:38-42` says outright. So everything
fetched through `Net.get` is bounded per read and not in wall-clock at all,
which is survivable for a feed page and not for a file a reader is watching
with a frozen UI. `socketutil.file_sink` is what makes the number mean
something, and writing to a file rather than to the heap is the other half.
The sink closes the handle itself on every terminating call, so the `pcall`d
`close` beside it covers only the request that died before the sink ever ran.

**`Net.get`'s own docstring is wrong about this**, and it is recorded rather
than fixed: it claims a feed page "has not finished in 30s, is not coming",
while its sink makes that untrue. The one-line repair is to give it
`socketutil.table_sink` too, and it wants its own decision — it touches the
reading path, and the walk is the only thing that has ever run through it.

### What is remembered, and why it is written on failure

`settings/meguru_update_cache.json` holds the last release found and a
`checked_at` timestamp. Two different clocks read it: the payload is reused for
an hour so a reader tapping the row twice spends one API call, and `checked_at`
gates a background check to once a week.

**`checked_at` is written on every completed check, including the failures, and
that is the whole reason it is a separate field from the payload.** A device
that is offline at every start would otherwise reach for the network on every
single start, forever — and on a Kindle, whose `isConnected()` is true whenever
wifi is on, "offline" is the ordinary case rather than the exception.

**A successful install rewrites the file rather than deleting it.** Deleting it
resets the weekly gate to "never checked", so the next start checks immediately
and so does every start after that until a check succeeds — which is
pagenumbercrop's behaviour and is the wrong shape.

### The row, and what it is not

*Check for updates* is the one row under `Settings` that is not a preference:
it stores nothing, and it is the only row there that can be *done* rather than
set. It is behind a `separator` on the `Set Meguru as default reader for .cbz`
row above it, and it is the reason the "one seam only" note on separators was
retired.

`Updater.checkForUpdates` goes through `NetworkMgr:runWhenOnline`, which asks
for a connection when there is none — the right thing for a tap, and the one
case it does not cover is a device that is **connected but not online**, where
it drops the callback rather than running it (`manager.lua:698-709`). Nothing
runs and nothing is said, which is why the "Checking…" message carries a
timeout; tapping again once the connection is real works. `checkSilentForUpdates`
gates on `isConnected` instead, because the one thing a background check must
never do is put a wifi prompt in front of a reader opening a book.

The result goes to `UIManager:askForRestart`, **not** `restartKOReader`. The
former defers through `event_handlers.Restart`, which shows the same
"Restart now" / "Restart later" prompt, broadcasts the `Restart` event first so
other plugins flush what they have open, and degrades to a message on a device
that cannot restart rather than quitting for nothing.

