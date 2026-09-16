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

**What this models and what it does not**, per CLAUDE.md's rule about mirrors:
it models the *arithmetic* of the detector - the ink predicate, the two
projections, the recursive cut, the sheared search, emitLeaf and the containment
filter - because those are the parts a measurement can settle. It does not model
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
PANEL_GUTTER_RATIO = 0.005
PANEL_MIN_SIDE_FRAC = 0.03
PANEL_MIN_AREA_FRAC = 0.005
PANEL_SLIVER_ASPECT = 4
PANEL_SLIVER_INK_FRAC = 0.02
PANEL_MAX_DEPTH = 6
PANEL_MAX_PANELS = 40
PANEL_SHEAR_SLOPES = [0.035, -0.035, 0.061, -0.061, 0.087, -0.087,
                      0.115, -0.115, 0.141, -0.141]
PANEL_SHEAR_MAX_DEPTH = 4
PANEL_SHEAR_TRIGGER = 0.35
PANEL_SHEAR_STEP = 2
PANEL_SHEAR_INK_RATIO = 0
SINGLE_RATIO, PAGE_COV_MIN, COV_MIN = 0.6, 0.4, 0.5


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


class Ctx:
    def __init__(self, w, h, manga=True):
        self.w, self.h = w, h
        self.rows = [0] * h
        self.cols = [0] * w
        self.ink_ratio = PANEL_GUTTER_INK_RATIO
        min_dim = min(w, h)
        self.min_gutter = max(2, int(min_dim * PANEL_GUTTER_RATIO))
        self.min_side = max(4, int(min_dim * PANEL_MIN_SIDE_FRAC))
        self.min_area = int(w * h * PANEL_MIN_AREA_FRAC)
        self.sliver_ink = 0
        self.shear_step = PANEL_SHEAR_STEP
        self.slope_hint = None
        self.shear_searches = 0
        self.shear_splits = 0


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


def emit_leaf(x0, y0, x1, y1, ink, ctx, out):
    w, h = x1 - x0 + 1, y1 - y0 + 1
    if w < ctx.min_side or h < ctx.min_side or w * h < ctx.min_area:
        return
    long_side, short_side = (w, h) if w >= h else (h, w)
    if long_side >= short_side * PANEL_SLIVER_ASPECT and ink < ctx.sliver_ink:
        return
    out.append((x0, y0, w, h, ink))


TRACE = False
NOCLIP = False
SHEAR_DEPTH = 'all'
# True: give the sheared projection the straight cut's ink ratio instead of
# PANEL_SHEAR_INK_RATIO. That is the comparison that found the bug
# PANEL_SHEAR_INK_RATIO was split out for; it is an experiment, not a behaviour.
SHEAR_LOOSE = False


def _t(depth, *a):
    if TRACE:
        print("  " * depth + "| " + " ".join(str(v) for v in a))


def cut(data, x0, y0, x1, y1, depth, ctx, out):
    if x1 < x0 or y1 < y0 or len(out) >= PANEL_MAX_PANELS:
        return
    project(data, x0, y0, x1, y1, ctx.rows, ctx.cols)
    top, bottom = trim_range(ctx.rows, y0, y1)
    left, right = trim_range(ctx.cols, x0, x1)
    if bottom < top or right < left:
        return
    region_ink = sum(ctx.rows[top:bottom + 1])
    _t(depth, f"cut d{depth} region {x0},{y0}..{x1},{y1} trimmed {left},{top}..{right},{bottom}")
    if depth < PANEL_MAX_DEPTH:
        width, height = right - left + 1, bottom - top + 1
        row = find_widest_gutter(ctx.rows, top, bottom, width,
                                 ctx.ink_ratio, ctx.min_gutter)
        col = find_widest_gutter(ctx.cols, left, right, height,
                                 ctx.ink_ratio, ctx.min_gutter)
        row_len, col_len = row[2], col[2]
        _t(depth, f"  straight rows={row[0]}..{row[1]} len={row_len}"
                  f"  cols={col[0]}..{col[1]} len={col_len}")
        if row_len > 0 and row_len >= col_len:
            cut(data, left, top, right, row[0] - 1, depth + 1, ctx, out)
            cut(data, left, row[1] + 1, right, bottom, depth + 1, ctx, out)
            return
        elif col_len > 0:
            cut(data, left, top, col[0] - 1, bottom, depth + 1, ctx, out)
            cut(data, col[1] + 1, top, right, bottom, depth + 1, ctx, out)
            return
        if (depth <= (0 if SHEAR_DEPTH == 'root' else PANEL_SHEAR_MAX_DEPTH)
                and (min_in_range(ctx.cols, left, right) <= height * PANEL_SHEAR_TRIGGER
                     or min_in_range(ctx.rows, top, bottom) <= width * PANEL_SHEAR_TRIGGER)):
            ctx.shear_searches += 1
            r = find_sheared_split(data, left, top, right, bottom, ctx)
            _t(depth, f"  shear -> {r}")
            if r and r[0] == "cols":
                ctx.shear_splits += 1
                split = r[1]
                cut(data, left, top, split, bottom, depth + 1, ctx, out)
                cut(data, split + 1, top, right, bottom, depth + 1, ctx, out)
                return
            if r and r[0] == "rows":
                ctx.shear_splits += 1
                split = r[1]
                cut(data, left, top, right, split, depth + 1, ctx, out)
                cut(data, left, split + 1, right, bottom, depth + 1, ctx, out)
                return
    _t(depth, f"  EMIT {left},{top} {right-left+1}x{bottom-top+1} ink={region_ink}")
    emit_leaf(left, top, right, bottom, region_ink, ctx, out)


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
    cells = []
    global TRACE
    TRACE = True
    cut(data, 0, 0, sw - 1, sh - 1, 0, ctx, cells)
    TRACE = False
    print(f"cut -> {len(cells)} leaves, shear {ctx.shear_splits}/{ctx.shear_searches}")

    def show(tag, lst):
        for i, c in enumerate(lst):
            print(f"  {tag}[{i}] cells {c[0]},{c[1]} {c[2]}x{c[3]} ink={c[4]} "
                  f"({100.0*c[4]/(c[2]*c[3]):.1f}%)  "
                  f"page x{100.0*c[0]/sw:.1f}%..{100.0*(c[0]+c[2])/sw:.1f}% "
                  f"y{100.0*c[1]/sh:.1f}%..{100.0*(c[1]+c[3])/sh:.1f}%")
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
               if a not in ("noclip", "root", "all", "loose")]
    if unknown:
        raise SystemExit("unknown argument(s): %s\n"
                         "usage: panelprobe.py <image> [noclip] [root|all] [loose]"
                         % " ".join(unknown))
    NOCLIP = "noclip" in args
    if "root" in args:
        SHEAR_DEPTH = "root"
    elif "all" in args:
        SHEAR_DEPTH = "all"
    SHEAR_LOOSE = "loose" in args
    detect(sys.argv[1])
