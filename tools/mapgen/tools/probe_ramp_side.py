"""一条坡道的轴向剖面：沙地必须贴地，坡只在台地区内升起。"""
import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from rtsmap.gates.g2_landforms import polygon_mask  # noqa: E402
from tools._paths import DEFAULT_HEIGHT  # noqa: E402

BIN = DEFAULT_HEIGHT
SPEC = ROOT / "workbench_output" / "large_lake_256" / "runs" / "16" / "G2" / "mapspec.json"

raw = BIN.read_bytes()
vw, vh = np.frombuffer(raw[:8], dtype=np.int32)
hf = np.frombuffer(raw[8:], dtype=np.float32).reshape(int(vh), int(vw))
sem = hf[::2, ::2][:512, :512]
spec = json.loads(SPEC.read_text(encoding="utf-8"))
pl = spec["plateaus"][0]
region = polygon_mask(np.asarray(pl["outline"], dtype=float))
rc = np.array(pl["ramp_centers"][0], dtype=float)
inn = np.array(pl["ramp_dirs"][0], dtype=float)
if float(np.dot(rc - np.array(pl["center"], dtype=float), inn)) > 0:
    inn = -inn
print(f"plateau0 ramp0 rc={rc} inward={inn}")
print("s  ax   h     in_region")
for s in range(-8, 18):
    x = rc[0] + inn[0] * s
    z = rc[1] + inn[1] * s
    j, i = int(np.clip(x, 0, 511)), int(np.clip(z, 0, 511))
    inside = bool(region[i, j])
    print(f"{s:3d} {s:5.1f} {sem[i,j]:6.2f}  {inside}")
