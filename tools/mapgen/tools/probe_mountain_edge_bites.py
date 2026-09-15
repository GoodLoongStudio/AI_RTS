"""量化山体外轮廓凹陷，并落盘诊断图。

用法：.venv-g2/Scripts/python.exe tools/probe_mountain_edge_bites.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools._paths import DEFAULT_HEIGHT  # noqa: E402

from rtsmap.gates.g2_landforms import polygon_mask  # noqa: E402

G2 = ROOT / "workbench_output" / "single_large_lake" / "runs" / "16"
BIN = DEFAULT_HEIGHT
OUT = ROOT / "review" / "G4" / "g2_large_lake_kits" / "_diag"
FOOT_REVIEW = np.array([1638.672, 1365.234])
LOGICAL = 3.90625


def load_hf():
    raw = BIN.read_bytes()
    vw, vh = np.frombuffer(raw[:8], dtype=np.int32)
    return np.frombuffer(raw[8:], dtype=np.float32).reshape(int(vh), int(vw))


def highfreq_bite(mask: np.ndarray, smooth_sigma: float = 6.0) -> dict:
    """相对平滑包络的高频缺口：去掉大尺度湾，只看'被咬的小牙'。"""
    ys, xs = np.nonzero(mask)
    if ys.size < 20:
        return {}
    cy, cx = float(ys.mean()), float(xs.mean())
    boundary = mask & ~ndimage.binary_erosion(mask)
    by, bx = np.nonzero(boundary)
    ang = np.arctan2(by - cy, bx - cx)
    r = np.hypot(bx - cx, by - cy)
    order = np.argsort(ang)
    ang, r = ang[order], r[order]
    # 均匀重采样 256 点
    grid = np.linspace(-np.pi, np.pi, 256, endpoint=False)
    rr = np.interp(grid, ang, r, period=2 * np.pi)
    # 低通包络
    k = np.fft.rfft(rr)
    keep = 5
    k[keep:] = 0
    env = np.fft.irfft(k, n=256).real
    # 再做一个空间平滑对照
    sm = ndimage.gaussian_filter1d(rr, 8.0, mode="wrap")
    bite = np.maximum(sm - rr, 0.0)
    return dict(
        hf_bite_max=float(bite.max()),
        hf_bite_p90=float(np.percentile(bite, 90)),
        hf_bite_mean=float(bite.mean()),
        hf_n=int((bite > 1.5).sum()),
        r_mean=float(rr.mean()),
        env_amp=float((env.max() - env.min()) * 0.5),
    )


def save_overlay(rock, labels, lab, sem, path: Path, title=""):
    m = labels == lab
    ys, xs = np.nonzero(m)
    pad = 8
    y0, y1 = max(int(ys.min()) - pad, 0), min(int(ys.max()) + pad + 1, 512)
    x0, x1 = max(int(xs.min()) - pad, 0), min(int(xs.max()) + pad + 1, 512)
    sub = m[y0:y1, x0:x1]
    hsub = sem[y0:y1, x0:x1]
    # 平滑对照
    sm = ndimage.gaussian_filter(sub.astype(np.float64), 4.0) > 0.45
    boundary = sub & ~ndimage.binary_erosion(sub)
    sm_b = sm & ~ndimage.binary_erosion(sm)
    rgb = np.zeros(sub.shape + (3,), dtype=np.uint8)
    # 高度作底
    hn = (np.clip(hsub, 0, 16) / 16.0 * 180 + 40).astype(np.uint8)
    rgb[..., 0] = hn
    rgb[..., 1] = (hn * 0.85).astype(np.uint8)
    rgb[..., 2] = (hn * 0.55).astype(np.uint8)
    rgb[sub] = (210, 160, 90)
    rgb[sm & ~sub] = (80, 180, 80)   # 平滑后多出来的（填上的凹陷）
    rgb[sub & ~sm] = (200, 60, 60)   # 平滑后削掉的尖角
    rgb[boundary] = (30, 30, 30)
    rgb[sm_b] = (20, 90, 220)
    Image.fromarray(rgb).resize((sub.shape[1] * 3, sub.shape[0] * 3), Image.NEAREST).save(path)
    print(f"wrote {path.name}  fill={int((sm & ~sub).sum())}  clip={int((sub & ~sm).sum())}")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    spec = json.loads((G2 / "G2" / "mapspec.json").read_text(encoding="utf-8"))
    grid = np.load(G2 / "G3" / "mapgrid.npz")
    hf = load_hf()
    sem = hf[1::2, 1::2][:512, :512]
    region = np.zeros((512, 512), dtype=bool)
    for pl in spec.get("plateaus", []):
        region |= polygon_mask(np.asarray(pl["outline"], dtype=float))
    rock = (grid["blocking"] > 0) & ~(grid["water_footprint"] > 0) & ~region
    labels, _n = ndimage.label(rock)
    sizes = np.bincount(labels.ravel()); sizes[0] = 0

    fx, fz = FOOT_REVIEW / LOGICAL
    fj, fi = int(fx), int(fz)
    near_lab = int(labels[min(max(fi, 0), 511), min(max(fj, 0), 511)])
    # 焦点在山脚平地，label 可能是 0；改取焦点周围最近的岩体
    if near_lab == 0:
        d = ndimage.distance_transform_edt(~rock)
        yi, xi = np.unravel_index(np.argmin(np.where(
            (np.abs(np.arange(512)[:, None] - fi) < 80) &
            (np.abs(np.arange(512)[None, :] - fj) < 80), d, 1e9)), d.shape)
        near_lab = int(labels[yi, xi])
        print(f"foot focus on flat; nearest rock label={near_lab} at ({xi},{yi}) dist={d[yi,xi]:.1f}")

    print(f"{'lab':>4} {'cells':>7} {'hf_bite':>8} {'p90':>6} {'n>1.5':>6} {'r_mean':>7} {'env_amp':>8} foot")
    for lab in np.argsort(sizes)[::-1]:
        if sizes[lab] < 200:
            break
        st = highfreq_bite(labels == lab)
        mark = " <-- foot" if lab == near_lab else ""
        print(f"{lab:4d} {int(sizes[lab]):7d} {st.get('hf_bite_max',0):8.2f} "
              f"{st.get('hf_bite_p90',0):6.2f} {st.get('hf_n',0):6d} "
              f"{st.get('r_mean',0):7.1f} {st.get('env_amp',0):8.1f}{mark}")

    for lab in (near_lab, 2, 10, 7):
        if sizes[lab] > 0:
            save_overlay(rock, labels, lab, sem, OUT / f"edge_lab{lab}.png")

    # 全图岩体轮廓
    bound = rock & ~ndimage.binary_erosion(rock)
    rgb = np.zeros((512, 512, 3), dtype=np.uint8)
    rgb[rock] = (180, 130, 70)
    rgb[region] = (220, 200, 140)
    rgb[grid["water_footprint"] > 0] = (40, 90, 140)
    rgb[bound] = (20, 20, 20)
    # 山脚焦点
    rgb[max(fi-2,0):fi+3, max(fj-2,0):fj+3] = (255, 0, 0)
    Image.fromarray(rgb).save(OUT / "edge_all_rock.png")
    print("wrote edge_all_rock.png")


if __name__ == "__main__":
    main()
