# -*- coding: utf-8 -*-
"""生成无缝岩石纹理（确定性）→ AI_RTS assets/models/scifi-worlds/generated/ridge_rock.png。

多倍频值噪声 + 暗色裂隙，灰岩色调；供 G4 岩脊基座三平面映射使用（可重跑覆盖）。
"""
import numpy as np
from pathlib import Path
from PIL import Image

import sys

_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_ROOT))
from rtsmap.contract import G4_AIRTS  # noqa: E402

OUT = Path(G4_AIRTS) / "assets" / "models" / "scifi-worlds" / "generated" / "ridge_rock.png"


def _octave(rng, size, cells, amp):
    grid = rng.random((cells, cells))
    im = Image.fromarray((grid * 255).astype(np.uint8))
    im = im.resize((size, size), Image.BICUBIC)
    return (np.asarray(im, dtype=np.float64) / 255.0 - 0.5) * amp


def main():
    rng = np.random.default_rng(20260905)
    size = 512
    noise = (
        _octave(rng, size, 4, 0.55)
        + _octave(rng, size, 16, 0.30)
        + _octave(rng, size, 64, 0.18)
        + _octave(rng, size, 256, 0.10)
    )
    # 归一化到 0..1
    noise = (noise - noise.min()) / (noise.max() - noise.min())
    # 灰岩色调：中灰基底 + 明暗起伏
    gray = 0.36 + noise * 0.20
    # 暗色裂隙：高频噪声高阈值处压暗（岩石裂缝）
    crack = _octave(rng, size, 128, 1.0)
    crack_n = (crack - crack.min()) / (crack.max() - crack.min())
    gray *= np.where(crack_n > 0.82, 0.78, 1.0)
    rgb = np.stack([gray] * 3, axis=-1)
    rgb = (np.clip(rgb, 0, 1) * 255).astype(np.uint8)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(rgb).save(OUT)
    print(f"ridge texture -> {OUT}")


if __name__ == "__main__":
    main()
