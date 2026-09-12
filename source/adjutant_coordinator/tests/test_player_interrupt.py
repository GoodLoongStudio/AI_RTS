# -*- coding: utf-8 -*-
"""玩家打断测试：立即增加代际、撤销 lease、失效旧意图、计划不被清空、局部性。

图节点级测试（不依赖模型与网络）+ 显式归还后 AI 才能重新接管。
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph import interrupts as itr
from adjutant_coordinator.graph.nodes import (
    GraphConfig, GraphServices, NodeContext, node_arbitrate_intent, node_classify,
    node_ingest, node_reconcile_plan, node_tactical_agent,
)
from adjutant_coordinator.graph.pydantic_agents import FakeStructuredModel
from adjutant_coordinator.graph.state import AdjutantGraphState

from graph_test_helpers import (
    MATCH, PLAYER, RULES, events_for, header, make_batch, make_intent, make_plan, rules_view,
    tactical,
)


def make_state(with_plan=True) -> AdjutantGraphState:
    state = AdjutantGraphState(match_id=MATCH, player_id=PLAYER)
    state.rules_version = RULES
    if with_plan:
        plan = make_plan(units=["Unit_1", "Unit_2"])
        state.active_plan = plan
        state.plan_version = "plan-a:v1"
        state.last_strategy_tick = 0  # 计划刚生成，战略不因“无 tick 记录”重复触发
        state.register_task("t-1", "running")
    state.ensure_units(["Unit_1", "Unit_2"])
    state.add_intent(make_intent("i-u1", units=["Unit_1"], expires_tick=100000,
                                 generation=state.generation_of("Unit_1")), "active")
    state.add_intent(make_intent("i-u2", units=["Unit_2"], expires_tick=100000,
                                 generation=state.generation_of("Unit_2")), "active")
    return state


def make_ctx(observation=None, tick=0, config=None, services=None):
    return NodeContext(
        services=services or GraphServices(config=config or GraphConfig()),
        observation=observation or {}, tick=tick)


class PlayerInterruptNodeTest(unittest.TestCase):
    def test_override_bumps_generation_and_drops_only_related_intents(self):
        state = make_state()
        data = state.to_dict()
        gen_u1 = state.generation_of("Unit_1")
        data["pending_events"] = [events_for("player_override", ["Unit_1"], 10)]
        ctx = make_ctx(tick=10)

        data = node_classify(data, ctx)
        self.assertEqual(data["route"], itr.ROUTE_PLAYER_INTERRUPT)
        data = node_reconcile_plan(data, ctx)

        restored = AdjutantGraphState.from_dict(data)
        self.assertGreater(restored.generation_of("Unit_1"), gen_u1)
        self.assertTrue(restored.is_unit_player_controlled("Unit_1"))
        self.assertEqual(restored.find_intent("i-u1")["state"], "dropped")
        self.assertEqual(restored.find_intent("i-u1")["drop_reason"], "player_override")
        # 未涉及的单位继续由 AI 执行：意图仍然有效。
        self.assertEqual(restored.find_intent("i-u2")["state"], "active")
        self.assertFalse(restored.is_unit_player_controlled("Unit_2"))
        self.assertEqual(restored.active_tasks["t-1"], "partially_overridden")
        # 局部接管不清空整个战略计划。
        self.assertIsNotNone(restored.active_plan)
        self.assertEqual(restored.plan_version, "plan-a:v1")
        self.assertTrue(data["paused"])

    def test_release_allows_reacquire(self):
        state = make_state()
        state.mark_player_override(["Unit_1"], 10, "manual")
        data = state.to_dict()
        data["pending_events"] = [events_for("player_release", ["Unit_1"], 20)]
        ctx = make_ctx(tick=20)
        data = node_classify(data, ctx)
        data = node_reconcile_plan(data, ctx)
        restored = AdjutantGraphState.from_dict(data)
        self.assertFalse(restored.is_unit_player_controlled("Unit_1"))
        self.assertIn("Unit_1", restored.released_units)
        # 归还后 AI 才能重新接管：新的 generation 允许新意图。
        intent = make_intent("i-u1-new", units=["Unit_1"], expires_tick=100000)
        ok, reason = restored.is_intent_valid(intent, 21)
        self.assertTrue(ok, reason)

    def test_stale_intent_cannot_take_over_after_player_command(self):
        state = make_state()
        stale_generation = state.generation_of("Unit_1")
        state.mark_player_override(["Unit_1"], 10, "manual")
        data = state.to_dict()
        data["candidate_intents"] = [make_intent(
            "i-stale", units=["Unit_1"], generation=stale_generation, expires_tick=100000)]
        ctx = make_ctx(observation={"tactical": tactical()}, tick=11)
        data = node_arbitrate_intent(data, ctx)
        dropped = {item["intent_id"]: item["reason"]
                   for item in data["intent_arbitration"]["dropped"]}
        self.assertEqual(dropped.get("i-stale"), "lease_owner_player:Unit_1")
        self.assertEqual(data["intent_arbitration"]["accepted"], [])

    def test_emergency_event_preempts_normal_intents(self):
        state = make_state()
        data = state.to_dict()
        data["pending_events"] = [events_for("base_under_attack", ["Unit_1"], 30)]
        ctx = make_ctx(observation={"tactical": tactical(), "rules": rules_view()}, tick=30)
        data = node_tactical_agent(data, ctx)
        restored = AdjutantGraphState.from_dict(data)
        self.assertEqual(restored.find_intent("i-u1")["state"], "dropped")
        self.assertEqual(restored.find_intent("i-u1")["drop_reason"], "preempted_by_emergency")
        # 无关单位的普通任务不被抢占。
        self.assertEqual(restored.find_intent("i-u2")["state"], "active")

    def test_ingest_records_identity_drift_and_blocks_dispatch(self):
        state = make_state()
        data = state.to_dict()
        ctx = make_ctx(observation={"header": header(50, match_id="other-match")}, tick=50)
        data = node_ingest(data, ctx)
        self.assertEqual(data["degraded_reason"], "identity_drift")
        # 漂移时 tick 不被推进（不接受别的对局的时间线）。
        self.assertEqual(data["server_tick"], 0)


class RouteClassificationTest(unittest.TestCase):
    def test_player_interrupt_wins_over_emergency(self):
        state = make_state()
        data = state.to_dict()
        data["pending_events"] = [
            events_for("base_under_attack", ["Unit_2"], 5, event_id="e-attack"),
            events_for("player_override", ["Unit_1"], 5, event_id="e-override"),
        ]
        data = node_classify(data, make_ctx(tick=5))
        self.assertEqual(data["route"], itr.ROUTE_PLAYER_INTERRUPT)

    def test_emergency_wins_over_strategic(self):
        state = make_state()
        state.active_plan = None  # 战略到期
        data = state.to_dict()
        data["pending_events"] = [events_for("enemy_spotted", ["Unit_1"], 5)]
        data = node_classify(data, make_ctx(tick=5))
        self.assertEqual(data["route"], itr.ROUTE_EMERGENCY_TACTICAL)

    def test_no_strategy_plan_triggers_strategic_route(self):
        state = make_state()
        state.active_plan = None
        data = state.to_dict()
        data["pending_events"] = []
        data = node_classify(data, make_ctx(tick=5))
        self.assertEqual(data["route"], itr.ROUTE_STRATEGIC)

    def test_pending_authority_does_not_block_tactics_route(self):
        """在途命令**不得**全局压制战术决策（2026-09-12 晚契约变更）。

        旧契约（本用例原本断言 `route == wait`）的实测后果：主循环 0.58 秒/轮，
        但模型每 **4.7 秒**才被问一次（`produce`/`attack_move` 先回 PendingAuthority，
        期间路由恒为 wait）—— 用户质问"既然每秒一次思考，为什么没看到持续下命令"。

        新契约：路由照常进战术分支；"不对同一单位重复下发"由**仲裁层**负责
        （`pending_authority_unresolved` 指纹去重 + `duplicate_of_live_intent`），
        它是单位级语义，不该由一条在途命令代表全队把决策掐掉。
        """
        state = make_state()
        state.pending_requests["i-u1"] = {"intent_id": "i-u1", "command_id": "cmd"}
        data = state.to_dict()
        data["pending_events"] = [events_for("queue_idle", ["Unit_1"], 5)]
        data = node_classify(data, make_ctx(tick=6))
        self.assertEqual(data["route"], itr.ROUTE_TACTICAL)


if __name__ == "__main__":
    unittest.main()
