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

    def test_producer_gone_stays_unknown(self):
        item = intent("i-1", "produce", ["Unit_0"],
                      {"producer": "Unit_0", "scene": "worker"})
        state = make_state([item])
        report = track_task_progress(state, observation=observation([]), tick=10)
        self.assertEqual(report["intents"]["i-1"]["status"], "unknown")


class BuildProgressTest(unittest.TestCase):
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
