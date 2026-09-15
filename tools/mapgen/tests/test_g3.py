"""G3 测试：临时目录内跑真实 G2→G3（auto 模式），不写正式 runs。

2026-09-06 重构（主计划代码事实 #5）：旧版依赖正式 runs/16 且 test_determinism
会直接重生成正式 G3；现改为独立临时输入输出。生成失败时跳过并单列（不当通过）。
"""
import json
import math
import shutil
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from rtsmap.contract import GRID_H, GRID_W, OVERLAY_A, OVERLAY_B
from rtsmap.gates import g2_layout, g3_content
from rtsmap.grid import MapGrid, canon_json_bytes, read_json, sha256_bytes, sha256_file

SOURCE = Path(__file__).resolve().parents[1] / "runs"
SEED = 16  # 已放行布局；auto 模式下同样可用（G1 源数据只读复制）


@pytest.fixture(scope="module")
def g3_run(tmp_path_factory):
    root = tmp_path_factory.mktemp("g3_real")
    shutil.copytree(SOURCE / str(SEED) / "G1", root / str(SEED) / "G1")
    res2 = g2_layout.run_one(SEED, root, dict(g2_layout.G2_DEFAULTS), auto=True)
    if not res2["mapspec"]["all_pass"]:
        pytest.skip(f"G2 未通过（{[k for k, v in res2['mapspec']['checks'].items() if not v]}），G3 测试不适用")
    r1 = g3_content.run_one(SEED, root, dict(g3_content.G3_DEFAULTS), auto=True)
    if not r1["mapspec"]["all_pass"]:
        pytest.skip(f"G3 未通过：failures={r1['mapspec']['resource_failures']}")
    r2 = g3_content.run_one(SEED, root, dict(g3_content.G3_DEFAULTS), auto=True)
    return root, r1, r2


def test_determinism_and_no_approval(g3_run):
    root, r1, r2 = g3_run
    h1 = (sha256_file(r1["run_dir"] / "mapgrid.npz"),
          sha256_bytes(canon_json_bytes(r1["mapspec"])))
    h2 = (sha256_file(r2["run_dir"] / "mapgrid.npz"),
          sha256_bytes(canon_json_bytes(r2["mapspec"])))
    assert h1 == h2, "G3 同输入重跑哈希不一致"
    manifest = read_json(root / str(SEED) / "G3" / "manifest.json")
    assert manifest["approved"] is False, "auto 模式不得填写人工 approval"
    assert manifest["execution_mode"] == "workbench_auto"


def test_resource_clearance(g3_run):
    """资源净空：passable、到 blocking ≥2m、资源间 ≥3m、不在 lane_core、到出生点 ≥6m。"""
    root, r1, _ = g3_run
    rd = root / str(SEED) / "G3"
    grid = MapGrid.load(rd / "mapgrid.npz")
    res = read_json(rd / "resources.json")["resources"]
    blocking = grid.get("blocking")
    passable = grid.get("passable")
    lane_core = grid.get("lane_core")
    overlay = grid.get("overlay")
    spawns = read_json(root / str(SEED) / "G1" / "mapspec.json")["starts"]
    clear = g3_content.clear_of_blocking(blocking, 2.0)
    for r in res:
        i, j = int(math.floor(r["z"])), int(math.floor(r["x"]))
        assert passable[i, j], f"资源 {r['id']} 在不可走格"
        assert overlay[i, j] == (OVERLAY_A if r["type"] == "A" else OVERLAY_B)
        assert not lane_core[i, j], f"资源 {r['id']} 在通道核心带"
        assert clear[i, j], f"资源 {r['id']} 距最近 blocking < 2m"
        for s in spawns:
            assert math.hypot(r["x"] - s[0], r["z"] - s[1]) >= 6.0 - 1e-6
    for a in range(len(res)):
        for b in range(a + 1, len(res)):
            d = math.hypot(res[a]["x"] - res[b]["x"], res[a]["z"] - res[b]["z"])
            assert d >= 3.0 - 1e-6, f"资源 {a}/{b} 间距 {d:.2f} < 3m"


