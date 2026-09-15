"""通行性验证（**含阻挡实例**）：石头到底有没有把路堵上。

与 tools/check_walkability.py 的区别：那个只看高度场坡度/水面，**不含石头**，
因此查不出"石头堵路"。本脚本把 G3 的最终 `blocking` 通道（= 岩体 + 已放实例盒）
叠到可走判定上，并用 `blocking_g2`（放石头之前）做对照，把封堵单独归因给石头。

判定口径（与 AI_RTS MatchConstants 一致）：
  - agent_max_slope 45° -> 相邻 2m 顶点坡度 <= 1.0
  - 水下 h < -0.35 不可走
  - blocking 格（4m 语义）内不可走

用法：python tools/check_walkability_blocked.py [seed]
"""
import json
import sys
from pathlib import Path

import numpy as np
from scipy import ndimage

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from tools._paths import DEFAULT_HEIGHT  # noqa: E402

R = ROOT / "workbench_output" / "single_large_lake" / "runs"
SEED = sys.argv[1] if len(sys.argv) > 1 else "16"
HEIGHT = DEFAULT_HEIGHT
G3 = R / SEED / "G3"
G2 = R / SEED / "G2"

d = HEIGHT.read_bytes()
w, h = np.frombuffer(d[:8], dtype=np.int32)
z = np.frombuffer(d[8:], dtype=np.float32).reshape(h, w)
cell = 2048.0 / (w - 1)          # 2 m
grid = np.load(G3 / "mapgrid.npz")
spec = json.loads((G2 / "mapspec.json").read_text(encoding="utf-8"))
starts = spec["starts"]
plateaus = spec["plateaus"]

# 坡度可走性（不含石头）
gy = np.abs(np.diff(z, axis=0)) / cell
gx = np.abs(np.diff(z, axis=1)) / cell
slope = np.zeros_like(z)
slope[:, :-1] = np.maximum(slope[:, :-1], gx)
slope[:-1, :] = np.maximum(slope[:-1, :], gy)
slope_walk = (slope <= 1.0) & (z > -0.35)


def blocking_on_vertices(blk4):
    """4m 语义 blocking -> 2m 顶点域（一格盖 2x2 顶点），并做 1 格膨胀：
    单位半径 0.9m，贴边通过需要留出余量（保守判定）。"""
    up = np.repeat(np.repeat(blk4.astype(bool), 2, axis=0), 2, axis=1)
    out = np.zeros((h, w), dtype=bool)
    m = min(up.shape[0], h), min(up.shape[1], w)
    out[:m[0], :m[1]] = up[:m[0], :m[1]]
    return out


def analyse(blk4, label):
    blocked = blocking_on_vertices(blk4)
    walk = slope_walk & ~blocked
    labels, n = ndimage.label(walk)
    sizes = np.bincount(labels.ravel())
    sizes[0] = 0
    order = np.argsort(sizes)[::-1]
    main = int(order[0]) if n else 0
    print(f"\n=== {label} ===")
    print(f"  walkable {walk.mean()*100:5.1f}%   components={n}   "
          f"main #{main} = {sizes[main]*cell*cell:,.0f} m2")

    def comp(x_m, z_m):
        i = int(np.clip(round(x_m / cell), 0, w - 1))
        j = int(np.clip(round(z_m / cell), 0, h - 1))
        return int(labels[j, i])

    res = {}
    for k, s in enumerate(starts):
        # 出生点为语义坐标 -> 世界米
        wx, wz = float(s[0]) * 4.0, float(s[1]) * 4.0
        c = comp(wx, wz)
        res[f"spawn{k}"] = c
    for k, pl in enumerate(plateaus):
        ctr = pl["center"]
        c = comp(float(ctr[0]) * 4.0, float(ctr[1]) * 4.0)
        res[f"plateau{k}"] = c
    for k, name in enumerate(sorted(res)):
        pass
    bad = [k for k, v in res.items() if v != main or v == 0]
    for k, v in res.items():
        tag = ""
        if v == 0:
            tag = "  <<< 不可走吧"
        elif v != main:
            tag = "  <<< 与主连通域隔离"
        print(f"    {k:12s} comp#{v}{tag}")
    print(f"  异常 {len(bad)}/{len(res)}")
    return walk, labels, main, res


w_g2, l_g2, main_g2, res_g2 = analyse(grid["blocking_g2"], "放石头前（G2 blocking）")
w_fn, l_fn, main_fn, res_fn = analyse(grid["blocking"], "放石头后（最终 blocking）")

print("\n=== 归因：石头造成的连通性变化 ===")
for k in res_g2:
    if res_g2[k] == main_g2 and (res_fn[k] != main_fn):
        print(f"  {k}: 由【连通】变为【隔离】 <== 石头封堵")
    elif res_g2[k] != main_g2 and res_fn[k] == main_fn:
        print(f"  {k}: 由隔离变为连通")
print(f"  main 连通域面积 {res_g2 and ''}"
      f"{(np.bincount(l_g2.ravel()).max())*cell*cell:,.0f} -> "
      f"{(np.bincount(l_fn.ravel()).max())*cell*cell:,.0f} m2")

# 成分图
from PIL import Image
S = 1024
arr = np.zeros((h, w, 3), dtype=np.uint8)
arr[w_g2] = (60, 60, 64)
arr[w_fn & ~w_g2] = (30, 90, 30)        # 只看被石头吃掉的格
arr[~w_fn] = (14, 14, 16)
arr[l_fn == main_fn] = np.where(arr[l_fn == main_fn] == 0, arr[l_fn == main_fn],
                                arr[l_fn == main_fn])
img = Image.fromarray(arr).resize((S, S), Image.NEAREST)
img.save(ROOT / "review" / "G4" / "g2_large_lake_kits" / "diag_walkable_blocked.png")
print("\nwrote diag_walkable_blocked.png（灰=仍可走，绿=被石头吃掉，黑=本来就不可走）")
