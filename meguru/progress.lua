--[[--
The reader's position, sent back to the server the book came from.

**What was missing without this.** A Komga book's progress was only ever *read* —
`pse:lastRead` off the feed, which Komga publishes from `readProgress?.page` and
only once a book has some. Nothing in this plugin ever sent one, so Komga's
`readProgress` stayed empty, so the attribute never appeared on the feed, so the
read half — `ui/open.lua`'s resume offer, `MeguruDocument:init`'s silent seed —
had nothing to read. The loop was open at the write end, and from the reader's
side an open loop is indistinguishable from a server that tracks nothing at all.

**A driver describes the request; this module makes it.** The endpoint, its body
and the numbering are the server's business (`driver.progressRequest`), and the
credential, the timeout, the redaction and the failure line are the engine's.
That is why there is exactly one `Net.patch` call in the plugin, and why a driver
cannot hold a socket open for as long as it likes.

**Two servers are absent, for two different reasons.** Suwayomi must not be given
this: its own stream template carries `?updateProgress=true`, so its server is
told the position by the page fetch the reader already makes — the one server
whose loop was never open, by accident of its wire format, and a second write
would be a duplicate. Kavita's write API is a different surface from its OPDS one,
reached with a JWT from a login rather than the API key already in its URLs; that
is a second authentication path, and this module does not carry one for a feature
nobody reported as broken.

**Failure is silent.** A report that does not land is a lost page number, not a
lost book: one line through `logger`, the URL through `Net.redactUrl` like every
other URL this plugin logs, and never a dialog, never a throw, never a retry of
its own. The reader is turning pages; the caller has already moved on.

**Nothing here knows what a page turn is.** There is no timer in this module and
no `UIManager` in it. *When* to report is a statement about the reader's thumb,
and belongs where the reader's UI is (`ui/reader.lua`); *what* is worth reporting
is the rule below, which belongs here beside the floor it is derived from.
--]]

local logger = require("logger")

local Base = require("meguru/driver/base")
local Net = require("meguru/net")
local Settings = require("meguru/settings")
local Sources = require("meguru/sources")

Base.loadDrivers()

local Progress = {}

--- The servers this may report to, and the list `ui/menu` builds its rows from.
---
--- Closed on purpose, word for word as `SeriesCover.KINDS` is: a kind that is not
--- here is not asked about its setting, because `Settings.get` warns and returns
--- nil for a name it does not know. A list derived from "which drivers implement
--- the hook" would answer *who can* rather than *who should* — and the one driver
--- that must never be on it is Suwayomi, whose loop was never open.
Progress.KINDS = { "komga" }

--- The settings key a kind's switch is stored under.
local function settingFor(kind)
    return "report_progress_" .. kind
end
Progress.settingFor = settingFor

--- Whether this kind is both known and switched on.
---
--- Asked on every report rather than cached by the caller, so turning the row off
--- takes effect at the next page rather than at the next book.
function Progress.wanted(kind)
    for _, known in ipairs(Progress.KINDS) do
        if known == kind then
            return Settings.get(settingFor(kind)) and true or false
        end
    end
    return false
end

--- Whether there is a network to send over.
---
--- The same test, in the same shape, that `SeriesCover.save` and
--- `MeguruDocument:hasConnection` make, and lazy for the same reason: it is a
--- *device* state, and a module that reached for the network manager at load time
--- would be unusable anywhere the UI is not up yet.
local function isConnected()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    return ok and NetworkMgr ~= nil and NetworkMgr:isConnected()
end

--- The position below which this installation will not report one, or nil.
---
--- **The whole of the regression policy is this number and one sentence: a report
--- never lowers the position the server already has.** Three guards fall out of
--- that one rule rather than being three rules of their own — a finished book
--- cannot be un-finished (Komga records its last page, so the floor *is* the last
--- page and every report is refused), a position that has not moved is not
--- re-sent, and a page already accepted is not reported again.
---
--- **It is the *server's* number, not the reader's.** `desc.last_read` is
--- `pse:lastRead` off the feed. The sidecar's `last_page` is the reader's own
--- progress, and using it would suppress the report that catches a server up on a
--- book it has never heard about — which is the case this module exists for.
---
--- **Clamped to `total`**, because a page count that shrank under a stale recorded
--- page would otherwise lock the book out of ever being reported again.
---
--- **Base-agnostic on purpose.** Whether a server counts its recorded page from
--- zero or from one is a property of that server, and nothing here needs to know:
--- a floor one page too low can only permit a report that could have been refused,
--- and can never move a server backwards.
function Progress.floorFor(desc, total)
    if type(desc) ~= "table" then
        return nil
    end
    local recorded = tonumber(desc.last_read)
    if not recorded or recorded < 1 then
        return nil
    end
    if total and total >= 1 and recorded > total then
        return total
    end
    return math.floor(recorded)
