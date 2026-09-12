# -*- coding: utf-8 -*-
"""有界异步调度器单测（计划 §3/§7.C）：

1. 单一在途：同一时刻至多一个工作槽，只有真正结束才允许下一个进入；
2. 观测合并：等待期间的普通观测只保留最新，合并计数可查；
3. 紧急优先：紧急任务插队；紧急在途时普通观测不抢占；
4. 有界队列：满了按明确原因丢弃（不静默）；
5. 过期结果拒绝：本地接收期限已过 → status=expired，且**不改任何状态**；
6. 代际过期拒绝：玩家在结果到达前接管了单位 → status=stale_generation；
7. 观测推进过多 → status=stale_snapshot；
8. 失败退避用单调时钟：退避期间提交被拒（reason=backoff_active），到点恢复；
9. 失败/超时不推断单位或任务状态（调度器只产出结果与原因）。
"""

import os
import sys
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)

from adjutant_coordinator.graph.async_scheduler import (  # noqa: E402
    KIND_EMERGENCY, KIND_NORMAL, REASON_BACKOFF, REASON_IN_FLIGHT_EMERGENCY,
    REASON_QUEUE_FULL, STATUS_ERROR, STATUS_EXPIRED, STATUS_OK,
    STATUS_STALE_GENERATION, STATUS_STALE_SNAPSHOT, DecisionScheduler,
)


class FakeClock:
    def __init__(self, now: float = 1000.0) -> None:
        self.now = float(now)

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += float(seconds)


class FakeFrame:
    """最小 frame：调度器只关心 server_tick / generations / deadline_monotonic。"""

    def __init__(self, tick: int, generations=None, deadline_seconds=3.0,
                 now: float = 1000.0) -> None:
        self.server_tick = int(tick)
        self.generations = dict(generations or {})
        self.deadline_seconds = float(deadline_seconds)
        self._created = float(now)

    @property
    def deadline_monotonic(self) -> float:
        return self._created + self.deadline_seconds


def wait_until(predicate, timeout=2.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.005)
    return False


class SchedulerTestBase(unittest.TestCase):

    def setUp(self):
        self.clock = FakeClock()
        self.calls = []
        self.gate = threading.Event()
        self.behaviour = {}

    def make(self, call=None, **kwargs):
        def default_call(request):
            self.calls.append(request)
            behaviour = self.behaviour.get(request.request_id, {})
            self.gate.wait(timeout=1.0)
            if behaviour.get("raise"):
                raise RuntimeError("boom")
            return behaviour.get("value", "v%d" % request.request_id)

        return DecisionScheduler(call or default_call, clock=self.clock, **kwargs)


