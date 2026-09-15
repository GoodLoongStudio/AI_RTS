"""山体形态探针：量"是平顶台地还是带脊的山"。

指标（全部用游戏内 height_data.bin，语义米；世界 = x4）：
  1) 高区面积占比（h > 0.8*max）：平顶台地 → 面积巨大；脊状山 → 面积小
  2) 高区高度标准差：平顶 → tiny；有脊/有峰 → 明显
  3) 局部起伏（100m 窗口内 max-min 的中位数）：衡量"碎不碎"
  4) 通过最高点的四个方向剖面：看是不是"上去一大片平台"

用法：python tools/probe_mountain_shape.py
"""
import sys
from pathlib import Path

import numpy as np
from scipy import ndimage

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools._paths import DEFAULT_HEIGHT  # noqa: E402

BIN = DEFAULT_HEIGHT
SEM2V = 2.0

raw = BIN.read_bytes()
vw, vh = np.frombuffer(raw[:8], dtype=np.int32)
hf = np.frombuffer(raw[8:], dtype=np.float32).reshape(vh, vw)
# 1025 顶点 -> 512 语义格（取格中心）
sem = hf[1::2, 1::2][:512, :512]
peak = float(sem.max())
hi = sem > 0.8 * peak
print(f"峰高 {peak:.2f} 语义米（世界 {peak*4:.0f} m）")
print(f"高区（> {0.8*peak:.2f}）面积 = {int(hi.sum())} 语义格 = {int(hi.sum())*16:,} m2 "
      f"（占地图 {hi.mean()*100:.2f}%）")
print(f"高区高度标准差 = {float(sem[hi].std()):.3f} 语义米  "
      f"（平顶台地 ≈0.1~0.3；带脊山体 >0.8）")

# 局部起伏：100m 窗口(25 格) 内 max-min 的中位数，只看高区
w = 25
mx = ndimage.maximum_filter(sem, size=w)
mn = ndimage.minimum_filter(sem, size=w)
relief = mx - mn
print(f"高区 100m 窗口起伏：中位数 {float(np.median(relief[hi])):.2f} 语义米"
      f"（{float(np.median(relief[hi]))*4:.1f} m）；90 分位 {float(np.percentile(relief[hi],90)):.2f}")
print(f"全图 100m 窗口起伏：中位数 {float(np.median(relief)):.2f} 语义米")

# 通过最高点的四向剖面（步长 4 语义米 = 8 顶点）
pi, pj = np.unravel_index(int(np.argmax(sem)), sem.shape)
print(f"\n最高点在语义格 ({pj},{pi}) = 世界 ({pj*4},{pi*4})")
for name, (di, dj) in (("东", (0, 1)), ("西", (0, -1)), ("南", (1, 0)), ("北", (-1, 0))):
    vals = []
    for t in range(0, 41, 2):        # ±80 语义米
        i, j = pi + di * t, pj + dj * t
        if 0 <= i < 512 and 0 <= j < 512:
            vals.append(sem[i, j])
    if vals:
        print(f"  {name}（±80m，步长 8m）: " + " ".join(f"{v:5.1f}" for v in vals))

# 高区连通块数：峰应该扎堆成脊，而不是一整块
lab, n = ndimage.label(hi)
sizes = np.bincount(lab.ravel()); sizes[0] = 0
big = np.sort(sizes)[::-1][:6]
print(f"\n> 0.8*峰 的连通块 {n} 个，最大几块面积（语义格）: {[int(x) for x in big if x>0]}")
