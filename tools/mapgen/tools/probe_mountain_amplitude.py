"""实测 mountain_addon 的幅值分布：新旧系数对比 + 峰高归因。

用户："把山的高度都提高一点"。改系数后高度直方图只涨了 0.4 语义米，
说明峰值不由被改的那一项主导，或输出被别处限制 —— 必须实测而不是推算。

用法：python tools/probe_mountain_amplitude.py [seed]
"""
import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from rtsmap.contract import GRID_H, GRID_W  # noqa: E402
from rtsmap.gates import g4_terrain_mountains as M  # noqa: E402
from rtsmap.gates.g2_landforms import polygon_mask  # noqa: E402

R = ROOT / "workbench_output" / "single_large_lake" / "runs"
SEED = sys.argv[1] if len(sys.argv) > 1 else "16"
spec = json.loads((R / SEED / "G2" / "mapspec.json").read_text(encoding="utf-8"))
grid = np.load(R / SEED / "G3" / "mapgrid.npz")
blocking = grid["blocking"] > 0
water = grid["water_footprint"] > 0
region = np.zeros((GRID_H, GRID_W), dtype=bool)
for pl in spec.get("plateaus", []):
    region |= polygon_mask(np.asarray(pl["outline"], dtype=float))

rock_v, rd_v, ro_v = M.vertex_rock_fields(blocking, region, water)
print(f"rock 顶点 {int(rock_v.sum())} / {rock_v.size}（{rock_v.mean()*100:.1f}%）"
      f"  rock_depth max = {rd_v.max():.1f} 格")

vi = np.arange(513, dtype=np.float64)
vx, vz = np.meshgrid(vi, vi)
addon = M.mountain_addon(vx.ravel(), vz.ravel(), rd_v.ravel(), ro_v.ravel())
addon = addon.reshape(513, 513)
rock_only = addon[rock_v]
print(f"addon（岩体内）: max={rock_only.max():.2f}  p99={np.percentile(rock_only,99):.2f}  "
      f"p90={np.percentile(rock_only,90):.2f}  mean={rock_only.mean():.2f}  (语义米)")
print(f"addon 全图 max={addon.max():.2f}  非岩体 max={addon[~rock_v].max():.2f}")

# 峰高归因：取最高的 200 个岩体顶点，看 core / crest 的取值
ri = np.flatnonzero(rock_v)
top = ri[np.argsort(addon.ravel()[ri])[-200:]]
xs, zs = vx.ravel()[top], vz.ravel()[top]
rd = rd_v.ravel()[top]
dmax = max(float(rd_v.max()), 1.0)


def smoothstep(a, b, v):
    t = np.clip((v - a) / max(b - a, 1e-9), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


core = smoothstep(0.0, dmax * 0.45, rd)
edge = smoothstep(0.0, dmax * 0.06, rd)
rg1 = 1.0 - np.abs(M._value_noise(xs, zs, 0.010, 3, 31011))
rg2 = 1.0 - np.abs(M._value_noise(xs, zs, 0.028, 2, 31012))
rg3 = 1.0 - np.abs(M._value_noise(xs, zs, 0.075, 1, 31013))
crest = 0.55 * rg1 + 0.30 * rg2 + 0.15 * rg3
fn_b = M._hash_noise_pair(xs * 0.55, zs * 0.55, 20260912) * 0.5 + 0.5
print(f"\n最高 200 顶点的均值：core={core.mean():.3f} crest={crest.mean():.3f} "
      f"rg2={rg2.mean():.3f} fn_b={fn_b.mean():.3f} rd={rd.mean():.1f}/{dmax:.0f}")
print(f"  -> core 项最大贡献 = core*(8.0+10.5*crest*core+3*rg2) 峰值≈{core.max()*(8.0+10.5*crest.max()*core.max()+3*rg2.max()):.2f}")
print(f"  -> 实测 addon max = {rock_only.max():.2f}（含 +0.5+fn_b 与 -0.6*3.90625={0.6*3.90625:.2f} 的基线修正）")
print(f"  可知 '峰值 = 16 语义' 是各噪声同时取极值的上界，实际由 crest 的分布决定："
      f"crest p99={np.percentile(crest,99):.3f} max={crest.max():.3f}")
