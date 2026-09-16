"""A faithful port of meguru/panel.lua, to run the detector without a Lua
interpreter. A development aid, not part of the plugin.

Run it as `python tools/panelprobe.py <image> [flags]`. The defaults are the
shipped behaviour; each flag names an experiment:

* `loose` gives the sheared projection the straight cut's ink allowance, which
  is what the detector did before `PANEL_SHEAR_INK_RATIO` was separated out.
* `root` stops the sheared search at depth 0; `all` (the default) is the shipped
  `PANEL_SHEAR_MAX_DEPTH`.
* `noclip` lets the sheared row projection write outside the region. The shipped
  code always clips, so this is not a behaviour that exists in the plugin.
* `noveto` empties the body pass and with it the guard that refuses a split
  through a detected panel. That is the parent commit's behaviour, for an A/B on
  the same page.

**What this models and what it does not**, per CLAUDE.md's rule about mirrors:
it models the *arithmetic* of the detector - the ink predicate, the two
projections, the recursive cut, the sheared search, emitLeaf, the containment
filter, and the bodies of ink the cut is not allowed to run through - because
those are the parts a measurement can settle. It does not model
Lua's evaluation rules, which is why anything derived here about *values* is
evidence and anything derived here about *Lua semantics* is not.

Two inputs are approximations of the device's, and both are named where they
happen: the downscale is a single PIL resample where the plugin decodes at the
capped native size and resamples again, and MuPDF's own render is not modelled.
"""

import sys
from collections import Counter

import numpy as np
from PIL import Image

PANEL_SCAN_WIDTH = 480
PANEL_SCAN_MAX_CELLS = 1200000
PANEL_INK_DELTA = 40
PANEL_BG_RING_FRAC = 0.01
PANEL_BG_MID_LO, PANEL_BG_MID_HI = 32, 224
PANEL_SEPARATOR_MIN_LUMA = 245
PANEL_SEPARATOR_FRAC = 0.80
PANEL_SEPARATOR_EDGE_FRAC = 0.03
PANEL_GUTTER_INK_RATIO = 0.005
PANEL_GUTTER_RATIO = 0.004
PANEL_MIN_SIDE_FRAC = 0.03
PANEL_MIN_AREA_FRAC = 0.005
PANEL_SLIVER_ASPECT = 4
PANEL_SLIVER_INK_FRAC = 0.02
PANEL_MAX_DEPTH = 6
PANEL_MAX_PANELS = 40
PANEL_SHEAR_SLOPES = [0.015, -0.015, 0.030, -0.030, 0.045, -0.045,
                      0.060, -0.060, 0.075, -0.075, 0.090, -0.090,
                      0.105, -0.105, 0.120, -0.120, 0.135, -0.135,
                      0.150, -0.150]
PANEL_SHEAR_MAX_DEPTH = 4
PANEL_SHEAR_TRIGGER = 0.35
PANEL_SHEAR_STEP = 2
PANEL_SHEAR_INK_RATIO = 0
SINGLE_RATIO, PAGE_COV_MIN, COV_MIN = 0.6, 0.4, 0.5

# The bodies of ink, and the evidence a panel's frame leaves. These five are the
# reference's values, unchanged; only the prefix is this file's, so that what they
# feed is not mistaken for a detector. They feed a *veto*: a split whose band runs
# through the box of a body that shows a frame is refused, because a full-width
# empty band inside a panel's own drawing is not a separator. See `blocked`.
PANEL_BODY_MIN_SIDE_FRAC = 0.02
PANEL_BODY_MIN_AREA_FRAC = 0.002
PANEL_BODY_FRAME_SUPPORT = 0.80
PANEL_BODY_FRAME_TOL_FRAC = 0.003
PANEL_BODY_FRAME_MIN = 1


def luma_array(im):
    """Image.rasterFor's luma: Rec.601, and not the mean of three channels."""
    a = np.asarray(im.convert("RGB"), dtype=np.float64)
    r, g, b = a[:, :, 0], a[:, :, 1], a[:, :, 2]
    return np.floor((4898 * r + 9618 * g + 1869 * b) / 16384)


