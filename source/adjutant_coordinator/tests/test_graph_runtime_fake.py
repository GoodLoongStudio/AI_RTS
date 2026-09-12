# -*- coding: utf-8 -*-
"""运行时测试（FakeModel，不需要 API Key）：

1. 战略计划 → 紧急战术意图 → 权威下发 → 回执；
2. 玩家打断立即生效、图暂停/恢复、旧意图不能抢回、显式归还后重新接管；
3. PendingAuthority 不重复下单，复核终态后结算；
4. checkpoint 恢复后不重复下单；
5. 模型超时/连续失败降级与冷却（Godot 不阻塞）；
6. LangGraph 引擎与内置执行器行为一致（未安装 langgraph 时跳过）。
"""

import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph.checkpoint import JsonCheckpointStore, MemoryCheckpointStore
from adjutant_coordinator.graph.graph import langgraph_available
from adjutant_coordinator.graph.pydantic_agents import FakeStructuredModel
from adjutant_coordinator.graph.runtime import AdjutantGraphRuntime, RuntimeConfig

from graph_test_helpers import (
    MATCH, PLAYER, RecordingTransport, events_for, header, make_batch, make_intent,
    make_plan, rules_view, strategic, tactical,
)

ENGINE_FALLBACK = "fallback"
ENGINE_LANGGRAPH = "langgraph"


def base_config(engine=ENGINE_FALLBACK, **overrides):
    config = RuntimeConfig(
        engine=engine,
        strategy_interval_ticks=100000,
        tactics_interval_ticks=1,
        emergency_min_interval_ticks=1,
        intent_ttl_ticks=600,
        emergency_intent_ttl_ticks=300,
        pending_timeout_ticks=1000,
        pause_on_player_interrupt=True,
    )
    for key, value in overrides.items():
        setattr(config, key, value)
    return config


def observation(tick, events=None, own=None, enemies=None, match_id=MATCH,
                rules_version=None):
    return {
        "header": header(tick, match_id=match_id,
                         rules_version=rules_version or None or "hash-graph-1"),
        "strategic": strategic(tick),
        "tactical": tactical(own=own, enemies=enemies, server_tick=tick),
        "rules": rules_view(),
        "events": list(events or []),
        "budget": {},
    }


class RuntimeFixture:
    """组装运行时：假模型 + 通道桩 + 内存 checkpoint。"""

    def __init__(self, strategy_script=None, tactics_script=None, transport=None,
                 config=None, store=None, recheck_fn=None):
        self.transport = transport or RecordingTransport()
        self.store = store or MemoryCheckpointStore()
        self.strategy = FakeStructuredModel("strategy", strategy_script or [])
        self.tactics = FakeStructuredModel("tactics", tactics_script or [])
        self.runtime = AdjutantGraphRuntime(
            MATCH, PLAYER, transport=self.transport,
            strategy_model=self.strategy, tactics_model=self.tactics,
            checkpoint_store=self.store, config=config or base_config(),
            recheck_fn=recheck_fn)
        self.runtime.restore()

    def tick(self, tick, events=None, own=None, enemies=None, match_id=MATCH):
        return self.runtime.tick(
            tick, observation(tick, events=events, own=own, enemies=enemies,
                              match_id=match_id))


