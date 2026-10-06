# Derainbow

The moiré filter borrowed from `derainbowify.koplugin`: why that plugin does nothing here
on its own, where the filter is applied, and the one buffer shape it is allowed to touch.

Part of the design record; [CLAUDE.md](../CLAUDE.md) is the map.

## The plugin that does nothing here

`derainbowify.koplugin` removes the rainbow shimmer a Kaleido 3 panel puts over fine
black-and-white artwork — which is most manga — with a Fourier pass in a native library
it builds and ships itself. Installed beside Meguru, it is **completely inert on a Meguru
book**, and it fails silently rather than loudly, which is why this file exists.

It reaches KOReader through four wraps and one menu section:

| its hook | what it is for |
|---|---|
| `KoptInterface.renderPage` | the rendered tile, the path it actually filters |
| `KoptInterface.renderOptimizedPage` | the hinting pre-render |
| `Document.hintPage` | warming a page ahead |
| `CreDocument:drawCurrentView` | the reflowable buffer |
| `KoptOptions` / `CreOptions` | where its switch is inserted |

A Meguru book is none of those. `MeguruDocument` renders pages itself through MuPDF and
answers `self.koptinterface = {}`, so nothing reaches KoptInterface and the switch never appears.

`Document.hintPage` is the one hook that could have fired, and it does not:
`MeguruDocument:hintPage` overrides that slot with its own prefetch loop and never calls
the base method, so `derainbowify`'s wrap is shadowed — but nothing here is a conflict.

## Where the filter runs

**At the two seams where a tile is produced, and not at the decode.** Those are
`MeguruDocument:renderPage` and `MeguruDocument:drawPagePart` — between them they are
every pixel a reader sees: the reader view (`direct` and `scale` alike), both halves of a
two-page spread, and every panel view, since panel zoom is the one consumer that never
passes through `renderPage`.

Applying it at the decode instead — the five functions that produce page buffers — was the
obvious design and is wrong three times over:

- **The decode is shared.** The retained native buffer is what the auto-crop, the panel
  detector, the page-number strip and the blank test all read their pixels from, through
  `Image.rasterFor`. Those were calibrated on the page as it arrived. Filtering the source
  moves every one of those answers, in ways that would look like a detector bug.
- **One path would be filtered twice.** A `scale` paint decodes a native and then slices
  and rescales it, so a filter on both would run over the same pixels twice.
- **Covers are decodes too.** `getCoverPageImage` and `_localCoverPageImage` call the same
  two decode functions the reader does, so every decode-site filter would need a special
  case to leave them alone. At the seams they are excluded *by construction* — a cover
  never becomes a tile.

Filtering at the seam is also what makes an **in-place** filter safe. The buffer there is
freshly rendered and owned by nobody else: either `renderRegionDirect`'s own
`page.draw_new`, or a `decodeRegion` that is documented never to hand back the
LRU-cached native (its 1:1 case deliberately copies, `document.lua`). The tile is filtered
*before* `cacheTile`, so the cached tile is the filtered one and a cache hit never pays
twice. The other plugin has to filter a copy, because stock's tile is shared with its
cache; Meguru's is not.

## The one buffer shape it may touch

`Derainbow.apply` refuses everything that is not `TYPE_BBRGB32` with `stride == width * 4`.
**That is a safety rule, not a preference**, and it is the single most important line in
the module.

`remove_moire` decides what it is looking at from `bpp = stride / width`:

| bpp | what the C does |
|---|---|
| 4 (RGB32) | the colour path — the one this filter is for |
| 3 (RGB24) | falls into the **grayscale** branch, writing one value into three bytes: a colour page comes back grey |
| 2 (BB8A) | takes that same three-byte-per-pixel branch over a two-byte pixel: a **heap overflow of one byte per pixel** |
| 1 (BB8) | 8-bit grayscale; the filter has nothing to remove on a colour panel |

`derainbowify`'s own bridge gates on `bpp >= 3` and so lets the second row through; it
never meets the third only because it never filters an alpha buffer. Meguru gates on the
exact type and refuses the rest, and the refusal costs nothing: **a page that is not
filtered is a page as it was.** A refusal is also logged once per reason per session, at
`dbg`, so a reader who turns the switch on where it cannot work can find out why without
the log filling with one line per pan.

The gate has a menu half: the row is offered only where `Image.colorEnabled()` is also
true (`ui/reader`), so a reader who turns colour rendering off is not offered a switch
whose effect the next paint would decline to produce.

## What is loaded, and from where

Two shared libraries, **shipped inside this plugin**:

```
<plugin dir>/libs/color_detect-<platform>.so
<plugin dir>/libs/moire_filter-<platform>.so
```

`Paths.lib` derives the path; `libs/README.md` records where the files came from, what
version they are and under what licence. `<platform>` is `amd64`, `kobo`, `pocketbook`,
`kindlehf`, `kindle` or `android-arm`/`android-arm64` — the suffixes are the other
project's filename convention and nothing about them can be inferred from anywhere else.

**`derainbowify.koplugin` is neither needed nor consulted.** An earlier version looked for
it in the data directory and answered "unavailable" when it was absent, which made the row
depend on a second install for no reason a reader could see. Vendoring the pair removes
that, and removes the ABI variance that came with it: what is loaded is what was tested,
whichever copy of the other plugin happens to be on the device.

