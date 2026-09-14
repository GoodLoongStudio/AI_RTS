# -*- coding: utf-8 -*-
"""探索前沿 + 访问记忆（计划 U1 / 审查 F01）。

要钉住的四个事实（都能在纯函数里判定）：
① **不再是固定点**：连续选点必须随"到达"更新（旧口径 ring 取任何值都返回同一坐标）；
② **到达 → 换下一个前沿**：≥3 个不同前沿（T01 的硬断言）；
③ **受阻 → 退避换目标**：同一前沿连续失败 `EXPLORE_MAX_FAILURES` 次 → 标 `unreachable` 并换；
④ **记忆有界 + 确定性**：格数不超上限，同一状态必得同一点。
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph import rules_fallback as rf  # noqa: E402

BASE = [10.0, 7.0]
BOUNDS = [50.0, 50.0]


def state():
    return {"server_tick": 1000, "map_bounds": list(BOUNDS)}


def choose(current, *, invalidation="", ok=True, tick=1000, unit="Unit_1"):
    """选前沿，并把"上一条路线"的结局摆好（模拟 movement 的记录）。"""
    state_now = current
    state_now.setdefault("routes", {})[unit] = {
        "ok": bool(ok), "target": list(current["last_point"] or []),
        "invalidated_reason": invalidation, "arrived_tick": tick,
    }
    return rf.explore_frontier(state_now, BASE, BOUNDS, unit=unit)


class ExploreFrontierTest(unittest.TestCase):
    def test_first_selection_is_a_point_inside_bounds(self):
        state_now = state()
        first = rf.explore_frontier(state_now, BASE, BOUNDS, unit="Unit_1")
        self.assertIsNotNone(first)
        self.assertTrue(rf.placement.in_bounds(first["point"], BOUNDS,
                                              rf.ADVANCE_EDGE_MARGIN_M))
        self.assertEqual(state_now["explore"]["current"], first["cell"])

    def test_arrival_moves_to_a_different_frontier(self):
        """到达 → 换前沿（≥3 个不同格）。旧口径在这里会返回同一个坐标。"""
        state_now = state()
        seen = []
        seen_points = []
        for _ in range(4):
            picked = rf.explore_frontier(state_now, BASE, BOUNDS, unit="Unit_1")
            self.assertIsNotNone(picked)
            seen.append(picked["cell"])
            seen_points.append(tuple(picked["point"]))
            # 模拟"这一跳真的走到了"：路线目标 = 本前沿、invalidated_reason = arrived
            state_now["routes"] = {"Unit_1": {"ok": True, "target": list(picked["point"]),
                                              "invalidated_reason": "arrived",
                                              "arrived_tick": 1000}}
        self.assertGreaterEqual(len(set(seen)), 3, "到达后必须换前沿：%s" % seen)
        # 而且必须是**坐标上不同**的前沿（不同格被边缘夹到同一点是无效推进）。
        self.assertGreaterEqual(len(set(seen_points)), 3,
                                "换了格却给了同一个坐标（夹取重复）：%s" % seen_points)
        covered = [item for item in state_now["explore"]["cells"].values()
                   if item.get("state") == "covered"]
        self.assertGreaterEqual(len(covered), 3)

    def test_navmesh_unavailable_switches_immediately_and_waits(self):
        """T02：网格不可用立刻换目标，格标 waiting 而不是 unreachable。"""
        state_now = state()
        first = rf.explore_frontier(state_now, BASE, BOUNDS, unit="Unit_1")
        state_now["nav_revision"] = 1
        state_now["routes"] = {"Unit_1": {"ok": False, "target": list(first["point"]),
                                          "reason": "navmesh_unavailable",
                                          "invalidated_reason": "navmesh_unavailable"}}
        nxt = rf.explore_frontier(state_now, BASE, BOUNDS, unit="Unit_1")
        self.assertIsNotNone(nxt)
        self.assertNotEqual(nxt["cell"], first["cell"], "临时断路必须立刻换目标")
        entry = state_now["explore"]["cells"].get(first["cell"]) or {}
        self.assertEqual(entry.get("state"), "waiting")
        self.assertEqual(entry.get("wait_reason"), "navmesh_unavailable")

    def test_nav_revision_zero_waits_then_reopens(self):
        """T02：版本 0 是合法值；临时断路记下 wait_revision=0，版本变化后重新打开。"""
        state_now = state()
        state_now["nav_revision"] = 0
        first = rf.explore_frontier(state_now, BASE, BOUNDS, unit="Unit_1")
        state_now["routes"] = {"Unit_1": {"ok": False, "target": list(first["point"]),
                                          "reason": "navmesh_unavailable",
                                          "invalidated_reason": "navmesh_unavailable"}}
        rf.explore_frontier(state_now, BASE, BOUNDS, unit="Unit_1")
        entry = state_now["explore"]["cells"].get(first["cell"]) or {}
        self.assertEqual(entry.get("state"), "waiting",
                         "临时断路不得标成永久 unreachable：%s" % entry)
        self.assertEqual(entry.get("wait_revision"), 0,
                         "版本 0 必须原样记下，不许写成 -1：%s" % entry)
        state_now["nav_revision"] = 2
        again = rf.explore_frontier(state_now, BASE, BOUNDS, unit="Unit_1")
        self.assertIsNotNone(again)
        reopened = state_now["explore"]["cells"].get(first["cell"]) or {}
        self.assertEqual(reopened.get("state"), "open",
                         "恢复后必须重新打开：%s" % reopened)

    def test_repeated_failure_marks_unreachable_and_switches(self):
        """同一前沿连续失败到上限 → 标 `unreachable` 并**换目标**（不是无限重试）。"""
        state_now = state()
        first = rf.explore_frontier(state_now, BASE, BOUNDS, unit="Unit_1")
        state_now["routes"] = {"Unit_1": {"ok": False, "target": list(first["point"]),
                                          "invalidated_reason": "path_failed"}}
        for _ in range(rf.EXPLORE_MAX_FAILURES + 1):
            rf.explore_frontier(state_now, BASE, BOUNDS, unit="Unit_1")
        entry = state_now["explore"]["cells"].get(first["cell"]) or {}
        self.assertIn(entry.get("state"), ("unreachable", "covered"),
                      "失败到上限必须落一个终态：%s" % entry)

    def test_memory_is_bounded(self):
        state_now = state()
        state_now["explore"] = {"cells": {}, "current": "", "selected": 0}
        for index in range(rf.EXPLORE_MEMORY_LIMIT * 2):
            state_now["explore"].setdefault("cells", {})["%d,%d" % (index, index)] = {
                "state": "covered"}
        rf.explore_frontier(state_now, BASE, BOUNDS, unit="Unit_1")
        # 上限口径：修剪在"选点前"做，选点后最多再加 2 条（出发格 + 本次前沿）→ LIMIT + 2。
        self.assertLessEqual(len(state_now["explore"]["cells"]), rf.EXPLORE_MEMORY_LIMIT + 2,
                             "访问记忆必须有界（长局不许无限增长）")

    def test_deterministic(self):
        first = rf.explore_frontier(state(), BASE, BOUNDS, unit="Unit_1")
        second = rf.explore_frontier(state(), BASE, BOUNDS, unit="Unit_1")
        self.assertEqual(first["cell"], second["cell"])
        self.assertEqual(first["point"], second["point"])

    def test_intel_biases_the_frontier_toward_it(self):
        """有情报 → 前沿偏向情报点（"朝上次见过敌人的方向"），而不是只看离基地远近。"""
        state_now = state()
        far_intel = [[45.0, 45.0]]
        picked = rf.explore_frontier(state_now, BASE, BOUNDS, unit="Unit_1", intel=far_intel)
        self.assertIsNotNone(picked)
        self.assertEqual(picked["reason"], "toward_intel")
        distance_base = ((picked["point"][0] - BASE[0]) ** 2
                         + (picked["point"][1] - BASE[1]) ** 2) ** 0.5
        # 朝情报方向时，选出的前沿应比"最近未访问格"更远（否则情报没起作用）
        nearest = rf.explore_frontier(state(), BASE, BOUNDS, unit="Unit_2")
        distance_nearest = ((nearest["point"][0] - BASE[0]) ** 2
                            + (nearest["point"][1] - BASE[1]) ** 2) ** 0.5
        self.assertGreaterEqual(round(distance_base, 1), round(distance_nearest, 1))

    def test_waypoint_uses_frontier_when_state_given(self):
        """`military_waypoint(state=…)` 无情报时必须走前沿（不再返回固定几何点）。"""
        state_now = state()
        first = rf.military_waypoint(BASE, bounds=BOUNDS, state=state_now, unit="Unit_1")
        self.assertTrue(first)
        second = rf.military_waypoint(BASE, bounds=BOUNDS, state=state_now, unit="Unit_1")
        self.assertEqual(first, second, "同一前沿未到达前保持同一点（不抖）")
        # 模拟到达 → 应换点
        state_now["routes"] = {"Unit_1": {"ok": True, "target": list(first),
                                          "invalidated_reason": "arrived", "arrived_tick": 1}}
        third = rf.military_waypoint(BASE, bounds=BOUNDS, state=state_now, unit="Unit_1")
        self.assertNotEqual(first, third, "到达后必须换下一个前沿")

    def test_legacy_behaviour_without_state(self):
        """不给 `state` → 保持旧几何口径（向后兼容，别把老调用点打崩）。"""
        point = rf.military_waypoint(BASE, bounds=BOUNDS, ring=2)
        self.assertEqual(len(point), 2)

    def test_other_unit_cannot_steal_scout_arrival(self):
        """地面单位调用不得冲掉侦察机的到达结算（`u1t01d` 的区分断言）。"""
        state_now = state()
        first = rf.explore_frontier(state_now, BASE, BOUNDS, unit="Unit_1")
        self.assertIsNotNone(first)
        # 士兵只读选点：不改 assigned / current
        other = rf.explore_frontier(state_now, BASE, BOUNDS, unit="Unit_11",
                                    ring=2, commit=False)
        self.assertIsNotNone(other)
        self.assertEqual(state_now["explore"]["assigned"]["Unit_1"], first["cell"])
        self.assertEqual(state_now["explore"]["current"], first["cell"])
        state_now["routes"] = {"Unit_1": {"ok": True, "target": list(first["point"]),
                                          "invalidated_reason": "arrived",
                                          "arrived_tick": 1200}}
        nxt = rf.explore_frontier(state_now, BASE, BOUNDS, unit="Unit_1")
        self.assertIsNotNone(nxt)
        self.assertNotEqual(nxt["cell"], first["cell"])
        covered = [item for item in state_now["explore"]["cells"].values()
                   if item.get("state") == "covered" and item.get("role") == "scout"]
        self.assertEqual(len(covered), 1)

    def test_selected_does_not_increment_while_holding(self):
        state_now = state()
        first = rf.explore_frontier(state_now, BASE, BOUNDS, unit="Unit_1")
        selected = int(state_now["explore"]["selected"])
        again = rf.explore_frontier(state_now, BASE, BOUNDS, unit="Unit_1")
        self.assertEqual(first["cell"], again["cell"])
        self.assertEqual(int(state_now["explore"]["selected"]), selected)

    def test_probe_unit_prefers_non_drone(self):
        """扩张前探优先用地面机动单位，不抽走唯一无人机。"""
        by_name = {
            "Unit_1": {"type": "drone", "movement": True},
            "Unit_10": {"type": "soldier", "movement": True},
        }
        picked = rf._pick_probe_unit(by_name, ["Unit_1", "Unit_10"], set())
        self.assertEqual(picked, "Unit_10")

    def test_scout_executor_prefers_living_drone(self):
        by_name = {
            "Unit_1": {"type": "drone", "movement": True, "hp": 6},
            "Unit_10": {"type": "soldier", "movement": True, "hp": 4},
        }
        self.assertEqual(
            rf.pick_scout_executor(by_name, ["Unit_1", "Unit_10"], set()), "Unit_1")

    def test_dead_drone_transfers_scout_to_soldier(self):
        """专职阵亡 → 转交地面机动单位（T03 换执行者）。"""
        explore = {"assigned": {"Unit_1": "0,0"}, "current": "0,0"}
        by_name = {
            "Unit_1": {"type": "drone", "movement": True, "hp": 0, "confirmed_dead": True},
            "Unit_10": {"type": "soldier", "movement": True, "hp": 4},
        }
        picked = rf.pick_scout_executor(
            by_name, ["Unit_1", "Unit_10"], set(), explore=explore)
        self.assertEqual(picked, "Unit_10")
        self.assertNotIn("Unit_1", explore.get("assigned") or {})

    def test_player_taken_drone_transfers_scout(self):
        """玩家接管 = 不在 ai_controlled 里 → 转交，且不夺回。"""
        by_name = {
            "Unit_1": {"type": "drone", "movement": True, "hp": 6},
            "Unit_10": {"type": "soldier", "movement": True, "hp": 4},
        }
        picked = rf.pick_scout_executor(by_name, ["Unit_10"], set())
        self.assertEqual(picked, "Unit_10")

    def test_busy_living_drone_does_not_transfer(self):
        """专职还在编制里只是忙碌 → 不抢工人。"""
        by_name = {
            "Unit_1": {"type": "drone", "movement": True, "hp": 6},
            "Unit_2": {"type": "worker", "movement": True, "gather": True, "hp": 4},
        }
        picked = rf.pick_scout_executor(
            by_name, ["Unit_1", "Unit_2"], {"Unit_1"})
        self.assertEqual(picked, "")

    def test_parallel_fill_issues_scout_to_replacement(self):
        state_now = {
            "server_tick": 2000, "map_bounds": [50.0, 50.0],
            "ai_controlled_units": ["Unit_0", "Unit_10"],
            "active_intents": [],
            "explore": {"assigned": {"Unit_1": "0,0"}, "current": "0,0",
                        "cells": {}, "selected": 1},
            "own_unit_types": {"Unit_10": "soldier"},
        }
        tactical = {"entities": [
            {"kind": "unit_self", "name": "Unit_0", "unit_type": "command_center",
             "queue": True, "pos": [10.0, 0.0, 7.0]},
            {"kind": "unit_self", "name": "Unit_10", "unit_type": "soldier",
             "movement": True, "hp": 4, "pos": [18.0, 0.0, 8.0]},
        ], "balance": {"A": 1000}}
        out = rf._parallel_intents(state_now, tactical=tactical, primary=[],
                                   ttl_ticks=3600, server_tick=2000, snapshot_id=1)
        scout = [item for item in out
                 if str(item.get("intent_id", "")).startswith("rule-fill-scout")]
        self.assertEqual(len(scout), 1, scout)
        self.assertEqual(scout[0]["unit_ids"], ["Unit_10"])
        self.assertEqual(scout[0]["action"], "scout")

    def test_parallel_fill_preempts_gatherer_when_no_scout(self):
        """开局无空闲士兵：专职没了就抢采集工继续探（T03 真机编制）。"""
        state_now = {
            "server_tick": 2000, "map_bounds": [50.0, 50.0],
            "ai_controlled_units": ["Unit_0", "Unit_2"],
            "active_intents": [
                {"intent_id": "rule-fill-gather-Unit_2-1000", "action": "gather",
                 "unit_ids": ["Unit_2"], "state": "active"},
            ],
            "explore": {"assigned": {"Unit_1": "0,0"}, "current": "0,0",
                        "cells": {}, "selected": 1},
            "own_unit_types": {"Unit_2": "worker"},
        }
        tactical = {"entities": [
            {"kind": "unit_self", "name": "Unit_0", "unit_type": "command_center",
             "queue": True, "pos": [10.0, 0.0, 7.0]},
            {"kind": "unit_self", "name": "Unit_2", "unit_type": "worker",
             "movement": True, "gather": True, "hp": 4, "pos": [12.0, 0.0, 8.0]},
        ], "balance": {"A": 1000}}
        out = rf._parallel_intents(state_now, tactical=tactical, primary=[],
                                   ttl_ticks=3600, server_tick=2000, snapshot_id=1)
        scout = [item for item in out
                 if str(item.get("intent_id", "")).startswith("rule-fill-scout")]
        self.assertEqual(len(scout), 1, scout)
        self.assertEqual(scout[0]["unit_ids"], ["Unit_2"])
        gather = state_now["active_intents"][0]
        self.assertEqual(gather["state"], "dropped")
        self.assertEqual(gather["drop_reason"], "scout_executor_transfer")

    def test_parallel_fill_does_not_steal_worker_while_drone_busy(self):
        """专职仍在编制只是忙碌 → 不转交、不拆采集。"""
        state_now = {
            "server_tick": 2000, "map_bounds": [50.0, 50.0],
            "ai_controlled_units": ["Unit_0", "Unit_1", "Unit_2"],
            "active_intents": [
                {"intent_id": "rule-fill-scout-Unit_1-1000", "action": "scout",
                 "unit_ids": ["Unit_1"], "state": "active"},
                {"intent_id": "rule-fill-gather-Unit_2-1000", "action": "gather",
                 "unit_ids": ["Unit_2"], "state": "active"},
            ],
            "explore": {"assigned": {"Unit_1": "0,0"}, "current": "0,0",
                        "cells": {}, "selected": 1},
            "own_unit_types": {"Unit_1": "drone", "Unit_2": "worker"},
        }
        tactical = {"entities": [
            {"kind": "unit_self", "name": "Unit_0", "unit_type": "command_center",
             "queue": True, "pos": [10.0, 0.0, 7.0]},
            {"kind": "unit_self", "name": "Unit_1", "unit_type": "drone",
             "movement": True, "hp": 6, "pos": [17.5, 1.5, 17.5]},
            {"kind": "unit_self", "name": "Unit_2", "unit_type": "worker",
             "movement": True, "gather": True, "hp": 4, "pos": [12.0, 0.0, 8.0]},
        ], "balance": {"A": 1000}}
        out = rf._parallel_intents(state_now, tactical=tactical, primary=[],
                                   ttl_ticks=3600, server_tick=2000, snapshot_id=1)
        scout = [item for item in out
                 if str(item.get("intent_id", "")).startswith("rule-fill-scout")]
        self.assertEqual(scout, [])
        self.assertEqual(state_now["active_intents"][1]["state"], "active")


if __name__ == "__main__":
    unittest.main()
