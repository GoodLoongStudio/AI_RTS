"""坡道沟槽检测：量"坡道带被山体加成排除"造成的两侧凹陷。

机制怀疑：`build_heightfield` 里 `shield_g` 是**二值**掩码
（`water | bridge | ramp_blend | shore`），`addon[shield_v] = 0` —— 坡道带完全不加山体，
而紧邻的岩体照加 → 坡道两侧形成垂直沟槽（用户指出的凹陷）。

指标：沿坡道轴向逐点取"带中心高度"与"带外 1~4 格内的最高高度"之差；
正值 = 带外更高 = 有沟槽壁；负值 = 带外更低 = 坡道凸起（高架堤）。

用法：python tools/probe_ramp_trench.py [seed]
"""
import json
import sys
from pathlib import Path

import numpy as np

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
sem = hf[::2, ::2][:512, :512]          # 1025 -> 512 语义格
P = dict(G4_PARAMS_DEFAULTS)


def h_at(sx, sz):
    return float(sem[int(np.clip(sz, 0, GRID_H - 1)), int(np.clip(sx, 0, GRID_W - 1))])


worst = []
for pk, pl in enumerate(spec.get("plateaus", [])):
    ctr = np.array(pl["center"], dtype=float)
    region = polygon_mask(np.asarray(pl["outline"], dtype=float))
    for rk, (rc0, rd0) in enumerate(zip(pl.get("ramp_centers", []), pl.get("ramp_dirs", []))):
        rc = np.array(rc0, dtype=float)
        d = np.array(rd0, dtype=float)
        if np.dot(rc - ctr, d) > 0:
            d = -d
        d = d / (np.linalg.norm(d) or 1.0)
        n = np.array([-d[1], d[0]])
        band = _ramp_band_mask(pl, rc0, d, P)
        if not band.any():
            continue
        # 台地外缘锚点（与 g4_terrain 的同口径）
        ii, jj = np.nonzero(region & band)
        if len(ii) == 0:
            continue
        ax_r = (jj + 0.5 - rc[0]) * d[0] + (ii + 0.5 - rc[1]) * d[1]
        t_out = float(ax_r.min()) - 0.5
        run = float(P.get("ramp_run_m", 15.0))

        rows = []
        for ax in np.arange(t_out + 1.0, t_out + run, 2.0):
            c = rc + d * ax
            h_in = h_at(c[0], c[1])
            # 带外参考：向外搜索到第一个非带格，再取 1 格更外。
            # **只统计两侧都在台地之外的位置** —— 若带外是台顶，那"坡面比旁边低"
            # 是坡道刻在台地边缘的正常几何，不是缺陷（第一版检测器就栽在这）。
            outs = []
            outside_is_plateau = False
            for off in range(1, 15):
                for sgn in (-1, 1):
                    p = c + n * (off * sgn)
                    i, j = int(p[1]), int(p[0])
                    if not (0 <= i < GRID_H and 0 <= j < GRID_W):
                        continue
                    if band[i, j]:
                        continue
                    outs.append((i, j, h_at(p[0], p[1])))
                    if region[i, j]:
                        outside_is_plateau = True
            if outs and not outside_is_plateau:
                h_out = max(o[2] for o in outs)
                rows.append((ax, h_in, h_out, h_out - h_in))
        if not rows:
            continue
        mx = max(rows, key=lambda r: r[3])
        mn = min(rows, key=lambda r: r[3])
        worst.append((mx[3], mn[3], pk, rk, (rc[0], rc[1]), len(rows)))

worst.sort(reverse=True)
print(f"{'沟槽深(语义米/世界米)':>22s}  {'凸起':>14s}  台地#坡道  中心")
for mx, mn, pk, rk, rc, n in worst:
    flag = "  <<< 沟槽" if mx > 1.0 else ("  <<< 凸起" if mn < -1.0 else "")
    print(f"  {mx:6.2f} / {mx*4:6.1f}m   {mn:6.2f}/{mn*4:6.1f}m   #{pk}-{rk}  "
          f"({rc[0]:.0f},{rc[1]:.0f}){flag}")
print(f"\n最深沟槽 {worst[0][0]:.2f} 语义米（{worst[0][0]*4:.1f} 世界米）"
      f" @ plateau#{worst[0][2]}-{worst[0][3]}" if worst else "无坡道")
print(f"沟槽 >1 语义米的坡道数 = {sum(1 for w in worst if w[0] > 1.0)} / {len(worst)}")