class PlanAndDispatchTest(unittest.TestCase):
    def test_strategy_plan_then_emergency_intent_is_dispatched(self):
        fixture = RuntimeFixture(
            strategy_script=[{"behavior": "completed", "plan": make_plan()}],
            tactics_script=[{"behavior": "completed", "intents": make_batch(
                [make_intent("i-1", issued_tick=5, expires_tick=605)])}])
        first = fixture.tick(0)
        self.assertEqual(first.route, "strategic")
        self.assertEqual(fixture.runtime.state.plan_version, "plan-a:v1")
        self.assertEqual(fixture.transport.sent, [])

        second = fixture.tick(5, events=[events_for("enemy_spotted", ["Unit_1"], 5)])
        self.assertEqual(second.route, "emergency_tactical")
        self.assertEqual(second.accepted_intents, ["i-1"])
        self.assertEqual(len(fixture.transport.sent), 1)
        envelope = fixture.transport.sent[0]
        self.assertEqual(envelope["op"], "adjutant_intent")
        self.assertEqual(envelope["generation"], fixture.runtime.state.generation_of("Unit_1"))
        self.assertEqual(second.receipts[0]["status"], "Accepted")
        self.assertEqual(fixture.runtime.state.task_state("t-1"), "running")

    def test_expired_window_is_recomputed_at_dispatch_with_fresh_tick(self):
        """真实模型慢：下发前按宿主提供的最新 tick 重算过期窗口（显式留痕）。"""
        fixture = RuntimeFixture(
            strategy_script=[{"behavior": "completed", "plan": make_plan()}],
            tactics_script=[{"behavior": "completed", "intents": make_batch(
                # 决策时的窗口：在模型耗时后已经过期（expires 远小于宿主最新 tick）
                [make_intent("i-1", issued_tick=5, expires_tick=10)])}])
        fixture.runtime._tick_provider = lambda: {"server_tick": 9000,
                                                 "snapshot_id": 120}
        fixture.tick(0)
        result = fixture.tick(5, events=[events_for("enemy_spotted", ["Unit_1"], 5)])
        self.assertEqual(result.accepted_intents, ["i-1"])
        envelope = fixture.transport.sent[-1]
        self.assertGreater(envelope["expires_tick"], 9000)
        self.assertEqual(result.receipts[0]["status"], "Accepted")
        kinds = [item["kind"] for item in fixture.runtime.state.decision_log]
        self.assertIn("intent_ttl_recomputed", kinds)

    def test_strategy_never_emits_commands_by_itself(self):
        fixture = RuntimeFixture(
            strategy_script=[{"behavior": "completed", "plan": make_plan()}],
            tactics_script=[])
        fixture.tick(0)
        self.assertEqual(fixture.transport.sent, [])
        self.assertEqual(fixture.runtime.state.active_tasks, {"t-1": "pending"})


class PlanVersionEchoTest(unittest.TestCase):
    """真实模型常把 plan_version 写成 plan_id / 版本号：可归一化，但历史版本必须仍被拒。"""

    def test_normalize_semantics(self):
        from adjutant_coordinator.graph.nodes import _normalize_plan_version

        state = {"plan_version": "plan-b:v2", "plan_version_history": ["plan-a:v1"],
                 "active_plan": {"plan_id": "plan-b", "plan_version": 2}}
        self.assertEqual(_normalize_plan_version("plan-a:v1", state), "plan-a:v1")
        self.assertEqual(_normalize_plan_version("plan-b", state), "plan-b:v2")
        self.assertEqual(_normalize_plan_version("2", state), "plan-b:v2")
        self.assertEqual(_normalize_plan_version("v2", state), "plan-b:v2")
        self.assertEqual(_normalize_plan_version("随便写的", state), "plan-b:v2")
        self.assertEqual(_normalize_plan_version("", state), "plan-b:v2")

    def test_echo_written_wrong_is_still_accepted(self):
        fixture = RuntimeFixture(
            strategy_script=[{"behavior": "completed", "plan": make_plan(plan_id="plan-a")}],
            tactics_script=[{"behavior": "completed", "intents": make_batch(
                [make_intent("i-1", plan_version="1", issued_tick=5, expires_tick=605)],
                plan_version="1")}])
        fixture.tick(0)
        result = fixture.tick(5, events=[events_for("enemy_spotted", ["Unit_1"], 5)])
        self.assertEqual(result.accepted_intents, ["i-1"])
        record = fixture.runtime.state.find_intent("i-1")
        self.assertEqual(record["plan_version"], "plan-a:v1")
        self.assertEqual(result.receipts[0]["status"], "Accepted")


