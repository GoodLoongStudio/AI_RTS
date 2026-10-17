# -*- coding: utf-8 -*-
"""P2 安全移动硬闸门测试（计划 §7）。

钉住的不变式（每一条都对应计划原文里的一句"不得"）：

1. 无边界 / 无路径 / 无中继点 / 无侦察确认 → **不许移动**；
2. 工人 / 建造者 / 基地 / 建筑 → **永远不许**野外移动；
3. 网格版本变了（重烘） → 旧路径作废，必须重规划；
4. 路径上有敌人 → 停止推进并送 `urgent`；
5. **规则/行为树只能从 `allowed_relay()` 拿移动目标** —— 没有合法路线就没有目标，
   这就是"没有有效路径的主力移动数为 0"的实现方式。
"""

import math
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph import movement as mv  # noqa: E402


def unit(name, unit_type, pos, *, movement=True, **extra):
    """观测里的己方单位。`movement` 默认 True（真机上机动单位都带这个字段）。

    注意闸门的**失败安全**方向：`movement` 缺失/未知一律按"不可移动"处理
    —— 拿不准就不动，而不是拿不准就往外派（这条由 `test_unknown_movement_is_protected` 钉住）。
    """
    entry = {"kind": "unit_self", "name": name, "unit_type": unit_type,
             "movement": movement, "pos": [float(pos[0]), 0.0, float(pos[1])]}
    entry.update(extra)
    return entry


def enemy(name, pos):
    return {"kind": "unit_enemy", "name": name, "pos": [float(pos[0]), 0.0, float(pos[1])]}


def tactical(entities, balance=None):
    return {"entities": entities, "balance": balance or {"a": 5000}}


def nav_ok(waypoints, *, nav_revision=1, route_length=10.0, end_clamped=False):
    def query(unit_name, target):
        return {"ok": True, "reachable": True, "nav_revision": nav_revision,
                "waypoints": [list(point) for point in waypoints],
                "route_length": route_length, "end_clamped": end_clamped,
                "start_clamped": False}
    return query


def nav_fail(reason="no_path", nav_revision=1):
    def query(unit_name, target):
        return {"ok": False, "reason": reason, "nav_revision": nav_revision}
    return query


class GateTest(unittest.TestCase):
    def _state(self, bounds=(50.0, 50.0), **extra):
        state = {"map_bounds": list(bounds) if bounds else None,
                 "ai_controlled_units": ["Unit_4"], "server_tick": 600}
        state.update(extra)
        return state

    def test_no_bounds_blocks_everything(self):
        plan = mv.plan_safe_route(self._state(bounds=None),
                                  tactical([unit("Unit_4", "soldier", (10, 7))]),
                                  unit="Unit_4", target=[40.0, 40.0], tick=600,
                                  nav_query=nav_ok([[10, 7], [20, 20], [40, 40]]))
        self.assertFalse(plan.ok)
        self.assertEqual(plan.reason, mv.REJECT_NO_BOUNDS)

    def test_invalid_bounds_is_not_guessed(self):
        for bad in ([], [0, 0], [-5, 10], ["a", "b"], [float("inf"), 10]):
            self.assertFalse(mv.valid_bounds(bad), bad)

    def test_unknown_movement_is_protected(self):
        """`movement` 未知/缺失 → 按**不可移动**处理（拿不准就不动，不是拿不准就派出去）。"""
        info = unit("Unit_4", "soldier", (10, 7), movement=False)
        self.assertTrue(mv.is_protected(info))
        self.assertTrue(mv.is_protected({}))

    def test_protected_units_never_move(self):
        """工人 / 建造者 / 基地 / 建筑：计划 §7 第 ④ 条，一律不许野外移动。"""
        for info in (unit("Unit_1", "worker", (10, 7)),
                     unit("Unit_0", "command_center", (10, 7)),
                     unit("Unit_2", "worker", (10, 7), construct=True),
                     unit("Unit_3", "barracks", (10, 7), movement=False)):
            plan = mv.plan_safe_route(self._state(), tactical([info]),
                                      unit=str(info["name"]), target=[40.0, 40.0],
                                      tick=600,
                                      nav_query=nav_ok([[10, 7], [40, 40]]))
            self.assertFalse(plan.ok, info["name"])
            self.assertEqual(plan.reason, mv.REJECT_PROTECTED_UNIT, info["name"])

    def test_no_path_blocks_and_reports_urgent(self):
        plan = mv.plan_safe_route(self._state(),
                                  tactical([unit("Unit_4", "soldier", (10, 7))]),
                                  unit="Unit_4", target=[40.0, 40.0], tick=600,
                                  nav_query=nav_fail())
        self.assertFalse(plan.ok)
        self.assertEqual(plan.reason, mv.REJECT_NO_PATH)
        self.assertEqual(plan.urgent_event, "path_failed",
                         "路径失败必须送 urgent（计划 §7 明确要求）")

    def test_navmesh_unavailable_is_not_a_path(self):
        """重烘期间查不到路 = **不能走**，不是"退化成直线"。"""
        plan = mv.plan_safe_route(self._state(),
                                  tactical([unit("Unit_4", "soldier", (10, 7))]),
                                  unit="Unit_4", target=[40.0, 40.0], tick=600,
                                  nav_query=nav_fail("navmesh_unavailable"))
        self.assertFalse(plan.ok)
        self.assertEqual(plan.relay_point, [])

    def test_no_relay_when_route_leaves_vision(self):
        """整条路径都在视野外 → 没有安全中继点 → 不许推进。

        2026-10-07 判据更新（**产品口径确实变了，不是把测试改绿**）：
        中继点现在按"沿权威路径**逐点**仍被己方视野覆盖的连续前缀"取，而"己方视野"
        包含推进单位自己（旧口径把它排除掉，于是单兵永远只能返回起点 = 零跳 bug）。
        所以"路径在视野外"要用**真的超出自己视野**的路径来验：单位在 (10,7)、
        视野默认 14 米时，(30,30) 已经在 28 米外 —— 第一段就不可见 → `no_relay`。
        """
        plan = mv.plan_safe_route(self._state(),
                                  tactical([unit("Unit_4", "soldier", (10, 7))]),
                                  unit="Unit_4", target=[45.0, 45.0], tick=600,
                                  nav_query=nav_ok([[30, 30], [40, 40], [45, 45]]))
        self.assertFalse(plan.ok)
        self.assertEqual(plan.reason, mv.REJECT_NO_RELAY)

    def test_relay_stops_at_the_edge_of_vision(self):
        """中继点 = 路径上仍被己方视野覆盖的**最远**点（推进一跳，不是走到终点）。

        2026-10-07：一跳长度按**沿路径走过的里程**从起点算（旧实现是"逐个拐点判覆盖"，
        拐点稀疏时一步都走不动）。单位在 (10,7)、默认半径 14 米 →
        一跳上限 14 米；路径 [10,7]→[14,7]→[18,7]→[30,7] 上最远可见点是 x=24
        （离单位 14 米，正好在上限上；x=30 是 20 米，超出）。
        """
        plan = mv.plan_safe_route(self._state(),
                                  tactical([unit("Unit_4", "soldier", (10, 7))]),
                                  unit="Unit_4", target=[30.0, 7.0], tick=600,
                                  nav_query=nav_ok([[10, 7], [14, 7], [18, 7], [30, 7]]))
        self.assertTrue(plan.ok, plan.reason)
        self.assertLess(plan.relay_point[0], 30.0, "不该一步走到终点")
        self.assertAlmostEqual(plan.relay_point[0], 24.0, places=1)
        self.assertAlmostEqual(
            mv.point_distance([10.0, 7.0], plan.relay_point),
            mv.RELAY_VISION_RADIUS_M, places=1,
            msg="一跳长度必须真的用满推进半径，而不是停在某个稀疏拐点上")

    def test_stale_nav_revision_forces_replan(self):
        state = self._state(routes={"Unit_4": {"ok": True, "nav_revision": 1,
                                               "last_replan_tick": 590,
                                               "target": [30.0, 7.0],
                                               "relay_point": [14.0, 7.0]}})
        plan = mv.plan_safe_route(state, tactical([unit("Unit_4", "soldier", (10, 7))]),
                                  unit="Unit_4", target=[30.0, 7.0], tick=600,
                                  nav_query=nav_ok([[10, 7], [14, 7]], nav_revision=2))
        self.assertFalse(plan.ok)
        self.assertEqual(plan.reason, mv.REJECT_STALE_REVISION)

    def test_enemy_on_route_blocks_and_reports_urgent(self):
        near = [[10, 7], [14, 7]]
        plan = mv.plan_safe_route(
            self._state(),
            tactical([unit("Unit_4", "soldier", (10, 7)), enemy("Enemy_1", (14, 7))]),
            unit="Unit_4", target=[20.0, 7.0], tick=600, nav_query=nav_ok(near))
        self.assertFalse(plan.ok)
        self.assertEqual(plan.reason, mv.REJECT_THREAT)
        self.assertEqual(plan.urgent_event, "enemy_on_route")

    def test_happy_path_records_every_required_field(self):
        """计划 §7 要求逐字段留痕：route_id/nav_revision/waypoints/threat_score/..."""
        state = self._state()
        plan = mv.plan_safe_route(state, tactical([unit("Unit_4", "soldier", (10, 7))]),
                                  unit="Unit_4", target=[14.0, 7.0], tick=600,
                                  nav_query=nav_ok([[10, 7], [12, 7], [14, 7]]))
        self.assertTrue(plan.ok, plan.reason)
        mv.record_route(state, plan)
        entry = mv.previous_route(state, "Unit_4")
        for key in ("route_id", "nav_revision", "waypoints", "route_length",
                    "threat_score", "scout_confirmation", "retreat_point",
                    "last_replan_tick", "relay_point"):
            self.assertIn(key, entry, key)
        self.assertTrue(entry["route_id"].startswith("route-"))
        self.assertEqual(entry["retreat_point"], [10.0, 7.0], "撤退点应回当前所在点")


class RelayOutletTest(unittest.TestCase):
    """`allowed_relay()` 是**唯一出口**：没有合法路线就没有移动目标。"""

    def test_no_route_means_no_target(self):
        self.assertIsNone(mv.allowed_relay({}, "Unit_4"))

    def test_blocked_route_is_not_a_target(self):
        state = {"routes": {"Unit_4": {"ok": False, "relay_point": [14.0, 7.0]}}}
        self.assertIsNone(mv.allowed_relay(state, "Unit_4"))

    def test_ok_route_returns_relay(self):
        state = {"routes": {"Unit_4": {"ok": True, "relay_point": [14.0, 7.0]}}}
        self.assertEqual(mv.allowed_relay(state, "Unit_4"), [14.0, 7.0])


