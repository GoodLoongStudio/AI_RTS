"""对游戏内截图做 FFT，客观测出"矩形拼缝"的空间周期（世界米）。

已知机位参数（与 capture_generated_map_views.gd 一致）：
  river_close: ortho, size=240, pitch=34, 分辨率 1920x1080
  横向 1px = 240*16/9/1920 米；纵向 1px = (240/sin34)/1080 米
"""
import sys
import numpy as np
from PIL import Image

path = sys.argv[1] if len(sys.argv) > 1 else \
    r"G:/AIRTS/RTS_Map_Tool/review/G4/g2_large_lake_kits/g110_river_close.png"
box = tuple(int(v) for v in (sys.argv[2].split(",") if len(sys.argv) > 2
                             else "1150,700,1800,1000".split(",")))
m_per_px_x = 240.0 * 16.0 / 9.0 / 1920.0
m_per_px_y = (240.0 / np.sin(np.deg2rad(34.0))) / 1080.0
print("每像素米数 x=%.3f y=%.3f" % (m_per_px_x, m_per_px_y))

im = Image.open(path).convert("L")
a = np.asarray(im.crop(box)).astype(np.float64)
print("crop", a.shape, "-> 世界尺寸 %.0f x %.0f m" %
      (a.shape[1] * m_per_px_x, a.shape[0] * m_per_px_y))

# 高通：减去大尺度趋势，只留拼缝类结构
def hp(x, k):
    from scipy import ndimage as ndi
    return x - ndi.gaussian_filter(x, k)

for axis, label, mpp in ((1, "X（屏幕横 = 世界横向）", m_per_px_x),
                         (0, "Y（屏幕纵 = 世界纵深）", m_per_px_y)):
    prof = hp(a, max(a.shape[axis] / 8.0, 3.0))
    prof = prof.mean(axis=1 - axis)
    prof -= prof.mean()
    n = len(prof)
    w = np.hanning(n)
    f = np.abs(np.fft.rfft(prof * w))
    freqs = np.fft.rfftfreq(n, d=mpp)          # 周期倒数（1/米）
    f[0:2] = 0
    top = np.argsort(f)[::-1][:6]
    print(f"--- {label} 主周期 ---")
    for i in sorted(top, key=lambda i: -f[i]):
        if freqs[i] <= 0:
            continue
        print("   周期 %8.1f m   幅度 %8.1f" % (1.0 / freqs[i], f[i]))