class PlayerInterruptRuntimeTest(unittest.TestCase):
    def make_fixture(self, engine=ENGINE_FALLBACK):
        return RuntimeFixture(
            strategy_script=[{"behavior": "completed", "plan": make_plan()}],
            tactics_script=[
                {"behavior": "completed", "intents": make_batch(
                    [make_intent("i-1", issued_tick=5, expires_tick=605)])},
                {"behavior": "completed", "intents": make_batch(
                    [make_intent("i-2", issued_tick=10, expires_tick=605)])},
                {"behavior": "completed", "intents": make_batch(
                    [make_intent("i-3", issued_tick=21, expires_tick=605)])},
            ],
            config=base_config(engine))

    def test_player_override_pauses_graph_and_blocks_old_intent(self):
        fixture = self.make_fixture()
        fixture.tick(0)
        fixture.tick(5, events=[events_for("enemy_spotted", ["Unit_1"], 5)])
        self.assertEqual(len(fixture.transport.sent), 1)

        record = fixture.runtime.on_player_command(["Unit_1"], server_tick=8)
        self.assertEqual(fixture.runtime.state.find_intent("i-1")["state"], "dropped")
        self.assertEqual(record["dropped_intents"], ["i-1"])
        self.assertTrue(fixture.runtime.state.is_unit_player_controlled("Unit_1"))

        paused = fixture.tick(8)
        self.assertEqual(paused.route, "player_interrupt")
        self.assertTrue(paused.paused)
        # 暂停期间不下发命令（等宿主/玩家决定后再恢复）。
        self.assertEqual(len(fixture.transport.sent), 1)

        resumed = fixture.tick(9)
        self.assertFalse(resumed.paused)
        self.assertEqual(len(fixture.transport.sent), 1)

        # 旧模型响应（同一个单位的旧代际）不能抢回控制。
        after = fixture.tick(10, events=[events_for("queue_idle", ["Unit_1"], 10)])
        dropped = {item["intent_id"]: item["reason"] for item in after.dropped_intents}
        self.assertEqual(dropped.get("i-2"), "lease_owner_player:Unit_1")
        self.assertEqual(len(fixture.transport.sent), 1)
        self.assertEqual(fixture.runtime.state.player_controlled_units, ["Unit_1"])

    def test_release_then_ai_can_control_again(self):
        fixture = self.make_fixture()
        fixture.tick(0)
        fixture.tick(5, events=[events_for("enemy_spotted", ["Unit_1"], 5)])
        fixture.runtime.on_player_command(["Unit_1"], server_tick=8)
        fixture.tick(8)
        fixture.tick(9)
        fixture.tick(10, events=[events_for("queue_idle", ["Unit_1"], 10)])

        fixture.runtime.on_player_release(["Unit_1"], server_tick=20)
        self.assertFalse(fixture.runtime.state.is_unit_player_controlled("Unit_1"))
        fixture.tick(20)                     # 玩家打断：暂停
        result = fixture.tick(21, events=[events_for("queue_idle", ["Unit_1"], 21)])
        self.assertEqual(result.accepted_intents, ["i-3"])
        self.assertEqual(len(fixture.transport.sent), 2)
        self.assertEqual(fixture.transport.sent[1]["intent_id"], "i-3")
        self.assertEqual(result.receipts[0]["status"], "Accepted")

    def test_reacquire_intent_carries_flag_to_authority(self):
        fixture = RuntimeFixture(
            strategy_script=[{"behavior": "completed", "plan": make_plan()}],
            tactics_script=[{"behavior": "completed", "intents": make_batch(
                [make_intent("i-1", issued_tick=5, expires_tick=605)])}])
        fixture.tick(0)
        fixture.tick(5, events=[events_for("enemy_spotted", ["Unit_1"], 5)])
        fixture.runtime.on_player_command(["Unit_1"], server_tick=8)
        fixture.tick(8)
        fixture.tick(9)
        fixture.runtime.on_player_release(["Unit_1"], server_tick=20)
        fixture.tick(20)
        reacquire = make_intent("i-reacquire", issued_tick=21, expires_tick=605)
        reacquire["reacquire"] = True
        fixture.tactics._script.append({"behavior": "completed",
                                        "intents": make_batch([reacquire])})
        result = fixture.tick(21, events=[events_for("queue_idle", ["Unit_1"], 21)])
        self.assertEqual(result.accepted_intents, ["i-reacquire"])
        self.assertTrue(fixture.transport.sent[-1]["params"]["reacquire"],
                        "显式重新接管标记必须随命令包送到权威层")

    def test_local_override_keeps_strategy_plan(self):
        fixture = self.make_fixture()
        fixture.tick(0)
        before_plan = fixture.runtime.state.plan_version
        fixture.runtime.on_player_command(["Unit_1"], server_tick=8)
        fixture.tick(8)
        self.assertEqual(fixture.runtime.state.plan_version, before_plan)
        self.assertIsNotNone(fixture.runtime.state.active_plan)


