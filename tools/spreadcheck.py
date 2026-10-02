"""A faithful port of meguru/spread.lua, to run the two-page imposition and the
gutter arithmetic without a Lua interpreter. A development aid, not part of the
plugin.

Run it as `python tools/spreadcheck.py`. It checks **properties**, not fixtures:
the rules the module is specified by, over every combination of a small book's
wide pages, every anchor the offset can be set to, and a grid for the gutter.
Then it prints a few walks, because the point of the imposition is what a reader
sees and a printed walk is the only way to read that here.

What it checks, and why each one is a property rather than an example:

* **The units tile the book exactly** — for chapter lengths 1..8 crossed with
  *every* set of wide pages and every anchor, walking page 1 to the end by whole
  units lands on every page exactly once, in order, and every unit is a single
  page or an adjacent pair. This is the whole of "which pages are shown
  together": a gap, an overlap or a pair spanning a wide page fails it.
* **Asking from either page of a pair answers the same pair** — the reader's page
  counter may stand on either one, and the pair drawn must not depend on which.
* **Turning walks the units** — `next_start` from the first unit visits every unit
  start in order and then answers None at the end of the book; `prev_start` does
  the mirror. A stall or a skip fails it, including the end-of-book case the
  reader's own page counter cannot see (the last unit being a pair).
* **The offset is in force in the run it is anchored in, and nowhere else** — this
  is the rule a reader asked for in two halves: outside that run the units are
  exactly the un-anchored ones, so **a wide page ends an offset by itself**; and
  inside it the run's first page stands alone, which is what makes setting the row
  again past a wide page re-anchor the offset there.
* **A page change is a turn or a landing, and the two are answered differently** —
  a turn whose target is inside the unit on screen steps a whole unit, a landing on
  that same page stays on the unit that contains it. The panel viewer's crossing is
  the landing that matters, and it is the one this rule was written wrong.
* **The gutter's four rules** — over a grid of artwork sizes, margins and screen
  shapes: never wider than the page's own margin, never a term in the scale (the
  artwork's fit is reproduced exactly by the pair's own fit), the pair never
  overflows the screen, and the spare width is what the gutter takes when the
  margin allows it.
* **The stated examples** — the ones the rules were written from, printed below.

**What this models, and what it does not**, per `docs/development.md`'s rule about
mirrors. It models the module's *arithmetic* — the run walk, the anchor and the
four gutter sentences — because that is what a check can settle. It does not model
Lua's evaluation rules, and one of them is in the code it mirrors: `unitFor` folds
`(run_start(...) == run) and 1 or 0`, safe only because the middle value is `1` —
a change to a value that could be `false` would not be mirrored here. The wide
list is searched as a binary search where this asks membership and the greatest
element below. A divergence in either is a divergence this cannot see.
"""

import itertools
import sys

# ---------------------------------------------------------------------------
# meguru/spread.lua, ported
# ---------------------------------------------------------------------------


def wide(wides, page):
    """Membership in the ascending list — the answer, not the binary search."""
    return page in wides


def last_wide_below(wides, n):
    """The greatest element of `wides` strictly below `n`, or None."""
    best = None
    for w in wides:
        if w < n and (best is None or w > best):
            best = w
    return best


def run_start(page, wides):
    """`Spread.runStart`: the page the run containing `page` starts at. A wide
    page is a run of its own, and anything below page 1 answers 0 — which is also
    "no anchor", so an offset of 0 can never match a run."""
    wides = wides or []
    try:
        page = int(page)
    except (TypeError, ValueError):
        return 0
    if page < 1:
        return 0
    if wide(wides, page):
        return page
    below = last_wide_below(wides, page)
    return (below + 1) if below is not None else 1


def unit_for(n, count, wides, anchor):
    """`Spread.unitFor`: the unit `n` is shown in — `(a, None)` alone, `(a, b)`
    for a pair — or None outside the book. `anchor` is the page the offset is
    anchored at, 0 for off."""
    if count is None or n is None or n < 1 or n > count:
        return None
    wides = wides or []
    if wide(wides, n):
        return (n, None)
    below = last_wide_below(wides, n)
    run = (below + 1) if below is not None else 1
    # The offset is the run it is anchored in — so a wide page ends it, the anchor
    # not being in the new run, and 0 (no anchor) never matches one.
    first = 1 if run_start(anchor, wides) == run else 0
    idx = n - run
    if idx < first:
        return (n, None)
    if ((idx - first) % 2) != 0:
        return (n - 1, n)
    nxt = n + 1
    if nxt > count or wide(wides, nxt):
        return (n, None)
    return (n, nxt)