**That freezes the version, and it is the price of the independence.** The four prototypes
in `meguru/derainbow.lua` are written against 0.0.12, and LuaJIT's FFI does not check a
signature against the library it calls — a changed one is undefined behaviour rather than
an error. So a newer `derainbowify` cannot break this, and cannot fix it either; updating
is a human re-copying the files and re-testing, which is what `libs/README.md` says.

**`available()` loads rather than looks.** Since the files are ours they are present on
every supported platform, so a plain existence check would be right everywhere except the
one place it matters: an Android install whose plugin directory sits inside the APK ships
these files and cannot `ffi.load` them. A row that appears and then does nothing is worse
than a row that is not there, so the load itself is the test. It is memoised, so it costs
one `dlopen` per session whichever caller reaches it first — the menu deciding whether to
offer the row, or the render path on the first page that wants filtering. The other three
conditions are a colour panel (`Device:hasColorScreen()`), a platform the builds cover,
and both files being on disk.

`init_moire_resources` is the one thing still deferred: it allocates, and a reader who
never turns the row on should not pay for it. The `ffi.cdef` is wrapped in `pcall` on
purpose — a second declaration of an already-declared symbol is refused by LuaJIT, and a
refusal there means the symbols exist, which is a working state.

**`cleanup_moire_resources` is deliberately never called.** The other plugin hooks
`UIManager.quit` to call it. Meguru will not wrap a KOReader core method for a resource
that the process teardown releases anyway; the wrap would be a global we do not need.

## Where it can run at all

The filter targets the colour filter array of a **Kaleido 3** panel. Whether the row
appears is decided by the gates above; whether the filter helps is a property of the panel,
and the two are not the same question.

| device | colour? | build? | row shown | effect |
|---|---|---|---|---|
| Kobo Clara/Libra Colour (`Kobo_monza`, `Kobo_spaColour`) | yes | `kobo` | yes | **the case it exists for** |
| Kindle Colorsoft, Scribe Colorsoft | yes | `kindlehf`/`kindle` | yes | **unknown** — a different panel technology, and KOReader has no CFA handling for it |
| PocketBook colour models | yes | `pocketbook` | yes | unknown |
| Android, colour | yes | `android-arm*` | only where the plugin dir is loadable | unknown |
| reMarkable Paper Pro | yes | **none** | no | — |
| desktop / emulator | yes | `amd64` | yes | **the only one measured** |
| every monochrome reader | no | — | no | — |

**Only the desktop has been run.** The filter was exercised there on a real page of a
local `.cbz` (806×1132 tiles, 36–51 ms) and on synthetic buffers; the rest of the table is
what the code says, not what anyone has seen. `docs/known-issues.md` records the two
consequences that matter most — the unmeasured cost on an ARM reader, and the fact that
whether the rainbow actually goes away has never been observed at all.

## The value, and the stamp

Per book, like the tone rows beside it, seeded from the plugin-wide `derainbow` preference.

**A book that carries a stored `1` opens unfiltered where the libraries are missing**, and
that is a property of `MeguruDocument:derainbow()` rather than of the seeding: the accessor
answers `false` when `Derainbow.available()` does. The value is the reader's and travels
with the book; what it *means* on any given device is filtered-or-not, and this device
cannot.

The switch joins the tone pair in `syncTone` and in the tile stamp — `tileAtTone` refuses a
tile rendered under the other answer — but **it is deliberately not allowed to cost what a
tone change costs.** A tone is baked into the decode, so moving one drops the whole native
cache and every memo derived from it. This filter runs on the tile, not the decode, so the
decodes are still exactly right: only the tiles are stale, and those are stamped rather than
freed, for the reason [render-path](render-path.md) sets out (the panel viewer can hold one
across paints). The row's handler is therefore a write and a `ReZoom`, and nothing else.

## Coexistence, and what to watch

- **Its Dispatcher action will crash on a Meguru book.** A gesture bound to derainbowify's
  own `copt_derainbow` runs a handler that reaches for `self.ui.rolling`, which a
  page-turning reader does not have. Meguru cannot patch that; its own row uses its own
  event and never takes that path. See [known-issues](known-issues.md).
- **Its `ReaderConfig:init` wrap** sets `self.options = KoptOptions` for any document whose
  `koptinterface` is non-nil — and Meguru's is `{}`, not nil, so this fires. Meguru's
  curation replaces the options at menu-open time and `Defaults.apply` runs after the
  stock defaults are loaded, so the curated dialog is not clobbered; it is worth a look on
  a device with both installed.
- **The ABI is frozen at 0.0.12, and nothing enforces that.** The four prototypes match the
  vendored pair and nothing checks them against anything. This is the deliberate side of the
  trade above — a newer upstream release cannot break the row — but it also means a fix in
  that release does not arrive either, and the only thing that would notice is a human
  re-reading `libs/README.md` and re-copying the files.
- **A second copy of the libraries may be in the process.** If `derainbowify.koplugin` *is*
  installed, it loads its own handle to its own files for its own hooks — which are inert on
  a Meguru book. Two `ffi.load`s of two versions of the same library is not a conflict here
  (each handle is separate and neither plugin calls the other's), but it is worth knowing
  when reading a log with both installed: the `ffi.load:` lines that matter are the ones
  naming *this* plugin's directory.