class StatsTest(unittest.TestCase):
    def test_stats_expose_the_two_hard_numbers(self):
        state = {}
        plan = mv.RoutePlan(unit="Unit_4", ok=True, reason="", scout_confirmation="unit:U4@600",
                            bound_clamped=True, threat_score=2.0)
        mv.record_route(state, plan)
        mv.record_route(state, mv.RoutePlan(unit="Unit_5", ok=False,
                                            reason=mv.REJECT_NO_PATH))
        stats = mv.movement_stats(state)
        self.assertEqual(stats["planned"], 2)
        self.assertEqual(stats["allowed"], 1)
        self.assertEqual(stats["blocked_reasons"][mv.REJECT_NO_PATH], 1)
        self.assertEqual(stats["bound_clamped"], 1)
        # 侦察先行覆盖率 = **主力**规划里走到"侦察确认"这一步的比例：
        # 上面两条 plan 里，第一条 ok 且带确认、第二条在 `no_path` 就被挡掉（没到确认环节）
        # → 1/2 = 0.5。定义写在 `movement_stats`，这里是它的守门断言。
        self.assertEqual(stats["scout_first_coverage"], 0.5)
        self.assertEqual(stats["unsafe_dispatches"], 0)

    def test_replan_latency_is_measured_from_invalidation(self):
        """重规划延迟（计划 §9）：从"路线失效"到"重新放行"隔了多少 tick，必须能读出来。

        这是"安全闸门有没有把部队卡住"的唯一数字 —— 只看"放行了几条路"看不出来。
        """
        state = {"server_tick": 600}
        mv.record_route(state, mv.RoutePlan(unit="Unit_4", ok=True, last_replan_tick=600))
        mv.invalidate_route(state, "Unit_4", reason="path_failed")
        state["server_tick"] = 640
        mv.record_route(state, mv.RoutePlan(unit="Unit_4", ok=True, last_replan_tick=640))
        stats = mv.movement_stats(state)
        self.assertEqual(stats["replan_latency_last"], 40)
        self.assertEqual(stats["replan_latency_max"], 40)
        self.assertEqual(stats["replan_latency_samples"], 1)
        self.assertEqual(stats["replan_latency_avg"], 40.0)
        # 没有失效就重规划（目标变了）→ 不产生样本（延迟指标不该被正常重规划稀释）。
        mv.record_route(state, mv.RoutePlan(unit="Unit_4", ok=True, last_replan_tick=700))
        self.assertEqual(mv.movement_stats(state)["replan_latency_samples"], 1)

    def test_replan_latency_counts_arrival_driven_replans(self):
        """到达也会让路线失效 → 也必须进延迟样本。

        2026-09-13 实测（240 秒局）：`arrivals=440` 而延迟样本恒 0 —— 因为"到达"只写了
        `arrived_tick`、没写 `invalidated_tick`，指标看起来"没有重规划"，其实是没统计。
        """
        state = {"server_tick": 600}
        mv.record_route(state, mv.RoutePlan(unit="Unit_4", ok=True, last_replan_tick=600))
        mv.note_arrival(state, "Unit_4", 620)
        state["server_tick"] = 700
        mv.record_route(state, mv.RoutePlan(unit="Unit_4", ok=True, last_replan_tick=700))
        stats = mv.movement_stats(state)
        self.assertEqual(stats["arrivals"], 1)
        self.assertEqual(stats["replan_latency_last"], 80)
        self.assertEqual(stats["replan_latency_samples"], 1)

    def test_scout_plans_do_not_inflate_coverage(self):
        """侦察兵的规划**不进**覆盖率分子（2026-09-13 实测：454/1 = 455.0 的假比率）。"""
        state = {}
        mv.record_route(state, mv.RoutePlan(unit="Unit_1", ok=True, role=mv.ROLE_SCOUT,
                                           scout_confirmation="scout:Unit_1@600"))
        mv.record_route(state, mv.RoutePlan(unit="Unit_4", ok=False, role=mv.ROLE_MAIN,
                                           reason=mv.REJECT_NO_RELAY))
        stats = mv.movement_stats(state)
        self.assertEqual(stats["scout_first_coverage"], 0.0,
                         "主力这一次没拿到确认 → 覆盖率必须是 0（不是被侦察兵撑成 >0）")
        self.assertLessEqual(stats["scout_first_coverage"], 1.0)

    def test_replan_decision_reuses_recent_route(self):
        state = {"routes": {"Unit_4": {"ok": True, "nav_revision": 1,
                                       "last_replan_tick": 590,
                                       "target": [30.0, 7.0]}}}
        self.assertFalse(mv.needs_replan(state, "Unit_4", [30.0, 7.0], 1, 600),
                         "目标没变、网格没换版本、间隔未到 → 复用")
        self.assertTrue(mv.needs_replan(state, "Unit_4", [31.0, 7.0], 1, 600),
                        "目标变了 → 重规划")
        self.assertTrue(mv.needs_replan(state, "Unit_4", [30.0, 7.0], 2, 600),
                        "网格换版本 → 重规划")
        self.assertTrue(mv.needs_replan(state, "Unit_4", [30.0, 7.0], 1, 9000),
                        "间隔到期 → 重规划")


class ArrivalAndPathFailedTest(unittest.TestCase):
    """到达 / 路径失败必须**改变后续行为**，不是只记一笔日志。

    这两类事件以前权威端根本不产（`_fast_unsupported` 里显式声明），于是
    "到达后重观测下一跳""路径失败立即停止推进"只是写在注释里的口号。
    现在由 10Hz 采样产出（`DebugControlServer._fast_sample_movement`），
    消费侧必须让它们真的生效 —— 否则又是一次"有字段、没行为"。
    """

    def _ctx(self, events):
        from adjutant_coordinator.graph.nodes import GraphConfig, GraphServices, NodeContext
        services = GraphServices(config=GraphConfig())
        return NodeContext(services=services,
                           observation={"fast_events": events, "tactical": {}, "rules": {}},
                           tick=700)

    def _state(self):
        return {"server_tick": 700, "fast_event_seq": -1,
                "routes": {"Unit_4": {"ok": True, "route_id": "route-1", "nav_revision": 1,
                                      "last_replan_tick": 690, "target": [20.0, 7.0],
                                      "relay_point": [14.0, 7.0]}}}

    def test_path_failed_stops_advancing_and_enters_urgent(self):
        from adjutant_coordinator.graph import nodes
        state = self._state()
        nodes._consume_fast_events(state, self._ctx(
            [{"seq": 5, "kind": "path_failed", "unit": "Unit_4", "server_tick": 700}]))
        route = state["routes"]["Unit_4"]
        self.assertFalse(route["ok"], "路径失败后必须作废路线（不许继续按老路线推进）")
        self.assertEqual(route["invalidated_reason"], "path_failed")
        self.assertIn("path_failed", [item["kind"] for item in state.get("movement_urgent", [])],
                      "路径失败必须进紧急线（计划 §7）")
        self.assertEqual(state["movement_stats"]["invalidations"], 1)

    def test_arrival_forces_replan_of_the_next_hop(self):
        from adjutant_coordinator.graph import nodes
        state = self._state()
        nodes._consume_fast_events(state, self._ctx(
            [{"seq": 6, "kind": "arrival", "unit": "Unit_4", "server_tick": 700}]))
        route = state["routes"]["Unit_4"]
        self.assertEqual(route["arrived_tick"], 700)
        self.assertFalse(route["ok"], "到达后必须重新观测再规划下一跳")
        self.assertEqual(state["movement_stats"]["arrivals"], 1)

    def test_arrival_does_not_complete_a_mission_by_itself(self):
        """到达只表示**移动段**完成，不自动表示侦察/防守/攻击完成（计划 §7 末句）。"""
        from adjutant_coordinator.graph import nodes
        state = self._state()
        state["active_intents"] = [{"intent_id": "i-scout-1", "action": "attack",
                                    "unit_ids": ["Unit_4"]}]
        nodes._consume_fast_events(state, self._ctx(
            [{"seq": 7, "kind": "arrival", "unit": "Unit_4", "server_tick": 700}]))
        intent = state["active_intents"][0]
        self.assertFalse(intent.get("effective_tick"),
                         "arrival 不能给 attack 意图盖「已生效」戳（移动段完成 ≠ 任务完成）")


class SquadTest(unittest.TestCase):
    """小队推进（计划 §7「主力使用稳定小队和中继点，**不让单位各自散开**」）。

    规则的可判定版本：
    ① 小队里**每个**成员都必须有合法路线（能走的先走 = 把队友留下挨打）；
    ② 全队只认**一个**推进点 = 各成员中最保守的那一跳（最慢的队友决定节奏）；
    ③ 队员离该点超过 `SQUAD_MAX_SPREAD_M` → 先集结，不推进。
    """

    def _plan(self, unit, relay, ok=True, reason=""):
        return mv.RoutePlan(unit=unit, ok=ok, reason=reason, relay_point=list(relay))

    def test_squad_target_is_the_most_conservative_hop(self):
        plans = [self._plan("Unit_1", [20.0, 7.0]), self._plan("Unit_2", [14.0, 7.0])]
        positions = {"Unit_1": [10.0, 7.0], "Unit_2": [12.0, 7.0]}
        relay, reason = mv.squad_hop(plans, positions)
        self.assertEqual(reason, "")
        self.assertEqual(relay, [14.0, 7.0], "应取最保守（离自己最近）的那一跳")

    def test_blocked_member_stops_the_whole_squad(self):
        from adjutant_coordinator.graph import nodes
        state = {"map_bounds": [50.0, 50.0], "server_tick": 600}
        view = tactical([unit("Unit_1", "soldier", (10, 7)),
                         unit("Unit_2", "soldier", (11, 7))])
        calls = {"n": 0}

        def query(unit_name, target):
            calls["n"] += 1
            if str(unit_name) == "Unit_2":
                return {"ok": False, "reason": "no_path", "nav_revision": 1}
            return {"ok": True, "reachable": True, "nav_revision": 1,
                    "waypoints": [[10, 7], [14, 7]], "route_length": 4.0}

        ctx = _ctx_with(query, view)
        kept, blocked = nodes._gate_movement(
            state, ctx, [_intent(units=["Unit_1", "Unit_2"], pos=(30.0, 7.0))])
        self.assertEqual(kept, [], "队里有人走不通 → 全队不许动")
        self.assertIn("squad_blocked", blocked[0]["reason"])

    def test_single_unit_is_never_blocked_by_scatter(self):
        """单人**不判**散开（2026-09-13 回归）。

        单人的中继点由 `safe_relay_point` 保证在"己方视野"内，而视野可能是**别的单位**
        提供的 → 该点可能离它自己很远。按散开拦掉 = 前探/前压永远出不了门。
        """
        from adjutant_coordinator.graph import nodes
        state = {"map_bounds": [50.0, 50.0], "server_tick": 600}
        view = tactical([unit("Unit_1", "soldier", (10, 7)),
                         unit("Unit_2", "soldier", (30, 40))])  # 视野由远处队友提供
        ctx = _ctx_with(nav_ok([[10, 7], [14, 7], [30, 40]]), view)
        kept, blocked = nodes._gate_movement(
            state, ctx, [_intent(units=["Unit_1"], pos=(30.0, 40.0))])
        reasons = [item["reason"] for item in blocked]
        self.assertFalse(any("squad_scatter" in reason for reason in reasons),
                         "单人不该被 squad_scatter 拦住：%s" % reasons)

    def test_scattered_squad_does_not_advance(self):
        plans = [self._plan("Unit_1", [20.0, 7.0]), self._plan("Unit_2", [14.0, 7.0])]
        positions = {"Unit_1": [10.0, 7.0], "Unit_2": [40.0, 40.0]}  # 队友在 40 米外
        relay, reason = mv.squad_hop(plans, positions)
        self.assertEqual(relay, [])
        self.assertEqual(reason, mv.REJECT_SQUAD_SCATTER)

    def test_squad_advances_to_one_shared_point(self):
        from adjutant_coordinator.graph import nodes
        state = {"map_bounds": [50.0, 50.0], "server_tick": 600}
        view = tactical([unit("Unit_1", "soldier", (10, 7)),
                         unit("Unit_2", "soldier", (11, 7))])
        ctx = _ctx_with(nav_ok([[10, 7], [14, 7], [18, 7], [30, 7]]), view)
        intent = _intent(units=["Unit_1", "Unit_2"], pos=(30.0, 7.0))
        kept, blocked = nodes._gate_movement(state, ctx, [intent])
        self.assertEqual(blocked, [])
        self.assertEqual(len(kept), 1)
        self.assertIn("squad|Unit_1|Unit_2", state["routes"],
                      "小队路线必须留痕（验收要读「小队推进」）")
        self.assertEqual(state["routes"]["squad|Unit_1|Unit_2"]["squad"],
                         ["Unit_1", "Unit_2"])


