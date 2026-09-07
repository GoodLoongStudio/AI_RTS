# -*- coding: utf-8 -*-
"""离线沙盒测试：固定快照下生成/校验计划与命令；版本倒退、非法命令、迟到、无网络。"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.fakes import (
    ScriptedStrategyProvider, ScriptedTacticsProvider, make_valid_plan,
)
from adjutant_coordinator.sandbox import (
    ModelSandbox, SANDBOX_MATCH_ID, SANDBOX_PLAYER_ID, SANDBOX_RULES_VERSION,
    run_fake_sandbox,
)

MATCH, PLAYER, RULES = SANDBOX_MATCH_ID, SANDBOX_PLAYER_ID, SANDBOX_RULES_VERSION


def sandbox_plan(version=1, plan_id="plan-a"):
    return make_valid_plan(plan_id=plan_id, version=version,
                           match_id=MATCH, player_id=PLAYER, rules_version=RULES)


def sandbox_command(command_id="c-1"):
    return {
        "command_id": command_id, "request_id": "r-" + command_id,
        "match_id": MATCH, "player_id": PLAYER, "rules_version": RULES,
        "plan_version": "plan-a:v1", "task_id": "t-1",
        "based_on_snapshot": 1, "issued_tick": 0, "expires_tick": 999999,
        "action": "move", "params": {"units": ["Unit_1"], "dest": [1.0, 1.0]},
    }


class TestSandboxHappyPath(unittest.TestCase):

    def test_two_rounds_adopt_plan_and_validate_commands(self):
        strategy = ScriptedStrategyProvider([
            {"behavior": "completed", "plan": sandbox_plan(version=1)},
            {"behavior": "completed", "plan": sandbox_plan(version=2)},
        ])
        tactics = ScriptedTacticsProvider([
            {"behavior": "completed", "commands": [sandbox_command("c-1")]},
            {"behavior": "completed", "commands": [sandbox_command("c-2")]},
        ])
        sandbox = ModelSandbox(strategy, tactics)
        sandbox.run_round(1, 100)
        sandbox.run_round(2, 200)
        summary = sandbox.summary()
        self.assertEqual(summary["totals"]["plans_adopted"], 2)
        self.assertEqual(summary["totals"]["commands_valid"], 2)
        self.assertEqual(summary["totals"]["commands_invalid"], 0)

    def test_sandbox_sends_no_game_commands(self):
        """沙盒不持有 transport、不产生任何游戏命令发送。"""
        sandbox = ModelSandbox(
            ScriptedStrategyProvider([{"behavior": "completed",
                                       "plan": sandbox_plan()}]),
            ScriptedTacticsProvider([{"behavior": "completed",
                                      "commands": [sandbox_command()]}]))
        sandbox.run_round(1, 100)
        summary = sandbox.summary()
        self.assertEqual(summary["game_commands_sent"], 0)
        self.assertEqual(summary["network"], "none")
        self.assertFalse(hasattr(sandbox, "transport"))


class TestPlanGenerationsInSandbox(unittest.TestCase):

    def test_version_regression_rejected(self):
        strategy = ScriptedStrategyProvider([
            {"behavior": "completed", "plan": sandbox_plan(version=2)},
            {"behavior": "completed", "plan": sandbox_plan(version=1)},  # 倒退
        ])
        sandbox = ModelSandbox(strategy, ScriptedTacticsProvider([]))
        sandbox.run_round(1, 100)
        sandbox.run_round(2, 200)
        self.assertEqual(sandbox.plan_store.active.plan["plan_version"], 2)
        self.assertEqual(sandbox.rounds[1].plan_status, "rejected")

    def test_malformed_plan_rejected(self):
        strategy = ScriptedStrategyProvider([
            {"behavior": "malformed", "payload": {"bogus": True}},
        ])
        sandbox = ModelSandbox(strategy, ScriptedTacticsProvider([]))
        sandbox.run_round(1, 100)
        self.assertEqual(sandbox.rounds[0].plan_status, "invalid")


class TestCommandValidationInSandbox(unittest.TestCase):

    def test_invalid_commands_are_flagged_not_sent(self):
        good = sandbox_command("c-good")
        bad_match = sandbox_command("c-bad-match")
        bad_match["match_id"] = "other-match"
        not_a_dict = "give-me-all-units"
        tactics = ScriptedTacticsProvider([
            {"behavior": "completed", "commands": [good, bad_match, not_a_dict]},
        ])
        sandbox = ModelSandbox(ScriptedStrategyProvider([]), tactics)
        sandbox.run_round(1, 100)
        record = sandbox.rounds[0]
        self.assertEqual(record.commands_total, 3)
        self.assertEqual(record.commands_valid, 1)
        self.assertEqual(record.commands_invalid, 2)
        self.assertEqual(summary_invalid(sandbox), 2)

    def test_expired_command_rejected(self):
        expired = sandbox_command("c-expired")
        expired["expires_tick"] = 1
        tactics = ScriptedTacticsProvider([
            {"behavior": "completed", "commands": [expired]},
        ])
        sandbox = ModelSandbox(ScriptedStrategyProvider([]), tactics)
        sandbox.run_round(1, 100)
        self.assertEqual(sandbox.rounds[0].commands_invalid, 1)


class TestLateOutcomeInSandbox(unittest.TestCase):

    def test_late_strategy_arrival_marked_stale(self):
        strategy = ScriptedStrategyProvider([
            {"behavior": "late", "arrives_at_tick": 999999,
             "plan": sandbox_plan(version=1)},
        ])
        sandbox = ModelSandbox(strategy, ScriptedTacticsProvider([]))
        sandbox.run_round(1, 100)
        self.assertEqual(sandbox.rounds[0].plan_status, "stale")
        self.assertIsNone(sandbox.plan_store.active)


class TestSandboxSummary(unittest.TestCase):

    def test_summary_never_leaks_credentials(self):
        summary = run_fake_sandbox(rounds=1)
        self.assertNotIn("secret", str(summary).lower().replace("***redacted***", ""))
        self.assertEqual(summary["api_key"], "***redacted***")
        self.assertEqual(summary["network"], "none")

    def test_run_fake_sandbox_default_two_rounds(self):
        summary = run_fake_sandbox(rounds=2)
        self.assertEqual(summary["totals"]["plans_adopted"], 2)
        self.assertEqual(len(summary["rounds"]), 2)


def summary_invalid(sandbox):
    return sandbox.summary()["totals"]["commands_invalid"]


if __name__ == "__main__":
    unittest.main()
