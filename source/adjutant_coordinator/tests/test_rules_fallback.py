# -*- coding: utf-8 -*-
"""规则兜底的防退化测试。

背景：本地模型链路任一环抖动都会让单轮卡满超时、部队全部空转。
兜底必须做到两件事：① 不抢模型的目标推理（只做事实可判定的事）；
② 产出的意图**必须能通过契约校验**，否则等于没兜底。
"""
import unittest

from adjutant_coordinator.graph import placement, rules_fallback
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


RULES_WITH_PRODUCERS = {
    "unit_types": [
        {"id": "worker", "scene_path": "res://source/match/units/Worker.tscn"},
        {"id": "command_center",
         "scene_path": "res://source/match/units/CommandCenter.tscn"},
        {"id": "barracks", "scene_path": "res://source/match/units/Barracks.tscn"},
        {"id": "soldier", "scene_path": "res://source/match/units/Infantry.tscn"},
    ],
    "productions": [
        {"product_type_id": "worker",
         "allowed_producer_type_ids": ["command_center"]},
        {"product_type_id": "soldier",
         "allowed_producer_type_ids": ["barracks"]},
    ],
}


def _war_state(*, soldiers=0, queued_soldiers=0, soldiers_in_flight=False):
    """兵营 + 满编工人 + N 个士兵的战场（用于兵力上限测试）。"""
    entities = [
        {"kind": "unit_self", "name": "Unit_0", "unit_type": "command_center",
         "pos": [10.0, 0.0, 7.0], "queue": True, "movement": False, "constructed": True},
        {"kind": "unit_self", "name": "Unit_1", "unit_type": "barracks",
         "pos": [14.0, 0.0, 7.0], "queue": True, "movement": False, "constructed": True},
        {"kind": "resource", "name": "Res_A", "pos": [40.0, 0.0, 2.0]},
    ]
    # 工人给足（否则阶梯 1.8 会先补工人，测不到出兵那一步）。
    for index in range(2, 8):
        entities.append({"kind": "unit_self", "name": "Unit_%d" % index,
                         "unit_type": "worker", "pos": [10.0 + index, 0.0, 10.0],
                         "gather": True, "construct": True, "movement": True})
    for index in range(soldiers):
        entities.append({"kind": "unit_self", "name": "Soldier_%d" % index,
                         "unit_type": "soldier", "pos": [20.0 + index * 0.5, 0.0, 20.0],
                         "movement": True, "constructed": True})
    production = [{"unit": "Unit_1", "queue_size": queued_soldiers, "items": [
        {"item_id": "item-%d" % i, "definition_id": "soldier", "state": "in_progress"}
        for i in range(queued_soldiers)]}]
    tactical = {"entities": entities, "production": production}
    active = []
    if soldiers_in_flight:
        active.append({"intent_id": "rule-produce-soldier-Unit_1-900", "action": "produce",
                       "unit_ids": ["Unit_1"], "state": "active", "target": {},
                       "issued_tick": 900, "expires_tick": 4000})
    return _state(units=["Unit_0", "Unit_1"] + ["Unit_%d" % i for i in range(2, 8)],
                  active=active), tactical


