--[[--
HTTP: one synchronous GET, and getting a parsed OPDS feed out of it.

LuaSocket is synchronous and KOReader has no threads, so every call here blocks
until it returns. Nothing in this module may be reached from a paint path, and
callers that fetch in a loop owe the user a progress widget and a Cancel
(see `meguru/sync.lua`).
--]]

local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")

local Net = {}

-- Feed fetches get tighter limits than socketutil.FILE_* (15s block / 60s
-- total), which is sized for pulling one page image. A sync walks tens of feed
-- pages back to back, and at FILE_* limits a single dead request would stall
-- the walk for a minute apiece. A feed page that has delivered nothing in 10s,
-- or has not finished in 30s, is not coming.
Net.FEED_BLOCK_TIMEOUT = 10
Net.FEED_TOTAL_TIMEOUT = 30

Net.FEED_ACCEPT = "application/atom+xml;profile=opds-catalog, application/xml;q=0.9, */*;q=0.5"
Net.IMAGE_ACCEPT = "image/*;q=1, */*;q=0.5"

--- A URL safe to log: scheme, host, port, path and only the *size* of the
--- query. Kavita puts its API key in the path, which is why the query is not
--- the only thing guarded — callers redact the path too when they log a stream
--- URL (see `Net.redactStreamUrl`).
function Net.redactUrl(str)
    local parsed = url.parse(str)
    if not parsed or not parsed.host then
        return "(invalid url)"
    end
    local shown = (parsed.scheme or "http") .. "://" .. parsed.host
    if parsed.port then
        shown = shown .. ":" .. parsed.port
    end
    shown = shown .. (parsed.path or "")
    if parsed.query and #parsed.query > 0 then
        shown = shown .. "?" .. #parsed.query .. " bytes of query"
    end
    return shown
end

--- A stream template with the credential-bearing path segment removed. Kavita
--- encodes its API key as a path segment (`/opds/<apiKey>/image/...`), so
--- logging the path of a stream URL leaks the key into crash.log.
function Net.redactStreamUrl(str)
    if type(str) ~= "string" then
        return "(none)"
    end
    local stripped = str:gsub("/opds/[^/]+/", "/opds/<redacted>/")
    return Net.redactUrl(stripped)
end

-- A resume lookup happens while the reader waits for a dialog to appear, not
-- while a walk is in progress, so it gets the tightest limits here: a server
-- that has not answered in 4s is not going to improve anyone's afternoon, and
-- the caller has a stale-but-usable answer to fall back on.
Net.RESUME_BLOCK_TIMEOUT = 4
Net.RESUME_TOTAL_TIMEOUT = 8

local TIMEOUTS = {
    feed = { Net.FEED_BLOCK_TIMEOUT, Net.FEED_TOTAL_TIMEOUT },
    page = { socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT },
    large = { socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT },
    resume = { Net.RESUME_BLOCK_TIMEOUT, Net.RESUME_TOTAL_TIMEOUT },
}

--- Synchronous GET. Returns `code, headers, body`.
---
--- On a transport failure, an unsupported scheme or a timeout, returns
--- `nil, nil, nil` after logging the reason — including LuaSocket's own error
--- string, so a device log explains itself.
---
--- On any non-200 response returns `code, headers, nil`, so a caller walking a
--- paginated feed can tell "the server said 404" from "the network died". Both
--- must stop the walk; only the second is worth retrying later.
---
--- `opts`: { username, password, accept, timeout = "feed"|"page"|"large" }.
function Net.get(url_str, opts)
    opts = opts or {}
    local parsed = url.parse(url_str)
    if not parsed or (parsed.scheme ~= "http" and parsed.scheme ~= "https") then
        logger.warn("Meguru: unsupported protocol for", Net.redactUrl(url_str))
        return nil
    end

    local sink = {}
    local req = {
        url = url_str,
        headers = {
            ["Accept"] = opts.accept or "*/*",
            -- Ask for the body uncompressed: the sink is a plain byte table and
            -- nothing here inflates anything.
            ["Accept-Encoding"] = "identity",
        },
        sink = ltn12.sink.table(sink),
    }
    if opts.username and opts.username ~= "" then
        req.user = opts.username
        -- LuaSocket builds the Basic-auth header as user..":"..password, so a
        -- nil password raises inside http.request. The built-in OPDS plugin
        -- defaults to "" for password-less catalogs; do the same.
        req.password = opts.password or ""
    end

    local timeout = TIMEOUTS[opts.timeout or "page"] or TIMEOUTS.page
    socketutil:set_timeout(timeout[1], timeout[2])
    local ok, code, headers = pcall(function()
        -- Same call shape as the built-in OPDS plugin: socket.skip(1, ...)
        -- drops the leading connection status, leaving (http_status,
        -- response_headers) on success and (err_message, nil) on failure.
        return socket.skip(1, http.request(req))
    end)
    socketutil:reset_timeout()

    if not ok then
        logger.warn("Meguru: HTTP error for", Net.redactUrl(url_str), ":", tostring(code))
        return nil
    end
    if type(code) ~= "number" then
        logger.warn("Meguru: HTTP request failed for", Net.redactUrl(url_str),
            "(", tostring(code), ")")
        return nil
    end
    if code ~= 200 then
        logger.warn("Meguru: HTTP", code, "for", Net.redactUrl(url_str))
        return code, headers, nil
    end
    return 200, headers, table.concat(sink)
