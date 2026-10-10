
<p align="center">
  <picture>
    <img src="docs/meguru-logo.png" alt="Meguru" width="320">
  </picture>
</p>

<br>

<p align="center"> <a href="https://github.com/Craftwork2720/meguru/releases/latest/download/meguru.koplugin.zip"><img src="https://img.shields.io/badge/Download-meguru.koplugin.zip-735DA8?style=for-the-badge&logo=github&logoColor=white&labelColor=1f2328" alt="Download meguru.koplugin.zip"></a> </p>

<br>

Meguru is a manga reader for KOReader. It's faster than the stock mupdf reader on large files and built for manga: auto-crop, manga mode, two-page view, night mode and panel zoom.

It opens `.cbz` files on your device, and can also stream manga straight from your server (Kavita, Suwayomi, Komga) through OPDS, with no downloading. Streams open in the same reader, so everything works the same.

**Contents:** [Installation](#installation) · [The reader](#the-reader) · [OPDS streaming](#opds-streaming)

## Installation

1. Download `meguru.koplugin.zip` and extract it.
2. Copy the `meguru.koplugin` folder into `koreader/plugins/`.
3. Restart KOReader.

## The reader

Works the same for local `.cbz` files and `.meguru` streams.


| Feature | What it does |
|---|---|
| Auto-crop | Trims empty margins and removes printed page numbers |
| Fit | Full page, fit to width or fit to height |
| Two pages | Two pages side by side |
| Manga mode | Pages turn right-to-left |
| Auto-rotate | Rotates the screen for wide double-page spreads |
| Night mode | Natural colours instead of a harsh negative |
| Derainbow[^1] | Removes the rainbow shimmer on colour e-ink screens |
| Hidden status bar | Less clutter while reading |
| Panel reading | Long-press for panel-by-panel reading (see below) |

> [!TIP]
> Tap a setting to apply it to the current book. Long-press it to make it the default for every new book.

**Panel reading** has three views, switched with the first button of the viewer's own row:

- **Panel Cut**: each panel is cut out and shown by itself
- **Pan & Zoom**: the whole page stays, and a window moves over it panel by panel
- **Free View**: pinch and drag the page, with no panels and no page turning

In Panel Cut and Pan & Zoom, a middle tap opens a button row: the first button is the view, the second is the zoom (1.4×/1.7×/1.9×, or 1.5×/2×/2.5× in Free View). Each view remembers its own zoom.

Panel zoom is on for books Meguru opens. To turn it off for a book, use KOReader's own ⋮ → *Panel zoom (manga/comic)* row.

### Opening .cbz files

Use **Open with… → Meguru** in the file browser.

If a file has a `ComicInfo.xml` (what Rakuyomi writes), its title, author and summary are used. You can turn this off in Settings to use file names instead.

> [!IMPORTANT]
> On first run Meguru becomes the default reader for `.cbz` (once, and it leaves any reader you already chose alone). To undo it or turn it back on: ⋮ → Tools → Meguru → Settings → *Set Meguru as default reader for .cbz*. You can also tick *Always use this engine for file type* in the "Open with…" dialog; that choice wins over the automatic one.

### Moving through a series

⋮ → Tools → Meguru opens the next or previous chapter, fetching it if needed. Turn on **Auto-open next in series** (same Settings submenu) to do it automatically when you finish a chapter.

This also works for local `.cbz` folders, in natural order (`2.cbz` before `10.cbz`). The rows only appear when there is another book to move to.

<br>

## OPDS streaming

An optional extra: read straight from your server in the same reader, with all the features above.

Requires the built-in OPDS plugin (enabled by default), pointed at a Kavita, Suwayomi or Komga server.

Unlike KOReader's built-in page streamer, a Meguru stream is a real book: it appears in History, keeps your progress and can sync with the server. The `.meguru` file is only a pointer, so it takes up almost no space.

### Usage

1. Open the OPDS catalog in the file browser and browse to a manga or chapter.
2. Tap the entry, then **▶ Meguru this series**.
3. Choose where to start. Meguru saves the stream and opens it.

The same **▶ Meguru this series** row at the top of a series listing opens the first chapter you haven't read.

### Where streams are saved

File browser → Tools → Meguru → Settings:

- **Main folder for .meguru streams: …** set once, used for all new streams. Existing streams are not moved.
- **Subfolder per server**: saves to `<folder>/<server>/<series>/`

### Where to start reading

When the server is further ahead than your local progress, Meguru asks where to continue. Every button names its own stream, and the ▶ marks the server's position:

```
Meguru: Now That We Draw
  Start reading — Volume 1
  Continue — Volume 1, page 30
  ▶ Continue — Volume 2, page 2 (Server)
```

The first button always opens the stream you tapped. Tapping outside the dialog cancels.

### Good to know

- A stream needs a reachable server. If a page can't load, the reason is shown on the page and it fills in when you're back online.
- Creating a stream also saves a `.cover.jpg` in its folder (can be turned off in Settings).
- **Check for updates** in ⋮ → Tools → Meguru → Settings. It never installs without asking.
- A stream can't be exported as a real `.cbz`.
- If you uninstall the plugin, existing `.meguru` files stop opening.

## License

AGPL-3.0-or-later, same as KOReader. See [LICENSE](LICENSE).

#### My [User Patches](https://github.com/Craftwork2720/koreader-patches) for KOReader. ❤️

[^1]: All credit for Derainbow goes to [Euphoriyy](https://github.com/Euphoriyy) and his [derainbowify.koplugin](https://github.com/Euphoriyy/derainbowify.koplugin).