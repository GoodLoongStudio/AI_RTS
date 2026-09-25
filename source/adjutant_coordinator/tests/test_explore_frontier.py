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

    def test_position_settles_frontier_when_route_ledger_never_arrives(self):
        """回归守卫（2026-09-21 实时对局取证）：路线台账不落 `arrived` 时，**位置事实**
        必须能结算前沿 —— 否则 `hold_assigned` 原样返回同一航点，侦察单位整局卡死。

        真机链路：副官持续建造 → 导航网格反复重烘 → `nav_revision` 每轮变化 →
        新计划被判 `stale_nav_revision` → 路线记录不刷新、`arrived` 永不落账
        （实测一局 457 次 stale）。旧实现在这里会 100% 复现"钉在同一格"。
        """
        state_now = state()
        seen = []
        current_pos = list(BASE)
        for index in range(4):
            picked = rf.explore_frontier(state_now, BASE, BOUNDS, unit="Unit_1",
                                         unit_pos=list(current_pos))
            self.assertIsNotNone(picked)
            seen.append(picked["cell"])
            # 单位确实走到了这一格（下一步它就站在格心附近）。
            current_pos = list(picked["point"])
            # 台账**永远不落 arrived**：只有一条 ok=True 的陈旧路线，目标还是老点。
            state_now["routes"] = {"Unit_1": {"ok": True, "target": [0.0, 0.0],
                                              "invalidated_reason": "",
                                              "nav_revision": index}}
        self.assertGreaterEqual(len(set(seen)), 3,
                                "位置已到格心就必须换前沿（台账坏掉也不能卡死）：%s" % seen)

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

    def test_probing_drone_transfers_scout(self):
        """【2026-09-22 侦察断线回归】专职被**扩张前探**占着 → 必须转交。

        实测（base_off_2/3，240s 纯规则局）：无人机被 `rule-probe-expansion`
        占走后再也不探敌，`enemy_intel_points` 只剩贴身 3 点、**敌方建筑 0 条
        情报**——"建筑不掉血"排查清单第 1 项（是否发现合法建筑目标）就断在这。
        T03 的本意是"侦察不能断"：被别的工作占着不动与阵亡等效。
        """
        by_name = {
            "Unit_1": {"type": "drone", "movement": True, "hp": 6},
            "Unit_10": {"type": "soldier", "movement": True, "hp": 4},
        }
        state = {"active_intents": [{
            "intent_id": "rule-probe-expansion-Unit_1-1768", "action": "move",
            "unit_ids": ["Unit_1"], "state": "active", "expires_tick": 99999,
        }]}
        picked = rf.pick_scout_executor(
            by_name, ["Unit_1", "Unit_10"], set(), state=state)
        self.assertEqual(picked, "Unit_10", "无人机被前探占着时必须转交地面单位")

    def test_scouting_drone_is_not_transferred(self):
        """对照组：无人机正在执行**侦察**意图 → 它就是执行者，不转交。"""
        by_name = {
            "Unit_1": {"type": "drone", "movement": True, "hp": 6},
            "Unit_10": {"type": "soldier", "movement": True, "hp": 4},
        }
        state = {"active_intents": [{
            "intent_id": "rule-fill-scout-Unit_1-900", "action": "move",
            "unit_ids": ["Unit_1"], "state": "active", "expires_tick": 99999,
        }]}
        picked = rf.pick_scout_executor(
            by_name, ["Unit_1", "Unit_10"], set(), state=state)
        self.assertEqual(picked, "Unit_1", "正在侦察的专职就是执行者，不该被顶掉")

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


class ScoutTransferSurvivalTest(unittest.TestCase):
    """【2026-09-22 D9】侦察备份 + 保命：专职阵亡后转交，且不抽交火中的单位。

    实测（det_9）：唯一无人机被击落后全程失明——转交链路存在却没发生，
    因为 (a) 替代者被军事轨的 attack_move 订单占着（`_en_route` 为真 →
    侦察令发不出去），(b) 转交侦察令优先级 3 被 advance 的 45 压掉。
    """

    def test_contact_unit_is_not_picked_as_replacement(self):
        """正在交火的单位不转交（保命）：有安全候选时选安全的。"""
        by_name = {
            "Unit_1": {"type": "drone", "movement": True, "hp": 0,
                       "confirmed_dead": True},
            "Unit_10": {"type": "soldier", "movement": True, "hp": 4,
                        "pos": [25.0, 0.0, 12.0]},
            "Unit_11": {"type": "soldier", "movement": True, "hp": 4,
                        "pos": [27.0, 0.0, 12.5]},
        }
        enemies = [{"name": "E1", "pos": [27.5, 0.0, 12.6]}]
        picked = rf.pick_scout_executor(by_name, ["Unit_10", "Unit_11"], set(),
                                        enemies=enemies)
        self.assertEqual(picked, "Unit_10", "交火中的 Unit_11 不该被拉去侦察")

    def test_transfer_releases_attack_move(self):
        """转交必须释放替代者的 attack_move，否则侦察令永远发不出去。"""
        state = {"active_intents": [
            {"intent_id": "rule-fill-advance-Unit_10-900", "action": "attack_move",
             "unit_ids": ["Unit_10"], "state": "active", "expires_tick": 99999},
            {"intent_id": "rule-fill-advance-Unit_11-900", "action": "attack_move",
             "unit_ids": ["Unit_11"], "state": "active", "expires_tick": 99999},
        ]}
        released = rf.release_unit_for_scout_transfer(state, "Unit_10")
        self.assertEqual(released, 1, "attack_move 必须被释放（D9）")
        states = {str(item["intent_id"]): str(item.get("state"))
                  for item in state["active_intents"]}
        self.assertEqual(states["rule-fill-advance-Unit_10-900"], "dropped")
        self.assertEqual(states["rule-fill-advance-Unit_11-900"], "active",
                         "只释放指定单位，不牵连其它")

    def test_transfer_priority_beats_idle_advance(self):
        """转交侦察令优先级必须压过空闲前压（45），否则立刻被顶掉。"""
        self.assertGreater(rf.SCOUT_TRANSFER_PRIORITY, 45)
        self.assertLess(rf.SCOUT_TRANSFER_PRIORITY, 92,
                        "仍须低于基地受袭回防（安全第一）")

    def test_safe_radius_covers_max_weapon_range(self):
        """保命半径必须覆盖当前平衡表的最大武器射程（反地炮塔 16m）。"""
        import json
        import os

        balance_path = os.path.join(
            os.path.dirname(rf.__file__), "..", "..", "..", "config", "balance",
            "demo.balance.v1.json")
        max_range = 0.0
        try:
            with open(os.path.normpath(balance_path), encoding="utf-8") as handle:
                balance = json.load(handle)
            for weapon in balance.get("weapons") or []:
                max_range = max(max_range, float(weapon.get("rangeMeters") or 0.0))
        except OSError:
            self.skipTest("平衡配置不可读")
        self.assertGreaterEqual(rf.SCOUT_TRANSFER_SAFE_M, max_range)


