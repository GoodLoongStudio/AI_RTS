"""视觉接口契约测试（GLM 可直接运行）：python -m pytest tests/test_visual_api.py -q

覆盖交接要求（01-Qwen3.8Max.md §五）：
1 输入只读 / 2 输出 schema / 3 逻辑不变 / 4 保护区与视觉体积校验 /
6 缺资源必须报错 / 7 固定逻辑只重建视觉 / 9 确定性与预算。
"""
import json
import shutil
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from rtsmap.contract import ALGO_VERSION, G2_DEFAULTS
from rtsmap.gates import g2_layout, g3_content, g4_export
from rtsmap.gates import g4_terrain
from rtsmap.grid import MapGrid, read_json, sha256_file
from rtsmap.presentation import (VISUAL_API_VERSION, VisualPlanError, build_visual_plan,
                                 build_zones, load_profile, plan_fingerprint)

PROJECT = Path(__file__).resolve().parents[1]
SEED = 16


@pytest.fixture(scope="module")
def context_env(tmp_path_factory):
    """真实 G2→G3→G4 上下文（临时目录，auto 模式）。"""
    root = tmp_path_factory.mktemp("visual_ctx")
    shutil.copytree(PROJECT / "runs" / str(SEED) / "G1", root / str(SEED) / "G1")
    res2 = g2_layout.run_one(SEED, root, dict(G2_DEFAULTS), auto=True)
    if not res2["mapspec"]["all_pass"]:
        pytest.skip("G2 未通过，视觉契约测试不适用")
    g3_content.run_one(SEED, root, dict(g3_content.G3_DEFAULTS), auto=True)
    g2_spec = res2["mapspec"]
    grid = MapGrid.load(root / str(SEED) / "G3" / "mapgrid.npz")
    params = dict(g4_export.G4_PARAMS_DEFAULTS)
    hf, meta = g4_terrain.build_heightfield(grid, params, g2_spec["plateaus"],
                                            g2_spec.get("bridges", []))
    catalog_list = json.loads((PROJECT / "rtsmap" / "data" / "assets_catalog.json")
                              .read_text(encoding="utf-8"))
    resources = read_json(root / str(SEED) / "G3" / "resources.json")["resources"]
    context = dict(
        map_id="test", world_size_m=[256.0, 256.0], cell_m=1.0,
        height=grid.get("height"), heightfield=hf,
        water_footprint=grid.get("water_footprint").astype(bool),
        blocking=grid.get("blocking"), blocking_g2=grid.get("blocking_g2"),
        terrain=grid.get("terrain"), passable=grid.get("passable"),
        lane_core=grid.get("lane_core"),
        plateaus=g2_spec["plateaus"], bridges=g2_spec.get("bridges", []),
        rivers=g2_spec.get("rivers", []), lakes=g2_spec.get("lakes", []),
        starts=g2_spec["starts"], resources=resources,
        expansion_anchors=g2_spec.get("expansion_anchors", []),
        lanes=read_json(root / str(SEED) / "G2" / "lanes.json"),
        ramp_blend=meta["ramp_blend"], apron=meta["apron"], shore=meta["shore"],
        bridge_mask=meta["bridge"], water_mask=meta["water"],
        catalog={e["res_path"]: e for e in catalog_list},
        catalog_list=catalog_list, g4_params=params,
    )
    return root, context


def test_plan_schema_and_determinism(context_env):
    _, context = context_env
    profile = load_profile("default")
    plan_a = build_visual_plan(context, profile, 777)
    plan_b = build_visual_plan(context, profile, 777)
    assert plan_a["api_version"] == VISUAL_API_VERSION
    for key in ("style_version", "profile", "profile_sha256", "visual_seed",
                "materials", "instances", "asset_dependencies", "stats",
                "warnings", "checks"):
        assert key in plan_a, f"VisualPlan 缺少字段 {key}"
    assert all(plan_a["checks"].values()), plan_a["checks"]
    assert plan_fingerprint(plan_a) == plan_fingerprint(plan_b), "同 Seed 同样式必须确定性一致"
    plan_c = build_visual_plan(context, profile, 778)
    assert plan_fingerprint(plan_c) != plan_fingerprint(plan_a), "不同视觉 Seed 应产生不同布置"


