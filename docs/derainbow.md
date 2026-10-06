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

A Meguru book is none of those. `MeguruDocument` renders pages itself, through MuPDF
(`meguru/doc/image`), and hands them to the screen from its own `drawOnePage`; it answers
`self.koptinterface = {}` as a stub, so nothing reaches KoptInterface at all. The switch
never appears either, because it is inserted into options tables a Meguru book does not
have — the plugin's reader menu is its own (`ui/reader`).

`Document.hintPage` is the one hook that could have fired, and it does not:
`MeguruDocument:hintPage` overrides that slot with its own prefetch loop and never calls
the base method, so `derainbowify`'s wrap is shadowed.

**Nothing about this is a conflict.** Both plugins install, load and run. The other one
simply never sees a page.

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

Two shared libraries, from the other plugin's own installed directory:

```
<data dir>/plugins/derainbowify.koplugin/libs/color_detect-<platform>.so
<data dir>/plugins/derainbowify.koplugin/libs/moire_filter-<platform>.so
```

`<platform>` is `amd64`, `kobo`, `pocketbook`, `kindlehf`, `kindle` or `android-<arch>`,
spelled exactly as that plugin spells it — the suffixes are its filename convention and
nothing about them can be inferred from anywhere else. Both files must exist: `available()`
answers `false` if either is missing, if the panel cannot show colour
(`Device:hasColorScreen()`), or if the platform is not one it builds for.

**Nothing is vendored and nothing is redistributed.** Meguru loads someone else's GPL-3.0
binary at runtime and ships none of it; the dependency is detected, not declared, and a
reader without the other plugin simply never sees the row. `available()` is **memoised** —
it is a fact about an installation, not about a device state — so a plugin installed
mid-session is noticed after a restart.

The libraries are `ffi.load`ed lazily, on the first page that actually wants filtering, so
a reader who never turns the switch on never pays for a `dlopen`. The `ffi.cdef` is
wrapped in `pcall` on purpose: the other plugin declares the same four prototypes, and a
second identical declaration is refused by LuaJIT. A refusal there means the symbols
already exist, which is a working state.

**`cleanup_moire_resources` is deliberately never called.** The other plugin hooks
`UIManager.quit` to call it. Meguru will not wrap a KOReader core method for a resource
that the process teardown releases anyway; the wrap would be a global we do not need.

## The value, and the stamp

Per book, like the tone rows beside it: `configurable.derainbow` and the book's own
`kopt_derainbow`, seeded from the plugin-wide `derainbow` preference (`doc/defaults`), with
the row on the Tone tab. Long-press sets the default for new books, through the same
`Defaults.PREFERENCE_FOR` entry every other row uses.

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
- **The ABI is unversioned.** The four prototypes are frozen at the version this was
  written against. A signature change upstream is undefined behaviour rather than a caught
  error, however much of this module is `pcall`ed.
