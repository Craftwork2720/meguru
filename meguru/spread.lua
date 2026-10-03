--[[--
Which pages are shown together, when the reader has asked for two at a time.

The reader's page number and the thing on the screen stop being the same once a
book is read two-up: page 7 is drawn beside page 8, and the *pair* is the unit.
This module is the whole of that rule. It is pure — it takes a page number, the
page count, the list of pages already known to be wide, and the page the offset
is anchored at, and returns the unit that page belongs to. Nothing here fetches,
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
9 wide gives: 9 alone, then **(10,11)**, then (12,13) — the offset off, which is
what a reader sees by default and what "the pairing starts again" means. The wide
page consumes one slot and the pairing continues from the page after it, which is
what a reader sees in the book: the printed spread is where the imposition starts
again. What the offset does to that is below.

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
known wide page re-anchors the run. The offset row is the reader's correction for
it — set where they are and that run's pairing moves one page — which is why the
two settings sit next to each other.

## The offset

Offset off pairs (1,2), (3,4)…; offset on leaves the **first page of a run**
standing alone and pairs (2,3), (4,5), (6,7) — so a reader on page 7 sees 6+7
rather than 7+8, which is what a book whose pages are laid out that way needs.

**The offset is held as the page it is anchored at, and it is the run that page
belongs to which is offset.** One sentence, doing two jobs, and both of them are
things a reader asked for:

* **A wide page ends the offset by itself.** Anchored at the front of a book with
  page 9 wide, the walk is: 1 alone, 2+3, 4+5, 6+7, 8 alone, **9** (the spread),
  then **(10,11)** — the run after a spread is not offset, because the anchor is
  not in it. A printed spread has already shifted the pairing by that one page,
  which is what the offset exists to correct; carrying it across the spread would
  put the rest of the book out by one instead.
* **The reader can anchor it again from where they are.** Setting the row on page
  10 anchors it *there*, so that run is the offset one: 10 alone, then (11,12).
  That is the whole of what "the reader has control" means here — the offset
  applies to the run it was set in and to no other.

The alternative was written first and rejected: a flag that offsets **every** run,
so a wide page means 9 (spread), 10 alone, (11,12). That is a reader who set the
offset at the front of a book being told that every spread after a printed one
goes out by a page as well — a rule that keeps answering after it has stopped
being true.

Where a re-anchored offset meets the wide page before it, there are two single
pages in a row: 9 is the spread, 10 is the run's first page. That is the shape to
look at if the pairing after a wide page ever reads wrong, and
`tools/spreadcheck.py` prints these walks and checks the rules behind them.

**An anchor of 0 is "off"**, and it is read by comparison: `0` and `"0"` are both
*truthy* in Lua, so a truth test would read a stored "off" as on. A stored `1` —
which is what this row wrote back when it was a flag — means page 1, the front of
the book, which is exactly the behaviour it had then.

## The gutter

A pair drawn from two tightly cropped pages has its artwork butted together at
the seam, and a book does not look like that: the pages are printed with a margin
on the side that goes into the binding, and when the two pages of a spread are
cropped to their panels that margin is thrown away. `gutter` gives it back —
**as much of it as the screen has room for, and never more than the page had.**

**Whether it is asked at all is the reader's, and that is the one thing here that
is not arithmetic**: the *Flexible gutter* row under *Two pages*, on by default,
and `document.lua`'s `_pairLayout` skips this function entirely when it is off. The
four sentences below do not change with it.

The rule is four sentences, and the order of them is the whole of it:

1. The **outer** edges of the pair stay tight to the artwork. They are the crop's
   business and this does not touch them.
2. The **scale comes first**, and it is the fit of the artwork *alone* — the two
   cropped pages side by side, fitted to the screen. The gutter is not part of
   that sum, so it can never make the artwork smaller.
3. The **gutter is the leftover**: whatever horizontal space is still going spare
   once the artwork is at that scale. It is a *consequence* of the scale rather
   than a term in it, which is why the two cannot disagree.
4. It is **clamped to the margins the pages actually have** — each half of the
   pair to its own page's inner margin, and neither may grow past it. A page
   cropped flush to its inner edge keeps a gutter of zero, and a screen with more
   slack than margin leaves the excess at the sides rather than inventing paper.

Two consequences worth stating because they are visible. On a screen whose shape
matches the pair's artwork — a 4:3 panel and two 2:3 pages, say — the leftover is
small, so the gutter is small and the artwork spans the screen exactly. On a very
wide screen the leftover is larger than the page's own margin, and then the margin
is all the gutter gets and the rest is letterbox: **the artwork is never blown up
to fill a gutter it does not have.**

The split between the two halves is proportional to the two margins. A page with
no inner margin contributes nothing, so the whole gutter lands on the other page's
side of the seam — which is also the right answer for the commonest scan of all,
where only one of the two pages has any margin at the inner edge to begin with.

The arithmetic is one function over plain numbers precisely so it can be checked
without a device — everything above is a `min` and a ratio, and
`tools/spreadcheck.py` is that check, the way `tools/panelprobe.py` is the panel
detector's.

## A page cropped smaller grows into what the pair is not using

A pair whose two pages are cropped to different heights has a blank under the
shorter one, and the shorter one grows into it — **as far as the room beside the
pair goes and no further, and never at the other page's expense.** `grow` is the
whole of it.

Three things about it are worth stating, because they are what makes it safe to
ask of every pair rather than a feature with a row of its own:

* **It only ever enlarges.** Each factor comes back 1 or more, and the taller
  half's is exactly 1: the page the reader already had is drawn at the size it
  had. Two pages cropped alike — two pages of one scan, the overwhelmingly common
  case — come back with two 1s, so **a book that never had a blank under a page
  reads exactly as it did before this rule existed.**
* **The room is the width the pair is not using.** The pair is fitted to the
  screen, so what is left over is horizontal, and it is left over exactly while
  the pair's *height* is what limits its fit. The shorter page grows until it is
  as tall as the other or until the room runs out, whichever comes first.
* **It cannot change the fit.** The growth stops at the width the pair's own
  height allows, so the pair is limited by its height before and after alike and
  the taller page is drawn at the same size — the promise is one equation:
  `min(screen_w / W, screen_h / H)` is the same on both sides of it.

**A pair fitted by width is not offered the growth at all**, and that falls out
of the second sentence rather than being a case of its own: a fit limited by the
width *is* the pair filling the screen's width, so there is nothing left to grow
into — and a page grown into a width-bound pair would take its room from the
other page, because the fit would shrink to make it. The caller says which fit is
in force, because the mode is the reader's and this module is arithmetic.

The screen is the one the gutter is measured against, and for the reason given
there; a footer the reader has kept makes the pair's own fit very slightly
smaller than this sum assumes, which leaves the room *under*-estimated rather
than over-, so nothing above is violated by it.

Like the gutter, it is plain numbers so it can be checked without a device:
`tools/spreadcheck.py` asks the same three sentences of a grid of pairs.
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

--- The page a *run* starts at: the stretch of pages between two wide ones, which
--- is what the offset is anchored in. A wide page is a run of its own, and
--- anything below page 1 answers 0 — which is also "no anchor", so an offset of 0
--- can never match a run and `unitFor` needs no case for it.
function Spread.runStart(page, list)
    list = list or {}
    page = tonumber(page) or 0
    if page < 1 then
        return 0
    end
    if isWide(list, page) then
        return page
    end
    local wide = lastBelow(list, page)
    return wide and (wide + 1) or 1
end

--- The unit `n` belongs to: `{ a = n }` for a page shown alone, `{ a = a, b = b }`
--- for a pair. `a` is always the earlier page — which of the two is drawn on the
--- left is the reading direction's business, not this module's.
---
--- `list` must be ascending and hold every page this session knows to be wide;
--- `anchor` is the page the offset is anchored at, or 0 for off — the per-book
--- answer described in the header.
---
--- Returns nil only for a page number outside the book.
function Spread.unitFor(n, count, list, anchor)
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

    -- **The offset is the run it is anchored in and no other**, which is what
    -- makes a wide page end it by itself: the anchor is not in the new run. An
    -- anchor of 0 answers a run start of 0, and no run starts at 0, so "off"
    -- needs no case here. See the header.
    local first = (Spread.runStart(anchor, list) == run) and 1 or 0
    local idx = n - run
    if idx < first then
        return { a = n }              -- the run's first page, offset on
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
function Spread.nextStart(n, count, list, anchor)
    local unit = Spread.unitFor(n, count, list, anchor)
    if not unit then
        return nil
    end
    local after = unit.b and (unit.b + 1) or (unit.a + 1)
    if after > count then
        return nil
    end
    local next_unit = Spread.unitFor(after, count, list, anchor)
    return next_unit and next_unit.a or nil
end

--- The page a backward turn from `n` lands on, or nil at the start of the book.
function Spread.prevStart(n, count, list, anchor)
    local unit = Spread.unitFor(n, count, list, anchor)
    if not unit or unit.a <= 1 then
        return nil
    end
    local prev_unit = Spread.unitFor(unit.a - 1, count, list, anchor)
    return prev_unit and prev_unit.a or nil
end

--- How far each half of a pair may widen into its own page's inner margin, in the
--- pages' own units. The header's four sentences, as arithmetic.
---
--- `content_w`/`content_h` are the two *cropped* pages side by side — the artwork
--- the scale is fitted to. `inner_left`/`inner_right` are what each page has to
--- give: the distance from its content to its own edge on the side that faces the
--- other page (so the left page's right margin and the right page's left margin).
--- The screen is the one the pair is being laid out against.
---
--- Returns `{ left = , right = }` in the same units as the margins it was handed,
--- so the caller widens each page's box by them and needs to know nothing about
--- the scale. Both are zero when there is nothing to do — no margin measured, no
--- room going spare, or nothing to measure at all.
function Spread.gutter(content_w, content_h, inner_left, inner_right, screen_w, screen_h)
    local nothing = { left = 0, right = 0 }
    content_w, content_h = tonumber(content_w), tonumber(content_h)
    screen_w, screen_h = tonumber(screen_w), tonumber(screen_h)
    if not (content_w and content_h and screen_w and screen_h)
        or content_w <= 0 or content_h <= 0
        or screen_w <= 0 or screen_h <= 0 then
        return nothing
    end
    local max_left = math.max(0, tonumber(inner_left) or 0)
    local max_right = math.max(0, tonumber(inner_right) or 0)
    local total_max = max_left + max_right
    if total_max <= 0 then
        return nothing
    end

    -- The artwork's own fit. The gutter comes out of what is left of the screen
    -- after it and is never a term in front of it, which is what keeps the two
    -- from disagreeing about how big the pages are.
    local scale = math.min(screen_w / content_w, screen_h / content_h)
    local spare = math.max(0, screen_w - content_w * scale)
    -- And never wider than the margins the pages actually have: a screen with
    -- more slack than that leaves the excess at the sides rather than widening a
    -- margin the source has not got.
    local total = math.min(spare, total_max * scale)
    if total <= 0 then
        return nothing
    end

    -- Split in proportion to the two margins, so a page with no inner margin of
    -- its own puts the whole gutter on the other page's side of the seam.
    local left = total * (max_left / total_max)
    -- The right is the remainder rather than a second product: two ratios of the
    -- same rounded number can come back a hair over the cap they were clamped to,
    -- and a gutter that is a hair over its own page's margin would draw paper the
    -- page does not have.
    local right = total - left
    return { left = left / scale, right = right / scale }
end

--- How far each half of a pair grows into the room the pair is not using, when
--- its two pages are cropped to different heights.
---
--- The header's three sentences, as arithmetic. `lw`/`lh` and `rw`/`rh` are the
--- two halves as they are drawn — each page's crop widened by whatever gutter it
--- keeps, in the pair's own units — and `fits_by_width` says whether the fit in
--- force limits the pair by its width, which is the one case with no room in it.
---
--- Returns a factor for each half, always 1 or more and exactly 1 for the half
--- that is not the shorter one, so the caller multiplies a box by it and needs to
--- know nothing about the scale. Both are 1 when there is nothing to do: equal
--- heights, no room going spare, a fit by width, or nothing to measure at all.
function Spread.grow(lw, lh, rw, rh, screen_w, screen_h, fits_by_width)
    local nothing = { left = 1, right = 1 }
    if fits_by_width then
        return nothing
    end
    lw, lh = tonumber(lw), tonumber(lh)
    rw, rh = tonumber(rw), tonumber(rh)
    screen_w, screen_h = tonumber(screen_w), tonumber(screen_h)
    if not (lw and lh and rw and rh and screen_w and screen_h)
        or lw <= 0 or lh <= 0 or rw <= 0 or rh <= 0
        or screen_w <= 0 or screen_h <= 0 then
        return nothing
    end

    -- **The room is the width the pair is not using**: what is left of the screen
    -- once the pair is at the height that limits its fit, which is nought for a
    -- pair that already fills the width. Measured from this end it is the spare
    -- the growth may spend; measured from the other it is the promise in the
    -- header — the fit is `screen_h / h_max` on both sides of the growth, so the
    -- taller half is drawn at the size it had.
    local h_max = math.max(lh, rh)
    local free = math.max(0, screen_w * h_max / screen_h - (lw + rw))
    if free <= 0 then
        return nothing
    end

    -- The shorter half grows until it is as tall as the other and no further than
    -- the room allows: the first term is the whole of the blank under it, the
    -- second what the screen has left. Neither half is scaled down, and the taller
    -- one's factor is not computed at all — which is what makes that a property of
    -- the function rather than something the caller has to keep true.
    if lh < rh then
        return { left = math.min(h_max / lh, 1 + free / lw), right = 1 }
    elseif rh < lh then
        return { left = 1, right = math.min(h_max / rh, 1 + free / rw) }
    end
    return nothing
end

return Spread
