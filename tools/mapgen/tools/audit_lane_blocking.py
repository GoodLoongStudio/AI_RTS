"""通道封堵审计：算每条路在【加石头前 / 后】的最小净宽，并点名肇事实例。

背景（用户反馈）："石头瞎摆，把路都堵上了"。
G3 的宽度守卫 `_guard_ok` 只在「净宽 < min(choke_any_min=8, G2 基线) - 0.25」时才拒绝，
且主循环带 `allow_lane_core=True`（允许盒进核心带边缘）—— 所以"没触发守卫"不等于
"路好走"。本脚本给出客观数字：每条路的最小净宽、被压缩比例、以及压缩处的肇事物件。

用法：python tools/audit_lane_blocking.py [seed]
"""
import json
import sys
from pathlib import Path

import numpy as np
from scipy import ndimage as ndi

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from rtsmap.pathing import lane_min_width, lane_samples_along  # noqa: E402

R = ROOT / "workbench_output" / "single_large_lake" / "runs"
SEED = sys.argv[1] if len(sys.argv) > 1 else "16"

G2 = R / SEED / "G2"
G3 = R / SEED / "G3"
lanes = json.loads((G2 / "lanes.json").read_text(encoding="utf-8"))
grid = np.load(G3 / "mapgrid.npz")
blk_final = (grid["blocking"] > 0)
blk_g2 = (grid["blocking_g2"] > 0)
objs = json.loads((G3 / "objects.json").read_text(encoding="utf-8"))["instances"]
print(f"lanes={len(lanes)}  instances={len(objs)}  "
      f"blocking 格 g2={int(blk_g2.sum())} final={int(blk_final.sum())}")

# 每个 blocking 格归属哪个实例（后写覆盖，够用）
owner = {}
for k, o in enumerate(objs):
    if not o["blocking"]:
        continue
    w, h = o["extent"]
    from rtsmap.gates.g3_content import oriented_rect_cells
    for i, j in oriented_rect_cells(o["x"], o["z"], w, h, o["yaw"]):
        if 0 <= i < blk_final.shape[0] and 0 <= j < blk_final.shape[1]:
            owner[(i, j)] = k

rows = []
for name, lane in lanes.items():
    pl = lane["polyline"]
    wg2 = lane_min_width(pl, blk_g2)
    wnow = lane_min_width(pl, blk_final)
    base = lane.get("base", 0.0) or 0.0
    # 找最窄采样点
    worst = min(lane_samples_along(pl, 2.0),
                key=lambda s: 0.0)  # 占位，下面重算
    samples = lane_samples_along(pl, 2.0)
    best = None
    for x, z, nx, nz in samples:
        from rtsmap.pathing import _side_clearance
        wl = _side_clearance(x, z, nx, nz, blk_final, 30.0, sign=-1.0)
        wr = _side_clearance(x, z, nx, nz, blk_final, 30.0, sign=1.0)
        w = min(wl + wr, 30.0)
        if best is None or w < best[0]:
            best = (w, x, z)
    wmin, wx, wz = best if best else (float("nan"), 0.0, 0.0)
    # 该处 3 格内的肇事物件
    culprits = {}
    ci, cj = int(round(wz)), int(round(wx))
    r = 3
    for di in range(-r, r + 1):
        for dj in range(-r, r + 1):
            k = owner.get((ci + di, cj + dj))
            if k is not None:
                o = objs[k]
                culprits[k] = (o["name"], tuple(round(v, 1) for v in o["extent"]))
    rows.append((wnow, wg2, name, lane.get("kind"), base, wmin, (wx, wz),
                 sorted(set(culprits.values()))[:4], len(culprits)))

rows.sort()
print(f"\n{'lane':16s} {'类':5s} {'base':>5s} {'G2净宽':>7s} {'现净宽':>7s} {'最窄点':>13s} {'肇事件(邻域)':>0s}")
for wnow, wg2, name, kind, base, wmin, at, cul, nc in rows:
    flag = ""
    if wnow < 8.0:
        flag = "  <<< 低于 choke_any_min=8"
    elif wg2 > 0 and wnow < wg2 * 0.75:
        flag = "  <<< 被压缩 >25%"
    print(f"{name:16s} {str(kind):5s} {base:5.1f} {wg2:7.2f} {wnow:7.2f} "
          f"({at[0]:5.1f},{at[1]:5.1f}){flag}")
    for nm, ext in cul:
        print(f"      肇事: {nm:38s} extent={ext}")

n_narrow = sum(1 for r in rows if r[0] < 8.0)
n_squeeze = sum(1 for r in rows if r[1] > 0 and r[0] < r[1] * 0.75)
print(f"\n合计：净宽 <8 的路 {n_narrow} 条；被压缩 >25% 的 {n_squeeze} 条")
