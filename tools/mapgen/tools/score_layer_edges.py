"""给逐层隔离图打"直线硬边"分：矩形拼缝会在竖直/水平方向形成贯穿多行的强梯度线。

做法：对裁剪区求 |∂/∂x| 与 |∂/∂y|；按列（行）统计落在强梯度阈值以上的像素数，
取最大列/行计数作为分数（一条贯穿整幅的直边 → 接近裁剪区高度/宽度）。
"""
import sys
import glob
import os
import numpy as np
from PIL import Image

OUT = r"G:/AIRTS/RTS_Map_Tool/review/G4/g2_large_lake_kits"
BOX = (1150, 700, 1800, 1000)

rows = []
for f in sorted(glob.glob(os.path.join(OUT, "layer_L_*.png"))) + \
        [os.path.join(OUT, "g110_river_close.png")]:
    if not os.path.exists(f):
        continue
    a = np.asarray(Image.open(f).convert("L").crop(BOX)).astype(np.float32)
    name = os.path.basename(f).replace("layer_", "").replace(".png", "")
    for axis, tag in ((1, "竖"), (0, "横")):
        g = np.abs(np.diff(a, axis=axis))
        thr = np.percentile(g, 99.0)
        hot = g > max(thr, 1e-6)
        counts = hot.sum(axis=1 - axis)
        n = (a.shape[1] if axis == 0 else a.shape[0])
        rows.append((counts.max() / max(n, 1), name, tag, g.mean()))
print(f'{"layer":16s} {"方向":4s} {"贯穿比":>7s} {"平均梯度":>8s}')
for score, name, tag, gm in sorted(rows, reverse=True)[:24]:
    print(f"{name:16s} {tag:4s} {score:7.2f} {gm:8.2f}")
