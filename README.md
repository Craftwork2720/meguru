<p align="center"> <picture> <img src="docs/meguru-logo.png" alt="Meguru" width="320"> </picture> </p> <br>

**Meguru is a manga reader for KOReader that also streams manga directly from your server (Kavita, Suwayomi, Komga) — no downloading required.**

It works two ways:

- **As a local reader** — faster than the stock mupdf reader, especially on large files, and built specifically for manga instead of general documents. Opens `.cbz` files already on your device, with auto-crop, manga mode, night mode and panel zoom.
- **As an OPDS streaming client** — point it at your server and pages load one at a time as you read, nothing downloaded up front, but each volume or chapter still sits in your library and behaves like an ordinary book.

Use it as just a fast `.cbz` reader, no server required — or hook it up to your OPDS library and read your way through a whole series without ever leaving the reader.

**Contents:** [Installation](#installation) · [The reader](#the-reader) · [OPDS streaming](#opds-streaming)

## Installation

1. Copy the `meguru.koplugin` folder into your `koreader/plugins/` directory.
2. Restart KOReader.

To uninstall, delete the `meguru.koplugin` folder.

---

# The reader

Everything below applies whether the book came from your device or from a stream.

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
| Panel zoom | Long-press a panel to zoom in, tap to move to the next one — read panel-by-panel |

> [!TIP]
> Tap a setting to apply it to the book you're reading. Long-press it to make
> it the default for every new book Meguru opens.

Panel zoom is a KOReader feature; Meguru just turns it on by default for the
books it opens (*Settings* → *Panel zoom in Meguru books*).

## Opening `.cbz` files

Use **Open with… → Meguru** from the file browser.

> [!IMPORTANT]
> **Meguru makes itself the reader for every `.cbz` on first run.** That's a
> one-time thing: it happens when the plugin is installed, leaves alone any
> reader you'd already chosen, and never happens again on its own.
>
> To undo it — or turn it back on — go to **⋮ → Tools → Meguru → Settings** →
> *Set Meguru as default reader for .cbz*. You can also set this from the
> "Open with…" dialog by ticking *Always use this engine for file type*;
> either way, that choice wins over the automatic claim.

---

# OPDS streaming

Requires the built-in OPDS plugin, enabled by default, pointed at a Kavita,
Suwayomi or Komga server.

## Why use Meguru for this

KOReader's built-in page-stream viewer is a *quick look*: close it and your
place is gone, and it never shows up in your library. Meguru turns a stream
into a real book instead — it appears in **History**, keeps your reading
progress, and can pick up where you left off on another device or in the
server's own web reader.

A `.meguru` file itself stores none of the manga — no pages, no archive —
so it takes up next to no space on your device; the pages only ever live on
the server.

## Usage

1. Open the **OPDS catalog** in KOReader's file browser, as usual.
2. Browse to a manga or chapter and tap the entry.
3. In the dialog that appears, tap **▶ Meguru this series**.
4. Meguru asks where to start, saves the stream, and opens it.

From then on it's an ordinary book: reopen it from **History** and you
continue where you left off.

> [!TIP]
> The same **▶ Meguru this series** row also appears at the top of a series
> listing. There it opens the **first chapter you haven't read** — the
> quickest way back into a long series.

### Where streams are saved

Meguru never asks for a folder while you're trying to read. Set it once, and
every new stream goes there:

- **File browser** → *Tools* → **Meguru** → ***Settings*** →
  *Main folder for .meguru streams: …*
- Turn on *Subfolder per server* to also nest streams under their server's name:
  `<folder>/<server>/<series>/`

Changing the folder later doesn't move streams you've already saved.

### Where to start reading

When you open a `.meguru` stream and the server is further ahead than what's
saved locally, Meguru asks whether to continue where the file left off or
where the server says you got to — instead of guessing. The title names the
**series**, and every button names its own stream:

```
Meguru: Now That We Draw
  Start reading — Volume 1
  Continue — Volume 1, page 30
  ▶ Continue — Volume 2, page 2 (Server)
```

The **▶** marks the server's answer — the point it hasn't seen you finish. If
that position is inside the stream you're opening, the button names a page;
if it's in a later volume, it names that stream instead.

The first button is always there and always opens the stream you tapped.
Tapping outside the dialog cancels — nothing opens, nothing is saved.

### Moving through a series

The reader's **⋮ → Tools → Meguru** menu can open the next or previous
chapter, fetching it from the server if it isn't already saved. Turn on
*Auto-open next in series* (same Settings submenu) to have it happen
automatically as soon as you finish a chapter.

### Good to know

- Creating a series stream also drops a `.cover.jpg` in its folder — turn
  that off in *Settings* if you don't want it.
- A stream needs the server to be reachable to show its pages — if a page
  can't load, Meguru tells you why right on the page (no connection, server
  error, etc.) and fills it in once you're back online.
- Uninstalling the plugin leaves streams that no longer open — delete the
  `.meguru` files if you remove it.
- On Komga, open books from inside a series, not from "Latest books", "On
  Deck" or "Keep Reading" — Komga doesn't tell Meguru which series those
  entries belong to, so it won't guess and open the wrong one.
- A stream can't be exported like a real `.cbz` — it's just a pointer to the
  pages on the server, not the pages themselves.