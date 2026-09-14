# -*- coding: utf-8 -*-
"""任务进度监督测试（方案 §4：命令接受回执与任务执行结果分开）。

全部用例只喂**观测事实**，断言进度是从观测差分推出来的，而不是把 Accepted 当成功。
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph.progress import track_task_progress
from adjutant_coordinator.graph.state import (
    INTENT_ACTIVE, INTENT_ACTIVE_UNKNOWN, INTENT_COMPLETED, INTENT_FAILED,
    INTENT_LIVE_STATES, TASK_COMPLETED, TASK_FAILED, TASK_RUNNING, TASK_UNKNOWN,
)


def assert_unknown_keeps_occupancy(case, item, state, task_id="t-1"):
    """未知 ≠ 失败，且**继续占用单位**（2026-09-12 契约修正）。

    实测依据：旧契约把"连续无进展 / 单位或目标脱离视野 / 队列项消失但没看到新单位"
    判成 `failed` → 单位立刻被释放 → 微操层下一轮重发同一条命令
    （同局 `Unit_3|gather` 22 次、`Unit_5|gather` 21 次，47/50 条意图被标 failed）。
    计划明确：任务失败只能来自**权威回执**，不能用观测时序推断。

    任务状态：意图仍在 `INTENT_LIVE_STATES` 里 → 任务仍是**运行中**
    （只有权威回执给出终态才允许把任务标完成/失败）。
    """
    case.assertEqual(item["state"], INTENT_ACTIVE_UNKNOWN)
    case.assertIn(item["state"], INTENT_LIVE_STATES)
    case.assertEqual(state["active_tasks"][task_id], TASK_RUNNING)


def make_state(intents):
    return {"server_tick": 0, "active_intents": intents, "active_tasks": {}}


def intent(intent_id, action, units, target, task_id="t-1"):
    return {"intent_id": intent_id, "action": action, "unit_ids": list(units),
            "target": dict(target), "task_id": task_id, "state": INTENT_ACTIVE,
            "expires_tick": 10 ** 9}


def own(name, *, pos=None, hp=100.0, unit_type="worker", carried=(0, 0), **extra):
    entity = {"kind": "unit_self", "name": name, "unit_type": unit_type,
              "hp": hp, "hp_max": 100.0, "pos": list(pos or [0.0, 0.0, 0.0]),
              "carried": list(carried)}
    entity.update(extra)
    return entity


def observation(*groups, production=(), intel=(), truncated=False):
    """按位置传入的若干实体组会被合并进 entities（我方/敌方/资源混排，与真实观测一致）。"""
    entities = []
    for group in groups:
        entities.extend(group)
    return {"tactical": {"entities": entities, "production": list(production),
                         "truncated": truncated},
            "strategic": {"enemy_intel": list(intel)}}


def enemy(name, hp, *, dead=False):
    return {"kind": "unit_enemy", "name": name, "hp": hp, "hp_max": 100.0,
            "pos": [0.0, 0.0, 0.0], "confirmed_dead": dead}


class MovementProgressTest(unittest.TestCase):
    def test_approach_then_arrive_completes_task(self):
        item = intent("i-1", "move", ["Unit_1"], {"pos": [10.0, 0.0, 0.0]})
        state = make_state([item])
        report = track_task_progress(state, observation=observation(
            [own("Unit_1", pos=(0.0, 0.0, 0.0))]), tick=10)
        self.assertEqual(report["intents"]["i-1"]["status"], "in_progress")
        report = track_task_progress(state, observation=observation(
            [own("Unit_1", pos=(6.0, 0.0, 0.0))]), tick=20)
        self.assertEqual(report["intents"]["i-1"]["status"], "in_progress")
        report = track_task_progress(state, observation=observation(
            [own("Unit_1", pos=(9.0, 0.0, 0.0))]), tick=30)
        self.assertEqual(report["intents"]["i-1"]["status"], "completed")
        self.assertEqual(item["state"], INTENT_COMPLETED)
        self.assertEqual(state["active_tasks"]["t-1"], TASK_COMPLETED)

    def test_movement_completion_unlocks_the_current_hop(self):
        """观测到位必须作废当前跳，否则半路不再下新令后会卡到 hop 超时。"""
        item = intent("i-1", "attack_move", ["Unit_1"], {"pos": [10.0, 0.0]})
        state = make_state([item])
        state["routes"] = {"Unit_1": {
            "ok": True, "route_id": "r1", "nav_revision": 0,
            "last_replan_tick": 10, "relay_point": [10.0, 0.0],
            "target": [10.0, 0.0],
        }}
        track_task_progress(state, observation=observation(
            [own("Unit_1", pos=(10.0, 0.0, 0.0))]), tick=30)
        route = state["routes"]["Unit_1"]
        self.assertFalse(route["ok"])
        self.assertEqual(route["invalidated_reason"], "arrived")

    def test_two_dimensional_waypoint_arrival_completes_scout(self):
        """侦察前沿是 [x, z]，实体是 [x, y, z] —— 两种都要能判定到达。"""
        item = intent("i-scout", "scout", ["Unit_1"], {"pos": [17.5, 17.5]})
        state = make_state([item])
        report = track_task_progress(state, observation=observation(
            [own("Unit_1", pos=(17.47, 1.5, 17.46), unit_type="drone")]), tick=1200)
        self.assertEqual(report["intents"]["i-scout"]["status"], "completed")
        self.assertEqual(item["state"], INTENT_COMPLETED)

    def test_stalled_movement_stays_unknown_not_failed(self):
        """停顿**不能**判失败，但更不能判成功（保持未知 + 继续占用）。"""
        item = intent("i-1", "move", ["Unit_1"], {"pos": [50.0, 0.0, 0.0]})
        state = make_state([item])
        for tick in (10, 20, 30):
            track_task_progress(state, observation=observation(
                [own("Unit_1", pos=(0.0, 0.0, 0.0))]), tick=tick)
        assert_unknown_keeps_occupancy(self, item, state)

    def test_lost_unit_stays_unknown(self):
        item = intent("i-1", "move", ["Unit_1"], {"pos": [50.0, 0.0, 0.0]})
        state = make_state([item])
        report = track_task_progress(state, observation=observation([]), tick=10)
        self.assertEqual(report["intents"]["i-1"]["status"], "unknown")

    def test_missing_target_pos_fails(self):
        item = intent("i-1", "move", ["Unit_1"], {})
        state = make_state([item])
        report = track_task_progress(state, observation=observation(
            [own("Unit_1")]), tick=10)
        self.assertEqual(report["intents"]["i-1"]["status"], "failed")


class AttackProgressTest(unittest.TestCase):
    def test_damage_counts_as_progress_and_death_completes(self):
        item = intent("i-1", "attack", ["Unit_4"], {"entity_id": "Unit_9"})
        state = make_state([item])
        report = track_task_progress(state, observation=observation(
            [own("Unit_4", unit_type="soldier")], [enemy("Unit_9", 80.0)]), tick=10)
        self.assertEqual(report["intents"]["i-1"]["status"], "in_progress")
        self.assertEqual(report["intents"]["i-1"]["metrics"]["target_hp"], 80.0)
        report = track_task_progress(state, observation=observation(
            [own("Unit_4", unit_type="soldier")], [enemy("Unit_9", 40.0)]), tick=20)
        self.assertEqual(report["intents"]["i-1"]["status"], "in_progress")
        report = track_task_progress(state, observation=observation(
            [own("Unit_4", unit_type="soldier")], [enemy("Unit_9", 0.0, dead=True)]), tick=30)
        self.assertEqual(report["intents"]["i-1"]["status"], "completed")
        self.assertEqual(item["state"], INTENT_COMPLETED)

    def test_enemy_confirmed_dead_from_intel_completes(self):
        item = intent("i-1", "attack", ["Unit_4"], {"entity_id": "Unit_9"})
        state = make_state([item])
        report = track_task_progress(state, observation=observation(
            [own("Unit_4", unit_type="soldier")], intel=[
                {"name": "Unit_9", "confirmed_dead": True, "last_seen_tick": 5}]), tick=10)
        self.assertEqual(report["intents"]["i-1"]["status"], "completed")

    def test_brief_unseen_target_is_not_an_alarm(self):
        # 视野抖动很常见：刚看不见时应保持 in_progress，不要立刻报中断。
        item = intent("i-1", "attack", ["Unit_4"], {"entity_id": "Unit_9"})
        state = make_state([item])
        report = track_task_progress(state, observation=observation(
            [own("Unit_4", unit_type="soldier")], intel=[
                {"name": "Unit_9", "confirmed_dead": False, "last_seen_tick": 395}]),
            tick=400)
        self.assertEqual(report["intents"]["i-1"]["status"], "in_progress")

    def test_target_out_of_sight_interrupts_but_keeps_intent_live(self):
        # 持续失去视野 = 可恢复中断，不能记成失败，也不能写死意图状态。
        item = intent("i-1", "attack", ["Unit_4"], {"entity_id": "Unit_9"})
        state = make_state([item])
        report = track_task_progress(state, observation=observation(
            [own("Unit_4", unit_type="soldier")], intel=[
                {"name": "Unit_9", "confirmed_dead": False, "last_seen_tick": 5}]),
            tick=1200)
        self.assertEqual(report["intents"]["i-1"]["status"], "interrupted")
        self.assertEqual(item["state"], INTENT_ACTIVE)
        self.assertEqual(state["active_tasks"]["t-1"], TASK_RUNNING)

    def test_long_unseen_target_stays_unknown(self):
        """长时间看不到目标 = 迷雾，不是"目标已死"，更不是任务失败。"""
        item = intent("i-1", "attack", ["Unit_4"], {"entity_id": "Unit_9"})
        state = make_state([item])
        report = track_task_progress(state, observation=observation(
            [own("Unit_4", unit_type="soldier")], intel=[
                {"name": "Unit_9", "confirmed_dead": False, "last_seen_tick": 5}]),
            tick=5 + 4 * 600 + 1)
        self.assertEqual(report["intents"]["i-1"]["status"], "unknown")

    def test_no_damage_for_three_samples_stays_unknown(self):
        item = intent("i-1", "attack", ["Unit_4"], {"entity_id": "Unit_9"})
        state = make_state([item])
        for tick in (10, 20, 30, 40):
            track_task_progress(state, observation=observation(
                [own("Unit_4", unit_type="soldier")], [enemy("Unit_9", 80.0)]), tick=tick)
        assert_unknown_keeps_occupancy(self, item, state)


class GatherProgressTest(unittest.TestCase):
    def test_carried_increase_is_progress(self):
        item = intent("i-1", "gather", ["Unit_2"], {"entity_id": "ResourceA"})
        state = make_state([item])
        track_task_progress(state, observation=observation(
            [own("Unit_2", carried=(0, 0))], [{"kind": "resource", "name": "ResourceA"}]),
            tick=10)
        report = track_task_progress(state, observation=observation(
            [own("Unit_2", carried=(5, 0))], [{"kind": "resource", "name": "ResourceA"}]),
            tick=20)
        self.assertEqual(report["intents"]["i-1"]["status"], "in_progress")
        self.assertEqual(report["intents"]["i-1"]["metrics"]["carried"], {"Unit_2": 5})

    def test_resource_gone_from_complete_observation_completes(self):
        item = intent("i-1", "gather", ["Unit_2"], {"entity_id": "ResourceA"})
        state = make_state([item])
        track_task_progress(state, observation=observation(
            [own("Unit_2", carried=(5, 0))], [{"kind": "resource", "name": "ResourceA"}]),
            tick=10)
        report = track_task_progress(state, observation=observation(
            [own("Unit_2", carried=(0, 0))]), tick=20)
        self.assertEqual(report["intents"]["i-1"]["status"], "completed")

    def test_remaining_zero_completes_gather_so_worker_can_reassign(self):
        """T10：完整观测里矿点 remaining=0 → 采集完成，工人才能转岗。"""
        item = intent("i-1", "gather", ["Unit_2"], {"entity_id": "ResourceA"})
        state = make_state([item])
        track_task_progress(state, observation=observation(
            [own("Unit_2", carried=(5, 0))],
            [{"kind": "resource", "name": "ResourceA", "remaining": 10}]), tick=10)
        report = track_task_progress(state, observation=observation(
            [own("Unit_2", carried=(5, 0))],
            [{"kind": "resource", "name": "ResourceA", "remaining": 0}]), tick=20)
        self.assertEqual(report["intents"]["i-1"]["status"], "completed")
        self.assertEqual(item["state"], INTENT_COMPLETED)

    def test_truncated_observation_never_claims_resource_depleted(self):
        item = intent("i-1", "gather", ["Unit_2"], {"entity_id": "ResourceA"})
        state = make_state([item])
        track_task_progress(state, observation=observation(
            [own("Unit_2", carried=(5, 0))], [{"kind": "resource", "name": "ResourceA"}]),
            tick=10)
        report = track_task_progress(state, observation=observation(
            [own("Unit_2", carried=(0, 0))], truncated=True), tick=20)
        self.assertEqual(report["intents"]["i-1"]["status"], "in_progress")


class ProduceProgressTest(unittest.TestCase):
    def _queue(self, **item):
        base = {"item_id": "q-1", "definition_id": "worker", "state": "producing",
                "completed_work": 1, "required_work": 4}
        base.update(item)
        return {"producer": "Unit_0", "producer_type": "command_center",
                "queue_size": 1, "items": [base]}

    def _empty_queue(self):
        return {"producer": "Unit_0", "producer_type": "command_center",
                "queue_size": 0, "items": []}

    def test_queue_item_is_progress_with_work_ratio(self):
        item = intent("i-1", "produce", ["Unit_0"],
                      {"producer": "Unit_0", "scene": "worker"})
        state = make_state([item])
        report = track_task_progress(state, observation=observation(
            [own("Unit_0", unit_type="command_center")],
            production=[self._queue()]), tick=10)
        metrics = report["intents"]["i-1"]["metrics"]
        self.assertEqual(report["intents"]["i-1"]["status"], "in_progress")
        self.assertEqual(metrics["ratio"], 0.25)

    def test_queue_item_lost_without_new_unit_is_failure(self):
        # 方案 §4 明确：不能把"项目从队列消失"一律当成生产成功。
        item = intent("i-1", "produce", ["Unit_0"],
                      {"producer": "Unit_0", "scene": "worker"})
        state = make_state([item])
        track_task_progress(state, observation=observation(
            [own("Unit_0", unit_type="command_center")],
            production=[self._queue()]), tick=10)
        report = track_task_progress(state, observation=observation(
            [own("Unit_0", unit_type="command_center")],
            production=[self._empty_queue()]), tick=20)
        # 队列项消失且没看到新单位：**不判成功，也不判失败**（可能还没走出来）。
        self.assertEqual(report["intents"]["i-1"]["status"], "unknown")
        assert_unknown_keeps_occupancy(self, item, state)

    def test_queue_item_lost_with_new_unit_completes(self):
        item = intent("i-1", "produce", ["Unit_0"],
                      {"producer": "Unit_0", "scene": "worker"})
        state = make_state([item])
        track_task_progress(state, observation=observation(
            [own("Unit_0", unit_type="command_center")],
            production=[self._queue()]), tick=10)
        report = track_task_progress(state, observation=observation(
            [own("Unit_0", unit_type="command_center"), own("Unit_7")],
            production=[self._empty_queue()]), tick=20)
        self.assertEqual(report["intents"]["i-1"]["status"], "completed")

    # ---- 2026-09-13 归档复盘根因（GPT 报告 P1a）----

    def _infantry_intent(self):
        """真实形状：场景名 `Infantry.tscn`，权威产品 ID `soldier`（两套命名）。"""
        item = intent("rule-produce-soldier-Unit_17-1409", "produce", ["Unit_17"],
                      {"producer": "Unit_17",
                       "scene": "res://source/match/units/Infantry.tscn"})
        item["production"] = {"item_id": "e69b08d1-7f26-464d-b066-7601e69b3aef",
                              "product_id": "soldier", "producer": "Unit_17"}
        return item

    def _soldier_queue(self, *, item_id="e69b08d1-7f26-464d-b066-7601e69b3aef",
                       work=30, required=120):
        return {"producer": "Unit_17", "producer_type": "barracks", "queue_size": 1,
                "items": [{"item_id": item_id, "definition_id": "soldier",
                           "state": "Producing", "completed_work": work,
                           "required_work": required}]}

    def test_scene_path_is_not_the_product_id(self):
        """**根因**：`scene=Infantry.tscn` 与 `definition_id=soldier` 不是同一套命名 ——
        拿 scene 直接比永远比不中（旧实现因此判"队列里没有"，任务停在 active_unknown）。

        证据（archive_045ed0d6）：intent `rule-produce-soldier-Unit_17-1409` 的回执
        `item.definition_id=soldier`、`scene=…/Infantry.tscn`；队列项 `definition_id=soldier`。
        """
        item = self._infantry_intent()
        state = make_state([item])
        report = track_task_progress(state, observation=observation(
            [own("Unit_17", unit_type="barracks")],
            production=[self._soldier_queue()]), tick=1415)
        self.assertEqual(report["intents"][item["intent_id"]]["status"], "in_progress",
                         "认出权威产品 ID 后必须看到「队列中生产中」")

    def test_production_finished_event_settles_by_item_id(self):
        """**闭环**：完成事件带**同一个 item_id** → 直接结算 completed，不等 TTL、不靠产物计数。"""
        item = self._infantry_intent()
        state = make_state([item])
        state["production_ledger"] = {
            "e69b08d1-7f26-464d-b066-7601e69b3aef": {
                "producer": "Unit_17", "product_id": "soldier",
                "started_tick": 1415, "finished_tick": 1532}}
        report = track_task_progress(state, observation=observation(
            [own("Unit_17", unit_type="barracks"),
             own("Unit_23", unit_type="soldier")],
            production=[self._empty_queue()]), tick=1600)
        self.assertEqual(report["intents"][item["intent_id"]]["status"], "completed")
        self.assertEqual(item["state"], INTENT_COMPLETED)
        metrics = (item.get("progress") or {}).get("metrics") or {}
        self.assertEqual(metrics.get("item_id"), "e69b08d1-7f26-464d-b066-7601e69b3aef")

    def test_sibling_item_finish_does_not_complete_other_line(self):
        """T09：双设施同类并产，一条 item 完成不得误结另一条。"""
        first = self._infantry_intent()
        second = intent("rule-produce-soldier-Unit_18-1409", "produce", ["Unit_18"],
                        {"producer": "Unit_18",
                         "scene": "res://source/match/units/Infantry.tscn"})
        second["production"] = {"item_id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                                "product_id": "soldier", "producer": "Unit_18"}
        state = make_state([first, second])
        state["production_ledger"] = {
            "e69b08d1-7f26-464d-b066-7601e69b3aef": {
                "producer": "Unit_17", "product_id": "soldier",
                "started_tick": 1415, "finished_tick": 1532},
        }
        still_queue = {"producer": "Unit_18", "producer_type": "barracks",
                       "queue_size": 1,
                       "items": [{"item_id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                                  "definition_id": "soldier", "state": "Producing",
                                  "completed_work": 40, "required_work": 120}]}
        report = track_task_progress(state, observation=observation(
            [own("Unit_17", unit_type="barracks"),
             own("Unit_18", unit_type="barracks"),
             own("Unit_23", unit_type="soldier")],
            production=[self._empty_queue_of("Unit_17"), still_queue]), tick=1600)
        self.assertEqual(report["intents"][first["intent_id"]]["status"], "completed")
        self.assertEqual(report["intents"][second["intent_id"]]["status"], "in_progress",
                         "另一条生产线被误结：%s" % report["intents"][second["intent_id"]])

    def test_vanished_without_finish_event_stays_unknown_with_recheck(self):
        """队列项消失但**没有完成事件** → 保持未知，并记下"该去对账什么"（item_id + 生产者）。"""
        item = self._infantry_intent()
        state = make_state([item])
        track_task_progress(state, observation=observation(
            [own("Unit_17", unit_type="barracks")],
            production=[self._soldier_queue()]), tick=1415)
        report = track_task_progress(state, observation=observation(
            [own("Unit_17", unit_type="barracks")],
            production=[self._empty_queue_of("Unit_17")]), tick=1600)
        self.assertEqual(report["intents"][item["intent_id"]]["status"], "unknown")
        metrics = (item.get("progress") or {}).get("metrics") or {}
        self.assertEqual((metrics.get("recheck") or {}).get("item_id"),
                         "e69b08d1-7f26-464d-b066-7601e69b3aef")

    def _empty_queue_of(self, producer):
        return {"producer": producer, "producer_type": "barracks", "queue_size": 0, "items": []}

    def test_producer_gone_stays_unknown(self):
        item = intent("i-1", "produce", ["Unit_0"],
                      {"producer": "Unit_0", "scene": "worker"})
        state = make_state([item])
        report = track_task_progress(state, observation=observation([]), tick=10)
        self.assertEqual(report["intents"]["i-1"]["status"], "unknown")


class BuildProgressTest(unittest.TestCase):
    def test_build_type_resolves_from_site_entity(self):
        """建造同样有"场景名 ≠ 类型 ID"的坑：`AircraftFactory.tscn`（驼峰）→ `aircraft_factory`
        （蛇形）。必须按**工地实体**的 `unit_type` 判，否则永远看不到"已建成"。"""
        item = intent("i-1", "build", ["Unit_2"],
                      {"producer": "Unit_2", "entity_id": "Unit_45",
                       "scene": "res://source/match/units/AircraftFactory.tscn"})
        state = make_state([item])
        report = track_task_progress(state, observation=observation(
            [own("Unit_2"),
             own("Unit_45", unit_type="aircraft_factory", constructed=True)]), tick=600)
        self.assertEqual(report["intents"]["i-1"]["status"], "completed")

    def test_site_then_constructed_completes(self):
        item = intent("i-1", "build", ["Unit_2"],
                      {"producer": "Unit_2", "scene": "barracks"})
        state = make_state([item])
        report = track_task_progress(state, observation=observation(
            [own("Unit_2")]), tick=10)
        self.assertEqual(report["intents"]["i-1"]["status"], "in_progress")
        report = track_task_progress(state, observation=observation(
            [own("Unit_2"),
             own("Unit_8", unit_type="barracks", constructed=False)]), tick=20)
        self.assertEqual(report["intents"]["i-1"]["status"], "in_progress")
        report = track_task_progress(state, observation=observation(
            [own("Unit_2"),
             own("Unit_8", unit_type="barracks", constructed=True)]), tick=30)
        self.assertEqual(report["intents"]["i-1"]["status"], "completed")
        self.assertEqual(item["state"], INTENT_COMPLETED)

    def test_never_appearing_site_stays_unknown(self):
        """工地迟迟没出现：保持未知 + 继续占用（判失败会让微操重发建造）。"""
        item = intent("i-1", "build", ["Unit_2"],
                      {"producer": "Unit_2", "scene": "barracks"})
        state = make_state([item])
        for tick in (10, 20, 30):
            track_task_progress(state, observation=observation([own("Unit_2")]), tick=tick)
        assert_unknown_keeps_occupancy(self, item, state)


class TaskAggregationTest(unittest.TestCase):
    def test_task_stays_running_while_any_intent_is_live(self):
        done = intent("i-1", "move", ["Unit_1"], {"pos": [0.0, 0.0, 0.0]})
        pending = intent("i-2", "move", ["Unit_2"], {"pos": [99.0, 0.0, 0.0]})
        state = make_state([done, pending])
        report = track_task_progress(state, observation=observation(
            [own("Unit_1", pos=(0.0, 0.0, 0.0)), own("Unit_2", pos=(50.0, 0.0, 0.0))]),
            tick=10)
        self.assertEqual(report["intents"]["i-1"]["status"], "completed")
        self.assertEqual(report["intents"]["i-2"]["status"], "in_progress")
        self.assertEqual(state["active_tasks"]["t-1"], TASK_RUNNING)

    def test_task_completes_only_after_all_intents_done(self):
        first = intent("i-1", "move", ["Unit_1"], {"pos": [0.0, 0.0, 0.0]})
        second = intent("i-2", "move", ["Unit_2"], {"pos": [0.0, 0.0, 0.0]})
        state = make_state([first, second])
        track_task_progress(state, observation=observation(
            [own("Unit_1", pos=(0.0, 0.0, 0.0)), own("Unit_2", pos=(50.0, 0.0, 0.0))]),
            tick=10)
        self.assertEqual(state["active_tasks"]["t-1"], TASK_RUNNING)
        track_task_progress(state, observation=observation(
            [own("Unit_1", pos=(0.0, 0.0, 0.0)), own("Unit_2", pos=(0.0, 0.0, 0.0))]),
            tick=20)
        self.assertEqual(state["active_tasks"]["t-1"], TASK_COMPLETED)

    def test_closed_intents_are_not_re_evaluated(self):
        item = intent("i-1", "move", ["Unit_1"], {"pos": [0.0, 0.0, 0.0]})
        state = make_state([item])
        track_task_progress(state, observation=observation(
            [own("Unit_1", pos=(0.0, 0.0, 0.0))]), tick=10)
        self.assertEqual(item["state"], INTENT_COMPLETED)
        report = track_task_progress(state, observation=observation([]), tick=20)
        self.assertEqual(report["intents"], {})
        self.assertEqual(item["state"], INTENT_COMPLETED)


class IndexObservationTest(unittest.TestCase):
    def test_truncated_flag_surfaces_in_report(self):
        item = intent("i-1", "gather", ["Unit_2"], {"entity_id": "ResourceA"})
        state = make_state([item])
        report = track_task_progress(state, observation=observation(
            [own("Unit_2", carried=(1, 0))], truncated=True), tick=10)
        self.assertTrue(report["truncated"])

    def test_missing_observation_does_not_crash(self):
        item = intent("i-1", "gather", ["Unit_2"], {"entity_id": "ResourceA"})
        state = make_state([item])
        report = track_task_progress(state, observation=None, tick=10)
        # 拿不到观测只能"未知"，不能据此判失败（否则一帧丢观测就会释放单位、触发重发）。
        self.assertEqual(report["intents"]["i-1"]["status"], "unknown")

    def test_unknown_action_is_reported_not_dropped(self):
        item = intent("i-1", "hold", ["Unit_2"], {})
        state = make_state([item])
        report = track_task_progress(state, observation=observation([own("Unit_2")]),
                                     tick=10)
        self.assertEqual(report["intents"]["i-1"]["status"], "in_progress")


if __name__ == "__main__":
    unittest.main()
