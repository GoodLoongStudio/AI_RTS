"""打印台地内凹陷块的样本格 + 掩码归属，定位是哪个掩码把台顶挖掉了。

用法：python tools/dump_plateau_depression.py [seed] [plateau_index]
"""
import json
import sys
from pathlib import Path

import numpy as np
from scipy import ndimage

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools._paths import DEFAULT_HEIGHT  # noqa: E402
from rtsmap.contract import GRID_H, GRID_W  # noqa: E402
from rtsmap.gates.g4_export import G4_PARAMS_DEFAULTS  # noqa: E402
from rtsmap.gates.g4_terrain import classify  # noqa: E402
from rtsmap.grid import MapGrid  # noqa: E402

R = ROOT / "workbench_output" / "single_large_lake" / "runs"
SEED = sys.argv[1] if len(sys.argv) > 1 else "16"
PK = int(sys.argv[2]) if len(sys.argv) > 2 else 2
spec = json.loads((R / SEED / "G2" / "mapspec.json").read_text(encoding="utf-8"))
grid = MapGrid.load(R / SEED / "G3" / "mapgrid.npz")
m = classify(grid, dict(G4_PARAMS_DEFAULTS), spec["plateaus"])
print("classify 掩码键:", sorted(m.keys()))

BIN = DEFAULT_HEIGHT
raw = BIN.read_bytes()
vw, vh = np.frombuffer(raw[:8], dtype=np.int32)
hf = np.frombuffer(raw[8:], dtype=np.float32).reshape(vh, vw)
# 用精确的 513 语义网格（hf1025[2k] == hf513[k]）。
# 注意**不要**用 hf[1::2,1::2]（那是 1025 上的插值中点）：在台地边界处
# 会把相邻的平地值一起平均进来，凭空造出 4~5 语义米的假凹陷。
sem = hf[::2, ::2][:512, :512]
TOP = float(G4_PARAMS_DEFAULTS["plateau_level"])

pl = spec["plateaus"][PK]
from rtsmap.gates.g2_landforms import polygon_mask
region = polygon_mask(np.asarray(pl["outline"], dtype=float))   # 只看该台地
dep = region & (sem < TOP - 0.3)
lab, n = ndimage.label(dep)
sizes = np.bincount(lab.ravel()); sizes[0] = 0
k = int(np.argmax(sizes))
mm = lab == k
print(f"\nplateau#{PK} 最大凹陷块 {int(mm.sum())} 格；样本：")
ii, jj = np.nonzero(mm)
for t in np.linspace(0, len(ii) - 1, 10).astype(int):
    i, j = int(ii[t]), int(jj[t])
    print(f"  ({j:3d},{i:3d})  h={sem[i,j]:6.2f}  "
          f"open_={bool(m['open_'][i,j])} blocking={bool((grid.get('blocking')>0)[i,j])} "
          f"rampG2={bool(m['ramp'][i,j])} plateau_top={bool(m['plateau_top'][i,j])} "
          f"water={bool(m['water'][i,j])}")

# 该块的掩码构成统计
tot = int(mm.sum())
print(f"\n凹陷块的掩码构成（占该块比例）：")
for name in ("open_", "ramp", "plateau_top", "water", "bridge"):
    c = int((mm & m[name]).sum())
    print(f"  {name:12s} {c:5d}/{tot}  {c/max(tot,1)*100:5.1f}%")
blk = (grid.get("blocking") > 0)
print(f"  blocking     {int((mm & blk).sum()):5d}/{tot}  {int((mm & blk).sum())/max(tot,1)*100:5.1f}%")
print(f"  台地轮廓内总格 {int(region.sum())}，其中凹陷 {int(dep.sum())} ({dep.sum()/max(region.sum(),1)*100:.1f}%)")
