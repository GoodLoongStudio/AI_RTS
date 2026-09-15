"""检测 assets/terrain_pbr 贴图的可无缝平铺程度。

卷绕处（首列 vs 末列 / 首行 vs 末行）平均绝对差越小越无缝；
差值大 = 平铺时出现硬直边（shader 里按 base_uv*k 平铺 → 地面出现矩形拼缝）。
"""
import sys
import numpy as np
from PIL import Image
from pathlib import Path

d = Path(sys.argv[1] if len(sys.argv) > 1 else r"G:/AIRTS/AI_RTS/assets/terrain_pbr")
rows = []
for p in sorted(d.glob("*.jpg")):
    if "normal" in p.name or "rough" in p.name:
        continue
    im = Image.open(p).convert("L")
    a = np.asarray(im).astype(np.float32)
    sx = float(np.abs(a[:, 0] - a[:, -1]).mean())
    sy = float(np.abs(a[0, :] - a[-1, :]).mean())
    # 参考：图内相邻列的平均差（“自然纹理梯度”基准）
    ref = float(np.abs(np.diff(a, axis=1)).mean())
    rows.append((max(sx, sy) / max(ref, 1e-6), sx, sy, ref, p.name, im.size))
rows.sort(reverse=True)
print(f'{"file":34s} {"size":11s} {"seamX":>6s} {"seamY":>6s} {"邻列":>6s} {"比值":>6s}')
for r, sx, sy, ref, name, size in rows:
    print(f"{name:34s} {str(size):11s} {sx:6.1f} {sy:6.1f} {ref:6.2f} {r:6.1f}")