class PendingAuthorityTest(unittest.TestCase):
    def test_pending_authority_is_not_resubmitted_and_resolves_by_receipt(self):
        transport = RecordingTransport(script=[{"accepted": False, "status": "PendingAuthority"}])
        recheck = lambda command_id: {"command_id": command_id, "intent_id": "i-1",
                                      "status": "Accepted", "accepted": True, "result": {}}
        fixture = RuntimeFixture(
            strategy_script=[{"behavior": "completed", "plan": make_plan()}],
            tactics_script=[{"behavior": "completed", "intents": make_batch(
                [make_intent("i-1", issued_tick=5, expires_tick=605)])}],
            transport=transport, recheck_fn=recheck)
        fixture.tick(0)
        result = fixture.tick(5, events=[events_for("enemy_spotted", ["Unit_1"], 5)])
        self.assertEqual(result.receipts[0]["status"], "PendingAuthority")
        self.assertIn("i-1", fixture.runtime.state.pending_requests)
        self.assertEqual(len(transport.sent), 1)

        # 在途未复核：本轮不触发战术（更不会重复下单）。
        waiting = fixture.tick(6, events=[events_for("queue_idle", ["Unit_1"], 6)])
        self.assertEqual(waiting.route, "wait")
        self.assertEqual(len(transport.sent), 1)
        self.assertEqual(fixture.tactics.call_count, 1)

        # 复核终态：pending 结算，意图进入 active，不需要重下单。
        resolved = fixture.tick(7)
        self.assertEqual(fixture.runtime.state.pending_requests, {})
        self.assertEqual(fixture.runtime.state.find_intent("i-1")["state"], "active")
        self.assertEqual(len(transport.sent), 1)
        kinds = [item["kind"] for item in fixture.runtime.state.decision_log]
        self.assertIn("pending_resolved", kinds)
        self.assertGreaterEqual(resolved.server_tick, 7)


class DegradeTest(unittest.TestCase):
    def test_model_timeout_degrades_without_blocking(self):
        fixture = RuntimeFixture(
            strategy_script=[{"behavior": "timeout"},
                             {"behavior": "completed", "plan": make_plan()}],
            tactics_script=[{"behavior": "timeout"}])
        first = fixture.tick(0)
        self.assertEqual(first.route, "strategic")
        self.assertIn("strategy_model_ModelTimeout", first.degraded_reason)
        self.assertIsNone(fixture.runtime.state.active_plan)

        # 战略失败不阻塞后续：下一轮成功采纳计划并清除降级。
        second = fixture.tick(1)
        self.assertEqual(fixture.runtime.state.plan_version, "plan-a:v1")
        self.assertEqual(second.degraded_reason, "")

        # 战术超时：既有计划保留，图不抛异常；降级原因必须保留可见——
        # 否则分不清"模型恢复"与"兜底顶上"。
        # 注意：本 fixture 的观测里没有 resource 实体，规则兜底判定"无事实可依"→
        # 不产出意图，所以这里仍然不下发；兜底"能派工"由 test_rules_fallback 覆盖。
        third = fixture.tick(5, events=[events_for("enemy_spotted", ["Unit_1"], 5)])
        self.assertIn("tactics_model_ModelTimeout", third.degraded_reason)
        self.assertIsNotNone(fixture.runtime.state.active_plan)
        self.assertEqual(fixture.transport.sent, [])

    def test_model_cooldown_after_repeated_failures(self):
        fixture = RuntimeFixture(
            strategy_script=[{"behavior": "timeout"}, {"behavior": "timeout"},
                             {"behavior": "timeout"}],
            config=base_config(model_error_limit=2, model_retry_cooldown_ticks=60))
        fixture.tick(0)
        fixture.tick(1)
        skipped = fixture.tick(2)
        self.assertEqual(skipped.route, "strategic")
        kinds = [(item["kind"], item.get("reason"))
                 for item in fixture.runtime.state.decision_log]
        self.assertIn(("strategy_skipped", "model_cooldown"), kinds)
        self.assertEqual(fixture.strategy.call_count, 2)
        # 冷却结束后允许再次调用（不会永久降级）。
        fixture.tick(62)
        self.assertEqual(fixture.strategy.call_count, 3)

    def test_identity_drift_blocks_dispatch(self):
        fixture = RuntimeFixture(
            strategy_script=[{"behavior": "completed", "plan": make_plan()}],
            tactics_script=[{"behavior": "completed", "intents": make_batch(
                [make_intent("i-1", issued_tick=5, expires_tick=605)])}])
        fixture.tick(0)
        drifted = fixture.tick(5, events=[events_for("enemy_spotted", ["Unit_1"], 5)],
                               match_id="other-match")
        self.assertEqual(drifted.degraded_reason, "identity_drift")
        self.assertEqual(fixture.transport.sent, [])


class CheckpointRestoreTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="adjutant-runtime-")
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)

    def test_restore_resumes_without_duplicate_orders(self):
        store = JsonCheckpointStore(self.root, MATCH, PLAYER)
        first = RuntimeFixture(
            strategy_script=[{"behavior": "completed", "plan": make_plan()}],
            tactics_script=[{"behavior": "completed", "intents": make_batch(
                [make_intent("i-1", issued_tick=5, expires_tick=605)])}],
            store=store)
        first.tick(0)
        first.tick(5, events=[events_for("enemy_spotted", ["Unit_1"], 5)])
        self.assertEqual(len(first.transport.sent), 1)
        saved = first.runtime.checkpoint()
        self.assertTrue(saved["saved"], saved)

        # 模拟进程重启：新运行时、新通道、新的空脚本模型。
        transport = RecordingTransport()
        restarted = RuntimeFixture(transport=transport, store=store)
        outcome = restarted.runtime.restore()
        self.assertTrue(outcome["restored"], outcome)
        state = restarted.runtime.state
        self.assertEqual(state.plan_version, "plan-a:v1")
        self.assertEqual([item["intent_id"] for item in state.active_intents], ["i-1"])
        self.assertEqual(state.generation_of("Unit_1"), first.runtime.state.generation_of("Unit_1"))
        self.assertEqual(state.active_tasks, first.runtime.state.active_tasks)

        # 恢复后继续 tick：不会重放已接受的意图（不重复下单）。
        result = restarted.tick(30)
        self.assertEqual(transport.sent, [])
        self.assertEqual(result.accepted_intents, [])

    def test_restore_refuses_rules_version_drift(self):
        store = JsonCheckpointStore(self.root, MATCH, PLAYER)
        fixture = RuntimeFixture(
            strategy_script=[{"behavior": "completed", "plan": make_plan()}],
            store=store)
        fixture.tick(0)
        fixture.runtime.checkpoint()
        restarted = RuntimeFixture(store=store)
        outcome = restarted.runtime.restore(expect_rules_version="another-hash")
        self.assertFalse(outcome["restored"])
        self.assertEqual(outcome["reason"], "rules_version_mismatch")


@unittest.skipUnless(langgraph_available()["available"],
                     "langgraph 未安装；LanguageGraph 引擎专项测试跳过")
class LangGraphEngineTest(unittest.TestCase):
    """真实 LangGraph 引擎：同一批节点 + checkpoint + interrupt/resume。"""

    def make_fixture(self):
        return RuntimeFixture(
            strategy_script=[{"behavior": "completed", "plan": make_plan()}],
            tactics_script=[
                {"behavior": "completed", "intents": make_batch(
                    [make_intent("i-1", issued_tick=5, expires_tick=605)])},
                {"behavior": "completed", "intents": make_batch(
                    [make_intent("i-2", issued_tick=10, expires_tick=605)])},
            ],
            config=base_config(ENGINE_LANGGRAPH))

    def test_langgraph_dispatch_and_interrupt_resume(self):
        fixture = self.make_fixture()
        self.assertEqual(fixture.runtime.runner.engine, ENGINE_LANGGRAPH)
        first = fixture.tick(0)
        self.assertEqual(first.route, "strategic")
        self.assertEqual(fixture.runtime.state.plan_version, "plan-a:v1")

        second = fixture.tick(5, events=[events_for("enemy_spotted", ["Unit_1"], 5)])
        self.assertEqual(second.accepted_intents, ["i-1"])
        self.assertEqual(len(fixture.transport.sent), 1)

        fixture.runtime.on_player_command(["Unit_1"], server_tick=8)
        paused = fixture.tick(8)
        self.assertEqual(paused.route, "player_interrupt")
        self.assertTrue(paused.paused, "LangGraph 应在 reconcile_plan 后暂停图")

        resumed = fixture.tick(9)
        self.assertFalse(resumed.paused)
        self.assertEqual(len(fixture.transport.sent), 1)

        after = fixture.tick(10, events=[events_for("queue_idle", ["Unit_1"], 10)])
        dropped = {item["intent_id"]: item["reason"] for item in after.dropped_intents}
        self.assertEqual(dropped.get("i-2"), "lease_owner_player:Unit_1")

    def test_langgraph_and_fallback_agree_on_route_and_intents(self):
        def run(engine):
            fixture = RuntimeFixture(
                strategy_script=[{"behavior": "completed", "plan": make_plan()}],
                tactics_script=[{"behavior": "completed", "intents": make_batch(
                    [make_intent("i-1", issued_tick=5, expires_tick=605)])}],
                config=base_config(engine))
            results = [fixture.tick(0),
                       fixture.tick(5, events=[events_for("enemy_spotted", ["Unit_1"], 5)])]
            return results

        fallback = run(ENGINE_FALLBACK)
        langgraph = run(ENGINE_LANGGRAPH)
        for left, right in zip(fallback, langgraph):
            self.assertEqual(left.route, right.route)
            self.assertEqual(left.accepted_intents, right.accepted_intents)
            self.assertEqual(left.paused, right.paused)
            self.assertEqual([r["status"] for r in left.receipts],
                             [r["status"] for r in right.receipts])


