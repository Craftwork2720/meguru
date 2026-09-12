--[[--
Filesystem predicates and directory creation, plus the one raw write.

Deliberately small. It held whole-file read/write and directory listing for the
on-disk page and cover caches; both are gone, and marker files were never
written through here anyway (they go through `LuaSettings`, which owns its own
I/O). What is left is the question every path decision asks — does this exist,
is it a directory, can I make it — plus the one attribute the document wants.

`writeFile` comes back for one caller and one kind of file: a series' artwork,
saved beside its markers so that something outside KOReader can find it. It
writes bytes verbatim and knows nothing about what they mean — see
`meguru/seriescover`, which is the only thing that calls it.
--]]

local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local FS = {}

function FS.isDir(path)
    return lfs.attributes(path, "mode") == "directory"
end

function FS.exists(path)
    return lfs.attributes(path, "mode") ~= nil
end

--- Create `dir` and any missing parents. Returns the path, or nil on failure.
function FS.ensureDir(dir)
    if FS.isDir(dir) then
        return dir
    end
    return util.makePath(dir) and dir or nil
end

--- Modification time of `path` in seconds, or nil.
function FS.mtime(path)
    return lfs.attributes(path, "modification")
end

--- Write `data` to `path` verbatim. Returns the path, or nil plus a reason.
---
--- **Binary mode is not a detail.** `"w"` would translate line endings on the
--- way out, which for an image means every `\n` byte in it becomes `\r\n` and
--- the file is silently corrupted — a 53 KB WebP with a few hundred extra bytes
--- and a header that still looks right. `"wb"` writes what it was given.
---
--- The caller is responsible for `path`'s directory existing: this creates the
--- file, not the folder, and `Marker.saveAt` has already made the folder before
--- anything asks for a cover.
---
--- Each step is checked rather than assumed. A full disk fails at `write`, not
--- at `open`, and a `close` that fails has usually lost buffered data — so the
--- two are checked separately and the file is closed either way.
function FS.writeFile(path, data)
    if type(path) ~= "string" or path == "" then
        return nil, "no path"
    end
    if type(data) ~= "string" then
        return nil, "no data"
    end
    local handle, open_err = io.open(path, "wb")
    if not handle then
        return nil, tostring(open_err)
    end
    local ok, write_err = handle:write(data)
    local closed, close_err = handle:close()
    if not ok then
        return nil, tostring(write_err)
    end
    if not closed then
        return nil, tostring(close_err)
    end
    return path
end

return FS
