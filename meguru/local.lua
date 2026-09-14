--[[--
The other books in a local `.cbz`'s folder, in the order the folder shows them.

## The folder is the series

That is the whole of the model, and it replaced one that read a series out of the
file *name*: volume tokens, bare trailing numbers, a leading number as a position,
which bracket was a release tag and which was part of the title. Every one of those
rules existed to answer a question the folder already answers — *are these two
files the same series?* — and answering it from the name meant a grammar nobody
could predict, defending against a layout nobody has: one folder holding two
series' books.

So there is no parse here. A file is a neighbour when it is in the same folder, of
the same extension, and is not a dotfile. The order is a **natural sort of the file
name**, so `2.cbz` comes before `10.cbz` rather than after it, and "the next one" is
the next entry in that order.

**What the model costs, and why the rows are gated on it.** A folder is not always
one series: a flat library, or two titles somebody put in one directory, will
navigate from one into the other — `next` on the last volume of one opens whatever
sorts after it. Nothing on disk distinguishes that folder from a real series
folder, so this does not pretend to: it is the price of the simplification and the
reason `Local.seriesOf` answers nil unless the folder holds **a second book to move
to**. A lone one-shot gets no navigation rows at all, rather than two that answer
"no next chapter".

**Nothing is written and nothing is remembered.** No marker, no index, no list kept
between two calls: the folder is listed when the reader asks, in a gesture that
asked for it, exactly as `meguru/feed` walks a server's feed. A folder has no
`rel=next`, so its own order stands in for it.
--]]

local util = require("util")
local logger = require("logger")

local Local = {}

-- ---------------------------------------------------------------------------
-- Names
-- ---------------------------------------------------------------------------

--- Directory and file name of `path`. A bare name gives an empty directory.
local function splitPath(path)
    local dir, name = path:match("^(.*)[/\\]([^/\\]*)$")
    if not dir then
        return "", path
    end
    return dir, name
end

--- The last component of a directory path, or "".
local function folderName(dir)
    return dir:match("([^/\\]+)$") or ""
end

--- `A-Z` folded downwards, one byte at a time, and nothing else touched.
---
--- **Not `string.lower`, and not `%u`.** Both are the C library's `tolower()` and
--- `isupper()` under the device's locale, which is not the C locale: under a
--- Turkish one `I` folds to a dotless `ı`, and on any UTF-8 locale a lead byte of
--- a Polish or CJK character is fair game. This is used to compare two names for
--- *equality* (is this the file we are reading) and two extensions, where a fold
--- that varied by device would be a fold that matched on one and not another.
local function asciiLower(s)
    return (s:gsub("[A-Z]", function(c)
        return string.char(c:byte() + 32)
    end))
end

