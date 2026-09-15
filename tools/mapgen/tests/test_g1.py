"""G1 测试：确定性哈希、约束拒绝、画布往返、territory 取值。

运行：python -m pytest tests/test_g1.py -q   （或 python tests/test_g1.py）
"""
import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from rtsmap.contract import G1_DEFAULTS, OFFSET, PX_PER_M, px_to_world, world_to_px
from rtsmap.gates import g1_starts
from rtsmap.grid import canon_json_bytes, sha256_bytes, sha256_file


def test_determinism(tmp_path=None):
    """同 Seed 两次运行：mapgrid.npz 与 mapspec.json 字节级一致。"""
    tmp = Path(tmp_path or "runs/_test_determinism")
    d1, spec1 = g1_starts.run_one(1, tmp, dict(G1_DEFAULTS))
    d2, spec2 = g1_starts.run_one(1, tmp, dict(G1_DEFAULTS))
    h1 = (sha256_file(d1 / "mapgrid.npz"), sha256_bytes(canon_json_bytes(spec1)))
    h2 = (sha256_file(d2 / "mapgrid.npz"), sha256_bytes(canon_json_bytes(spec2)))
    assert h1 == h2, f"哈希不一致: {h1} != {h2}"


def test_min_pair_reject():
    """人工构造两点相距 20 m 的样本必须被 min_pair 拒绝。"""
    starts = np.array([[20.0, 20.0], [40.0, 20.0], [76.0, 76.0], [20.0, 76.0]])
    ev = g1_starts.evaluate_constraints(starts, dict(G1_DEFAULTS))
    assert not ev["min_pair"]["pass"], "相距 20 m 必须违反 min_pair"
    assert abs(ev["min_pair"]["value"] - 20.0) < 1e-6


def test_angle_gap_reject():
    """人工构造三点极角都在 60° 内的样本必须被 angle_gap 拒绝。"""
    # 三点在 +X 方向 ±20° 扇区内（半径 30–36 m），第四点在对侧
    s = np.array([
        [48 + 32 * math.cos(math.radians(-18)), 48 + 32 * math.sin(math.radians(-18))],
        [48 + 36 * math.cos(math.radians(0)), 48 + 36 * math.sin(math.radians(0))],
        [48 + 32 * math.cos(math.radians(18)), 48 + 32 * math.sin(math.radians(18))],
        [14.0, 48.0],
    ])
    ev = g1_starts.evaluate_constraints(s, dict(G1_DEFAULTS))
    assert not ev["angle_gap"]["pass"], "三点挤 60° 扇区必须违反 angle_gap"


def test_canvas_roundtrip():
    """画布世界↔像素往返误差 < 0.5 px。"""
    for x, z in [(0.0, 0.0), (13.37, 42.42), (48.0, 48.0), (96.0, 96.0), (95.999, 0.001)]:
        px, py = world_to_px(x, z)
        wx, wz = px_to_world(px, py)
        assert abs(px - (OFFSET + x * PX_PER_M)) < 0.5
        assert abs(py - (OFFSET + z * PX_PER_M)) < 0.5
        assert abs(wx - x) < 0.5 and abs(wz - z) < 0.5


def test_territory_values():
    """分散出生点的 territory 通道四个值都出现。"""
    starts = np.array([[20.0, 20.0], [76.0, 20.0], [76.0, 76.0], [20.0, 76.0]])
    terr = g1_starts.voronoi_territory(starts)
    vals = set(np.unique(terr).tolist())
    assert vals == {0, 1, 2, 3}, f"territory 取值 {vals} != {{0,1,2,3}}"


def _main():
    passed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"PASS {name}")
                passed += 1
            except AssertionError as e:
                print(f"FAIL {name}: {e}")
                return 1
    print(f"{passed} tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(_main())
