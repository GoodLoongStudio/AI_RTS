"""Pillow 绘图工具：2048 画布、世界↔像素、刻度、边框图例、contact sheet、直方图。

铁律：任何文字/图例不得进入地图区（64px 边框带内）；
例外仅限提示词明示的 starts.png minPair 标注、chokes.png 宽度数字（字号 ≤ 24px）。
"""
import math

import numpy as np
from PIL import Image, ImageDraw, ImageFont

from ..contract import CANVAS, H, MAP_PX, OFFSET, PX_PER_M, W, world_to_px

_FONT_CACHE = {}


def font(size: int, bold: bool = False):
    key = (size, bold)
    if key in _FONT_CACHE:
        return _FONT_CACHE[key]
    candidates = (
        ["C:/Windows/Fonts/arialbd.ttf", "C:/Windows/Fonts/msyhbd.ttc"]
        if bold
        else ["C:/Windows/Fonts/arial.ttf", "C:/Windows/Fonts/msyh.ttc"]
    )
    f = None
    for path in candidates:
        try:
            f = ImageFont.truetype(path, size)
            break
        except OSError:
            continue
    if f is None:
        f = ImageFont.load_default()
    _FONT_CACHE[key] = f
    return f


P_COLORS = ["#c0392b", "#2471a3", "#1e8449", "#d68910"]  # P0..P3
TERRITORY_RGB = [(173, 199, 232), (245, 203, 167), (178, 224, 178), (222, 194, 226)]
CONTEST_RGB = (255, 255, 255)


def _tick_step(span, target=12):
    """根据地图跨度选一个"好看"的刻度步长（使约 target 个刻度）。"""
    raw = span / max(target, 1)
    for s in (1, 2, 5, 10, 20, 25, 50, 100, 200, 250):
        if raw <= s:
            return s
    return 500


def grid_to_map(arr):
    """(GRID_H,GRID_W,3) uint8 → (MAP_PX,MAP_PX,3) uint8；PIL NEAREST 放大（支持非整数 px/cell）。"""
    im = Image.fromarray(np.ascontiguousarray(arr).astype(np.uint8))
    if im.size != (MAP_PX, MAP_PX):
        im = im.resize((MAP_PX, MAP_PX), Image.NEAREST)
    return np.array(im)


class Canvas:
    """2048×2048 统一画布，含地图区框、刻度、标题（顶部边框）、图例（底部边框）。"""

    def __init__(self, bg=(255, 255, 255)):
        self.img = Image.new("RGB", (CANVAS, CANVAS), bg)
        self.d = ImageDraw.Draw(self.img, "RGBA")

    # ---- 坐标 ----
    def w2p(self, x, z):
        return world_to_px(x, z)

    # ---- 地图区底图 ----
    def paste_map_image(self, arr):
        """arr: (1920,1920,3) uint8，贴到 (64,64)。"""
        im = Image.fromarray(arr.astype(np.uint8))
        self.img.paste(im, (OFFSET, OFFSET))
        self.d = ImageDraw.Draw(self.img, "RGBA")

    def map_grid_lines(self, step=None, color=(228, 228, 222, 255)):
        end = OFFSET + MAP_PX
        if step is None:
            step = _tick_step(W)
        for m in range(0, int(W) + 1, step):
            px = OFFSET + m * PX_PER_M
            if px <= end:
                self.d.line([(px, OFFSET), (px, end)], fill=color, width=1)
                self.d.line([(OFFSET, px), (end, px)], fill=color, width=1)

    # ---- 边框 ----
    def frame(self, title="", legend=None, legend_items=None):
        """画地图区外框 + 刻度 + 方位 + 标题（顶）+ 图例（底）。"""
        a, b = OFFSET, OFFSET + MAP_PX
        self.d.rectangle([a, a, b - 1, b - 1], outline=(40, 40, 40), width=3)
        # 刻度：自适应步长小刻度，每 2×步长标数字
        tick_s, tick_l = 6, 12
        step = _tick_step(W)
        major = step * 2
        for m in range(0, int(W) + 1, step):
            t = OFFSET + m * PX_PER_M
            if t > b:
                break
            big = (m % major == 0)
            ln = tick_l if big else tick_s
            self.d.line([(t, a - 2), (t, a - 2 - ln)], fill=(60, 60, 60), width=2)
            self.d.line([(t, b + 2), (t, b + 2 + ln)], fill=(60, 60, 60), width=2)
            self.d.line([(a - 2, t), (a - 2 - ln, t)], fill=(60, 60, 60), width=2)
            self.d.line([(b + 2, t), (b + 2 + ln, t)], fill=(60, 60, 60), width=2)
            if big:
                label = str(m)
                f = font(13)
                wpx = self.d.textlength(label, font=f)
                self.d.text((t - wpx / 2, a - 20), label, fill=(60, 60, 60), font=f)
                self.d.text((t - wpx / 2, b + 6), label, fill=(60, 60, 60), font=f)
                self.d.text((a - 6 - len(label) * 8, t - 8), label, fill=(60, 60, 60), font=f)
                self.d.text((b + 6, t - 8), label, fill=(60, 60, 60), font=f)
        # 方位（边框区）
        f18 = font(18, bold=True)
        self.d.text((b - 30, a - 24), "N", fill=(90, 90, 90), font=f18)
        self.d.text((b - 30, b + 8), "S", fill=(90, 90, 90), font=f18)
        self.d.text((a - 26, b - 26), "W", fill=(90, 90, 90), font=f18)
        self.d.text((b + 8, b - 26), "E", fill=(90, 90, 90), font=f18)
        # 标题（顶部边框）
        if title:
            self.d.text((a, 20), title, fill=(20, 20, 20), font=font(24, bold=True))
        # 图例（底部边框，可折行；色块加大，方便缩略预览也能认）
        items = legend if legend is not None else legend_items
        if items:
            f_leg = font(16, bold=True)
            sw, gap, row_h = 18, 10, 22
            x, y = a, b + 6
            for item in items:
                color, text = item
                tw = int(self.d.textlength(text, font=f_leg))
                need = sw + 6 + tw + gap
                if x + need > b and x > a:
                    x = a
                    y += row_h
                self.d.rectangle([x, y, x + sw, y + sw], fill=color, outline=(20, 20, 20), width=2)
                self.d.text((x + sw + 6, y - 1), text, fill=(16, 16, 16), font=f_leg)
                x += need

    def save(self, path):
        self.img.save(path)