end

--- Is `page` ahead of the position this installation has already recorded?
---
--- **The one definition of that rule**, asked here by the reporter and in
--- `ui/reader.lua` by both the page-turn arm and the closing flush. It is one
--- comparison with three callers, which is exactly the shape this codebase keeps
--- finding drifted copies of — `PSE.pageURL` is "the only place that rule lives"
--- for the same reason, and a guard that says "do not move the server backwards"
--- is not one to keep in three places.
---
--- A nil `floor` means nothing has been recorded, so every page is ahead of it.
function Progress.moved(floor, page)
    page = tonumber(page)
    if not page or page < 1 then
        return false
    end
    if not floor then
        return true
    end
    return page > floor
end

--- Send one page to the server the book came from.
---
--- Returns `true`, or `nil, reason`. **The reasons are the interface**, and the
--- caller distinguishes exactly two of them: `"off"`, `"offline"` and `"behind"`
--- are not the server's fault and must not count against its failure budget — an
--- offline device asked once per page turn costs nothing, and the answer changing
--- is how reporting comes back — while `"network"` and `"http"` are.
---
--- Synchronous, and that is the whole reason the caller is expected to debounce
--- it and to give up after a few failures: this blocks the UI thread for up to
--- `Net.PROGRESS_BLOCK_TIMEOUT`. Nothing here retries and nothing here schedules.
---
--- `marker_path` is used for one thing — the credential this session already
--- resolved for that book, which `Sources.credentials` prefers over the catalog
--- so a report cannot race the catalog's own cache.
function Progress.report(marker_path, desc, page, total)
    if type(desc) ~= "table" then
        return nil, "desc"
    end
    if not Progress.wanted(desc.server_kind) then
        return nil, "off"
    end
    local driver = Base.forKind(desc.server_kind)
    if not (driver and type(driver.progressRequest) == "function") then
        return nil, "hook"
    end

    page = math.floor(tonumber(page) or 0)
    total = tonumber(total)
    if page < 1 or not total or total < 1 then
        return nil, "page"
    end

    -- **The floor is asked here as well as by the caller, and that is not
    -- redundancy.** It is the difference between a rule the state machine in
    -- `ui/reader.lua` happens to keep and a rule no caller can break. The
    -- caller's floor is the stricter of the two — it rises with every accepted
    -- report, where this one is the snapshot the marker carries — so it never
    -- refuses a report the caller would have sent.
    if not Progress.moved(Progress.floorFor(desc, total), page) then
        return nil, "behind"
    end

    -- Asked before the request rather than after it, and this is the whole reason
    -- it is here: reading on a train is the ordinary case, and it should cost
    -- nothing rather than one timeout per page turn.
    if not isConnected() then
        return nil, "offline"
    end

    local request = driver.progressRequest(desc, page)
    if type(request) ~= "table" or type(request.url) ~= "string" then
        return nil, "hook"
    end

    local username, password = Sources.credentials(desc.server_name, marker_path)
    local code = Net.patch(request.url, request.body or "", {
        content_type = request.content_type,
        username     = username,
        password     = password,
        timeout      = "progress",
    })
    if code and code >= 200 and code <= 299 then
        logger.dbg("Meguru: reported page", page, "of", total,
            "to", Net.redactUrl(request.url))
        return true
    end

    -- Split the way `Net.fetchFeed` splits it, and for the same reason: a caller
    -- that hears "http" for a dead route goes looking for a status code that does
    -- not exist. `Net.patch` has already logged which of the two it was.
    return nil, code and "http" or "network"
end

return Progress
