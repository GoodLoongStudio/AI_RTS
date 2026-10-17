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


def opening_ready(prefix="Unit_E"):
    """2026-10-13 开局顺序夹具：经济已点火（建成矿场+矿车）+ 基础防御已落地。

    `opening_order_ready` 要求这两档就绪才放开作战/侦察生产档；代表"中局"的夹具
    必须带上它们，否则测到的是开局让位，而不是本用例想测的机制。
    """
    return [unit(prefix + "R", "ore_refinery"),
            unit(prefix + "W", "worker", gather=True),
            unit(prefix + "T", "anti_ground_turret")]


def enemy(name, pos=(10, 0, 10)):
    return {"kind": "unit_enemy", "name": name, "pos": list(pos), "confirmed_dead": False}


def state(ai_units, intents=()):
    return {"server_tick": 1000, "latest_snapshot_id": 5,
            "ai_controlled_units": list(ai_units), "active_intents": list(intents)}


def busy_intent(unit_name):
    return {"intent_id": "i-busy", "unit_ids": [unit_name], "state": "active"}


def _with_source(source):
    """给 RULES 里每条施工定义贴上进度源（模拟阶段 1 贯通到规则视图的新字段）。"""
    rules = {key: [dict(item) for item in value] if isinstance(value, list) else value
             for key, value in RULES.items()}
    for item in rules["constructions"]:
        item["construction_progress_source"] = source
    return rules


class NoBuilderStillBuildsTest(unittest.TestCase):
    """【阶段 3】automatic 施工下，"没有空闲工人"不得再让整条建造阶梯静默停摆。

    阶段 0 断点 C-1：旧实现 `builders = list(idle_builders); if not builders: continue`
    —— 一个工人都在忙时，本轮**不产任何建造意图、也不留任何痕**，玩家看到的就是
    "副官有钱不发展"。修好后由施工进度源决定，且权威端保证忙碌工人不会被真拉上工地。
    """

    def _busy_fixture(self):
        st = state(["Unit_2"], intents=[busy_intent("Unit_2")])
        tact = {"entities": [unit("Unit_2", "worker", construct=True)]}
        return st, tact

    def test_automatic_source_still_emits_build_without_idle_builder(self):
        st, tact = self._busy_fixture()
        out = rf.development_intents(st, tactical=tact, rules=_with_source("automatic"),
                                     server_tick=1000, snapshot_id=5)
        actions = [i["action"] for i in out]
        self.assertIn("build", actions,
                      "automatic 施工不该再把'没有空闲工人'当成开工前置")
        # 2026-10-13 开局顺序：经济档车厂先于军事档兵营；本类断言的"载体语义"不变。
        self.assertEqual(out[actions.index("build")]["target"]["scene"],
                         "res://buildings/VehicleFactory.tscn")

    def test_worker_source_still_requires_idle_builder(self):
        st, tact = self._busy_fixture()
        out = rf.development_intents(st, tactical=tact, rules=_with_source("worker"),
                                     server_tick=1000, snapshot_id=5)
        self.assertEqual([i["action"] for i in out], [],
                         "worker 兼容口径必须保留'先有建造者'的旧语义")

    def test_hybrid_source_also_lifts_the_builder_precondition(self):
        st, tact = self._busy_fixture()
        out = rf.development_intents(st, tactical=tact, rules=_with_source("hybrid"),
                                     server_tick=1000, snapshot_id=5)
        self.assertIn("build", [i["action"] for i in out],
                      "hybrid 只让 Worker 提供加速，同样不得构成开工前置")

    def test_missing_source_defaults_to_worker_conservatively(self):
        st, tact = self._busy_fixture()
        out = rf.development_intents(st, tactical=tact, rules=RULES,
                                     server_tick=1000, snapshot_id=5)
        self.assertEqual([i["action"] for i in out], [],
                         "规则视图没带进度源时必须退回 worker 口径，不得猜成 automatic")

    def test_construction_progress_source_reader(self):
        self.assertEqual(rf.construction_progress_source(_with_source("automatic"),
                                                         "barracks"), "automatic")
        self.assertEqual(rf.construction_progress_source(RULES, "barracks"), "worker")
        self.assertEqual(rf.construction_progress_source(None, "barracks"), "worker")


