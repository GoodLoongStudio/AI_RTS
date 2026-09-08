# -*- coding: utf-8 -*-
"""Provider 接口测试：上下文/结果结构、自检、Legacy 适配、脚本化假模型六种行为。"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.provider import (
    LegacyModelAdapter, ModelCallContext, ModelOutcome,
    OUTCOME_COMPLETED, OUTCOME_ERROR, OUTCOME_TIMEOUT,
    ROLE_STRATEGY, ROLE_TACTICS,
)
from adjutant_coordinator.fakes import (
    ScriptedStrategyProvider, ScriptedTacticsProvider, make_valid_plan,
)


def make_context(**overrides):
    fields = dict(
        request_id="req-1", role=ROLE_STRATEGY, match_id="m-1", player_id="Player_1",
        rules_version="hash-1", plan_version="plan-a:v1", snapshot_id=3,
        server_tick=100, issued_tick=100, deadline_tick=250,
        budget={"A": 500}, observation={"units": 4},
    )
    fields.update(overrides)
    return ModelCallContext(**fields)


class TestModelOutcome(unittest.TestCase):

    def test_valid_completed(self):
        outcome = ModelOutcome(status=OUTCOME_COMPLETED, role=ROLE_STRATEGY,
                               request_id="r", payload={"plan": True})
        self.assertEqual(outcome.validate(), [])

    def test_unknown_status_rejected_by_validate(self):
        outcome = ModelOutcome(status="mystery", role=ROLE_STRATEGY, request_id="r",
                               payload={})
        self.assertTrue(any("status" in e for e in outcome.validate()))

    def test_completed_without_payload_is_valid_empty_response(self):
        """空响应（completed+None）合法：由调度器按空业务路径处理。"""
        outcome = ModelOutcome(status=OUTCOME_COMPLETED, role=ROLE_TACTICS, request_id="r")
        self.assertEqual(outcome.validate(), [])

    def test_empty_request_id_invalid(self):
        outcome = ModelOutcome(status=OUTCOME_TIMEOUT, role=ROLE_TACTICS, request_id="")
        self.assertTrue(any("request_id" in e for e in outcome.validate()))

    def test_late_detection(self):
        outcome = ModelOutcome(status=OUTCOME_COMPLETED, role=ROLE_STRATEGY,
                               request_id="r", payload={}, available_at_tick=300)
        self.assertTrue(outcome.is_late_at(server_tick=100, deadline_tick=250))
        self.assertFalse(outcome.is_late_at(server_tick=300, deadline_tick=400))


class TestLegacyModelAdapter(unittest.TestCase):

    def test_dict_result_becomes_completed(self):
        class Legacy:
            def propose_plan(self, context):
                return make_valid_plan()
        outcome = LegacyModelAdapter(Legacy(), ROLE_STRATEGY).propose(make_context())
        self.assertEqual(outcome.status, OUTCOME_COMPLETED)
        self.assertEqual(outcome.payload["plan_id"], "plan-a")

    def test_none_result_becomes_empty_completed(self):
        class Legacy:
            def propose_plan(self, context):
                return None
        outcome = LegacyModelAdapter(Legacy(), ROLE_STRATEGY).propose(make_context())
        self.assertEqual(outcome.status, OUTCOME_COMPLETED)
        self.assertIsNone(outcome.payload)

    def test_exception_becomes_retryable_error(self):
        class Legacy:
            def propose_commands(self, context):
                raise RuntimeError("boom")
        outcome = LegacyModelAdapter(Legacy(), ROLE_TACTICS).propose(
            make_context(role=ROLE_TACTICS))
        self.assertEqual(outcome.status, OUTCOME_ERROR)
        self.assertTrue(outcome.retryable)
        self.assertIn("boom", outcome.reason)

    def test_context_fields_passed_through(self):
        seen = {}

        class Legacy:
            def propose_plan(self, context):
                seen.update(context)
                return None
        LegacyModelAdapter(Legacy(), ROLE_STRATEGY).propose(make_context())
        self.assertEqual(seen["match_id"], "m-1")
        self.assertEqual(seen["rules_version"], "hash-1")
        self.assertEqual(seen["budget"], {"A": 500})


class TestScriptedFakes(unittest.TestCase):

    def test_completed_plan(self):
        provider = ScriptedStrategyProvider([
            {"behavior": "completed", "plan": make_valid_plan(version=1)}])
        outcome = provider.propose(make_context())
        self.assertEqual(outcome.status, OUTCOME_COMPLETED)
        self.assertEqual(outcome.payload["plan_version"], 1)
        self.assertEqual(provider.call_count, 1)

    def test_timeout_behavior(self):
        provider = ScriptedStrategyProvider([{"behavior": "timeout"}])
        outcome = provider.propose(make_context())
        self.assertEqual(outcome.status, OUTCOME_TIMEOUT)

    def test_error_behavior(self):
        provider = ScriptedStrategyProvider([
            {"behavior": "error", "reason": "overloaded", "retryable": True}])
        outcome = provider.propose(make_context())
        self.assertEqual(outcome.status, OUTCOME_ERROR)
        self.assertTrue(outcome.retryable)

    def test_empty_behavior(self):
        provider = ScriptedTacticsProvider([{"behavior": "empty"}])
        outcome = provider.propose(make_context(role=ROLE_TACTICS))
        self.assertEqual(outcome.status, OUTCOME_COMPLETED)
        self.assertIsNone(outcome.payload)

    def test_malformed_behavior_keeps_invalid_payload(self):
        provider = ScriptedStrategyProvider([
            {"behavior": "malformed", "payload": {"bogus": 1}}])
        outcome = provider.propose(make_context())
        self.assertEqual(outcome.status, OUTCOME_COMPLETED)
        self.assertEqual(outcome.payload, {"bogus": 1})

    def test_late_behavior_carries_arrival_tick(self):
        provider = ScriptedStrategyProvider([
            {"behavior": "late", "arrives_at_tick": 900}])
        outcome = provider.propose(make_context())
        self.assertTrue(outcome.is_late_at(server_tick=100, deadline_tick=250))

    def test_raise_behavior_propagates(self):
        provider = ScriptedStrategyProvider([{"behavior": "raise"}])
        with self.assertRaises(RuntimeError):
            provider.propose(make_context())

    def test_cancelled_context_short_circuits(self):
        provider = ScriptedStrategyProvider([{"behavior": "completed",
                                              "plan": make_valid_plan()}])
        outcome = provider.propose(make_context(is_cancelled=lambda: True))
        self.assertIsNone(outcome.payload)

    def test_script_exhaustion_is_empty_response(self):
        provider = ScriptedTacticsProvider([])
        outcome = provider.propose(make_context(role=ROLE_TACTICS))
        self.assertEqual(outcome.status, OUTCOME_COMPLETED)
        self.assertIsNone(outcome.payload)


if __name__ == "__main__":
    unittest.main()
