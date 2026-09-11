--[[--
What a credential looks like inside a URL, and how to take it out and put it
back.

Kavita is the reason this exists. Its API key is not a query parameter but a
**path segment** (`/api/opds/<key>/…`), so a URL-shaped redaction that keeps the
path keeps the key — and every Kavita URL has one: the catalogue root, every
feed, every stream template, every page. It is written to the marker file in the
reader's book folder, and `Net.get` logs a URL on every failed request.

This is a leaf: it requires nothing, logs nothing, and reads no settings. Callers
decide what to do with an answer.

**Two rules, and callers must take the one they mean.**

  * the segment after `opds/` names a *position*. Kavita puts its key there, and
    the catalogue root puts the same key in the same place — which is what makes
    this rule exactly invertible.
  * any UUID-shaped segment is a *guess* (Kavita's key happens to be a UUID).

`redact` applies both, for a log line or a diagnostics column: a false positive
there costs one redacted word in a line nobody fetches from. `redactTemplate`
applies only the first, and that asymmetry is load-bearing. A stream template is
fetched *from*, so a guess that fires on something else — a future driver whose
book id is a UUID — would blank a part of the URL that `restoreTemplate` cannot
put back, because the only thing it knows is the catalogue root's key. The book
would break permanently, in a way no configuration repairs. The positional rule
cannot do that: it replaces what it can name, and names it the same way back.
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

--- `str` with the credential-bearing path segment removed, positionally.
---
--- This is what a marker file stores. See the module docblock for why the UUID
--- guess is deliberately not applied here.
function Credential.redactTemplate(str)
    if type(str) ~= "string" or str == "" then
        return str
    end
    return (str:gsub("(/opds/)[^/?]+", "%1" .. Credential.PLACEHOLDER))
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
--- **The prefix guard is the whole safety of this function.** The key goes back
--- only when the text before the template's first placeholder is byte-identical
--- to the text before the root's key. For Kavita both are
--- `http://host:port/api/opds/`, so it holds. It refuses when `server_name` now
--- names a *different* catalogue — a renamed entry, a second server reusing the
--- title, a server that moved host — and refusing is the point: without this
--- comparison the function would splice catalogue B's key into a URL that still
--- points at host A, which is **sending one server's credential to another**.
--- That is the worst outcome this module can produce, and one string comparison
--- prevents it. A refusal costs a visible `<redacted>` in the URL and a warning
--- in the log, which is self-describing.
function Credential.restoreTemplate(template, root)
    if type(template) ~= "string" or template == "" then
        return template, 0
    end
    local at = template:find(Credential.PLACEHOLDER, 1, true)
    if not at then
        return template, 0
    end
    local key, key_at = Credential.keyFromRoot(root)
    if not key then
        return template, 0
    end
    if template:sub(1, at - 1) ~= root:sub(1, key_at - 1) then
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
