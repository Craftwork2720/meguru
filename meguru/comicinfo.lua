--[[--
The metadata a `.cbz` carries about itself: its `ComicInfo.xml`, read into
`doc_props` terms.

A `.cbz` is a zip, and the ComicRack schema — now the Anansi project's
`ComicInfo` — puts a `ComicInfo.xml` entry inside it. It is what comic libraries
write and serve (Komga and Kavita both), and it is what Rakuyomi writes into
every chapter it downloads: its `backend/shared/src/cbz_metadata` implements that
schema, and its reader fails with `no ComicInfo.xml entry in the archive` when a
file has none. So this is the *file* speaking about itself rather than one
plugin's convention.

## Why the whole schema is read and only seven fields are used

`ComicInfo` v2.1 declares around forty elements. **`doc_props` has seven slots**
— `title`, `authors`, `series`, `series_index`, `language`, `keywords`,
`description`, which is the list `BookInfo` actually draws
(`filemanagerbookinfo.lua:34-43`) — so "use the whole schema" cannot mean putting
the whole schema into `doc_props`; most of it has nowhere to be shown.

What it does mean, and what this module does, is **read the file as a schema
rather than as a list of fields we happen to want**: one pass collects every
non-empty element the entry has, and `MAP` decides which of them answers which
`doc_props` key. A field a newer writer adds is then read without a change here,
and the mapping is one table to read rather than a `match` per property.

## Read into memory, never to disk

`Archiver.Reader:extractToMemory` is the whole reason this can exist:
`meguru/updater` knows the other route, `extractToPath`, and that one writes —
which would have made merely opening a comic leave a file behind, against the one
rule this plugin keeps. `ffi/archiver` is required lazily, for the reason the
updater already gives: its module body loads libarchive, and a build without it
would take the whole plugin down at load rather than degrade one feature.

## What is logged, and why so much of it

**A comic with no `ComicInfo.xml` says nothing** — that is the ordinary case for
a folder of scans, not a fault, and a line per book is the noise the log-level
rule exists to keep out. Every other way of coming away empty is a *failure or a
refusal* and gets a line at `info`, because the first version of this module
swallowed all of them silently and the result was unreadable from the outside:
the title simply did not change, and nothing anywhere said why. A caught failure
that degrades quietly is survivable and invisible at the same time, and those two
must not both be true.
--]]

local logger = require("logger")

local ComicInfo = {}

-- The five predefined entities, and nothing else. `&amp;` is the one that turns
-- up in real series names, and leaving it encoded would put `&amp;` in History.
local ENTITIES = {
    ["&amp;"] = "&", ["&lt;"] = "<", ["&gt;"] = ">",
    ["&quot;"] = '"', ["&apos;"] = "'",
}

local ENTRY = "ComicInfo.xml"

-- A ceiling on what will be read, so an archive that happens to carry a huge
-- entry under that name cannot be made to allocate it. The real thing is under a
-- kilobyte; this is two orders of magnitude of room.
local MAX_BYTES = 64 * 1024

-- Once per process: a build without libarchive cannot read any comic's metadata,
-- so this is a property of the build rather than an event per book — and saying
-- it once per book would bury everything else.
local archive_support_reported = false

--- Which `ComicInfo` element answers which `doc_props` key.
---
--- **Element names are matched case-insensitively, and that is a requirement
--- rather than a convenience.** `ComicInfo.xsd` declares the language element as
--- `LanguageISO` and declares no second spelling of it — but the files in hand do
--- not follow the schema: Rakuyomi's downloads write `<LanguageIso/>`,
--- lowercased, which is ComicRack's spelling of it. So the divergence is the
--- *writer's* rather than a version of the schema, and an exact match would miss
--- it on the very files this was written for — silently, which is the failure
--- this module's logging exists to end. Both spellings are measured.
---
--- Only the seven keys `BookInfo` draws are mapped. The schema's other elements
--- — `Publisher`, `Imprint`, `Year`, the `Penciller`/`Inker` credit list,
--- `Manga`, `AgeRating` — have no slot in `doc_props` and would be written into
--- the sidecar for nothing to read.
---
--- Two of these are judgement calls and are named as such so they are one line
--- to change:
---
---   * `keywords` takes `Tags`, falling back to `Genre`. `doc_props` calls the
---     field "Keywords", which is a folksonomy term like Tags; ComicRack's
---     `Genre` is a short category list. Neither is a perfect fit, and nothing
---     has been measured against a file that fills both.
---   * `authors` takes `Writer`. The schema describes it as "person who wrote
---     the book", and `Penciller`/`Inker`/`Letterer` are credits rather than
---     authorship — `BookInfo` shows one "Author(s):" line.
local MAP = {
    { prop = "title",        tags = { "title" } },
    { prop = "series",       tags = { "series" } },
    { prop = "series_index", tags = { "number" }, numeric = true },
    { prop = "language",     tags = { "languageiso" } },
    { prop = "keywords",     tags = { "tags", "genre" } },
    { prop = "description",  tags = { "summary" } },
    { prop = "authors",      tags = { "writer" } },
}

