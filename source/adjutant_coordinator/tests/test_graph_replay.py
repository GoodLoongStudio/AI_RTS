# -*- coding: utf-8 -*-
"""JSONL 回放测试：敌袭 / 目标死亡 / 路径失败 / 玩家接管 / 模型超时。

每个场景使用独立 run_id 目录，产物（输入/状态/意图/回执/汇总）留痕；
不需要 API Key，不联网；汇总必须通过 results 重算自校验。
"""

import json
import os
import shutil
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph.graph import langgraph_available
from adjutant_coordinator.graph.replay import run_replay, verify_summary

FIXTURES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")
SCENARIOS = (
    "replay_base_attack.jsonl",
    "replay_target_dead.jsonl",
    "replay_path_failed.jsonl",
    "replay_player_takeover.jsonl",
    "replay_model_timeout.jsonl",
)


class ReplayScenarioTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="adjutant-replay-")
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.summaries = {}

    def run_fixture(self, name, engine="fallback"):
        run_id = "%s_%s_%d" % (name.replace(".jsonl", ""),
                               time.strftime("%Y%m%d_%H%M%S"), time.time_ns() % 1_000_000)
        summary = run_replay(os.path.join(FIXTURES_DIR, name), run_id,
                             engine=engine, run_root=self.root)
        self.summaries[name] = summary
        return summary

    def test_all_scenarios_pass(self):
        for name in SCENARIOS:
            with self.subTest(fixture=name):
                summary = self.run_fixture(name)
                failures = [item for item in summary["results"] if item["kind"] == "FAIL"]
                self.assertEqual(failures, [], "%s 断言失败：%s" % (name, failures))
                self.assertEqual(summary["FAIL"], 0)
                self.assertGreater(summary["PASS"], 0)
                # 汇总自校验（重算与顶层/counts 一致）。
                verify_summary(summary)
                run_dir = os.path.join(self.root, summary["run_id"])
                for artifact in ("inputs.jsonl", "states.jsonl", "intents.jsonl",
                                 "receipts.jsonl", "summary.json"):
                    self.assertTrue(os.path.exists(os.path.join(run_dir, artifact)),
                                    "%s 缺少产物 %s" % (name, artifact))

    def test_base_attack_dispatches_emergency_intent(self):
        summary = self.run_fixture("replay_base_attack.jsonl")
        self.assertGreaterEqual(summary["dispatch_total"], 1)
        self.assertEqual(summary["state"]["plan_version"], "plan-a:v1")
        self.assertEqual(summary["state"]["degraded_reason"], "")

    def test_player_takeover_keeps_plan_and_reacquires_after_release(self):
        summary = self.run_fixture("replay_player_takeover.jsonl")
        state = summary["state"]
        self.assertEqual(state["plan_version"], "plan-a:v1")
        self.assertEqual(state["player_controlled_units"], [])
        self.assertIn("i-move-3", state["live_intents"])
        # 被玩家接管的旧意图不得留在活跃集合里。
        self.assertNotIn("i-move-1", state["live_intents"])

    def test_path_failed_blocks_duplicate_order(self):
        summary = self.run_fixture("replay_path_failed.jsonl")
        reasons = [item["detail"] for item in summary["results"]
                   if item["item"].endswith("dropped[i-move-2]=duplicate_of_live_intent:i-move-1")]
        self.assertTrue(reasons, "缺少重复下单拦截断言")

    def test_model_timeout_degrades_then_recovers(self):
        summary = self.run_fixture("replay_model_timeout.jsonl")
        self.assertEqual(summary["state"]["degraded_reason"], "")
        self.assertIn("i-recover", summary["state"]["live_intents"])

    def test_receipts_are_recorded_with_command_id(self):
        summary = self.run_fixture("replay_base_attack.jsonl")
        run_dir = os.path.join(self.root, summary["run_id"])
        with open(os.path.join(run_dir, "receipts.jsonl"), "r", encoding="utf-8") as handle:
            lines = [json.loads(line) for line in handle if line.strip()]
        self.assertTrue(lines)
        self.assertEqual(lines[0]["receipt"]["status"], "Accepted")
        self.assertTrue(lines[0]["envelope"]["command_id"])
        self.assertEqual(lines[0]["envelope"]["op"], "adjutant_intent")


@unittest.skipUnless(langgraph_available()["available"],
                     "langgraph 未安装；LangGraph 引擎回放跳过")
class ReplayLangGraphTest(unittest.TestCase):
    def test_langgraph_engine_replay_matches_expectations(self):
        root = tempfile.mkdtemp(prefix="adjutant-replay-lg-")
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        for name in SCENARIOS:
            with self.subTest(fixture=name):
                summary = run_replay(os.path.join(FIXTURES_DIR, name),
                                     "%s_lg" % name.replace(".jsonl", ""),
                                     engine="langgraph", run_root=root)
                failures = [item for item in summary["results"] if item["kind"] == "FAIL"]
                self.assertEqual(failures, [], "%s(LangGraph) 断言失败：%s" % (name, failures))


if __name__ == "__main__":
    unittest.main()
