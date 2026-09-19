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
        """整条路径都在视野外 → 没有安全中继点 → 不许推进。"""
        plan = mv.plan_safe_route(self._state(),
                                  tactical([unit("Unit_4", "soldier", (10, 7))]),
                                  unit="Unit_4", target=[45.0, 45.0], tick=600,
                                  nav_query=nav_ok([[30, 30], [40, 40], [45, 45]]))
        self.assertFalse(plan.ok)
        self.assertEqual(plan.reason, mv.REJECT_NO_RELAY)

    def test_relay_stops_at_the_edge_of_vision(self):
        """中继点 = 路径上仍被己方视野覆盖的**最远**点（推进一跳，不是走到终点）。"""
        plan = mv.plan_safe_route(self._state(),
                                  tactical([unit("Unit_4", "soldier", (10, 7))]),
                                  unit="Unit_4", target=[30.0, 7.0], tick=600,
                                  nav_query=nav_ok([[10, 7], [14, 7], [18, 7], [30, 7]]))
        self.assertTrue(plan.ok, plan.reason)
        self.assertLess(plan.relay_point[0], 30.0, "不该一步走到终点")
        self.assertAlmostEqual(plan.relay_point[0], 18.0, places=1)

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


if __name__ == "__main__":
    unittest.main()
