# -*- coding: utf-8 -*-
"""宿主调度器测试：provider 注入、并行不阻塞、版本代际、超时保留计划、
断线重连身份校验、异常结构化、脏数据不崩。全部确定性（注入时钟）。"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.coordinator import AdjutantCoordinator
from adjutant_coordinator.host import HostScheduler, HostConfig, HOST_FATAL
from adjutant_coordinator.fakes import (
    ScriptedStrategyProvider, ScriptedTacticsProvider, make_valid_plan,
)
from adjutant_coordinator.structured_log import MemorySink, StructuredLogger
from adjutant_coordinator.transport import (
    ConnectionState, FakeTransport, ResilientTransport, TransportError,
)

MATCH, PLAYER, RULES = "m-1", "Player_1", "hash-1"


def make_command(command_id="c-1", units=("Unit_1",)):
    return {
        "command_id": command_id, "request_id": "r-" + command_id,
        "match_id": MATCH, "player_id": PLAYER, "rules_version": RULES,
        "plan_version": "plan-a:v1", "task_id": "t-1",
        "based_on_snapshot": 1, "issued_tick": 0, "expires_tick": 999999,
        "action": "move", "params": {"units": list(units), "dest": [1.0, 1.0]},
    }


class HostFixture:
    """组装：协调器 + 脚本 provider + Fake/Resilient transport + 内存日志。"""

    def __init__(self, strategy_script=None, tactics_script=None,
                 transport=None, config=None, identity_provider=None,
                 coordinator_transport=None):
        self.sink = MemorySink()
        self.logger = StructuredLogger(self.sink, base={
            "match_id": MATCH, "player_id": PLAYER, "rules_version": RULES})
        self.transport = transport or FakeTransport()
        self.coordinator = AdjutantCoordinator(
            match_id=MATCH, player_id=PLAYER,
            transport=coordinator_transport or self.transport,
            config=None)
        self.strategy = ScriptedStrategyProvider(strategy_script or [])
        self.tactics = ScriptedTacticsProvider(tactics_script or [])
        self.identity_provider = identity_provider
        self.host = HostScheduler(
            coordinator=self.coordinator,
            strategy_provider=self.strategy,
            tactics_provider=self.tactics,
            transport=self.transport,
            logger=self.logger,
            config=config or HostConfig(
                strategy_interval_ticks=1000, tactics_interval_ticks=1,
                request_timeout_ticks=150, heartbeat_interval_ticks=100000),
            identity_provider=identity_provider,
        )
        self.host.ingest_header({"match_id": MATCH, "player_id": PLAYER,
                                 "rules_version": RULES, "snapshot_id": 1})


class TestProviderInjection(unittest.TestCase):

    def test_providers_are_called_with_context(self):
        fixture = HostFixture(
            strategy_script=[{"behavior": "completed", "plan": make_valid_plan()}],
            tactics_script=[{"behavior": "empty"}])
        fixture.host.run_tick(10, {"major_event": "match_started"})
        self.assertEqual(fixture.strategy.call_count, 1)
        self.assertEqual(fixture.tactics.call_count, 1)
        context = fixture.strategy.calls[0]
        self.assertEqual(context.match_id, MATCH)
        self.assertEqual(context.rules_version, RULES)
        self.assertTrue(context.deadline_tick > context.issued_tick)
        self.assertEqual(context.request_id, "host-strat-1")


class TestParallelNonBlocking(unittest.TestCase):

    def test_pending_strategy_does_not_block_tactics(self):
        """战略结果挂起（乱序/迟到模拟）时，战术命令照常提交。"""
        fixture = HostFixture(
            strategy_script=[{"behavior": "late", "arrives_at_tick": 120,
                              "plan": make_valid_plan()}],
            tactics_script=[{"behavior": "completed",
                             "commands": [make_command("c-parallel")]}])
        fixture.host.run_tick(10, {"major_event": "match_started"})
        # 战略挂起（120 <= deadline 160）但战术已提交（互不阻塞）。
        self.assertIsNotNone(fixture.host._pending_strategy)
        self.assertIn("c-parallel", [e["command_id"] for e in fixture.transport.sent])
        # 后续 tick 结果到达（未过 deadline）→ 采纳，不受战术先执行影响。
        fixture.host.run_tick(120)
        self.assertIsNotNone(fixture.coordinator.plans.active)
        self.assertEqual(fixture.coordinator.plans.active.plan["plan_version"], 1)


class TestPlanGenerations(unittest.TestCase):

    def test_version_must_increase_old_plan_rejected(self):
        fixture = HostFixture(strategy_script=[
            {"behavior": "completed", "plan": make_valid_plan(version=2)},
            {"behavior": "completed", "plan": make_valid_plan(version=1)},
        ])
        fixture.host.run_tick(10, {"major_event": "match_started"})
        self.assertEqual(fixture.coordinator.plans.active.plan["plan_version"], 2)
        fixture.host.run_tick(1200)  # 周期到期，第二次计划（版本倒退）
        adopted = fixture.sink.find("plan_adoption")
        self.assertEqual(adopted[-1]["status"], "rejected")
        self.assertEqual(fixture.coordinator.plans.active.plan["plan_version"], 2)

    def test_stale_plan_late_arrival_discarded(self):
        """迟到结果（晚于 deadline 到达）丢弃：计划不覆盖、记录 stale。"""
        fixture = HostFixture(strategy_script=[
            {"behavior": "late", "arrives_at_tick": 999999,
             "plan": make_valid_plan(version=1)}])
        fixture.host.run_tick(10, {"major_event": "match_started"})
        self.assertIsNone(fixture.coordinator.plans.active)
        stale = fixture.sink.find("model_outcome_stale")
        self.assertEqual(len(stale), 1)
        self.assertIn("deadline", stale[0]["reason"])


class TestTimeoutKeepsPlan(unittest.TestCase):

    def test_timeout_keeps_current_plan_and_marks_degraded(self):
        """超时后保留当前有效计划与基础防守行为（不重复下单）。"""
        fixture = HostFixture(strategy_script=[
            {"behavior": "completed", "plan": make_valid_plan(version=1)},
            {"behavior": "timeout"},   # 第二请求超时
        ])
        fixture.host.run_tick(10, {"major_event": "match_started"})
        self.assertIsNotNone(fixture.coordinator.plans.active)
        fixture.host.run_tick(1300)  # 周期到期，第二请求超时
        self.assertEqual(len(fixture.sink.find("model_outcome_timeout")), 1)
        # 旧计划仍有效；协调器 degraded（不发新命令，游戏内自动防守照常）。
        self.assertIsNotNone(fixture.coordinator.plans.active)
        self.assertEqual(fixture.coordinator.plans.active.plan["plan_version"], 1)
        self.assertTrue(fixture.coordinator.degraded)

    def test_pending_result_settled_after_deadline_is_discarded(self):
        """到达时间早于请求发出（时间倒流）→ 无效结果丢弃；旧计划保留。"""
        fixture = HostFixture(strategy_script=[
            {"behavior": "completed", "plan": make_valid_plan(version=1)},
            {"behavior": "late", "arrives_at_tick": 140,
             "plan": make_valid_plan(version=2)},   # 140 < issued 1300：时间倒流
        ])
        fixture.host.run_tick(10, {"major_event": "match_started"})
        self.assertEqual(fixture.coordinator.plans.active.plan["plan_version"], 1)
        fixture.host.run_tick(1300)
        self.assertEqual(len(fixture.sink.find("model_outcome_invalid")), 1)
        self.assertIn("before issue", fixture.sink.find("model_outcome_invalid")[0]["reason"])
        # 无论如何旧计划不被 v2 覆盖。
        self.assertEqual(fixture.coordinator.plans.active.plan["plan_version"], 1)


class TestConnectionLifecycle(unittest.TestCase):

    def make_resilient_fixture(self, probe_identity=None, strategy_script=None):
        inner = FakeTransport(heartbeat_failures=3)
        identity = {"match_id": MATCH, "player_id": PLAYER, "rules_version": RULES}
        if probe_identity is not None:
            identity = probe_identity

        def probe():
            return dict(identity)

        resilient = ResilientTransport(inner, identity, reconnect_probe=probe)
        fixture = HostFixture(
            strategy_script=strategy_script,
            transport=resilient,
            coordinator_transport=resilient,
            identity_provider=probe,
            config=HostConfig(strategy_interval_ticks=1000, tactics_interval_ticks=1,
                              request_timeout_ticks=150, heartbeat_interval_ticks=1),
        )
        fixture.resilient = resilient
        return fixture

    def test_heartbeat_failures_trigger_reconnect_with_identity_check(self):
        fixture = self.make_resilient_fixture()
        # 心跳连续失败 3 次 → 断线 → 重连成功（身份一致）。
        fixture.host.run_tick(10)
        fixture.host.run_tick(20)
        fixture.host.run_tick(30)
        reconnected = fixture.sink.find("reconnected")
        self.assertEqual(len(reconnected), 1)
        self.assertEqual(reconnected[0]["reason"], "identity verified")
        self.assertEqual(fixture.host.state, "ok")

    def test_identity_drift_rejects_reconnect(self):
        fixture = self.make_resilient_fixture(
            probe_identity={"match_id": "m-OTHER", "player_id": PLAYER,
                            "rules_version": RULES})
        fixture.host.run_tick(10)
        fixture.host.run_tick(20)
        fixture.host.run_tick(30)
        rejected = fixture.sink.find("reconnect_rejected")
        self.assertEqual(len(rejected), 1)
        self.assertIn("match_id", rejected[0]["reason"])
        self.assertTrue(fixture.coordinator.degraded)
        # 保持断开：绝不把命令发进别的对局。
        self.assertEqual(fixture.resilient.state, ConnectionState.DISCONNECTED)

    def test_plan_survives_disconnect(self):
        """断线不丢当前计划/任务状态。"""
        fixture = self.make_resilient_fixture(strategy_script=[
            {"behavior": "completed", "plan": make_valid_plan(version=1)}])
        fixture.host.run_tick(1, {"major_event": "match_started"})
        self.assertIsNotNone(fixture.coordinator.plans.active)
        # 人为断开内层通道 → 心跳失败 → 断线处理（重连身份一致会恢复）。
        inner = fixture.resilient._inner
        inner.set_connected(False)
        fixture.host._last_heartbeat_tick = None
        fixture.host.run_tick(100000)
        # 计划与任务保持（断线不丢状态）。
        self.assertIsNotNone(fixture.coordinator.plans.active)
        self.assertEqual(fixture.coordinator.tasks.state_of("t-1"), "pending")


class TestDirtyDataTolerance(unittest.TestCase):

    def test_empty_invalid_unknown_do_not_crash(self):
        """空响应 / 非法 JSON 结构 / 未知状态：协调器不崩，命令标记可诊断。"""
        transport = FakeTransport(script=[
            "empty",         # 空响应
            "invalid_json",  # 非法 JSON 结构
            "unknown_state", # 未知 status
        ])
        fixture = HostFixture(
            transport=transport, coordinator_transport=transport,
            tactics_script=[{"behavior": "completed", "commands": [
                make_command("c-empty"),
                make_command("c-invalid", units=("Unit_2",)),
                make_command("c-unknown", units=("Unit_3",)),
            ]}])
        # 三条命令分别命中三种脏回执；协调器必须全部活着处理。
        fixture.host.run_tick(10)
        self.assertEqual(len(fixture.coordinator.decisions), 3)
        kinds = [d["kind"] for d in fixture.coordinator.decisions]
        self.assertIn("command_receipt", kinds)
        # 空回执与非法结构都不 accepted，但都不崩溃。
        self.assertFalse(fixture.coordinator.metrics.commands_accepted > 0)

    def test_provider_exception_structured_not_fatal(self):
        """provider 抛异常 → 结构化 error（限流降级），调度器不进 fatal。"""
        fixture = HostFixture(strategy_script=[{"behavior": "raise"}],
                              tactics_script=[])
        state = fixture.host.run_tick(10, {"major_event": "match_started"})
        self.assertEqual(state, "degraded")
        self.assertEqual(len(fixture.sink.find("model_outcome_error")), 1)
        self.assertNotEqual(fixture.host.state, HOST_FATAL)

    def test_scheduler_crash_becomes_fatal_and_reraises(self):
        """调度器内部意外异常 → fatal 可诊断状态并重抛，绝不静默吞错。"""

        class ExplodingTransport(FakeTransport):
            def heartbeat(self):
                raise RuntimeError("heartbeat exploded")

        fixture = HostFixture(transport=ExplodingTransport())
        with self.assertRaises(RuntimeError):
            fixture.host.run_tick(10)
        self.assertEqual(fixture.host.state, HOST_FATAL)
        self.assertIn("heartbeat exploded", fixture.host.fatal_reason)
        fatal = fixture.sink.find("host_fatal")
        self.assertEqual(len(fatal), 1)

    def test_malformed_plan_payload_rejected_not_crash(self):
        """格式错误的计划 payload：协议校验拒绝，协调器保持无计划状态。"""
        fixture = HostFixture(strategy_script=[
            {"behavior": "malformed", "payload": {"bogus": 1}}])
        fixture.host.run_tick(10, {"major_event": "match_started"})
        self.assertIsNone(fixture.coordinator.plans.active)
        self.assertEqual(len(fixture.sink.find("plan_adoption")), 1)
        self.assertEqual(fixture.sink.find("plan_adoption")[0]["status"], "rejected")


if __name__ == "__main__":
    unittest.main()
