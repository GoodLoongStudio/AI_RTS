"""桥组合模块（bridge_assembly）确定性测试：不依赖 Godot。"""
import math

import pytest

from rtsmap.gates import bridge_assembly as ba


def _flat_h(x, z):
    return 0.6


def make_bridge(a=(75.0, 148.0), b=(93.0, 170.0), width=8.0):
    return ba.build_bridge_assembly(dict(a=list(a), b=list(b), width=width), _flat_h)


def test_deck_top_is_shore_plus_offset():
    asm = make_bridge()
    assert asm["meta"]["deck_top"] == pytest.approx(0.6 + ba.DECK_ABOVE_SHORE, abs=1e-6)
    assert asm["meta"]["bank_a"] == pytest.approx(0.6)
    assert asm["meta"]["bank_b"] == pytest.approx(0.6)


def test_clear_width_accounts_for_rails():
    asm = make_bridge()
    # 护栏侵占计入通行净宽：净宽 = 桥宽 - 2*护栏宽 < 桥宽
    assert asm["meta"]["clear_width"] == pytest.approx(8.0 - 2 * ba.RAIL_WIDTH, abs=1e-6)
    assert asm["meta"]["clear_width"] < asm["meta"]["deck_width"]
    for w in asm["walk"]:
        assert w["width"] == pytest.approx(asm["meta"]["clear_width"], abs=1e-6)


def test_parts_use_approved_four_pieces():
    asm = make_bridge()
    kinds = {p["kind"] for p in asm["parts"]}
    assert kinds == {"deck", "end", "rail", "pillar"}
    # 每岸仅一层收口（2 个 end），两侧连续护栏（2 个 rail）
    assert sum(1 for p in asm["parts"] if p["kind"] == "end") == 2
    assert sum(1 for p in asm["parts"] if p["kind"] == "rail") == 2
    assert sum(1 for p in asm["parts"] if p["kind"] == "deck") >= 1


def test_walk_slabs_continuous_no_gap():
    """可走板沿桥轴首尾相接（端坡→桥面→端坡），无断档。"""
    asm = make_bridge()
    span = asm["meta"]["span"]
    # 沿轴采样：每个 t 都应落在某个可走板的轴向覆盖内
    yaw = math.radians(asm["meta"]["yaw"])
    ux, uz = math.sin(yaw), math.cos(yaw)
    ax, az = 75.0, 148.0
    for i in range(41):
        t = span * i / 40.0
        px, pz = ax + ux * t, az + uz * t
        covered = False
        for w in asm["walk"]:
            # 板中心到采样点的轴向距离 <= 板长/2（含少量重叠余量）
            dx, dz = px - w["x"], pz - w["z"]
            along = dx * ux + dz * uz
            lat = abs(dx * uz - dz * ux)
            if abs(along) <= w["length"] / 2.0 + 0.06 and lat <= w["width"] / 2.0 + 0.06:
                covered = True
                break
        assert covered, f"t={t:.2f} 处无可走板覆盖（断档）"


def test_walk_slab_steps_climbable():
    """相邻可走板高度差 <= 0.3m（climb=0.5 → 1 voxel 可越）。"""
    asm = make_bridge()
    tops = [w["top"] for w in asm["walk"]]
    for i in range(1, len(tops)):
        assert abs(tops[i] - tops[i - 1]) <= 0.3 + 1e-6, (
            f"可走板台阶 {abs(tops[i]-tops[i-1]):.3f}m 超过 climb 可越范围")


def test_end_segments_fill_span_without_gap():
    """end_a 覆盖 [0,end_len]、deck 覆盖中段、end_b 覆盖 [span-end_len,span]。"""
    asm = make_bridge()
    span = asm["meta"]["span"]
    end_len = asm["meta"]["end_len"]
    n_seg = asm["meta"]["n_seg"]
    seg_len = asm["meta"]["seg_len"]
    # 甲板段总长 + 两端收口 = 跨距（无空隙；meta 保留 3 位小数，容差 0.02）
    assert 2 * end_len + n_seg * seg_len == pytest.approx(span, abs=0.02)


def test_missing_span_rejected():
    with pytest.raises(ValueError):
        ba.build_bridge_assembly(dict(a=[10, 10], b=[10, 10], width=8.0), _flat_h)