def _ctx_with(nav_query, tactical_entities):
    from adjutant_coordinator.graph.nodes import GraphConfig, GraphServices, NodeContext
    services = GraphServices(config=GraphConfig(), nav_query=nav_query)
    return NodeContext(services=services,
                       observation={"tactical": tactical_entities, "rules": {}}, tick=600)


def _intent(units, pos, action="attack_move"):
    return {"intent_id": "rule-fill-advance-%s-600" % units[0], "action": action,
            "unit_ids": list(units), "target": {"pos": list(pos)},
            "priority": 3, "issued_tick": 600, "expires_tick": 1200}


class RelayStartDedupTest(unittest.TestCase):
    """中继点必须**真的把单位往前挪**（2026-10-07 零跳修复的守门测试）。

    背景（用户实测："单个兵走一小段后等很久"）：`safe_relay_point` 旧实现对每个**已有拐点**
    判"是否被己方视野覆盖"，而权威路径在开阔地上常常只回两个端点 → 60 米合法直路返回**起点**，
    调用层照签 `ok=true` 的推进意图 = 位移 0 的空跳（命令账在涨、部队不动）。
    这里钉住四件事：
    ① 稀疏直路 → 沿路径取 `min(半径, 单位视野)` 米处的点（不是起点、不是终点）；
    ② 一跳长度**逐单位**取权威 `sight`，缺字段才退回 14 米；
    ③ 用满视野半径（不再停在稀疏拐点上）；
    ④ 单位已经站在中继点上时不签推进（`relay_too_close`），而不是发一条零位移命令。
    """

    def _state(self, bounds=(200.0, 200.0), **extra):
        state = {"map_bounds": list(bounds), "server_tick": 600,
                 "ai_controlled_units": ["Unit_4"]}
        state.update(extra)
        return state

    def _plan(self, tactical_view, waypoints, *, target=(70.0, 10.0), unit="Unit_4",
              role=mv.ROLE_MAIN):
        return mv.plan_safe_route(self._state(), tactical_view, unit=unit,
                                  target=list(target), tick=600,
                                  nav_query=nav_ok(waypoints), role=role)

    def test_sparse_direct_route_no_longer_collapses_to_the_origin(self):
        """权威直路只有两个端点时，也必须沿路径给出一跳（回归：旧实现返回起点）。"""
        view = tactical([unit("Unit_4", "tank", (10, 10), sight=16.0)])
        plan = self._plan(view, [[10.0, 10.0], [70.0, 10.0]])
        self.assertTrue(plan.ok, plan.reason)
        self.assertNotEqual(plan.relay_point, [10.0, 10.0],
                            "中继点等于起点 = 零位移推进，不许再签发")
        self.assertAlmostEqual(plan.relay_point[1], 10.0, places=3,
                               msg="点必须在权威路径上（不许自己画直线）")
        self.assertAlmostEqual(
            mv.point_distance([10.0, 10.0], plan.relay_point),
            min(16.0, mv.RELAY_MAX_HOP_M), places=3,
            msg="稀疏直路的一跳长度 = min(B2 节奏上限, 单位视野=16)；无友军视野链时单兵不越自己视野")

    def test_hop_length_uses_authoritative_sight_per_unit(self):
        """一跳长度逐单位取 `sight`（tank 16 / scout 24 不是同一个数）。"""
        blocked_on_radius = tactical([unit("Unit_4", "soldier", (10, 10), sight=4.0)])
        short = self._plan(blocked_on_radius, [[10.0, 10.0], [70.0, 10.0]])
        self.assertTrue(short.ok, short.reason)
        self.assertAlmostEqual(
            mv.point_distance([10.0, 10.0], short.relay_point), 4.0, places=3,
            msg="视野 4 米 → 一跳只有 4 米（不许用固定 14 米越过真实视野）")

        far_sight = tactical([unit("Unit_4", "scout", (10, 10), sight=24.0)])
        long_hop = self._plan(far_sight, [[10.0, 10.0], [70.0, 10.0]])
        self.assertTrue(long_hop.ok, long_hop.reason)
        self.assertAlmostEqual(
            mv.point_distance([10.0, 10.0], long_hop.relay_point),
            min(24.0, mv.RELAY_MAX_HOP_M), places=3,
            msg="【B2 2026-10-11 口径】一跳上限 = 节奏上限 RELAY_MAX_HOP_M（24）："
                "视野 24 的 scout 单兵可走满 24；更远仍要靠友军视野链逐点覆盖")

    def test_dense_route_uses_the_full_radius_not_sparse_corners(self):
        """密集路径：一跳长度仍由**半径**决定，沿途拐点只是"路径在那里"，不是跳长上限。"""
        view = tactical([unit("Unit_4", "soldier", (10, 7))])
        plan = self._plan(view, [[10, 7], [20, 7], [40, 7], [60, 7]],
                          target=(60.0, 7.0))
        self.assertTrue(plan.ok, plan.reason)
        self.assertLess(plan.relay_point[0], 60.0, "不该一步走到终点")
        self.assertAlmostEqual(plan.relay_point[0], 10.0 + mv.RELAY_VISION_RADIUS_M,
                               places=1)

    def test_blind_gap_is_not_crossed(self):
        """路径上第一段就看不见 → 不许推进（`no_relay`），更不许跳过缺口到后面。"""
        view = tactical([unit("Unit_4", "soldier", (10, 7))])
        plan = self._plan(view, [[30.0, 30.0], [40.0, 40.0], [45.0, 45.0]],
                          target=(45.0, 45.0))
        self.assertFalse(plan.ok)
        self.assertEqual(plan.reason, mv.REJECT_NO_RELAY)
        self.assertEqual(plan.relay_point, [])

    def test_zero_displacement_relay_is_rejected(self):
        """单位已经站在中继点上 → `relay_too_close`，不发零位移推进命令。

        构造：权威路径从 (10,10) 起，单位已经走到 (11,10)（上一跳几乎走完），
        视野 4 米 → 下一条中继点只比当前位置远 ~3 米，但守卫要求"必须挪动 ≥ 0.5 米"，
        这里同时验证"守卫真的在算位移"，而不是永远返回 ok。
        """
        view = tactical([unit("Unit_4", "soldier", (11, 10), sight=4.0)])
        plan = self._plan(view, [[10.0, 10.0], [70.0, 10.0]], target=(70.0, 10.0))
        self.assertTrue(plan.ok, "路径起点仍在视野内，这一跳应该被批准：%s" % plan.reason)
        self.assertGreaterEqual(
            mv.point_distance([11.0, 10.0], plan.relay_point), mv.MIN_HOP_DISTANCE_M,
            "被批准的一跳必须真的挪动")

    def test_unit_already_at_or_past_the_path_start(self):
        """【B2 2026-10-11 口径】单位已过路径起点分两种：
        ① **仍能向前走一小步**（前缀在该单位自身视野内可继续）→ 允许签"位置在前方"的一跳；
        ② **已过起点远超一跳 / 起点已不可见** → 必须拦（`no_relay`/`relay_too_close`），
           不许静默 ok。两条都必须显式报原因。
        """
        view = tactical([unit("Unit_4", "soldier", (14, 10), sight=4.0)])
        state = self._state()
        plan = self._plan(view, [[10.0, 10.0], [70.0, 10.0]], target=(70.0, 10.0))
        self.assertTrue(plan.ok, plan.reason)
        self.assertGreater(plan.relay_point[0], 14.0,
                           "签出的中继点必须在单位**前方**（不是已走过的回程点）")
        self.assertTrue(state["map_bounds"], "state 未被改动（只读规划）")

        # ② 已过起点 30 米（远超一跳 24）且起点已不可见：必须拦。
        far = tactical([unit("Unit_4", "soldier", (40, 10), sight=4.0)])
        plan_far = self._plan(far, [[10.0, 10.0], [70.0, 10.0]], target=(70.0, 10.0))
        self.assertFalse(plan_far.ok, "已过起点远超一跳：不许再签")
        self.assertIn(plan_far.reason, (mv.REJECT_RELAY_TOO_CLOSE, mv.REJECT_NO_RELAY))
        self.assertEqual(plan_far.relay_point, [])

    def test_zero_displacement_is_counted_as_a_block(self):
        """调用层（闸门）把"没有可推进的下一段"记成显式原因，不再放行零位移命令。

        【B2 2026-10-11 构造更新】旧构造（单位在 (14,10)、路径 10→70）在新节奏上限下
        是**合法前向小步**（4m），不再属于"零位移"。真·零位移改由"单位已走过路径首点
        且首点已不可见"构造（与 `test_zero_displacement_relay_is_rejected` 同语义）。
        """
        from adjutant_coordinator.graph import nodes
        state = {"map_bounds": [200.0, 200.0], "server_tick": 600,
                 "ai_controlled_units": ["Unit_4"]}
        view = tactical([unit("Unit_4", "soldier", (18, 10), sight=4.0)])
        ctx = _ctx_with(nav_ok([[10.0, 10.0], [18.0, 10.0]]), view)
        kept, blocked = nodes._gate_movement(
            state, ctx, [_intent(["Unit_4"], (18.0, 10.0))])
        self.assertEqual(kept, [], "零位移推进不许出现在下发候选里")
        self.assertTrue(blocked, "必须留下可统计的拦下原因")
        reasons = [item["reason"] for item in blocked]
        self.assertTrue(
            any(mv.REJECT_RELAY_TOO_CLOSE in reason or mv.REJECT_NO_RELAY in reason
                for reason in reasons),
            "原因必须是 relay_too_close / no_relay 之一：%s" % reasons)

    def test_relay_must_not_jump_over_a_blind_gap_into_rear_ally_vision(self):
        """【2026-10-11 反例】可见集合是圆盘的**并集**，沿直线不一定单调。

        推进单位在 x=0（视野 4m），友军在 x=24（视野 4m）：x∈(4,20) 是盲区，
        但**端点 x=24 恰好可见**。旧实现对"最后一个可见采样点"做二分（依据是
        "前缀单调"这一错误假定），会直接跨到后方友军视野里返回 24 —— 主力于是
        穿过自己完全看不见的 16 米。现在只放行**第一个不可见点之前**的连续前缀。

        这条断言有区分力：132 条旧用例在修前全绿，因为它们要么单单位自视野
        （前缀确实单调），要么友军视野与起点连通。
        """
        by_name = mv._by_name(tactical([
            unit("mover", "soldier", (0, 0), sight=4.0),
            unit("ally", "soldier", (24, 0), sight=4.0),
        ]))
        relay = mv.safe_relay_point([[0.0, 0.0], [24.0, 0.0]], by_name,
                                    unit="mover", origin=[0.0, 0.0])
        self.assertTrue(relay, "起点自己看得见，应给出前缀内的中继点")
        self.assertLessEqual(relay[0], 4.0 + 1e-6,
                             "不许越过盲区：%r 跨进了后方友军视野" % (relay,))
        self.assertGreater(relay[0], 0.0, "仍是有效前向小步，不退化成零跳")

    def test_contiguous_vision_chain_still_allows_the_longer_hop(self):
        """盲区判据不能顺手把**真正连续**的视野链也砍短：友军一格一格接得上时，
        一跳仍应走到节奏上限（`RELAY_MAX_HOP_M`），这是 B2 放宽 24m 的目的。
        """
        entities = [unit("mover", "soldier", (0, 0), sight=4.0)]
        for x in (4, 8, 12, 16, 20, 24):
            entities.append(unit("ally_%d" % x, "soldier", (x, 0), sight=4.0))
        relay = mv.safe_relay_point([[0.0, 0.0], [40.0, 0.0]],
                                    mv._by_name(tactical(entities)),
                                    unit="mover", origin=[0.0, 0.0])
        self.assertTrue(relay)
        self.assertAlmostEqual(relay[0], mv.RELAY_MAX_HOP_M, delta=1.0)


