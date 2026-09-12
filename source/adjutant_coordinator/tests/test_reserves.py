# -*- coding: utf-8 -*-
"""资源预留测试（方案 §6）。

要点：预留是**玩家设定**（首次开启取余额 20%，之后玩家可改），
AI 下单前由权威端检查余额 / 预留 / 已承诺成本；设 0 表示允许使用全部资源。
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph import reserves
from adjutant_coordinator.graph.state import (
    INTENT_ACTIVE, INTENT_COMPLETED, AdjutantGraphState,
)

RULES = {
    "unit_types": [
        {"id": "worker", "scene_path": "res://units/Worker.tscn"},
        {"id": "command_center", "scene_path": "res://units/CommandCenter.tscn"},
    ],
    "productions": [
        {"product_type_id": "worker", "allowed_producer_type_ids": ["command_center"],
         "cost": [{"kind": "A", "amount": 200}]},
    ],
    "constructions": [
        {"id": "barracks", "blueprint_scene_path": "res://buildings/Barracks.tscn",
         "cost": [{"kind": "A", "amount": 300}]},
    ],
}

OBS = {"tactical": {"balance": {"a": 1000, "b": 40}}}


def produce(intent_id="i-1", scene="res://units/Worker.tscn", producer="Unit_0"):
    return {"intent_id": intent_id, "action": "produce", "unit_ids": [producer],
            "target": {"producer": producer, "scene": scene}, "state": INTENT_ACTIVE}


def build(intent_id="i-2", scene="res://buildings/Barracks.tscn", builder="Unit_2"):
    return {"intent_id": intent_id, "action": "build", "unit_ids": [builder],
            "target": {"producer": builder, "scene": scene}, "state": INTENT_ACTIVE}


def move(intent_id="i-3"):
    return {"intent_id": intent_id, "action": "move", "unit_ids": ["Unit_2"],
            "target": {"pos": [10.0, 0.0]}, "state": INTENT_ACTIVE}


class InitializeTest(unittest.TestCase):
    def test_first_enable_takes_twenty_percent_of_balance(self):
        state = {}
        created = reserves.ensure_reserves(state, {"A": 1000, "B": 45})
        self.assertTrue(created)
        self.assertEqual(state["reserves"], {"A": 200, "B": 9})

    def test_second_call_does_not_recompute_from_current_balance(self):
        # 方案明文：不能每次花费后按剩余余额重算。
        state = {}
        reserves.ensure_reserves(state, {"A": 1000})
        reserves.set_reserves(state, {"A": 0})
        self.assertFalse(reserves.ensure_reserves(state, {"A": 9999}))
        self.assertEqual(state["reserves"], {"A": 0})

    def test_percent_is_configurable(self):
        state = {}
        reserves.ensure_reserves(state, {"A": 1000}, percent=35)
        self.assertEqual(state["reserves"], {"A": 350})


class PlayerAdjustTest(unittest.TestCase):
    def test_partial_update_keeps_other_kinds(self):
        state = {}
        reserves.ensure_reserves(state, {"A": 1000, "B": 100})
        updated = reserves.set_reserves(state, {"A": 50})
        self.assertEqual(updated, {"A": 50, "B": 20})

    def test_zero_means_unrestricted(self):
        state = {}
        reserves.ensure_reserves(state, {"A": 1000})
        reserves.set_reserves(state, {"A": 0})
        available = reserves.spendable({"A": 400}, state["reserves"], {})
        self.assertEqual(available["A"], 400)


class SpendableTest(unittest.TestCase):
    def test_subtracts_reserve_and_committed(self):
        available = reserves.spendable({"A": 1000}, {"A": 200}, {"A": 300})
        self.assertEqual(available["A"], 500)

    def test_never_negative(self):
        available = reserves.spendable({"A": 100}, {"A": 200}, {"A": 300})
        self.assertEqual(available["A"], 0)


class IntentCostTest(unittest.TestCase):
    def test_produce_cost_looked_up_by_scene_path(self):
        # 仲裁前 scene 已被归一化成**场景路径**，必须按路径反查（不能按 id 查）。
        self.assertEqual(reserves.intent_cost(produce(), RULES), {"A": 200})

    def test_build_cost_looked_up_by_blueprint_path(self):
        self.assertEqual(reserves.intent_cost(build(), RULES), {"A": 300})

    def test_non_costly_action_has_no_cost(self):
        self.assertEqual(reserves.intent_cost(move(), RULES), {})

    def test_unknown_scene_returns_empty_instead_of_guessing(self):
        self.assertEqual(reserves.intent_cost(
            produce(scene="res://units/Unknown.tscn"), RULES), {})

    def test_rules_error_returns_empty(self):
        self.assertEqual(reserves.intent_cost(produce(), {"error": "unavailable"}), {})


class ApplyBudgetTest(unittest.TestCase):
    def _state(self, reserves_map):
        state = {"active_intents": []}
        state["reserves"] = dict(reserves_map)
        state["reserves_initialized"] = True
        return state

    def test_blocks_when_reserve_would_be_breached(self):
        state = self._state({"A": 900})
        kept, dropped = reserves.apply_budget(
            state, [produce()], rules=RULES, observation=OBS,
            live_states=(INTENT_ACTIVE,))
        self.assertEqual(kept, [])
        self.assertEqual(dropped[0]["reason"], "insufficient_reserve:A")

    def test_allows_within_spendable(self):
        state = self._state({"A": 200})
        kept, dropped = reserves.apply_budget(
            state, [produce()], rules=RULES, observation=OBS,
            live_states=(INTENT_ACTIVE,))
        self.assertEqual([item["intent_id"] for item in kept], ["i-1"])
        self.assertEqual(dropped, [])

    def test_same_batch_candidates_do_not_reuse_one_purse(self):
        # 余额 1000、预留 700 → 可花 300：两个 200 成本的候选只能过一个。
        state = self._state({"A": 700})
        kept, dropped = reserves.apply_budget(
            state, [produce("i-1"), produce("i-2")], rules=RULES, observation=OBS,
            live_states=(INTENT_ACTIVE,))
        self.assertEqual([item["intent_id"] for item in kept], ["i-1"])
        self.assertEqual(dropped[0]["intent_id"], "i-2")

    def test_active_intents_are_already_committed(self):
        # 预留 700 + 在途 200 已占 → 可花 100，新的 200 成本必须被挡。
        state = self._state({"A": 700})
        state["active_intents"] = [produce("i-old")]
        kept, dropped = reserves.apply_budget(
            state, [produce("i-new")], rules=RULES, observation=OBS,
            live_states=(INTENT_ACTIVE,))
        self.assertEqual(kept, [])
        self.assertEqual(dropped[0]["intent_id"], "i-new")

    def test_completed_intents_release_their_commitment(self):
        state = self._state({"A": 200})
        state["active_intents"] = [dict(produce("i-old"), state=INTENT_COMPLETED)]
        kept, _dropped = reserves.apply_budget(
            state, [produce("i-new")], rules=RULES, observation=OBS,
            live_states=(INTENT_ACTIVE,))
        self.assertEqual([item["intent_id"] for item in kept], ["i-new"])

    def test_unknown_cost_is_never_blocked(self):
        # 规则里查不到成本时不许猜数值，更不能误杀。
        state = self._state({"A": 99999})
        kept, dropped = reserves.apply_budget(
            state, [move(), produce(scene="res://units/Unknown.tscn")],
            rules=RULES, observation=OBS, live_states=(INTENT_ACTIVE,))
        self.assertEqual(len(kept), 2)
        self.assertEqual(dropped, [])

    def test_apply_budget_initializes_reserves_when_missing(self):
        state = {"active_intents": []}
        reserves.apply_budget(state, [produce()], rules=RULES, observation=OBS,
                              live_states=(INTENT_ACTIVE,))
        self.assertTrue(state["reserves_initialized"])
        self.assertEqual(state["reserves"], {"A": 200, "B": 8})


class AuthorityReserveTest(unittest.TestCase):
    """权威端导出的预留优先于本地推断（方案 §6："由权威端检查"）。"""

    def test_authority_value_overrides_local_initialization(self):
        state = {"active_intents": []}
        observation = {"tactical": {"balance": {"a": 1000}, "reserves": {"A": 700}}}
        reserves.apply_budget(state, [produce()], rules=RULES, observation=observation,
                              live_states=(INTENT_ACTIVE,))
        # 权威端给的是 700（而不是本地 20% = 200）→ 可花 300，200 成本允许。
        self.assertEqual(state["reserves"], {"A": 700})
        self.assertTrue(state["reserves_initialized"])

    def test_authority_value_is_applied_immediately(self):
        state = {"active_intents": []}
        first = {"tactical": {"balance": {"a": 1000}, "reserves": {"A": 200}}}
        reserves.apply_budget(state, [], rules=RULES, observation=first,
                              live_states=(INTENT_ACTIVE,))
        self.assertEqual(state["reserves"], {"A": 200})
        # 玩家改成 900 → 下一轮立刻生效（不需要额外下行通道）。
        second = {"tactical": {"balance": {"a": 1000}, "reserves": {"A": 900}}}
        kept, dropped = reserves.apply_budget(state, [produce()], rules=RULES,
                                              observation=second,
                                              live_states=(INTENT_ACTIVE,))
        self.assertEqual(kept, [])
        self.assertEqual(dropped[0]["reason"], "insufficient_reserve:A")

    def test_empty_authority_dict_means_unrestricted_not_unconfigured(self):
        # 空字典 = 玩家把预留设为 0（不限制）；**不能**误判成"没配置"再按 20% 初始化。
        state = {"active_intents": []}
        observation = {"tactical": {"balance": {"a": 1000}, "reserves": {}}}
        kept, dropped = reserves.apply_budget(state, [produce()], rules=RULES,
                                              observation=observation,
                                              live_states=(INTENT_ACTIVE,))
        self.assertEqual(state["reserves"], {})
        self.assertEqual(len(kept), 1)
        self.assertEqual(dropped, [])

    def test_falls_back_to_local_percent_when_authority_silent(self):
        state = {"active_intents": []}
        observation = {"tactical": {"balance": {"a": 1000}}}
        reserves.apply_budget(state, [], rules=RULES, observation=observation,
                              live_states=(INTENT_ACTIVE,))
        self.assertEqual(state["reserves"], {"A": 200})

    def test_strategic_view_is_used_as_fallback_source(self):
        observation = {"strategic": {"resources": {"a": 10, "b": 20},
                                     "reserves": {"a": 4}}}
        self.assertEqual(reserves.normalize_reserve_setting(observation), {"A": 4})
        self.assertEqual(reserves.normalize_balance(observation), {"A": 10, "B": 20})

    def test_missing_reserves_key_returns_none(self):
        self.assertIsNone(reserves.normalize_reserve_setting(
            {"tactical": {"balance": {"a": 1}}}))


class PersistenceTest(unittest.TestCase):
    def test_reserves_survive_state_round_trip(self):
        # "关闭重开副官保留本局已调整额度"依赖 checkpoint 往返保留这些字段。
        state = AdjutantGraphState(match_id="m-1", player_id="P1")
        state.reserves = {"A": 123}
        state.reserves_initialized = True
        state.reserves_percent = 20
        restored = AdjutantGraphState.from_dict(state.to_dict())
        self.assertEqual(restored.reserves, {"A": 123})
        self.assertTrue(restored.reserves_initialized)
        self.assertEqual(restored.reserves_percent, 20)

    def test_task_progress_survives_state_round_trip(self):
        state = AdjutantGraphState(match_id="m-1", player_id="P1")
        state.task_progress = {"intents": {"i-1": {"status": "in_progress"}}}
        restored = AdjutantGraphState.from_dict(state.to_dict())
        self.assertEqual(restored.task_progress["intents"]["i-1"]["status"], "in_progress")

    def test_balance_prefers_tactical_then_strategic(self):
        self.assertEqual(reserves.normalize_balance(OBS), {"A": 1000, "B": 40})
        self.assertEqual(reserves.normalize_balance(
            {"strategic": {"resources": {"a": 7}}}), {"A": 7})


if __name__ == "__main__":
    unittest.main()
