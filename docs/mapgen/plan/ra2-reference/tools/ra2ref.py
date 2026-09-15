"""Build reference figures from parsed RA2 multiplayer maps (clean top-down ortho raster, stats chart,
preview strip). Temporary analysis tool; lives outside the repo. Output -> ./ref
"""
import os, json, math, collections
import numpy as np
from PIL import Image, ImageDraw, ImageFont
import mapparse


def bar_panel(img, box, values_by_label, title, xlabel, bins=None, colors=None):
    """Minimal PIL histogram/bar panel. values_by_label: {label: list_of_values} (binned) or {label: {x: y}} (pre-binned)."""
    dr = ImageDraw.Draw(img)
    x0, y0, x1, y1 = box
    dr.rectangle(box, fill=(250, 250, 250), outline=(0, 0, 0))
    dr.text((x0 + 8, y0 + 6), title, fill=(0, 0, 0))
    dr.text((x0 + 8, y1 - 16), xlabel, fill=(60, 60, 60))
    px0, py0, px1, py1 = x0 + 40, y0 + 28, x1 - 12, y1 - 34
    colors = colors or [(60, 120, 220), (240, 150, 40), (60, 170, 80), (220, 60, 60)]
    series = []
    for i, (label, vals) in enumerate(values_by_label.items()):
        if isinstance(vals, dict):
            xs = sorted(vals); ys = [vals[k] for k in xs]
        else:
            edges = bins
            cnt = [0] * (len(edges) - 1)
            for v in vals:
                for b in range(len(edges) - 1):
                    if edges[b] <= v < edges[b + 1]:
                        cnt[b] += 1; break
            xs = [(edges[b] + edges[b + 1]) / 2 for b in range(len(edges) - 1)]; ys = cnt
        series.append((label, xs, ys, colors[i % len(colors)]))
    allx = [x for _, xs, _, _ in series for x in xs]; ally = [y for _, _, ys, _ in series for y in ys]
    if not allx:
        return
    xmin, xmax = min(allx), max(allx); ymax = max(ally) or 1
    nb = max(len(xs) for _, xs, _, _ in series)
    bw = (px1 - px0) / max(nb, 1) / max(len(series), 1) * 0.9
    for si, (label, xs, ys, col) in enumerate(series):
        for x, y in zip(xs, ys):
            cx = px0 + (x - xmin) / max(xmax - xmin, 1e-9) * (px1 - px0 - bw * len(series)) + si * bw
            h = y / ymax * (py1 - py0)
            dr.rectangle([cx, py1 - h, cx + bw, py1], fill=col)
        dr.text((px1 - 150, py0 + 4 + 12 * si), f"{label} n={sum(ys)}", fill=col)
    # axis labels
    dr.line([px0, py1, px1, py1], fill=(0, 0, 0)); dr.line([px0, py0, px0, py1], fill=(0, 0, 0))
    for k in range(6):
        xv = xmin + (xmax - xmin) * k / 5
        dr.text((px0 + (px1 - px0 - bw * len(series)) * k / 5, py1 + 4), f"{xv:.2f}" if xmax < 5 else f"{xv:.0f}", fill=(0, 0, 0))
    dr.text((x0 + 4, py0), f"{ymax}", fill=(0, 0, 0))

ROOT = os.path.dirname(__file__)
REF = os.path.join(ROOT, "ref")
os.makedirs(REF, exist_ok=True)
MULTI = os.path.join(ROOT, "extract", "MULTI")


def cell_raster(info, cells, ore, gem, starts):
    """Native-resolution raster: each iso cell -> 2x1 px block at (u=X-Y+off, v=X+Y). Perfect tiling."""
    X = cells["X"].astype(int); Y = cells["Y"].astype(int); L = cells["level"].astype(int)
    u = X - Y; v = X + Y
    umin, vmin = u.min(), v.min()
    Wpx = (u.max() - umin) + 2; Hpx = (v.max() - vmin) + 1
    lvl = np.full((Hpx, Wpx), -1, dtype=np.int16)
    def put(arr, xx, yy, val):
        uu = xx - yy - umin; vv = xx + yy - vmin
        arr[vv, uu] = val; arr[vv, np.minimum(uu + 1, Wpx - 1)] = val
    put(lvl, X, Y, L)
    kind = np.zeros((Hpx, Wpx), dtype=np.uint8)  # 0 terrain,1 ore,2 gem
    if ore:
        o = np.array(ore); put(kind, o[:, 0], o[:, 1], 1)
    if gem:
        g = np.array(gem); put(kind, g[:, 0], g[:, 1], 2)
    # colour: level ramp
    rgb = np.zeros((Hpx, Wpx, 3), dtype=np.uint8) + np.array([14, 14, 18], dtype=np.uint8)
    valid = lvl >= 0
    t = np.clip(lvl / 12.0, 0, 1)
    base = np.stack([70 + 150 * t, 62 + 130 * t, 46 + 100 * t], axis=-1)
    rgb[valid] = base[valid].astype(np.uint8)
    # cliff edges: |dL| == 4 with right/down neighbour
    edge = np.zeros_like(valid)
    d1 = np.abs(lvl[:, 1:] - lvl[:, :-1]); m1 = (lvl[:, 1:] >= 0) & (lvl[:, :-1] >= 0) & (d1 >= 3)
    edge[:, 1:] |= m1
    d2 = np.abs(lvl[1:, :] - lvl[:-1, :]); m2 = (lvl[1:, :] >= 0) & (lvl[:-1, :] >= 0) & (d2 >= 3)
    edge[1:, :] |= m2
    rgb[edge] = (40, 20, 10)
    rgb[kind == 1] = (235, 190, 40)
    rgb[kind == 2] = (80, 210, 240)
    return rgb, (umin, vmin), (Wpx, Hpx)


