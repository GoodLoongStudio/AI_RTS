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
        self.assertEqual(stats["scout_first_coverage"], 1.0)
        self.assertEqual(stats["unsafe_dispatches"], 0)

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


if __name__ == "__main__":
    unittest.main()
