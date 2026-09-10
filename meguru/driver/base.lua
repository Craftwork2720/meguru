--[[--
The driver contract, plus the parts every driver would otherwise duplicate.

A driver is a set of **pure functions over already-parsed feeds**. HTTP,
pagination, credentials and transactions belong to the engine — otherwise there
are three copies of the `rel=next` loop and three copies of the loop guard, and
HTTP ends up inside a driver where it cannot be read as a whole.

The one piece of real I/O a driver needs is Suwayomi's lazy per-chapter
metadata fetch, and that arrives as an injected `fetch` callback rather than as
a socket the driver opens itself.

`base_url` is always the **real** catalog root, credentials and API key
included, obtained from `sources.lua` at call time and never stored. The
`servers.root_url` column holds only the redacted form used for diagnostics —
it cannot be fetched from, which is the point.
--]]

local Naming = require("meguru/naming")
local PSE = require("meguru/pse")

local Base = {}

local registry = {}

--- Every driver, so `loadDrivers` can bring the registry up. The list lives
--- here with the registry it fills; adding a server is a new file plus a line.
local DRIVER_MODULES = {
    "meguru/driver/kavita",
    "meguru/driver/suwayomi",
}

--- Require every driver, which is what registers them.
---
--- Must be called before anything consults the registry, and is deliberately
--- not done at load time: a driver may in principle require this module, and a
--- load-time cycle would hand it a half-built table.
function Base.loadDrivers()
    for _, module in ipairs(DRIVER_MODULES) do
        require(module)
    end
end

--- Register a driver under the `servers.kind` it handles.
function Base.register(kind, driver)
    driver.kind = kind
    -- Filled in here rather than left to each driver, so an engine that calls
    -- `resolveStream` unconditionally cannot trip over a driver that had no
    -- reason to override it.
    driver.resolveStream = driver.resolveStream or Base.resolveStream
    registry[kind] = driver
end

--- The driver for a server kind, or nil when the kind is unknown or was never
--- sniffed. Callers must treat nil as "cannot sync this server" rather than
--- guessing — a wrong driver against a real feed silently mis-keys a library.
function Base.forKind(kind)
    return kind and registry[kind] or nil
end