class ArmyCapTest(unittest.TestCase):
    """**兵力上限**守门（手册 04 §军队规模规划："接敌前坦克上限 60；达到上限停止产坦克"）。

    背景（2026-09-13 用户实测）：「游戏都到 20-30FPS 了，不应该为了 AI 副官而放弃游戏性能」。
    真凶链：生产结算修好 → 阶梯每轮无上限补兵 → **150 秒兵力 11 → 105** → 帧率被拖垮。
    手册早已把"无上限生产"列为禁止项（v4 实测 385 辆坦克既调不动也拖垮端点），
    这里把"达到上限就停手"钉成不变式。
    """

    def test_combat_production_stops_at_cap(self):
        cap = rules_fallback.COMBAT_UNIT_CAP
        state, tactical = _war_state(soldiers=cap)
        batch = _batch(state, tactical=tactical, rules=RULES_WITH_PRODUCERS)
        produces = [i for i in batch["intents"] if i["action"] == "produce"]
        self.assertEqual(produces, [], "到上限还出兵 = 无上限生产：%s" % produces)
        self.assertEqual(state["army_cap"]["deployed"], cap)
        self.assertEqual(state["army_cap"]["blocked"], 1, "被拦轮次要记账（不许静默跳过）")

    def test_one_below_cap_still_produces(self):
        """差一个也照常出兵（上限不是"提前停手"，是硬顶）。"""
        cap = rules_fallback.COMBAT_UNIT_CAP
        state, tactical = _war_state(soldiers=cap - 1)
        batch = _batch(state, tactical=tactical, rules=RULES_WITH_PRODUCERS)
        produces = [i for i in batch["intents"] if i["action"] == "produce"]
        self.assertTrue(produces, "没到上限就该继续补兵")
        self.assertEqual(produces[0]["target"]["producer"], "Unit_1")
        self.assertNotIn("army_cap", state)

    def test_queued_units_count_toward_cap(self):
        """队列里正在产的也要算 —— 只数已落地就是"边产边超编"。"""
        cap = rules_fallback.COMBAT_UNIT_CAP
        state, tactical = _war_state(soldiers=cap - 2, queued_soldiers=2)
        batch = _batch(state, tactical=tactical, rules=RULES_WITH_PRODUCERS)
        self.assertEqual([i for i in batch["intents"] if i["action"] == "produce"], [])
        self.assertEqual(state["army_cap"]["queued"], 2)

    def test_worker_production_is_not_capped(self):
        """上限只管作战单位：工人/经济照常（不许用"到上限"顺手把经济也停了）。"""
        cap = rules_fallback.COMBAT_UNIT_CAP
        state, tactical = _war_state(soldiers=cap)
        # 工人只剩 1 个（远低于目标）→ 即使兵力到顶也应当继续补工人。
        tactical["entities"] = [e for e in tactical["entities"]
                                if e.get("unit_type") != "worker"]
        tactical["entities"].append(
            {"kind": "unit_self", "name": "Unit_2", "unit_type": "worker",
             "pos": [10.0, 0.0, 10.0], "gather": True, "construct": True, "movement": True})
        state["ai_controlled_units"] = ["Unit_0", "Unit_1", "Unit_2"]
        batch = _batch(state, tactical=tactical, rules=RULES_WITH_PRODUCERS)
        produces = [i for i in batch["intents"] if i["action"] == "produce"]
        self.assertTrue(produces, "到兵力上限也必须能继续补工人")
        self.assertTrue(all(i["target"]["scene"].endswith("Worker.tscn") for i in produces))

    def test_blocked_counter_is_per_round(self):
        """同一轮里阶梯与并行填充各判一次 → `blocked` 只许 +1；**跨轮**才继续累加。"""
        cap = rules_fallback.COMBAT_UNIT_CAP
        state, tactical = _war_state(soldiers=cap)
        for index in range(3):
            tick = 1000 + index * 60        # 每轮 tick 前进（同一 tick = 同一轮）
            rules_fallback.batch_from_rules(
                state, tactical=tactical, rules=RULES_WITH_PRODUCERS, ttl_ticks=3600,
                server_tick=tick, snapshot_id=10)
            self.assertEqual(state["army_cap"]["blocked"], index + 1,
                             "轮次计数：第 %d 轮后应为 %d" % (index + 1, index + 1))
        self.assertEqual(state["army_cap"]["last_block_tick"], 1000 + 2 * 60)


#: 带 `capabilities` 的规则视图（**真实导出形状**：2026-09-13 由 `AdjutantRulesExportSmokeTest`
#: 打印确认 —— 每个类型都带 capabilities，炮塔有 attack 但**没有** move）。
COMBAT_RULES = {
    "unit_types": [
        {"id": "worker", "capabilities": {"gather": True, "construct": True, "move": True}},
        {"id": "soldier", "capabilities": {"move": True, "attack": True}},
        {"id": "tank", "capabilities": {"move": True, "attack": True}},
        {"id": "helicopter", "capabilities": {"move": True, "attack": True}},
        {"id": "apc", "capabilities": {"move": True, "attack": True}},
        {"id": "heavy_tank", "capabilities": {"move": True, "attack": True}},
        {"id": "transport_truck", "capabilities": {"move": True}},
        {"id": "drone", "capabilities": {"move": True}},
        # 固定防御：能打但不能动 —— **不算兵力**（否则 60 座炮塔就能吃满兵力上限）。
        {"id": "anti_air_turret", "capabilities": {"attack": True}},
        {"id": "anti_ground_turret", "capabilities": {"attack": True}},
        {"id": "command_center", "capabilities": {"produce": True}},
    ],
    "productions": [
        {"product_type_id": "soldier", "allowed_producer_type_ids": ["barracks"]},
    ],
}


