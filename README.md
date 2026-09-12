# Meguru

A KOReader plugin that turns manga streamed from an OPDS server into ordinary
KOReader **books**. No archive is ever downloaded: each page is fetched over HTTP
only when you are about to read it, and the book behaves like any other book on
your device.

> [!NOTE]
> Meguru needs a server that supports **OPDS page streaming** (OPDS-PSE).
> Kavita and Suwayomi are supported today.

## Why use it

KOReader already ships a page-stream viewer, but it is a *quick look*: close it
and your place is gone, and it never appears in your library. Meguru saves the
stream as a real book instead:

- it appears in **History** and on the home screen, like any other book;
- KOReader keeps its normal **reading progress** — close it, reopen it, carry on;
- if the server already knows where you stopped — on another device, or in the
  server's own web reader — a book you have never opened here starts there;
- finishing a volume can open the next one by itself;
- every page is still requested one at a time, as you read.

## Installation

1. Copy the `meguru.koplugin` folder into your `koreader/plugins/` directory.
2. Restart KOReader.
3. Make sure the built-in OPDS plugin is enabled — it is by default.

Meguru does **not** replace the built-in OPDS browser. It adds one row to the
dialog that browser already shows; the browser itself is never modified.

To uninstall, delete the `meguru.koplugin` folder.

## Usage

1. Open the **OPDS catalog** in KOReader's file browser, as usual.
2. Browse to a manga or chapter and tap the entry.
3. In the dialog that appears, tap **▶ Meguru this series**.
4. Meguru asks where to start, saves the book, and opens it.

From then on it is an ordinary book: reopen it from **History** and you continue
where you left off.

> [!TIP]
> The same **▶ Meguru this series** row is also offered at the top of a series
> listing. There it opens the **first chapter you have not read**, which is the
> quickest way back into a long series.

### Where books are saved

Meguru never asks for a folder while you are trying to read. Set it once, and
every new book goes there:

- **File browser** → *Tools* → **Meguru** → *Save books in: …*
- turn on *Subfolder per catalog* to also nest books under their catalog's name:
  `<folder>/<catalog>/<series>/`

Changing the folder does not move books you have already saved.

## While reading

| Feature | What it does |
|---|---|
| Auto-crop | Trims the empty margins around the artwork |
| Page-number crop | Removes a printed page number from the bottom gutter |
| Fit | Full page, fit to width, or fit to height |
| Manga mode | Pages turn right-to-left |
| Auto-rotate | Wide double-page spreads rotate the screen to fit |
| Night mode | Keeps colours natural instead of a harsh negative |
| Hidden status bar | Removes clutter while you read |
| Panel zoom | Long-press a panel to zoom into it (on by default) |

> [!TIP]
> Tap a setting to apply it to the book you are reading. Long-press it to make it
> the default for every new book Meguru opens.

**Panel zoom** is the exception, and deliberately: its switch is KOReader's own —
**⋮ → Panel zoom (manga/comic) → *Allow panel zoom*** — and there is one of it
for every Meguru book. Flip it once and it stays flipped, exactly as it does for
a `.cbz`. It starts on.

The reader's **⋮ → Tools → Meguru** menu holds the rest:

- *Find the next / previous chapter* — when the book has no neighbour yet, this
  fetches the series' chapter list and opens it;
- *Auto-open next at the end* — opens the next chapter by itself when you finish
  one;
- *Hide status bar*, and the same two folder settings as the file browser.

## Where to start reading

When the server knows a position that differs from yours, Meguru asks instead of
guessing. The title names the **series**, because the question is where in the
series to carry on, and every button names its own book:

```
Meguru: Now That We Draw
  Start reading — Volume 1
  Continue — Volume 1, page 30
  ▶ Continue — Volume 2, page 2 (Server)
```

The **▶** marks the server's answer — the chapter it has not seen you finish. It
is one button with two readings: if that position is inside the book you are
opening, the button names a page; if it is in a later volume, it names a book.

The first button is always there, and always opens the book you tapped. Tapping
past the dialog cancels: nothing is opened, and nothing is saved.