class MilitaryTrackLoopControlTest(unittest.TestCase):
    """一个单位算不出航点，**不许**把整条军事轨剩下的单位一起饿掉。

    `_parallel_intents` 的军事轨原来写的是：

    ```python
    point = military_waypoint(...)
    if not point:
        break          # ← 终止整条轨，把它之后的**所有**作战单位一起跳过
    ```

    `military_waypoint` 在 `not base or len(base) < 2` 时返回空，而调用处传的是
    `origin or base`（`origin` 可能为 `None`）⇒ 它确实会返回空。
    一个单位的异常不该让整条轨停摆 —— 这是"有的兵在动、有的兵一直不动"的一个直接机制。
    """

    def _view(self):
        return {
            "entities": [
                unit("Unit_0", "command_center", (8, 7), movement=False, queue=True),
                unit("Unit_1", "drone", (12, 8)),
                unit("Unit_2", "soldier", (10, 7)),
                unit("Unit_3", "soldier", (11, 7)),
                unit("Unit_4", "soldier", (12, 7)),
            ],
            "balance": {"A": 50000},
        }

    def _state(self):
        return {"map_bounds": [50.0, 50.0], "server_tick": 600, "snapshot_id": 1,
                # `nav_revision` 必须是**标量**才是合法形状：`parse_nav_revision`
                # 对 dict/list 一律返回 -1（实测探针），于是 `hop_in_progress` 永远为假、
                # "在路上"根本判不出来 —— 测试里设错形状会静默地测不到东西。
                "nav_revision": 1,
                "routes": {}, "movement_stats": {}, "active_intents": [],
                "active_tasks": [], "combat_types": ["soldier"],
                "ai_controlled_units": ["Unit_0", "Unit_1", "Unit_2", "Unit_3",
                                        "Unit_4"],
                "enemy_intel_points": [[40.0, 40.0]]}

    def test_a_unit_without_a_waypoint_does_not_starve_the_rest(self):
        from adjutant_coordinator.graph import rules_fallback as rf
        state = self._state()
        view = self._view()
        real = rf.military_waypoint

        def fake(origin, **kwargs):
            if str(kwargs.get("unit", "")) == "Unit_2":
                return None            # 只有中间这个单位算不出航点
            return real(origin, **kwargs)

        with mock.patch.object(rf, "military_waypoint", fake):
            out = rf._parallel_intents(state, tactical=view, primary=[],
                                       ttl_ticks=3600, server_tick=600, snapshot_id=1)
        units_with_intents = {str(u) for item in out
                              for u in (item.get("unit_ids") or [])}
        self.assertIn("Unit_3", units_with_intents,
                      "排在『算不出航点』那个单位**之后**的作战单位必须照样拿到意图"
                      "（旧实现 `break` 会把它们一起饿掉）")
        skipped = {(str(item.get("unit")), str(item.get("reason")))
                   for item in (state.get("decision_log") or [])
                   if str(item.get("kind")) == "advance_skipped"}
        self.assertIn(("Unit_2", "no_waypoint"), skipped,
                      "算不出航点要逐条留痕（计数会被 `movement_stats` 视图掩盖）")
        self.assertTrue(any(reason in ("busy", "used", "suspended", "not_combat")
                            for _unit, reason in skipped),
                        "其它出口（名额/占用/类型）也要留痕并带原因：%s" % sorted(skipped))

    def test_en_route_veto_is_counted(self):
        """`_en_route` 否决是"通往新命令的唯一道路"，必须可计数（否则只能靠推理）。"""
        from adjutant_coordinator.graph import rules_fallback as rf
        from adjutant_coordinator.graph import movement as mv
        state = self._state()
        view = self._view()
        mv.record_route(state, mv.RoutePlan(
            unit="Unit_2", ok=True, relay_point=[14.0, 7.0], target=[30.0, 7.0],
            nav_revision=1, last_replan_tick=600, route_id="r-1"))
        out = rf._parallel_intents(state, tactical=view, primary=[],
                                   ttl_ticks=3600, server_tick=600, snapshot_id=1)
        units_with_intents = {str(u) for item in out
                              for u in (item.get("unit_ids") or [])}
        self.assertNotIn("Unit_2", units_with_intents, "在路上的单位不该被改令")
        skipped = [item for item in state.get("decision_log") or []
                   if str(item.get("kind")) == "advance_skipped"]
        self.assertTrue(any(str(item.get("unit")) == "Unit_2"
                            and str(item.get("reason")) == "en_route"
                            for item in skipped),
                        "被 `_en_route` 否决要逐条留痕（否则只能靠推理）")


def rf_arrival_override_enabled() -> bool:
    """`rules_fallback.ARRIVAL_BUSY_OVERRIDE` 的只读探针（供 skipUnless 用）。

    为什么要有它：round-29 追出的竞态是真的（到达被处理 → 同轮又新建意图 →
    下轮重新算 `busy` → 被挡到 30.07 秒），实现也已就位，
    但第一版**把对局打挂了两次**（日志载荷里的 `⇒` 在 GBK 控制台 print 不了），
    `run_health` 两次都判"不可用" ⇒ **没有可采信的读数**。
    按 prompt §4（未验证的不算成果）本轮先关闭候选；
    测试跟着开关走，**不把"未启用"伪装成"通过"**。
    """
    from adjutant_coordinator.graph import rules_fallback as rf
    return bool(getattr(rf, "ARRIVAL_BUSY_OVERRIDE", False))


class ArrivalPriorityServiceTest(unittest.TestCase):
    """**刚到达的单位要排到前面**（prompt §3-C 原文的"arrival 触发下一段优先服务"）。

    依据（round-26 实测）：
      - 接续 p95 = 4.68 秒，而"等到下一决策轮"的 p95 只有 1.45 秒
        ⇒ 单位平均**多等 2~3 轮**才被服务到（排队，不是不能动）；
      - 40.1% 的接续落在 1~5 秒、全是战斗单位；只有 4.4% 超过 5 秒
        ⇒ **要动的不是尾巴**，是"多等的那 1~4 轮"。

    做法：`node_ingest` 到达时写 `state["unit_arrival_tick"]`，
    军事轨把它作**主排序键**（降序 = 最近到达的在前）。
    """

    def _view(self, count: int):
        entities = [unit("Unit_0", "command_center", (8, 7), movement=False, queue=True),
                    unit("Unit_1", "drone", (12, 8))]
        for index in range(count):
            entities.append(unit("Unit_%d" % (index + 10), "soldier", (10 + index, 7)))
        return {"entities": entities, "balance": {"A": 50000}}

    def _state(self, count: int, arrivals=None):
        names = ["Unit_0", "Unit_1"] + ["Unit_%d" % (index + 10)
                                        for index in range(count)]
        return {"map_bounds": [50.0, 50.0], "server_tick": 600, "snapshot_id": 1,
                "nav_revision": 1, "routes": {}, "movement_stats": {},
                "active_intents": [], "active_tasks": [],
                "combat_types": ["soldier"], "ai_controlled_units": names,
                "unit_arrival_tick": dict(arrivals or {}),
                "enemy_intel_points": [[40.0, 40.0]]}

    def test_recently_arrived_units_are_served_first(self):
        """最近到达的单位要出现在输出**前部**（每轮上限之下，靠后就是没被服务）。"""
        from adjutant_coordinator.graph import rules_fallback as rf
        count = 24                       # 远超每轮上限，位置差别才有意义
        # 只有字母序**最后**两个单位有到达记录 —— 固定顺序下它们永远排在最后
        state = self._state(count, arrivals={"Unit_32": 599, "Unit_33": 580})
        view = self._view(count)
        out = rf._parallel_intents(state, tactical=view, primary=[],
                                   ttl_ticks=3600, server_tick=600, snapshot_id=1)
        served = [str(name) for item in out
                  if str(item.get("intent_id", "")).startswith("rule-fill-advance")
                  for name in (item.get("unit_ids") or [])]
        self.assertIn("Unit_33", served,
                      "刚到达的单位必须被优先服务（否则它要再等 2~3 轮）")
        self.assertIn("Unit_32", served, "到达更晚的排在更前面，也应被服务")
        # 到达更晚的应当排在到达更早的之前
        self.assertLess(served.index("Unit_32"), served.index("Unit_33"),
                        "排序键必须按到达时刻**降序**（越近越靠前）")

    def test_recently_arrived_unit_can_override_busy(self):
        """**刚到达且不在途**的单位要被放行（第一道闸 `busy`）。

        ⚠ 本测试**只钉到"放行"这一层**，不钉"最终产出推进意图" —— 因为
        round-31 用逐出口追踪（`AIRTS_ADVANCE_TRACE`）查出：**有的单位根本
        没进入军事轨的循环**（追踪里 `enter` 从 index=1 开始，**index=0 缺失**），
        与 `busy` 这道闸无关。那是另一个（更靠前的）缺口，见 C-112。

        ⚠ 另记一个测试自身的坑（round-30 误判的根源）：
        **不能在同一个 state 上把 `_parallel_intents` 调两次** —— 它会推进
        `advance_cursor`（轮转游标），第二次调用换了起点，结论就变了。
        """
        from adjutant_coordinator.graph import rules_fallback as rf
        count = 6
        state = self._state(count)
        state["server_tick"] = 600
        state["active_intents"] = [
            {"intent_id": "rule-fill-advance-Unit_%d-500" % (i + 10), "state": "active",
             "action": "attack_move", "unit_ids": ["Unit_%d" % (i + 10)]}
            for i in range(count)]
        state["unit_arrival_tick"] = {"Unit_12": 500}
        rf._parallel_intents(state, tactical=self._view(count), primary=[],
                             ttl_ticks=3600, server_tick=600, snapshot_id=1)
        self.assertEqual(
            state["movement_stats"].get("advance_busy_overridden"), 1,
            "刚到达且不在途的单位必须被放行（否则被新意图挡到 TTL）")

    def test_stale_arrival_does_not_override_busy(self):
        """**早就到达**的单位不许绕过 `busy` —— 这条纪律不能被改动的窗口废掉。"""
        from adjutant_coordinator.graph import rules_fallback as rf
        count = 6
        view = self._view(count)
        state = self._state(count)
        state["server_tick"] = 600
        state["active_intents"] = [
            {"intent_id": "rule-fill-advance-Unit_%d-500" % (i + 10), "state": "active",
             "action": "attack_move", "unit_ids": ["Unit_%d" % (i + 10)]}
            for i in range(count)]
        # 到达发生在 5000 tick 之前 ⇒ 远超窗口
        state["unit_arrival_tick"] = {"Unit_12": -4400}
        out = rf._parallel_intents(state, tactical=view, primary=[],
                                   ttl_ticks=3600, server_tick=600, snapshot_id=1)
        served = {str(n) for item in out
                  if str(item.get("intent_id", "")).startswith("rule-fill-advance")
                  for n in (item.get("unit_ids") or [])}
        self.assertNotIn("Unit_12", served,
                         "久远到达的单位仍须遵守 busy 纪律（窗口必须有限）")

    def test_combat_track_reserve_stays_reverted(self):
        """作战轨**不许**自行加保底名额 —— round-37 试过，实测更差，round-38 已撤销。

        ## 为什么这条要写成"防回退"测试

        机制不对称看起来很像疏漏：**侦察轨早有 `scout_reserve = 1`**（经济轨/建造轨用
        `_room(reserve=scout_reserve)` 给它让位），而作战轨用裸 `_room()`。
        round-37 我据此把同一模式对称地用到作战轨 —— **实测反而更差**：

        | 口径 | 对照 `81893e7b` | 无保底 `ab487d43` | **有保底 `9d887277`** |
        |---|---|---|---|
        | `advance_batch_full` 轮次占比 | 82.4% | 83.1% | **87.1%** |
        | 军事意图/轮（`skipped`+`emitted`） | 10.45 | **19.79** | **16.39** |
        | `emitted` 合计 | 1048 | **1304** | **1127** |

        根因：`PARALLEL_FILL_CAP = 8` 是**硬上限**，`emitted` 分布从 `{8:131}`
        变成 `{7:137, 8:21}` —— 保底只是"把一格从别的轨挪给军事轨"，
        总量不变，而军事轨的 `_room` 反而**更早**为假。
        ⇒ **硬上限下保底 = 零和搬运（此处净损）。**

        本测试防止后来者（或我自己）看到那个"不对称"又把保底加回去。
        """
        from adjutant_coordinator.graph import rules_fallback as rf
        import inspect
        src = inspect.getsource(rf._parallel_intents)
        # ⚠ 只在**代码行**里找，不在注释里找 —— 撤销说明的注释里合法地提到了这个字符串
        # （round-38 第一版断言踩过：它被注释里的说明文字误判成"代码又加回来了"）。
        code_lines = [line.split("#", 1)[0] for line in src.splitlines()]
        code = "\n".join(code_lines)
        self.assertNotIn(
            "_room(reserve=military_reserve)", code,
            "作战轨的保底名额已在 round-38 撤销（实测更差）；"
            "重新加回前必须先读军事轨循环处的实测对照表")
        # 侦察轨的保底必须保留（它是既有设计，不在本次撤销范围）
        self.assertIn("_room(reserve=scout_reserve)", code,
                      "侦察轨的保底是既有设计，不许被这次撤销连带删掉")

    def test_without_arrivals_it_still_rotates(self):
        """没有到达记录时行为不变（仍按轮转游标）—— 优先层不能破坏原有轮转。"""
        from adjutant_coordinator.graph import rules_fallback as rf
        count = 24
        state = self._state(count)
        view = self._view(count)
        out = rf._parallel_intents(state, tactical=view, primary=[],
                                   ttl_ticks=3600, server_tick=600, snapshot_id=1)
        self.assertTrue(state.get("advance_cursor") is not None,
                        "没有到达记录时游标仍要推进（轮转不能被优先层吃掉）")
        self.assertTrue(any(str(item.get("intent_id", "")).startswith("rule-fill-advance")
                            for item in out))


