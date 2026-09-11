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

--- How far ahead a recorded page may be before it stops being the same place.
---
--- Servers that track progress count pages *fetched*, and this reader fetches one
--- page beyond the one on screen so the next turn is instant
--- (`MeguruDocument.prefetch_count`) — so a book read here ends up recorded a page
--- ahead of where its reader stopped. That lead is the artefact this tolerates.
---
--- **It is not subtracted from the page.** Doing that was the first version, and
--- it was wrong in the case that matters most: a position recorded by *another*
--- reader has no such lead, so trimming it walks the reader back three pages they
--- had already read — the one direction that skips nothing and annoys everybody.
--- A lead this small means the two positions agree, which is a reason to say
--- nothing rather than to say a different number.
---
--- The slack covers the artefact plus a little judgement: page numbering also
--- drifts by one wherever a server counts from zero, and a two-page lead is still
--- not worth a question.
local SERVER_PAGE_TOLERANCE = 3

--- Whether a recorded page and a local one describe the same place.
---
--- True when the recording is not meaningfully ahead — including when it is
--- behind, where there is equally nothing to offer.
---
--- A missing local page is never "the same place": with nothing to compare
--- against, the recording is the only position there is.
function PSE.samePlace(recorded, local_page)
    recorded, local_page = tonumber(recorded), tonumber(local_page)
    if not recorded or not local_page then
        return false
    end
    return recorded - local_page <= SERVER_PAGE_TOLERANCE
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