class SingleInFlightTest(SchedulerTestBase):

    def test_only_one_in_flight_and_no_stacking(self):
        scheduler = self.make()
        first, _ = scheduler.submit(FakeFrame(1), deadline_seconds=5.0)
        self.assertTrue(first)
        self.assertTrue(wait_until(lambda: len(self.calls) == 1))
        # 第一个还在跑：新的普通观测只合并进待命槽，不会开出第二个工作线程
        second, why = scheduler.submit(FakeFrame(2), deadline_seconds=5.0)
        self.assertTrue(second)
        self.assertEqual(why, "queued")
        self.assertEqual(len(self.calls), 1)
        stats = scheduler.stats()
        self.assertEqual(stats["in_flight"], 1)
        self.assertEqual(stats["pending_normal"], 1)
        self.gate.set()
        self.assertTrue(wait_until(lambda: len(self.calls) == 2))
        self.assertEqual(self.calls[1].frame.server_tick, 2, "第二个工作槽必须是最新观测")

    def test_normal_observations_are_merged_keeping_latest(self):
        """闸门保持关闭 → 第一轮停在在途，后续普通观测全部合并进同一待命槽。"""
        scheduler = self.make()
        scheduler.submit(FakeFrame(1))
        self.assertTrue(wait_until(lambda: len(self.calls) == 1))
        for tick in (2, 3, 4):
            scheduler.submit(FakeFrame(tick))
        self.assertEqual(scheduler.stats()["pending_normal"], 1,
                         "普通观测只保留一个待命槽")
        self.assertEqual(scheduler.stats()["merged"], 2)
        self.gate.set()
        self.assertTrue(wait_until(lambda: len(self.calls) >= 2))
        self.assertEqual(self.calls[-1].frame.server_tick, 4, "待命槽必须是最新观测")

    def test_emergency_jumps_queue(self):
        scheduler = self.make()
        first, _ = scheduler.submit(FakeFrame(1))
        self.assertTrue(first)
        self.assertTrue(wait_until(lambda: len(self.calls) == 1))
        scheduler.submit(FakeFrame(2))                        # 普通待命
        accepted, _ = scheduler.submit(FakeFrame(3), kind=KIND_EMERGENCY)
        self.assertTrue(accepted)
        self.gate.set()
        self.assertTrue(wait_until(lambda: len(self.calls) >= 2))
        self.assertEqual(self.calls[1].kind, KIND_EMERGENCY, "紧急任务必须插队")

    def test_normal_is_refused_while_emergency_in_flight(self):
        scheduler = self.make()
        self.gate.wait(timeout=0)          # 保持闸门关闭 → 紧急任务停在在途
        scheduler.submit(FakeFrame(1), kind=KIND_EMERGENCY)
        self.assertTrue(wait_until(lambda: len(self.calls) == 1))
        accepted, why = scheduler.submit(FakeFrame(2), kind=KIND_NORMAL)
        self.assertFalse(accepted)
        self.assertEqual(why, REASON_IN_FLIGHT_EMERGENCY)
        self.gate.set()

    def test_bounded_queue_refuses_with_reason(self):
        scheduler = self.make(max_normal_queue=0)
        first, _ = scheduler.submit(FakeFrame(1))
        self.assertTrue(first)
        self.assertTrue(wait_until(lambda: len(self.calls) == 1))
        accepted, why = scheduler.submit(FakeFrame(2))
        self.assertFalse(accepted)
        self.assertEqual(why, REASON_QUEUE_FULL)
        self.gate.set()
        self.assertTrue(wait_until(lambda: scheduler.stats()["completed"] == 1))


class FreshnessTest(SchedulerTestBase):

    def test_expired_result_is_rejected(self):
        scheduler = self.make()
        self.gate.set()
        scheduler.submit(FakeFrame(1, deadline_seconds=1.0, now=self.clock.now))
        self.assertTrue(wait_until(lambda: scheduler.stats()["completed"] == 1))
        self.clock.advance(2.0)                    # 结果到达时已超过本地接收期限
        outcome = scheduler.poll()
        self.assertIsNotNone(outcome)
        self.assertEqual(outcome.status, STATUS_EXPIRED)
        self.assertFalse(outcome.accepted)
        self.assertEqual(scheduler.stats()["rejected_expired"], 1)

    def test_stale_generation_is_rejected(self):
        scheduler = self.make()
        self.gate.set()
        scheduler.submit(FakeFrame(1, generations={"Unit_4": 7}, deadline_seconds=60.0))
        self.assertTrue(wait_until(lambda: scheduler.stats()["completed"] == 1))
        outcome = scheduler.poll(current_generations={"Unit_4": 8})
        self.assertIsNotNone(outcome)
        self.assertEqual(outcome.status, STATUS_STALE_GENERATION)

    def test_stale_snapshot_is_rejected(self):
        scheduler = self.make(max_tick_drift=100)
        self.gate.set()
        scheduler.submit(FakeFrame(1000, deadline_seconds=60.0))
        self.assertTrue(wait_until(lambda: scheduler.stats()["completed"] == 1))
        outcome = scheduler.poll(current_tick=5000)
        self.assertIsNotNone(outcome)
        self.assertEqual(outcome.status, STATUS_STALE_SNAPSHOT)

    def test_fresh_result_is_accepted(self):
        scheduler = self.make()
        self.gate.set()
        scheduler.submit(FakeFrame(1000, generations={"Unit_4": 7}, deadline_seconds=60.0))
        self.assertTrue(wait_until(lambda: scheduler.stats()["completed"] == 1))
        outcome = scheduler.poll(current_generations={"Unit_4": 7}, current_tick=1010)
        self.assertIsNotNone(outcome)
        self.assertEqual(outcome.status, STATUS_OK)
        self.assertTrue(outcome.accepted)
        self.assertEqual(outcome.value, "v1")