def next_start(n, count, wides, anchor):
    """`Spread.nextStart`: the page a forward turn from `n` lands on."""
    unit = unit_for(n, count, wides, anchor)
    if not unit:
        return None
    a, b = unit
    after = (b + 1) if b else (a + 1)
    if after > count:
        return None
    nxt = unit_for(after, count, wides, anchor)
    return nxt[0] if nxt else None


def prev_start(n, count, wides, anchor):
    """`Spread.prevStart`: the page a backward turn from `n` lands on."""
    unit = unit_for(n, count, wides, anchor)
    if not unit or unit[0] <= 1:
        return None
    prev = unit_for(unit[0] - 1, count, wides, anchor)
    return prev[0] if prev else None


def spread_snap(number, current, count, wides, anchor, turn):
    """`MeguruDocument:spreadSnap` — the imposition's rule as the pager asks it.

    Ported here rather than left to the device because the *same* target answers
    differently in the two modes, which is what the panel viewer's page crossing got
    wrong: a turn into the unit already on screen steps a whole unit, and a landing
    on that same page stays on the unit that contains it. It does not model the
    second return value (whether a forward turn ran off the end of the book), which
    the pager uses to say `EndOfBook`."""
    if number is None or count is None:
        return number
    if number < 1:
        return number
    if number > count:
        number = count
    here = unit_for(current, count, wides, anchor) if current else None
    there = unit_for(number, count, wides, anchor)
    if turn and here and there and here[0] == there[0] and current != number:
        if number >= current:
            target = next_start(current, count, wides, anchor)
        else:
            target = prev_start(current, count, wides, anchor)
        return target if target is not None else current
    return there[0] if there else number


def gutter(content_w, content_h, inner_left, inner_right, screen_w, screen_h):
    """`Spread.gutter`: how far each half widens into its own page's inner
    margin, in the pages' own units. Returns `(left, right)`."""
    def nothing():
        return (0.0, 0.0)
    try:
        content_w, content_h = float(content_w), float(content_h)
        screen_w, screen_h = float(screen_w), float(screen_h)
    except (TypeError, ValueError):
        return nothing()
    if content_w <= 0 or content_h <= 0 or screen_w <= 0 or screen_h <= 0:
        return nothing()
    max_left = max(0.0, float(inner_left or 0))
    max_right = max(0.0, float(inner_right or 0))
    total_max = max_left + max_right
    if total_max <= 0:
        return nothing()

    scale = min(screen_w / content_w, screen_h / content_h)
    spare = max(0.0, screen_w - content_w * scale)
    total = min(spare, total_max * scale)
    if total <= 0:
        return nothing()
    left = total * (max_left / total_max)
    # The remainder rather than a second product, as the Lua does and for the
    # reason it gives there.
    right = total - left
    return (left / scale, right / scale)


# ---------------------------------------------------------------------------
# The checks
# ---------------------------------------------------------------------------


def units_of(count, wides, anchor):
    """Walk the book by whole units, the way `drawPage`'s caller never does but
    the imposition must support."""
    units, page = [], 1
    while page <= count:
        unit = unit_for(page, count, wides, anchor)
        if not unit:
            return None
        units.append(unit)
        page = (unit[1] or unit[0]) + 1
    return units


def check_units(count, wides, anchor, fails):
    units = units_of(count, wides, anchor)
    tag = (count, tuple(sorted(wides)), anchor)
    if not units:
        fails.append(("no unit for a page in the book", tag))
        return
    expected = 1
    for unit in units:
        a, b = unit
        if a != expected:
            fails.append(("units do not tile", tag, unit, expected))
            return
        if b is not None and b != a + 1:
            fails.append(("unit is not a single or a pair", tag, unit))
            return
        expected = (b or a) + 1
    if expected != count + 1:
        fails.append(("units stop short", tag, expected, count + 1))
        return
    for (a, b) in units:
        if unit_for(a, count, wides, anchor) != (a, b):
            fails.append(("not idempotent at its first page", tag, (a, b)))
            return
        if b is not None and unit_for(b, count, wides, anchor) != (a, b):
            fails.append(("not idempotent at its second page", tag, (a, b)))
            return
        if wide(wides, a) and b is not None:
            fails.append(("a wide page was paired", tag, (a, b)))
            return
        if b is not None and wide(wides, b):
            fails.append(("a wide page was paired", tag, (a, b)))
            return


