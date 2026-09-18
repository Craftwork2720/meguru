--[[--
HTTP: two synchronous GETs, one synchronous PATCH, and getting a parsed OPDS feed
out of one of them.

`get` returns the body as a string and `getToFile` writes it to a path. The
second is not a convenience: it is the only one of the two that can be bounded
in wall-clock, because `socketutil` enforces its total timeout through its own
sinks and `get` uses a plain `ltn12.sink.table`. See `Net.getToFile`.

`patch` is the opposite direction and the only write in this plugin: a driver
describes one request and `meguru/progress` makes it. It is a function of its own
rather than a `method` option on `get`, for two reasons — its success test
genuinely differs (see `Net.patch`), and a method parameter on a function whose
contract is "200 or nothing" would hide the one caller that must not be read that
way. **The verb belongs to the engine and is not a field a caller passes**, which
is what keeps a driver from choosing one.

A second verb should arrive as a second function, named for it, when something
actually needs it. There is one write here.

LuaSocket is synchronous and KOReader has no threads, so every call here blocks
until it returns. Nothing in this module may be reached from a paint path, and
callers that fetch in a loop owe the user a bound on how long it can take —
`Feed` caps a walk by pages and by `Net` timeout for exactly that reason, and
the update download has its own tier for the same one.
--]]

local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")

local Credential = require("meguru/credential")

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

--- A URL safe to log: scheme, host, port, a path with any credential-bearing
--- segment removed, and only the *size* of the query.
---
--- **Every log line that prints a URL prints it through here**, which is why the
--- credential rule lives inside this function rather than beside it. Kavita
--- encodes its API key as a path segment (`/opds/<apiKey>/…`), so a path that is
--- shown verbatim leaks the key into `crash.log` — a file routinely pasted into
--- bug reports. There used to be a separate `Net.redactStreamUrl` for that,
--- defined and called from nowhere while all four call sites here printed the
--- key; one function every caller already reaches for is the only shape of this
--- that survives the fifth log line.
---
--- Two things this output is *already* safe about, said here so nobody "fixes"
--- them:
---
---   * the query is reduced to its byte count, never its contents — that is what
---     covers a server that carries its credential as a token parameter;
---   * `user:pass@host` never appears, because `url.parse` splits those into
---     `parsed.user`/`parsed.password` and `shown` is built from `scheme`, `host`
---     and `port` only.
---
--- What remains is deliberately diagnostic: `…/api/opds/<redacted>/image?97
--- bytes of query` still says which endpoint was asked for, which is the whole
--- reason the URL was logged.
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
    return Credential.redact(shown)
end

-- A resume lookup happens while the reader waits for a dialog to appear, not
-- while a walk is in progress, so it gets the tightest limits here: a server
-- that has not answered in 4s is not going to improve anyone's afternoon, and
-- the caller has a stale-but-usable answer to fall back on.
Net.RESUME_BLOCK_TIMEOUT = 4
Net.RESUME_TOTAL_TIMEOUT = 8

-- The tightest tier here, and for the opposite reason to `resume`'s: a position
-- report is fired *by a page turn*, so it has to lose to the reader's thumb. A
-- server that has not answered in 2s has lost that race, and another report is
-- coming at the next page anyway, so there is nothing worth waiting for.
Net.PROGRESS_BLOCK_TIMEOUT = 2
Net.PROGRESS_TOTAL_TIMEOUT = 4