class StrategyDisabledRoutingTest(unittest.TestCase):
    """战略层缺省（--strategy-mode off / 模型缺失）时的路由回归钉（2026-09-12）。

    死锁机制：active_plan 恒为 None → is_strategy_due 恒真 → 路由永远 strategic；
    战略层关闭后不再报错（也就不进冷却让位）→ 战术节点永远轮不到 →
    task_patch_submitted=0、整局 0 下发（实测 556/556 全 strategic、own=4 全程不变）。
    修复：strategy_disabled 立标志后，classify_route 跳过战略分支，战术分支成为
    单一决策入口（计划 §6 阶段 A：省略高层、状态里标注高层意图缺省）。
    """

    def _runtime_without_strategy(self, tactics_script):
        transport = RecordingTransport()
        runtime = AdjutantGraphRuntime(
            MATCH, PLAYER, transport=transport,
            strategy_model=None,
            tactics_model=FakeStructuredModel("tactics", tactics_script),
            checkpoint_store=MemoryCheckpointStore(), config=base_config())
        runtime.restore()
        return runtime, transport

    def test_runtime_marks_strategy_disabled_at_construction(self):
        runtime, _ = self._runtime_without_strategy([])
        self.assertTrue(runtime.state.strategy_disabled)

    def test_strategy_model_present_keeps_flag_false(self):
        fixture = RuntimeFixture(
            strategy_script=[{"behavior": "completed", "plan": make_plan()}],
            tactics_script=[])
        self.assertFalse(fixture.runtime.state.strategy_disabled)

    def test_no_event_without_strategy_routes_wait_not_strategic(self):
        runtime, _ = self._runtime_without_strategy([])
        first = runtime.tick(0)
        self.assertEqual(first.route, "wait")
        kinds = [str(entry.get("kind", ""))
                 for entry in runtime.state.decision_log]
        self.assertNotIn("strategy_skipped", kinds)

    def test_tactical_entry_dispatches_intents_without_strategy(self):
        runtime, transport = self._runtime_without_strategy(
            [{"behavior": "completed", "intents": make_batch(
                [make_intent("i-1", issued_tick=5, expires_tick=605)])}])
        second = runtime.tick(5, observation(
            5, events=[events_for("queue_idle", ["Unit_1"], 5)],
            own=[{"name": "Unit_1"}]))
        self.assertEqual(second.route, "tactical")
        self.assertEqual(second.accepted_intents, ["i-1"])
        self.assertEqual(len(transport.sent), 1)
        self.assertEqual(transport.sent[0]["op"], "adjutant_intent")

    def test_wait_node_preserves_micro_candidates_for_arbitration(self):
        """wait 轮微操候选必须能到达仲裁（WAIT→ARBITRATE 边）。

        node_wait 曾无条件清空 candidate_intents：战略层关闭后 wait 轮占绝大多数，
        微操候选全部饿死（仲裁恒空、整局 sent=0、基地纹丝不动，2026-09-12 实测）。
        """
        from adjutant_coordinator.graph.nodes import node_wait
        candidate = {"intent_id": "bt-gather-Unit_3-1", "action": "gather",
                     "unit_ids": ["Unit_3"]}
        state = {"pending_events": [{"kind": "queue_idle", "payload": {}}],
                 "candidate_intents": [candidate], "intent_arbitration": {}}
        out = node_wait(state, None)
        self.assertEqual(out["candidate_intents"], [candidate])

    def test_lease_generation_sync_adopts_authority_and_never_regresses(self):
        """控制代际以权威为准（StaleGeneration 白拒回归钉，2026-09-12）。

        权威租约计数跨对局累加而本地每轮重算：单位第一次命令后权威代际就永久领先，
        之后所有命令被 StaleGeneration 拒（实测 5 分钟 336 条、每单位只吃得到一条）。
        对齐规则：权威领先 → 采纳；本地领先（玩家接管镜像 +1）→ 保留（守卫只拒落后）。
        """
        runtime, _ = self._runtime_without_strategy([])
        runtime.state.unit_generations = {"Unit_1": 3}
        obs = observation(5, events=[events_for("queue_idle", ["Unit_1"], 5)],
                          own=[{"name": "Unit_1"}])
        obs["tactical"]["lease_generations"] = {"Unit_1": 340, "Unit_9": 341}
        runtime.tick(5, obs)
        self.assertEqual(runtime.state.generation_of("Unit_1"), 340)
        self.assertEqual(runtime.state.generation_of("Unit_9"), 341)
        synced = [e for e in runtime.state.decision_log
                  if str(e.get("kind", "")) == "lease_generation_synced"]
        self.assertTrue(synced)
        runtime.state.unit_generations["Unit_1"] = 500
        obs2 = observation(6, own=[{"name": "Unit_1"}])
        obs2["tactical"]["lease_generations"] = {"Unit_1": 340}
        runtime.tick(6, obs2)
        self.assertEqual(runtime.state.generation_of("Unit_1"), 500)