class AdvanceRotationFairnessTest(unittest.TestCase):
    """军事轨的服务顺序必须**轮转**，否则靠后的单位会被周期性饿（2026-10-09）。

    `ai_units` 是 `nodes.py` 里 `sorted(...)` 出来的**固定字母序**，而本轨每轮有产出上限
    （`PARALLEL_FILL_CAP = 8`）。两者叠加 ⇒ 靠前的单位每轮先被服务、靠后的**每次都被截断**。

    实测（`archive_9e5627fe`，`rotation_fairness.py`）：推进意图在列表里的
    **平均排名跨度 0.0 → 16.7**（完全没有轮转），而**排在最后的正是停最久的**
    （`Unit_41` 16.2 / `Unit_36` 11.5 / `Unit_37` 12.4）。真停滞样本的恢复时刻还**成簇**、
    同一簇内"到达越早停得越久"—— 正是排队的形状。
    """

    def _view(self, count: int):
        entities = [unit("Unit_0", "command_center", (8, 7), movement=False, queue=True),
                    unit("Unit_1", "drone", (12, 8))]
        for index in range(count):
            entities.append(unit("Unit_%d" % (index + 10), "soldier",
                                 (10 + index, 7)))
        return {"entities": entities, "balance": {"A": 50000}}

    def _state(self, count: int):
        names = ["Unit_0", "Unit_1"] + ["Unit_%d" % (index + 10)
                                        for index in range(count)]
        return {"map_bounds": [50.0, 50.0], "server_tick": 600, "snapshot_id": 1,
                "nav_revision": 1, "routes": {}, "movement_stats": {},
                "active_intents": [], "active_tasks": [],
                "combat_types": ["soldier"], "ai_controlled_units": names,
                "enemy_intel_points": [[40.0, 40.0]]}

    def _advance_units(self, state, view):
        """只取**军事轨的前压**意图（`rule-fill-advance`）。

        注意不能用"所有意图里的单位"：无人机走的是**侦察轨**（`rule-fill-scout`），
        它出现在输出里是**对的** —— 第一版断言因此误报（把侦察轨的产物当成军事轨的）。
        """
        from adjutant_coordinator.graph import rules_fallback as rf
        out = rf._parallel_intents(state, tactical=view, primary=[],
                                   ttl_ticks=3600, server_tick=600, snapshot_id=1)
        found = set()
        for item in out:
            if not str(item.get("intent_id", "")).startswith("rule-fill-advance"):
                continue
            for name in (item.get("unit_ids") or []):
                found.add(str(name))
        return found

    def test_cursor_advances_so_the_tail_gets_a_turn(self):
        """连续多轮里，**排最后的单位**必须至少有一次进入被服务的头部。

        旧实现（固定顺序）下，`Unit_1x` 里字母序最大的那几个**永远**排在
        `PARALLEL_FILL_CAP` 之后 ⇒ 每轮都被截断。
        """
        count = 24                      # 远超每轮上限，必然有单位被截断
        state = self._state(count)
        view = self._view(count)
        served_first_round = self._advance_units(state, view)
        self.assertTrue(state.get("advance_cursor"), "轮转游标必须被持久化（否则没有轮转）")
        # 游标前移 ⇒ 下一轮的起点不同 ⇒ 服务的头部集合会变化
        cursor_after_first = state["advance_cursor"]
        for tick in range(601, 620):
            state["server_tick"] = tick
            self._advance_units(state, view)
        self.assertNotEqual(state["advance_cursor"], cursor_after_first,
                            "游标必须在每轮推进")
        # 逐轮累积：被服务过的单位应当覆盖**全部**作战单位（轮转的直接效果）
        state2 = self._state(count)
        view2 = self._view(count)
        seen = set()
        for tick in range(600, 900):
            state2["server_tick"] = tick
            seen |= self._advance_units(state2, view2)
        expected = {"Unit_%d" % (index + 10) for index in range(count)}
        missing = expected - seen
        self.assertFalse(missing,
                         "轮转之后每个作战单位都该轮到过；仍然没被服务的是 %s"
                         % sorted(missing))

    def test_rotation_does_not_change_filters(self):
        """轮转只改**顺序**，不许改变"谁合格" —— 无人机的类型判定不受影响。"""
        count = 6
        state = self._state(count)
        view = self._view(count)
        served = self._advance_units(state, view)
        self.assertNotIn("Unit_1", served, "无人机不是作战单位，不许被军事轨推进")


class ArrivedHopNotInProgressTest(unittest.TestCase):
    """**到达过的跳不许再算"在路上"**（2026-10-09，C2 门禁 32 秒尾巴的根因）。

    `note_arrival` 把路线标成 `ok=False` + `arrived_tick=<到达时刻>`，这是"这一跳结束了"的
    唯一信号。但 `record_route` 原来**整条替换** `routes[unit]`：同一目标被重新规划一次，
    `arrived_tick` 就被清成 0、`ok` 被写回 `True` ⇒ `unit_en_route` 又为真 ⇒
    `rules_fallback._parallel_intents` 里 `if _en_route(name): continue` **每轮跳过它** ⇒
    直到 `HOP_HOLD_MAX_TICKS`(1800 tick ≈ 30 秒) 的第二道保险才放行。

    实测（`archive_aa061295`，round-10）：654 条到达里 **652 条**都正常调用了 `note_arrival`，
    所以被抹掉的是**记号**而不是"到达没记账"；门禁 p95 长期钉在 31.8~33.1 秒
    （≈30 秒保险 + 一轮）与之吻合。
    """

    def _state(self):
        return {"server_tick": 0, "routes": {}, "movement_stats": {},
                "active_intents": [], "active_tasks": []}

    def _plan(self, tick, target=(30.0, 7.0), relay=(14.0, 7.0)):
        return mv.RoutePlan(unit="Unit_9", ok=True, relay_point=list(relay),
                            target=list(target), nav_revision=1,
                            last_replan_tick=tick, route_id="r-%d" % tick)

    def test_replan_to_the_same_target_keeps_the_arrived_marker(self):
        state = self._state()
        mv.record_route(state, self._plan(100))
        self.assertTrue(mv.hop_in_progress(state, "Unit_9", 1, 110),
                        "刚规划的一跳当然算在途")
        mv.note_arrival(state, "Unit_9", 200)
        self.assertFalse(mv.hop_in_progress(state, "Unit_9", 1, 210),
                         "到达之后不算在途")
        mv.record_route(state, self._plan(300))
        entry = state["routes"]["Unit_9"]
        self.assertEqual(entry.get("arrived_tick"), 200,
                         "同一目标的重规划必须保留 arrived_tick"
                         "（否则这一跳看起来又在途）")
        self.assertFalse(entry.get("ok"), "已到达的跳不许被写回可复用")
        self.assertFalse(mv.hop_in_progress(state, "Unit_9", 1, 310),
                         "**到达之后**，同一目标的重规划不许把它变回'在路上'"
                         "（否则规则地板会每轮跳过它直到 30 秒保险）")
        self.assertGreaterEqual(state["movement_stats"].get("arrival_marker_kept", 0), 1,
                                "保留记号这件事要可计数（验收要能读）")

    def test_replan_to_a_new_target_starts_a_fresh_hop(self):
        """真·下一跳（换了目标）必须照旧算在途，不能被上面的保护误伤。"""
        state = self._state()
        mv.record_route(state, self._plan(100))
        mv.note_arrival(state, "Unit_9", 200)
        mv.record_route(state, self._plan(300, target=(80.0, 40.0), relay=(24.0, 14.0)))
        entry = state["routes"]["Unit_9"]
        self.assertEqual(int(entry.get("arrived_tick", 0) or 0), 0,
                         "换目标 = 新的一跳，不该继承上一跳的到达记号")
        self.assertTrue(entry.get("ok"))
        self.assertTrue(mv.hop_in_progress(state, "Unit_9", 1, 310))

    def test_stale_arrived_route_still_expires(self):
        """记号保留不等于永久在途：换网格版本仍要能重新规划。"""
        state = self._state()
        mv.record_route(state, self._plan(100))
        mv.note_arrival(state, "Unit_9", 200)
        mv.record_route(state, self._plan(300))
        self.assertFalse(mv.hop_in_progress(state, "Unit_9", 2, 310),
                         "网格换版本 → 旧路作废")