class CombatVocabularyTest(unittest.TestCase):
    """作战单位口径**只有一处实现**（2026-09-13 收工自检：曾有三份硬编码副本）。

    三份副本各自的毛病：
    - `rules_fallback.COMBAT_TYPES` 漏 `apc` / `heavy_tank`（配置里都带武器）；
    - `behavior_tree` 的 cfg 写着 `vehicle` / `aircraft` —— 配置里**不存在**这两个 id，
      直升机（真实 id `helicopter`）因此漏计；
    - `campaign` 又抄一份常量。
    现在唯一实现 = `combat_types_from_rules()`（`attack ∧ move`），逐轮落进
    `state["combat_types"]`，谁都不许再抄。
    """

    def test_combat_types_derived_from_rules(self):
        derived = set(rules_fallback.combat_types_from_rules(COMBAT_RULES))
        self.assertEqual(derived, {"soldier", "tank", "helicopter", "apc", "heavy_tank"})
        self.assertNotIn("transport_truck", derived, "无武器的运输车不是作战单位")
        self.assertNotIn("worker", derived)
        self.assertNotIn("command_center", derived, "建筑不占兵力上限")

    def test_immobile_turrets_are_not_troops(self):
        """**能打 ≠ 是兵力**：固定炮塔能打但不能动 → 不占兵力上限、也不该被派去行军。

        依据（真机导出实测）：能打的类型是
        `[anti_air_turret, anti_ground_turret, apc, heavy_tank, helicopter, soldier, tank]`，
        其中前两个 `move=false`。只认 attack 的口径会让 60 座炮塔吃满兵力上限。
        """
        derived = set(rules_fallback.combat_types_from_rules(COMBAT_RULES))
        self.assertNotIn("anti_air_turret", derived)
        self.assertNotIn("anti_ground_turret", derived)

    def test_partial_capabilities_do_not_derive(self):
        """**能力字段必须齐全**：只给一部分类型带 capabilities → 不派生（否则口径残缺少算）。"""
        partial = {"unit_types": [
            {"id": "tank", "capabilities": {"move": True, "attack": True}},
            {"id": "worker"},                      # ← 没有能力字段
        ]}
        self.assertEqual(rules_fallback.combat_types_from_rules(partial), ())
        self.assertEqual(rules_fallback.combat_types_of({}, partial),
                         rules_fallback.COMBAT_TYPES, "残缺输入必须回退常量")

    def test_missing_capabilities_falls_back_to_constant(self):
        """规则视图缺能力字段（老配置/夹具）→ 不派生，回退常量（保守，行为不变）。"""
        self.assertEqual(rules_fallback.combat_types_from_rules({"unit_types": [{"id": "tank"}]}), ())
        self.assertEqual(rules_fallback.combat_types_of({}), rules_fallback.COMBAT_TYPES)

    def test_state_field_wins_over_rules(self):
        """`state["combat_types"]`（本轮由 node_ingest 派生）优先于现算与常量。"""
        state = {"combat_types": ["apc"]}
        self.assertEqual(rules_fallback.combat_types_of(state, COMBAT_RULES), ("apc",))

    def test_apc_counts_toward_cap_only_with_derived_vocabulary(self):
        """口径统一的**实际后果**：APC 占不占兵力上限，取决于用派生口径还是硬编码常量。"""
        cap = rules_fallback.COMBAT_UNIT_CAP
        rules_with_caps = dict(RULES_WITH_PRODUCERS)
        # 能力字段必须**齐全**才会派生（残缺输入一律回退常量），所以这里给全。
        rules_with_caps["unit_types"] = [
            {"id": "worker", "capabilities": {"gather": True, "construct": True, "move": True}},
            {"id": "command_center", "capabilities": {"produce": True}},
            {"id": "barracks", "capabilities": {"produce": True}},
            {"id": "soldier", "capabilities": {"move": True, "attack": True}},
            {"id": "tank", "capabilities": {"move": True, "attack": True}},
            {"id": "helicopter", "capabilities": {"move": True, "attack": True}},
            {"id": "apc", "capabilities": {"move": True, "attack": True}},
            {"id": "anti_ground_turret", "capabilities": {"attack": True}},
        ]

        def build():
            state, tactical = _war_state(soldiers=cap - 1)
            tactical["entities"].append(
                {"kind": "unit_self", "name": "Unit_9", "unit_type": "apc",
                 "pos": [22.0, 0.0, 22.0], "movement": True, "constructed": True})
            state["ai_controlled_units"] = list(state["ai_controlled_units"]) + ["Unit_9"]
            return state, tactical

        # ① 无能力字段 → 回退常量（不数 apc）→ 未到上限，照常出兵。
        state_a, tactical_a = build()
        batch_a = _batch(state_a, tactical=tactical_a, rules=RULES_WITH_PRODUCERS)
        self.assertTrue([i for i in batch_a["intents"] if i["action"] == "produce"],
                        "回退口径下 apc 不计入，仍应能补兵")
        # ② 带能力字段 → 派生口径含 apc → 到顶 → 停发作战生产。
        state_b, tactical_b = build()
        batch_b = _batch(state_b, tactical=tactical_b, rules=rules_with_caps)
        self.assertEqual([i for i in batch_b["intents"] if i["action"] == "produce"], [],
                         "派生口径下 apc 计入兵力 → 到上限必须停手")
        self.assertEqual(state_b["army_cap"]["deployed"], cap)


