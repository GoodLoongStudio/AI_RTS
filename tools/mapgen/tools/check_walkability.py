"""部队通行性的确定性几何验证（不依赖 Godot NavigationServer）。

输入：G4 导出的权威 height_data.bin（513x513 顶点，含山体）+ nav_targets.json。
规则（与 AI_RTS MatchConstants 一致）：
  - agent_max_slope = 45 度 -> 可走条件：相邻格坡度 <= 1.0（tan45）
  - 水面 y=0：水下（h < -0.35）不可走（过河走桥）
  - 桥面 h=0.6 可走
输出：连通分量统计、4 出生点两两连通矩阵、资源点可达率、山体阻挡统计。
"""

import json
import struct
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools._paths import DEFAULT_HEIGHT, ROOT  # noqa: E402

HEIGHT = str(DEFAULT_HEIGHT)
TARGETS = str(ROOT / "workbench_output" / "g2_large_lake_kits" / "g4_export" / "nav_targets.json")

d = open(HEIGHT, "rb").read()
w, h = struct.unpack("<ii", d[:8])
z = np.frombuffer(d[8:], dtype=np.float32).reshape(h, w)
cell = 2048.0 / (w - 1)

# ---- 可走判定：坡度 <= 45 度 且 非水下 ----
gy = np.abs(np.diff(z, axis=0)) / cell          # z 向坡度（格间）
gx = np.abs(np.diff(z, axis=1)) / cell          # x 向坡度
slope = np.zeros_like(z)
slope[:, :-1] = np.maximum(slope[:, :-1], gx)
slope[:-1, :] = np.maximum(slope[:-1, :], gy)
walkable = (slope <= 1.0) & (z > -0.35)

# ---- 连通分量（4 邻）----
from scipy import ndimage
labels, n = ndimage.label(walkable)
sizes = np.bincount(labels.ravel())
sizes[0] = 0
order = np.argsort(sizes)[::-1]
print(f"grid {w}x{h}  cell={cell:.2f}m  walkable={walkable.mean()*100:.1f}%  components={n}")
for k in order[:5]:
    if sizes[k] > 0:
        print(f"  component #{k}: {sizes[k]} cells ({sizes[k]*cell*cell:.0f} m2)")

# ---- 出生点与资源点连通性 ----
targets = json.load(open(TARGETS, encoding="utf-8"))
spawns = [t for t in targets["targets"] if "spawn" in str(t.get("name", "")).lower()]
rest = [t for t in targets["targets"] if "spawn" not in str(t.get("name", "")).lower()]

def comp_of(x_m: float, z_m: float) -> int:
    i = int(np.clip(round(x_m / cell), 0, w - 1))
    j = int(np.clip(round(z_m / cell), 0, h - 1))
    return int(labels[j, i])

main_comp = max(range(1, n + 1), key=lambda k: sizes[k])
print(f"main component: #{main_comp} ({sizes[main_comp]*cell*cell:.0f} m2)")

ok_spawn = 0
for t in spawns:
    c = comp_of(float(t["x"]), float(t["z"]))
    ok = c == main_comp
    ok_spawn += ok
    print(f"  spawn {t.get('name','?')}: comp={c} main={ok}")
print(f"spawns on main: {ok_spawn}/{len(spawns)}")

if rest:
    reach = sum(1 for t in rest if comp_of(float(t["x"]), float(t["z"])) == main_comp)
    print(f"targets on main: {reach}/{len(rest)}")

# ---- 山体阻挡统计 ----
mountain = z > 10.0
print(f"mountain cells (h>10m): {mountain.sum()} ({mountain.mean()*100:.1f}%)  max={z.max():.1f}m")
# 山体是否构成有效分隔（山体格不属于 main 分量即阻挡成立）
mountain_blocking = int((mountain & (labels != main_comp)).sum())
print(f"mountain cells blocking (not on main): {mountain_blocking}")


# ---- 可视化输出：连通分量着色图（G2 会话布局修复的输入）----
from PIL import Image

def _comp_color(lab_val: int, main: int, size: int) -> tuple:
    if lab_val == 0:
        return (52, 48, 46)          # 不可走（崖壁/山/水）：深灰
    if lab_val == main:
        return (232, 176, 64)        # 主连通分量：金橙
    hue = (lab_val * 47) % 360
    import colorsys
    r, g, b = colorsys.hsv_to_rgb(hue / 360.0, 0.55, 0.85)
    return (int(r * 255), int(g * 255), int(b * 255))

img = np.zeros((h, w, 3), dtype=np.uint8)
for lab_val in range(0, n + 1):
    mask = labels == lab_val
    if mask.any():
        img[mask] = _comp_color(lab_val, main_comp, int(sizes[lab_val] if lab_val < len(sizes) else 0))

# 目标点标注：可达=白圈，不可达=红圈+红叉
from PIL import ImageDraw
pil = Image.fromarray(img)
dr = ImageDraw.Draw(pil)
for t in targets_list if (targets_list := targets.get("targets", [])) else []:
    i = int(np.clip(round(float(t["x"]) / cell), 0, w - 1))
    j = int(np.clip(round(float(t["z"]) / cell), 0, h - 1))
    c = comp_of(float(t["x"]), float(t["z"]))
    ok = c == main_comp
    color = (255, 255, 255) if ok else (255, 40, 40)
    dr.ellipse([i - 5, j - 5, i + 5, j + 5], outline=color, width=3)
    if not ok:
        dr.line([i - 8, j - 8, i + 8, j + 8], fill=(255, 40, 40), width=2)
        dr.line([i - 8, j + 8, i + 8, j - 8], fill=(255, 40, 40), width=2)

pil = pil.resize((w * 2, h * 2), Image.NEAREST)
out_png = r"G://AIRTS//RTS_Map_Tool//review//G4//g2_large_lake_kits//walkability_components.png"
pil.save(out_png)
print("visualization ->", out_png)