class GateInArbitrationTest(unittest.TestCase):
    """闸门挂在**仲裁前**（通往下发的唯一咽喉）：能改写目标、能摘掉意图、能计数。

    这是"没有有效路径的主力移动数为 0"的**结构性**保证：不靠事后统计发现，
    而是让未经验证的移动意图根本没有办法走到下发。
    """

    def _ctx(self, nav_query, tactical):
        from adjutant_coordinator.graph.nodes import GraphConfig, GraphServices, NodeContext
        services = GraphServices(config=GraphConfig(), nav_query=nav_query)
        return NodeContext(services=services,
                           observation={"tactical": tactical, "rules": {}}, tick=600)

    def _state(self, **extra):
        state = {"map_bounds": [50.0, 50.0], "server_tick": 600,
                 "ai_controlled_units": ["Unit_4"]}
        state.update(extra)
        return state

    def _intent(self, action="attack_move", pos=(30.0, 7.0)):
        return {"intent_id": "rule-fill-advance-Unit_4-600", "action": action,
                "unit_ids": ["Unit_4"], "target": {"pos": list(pos)},
                "priority": 3, "issued_tick": 600, "expires_tick": 1200}

    def test_target_is_rewritten_to_the_safe_relay(self):
        from adjutant_coordinator.graph import nodes
        candidate = self._intent(pos=(30.0, 7.0))
        kept, blocked = nodes._gate_movement(
            self._state(), self._ctx(nav_ok([[10, 7], [14, 7], [18, 7], [30, 7]]),
                                     tactical([unit("Unit_4", "soldier", (10, 7))])),
            [candidate])
        self.assertEqual(blocked, [])
        self.assertEqual(len(kept), 1)
        self.assertLess(kept[0]["target"]["pos"][0], 30.0,
                        "目标必须被改写成中继点（一跳），不是原始终点")

    def test_intent_is_dropped_when_there_is_no_path(self):
        from adjutant_coordinator.graph import nodes
        candidate = self._intent()
        kept, blocked = nodes._gate_movement(
            self._state(), self._ctx(nav_fail(), tactical([unit("Unit_4", "soldier", (10, 7))])),
            [candidate])
        self.assertEqual(kept, [], "没有权威路径 → 不许移动")
        self.assertEqual(blocked[0]["reason"], "movement_gated:%s" % mv.REJECT_NO_PATH)

    def test_worker_move_is_gated_even_with_a_valid_path(self):
        from adjutant_coordinator.graph import nodes
        candidate = self._intent()
        candidate["unit_ids"] = ["Unit_1"]
        state = self._state(ai_controlled_units=["Unit_1"])
        kept, blocked = nodes._gate_movement(
            state, self._ctx(nav_ok([[10, 7], [14, 7]]),
                             tactical([unit("Unit_1", "worker", (10, 7))])),
            [candidate])
        self.assertEqual(kept, [])
        self.assertEqual(blocked[0]["reason"],
                         "movement_gated:%s" % mv.REJECT_PROTECTED_UNIT)

    def test_ungated_is_counted_when_host_did_not_wire_nav_query(self):
        """宿主没接权威寻路时：**不假装通过**，而是显式计数（验收要看得见）。"""
        from adjutant_coordinator.graph import nodes
        state = self._state()
        kept, _blocked = nodes._gate_movement(
            state, self._ctx(None, tactical([unit("Unit_4", "soldier", (10, 7))])),
            [self._intent()])
        self.assertEqual(len(kept), 1, "没接寻路时不硬拦（离线回放要保持原语义）")
        self.assertEqual(state["movement_stats"]["ungated"], 1,
                         "未经闸门的移动必须计数，不能静默放行")

    def test_urgent_event_is_recorded_on_threat(self):
        from adjutant_coordinator.graph import nodes
        state = self._state()
        nodes._gate_movement(
            state,
            self._ctx(nav_ok([[10, 7], [14, 7]]),
                      tactical([unit("Unit_4", "soldier", (10, 7)),
                                enemy("Enemy_1", (14, 7))])),
            [self._intent(pos=(20.0, 7.0))])
        self.assertEqual([item["kind"] for item in state["movement_urgent"]],
                         ["enemy_on_route"])


class HopHoldTest(unittest.TestCase):
    """**在路上的不许换目标**（2026-09-13 用户实测原话：
    "你下达命令不能瞎下达啊，部队还没到位，你就下达下一个命令了，这部队怎么跟得过来啊"）。

    根因链：每个决策轮都用**新算出来的**前压点当目标 → `needs_replan()` 判"目标变了"
    → 中继点每轮都变 → 单位在路上被反复改方向（表现：原地打转、队伍拉散、永远走不到）。
    纪律：**到位再下一条**（到达由观测确认 → 作废路线 → 下一轮才规划下一跳）。
    """

    def _state(self, *, ok=True, last_replan=590, nav_revision=1, invalidated="",
               relay=(14.0, 7.0)):
        route = {"ok": bool(ok), "route_id": "route-1", "nav_revision": nav_revision,
                 "last_replan_tick": last_replan, "target": [20.0, 7.0],
                 "relay_point": [float(relay[0]), float(relay[1])]}
        if invalidated:
            route["ok"] = False
            route["invalidated_reason"] = invalidated
        return {"map_bounds": [50.0, 50.0], "server_tick": 600,
                "nav_revision": nav_revision, "ai_controlled_units": ["Unit_4"],
                "routes": {"Unit_4": route}}

    def _view(self):
        return tactical([unit("Unit_4", "soldier", (10, 7))])

    def _query(self, calls):
        def query(unit_name, target):
            calls.append([float(target[0]), float(target[1])])
            return {"ok": True, "reachable": True, "nav_revision": 1,
                    "waypoints": [[10, 7], [16, 7], [30, 7]], "route_length": 20.0,
                    "end_clamped": False, "start_clamped": False}
        return query

    def _advance(self, pos=(30.0, 7.0), unit="Unit_4"):
        return {"intent_id": "rule-fill-advance-%s-600" % unit, "action": "attack_move",
                "unit_ids": [unit], "target": {"pos": list(pos)},
                "priority": 3, "issued_tick": 600, "expires_tick": 1200}

    def test_mid_route_target_change_keeps_the_current_hop(self):
        """**半路想换目标 → 先走完当前这一跳**（不查新路径、不下新令）。"""
        from adjutant_coordinator.graph import nodes
        state = self._state()
        calls = []
        kept, blocked = nodes._gate_movement(
            state, _ctx_with(self._query(calls), self._view()), [self._advance()])
        self.assertEqual(blocked, [], "在路上不是拒绝，是**等它到位**")
        self.assertEqual(calls, [], "半路不许再查路径（省查询，也不换中继点）")
        self.assertEqual(kept, [], "旧令还在执行：再发一条只会半路改令")
        self.assertEqual(state["movement_stats"]["hop_holds"], 1,
                         "被压下来的新目标必须记账（否则回头查不出『为什么不理我』）")
        self.assertEqual(state["movement_stats"]["hop_reuse_dropped"], 1)

    def test_same_destination_is_not_counted_as_a_hold(self):
        """新目标就是这个中继点（本来就在往那走）→ 不算"半路改目标"，也不再发令。"""
        from adjutant_coordinator.graph import nodes
        state = self._state()
        calls = []
        kept, _blocked = nodes._gate_movement(
            state, _ctx_with(self._query(calls), self._view()),
            [self._advance(pos=(14.0, 7.0))])
        self.assertEqual(kept, [], "已经在走这一跳：不要再下同一条")
        self.assertNotIn("hop_holds", state.get("movement_stats") or {})
        self.assertEqual(state["movement_stats"]["hop_reuse_dropped"], 1)

    def test_arrival_unlocks_the_next_hop(self):
        """**到位之后照常规划下一跳**（到达由观测确认 → 路线作废 → 允许换目标）。"""
        from adjutant_coordinator.graph import nodes
        state = self._state(ok=False, invalidated="arrived")
        calls = []
        kept, blocked = nodes._gate_movement(
            state, _ctx_with(self._query(calls), self._view()), [self._advance()])
        self.assertEqual(blocked, [])
        self.assertEqual(len(calls), 1, "到位了就该重新规划（这正是『下一条命令』的时机）")
        self.assertNotEqual(kept[0]["target"]["pos"], [14.0, 7.0],
                            "新一跳的目标必须来自新的规划，不是旧中继点")

    def test_path_failed_unlocks_the_next_hop(self):
        """路径失败作废后 → 允许换目标（不能拿"在路上"当借口卡住求救）。"""
        from adjutant_coordinator.graph import nodes
        state = self._state(ok=False, invalidated="path_failed")
        calls = []
        nodes._gate_movement(state, _ctx_with(self._query(calls), self._view()),
                             [self._advance()])
        self.assertEqual(len(calls), 1)

    def test_stale_hop_must_be_replanned(self):
        """一条跳老过 `HOP_HOLD_MAX_TICKS` → 必须重规划（防"卡在陈旧路线上永远不动"）。"""
        from adjutant_coordinator.graph import nodes
        state = self._state(last_replan=600 - mv.HOP_HOLD_MAX_TICKS - 1)
        calls = []
        nodes._gate_movement(state, _ctx_with(self._query(calls), self._view()),
                             [self._advance()])
        self.assertEqual(len(calls), 1, "超时的跳不许无限复用")

    def test_nav_revision_change_unlocks_the_next_hop(self):
        """网格换版本（重烘完了）→ 允许重新规划（旧路已作废）。"""
        from adjutant_coordinator.graph import nodes
        state = self._state(nav_revision=1)
        state["nav_revision"] = 2
        calls = []
        nodes._gate_movement(state, _ctx_with(self._query(calls), self._view()),
                             [self._advance()])
        self.assertEqual(len(calls), 1)

    def _fill_view(self, state):
        """基地锚点 + 专职无人机：士兵不会被转交侦察，前压也才有合法圆心。"""
        state["combat_types"] = ["soldier"]
        state["ai_controlled_units"] = ["Unit_0", "Unit_1", "Unit_4"]
        state["enemy_intel_points"] = [[40.0, 40.0]]
        return {
            "entities": [
                unit("Unit_0", "command_center", (8, 7), movement=False, queue=True),
                unit("Unit_1", "drone", (12, 8)),
                unit("Unit_4", "soldier", (10, 7)),
            ],
            "balance": {"A": 50000},
        }

    def test_parallel_fill_does_not_reissue_advance_while_en_route(self):
        """并行填充不得用新 tick id 再发一条前压（`u4dev` 100 条重复的根因）。"""
        from adjutant_coordinator.graph import rules_fallback as rf
        state = self._state()
        view = self._fill_view(state)
        out = rf._parallel_intents(state, tactical=view, primary=[],
                                   ttl_ticks=3600, server_tick=600, snapshot_id=1)
        advances = [item for item in out
                    if str(item.get("intent_id", "")).startswith("rule-fill-advance")]
        self.assertEqual(advances, [], "在路上再发前压就是半路改令：%s" % advances)

    def test_parallel_fill_advances_after_arrival(self):
        """到达作废路线之后，填充必须能发下一跳（区分『半路不发』和『到了也不发』）。"""
        from adjutant_coordinator.graph import rules_fallback as rf
        state = self._state(ok=False, invalidated="arrived")
        view = self._fill_view(state)
        out = rf._parallel_intents(state, tactical=view, primary=[],
                                   ttl_ticks=3600, server_tick=600, snapshot_id=1)
        advances = [item for item in out
                    if str(item.get("intent_id", "")).startswith("rule-fill-advance")]
        self.assertTrue(advances, "到位后必须能发下一跳，否则部队会停在中继点")


