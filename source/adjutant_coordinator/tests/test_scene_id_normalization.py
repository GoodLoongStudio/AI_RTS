# -*- coding: utf-8 -*-
"""回归：模型按提示词用产品/建造 id 填 target.scene 时，必须被归一化为场景路径。

背景（2026-09-10 实战实测）：
`build_tactics_context` 的提示词写着"produce 的 target.scene 用产品类型 id"，
而仲裁的受信任集合 `rules_scene_paths()` 只含 `res://...tscn` 路径，
于是模型照提示词填 "worker" 时必然被判 `scene_not_in_rules:worker` 丢弃
（实测副官侦察/生产意图整批被拒，单位只会移动不会造兵）。

修复：`rules_scene_index()` 提供 id → 场景路径映射，`node_arbitrate_intent`
在仲裁前把 id 归一化成路径。本测试锁住"归一化后能通过、非法引用仍被拒"。
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph.model_context import (  # noqa: E402
    rules_scene_index, rules_scene_paths, validate_intent_references,
)

WORKER_SCENE = "res://source/match/units/Worker.tscn"
BARRACKS_SCENE = "res://source/match/units/Barracks.tscn"

RULES = {
    "unit_types": [
        {"id": "worker", "scene_path": WORKER_SCENE},
        {"id": "barracks", "scene_path": BARRACKS_SCENE},
    ],
    "constructions": [
        {"id": "barracks", "blueprint_scene_path": BARRACKS_SCENE},
    ],
}


class SceneIndexTest(unittest.TestCase):
    def test_index_maps_ids_to_scene_paths(self):
        index = rules_scene_index(RULES)
        self.assertEqual(index["worker"], WORKER_SCENE)
        self.assertEqual(index["barracks"], BARRACKS_SCENE)

    def test_index_uses_setdefault_so_unit_type_wins(self):
        rules = {
            "unit_types": [{"id": "dup", "scene_path": "res://unit.tscn"}],
            "constructions": [{"id": "dup", "blueprint_scene_path": "res://build.tscn"}],
        }
        self.assertEqual(rules_scene_index(rules)["dup"], "res://unit.tscn")

    def test_trusted_paths_stay_paths_only(self):
        # 校验集合保持纯路径：id 只在归一化之后进入，避免放宽校验口径。
        self.assertNotIn("worker", rules_scene_paths(RULES))

    def test_unknown_scene_still_rejected(self):
        problems = validate_intent_references(
            [{"intent_id": "i-x", "action": "produce",
              "target": {"scene": "res://evil/factory.tscn", "producer": "Unit_1"}}],
            known_entities={"Unit_1"}, scene_paths=rules_scene_paths(RULES))
        self.assertEqual(problems[0][1],
                         "scene_not_in_rules:res://evil/factory.tscn")

    def test_normalized_id_passes_validation(self):
        intent = {"intent_id": "i-ok", "action": "produce",
                  "target": {"scene": "worker", "producer": "Unit_1"}}
        index = rules_scene_index(RULES)
        intent["target"]["scene"] = index[intent["target"]["scene"]]
        problems = validate_intent_references(
            [intent], known_entities={"Unit_1"}, scene_paths=rules_scene_paths(RULES))
        self.assertEqual(problems, [])

    def test_missing_rules_give_empty_index(self):
        self.assertEqual(rules_scene_index({"error": "no match scene"}), {})
        self.assertEqual(rules_scene_index(None), {})


if __name__ == "__main__":
    unittest.main()
