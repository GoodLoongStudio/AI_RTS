"""地形剖面探针：读游戏内实际使用的 height_data.bin，打印剖面与高度直方图。

回答两个问题（不靠看图）：
  1) 台地是不是真的 32m 高台（剖面是否有清晰台面 + 陡坎）？
  2) 山体是不是"平顶大饼"（剖面顶部是平的还是有起伏）？

坐标口径：
  height_data 顶点 k 对应语义 (k/2)；游戏世界 = 语义 × 4。
  G2 语义坐标 = review 世界 / 3.90625。
"""
import sys
import numpy as np
from pathlib import Path

BIN = Path(sys.argv[1] if len(sys.argv) > 1 else
           r"G:/AIRTS/AI_RTS/source/match/maps/generated/16-0-7d337ce8be/height_data.bin")
data = np.fromfile(BIN, dtype=np.int32, count=2)
w, h = int(data[0]), int(data[1])
hf = np.fromfile(BIN, dtype=np.float32, offset=8).reshape(h, w)
print(f"height_data {w}x{h}  秒米单位（世界 = 秒 x4）")
print(f"高度 min={hf.min():.2f} max={hf.max():.2f} mean={hf.mean():.2f}")

# 高度直方图（找"台面"所在的离散台阶）
hist, edges = np.histogram(hf, bins=24)
tot = hf.size
print("\n高度分布（语义米 -> 占比）:")
for i in range(len(hist)):
    if hist[i] / tot < 0.001:
        continue
    print(f"  {edges[i]:7.2f}..{edges[i+1]:7.2f}  {hist[i]/tot*100:6.2f}%  (世界 {edges[i]*4:7.1f}..{edges[i+1]*4:7.1f} m)")

SEM2V = 2.0  # 顶点 = 语义 * 2


def profile(cx_sem, cz_sem, axis, length_sem, label, step_sem=2.0):
    ax = np.asarray(axis, dtype=np.float64)
    ax /= max(np.linalg.norm(ax), 1e-9)
    print(f"\n=== 剖面 {label}  中心语义({cx_sem:.1f},{cz_sem:.1f}) 轴({ax[0]:.2f},{ax[1]:.2f}) 长±{length_sem:.0f}m ===")
    vals = []
    for t in np.arange(-length_sem, length_sem + 1e-6, step_sem):
        sx = cx_sem + ax[0] * t
        sz = cz_sem + ax[1] * t
        i = int(round(sx * SEM2V))
        j = int(round(sz * SEM2V))
        if 0 <= i < w and 0 <= j < h:
            vals.append((t, float(hf[j, i])))
    line = "  "
    for k, (t, v) in enumerate(vals):
        line += f"{v:5.1f} "
        if (k + 1) % 16 == 0:
            print(line)
            line = "  "
    if line.strip():
        print(line)
    vs = np.array([v for _, v in vals])
    if vs.size:
        d = np.abs(np.diff(vs))
        print(f"  端点 {vs[0]:.1f} -> {vs[-1]:.1f}；最大单步跳变 {d.max():.2f} 语义米（{d.max()*4:.1f} 世界米，"
              f"{np.degrees(np.arctan2(d.max()*4, step_sem*4)):.1f}°）")


# 台地：home plateau #0 中心，沿 ramp_dirs[0] 方向
profile(367.03, 389.60, (-0.5222, 0.8528), 70, "台地#0（沿坡道方向）")
# 山体：mountain_focus/3.90625
profile(1752.724 / 3.90625, 1655.545 / 3.90625, (1.0, 0.0), 90, "山体（东西向）")
profile(1752.724 / 3.90625, 1655.545 / 3.90625, (0.0, 1.0), 90, "山体（南北向）")
profile(1638.672 / 3.90625, 1365.234 / 3.90625, (-0.36566, -0.93075), 80, "山脚外法线（向山）")
# 平地对照
profile(200.0, 700.0, (1.0, 0.0), 60, "平坦沙漠对照")