def check_walk(count, wides, anchor, fails):
    units = units_of(count, wides, anchor)
    if not units:
        return
    tag = (count, tuple(sorted(wides)), anchor)
    starts = [u[0] for u in units]
    walked, page = [], starts[0]
    while page is not None:
        walked.append(page)
        page = next_start(page, count, wides, anchor)
        if len(walked) > count + 1:
            fails.append(("forward walk does not end", tag))
            return
    if walked != starts:
        fails.append(("forward walk skipped or stalled", tag, walked, starts))
        return
    back, page = [], starts[-1]
    while page is not None:
        back.append(page)
        page = prev_start(page, count, wides, anchor)
        if len(back) > count + 1:
            fails.append(("backward walk does not end", tag))
            return
    if back != list(reversed(starts)):
        fails.append(("backward walk skipped or stalled", tag, back, starts))


def check_snap(count, wides, anchor, fails):
    """A landing never leaves the unit that contains the page; a turn does."""
    units = units_of(count, wides, anchor)
    if not units:
        return
    tag = (count, tuple(sorted(wides)), anchor)
    for i, unit in enumerate(units):
        a, b = unit
        # A landing: the pager hands over a page — a bookmark, a search hit, the
        # panel viewer crossing from one page's panels to the other's — and the unit
        # that contains it is what must be shown. This is the crossing the plugin
        # got wrong: page 5 of the spread 4+5 used to arrive on 6+7.
        for page in (a, b):
            if page is None:
                continue
            landed = spread_snap(page, a, count, wides, anchor, False)
            if landed != a:
                fails.append(("a landing left its unit", tag, page, a, landed))
                return
        # A turn: the counter crosses the unit, and the view steps a whole one.
        if b is not None:
            turned = spread_snap(b, a, count, wides, anchor, True)
            expected = units[i + 1][0] if i + 1 < len(units) else a
            if turned != expected:
                fails.append(("a turn inside the unit did not step", tag, (a, b), turned, expected))
                return


def check_offset(count, wides, anchor, fails):
    """The offset is in force in the run it is anchored in and nowhere else.

    Compared **per page** and not unit by unit: the anchored walk holds different
    units from the plain one, so lining the two lists up by index compares pages
    that were never meant to match.
    """
    tag = (count, tuple(sorted(wides)), anchor)
    if not anchor:
        # An anchor of 0 is off, which is the pairing with no anchor at all.
        for p in range(1, count + 1):
            if unit_for(p, count, wides, 0) != unit_for(p, count, wides, None):
                fails.append(("0 is not the same as no anchor", tag, p))
                return
        return
    run = run_start(anchor, wides)
    for p in range(1, count + 1):
        if run_start(p, wides) == run:
            continue
        # Outside the anchored run the pairing must be the un-anchored one. This is
        # "a wide page ends the offset by itself", the page just before the spread
        # included -- and the page just after it is the one that proves it.
        if unit_for(p, count, wides, anchor) != unit_for(p, count, wides, 0):
            fails.append(("the offset reached outside its run", tag, p,
                          unit_for(p, count, wides, anchor),
                          unit_for(p, count, wides, 0)))
            return
    if run > count:
        return
    # Inside it the run is shifted: its first page stands alone, its second starts
    # a pair. (A one-page run has nothing to shift, and is left alone.)
    first = unit_for(run, count, wides, anchor)
    if first and first[1] is not None:
        fails.append(("the anchored run's first page was paired", tag, first))
        return
    second = run + 1
    if second <= count and not wide(wides, second):
        unit = unit_for(second, count, wides, anchor)
        if not unit or unit[0] != second:
            fails.append(("the anchored run is not shifted", tag, second, unit))