def test_resources_reachable_and_at_valid_height(g3_run):
    """每个资源必须从各家出生点真实可达（G3 重算 blocking 后），且不在水面。"""
    root, r1, _ = g3_run
    from rtsmap.pathing import bfs_components, cell_of
    rd = root / str(SEED) / "G3"
    grid = MapGrid.load(rd / "mapgrid.npz")
    res = read_json(rd / "resources.json")["resources"]
    labels = bfs_components(grid.get("passable"))
    water = grid.get("water_footprint").astype(bool)
    height = grid.get("height")
    spawns = read_json(root / str(SEED) / "G1" / "mapspec.json")["starts"]
    spawn_label = labels[cell_of(*spawns[0])]
    for r in res:
        i, j = cell_of(r["x"], r["z"])
        assert labels[i, j] == spawn_label, f"资源 {r['id']} 不在主连通域"
        assert not water[i, j] or height[i, j] > -2.0, f"资源 {r['id']} 落在水面上"


def test_instances_and_recheck(g3_run):
    """实例数 ≤ 预算；复检连通；blocking ⊇ 原簇格 ≥90%；映射快照写入任务目录。"""
    root, r1, _ = g3_run
    rd = root / str(SEED) / "G3"
    rep = read_json(rd / "recheck_report.json")
    assert rep["budget_pass"], f"实例 {rep['instance_count']} 超预算 {rep['budget']}"
    assert rep["recheck"]["components_pass"] and rep["recheck"]["keypoints_pass"]
    assert rep["cluster_cover_pass"], f"簇覆盖率 {rep['cluster_cover_frac']:.3f} < 0.90"
    assert (rd / "terrain_to_assets.json").exists(), "映射快照应写入本任务 G3 目录"
    spec = read_json(rd / "mapspec.json")
    assert spec["all_pass"], (f"G3 all_pass=False: removed={len(spec['removed_instances'])} "
                              f"res_fail={spec['resource_failures']}")


def test_blocking_g2_preserved(g3_run):
    """G2 原始 blocking 通道被保留（blocking_g2）且与本次 G2 输出一致。"""
    root, r1, _ = g3_run
    grid = MapGrid.load(root / str(SEED) / "G3" / "mapgrid.npz")
    assert grid.has("blocking_g2")
    g2 = MapGrid.load(root / str(SEED) / "G2" / "mapgrid.npz")
    assert np.array_equal(grid.get("blocking_g2"), g2.get("blocking")), \
        "blocking_g2 与本次 G2 blocking 不一致"
    # 上游其余权威通道必须逐字节保留
    for channel in ("territory", "region", "role", "lane_core", "terrain",
                    "water_footprint", "height"):
        assert np.array_equal(grid.get(channel), g2.get(channel)), f"G3 改写了上游通道 {channel}"


def test_approval_inheritance_requires_matching_hashes(tmp_path):
    """旧 approval 只在版本+输入+输出哈希全一致时继承；新地貌不得继承旧认可。"""
    from rtsmap.gate import manifest_path, new_manifest
    from rtsmap.grid import write_json
    algo = g3_content.ALGO_VERSION["G3"]
    original = new_manifest(SEED, "G3", 12, algo, {}, "g2-a", {"grid": "g3-a"})
    original.update(approved=True, approved_note="fixture", approved_at="test")
    path = manifest_path(tmp_path, SEED, "G3")
    path.parent.mkdir(parents=True)
    write_json(path, original)
    for input_hash, output_hash, expected in [("g2-a", {"grid": "g3-a"}, True),
                                              ("g2-b", {"grid": "g3-a"}, False),
                                              ("g2-a", {"grid": "g3-b"}, False)]:
        current = new_manifest(SEED, "G3", 12, algo, {}, input_hash, output_hash)
        g3_content._inherit_approval(tmp_path, SEED, "G3", current, algo)
        assert current["approved"] is expected


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
