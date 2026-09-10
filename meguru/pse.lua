--[[--
OPDS-PSE: finding a page stream in a feed entry, and turning its template into
page URLs.

The convention (as implemented by Kavita, Suwayomi, Komga and the rest) is a
link with the `stream` relation whose href contains `{pageNumber}`, plus
substitutable `{width}`/`{maxWidth}` and `{height}`/`{maxHeight}`. **The page
number is zero based** — the first page of a stream is `{pageNumber}=0` while
ReaderUI numbers document pages from 1 — so every caller passes a zero-based
index. `PSE.pageURL` is the only place that rule lives.
--]]

local url = require("socket.url")

local Net = require("meguru/net")
local Paths = require("meguru/paths")

local PSE = {}

PSE.STREAM_REL = "http://vaemendis.net/opds-pse/stream"

--- Page count and server-reported last-read page off a stream link.
---
--- The parser flattens namespaced attributes onto the link keyed by their
--- local name, and the prefix varies by server (`pse:count`, or none at all),
--- so the attribute is matched by key *suffix* rather than by exact name.
function PSE.attributesFromLink(link)
    local count, last_read
    for key, value in pairs(link) do
        if type(key) == "string" then
            if key:sub(-6) == ":count" then
                count = tonumber(value)
            elseif key:sub(-9) == ":lastRead" then
                last_read = tonumber(value)
            end
        end
    end
    return count, (last_read and last_read > 0) and last_read or nil
end

--- The page stream advertised by a feed entry: an absolute template, the page
--- count, and the server-reported last-read page. Returns nothing when the
--- entry carries no usable stream.
---
--- A template without `{pageNumber}` is rejected rather than accepted as a
--- degenerate one-page stream: every page would then fetch the same URL.
function PSE.streamFromEntry(entry, base_url)
    for _, link in ipairs(entry and entry.link or {}) do
        if type(link) == "table" and type(link.href) == "string"
            and link.rel == PSE.STREAM_REL then
            local template = url.absolute(base_url, link.href)
            if template:find("{pageNumber}", 1, true) then
                local count, last_read = PSE.attributesFromLink(link)
                if count then
                    return template, count, last_read
                end
            end
        end
    end
    return nil
end

--- The URL of one page. `zero_based_index` is 0 for the first page.
---
--- `screen_h` is optional: the height substitutions are only applied when a
--- height is given, so a caller that knows only its width leaves any
--- `{height}` in the template untouched rather than substituting nonsense.
function PSE.pageURL(template, zero_based_index, screen_w, screen_h)
    local ret = template:gsub("{pageNumber}", tostring(zero_based_index))
    ret = ret:gsub("{width}", tostring(screen_w))
    ret = ret:gsub("{maxWidth}", tostring(screen_w))
    if screen_h then
        ret = ret:gsub("{height}", tostring(screen_h))
        ret = ret:gsub("{maxHeight}", tostring(screen_h))
    end
    return ret
end

--- Raw bytes of one page image, or nil plus the HTTP code.
function PSE.fetchPage(url_str, opts)
    opts = opts or {}
    local code, _, body = Net.get(url_str, {
        username = opts.username,
        password = opts.password,
        accept = opts.accept or Net.IMAGE_ACCEPT,
        timeout = opts.timeout or "page",
    })
    if code ~= 200 or not body then
        return nil, code
    end
    return body, code
end

--- Where the raw bytes of one page are cached.
---
--- Pure: a name, not a directory. Creating it is `doc/cache.lua`'s job, since
--- that is also the module that writes the file and can tell whether it is
--- writing a page or a cover.
function PSE.pageCachePath(slug, pageno)
    return Paths.pageCacheDir() .. "/" .. slug .. "-p" .. pageno
end

return PSE
