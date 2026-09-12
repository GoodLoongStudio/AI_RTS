# -*- coding: utf-8 -*-
"""发展阶梯测试（决策手册 BLD-01）。

背景：实测副官"只会采集、不发展" —— `rules_fallback` 只在模型失败时触发，
而 2B 模型是"成功但只回 gather"。因此需要一条**确定性阶梯**，
在模型整批无发展动作时补上骨架。
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph import rules_fallback as rf

RULES = {
    "unit_types": [
        {"id": "worker", "scene_path": "res://units/Worker.tscn"},
        {"id": "soldier", "scene_path": "res://units/Soldier.tscn"},
        {"id": "tank", "scene_path": "res://units/Tank.tscn"},
        {"id": "barracks", "scene_path": "res://buildings/Barracks.tscn"},
        {"id": "vehicle_factory", "scene_path": "res://buildings/VehicleFactory.tscn"},
        {"id": "command_center", "scene_path": "res://buildings/CommandCenter.tscn"},
    ],
    "constructions": [
        {"id": "barracks", "blueprint_scene_path": "res://buildings/Barracks.tscn"},
        {"id": "vehicle_factory",
         "blueprint_scene_path": "res://buildings/VehicleFactory.tscn"},
    ],
    "productions": [
        {"product_type_id": "worker", "allowed_producer_type_ids": ["command_center"]},
        {"product_type_id": "soldier", "allowed_producer_type_ids": ["barracks"]},
        {"product_type_id": "tank", "allowed_producer_type_ids": ["vehicle_factory"]},
    ],
}


def unit(name, utype, *, construct=False, gather=False, queue=False, pos=(0, 0, 0)):
    return {"kind": "unit_self", "name": name, "unit_type": utype,
            "construct": construct, "gather": gather, "queue": queue, "pos": list(pos)}


def enemy(name, pos=(10, 0, 10)):
    return {"kind": "unit_enemy", "name": name, "pos": list(pos), "confirmed_dead": False}


def state(ai_units, intents=()):
    return {"server_tick": 1000, "latest_snapshot_id": 5,
            "ai_controlled_units": list(ai_units), "active_intents": list(intents)}


def busy_intent(unit_name):
    return {"intent_id": "i-busy", "unit_ids": [unit_name], "state": "active"}


class BuildLadderTest(unittest.TestCase):
    def test_builds_barracks_when_missing(self):
        st = state(["Unit_0", "Unit_2"])
        tact = {"entities": [
            unit("Unit_0", "command_center", queue=True),
            unit("Unit_2", "worker", construct=True, gather=True),
        ]}
        out = rf.development_intents(st, tactical=tact, rules=RULES,
                                     ttl_ticks=3600, server_tick=1000, snapshot_id=5)
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0]["action"], "build")
        self.assertEqual(out[0]["unit_ids"], ["Unit_2"])
        self.assertEqual(out[0]["target"]["scene"], "res://buildings/Barracks.tscn")
        self.assertEqual(out[0]["target"]["producer"], "Unit_2")

    def test_skips_to_next_building_when_barracks_exists(self):
        st = state(["Unit_2"])
        tact = {"entities": [
            unit("Unit_9", "barracks"),
            unit("Unit_2", "worker", construct=True),
        ]}
        out = rf.development_intents(st, tactical=tact, rules=RULES,
                                     server_tick=1000, snapshot_id=5)
        self.assertEqual(out[0]["action"], "build")
        self.assertEqual(out[0]["target"]["scene"], "res://buildings/VehicleFactory.tscn")

    def test_no_buildable_when_no_idle_builder(self):
        st = state(["Unit_2"], intents=[busy_intent("Unit_2")])
        tact = {"entities": [unit("Unit_2", "worker", construct=True)]}
        out = rf.development_intents(st, tactical=tact, rules=RULES)
        self.assertEqual([i["action"] for i in out], [])


class ProduceLadderTest(unittest.TestCase):
    def test_produces_soldier_when_barracks_idle(self):
        st = state(["Unit_9"])
        tact = {"entities": [unit("Unit_9", "barracks", queue=True)]}
        out = rf.development_intents(st, tactical=tact, rules=RULES,
                                     server_tick=1000, snapshot_id=5)
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0]["action"], "produce")
        self.assertEqual(out[0]["target"]["scene"], "res://units/Soldier.tscn")
        self.assertEqual(out[0]["target"]["producer"], "Unit_9")

    def test_prefers_soldier_before_tank(self):
        st = state(["Unit_9", "Unit_8"])
        tact = {"entities": [unit("Unit_9", "barracks", queue=True),
                             unit("Unit_8", "vehicle_factory", queue=True)]}
        out = rf.development_intents(st, tactical=tact, rules=RULES)
        self.assertEqual(out[0]["target"]["producer"], "Unit_9")

    def test_picks_the_least_populated_product_for_multi_unit_types(self):
        """已有兵营+车厂且都空闲时，要按"现有数量最少"补，不能永远只出士兵。

        回归守卫（2026-09-11 实测）：阶梯原来 `return` 第一级，
        兵营一建成第一级 (soldier, barracks) 就永远命中 → 车厂全程闲置、
        整局只有 soldier，"多兵种"名存实亡。
        """
        st = state(["Unit_9", "Unit_8", "Unit_4", "Unit_5", "Unit_6"])
        tact = {"entities": [
            unit("Unit_9", "barracks", queue=True),
            unit("Unit_8", "vehicle_factory", queue=True),
            unit("Unit_4", "soldier"), unit("Unit_5", "soldier"), unit("Unit_6", "soldier"),
        ]}
        out = rf.development_intents(st, tactical=tact, rules=RULES)
        self.assertEqual(out[0]["action"], "produce")
        self.assertEqual(out[0]["target"]["producer"], "Unit_8")   # 车厂
        self.assertEqual(out[0]["target"]["scene"], "res://units/Tank.tscn")

    def test_prefers_soldier_when_composition_is_empty(self):
        """空编制时按阶梯顺序先出士兵（不是先出坦克）。"""
        st = state(["Unit_9", "Unit_8"])
        tact = {"entities": [unit("Unit_9", "barracks", queue=True),
                             unit("Unit_8", "vehicle_factory", queue=True)]}
        out = rf.development_intents(st, tactical=tact, rules=RULES)
        self.assertEqual(out[0]["target"]["producer"], "Unit_9")

    def test_no_produce_when_producer_busy(self):
        st = state(["Unit_9"], intents=[busy_intent("Unit_9")])
        tact = {"entities": [unit("Unit_9", "barracks", queue=True)]}
        self.assertEqual(rf.development_intents(st, tactical=tact, rules=RULES), [])


class AttackLadderTest(unittest.TestCase):
    def test_attacks_when_army_ready_and_enemy_visible(self):
        st = state(["Unit_4", "Unit_5"])
        tact = {"entities": [
            unit("Unit_9", "barracks"),          # 已有兵营 → 不建
            unit("Unit_2", "worker", gather=True),  # 工人也已有
            unit("Unit_4", "soldier", pos=(1, 0, 1)),
            unit("Unit_5", "soldier", pos=(2, 0, 1)),
            enemy("Enemy_1", (20, 0, 20)),
        ]}
        # 兵营/车厂都已有 → 跳过建造级；barracks 忙碌 → 跳过生产级 → 走到出击
        st["active_intents"] = [busy_intent("Unit_9")]
        out = rf.development_intents(st, tactical=tact, rules=RULES,
                                     army_threshold=2)
        self.assertEqual(out[0]["action"], "attack")
        self.assertEqual(out[0]["target"]["entity_id"], "Enemy_1")

    def test_no_attack_without_enemy(self):
        st = state(["Unit_4", "Unit_5"])
        tact = {"entities": [unit("Unit_9", "barracks"), unit("Unit_8", "vehicle_factory"),
                             unit("Unit_4", "soldier"), unit("Unit_5", "soldier")]}
        st["active_intents"] = [busy_intent("Unit_9"), busy_intent("Unit_8")]
        self.assertEqual(rf.development_intents(st, tactical=tact, rules=RULES), [])

    def test_no_attack_below_threshold(self):
        st = state(["Unit_4"])
        tact = {"entities": [unit("Unit_9", "barracks"), unit("Unit_8", "vehicle_factory"),
                             unit("Unit_4", "soldier"), enemy("Enemy_1")]}
        st["active_intents"] = [busy_intent("Unit_9"), busy_intent("Unit_8")]
        self.assertEqual(rf.development_intents(st, tactical=tact, rules=RULES,
                                                army_threshold=2), [])

    def test_drone_is_not_combat(self):
        st = state(["Unit_4"])
        tact = {"entities": [unit("Unit_9", "barracks"), unit("Unit_8", "vehicle_factory"),
                             unit("Unit_4", "drone"), enemy("Enemy_1")]}
        st["active_intents"] = [busy_intent("Unit_9"), busy_intent("Unit_8")]
        self.assertEqual(rf.development_intents(st, tactical=tact, rules=RULES), [])


class ActionRankTest(unittest.TestCase):
    """跨产者抢占序（模型意图 vs 阶梯/行为树意图的胜负规则）。"""

    def test_survival_and_development_outrank_low_priority_actions(self):
        self.assertGreater(rf.action_rank("retreat"), rf.action_rank("attack"))
        self.assertGreater(rf.action_rank("attack"), rf.action_rank("build"))
        self.assertGreater(rf.action_rank("build"), rf.action_rank("gather"))
        self.assertGreater(rf.action_rank("gather"), rf.action_rank("move"))

    def test_unknown_action_is_never_preempted(self):
        # 未知动作取最高序：拿不准就不抢，绝不做无依据的打断。
        self.assertGreater(rf.action_rank("some_future_action"),
                           rf.action_rank("retreat"))


class BoundaryTest(unittest.TestCase):
    def test_player_controlled_units_never_appear(self):
        # ai_controlled_units 不含 Unit_3（玩家接管）→ 阶梯不得用它。
        st = state(["Unit_2"])
        tact = {"entities": [unit("Unit_3", "worker", construct=True)]}
        self.assertEqual(rf.development_intents(st, tactical=tact, rules=RULES), [])

    def test_no_tactical_returns_empty(self):
        self.assertEqual(rf.development_intents(state(["Unit_2"]), tactical=None,
                                                rules=RULES), [])

    def test_rules_error_returns_empty(self):
        st = state(["Unit_2"])
        tact = {"entities": [unit("Unit_2", "worker", construct=True)]}
        self.assertEqual(rf.development_intents(st, tactical=tact,
                                                rules={"error": "unavailable"}), [])

    def test_intent_shape_is_contract_compatible(self):
        st = state(["Unit_2"])
        tact = {"entities": [unit("Unit_2", "worker", construct=True)]}
        out = rf.development_intents(st, tactical=tact, rules=RULES,
                                     ttl_ticks=3600, server_tick=1000, snapshot_id=5)
        item = out[0]
        for key in ("intent_id", "task_id", "unit_ids", "action", "target",
                    "based_on_snapshot", "issued_tick", "expires_tick", "generation"):
            self.assertIn(key, item)
        self.assertEqual(item["based_on_snapshot"], 5)
        self.assertEqual(item["issued_tick"], 1000)
        self.assertEqual(item["expires_tick"], 1000 + 3600)
        self.assertEqual(item["generation"], 0)


if __name__ == "__main__":
    unittest.main()