## Reading local files

Meguru can also open `.cbz` files already on your device, with the same cropping,
night mode and page-turning behaviour as a streamed book. Use **Open with… →
Meguru** from the file browser.

> [!IMPORTANT]
> You can pick *Always use this engine for filetype* to make Meguru your default
> CBZ reader, or just once without changing your default.

## What is actually on your disk

Each saved book is a small **marker file** with the `.meguru` extension. It is not
an archive and holds no pages — just enough to find the stream again: the server
it came from, which chapter it is, the page URL template and the page count.

**Nothing else is written.** Pages are kept in memory as you read and are gone
when you close the book; there is no page cache and no cover cache on disk, and
no database. The only thing Meguru creates is markers.

> [!WARNING]
> Because a book is a marker and not an archive, it needs the server to be
> reachable to display pages. And because the markers are read by this plugin,
> uninstalling Meguru leaves books that no longer open — delete the `.meguru`
> files if you remove the plugin.

**Opening a book needs no network and no configuration** — everything required to
open the marker is inside the file, and Meguru has no database and no cache to be
missing. Reading is a different matter: the pages come from the server, so a page
that has not already been fetched cannot be shown. When one is missing, **the
reason is written where the page would be** instead of a blank page — no
connection, a server that is not answering, an error the server returned — and
the log says the same. Turning the page tries again, and so does reconnecting:
the page you are looking at fills in by itself once the Wi-Fi is back. Looking for the next chapter also
needs the network, because it means reading the series' chapter list from the
server.

## Limitations

- **OPDS 1.x catalogs with page streaming.** Entries that only offer a file
  download keep their normal download buttons, untouched.
- **The next chapter is fetched when you ask for it.** There is no background
  crawling of your libraries, so a series you have just added knows only the
  chapter you opened until you ask for a neighbour.
- **Reading progress is not written back to the server by Meguru.** It reads the
  position the server reports; where the server tracks progress from page
  fetches, that happens on the server's side.
- **A book cannot be exported or moved like a CBZ.** It is a marker; the pages
  live on the server.

## Upgrading from an older version

Versions before this one kept a local catalog in
`koreader/settings/meguru.sqlite3`, and even older ones kept page and cover
caches under `koreader/cache/meguru/`. Nothing reads either any more, and nothing
sweeps them:

```
koreader/settings/meguru.sqlite3     # delete by hand
koreader/cache/meguru/pages/         # delete by hand
koreader/cache/meguru/covers/        # delete by hand
```

Markers written by an older version still open and read. They carry less than new
ones do — an old marker does not record which server software it came from, so
Meguru has to work that out from the page URL before it can find the next
chapter.

## What is in the folder

```
_meta.lua          plugin manifest
main.lua           provider registration and menu dispatch

meguru/
  marker.lua       the marker file: read, write, naming, series identity
  feed.lua         reading a series feed: pagination, reading order, neighbours
  pse.lua          OPDS-PSE: finding the stream link, building a page URL
  net.lua          HTTP and feed parsing
  credential.lua   what a credential looks like in a URL: redact / restore
  sources.lua      read-only view of KOReader's OPDS settings
  settings.lua     plugin-wide preferences
  paths.lua        every path Meguru uses
  fs.lua           filesystem predicates and directory creation
  naming.lua       titles, series names, folder-safe names, stable keys
  hook.lua         runtime wraps on the built-in OPDS browser
  driver/          per-server knowledge (Kavita, Suwayomi)
  doc/             the document itself: rendering, decoding, per-book defaults
  ui/              the open flow, the reader integration, the two menus
```

**No file belonging to KOReader or to another plugin is ever modified.** Meguru
wraps a few methods of the built-in OPDS plugin in memory — restarting KOReader
removes the wraps — and writes two things: marker files, and the same per-book
settings file KOReader keeps beside every document it opens.

## Credits

Meguru is the successor to `meguru.koplugin`, which is in turn the successor to
`opdsbook.koplugin`. The old plugins are kept for reference; this one shares no
files or formats with them, so books saved by an older plugin are simply
different books.