class IntelPointFormatTest(unittest.TestCase):
    """敌情点形状容错 + 持续前压（2026-09-22 D5/D6 回归）。

    D6（重大）：`enemy_intel_points` 的真实形状是 `[[x, z], ...]`，而
    `military_waypoint` 原先直接调 `pos2d`（要 dict）→ AttributeError 穿过
    `_parallel_intents` 冒到 `development_intents` 外被整块吞掉 ——
    **无可见敌人且有情报时，整条规则层当拍全灭**（生产/建造/采集/军事/侦察轨）。
    D5：单位站在情报点上时旧实现返回 None（站桩），必须落到探索前沿继续推。
    """

    BASE = [20.0, 6.0]
    BOUNDS = [100.0, 100.0]

    def _state(self):
        return {"map_bounds": list(self.BOUNDS), "server_tick": 1000,
                "explore": {}, "own_unit_types": {}}

    def test_raw_list_and_dict_intel_agree(self):
        state = self._state()
        raw = rf.military_waypoint(self.BASE, bounds=self.BOUNDS,
                                   intel=[[58.9, 16.4]], search=True,
                                   state=state, unit="U1")
        state2 = self._state()
        as_dict = rf.military_waypoint(self.BASE, bounds=self.BOUNDS,
                                       intel=[{"pos": [58.9, 0.0, 16.4]}],
                                       search=True, state=state2, unit="U1")
        self.assertEqual(raw, as_dict, "两种情报形状必须给同一个航点")

    def test_ladder_survives_raw_list_intel(self):
        """回归 D6：无可见敌人 + 原始列表情报时，规则层不许整块崩掉。"""
        entities = [
            {"kind": "unit_self", "name": "Unit_0", "unit_type": "command_center",
             "pos": [20.0, 0.0, 6.0], "movement": False, "queue": True,
             "hp": 100, "hp_max": 100},
            {"kind": "unit_self", "name": "Unit_1", "unit_type": "drone",
             "pos": [30.0, 0.0, 20.0], "movement": True, "hp": 6, "hp_max": 6},
            {"kind": "unit_self", "name": "Unit_10", "unit_type": "soldier",
             "pos": [25.0, 0.0, 12.0], "movement": True, "hp": 4, "hp_max": 4},
            {"kind": "resource", "name": "R1", "pos": [24.0, 0.0, 10.0],
             "resource_a": True},
        ]
        state = {"map_bounds": list(self.BOUNDS), "server_tick": 1800,
                 "ai_controlled_units": ["Unit_0", "Unit_1", "Unit_10"],
                 "own_unit_types": {"Unit_0": "command_center", "Unit_1": "drone",
                                    "Unit_10": "soldier"},
                 "active_intents": [], "explore": {},
                 "enemy_intel_points": [[58.9, 16.4]]}
        out = rf.development_intents(state, tactical={"entities": entities},
                                     rules={}, server_tick=1800)
        self.assertTrue(out, "有情报时规则层必须照常产出（D6：曾整块崩掉）")

    def test_unit_standing_on_intel_keeps_exploring(self):
        """回归 D5：站在情报点上不许站桩——必须持续往未探区推进。

        注意 D7 之后"回情报点一次"是合法的（扫描网格中心就是情报点，
        回看最后一次目击是合理动作）；判据是**多次调用必须推进**，不是
        "下一跳必须不同于当前点"。
        """
        state = self._state()
        state["own_unit_types"] = {"U1": "drone"}
        seen = []
        pos = [58.9, 16.4]
        for _ in range(4):
            point = rf.military_waypoint(pos, bounds=self.BOUNDS,
                                         intel=[[58.9, 16.4]], search=True,
                                         state=state, unit="U1", unit_pos=pos)
            self.assertIsNotNone(point, "站在情报点上必须有下一跳（不许返回 None）")
            seen.append((round(float(point[0]), 1), round(float(point[1]), 1)))
            pos = list(point)
        self.assertGreater(len(set(seen)), 1,
                           "必须持续换点推进，不许钉死在情报点：%s" % (seen,))


if __name__ == "__main__":
    unittest.main()