end

--- The document inside a raw `opdsparser` result.
---
--- The parser builds a table named after the document's *root element*, so an
--- Atom feed comes back as `{ feed = { entry = {...}, author = {...} } }` and
--- nothing is at the top level. Callers that read `.entry`, `.title` or
--- `.author` off the raw result therefore find nil everywhere and see a feed
--- with no entries — which is a silent failure, since an "empty" feed and a
--- feed that was never unwrapped look identical.
---
--- `genItemTableFromCatalog` in the built-in browser compensates the same way
--- (`local feed = catalog.feed or catalog`), which is the authority for this
--- shape. `open.lua` reads the browser's parse result directly and so needs it
--- too; `parseFeed` below reads a fetched body. One definition, because two
--- modules must not disagree about what a feed looks like.
---
--- A document whose root element is not `<feed>` — an OpenSearch descriptor — is
--- returned unchanged, which is what lets a caller tell the two apart.
function Net.feedFrom(root)
    if type(root) ~= "table" then
        return nil
    end
    if type(root.feed) == "table" then
        return root.feed
    end
    return root
end

--- Parse an Atom feed body into the flat table shape the built-in OPDS parser
--- produces: `feed.entry` is an array, `entry.link` is an array of
--- `{ rel, href, type, ... }`, and OPDS-PSE attributes sit on the link keyed by
--- a namespaced name (`pse:count`).
---
--- `opdsparser` is required *at call time*, never at load time: a plugin's
--- directory is only appended to `package.path` once all plugins have loaded,
--- so a load-time require of another plugin's module fails on devices where
--- this module is reached earlier (pluginloader.lua:241).
function Net.parseFeed(body)
    if type(body) ~= "string" or body == "" or body:match("^%s*{") then
        return nil
    end
    local ok, OPDSParser = pcall(require, "opdsparser")
    if not ok or type(OPDSParser) ~= "table" or type(OPDSParser.parse) ~= "function" then
        logger.warn("Meguru: built-in OPDS feed parser unavailable")
        return nil
    end
    local ok_parse, root = pcall(OPDSParser.parse, OPDSParser, body)
    if not ok_parse or type(root) ~= "table" then
        return nil
    end
    local feed = Net.feedFrom(root)
    if type(feed.entry) ~= "table" then
        return nil -- parsed, but not a list of entries
    end
    return feed
end

--- Fetch and parse one feed. Returns `feed` or `nil, reason`, where reason is
--- "network" or "http" — the caller needs that distinction to decide whether a
--- failed walk is worth retrying (see the `complete` flag in sync).
function Net.fetchFeed(url_str, opts)
    if type(url_str) ~= "string" or url_str == "" then
        return nil, "network"
    end
    opts = opts or {}
    local code, _, body = Net.get(url_str, {
        username = opts.username,
        password = opts.password,
        accept = opts.accept or Net.FEED_ACCEPT,
        timeout = opts.timeout or "feed",
    })
    if code ~= 200 or not body then
        return nil, (code and "http") or "network"
    end
    local feed = Net.parseFeed(body)
    if not feed then
        return nil, "http" -- 200 with an unparseable body: a truncated response
    end
    return feed
end

return Net
