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
        # `BUILD_LIMITS["barracks"] = 2`（对齐开局购买力）之后，"有 1 座兵营"**不算到顶**，
        # 所以这里要给到 2 座，测的才是"到顶后跳到下一级"。
        st = state(["Unit_2"])
        tact = {"entities": [
            unit("Unit_9", "barracks"),
            unit("Unit_8", "barracks"),
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


class WorkerBackfillTest(unittest.TestCase):
    """补工人（阶梯 1.8）不得把后面的出兵饿死。

    实测背景（2026-09-12 晚，`--model off` 5 分钟真实局）：
    兵营/车厂都建好、余额 50000、5 分钟**一个兵都没出、一分钱没花**。
    事件日志给出真凶：`rule-produce-worker-Unit_0` 被重复生成 **391 次**，全部被下游
    `duplicate_of_live_intent` 丢弃 —— 阶梯是"逐级 return"结构，只要"补工人"长期在途，
    后面的出兵级**永远轮不到**。
    """

    def _frame(self, workers=2, in_flight=False):
        entities = [
            unit("Unit_0", "command_center", queue=True),
            unit("Unit_9", "barracks", queue=True),
            unit("Unit_8", "vehicle_factory", queue=True),
        ]
        # 工人**必须同时在 `ai_controlled_units`**：候选池严格取租约列表，
        # 只写进观测不写租约 = 阶梯看不见它们（第一版用例就踩了这个，故留注释）。
        ai_units = ["Unit_0", "Unit_9", "Unit_8"]
        for index in range(workers):
            name = "Unit_%d" % (10 + index)
            entities.append(unit(name, "worker", gather=True))
            ai_units.append(name)
        intents = [{"intent_id": "rule-produce-worker-Unit_0-900",
                    "unit_ids": ["Unit_0"], "state": "active"}] if in_flight else []
        return state(ai_units, intents=intents), {"entities": entities}

    def test_in_flight_worker_production_does_not_starve_army(self):
        st, tact = self._frame(workers=2, in_flight=True)
        out = rf.development_intents(st, tactical=tact, rules=RULES,
                                     server_tick=1000, snapshot_id=5)
        # 骨架永远排在第一位（并行填充只往后追加），所以断言 out[0] 即可 ——
        # 不再断言"整批只有一条"：现在其它空闲单位也会在同一批里拿到各自的活。
        self.assertEqual(out[0]["action"], "produce")
        self.assertEqual(out[0]["target"]["producer"], "Unit_9")
        self.assertEqual(out[0]["target"]["scene"], "res://units/Soldier.tscn")

    def test_backfills_worker_when_none_in_flight(self):
        st, tact = self._frame(workers=2, in_flight=False)
        out = rf.development_intents(st, tactical=tact, rules=RULES,
                                     server_tick=1000, snapshot_id=5)
        self.assertEqual(out[0]["action"], "produce")
        self.assertEqual(out[0]["target"]["producer"], "Unit_0")      # 基地补工人
        self.assertEqual(out[0]["target"]["scene"], "res://units/Worker.tscn")

    def test_stops_backfilling_once_target_reached(self):
        # 目标 = max(4, 基地数 × 6) = 6（2026-09-12 晚对齐传统 AI 后从 4 提到 6）。
        st, tact = self._frame(workers=6, in_flight=False)
        out = rf.development_intents(st, tactical=tact, rules=RULES,
                                     server_tick=1000, snapshot_id=5)
        self.assertEqual(out[0]["target"]["producer"], "Unit_9")      # 转向出兵


class FinishSiteTest(unittest.TestCase):
    """续建意图必须**契约合法**：build 必须同时带 `target.scene` 与 `target.producer`。

    实测背景：`rule-finish-site-Unit_4-756` 因缺 `target.scene` 被判 `contract_invalid`
    （`contracts.TacticalIntent` 的 SCENE_ACTIONS 校验），意图直接消失。
    """

    def test_finish_site_intent_carries_scene(self):
        st = state(["Unit_2", "Unit_7"])
        tact = {"entities": [
            unit("Unit_9", "barracks", queue=True),
            unit("Unit_8", "vehicle_factory", queue=True),
            unit("Unit_2", "worker", construct=True),
            # 未完工工地：只有显式 constructed=False 才算（None=未知不算）。
            {"kind": "unit_self", "name": "Unit_7", "unit_type": "barracks",
             "construct": False, "gather": False, "queue": False,
             "constructed": False, "pos": [12.0, 0.0, 7.0]},
        ]}
        out = rf.development_intents(st, tactical=tact, rules=RULES,
                                     server_tick=1000, snapshot_id=5)
        self.assertEqual(out[0]["action"], "build")
        self.assertEqual(out[0]["target"]["entity_id"], "Unit_7")
        self.assertEqual(out[0]["target"]["scene"], "res://buildings/Barracks.tscn")
        self.assertEqual(out[0]["target"]["producer"], "Unit_2")


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

    def test_no_produce_when_producer_is_already_producing(self):
        """该设施**正在生产**（有在途 produce 意图）时不再重复下单。

        判据收窄（2026-09-12 晚，用户报"有钱 46800 却不出兵"）：旧实现拿整个 `busy`
        集合当占用判据，任何非可抢占的在途意图都能让整条生产线停摆。
        现在只按"**这个执行者是否已有在途 produce 意图**"判定。
        """
        st = state(["Unit_9"], intents=[{
            "intent_id": "i-produce", "unit_ids": ["Unit_9"],
            "action": "produce", "state": "active"}])
        tact = {"entities": [unit("Unit_9", "barracks", queue=True)]}
        self.assertEqual(rf.development_intents(st, tactical=tact, rules=RULES), [])

    def test_unrelated_live_intent_does_not_stall_production(self):
        """与生产无关的在途意图**不得**让生产线停摆（这正是"有钱不出兵"的根因）。"""
        st = state(["Unit_9"], intents=[busy_intent("Unit_9")])
        tact = {"entities": [unit("Unit_9", "barracks", queue=True)]}
        out = rf.development_intents(st, tactical=tact, rules=RULES,
                                     server_tick=1000, snapshot_id=5)
        self.assertEqual(out[0]["action"], "produce")
        self.assertEqual(out[0]["target"]["producer"], "Unit_9")
        self.assertEqual(out[0]["target"]["scene"], "res://units/Soldier.tscn")

    def test_other_producer_keeps_working_when_one_is_busy(self):
        """一座设施在产时，**其它**已完工设施照常补货（不是全线停摆）。"""
        st = state(["Unit_9", "Unit_8"], intents=[{
            "intent_id": "i-produce", "unit_ids": ["Unit_9"],
            "action": "produce", "state": "active"}])
        tact = {"entities": [unit("Unit_9", "barracks", queue=True),
                             unit("Unit_8", "vehicle_factory", queue=True)]}
        out = rf.development_intents(st, tactical=tact, rules=RULES,
                                     server_tick=1000, snapshot_id=5)
        self.assertEqual(out[0]["action"], "produce")
        self.assertEqual(out[0]["target"]["producer"], "Unit_8")   # 车厂继续出坦克
        self.assertEqual(out[0]["target"]["scene"], "res://units/Tank.tscn")


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


class BuildSerializationTest(unittest.TestCase):
    """施工串行：有工地在施工时**不开新工地**（传统 AI 优点 #2）。

    实测依据（2026-09-12 晚）：同时铺开多个工地时 `build` 命令 181 条、其中 172 条被
    `NotVisible` 拒（落点在视野外），还把工人成批从采集里抽走 → 采集线停摆。
    """

    def test_no_new_build_while_a_site_is_unfinished(self):
        st = state(["Unit_2", "Unit_9"])
        tact = {"entities": [
            # 兵营是**已放置、未完工**的工地（constructed=False 才算工地）。
            {"kind": "unit_self", "name": "Unit_9", "unit_type": "barracks",
             "construct": False, "gather": False, "queue": True,
             "constructed": False, "pos": [18.0, 0.0, 7.0]},
            unit("Unit_2", "worker", construct=True, gather=True),
        ]}
        out = rf.development_intents(st, tactical=tact, rules=RULES,
                                     server_tick=1000, snapshot_id=5)
        ids = [item["intent_id"] for item in out]
        self.assertFalse([i for i in ids if i.startswith("rule-build-")],
                         "有工地在施工时不得再开新工地：%s" % (ids,))
        self.assertTrue([i for i in ids if i.startswith("rule-finish-site-")],
                        "必须派 1 个工人续建现有工地：%s" % (ids,))


class ExpansionLadderTest(unittest.TestCase):
    """扩线：产能 → **防御** → **分基地**（2026-09-12 晚，用户反馈"不会发展、
    不会多造建筑、防御、分子基地"）。

    旧实现是 `if building in own_types: continue` —— **有一座就永远跳过**，
    于是兵营+车厂建完发展线彻底停摆（余额 46800 花不出去）。现在按 `BUILD_LIMITS`
    的座数上限判定，同类型可以要 2 座（分基地），也可以要不同功能的塔（防空/反地）。
    """

    RULES = {
        "unit_types": [{"id": name, "scene_path": "res://units/%s.tscn" % name}
                       for name in ("worker", "command_center", "barracks",
                                    "vehicle_factory", "aircraft_factory", "soldier",
                                    "tank", "helicopter", "anti_air_turret",
                                    "anti_ground_turret")],
        # 与真实配置一致：`constructions[].blueprint_scene_path` 和
        # `unit_types[].scene_path` 指向**同一个场景文件**（这里都用 res://units/...）。
        # 注意 `rules_scene_index` 在同 id 冲突时 **unit_type 优先**（有专门用例钉住），
        # 所以两边写不一致时拿到的会是 unit_types 的那份——不是 bug，是既定口径。
        "constructions": [{"id": name, "blueprint_scene_path": "res://units/%s.tscn" % name}
                          for name in ("barracks", "vehicle_factory", "aircraft_factory",
                                       "anti_air_turret", "anti_ground_turret",
                                       "command_center")],
        "productions": [
            {"product_type_id": "worker", "allowed_producer_type_ids": ["command_center"]},
            {"product_type_id": "soldier", "allowed_producer_type_ids": ["barracks"]},
            {"product_type_id": "tank", "allowed_producer_type_ids": ["vehicle_factory"]},
            {"product_type_id": "helicopter",
             "allowed_producer_type_ids": ["aircraft_factory"]},
        ],
    }

    #: 把产能铺到 `BUILD_LIMITS` 上限所需的**额外**实体（新口径：兵营/车厂各 2 座）。
    #: 这些用例问的是"到顶之后轮到哪一级"，所以必须先把前面几级真的填满；
    #: 否则测到的是"还没到顶的那一级"，断言会随上限调整而失效。
    PRODUCTION_FULL = [("Unit_15", ("barracks", (22, 0, 7))),
                       ("Unit_16", ("vehicle_factory", (4, 0, 13)))]
    #: 防御同样各 2 座（防空/反地）才算到顶。
    DEFENCE_FULL = [("Unit_17", ("anti_air_turret", (16, 0, 5))),
                    ("Unit_18", ("anti_ground_turret", (4, 0, 5)))]

    def _state(self, buildings):
        names = ["Unit_2"] + [name for name, _ in buildings]
        entities = [unit("Unit_2", "worker", construct=True, gather=True, pos=(10, 0, 9))]
        entities += [unit(name, utype, queue=utype != "worker", pos=pos)
                     for name, (utype, pos) in buildings]
        # 远端矿点（离主基地 > EXPANSION_MIN_DISTANCE_M），供分基地选址。
        entities.append({"kind": "resource", "name": "Res_far", "pos": [60.0, 0.0, 7.0]})
        return (state(names, intents=[]), {"entities": entities}, names)

    def test_builds_defence_after_production_buildings(self):
        st, tact, _ = self._state([
            ("Unit_0", ("command_center", (10, 0, 7))),
            ("Unit_4", ("barracks", (18, 0, 7))),
            ("Unit_5", ("vehicle_factory", (4, 0, 7))),
            ("Unit_13", ("aircraft_factory", (10, 0, 3))),
        ] + self.PRODUCTION_FULL)
        out = rf.development_intents(st, tactical=tact, rules=self.RULES,
                                     server_tick=1000, snapshot_id=5)
        self.assertEqual(out[0]["action"], "build")
        self.assertEqual(out[0]["target"]["scene"], "res://units/anti_air_turret.tscn")

    def test_builds_second_command_center_near_far_resource(self):
        st, tact, _ = self._state([
            ("Unit_0", ("command_center", (10, 0, 7))),
            ("Unit_4", ("barracks", (18, 0, 7))),
            ("Unit_5", ("vehicle_factory", (4, 0, 7))),
            ("Unit_13", ("aircraft_factory", (10, 0, 3))),
            ("Unit_11", ("anti_air_turret", (16, 0, 1))),
            ("Unit_12", ("anti_ground_turret", (4, 0, 1))),
        ] + self.PRODUCTION_FULL + self.DEFENCE_FULL)
        # 分基地之所以**能**建，是因为有工人在远端矿点采矿 = 那片地在己方视野内。
        tact["entities"].append(unit("Unit_7", "worker", construct=True, gather=True,
                                     pos=(60, 0, 8)))
        out = rf.development_intents(st, tactical=tact, rules=self.RULES,
                                     server_tick=1000, snapshot_id=5)
        self.assertEqual(out[0]["action"], "build")
        self.assertEqual(out[0]["target"]["scene"], "res://units/command_center.tscn")
        # 分基地必须**离开主基地**（不能贴着主基地再盖一座）。
        pos = out[0]["target"]["pos"]
        self.assertGreater(((pos[0] - 10.0) ** 2 + (pos[1] - 7.0) ** 2) ** 0.5,
                           rf.EXPANSION_MIN_DISTANCE_M)

    def test_no_second_base_when_far_resource_is_unseen(self):
        """远端矿点**看不见**时不得选分基地（否则必被 `NotVisible` 拒）。

        实测依据：建造被拒的主因就是落点在己方视野外（172 条 `NotVisible`）；
        分基地若选在"没单位看得见的远方"，等于发一条注定被拒的命令。
        """
        st, tact, _ = self._state([
            ("Unit_0", ("command_center", (10, 0, 7))),
            ("Unit_4", ("barracks", (18, 0, 7))),
            ("Unit_5", ("vehicle_factory", (4, 0, 7))),
            ("Unit_13", ("aircraft_factory", (10, 0, 3))),
            ("Unit_11", ("anti_air_turret", (16, 0, 1))),
            ("Unit_12", ("anti_ground_turret", (4, 0, 1))),
        ] + self.PRODUCTION_FULL + self.DEFENCE_FULL)
        out = rf.development_intents(st, tactical=tact, rules=self.RULES,
                                     server_tick=1000, snapshot_id=5)
        scenes = [item["target"].get("scene") for item in out
                  if item["action"] == "build"]
        self.assertNotIn("res://units/command_center.tscn", scenes,
                         "看不见的远方不能选分基地：%s" % (scenes,))

    def test_no_second_base_without_far_resource(self):
        st, tact, _ = self._state([
            ("Unit_0", ("command_center", (10, 0, 7))),
            ("Unit_4", ("barracks", (18, 0, 7))),
            ("Unit_5", ("vehicle_factory", (4, 0, 7))),
            ("Unit_13", ("aircraft_factory", (10, 0, 3))),
            ("Unit_11", ("anti_air_turret", (16, 0, 1))),
            ("Unit_12", ("anti_ground_turret", (4, 0, 1))),
        ] + self.PRODUCTION_FULL + self.DEFENCE_FULL)
        tact["entities"] = [e for e in tact["entities"] if e.get("kind") != "resource"]
        out = rf.development_intents(st, tactical=tact, rules=self.RULES,
                                     server_tick=1000, snapshot_id=5)
        # 没有远端矿点就**不许建假分基地**；其它线（补工人/出兵）照常推进。
        self.assertFalse([item for item in out if item["action"] == "build"],
                         "没有远端矿点仍发了 build：%s" % (out,))

    def test_stops_when_all_limits_reached(self):
        st, tact, _ = self._state([
            ("Unit_0", ("command_center", (10, 0, 7))),
            ("Unit_14", ("command_center", (58, 0, 9))),
            # 基地上限对齐传统 AI `max_command_centers = 3`。
            ("Unit_19", ("command_center", (58, 0, 16))),
            ("Unit_4", ("barracks", (18, 0, 7))),
            ("Unit_5", ("vehicle_factory", (4, 0, 7))),
            ("Unit_13", ("aircraft_factory", (10, 0, 3))),
            ("Unit_11", ("anti_air_turret", (16, 0, 1))),
            ("Unit_12", ("anti_ground_turret", (4, 0, 1))),
        ] + self.PRODUCTION_FULL + self.DEFENCE_FULL)
        out = rf.development_intents(st, tactical=tact, rules=self.RULES,
                                     server_tick=1000, snapshot_id=5)
        # 建造线到顶 → 轮到"出兵"这条线（不能因为建造到顶就整轮不动）。
        # 注意：`development_intents` 现在还会**并行填充**其它空闲单位（经济/生产/军事各轨），
        # 所以这里断言"有 produce 且没有任何 build"，而不是断言整批只有一条。
        actions = [item["action"] for item in out]
        self.assertIn("produce", actions, "建造到顶后必须轮到出兵：%s" % (out,))
        self.assertNotIn("build", actions, "建造线已到顶，不该再发 build：%s" % (out,))


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