def test_instances_are_readonly_decoration_within_protection(context_env):
    from rtsmap.gates.g3_content import oriented_rect_cells
    _, context = context_env
    profile = load_profile("default")
    zones = build_zones(context)
    plan = build_visual_plan(context, profile, 999)
    assert plan["stats"]["total"] > 0, "默认样式必须真的放置实例（不能是空接口）"
    assert plan["stats"]["total"] <= profile["budget_total"]
    forbidden, blocking = zones["forbidden"], zones["blocking"]
    for ins in plan["instances"]:
        assert ins["collision"] is False and ins["blocking"] is False, \
            "视觉实例不得携带碰撞或改变可走性"
        assert ins["asset"] in context["catalog"]
        w, h = ins["footprint_m"]
        cells = oriented_rect_cells(ins["x"], ins["z"], w, h, ins["yaw"])
        assert cells, "实例必须有有效包围格"
        for i, j in cells:
            assert 0 <= i < 256 and 0 <= j < 256
            # 校验视觉体积（有向矩形），不只中心点：保护区内禁止悬出
            assert not (forbidden[i, j] and not blocking[i, j]), \
                f"实例 {ins['name']} 侵入保护区 ({i},{j})"


def test_logic_channels_untouched_and_missing_assets_raise(context_env):
    _, context = context_env
    profile = load_profile("default")
    before = {name: np.asarray(context[name]).copy()
              for name in ("blocking", "height", "water_footprint", "passable", "terrain")}
    build_visual_plan(context, profile, 4242)
    for name, arr in before.items():
        assert np.array_equal(arr, context[name]), f"视觉计划改写了权威通道 {name}"
    # 缺资源必须报错，不静默回退
    with pytest.raises(VisualPlanError):
        load_profile("definitely-missing-style")
    broken = json.loads(json.dumps({k: v for k, v in profile.items() if not k.startswith("_")}))
    broken["cliff_rocks"] = dict(broken["cliff_rocks"])
    broken["style_version"] = "broken-test"
    import rtsmap.presentation.visual as visual_mod
    original = visual_mod._cliff_pool

    def empty_pool(catalog, cfg):
        raise VisualPlanError("崖体资产池为空（测试）")
    visual_mod._cliff_pool = empty_pool
    try:
        with pytest.raises(VisualPlanError):
            build_visual_plan(context, broken, 4242)
    finally:
        visual_mod._cliff_pool = original


def test_scene_build_is_visual_seed_isolated(context_env, tmp_path):
    """固定逻辑地图，只换视觉 Seed：G1–G3 权威数据哈希不变，场景 Visual 段变化。"""
    root, _ = context_env
    logic_before = {g: sha256_file(root / str(SEED) / g / "mapgrid.npz")
                    for g in ("G1", "G2", "G3")}
    params = dict(g4_export.G4_PARAMS_DEFAULTS)
    out_a, out_b = tmp_path / "a", tmp_path / "b"
    built_a = g4_export.build_scene_text(f"{SEED}-0", root, SEED, out_a, params, visual_seed=11)
    text_a = built_a["tscn"].read_text(encoding="utf-8")
    built_b = g4_export.build_scene_text(f"{SEED}-0", root, SEED, out_b, params, visual_seed=22)
    text_b = built_b["tscn"].read_text(encoding="utf-8")
    logic_after = {g: sha256_file(root / str(SEED) / g / "mapgrid.npz")
                   for g in ("G1", "G2", "G3")}
    assert logic_before == logic_after, "视觉重建不得改变逻辑权威数据"
    assert (built_a["height_data_sha256"] == built_b["height_data_sha256"]), \
        "高程数据（逻辑几何）必须与视觉 Seed 无关"
    assert text_a != text_b, "不同视觉 Seed 应产生不同场景装饰"
    assert built_b["visual"]["stats"]["total"] > 0
    # 场景结构断言：真实高程地形 + 唯一地图 ID + 出生点非 Y=0
    assert "GeneratedTerrain.gd" in text_a and "height_data_path" in text_a
    assert f"map_{SEED}-0" in built_a["tscn"].name
    spawn_lines = [ln for ln in text_a.splitlines() if "8.74228e-08, 0, -1" in ln]
    assert len(spawn_lines) == 4
    ys = [float(ln.split(", ")[-2]) for ln in spawn_lines]
    assert any(y > 1.0 for y in ys), f"至少一个出生点在高地上（非 Y=0）: {ys}"
    report = built_a["hf_report"]
    assert report["walkable_slope_step_ok"], report
    nav = built_a["nav"]
    kinds = {t["kind"] for t in nav["targets"]}
    assert {"spawn", "expansion", "plateau_top", "ramp_top", "ramp_bottom"} <= kinds
