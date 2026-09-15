"""把实机渲染图与高度场对齐，客观测「台地面 vs 平地」的色差。

机位口径（与 capture_generated_map_views.gd 的 plateau_ramp 一致）：
  ortho, size=520, pitch=45, dist=620, focus（游戏世界米）=(1545.4, 1432.2)
正交相机像素 -> 地面：
  世界 x = focus.x + (px - W/2) * s
  世界 z = focus.z - (H/2 - py) * s / sin(pitch)
  其中 s = size / H（纵向每像素米数，横向同 s，因为正交相机 size 是纵向尺寸而
  横向 = size * 16/9 且横向像素也多 16/9 倍）
高度场：height_data 顶点 k 对应语义 (k/2)，游戏世界 = 语义 x 4。
"""
import sys
import numpy as np
from PIL import Image
from pathlib import Path

IMG = Path(sys.argv[1] if len(sys.argv) > 1 else
           r"G:/AIRTS/RTS_Map_Tool/review/G4/g2_large_lake_kits/g116_plateau_ramp.png")
BIN = Path(r"G:/AIRTS/AI_RTS/source/match/maps/generated/16-0-7d337ce8be/height_data.bin")

hdr = np.fromfile(BIN, dtype=np.int32, count=2)
w, h = int(hdr[0]), int(hdr[1])
hf = np.fromfile(BIN, dtype=np.float32, offset=8).reshape(h, w)
SEM2V = 2.0

SIZE = 520.0
PITCH = 45.0
FOCUS = (1545.4, 1432.2)   # 游戏世界米

im = np.asarray(Image.open(IMG).convert("RGB")).astype(np.float32)
H, W = im.shape[:2]
s = SIZE / H                       # 米 / 像素（纵向）
sx = SIZE * (16.0 / 9.0) / W       # 米 / 像素（横向）—— 应等于 s
print(f"图 {W}x{H}  纵向 {s:.4f} m/px  横向 {sx:.4f} m/px")


def world_of(px, py):
    return (FOCUS[0] + (px - W / 2.0) * sx,
            FOCUS[1] - (H / 2.0 - py) * s / np.sin(np.deg2rad(PITCH)))


def height_at(wx, wz):
    i = int(round(wx / 4.0 * SEM2V))
    j = int(round(wz / 4.0 * SEM2V))
    if 0 <= i < w and 0 <= j < h:
        return float(hf[j, i])
    return float("nan")


# 多列聚合。口径要严：只取「高度≈台地面 且 局部平坦」的像素为台面，
# 「高度≈平地 且 局部平坦」为平地 —— 否则山坡/山体/崖壁像素混进来，
# 测出来的不是台面 vs 平地的对比（第一版就是这样，方差极大）。
from scipy import ndimage as ndi

_fmin = ndi.minimum_filter(hf, size=9)
_fmax = ndi.maximum_filter(hf, size=9)
_flat = (_fmax - _fmin) < 0.8          # 9 顶点窗口内起伏 < 0.8 语义米 → 平坦


def sample(wx, wz):
    i = int(round(wx / 4.0 * SEM2V))
    j = int(round(wz / 4.0 * SEM2V))
    if 0 <= i < w and 0 <= j < h:
        return float(hf[j, i]), bool(_flat[j, i])
    return float("nan"), False


TOP, PLAIN = [], []
for wx_const in np.arange(FOCUS[0] - 400.0, FOCUS[0] + 400.0 + 1e-6, 25.0):
    px = int(round(W / 2.0 + (wx_const - FOCUS[0]) / sx))
    if not (0 <= px < W):
        continue
    for py in range(40, H - 40, 3):
        wz = world_of(px, py)[1]
        hh, fl = sample(wx_const, wz)
        if not np.isfinite(hh) or not fl:
            continue
        rgb = im[py, px]
        if abs(hh - 8.1) < 0.25:
            TOP.append(rgb)
        elif abs(hh - 0.6) < 0.15:
            PLAIN.append(rgb)


def stats(name, arr):
    a = np.array(arr, dtype=np.float64)
    lum = a @ np.array([0.299, 0.587, 0.114])
    sat = a.max(axis=1) - a.min(axis=1)
    print(f"  {name:8s} n={len(a):6d}  RGB={a.mean(axis=0).round(1)}  亮度={lum.mean():6.1f}  (max-min)={sat.mean():5.1f}")
    return a, lum


print(f"\n=== 聚合（x 从 {FOCUS[0]-400:.0f} 到 {FOCUS[0]+400:.0f}，每 50m 一列，每列每 3px）===")
t, tl = stats("台地面", TOP)
p, pl = stats("平地", PLAIN)
if len(t) and len(p):
    print(f"  Δ亮度 = {tl.mean()-pl.mean():+.1f}  相对 {abs(tl.mean()-pl.mean())/pl.mean()*100:.1f}%")
    print(f"  ΔRGB  = {(t.mean(axis=0)-p.mean(axis=0)).round(1)}")