def has_white_separator(L):
    h, w = L.shape
    xm = max(1, int(w * PANEL_SEPARATOR_EDGE_FRAC))
    ym = max(1, int(h * PANEL_SEPARATOR_EDGE_FRAC))
    row_req = -(-int(w * PANEL_SEPARATOR_FRAC) // 1)
    col_req = -(-int(h * PANEL_SEPARATOR_FRAC) // 1)
    row_ok = (L >= PANEL_SEPARATOR_MIN_LUMA).sum(axis=1)
    for y in range(ym, h - ym):
        if row_ok[y] >= row_req:
            return True
    col_ok = (L >= PANEL_SEPARATOR_MIN_LUMA).sum(axis=0)
    for x in range(xm, w - xm):
        if col_ok[x] >= col_req:
            return True
    return False


def background_for(L):
    h, w = L.shape
    ring = max(1, int(min(w, h) * PANEL_BG_RING_FRAC))
    mask = np.zeros((h, w), dtype=bool)
    mask[:ring, :] = True
    mask[h - ring:, :] = True
    mask[ring:h - ring, :ring] = True
    mask[ring:h - ring, w - ring:] = True
    vals = np.clip(L[mask], 0, 255).astype(int)
    bins = np.bincount(vals, minlength=256)
    half = vals.size / 2
    cum = 0
    for v in range(256):
        cum += bins[v]
        if cum >= half:
            if PANEL_BG_MID_LO <= v < PANEL_BG_MID_HI and has_white_separator(L):
                return 255
            return v
    return 255


def build_ink_map(L, bg):
    return (np.abs(L - bg) > PANEL_INK_DELTA).astype(np.uint8)


# ---------------------------------------------------------------------------
# Bodies of ink, and the veto they arm
# ---------------------------------------------------------------------------

def line_support(values, first, last, tolerance):
    """What fraction of one side is supported by a single straight line.

    Ported from 83a3b7a's `lineSupport`, values and sampling unchanged. It is the
    evidence that a *tilted* frame is a frame: a boundary drawn at six degrees is
    still a straight line, where a curved face outline is not one over most of its
    extent. `tolerance` is in cells, and forgives a stroke being two cells thick.
    """
    span = last - first
    if span <= 0:
        return 0.0
    best = 0.0
    for a in range(5):
        for b in range(a + 3, 9):
            i = first + int(span * a / 8)
            j = first + int(span * b / 8)
            slope = (values[j] - values[i]) / (j - i)
            if abs(slope) <= 0.35:
                count = 0
                for k in range(first, last + 1):
                    if abs(values[k] - values[i] - (k - i) * slope) <= tolerance:
                        count += 1
                ratio = count / (span + 1)
                if ratio > best:
                    best = ratio
                    if best >= PANEL_BODY_FRAME_SUPPORT:
                        return best
    return best


def frame_sides(ys, xs, w, h, box, tolerance):
    """How many of the body's four sides are a straight line.

    The left and right sides are the body's own leftmost and rightmost cell in each
    row, the top and bottom its topmost and bottommost in each column: reading a
    side as an extreme per line is what makes a slanted one read as a line rather
    than as a wall. Absolute indices, as in the Lua - the arrays are sized to the
    map and only the box's span is read back.
    """
    left = [float("inf")] * h
    right = [-1] * h
    top = [float("inf")] * w
    bottom = [-1] * w
    for y, x in zip(ys, xs):
        if x < left[y]:
            left[y] = x
        if x > right[y]:
            right[y] = x
        if y < top[x]:
            top[x] = y
        if y > bottom[x]:
            bottom[x] = y
    bx, by, bw, bh = box
    sides = 0
    for values, first, last in ((left, by, by + bh - 1), (right, by, by + bh - 1),
                                (top, bx, bx + bw - 1), (bottom, bx, bx + bw - 1)):
        if line_support(values, first, last, tolerance) >= PANEL_BODY_FRAME_SUPPORT:
            sides += 1
    return sides


def collect_bodies(data, min_side_frac, min_area):
    """Every substantial 8-connected body of ink, as a box plus its frame evidence.

    A port of `collectComponents` and the frame evidence it carries, and only of
    that: the containment rule, the small-box `hasFrame` test, the joining of
    floating bodies and the tier grouping are all left behind, because a veto needs
    to know where a panel's box *is* and not which boxes are panels in the end.

    Bodies below either size floor are dropped before any evidence is computed,
    which is what keeps the cost proportional to the page's real structure rather
    than to its noise - and what keeps a *stipple* of small ink from arming a veto.
    """
    h, w = data.shape
    flat = data.reshape(-1)
    seen = bytearray(w * h)
    # Sized to the ink count and not to the cell count: a cell enters the queue when
    # it is first marked seen, once, so one body can never put more in it than the
    # page has ink. The plugin does the same, for the memory.
    queue = [0] * max(1, int(flat.sum()))
    tolerance = max(1, min(w, h) * PANEL_BODY_FRAME_TOL_FRAC)
    bodies = []
    for index in range(w * h):
        if flat[index] == 0 or seen[index]:
            continue
        seen[index] = 1
        queue[0] = index
        head, tail = 0, 1
        left, right, top, bottom = w, 0, h, 0
        while head < tail:
            position = queue[head]
            head += 1
            y, x = divmod(position, w)
            if x < left:
                left = x
            if x > right:
                right = x
            if y < top:
                top = y
            if y > bottom:
                bottom = y
            for ny in range(max(0, y - 1), min(h - 1, y + 1) + 1):
                row = ny * w
                for neighbour in range(row + max(0, x - 1),
                                       row + min(w - 1, x + 1) + 1):
                    if not seen[neighbour] and flat[neighbour]:
                        seen[neighbour] = 1
                        queue[tail] = neighbour
                        tail += 1
        bw, bh = right - left + 1, bottom - top + 1
        if bw < w * min_side_frac or bh < h * min_side_frac or bw * bh < min_area:
            continue
        ys = [position // w for position in queue[:tail]]
        xs = [position - (position // w) * w for position in queue[:tail]]
        bodies.append({"x": left, "y": top, "w": bw, "h": bh,
                       "sides": frame_sides(ys, xs, w, h,
                                            (left, top, bw, bh), tolerance)})
    return bodies


def blocked(ctx, x0, x1, y0, y1, axis):
    """The body whose interior this band runs through, or None.

    `x0..x1` and `y0..y1` are the band's own extent in cells, inclusive, and `axis`
    says which of the two the cut would separate along. The band has to lie
    *strictly* inside the body on that axis - a band at the body's own edge is the
    frame, and cutting there is what the cut is for - and the body has to span the
    region on the other, so that a body a node merely clips at its edge does not
    veto a split of that node.

    That second condition is the conservative one, and the price is named rather
    than hidden: two framed panels side by side with a white band across both leave
    neither body spanning the region, so no veto fires and the cut still runs
    through them. Widening it to a plain overlap catches that case and refuses more
    legitimate splits with it.
    """
    for body in ctx.bodies:
        if axis == "rows":
            inside = body["y"] < y0 and body["y"] + body["h"] - 1 > y1
            spans = body["x"] <= x0 and body["x"] + body["w"] - 1 >= x1
        else:
            inside = body["x"] < x0 and body["x"] + body["w"] - 1 > x1
            spans = body["y"] <= y0 and body["y"] + body["h"] - 1 >= y1
        if inside and spans:
            return body
    return None


class Ctx:
    def __init__(self, w, h, manga=True):
        self.w, self.h = w, h
        self.rows = [0] * h
        self.cols = [0] * w
        self.ink_ratio = PANEL_GUTTER_INK_RATIO
        min_dim = min(w, h)
        self.min_gutter = max(1, int(min_dim * PANEL_GUTTER_RATIO))
        self.min_side = max(4, int(min_dim * PANEL_MIN_SIDE_FRAC))
        self.min_area = int(w * h * PANEL_MIN_AREA_FRAC)
        self.sliver_ink = 0
        self.shear_step = PANEL_SHEAR_STEP
        self.slope_hint = None
        self.shear_searches = 0
        self.shear_splits = 0
        # The framed bodies a split may not run through, and how many splits they
        # took. Empty means no veto, which is the parent commit's behaviour.
        self.bodies = []
        self.vetoes = 0


def project(data, x0, y0, x1, y1, rows, cols):
    """Inclusive bounds, absolute indices - the reference's shape."""
    w = data.shape[1]
    for x in range(x0, x1 + 1):
        cols[x] = 0
    for y in range(y0, y1 + 1):
        row = data[y]
        cnt = 0
        for x in range(x0, x1 + 1):
            if row[x]:
                cnt += 1
                cols[x] += 1
        rows[y] = cnt


def trim_range(proj, frm, to):
    while frm <= to and proj[frm] == 0:
        frm += 1
    while to >= frm and proj[to] == 0:
        to -= 1
    return frm, to


def find_widest_gutter(proj, frm, to, span, ink_ratio, min_length):
    max_ink = span * ink_ratio
    best = (None, None, 0)
    run_start = None
    i = frm
    while i <= to:
        if proj[i] <= max_ink:
            if run_start is None:
                run_start = i
        else:
            if run_start is not None and run_start > frm:
                length = i - run_start
                if length >= min_length and length > best[2]:
                    best = (run_start, i - 1, length)
            run_start = None
        i += 1
    return best


def collect_gutters(proj, frm, to, span, ink_ratio, min_length):
    max_ink = span * ink_ratio
    guts = []
    run_start = None
    i = frm
    while i <= to:
        if proj[i] <= max_ink:
            if run_start is None:
                run_start = i
        else:
            if run_start is not None and run_start > frm:
                length = i - run_start
                if length >= min_length:
                    guts.append((run_start, i - 1, length))
            run_start = None
        i += 1
    guts.sort(key=lambda g: -g[2])
    return guts


def project_cols_sheared(data, x0, y0, x1, y1, slope, cols, step):
    for x in range(x0, x1 + 1):
        cols[x] = 0
    ymid = (y0 + y1) // 2
    for y in range(y0, y1 + 1, step):
        shift = int(np.floor(slope * (y - ymid) + 0.5))
        row = data[y]
        lo = max(x0, x0 + shift)
        hi = min(x1, x1 + shift)
        for x in range(lo, hi + 1):
            if row[x]:
                t = x - shift
                cols[t] += 1


def project_rows_sheared(data, x0, y0, x1, y1, slope, rows, step):
    for y in range(y0, y1 + 1):
        rows[y] = 0
    xmid = (x0 + x1) // 2
    for y in range(y0, y1 + 1):
        row = data[y]
        for x in range(x0, x1 + 1, step):
            if row[x]:
                t = y - int(np.floor(slope * (x - xmid) + 0.5))
                if NOCLIP:
                    if 0 <= t < len(rows):
                        rows[t] += 1
                elif y0 <= t <= y1:
                    rows[t] += 1


def min_in_range(proj, frm, to):
    return min(proj[frm:to + 1])


def try_slope(data, left, top, right, bottom, ctx, slope):
    """Mirrors meguru/panel.lua's trySlope: the cut is the middle of the empty
    run the sheared projection found, not the band the run maps back to."""
    width = right - left + 1
    height = bottom - top + 1
    step = ctx.shear_step
    ratio = ctx.ink_ratio if SHEAR_LOOSE else PANEL_SHEAR_INK_RATIO
    project_cols_sheared(data, left, top, right, bottom, slope, ctx.cols, step)
    for g in collect_gutters(ctx.cols, left, right, height / step,
                             ratio, ctx.min_gutter):
        split = (g[0] + g[1]) // 2
        if split > left and split < right:
            return "cols", split
    project_rows_sheared(data, left, top, right, bottom, slope, ctx.rows, step)
    for g in collect_gutters(ctx.rows, top, bottom, width / step,
                             ratio, ctx.min_gutter):
        split = (g[0] + g[1]) // 2
        if split > top and split < bottom:
            return "rows", split
    return None


def find_sheared_split(data, left, top, right, bottom, ctx):
    if ctx.slope_hint is not None:
        r = try_slope(data, left, top, right, bottom, ctx, ctx.slope_hint)
        if r:
            return r
    for slope in PANEL_SHEAR_SLOPES:
        if slope != ctx.slope_hint:
            r = try_slope(data, left, top, right, bottom, ctx, slope)
            if r:
                ctx.slope_hint = slope
                return r
    return None


def emit_leaf(x0, y0, x1, y1, ink, ctx, out, edges):
    w, h = x1 - x0 + 1, y1 - y0 + 1
    if w < ctx.min_side or h < ctx.min_side or w * h < ctx.min_area:
        return
    long_side, short_side = (w, h) if w >= h else (h, w)
    if long_side >= short_side * PANEL_SLIVER_ASPECT and ink < ctx.sliver_ink:
        return
    out.append((x0, y0, w, h, ink, edges))


TRACE = False
NOCLIP = False
NOVETO = False
SHEAR_DEPTH = 'all'
# True: give the sheared projection the straight cut's ink ratio instead of
# PANEL_SHEAR_INK_RATIO. That is the comparison that found the bug
# PANEL_SHEAR_INK_RATIO was split out for; it is an experiment, not a behaviour.
SHEAR_LOOSE = False


def _t(depth, *a):
    if TRACE:
        print("  " * depth + "| " + " ".join(str(v) for v in a))


def cut(data, x0, y0, x1, y1, edges, depth, ctx, out):
    if x1 < x0 or y1 < y0 or len(out) >= PANEL_MAX_PANELS:
        return
    project(data, x0, y0, x1, y1, ctx.rows, ctx.cols)
    top, bottom = trim_range(ctx.rows, y0, y1)
    left, right = trim_range(ctx.cols, x0, x1)
    if bottom < top or right < left:
        return
    region_ink = sum(ctx.rows[top:bottom + 1])
    el = edges["l"] if left == x0 else (left, 0.0)
    er = edges["r"] if right == x1 else (right, 0.0)
    et = edges["t"] if top == y0 else (top, 0.0)
    ebo = edges["bo"] if bottom == y1 else (bottom, 0.0)
    _t(depth, f"cut d{depth} region {x0},{y0}..{x1},{y1} trimmed {left},{top}..{right},{bottom}")
    if depth < PANEL_MAX_DEPTH:
        width, height = right - left + 1, bottom - top + 1
        row = find_widest_gutter(ctx.rows, top, bottom, width,
                                 ctx.ink_ratio, ctx.min_gutter)
        col = find_widest_gutter(ctx.cols, left, right, height,
                                 ctx.ink_ratio, ctx.min_gutter)
        row_len, col_len = row[2], col[2]
        # A row of a panel's own drawing that happens to be empty across the region
        # is the one thing a projection cannot tell from a separator, so the bodies
        # say it instead: a split whose band runs through a framed body's box is
        # refused, and the region is that panel rather than two of them.
        row_hit = blocked(ctx, left, right, row[0], row[1], "rows") if row_len > 0 else None
        col_hit = blocked(ctx, col[0], col[1], top, bottom, "cols") if col_len > 0 else None
        if row_hit:
            ctx.vetoes += 1
            _t(depth, f"  veto rows {row[0]}..{row[1]} runs through body "
                      f"{row_hit['x']},{row_hit['y']} {row_hit['w']}x{row_hit['h']}")
        if col_hit:
            ctx.vetoes += 1
            _t(depth, f"  veto cols {col[0]}..{col[1]} runs through body "
                      f"{col_hit['x']},{col_hit['y']} {col_hit['w']}x{col_hit['h']}")
        row_ok = row_len > 0 and not row_hit
        col_ok = col_len > 0 and not col_hit
        _t(depth, f"  straight rows={row[0]}..{row[1]} len={row_len}"
                  f"  cols={col[0]}..{col[1]} len={col_len}")
        if row_ok and (not col_ok or row_len >= col_len):
            cut(data, left, top, right, row[0] - 1,
                {"l": el, "r": er, "t": et, "bo": (row[0] - 1, 0.0)}, depth + 1, ctx, out)
            cut(data, left, row[1] + 1, right, bottom,
                {"l": el, "r": er, "t": (row[1] + 1, 0.0), "bo": ebo}, depth + 1, ctx, out)
            return
        elif col_ok:
            cut(data, left, top, col[0] - 1, bottom,
                {"l": el, "r": (col[0] - 1, 0.0), "t": et, "bo": ebo}, depth + 1, ctx, out)
            cut(data, col[1] + 1, top, right, bottom,
                {"l": (col[1] + 1, 0.0), "r": er, "t": et, "bo": ebo}, depth + 1, ctx, out)
            return
        # A veto on either axis ends the decomposition here rather than turning to
        # the slant: if an empty line ran through a detected panel, this region *is*
        # that panel, and a sheared split of it is the same mistake at an angle.
        if row_len == 0 and col_len == 0 and depth <= (
                (0 if SHEAR_DEPTH == 'root' else PANEL_SHEAR_MAX_DEPTH)
                ) and (min_in_range(ctx.cols, left, right) <= height * PANEL_SHEAR_TRIGGER
                       or min_in_range(ctx.rows, top, bottom) <= width * PANEL_SHEAR_TRIGGER):
            ctx.shear_searches += 1
            r = find_sheared_split(data, left, top, right, bottom, ctx)
            _t(depth, f"  shear -> {r}")
            if r:
                axis, split = r
                slope = ctx.slope_hint
                # The band the line sweeps, which is what has to be clear of a body.
                if axis == "cols":
                    ymid = (top + bottom) // 2
                    an, ax = sorted((split + slope * (top - ymid),
                                     split + slope * (bottom - ymid)))
                    hit = blocked(ctx, int(np.floor(an)), int(np.ceil(ax)), top, bottom, "cols")
                else:
                    xmid = (left + right) // 2
                    an, ax = sorted((split + slope * (left - xmid),
                                     split + slope * (right - xmid)))
                    hit = blocked(ctx, left, right, int(np.floor(an)), int(np.ceil(ax)), "rows")
                if hit:
                    ctx.vetoes += 1
                    _t(depth, f"  veto shear {axis} {split} runs through body "
                              f"{hit['x']},{hit['y']} {hit['w']}x{hit['h']}")
                else:
                    ctx.shear_splits += 1
                    if axis == "cols":
                        ymid = (top + bottom) // 2
                        line = (split - slope * ymid, slope)
                        cut(data, left, top, split, bottom,
                            {"l": el, "r": line, "t": et, "bo": ebo}, depth + 1, ctx, out)
                        cut(data, split + 1, top, right, bottom,
                            {"l": line, "r": er, "t": et, "bo": ebo}, depth + 1, ctx, out)
                    else:
                        xmid = (left + right) // 2
                        line = (split - slope * xmid, slope)
                        cut(data, left, top, right, split,
                            {"l": el, "r": er, "t": et, "bo": line}, depth + 1, ctx, out)
                        cut(data, left, split + 1, right, bottom,
                            {"l": el, "r": er, "t": line, "bo": ebo}, depth + 1, ctx, out)
                    return
    _t(depth, f"  EMIT {left},{top} {right-left+1}x{bottom-top+1} ink={region_ink}")
    emit_leaf(left, top, right, bottom, region_ink, ctx, out,
              {"l": el, "r": er, "t": et, "bo": ebo})


def detect(path):
    im = Image.open(path)
    im.load()
    native_w, native_h = im.size
    scale = min(1.0, PANEL_SCAN_WIDTH / native_w,
                (PANEL_SCAN_MAX_CELLS / (native_w * native_h)) ** 0.5)
    sw = max(2, int(native_w * scale + 0.5))
    sh = max(2, int(native_h * scale + 0.5))
    scan = im if scale >= 1 else im.resize((sw, sh), Image.BILINEAR)
    L = luma_array(scan)
    bg = background_for(L)
    data = build_ink_map(L, bg)
    ink = int(data.sum())
    print(f"native {native_w}x{native_h}  scan {sw}x{sh}  bg={bg}  "
          f"ink={ink} ({100.0*ink/(sw*sh):.1f}%)")

    ctx = Ctx(sw, sh)
    ctx.sliver_ink = int(ink * PANEL_SLIVER_INK_FRAC)
    print(f"min_side={ctx.min_side} min_area={ctx.min_area} "
          f"min_gutter={ctx.min_gutter} sliver_ink={ctx.sliver_ink}")
    bodies = [] if NOVETO else collect_bodies(data, PANEL_BODY_MIN_SIDE_FRAC,
                                              sw * sh * PANEL_BODY_MIN_AREA_FRAC)
    ctx.bodies = [b for b in bodies if b["sides"] >= PANEL_BODY_FRAME_MIN]
    print(f"bodies {len(bodies)} -> framed {len(ctx.bodies)}"
          + ("".join(f"\n    body {b['x']},{b['y']} {b['w']}x{b['h']} sides={b['sides']}"
                     for b in bodies if b["sides"] >= PANEL_BODY_FRAME_MIN)))
    cells = []
    global TRACE
    TRACE = True
    cut(data, 0, 0, sw - 1, sh - 1,
        {"l": (0.0, 0.0), "r": (float(sw - 1), 0.0),
         "t": (0.0, 0.0), "bo": (float(sh - 1), 0.0)}, 0, ctx, cells)
    TRACE = False
    print(f"cut -> {len(cells)} leaves, shear {ctx.shear_splits}/{ctx.shear_searches}"
          f", vetoed candidates {ctx.vetoes}")

    sx, sy = native_w / sw, native_h / sh

    def planes_for(c):
        """Cells -> the four half-planes in native page coordinates, exactly as
        segment() builds them, one-cell expansion included."""
        e = c[5]
        x0n, x1n = c[0] * sx, (c[0] + c[2] - 1) * sx
        y0n, y1n = c[1] * sy, (c[1] + c[3] - 1) * sy
        l = (e["l"][0] * sx - sx, e["l"][1] * sx / sy)
        r = (e["r"][0] * sx + sx, e["r"][1] * sx / sy)
        t = (e["t"][0] * sy - sy, e["t"][1] * sy / sx)
        bo = (e["bo"][0] * sy + sy, e["bo"][1] * sy / sx)
        left = max(0.0, min(l[0] + l[1] * y0n, l[0] + l[1] * y1n))
        right = min(float(native_w), max(r[0] + r[1] * y0n, r[0] + r[1] * y1n))
        top = max(0.0, min(t[0] + t[1] * x0n, t[0] + t[1] * x1n))
        bottom = min(float(native_h), max(bo[0] + bo[1] * x0n, bo[0] + bo[1] * x1n))
        return [(left, top, right, bottom),
                [(-1.0, l[1], l[0]), (1.0, -r[1], -r[0]),
                 (t[1], -1.0, t[0]), (-bo[1], 1.0, -bo[0])]]

    def show(tag, lst):
        for i, c in enumerate(lst):
            box, p = planes_for(c)
            print(f"  {tag}[{i}] cells {c[0]},{c[1]} {c[2]}x{c[3]} ink={c[4]} "
                  f"({100.0*c[4]/(c[2]*c[3]):.1f}%)  "
                  f"page x{100.0*c[0]/sw:.1f}%..{100.0*(c[0]+c[2])/sw:.1f}% "
                  f"y{100.0*c[1]/sh:.1f}%..{100.0*(c[1]+c[3])/sh:.1f}%")
            print("        crop %.0f,%.0f %.0fx%.0f  edge slopes"
                  "  l%+.3f r%+.3f t%+.3f b%+.3f"
                  % (box[0], box[1], box[2] - box[0], box[3] - box[1],
                     p[0][1], p[1][1], p[2][0], p[3][0]))
    show("raw", cells)

    kept = []
    for i, c in enumerate(cells):
        dropped = False
        for j, o in enumerate(cells):
            if (j != i and o[2] * o[3] > c[2] * c[3]
                    and c[0] >= o[0] and c[1] >= o[1]
                    and c[0] + c[2] <= o[0] + o[2]
                    and c[1] + c[3] <= o[1] + o[3]):
                dropped = True
                print(f"  -> raw[{i}] lies inside raw[{j}]; dropped")
                break
        if not dropped:
            kept.append(c)
    print(f"containment filter -> {len(kept)}")
    show("kept", kept)


if __name__ == "__main__":
    # Slots, not positions: every flag is named, so they can be given in any
    # order and none of them can be "present but empty". The old parsing read
    # sys.argv[4] whenever a third argument existed, which crashed on
    # `... noclip` and silently ignored the word it was documented to read.
    args = sys.argv[2:]
    unknown = [a for a in args
               if a not in ("noclip", "root", "all", "loose", "noveto")]
    if unknown:
        raise SystemExit("unknown argument(s): %s\n"
                         "usage: panelprobe.py <image> [noclip] [root|all] [loose] [noveto]"
                         % " ".join(unknown))
    NOCLIP = "noclip" in args
    NOVETO = "noveto" in args
    if "root" in args:
        SHEAR_DEPTH = "root"
    elif "all" in args:
        SHEAR_DEPTH = "all"
    SHEAR_LOOSE = "loose" in args
    detect(sys.argv[1])