local TIMEOUTS = {
    feed = { Net.FEED_BLOCK_TIMEOUT, Net.FEED_TOTAL_TIMEOUT },
    page = { socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT },
    large = { socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT },
    resume = { Net.RESUME_BLOCK_TIMEOUT, Net.RESUME_TOTAL_TIMEOUT },
    -- Sized for one archive rather than one page, and the only tier whose total
    -- is enforced -- see `Net.getToFile` for why that is not a property of the
    -- numbers but of the sink.
    download = { socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT },
    -- The block timeout is what actually bounds this one, for the same reason
    -- `download`'s total is the only total that means anything: `patch` ends in a
    -- `ltn12.sink.table` too, and `socketutil` honours its total only through
    -- its own sinks. The number is here for symmetry with every other tier.
    progress = { Net.PROGRESS_BLOCK_TIMEOUT, Net.PROGRESS_TOTAL_TIMEOUT },
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
--- `opts`: { username, password, accept,
---           timeout = "feed"|"page"|"large"|"resume" }.
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

--- Synchronous PATCH. Returns `code, headers, body`.
---
--- **The verb is PATCH because the one endpoint this plugin writes to says so,
--- and that was measured rather than assumed.** `PUT` on
--- `/api/v1/books/{id}/read-progress` is answered **405 Method Not Allowed** by
--- Komga 1.27.0, whose own OpenAPI lists exactly `PATCH` and `DELETE` there. The
--- first version of this was a PUT, derived from the API's shape rather than from
--- a request to a server, and a 405 on a device is what that costs.
---
--- **Success is 200 *or* 204, and this is the one place the contract deliberately
--- departs from `get`'s.** A server that accepts a write and has nothing to say
--- about it answers exactly 204 with an empty body; a client that only knew 200
--- would read a completed write as a failure — and the one caller here reports
--- what it reads as a failure and tries again. So an empty body means success in
--- this function, where in `SeriesCover.save` it is the signature of a broken
--- fetch, and the two must not be reasoned about together.
---
--- On a transport failure, an unsupported scheme or a timeout, returns
--- `nil, nil, nil` after logging the reason, exactly as `get` does. On a non-2xx
--- response it logs the code and returns `code, headers, nil`, so a caller can
--- tell "the server refused" from "the network died" — `meguru/progress` reports
--- those as `"http"` and `"network"`, and they are not the same problem.
---
--- **The body is the caller's, and this module has no encoder.** The one write
--- this plugin makes is one field, and dragging in a JSON library for it would be
--- machinery with one caller.
---
--- `opts`: { username, password, content_type, accept,
---           timeout = "progress"|"feed"|"page"|"large"|"resume" }.
function Net.patch(url_str, body, opts)
    opts = opts or {}
    body = type(body) == "string" and body or ""
    local parsed = url.parse(url_str)
    if not parsed or (parsed.scheme ~= "http" and parsed.scheme ~= "https") then
        logger.warn("Meguru: unsupported protocol for", Net.redactUrl(url_str))
        return nil
    end

    local sink = {}
    local req = {
        url = url_str,
        method = "PATCH",
        headers = {
            ["Accept"] = opts.accept or "*/*",
            -- Same reason as `get`'s: the sink is a plain byte table and nothing
            -- here inflates anything.
            ["Accept-Encoding"] = "identity",
            ["Content-Type"] = opts.content_type or "application/json",
            -- Stated rather than left to LuaSocket: a request carrying a body and no
            -- length is answered 411 by some servers and proxies, and counting a
            -- body this short twice costs nothing.
            ["Content-Length"] = tostring(#body),
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(sink),
    }
    if opts.username and opts.username ~= "" then
        req.user = opts.username
        -- As in `get`: LuaSocket concatenates user..":"..password, so a nil
        -- password raises inside http.request.
        req.password = opts.password or ""
    end

    local timeout = TIMEOUTS[opts.timeout or "progress"] or TIMEOUTS.progress
    socketutil:set_timeout(timeout[1], timeout[2])
    local ok, code, headers = pcall(function()
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
    if code < 200 or code > 299 then
        logger.warn("Meguru: HTTP", code, "for", Net.redactUrl(url_str))
        return code, headers, nil
    end
    return code, headers, table.concat(sink)
end

--- Synchronous GET written straight to `path`. Returns `true`, or `nil, reason`
--- where reason is `"network"`, `"http"` or `"write"`.
---
--- **This exists beside `get` rather than inside it, and the reason is that
--- `get` cannot be bounded.** `get` collects its body with `ltn12.sink.table`,
--- and `socketutil`'s total timeout is honoured *only* by its own sinks — the
--- socket-level total is reset on every poll, which `socketutil.lua:38-42` says
--- outright. So everything fetched through `get` is bounded per read and not in
--- wall-clock at all. That is survivable for a feed page and not for an update
--- archive: the reader's device would sit with a frozen UI, no upper bound on
--- how long, and the whole file on the Lua heap. `socketutil.file_sink` is what
--- makes the `total` number mean anything here, and the file is the other half.
---
--- A partial file is removed on every failure path, so a truncated download
--- cannot be mistaken for a complete one by whatever reads that path next.
---
--- `opts`: { accept, timeout = "download"|"feed"|"page"|"large"|"resume" }.
function Net.getToFile(url_str, path, opts)
    opts = opts or {}
    local parsed = url.parse(url_str)
    if not parsed or (parsed.scheme ~= "http" and parsed.scheme ~= "https") then
        logger.warn("Meguru: unsupported protocol for", Net.redactUrl(url_str))
        return nil, "network"
    end
    local handle, open_err = io.open(path, "wb")
    if not handle then
        -- "wb" for the reason `FS.writeFile` gives: "w" would translate line
        -- endings, and an archive is the one file where a few hundred extra
        -- bytes still leave a header that looks right.
        logger.warn("Meguru: cannot write to", path, ":", tostring(open_err))
        return nil, "write"
    end

    local timeout = TIMEOUTS[opts.timeout or "download"] or TIMEOUTS.download
    socketutil:set_timeout(timeout[1], timeout[2])
    local ok, code = pcall(function()
        return socket.skip(1, http.request{
            url = url_str,
            headers = {
                ["Accept"] = opts.accept or "*/*",
                ["Accept-Encoding"] = "identity",
            },
            sink = socketutil.file_sink(handle),
        })
    end)
    socketutil:reset_timeout()

    -- `socketutil.file_sink` closes the handle on *every* terminating call, the
    -- error path included, so this is normally a no-op. It is here for the one
    -- case the sink never runs at all -- a request that dies before the first
    -- byte, where `http.request` returns without touching the sink and the
    -- handle would otherwise leak. `pcall`, because closing an already-closed
    -- handle raises in Lua 5.1 and that would turn a failed download into a
    -- thrown one.
    pcall(handle.close, handle)

    if not ok or type(code) ~= "number" or code ~= 200 then
        logger.warn("Meguru: could not download", Net.redactUrl(url_str),
            "(", tostring(code), ")")
        pcall(os.remove, path)
        return nil, (type(code) == "number") and "http" or "network"
    end
    return true
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
    -- A feed with no entries is still a feed, and is returned as one. It is not
    -- `fetchFeed`'s business to call that a parse failure, and for a long time it
    -- did: Suwayomi answers `filter=unread` on a fully read series with a valid,
    -- empty feed, and rejecting it here turned "the server says nothing is
    -- unread" into `"http"` — an HTTP-level failure with no URL logged to look
    -- at, because there *was* no HTTP error. See `fetchFeed`.
    return Net.feedFrom(root)
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
    if type(feed.entry) ~= "table" then
        -- Parsed, and lists nothing. **Its own reason, because it is its own
        -- state**: a caller that hears "http" goes looking for a status code
        -- that does not exist, and the filtered feeds this plugin asks for are
        -- *legitimately* empty — a fully read series has nothing under
        -- `filter=unread`. Callers that treat empty as "no answer" and ask again
        -- differently need to be able to tell it apart from a broken response.
        return nil, "empty"
    end
    return feed
end

return Net