def render_clean(f, target_w=1024):
    info, cells, ore, gem, starts, prev, sec = mapparse.parse_map(os.path.join(MULTI, f))
    rgb, (umin, vmin), (Wpx, Hpx) = cell_raster(info, cells, ore, gem, starts)
    scale = max(1, int(round(target_w / Wpx)))
    # each cell is 2 px wide, 1 px tall at native; to get square-ish cells use (scale, 2*scale)
    # (u,v)=(X-Y,X+Y) raster is already true top-down orthographic (equal world scale on both axes)
    img = Image.fromarray(rgb).resize((Wpx * scale, Hpx * scale), Image.NEAREST)
    dr = ImageDraw.Draw(img)
    def to_px(x, y):
        return ((x - y - umin + 1) * scale, (x + y - vmin + 0.5) * scale)
    for i, (sx, sy) in enumerate(starts):
        p = to_px(sx, sy); r = 6 * scale
        dr.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], outline=(255, 60, 60), width=3)
        dr.text((p[0] + r + 3, p[1] - r), f"P{i}", fill=(255, 255, 255))
    if len(starts) >= 2:
        best = None
        for i in range(len(starts)):
            for j in range(i + 1, len(starts)):
                d = math.hypot(starts[i][0] - starts[j][0], starts[i][1] - starts[j][1])
                if best is None or d < best[0]:
                    best = (d, i, j)
        a = to_px(*starts[best[1]]); b = to_px(*starts[best[2]])
        dr.line([a, b], fill=(255, 130, 130), width=2)
        dr.text(((a[0] + b[0]) / 2 + 4, (a[1] + b[1]) / 2), f"min pair {best[0]:.1f} cells", fill=(255, 220, 220))
    W, H = info["size"][2], info["size"][3]
    title = (f"RA2 {f}  theater={info['theater']}  Size={W}x{H}  starts={len(starts)}  "
             f"ore={len(ore)} gem={len(gem)}  maxLevel={max(map(int, info['level_hist']))}  "
             f"minPair/sqrt(WH)={info['start_pair_min'] / math.sqrt(W * H):.2f}")
    dr.rectangle([0, 0, img.width, 16], fill=(0, 0, 0))
    dr.text((4, 2), title, fill=(255, 255, 255))
    return img, info, prev


