# -*- coding: utf-8 -*-
"""AI 小队编制（用户 2026-09-14 规格）。

用户原话："小队可以是步兵多一点，坦克 1-2 个就行，小队是给 AI 去指挥的，
玩家也会有另一套分组小队系统。"

这条规格要钉住的是**四个可判定事实**：
① 步兵为主（每队 ≤ `SQUAD_INFANTRY_MAX`）；
② 坦克 1~2 个（每队 ≤ `SQUAD_TANK_MAX`，且**先保证每队都有 1 个**再补第 2 个）；
③ 空中不与地面同队（两套导航网格，混合队没有队形/中继点语义）；
④ 同一观测必得同一编组（确定性），且**一个单位都不许丢**。

反例来自实测（2026-09-14 live 局）：20 人一坨、队内最大间距 22m、`drone` 被编进地面小队、
坦克与步兵因"集群键含类型"而永远分属两队 → 玩家看到的就是一堆单位挤在一个信标上。
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph import squads  # noqa: E402
from adjutant_coordinator.graph.task_patch import ACTOR_SQUAD  # noqa: E402


def unit(name, unit_type, x=10.0, z=7.0, **flags):
    """观测里的己方作战单位（`op=tactical` 实体形状；作战单位必须带 movement）。"""
    entry = {
        "kind": "unit_self", "name": name, "unit_type": unit_type,
        "pos": [float(x), 0.0, float(z)], "hp": 100.0, "hp_max": 100.0,
        "movement": True, "gather": False, "construct": False, "queue": False,
    }
    entry.update(flags)
    return entry


def tactical(entities):
    return {"entities": list(entities)}


def squads_of(entities):
    return [squad for squad in squads.derive_squads(tactical(entities))
            if str(squad.get("kind")) == ACTOR_SQUAD]


class SquadCompositionTest(unittest.TestCase):
    def test_infantry_heavy_with_one_or_two_tanks(self):
        """"步兵多一点，坦克 1-2 个"：每队步兵 ≤6、坦克 ≤2。"""
        entities = [unit("Unit_%d" % index, "soldier", x=10.0 + index * 0.4)
                    for index in range(8)]
        entities += [unit("Tank_%d" % index, "tank", x=12.0 + index * 0.4)
                     for index in range(4)]
        squads_found = squads_of(entities)
        self.assertTrue(squads_found)
        for squad in squads_found:
            mix = squad.get("mix") or {}
            self.assertLessEqual(mix.get("infantry", 0), squads.SQUAD_INFANTRY_MAX,
                                 "步兵超编：%s" % squad)
            self.assertLessEqual(mix.get("tank", 0), squads.SQUAD_TANK_MAX,
                                 "坦克超编：%s" % squad)
        total_tanks = sum((squad.get("mix") or {}).get("tank", 0) for squad in squads_found)
        self.assertEqual(total_tanks, 4, "坦克不许丢")

    def test_every_squad_gets_a_tank_before_a_second_one(self):
        """坦克**轮转分配**：先保证每队 1 个，再补第 2 个（不许前几队吃满）。"""
        entities = [unit("Unit_%d" % index, "soldier", x=10.0 + index * 0.3)
                    for index in range(12)]
        entities += [unit("Tank_%d" % index, "tank", x=12.0 + index * 0.3)
                     for index in range(2)]
        squads_found = squads_of(entities)
        self.assertEqual(len(squads_found), 2, "12 步 = 2 队（每队 ≤6）")
        self.assertEqual([(squad.get("mix") or {}).get("tank", 0)
                          for squad in squads_found], [1, 1],
                         "2 个坦克应每队 1 个，而不是挤在同一队")

    def test_no_squad_exceeds_the_cap(self):
        """20 个步兵不许再编成 1 队（旧口径就是这么一坨）。"""
        entities = [unit("Unit_%d" % index, "soldier", x=10.0 + index * 0.2)
                    for index in range(20)]
        squads_found = squads_of(entities)
        self.assertEqual(len(squads_found), 4, "20 步 ÷ 6 = 4 队")
        for squad in squads_found:
            self.assertLessEqual(len(squad["units"]), squads.MAX_UNITS_PER_ACTOR)

    def test_air_never_shares_a_squad_with_ground(self):
        """空中不与地面同组：空中/地面是**两套导航网格**，混合队没有队形语义。"""
        entities = [unit("Unit_1", "soldier"), unit("Unit_2", "soldier"),
                    unit("Unit_3", "tank"),
                    unit("Unit_4", "drone"), unit("Unit_5", "helicopter")]
        squads_found = squads_of(entities)
        ground = {"Unit_1", "Unit_2", "Unit_3"}
        air = {"Unit_4", "Unit_5"}
        for squad in squads_found:
            members = set(squad["units"])
            self.assertFalse(members & ground and members & air,
                             "空中队里混进了地面单位：%s" % squad)
        names = {name for squad in squads_found for name in squad["units"]}
        self.assertEqual(names, ground | air, "一个单位都不许丢")

    def test_types_outside_the_combat_set_are_kept_as_their_own_group(self):
        """**口径外**类型（未知新兵种 / 缺失类型）各自成组：既不编队，也不许丢。

        为什么不编队：编队会给出"全队一个中继点"的语义，把没被识别的单位塞进去，
        风险是"让不该动的对象跟着走"。这份保守与 `classify` 的能力口径一致。
        """
        entities = [unit("Unit_1", "soldier"), unit("Unit_2", ""),
                    unit("Unit_3", "future_tank_3000")]
        squads_found = squads_of(entities)
        names = sorted(name for squad in squads_found for name in squad["units"])
        self.assertEqual(names, ["Unit_1", "Unit_2", "Unit_3"])
        unknown = [squad for squad in squads_found if "Unit_3" in squad["units"]]
        self.assertEqual(len(unknown), 1)
        self.assertEqual(unknown[0]["units"], ["Unit_3"], "口径外类型不许被编进战斗小队")

    def test_fixed_turrets_do_not_join_squads(self):
        """固定炮塔算"能打"但**动不了** → 不进小队（历史行为：静态对象不进执行者候选）。

        两道闸都要：`derive_squads` 的前置过滤会滤掉"不可移动且不生产"的对象，
        `_is_composable` 再要求 `movement` —— 少一道就会出现"让炮塔跟着部队走"。
        """
        entities = [unit("Unit_1", "soldier"), unit("Unit_2", "tank"),
                    unit("Turret_1", "anti_air_turret", movement=False)]
        groups = squads.derive_squads(tactical(entities))
        squad_units = [name for entry in groups if entry["kind"] == "squad"
                       for name in entry["units"]]
        self.assertNotIn("Turret_1", squad_units, "不可移动的对象不许编进小队")
        from adjutant_coordinator.graph import rules_fallback

        self.assertFalse(
            squads._is_composable(unit("Unit_9", "soldier", movement=False),
                                  rules_fallback.COMBAT_TYPES),
            "可移动是编队的硬前置（哪怕是口径内的类型）")

    def test_workers_are_not_fighting_squads(self):
        """工人组不受战斗编成约束（保持集群口径，别把采集线按 6 人拆散）。"""
        entities = [unit("Worker_%d" % index, "worker", x=10.0 + index * 0.2,
                         gather=True, construct=True)
                    for index in range(9)]
        groups = squads.derive_squads(tactical(entities))
        workers = [entry for entry in groups if str(entry.get("kind")) == "worker"]
        self.assertEqual(sum(len(entry["units"]) for entry in workers), 9)

    def test_facilities_and_workers_never_enter_a_fighting_squad(self):
        """设施（有生产队列）与工人（能采集/建造）**不许**被编进作战小队。

        这是"建筑被下令移动"这类事故的唯一防线：`classify` 按能力标志分流，
        小队编成只在 `ACTOR_SQUAD` 桶里做。实测踩到过反面：夹具把 `queue/gather`
        写死 False 时，工厂+工人+坦克会被编成**同一支小队**。
        """
        entities = [
            {"kind": "unit_self", "name": "Unit_0", "unit_type": "vehicle_factory",
             "pos": [0.0, 0.0, 0.0], "movement": False, "queue": True, "gather": False,
             "construct": False},
            {"kind": "unit_self", "name": "Unit_2", "unit_type": "worker",
             "pos": [5.0, 0.0, 5.0], "movement": True, "queue": False, "gather": True,
             "construct": True},
            unit("Unit_4", "tank", x=8.0, z=8.0),
        ]
        groups = squads.derive_squads(tactical(entities))
        by_kind = {str(entry["kind"]): entry for entry in groups}
        self.assertEqual(sorted(by_kind), ["facility", "squad", "worker"])
        self.assertEqual(by_kind["squad"]["units"], ["Unit_4"],
                         "作战小队里混进了非作战单位：%s" % by_kind["squad"])
        self.assertEqual(by_kind["facility"]["units"], ["Unit_0"])
        self.assertEqual(by_kind["worker"]["units"], ["Unit_2"])

    def test_composition_is_deterministic(self):
        """确定性：同一批单位（哪怕输入顺序不同）必得同一编组 —— 引用表可复核的前提。"""
        entities = [unit("Unit_%d" % index, "soldier", x=10.0 + index * 0.3)
                    for index in range(7)]
        entities += [unit("Tank_0", "tank", x=12.0), unit("Unit_9", "drone", x=11.0)]
        first = [(squad["squad_id"], tuple(squad["units"]))
                 for squad in squads_of(entities)]
        second = [(squad["squad_id"], tuple(squad["units"]))
                  for squad in squads_of(list(reversed(entities)))]
        self.assertEqual(first, second, "同一观测的编组必须与遍历顺序无关")

    def test_persist_keeps_id_when_member_dies(self):
        """T08：成员死亡不整队换编号，残部继续（不等满编）。"""
        entities = [unit("Unit_%d" % index, "soldier", x=10.0 + index * 0.3)
                    for index in range(4)]
        first = squads_of(entities)
        self.assertTrue(first)
        squad_id = first[0]["squad_id"]
        living = ["Unit_0", "Unit_1", "Unit_2"]
        derived = squads_of([item for item in entities if item["name"] in living])
        persisted = squads.persist_squads(first, derived, living)
        combat = [item for item in persisted if item.get("kind") == ACTOR_SQUAD]
        self.assertTrue(any(item.get("squad_id") == squad_id for item in combat))
        kept = next(item for item in combat if item.get("squad_id") == squad_id)
        self.assertNotIn("Unit_3", kept["units"])
        self.assertEqual(kept.get("status"), "understrength")


if __name__ == "__main__":
    unittest.main()
