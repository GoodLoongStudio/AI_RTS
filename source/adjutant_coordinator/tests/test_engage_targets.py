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


class StructureFirePriorityTest(unittest.TestCase):
    """建筑攻坚目标优先级（2026-09-22；参谋阶段 A"能打到的生产建筑/反地炮塔优先"）。

    实测依据（base_off_5，240s 纯规则局）：53 个作战单位打 9 个仍超时 ——
    反地炮塔 2.0 伤/16m 而我方步兵 0.5 伤/6m，单位在"打最近的敌兵"时被塔白嫖；
    敌人步兵恒定 6-7（生产建筑没被拆），炮塔 130 秒只磨掉 10.5/16 血。
    """

    def _pick(self, enemies, unit_pos=(0.0, 0.0)):
        from adjutant_coordinator.graph import rules_fallback as rf
        return rf.pick_engage_target({}, "U1", enemies, list(unit_pos),
                                     combat_types=("soldier",))

    def test_turret_beats_nearer_soldier(self):
        """炮塔比更近的敌兵优先（不先拆塔，冲锋全程白给）。"""
        enemies = [
            {"kind": "unit_enemy", "name": "E_turret", "unit_type": "anti_ground_turret",
             "pos": [20.0, 0, 0.0], "hp": 16.0, "hp_max": 16.0},
            {"kind": "unit_enemy", "name": "E_soldier", "unit_type": "soldier",
             "pos": [10.0, 0, 0.0], "hp": 4.0, "hp_max": 4.0},
        ]
        self.assertEqual(self._pick(enemies), "E_turret")

    def test_production_beats_command_center(self):
        """生产建筑比指挥中心优先（不拆产能，敌人补兵永无止境）。"""
        enemies = [
            {"kind": "unit_enemy", "name": "E_cc", "unit_type": "command_center",
             "pos": [10.0, 0, 0.0], "hp": 100.0, "hp_max": 100.0},
            {"kind": "unit_enemy", "name": "E_barracks", "unit_type": "barracks",
             "pos": [14.0, 0, 0.0], "hp": 28.0, "hp_max": 28.0},
        ]
        self.assertEqual(self._pick(enemies), "E_barracks")

    def test_focus_fire_up_to_cap_then_switch(self):
        """【2026-09-22 D11 集火】未达上限应集火同一目标，达到上限必须换目标。

        旧值 FIRE_SOFT_CAP=1 是"一敌一锁"的反集火：实测 det_16 我方 45 个作战
        单位、140 秒只对 5 座建筑各造成 3.5 伤害（合计 17.5），三轮零摧毁。
        """
        enemies = [
            {"kind": "unit_enemy", "name": "A", "unit_type": "anti_ground_turret",
             "pos": [20.0, 0, 0.0], "hp": 16.0, "hp_max": 16.0},
            {"kind": "unit_enemy", "name": "B", "unit_type": "barracks",
             "pos": [22.0, 0, 0.0], "hp": 28.0, "hp_max": 28.0},
        ]
        from adjutant_coordinator.graph import rules_fallback as rf
        few = {"engage_locks": {"U%d" % i: "A" for i in range(2)}}
        self.assertEqual(
            rf.pick_engage_target(few, "U99", enemies, [0.0, 0.0],
                                  combat_types=("soldier",)), "A",
            "未达集火上限时应继续打同一个目标")
        full = {"engage_locks": {"U%d" % i: "A"
                                 for i in range(rf.STRUCTURE_FIRE_CAP)}}
        self.assertEqual(
            rf.pick_engage_target(full, "U99", enemies, [0.0, 0.0],
                                  combat_types=("soldier",)), "B",
            "达到集火上限后必须换目标（防无意义过杀）")

    def test_mobile_targets_still_split_fire(self):
        """对照组：移动目标仍是"一敌一锁"（既有口径，守门测试同款）——
        集火只对静态建筑生效，追兵堆人多是浪费。"""
        from adjutant_coordinator.graph import rules_fallback as rf
        enemies = [
            {"kind": "unit_enemy", "name": "A", "unit_type": "soldier",
             "pos": [20.0, 0, 0.0], "hp": 4.0, "hp_max": 4.0},
            {"kind": "unit_enemy", "name": "B", "unit_type": "soldier",
             "pos": [22.0, 0, 0.0], "hp": 4.0, "hp_max": 4.0},
        ]
        one = {"engage_locks": {"U0": "A"}}
        self.assertEqual(
            rf.pick_engage_target(one, "U99", enemies, [0.0, 0.0],
                                  combat_types=("soldier",)), "B",
            "移动目标有一个锁就该换人（不许全军追一个兵）")

    def test_mobile_only_still_picks_by_distance(self):
        """没有建筑时回归距离/威胁口径（别把"打建筑"变成"永远不打兵"）。"""
        enemies = [
            {"kind": "unit_enemy", "name": "E_far", "unit_type": "soldier",
             "pos": [30.0, 0, 0.0], "hp": 4.0, "hp_max": 4.0},
            {"kind": "unit_enemy", "name": "E_near", "unit_type": "soldier",
             "pos": [8.0, 0, 0.0], "hp": 4.0, "hp_max": 4.0},
        ]
        self.assertEqual(self._pick(enemies), "E_near")


if __name__ == "__main__":
    unittest.main()
