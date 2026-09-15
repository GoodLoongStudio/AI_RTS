"""诊断图：blocking 格 + 路线折线 + 阻挡实例外接盒 + 坡道/桥，一张图看清石头压在哪。

用户反馈"石头瞎摆把路都堵上了"——净宽指标只掉了 1 条（14.25->9.75），
所以要看的是【空间关系】而不是单一标量。

用法：python tools/render_lane_blocking_map.py [seed] [out.png]
"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from rtsmap.gates.g3_content import oriented_rect_cells  # noqa: E402

R = ROOT / "workbench_output" / "single_large_lake" / "runs"
SEED = sys.argv[1] if len(sys.argv) > 1 else "16"
OUT = Path(sys.argv[2]) if len(sys.argv) > 2 else \
    ROOT / "review" / "G4" / "g2_large_lake_kits" / "diag_lane_blocking.png"

G2, G3 = R / SEED / "G2", R / SEED / "G3"
grid = np.load(G3 / "mapgrid.npz")
blk = grid["blocking"] > 0
lane_core = grid["lane_core"] > 0
passable = grid["passable"] > 0
lanes = json.loads((G2 / "lanes.json").read_text(encoding="utf-8"))
spec = json.loads((G2 / "mapspec.json").read_text(encoding="utf-8"))
objs = json.loads((G3 / "objects.json").read_text(encoding="utf-8"))["instances"]

H, W = blk.shape
S = 1024
img = Image.new("RGB", (S, S), (24, 24, 28))
d = ImageDraw.Draw(img)
# 可通行=灰 不可通行=近黑
arr = np.zeros((H, W, 3), dtype=np.uint8)
arr[passable] = (70, 70, 74)
arr[blk] = (16, 16, 18)
arr[lane_core] = (52, 46, 30)
img.paste(Image.fromarray(arr).resize((S, S), Image.NEAREST), (0, 0))
d = ImageDraw.Draw(img)
sc = S / float(W)


def P(x, z):
    return (x * sc, z * sc)


# 坡道（G2 spec 的 ramp_centers/dirs，主坡 MAIN_RUN 长度用 kit 常量近似）
for pl in spec.get("plateaus", []):
    for ctr, dr in zip(pl.get("ramp_centers", []), pl.get("ramp_dirs", [])):
        x0, z0 = ctr
        dx, dz = dr
        n = (dx * dx + dz * dz) ** 0.5 or 1.0
        dx, dz = dx / n, dz / n
        a = (x0 - dx * 6, z0 - dz * 6)
        b = (x0 + dx * 30, z0 + dz * 30)
        d.line([P(*a), P(*b)], fill=(0, 200, 255), width=3)
        d.ellipse([P(x0 - 3, z0 - 3), P(x0 + 3, z0 + 3)], outline=(0, 255, 255), width=2)

# 阻挡实例外接盒
for o in objs:
    if not o["blocking"]:
        continue
    w, h = o["extent"]
    cells = list(oriented_rect_cells(o["x"], o["z"], w, h, o["yaw"]))
    if not cells:
        continue
    ii = [c[0] for c in cells]
    jj = [c[1] for c in cells]
    d.rectangle([P(min(jj), min(ii)), P(max(jj) + 1, max(ii) + 1)],
                outline=(255, 150, 0), width=1)

# 路线
for name, lane in lanes.items():
    pl = lane["polyline"]
    d.line([P(p[0], p[1]) for p in pl], fill=(255, 60, 60), width=3)

# 出生点
for i, s in enumerate(spec.get("starts", [])):
    d.ellipse([P(s[0] - 5, s[1] - 5), P(s[0] + 5, s[1] + 5)], outline=(120, 255, 120), width=4)
    d.text(P(s[0] + 6, s[1]), f"P{i}", fill=(120, 255, 120))

# 图例
d.text((10, 8), "grey=passable  black=blocking  red=lane  cyan=ramp  orange=rock box  green=spawn",
       fill=(230, 230, 230))
OUT.parent.mkdir(parents=True, exist_ok=True)
img.save(OUT)
print("wrote", OUT)
print(f"blocking {blk.mean()*100:.1f}%   lane_core {lane_core.mean()*100:.1f}%   "
      f"passable {passable.mean()*100:.1f}%   实例 {len(objs)}")

# 硬指标：路线核心带 & 坡道走廊里的阻挡覆盖率
inter_lane = (blk & lane_core).sum() / max(lane_core.sum(), 1)
print(f"lane_core 内 blocking 覆盖 = {inter_lane*100:.1f}%  "
      f"({int((blk & lane_core).sum())}/{int(lane_core.sum())} 格)")