function Base.kinds()
    local kinds = {}
    for kind in pairs(registry) do
        kinds[#kinds + 1] = kind
    end
    table.sort(kinds)
    return kinds
end

--- The server kind a feed's own `<author>` names, or nil.
---
--- Every feed the supported servers emit names its software there, which is the
--- only thing a catalog says about what is behind it. Each driver declares its
--- own signatures, so adding a server adds its own name rather than editing a
--- list somewhere else.
---
--- A hint, never a gate — `kindFor` below is what keeps an unrecognised author
--- from being the end of the story, and the user can always set the kind by
--- hand.
function Base.kindFromAuthor(author)
    local name, uri = "", ""
    if type(author) == "string" then
        name = author
    elseif type(author) == "table" then
        name = type(author.name) == "string" and author.name or ""
        uri = type(author.uri) == "string" and author.uri or ""
    else
        return nil
    end
    local blob = (name .. " " .. uri):lower()
    -- Over `kinds()`, which is sorted: two drivers whose needles overlapped
    -- would otherwise resolve by `pairs` order, which is not stable.
    for _, kind in ipairs(Base.kinds()) do
        for _, needle in ipairs(registry[kind].authorSignatures or {}) do
            if blob:find(needle, 1, true) then
                return kind
            end
        end
    end
    return nil
end

--- The driver that recognises this entry as its own, or nil.
---
--- The last resort for a server that signs its feeds with an `<author>` no
--- driver knows, which is not the soft failure it looks like: the driver is what
--- knows a series' canonical feed, so a server with no kind produces books that
--- can never be catalogued — no next or previous chapter, ever, with nothing in
--- the marker to say why. The old plugin could shrug at an unknown author
--- because it only *stored* `server_kind`; here it decides whether the book has
--- an identity at all.
---
--- Each driver's `discover` is already the function that answers "is this mine?",
--- from the entry and its stream rather than from a name, so this asks the
--- drivers directly instead of keeping a second set of signatures in step with
--- the first.
---
--- Only an *unambiguous* answer counts. If two drivers claim the entry the server
--- stays unknown, because a wrong kind is worse than none: it picks the wrong
--- driver, and every later sync re-keys the series against feeds that do not
--- describe it. The menu's manual override is the way out of both.
function Base.kindFor(entry, stream, ctx)
    local claimed
    for _, kind in ipairs(Base.kinds()) do
        local ok, found = pcall(registry[kind].discover, entry, stream, ctx)
        if ok and type(found) == "table" and found.series_remote_id then
            if claimed then
                return nil
            end
            claimed = kind
        end
    end
    return claimed
end

--- Strip a trailing suffix from a feed title, or return it unchanged.
function Base.stripSuffix(text, suffix)
    if type(text) ~= "string" then
        return nil
    end
    if text:sub(-#suffix) == suffix then
        return text:sub(1, #text - #suffix)
    end
    return text
end

--- The first link on an entry with one of the given rels, or nil.
function Base.link(entry, ...)
    for _, link in ipairs(entry and entry.link or {}) do
        if type(link) == "table" then
            for i = 1, select("#", ...) do
                if link.rel == select(i, ...) then
                    return link
                end
            end
        end
    end
    return nil
end

--- Absolute URL of a link href. Tolerates an already-absolute href.
function Base.absolute(base_url, href)
    local url = require("socket.url")
    if type(href) ~= "string" or href == "" then
        return nil
    end
    return url.absolute(base_url, href)
end

local OPDS_IMAGE_REL = "http://opds-spec.org/image"
local OPDS_THUMBNAIL_REL = "http://opds-spec.org/image/thumbnail"

--- Artwork that can stand in as a series cover, as an absolute URL.
---
--- The feed is asked first: a series feed's own image is the *series*' artwork.
--- Only when it has none does the entry's image serve, which is the only thing
--- a chapter-level feed can offer — the chapter's own cover, usually the same
--- artwork, and better than leaving the book with no cover at all. Callers
--- store the result with COALESCE so a later, better value always wins.
function Base.coverFromFeed(feed, entry, base_url)
    local link = Base.link(feed, OPDS_IMAGE_REL, OPDS_THUMBNAIL_REL)
        or Base.link(entry, OPDS_IMAGE_REL, OPDS_THUMBNAIL_REL)
    if not link then
        return nil
    end
    return Base.absolute(base_url, link.href)
end

--- The page stream an entry advertises directly, if it carries one.
--- Not every server does: Suwayomi's chapter entries only link to a metadata
--- feed, which is what `resolveStream` exists to handle.
function Base.directStream(entry, base_url)
    return PSE.streamFromEntry(entry, base_url)
end

--- The item shape every driver returns, with the display fields derived here so
--- two drivers cannot disagree about how a title becomes a label.
---
--- `ordinal` is deliberately left nil by both v1 drivers, whose canonical feeds
--- are already in reading order: `feed_index` then orders them, and a provider
--- renumbering a chapter is followed automatically instead of being fought by a
--- stored number. The ordinal machinery is kept because a driver that *does*
--- have a dependable ordinal (Komga's `bookId` ordering, a generic server) will
--- need it.
function Base.item(fields)
    local title = fields.title or ""
    local display = Naming.cleanTitle(title)
    local _, label = Naming.deriveSeries(title)
    return {
        item_key        = fields.item_key,
        item_key_source = fields.item_key_source,
        feed_index      = fields.feed_index,
        ordinal         = fields.ordinal,
        ordinal_source  = fields.ordinal_source or "feed",
        title           = title,
        display_title   = display ~= "" and display or title,
        volume_label    = fields.volume_label or label,
        template        = fields.template,
        detail_url      = fields.detail_url,
        page_count      = fields.page_count,
        last_read       = fields.last_read,
    }
end

--- Default `resolveStream`: the stream came with the entry, so there is nothing
--- to fetch. Returns `template, count`.
---
--- A driver that stores a NULL template overrides this. So does one whose
--- stored template can go stale — which is why the engine re-resolves on every
--- open when the catalog is reachable, rather than treating this as a one-off.
function Base.resolveStream(item, _fetch, _ctx)
    return item.template, item.page_count
end

-- Every driver must implement these; they are declared only so the contract is
-- legible in one place, and so a missing one fails where it is called rather
-- than three frames deeper.
--
--   authorSignatures                      -> { "kavita" } — lowercased
--                                            needles matched against the
--                                            feed-level <author>
--   discover(entry, stream, ctx)          -> { series_remote_id, discovered_from }
--     discovered_from: "stream"    the entry itself carried the series identity,
--                                  so the engine may sync without asking
--                      "series"    a series-list entry
--                      "aggregate" a chapter-level aggregate, where the series
--                                  may not be recoverable at all
--     Also the evidence `kindFor` uses to name a server whose <author> matched
--     nothing, so it must answer strictly: a driver returning a series id for
--     another server's entry makes that server unattributable rather than
--     misattributed, which is the safer of the two.
--   catalogURL(base_url, remote_id, ctx)  -> string
--   parseCatalogPage(feed, base_url, ctx) -> { item, ... }
--   seriesName(feed, entry, ctx)          -> string

return Base
