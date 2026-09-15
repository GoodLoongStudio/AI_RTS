"""G1 绘图：starts.png / starts_table.png / territory.png / contact / hist。"""
import math

import numpy as np
from PIL import Image, ImageColor, ImageDraw

from ..contract import (BASE_RADIUS, CONTEST_BAND, G1_CORNER_DIST, G1_DEFAULTS, GRID_H,
                        GRID_W, MAP_CENTER, OFFSET, PX_PER_M, W, PX_PER_M as PPM)
from .canvas import (
    CONTEST_RGB, Canvas, P_COLORS, TERRITORY_RGB, contact_sheet, draw_spawn_marker,
    draw_ring, font, grid_to_map, histogram_panel,
)
from ..contract import world_to_px

MAP_END = OFFSET + 1920


def _draw_zone_overlays(cv: Canvas, margin_m=None, center_gap_m=None):
    """留白带（半透明红）+ 中心禁区（半透明圆）；默认值取自 G1_DEFAULTS。"""
    margin_m = G1_DEFAULTS["margin"] if margin_m is None else margin_m
    center_gap_m = G1_DEFAULTS["center_gap"] if center_gap_m is None else center_gap_m
    d = cv.d
    a, b = OFFSET, MAP_END
    band = margin_m * PPM
    for (x0, y0, x1, y1) in [
        (a, a, b, a + band), (a, b - band, b, b), (a, a + band, a + band, b - band),
        (b - band, a + band, b, b - band),
    ]:
        d.rectangle([x0, y0, x1, y1], fill=(220, 60, 60, 34))
    cx, cy = cv.w2p(*MAP_CENTER)
    r = center_gap_m * PPM
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(220, 60, 60, 34))


def _min_pair_pair(spec):
    dm = spec["pair_dist_matrix"]
    best = (math.inf, 0, 1)
    for i in range(len(dm)):
        for j in range(i + 1, len(dm)):
            if dm[i][j] < best[0]:
                best = (dm[i][j], i, j)
    return best


def plot_starts(spec, path):
    cv = Canvas()
    cv.map_grid_lines()
    _draw_zone_overlays(cv)
    starts = spec["starts"]
    for k, (x, z) in enumerate(starts):
        draw_spawn_marker(cv, x, z, k, P_COLORS[k])
    # 最小两两距离线段 + 数值（唯一允许进地图区的文字，≤24px）
    d_val, i, j = _min_pair_pair(spec)
    x0, y0 = cv.w2p(*starts[i])
    x1, y1 = cv.w2p(*starts[j])
    cv.d.line([(x0, y0), (x1, y1)], fill=(192, 57, 43), width=4)
    mx, my = (x0 + x1) / 2, (y0 + y1) / 2
    text = f"{d_val:.1f} m"
    f = font(20, bold=True)
    tw = cv.d.textlength(text, font=f)
    cv.d.rectangle([mx - tw / 2 - 4, my - 14, mx + tw / 2 + 4, my + 10], fill=(255, 255, 255))
    cv.d.text((mx - tw / 2, my - 13), text, fill=(150, 30, 20), font=f)
    title = f"G1 Seed {spec['master_seed']} — starts (sampler {spec['sampler']})"
    if spec["accepted"]:
        title += f"  ACCEPTED (attempts {spec['attempts']})"
    else:
        title += f"  REJECTED: {spec['reject_reason']} (attempts {spec['attempts']})"
    cv.frame(title=title, legend=[(P_COLORS[k], f"P{k} home") for k in range(4)]
             + [("#c0392b", "min pair"), ("#e8b6b6", "margin 12m / center 24m")])
    cv.save(path)


