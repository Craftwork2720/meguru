--[[--
The byte cache: raw page images in RAM, book covers on disk.

Bytes live here, not decoded buffers. A page is fetched once and its bytes are
handed back to every later decode out of a small in-memory LRU, so a page turn
costs no network at all. The cap is global rather than per-book, and eviction is
by recency of *use*, so the least recently read page is the one that goes.

Keys are derived from the book's *identity* — `Marker.cacheKey`, which is the
natural key (server, series, item) plus a readable head from the title. The
tests below are the ones that keep that honest:

  * Two books must never share an entry. Keying on the readable part alone does
    exactly that, so the digest carries identity and the head is decoration.
    (This module used to be handed the marker's basename. Every Suwayomi
    "Chapter 1" and every Kavita "Volume 1" therefore shared one file, and the
    second book to be opened was served the first one's bytes.)
  * The key must not move when the marker does. A marker can be moved, renamed
    or re-saved with a new title; the identity inside it does not change, so
    neither does the key here.
  * The key must not move when the *stream* does. Kavita's template embeds a
    rotatable API key and Suwayomi's chapter number can be renumbered, so
    neither is part of the key.

Pages being module-level is safe *because* the key is identity. The store is
shared by every document in the process, so a second document of the same book
finds the first one's pages instead of mistaking them for another book's — and
the only cost module-level state can ever have here is the one a cache is
allowed to have: it can go cold. Modules load once per process, so in practice
it does not.

Covers are the one thing still on disk, keyed by the same identity plus a hash
of the cover *URL*, so a book whose cover link was re-pointed gets a new file
rather than a stale hit and the old one is simply never read again.

Nothing cached is load-bearing: every entry can be refetched, so the whole
store may be dropped at any moment — see `clear`.
--]]

local FS = require("meguru/fs")
local Naming = require("meguru/naming")
local Paths = require("meguru/paths")
local logger = require("logger")

local Cache = {}

-- Raw page bytes, most recently used first: `{ key =, pageno =, bytes = }`.
--
-- A plain dense array, so `#` is exact under 5.1 and the oldest entry is always
-- the tail. The book identity is a field of the tuple rather than a prefix of a
-- filename — the one thing that changed when these moved off disk, and still
-- the thing that keeps two books apart, now inside a table the process shares.
local pages = {}

--- Raw bytes of one page, or nil. A hit is moved to the front.
---
--- `key` is the book identity from `Marker.cacheKey`; this module never derives
--- it, so there is exactly one place that decides what a book is.
function Cache.getPage(key, pageno)
    for i = 1, #pages do
        local entry = pages[i]
        if entry.key == key and entry.pageno == pageno then
            if i > 1 then
                table.remove(pages, i)
                table.insert(pages, 1, entry)
            end
            return entry.bytes
        end
    end
    return nil
end

--- Keep `bytes` for one page, evicting beyond `cap`.
---
--- `cap` is a parameter rather than a constant here so the policy stays with
--- the document, the way the old disk prune's did.
---
--- The comparison is `> cap` and not `>=`: `evictOldest` in `doc/document.lua`
--- loops on `count >= cap`, so its caps keep one fewer than they read. That is
--- harmless there and would not be here, where it would quietly turn a chosen
--- four into three.
function Cache.putPage(key, pageno, bytes, cap)
    for i = 1, #pages do
        if pages[i].key == key and pages[i].pageno == pageno then
            table.remove(pages, i)
            break
        end
    end
    table.insert(pages, 1, { key = key, pageno = pageno, bytes = bytes })
    -- Dropping the tail drops the last reference to those bytes, so the GC
    -- reclaims them without anything here having to be told to.
    while #pages > cap do
        table.remove(pages)
    end
end

--- Raw bytes of a book's cover.
---
--- Keyed by a hash of the cover URL as well as the book: a book whose cover
--- link was re-pointed gets a new file rather than a stale hit, and the old one
--- is never read again. That hash is 32 bits, which is deliberate and unlike
--- the book key — the two things it can confuse are two successive cover URLs
--- of the *same* book, where the cost is a stale cover, not another book's
--- bytes.
function Cache.coverPath(key, cover_url)
    return Paths.coverCacheDir() .. "/" .. key .. "-cover-"
        .. string.format("%08x", Naming.hash32(cover_url or "")) .. ".img"
end

function Cache.read(path)
    if not FS.exists(path) then
        return nil
    end
    return FS.readFile(path)
end

--- Write bytes out, creating the directory if it is not there yet.
---
--- The mkdir lives here rather than in `Paths`, which is pure by design, and
--- rather than at document init, which would have to know which of the two
--- directories this particular write needs. It costs one stat on a write that
--- only happens on a cache miss, so once per page ever.
---
--- Failure is not fatal: the caller still has the bytes and the page renders.
--- Only the next open pays for the fetch again.
function Cache.write(path, bytes)
    local dir = path:match("^(.*)/[^/]+$")
    if dir then
        FS.ensureDir(dir)
    end
    return FS.writeFile(path, bytes)
end

--- Drop every cached byte, returning how many entries went and how much space
--- they took.
---
--- Nothing here is load-bearing: a page or a cover is refetched from the server
--- the next time it is needed, so clearing cannot break a book — it only drops
--- warm pages and frees disk. A page of the book open right now simply
--- refetches the next time it is painted *from bytes*; if its decoded buffer is
--- still in the document's native LRU the repaint does not even need that.
---
--- The two-directory sweep below is now half a migration. `covers/` is live,
--- but `pages/` has held nothing since the bytes moved to RAM — it is swept
--- because files written by an older version would otherwise sit on disk
--- forever, with nothing left that would ever read or age them out. (Their
--- removal is not automatic for a reader who never taps this row. That is the
--- deliberate trade: one manual sweep, and no extra state to carry.) `FS` has
--- no `rmdir`, so the emptied `pages/` directory itself is left behind, which
--- is harmless.
function Cache.clear()
    local removed, freed = 0, 0
    for _, entry in ipairs(pages) do
        removed, freed = removed + 1, freed + #entry.bytes
    end
    pages = {}
    for _, dir in ipairs{ Paths.pageCacheDir(), Paths.coverCacheDir() } do
        for _, name in ipairs(FS.listDir(dir)) do
            if name:match("%.img$") then
                local full = dir .. "/" .. name
                local size = FS.size(full) or 0
                if FS.removeFile(full) then
                    removed, freed = removed + 1, freed + size
                end
            end
        end
    end
    logger.info("Meguru: cleared", removed, "cached item(s),", freed, "bytes")
    return removed, freed
end

return Cache