def gallery(files, out, cols=2, tile_w=1024):
    tiles = []
    for f in files:
        img, info, prev = render_clean(f, tile_w)
        tiles.append(img)
    th = max(t.height for t in tiles)
    tw = max(t.width for t in tiles)
    rows = math.ceil(len(tiles) / cols)
    sheet = Image.new("RGB", (tw * cols, th * rows), (30, 30, 34))
    for i, t in enumerate(tiles):
        sheet.paste(t, ((i % cols) * tw, (i // cols) * th))
    sheet.save(out)
    return sheet


def preview_strip(files, out):
    imgs = []
    for f in files:
        info, cells, ore, gem, starts, prev, sec = mapparse.parse_map(os.path.join(MULTI, f))
        if prev is None:
            continue
        # parse_map flipped BGR->RGB; give both for inspection
        a = prev
        b = Image.fromarray(np.asarray(prev)[:, :, ::-1].copy())
        for tag, im in (("as-BGR", a), ("as-RGB", b)):
            im2 = im.resize((im.width * 3, im.height * 3), Image.NEAREST)
            dr = ImageDraw.Draw(im2); dr.text((3, 3), f"{f} {tag} {prev.width}x{prev.height}", fill=(255, 255, 0))
            imgs.append(im2)
    W = max(i.width for i in imgs); H = sum(i.height for i in imgs)
    sheet = Image.new("RGB", (W, H), (0, 0, 0)); y = 0
    for i in imgs:
        sheet.paste(i, (0, y)); y += i.height
    sheet.save(out)


def stats_chart(out):
    S = json.load(open(os.path.join(ROOT, "mapstats", "stats.json")))
    multi = set(os.listdir(MULTI))
    M = [s for s in S if s["file"] in multi and "error" not in s and len(s["starts"]) >= 2]
    std = [s for s in M if s["start_pair_min"] / math.sqrt(s["size"][2] * s["size"][3]) > 0.3 and s.get("ore_cells", 0) > 0]
    img = Image.new("RGB", (1400, 1000), (235, 235, 240))
    dr = ImageDraw.Draw(img)
    dr.text((10, 6), "Facts parsed from G:\\Command & Conquer Red Alert 2\\MULTI.MIX (97 official MP maps, standard variants only) 2026-09-03", fill=(0, 0, 0))
    # (a) normalized min pair distance by player count
    by = {}
    for n in (2, 4, 6, 8):
        vals = [s["start_pair_min"] / math.sqrt(s["size"][2] * s["size"][3]) for s in std if len(s["starts"]) == n]
        if vals:
            by[f"{n}p"] = vals
    bar_panel(img, (10, 30, 690, 500), by, "min start-pair distance / sqrt(W*H)", "normalized min pair distance",
              bins=list(np.arange(0.3, 1.55, 0.05)))
    # (b) nearest ore per start
    near = [p["nearest"] for s in std for p in s.get("ore_per_start", [])]
    bar_panel(img, (710, 30, 1390, 500), {"nearest ore": near}, "Nearest ore cell to each start (cells)", "cells",
              bins=list(range(0, 62, 2)), colors=[(200, 160, 40)])
    # (c) level histogram
    agg = collections.Counter()
    for s in std:
        for k, v in s["level_hist"].items():
            agg[int(k)] += v
    tot = sum(agg.values())
    bar_panel(img, (10, 520, 690, 990), {"level %": {k: round(100 * agg[k] / tot, 1) for k in agg}},
              "Cell height Level distribution, % (Level 0..14)", "Level", colors=[(150, 90, 50)])
    # (d) map sizes scatter
    box = (710, 520, 1390, 990); dr.rectangle(box, fill=(250, 250, 250), outline=(0, 0, 0))
    dr.text((718, 526), "Map Size W x H by player count (2p blue, 4p orange, 6p green, 8p red)", fill=(0, 0, 0))
    cols = {2: (60, 120, 220), 3: (120, 120, 120), 4: (240, 150, 40), 6: (60, 170, 80), 8: (220, 60, 60)}
    for s in std:
        w, h = s["size"][2], s["size"][3]; n = len(s["starts"])
        x = 740 + (w - 30) / 130 * 600; y = 960 - (h - 40) / 120 * 400
        dr.ellipse([x - 5, y - 5, x + 5, y + 5], fill=cols.get(n, (0, 0, 0)))
    for w in (40, 60, 80, 100, 120, 140, 160):
        x = 740 + (w - 30) / 130 * 600; dr.text((x - 8, 964), str(w), fill=(0, 0, 0))
    for h in (40, 60, 80, 100, 120, 140):
        y = 960 - (h - 40) / 120 * 400; dr.text((716, y - 6), str(h), fill=(0, 0, 0))
    img.save(out)
    # numeric summary
    summ = {}
    for n in (2, 3, 4, 6, 8):
        vals = [s["start_pair_min"] / math.sqrt(s["size"][2] * s["size"][3]) for s in std if len(s["starts"]) == n]
        raw = [s["start_pair_min"] for s in std if len(s["starts"]) == n]
        if vals:
            summ[f"{n}p"] = dict(count=len(vals), norm_min=round(min(vals), 3), norm_median=round(float(np.median(vals)), 3),
                                 norm_max=round(max(vals), 3), cells_min=min(raw), cells_max=max(raw))
    summ["nearest_ore_to_start_cells"] = dict(p10=round(float(np.percentile(near, 10)), 1), median=round(float(np.median(near)), 1),
                                              p90=round(float(np.percentile(near, 90)), 1))
    summ["level_pct"] = {k: round(100 * agg[k] / tot, 2) for k in sorted(agg)}
    summ["standard_maps_used"] = len(std)
    return summ


if __name__ == "__main__":
    four = ["mp03t4.map", "mp05t4.map", "mp07t4.map", "2FF4B88F.map-ini"]
    gallery(four, os.path.join(REF, "ra2_ref_gallery_4p.png"))
    gallery(["mp01t4.map", "mp02t2.map", "mp17t6.map", "mp27t8.map"], os.path.join(REF, "ra2_ref_gallery_misc.png"))
    preview_strip(["mp03t4.map", "mp05t4.map"], os.path.join(REF, "ra2_ref_preview_channels.png"))
    summ = stats_chart(os.path.join(REF, "ra2_ref_stats.png"))
    json.dump(summ, open(os.path.join(REF, "ra2_ref_summary.json"), "w"), indent=1)
    print(json.dumps(summ, indent=1))