class BuildSpotExhaustionTest(unittest.TestCase):
    """**候选全不可用时宁可不建**（2026-09-14 迭代3 真机现场）。

    实测：`pick_build_spot` 的最后兜底直接返回 `clamp_into_bounds(anchor)` = **基地自身坐标**，
    而它必然 `SurfaceNotBuildable` → 同一个点被拒 **13 次**（拒绝账本记了也没用：
    这条兜底路径**绕过账本**）。用户原话："你下达命令不能瞎下达"。
    """

    BY_NAME = {"Unit_0": {"name": "Unit_0", "type": "command_center",
                          "pos": [10.0, 0.0, 7.0]}}

    def _ban_around(self, ledger, *, radius=12):
        """把锚点周围 `radius` 米内的**所有网格点**拉黑（含 retreat 的 3/5/7m 步进）。"""
        for dx in range(-radius, radius + 1):
            for dz in range(-radius, radius + 1):
                for _ in range(placement.RejectionLedger.BAN_AFTER):
                    ledger.add(placement.REJECT_GEOMETRY,
                               placement.spot_key((10.0 + dx, 7.0 + dz)), 1000)

    def test_never_returns_a_banned_spot(self):
        """**不变式**：返回值要么是空，要么是一个"没被拉黑"的点。

        这是客户可感知的判据 —— 返回被拉黑的点 = 又发一条注定被拒的命令。
        """
        ledger = placement.RejectionLedger()
        for key in ("10,7", "10,10", "10,4", "14,7", "7,7", "6,7"):
            for _ in range(3):
                ledger.add(placement.REJECT_GEOMETRY, key, 1000)
        spot = rules_fallback.pick_build_spot(
            self.BY_NAME, [], [10.0, 7.0], blocked=ledger, bounds=[80.0, 80.0], state={})
        if spot:
            self.assertFalse(placement.is_banned(ledger, spot),
                             "返回了被拉黑的点：%s" % (spot,))

    def test_model_build_menu_excludes_banned_spots(self):
        """**模型侧的落点菜单**也必须过账本：菜单里出现坏点 = 把注定被拒的命令放进选项。

        （2026-09-14 迭代3 现场：`squads.build_decision_frame` 生成候选时**没传 rejected**，
        兜底还直接给基地坐标 → 模型选中坏点 → 又一次 `SurfaceNotBuildable`。）
        """
        from adjutant_coordinator.graph import squads

        ledger = placement.RejectionLedger()
        self._ban_around(ledger, radius=10)
        entities = [
            {"kind": "unit_self", "name": "Unit_0", "unit_type": "command_center",
             "queue": True, "pos": [10.0, 0.0, 7.0]},
            {"kind": "unit_self", "name": "Unit_1", "unit_type": "worker",
             "gather": True, "construct": True, "movement": True, "pos": [11.0, 0.0, 8.0]},
        ]
        frame = squads.build_decision_frame(
            match_id="m", player_id="p", rules_version="r", snapshot_id=1, server_tick=60,
            tactical={"server_tick": 60, "snapshot_id": 1, "entities": entities},
            rules={"unit_types": [], "productions": []},
            authorized_units={"Unit_1"}, map_bounds=[64.0, 64.0], rejected=ledger)
        for spot in frame.build_spots or []:
            self.assertFalse(placement.is_banned(ledger, spot),
                             "模型菜单里出现了被拉黑的落点：%s" % (spot,))

    def test_exhausted_candidates_return_empty_and_record(self):
        """候选与兜底全不可用 → **不发命令**（`[]`）+ 留痕（复盘要能看出为什么没建）。"""
        ledger = placement.RejectionLedger()
        self._ban_around(ledger)
        state = {"server_tick": 2000}
        spot = rules_fallback.pick_build_spot(
            self.BY_NAME, [], [10.0, 7.0], blocked=ledger, bounds=[80.0, 80.0], state=state)
        self.assertEqual(spot, [], "没有可用落点时必须不发（旧实现返回基地坐标 → 被拒 13 次）")
        kinds = [entry.get("kind") for entry in state.get("decision_log") or []]
        self.assertIn("build_spot_exhausted", kinds, "不发命令必须留痕（否则复盘查不出为什么没建）")


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


