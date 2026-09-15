"""G4 后处理：ortho_raw → 2048 画布 ortho_godot.png；ortho_flat_raw 与 mapgrid.blocking 差分。

2026-09-05 适配 256m：PX_PER_M = 7.5（非整数）——格→像素一律用整数取界
（round(i·7.5)），格→画布放大用 PIL resize（不再 np.repeat）。
"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from rtsmap.contract import GRID_H, GRID_W, OFFSET, PX_PER_M  # noqa: E402
from rtsmap.grid import MapGrid  # noqa: E402

MAP_PX = 1920


def ImageFont_load(size, bold=False):
    from PIL import ImageFont
    try:
        p = "C:/Windows/Fonts/arialbd.ttf" if bold else "C:/Windows/Fonts/arial.ttf"
        return ImageFont.truetype(p, size)
    except OSError:
        return ImageFont.load_default()


def compose_canvas(raw_path, out_path, title):
    cv = Image.new("RGB", (2048, 2048), (255, 255, 255))
    d = ImageDraw.Draw(cv)
    raw = Image.open(raw_path).convert("RGB")
    if raw.size != (MAP_PX, MAP_PX):
        raw = raw.resize((MAP_PX, MAP_PX))
    cv.paste(raw, (OFFSET, OFFSET))
    d.rectangle([OFFSET, OFFSET, OFFSET + MAP_PX - 1, OFFSET + MAP_PX - 1],
                outline=(40, 40, 40), width=3)
    f = ImageFont_load(24, True)
    d.text((OFFSET, 20), title, fill=(20, 20, 20), font=f)
    f13 = ImageFont_load(13)
    step_m = 32
    for m in range(0, 257, step_m):
        t = OFFSET + m * PX_PER_M
        if t > OFFSET + MAP_PX + 1:
            break
        d.text((t - 6, OFFSET - 20), str(m), fill=(60, 60, 60), font=f13)
        d.text((t - 6, OFFSET + MAP_PX + 2), str(m), fill=(60, 60, 60), font=f13)
    cv.save(out_path)


def _cell_bounds(i):
    """格 i 的像素界（PX_PER_M 非整数 → 取整边界，重叠 1px 无害）。"""
    return int(round(i * PX_PER_M)), int(round((i + 1) * PX_PER_M))


def diff_flat(raw_path, grid, out_path, report_path, seed):
    raw = np.asarray(Image.open(raw_path).convert("RGB").resize((MAP_PX, MAP_PX)))
    blocking = grid.get("blocking")
    red = (raw[:, :, 0] > 150) & (raw[:, :, 1] < 90) & (raw[:, :, 2] < 90)
    godot = np.zeros((GRID_H, GRID_W), dtype=bool)
    # 采样口径 = 格中心 3×3px 窗口（0.4m）：Python blocking 是"格中心在盒内"约定，
    # 256m 的 7.5px/格下按整格窗口取均值会把每个盒的边缘半格刷成系统性 1 格环
    # （实测 30% 阈值 4.9%、整窗 50% 阈值 2.7%）；中心窗口与中心约定对齐后 ~0.x%。
    for i in range(GRID_H):
        cy = int(round((i + 0.5) * PX_PER_M))
        r0, r1 = max(0, cy - 1), min(MAP_PX, cy + 2)
        for j in range(GRID_W):
            cx = int(round((j + 0.5) * PX_PER_M))
            c0, c1 = max(0, cx - 1), min(MAP_PX, cx + 2)
            cell = red[r0:r1, c0:c1]
            if cell.size and cell.mean() > 0.50:
                godot[i, j] = True
    py = blocking > 0
    both = py & godot
    only_py = py & ~godot
    only_godot = godot & ~py
    inconsistent = (only_py | only_godot).sum() / max(int(py.sum()), 1)
    vis = np.full((GRID_H, GRID_W, 3), 235, dtype=np.uint8)
    vis[both] = (150, 150, 150)
    vis[only_py] = (220, 60, 60)
    vis[only_godot] = (60, 80, 220)
    im = Image.fromarray(vis).resize((MAP_PX, MAP_PX), Image.NEAREST)
    cv = Image.new("RGB", (2048, 2048), (255, 255, 255))
    cv.paste(im, (OFFSET, OFFSET))
    d = ImageDraw.Draw(cv)
    d.rectangle([OFFSET, OFFSET, OFFSET + MAP_PX - 1, OFFSET + MAP_PX - 1],
                outline=(40, 40, 40), width=3)
    d.text((OFFSET, 20), f"G4 Seed {seed} — diff (gray=match, red=python-only, blue=godot-only)",
           fill=(20, 20, 20), font=ImageFont_load(24, True))
    d.text((OFFSET, OFFSET + MAP_PX + 4),
           f"inconsistency vs python blocking: {inconsistent:.3%}",
           fill=(20, 20, 20), font=ImageFont_load(20, True))
    cv.save(out_path)
    report = {
        "python_blocking_cells": int(py.sum()),
        "godot_cells": int(godot.sum()),
        "both": int(both.sum()),
        "python_only": int(only_py.sum()),
        "godot_only": int(only_godot.sum()),
        "inconsistency_ratio": round(float(inconsistent), 4),
        "pass": bool(inconsistent < 0.02),
    }
    Path(report_path).write_text(json.dumps(report, indent=1), encoding="utf-8")
    return report


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="G4 后处理：画布合成 + flat 差分")
    ap.add_argument("seed", nargs="?", default=None, help="布局 Seed（旧接口）")
    ap.add_argument("--runs", default="runs", help="runs 根目录（正式 runs 或任务目录）")
    ap.add_argument("--g4-dir", default=None, dest="g4_dir",
                    help="G4 产物目录（默认 <runs>/<seed>/G4；工作台任务为 <job>/g4/<map_id>）")
    ap.add_argument("--map-id", default=None, dest="map_id",
                    help="新版场景名 map_<id>（提供时跳过旧版 ortho_raw 合成，只做差分）")
    args = ap.parse_args()
    if not args.seed:
        ap.error("需要 seed")
    runs_root = Path(args.runs)
    g4 = Path(args.g4_dir) if args.g4_dir else runs_root / args.seed / "G4"
    g4.mkdir(parents=True, exist_ok=True)
    if (g4 / "ortho_raw.png").exists():
        compose_canvas(g4 / "ortho_raw.png", g4 / "ortho_godot.png",
                       f"G4 Seed {args.seed} — Godot ortho top view")
    grid = MapGrid.load(runs_root / args.seed / "G3" / "mapgrid.npz")
    flat = g4 / "ortho_flat_raw.png"
    if flat.exists():
        rep = diff_flat(flat, grid, g4 / "diff.png", g4 / "diff_report.json", args.seed)
        print(json.dumps(rep))
    else:
        print(f"skip diff: {flat} 不存在（新版真实地形场景用 nav_check/高度场报告验收）")