def plot_starts_table(spec, path):
    w, h = 1400, 1100
    im = Image.new("RGB", (w, h), (255, 255, 255))
    d = ImageDraw.Draw(im)
    d.text((30, 20), f"G1 Seed {spec['master_seed']} — distance matrix & constraints",
           fill=(0, 0, 0), font=font(26, bold=True))
    y = 90
    # 距离矩阵
    f = font(22)
    fb = font(22, bold=True)
    starts = spec["starts"]
    col_w, row_h = 160, 56
    x0 = 60
    d.text((x0, y), "pair distance (m)", fill=(0, 0, 0), font=fb)
    y += 44
    for j in range(4):
        d.text((x0 + col_w * (j + 1) + 30, y), f"P{j}", fill=(0, 0, 0), font=fb)
    y += row_h
    for i in range(4):
        d.text((x0 + 10, y + 12), f"P{i}", fill=(0, 0, 0), font=fb)
        for j in range(4):
            v = spec["pair_dist_matrix"][i][j]
            txt = "-" if i == j else f"{v:.1f}"
            d.text((x0 + col_w * (j + 1) + 30, y + 12), txt, fill=(0, 0, 0), font=f)
        y += row_h
    y += 30
    # 约束表
    d.text((x0, y), "constraints", fill=(0, 0, 0), font=fb)
    y += 44
    headers = ["constraint", "value", "limit", "pass"]
    col_x = [x0, x0 + 240, x0 + 620, x0 + 900]
    for hx, hd in zip(col_x, headers):
        d.text((hx, y), hd, fill=(80, 80, 80), font=fb)
    y += 40
    for name, c in spec["constraints"].items():
        val = c["value"]
        if isinstance(val, list):
            val = " / ".join(f"{v:.1f}" for v in val)
        elif isinstance(val, float):
            val = f"{val:.3f}"
        lim = c["limit"]
        if isinstance(lim, list):
            lim = " / ".join(str(v) for v in lim)
        elif isinstance(lim, float):
            lim = f"{lim:.2f}"
        ok = c["pass"]
        d.text((col_x[0], y), name, fill=(0, 0, 0), font=f)
        d.text((col_x[1], y), str(val), fill=(0, 0, 0), font=f)
        d.text((col_x[2], y), str(lim), fill=(0, 0, 0), font=f)
        d.text((col_x[3], y), "OK" if ok else "FAIL", fill=(0, 130, 0) if ok else (200, 0, 0), font=fb)
        y += 38
    y += 24
    cells = spec["constraints"]["territory_ratio"].get("cells", [])
    d.text((x0, y), f"territory cells P0..P3: {cells}", fill=(0, 0, 0), font=f)
    y += 34
    d.text((x0, y), f"attempts: {spec['attempts']}   reject_reason: {spec['reject_reason']}",
           fill=(0, 0, 0), font=f)
    y += 34
    d.text((x0, y), f"corner_flags: {spec['corner_flags']} (<{G1_CORNER_DIST} m to nearest corner)",
           fill=(0, 0, 0), font=f)
    y += 34
    d.text((x0, y), f"rot_sym_err: {spec['rot_sym_err']:.4f}", fill=(0, 0, 0), font=f)
    im.save(path)


def render_territory_image(spec):
    """从出生点重算 territory 与争夺带（不回读 PNG），返回 (1920,1920,3) uint8。"""
    from ..gates.g1_starts import voronoi_territory

    starts = np.asarray(spec["starts"], dtype=float)
    terr = voronoi_territory(starts)
    gi = np.arange(GRID_W) + 0.5
    gj = np.arange(GRID_H) + 0.5
    xx, zz = np.meshgrid(gi, gj)
    d = np.stack([np.hypot(xx - s[0], zz - s[1]) for s in starts])
    d_sorted = np.sort(d, axis=0)
    contest = (d_sorted[1] - d_sorted[0]) < CONTEST_BAND
    img = np.zeros((GRID_H, GRID_W, 3), dtype=np.float32)
    for k in range(4):
        img[terr == k] = TERRITORY_RGB[k]
    img[contest] = img[contest] * 0.45 + np.array(CONTEST_RGB, dtype=np.float32) * 0.55
    img = grid_to_map(img.astype(np.uint8))
    return img


def plot_territory(spec, path):
    cv = Canvas()
    cv.paste_map_image(render_territory_image(spec))
    starts = spec["starts"]
    for k, (x, z) in enumerate(starts):
        px, py = cv.w2p(x, z)
        draw_ring(cv.d, px, py, 10 * PPM, P_COLORS[k], width=3)
        from .canvas import draw_disc
        draw_disc(cv.d, px, py, 7, P_COLORS[k])
        cv.d.text((px + 10, py - 28), f"P{k}", fill=P_COLORS[k], font=font(20, bold=True))
    legend = [(TERRITORY_RGB[k], f"P{k} territory") for k in range(4)]
    legend.append((CONTEST_RGB, f"contest band (<{CONTEST_BAND:.0f} m)"))
    title = f"G1 Seed {spec['master_seed']} — Voronoi territory"
    if not spec["accepted"]:
        title += f"  (REJECTED: {spec['reject_reason']})"
    cv.frame(title=title, legend=legend)
    cv.save(path)


