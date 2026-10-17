# -*- coding: utf-8 -*-
"""规则降级计划：第一次采纳，第二次维持，不加大版本、不清在途任务。"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph.campaign import RULES_PLAN_ID, RulesSafeStrategy
from adjutant_coordinator.graph.nodes import (
    GraphServices, NodeContext, _finalize_strategy_result,
)


def _context(current=None):
    data = {
        "match_id": "match-rules",
        "player_id": "Player_1",
        "rules_version": "rules-v",
        "server_tick": 40,
        "snapshot_id": 2,
        "campaign": {"phase": "摸底", "frontier_name": "经济点火"},
    }
    if current is not None:
        data["current_plan"] = current
    return data


class RulesSafePlanTest(unittest.TestCase):
    def test_second_review_holds_without_bumping_version_or_clearing_tasks(self):
        agent = RulesSafeStrategy()
        first = agent.propose_plan(_context())
        self.assertEqual(first.plan_id, RULES_PLAN_ID)
        self.assertFalse(first.maintain_current)
        self.assertEqual(first.plan_version, 1)
        self.assertEqual(first.rationale, "rules_degraded_adopt")
        task_ids = [task.task_id for task in first.tasks]
        self.assertEqual(task_ids, ["rules-economy", "rules-defense", "rules-recon"])
        for task in first.tasks:
            self.assertEqual(list(task.units), [])

        state = {
            "match_id": "match-rules",
            "player_id": "Player_1",
            "rules_version": "rules-v",
            "server_tick": 40,
            "latest_snapshot_id": 2,
            "active_plan": None,
            "plan_version": "",
            "plan_adopt_generation": 0,
            "active_tasks": {"live-gather": "running"},
            "active_intents": [{
                "intent_id": "gather-1",
                "action": "gather",
                "state": "active",
                "unit_ids": ["Unit_3"],
            }],
            "decision_log": [],
        }
        ctx = NodeContext(services=GraphServices(), observation={}, tick=40)
        _finalize_strategy_result(state, ctx, first, 40, None)
        self.assertEqual(state["plan_version"], "rules-mainline-default:v1")
        self.assertEqual(state["plan_adopt_generation"], 1)
        self.assertEqual(state["active_tasks"]["rules-economy"], "pending")
        self.assertEqual(state["active_tasks"]["live-gather"], "running")
        version = state["plan_version"]
        generation = state["plan_adopt_generation"]
        tasks = dict(state["active_tasks"])
        intents = list(state["active_intents"])

        second = agent.propose_plan(_context(state["active_plan"]))
        self.assertTrue(second.maintain_current)
        self.assertEqual(second.tasks, [])
        self.assertEqual(second.plan_version, 1)
        self.assertEqual(second.rationale, "rules_degraded_hold")
        state["server_tick"] = 240
        _finalize_strategy_result(state, ctx, second, 240, None)
        self.assertEqual(state["plan_version"], version)
        self.assertEqual(state["plan_adopt_generation"], generation)
        self.assertEqual(state["active_tasks"], tasks)
        self.assertEqual(state["active_intents"], intents)
        self.assertEqual(state["plan_hold_count"], 1)
        holds = [item for item in state["decision_log"] if item.get("kind") == "plan_hold"]
        self.assertEqual(len(holds), 1)
        self.assertEqual(holds[0]["reason"], "rules_degraded_hold")
        self.assertEqual(holds[0]["plan_version"], version)


if __name__ == "__main__":
    unittest.main()