class SameUnitCommandConflictTest(unittest.TestCase):
    """**一个单位一轮只许一条"去哪/停哪"的命令**（2026-09-13 用户实测：
    "你下达命令不能瞎下达啊，部队还没到位，你就下达下一个命令了"）。

    实测现场（真机档案 `archive_045ed0d6`）：同一 tick 里 Unit_23 同时收到
    `fallback-hold-Unit_23-7`（→ stop）与 `bt-retreat-Unit_23-2249`（→ move），
    **两条都 Accepted** → 单位"停一下又走"。该局这样的组共 32 个。
    成因：阶梯/并行填充/行为树/受阻降级是四条独立发令路，没人按单位去重。
    """

    def _state(self):
        return {"server_tick": 2249, "ai_controlled_units": ["Unit_23", "Unit_35"]}

    def _intent(self, intent_id, action, unit, pos=(20.0, 7.0)):
        return {"intent_id": intent_id, "action": action, "unit_ids": [unit],
                "target": {"pos": list(pos)}, "priority": 3, "issued_tick": 2249,
                "expires_tick": 5849}

    def test_hold_and_retreat_on_one_unit_keep_the_retreat(self):
        """守卫（rank 10）与撤退（rank 90）撞车 → 留撤退；被压下的要记账。"""
        from adjutant_coordinator.graph import nodes
        state = self._state()
        hold = self._intent("fallback-hold-Unit_23-7", "hold", "Unit_23")
        retreat = self._intent("bt-retreat-Unit_23-2249", "retreat", "Unit_23",
                               pos=(5.0, 5.0))
        kept, dropped = nodes._resolve_same_unit_conflicts(state, [hold, retreat], 2249)
        self.assertEqual([item["intent_id"] for item in kept],
                         ["bt-retreat-Unit_23-2249"], "求生优先（rank 90 > 10）")
        self.assertEqual(len(dropped), 1)
        self.assertEqual(dropped[0]["reason"], "same_unit_conflict")
        self.assertEqual(state["movement_stats"]["same_unit_conflicts"], 1)
        decisions = [item for item in state["decision_log"]
                     if item.get("kind") == "same_unit_conflict"]
        self.assertTrue(decisions, "被压下的命令必须留痕（否则查不出为什么没发）")

    def test_different_units_do_not_conflict(self):
        from adjutant_coordinator.graph import nodes
        state = self._state()
        first = self._intent("rule-fill-advance-Unit_23-2249", "attack_move", "Unit_23")
        second = self._intent("rule-fill-advance-Unit_35-2249", "attack_move", "Unit_35")
        kept, dropped = nodes._resolve_same_unit_conflicts(state, [first, second], 2249)
        self.assertEqual(len(kept), 2, "不同单位互不影响")
        self.assertEqual(dropped, [])
        self.assertNotIn("same_unit_conflicts", state.get("movement_stats") or {})

    def test_attack_beats_hold_for_the_same_unit(self):
        """同单位 `attack`(70) vs `hold`(10) → 留攻击（攻击已经过安全闸门与校验）。"""
        from adjutant_coordinator.graph import nodes
        state = self._state()
        attack = self._intent("rule-attack-Unit_23-2249", "attack", "Unit_23")
        hold = self._intent("fallback-hold-Unit_23-2249", "hold", "Unit_23")
        kept, _dropped = nodes._resolve_same_unit_conflicts(state, [attack, hold], 2249)
        self.assertEqual([item["intent_id"] for item in kept],
                         ["rule-attack-Unit_23-2249"])

    def test_squad_intent_yields_whole_when_a_member_is_claimed(self):
        """小队里**有人**已被更高 rank 占住 → 整条小队意图让位（不"半队出发"）。"""
        from adjutant_coordinator.graph import nodes
        state = self._state()
        retreat = self._intent("bt-retreat-Unit_23-2249", "retreat", "Unit_23")
        squad = {"intent_id": "rule-attack-squad-2249", "action": "attack",
                 "unit_ids": ["Unit_23", "Unit_35"], "target": {"entity_id": "Enemy_1"},
                 "priority": 4, "issued_tick": 2249, "expires_tick": 5849}
        kept, _dropped = nodes._resolve_same_unit_conflicts(state, [squad, retreat], 2249)
        self.assertEqual([item["intent_id"] for item in kept],
                         ["bt-retreat-Unit_23-2249"],
                         "整条让位：不能只带走一半人")

    def test_gather_is_not_cancelled_by_move(self):
        """本职动作（采集）不在这一层互相取消（避免把经济线一起掐掉）。"""
        from adjutant_coordinator.graph import nodes
        state = self._state()
        gather = {"intent_id": "rule-fill-gather-Unit_23-2249", "action": "gather",
                  "unit_ids": ["Unit_23"], "target": {"resource": "Res_A"},
                  "priority": 3, "issued_tick": 2249, "expires_tick": 5849}
        move = self._intent("rule-fill-advance-Unit_23-2249", "attack_move", "Unit_23")
        kept, dropped = nodes._resolve_same_unit_conflicts(state, [gather, move], 2249)
        self.assertEqual(len(kept), 2, "采集/生产/建造不参与移动族去重")
        self.assertEqual(dropped, [])