def render_mini(spec, size=494):
    """contact sheet 用轻量小图：留白带 + 每出生点间隔圈（圈内无相邻出生点）+ 基地盘 + minpair 线。

    2026-09-04：去掉中央大禁区圈（center_gap 已置 0）；改画每出生点的间隔圈（半径=min_pair 限值/2）。
    """
    scale = size / W

    def w2p(x, z):
        return (x * scale, z * scale)

    im = Image.new("RGB", (size, size), (255, 255, 255))
    d = ImageDraw.Draw(im, "RGBA")
    band = G1_DEFAULTS["margin"] * scale
    for (x0, y0, x1, y1) in [
        (0, 0, size, band), (0, size - band, size, size),
        (0, band, band, size - band), (size - band, band, size, size - band),
    ]:
        d.rectangle([x0, y0, x1, y1], fill=(220, 60, 60, 40))
    d.rectangle([0, 0, size - 1, size - 1], outline=(60, 60, 60), width=2)
    starts = spec["starts"]
    # 每出生点间隔圈：半径 = min_pair 限值/2 → 相邻出生点恰在圈外（圈内无相邻出生点）
    r_sep = spec["constraints"]["min_pair"]["limit"] / 2.0 * scale
    d_val, i, j = _min_pair_pair(spec)
    x0, y0 = w2p(*starts[i])
    x1, y1 = w2p(*starts[j])
    d.line([(x0, y0), (x1, y1)], fill=(192, 57, 43), width=2)
    for k, (x, z) in enumerate(starts):
        px, py = w2p(x, z)
        rgb = ImageColor.getrgb(P_COLORS[k])
        d.ellipse([px - r_sep, py - r_sep, px + r_sep, py + r_sep], outline=(*rgb, 110), width=2)
        rr = BASE_RADIUS * scale
        d.ellipse([px - rr, py - rr, px + rr, py + rr], outline=P_COLORS[k], width=2)
        d.ellipse([px - 3, py - 3, px + 3, py + 3], fill=P_COLORS[k])
    return im


def plot_contacts(sd, specs):
    acc = [s for s in specs if s["accepted"]][:16]
    rej = [s for s in specs if not s["accepted"]][:16]
    if acc:
        items = [(render_mini(s), f"Seed {s['master_seed']} | minPair {s['min_pair']:.1f}")
                 for s in acc]
        contact_sheet(items).save(sd / "contact_accepted.png")
    if rej:
        items = [(render_mini(s), f"Seed {s['master_seed']} | REJECT {s['reject_reason']}")
                 for s in rej]
        contact_sheet(items).save(sd / "contact_rejected.png")


def plot_hist(sd, accepted_specs):
    if not accepted_specs:
        return
    canvas = Image.new("RGB", (2048, 2048), (255, 255, 255))
    d = ImageDraw.Draw(canvas)
    d.text((40, 16), f"G1 histograms — {len(accepted_specs)} accepted seeds",
           fill=(0, 0, 0), font=font(30, bold=True))
    panels = [
        ("min_pair (m)", [s["min_pair"] for s in accepted_specs]),
        ("center dist (m)", [v for s in accepted_specs for v in s["center_dists"]]),
        ("adjacent angle gaps (deg)", [v for s in accepted_specs for v in s["adjacent_angle_gaps_deg"]]),
        ("territory ratio", [s["constraints"]["territory_ratio"]["value"] for s in accepted_specs]),
    ]
    pos = [(40, 80), (1060, 80), (40, 1060), (1060, 1060)]
    for (title, values), (px, py) in zip(panels, pos):
        im, stats = histogram_panel(values, bins=20)
        d.text((px + 4, py), title, fill=(0, 0, 0), font=font(22, bold=True))
        canvas.paste(im, (px, py + 34))
        if stats:
            d.text((px + 8, py + 34 + 900 - 24),
                   f"n={stats['n']} min={stats['min']:.1f} med={stats['median']:.1f} max={stats['max']:.1f}",
                   fill=(80, 80, 80), font=font(15))
    canvas.save(sd / "hist.png")