@unittest.skipUnless(langgraph_available()["available"],
                     "langgraph 未安装，跳过 langgraph 引擎测试")
class StrategyDisabledLangGraphTest(unittest.TestCase):
    """langgraph 引擎下的同一回归钉。

    LangGraph StateGraph 只认 GraphStateDict 声明的通道：漏声明的键在图入口
    `_cleaned` 与节点输出两处被过滤。strategy_disabled 漏声明时，构造期与
    节点内立的标志全部失效 → 路由死锁在 strategic（真机 556/556 全 strategic）。
    patch_ready 漏声明时，异步结果收得到（task_patch_result）却落不了地
    （task_patch_applied 恒 0）。
    """

    def test_flag_survives_channel_and_routes_tactical(self):
        transport = RecordingTransport()
        runtime = AdjutantGraphRuntime(
            MATCH, PLAYER, transport=transport,
            strategy_model=None,
            tactics_model=FakeStructuredModel(
                "tactics", [{"behavior": "completed", "intents": make_batch(
                    [make_intent("i-1", issued_tick=5, expires_tick=605)])}]),
            checkpoint_store=MemoryCheckpointStore(),
            config=base_config(ENGINE_LANGGRAPH))
        runtime.restore()
        self.assertEqual(runtime.runner.engine, ENGINE_LANGGRAPH)
        self.assertTrue(runtime.state.strategy_disabled)
        second = runtime.tick(5, observation(
            5, events=[events_for("queue_idle", ["Unit_1"], 5)],
            own=[{"name": "Unit_1"}]))
        self.assertEqual(second.route, "tactical")
        self.assertEqual(second.accepted_intents, ["i-1"])
        self.assertEqual(len(transport.sent), 1)

    def test_patch_ready_key_is_a_declared_channel(self):
        from adjutant_coordinator.graph.graph import GraphStateDict
        declared = set(GraphStateDict.__annotations__)
        for key in ("strategy_disabled", "patch_ready", "plan_version_history",
                    "reserves", "reserves_initialized", "reserves_percent",
                    "task_progress"):
            self.assertIn(key, declared)


if __name__ == "__main__":
    unittest.main()
