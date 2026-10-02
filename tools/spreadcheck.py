"""A faithful port of meguru/spread.lua, to run the two-page imposition and the
gutter arithmetic without a Lua interpreter. A development aid, not part of the
plugin.

Run it as `python tools/spreadcheck.py`. It checks **properties**, not fixtures:
the rules the module is specified by, over every combination of a small book's
wide pages and both offset answers, plus a grid for the gutter. Then it prints a
few walks, because the point of the imposition is what a reader sees and a
printed walk is the only way to read that here.

What it checks, and why each one is a property rather than an example:

* **The units tile the book exactly** — for chapter lengths 1..8 crossed with
  *every* set of wide pages and both offsets, walking page 1 to the end by whole
  units lands on every page exactly once, in order, and every unit is a single
  page or an adjacent pair. This is the whole of "which pages are shown
  together": a gap, an overlap or a pair that spans a wide page fails it.
* **Asking from either page of a pair answers the same pair** — the reader's page
  counter may stand on either one, and the pair drawn must not depend on which.
* **Turning walks the units** — `next_start` from the first unit visits every
  unit start in order and then answers None at the end of the book; `prev_start`
  does the mirror. A stall or a skip fails it, including the end-of-book case the
  reader's own page counter cannot see (the last unit being a pair).
* **The gutter's four rules** — over a grid of artwork sizes, margins and screen
  shapes: never wider than the page's own margin, never a term in the scale (the
  artwork's fit is reproduced exactly by the pair's own fit), the pair never
  overflows the screen, and the spare width is what the gutter takes when the
  margin allows it.
* **The stated examples** — the ones the rules were written from: a wide page 9
  pair-matching from 10, the offset pairing 6+7, and the offset *with* a wide
  page leaving two single pages in a row.

**What this models, and what it does not**, per `docs/development.md`'s rule about
mirrors. It models the module's *arithmetic* — the run walk, the offset's
domain and the four gutter sentences — because that is what a check can settle.
It does not model Lua's evaluation rules, and two of them are present in the code
it mirrors: `offsetOn` folds `and 1 or 0` (safe only because `1` is truthy — a
change to a value that could be `false` would not be mirrored here), and the wide
list is searched as a binary search where this only asks membership and the
greatest element below. A divergence in either is a divergence this cannot see.
"""

import itertools
import sys

# ---------------------------------------------------------------------------
# meguru/spread.lua, ported
# ---------------------------------------------------------------------------


def offset_on(offset):
    """`Spread`'s `offsetOn`: 0 and "0" are off, and both are *truthy* in Lua, so
    the domain is compared rather than tested."""
    return offset is True or offset == 1 or offset == "1"


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


def unit_for(n, count, wides, offset):
    """`Spread.unitFor`: the unit `n` is shown in — `(a, None)` alone, `(a, b)`
    for a pair — or None outside the book."""
    if count is None or n is None or n < 1 or n > count:
        return None
    wides = wides or []
    if wide(wides, n):
        return (n, None)
    below = last_wide_below(wides, n)
    run = (below + 1) if below is not None else 1
    # The offset leaves the first page of *every* run standing alone, a wide
    # page's run included.
    first = 1 if offset_on(offset) else 0
    idx = n - run
    if idx < first:
        return (n, None)
    if ((idx - first) % 2) != 0:
        return (n - 1, n)
    nxt = n + 1
    if nxt > count or wide(wides, nxt):
        return (n, None)
    return (n, nxt)


def next_start(n, count, wides, offset):
    """`Spread.nextStart`: the page a forward turn from `n` lands on."""
    unit = unit_for(n, count, wides, offset)
    if not unit:
        return None
    a, b = unit
    after = (b + 1) if b else (a + 1)
    if after > count:
        return None
    nxt = unit_for(after, count, wides, offset)
    return nxt[0] if nxt else None


def prev_start(n, count, wides, offset):
    """`Spread.prevStart`: the page a backward turn from `n` lands on."""
    unit = unit_for(n, count, wides, offset)
    if not unit or unit[0] <= 1:
        return None
    prev = unit_for(unit[0] - 1, count, wides, offset)
    return prev[0] if prev else None


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