--- Trim, decode and reject-empty. Nil for anything that is not text worth using,
--- which is the same answer as a field the file left out.
local function text(value)
    if type(value) ~= "string" then
        return nil
    end
    value = value:gsub("&%a+;", ENTITIES):gsub("^%s+", ""):gsub("%s+$", "")
    return value ~= "" and value or nil
end

--- Every non-empty element of the entry, keyed by its lowercased name.
---
--- ComicInfo is flat: its elements sit directly under the root and hold text.
--- The pattern therefore wants the closing tag to follow immediately, which also
--- skips the root itself — `<ComicInfo xmlns:…>` carries attributes and its body
--- holds `<`, so neither it nor the `<?xml …?>` declaration can match.
---
--- An empty element (`<Tags/>`, and Rakuyomi writes several) simply does not
--- match, which is the same answer as an element that is not there at all.
local function elements(xml)
    local found = {}
    for tag, value in xml:gmatch("<([%w_]+)%s*>([^<]*)</%1>") do
        local name = tag:lower()
        local decoded = text(value)
        if decoded and found[name] == nil then
            found[name] = decoded
        end
    end
    return found
end

--- The archive's metadata in `doc_props` terms, or nil.
---
--- Nil is an ordinary answer — a plain `.cbz` from a folder of scans has no such
--- entry — and every caller falls back to the file's name, which is what a
--- `.cbz` was known by before this existed. A truncated or unreadable entry
--- answers the same way, deliberately: metadata a reader never asked for must
--- not be able to cost them the book.
---
--- The returned table is `doc_props`-shaped and never contains `title` as nil
--- alone without the caller's fallback having been applied — this module does
--- not know the file name, and the caller does.
function ComicInfo.read(file)
    if type(file) ~= "string" or file == "" then
        return nil
    end
    local ok_archiver, Archiver = pcall(require, "ffi/archiver")
    if not ok_archiver or type(Archiver) ~= "table" or not Archiver.Reader then
        if not archive_support_reported then
            archive_support_reported = true
            logger.info("Meguru: cannot read .cbz metadata - this build of"
                .. " KOReader has no archive support")
        end
        return nil
    end
    local reader = Archiver.Reader:new()
    if not reader:open(file) then
        logger.info("Meguru: cannot open", file, "to read its metadata ("
            .. tostring(reader.err or "no reason given") .. ")")
        return nil
    end

    -- **`entry.size` is a cdata `int64_t`, not a Lua number**, and comparing it
    -- to a Lua number is what LuaJIT's FFI does natively — so it is compared
    -- directly rather than through `tonumber`, which does not convert cdata.
    -- `type(entry.size) == "number"` is the trap here and it is a *silent* one:
    -- it is false for `754LL`, so a guard written that way rejects the entry and
    -- looks exactly like an archive that has none. That is what the first
    -- version of this module did, and it is why a book opened through Rakuyomi
    -- kept its hashed file name while every part of the read was in fact working.
    -- Measured on a real download: `entry mode=file size=754LL`.
    local found, xml
    pcall(function()
        for entry in reader:iterate() do
            if entry.path == ENTRY and entry.mode == "file" then
                found = true
                if entry.size and entry.size > MAX_BYTES then
                    break
                end
                xml = reader:extractToMemory(entry.path)
                break
            end
        end
    end)
    reader:close()

    if not found then
        -- The ordinary case, and deliberately silent.
        return nil
    end
    if type(xml) ~= "string" then
        logger.info("Meguru: " .. ENTRY .. " in", file, "could not be read")
        return nil
    end

    local fields = elements(xml)
    local props, count = {}, 0
    for _, rule in ipairs(MAP) do
        local value
        for _, tag in ipairs(rule.tags) do
            value = fields[tag]
            if value then
                break
            end
        end
        if value then
            -- `Number` is a string in the schema ("97.5", and a scanlation will
            -- write "12a"), so a value that will not convert is kept as it is
            -- rather than dropped — `BookInfo` prints it either way.
            props[rule.prop] = rule.numeric and (tonumber(value) or value) or value
            count = count + 1
        end
    end
    if count == 0 then
        logger.info("Meguru: " .. ENTRY .. " in", file,
            "carries none of the fields a book is shown by")
        return nil
    end
    logger.dbg("Meguru: .cbz metadata -", count, "field(s), title",
        props.title or "(none)")
    return props
end

return ComicInfo
