# -*- coding: utf-8 -*-
"""规则兜底的防退化测试。

背景：本地模型链路任一环抖动都会让单轮卡满超时、部队全部空转。
兜底必须做到两件事：① 不抢模型的目标推理（只做事实可判定的事）；
② 产出的意图**必须能通过契约校验**，否则等于没兜底。
"""
import unittest

from adjutant_coordinator.graph import rules_fallback
from adjutant_coordinator.graph.contracts import parse_intent_batch

TACTICAL = {
    "entities": [
        {"kind": "unit_self", "name": "Unit_0", "unit_type": "command_center",
         "pos": [10.0, 0.0, 7.0], "queue": True, "movement": False},
        {"kind": "unit_self", "name": "Unit_2", "unit_type": "worker",
         "pos": [10.0, 0.0, 10.0], "gather": True, "construct": True, "movement": True},
        {"kind": "unit_self", "name": "Unit_3", "unit_type": "worker",
         "pos": [12.0, 0.0, 12.0], "gather": True, "construct": True, "movement": True},
        {"kind": "resource", "name": "Res_A", "pos": [40.0, 0.0, 2.0]},
        {"kind": "resource", "name": "Res_B", "pos": [12.5, 0.0, 12.5]},
    ]
}

RULES = {
    "unit_types": [
        {"id": "worker", "scene_path": "res://source/match/units/Worker.tscn"},
        {"id": "command_center",
         "scene_path": "res://source/match/units/CommandCenter.tscn"},
    ],
    "productions": [
        {"product_type_id": "worker",
         "allowed_producer_type_ids": ["command_center"]},
    ],
}


def _state(units=("Unit_0", "Unit_2", "Unit_3"), active=None, pending=None):
    return {
        "ai_controlled_units": list(units),
        "active_intents": list(active or []),
        "pending_requests": dict(pending or {}),
        "server_tick": 1000,
        "latest_snapshot_id": 10,
    }


def _batch(state, tactical=TACTICAL, rules=RULES):
    batch = rules_fallback.batch_from_rules(
        state, tactical=tactical, rules=rules, ttl_ticks=3600,
        server_tick=1000, snapshot_id=10)
    batch.update({"match_id": "m", "player_id": "Player_0", "plan_version": "p:1"})
    return batch


class FallbackTest(unittest.TestCase):

    def test_idle_workers_gather_nearest_resource(self):
        batch = _batch(_state())
        gather = {i["unit_ids"][0]: i for i in batch["intents"] if i["action"] == "gather"}
        self.assertEqual(set(gather), {"Unit_2", "Unit_3"})
        # Unit_3 在 (12,12)，Res_B 在 (12.5,12.5) 明显更近。
        self.assertEqual(gather["Unit_3"]["target"]["entity_id"], "Res_B")
        self.assertEqual(gather["Unit_2"]["target"]["entity_id"], "Res_B")

    def test_busy_units_are_never_stolen(self):
        state = _state(active=[{"intent_id": "live", "state": "active",
                                "unit_ids": ["Unit_3"]}])
        batch = _batch(state)
        for intent in batch["intents"]:
            self.assertNotIn("Unit_3", intent["unit_ids"])

    def test_producer_trains_worker_with_scene_path(self):
        batch = _batch(_state())
        produce = [i for i in batch["intents"] if i["action"] == "produce"]
        self.assertEqual(len(produce), 1)
        target = produce[0]["target"]
        # 契约要求 scene 是规则视图里的场景**路径**（权威端 load() 用它）。
        self.assertTrue(target["scene"].startswith("res://"))
        self.assertEqual(target["producer"], "Unit_0")

    def test_worker_sufficient_skips_training(self):
        # 工人数量以**观测**为准：观测里必须有 `WORKER_TARGET_6` 个 worker 才判定"够用"。
        # 【2026-09-12 晚改】目标从 4 提到 6（对齐传统 AI `workers_per_command_center`），
        # 所以这里必须给到 6 个 —— 否则测的就不是"够用后停手"，而是"还没够"。
        tactical = {"entities": TACTICAL["entities"] + [
            {"kind": "unit_self", "name": "Unit_%d" % index, "unit_type": "worker",
             "pos": [11.0 - index, 0.0, 11.0], "gather": True, "movement": True}
            for index in range(6, 10)
        ]}
        state = _state(units=("Unit_0", "Unit_2", "Unit_3", "Unit_6", "Unit_7",
                              "Unit_8", "Unit_9"))
        batch = _batch(state, tactical=tactical)
        # `MAX_GATHER_INTENTS` 同步提到 8（工人目标 6/基地后，4 条配额会让第 5 个
        # 以后的工人长期没有采集意图）→ 6 个工人应全部拿到采集命令。
        self.assertEqual(len([i for i in batch["intents"] if i["action"] == "gather"]), 6)
        self.assertFalse([i for i in batch["intents"] if i["action"] == "produce"])

    def test_no_resource_yields_no_intents(self):
        # 无资源可采集时不下发任何命令：hold 等价于"原地不动"，下发只会
        # 因模型耗时被拖过期、产生拒绝噪音。
        empty = {"entities": [e for e in TACTICAL["entities"]
                              if e["kind"] != "resource"]}
        batch = _batch(_state(), tactical=empty, rules={"productions": []})
        self.assertEqual(batch["intents"], [])

    def test_output_passes_contract(self):
        """兜底产出必须能通过契约校验，否则等于没兜底。"""
        parsed = parse_intent_batch(_batch(_state()))
        self.assertTrue(parsed.intents)
        actions = {i.action for i in parsed.intents}
        self.assertTrue(actions <= {"gather", "produce"})


if __name__ == "__main__":
    unittest.main()