def units_of(count, wides, offset):
    """Walk the book by whole units, the way `drawPage`'s caller never does but
    the imposition must support."""
    units, page = [], 1
    while page <= count:
        unit = unit_for(page, count, wides, offset)
        if not unit:
            return None
        units.append(unit)
        page = (unit[1] or unit[0]) + 1
    return units


def check_units(count, wides, offset, fails):
    units = units_of(count, wides, offset)
    tag = (count, tuple(sorted(wides)), offset)
    if not units:
        fails.append(("no unit for a page in the book", tag))
        return
    # The tile: every page exactly once, in order, and no unit wider than a pair.
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
    # And what the module answers from either page of a unit is that unit.
    for (a, b) in units:
        if unit_for(a, count, wides, offset) != (a, b):
            fails.append(("not idempotent at its first page", tag, (a, b)))
            return
        if b is not None and unit_for(b, count, wides, offset) != (a, b):
            fails.append(("not idempotent at its second page", tag, (a, b)))
            return
        # A wide page is never one half of a pair, and never a pair's partner.
        if wide(wides, a) and b is not None:
            fails.append(("a wide page was paired", tag, (a, b)))
            return
        if b is not None and wide(wides, b):
            fails.append(("a wide page was paired", tag, (a, b)))
            return


def check_walk(count, wides, offset, fails):
    units = units_of(count, wides, offset)
    if not units:
        return
    tag = (count, tuple(sorted(wides)), offset)
    starts = [u[0] for u in units]
    walked, page = [], starts[0]
    while page is not None:
        walked.append(page)
        page = next_start(page, count, wides, offset)
        if len(walked) > count + 1:
            fails.append(("forward walk does not end", tag))
            return
    if walked != starts:
        fails.append(("forward walk skipped or stalled", tag, walked, starts))
        return
    back, page = [], starts[-1]
    while page is not None:
        back.append(page)
        page = prev_start(page, count, wides, offset)
        if len(back) > count + 1:
            fails.append(("backward walk does not end", tag))
            return
    if back != list(reversed(starts)):
        fails.append(("backward walk skipped or stalled", tag, back, starts))


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

    # The imposition: every book up to 8 pages, every set of wide pages in it,
    # both offsets. 2^(1..8) sets is small enough to be exhaustive.
    for count in range(1, 9):
        for mask in range(1 << count):
            wides = {i + 1 for i in range(count) if mask & (1 << i)}
            for offset in (0, 1):
                checked += 1
                check_units(count, wides, offset, fails)
                check_walk(count, wides, offset, fails)

    # A few longer books, where a run can restart more than once.
    for count, wides in [(12, []), (12, {1}), (12, {2}), (12, {9}),
                         (20, {5, 9, 9 + 1}), (40, {3, 8, 21, 39}),
                         (40, set(range(2, 40, 3)))]:
        for offset in (0, 1):
            checked += 1
            check_units(count, wides, offset, fails)
            check_walk(count, wides, offset, fails)

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
    """The rules' own examples, as a walk a reader can read."""
    print("\n-- a wide page 9, offset off --")
    show_walk(14, {9}, 0)
    print("\n-- the same book, offset on --")
    show_walk(14, {9}, 1)
    print("\n-- the gutter, on four screens (artwork 1800x1400, margins 80+80) --")
    for sw, sh, ml, mr in [(1680, 1264, 80, 80), (1920, 1080, 80, 80),
                           (1920, 1080, 0, 120), (1000, 1000, 80, 80)]:
        gl, gr = gutter(1800, 1400, ml, mr, sw, sh)
        scale = min(sw / 1800, sh / 1400)
        pair_w = 1800 + gl + gr
        print(f"  {sw}x{sh}, margins {ml}+{mr}: gutter {gl:.1f}+{gr:.1f} -> "
              f"pair {pair_w:.0f} native at {scale:.4f} = {pair_w * scale:.0f}px of {sw}px")


def show_walk(count, wides, offset):
    units = units_of(count, wides, offset)
    parts = []
    for a, b in units:
        parts.append(f"{a}" if b is None else f"{a}+{b}")
    print(f"  pages 1..{count}, wide {sorted(wides) or '-'}, offset {offset}: "
          + "  ".join(parts))


if __name__ == "__main__":
    sys.exit(main())