class BlockedMoveFallbackTest(unittest.TestCase):
    """**受阻降级**守门测试（计划 §7：没有证据时只能集结、守卫、脱离或等待）。

    背景（2026-09-13 结局局，10 分钟真实交战打到结算、我方单位归零）：
    旧实现把被拦下的推进意图**直接丢弃**（`continue`），于是部队"停在原地挨打" ——
    日志上只看到 `movement_gated:threat_too_high`，看不出部队接下来做了什么。

    这里钉住三条不变式：
    ① 每个被拦下的推进意图都必须落进**四个归宿之一**（脱离/集结/守卫/等待），
       且 `wait` 是**显式记账**（不是静默丢弃）；
    ② 降级出来的移动也必须过闸门（边界 + 权威路径 + 脱离判据），拿不到路径就守卫；
    ③ 求生移动（撤退）只服从"真的在脱离敌人"这一条判据 —— 目标更靠近敌人 = 拦住。
    """

    BASE = [5.0, 5.0]
    UNIT = [10.0, 7.0]
    ENEMY = [14.0, 7.0]
    ADVANCE = [20.0, 7.0]

    def _state(self):
        return {"map_bounds": [50.0, 50.0], "server_tick": 600,
                "ai_controlled_units": ["Unit_4", "Unit_1", "Unit_2"]}

    def _view(self, *, base=True, enemies=True, two_soldiers=False):
        entities = [unit("Unit_4", "soldier", (10, 7))]
        if base:
            entities.append(unit("Unit_0", "command_center", (5, 5), movement=False))
        if enemies:
            entities.append(enemy("Enemy_1", (14, 7)))
        if two_soldiers:
            entities = [unit("Unit_1", "soldier", (10, 7)),
                        unit("Unit_2", "soldier", (40, 40)),
                        unit("Unit_0", "command_center", (5, 5), movement=False)]
        return tactical(entities)

    def _disengage(self, *, base=True):
        from adjutant_coordinator.graph import rules_fallback as rf
        return rf.disengage_point(
            tuple(self.UNIT), home=tuple(self.BASE) if base else None,
            enemies=[{"pos": [self.ENEMY[0], 0.0, self.ENEMY[1]]}],
            bounds=[50.0, 50.0])

    @classmethod
    def _is_disengage_target(cls, pos):
        """目标比当前位置更远离敌人，且不是沿威胁轴硬顶（那是推进）。"""
        farther = math.hypot(pos[0] - cls.ENEMY[0], pos[1] - cls.ENEMY[1]) > 4.5
        along_threat = abs(pos[1] - cls.ENEMY[1]) < 2.5 and pos[0] > 12.0
        return farther and not along_threat

    @classmethod
    def _nav(cls, *, retreat_ok=True, revision=1):
        """目标感知的路径桩：脱离点 → 远离敌人的路；否则 → 穿过敌人的推进路。"""
        def query(unit_name, target):
            pos = [float(target[0]), float(target[1])]
            if cls._is_disengage_target(pos):
                if not retreat_ok:
                    return {"ok": False, "reason": "no_path", "nav_revision": revision}
                return {"ok": True, "reachable": True, "nav_revision": revision,
                        "waypoints": [list(cls.UNIT), pos], "route_length": 8.0,
                        "end_clamped": False, "start_clamped": False}
            return {"ok": True, "reachable": True, "nav_revision": revision,
                    "waypoints": [list(cls.UNIT), list(cls.ENEMY)], "route_length": 4.0,
                    "end_clamped": False, "start_clamped": False}
        return query

    def _advance(self, units=("Unit_4",), pos=(20.0, 7.0)):
        return {"intent_id": "rule-fill-advance-%s-600" % units[0], "action": "attack_move",
                "unit_ids": list(units), "target": {"pos": list(pos)},
                "priority": 3, "issued_tick": 600, "expires_tick": 1200}

    def test_threat_block_yields_retreat_to_base(self):
        from adjutant_coordinator.graph import nodes
        state = self._state()
        ctx = _ctx_with(self._nav(), self._view())
        kept, blocked = nodes._gate_movement(state, ctx, [self._advance()])
        self.assertEqual(blocked[0]["detail"], mv.REJECT_THREAT)
        actions = [str(item["action"]) for item in kept]
        self.assertIn("retreat", actions, "遇敌拦下必须撤向脱离点，不许什么都不做：%s" % kept)
        retreat = [item for item in kept if item["action"] == "retreat"][0]
        point = retreat["target"]["pos"]
        self.assertNotEqual(point, self.BASE, "撤退目标不得再是主基地")
        self.assertGreater(
            math.hypot(point[0] - self.ENEMY[0], point[1] - self.ENEMY[1]),
            math.hypot(self.UNIT[0] - self.ENEMY[0], self.UNIT[1] - self.ENEMY[1]),
            "脱离点必须比当前位置更远离敌人，实际 %s" % point)
        self.assertEqual(state["movement_stats"]["fallbacks"].get("retreat"), 1)
        self.assertEqual(state["movement_stats"]["unsafe_dispatches"], 0,
                         "降级产物同样是**验证过的**移动，不能把 unsafe 计数弄脏")
        survival = state["routes"]["survival|Unit_4"]
        self.assertEqual(survival["fallback"], "retreat",
                         "降级路线必须留痕（报告要读）")
        self.assertEqual(state["routes"]["Unit_4"]["fallback"], "",
                         "推进路线的槽位不许被求生路线改写")

    def test_retreat_target_must_be_farther_from_enemy(self):
        """撤退路径不安全（要贴着/穿过敌人）→ 不发这条撤退，改**守卫**并留原因。"""
        from adjutant_coordinator.graph import nodes
        state = self._state()

        def nav_through_enemy(unit_name, target):
            # 回基地的路径先贴着敌人（经过 (14,7)）→ 比现在更近 = 不是撤退。
            return {"ok": True, "reachable": True, "nav_revision": 1,
                    "waypoints": [[10, 7], [14, 7], [8, 6], [5, 5]], "route_length": 9.0,
                    "end_clamped": False, "start_clamped": False}

        kept, _blocked = nodes._gate_movement(
            state, _ctx_with(nav_through_enemy, self._view()), [self._advance()])
        self.assertEqual([item["action"] for item in kept], ["hold"],
                         "撤不动 → 守卫（原地 stop，交给自动交火），不许硬撤")
        self.assertEqual(state["movement_stats"]["fallbacks"].get("hold"), 1)
        self.assertIn("retreat:%s" % mv.REJECT_NOT_DISENGAGING,
                      state["movement_stats"]["fallback_reasons"])

    def test_no_base_anchor_still_has_a_fallback(self):
        """拿不到基地锚点也不许"什么都不做"：仍按脱离点撤退，或降级守卫。"""
        from adjutant_coordinator.graph import nodes
        state = self._state()
        kept, _blocked = nodes._gate_movement(
            state, _ctx_with(self._nav(), self._view(base=False)), [self._advance()])
        actions = [item["action"] for item in kept]
        self.assertTrue(actions, "没有基地时也必须有脱离/守卫，不能静默丢弃")
        self.assertTrue(set(actions) <= {"retreat", "hold"}, actions)
        if "retreat" in actions:
            point = [item["target"]["pos"] for item in kept if item["action"] == "retreat"][0]
            self.assertNotEqual(point, self.BASE)
            self.assertGreater(
                math.hypot(point[0] - self.ENEMY[0], point[1] - self.ENEMY[1]), 4.0)
        else:
            reasons = state["movement_stats"]["fallback_reasons"]
            self.assertTrue(reasons, "守卫必须留下原因：%s" % reasons)

    def test_no_path_block_is_an_explicit_wait(self):
        """没证据（无路径）时计划允许"等待" —— 但必须是**显式**归宿，不是静默丢弃。"""
        from adjutant_coordinator.graph import nodes
        state = self._state()
        kept, _blocked = nodes._gate_movement(
            state, _ctx_with(nav_fail(), self._view()), [self._advance()])
        self.assertEqual(kept, [], "拿不到路径就不许移动（也不许降级出一条没验证的路）")
        stats = state["movement_stats"]
        self.assertEqual(stats["fallback_wait_reasons"].get(mv.REJECT_NO_PATH), 1)
        self.assertEqual(stats["fallback_total"], 1)
        self.assertEqual(stats["fallbacks"].get("wait"), 1)

    def test_disengage_move_reaching_closer_to_enemy_is_blocked(self):
        """行为树的"劣势撤离"同样过闸门：目标更靠近敌人 = 拦住（换个方向送不算撤）。"""
        from adjutant_coordinator.graph import nodes
        state = self._state()
        retreat = {"intent_id": "bt-retreat-Unit_4-600", "action": "retreat",
                   "unit_ids": ["Unit_4"], "target": {"pos": [16.0, 7.0]},
                   "priority": 95, "issued_tick": 600, "expires_tick": 1200}
        kept, blocked = nodes._gate_movement(
            state, _ctx_with(self._nav(), self._view()), [retreat])
        self.assertEqual(blocked[0]["reason"],
                         "movement_gated:%s" % mv.REJECT_NOT_DISENGAGING)
        self.assertEqual([item["action"] for item in kept], ["hold"],
                         "求生移动被拦 → 守卫（再撤会和刚被拒的意图撞车）")

    def test_survival_route_never_clobbers_the_advance_route(self):
        """求生（撤退/集结）路线**不许**占用"被批准推进的路线"槽位。

        那个槽位（`routes[unit]`）是 `allowed_relay()` / `needs_replan()` 的数据源：
        把被拒的求生路线写进去会把合法推进路线顶掉（下一轮被迫重规划），
        把已批准的撤退终点写进去会被当成"可推进中继点"发回给规则阶梯。
        """
        from adjutant_coordinator.graph import nodes
        state = self._state()
        # 目标不同 → 闸门必须重规划（否则会直接复用它、根本走不到降级）。
        mv.record_route(state, mv.RoutePlan(unit="Unit_4", ok=True, relay_point=[14.0, 7.0],
                                           target=[40.0, 40.0], nav_revision=1,
                                           last_replan_tick=600))
        self.assertEqual(mv.allowed_relay(state, "Unit_4"), [14.0, 7.0])

        def nav_through_enemy(unit_name, target):
            return {"ok": True, "reachable": True, "nav_revision": 1,
                    "waypoints": [[10, 7], [14, 7], [8, 6], [5, 5]], "route_length": 9.0,
                    "end_clamped": False, "start_clamped": False}

        nodes._gate_movement(state, _ctx_with(nav_through_enemy, self._view()),
                             [self._advance()])
        survival = state["routes"]["survival|Unit_4"]
        self.assertFalse(survival["ok"], "求生路线自己要留痕（含被拒结论）")
        self.assertEqual(survival["reason"], mv.REJECT_NOT_DISENGAGING)
        self.assertNotEqual(survival["target"], self.BASE, "求生路线不得再指向主基地")
        self.assertGreater(
            math.hypot(survival["target"][0] - self.ENEMY[0],
                       survival["target"][1] - self.ENEMY[1]), 4.0)
        advance = state["routes"]["Unit_4"]
        self.assertEqual(advance["target"], [20.0, 7.0],
                         "推进路线的记录（含目标）不许被求生路线改写")
        self.assertEqual(advance["fallback"], "", "推进路线不该被标成降级产物")

    def test_survival_rejection_is_reused_without_a_second_query(self):
        """同一个"撤不动"的结论在窗口内复用 → 不再重复查权威路径（省钱且语义相同）。"""
        from adjutant_coordinator.graph import nodes
        state = self._state()
        calls = []

        def nav_spy(unit_name, target):
            calls.append([float(target[0]), float(target[1])])
            return {"ok": True, "reachable": True, "nav_revision": 1,
                    "waypoints": [[10, 7], [14, 7], [8, 6], [5, 5]], "route_length": 9.0,
                    "end_clamped": False, "start_clamped": False}

        ctx = _ctx_with(nav_spy, self._view())
        nodes._gate_movement(state, ctx, [self._advance()])
        after_first = len([call for call in calls if call != self.ADVANCE])
        state["server_tick"] = 660
        nodes._gate_movement(state, ctx, [self._advance()])
        after_second = len([call for call in calls if call != self.ADVANCE])
        self.assertEqual(after_first, 1, "第一次必须真的问一次脱离点（不许凭空拒绝）")
        self.assertEqual(after_second, 1, "窗口内不许再问第二次")
        self.assertTrue(any(str(key).endswith("(复用)")
                            for key in state["movement_stats"]["fallback_reasons"]),
                        "复用也要留痕：%s" % state["movement_stats"]["fallback_reasons"])

    def test_no_nav_query_while_grid_is_rebaking(self):
        """网格刚换版本（重烘中）→ **不做求生查询**（重烘期间查路径会阻塞整轮）。

        实测（2026-09-13 180 秒真机局）：唯一一次 3.59 秒"单轮静默"就发生在这里 ——
        那一轮正在重烘（`movement_gated:stale_nav_revision`），同时又发了一条求生撤退查询，
        协调线程被一次权威寻路往返卡了 3.24 秒。晚一轮再算完全安全（部队已被拦下、守卫中）。
        """
        from adjutant_coordinator.graph import nodes
        state = self._state()
        # 缓存路线的网格版本 = 6，当前版本 = 7 → 刚重烘过。
        mv.record_route(state, mv.RoutePlan(unit="Unit_4", ok=True, relay_point=[14.0, 7.0],
                                           target=[20.0, 7.0], nav_revision=6,
                                           last_replan_tick=600))
        state["nav_revision"] = 7
        calls = []

        def nav_spy(unit_name, target):
            calls.append([float(target[0]), float(target[1])])
            return {"ok": True, "reachable": True, "nav_revision": 7,
                    "waypoints": [[10, 7], [6, 6], [5, 5]], "route_length": 6.0,
                    "end_clamped": False, "start_clamped": False}

        self.assertTrue(mv.nav_revision_changed(state, "Unit_4"))
        # 直接测降级入口（真实链路上这是"本轮推进查询与求生查询之间网格又换了一版"的竞态；
        # 这里把条件摆明，钉住"已知网格换了就不查"这条纪律）。
        out = nodes._blocked_move_fallbacks(
            state, _ctx_with(nav_spy, self._view()),
            {"intent_id": "i-1", "action": "attack_move", "unit_ids": ["Unit_4"],
             "target": {"pos": [20.0, 7.0]}, "priority": 3, "issued_tick": 600},
            units=["Unit_4"], reason=mv.REJECT_THREAT, tick=600, budget=[2])
        self.assertEqual([item["action"] for item in out], ["hold"],
                         "重烘期间只能守卫（下一轮再算撤退）")
        self.assertEqual(calls, [],
                         "重烘期间**不许**再发求生路径查询：%s" % calls)
        self.assertIn("nav_rebake:retreat", state["movement_stats"]["fallback_reasons"])

    def test_scattered_squad_regroups_instead_of_scattering(self):
        """队形散开 → **真的去集结**（regroup 到最保守的那一跳），不是"下轮再试"。"""
        from adjutant_coordinator.graph import nodes
        state = self._state()
        view = self._view(two_soldiers=True)
        kept, blocked = nodes._gate_movement(
            state, _ctx_with(nav_ok([[10, 7], [14, 7], [18, 7]]), view),
            [self._advance(units=("Unit_1", "Unit_2"), pos=(30.0, 7.0))])
        self.assertEqual(blocked[0]["detail"], mv.REJECT_SQUAD_SCATTER)
        self.assertEqual([item["action"] for item in kept], ["regroup", "regroup"])
        self.assertEqual({tuple(item["target"]["pos"]) for item in kept}, {(18.0, 7.0)},
                         "全队必须集结点一致（否则仲裁层合并不了、也就看不到批量指挥）")
        self.assertEqual(state["movement_stats"]["fallbacks"].get("regroup"), 2)

    def test_fallback_id_is_stable_inside_the_window(self):
        """同一窗口内重复生成的降级意图 id 相同 → 由仲裁层判重（去重只有一处实现）。"""
        from adjutant_coordinator.graph import nodes
        first = nodes._fallback_intent_id("retreat", "Unit_4", 600)
        same_window = nodes._fallback_intent_id("retreat", "Unit_4", 899)
        next_window = nodes._fallback_intent_id("retreat", "Unit_4", 900)
        self.assertEqual(first, same_window)
        self.assertNotEqual(first, next_window)

    def test_reinforcements_coming_lets_the_mass_advance(self):
        """集结修复（2026-09-21）：援军已在赶来这一仗 → 闸门放行，大军压得上去。

        没有这一条时，被 `threat_too_high` 拦下的单位会逐个后撤，正在集结的
        大军被一根根抽走（实测 v11：114 次 retreat，413 次推进只放行 56 次，
        90:31 的优势兵力超时亡）。判据：受命赶来这一仗的援军战力 ≥ 接敌门槛 × 当面之敌。
        """
        from adjutant_coordinator.graph import nodes
        state = self._state()
        # Unit_4 的路线目标 = 敌人所在处（20,7）；3 个战友受命开往同一战区（16,7）。
        state["routes"] = {
            "Unit_4": {"ok": True, "target": [20.0, 7.0], "nav_revision": 1,
                       "last_replan_tick": 590, "relay_point": [14.0, 7.0]},
            "Ref_1": {"ok": True, "target": [16.0, 7.0]},
            "Ref_2": {"ok": True, "target": [16.5, 7.0]},
            "Ref_3": {"ok": True, "target": [17.0, 7.0]},
        }
        entities = [unit("Unit_4", "soldier", (10, 7))]
        entities.append(unit("Ref_1", "soldier", (30, 30)))
        entities.append(unit("Ref_2", "soldier", (31, 30)))
        entities.append(unit("Ref_3", "soldier", (32, 30)))
        entities.append(unit("Unit_0", "command_center", (5, 5), movement=False))
        entities.append(enemy("Enemy_1", (14, 7)))
        view = tactical(entities)
        kept, blocked = nodes._gate_movement(
            state, _ctx_with(self._nav(), view), [self._advance()])
        self.assertEqual(blocked, [], "援军在路上时不许再拦：%s" % blocked)
        self.assertTrue(kept, "放行后必须有可下发的推进")

    def test_threat_blocked_unit_still_retreats_when_alone(self):
        """对照组：孤立无援 → 仍然撤退（求生纪律不因集结修复而放宽）。"""
        from adjutant_coordinator.graph import nodes
        state = self._state()
        state["routes"] = {
            "Unit_4": {"ok": True, "target": [20.0, 7.0], "nav_revision": 1,
                       "last_replan_tick": 590, "relay_point": [14.0, 7.0]},
        }
        kept, blocked = nodes._gate_movement(
            state, _ctx_with(self._nav(), self._view()), [self._advance()])
        self.assertEqual(blocked[0]["detail"], mv.REJECT_THREAT)
        actions = [str(item["action"]) for item in kept]
        self.assertIn("retreat", actions,
                      "没有援军时必须照旧撤离：%s" % actions)

    def test_fallback_holds_instead_of_retreat_when_support_coming(self):
        """已拦下时的第二道判据：援军在路上 → 守卫等大队，不后撤。

        闸门那道判据用"本次路径终点"算支援；这里用"该单位自己路线的目标"再判一次
        （两个点可能不同），保证同一条纪律在两处都不会把大军放跑。
        """
        held = mv.fallback_action_for("attack_move", mv.REJECT_THREAT,
                                      support=3.0, local_enemy=1.0)
        self.assertEqual(held, mv.FALLBACK_GUARD)
        alone = mv.fallback_action_for("attack_move", mv.REJECT_THREAT,
                                       support=0.0, local_enemy=1.0)
        self.assertEqual(alone, mv.FALLBACK_RETREAT)
        # 支援不足（< 1.2 × 当面之敌）→ 仍然撤退。
        thin = mv.fallback_action_for("attack_move", mv.REJECT_THREAT,
                                      support=1.0, local_enemy=1.0)
        self.assertEqual(thin, mv.FALLBACK_RETREAT)
        # 没有敌人时不存在"这一仗"，不改变原有分档。
        no_foe = mv.fallback_action_for("attack_move", mv.REJECT_THREAT,
                                        support=5.0, local_enemy=0.0)
        self.assertEqual(no_foe, mv.FALLBACK_RETREAT)


if __name__ == "__main__":
    unittest.main()