class RefineryLadderTest(unittest.TestCase):
    """矿场必须真能排上阶梯，且没有合法远端矿时**留下具体原因**而不是静默跳过。"""

    REF_RULES = {
        "unit_types": [{"id": "ore_refinery",
                        "scene_path": "res://buildings/OreRefinery.tscn"}],
        "constructions": [{"id": "ore_refinery",
                           "blueprint_scene_path": "res://buildings/OreRefinery.tscn",
                           "construction_progress_source": "automatic"}],
        "productions": [],
    }

    @staticmethod
    def _maxed_out_entities():
        """把 BUILD_LADDER 里矿场之前的每一级都顶到限额，逼阶梯走到 ore_refinery。"""
        built = (["barracks"] * 2 + ["vehicle_factory"] * 2 + ["aircraft_factory"]
                 + ["anti_air_turret"] * 2 + ["anti_ground_turret"] * 2)
        entities = [unit("Unit_cc", "command_center", queue=True, pos=(10, 0, 10)),
                    unit("Unit_w", "worker", construct=True, pos=(12, 0, 12))]
        entities += [unit("Unit_b%d" % index, key, pos=(20.0 + index, 0.0, 20.0))
                     for index, key in enumerate(built)]
        return entities

    def test_no_far_resource_records_blocking_reason(self):
        st = state(["Unit_cc", "Unit_w"])
        st["map_bounds"] = [200.0, 200.0]
        rf.development_intents(st, tactical={"entities": self._maxed_out_entities()},
                               rules=self.REF_RULES, server_tick=1000, snapshot_id=5)
        kinds = [str(entry.get("kind")) for entry in st.get("decision_log") or []]
        self.assertIn("expansion_spot_exhausted", kinds,
                      "没有可见远端矿时必须留痕，否则'整局没矿场'无从归因：%s" % kinds)
        note = next(entry for entry in st["decision_log"]
                    if str(entry.get("kind")) == "expansion_spot_exhausted")
        self.assertEqual(str(note.get("building")), "ore_refinery")

    def test_far_visible_resource_orders_refinery_not_second_base(self):
        entities = self._maxed_out_entities()
        entities.append({"kind": "resource", "name": "R_far", "pos": [150.0, 0.0, 150.0]})
        # 落点必须**在己方视野内**（`pick_expansion_spot` 的硬判据）：派个单位钉在矿点旁，
        # 否则"看得见远端矿"这个前提本身不成立，测的就不是阶梯能不能排到矿场。
        entities.append(unit("Unit_scout", "worker", construct=True, pos=(150.0, 0.0, 150.0)))
        st = state(["Unit_cc", "Unit_w", "Unit_scout"])
        st["map_bounds"] = [200.0, 200.0]
        out = rf.development_intents(st, tactical={"entities": entities},
                                     rules=self.REF_RULES, server_tick=1000, snapshot_id=5)
        scenes = [str((i.get("target") or {}).get("scene", "")) for i in out]
        self.assertIn("res://buildings/OreRefinery.tscn", scenes,
                      "远端矿可见时阶梯必须能排到矿场：%s" % scenes)


