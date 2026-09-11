--[[--
Filesystem predicates and directory creation.

Deliberately small now. It held whole-file read/write and directory listing for
the on-disk page and cover caches; both are gone, and marker files were never
written through here anyway (they go through `LuaSettings`, which owns its own
I/O). What is left is the question every path decision asks — does this exist,
is it a directory, can I make it — plus the one attribute the document wants.
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

return FS
