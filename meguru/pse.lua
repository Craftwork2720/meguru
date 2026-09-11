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

local PSE = {}

PSE.STREAM_REL = "http://vaemendis.net/opds-pse/stream"

--- Page count and server-reported last-read page off a stream link.
---
--- The parser flattens namespaced attributes onto the link keyed by their
--- local name, and the prefix varies by server (`pse:count`, or none at all),
--- so the attribute is matched by key *suffix* rather than by exact name.
---
--- **A `lastRead` of 0 is returned as 0, not as nil**, and the difference is
--- load-bearing. Kavita marks a chapter unread by writing `lastRead="0"` rather
--- than by dropping the attribute, so collapsing the two loses the only signal
--- that says "this is no longer read". `Catalog.upsertItem` writes progress with
--- `COALESCE(excluded.last_read, items.last_read)`, so a nil leaves whatever was
--- stored there — which meant a volume marked unread on the server stayed the
--- furthest-read one here forever, and the resume dialog kept offering to
--- continue from it. Absent still means nil: that is a feed not publishing
--- progress at all, which must not overwrite what a better feed recorded.
---
--- Returning 0 is safe everywhere by construction: every consumer asks
--- `> 0` or `> 1` before treating the number as a page.
---
--- **The number is *not* normalised here, and must not be.** Suwayomi counts
--- pages from zero and Kavita from one, so the same state is `50`-of-51 on one
--- and `174`-of-174 on the other — a difference only a driver can resolve, and
--- `driver/suwayomi.lua` does it where its own progress enters. Normalising in a
--- parser shared by both would move Kavita's pages by one.
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
    return count, last_read
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
--- **`template` must be a live one, not a marker's raw field.** A marker stores
--- its template with any credential-bearing path segment replaced by
--- `<redacted>` (see `meguru/credential`), and `Marker.load` puts it back. Hand
--- this a template straight off disk and the URL it builds is self-describing
--- and wrong — `…/api/opds/<redacted>/image?…` — which the server answers with a
--- 404 and nothing in this function can notice.
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

-- `PSE.pageCachePath` used to live here: where the raw bytes of one page were
-- written on disk. Pages are never on disk now — the engine keeps a few in RAM —
-- so there is no name to build and nothing in this module files anything.

return PSE