--- A sort key that puts `2.cbz` before `10.cbz`.
---
--- **A key rather than a comparison function, and that is the point.** Walking two
--- names at once is the usual way to write a natural sort and the usual way to
--- make `table.sort` throw — "invalid order function for sorting" — from inside a
--- tap, when the walk turns out not to be a consistent order. A key is a function
--- of *one* name, so the comparison is a plain `<` between two strings and cannot
--- be inconsistent. Two different names never produce the same key either: digits
--- are re-encoded, every other byte is copied, and the encoding is injective.
---
--- A run of digits becomes the marker byte `\1`, its length without leading zeros
--- in three digits, and the run with those zeros dropped. So `2` sorts before `10`
--- — `001` is already less than `002`, before a single digit is compared — and
--- `2`, `02` and `002` land together, in that order.
---
--- That last order is the pad byte's doing and it is the opposite of what it looks
--- like: the dropped zeros are **not** a suffix, because the rest of the name
--- follows them. A pad of `\0` would therefore sort a name *earlier*, since `\0`
--- is below the `.` that comes next; the pad is `\255`, above every byte a UTF-8
--- name can hold, so fewer leading zeros sorts first. It is only ever reached when
--- two runs are the same number, so it decides ties and nothing else. (A run of
--- more than 999 digits would overflow the length field, which no file name has.)
---
--- Bytes >= 0x80 are copied verbatim, so a Polish or CJK name orders by its own
--- bytes, the way the file browser that wrote it would have shown it.
local function sortKey(name)
    local out = {}
    local i = 1
    while i <= #name do
        if name:byte(i) >= 48 and name:byte(i) <= 57 then
            local last = select(2, name:find("%d+", i))
            local run = name:sub(i, last)
            local digits = run:gsub("^0+", "")
            if digits == "" then
                digits = "0"
            end
            out[#out + 1] = "\1" .. string.format("%03d", #digits) .. digits
                .. string.rep("\255", #run - #digits)
            i = last + 1
        else
            out[#out + 1] = name:sub(i, i)
            i = i + 1
        end
    end
    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- The folder
-- ---------------------------------------------------------------------------

--- The run of books in `path`'s folder, sorted, and where `path` sits in it.
---
--- Answers `run, pos` — or `nil, reason`, the second value being why exactly when
--- the first is nil. The only function here that touches a filesystem, and the
--- only one that logs.
---
--- The listing is KOReader's own `util.findFiles` with `recursive = false`; this
--- module does not add a directory walk to `meguru/fs`, whose header says listing
--- was removed with the on-disk caches. It is **not capped**: a long webtoon run
--- is the case this exists for, and a cap low enough to catch a library folder
--- would refuse it too. What that costs is one `lfs.attributes` per entry of the
--- folder, on a menu build and on a tap — real work on a slow card, and the price
--- of not guessing at size.
---
--- **A listing that does not contain the file being read is a failure, not "no
--- neighbours".** `util.findFiles` swallows a failed `lfs.dir`, which leaves an
--- unreadable directory and an empty one as the same answer; the file being read
--- is in that folder, so a listing that has lost it has failed whatever it says.
local function runOf(path)
    local dir, base = splitPath(path)
    if dir == "" then
        return nil, "the file names no folder"
    end
    local lower_base = asciiLower(base)
    local self_ext = asciiLower(select(2, util.splitFileNameSuffix(base)) or "")

    local run = {}
    util.findFiles(dir, function(full, name)
        -- A dotfile is never a book. On a card written by macOS it is worse than
        -- useless: `._Berserk 02.cbz` is an AppleDouble companion of a real file.
        if name:sub(1, 1) == "." then
            return
        end
        -- The same extension the *current* file has, so a `.cbz` run is not joined
        -- by the `.cbr` beside it and never by a `.meguru` marker or a `.jpg`.
        if asciiLower(select(2, util.splitFileNameSuffix(name)) or "") ~= self_ext then
            return
        end
        run[#run + 1] = { path = full, name = name, key = sortKey(name) }
    end, false)

    local here
    for i = 1, #run do
        if asciiLower(run[i].name) == lower_base then
            here = run[i]
            break
        end
    end
    if not here then
        logger.warn("Meguru: cannot list the folder of", path,
            "(the listing does not contain it)")
        return nil, "the folder could not be listed, or does not contain this file"
    end

    -- By position in the sorted run, never by arithmetic on a number read out of a
    -- name: there is no number to read any more, and a position is the only thing
    -- the folder order actually states.
    table.sort(run, function(a, b)
        return a.key < b.key
    end)
    local pos
    for i = 1, #run do
        if run[i] == here then
            pos = i
            break
        end
    end

    logger.dbg("Meguru: local folder", dir, "—", #run, "book(s), this one at", pos)
    return run, pos
end

--- The folder this book shares with its neighbours, or nil when it has none.
---
--- Nil is the answer for a folder holding only this file, and *that* is the gate
--- the reader menu is drawn on: a lone one-shot gets no "open next in series" row
--- rather than a row that could only say there is no next. A folder with two books
--- answers with the folder's **name**, which is the only thing there is to call the
--- series — and what a "no next chapter" message says out loud.
function Local.seriesOf(path)
    local run = runOf(path)
    if not run or #run < 2 then
        return nil
    end
    return { name = folderName(splitPath(path)) }
end

--- The file either side of `path` in its own folder, or nil plus why.
---
--- `which` is `"next"` or `"previous"`; anything else reads as `"next"`. Both ends
--- of the folder are ordinary answers — the message the reader sees is the same
--- whichever way there is nothing, so the reason is for the log.
function Local.neighbor(path, which)
    local run, pos = runOf(path)
    if not run then
        return nil, pos
    end
    if #run < 2 then
        return nil, "nothing else in the folder"
    end
    local pick = run[which == "previous" and pos - 1 or pos + 1]
    if not pick then
        return nil, which == "previous" and "the first book in the folder"
            or "the last book in the folder"
    end
    return pick.path
end

return Local
