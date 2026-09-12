--[[--
What a credential looks like inside a URL, and how to take it out and put it
back.

Kavita is the reason this exists, and it puts its API key in **two different
places** depending on which kind of URL it is.

  * The stream and every feed carry it as a **path segment**
    (`/api/opds/<key>/…`), so a URL-shaped redaction that keeps the path keeps
    the key.
  * **The artwork carries it as a query parameter**
    (`/api/image/series-cover?seriesId=…&apiKey=<key>`, and `chapter-cover` the
    same way). A rule that only walks the path sees nothing here, which is how
    the key came to be written into marker files in plain text — see the
    `apiKey` rule below.

Both are written to the marker file in the reader's book folder, and `Net.get`
logs a URL on every failed request. (`Net.redactUrl` reduces a query to its byte
count, so a log line was never the leak; a marker was.)

This is a leaf: it requires nothing, logs nothing, and reads no settings. Callers
decide what to do with an answer.

**Three rules, and callers must take the one they mean.**

  * the segment after `opds/` names a *position*. Kavita puts its key there, and
    the catalogue root puts the same key in the same place — which is what makes
    this rule exactly invertible.
  * the `apiKey` **query parameter** names the same key again, in the URLs that
    do not go through `/opds/`. Also a position, also exactly invertible.
  * any UUID-shaped segment is a *guess* (Kavita's key happens to be a UUID).

`redact` applies all three, for a log line or a diagnostics column: a false
positive there costs one redacted word in a line nobody fetches from.
`redactTemplate` applies the first two and not the third, and that asymmetry is
load-bearing. A stream template is fetched *from*, so a guess that fires on
something else — a future driver whose book id is a UUID — would blank a part of
the URL that `restoreTemplate` cannot put back, because the only thing it knows
is the catalogue root's key. The book would break permanently, in a way no
configuration repairs. The two positional rules cannot do that: they replace what
they can name, and name it the same way back.
--]]

local Credential = {}

Credential.PLACEHOLDER = "<redacted>"

local UUID_SEGMENT = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

-- Escaped once, at load, rather than per call.
--
-- `gsub`'s pattern argument is not a string literal's business: the placeholder
-- is a Lua pattern here, and `<redacted>` happens to contain nothing magical
-- today. One that grew a `-` would become a lazy quantifier matching nothing,
-- and one that grew a `.` would match any character — so `restoreTemplate` would
-- splice the key over an adjacent byte and return a URL that is wrong by one
-- character with no error anywhere to say so.
local PLACEHOLDER_PATTERN = Credential.PLACEHOLDER:gsub("%W", "%%%0")

--- `scheme://host:port` of a URL, with no path — the part two URLs must share
--- before one's credential may be spliced into the other.
---
--- Read as a pattern rather than through `socket.url`, because this module is a
--- leaf that requires nothing (see the docblock) and because `url.parse` returns
--- a table whose `host` drops the port that this comparison has to keep: two
--- servers behind one hostname are told apart by their port and by nothing else.
---
--- Returns nil, or the empty string for a string that is not a URL at all;
--- `restoreTemplate` treats both as a refusal.
local function originOf(url_str)
    if type(url_str) ~= "string" then
        return nil
    end
    return url_str:match("^(%a[%w+.-]*://[^/]+)")
end

--- The credential the catalogue root carries, and where.
---
--- Only the positional rule: this is the value `restoreTemplate` will put back,
--- so it must be the value the template was stripped of, and nothing else.
---
--- Returns `key, at` — the key and the 1-based index it starts at — or nil when
--- the root carries none. A root that is already redacted returns nil rather
--- than `<redacted>`, so a caller that was handed `servers.root_url` by mistake
--- gets nothing instead of a no-op substitution that looks like success.
function Credential.keyFromRoot(root)
    if type(root) ~= "string" or root == "" then
        return nil
    end
    local at = root:find("/opds/", 1, true)
    if not at then
        return nil
    end
    local from = at + #"/opds/"
    -- Sliced before matching rather than matched with an `init`: whether `^`
    -- anchors to `init` or to the start of the subject is the kind of thing that
    -- differs between Lua versions, and this must not be the place that finds out.
    local key = root:sub(from):match("^([^/?]+)")
    if not key or key == "" or key == Credential.PLACEHOLDER then
        return nil
    end
    return key, from
end

--- Matches Kavita's artwork URLs: `?apiKey=<key>`, or `&apiKey=<key>` further in.
---
--- The value is cut at `&` and at `#` — a fragment would otherwise swallow the
--- rest of the URL into the placeholder, and `restoreTemplate` cannot put back
--- what it replaced as part of a larger match.
local APIKEY_PATTERN = "([?&]apiKey=)[^&#]*"

--- `str` with every credential-bearing position removed.
---
--- This is what a marker file stores. Two rules, because Kavita uses two
--- places, and the second one was missing for as long as only the first was
--- written down:
---
---   * the segment after `/opds/` — the stream template and every feed;
---   * the `apiKey` query parameter — every cover, which is why `cover_url`
---     and `series_cover_url` are in `CREDENTIAL_FIELDS` and needed this rule
---     to earn their place there. A cover URL contains no `/opds/` at all, so
---     the positional rule passed it through untouched and the key went to disk
---     inside a marker.
---
--- See the module docblock for why the UUID guess is deliberately not applied
--- here.
function Credential.redactTemplate(str)
    if type(str) ~= "string" or str == "" then
        return str
    end
    local out = str:gsub("(/opds/)[^/?]+", "%1" .. Credential.PLACEHOLDER)
    return (out:gsub(APIKEY_PATTERN, "%1" .. Credential.PLACEHOLDER))
end

--- `str` with every credential-shaped segment removed. For logs and diagnostics.
function Credential.redact(str)
    if type(str) ~= "string" or str == "" then
        return str
    end
    -- Rewritten in place rather than split and re-joined: `gmatch("[^/]+")`
    -- would drop one slash of the scheme's "//".
    local out = Credential.redactTemplate(str)
    return (out:gsub("/([^/]+)", function(segment)
        return segment:match(UUID_SEGMENT) and "/" .. Credential.PLACEHOLDER
            or "/" .. segment
    end))
end

--- Put `root`'s credential back where `template` was stripped of one.
---
--- Returns `restored, count`: the template, and how many placeholders were
--- filled. A count of 0 means nothing was done, and the caller decides whether
--- that is the healthy case (no placeholder to begin with — a Suwayomi marker)
--- or the broken one (a placeholder is still there).
---
--- **The origin guard is the whole safety of this function.** The key goes back
--- only when the placeholder sits inside the same `scheme://host:port` the
--- catalogue root is on — and refusing is the point: without the comparison the
--- function would splice catalogue B's key into a URL that still points at host
--- A, which is **sending one server's credential to another**. That is the worst
--- outcome this module can produce, and one comparison prevents it. A refusal
--- costs a visible `<redacted>` in the URL and a warning in the log, which is
--- self-describing.
---
--- **It used to require the prefix to be byte-identical to the root's, and that
--- was narrowed to the origin when the `apiKey` rule arrived.** The old test
--- worked only because a Kavita *stream* URL and its catalogue root share the
--- prefix `…/api/opds/`; a cover URL shares none of it (`…/api/image/…`), so the
--- identical-prefix test refused every cover and they would have been restored
--- to a literal `<redacted>` — a 404 the reader would see as a missing cover.
---
--- What was given up is smaller than it looks. Two Kavita catalogues on one
--- host have byte-identical prefixes anyway (`http://host/api/opds/`), so the
--- old test could not tell them apart either; the origin still refuses the case
--- the guard exists for, which is the key surviving a move to another host.
function Credential.restoreTemplate(template, root)
    if type(template) ~= "string" or template == "" then
        return template, 0
    end
    local at = template:find(Credential.PLACEHOLDER, 1, true)
    if not at then
        return template, 0
    end
    -- Everything before the placeholder, which the origin covers rather than
    -- equals: see the docblock for what that widened and what it did not.
    local prefix = template:sub(1, at - 1)
    local key = Credential.keyFromRoot(root)
    if not key then
        return template, 0
    end
    local origin = originOf(root)
    -- `#origin` is 0 for a string that matched nothing, and `prefix:sub(1, 0)`
    -- is the empty string, which would compare equal — so an unparseable root
    -- is refused explicitly rather than by luck.
    if not origin or origin == "" or prefix:sub(1, #origin) ~= origin then
        return template, 0
    end
    -- A *function* replacement, not a string: `string.gsub` gives `%` special
    -- meaning in a string replacement and raises "invalid use of '%' in
    -- replacement string". A Kavita key is a UUID and never contains one, but
    -- this is general and the throw would land in the page-fetch path, on the
    -- device, naming nothing.
    --
    -- **No parentheses around the call.** `return (f())` truncates a Lua
    -- multi-value expression to one value, and `gsub`'s second value is the
    -- count this function's caller branches on — so wrapping it here made
    -- `count` nil on exactly the *successful* path, where `count == 0` is false
    -- and the caller's `count > 1` then compared a number with nil and took the
    -- document open down with it. The two returns above are fine only because
    -- they are literals.
    return template:gsub(PLACEHOLDER_PATTERN, function() return key end)
end

return Credential
