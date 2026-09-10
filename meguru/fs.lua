--[[--
Filesystem operations: creating directories, reading and writing whole files,
listing and removing them. Everything the plugin does to the disk goes through
here.
--]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
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

function FS.readFile(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local data = f:read("*a")
    f:close()
    return data
end

function FS.writeFile(path, data)
    local f = io.open(path, "wb")
    if not f then
        logger.warn("Meguru: cannot write", path)
        return false
    end
    f:write(data)
    f:close()
    return true
end

function FS.removeFile(path)
    return os.remove(path) ~= nil
end

--- File names (not paths) directly inside `dir`, or an empty list.
function FS.listDir(dir)
    local names = {}
    if not FS.isDir(dir) then
        return names
    end
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            names[#names + 1] = name
        end
    end
    return names
end

--- Modification time of `path` in seconds, or nil.
function FS.mtime(path)
    return lfs.attributes(path, "modification")
end

--- Size of `path` in bytes, or nil.
function FS.size(path)
    return lfs.attributes(path, "size")
end

return FS
