--[[--
The on-disk byte cache: raw page images and book covers.

Bytes live here, not decoded buffers. A page is fetched once, written to disk
and read back for every later decode, so re-reading a book — or re-opening one
after a restart — costs no network at all. The cap is global rather than
per-book, and eviction is by modification time, so the least recently *used*
file is what goes.

Names are derived from the marker's slug rather than from its full path: a
marker can be moved or renamed, and the cache should not be orphaned by that.
--]]

local FS = require("meguru/fs")
local Naming = require("meguru/naming")
local Paths = require("meguru/paths")
local PSE = require("meguru/pse")
local logger = require("logger")

local Cache = {}

--- Raw bytes of one page. The `.img` suffix is what `prune` matches on, and it
--- is what keeps a page file from colliding with a cover file — covers carry
--- their own suffix below.
function Cache.pagePath(slug, pageno)
    return PSE.pageCachePath(slug, pageno) .. ".img"
end

--- Raw bytes of a book's cover.
---
--- Keyed by a hash of the cover URL as well as the slug: a book whose cover
--- link was re-pointed gets a new file rather than a stale hit, and the old one
--- ages out on its own.
function Cache.coverPath(slug, cover_url)
    return Paths.coverCacheDir() .. "/" .. slug .. "-cover-"
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

--- Drop every cached byte, returning how many files went and how much space
--- they took.
---
--- Nothing here is load-bearing: a page or a cover is refetched from the server
--- the next time it is needed, so clearing cannot break a book — it only frees
--- disk and drops warm pages. A page of the book open right now simply refetches
--- the next time it is painted from disk.
function Cache.clear()
    local removed, freed = 0, 0
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
    logger.info("Meguru: cleared", removed, "cached file(s),", freed, "bytes")
    return removed, freed
end

--- Drop the oldest files until at most `cap` remain.
---
--- A little headroom is taken beyond the cap so the prune does not run on every
--- single page once the cache is full — it costs a directory walk.
function Cache.prune(dir, cap)
    local entries = {}
    for _, name in ipairs(FS.listDir(dir)) do
        if name:match("%.img$") then
            local full = dir .. "/" .. name
            if FS.exists(full) then
                entries[#entries + 1] = { full = full, mtime = FS.mtime(full) or 0 }
            end
        end
    end
    if #entries <= cap then
        return
    end
    table.sort(entries, function(a, b) return a.mtime < b.mtime end)
    for i = 1, #entries - cap + 16 do
        FS.removeFile(entries[i].full)
    end
    logger.dbg("Meguru: pruned", #entries - cap + 16, "cached file(s)")
end

return Cache
