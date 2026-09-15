"""找出「孤立凸起小台」——平地上莫名冒出的小平台/坡道（用户红框里的东西）。

判定：高度场里 h > 1.5 语义米（世界 6m）的连通块，面积 3~400 语义格，
且**不与任何台地轮廓相接**（用 G2 plateau outline 判定）。

这些孤立凸起在正常地貌里不该存在：台地面只应在台地轮廓内，
坡面只应在轮廓边缘的坡口带上。

用法：python tools/find_orphan_plates.py [seed]
"""
import json
import sys
from pathlib import Path

import numpy as np
from scipy import ndimage

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools._paths import DEFAULT_HEIGHT  # noqa: E402
from rtsmap.gates.g2_landforms import polygon_mask  # noqa: E402

R = ROOT / "workbench_output" / "single_large_lake" / "runs"
SEED = sys.argv[1] if len(sys.argv) > 1 else "16"
spec = json.loads((R / SEED / "G2" / "mapspec.json").read_text(encoding="utf-8"))
BIN = DEFAULT_HEIGHT

raw = BIN.read_bytes()
vw, vh = np.frombuffer(raw[:8], dtype=np.int32)
hf = np.frombuffer(raw[8:], dtype=np.float32).reshape(vh, vw)   # 1025², 语义米
G, P = 0.6, 8.1

# 1025 顶点 -> 512 语义格（每格取中心）
sem = hf[1::2, 1::2][:512, :512]

region = np.zeros((512, 512), dtype=bool)
for pl in spec.get("plateaus", []):
    region |= polygon_mask(np.asarray(pl["outline"], dtype=float))
region_d = ndimage.binary_dilation(region, iterations=8)   # 轮廓外 8 格（32m）内算"贴台地"

elev = sem > (G + 1.0)                                     # 明显高于平地
lab, n = ndimage.label(elev)
print(f"高于平地 1.0 语义米的连通块 {n} 个；台地轮廓内 {int((elev & region).sum())} 格")

sizes = ndimage.sum(elev, lab, range(1, n + 1))
orphans = []
for k in range(1, n + 1):
    m = lab == k
    if m.sum() < 3 or m.sum() > 400:
        continue
    if (m & region).any():
        continue                       # 与台地重合/相接 → 正常
    if (m & region_d).any():
        continue                       # 紧贴台地边缘 → 可能是坡面/崖脚
    ii, jj = np.nonzero(m)
    orphans.append({
        "cells": int(m.sum()),
        "center_sem": (float(jj.mean() + 0.5), float(ii.mean() + 0.5)),
        "center_world": (float((jj.mean() + 0.5) * 4), float((ii.mean() + 0.5) * 4)),
        "bbox_sem": [int(jj.min()), int(ii.min()), int(jj.max()), int(ii.max())],
        "h_min": round(float(sem[m].min()), 2), "h_max": round(float(sem[m].max()), 2),
    })

orphans.sort(key=lambda o: -o["cells"])
print(f"\n=== 孤立凸起小台（与任何台地轮廓都不相接）：{len(orphans)} 个 ===")
print(f"{'格数':>5s} {'中心(语义)':>18s} {'中心(世界m)':>16s} {'bbox(语义)':>22s} {'高度范围':>12s}")
for o in orphans[:20]:
    cs, cw, bb = o["center_sem"], o["center_world"], o["bbox_sem"]
    print(f"{o['cells']:5d} ({cs[0]:7.1f},{cs[1]:6.1f}) ({cw[0]:7.0f},{cw[1]:6.0f}) "
          f"[{bb[0]:3d},{bb[1]:3d}..{bb[2]:3d},{bb[3]:3d}] {o['h_min']:5.2f}~{o['h_max']:5.2f}")

# 对照：每个台地的 ramp_centers 与轮廓的关系
print("\n=== 各台地 ramp_centers 到自身轮廓的距离（语义格）===")
from scipy import ndimage as ndi
for k, pl in enumerate(spec.get("plateaus", [])):
    m = polygon_mask(np.asarray(pl["outline"], dtype=float))
    if not m.any():
        continue
    din = ndi.distance_transform_edt(m)          # 内部到边界的距离
    dout = ndi.distance_transform_edt(~m)        # 外部到边界的距离
    line = []
    for rc in pl.get("ramp_centers", []):
        j, i = int(rc[0]), int(rc[1])
        inside = m[i, j]
        d = float(din[i, j]) if inside else -float(dout[i, j])
        line.append(f"({rc[0]:.0f},{rc[1]:.0f}) 内={inside} 距边={d:+.1f}")
    print(f"  plateau#{k} {pl.get('kind','?'):8s} 面积{int(m.sum()):6d}格 : " + " | ".join(line))