# ---- 基本图元 ----

def draw_disc(d, cx, cy, r, fill):
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=fill)


def draw_ring(d, cx, cy, r, outline, width=2, dash=False):
    if not dash:
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=outline, width=width)
        return
    # 虚线圆
    n = max(24, int(r / 4))
    for k in range(0, n, 2):
        a0 = 360 * k / n
        a1 = 360 * (k + 1) / n
        d.arc([cx - r, cy - r, cx + r, cy + r], start=a0, end=a1, fill=outline, width=width)


def draw_spawn_marker(cv, x, z, idx, color, base_radius_m=10.0, label_size=24):
    """出生点：白边实心点 + 基地盘圆 + 编号 P0–P3（编号紧贴点，属于标记的一部分）。"""
    px, py = cv.w2p(x, z)
    r = base_radius_m * PX_PER_M
    draw_ring(cv.d, px, py, r, color, width=4, dash=True)
    draw_disc(cv.d, px, py, 16, (255, 255, 255))
    draw_disc(cv.d, px, py, 11, color)
    cv.d.text((px + 14, py - 32), f"P{idx}", fill=color, font=font(label_size, bold=True))


# ---- contact sheet ----

def contact_sheet(images_with_labels, cols=4, cell=512, note_lines=None):
    """每格 cell×cell，格子顶部 18px 白条写标注；返回 PIL Image。"""
    n = len(images_with_labels)
    rows = math.ceil(max(n, 1) / cols)
    out = Image.new("RGB", (cols * cell, rows * cell), (255, 255, 255))
    d = ImageDraw.Draw(out)
    for k, (im, label) in enumerate(images_with_labels):
        gx, gy = (k % cols) * cell, (k // cols) * cell
        if im is not None:
            im = im.copy()
            im.thumbnail((cell, cell - 18))
            out.paste(im, (gx + (cell - im.width) // 2, gy + 18))
        d.rectangle([gx, gy, gx + cell - 1, gy + cell - 1], outline=(150, 150, 150))
        if label:
            d.text((gx + 4, gy + 2), label, fill=(0, 0, 0), font=font(14, bold=True))
    return out


# ---- Pillow 直方图 ----

def histogram_panel(values, bins=20, color="#2471a3", vmin=None, vmax=None):
    """绘制一个直方图面板（Pillow 自绘），返回 (Image, stats_dict)。"""
    vals = np.asarray([v for v in values if v is not None and np.isfinite(v)], dtype=float)
    stats = {}
    if vals.size:
        stats = {
            "n": int(vals.size),
            "min": float(vals.min()),
            "median": float(np.median(vals)),
            "max": float(vals.max()),
            "mean": float(vals.mean()),
        }
    w, h = 940, 880
    pad_l, pad_b, pad_t = 70, 60, 60
    im = Image.new("RGB", (w, h), (255, 255, 255))
    d = ImageDraw.Draw(im)
    lo = float(vals.min()) if vals.size else 0.0
    hi = float(vals.max()) if vals.size else 1.0
    if vmin is not None:
        lo = min(lo, vmin)
    if vmax is not None:
        hi = max(hi, vmax)
    if hi - lo < 1e-9:
        hi = lo + 1.0
    counts, edges = np.histogram(vals, bins=bins, range=(lo, hi)) if vals.size else (np.zeros(bins), np.linspace(lo, hi, bins + 1))
    maxc = max(int(counts.max()), 1)
    plot_w, plot_h = w - pad_l - 30, h - pad_b - pad_t
    x0, y0 = pad_l, h - pad_b
    # 轴
    d.line([(x0, y0 - plot_h), (x0, y0), (x0 + plot_w, y0)], fill=(60, 60, 60), width=2)
    bw = plot_w / bins
    for k in range(bins):
        c = int(counts[k])
        bh = int(plot_h * c / maxc)
        if bh > 0:
            d.rectangle([x0 + k * bw + 1, y0 - bh, x0 + (k + 1) * bw - 1, y0 - 1],
                        fill=color, outline=(255, 255, 255))
        if k % max(1, bins // 10) == 0:
            d.text((x0 + k * bw, y0 + 6), f"{edges[k]:.2f}", fill=(60, 60, 60), font=font(13))
    d.text((x0 + plot_w, y0 + 6), f"{hi:.2f}", fill=(60, 60, 60), font=font(13))
    # y 轴刻度
    for frac in (0.5, 1.0):
        yy = y0 - int(plot_h * frac)
        d.line([(x0 - 4, yy), (x0, yy)], fill=(60, 60, 60), width=2)
        d.text((x0 - 44, yy - 8), str(int(maxc * frac)), fill=(60, 60, 60), font=font(13))
    return im, stats
