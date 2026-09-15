"""检查山脚是否被 mountain_addon 挖成壕沟。

addon = h_rock - 0.6*logical_cell，岩体最外圈 rd≈0 时 h_rock 可能 < 2.34，
叠加后边缘低于平地 = 用户看到的凹陷。
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
from scipy import ndimage

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools._paths import DEFAULT_HEIGHT  # noqa: E402

from rtsmap.contract import GRID_H, GRID_W  # noqa: E402
from rtsmap.gates import g4_terrain_mountains as M  # noqa: E402
from rtsmap.gates.g2_landforms import polygon_mask  # noqa: E402

G2 = ROOT / "workbench_output" / "single_large_lake" / "runs" / "16"
BIN = DEFAULT_HEIGHT


def main():
    spec = json.loads((G2 / "G2" / "mapspec.json").read_text(encoding="utf-8"))
    grid = np.load(G2 / "G3" / "mapgrid.npz")
    blocking = grid["blocking"] > 0
    water = grid["water_footprint"] > 0
    region = np.zeros((GRID_H, GRID_W), dtype=bool)
    for pl in spec.get("plateaus", []):
        region |= polygon_mask(np.asarray(pl["outline"], dtype=float))

    rock_v, rd_v, ro_v = M.vertex_rock_fields(blocking, region, water)
    vi = np.arange(513, dtype=np.float64)
    vx, vz = np.meshgrid(vi, vi)
    addon = M.mountain_addon(vx.ravel(), vz.ravel(), rd_v.ravel(), ro_v.ravel())
    addon = addon.reshape(513, 513)

    raw = BIN.read_bytes()
    vw, vh = np.frombuffer(raw[:8], dtype=np.int32)
    hf = np.frombuffer(raw[8:], dtype=np.float32).reshape(int(vh), int(vw))
    # 1025 -> 513 抽
    hf513 = hf[::2, ::2][:513, :513]

    ring0 = rock_v & (rd_v < 1.5)
    ring1 = rock_v & (rd_v >= 1.5) & (rd_v < 3.5)
    ring2 = rock_v & (rd_v >= 3.5) & (rd_v < 6.5)
    fan = (ro_v > 0) & (ro_v < 4) & ~rock_v
    sand = ~rock_v & (ro_v >= 8) & (hf513 > -0.5) & (hf513 < 1.2)

    print("=== addon 分带 ===")
    for name, m in (("rd<1.5 最外圈", ring0), ("rd 1.5-3.5", ring1),
                    ("rd 3.5-6.5", ring2), ("扇区 ro<4", fan), ("远沙地", sand)):
        if not m.any():
            continue
        a = addon[m]
        print(f"  {name:16s} n={int(m.sum()):6d}  addon "
              f"min={a.min():7.2f} p10={np.percentile(a,10):6.2f} "
              f"med={np.median(a):6.2f} p90={np.percentile(a,90):6.2f} "
              f"neg%={(a<0).mean()*100:5.1f}")

    print("\n=== 权威高度 分带 ===")
    for name, m in (("rd<1.5 最外圈", ring0), ("rd 1.5-3.5", ring1),
                    ("rd 3.5-6.5", ring2), ("扇区 ro<4", fan), ("远沙地", sand)):
        if not m.any():
            continue
        h = hf513[m]
        print(f"  {name:16s} n={int(m.sum()):6d}  h "
              f"min={h.min():7.2f} p10={np.percentile(h,10):6.2f} "
              f"med={np.median(h):6.2f} p90={np.percentile(h,90):6.2f}")

    # 山脚壕沟：岩体外 2 格高度 < 相邻远沙地中位 - 0.15
    sand_med = float(np.median(hf513[sand])) if sand.any() else 0.6
    near = (ro_v > 0) & (ro_v <= 2.5) & ~rock_v
    moat = near & (hf513 < sand_med - 0.15)
    print(f"\n远沙地中位高度 {sand_med:.3f}")
    print(f"岩体外 2.5 格低于沙地 0.15 的壕沟格: {int(moat.sum())} / {int(near.sum())} "
          f"= {moat.mean()*100 if near.any() else 0:.1f}% of near-fan")
    if moat.any():
        print(f"  壕沟深度: min={hf513[moat].min():.2f} med={np.median(hf513[moat]):.2f} "
              f"相对沙地 {np.median(hf513[moat])-sand_med:.2f}")

    # 岩体内缘相对"再往里 4 格"是否下凹（ rim 比内侧低很多是正常裙；
    # 比两侧同深度的点低才是沿缘的凹陷）
    boundary = rock_v & (rd_v < 2.0)
    # 沿边界，比较每个点与同 rd 带的中位
    band = rock_v & (rd_v < 2.5)
    if band.any():
        med = float(np.median(addon[band]))
        dips = band & (addon < med - 1.0)
        print(f"\nrd<2.5 带 addon 中位 {med:.2f}；低于中位 1.0 的点 "
              f"{int(dips.sum())} / {int(band.sum())} = {dips.mean()*100:.1f}%")
        if dips.any():
            print(f"  这些点 addon min={addon[dips].min():.2f} p50={np.median(addon[dips]):.2f}")


if __name__ == "__main__":
    main()
