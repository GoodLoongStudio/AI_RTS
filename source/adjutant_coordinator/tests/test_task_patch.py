# -*- coding: utf-8 -*-
"""四列任务修改（TaskPatchBatch）+ 引用表（DecisionFrame）单测。

覆盖（对应计划 §2.1/§2.2 与实施顺序门槛 1）：
- 引用表确定性：同一观测两次生成 ref 完全一致；
- 逐行独立校验：某行非法不影响其它行（非原子批次，逐项回执）；
- 能力匹配：actor 类别 → 技能、技能 → 目标类别、生产/建造必须整条取自候选；
- 元数据继承：generation / expires_tick / plan_version 只能来自 DecisionFrame；
- 容量：超出模式行数的部分被显式拒绝（reason=row_limit_exceeded）。
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))))

from adjutant_coordinator.graph.squads import build_decision_frame  # noqa: E402
from adjutant_coordinator.graph.task_patch import (  # noqa: E402
    MODE_DEEP, MODE_FAST, SKILL_ATTACK, SKILL_BUILD, SKILL_GATHER, SKILL_PRODUCE,
    TaskPatchBatch, decode_task_patch, modifications_to_intents, parse_task_patch,
)

RULES = {
    "unit_types": [
        {"id": "worker", "scene_path": "res://units/Worker.tscn"},
        {"id": "soldier", "scene_path": "res://units/Soldier.tscn"},
        {"id": "command_center", "scene_path": "res://units/CommandCenter.tscn"},
    ],
    "constructions": [
        {"id": "barracks", "blueprint_scene_path": "res://buildings/Barracks.tscn"},
    ],
    "productions": [
        {"product_type_id": "worker", "allowed_producer_type_ids": ["command_center"]},
        {"product_type_id": "soldier", "allowed_producer_type_ids": ["barracks"]},
    ],
}


def _unit(name, unit_type, pos, **flags):
    entity = {"kind": "unit_self", "name": name, "unit_type": unit_type,
              "pos": [pos[0], 0.0, pos[1]], "hp": 100.0, "hp_max": 100.0,
              "movement": True, "construct": False, "gather": False, "queue": False}
    entity.update(flags)
    return entity


def _enemy(name, pos):
    return {"kind": "unit_enemy", "name": name, "pos": [pos[0], 0.0, pos[1]]}


def _resource(name, pos):
    return {"kind": "resource", "name": name, "pos": [pos[0], 0.0, pos[1]]}


def _tactical():
    return {
        "server_tick": 4242, "snapshot_id": 4242,
        "entities": [
            _unit("Unit_0", "command_center", (0, 0), movement=False, queue=True),
            _unit("Unit_2", "worker", (5, 5), gather=True, construct=True),
            _unit("Unit_4", "soldier", (20, 20)),
            _unit("Unit_5", "soldier", (21, 20)),
            _enemy("Unit_9", (40, 40)),
            _resource("ResourceA", (12, 6)),
        ],
    }


def _ref_for_product(frame, scene):
    """按产物 id 反查本轮的 U*/V* ref（候选按 id 排序，测试不写死编号）。"""
    for ref, entry in frame.targets.items():
        if entry.get("kind") == "product" and entry.get("scene") == scene:
            return ref
    raise AssertionError("本轮候选里没有 %s" % scene)


def _frame(**overrides):
    params = dict(
        match_id="m1", player_id="Player_0", rules_version="rv1",
        snapshot_id=4242, server_tick=4242, tactical=_tactical(), rules=RULES,
        mode=MODE_FAST, plan_version="p:v1",
        generations={"Unit_4": 7, "Unit_5": 7, "Unit_2": 3},
        task_versions={"S1": 2, "W1": 1, "F1": 4},
        intent_ttl_ticks=3600, emergency_intent_ttl_ticks=1200,
    )
    params.update(overrides)
    return build_decision_frame(**params)


class RefTableTests(unittest.TestCase):

    def test_actors_cover_squad_worker_facility(self):
        frame = _frame()
        kinds = {actor["kind"] for actor in frame.actors.values()}
        self.assertEqual(kinds, {"squad", "worker", "facility"})
        # 两个士兵同格 → 同一小队；指挥中心是 F1；两个工人能力 → W1
        self.assertIn("S1", frame.actors)
        self.assertEqual(frame.actors["S1"]["units"], ["Unit_4", "Unit_5"])
        self.assertEqual(frame.actors["F1"]["units"], ["Unit_0"])
        self.assertEqual(frame.actors["F1"]["products"], ["worker"])
        self.assertEqual(frame.actors["W1"]["buildings"], ["barracks"])

    def test_targets_and_params_present(self):
        frame = _frame()
        self.assertEqual(frame.targets["E1"]["entity_id"], "Unit_9")
        self.assertEqual(frame.targets["R1"]["entity_id"], "ResourceA")
        self.assertIn("B1", frame.targets)          # 主基地锚点
        self.assertIn("L1", frame.targets)          # 基地点位
        self.assertIn("U1", frame.targets)          # 可生产单位
        self.assertIn("V1", frame.targets)          # 可建造建筑
        self.assertEqual(frame.targets["V1"]["scene"], "barracks")
        self.assertIn("P0", frame.params)
        self.assertIn("Q4", frame.params)
        self.assertTrue(frame.build_spots)

    def test_deterministic(self):
        first, second = _frame(), _frame()
        self.assertEqual(sorted(first.actors), sorted(second.actors))
        self.assertEqual(sorted(first.targets), sorted(second.targets))
        self.assertEqual(first.actors, second.actors)

    def test_new_member_joins_existing_squad(self):
        tactical = _tactical()
        tactical["entities"].append(_unit("Unit_6", "soldier", (22, 21)))
        frame = build_decision_frame(
            match_id="m1", player_id="P", rules_version="rv1", snapshot_id=1,
            server_tick=1, tactical=tactical, rules=RULES)
        self.assertEqual(frame.actors["S1"]["units"], ["Unit_4", "Unit_5", "Unit_6"])

    def test_hidden_units_excluded_when_unauthorized(self):
        frame = _frame(authorized_units={"Unit_4", "Unit_5"})
        self.assertEqual(sorted(frame.actors), ["S1"])
        self.assertEqual(frame.actors["S1"]["units"], ["Unit_4", "Unit_5"])


class DecodeTests(unittest.TestCase):

    def test_valid_rows_decode(self):
        frame = _frame()
        worker_ref = _ref_for_product(frame, "worker")
        # 本轮 3 个执行者（S1/W1/F1）→ 行上限 = min(模式容量, 3) = 3。
        batch = TaskPatchBatch(u=[["S1", "ATK", "E1", "P2"],
                                  ["W1", "GAT", "R1", "P0"],
                                  ["F1", "PROD", worker_ref, "Q4"],
                                  ["W1", "BLD", _ref_for_product(frame, "barracks"),
                                   "P0"]])
        result = decode_task_patch(batch, frame)
        self.assertEqual(len(result.modifications), 3)
        # 第 4 行超本轮容量（3）→ 容量先行判定。
        self.assertEqual([item.reason for item in result.rejections],
                         ["row_limit_exceeded"])
        attack = result.modifications[0]
        self.assertEqual(attack.action, "attack")
        self.assertEqual(attack.target["entity_id"], "Unit_9")
        self.assertEqual(attack.generations, {"Unit_4": 7, "Unit_5": 7})
        self.assertEqual(attack.task_version, 2)
        produce = result.modifications[2]
        self.assertEqual(produce.target["scene"], "worker")
        self.assertEqual(produce.target_ref, worker_ref)
        self.assertEqual(produce.params["qty"], 4)

    def test_build_row_gets_program_placement(self):
        """BLD 只用建筑候选 ref；落点由程序挑候选（模型不猜坐标）。"""
        frame = _frame()
        result = decode_task_patch(TaskPatchBatch(u=[
            ["W1", "BLD", _ref_for_product(frame, "barracks"), "P0"]]), frame)
        self.assertEqual(len(result.modifications), 1)
        build = result.modifications[0]
        self.assertEqual(build.target["scene"], "barracks")
        self.assertTrue(build.target.get("pos"), "BLD 落点必须由程序补齐")
        self.assertIn(tuple(build.target["pos"]), frame.build_spots)

    def test_build_placement_prefers_clear_spot(self):
        """落点优先"空"（离已占用点最远），不是"离执行者最近"。

        实测依据（2026-09-12 用户反馈）：按最近挑点 + 候选半径只有 12m 时，
        barracks/vehicle_factory 落在指挥中心 5m 内，3 个工人被堵在 1.5m 口袋里。
        """
        from adjutant_coordinator.graph.task_patch import DecisionFrame, _build_placement
        frame = DecisionFrame(
            match_id="m", player_id="P", rules_version="r", snapshot_id=1,
            server_tick=1, mode="fast",
            build_spots=((10.0, 0.0), (50.0, 0.0)),
            occupied_points=((9.0, 0.0), (8.0, 0.0), (11.0, 0.0)))
        chosen = _build_placement(frame, {"ref": "W1", "pos": [10.5, 0.0]})
        self.assertEqual(chosen, [50.0, 0.0],
                         "近处落点被己方单位占满时必须改选空落点")

    def test_build_spots_are_rings_not_a_single_tight_circle(self):
        """落点候选必须覆盖多圈（避免所有建筑挤在基地一圈）。"""
        frame = _frame()
        self.assertGreaterEqual(len(frame.build_spots), 8)
        radii = sorted({round((x ** 2 + z ** 2) ** 0.5) for x, z in frame.build_spots})
        self.assertGreaterEqual(len(radii), 2, "应有多圈半径：%s" % radii)

    def test_prompt_renders_balance_and_development_menu(self):
        """模型必须能看到余额 + 一张**候选菜单**（计划 §二/§七§3：候选而非全量清单）。"""
        import dataclasses

        from adjutant_coordinator.graph.task_patch_prompt import render_compact_text
        frame = _frame()
        text = render_compact_text(dataclasses.replace(frame, balance={"a": 5000, "b": 0}))
        self.assertIn("余额: a=5000", text)
        self.assertIn("本轮发展骨架", text, "发展菜单必须置顶且显眼")
        self.assertIn("维持现有任务", text, "候选菜单必须保留「维持」选项")
        # 生产候选的数量提示必须是 Q2（计划 §三"不占满生产队列"，不是 Q8）
        self.assertNotIn("Q8", text)

    def test_row_level_rejection_does_not_block_others(self):
        frame = _frame()
        result = decode_task_patch(TaskPatchBatch(u=[
            ["S9", "ATK", "E1", "P0"],        # 未知 actor
            ["S1", "GAT", "R1", "P0"],        # 小队不能采集
            ["S1", "ATK", "R1", "P0"],        # 目标类别不匹配
            ["S1", "ATK", "E1", "P0"],        # 合法（但第 4 行超本轮行上限）
        ]), frame, max_rows=4)
        self.assertEqual(len(result.modifications), 1)
        reasons = [item.reason for item in result.rejections]
        self.assertEqual(reasons, ["unknown_actor", "skill_not_allowed_for_actor",
                                   "target_kind_mismatch"])
        # 合法行不受前面非法行影响：它就是第 4 行（索引 3）解出来的。
        self.assertEqual(result.modifications[0].row_index, 3)

    def test_duplicate_actor_rejected(self):
        frame = _frame()
        result = decode_task_patch(TaskPatchBatch(u=[
            ["W1", "GAT", "R1", "P0"],
            ["W1", "GAT", "R1", "P0"],        # 同一执行者第二条：只保留第一条
        ]), frame)
        self.assertEqual(len(result.modifications), 1)
        self.assertEqual(result.rejections[0].reason, "duplicate_actor")

    def test_effective_max_rows_never_exceeds_actors(self):
        from adjutant_coordinator.graph.task_patch import effective_max_rows
        frame = _frame()                      # 3 个执行者
        self.assertEqual(effective_max_rows(frame), 3)
        self.assertEqual(effective_max_rows(_frame(mode=MODE_DEEP)), 3)
        # 执行者多于模式容量时，才轮到容量生效（fast 6）。
        from adjutant_coordinator.graph.squads import build_decision_frame
        tactical = _tactical()
        tactical["entities"] = [e for e in tactical["entities"]
                                if not str(e.get("kind", "")).startswith("unit_enemy")]
        for index in range(10):          # 彼此拉开 60m → 各自成小队
            tactical["entities"].append(_unit("Unit_%d" % (20 + index), "soldier",
                                              (60 + index * 60, 60)))
        wide = build_decision_frame(
            match_id="m", player_id="P", rules_version="r", snapshot_id=1,
            server_tick=1, tactical=tactical, rules=RULES)
        self.assertGreaterEqual(len(wide.actors), 6)
        self.assertEqual(effective_max_rows(wide), 6)

    def test_unknown_skill_params_and_arity(self):
        frame = _frame()
        # 结构层（TaskPatchBatch）已强制 4 列；列数错误走原始输入路径（回放/日志重放）。
        result = decode_task_patch({"u": [["S1", "FLY", "E1", "P0"],
                                          ["S1", "ATK", "E1", "P9"],
                                          ["S1", "ATK", "E1"]]}, frame)
        self.assertEqual([item.reason for item in result.rejections],
                         ["unknown_skill", "unknown_params", "bad_arity"])

    def test_produce_must_match_facility_capability(self):
        frame = _frame()
        # 规则视图里 soldier 只允许 barracks，而场上没有 barracks → 指挥中心只能产 worker。
        soldier_ref = _ref_for_product(frame, "soldier")
        result = decode_task_patch(
            TaskPatchBatch(u=[["F1", "PROD", soldier_ref, "Q1"]]), frame)
        self.assertEqual(len(result.rejections), 1)
        self.assertEqual(result.rejections[0].reason, "capability_mismatch")

    def test_row_limit_by_mode(self):
        """容量按模式生效；显式 max_rows 用于隔离测试容量本身。"""
        from adjutant_coordinator.graph.task_patch import MODE_LIMITS
        self.assertEqual(MODE_LIMITS[MODE_FAST]["max_rows"], 6)
        self.assertEqual(MODE_LIMITS[MODE_DEEP]["max_rows"], 10)
        # 用不同的执行者，避免 duplicate_actor 干扰容量判定。
        rows = [["S1", "ATK", "E1", "P0"], ["W1", "GAT", "R1", "P0"],
                ["F1", "PROD", _ref_for_product(_frame(), "worker"), "Q1"],
                ["S1", "RET", "L1", "P0"]]
        result = decode_task_patch(TaskPatchBatch(u=rows), _frame(), max_rows=3)
        self.assertEqual(len(result.modifications), 3)
        self.assertEqual([item.reason for item in result.rejections],
                         ["row_limit_exceeded"])

    def test_no_target_skills(self):
        frame = _frame()
        result = decode_task_patch(TaskPatchBatch(u=[["S1", "HOLD", "-", "P0"]]), frame)
        self.assertEqual(len(result.modifications), 1)
        rejected = decode_task_patch(TaskPatchBatch(u=[["S1", "HOLD", "E1", "P0"]]),
                                     frame)
        self.assertEqual(rejected.rejections[0].reason, "target_not_applicable")

    def test_unchanged_task_is_confirmed_not_dispatched(self):
        """复述现状的行（= 执行者当前任务）只确认，**不下发新命令**。

        实测依据（2026-09-12 用户反馈）：模型没有记忆，每轮重发"W1 采集 R13"，
        若不判定未变化，工人采集会被反复下令（行为树本来就会自己循环）。
        """
        frame = _frame(current_tasks={"Unit_2": {"skill": "GAT",
                                                 "target": {"entity_id": "ResourceA"}}})
        batch = TaskPatchBatch(u=[["W1", "GAT", "R1", "P0"]])
        result = decode_task_patch(batch, frame)
        self.assertEqual(len(result.modifications), 1)
        self.assertTrue(result.modifications[0].unchanged)
        self.assertEqual(len(result.unchanged), 1)
        self.assertEqual(result.changed, [])
        # 关键：不下发（否则就是"重复命令"）
        intents = modifications_to_intents(result, frame)
        self.assertEqual(intents.intents, [])

    def test_changed_task_still_dispatches(self):
        frame = _frame(current_tasks={"Unit_2": {"skill": "GAT",
                                                 "target": {"entity_id": "ResourceA"}}})
        result = decode_task_patch(TaskPatchBatch(u=[["W1", "BLD",
                                                      _ref_for_product(frame, "barracks"),
                                                      "P0"]]), frame)
        self.assertEqual(len(result.changed), 1)
        self.assertEqual(len(modifications_to_intents(result, frame).intents), 1)

    def test_empty_patch_means_no_change(self):
        result = decode_task_patch(TaskPatchBatch(u=[]), _frame())
        self.assertEqual(result.modifications, [])
        self.assertEqual(result.rejections, [])

    def test_structural_layer_is_lenient_and_decoder_rejects_per_row(self):
        """结构层不再整批否决：列数不对的行照样解析，由解码器**逐行**拒绝。

        实测依据（2026-09-12）：结构层硬校验"每行 4 项"会让 PydanticAI 整批重试，
        而模型重试最省事的答案是 `{"u":[]}` → 每轮 0 任务、游戏里毫无变化。
        """
        from adjutant_coordinator.graph.task_patch import decode_task_patch
        batch = parse_task_patch({"u": [["S1", "ATK", "E1"],           # 3 列 → 该行被拒
                                        ["S1", "ATK", "E1", "P0"]]})  # 4 列 → 正常
        self.assertEqual(len(batch.u), 2)
        result = decode_task_patch(batch, _frame())
        self.assertEqual(len(result.modifications), 1)
        self.assertEqual([item.reason for item in result.rejections], ["bad_arity"])

    def test_parse_accepts_non_dict_via_model_validate(self):
        from adjutant_coordinator.graph.contracts import ContractError
        with self.assertRaises(ContractError):
            parse_task_patch({"u": "不是数组"})


class IntentExpansionTests(unittest.TestCase):

    def test_metadata_comes_from_frame(self):
        frame = _frame()
        result = decode_task_patch(TaskPatchBatch(u=[["S1", "ATK", "E1", "P2"]]), frame)
        batch = modifications_to_intents(result, frame)
        intent = batch.intents[0]
        self.assertEqual(intent.plan_version, "p:v1")
        self.assertEqual(intent.based_on_snapshot, 4242)
        self.assertEqual(intent.issued_tick, 4242)
        self.assertEqual(intent.generation, 7)
        self.assertEqual(intent.target["entity_id"], "Unit_9")

    def test_emergency_skill_uses_shorter_ttl(self):
        frame = _frame()
        result = decode_task_patch(TaskPatchBatch(u=[["S1", "RET", "L1", "P0"]]), frame)
        intent = modifications_to_intents(result, frame).intents[0]
        self.assertEqual(intent.expires_tick, 4242 + 1200)

    def test_produce_expansion_carries_producer(self):
        frame = _frame()
        worker_ref = _ref_for_product(frame, "worker")
        result = decode_task_patch(
            TaskPatchBatch(u=[["F1", "PROD", worker_ref, "Q2"]]), frame)
        intent = modifications_to_intents(result, frame).intents[0]
        self.assertEqual(intent.action, "produce")
        self.assertEqual(intent.target["producer"], "Unit_0")
        self.assertEqual(intent.target["scene"], "worker")


if __name__ == "__main__":
    unittest.main()
