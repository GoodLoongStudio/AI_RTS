# -*- coding: utf-8 -*-
"""协调器核心测试：计划采纳代际、逐条批次、乱序返回、玩家优先权、
事件合并、重试退避、资源预留约束。全部确定性（假模型 + 注入时钟）。"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.coordinator import (
    AdjutantCoordinator, FakeStrategyModel, FakeTacticsModel, CoordinatorConfig,
    REQUEST_STATUS_STALE, REQUEST_STATUS_TIMED_OUT,
)
from adjutant_coordinator.state import (
    TASK_PENDING, TASK_RUNNING, TASK_UNKNOWN,
)

MATCH = "m-1"
PLAYER = "Player_1"
RULES = "hash-1"


def make_plan(version=1, plan_id="plan-a", reserves=None):
    return {
        "plan_id": plan_id,
        "plan_version": version,
        "match_id": MATCH,
        "player_id": PLAYER,
        "rules_version": RULES,
        "based_on_snapshot": 1,
        "valid_until_tick": 100000,
        "phase_goal": "发展经济",
        "tasks": [{"task_id": "t-1", "priority": 1, "completion": "工人 4 名"}],
        "reserves": reserves or {},
        "rationale": "测试计划",
    }


def make_command(command_id="c-1", task_id="t-1", units=("Unit_1",), est_cost=None,
                 plan_version="plan-a:v1", expires=100000):
    return {
        "command_id": command_id,
        "request_id": "r-" + command_id,
        "match_id": MATCH,
        "player_id": PLAYER,
        "rules_version": RULES,
        "plan_version": plan_version,
        "task_id": task_id,
        "based_on_snapshot": 1,
        "issued_tick": 100,
        "expires_tick": expires,
        "action": "move",
        "params": {"units": list(units), "dest": [5.0, 5.0], "est_cost": est_cost or {}},
    }


class AcceptTransport:
    """测试桩：全部接受并记录提交顺序。"""

    def __init__(self, receipts=None):
        self.submitted = []
        self._receipts = receipts or {}

    def __call__(self, command):
        self.submitted.append(command["command_id"])
        return self._receipts.get(
            command["command_id"],
            {"ok": True, "accepted": True, "status": "Accepted",
             "command_id": command["command_id"], "result": {}})


def make_coordinator(strategy_script=None, tactics_script=None, transport=None, config=None):
    return AdjutantCoordinator(
        match_id=MATCH,
        player_id=PLAYER,
        transport=transport or AcceptTransport(),
        strategy_model=FakeStrategyModel(strategy_script or []),
        tactics_model=FakeTacticsModel(tactics_script or []),
        config=config or CoordinatorConfig(strategy_interval_ticks=100,
                                           tactics_interval_ticks=1),
    )


class TestPlanAdoption(unittest.TestCase):

    def test_plan_adopted_and_version_monotonic(self):
        coordinator = make_coordinator(strategy_script=[make_plan(version=1)])
        coordinator.ingest_snapshot({"snapshot_id": 1, "rules_version": RULES}, {})
        coordinator.tick(10)
        self.assertTrue(coordinator.plans.active is not None)
        self.assertEqual(coordinator.plans.plan_version(), "plan-a:v1")

        # 同 plan_id 版本倒退 → 拒绝采纳（旧输出不能覆盖）。
        coordinator._strategy = FakeStrategyModel([make_plan(version=1)])
        coordinator.tick(200)
        self.assertEqual(coordinator.plans.plan_version(), "plan-a:v1")

    def test_stale_rules_version_plan_rejected(self):
        plan = make_plan()
        plan["rules_version"] = "old-hash"
        coordinator = make_coordinator(strategy_script=[plan])
        coordinator.ingest_snapshot({"snapshot_id": 1, "rules_version": RULES}, {})
        coordinator.tick(10)
        self.assertTrue(coordinator.plans.active is None)
        self.assertTrue(any(
            d["kind"] in ("plan_rejected", "plan_invalid") for d in coordinator.decisions))


class TestBatchAndReceipts(unittest.TestCase):

    def test_batch_is_per_command_not_atomic(self):
        receipts = {
            "c-1": {"ok": True, "accepted": True, "status": "Accepted", "command_id": "c-1", "result": {}},
            "c-2": {"ok": False, "accepted": False, "status": "InsufficientResources",
                     "reason": "资源不足", "command_id": "c-2", "result": {}},
        }
        transport = AcceptTransport(receipts)
        coordinator = make_coordinator(
            tactics_script=[[make_command("c-1"), make_command("c-2")]],
            transport=transport)
        coordinator.ingest_snapshot({"snapshot_id": 1, "rules_version": RULES}, {})
        coordinator.tick(10)
        self.assertEqual(transport.submitted, ["c-1", "c-2"])  # 逐条提交
        self.assertEqual(coordinator.metrics.commands_accepted, 1)
        self.assertEqual(coordinator.metrics.commands_rejected, 1)

    def test_pending_authority_does_not_fail_task(self):
        receipts = {
            "c-1": {"ok": False, "accepted": False, "status": "PendingAuthority",
                     "reason": "等待服务器确认", "command_id": "c-1", "result": {}},
        }
        coordinator = make_coordinator(
            tactics_script=[[make_command("c-1")]],
            transport=AcceptTransport(receipts))
        coordinator.ingest_snapshot({"snapshot_id": 1, "rules_version": RULES}, {})
        coordinator.tick(10)
        # PendingAuthority ≠ 任务失败：保持 pending/unknown，等待 command_id 复核。
        self.assertIn(coordinator.tasks.state_of("t-1"), (TASK_PENDING, TASK_UNKNOWN))
        self.assertEqual(coordinator.metrics.commands_pending, 1)


class TestPlayerPriority(unittest.TestCase):

    def test_player_override_blocks_then_reacquire(self):
        coordinator = make_coordinator(
            tactics_script=[[make_command("c-1"), make_command("c-2", units=("Unit_1",))]])
        coordinator.ingest_snapshot({"snapshot_id": 1, "rules_version": RULES}, {})
        coordinator.tick(10)
        self.assertTrue(coordinator.metrics.commands_accepted >= 1)
        # 玩家手动接管 → 租约失效。
        coordinator.notify_player_override(["Unit_1"])
        late = make_command("c-late")
        receipt = coordinator.submit_command(late, 500)
        self.assertEqual(receipt.status, "PlayerOverride")
        self.assertFalse(receipt.accepted)
        # 显式 reacquire 授权 → 重新接管成功。
        reacquire = make_command("c-reacquire")
        reacquire["params"]["reacquire"] = True
        receipt2 = coordinator.submit_command(reacquire, 510)
        self.assertTrue(receipt2.accepted)


class TestRequestGenerations(unittest.TestCase):

    def test_late_result_discarded_after_timeout(self):
        coordinator = make_coordinator(
            strategy_script=[], config=CoordinatorConfig(
                strategy_interval_ticks=100, tactics_interval_ticks=1000,
                request_timeout_ticks=50))
        coordinator.ingest_snapshot({"snapshot_id": 1, "rules_version": RULES}, {})
        coordinator.tick(10)
        request_id = [r for r in coordinator._active_requests.values()
                      if r.role == "strategy"][0].request_id
        # 超时后迟到的计划返回 → 丢弃，不抢回控制。
        coordinator.tick(100)
        accepted = coordinator.deliver_late_result(request_id, make_plan(), 100)
        self.assertFalse(accepted)
        stale = [r for r in coordinator._active_requests.values() if r.status == REQUEST_STATUS_STALE]
        self.assertEqual(len(stale), 1)
        self.assertTrue(coordinator.plans.active is None)


class TestEventsAndRetries(unittest.TestCase):

    def test_event_merge_window(self):
        coordinator = make_coordinator()
        coordinator.push_event("unit_moved", 100, {"subject": "Unit_1"})
        coordinator.push_event("unit_moved", 105, {"subject": "Unit_1"})
        coordinator.push_event("unit_moved", 130, {"subject": "Unit_1"})
        events = coordinator.events.drain()
        # 窗口内同键合并为最新；窗口外保留。
        self.assertEqual(len(events), 2)
        self.assertEqual(events[-1].server_tick, 130)
        self.assertGreater(coordinator.events.merged, 0)

    def test_event_bounded_backpressure(self):
        coordinator = make_coordinator()
        for index in range(700):
            coordinator.push_event("scan", index, {"subject": "s%d" % index})
        self.assertLessEqual(coordinator.events.pending(), 512)
        self.assertGreater(coordinator.events.dropped, 0)


class TestBudgetReserve(unittest.TestCase):

    def test_competing_orders_cannot_overspend_reserve(self):
        coordinator = make_coordinator(
            tactics_script=[[
                make_command("c-1", est_cost={"A": 500}),
                make_command("c-2", est_cost={"A": 400}),
            ]])
        coordinator.ingest_snapshot({"snapshot_id": 1, "rules_version": RULES}, {})
        coordinator.set_reserves({"A": 800})
        coordinator.tick(10)
        # 第一条 500 被接受；第二条 400 会超支（500+400>800）→ 协调器侧拦截。
        self.assertEqual(coordinator.metrics.commands_accepted, 1)
        self.assertEqual(coordinator.metrics.budget_rejected, 1)


if __name__ == "__main__":
    unittest.main()
