# -*- coding: utf-8 -*-
"""Hermes 技能 v5 闭环脚本单元测试（游戏 TCP 与模型全部 mock，零网络零游戏命令）。

覆盖：计划采纳/版本递增拒绝、命令包络完整性与回执落盘、旧 op 禁用、
截断/失败不提交、战术命令统计。
"""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

_SKILL_CANDIDATES = (
    Path(r"G:\AIRTS\临时文件夹\hermes_skill\ai-rts-commander\scripts"),
    Path("/home/ubuntu/.hermes/skills/games/ai-rts-commander/scripts"))
SKILL_SCRIPTS = next(p for p in _SKILL_CANDIDATES if (p / "rts_common.py").exists())
REPO_SOURCE = Path(__file__).resolve().parents[2]


def _load(name):
    spec = importlib.util.spec_from_file_location(
        name, SKILL_SCRIPTS / ("%s.py" % name))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class _FakeOutcome:
    def __init__(self, status, payload, reason=""):
        self.status = status
        self.payload = payload
        self.reason = reason


class _FakeProvider:
    def __init__(self, outcome):
        self._outcome = outcome
        self.calls = []

    def propose(self, context):
        self.calls.append(context)
        return self._outcome


class RtsSkillTest(unittest.TestCase):

    def setUp(self):
        sys.path.insert(0, str(REPO_SOURCE))
        self._tmp = tempfile.TemporaryDirectory()
        self.common = _load("rts_common")
        # 技能状态全部重定向到临时目录（不污染真实技能目录）
        self.common.SCRIPT_DIR = Path(self._tmp.name)
        self.common.STATE_DIR = self.common.SCRIPT_DIR
        self.common.PLAN_PATH = self.common.SCRIPT_DIR / "plan.json"
        self.common.PLAN_HISTORY = self.common.SCRIPT_DIR / "plan_history.jsonl"
        self.common.RECEIPTS_PATH = self.common.SCRIPT_DIR / "receipts.jsonl"
        self.common.SEEN_PATH = self.common.SCRIPT_DIR / "seen_cells.json"
        self._orig_call_tcp = self.common.call_tcp
        self.wire = []

    def tearDown(self):
        self.common.call_tcp = self._orig_call_tcp
        self._tmp.cleanup()

    # ---- 常量与工具 ----

    def test_forbidden_ops_declared(self):
        for op in ("move", "gather", "build", "produce", "attack", "stop", "start"):
            self.assertIn(op, self.common.FORBIDDEN_OPS)

    def test_snapshot_context_rejects_missing_fields(self):
        with self.assertRaises(ValueError):
            self.common.snapshot_context({"match_id": "m"})

    def test_snapshot_context_hash_form(self):
        context = self.common.snapshot_context({
            "match_id": "m", "rules_version": {"content_hash": "abc12345"},
            "snapshot_id": 3, "server_tick": 900})
        self.assertEqual(context["rules_version"], "abc12345")
        self.assertEqual(context["snapshot_id"], 3)

    # ---- 计划采纳 ----

    def _context(self):
        return {"match_id": "match-1", "player_id": "Player_0",
                "rules_version": "hash1234", "snapshot_id": 5, "server_tick": 1000}

    def test_adopt_plan_first_version(self):
        plan, error = self.common.adopt_plan({
            "plan_version": 1, "phase_goal": "发展经济",
            "valid_until_tick": 4600,
            "tasks": [{"kind": "gather", "description": "采集A", "params_hint": {}}]},
            self._context())
        self.assertIsNone(error)
        self.assertEqual(plan["plan_version"], 1)
        self.assertEqual(plan["tasks"][0]["task_id"], "t1")
        self.assertEqual(json.loads(self.common.PLAN_PATH.read_text(encoding="utf-8")),
                         plan)

    def test_adopt_plan_rejects_regression(self):
        self.common.adopt_plan({"plan_version": 2, "phase_goal": "g",
                                "tasks": [{"kind": "gather"}]}, self._context())
        _, error = self.common.adopt_plan({"plan_version": 1, "phase_goal": "g",
                                           "tasks": [{"kind": "gather"}]},
                                          self._context())
        self.assertIn("倒退", error)
        # 真倒退时现有计划必须保持不变
        self.assertEqual(self.common.read_plan()["plan_version"], 2)

    def test_adopt_plan_same_version_auto_increments(self):
        # 模型输出与当前同版本：按"采纳新计划"意图自动递增，不再拒绝
        self.common.adopt_plan({"plan_version": 3, "phase_goal": "g",
                                "tasks": [{"kind": "gather"}]}, self._context())
        plan, error = self.common.adopt_plan({"plan_version": 3, "phase_goal": "g2",
                                              "tasks": [{"kind": "explore"}]},
                                             self._context())
        self.assertIsNone(error)
        self.assertEqual(plan["plan_version"], 4)

    def test_adopt_plan_invalid_version_falls_forward(self):
        plan, error = self.common.adopt_plan({"plan_version": "abc", "phase_goal": "g",
                                              "tasks": [{"kind": "gather"}]},
                                             self._context())
        self.assertIsNone(error)
        self.assertEqual(plan["plan_version"], 1)

    def test_adopt_plan_rejects_bad_tasks(self):
        _, error = self.common.adopt_plan({"plan_version": 1, "phase_goal": "g",
                                           "tasks": []}, self._context())
        self.assertIn("tasks", error)

    # ---- 命令包络 ----

    def test_send_command_envelope_and_receipt(self):
        captured = {}

        def fake_call(port, payload, timeout=25.0):
            captured["port"] = port
            captured["payload"] = payload
            return {"accepted": True, "status": "Accepted", "command_id": "srv-1"}

        self.common.call_tcp = fake_call
        snapshot = {"match_id": "match-1", "rules_version": {"content_hash": "hash1234"},
                    "snapshot_id": 7, "server_tick": 2000}
        receipt = self.common.send_command("move", {"units": ["Worker1"], "dest": [10, 10]},
                                           "t1", snapshot, "Player_0", "2")
        self.assertTrue(receipt["accepted"])
        self.assertEqual(captured["port"], self.common.SERVER_TCP)
        payload = captured["payload"]
        self.assertEqual(payload["op"], "adjutant_command")
        for field in ("command_id", "request_id", "match_id", "player_id",
                      "rules_version", "plan_version", "task_id",
                      "based_on_snapshot", "issued_tick", "expires_tick",
                      "action", "params"):
            self.assertIn(field, payload)
        self.assertEqual(payload["rules_version"], "hash1234")
        self.assertEqual(payload["expires_tick"], 2000 + self.common.EXPIRY_TICKS)
        records = [json.loads(line) for line in
                   self.common.RECEIPTS_PATH.read_text(encoding="utf-8").splitlines()]
        self.assertEqual(len(records), 1)
        self.assertTrue(records[0]["accepted"])

    def test_send_command_failure_recorded(self):
        self.common.call_tcp = lambda port, payload, timeout=25.0: {
            "accepted": False, "status": "QueueFull", "reason": "生产队列已满"}
        snapshot = {"match_id": "m", "rules_version": "h", "snapshot_id": 1,
                    "server_tick": 10}
        receipt = self.common.send_command("produce", {"unit": "V1", "scene": "s"},
                                           "t2", snapshot, "Player_0")
        self.assertFalse(receipt["accepted"])
        record = json.loads(self.common.RECEIPTS_PATH.read_text(
            encoding="utf-8").splitlines()[-1])
        self.assertEqual(record["status"], "QueueFull")

    # ---- 覆盖率 ----

    def test_update_coverage_grid(self):
        seen = set()
        rules = {"unit_types": [{"id": "worker", "sight_range": 8}]}
        entities = [{"kind": "unit_self", "unit_type": "worker", "hp": 6,
                     "constructed": True, "pos": [5.0, 0, 5.0]}]
        coverage, seen = self.common.update_coverage(
            entities, {"worker": 8}, [50.0, 50.0], seen)
        self.assertGreater(coverage, 0.01)
        self.assertIn((5, 5), seen)
        # 死亡单位不贡献视野
        _, seen2 = self.common.update_coverage(
            [{"kind": "unit_self", "unit_type": "worker", "hp": 0, "pos": [5, 0, 5]}],
            {"worker": 8}, [50.0, 50.0], set())
        self.assertEqual(len(seen2), 0)

    # ---- rts_ctl：旧 op 禁用 ----

    def test_rts_ctl_rejects_legacy_ops(self):
        ctl = _load("rts_ctl")
        sent = []

        def fake_observe(op, **params):
            sent.append(op)
            return {}

        self.common.observe = fake_observe
        ctl.observe = fake_observe
        for op in ("move", "gather", "build", "start"):
            argv = [op]
            old_argv = sys.argv
            sys.argv = ["rts_ctl.py"] + argv
            try:
                code = ctl.main()
            finally:
                sys.argv = old_argv
            self.assertEqual(code, 2, "旧 op %s 必须被拒绝" % op)
        self.assertEqual(sent, [], "被拒绝的 op 不得发出任何请求")

    def test_rts_ctl_observe_whitelist(self):
        ctl = _load("rts_ctl")
        sent = []
        self.common.observe = lambda op, **params: (sent.append(op) or {
            "players": [{"name": "Player_0", "human": True}]})
        ctl.observe = self.common.observe
        old_argv = sys.argv
        sys.argv = ["rts_ctl.py", "status"]
        try:
            code = ctl.main()
        finally:
            sys.argv = old_argv
        self.assertEqual(code, 0)
        self.assertEqual(sent, ["status"])

    # ---- rts_act：模型输出 → 包络命令 ----

    def _patch_act(self, act, provider):
        act.load_provider = lambda role, instruction, max_tokens=800, effort="low": (
            provider, type("C", (), {"calls": []})())
        act.observe = lambda op, **params: {
            "rules": {"match_id": "m", "rules_version": {"content_hash": "h"},
                      "snapshot_id": 1, "server_tick": 500,
                      "unit_types": [], "productions": [], "constructions": []},
            "tactical": {"match_id": "m", "rules_version": {"content_hash": "h"},
                         "snapshot_id": 2, "server_tick": 520, "entities": []},
            "strategic": {"match_id": "m", "rules_version": {"content_hash": "h"},
                          "snapshot_id": 3, "server_tick": 520, "map_bounds": [50, 50]},
        }[op]
        act.resolve_player = lambda: "Player_0"
        act.read_plan = lambda: {"plan_version": 2, "phase_goal": "g", "tasks": []}
        sent = []

        def fake_send(action, params, task_id, snapshot, player_id, plan_version="1"):
            sent.append({"action": action, "params": params, "task_id": task_id,
                         "plan_version": plan_version})
            return {"accepted": True, "status": "Accepted"}

        act.send_command = fake_send
        return sent

    def test_rts_act_sends_envelope_commands(self):
        act = _load("rts_act")
        provider = _FakeProvider(_FakeOutcome("completed", {"commands": [
            {"task_id": "t1", "action": "move", "units": ["Worker1"], "dest": [10, 10]},
            {"task_id": "t2", "action": "gather", "units": ["Worker2"], "kind": "a"},
        ]}))
        sent = self._patch_act(act, provider)
        old_argv = sys.argv
        sys.argv = ["rts_act.py"]
        try:
            code = act.main()
        finally:
            sys.argv = old_argv
        self.assertEqual(code, 0)
        self.assertEqual(len(sent), 2)
        self.assertEqual(sent[0]["plan_version"], "2")
        self.assertEqual(sent[1]["action"], "gather")

    def test_rts_act_failure_keeps_no_submission(self):
        act = _load("rts_act")
        provider = _FakeProvider(_FakeOutcome("timeout", None, "timeout"))
        sent = self._patch_act(act, provider)
        old_argv = sys.argv
        sys.argv = ["rts_act.py"]
        try:
            code = act.main()
        finally:
            sys.argv = old_argv
        self.assertEqual(code, 1)
        self.assertEqual(sent, [], "模型失败时不得提交任何命令")

    def test_rts_act_rejects_stale_snapshot(self):
        act = _load("rts_act")
        provider = _FakeProvider(_FakeOutcome("completed", {"commands": [
            {"task_id": "t1", "action": "move", "units": ["Worker1"],
             "dest": [10, 10]}]}))
        self._patch_act(act, provider)
        # 注入基于未来快照的非法命令 → 本地包络校验必须拒绝
        real_validate = act.validate_command_envelope
        captured = {}

        def spy(command, context):
            captured["based_on"] = command["based_on_snapshot"]
            return real_validate(command, context)

        act.validate_command_envelope = spy
        old_argv = sys.argv
        sys.argv = ["rts_act.py"]
        try:
            act.main()
        finally:
            sys.argv = old_argv
        self.assertLessEqual(captured["based_on"], 520)

    # ---- rts_plan：失败保留现有计划 ----

    def test_rts_plan_failure_keeps_plan(self):
        plan_mod = _load("rts_plan")
        self.common.adopt_plan({
            "plan_version": 3, "phase_goal": "keep",
            "tasks": [{"kind": "gather"}]}, self._context())
        plan_mod.adopt_plan = self.common.adopt_plan
        plan_mod.observe = lambda op, **params: {
            "strategic": {"match_id": "m", "rules_version": {"content_hash": "h"},
                          "snapshot_id": 1, "server_tick": 700, "map_bounds": [50, 50]},
            "rules": {"unit_types": [], "productions": [], "constructions": []},
            "tactical": {"match_id": "m", "rules_version": {"content_hash": "h"},
                         "snapshot_id": 1, "server_tick": 700, "entities": []},
        }[op]
        plan_mod.resolve_player = lambda: "Player_0"
        plan_mod.load_provider = lambda role, instruction, max_tokens=800, effort="low": (
            _FakeProvider(_FakeOutcome("error", None, "http 500")),
            type("C", (), {"calls": []})())
        old_argv = sys.argv
        sys.argv = ["rts_plan.py"]
        try:
            code = plan_mod.main()
        finally:
            sys.argv = old_argv
        self.assertEqual(code, 1)
        self.assertEqual(self.common.read_plan()["plan_version"], 3)


if __name__ == "__main__":
    unittest.main()
