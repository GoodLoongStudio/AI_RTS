# -*- coding: utf-8 -*-
"""协议校验测试：必填字段、身份/版本/过期、计划结构。"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.protocol import validate_command_envelope, validate_plan

CONTEXT = {
    "match_id": "m-1",
    "player_id": "Player_1",
    "rules_version": "hash-1",
    "current_tick": 1000,
    "latest_snapshot_id": 7,
}


def make_command(**overrides):
    command = {
        "command_id": "c-1",
        "request_id": "r-1",
        "match_id": "m-1",
        "player_id": "Player_1",
        "rules_version": "hash-1",
        "plan_version": "plan-a:v1",
        "task_id": "t-1",
        "based_on_snapshot": 5,
        "issued_tick": 900,
        "expires_tick": 2000,
        "action": "move",
        "params": {"units": ["Unit_1"], "dest": [1.0, 2.0]},
    }
    command.update(overrides)
    return command


def make_plan(**overrides):
    plan = {
        "plan_id": "plan-a",
        "plan_version": 1,
        "match_id": "m-1",
        "player_id": "Player_1",
        "rules_version": "hash-1",
        "based_on_snapshot": 5,
        "valid_until_tick": 5000,
        "phase_goal": "发展经济并建立第一支战斗编队",
        "tasks": [
            {"task_id": "t-1", "priority": 1, "completion": "工人 4 名",
             "allowed_actions": ["produce"]},
            {"task_id": "t-2", "priority": 2, "completion": "车辆工厂 1 座",
             "allowed_actions": ["build"]},
        ],
        "reserves": {"A": 800},
        "rationale": "开局发展优先",
    }
    plan.update(overrides)
    return plan


class TestCommandEnvelope(unittest.TestCase):

    def test_valid_command_passes(self):
        self.assertEqual(validate_command_envelope(make_command(), CONTEXT), [])

    def test_missing_required_fields(self):
        command = make_command()
        del command["command_id"]
        del command["expires_tick"]
        errors = validate_command_envelope(command, CONTEXT)
        self.assertTrue(any("command_id" in e for e in errors))
        self.assertTrue(any("expires_tick" in e for e in errors))

    def test_expired_command_rejected(self):
        errors = validate_command_envelope(make_command(expires_tick=999), CONTEXT)
        self.assertTrue(any("expires_tick" in e for e in errors))

    def test_wrong_match_id_rejected(self):
        errors = validate_command_envelope(make_command(match_id="other"), CONTEXT)
        self.assertTrue(any("match_id" in e for e in errors))

    def test_wrong_player_rejected(self):
        errors = validate_command_envelope(make_command(player_id="Player_2"), CONTEXT)
        self.assertTrue(any("player_id" in e for e in errors))

    def test_stale_rules_version_rejected(self):
        errors = validate_command_envelope(make_command(rules_version="old"), CONTEXT)
        self.assertTrue(any("rules_version" in e for e in errors))

    def test_future_snapshot_rejected(self):
        errors = validate_command_envelope(make_command(based_on_snapshot=99), CONTEXT)
        self.assertTrue(any("based_on_snapshot" in e for e in errors))


class TestPlanValidation(unittest.TestCase):

    def test_valid_plan_passes(self):
        self.assertEqual(validate_plan(make_plan(), CONTEXT), [])

    def test_duplicate_task_ids_rejected(self):
        plan = make_plan()
        plan["tasks"] = [
            {"task_id": "t-1", "priority": 1, "completion": "x"},
            {"task_id": "t-1", "priority": 2, "completion": "y"},
        ]
        errors = validate_plan(plan, CONTEXT)
        self.assertTrue(any("重复" in e for e in errors))

    def test_missing_phase_goal_rejected(self):
        plan = make_plan()
        del plan["phase_goal"]
        errors = validate_plan(plan, CONTEXT)
        self.assertTrue(any("phase_goal" in e for e in errors))


if __name__ == "__main__":
    unittest.main()
