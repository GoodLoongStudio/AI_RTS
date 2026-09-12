# -*- coding: utf-8 -*-
"""契约测试：StrategicPlan / TacticalIntent 校验、目标约束与命令包映射。

全部确定性，不需要 API Key、不联网。
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph.contracts import (
    ContractError, IntentBatch, PlayerControlEvent, StrategicPlan, TacticalIntent,
    intent_to_command_envelope, intent_public_view, parse_intent_batch,
    parse_player_control_event, parse_strategic_plan, parse_tactical_intent,
)
from adjutant_coordinator.protocol import validate_plan

from graph_test_helpers import MATCH, PLAYER, RULES, SCENE_TANK, make_batch, make_intent, make_plan


class PlanContractTest(unittest.TestCase):
    def test_plan_parses_and_passes_existing_protocol(self):
        plan = parse_strategic_plan(make_plan())
        self.assertIsInstance(plan, StrategicPlan)
        self.assertEqual(plan.plan_version, 1)
        self.assertEqual(plan.tasks[0].task_id, "t-1")
        # 与既有协调器协议保持一致：转 dict 后仍能通过 protocol.validate_plan。
        errors = validate_plan(plan.to_plan_dict(), {
            "match_id": MATCH, "player_id": PLAYER, "rules_version": RULES})
        self.assertEqual(errors, [])

    def test_plan_rejects_extra_fields(self):
        raw = make_plan()
        raw["hallucinated_field"] = "模型编造的字段"
        with self.assertRaises(ContractError) as ctx:
            parse_strategic_plan(raw)
        self.assertTrue(any("hallucinated_field" in item for item in ctx.exception.errors))

    def test_plan_rejects_duplicate_task_ids(self):
        raw = make_plan()
        raw["tasks"].append(dict(raw["tasks"][0]))
        with self.assertRaises(ContractError):
            parse_strategic_plan(raw)

    def test_plan_rejects_empty_tasks_and_unknown_action(self):
        raw = make_plan()
        raw["tasks"] = []
        with self.assertRaises(ContractError):
            parse_strategic_plan(raw)
        raw = make_plan()
        raw["tasks"][0]["allowed_actions"] = ["teleport"]
        with self.assertRaises(ContractError):
            parse_strategic_plan(raw)

    def test_plan_rejects_non_increasing_version(self):
        raw = make_plan(version=0)
        with self.assertRaises(ContractError):
            parse_strategic_plan(raw)


class IntentContractTest(unittest.TestCase):
    def test_intent_parses(self):
        intent = parse_tactical_intent(make_intent())
        self.assertIsInstance(intent, TacticalIntent)
        self.assertEqual(intent.action, "move")
        self.assertEqual(intent.unit_ids, ["Unit_1"])

    def test_intent_rejects_unknown_action(self):
        with self.assertRaises(ContractError):
            parse_tactical_intent(make_intent(action="nuke"))

    def test_intent_rejects_arbitrary_target_keys(self):
        with self.assertRaises(ContractError) as ctx:
            parse_tactical_intent(make_intent(target={"script_path": "res://evil.tscn"}))
        self.assertTrue(any("script_path" in item for item in ctx.exception.errors))

    def test_intent_requires_position_for_move(self):
        with self.assertRaises(ContractError):
            parse_tactical_intent(make_intent(target={}))

    def test_attack_requires_entity_id(self):
        with self.assertRaises(ContractError):
            parse_tactical_intent(make_intent(action="attack", target={"pos": [1.0, 1.0]}))
        intent = parse_tactical_intent(make_intent(
            action="attack", target={"entity_id": "Unit_enemy_1"}))
        self.assertEqual(intent.target["entity_id"], "Unit_enemy_1")

    def test_produce_requires_scene_and_producer(self):
        with self.assertRaises(ContractError):
            parse_tactical_intent(make_intent(action="produce", target={"scene": SCENE_TANK}))
        intent = parse_tactical_intent(make_intent(
            action="produce", target={"scene": SCENE_TANK, "producer": "Unit_9"}))
        self.assertEqual(intent.action, "produce")

    def test_intent_rejects_bad_ttl_and_abort_condition(self):
        with self.assertRaises(ContractError):
            parse_tactical_intent(make_intent(issued_tick=100, expires_tick=50))
        with self.assertRaises(ContractError):
            raw = make_intent()
            raw["abort_when"] = ["whatever"]
            parse_tactical_intent(raw)

    def test_intent_requires_units_for_unit_actions(self):
        with self.assertRaises(ContractError):
            parse_tactical_intent(make_intent(units=[]))

    def test_batch_rejects_duplicate_intent_ids(self):
        raw = make_batch([make_intent("i-1"), make_intent("i-1", action="hold", target={})])
        with self.assertRaises(ContractError):
            parse_intent_batch(raw)
        batch = parse_intent_batch(make_batch([make_intent("i-1")]))
        self.assertIsInstance(batch, IntentBatch)

    def test_command_envelope_mapping(self):
        envelope = intent_to_command_envelope(
            parse_tactical_intent(make_intent(units=["Unit_1", "Unit_2"], generation=7)),
            match_id=MATCH, player_id=PLAYER, rules_version=RULES,
            command_id="cmd-1", request_id="req-1")
        self.assertEqual(envelope["op"], "adjutant_intent")
        self.assertEqual(envelope["generation"], 7)
        self.assertEqual(envelope["intent_id"], "i-1")
        self.assertEqual(envelope["params"]["units"], ["Unit_1", "Unit_2"])
        self.assertEqual(envelope["params"]["dest"], [10.0, 10.0])
        self.assertEqual(envelope["action"], "move")

    def test_command_envelope_for_attack_and_produce(self):
        attack = intent_to_command_envelope(
            parse_tactical_intent(make_intent(action="attack", target={"entity_id": "E_1"})),
            match_id=MATCH, player_id=PLAYER, rules_version=RULES,
            command_id="cmd-2", request_id="req-2")
        self.assertEqual(attack["params"]["target"], "E_1")
        produce = intent_to_command_envelope(
            parse_tactical_intent(make_intent(
                action="produce", target={"scene": SCENE_TANK, "producer": "Unit_9"})),
            match_id=MATCH, player_id=PLAYER, rules_version=RULES,
            command_id="cmd-3", request_id="req-3")
        self.assertEqual(produce["params"]["scene"], SCENE_TANK)
        self.assertEqual(produce["params"]["producer"], "Unit_9")

    def test_public_view_has_no_hidden_reasoning(self):
        view = intent_public_view(parse_tactical_intent(make_intent()))
        self.assertEqual(view["intent_id"], "i-1")
        self.assertNotIn("chain_of_thought", view)
        self.assertFalse(view["reacquire"])

    def test_reacquire_flag_reaches_command_envelope(self):
        raw = make_intent()
        raw["reacquire"] = True
        intent = parse_tactical_intent(raw)
        self.assertTrue(intent.reacquire)
        envelope = intent_to_command_envelope(
            intent, match_id=MATCH, player_id=PLAYER, rules_version=RULES,
            command_id="cmd-r", request_id="req-r")
        self.assertTrue(envelope["params"]["reacquire"])


class PlayerControlEventTest(unittest.TestCase):
    def test_event_kinds(self):
        event = parse_player_control_event({
            "kind": "player_release", "match_id": MATCH, "player_id": PLAYER,
            "unit_ids": ["Unit_1"], "server_tick": 10})
        self.assertEqual(event.kind, "player_release")
        with self.assertRaises(ContractError):
            parse_player_control_event({
                "kind": "player_teleport", "match_id": MATCH, "player_id": PLAYER,
                "unit_ids": ["Unit_1"]})
        with self.assertRaises(ContractError):
            parse_player_control_event({
                "kind": "player_override", "match_id": MATCH, "player_id": PLAYER,
                "unit_ids": []})


if __name__ == "__main__":
    unittest.main()