def check_gutter(cw, ch, ml, mr, sw, sh, fails):
    tag = (cw, ch, ml, mr, sw, sh)
    gl, gr = gutter(cw, ch, ml, mr, sw, sh)
    # (3) never wider than the margin the page actually has.
    if gl > ml + 1e-6 or gr > mr + 1e-6:
        fails.append(("gutter grew past the page's margin", tag, gl, gr))
        return
    if gl < -1e-9 or gr < -1e-9:
        fails.append(("negative gutter", tag, gl, gr))
        return
    scale = min(sw / cw, sh / ch)
    # (2) the scale is the artwork's own fit, and the pair's own fit reproduces
    # it exactly -- this is the whole reason the two cannot disagree.
    pair_w = cw + gl + gr
    if abs(min(sw / pair_w, sh / ch) - scale) > 1e-6 * scale:
        fails.append(("the pair's fit is not the artwork's fit", tag))
        return
    # (4) never overflowing the screen.
    if pair_w * scale > sw + 1e-6:
        fails.append(("the pair overflows the screen", tag, pair_w * scale, sw))
        return
    spare, cap = sw - cw * scale, (ml + mr) * scale
    if spare <= cap:
        # (3) the gutter is the leftover, and with room to spare it fills the width.
        if abs(pair_w * scale - sw) > 1e-6 * sw:
            fails.append(("the pair does not fill the screen it could", tag))
            return
        if abs((gl + gr) - spare / scale) > 1e-6:
            fails.append(("the gutter is not the leftover", tag, gl + gr, spare / scale))
            return
    elif abs((gl + gr) * scale - cap) > 1e-6 * max(1.0, cap):
        fails.append(("the gutter did not stop at the margin", tag, (gl + gr) * scale, cap))
        return
    # A page with no inner margin contributes none of the gutter.
    if (ml == 0 and gl != 0.0) or (mr == 0 and gr != 0.0):
        fails.append(("a page with no margin gave some", tag, gl, gr))


def main():
    fails = []
    checked = 0

    # The imposition: every book up to 8 pages, every set of wide pages in it, and
    # every anchor the offset can be set to in that book (0 = off). Exhaustive,
    # 2^(1..8) sets being small enough.
    for count in range(1, 9):
        for mask in range(1 << count):
            wides = {i + 1 for i in range(count) if mask & (1 << i)}
            for anchor in [0] + list(range(1, count + 1)):
                checked += 1
                check_units(count, wides, anchor, fails)
                check_walk(count, wides, anchor, fails)
                check_offset(count, wides, anchor, fails)
                check_snap(count, wides, anchor, fails)

    # A few longer books, where a run can restart more than once -- and where the
    # anchor's run is not the first one.
    for count, wides in [(12, []), (12, {1}), (12, {2}), (12, {9}),
                         (20, {5, 9, 10}), (40, {3, 8, 21, 39}),
                         (40, set(range(2, 40, 3)))]:
        for anchor in [0, 1, 2, count // 2, count - 1, count]:
            checked += 1
            check_units(count, wides, anchor, fails)
            check_walk(count, wides, anchor, fails)
            check_offset(count, wides, anchor, fails)
            check_snap(count, wides, anchor, fails)

    # The gutter: artwork sizes, margins and screen shapes, exhaustively crossed.
    screens = [(1680, 1264), (1920, 1080), (1000, 1000), (800, 1280),
               (1264, 1680), (2560, 1600), (600, 800)]
    artworks = [(900, 1400), (1800, 1400), (1000, 1000), (700, 1000), (1400, 900)]
    margins = [0, 5, 40, 80, 200, 400]
    for (sw, sh), (cw, ch), (ml, mr) in itertools.product(screens, artworks,
                                                          itertools.product(margins, repeat=2)):
        checked += 1
        check_gutter(cw, ch, ml, mr, sw, sh, fails)

    if fails:
        for fail in fails[:20]:
            print("  ", fail)
        print(f"{len(fails)} problem(s) of {checked} checked")
        return 1

    print(f"ok -- {checked} cases, no failures")
    print_examples()
    return 0


def print_examples():
    """The rules' own examples, as walks a reader can read."""
    print("\n-- a wide page 9: the offset ends by itself --")
    show_walk(14, {9}, 0)
    show_walk(14, {9}, 1)
    print("\n-- and set again past it, on page 10 --")
    show_walk(14, {9}, 10)
    print("\n-- the gutter, on four screens (artwork 1800x1400, margins 80+80) --")
    for sw, sh, ml, mr in [(1680, 1264, 80, 80), (1920, 1080, 80, 80),
                           (1920, 1080, 0, 120), (1000, 1000, 80, 80)]:
        gl, gr = gutter(1800, 1400, ml, mr, sw, sh)
        scale = min(sw / 1800, sh / 1400)
        pair_w = 1800 + gl + gr
        print(f"  {sw}x{sh}, margins {ml}+{mr}: gutter {gl:.1f}+{gr:.1f} -> "
              f"pair {pair_w:.0f} native at {scale:.4f} = {pair_w * scale:.0f}px of {sw}px")


def show_walk(count, wides, anchor):
    units = units_of(count, wides, anchor)
    parts = [f"{a}" if b is None else f"{a}+{b}" for a, b in units]
    print(f"  pages 1..{count}, wide {sorted(wides) or '-'}, offset anchored at "
          f"{anchor or 'off'}: " + "  ".join(parts))


if __name__ == "__main__":
    sys.exit(main())
