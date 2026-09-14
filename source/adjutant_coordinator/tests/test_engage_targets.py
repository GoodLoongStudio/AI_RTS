# -*- coding: utf-8 -*-
"""F02 / T04：交火目标按距离/威胁排序，数组顺序不决定战术；带滞回与火力分配。"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph import behavior_tree  # noqa: E402


def _entity(kind, name=None, unit_type=None, pos=(0, 0, 0), **extra):
    out = {"kind": kind, "pos": list(pos)}
    if name is not None:
        out["name"] = name
    if unit_type is not None:
        out["unit_type"] = unit_type
    out.update(extra)
    return out


class EngageTargetTest(unittest.TestCase):
    def test_nearest_not_list_first(self):
        """输入远敌在前、近敌在后 → 必须打近的（F02 旧口径会打 far_enemy）。"""
        state = {
            "server_tick": 1000, "latest_snapshot_id": 3,
            "ai_controlled_units": ["U_s1", "U_s2"],
            "player_controlled_units": [],
        }
        tac = {"entities": [
            _entity("unit_self", "U_s1", "soldier", pos=(10, 0, 10)),
            _entity("unit_self", "U_s2", "soldier", pos=(11, 0, 10)),
            _entity("unit_self", "U_cc", "command_center", pos=(0, 0, 0)),
            _entity("unit_enemy", "far_enemy", "soldier", pos=(100, 0, 100)),
            _entity("unit_enemy", "near_enemy", "soldier", pos=(12, 0, 10)),
        ]}
        intents = behavior_tree.micro_intents(state, tactical=tac)
        attacks = [item for item in intents if item["action"] == "attack"]
        self.assertTrue(attacks, "有可见敌人却没交火：%s" % intents)
        first = attacks[0]["target"]["entity_id"]
        self.assertEqual(first, "near_enemy",
                         "列表第一项是远敌，排序后必须打近敌，实际=%s" % first)

    def test_order_permutation_same_target(self):
        """T04：敌人顺序置换不改变选中的近威胁。"""
        state = {
            "server_tick": 1000, "latest_snapshot_id": 3,
            "ai_controlled_units": ["U_s1", "U_s2"],
            "player_controlled_units": [],
        }
        near = _entity("unit_enemy", "near_enemy", "soldier", pos=(12, 0, 10))
        far = _entity("unit_enemy", "far_enemy", "soldier", pos=(100, 0, 100))
        own = [
            _entity("unit_self", "U_s1", "soldier", pos=(10, 0, 10)),
            _entity("unit_self", "U_s2", "soldier", pos=(11, 0, 10)),
            _entity("unit_self", "U_cc", "command_center", pos=(0, 0, 0)),
        ]
        a = behavior_tree.micro_intents(state, tactical={"entities": own + [far, near]})
        b = behavior_tree.micro_intents(state, tactical={"entities": own + [near, far]})
        pick_a = [item["target"]["entity_id"] for item in a if item["action"] == "attack"]
        pick_b = [item["target"]["entity_id"] for item in b if item["action"] == "attack"]
        self.assertTrue(pick_a and pick_b)
        self.assertEqual(pick_a[0], pick_b[0])
        self.assertEqual(pick_a[0], "near_enemy")

    def test_capability_skips_air_for_soldier(self):
        """T04：可攻击与不可攻击域混合 → 士兵不打无人机。"""
        state = {
            "server_tick": 1000, "latest_snapshot_id": 3,
            "ai_controlled_units": ["U_s1", "U_s2"],
            "own_unit_types": {"U_s1": "soldier", "U_s2": "soldier"},
            "own_attack_domains": {"U_s1": ["terrain"], "U_s2": ["terrain"]},
        }
        tac = {"entities": [
            _entity("unit_self", "U_s1", "soldier", pos=(10, 0, 10),
                    attack_domains=["terrain"]),
            _entity("unit_self", "U_s2", "soldier", pos=(11, 0, 10),
                    attack_domains=["terrain"]),
            _entity("unit_enemy", "E_air", "drone", pos=(12, 0, 10), domain="air"),
            _entity("unit_enemy", "E_tank", "tank", pos=(20, 0, 10), domain="terrain"),
        ]}
        intents = behavior_tree.micro_intents(state, tactical=tac)
        attacks = [item["target"]["entity_id"] for item in intents
                   if item["action"] == "attack"]
        self.assertTrue(attacks)
        self.assertNotIn("E_air", attacks)
        self.assertIn("E_tank", attacks)

    def test_fire_allocation_and_stickiness(self):
        """两人不应全锁列表第一个敌人；已锁定目标在滞回内保持。"""
        state = {
            "server_tick": 1000, "latest_snapshot_id": 3,
            "ai_controlled_units": ["U_s1", "U_s2", "U_s3"],
            "player_controlled_units": [],
        }
        tac = {"entities": [
            _entity("unit_self", "U_s1", "soldier", pos=(10, 0, 10)),
            _entity("unit_self", "U_s2", "soldier", pos=(10.5, 0, 10)),
            _entity("unit_self", "U_s3", "soldier", pos=(11, 0, 10)),
            _entity("unit_enemy", "E_a", "soldier", pos=(13, 0, 10)),
            _entity("unit_enemy", "E_b", "soldier", pos=(14, 0, 10)),
        ]}
        first = behavior_tree.micro_intents(state, tactical=tac)
        attacks = {item["unit_ids"][0]: item["target"]["entity_id"]
                   for item in first if item["action"] == "attack"}
        self.assertGreaterEqual(len(set(attacks.values())), 2,
                                "火力必须拆开，不能全军锁同一个：%s" % attacks)
        second = behavior_tree.micro_intents(state, tactical=tac)
        again = {item["unit_ids"][0]: item["target"]["entity_id"]
                 for item in second if item["action"] == "attack"}
        self.assertEqual(attacks, again, "滞回失效，每轮换目标：%s → %s" % (attacks, again))


if __name__ == "__main__":
    unittest.main()