class TurretPerimeterTest(unittest.TestCase):
    """防御塔必须落在当前视野最外围，不能套在指挥中心旁边。"""

    BOUNDS = [80.0, 80.0]
    HQ = [10.0, 7.0]

    def _by_name(self, extras=None):
        units = {
            "Unit_0": {"type": "command_center", "queue": True,
                       "pos": [10.0, 0.0, 7.0]},
            "Unit_2": {"type": "worker", "gather": True, "construct": True,
                       "pos": [11.0, 0.0, 8.0]},
        }
        if extras:
            units.update(extras)
        return units

    def _own_points(self, by_name):
        return [(float(info["pos"][0]), float(info["pos"][2]))
                for info in by_name.values() if info.get("pos")]

    def test_prefers_outer_when_base_has_outer_buildings(self):
        by_name = self._by_name({
            "Unit_4": {"type": "barracks", "pos": [22.0, 0.0, 7.0]},
            "Unit_5": {"type": "vehicle_factory", "pos": [4.0, 0.0, 7.0]},
        })
        spot = rules_fallback.pick_turret_spot(
            by_name, [], self.HQ, bounds=self.BOUNDS)
        self.assertTrue(spot, "必须给出防御塔落点")
        distance = ((spot[0] - self.HQ[0]) ** 2 + (spot[1] - self.HQ[1]) ** 2) ** 0.5
        self.assertGreaterEqual(distance, 8.0,
                                "有外侧建筑时塔应落在视野外圈，不应贴指挥中心：%s" % (spot,))
        self.assertIsNone(placement.spot_issue(spot, self.BOUNDS, self._own_points(by_name)))

    def test_stays_in_vision(self):
        by_name = self._by_name()
        spot = rules_fallback.pick_turret_spot(
            by_name, [], self.HQ, bounds=self.BOUNDS)
        self.assertTrue(spot)
        nearest = placement.first_own_distance(spot, self._own_points(by_name))
        self.assertLessEqual(nearest, placement.VISION_SAFE_RADIUS_M + 0.05)

    def test_does_not_walk_far_outside_base(self):
        """不许把塔建到基地外缘带之外（用户 2026-09-15 晚实测："太靠外面了"）。

        给一座 24m 外的兵营当视野锚点：旧口径"越远越优先"会沿着它把塔推到视野边缘；
        新口径（`placement.turret_band_rank`）必须仍把塔留在基地外缘带附近。
        """
        by_name = self._by_name({
            "Unit_4": {"type": "barracks", "pos": [34.0, 0.0, 7.0]},
        })
        spot = rules_fallback.pick_turret_spot(
            by_name, [], self.HQ, bounds=self.BOUNDS)
        self.assertTrue(spot, "必须给出防御塔落点")
        distance = ((spot[0] - self.HQ[0]) ** 2 + (spot[1] - self.HQ[1]) ** 2) ** 0.5
        self.assertLessEqual(
            distance, placement.TURRET_BAND_OUTER_M + 1.5,
            "塔不该建到基地外缘带之外：%s（距基地 %.1fm）" % (spot, distance))

    def test_spreads_from_existing_turret(self):
        by_name = self._by_name({
            "Unit_4": {"type": "barracks", "pos": [22.0, 0.0, 7.0]},
            "Unit_11": {"type": "anti_air_turret", "pos": [26.0, 0.0, 7.0]},
        })
        spot = rules_fallback.pick_turret_spot(
            by_name, [], self.HQ, bounds=self.BOUNDS)
        self.assertTrue(spot)
        overlap = ((spot[0] - 26.0) ** 2 + (spot[1] - 7.0) ** 2) ** 0.5
        self.assertGreaterEqual(overlap, 3.0, "第二座塔不应叠在第一座上：%s" % (spot,))


if __name__ == "__main__":
    unittest.main()
