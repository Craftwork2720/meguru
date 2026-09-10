--[[--
Turning server-provided titles into series names, folder components and marker
file names.

Pure string work: no I/O, no settings, no catalog. Lua 5.1 strings are byte
strings and device filesystems store UTF-8 names verbatim, so every operation
here is byte-exact — bytes >= 0x80 pass through untouched and only ASCII bytes
that are hostile to a filesystem are ever replaced.
--]]

local Paths = require("meguru/paths")

local Naming = {}

-- Kavita emits, next to the real entry of the volume last read, an alias entry
-- whose title is prefixed with this. Both carry the same stream, so the prefix
-- is dropped for naming and for series derivation and the two map to one book.
Naming.ALIAS_PREFIX = "Continue Reading from: "

-- Byte cap for a marker base name and for a series/server folder component.
-- On-device filesystems treat names as UTF-8 byte strings with a 255-byte
-- per-component limit. The marker adds "." .. extension plus at worst a "-"
-- and 8 hex digits, and the cover cache appends "-cover-<8hex>.img" to the same
-- base, so 220 keeps every derived component under 255.
Naming.MAX_COMPONENT_BYTES = 220

--- Drop a leading "Continue Reading from: " prefix, so an alias entry and the
--- real volume it duplicates name to the same marker file.
function Naming.stripAliasPrefix(title)
    title = title or ""
    local prefix = Naming.ALIAS_PREFIX
    if title:sub(1, #prefix) == prefix then
        return title:sub(#prefix + 1)
    end
    return title
end

--- Codepoint and byte length of the UTF-8 character at the head of `s`, or nil
--- for an empty string or a malformed sequence. Deliberately permissive about
--- which lead bytes it accepts — this only ever answers "is the first character
--- a glyph", it never validates a whole string.
local function utf8Head(s)
    local b1 = s:byte(1)
    if not b1 then
        return nil, nil
    end
    if b1 < 0x80 then
        return b1, 1
    elseif b1 >= 0xC0 and b1 < 0xE0 then
        local b2 = s:byte(2)
        if not b2 then return nil, nil end
        return (b1 - 0xC0) * 0x40 + (b2 - 0x80), 2
    elseif b1 >= 0xE0 and b1 < 0xF0 then
        local b2, b3 = s:byte(2), s:byte(3)
        if not (b2 and b3) then return nil, nil end
        return (b1 - 0xE0) * 0x1000 + (b2 - 0x80) * 0x40 + (b3 - 0x80), 3
    elseif b1 >= 0xF0 and b1 < 0xF8 then
        local b2, b3, b4 = s:byte(2), s:byte(3), s:byte(4)
        if not (b2 and b3 and b4) then return nil, nil end
        return (b1 - 0xF0) * 0x40000 + (b2 - 0x80) * 0x1000
            + (b3 - 0x80) * 0x40 + (b4 - 0x80), 4
    end
    return nil, nil
end

-- Servers bakes a reading-progress glyph into an entry's <title> (Kavita: a
-- filled/partial circle; Suwayomi: a down arrow, a check mark, an hourglass).
-- It is server bookkeeping, never part of the book's name.
--
-- Matched as *ranges* rather than an exhaustive list of the codepoints seen so
-- far: a server build that switches to a new status icon tomorrow is still
-- stripped without a code change.
local GLYPH_RANGES = {
    { 0x2190, 0x21FF },   -- Arrows
    { 0x2300, 0x23FF },   -- Misc Technical (hourglass, stopwatch)
    { 0x25A0, 0x25FF },   -- Geometric Shapes (filled/partial circles)
    { 0x2600, 0x27BF },   -- Misc Symbols + Dingbats (check marks, stars)
    { 0x2B00, 0x2BFF },   -- Misc Symbols and Arrows
    { 0x1F300, 0x1FAFF }, -- Emoji planes
}

local function isGlyphCodepoint(cp)
    if not cp then
        return false
    end
    for _, range in ipairs(GLYPH_RANGES) do
        if cp >= range[1] and cp <= range[2] then
            return true
        end
    end
    return false
end

--- Strip leading reading-progress glyphs and the whitespace after them.
---
--- A glyph with emoji presentation (U+2B07 + U+FE0F) is two codepoints: the
--- range check strips the base, then the variation selector is swallowed so no
--- invisible byte lingers at the head.
local function stripLeadingGlyph(title)
    local t = title
    while true do
        local cp, len = utf8Head(t)
        if not isGlyphCodepoint(cp) then
            break
        end
        t = t:sub(len + 1)
        while t:byte(1) == 0xEF and t:byte(2) == 0xB8
            and t:byte(3) and t:byte(3) >= 0x80 and t:byte(3) <= 0x8F do
            t = t:sub(4)
        end
    end
    return (t:gsub("^%s+", ""))
end

--- A title safe to show: alias prefix and leading glyph gone, nothing else.
--- This is what ReaderUI displays, so it is applied at display time and never
--- baked into a stored value.
function Naming.cleanTitle(title)
    return stripLeadingGlyph(Naming.stripAliasPrefix(title))
end

-- Some servers stamp every entry whose book has no recorded creator with a
-- placeholder. Echoing that into History or Book info shows a bogus author.
local AUTHOR_PLACEHOLDERS = { "unknown", "unknown author" }

--- A real author name, or nil when there is none worth showing.
function Naming.cleanAuthor(author)
    local s
    if type(author) == "string" then
        s = author
    elseif type(author) == "table" and type(author.name) == "string" then
        s = author.name
    else
        return nil
    end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    local lowered = s:lower()
    for _, placeholder in ipairs(AUTHOR_PLACEHOLDERS) do
        if lowered == placeholder then
            return nil
        end
    end
    return s
end

-- Suwayomi writes the manga title of a chapter entry as "Series: <Manga> |
-- Chapter N | ...", and some feeds label the name with its kind. The label is
-- bookkeeping, never part of the name.
--
-- Only a leading "<word>:" matches, so a title that merely contains the word
-- ("A Series of Unfortunate Events") is untouched.
local SERIES_NAME_LABELS = { "series", "manga" }

function Naming.stripSeriesLabel(s)
    if type(s) ~= "string" then
        return s
    end
    local t = s:gsub("^%s+", "")
    local head = t:lower()
    for _, label in ipairs(SERIES_NAME_LABELS) do
        local prefix = label .. ":"
        if head:sub(1, #prefix) == prefix then
            local rest = t:sub(#prefix + 1):gsub("^%s+", "")
            if rest ~= "" then
                return rest
            end
            return s
        end
    end
    return s
end

--- En/em dashes to ASCII "-", so " – Volume 3" peels like " - Volume 3".
local function normalizeDashes(s)
    return (s:gsub("\u{2013}", "-"):gsub("\u{2014}", "-"))
end

--- Make `name` a safe single filesystem component: path-hostile and control
--- bytes become spaces, runs collapse, and the result is capped to `cap_bytes`
--- on a UTF-8 boundary so it never ends in a dangling lead byte.
function Naming.sanitizeComponent(name, cap_bytes)
    cap_bytes = cap_bytes or Naming.MAX_COMPONENT_BYTES
    local out = {}
    for i = 1, #name do
        local b = name:byte(i)
        if b < 32 or b == 127 or b == 47 or b == 92 or b == 58
            or b == 42 or b == 63 or b == 34 or b == 60 or b == 62 or b == 124 then
            out[#out + 1] = " "
        else
            out[#out + 1] = name:sub(i, i)
        end
    end
    name = table.concat(out)
    -- Trailing dots and spaces are trimmed too: FAT filesystems do it behind
    -- our back, which would make the name we recorded disagree with the disk.
    name = name:gsub("%s+", " "):gsub("^%s+", ""):gsub("[%s.]+$", "")
    if name == "" or name == "." or name == ".." then
        return "stream"
    end
    -- Reserved device names on Windows. Fatal only there, but free to guard.
    if name:lower():match("^(con|prn|aux|nul|com[1-9]|lpt[1-9])$") then
        name = name .. "-stream"
    end
    -- Never double the extension if the title itself ends with it.
    if name:lower():sub(-(#Paths.MARKER_EXT + 1)) == "." .. Paths.MARKER_EXT then
        name = name:sub(1, #name - (#Paths.MARKER_EXT + 1))
    end
    if #name > cap_bytes then
        -- Walk back from the cut past continuation bytes to the sequence's lead
        -- byte and cut there.
        local cut = cap_bytes
        while cut > 0 do
            local b = name:byte(cut)
            if b < 0x80 or b >= 0xC0 then
                break
            end
            cut = cut - 1
        end
        name = name:sub(1, cut):gsub("[%s.]+$", "")
    end
    if name == "" then
        return "stream"
    end
    return name
end

--- The marker file's base name (no extension) for an entry title: alias prefix
--- and leading glyph gone, filesystem-hostile bytes replaced, nothing else.
--- The title is kept verbatim otherwise, so the file reads cleanly in the file
--- browser and does not change when the server advances its progress glyph.
function Naming.markerBaseName(title)
    title = stripLeadingGlyph(Naming.stripAliasPrefix(title))
    return Naming.sanitizeComponent(title, Naming.MAX_COMPONENT_BYTES)
end

-- Trailing volume/chapter tokens recognised when deriving a series name, in
-- the order tried. Each is a literal word; "Vol" is also accepted dotted.
local VOLUME_TOKENS = { "Volume", "Vol", "Chapter", "Ch", "Part", "v" }

--- Strip a trailing run of parenthesised/bracketed release tags, so the volume
--- token can be matched even when the server appends per-release bookkeeping
--- after it. Komga titles every volume "<Series> v<NN> (<group>) (<group>)".
local function stripTrailingReleaseGroups(t)
    while true do
        local prev = t
        t = t:gsub("%s*[%(%[][^%)%]]*[%)%]]%s*$", "")
        if t == prev or t == "" then
            return t
        end
    end
end

--- Derive a series name and volume label from a raw entry title.
---
--- Returns `series, volume_label, volume_index`, or nothing when no series can
--- be confidently derived — then the caller stays flat.
---   "◔ This Alluring ... - Volume 3" -> "This Alluring ...", "Volume 3", 3
---   "Series: Alya ... - Volume 2"    -> "Alya ...", "Volume 2", 2
---   "Series - Volume 1-2"            -> "Series", "Volume 1-2", 1 (omnibus)
---   "Series - Volume 7.5"            -> "Series", "Volume 7.5", 7.5
---   "'Tis Time ... Princess v01 (x)" -> "'Tis Time ... Princess", "v01", 1
---   "Series - Part One"              -> nil (no digits)
---   "⬇️ Chapter 17"                   -> nil (no series name; Suwayomi)
---
--- A hyphenated range ("Volume 1-2") is one omnibus stream spanning several
--- original volumes — how Kavita's storyline feed groups them — and indexes
--- from its *first* number, so the next combined volume still orders after it.
--- A decimal ("Volume 7.5") is kept whole, so it orders between its integer
--- neighbours.
function Naming.deriveSeries(raw_title)
    local t = Naming.stripAliasPrefix(raw_title)
    t = stripLeadingGlyph(t):gsub("^%s+", ""):gsub("%s+$", "")
    if t == "" then
        return nil
    end
    t = Naming.stripSeriesLabel(t)
    t = normalizeDashes(t)
    -- A volume token is only *trailing* once any release-tag groups are gone:
    -- Komga's token sits before its "(...)" groups, never at the very end.
    t = stripTrailingReleaseGroups(t)

    for _, token in ipairs(VOLUME_TOKENS) do
        -- The prefix is minimal so the *trailing* token is the one peeled off;
        -- greedy would eat a second, earlier "Volume N". After the number an
        -- optional fractional part and an optional hyphenated range are
        -- tolerated, both indexing from the leading integer.
        local pattern = "^(.-)%s*[%-:]*%s*" .. token .. "%.?%s*(%d+%.?%d*)%s*%-?%s*%d*%s*$"
        local prefix, num = t:match(pattern)
        if prefix and prefix ~= "" then
            local label = t:sub(#prefix + 1):gsub("^[%s%-:]+", ""):gsub("%s+$", "")
            local series = prefix:gsub("%s+$", ""):gsub("[%-:%s]+$", "")
            if series ~= "" then
                if label == "" then
                    label = token .. " " .. num
                end
                return series, label, tonumber(num)
            end
        end
    end
    return nil
end

--- A sort key for a series name: case-folded, punctuation and whitespace runs
--- collapsed to single spaces.
---
--- `string.lower` only touches ASCII, so multibyte characters pass through
--- untouched — continuation bytes are 0x80..0xBF and cannot be mistaken for
--- 'A'..'Z'. That is the behaviour wanted here: a name is folded enough to sort
--- predictably without being mangled.
function Naming.sortKey(name)
    if type(name) ~= "string" then
        return nil
    end
    local s = name:lower():gsub("[%p%s]+", " ")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Dependable 32-bit hash (djb2), for cache keys and for disambiguating names
--- that would otherwise collide. Not a security primitive — it only has to be
--- stable across restarts and spread similar inputs apart.
function Naming.hash32(str)
    local h = 5381
    for i = 1, #str do
        h = (h * 33 + str:byte(i)) % 4294967296
    end
    return h
end

--- A filesystem component for a *natural key*, e.g. "<server>|<series>|<item>".
---
--- Deliberately derived from identity rather than from a stream URL: Kavita's
--- template embeds the API key and Suwayomi's chapter number can be renumbered,
--- so a URL-derived suffix would silently rename the file — and orphan its
--- reading progress — after a key rotation.
function Naming.keySuffix(natural_key)
    return string.format("%08x", Naming.hash32(natural_key or ""))
end

--- `name` with a natural-key suffix appended, for when the plain component is
--- already taken by a different book.
function Naming.disambiguated(name, natural_key)
    return name .. "-" .. Naming.keySuffix(natural_key)
end

return Naming