class BackoffTest(SchedulerTestBase):

    def test_failure_backoff_uses_monotonic_clock(self):
        scheduler = self.make(base_backoff_seconds=2.0, max_backoff_seconds=8.0)
        self.behaviour[1] = {"raise": True}
        self.gate.set()
        scheduler.submit(FakeFrame(1))
        self.assertTrue(wait_until(lambda: scheduler.stats()["completed"] == 1))
        outcome = scheduler.poll()
        self.assertIsNotNone(outcome)
        self.assertEqual(outcome.status, STATUS_ERROR)
        accepted, why = scheduler.submit(FakeFrame(2))
        self.assertFalse(accepted)
        self.assertIn(REASON_BACKOFF, why)
        self.assertEqual(scheduler.stats()["refused_backoff"], 1)
        self.clock.advance(2.5)                    # 单调时钟推进后退避结束
        accepted, _ = scheduler.submit(FakeFrame(3))
        self.assertTrue(accepted)

    def test_backoff_grows_then_caps(self):
        scheduler = self.make(base_backoff_seconds=1.0, max_backoff_seconds=4.0)
        self.behaviour[1] = {"raise": True}
        self.behaviour[2] = {"raise": True}
        self.gate.set()
        scheduler.submit(FakeFrame(1))
        self.assertTrue(wait_until(lambda: scheduler.stats()["errors"] == 1))
        first_backoff = scheduler.stats()["backoff_seconds"]
        self.clock.advance(first_backoff + 0.01)
        scheduler.submit(FakeFrame(2))
        self.assertTrue(wait_until(lambda: scheduler.stats()["errors"] == 2))
        second_backoff = scheduler.stats()["backoff_seconds"]
        self.assertGreater(second_backoff, first_backoff)
        self.assertLessEqual(second_backoff, 4.0)


class NoStateInferenceTest(SchedulerTestBase):

    def test_scheduler_only_produces_outcomes(self):
        """调度器不得改动 frame/状态：失败与超时都不推断单位或任务状态。"""
        scheduler = self.make()
        frame = FakeFrame(1)
        self.behaviour[1] = {"raise": True}
        self.gate.set()
        scheduler.submit(frame)
        self.assertTrue(wait_until(lambda: scheduler.stats()["completed"] == 1))
        outcome = scheduler.poll()
        self.assertIsNotNone(outcome)
        self.assertEqual(outcome.status, STATUS_ERROR)
        self.assertEqual(frame.generations, {})
        self.assertFalse(hasattr(frame, "task_state"))
        # 结果对象只带原因，不带任何"任务已完成/失败"的结论
        self.assertNotIn("task", outcome.to_dict())
        self.assertNotIn("unit_state", outcome.to_dict())

    def test_stats_are_auditable(self):
        scheduler = self.make()
        self.gate.set()
        scheduler.submit(FakeFrame(1), kind=KIND_EMERGENCY)
        self.assertTrue(wait_until(lambda: scheduler.stats()["completed"] == 1))
        stats = scheduler.stats()
        for key in ("submitted", "started", "completed", "in_flight", "failures",
                    "backoff_seconds", "last_error"):
            self.assertIn(key, stats)


if __name__ == "__main__":
    unittest.main()
