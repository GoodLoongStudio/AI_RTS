"""台地内凹陷/缺口检测：轮廓之内但没有达到台顶高度的连通区。

这正是用户说的"凹陷"最可能的形态：台地顶面被挖掉一块（坡道刻槽切深了、
或者内部锚平步骤漏掉了某片格）。

判定：`region(轮廓) & (h < plateau_level - 0.3)` 的连通块。
台地顶必须处处 ≈ plateau_level；低于它 1 米以上即为凹。
报告每块的面积、中心、最深值，以及是否与坡道带相邻（区分"坡道刻槽"与"漏锚平"）。

用法：python tools/find_plateau_depressions.py [seed]
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
from rtsmap.gates.g2_landforms import polygon_mask  # noqa: E402
from rtsmap.gates.g4_export import G4_PARAMS_DEFAULTS  # noqa: E402
from rtsmap.gates.g4_terrain import _ramp_band_mask  # noqa: E402

R = ROOT / "workbench_output" / "single_large_lake" / "runs"
SEED = sys.argv[1] if len(sys.argv) > 1 else "16"
spec = json.loads((R / SEED / "G2" / "mapspec.json").read_text(encoding="utf-8"))
BIN = DEFAULT_HEIGHT
raw = BIN.read_bytes()
vw, vh = np.frombuffer(raw[:8], dtype=np.int32)
hf = np.frombuffer(raw[8:], dtype=np.float32).reshape(vh, vw)
# 用精确的 513 语义网格（hf1025[2k] == hf513[k]）。
# 注意**不要**用 hf[1::2,1::2]（那是 1025 上的插值中点）：在台地边界处
# 会把相邻的平地值一起平均进来，凭空造出 4~5 语义米的假凹陷。
sem = hf[::2, ::2][:512, :512]
TOP = float(G4_PARAMS_DEFAULTS["plateau_level"])
P = dict(G4_PARAMS_DEFAULTS)
print(f"台顶权威高度 = {TOP} 语义米（世界 {TOP*4:.1f} m）；判定阈值 < {TOP-0.3:.2f}")

total = 0
lines = []
for pk, pl in enumerate(spec.get("plateaus", [])):
    region = polygon_mask(np.asarray(pl["outline"], dtype=float))
    if not region.any():
        continue
    band_any = np.zeros_like(region)
    for rc0, rd0 in zip(pl.get("ramp_centers", []), pl.get("ramp_dirs", [])):
        ctr = np.array(pl["center"], dtype=float)
        d = np.array(rd0, dtype=float)
        if np.dot(np.array(rc0) - ctr, d) > 0:
            d = -d
        band_any |= _ramp_band_mask(pl, rc0, d / (np.linalg.norm(d) or 1.0), P)
    dep = region & (sem < TOP - 0.3)
    lab, n = ndimage.label(dep)
    sizes = np.bincount(lab.ravel()); sizes[0] = 0
    comps = [(int(s), int(k)) for k, s in enumerate(sizes) if s >= 3]
    comps.sort(reverse=True)
    area = int(region.sum())
    if comps:
        lines.append(f"\nplateau#{pk} ({pl.get('kind','?')}) 面积 {area} 格，凹块 {len(comps)} 个：")
    for s, k in comps[:5]:
        m = lab == k
        ii, jj = np.nonzero(m)
        c = (float(jj.mean()), float(ii.mean()))
        hmin = float(sem[m].min())
        on_ramp = int((m & band_any).sum())
        lines.append(f"   {s:5d} 格 ({s*16:7,d} m2)  中心语义({c[0]:5.1f},{c[1]:5.1f}) "
                     f"世界({c[0]*4:6.0f},{c[1]*4:6.0f})  最深 {hmin:5.2f}（差 {TOP-hmin:4.2f}）"
                     f"  与坡道带重叠 {on_ramp}/{s}"
                     f"{'  ← 坡道刻槽' if on_ramp > s*0.5 else '  ← 非坡道（疑似漏锚平/其他）'}")
        total += s
print("\n".join(lines) if lines else "所有台地顶面都达到权威高度（无凹陷）")
print(f"\n凹陷总面积 {total} 格 = {total*16:,} m2")

# 全图检查：台地轮廓内整体低于台顶的比例
allreg = np.zeros_like(sem, dtype=bool)
for pl in spec.get("plateaus", []):
    allreg |= polygon_mask(np.asarray(pl["outline"], dtype=float))
low = allreg & (sem < TOP - 0.3)
print(f"全部台地轮廓内 {int(allreg.sum())} 格，其中低于台顶 0.3 以上 {int(low.sum())} 格"
      f"（{low.sum()/max(allreg.sum(),1)*100:.2f}%）")
