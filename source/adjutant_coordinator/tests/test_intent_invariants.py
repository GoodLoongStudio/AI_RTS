# -*- coding: utf-8 -*-
"""意图不变量：**任何产出路径**的命令都不得违反"权威端会接受"的前置条件。

## 这是"防同类复发"的闸门（用户 2026-09-12 明确要求："从根上解决，同类问题不要再出现"）

复盘那两轮返工：
  - 第一轮：落点越界（163/169 条 `OutOfBounds`）→ 补 `map_bounds`；
  - 第二轮：换了皮变成视野外（172 条 `NotVisible`）→ 再补半径常量。
两次都是"**实测发现了才去补**"，因为原来没有任何一处机制保证"产出即合法"。

本文件把这条保证固化下来（新增产出路径必须接进 `_ladder_paths()` / `_frame_paths()`，
否则它就在闸门之外）：

1. 多条产出路径 × 一组**边界观测**（贴边基地 / 小地图 / 大地图 / 无 bounds）；
2. 断言产出的建造落点全部通过**唯一判据** `placement.spot_issue`
   （= 界内 ∧ 视野内 ∧ 有净空 ∧ 未被拉黑）；
3. 断言几何口径**只有一份**（常量同一 + 判定逐点一致）；
4. 断言内容类拒绝会真的"停发该类意图"。
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph import placement  # noqa: E402
from adjutant_coordinator.graph import rules_fallback as rf  # noqa: E402
from adjutant_coordinator.graph import squads  # noqa: E402

RULES = {
    "unit_types": [
        {"id": "worker", "scene_path": "res://units/Worker.tscn"},
        {"id": "soldier", "scene_path": "res://units/Soldier.tscn"},
        {"id": "command_center", "scene_path": "res://buildings/CommandCenter.tscn"},
        {"id": "barracks", "scene_path": "res://buildings/Barracks.tscn"},
        {"id": "vehicle_factory", "scene_path": "res://buildings/VehicleFactory.tscn"},
    ],
    "constructions": [
        {"id": "barracks", "blueprint_scene_path": "res://buildings/Barracks.tscn"},
        {"id": "vehicle_factory",
         "blueprint_scene_path": "res://buildings/VehicleFactory.tscn"},
    ],
    "productions": [
        {"product_type_id": "worker", "allowed_producer_type_ids": ["command_center"]},
        {"product_type_id": "soldier", "allowed_producer_type_ids": ["barracks"]},
    ],
}

#: 边界观测：基地位置 × 地图大小。贴边/小地图是历史上两类越界与视野事故的现场。
SCENARIOS = (
    ("base_center", (10.0, 7.0), [60.0, 60.0]),
    ("base_near_edge", (10.0, 3.0), [20.0, 20.0]),
    ("tiny_map", (4.0, 4.0), [12.0, 12.0]),
    ("no_bounds", (10.0, 7.0), None),
)


def unit(name, utype, *, construct=False, gather=False, queue=False, pos=(0, 0, 0)):
    return {"kind": "unit_self", "name": name, "unit_type": utype,
            "construct": construct, "gather": gather, "queue": queue, "pos": list(pos)}


def observation(base_x, base_z, *, builders=True, barracks=False, factory=False):
    entities = [unit("Unit_0", "command_center", queue=True, pos=(base_x, 0, base_z))]
    if builders:
        entities.append(unit("Unit_2", "worker", construct=True, gather=True,
                             pos=(base_x + 2.0, 0, base_z + 1.0)))
    if barracks:
        entities.append(unit("Unit_4", "barracks", pos=(base_x + 4.0, 0, base_z)))
    if factory:
        entities.append(unit("Unit_5", "vehicle_factory", pos=(base_x - 4.0, 0, base_z)))
    entities.append({"kind": "resource", "name": "Res_0",
                     "pos": [base_x + 6.0, 0.0, base_z + 6.0]})
    return {"entities": entities}


def own_points(tactical):
    """**己方实体**坐标（不含资源/敌人）：净空判定的对象就是它们。"""
    out = []
    for entity in tactical.get("entities", []):
        if "unit_self" not in str(entity.get("kind", "")):
            continue
        pos = entity.get("pos")
        if isinstance(pos, (list, tuple)) and len(pos) >= 3:
            out.append((float(pos[0]), float(pos[2])))
    return out


def ladder_state(names, bounds=None):
    """地板输入状态。`map_bounds` 由 `nodes.node_ingest` 从 `op=strategic` 落盘，
    这里按同样口径给出（缺省即"还没拿到战略视图"）。"""
    state = {"server_tick": 1000, "latest_snapshot_id": 5,
             "ai_controlled_units": list(names), "active_intents": []}
    if bounds is not None:
        state["map_bounds"] = list(bounds)
    return state


class BuildSpotInvariantTest(unittest.TestCase):
    """产出的建造落点必须通过唯一判据（这是"同类不再复发"的硬约束）。"""

    def _assert_spot_ok(self, pos, bounds, points, label):
        issue = placement.spot_issue(pos, bounds, points)
        self.assertIsNone(issue, "%s 的落点违反前置条件（%s）：%s" % (label, issue, pos))

    def test_ladder_build_spots_pass_preconditions(self):
        """发展阶梯（地板）产出的每一个建造落点都必须合法。"""
        for label, (base_x, base_z), bounds in SCENARIOS:
            with self.subTest(scenario=label):
                tactical = observation(base_x, base_z)
                out = rf.development_intents(
                    ladder_state(["Unit_0", "Unit_2"], bounds), tactical=tactical,
                    rules=RULES, server_tick=1000, snapshot_id=5)
                self.assertTrue(out, "没有产出任何意图 = 地板失效")
                self.assertEqual(out[0]["action"], "build")
                self._assert_spot_ok(out[0]["target"]["pos"], bounds,
                                     own_points(tactical), "development_intents")

    def test_unknown_map_size_still_stays_in_vision(self):
        """拿不到地图尺寸时，仍然**必须**落点在视野内（视野与地图无关）。

        这里刻意**不**要求"收缩到最内圈"：统一收缩会把"朝地图内侧、本来合法"的
        候选一起杀掉（贴边基地会把整圈清空 → 再也建不出东西）。越界是**逐点**的事，
        由 `candidate_spots` 逐点筛 + 账本按点拉黑自愈；视野则是与地图无关的硬约束。
        """
        anchored = ladder_state(["Unit_0", "Unit_2"])
        out = rf.development_intents(anchored, tactical=observation(10.0, 3.0),
                                     rules=RULES, server_tick=1000, snapshot_id=5)
        pos = out[0]["target"]["pos"]
        nearest = placement.first_own_distance(
            pos, own_points(observation(10.0, 3.0)))
        self.assertLessEqual(nearest, placement.VISION_SAFE_RADIUS_M + 0.01,
                             "未知地图尺寸时落点也必须留在视野内：%s" % (pos,))

    def test_frame_build_spots_pass_preconditions(self):
        """模型侧决策帧给出的每一个建造候选都必须合法（模型只会从中挑）。"""
        for label, (base_x, base_z), bounds in SCENARIOS:
            with self.subTest(scenario=label):
                tactical = observation(base_x, base_z)
                frame = squads.build_decision_frame(
                    match_id="m", player_id="Player_0", rules_version="h",
                    snapshot_id=1, server_tick=1, tactical=tactical, rules=RULES,
                    map_bounds=bounds)
                self.assertTrue(frame.build_spots, "没有候选 = 模型无从下手")
                for spot in frame.build_spots:
                    self._assert_spot_ok(spot, bounds, own_points(tactical),
                                         "build_decision_frame")

    def test_reserves_open_when_no_idle_builder(self):
        """没有空闲工人时不得产出建造命令（"命令发了没人干"也是同类浪费）。"""
        tactical = observation(10.0, 7.0, builders=False)
        out = rf.development_intents(ladder_state(["Unit_0"]), tactical=tactical,
                                     rules=RULES, server_tick=1000, snapshot_id=5)
        self.assertEqual([item for item in out if item["action"] == "build"], [])


class SingleSourceOfTruthTest(unittest.TestCase):
    """几何口径只能有一份 —— 两份口径就是同类问题换皮复发的温床。"""

    def test_constants_are_shared(self):
        self.assertEqual(rf.BUILD_BOUND_MARGIN_M, placement.BUILD_BOUND_MARGIN_M)
        self.assertEqual(squads.BUILD_BOUND_MARGIN_M, placement.BUILD_BOUND_MARGIN_M)
        self.assertEqual(squads.VISION_SAFE_RADIUS_M, placement.VISION_SAFE_RADIUS_M)

    def test_bounds_judgement_is_identical(self):
        bounds = [20.0, 20.0]
        for x in (-1.0, 0.0, 3.0, 10.0, 17.0, 20.0, 25.0):
            for z in (3.0, 10.0, 17.0):
                point = [x, 0.0, z]
                self.assertEqual(rf.in_map_bounds(point, bounds),
                                 placement.in_bounds(point, bounds),
                                 "两侧口径不一致：%s" % (point,))

    def test_rejection_classification_is_finite(self):
        cases = {
            "Rejected OutOfBounds": placement.REJECT_GEOMETRY,
            "NotVisible": placement.REJECT_VISION,
            "Occupied": placement.REJECT_OCCUPANCY,
            "InvalidScene": placement.REJECT_CONTRACT,
            "StaleGeneration": placement.REJECT_STALE,
            "某种没见过的新原因": placement.REJECT_OTHER,
        }
        for text, expected in cases.items():
            self.assertEqual(placement.classify_rejection(text), expected, text)

    def test_reasonless_rejection_is_its_own_class(self):
        """**链路没给原因** ≠ 未知原因。

        2026-09-12 真机：`build` 续建被误报成 `Rejected` + 空原因，被归到"未知"→ 不记账、
        不退避 → 5 分钟重发同一条命令 30 次（占该局全部命令的 26%）。
        空原因必须独立成类并按**意图前缀**停发。
        """
        for text in ("", "Rejected", "Rejected ", "Rejected  "):
            self.assertEqual(placement.classify_rejection(text),
                             placement.REJECT_UNSPECIFIED, repr(text))
        self.assertIn(placement.REJECT_UNSPECIFIED, placement.PREFIX_BAN_KINDS)
        # 无原因**不得**触发全局退避：说不清原因的一次拒绝不该停住整局建造。
        self.assertNotIn(placement.REJECT_UNSPECIFIED, placement.CONTENT_KINDS)
        ledger = placement.RejectionLedger()
        for tick in (10, 11, 12):
            ledger.add(placement.REJECT_UNSPECIFIED, "rule-finish-site", tick)
        self.assertTrue(ledger.is_banned("rule-finish-site", 13),
                        "无原因拒绝刷到阈值后必须停发该类意图")

    def test_intent_prefix_groups_the_same_kind(self):
        self.assertEqual(placement.intent_prefix("rule-produce-worker-Unit_0-1234"),
                         "rule-produce-worker")
        self.assertEqual(placement.intent_prefix("rule-build-barracks-Unit_2-99"),
                         "rule-build-barracks")
        self.assertEqual(placement.intent_prefix("rule-scout-Unit_5-7"), "rule-scout")


class RejectionLedgerGateTest(unittest.TestCase):
    """内容类拒绝必须**真的停发该类意图**（而不是每 tick 重发同一条坏命令）。"""

    def test_banned_intent_kind_is_not_emitted(self):
        # 建造阶梯已满足 → 轮到阶梯 1.8"补工人"。
        # 「已满足」用**规则视图里没有可建项**来表达：直接写死"建了几座"会随
        # `BUILD_LIMITS` 调整而失效（这类用例只该关心"被拒的类别必须停发"）。
        tactical = observation(10.0, 7.0, barracks=True, factory=True)
        st = ladder_state(["Unit_0", "Unit_2", "Unit_4", "Unit_5"])
        no_buildable = {**RULES, "constructions": []}
        first = rf.development_intents(st, tactical=tactical, rules=no_buildable,
                                       server_tick=1000, snapshot_id=5)
        worker_kind = [item for item in first
                       if str(item["intent_id"]).startswith("rule-produce-worker")]
        self.assertTrue(worker_kind, "前提：正常应产出补工人意图：%s" % (first,))
        # 模拟权威端连续 3 次以"内容类"原因拒绝该类意图。
        ledger = placement.RejectionLedger()
        for tick in (1000, 1001, 1002):
            ledger.add(placement.REJECT_CONTRACT, "rule-produce-worker", tick)
        placement.ledger_to_state(ledger, st)
        after = rf.development_intents({**st, "server_tick": 1003}, tactical=tactical,
                                       rules=no_buildable, server_tick=1003, snapshot_id=5)
        self.assertFalse([item for item in after
                          if str(item["intent_id"]).startswith("rule-produce-worker")],
                         "被拒的意图类别必须停发：%s" % (after,))

    def test_geometry_ban_only_blocks_that_spot(self):
        """几何类拒绝只拉黑**那个点**，不得让别的落点跟着一起不可用。"""
        ledger = placement.RejectionLedger()
        bad = [4.0, 6.0]
        for tick in (100, 101, 102):
            ledger.add(placement.REJECT_VISION, placement.spot_key(bad), tick)
        self.assertTrue(ledger.is_banned(placement.spot_key(bad)))
        self.assertFalse(ledger.is_banned(placement.spot_key([0.0, 0.0])))
        ok = placement.candidate_spots(10.0, 10.0, bounds=[60.0, 60.0],
                                       own_points=[(10.0, 10.0)],
                                       rejected=ledger,
                                       radii=(4.0,))
        self.assertTrue(ok, "一个坏点不应让整圈候选消失")
        self.assertNotIn("4,6", [placement.spot_key(spot) for spot in ok])


if __name__ == "__main__":
    unittest.main()
