--[[--
Kavita's OPDS surface.

A series-feed entry is one *chapter row in Kavita's own model* — a collected
volume or a loose chapter, either way with its own stream — so entry ↔ stream is
1:1 and this driver stores the template directly. Only Suwayomi needs the lazy
extra fetch.

Three numbers ride on every entry and only one of them is an identity (see
PROTOCOL.md): `entry.id` is opaque, `volumeId` is shared by several entries in
132 of 2776 series, and `chapterId` is unique per chapter. Everything here keys
on `chapterId`.
--]]

local Base = require("meguru/driver/base")
local Naming = require("meguru/naming")
local PSE = require("meguru/pse")

local Kavita = {}

--- Matched against the lowercased feed-level `<author>` name and uri. Kavita
--- signs every feed it serves with its own name.
Kavita.authorSignatures = { "kavita" }

--- The stream template a Kavita marker carries. `chapterId` is the query
--- parameter that is also this driver's `item_key` (see PROTOCOL.md), so a
--- template carrying it is one only Kavita emits.
Kavita.streamSignatures = { { "chapterId=" } }

local STORYLINE_SUFFIX = " - Storyline"

--- One parameter out of a URL's query string, or nil.
---
--- `parsed.query` excludes the leading "?", so a sentinel "&" is prepended to
--- give the first parameter the same shape as the rest; matching the name
--- between "&" and "=" is what keeps `chapterId` from being found inside
--- `subChapterId`.
local function queryParam(url_str, name)
    local url = require("socket.url")
    local parsed = url.parse(url_str)
    local query = parsed and parsed.query
    if type(query) ~= "string" or query == "" then
        return nil
    end
    local value = ("&" .. query):match("&" .. name .. "=([^&]*)")
    if value == nil or value == "" then
        return nil
    end
    return value
end

--- The raw stream href on an entry, deliberately not made absolute: the query
--- is identical either way, and resolving it would need a base URL this
--- function may not have been given.
local function streamHref(entry)
    local link = Base.link(entry, PSE.STREAM_REL)
    return link and link.href
end

--- Identify the series a browsed entry belongs to.
---
--- The stream URL carries `seriesId` alongside `chapterId`, so an entry resolves
--- to its series with no browsing context at all — including a book opened from
--- `on-deck` or `recently-added`, which list series rather than chapters.
function Kavita.discover(entry, stream, _ctx)
    local href = stream or streamHref(entry)
    if type(href) ~= "string" or href == "" then
        return nil
    end
    local remote_id = queryParam(href, "seriesId")
    if not remote_id then
        return nil
    end
    return {
        series_remote_id = remote_id,
        discovered_from = "stream",
    }
end

--- The canonical series feed. 0/46 series paginate, so this is normally the
--- whole series in one response — the `rel=next` walker in sync.lua handles it
--- either way.
function Kavita.catalogURL(base_url, series_remote_id, _ctx)
    return string.format("%s/series/%s", base_url, series_remote_id)
end

--- One page of the canonical feed to normalized items.
---
--- Entries without a usable stream are skipped rather than keyed on something
--- weaker: a template with no `{pageNumber}` opens nothing, and inventing a key
--- for it would put a chapter in the reading order that cannot be read.
function Kavita.parseCatalogPage(feed, base_url, _ctx)
    local items = {}
    for _, entry in ipairs(feed and feed.entry or {}) do
        local template, count, last_read = PSE.streamFromEntry(entry, base_url)
        local item_key = template and queryParam(template, "chapterId")
        if item_key then
            items[#items + 1] = Base.item({
                item_key        = item_key,
                item_key_source = "chapterId",
                title           = entry.title,
                template        = template,
                page_count      = count,
                last_read       = last_read,
                -- Every entry of a Kavita series feed carries its own `image`
                -- and `image/thumbnail`, so a volume's cover costs the sync
                -- nothing. Without it all of them fall back to page 1 of their
                -- own stream — the same page for the whole series, in a larger
                -- and slower form.
                cover_url       = Base.coverFromEntry(entry, base_url),
            })
        end
    end
    return items
end

--- The series name from the series feed's own `<title>`, which Kavita writes as
--- "<Series> - Storyline".
---
--- An aggregate has no series feed, so the entry title is the fallback there —
--- and it is the *only* case that needs it, which is why the feed title is
--- tried first rather than deriving a name the feed already states.
function Kavita.seriesName(feed, entry, _ctx)
    local from_feed = Naming.stripSeriesLabel(
        Base.stripSuffix(feed and feed.title, STORYLINE_SUFFIX))
    if from_feed and from_feed ~= "" then
        return from_feed
    end
    local derived = Naming.deriveSeries(entry and entry.title or "")
    if derived and derived ~= "" then
        return derived
    end
    return nil
end

-- `resolveStream` is left to the default in base.lua: the stream arrives with
-- the entry, so there is nothing to fetch on open.

Base.register("kavita", Kavita)

return Kavita
