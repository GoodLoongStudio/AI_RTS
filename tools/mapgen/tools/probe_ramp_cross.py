"""坡道横剖面：沿坡道【法向】切一刀，看坡面两侧是不是垂直硬壁（方形通道）。

用户反馈"坡道生成的有问题"。沿坡道轴向的剖面（probe_terrain_profile.py）看起来是
连续斜坡，但沿法向切才能看出：坡口带 `_ramp_band_mask` 是一个**矩形窗口**，
带内被重写为坡面、带外不动 —— 于是两侧形成垂直台阶，实机上读作"方形凹槽/盒子"，
而不是自然的坡道。

用法：python tools/probe_ramp_cross.py [seed]
"""
import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools._paths import DEFAULT_HEIGHT  # noqa: E402

R = ROOT / "workbench_output" / "single_large_lake" / "runs"
SEED = sys.argv[1] if len(sys.argv) > 1 else "16"
spec = json.loads((R / SEED / "G2" / "mapspec.json").read_text(encoding="utf-8"))
BIN = DEFAULT_HEIGHT
raw = BIN.read_bytes()
vw, vh = np.frombuffer(raw[:8], dtype=np.int32)
hf = np.frombuffer(raw[8:], dtype=np.float32).reshape(vh, vw)   # 1025² 顶点, 语义米


def h_at(sx, sz):
    """语义坐标 -> 高度（双线性，顶点域 = 语义 x2）。"""
    x = np.clip(sx * 2.0, 0, vw - 1.001)
    z = np.clip(sz * 2.0, 0, vh - 1.001)
    i0, j0 = int(x), int(z)
    fx, fz = x - i0, z - j0
    return float(hf[j0, i0] * (1 - fx) * (1 - fz) + hf[j0, i0 + 1] * fx * (1 - fz)
                 + hf[j0 + 1, i0] * (1 - fx) * fz + hf[j0 + 1, i0 + 1] * fx * fz)


for pk, pl in enumerate(spec.get("plateaus", [])):
    ctr = np.array(pl["center"], dtype=float)
    for rk, (rc, rd) in enumerate(zip(pl.get("ramp_centers", []), pl.get("ramp_dirs", []))):
        rc = np.array(rc, dtype=float)
        d = np.array(rd, dtype=float)
        if np.dot(rc - ctr, d) > 0:
            d = -d                     # 指向内部（与 g4_terrain 同约定）
        d = d / (np.linalg.norm(d) or 1.0)
        n = np.array([-d[1], d[0]])    # 法向

        # 沿法向在"坡道中段"切一刀：轴向取 rc + d*(-7.5)（坡面中间，ramp_run=15）
        mid = rc + d * (-7.5)
        print(f"\n=== plateau#{pk} ramp#{rk}  rc=({rc[0]:.0f},{rc[1]:.0f}) dir=({d[0]:.2f},{d[1]:.2f}) ===")
        print("  法向剖面（t 为相对坡道中心的法向偏移，语义米 / 高度语义米）:")
        vals = []
        for t in np.arange(-14, 14.01, 1.0):
            p = mid + n * t
            vals.append((t, h_at(p[0], p[1])))
        line = "  "
        for k, (t, v) in enumerate(vals):
            line += f"{v:5.1f}"
            if (k + 1) % 14 == 0:
                print(line)
                line = "  "
        if line.strip():
            print(line)
        vs = np.array([v for _, v in vals])
        dv = np.abs(np.diff(vs))
        print(f"  法向最大单步跳变 {dv.max():.2f} 语义米（{dv.max()*4:.1f} 世界米；"
              f"1 格间距 → {np.degrees(np.arctan(dv.max()*4/4)):.0f}°）")

        # 轴向剖面（对照：应当是连续斜坡）
        print("  轴向剖面（沿坡道方向，-25..+15 语义米）:")
        vals2 = []
        for t in np.arange(-25, 15.01, 2.0):
            p = rc + d * t
            vals2.append(h_at(p[0], p[1]))
        print("  " + " ".join(f"{v:.1f}" for v in vals2))