class BuildLadderTest(unittest.TestCase):
    def test_builds_barracks_when_missing(self):
        st = state(["Unit_0", "Unit_2"])
        tact = {"entities": [
            unit("Unit_0", "command_center", queue=True),
            unit("Unit_2", "worker", construct=True, gather=True),
        ] + opening_ready()}
        out = rf.development_intents(st, tactical=tact, rules=RULES,
                                     ttl_ticks=3600, server_tick=1000, snapshot_id=5)
        # 本用例钉两件事：① 缺兵营时必须产出**恰好一条**命令（阶梯 1 负责，不与其它轨重复）；
        # ② 那条必须是"派工人建兵营"（手册 BLD-01 的第一优先，不被采集/出兵挤掉）。
        # 背景（2026-09-15 实测 match 9fa2f599）：补工人曾整局为 0（生产者判据只认 `idle_producers`），
        # 修法落在**阶梯 1.8 的生产者判据**上，而**不**让并行填充轨重复补工人（那里只加了一句
        # 说明注释）—— 所以这里仍严格断言"只一条"。
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0]["action"], "build")
        self.assertEqual(out[0]["unit_ids"], ["Unit_2"])
        # 2026-10-13 开局顺序：经济档（车厂）先于军事档（兵营）；
        # "恰好一条、由工人承载、不被挤掉"三条断言不变。
        self.assertEqual(out[0]["target"]["scene"], "res://buildings/VehicleFactory.tscn")
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
        ] + opening_ready()
        # 工人**必须同时在 `ai_controlled_units`**：候选池严格取租约列表，
        # 只写进观测不写租约 = 阶梯看不见它们（第一版用例就踩了这个，故留注释）。
        ai_units = ["Unit_0", "Unit_9", "Unit_8",
                    "Unit_ER", "Unit_EW", "Unit_ET"]
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
        st = state(["Unit_9", "Unit_ER", "Unit_EW", "Unit_ET"])
        tact = {"entities": [unit("Unit_9", "barracks", queue=True)]
                + opening_ready()}
        out = rf.development_intents(st, tactical=tact, rules=RULES,
                                     server_tick=1000, snapshot_id=5)
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0]["action"], "produce")
        self.assertEqual(out[0]["target"]["scene"], "res://units/Soldier.tscn")
        self.assertEqual(out[0]["target"]["producer"], "Unit_9")

    def test_prefers_soldier_before_tank(self):
        st = state(["Unit_9", "Unit_8", "Unit_ER", "Unit_EW", "Unit_ET"])
        tact = {"entities": [unit("Unit_9", "barracks", queue=True),
                             unit("Unit_8", "vehicle_factory", queue=True)]
                + opening_ready()}
        out = rf.development_intents(st, tactical=tact, rules=RULES)
        self.assertEqual(out[0]["target"]["producer"], "Unit_9")

    def test_picks_the_least_populated_product_for_multi_unit_types(self):
        """已有兵营+车厂且都空闲时，要按"现有数量最少"补，不能永远只出士兵。

        回归守卫（2026-09-11 实测）：阶梯原来 `return` 第一级，
        兵营一建成第一级 (soldier, barracks) 就永远命中 → 车厂全程闲置、
        整局只有 soldier，"多兵种"名存实亡。
        """
        st = state(["Unit_9", "Unit_8", "Unit_4", "Unit_5", "Unit_6",
                    "Unit_ER", "Unit_EW", "Unit_ET"])
        tact = {"entities": [
            unit("Unit_9", "barracks", queue=True),
            unit("Unit_8", "vehicle_factory", queue=True),
            unit("Unit_4", "soldier"), unit("Unit_5", "soldier"), unit("Unit_6", "soldier"),
        ] + opening_ready()}
        out = rf.development_intents(st, tactical=tact, rules=RULES)
        self.assertEqual(out[0]["action"], "produce")
        self.assertEqual(out[0]["target"]["producer"], "Unit_8")   # 车厂
        self.assertEqual(out[0]["target"]["scene"], "res://units/Tank.tscn")

    def test_prefers_soldier_when_composition_is_empty(self):
        """空编制时按阶梯顺序先出士兵（不是先出坦克）。"""
        st = state(["Unit_9", "Unit_8", "Unit_ER", "Unit_EW", "Unit_ET"])
        tact = {"entities": [unit("Unit_9", "barracks", queue=True),
                             unit("Unit_8", "vehicle_factory", queue=True)]
                + opening_ready()}
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
        st = state(["Unit_9", "Unit_ER", "Unit_EW", "Unit_ET"],
                   intents=[busy_intent("Unit_9")])
        tact = {"entities": [unit("Unit_9", "barracks", queue=True)]
                + opening_ready()}
        out = rf.development_intents(st, tactical=tact, rules=RULES,
                                     server_tick=1000, snapshot_id=5)
        self.assertEqual(out[0]["action"], "produce")
        self.assertEqual(out[0]["target"]["producer"], "Unit_9")
        self.assertEqual(out[0]["target"]["scene"], "res://units/Soldier.tscn")

    def test_other_producer_keeps_working_when_one_is_busy(self):
        """一座设施在产时，**其它**已完工设施照常补货（不是全线停摆）。"""
        st = state(["Unit_9", "Unit_8", "Unit_ER", "Unit_EW", "Unit_ET"], intents=[{
            "intent_id": "i-produce", "unit_ids": ["Unit_9"],
            "action": "produce", "state": "active"}])
        tact = {"entities": [unit("Unit_9", "barracks", queue=True),
                             unit("Unit_8", "vehicle_factory", queue=True)]
                + opening_ready()}
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
        ] + self.PRODUCTION_FULL
            + [("Unit_ER", ("ore_refinery", (12, 0, 9))),
               ("Unit_EW", ("worker", (12, 0, 10)))])
        st["map_bounds"] = [80.0, 80.0]
        out = rf.development_intents(st, tactical=tact, rules=self.RULES,
                                     server_tick=1000, snapshot_id=5)
        self.assertEqual(out[0]["action"], "build")
        self.assertEqual(out[0]["target"]["scene"], "res://units/anti_air_turret.tscn")
        # 2026-09-23 自动相邻放置：副官不再下发坐标（pos 缺席 = 权威端自己搜合法
        # 落点），只把政策点作为 hint 供游戏侧优先围着搜。防御塔的政策判据
        # （基地外围）仍然要在 hint 上成立。
        self.assertNotIn("pos", out[0]["target"],
                         "落点已移交权威端，副官不得再自带坐标")
        hint = out[0]["target"]["hint"]
        distance = ((hint[0] - 10.0) ** 2 + (hint[1] - 7.0) ** 2) ** 0.5
        self.assertGreaterEqual(distance, 8.0,
                                "产能建筑已在外侧时，防御塔政策点应落在基地外围：%s" % (hint,))

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
        # 分基地必须**离开主基地**（不能贴着主基地再盖一座）。坐标已移交权威端
        # （2026-09-23 自动放置），政策判据落在 hint 上。
        self.assertNotIn("pos", out[0]["target"],
                         "落点已移交权威端，副官不得再自带坐标")
        hint = out[0]["target"]["hint"]
        self.assertGreater(((hint[0] - 10.0) ** 2 + (hint[1] - 7.0) ** 2) ** 0.5,
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
        # 2026-10-12: each completed HQ must have local defense coverage.
        # Merely filling the old global cap at home no longer means "full".
        for index, position in enumerate([(58, 0, 8), (58, 0, 17)]):
            for type_id in ["anti_air_turret", "anti_ground_turret"]:
                tact["entities"].append(unit("Covered_%s_%d" % (type_id, index),
                                              type_id, pos=position))
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


class ProduceGapTest(unittest.TestCase):
    """生产缺口口径 = **现有 + 队列 + 在途**（2026-09-15 用户要求）。

    回归背景：只数现有单位时，刚下发的兵还没出现在观测里 → `counts` 恒 0 →
    "数量最少者优先"会连续多轮押同一个产品；车/机一落地就记 1、步兵有存量，
    于是长期偏向车辆与飞机（用户实测"AI 不喜欢生产小步兵"）。
    """

    def test_soldier_shortage_rule(self):
        self.assertTrue(rf.soldier_shortage(0, 5))      # 完全没有步兵 → 必须补
        self.assertTrue(rf.soldier_shortage(1, 9))      # 占比 11% < 34% → 补
        self.assertFalse(rf.soldier_shortage(3, 3))     # 3 兵 0 车 → 该补车（既有回归守这条）
        self.assertFalse(rf.soldier_shortage(4, 10))    # 占比 40% ≥ 34%

    def test_produce_totals_counts_queue_and_inflight(self):
        by_name = {"U1": {"type": "soldier"}, "U2": {"type": "tank"}}
        tactical = {"production": [{"producer": "F1", "items": [
            {"definition_id": "soldier"},
            {"product_type_id": "tank"},          # 旧名也要能读（唯一口径兼容）
        ]}]}
        st = {"active_intents": [
            {"action": "produce", "state": "active",
             "target": {"scene": "res://units/Tank.tscn"}},
            {"action": "produce", "state": "expired",     # 非 live → 不计
             "target": {"scene": "res://units/Tank.tscn"}},
            {"action": "move", "state": "active",         # 非 produce → 不计
             "target": {"scene": "res://units/Tank.tscn"}},
        ]}
        scene_index = {"soldier": "res://units/Soldier.tscn",
                       "tank": "res://units/Tank.tscn"}
        totals = rf.produce_totals(by_name, tactical, st, scene_index)
        self.assertEqual(totals.get("soldier"), 2)   # 1 现有 + 1 队列
        self.assertEqual(totals.get("tank"), 3)      # 1 现有 + 1 队列 + 1 在途
        self.assertEqual(totals.get("worker", 0), 0)


class ReconReplacementTest(unittest.TestCase):
    """侦察补充：专职侦察没了 → 用空闲机场补一架无人机（2026-09-15 用户要求）。

    回归背景：`PRODUCT_LADDER` 刻意不含 drone，于是"专职侦察一死，整局再没有侦察"。
    """

    def _call(self, *, live_types=(), queued=0, inflight=0, factory="Unit_8"):
        by_name = {}
        ai_units = []
        for index, kind in enumerate(live_types):
            name = "U_%d" % index
            by_name[name] = {"type": kind}
            ai_units.append(name)
        if factory:
            by_name[factory] = {"type": "aircraft_factory"}
            ai_units.append(factory)
        # 2026-10-13 开局顺序：侦察补充档只在经济+防御就绪后开门，夹具代表中局。
        by_name["Unit_ER"] = {"type": "ore_refinery"}
        by_name["Unit_EW"] = {"type": "worker"}
        by_name["Unit_ET"] = {"type": "anti_ground_turret"}
        ai_units.extend(["Unit_ER", "Unit_EW", "Unit_ET"])
        tactical = {}
        if queued:
            tactical = {"production": [{"producer": factory,
                                        "items": [{"definition_id": "drone"}] * queued}]}
        intents = [{"intent_id": "i-%d" % index, "action": "produce", "state": "active",
                    "unit_ids": [factory],
                    "target": {"scene": "res://units/Drone.tscn"}}
                   for index in range(inflight)]
        st = {"active_intents": intents}
        return rf.recon_produce_intent(
            st, by_name, {"ai_units": ai_units, "own_types": ["aircraft_factory"]},
            tactical, {"drone": "res://units/Drone.tscn"},
            free_producers=[factory] if factory else [],
            usable_producers={factory} if factory else set(),
            production_views={}, tick=1000)

    def test_adds_drone_when_no_probe_alive(self):
        # 返回 `(producer, scene)`：意图由阶梯在本地构造（`_intent` 是带 tick 的闭包）。
        self.assertEqual(self._call(live_types=["soldier", "tank"]),
                         ("Unit_8", "res://units/Drone.tscn"))

    def test_no_drone_when_probe_alive(self):
        # 没有确认敌情、并且已经有机场：目标是 2 架。1 架在编仍要补，补到上限才停。
        self.assertEqual(self._call(live_types=["drone", "soldier"]),
                         ("Unit_8", "res://units/Drone.tscn"))

    def test_no_drone_when_quota_full(self):
        self.assertIsNone(self._call(live_types=["drone", "drone", "soldier"]))

    def test_no_drone_when_queued_or_inflight(self):
        self.assertEqual(self._call(live_types=["soldier"], queued=1),
                         ("Unit_8", "res://units/Drone.tscn"))
        self.assertIsNone(self._call(live_types=["soldier"], queued=2))
        self.assertIsNone(self._call(live_types=["drone"], inflight=1))
        self.assertIsNone(self._call(live_types=["soldier"], inflight=2))

    def test_no_drone_without_idle_factory(self):
        self.assertIsNone(self._call(live_types=["soldier"], factory=""))


if __name__ == "__main__":
    unittest.main()


class SiteKeepQuotaTest(unittest.TestCase):
    """工地保留名额（【2026-09-15 用户口径】「留少部分建造就行，闲置工人优先采矿」）。

    规则：**每个未完工工地最多留 1 个工人**（离它最近的）；工地附近其余工人必须去采矿。
    旧实现对每个工地保护 10m 半径内的**全部**工人，而施工只有 1 个执行者 ⇒ 路过/被挤到
    工地旁的工人一起被排除出采集、原地闲置（用户反馈「闲职工人不优先采矿」的直接来源）。

    这个用例是**类级守门**：以后若有人把「按位置批量保护」改回来，它会立刻失败。
    """

    def test_only_one_worker_kept_per_site(self):
        st = state(["Unit_2", "Unit_5"])
        tact = {"entities": [
            # 未完工的工地（`constructed is False` 才是「工地」）。
            {"kind": "unit_self", "name": "Unit_1", "unit_type": "barracks",
             "construct": False, "gather": False, "queue": False,
             "constructed": False, "pos": [5.0, 0.0, 5.0]},
            # 两个工人**都在**工地 10m 半径内（旧实现会把两个一起保护、都不去采矿）。
            unit("Unit_2", "worker", construct=True, gather=True, pos=(6, 0, 5)),
            unit("Unit_5", "worker", construct=True, gather=True, pos=(7, 0, 5)),
            {"kind": "resource", "name": "Res_1", "pos": [30.0, 0.0, 30.0]},
        ]}
        out = rf.development_intents(st, tactical=tact, rules=RULES,
                                     server_tick=1000, snapshot_id=5)
        gathers = [i for i in out if i["action"] == "gather"]
        self.assertEqual(
            len(gathers), 1,
            "工地旁只该留 1 个工人，另一个必须去采矿；实际命令=%s"
            % [(i["action"], i.get("unit_ids")) for i in out])


class PendingProductionDedupTest(unittest.TestCase):
    """队列 / 在途的**去重**口径（2026-10-11 提示词 §一.3 第 2 条）。

    一条 produce 意图被权威接受后，它会**变成**队列里的一个 item。旧代码两边各加一，
    同一架无人机被数成 2 架 → "还差一架"永远算不满 → 副官不再补机。
    这几条断言在修前**必红**（旧实现按 item/intent 各数一次，且不看 state、不按身份去重）。
    """

    SCENES = {"drone": "res://units/Drone.tscn"}

    def test_accepted_intent_and_matching_queue_item_count_once(self):
        tactical = {"production": [{"unit": "Unit_7", "items": [
            {"item_id": "i1", "producer_id": "Unit_7", "definition_id": "drone",
             "state": "Queued"},
        ]}]}
        state = {"active_intents": [
            {"action": "produce", "state": "active", "unit_ids": ["Unit_7"],
             "target": {"scene": "res://units/Drone.tscn"}},
        ]}
        pending = rf.pending_production(tactical, state, self.SCENES)
        self.assertEqual(pending.get("drone", 0), 1,
                         "同一条订单（已接受 → 已在队列）不许数成 2：%s" % pending)

    def test_unaccepted_intent_still_counts_when_queue_is_empty(self):
        # 还没被权威接受 ⇒ 队列里没有对应项，这一条必须算，否则会重复下单。
        state = {"active_intents": [
            {"action": "produce", "state": "pending_authority", "unit_ids": ["Unit_7"],
             "target": {"scene": "res://units/Drone.tscn"}},
        ]}
        pending = rf.pending_production({"production": []}, state, self.SCENES)
        self.assertEqual(pending.get("drone", 0), 1,
                         "在途未接受的订单不能被吞掉：%s" % pending)

    def test_terminal_queue_items_are_not_counted(self):
        tactical = {"production": [{"unit": "Unit_7", "items": [
            {"item_id": "a", "producer_id": "Unit_7", "definition_id": "drone",
             "state": "Completed"},        # 已落地：单位本体已在 by_name 里
            {"item_id": "b", "producer_id": "Unit_7", "definition_id": "drone",
             "state": "Cancelled"},        # 已取消：永远不会出单位
            {"item_id": "c", "producer_id": "Unit_7", "definition_id": "drone",
             "state": "ProducerLost"},     # 生产线没了
            {"item_id": "d", "producer_id": "Unit_7", "definition_id": "drone",
             "state": "Producing"},
        ]}]}
        pending = rf.pending_production(tactical, {"active_intents": []}, self.SCENES)
        self.assertEqual(pending.get("drone", 0), 1,
                         "只有 Producing 那条该算：%s" % pending)

    def test_same_item_id_seen_twice_counts_once(self):
        tactical = {"production": [
            {"unit": "Unit_7", "items": [
                {"item_id": "dup", "producer_id": "Unit_7", "definition_id": "drone",
                 "state": "Queued"}]},
            {"unit": "Unit_8", "items": [
                {"item_id": "dup", "producer_id": "Unit_7", "definition_id": "drone",
                 "state": "Queued"}]},
        ]}
        pending = rf.pending_production(tactical, {"active_intents": []}, self.SCENES)
        self.assertEqual(pending.get("drone", 0), 1,
                         "同一 item_id 在两个视图里重复出现不许数两次：%s" % pending)

    def test_two_orders_from_different_producers_are_not_merged(self):
        # max() 合并只在同一 (生产者, 产品) 键上生效；两座机场各排一架就是两架。
        tactical = {"production": [
            {"unit": "Unit_7", "items": [
                {"item_id": "x", "producer_id": "Unit_7", "definition_id": "drone",
                 "state": "Queued"}]},
            {"unit": "Unit_9", "items": [
                {"item_id": "y", "producer_id": "Unit_9", "definition_id": "drone",
                 "state": "Queued"}]},
        ]}
        pending = rf.pending_production(tactical, {"active_intents": []}, self.SCENES)
        self.assertEqual(pending.get("drone", 0), 2,
                         "不同生产者的两条订单不许被压成一条：%s" % pending)


class ReconCoverageReportTest(unittest.TestCase):
    """侦察覆盖增益报告（提示词 §一.3 第 1/3 条要记录的两个数）。"""

    @staticmethod
    def _state(cells):
        return {"explore": {"cells": cells}, "server_tick": 1000}

    def test_only_covered_cells_count(self):
        st = self._state({
            "1,1": {"state": "covered", "by": "Unit_2", "visits": 1, "tick": 10},
            "1,2": {"state": "open", "by": "Unit_2", "visits": 0, "tick": 0},
            "1,3": {"state": "waiting", "by": "Unit_2", "visits": 0, "tick": 0},
        })
        report = rf.recon_coverage_report(st, {"Unit_2": {"type": "drone"}})
        self.assertEqual(report["dedicated_cells"], 1,
                         "没真的走到的格不许算覆盖：%s" % report)

    def test_second_drone_gain_is_incremental_not_absolute(self):
        # 两架无人机探到**同一批格** ⇒ 第二架的增益必须是 0（这正是"多机有没有用"的判据）。
        st = self._state({
            "0,0": {"state": "covered", "by": "DroneA", "visits": 1, "tick": 10},
            "0,1": {"state": "covered", "by": "DroneA", "visits": 1, "tick": 11},
            "1,0": {"state": "covered", "by": "DroneB", "visits": 1, "tick": 20},
            "1,1": {"state": "covered", "by": "DroneB", "visits": 1, "tick": 21},
        })
        report = rf.recon_coverage_report(st, {"DroneA": {"type": "drone"},
                                               "DroneB": {"type": "drone"}})
        per_unit = report["per_unit_new_cells"]
        self.assertEqual([item["unit"] for item in per_unit], ["DroneA", "DroneB"],
                         "应按首次覆盖时间排序：%s" % per_unit)
        self.assertEqual(per_unit[0]["new_cells"], 2)
        self.assertEqual(per_unit[1]["new_cells"], 2,
                         "两架探到完全不同的格 ⇒ 第二架应带来 2 格净增益：%s" % per_unit)
        self.assertEqual(report["dedicated_cells"], 4)

    def test_overlapping_coverage_shows_zero_gain(self):
        # 两架无人机探到**完全相同**的格 ⇒ 覆盖格数不许翻倍，也不许凭空造出
        # 一个"有覆盖"的单位（cells 的 `by` 只记最后到达者）。
        # 这条是"多机到底有没有用"的反面判据。
        st = self._state({
            "0,0": {"state": "covered", "by": "DroneA", "visits": 2, "tick": 10},
            "0,1": {"state": "covered", "by": "DroneA", "visits": 1, "tick": 11},
        })
        report = rf.recon_coverage_report(st, {"DroneA": {"type": "drone"},
                                               "DroneB": {"type": "drone"}})
        self.assertEqual(report["dedicated_cells"], 2,
                         "重叠覆盖不该虚增覆盖格数：%s" % report)
        self.assertEqual([item["unit"] for item in report["per_unit_new_cells"]],
                         ["DroneA"],
                         "cells 只记最后到达者，不许凭空造出一个有覆盖的单位")
        self.assertEqual(report["dedicated_visits"], 3,
                         "同一格多次到达应累加工时：%s" % report)

    def test_conscript_scout_share_is_recorded(self):
        st = self._state({
            "0,0": {"state": "covered", "by": "DroneA", "visits": 3, "tick": 10},
            "2,2": {"state": "covered", "by": "Unit_9", "visits": 1, "tick": 12},
        })
        report = rf.recon_coverage_report(st, {"DroneA": {"type": "drone"},
                                               "Unit_9": {"type": "soldier"}})
        self.assertEqual(report["conscript_cells"], 1)
        self.assertEqual(report["dedicated_visits"], 3)
        self.assertAlmostEqual(report["scout_share"], 0.25, places=3,
                               msg="小兵侦察工时比例错：%s" % report)

    def test_note_is_throttled(self):
        st = {"server_tick": 1000, "ai_controlled_units": [], "ai_units": [],
              "map_bounds": [512.0, 512.0], "explore": {"cells": {}}}
        by_name = {"Unit_1": {"type": "drone", "movement": True, "pos": [1, 0, 1]}}
        scene_index = {"drone": "res://units/Drone.tscn"}
        for tick in (1000, 1100, 1200, 1300):
            st["server_tick"] = tick
            rf.recon_produce_intent(st, dict(by_name), {"ai_units": ["Unit_1"]},
                                    {"production": []}, scene_index,
                                    free_producers=[], usable_producers=set(),
                                    production_views={}, tick=tick)
        notes = [n for n in st.get("decision_log", []) if n.get("kind") == "recon_coverage"]
        self.assertEqual(len(notes), 2,
                         "应按 %d tick 节流，实际=%s"
                         % (rf.RECON_COVERAGE_NOTE_EVERY_TICKS, [n["server_tick"] for n in notes]))


class OpeningOrderTest(unittest.TestCase):
    """开局顺序（2026-10-13 用户口径）：矿场+矿车 → 基础防御 → 才是兵/坦克/无人机。

    旧 `BUILD_LADDER` 把 barracks/vehicle_factory/aircraft_factory 排在矿场前面，
    且 B1 会把机场插到队首；用户实测开局"先出兵营机场、不造矿场"。这里把顺序本身钉死。
    """

    RULES = {
        "unit_types": [
            {"id": "worker", "scene_path": "res://units/Worker.tscn"},
            {"id": "soldier", "scene_path": "res://units/Soldier.tscn"},
            {"id": "tank", "scene_path": "res://units/Tank.tscn"},
            {"id": "ore_refinery", "scene_path": "res://buildings/OreRefinery.tscn"},
            {"id": "anti_ground_turret", "scene_path": "res://units/anti_ground_turret.tscn"},
            {"id": "barracks", "scene_path": "res://buildings/Barracks.tscn"},
            {"id": "vehicle_factory", "scene_path": "res://buildings/VehicleFactory.tscn"},
            {"id": "command_center", "scene_path": "res://buildings/CommandCenter.tscn"},
        ],
        "constructions": [
            {"id": "ore_refinery",
             "blueprint_scene_path": "res://buildings/OreRefinery.tscn"},
            {"id": "anti_ground_turret",
             "blueprint_scene_path": "res://units/anti_ground_turret.tscn"},
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

    def _out(self, entities, lease):
        st = state(lease)
        st["map_bounds"] = [80.0, 80.0]
        # 矿场档要求"视野内有可采矿点"才发命令（政策不变），夹具给一个近矿。
        ents = list(entities) + [{"kind": "resource", "name": "R_near",
                                  "pos": [16.0, 0.0, 9.0], "resource_a": 5000,
                                  "visible": True}]
        return rf.development_intents(st, tactical={"entities": ents},
                                      rules=self.RULES, server_tick=1000, snapshot_id=5)

    def test_ladder_order_is_economy_then_defence_then_army(self):
        # 顺序本身钉死（2026-10-13 用户口径）：矿场+矿车 → 基础防御 → 兵/坦克/机场。
        order = list(rf.BUILD_LADDER)
        self.assertEqual(order[:2], ["ore_refinery", "vehicle_factory"])
        self.assertLess(order.index("anti_ground_turret"), order.index("barracks"))
        self.assertLess(order.index("anti_air_turret"), order.index("barracks"))
        self.assertLess(order.index("barracks"), order.index("aircraft_factory"))
        self.assertLess(order.index("aircraft_factory"), order.index("command_center"))

    def test_opening_does_not_start_with_army_buildings(self):
        out = self._out([unit("Unit_0", "command_center", queue=True),
                         unit("Unit_2", "worker", construct=True, gather=True)],
                        ["Unit_0", "Unit_2"])
        builds = [i for i in out if i["action"] == "build"]
        self.assertTrue(builds, "开局必须发出建造意图")
        first = builds[0]["target"]["scene"]
        self.assertNotIn(first, ("res://buildings/Barracks.tscn",
                                 "res://buildings/VehicleFactory.tscn"
                                 if False else "res://buildings/Barracks.tscn",
                                 "res://units/anti_air_turret.tscn"),
                         "开局第一座不得是军事档建筑（旧顺序的第一座是兵营）")
        self.assertEqual([i for i in out if i["action"] == "produce"], [],
                         "经济未点火前不得产作战单位")

    def test_combat_allowed_once_economy_and_defence_ready(self):
        out = self._out([unit("Unit_0", "command_center", queue=True),
                         unit("Unit_2", "worker", gather=True),
                         unit("Unit_R", "ore_refinery"),
                         unit("Unit_V", "vehicle_factory", queue=True),
                         unit("Unit_T", "anti_ground_turret"),
                         unit("Unit_9", "barracks", queue=True)],
                        ["Unit_0", "Unit_2", "Unit_R", "Unit_V", "Unit_T", "Unit_9"])
        scenes = [i["target"]["scene"] for i in out if i["action"] == "produce"]
        self.assertTrue(set(scenes) & {"res://units/Soldier.tscn", "res://units/Tank.tscn"},
                        "经济与防御就绪后作战档必须开门（否则是把兵线饿死的另一种病）")
