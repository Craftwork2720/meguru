--[[--
Which pages are shown together, when the reader has asked for two at a time.

The reader's page number and the thing on the screen stop being the same once a
book is read two-up: page 7 is drawn beside page 8, and the *pair* is the unit.
This module is the whole of that rule. It is pure — it takes a page number, the
page count, the list of pages already known to be wide, and whether the offset
answer is on, and returns the unit that page belongs to. Nothing here fetches,
renders or remembers anything; the document owns the answers and this owns the
arithmetic.

## A wide page is never a partner

A page the artist drew as one wide image (wider than tall) is a spread already.
It is shown **alone**, and so is a page whose *neighbour* is wide — a printed
spread is never cut in half across two screens. Both fall out of the same rule
rather than being two cases: a unit is one page when pairing it would put a wide
page in a pair.

## The run restarts after a spread

**This is the rule that makes the whole thing worth having.** Reading forward
from page 1, the pairs are (1,2), (3,4), (5,6) — until a wide page arrives. Page
9 wide gives: 9 alone, then **(10,11)**, then (12,13). The wide page consumes one
slot and the pairing continues from the page after it, which is what a reader
sees in the book: the printed spread is where the imposition starts again.

So the unit a page belongs to is *not* a function of the page's own parity. It is
a function of the last wide page before it — the run — and this module computes
it from the list of wide pages the session has actually decoded rather than by
walking the book. `unitFor` is therefore closed-form: the greatest known wide
page below `n` starts the run, and the parity within the run decides the rest.

## What that costs on a jump

The run is derived **only from the pages this session has decoded**, and the feed
carries no dimensions at all — a page's size is known only once its image has
been fetched and decoded (`MeguruDocument:getPageDims`). Reading in order is
exact: by the time a page is reached, it and its neighbours have been decoded.
A *jump* — a table of contents, a percentage, a resume — can land past wide pages
that were never seen, and the run is then the one page 1 would have given.

What the reader sees when that happens is **a parity flip**: two spreads shown
the other way round, each page individually correct, from then on until the next
known wide page re-anchors the run. The offset answer is the reader's correction
for it — it moves every pairing by one page — which is why the two settings sit
next to each other.

## The offset

Offset off pairs (1,2), (3,4)…; offset on leaves **page 1 alone** and pairs
(2,3), (4,5), (6,7) — so a reader on page 7 sees 6+7 rather than 7+8, which is
what a book whose first page stands alone needs. It shapes *only the run that
contains page 1*: a run that starts after a wide page always begins pairing at
its first two pages (page 9 wide means (10,11), offset or not). That is the
behaviour that makes the offset a correction for the front of the book rather
than a second, competing imposition.

**The stored value is 0/1 and 0 is truthy in Lua**, so `offset` is normalised by
comparison here and nowhere else — the trap `meguru/doc/defaults`' `seedRowValue`
documents at length.
--]]

local Spread = {}

--- Is `p` in the ascending `list`?
local function isWide(list, p)
    local lo, hi = 1, #list
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local v = list[mid]
        if v == p then
            return true
        elseif v < p then
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return false
end

--- The greatest element of the ascending `list` strictly below `n`, or nil.
local function lastBelow(list, n)
    local lo, hi, found = 1, #list, nil
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if list[mid] < n then
            found = list[mid]
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return found
end

--- The offset answer's domain, read explicitly. `0` and `"0"` are both "off",
--- and both are *truthy* — an `if offset then` here would read a stored 0 as on.
local function offsetOn(offset)
    return offset == true or offset == 1 or offset == "1"
end

--- The unit `n` belongs to: `{ a = n }` for a page shown alone, `{ a = a, b = b }`
--- for a pair. `a` is always the earlier page — which of the two is drawn on the
--- left is the reading direction's business, not this module's.
---
--- `list` must be ascending and hold every page this session knows to be wide;
--- `offset` is the per-book answer described in the header.
---
--- Returns nil only for a page number outside the book.
function Spread.unitFor(n, count, list, offset)
    n = tonumber(n)
    if not n or not count or n < 1 or n > count then
        return nil
    end
    list = list or {}

    -- A wide page is a spread already: it is never one half of a pair.
    if isWide(list, n) then
        return { a = n }
    end

    -- The run this page is in: it starts after the last *known* wide page below
    -- it, or at page 1. See the header for what "known" costs on a jump.
    local wide = lastBelow(list, n)
    local run = wide and (wide + 1) or 1

    -- The offset only shapes the run that holds page 1 (the header's rule).
    local first = (run == 1 and offsetOn(offset)) and 1 or 0
    local idx = n - run
    if idx < first then
        return { a = n }              -- page 1, offset on: it stands alone
    end

    if ((idx - first) % 2) ~= 0 then
        -- The second page of its pair: the unit starts one back.
        return { a = n - 1, b = n }
    end

    local nxt = n + 1
    if nxt > count or isWide(list, nxt) then
        -- No partner: the last page of the book, or the next page is a spread
        -- that must not be cut in half.
        return { a = n }
    end
    return { a = n, b = nxt }
end

--- The page a forward turn from `n` lands on — the start of the *next* unit, or
--- nil at the end of the book. This is what makes one gesture turn a whole
--- spread rather than a page.
function Spread.nextStart(n, count, list, offset)
    local unit = Spread.unitFor(n, count, list, offset)
    if not unit then
        return nil
    end
    local after = unit.b and (unit.b + 1) or (unit.a + 1)
    if after > count then
        return nil
    end
    local next_unit = Spread.unitFor(after, count, list, offset)
    return next_unit and next_unit.a or nil
end

--- The page a backward turn from `n` lands on, or nil at the start of the book.
function Spread.prevStart(n, count, list, offset)
    local unit = Spread.unitFor(n, count, list, offset)
    if not unit or unit.a <= 1 then
        return nil
    end
    local prev_unit = Spread.unitFor(unit.a - 1, count, list, offset)
    return prev_unit and prev_unit.a or nil
end

return Spread
