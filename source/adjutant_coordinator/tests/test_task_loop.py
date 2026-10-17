# -*- coding: utf-8 -*-
"""任务反馈闭环测试（第一阶段 · 修改 2：把任务分支接成可执行闭环）。

覆盖验收要求的正反场景：
1. 正常建造/生产/采集/移动中的真实进展不误判超时（waiting 保持）；
2. 到期无进展沿 timeout 边、明确失败沿 failure 边分别进诊断；
3. 重复输出 / Accepted 回执 / 重复回执不刷新 last_progress（停滞任务不会永远保活）；
4. 失败方案预算内可恢复（attempt+1）、耗尽受阻、条件变化可重评；
5. 暂停/玩家接管不消耗游戏进展等待预算（时钟用 server_tick）；
6. 缺失观测按 unknown/证据不足处理，不虚报完成；
7. 上层目标收到失败/恢复反馈；
8. 结束态任务不因恢复/时钟重置重开；
9. 期限/预算可配置且有单位（秒 → tick 换算）。
"""

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph import task_loop as tl
from adjutant_coordinator.graph.trace import load_trace

from graph_test_helpers import MATCH, PLAYER, events_for, make_batch, make_intent, make_plan
from test_graph_runtime_fake import RuntimeFixture, base_config, observation


def make_state(**overrides):
    state = {
        "match_id": MATCH, "player_id": PLAYER,
        "active_tasks": {}, "active_intents": [], "active_plan": None,
        "plan_version": "", "unit_arrival_tick": {}, "campaign_state": {},
        "measured_tick_hz": 30.0,
    }
    state.update(overrides)
    return state


def make_facts(**overrides):
    facts = {
        "constructed": {}, "counts": {}, "builders": ["Unit_w"], "producers": [],
        "workers": ["Unit_w"], "resource_count": 1, "refinery_delivered": 0,
        "balance": {"A": 1000}, "own": ["Unit_w"],
    }
    facts.update(overrides)
    return facts


def build_task_record(**overrides):
    record = tl.new_record("rule-build-vehicle_factory", goal_id="M01",
                           kind="build", tick=0)
    record["building_type"] = "vehicle_factory"
    record.update(overrides)
    return record


class DeadlineMathTest(unittest.TestCase):
    """期限换算与配置单位。"""

    def test_seconds_to_ticks_uses_measured_hz(self):
        self.assertEqual(tl.seconds_to_ticks(30.0, 30.0), 900)
        self.assertEqual(tl.seconds_to_ticks(30.0, 0.0),
                         tl.seconds_to_ticks(30.0, tl.FALLBACK_TICK_HZ))

    def test_per_kind_defaults_exist_with_rationale(self):
        for kind in ("build", "produce", "gather", "move", "attack"):
            self.assertIn(kind, tl.NO_PROGRESS_SECONDS)
            self.assertIn(kind, tl.DEADLINE_SECONDS)
        # 无进展期限必须小于总期限（否则 timeout 边永远先到，no_progress 边不可达）。
        for kind, seconds in tl.NO_PROGRESS_SECONDS.items():
            self.assertLess(seconds, tl.DEADLINE_SECONDS[kind])

    def test_zero_config_means_default_not_one_second(self):
        """0 = 用按类型默认表（round-02 真机闸门抓到的假超时根因）。"""
        from adjutant_coordinator.graph.task_loop import _config_seconds
        # 0.0 不得被当成 1 秒覆盖。
        self.assertEqual(
            _config_seconds({"loop_deadline_seconds": 0.0}, "build",
                            "loop_deadline_seconds", tl.DEADLINE_SECONDS,
                            tl.DEFAULT_DEADLINE_SECONDS),
            tl.DEADLINE_SECONDS["build"])
        # 显式正值才覆盖。
        self.assertEqual(
            _config_seconds({"loop_deadline_seconds": 12.0}, "build",
                            "loop_deadline_seconds", tl.DEADLINE_SECONDS,
                            tl.DEFAULT_DEADLINE_SECONDS), 12.0)
        # 按类型覆盖优先于全局。
        self.assertEqual(
            _config_seconds({"loop_no_progress_seconds": 99.0,
                             "loop_no_progress_seconds_build": 5.0}, "build",
                            "loop_no_progress_seconds", tl.NO_PROGRESS_SECONDS,
                            tl.DEFAULT_NO_PROGRESS_SECONDS), 5.0)


class ProgressVerdictTest(unittest.TestCase):
    """判定：成功/等待/无进展/超时/未知。"""

    def test_real_progress_never_false_timeout(self):
        """建造中（constructed 0→1 之前工地出现即算推进）不能误判超时。"""
        state = make_state()
        record = build_task_record()
        facts = make_facts(counts={"vehicle_factory": 1})  # 工地已出现
        verdict, code, cn, metrics = tl.evaluate_record(
            record, facts=facts, state=state, tick=100, mono=1.0)
        # constructed 仍是 0：未成功；stalled 未到限 → 正常等待。
        self.assertEqual(verdict, "waiting")
        self.assertEqual(code, "in_progress")

    def test_build_completion_is_success_evidence(self):
        """R2 返修：基线在任务建立时采集（0 座完工），之后出现完工才算本任务成功。"""
        state = make_state()
        record = build_task_record()
        # 建立轮：世界上还没有该建筑 → 基线 0。
        verdict, _, _, _ = tl.evaluate_record(
            record, facts=make_facts(), state=state, tick=100, mono=1.0)
        self.assertEqual(verdict, "waiting")
        self.assertEqual(record["baseline"], 0)
        # 完工事实出现 → 超过基线 → 成功。
        facts = make_facts(constructed={"vehicle_factory": 1})
        verdict, code, cn, metrics = tl.evaluate_record(
            record, facts=facts, state=state, tick=200, mono=2.0)
        self.assertEqual(verdict, "succeeded")
        self.assertIn("成功判据达成", cn)

    def test_preexisting_building_is_not_task_success(self):
        """R2 返修（独立复核反例）：任务建立前就存在的完工建筑不算本任务成功。"""
        state = make_state()
        record = build_task_record()
        facts = make_facts(constructed={"vehicle_factory": 1})
        verdict, _, cn, _ = tl.evaluate_record(
            record, facts=facts, state=state, tick=100, mono=1.0)
        self.assertEqual(verdict, "waiting")
        self.assertEqual(record["baseline"], 1)

    def test_no_progress_edge_after_limit(self):
        state = make_state()
        record = build_task_record()
        facts = make_facts()  # 什么都没变
        # 先评估一次（建立期限基线），再跨过无进展期限。
        tl.evaluate_record(record, facts=facts, state=state, tick=0, mono=0.0)
        verdict, code, cn, metrics = tl.evaluate_record(
            record, facts=facts, state=state, tick=100000, mono=100.0)
        self.assertEqual(verdict, "timeout")  # 总期限先到（deadline 900*8 tick 级）
        self.assertEqual(code, "total_deadline")

    def test_no_progress_without_total_deadline(self):
        """总期限关不掉（0=默认）时用极大值验证 no_progress 边本身可达。"""
        state = make_state()
        record = build_task_record(deadline_tick=10 ** 9)
        facts = make_facts()
        tl.evaluate_record(record, facts=facts, state=state, tick=0, mono=0.0)
        verdict, code, cn, metrics = tl.evaluate_record(
            record, facts=facts, state=state, tick=5000, mono=50.0)
        self.assertEqual(verdict, "no_progress")
        self.assertEqual(code, "no_progress_limit")

    def test_missing_evidence_is_unknown_not_failure(self):
        state = make_state()
        record = build_task_record()
        facts = make_facts()
        del facts["constructed"]  # 权威字段缺失
        record["building_type"] = ""
        verdict, code, cn, metrics = tl.evaluate_record(
            record, facts=facts, state=state, tick=10, mono=1.0)
        self.assertEqual(verdict, "unknown")
        self.assertIn("证据不足", cn)

    def test_gather_success_requires_delivery_not_balance(self):
        """采集成功只认真实交货；余额上升（可能来自其它收入）不算。"""
        state = make_state()
        record = tl.new_record("rule-gather-Unit_1-100", goal_id="M01",
                               kind="gather", tick=0)
        facts = make_facts(balance={"A": 9999}, refinery_delivered=0)
        verdict, _, _, _ = tl.evaluate_record(
            record, facts=facts, state=state, tick=10, mono=1.0)
        self.assertEqual(verdict, "waiting")
        facts["refinery_delivered"] = 1
        verdict, _, cn, _ = tl.evaluate_record(
            record, facts=facts, state=state, tick=20, mono=2.0)
        self.assertEqual(verdict, "succeeded")
        self.assertIn("交货", cn)


class LastProgressDisciplineTest(unittest.TestCase):
    """last_progress 只由实际变化更新。"""

    def test_repeated_receipts_do_not_refresh_progress(self):
        """重复输出 / Accepted 回执 / 重复回执都不能刷新实际进展时间。"""
        state = make_state()
        record = build_task_record()
        facts = make_facts()
        tl.evaluate_record(record, facts=facts, state=state, tick=0, mono=0.0)
        first_progress_tick = record["last_progress_tick"]
        # 模拟 20 轮"重复输出 + Accepted 回执"：指标没有任何变化。
        for tick in range(10, 200, 10):
            tl.evaluate_record(record, facts=facts, state=state, tick=tick,
                               mono=float(tick))
        self.assertEqual(record["last_progress_tick"], first_progress_tick)
        # 停滞计时确实在涨 → 到限会走 no_progress/timeout 边（不会永远保活）。
        verdict, code, _, metrics = tl.evaluate_record(
            record, facts=facts, state=state, tick=5000, mono=50.0)
        self.assertIn(verdict, ("no_progress", "timeout"))
        self.assertGreater(metrics["stalled_ticks"], record["no_progress_limit_ticks"])

    def test_metric_change_refreshes_progress(self):
        state = make_state()
        record = build_task_record()
        facts = make_facts()
        tl.evaluate_record(record, facts=facts, state=state, tick=0, mono=0.0)
        facts["constructed"]["vehicle_factory"] = 1
        verdict, _, _, _ = tl.evaluate_record(
            record, facts=facts, state=state, tick=100, mono=1.0)
        self.assertEqual(verdict, "succeeded")  # 直接成功（阈值 1）
        self.assertEqual(record["last_progress_tick"], 100)

    def test_pause_does_not_consume_game_clock_budget(self):
        """暂停/接管：server_tick 不涨 → 游戏进展等待预算不消耗。"""
        state = make_state()
        record = build_task_record()
        facts = make_facts()
        tl.evaluate_record(record, facts=facts, state=state, tick=1000, mono=100.0)
        before = record["last_progress_tick"]
        # 墙钟过了 60 秒，但 tick 不变（暂停/玩家接管）。
        verdict, code, _, _ = tl.evaluate_record(
            record, facts=facts, state=state, tick=1000, mono=160.0)
        self.assertEqual(verdict, "waiting")
        self.assertEqual(record["last_progress_tick"], before)
        self.assertEqual(code, "in_progress")


class DiagnoseRecoverBlockedTest(unittest.TestCase):
    """诊断 → 恢复（预算内）→ 受阻（耗尽/条件丢失）。"""

    def test_recovery_within_budget_increments_attempt(self):
        state = make_state()
        record = build_task_record(state=tl.TASK_DIAGNOSING)
        outcome, code, cn = tl.diagnose(record, facts=make_facts(), state=state,
                                        tick=100, mono=1.0)
        self.assertEqual(outcome, tl.TASK_RECOVERING)
        self.assertEqual(record["attempt"], 1)
        # C2 返修：授权本身不消耗预算；retries_used 只由"已结论尝试"增加。
        self.assertEqual(record["retries_used"], 0)
        self.assertEqual(record["attempt_started_tick"], 100)

    def test_budget_exhaustion_blocks_with_recheck(self):
        state = make_state()
        record = build_task_record(state=tl.TASK_DIAGNOSING,
                                   retries_used=tl.DEFAULT_RETRY_BUDGET)
        outcome, code, cn = tl.diagnose(record, facts=make_facts(), state=state,
                                        tick=100, mono=1.0)
        self.assertEqual(outcome, tl.TASK_BLOCKED)
        self.assertEqual(code, "retry_budget_exhausted")
        self.assertTrue(record["blocked_missing"])
        self.assertTrue(record["recheck_conditions"])

    def test_lost_precondition_blocks_with_missing_items(self):
        state = make_state()
        record = build_task_record(state=tl.TASK_DIAGNOSING)
        facts = make_facts(builders=[], resource_count=0)  # 没有建造者/资源
        outcome, code, cn = tl.diagnose(record, facts=facts, state=state,
                                        tick=100, mono=1.0)
        self.assertEqual(outcome, tl.TASK_BLOCKED)
        self.assertEqual(code, "precondition_lost")
        self.assertIn("没有可建造的工人", record["blocked_missing"])

    def test_cooldown_holds_same_failure_fingerprint(self):
        state = make_state()
        record = build_task_record(state=tl.TASK_DIAGNOSING)
        tl.diagnose(record, facts=make_facts(), state=state, tick=100, mono=1.0)
        # 刚授权、还没有任何下发 → 等待本次尝试被调度（不计失败）。
        outcome, code, cn = tl.diagnose(record, facts=make_facts(), state=state,
                                        tick=100, mono=1.0)
        self.assertEqual(outcome, tl.TASK_RECOVERING)
        self.assertEqual(code, "awaiting_attempt_result")
        # 本次尝试的命令已下发且被**拒绝**（按身份结算）→ 尝试结论；
        # 冷却未到 → 冷却保持（RECOVERING 不翻 DIAGNOSING）。
        record["attempt_intents"] = ["i-attempt-1"]
        record["attempt_receipts"] = [{"key": "i-attempt-1|c1", "intent_id": "i-attempt-1",
                                       "command_id": "c1", "status": "Rejected",
                                       "accepted": False, "tick": 150}]
        outcome, code, cn = tl.diagnose(record, facts=make_facts(), state=state,
                                        tick=160, mono=1.6)
        self.assertEqual(record["retries_used"], 1)
        self.assertEqual(record["attempt_fail_kind"], "execution_failed")
        self.assertEqual(outcome, tl.TASK_RECOVERING)
        self.assertEqual(code, "cooldown_active")
        self.assertTrue(record["failure_fingerprint"].startswith("build|"))

    def test_normal_state_does_not_recover_every_round(self):
        """正常推进中的任务不会被每轮拉进恢复分支。"""
        state = make_state()
        record = build_task_record()
        facts = make_facts()
        outcomes = set()
        for tick in range(0, 100, 10):
            verdict, _, _, _ = tl.evaluate_record(
                record, facts=facts, state=state, tick=tick, mono=float(tick))
            outcomes.add(verdict)
        self.assertEqual(outcomes, {"waiting"})


class LedgerLifecycleTest(unittest.TestCase):
    """台账同步、目标反馈、结束态不重开。"""

    def test_sync_registers_tasks_with_kind_and_goal(self):
        state = make_state(active_tasks={"rule-build-vehicle_factory": "running"},
                           active_intents=[{
                               "intent_id": "rule-build-vehicle_factory-1",
                               "task_id": "rule-build-vehicle_factory",
                               "action": "build", "unit_ids": ["Unit_w"],
                               "target": {"scene": "res://x/vehicle_factory.tscn"},
                           }])
        ledger = tl.sync_ledger(state, 10)
        record = ledger["rule-build-vehicle_factory"]
        self.assertEqual(record["kind"], "build")
        # 目标映射按 intent_prefixes 权威表：车厂属于 M02（产能建筑）。
        self.assertEqual(record["goal_id"], "M02")
        self.assertEqual(record["units"], ["Unit_w"])
        self.assertEqual(record["state"], tl.TASK_PENDING)

    def test_evaluate_reports_goal_feedback_on_failure(self):
        state = make_state(
            active_tasks={"rule-build-ore_refinery": "failed"},
            active_intents=[{
                "intent_id": "rule-build-ore_refinery-1",
                "task_id": "rule-build-ore_refinery",
                "action": "build", "unit_ids": ["Unit_w"],
                "target": {"scene": "res://x/ore_refinery.tscn"},
            }],
            measured_tick_hz=30.0)
        report = tl.evaluate(state, tick=0, config={"loop_no_progress_seconds": 0.001},
                             facts=make_facts())
        feedback = report["feedback"]
        self.assertIn("M08", feedback)  # 上层目标（分矿）收到失败状态
        self.assertIn(feedback["M08"]["state"],
                      ("at_risk", "diagnosing", "recovering", "blocked"))
        changes = report["changes"]
        self.assertTrue(changes)

    def test_ended_tasks_are_not_reopened(self):
        state = make_state(
            active_tasks={"rule-build-vehicle_factory": "completed"},
            active_intents=[{
                "intent_id": "rule-build-vehicle_factory-1",
                "task_id": "rule-build-vehicle_factory",
                "action": "build", "unit_ids": ["Unit_w"], "target": {},
            }],
            measured_tick_hz=30.0)
        facts0 = make_facts()  # 建立轮：尚无完工建筑（基线 0）
        tl.evaluate(state, tick=0, config={}, facts=facts0)
        facts = make_facts(constructed={"vehicle_factory": 1})
        tl.evaluate(state, tick=60, config={}, facts=facts)
        record = state["task_ledger"]["rule-build-vehicle_factory"]
        self.assertEqual(record["state"], tl.TASK_SUCCEEDED)
        self.assertTrue(record["ended"])
        # 之后指标回落（建筑被毁）也不许把已结束任务改回活动态。
        facts2 = make_facts(constructed={})
        tl.evaluate(state, tick=1000, config={}, facts=facts2)
        self.assertTrue(state["task_ledger"]["rule-build-vehicle_factory"]["ended"])
        self.assertEqual(state["task_ledger"]["rule-build-vehicle_factory"]["state"],
                         tl.TASK_SUCCEEDED)

    def test_ledger_survives_dict_round_trip(self):
        """台账必须跨 checkpoint：to_dict/from_dict  round-trip 不丢。"""
        from adjutant_coordinator.graph.state import AdjutantGraphState
        state = AdjutantGraphState(match_id=MATCH, player_id=PLAYER)
        state.task_ledger = {"t-1": tl.new_record("t-1", kind="build", tick=5)}
        state.task_ledger["t-1"]["attempt"] = 2
        state.task_ledger_feedback = {"M01": {"state": "at_risk"}}
        restored = AdjutantGraphState.from_dict(state.to_dict())
        self.assertEqual(restored.task_ledger["t-1"]["attempt"], 2)
        self.assertEqual(restored.task_ledger_feedback["M01"]["state"], "at_risk")
        summary = state.summary()
        self.assertIn("task_loop", summary)
        self.assertIn("t-1", summary["task_loop"]["tasks"])


    def test_blocked_recheck_requires_condition_change(self):
        """受阻后不是每个冷却窗都重评：条件签名不变 → 保持受阻（600s 观察实测过空转）。"""
        state = make_state(server_tick=1000)
        record = build_task_record(state=tl.TASK_BLOCKED,
                                   retries_used=tl.DEFAULT_RETRY_BUDGET)
        record["order_key"] = "rule-build-vehicle_factory|build|res://x/vehicle_factory.tscn"
        facts = make_facts()
        tl.diagnose(record, facts=facts, state=state, tick=1000, mono=1.0)
        self.assertEqual(record["state"], tl.TASK_BLOCKED)
        self.assertTrue(record["blocked_signature"])
        signature = record["blocked_signature"]
        # 前置仍满足但什么都没变 → 不得重评（evaluate 的 blocked 分支）。
        state["active_tasks"] = {"rule-build-vehicle_factory": "blocked"}
        state["task_ledger"] = {"rule-build-vehicle_factory": record}
        for tick in (1100, 1200, 1300):
            tl.evaluate(state, tick=tick, facts=facts)
        self.assertEqual(record["state"], tl.TASK_BLOCKED)
        self.assertEqual(record["blocked_signature"], signature)
        # 条件真变化（多了一个可建造者）→ 允许重评；C3-b 返修：同轮必须完成
        # 预算决定——预算仍 3/3 耗尽，所以当轮回到 blocked（仲裁门禁当轮即生效）。
        facts2 = make_facts(builders=["Unit_w", "Unit_w2"])
        report = tl.evaluate(state, tick=1400, facts=facts2)
        self.assertEqual(record["state"], tl.TASK_BLOCKED)
        codes = [c.get("reason_code") for c in report["changes"]]
        self.assertIn("recheck_conditions_met", codes)
        self.assertIn("retry_budget_exhausted", codes)
        self.assertTrue(tl.blocked_order_keys(state, 1400),
                        "重评当轮必须重新持键（不能先放行再决定）")
        # 预算未耗尽的受阻任务：条件再次变化 → 重评后同轮给出恢复授权。
        record["retries_used"] = 1
        facts3 = make_facts(builders=["Unit_w", "Unit_w2", "Unit_w3"])
        tl.evaluate(state, tick=1500, facts=facts3)
        self.assertEqual(record["state"], tl.TASK_RECOVERING)


class BlockedPlanGateTest(unittest.TestCase):
    """R1 返修：受阻台账必须抑制失败方案重发（执行门禁，不是只记账）。"""

    def _state_with_blocked_task(self, task_id="rule-build-ore_refinery",
                                 action="build", scene="res://x/ore_refinery.tscn"):
        state = make_state(server_tick=1000)
        intent = {"intent_id": "rule-build-ore_refinery-Unit_0-1000", "task_id": task_id,
                  "action": action, "unit_ids": ["Unit_0"],
                  "target": {"scene": scene}}
        state["active_tasks"] = {task_id: "running"}
        state["active_intents"] = [dict(intent)]
        tl.sync_ledger(state, 1000)
        record = state["task_ledger"][task_id]
        record["state"] = tl.TASK_BLOCKED
        record["blocked_missing"] = ["重试预算已耗尽（3/3）"]
        record["blocked_signature"] = "x"
        return state, intent

    def test_blocked_order_key_suppresses_same_plan(self):
        state, intent = self._state_with_blocked_task()
        keys = tl.blocked_order_keys(state)
        self.assertIn(tl.order_key_of_intent(intent), keys)
        # 同任务同目标的候选被抑制。
        self.assertIn(tl.order_key_of_intent(dict(intent, intent_id="new-1")), keys)

    def test_different_target_not_suppressed(self):
        state, intent = self._state_with_blocked_task()
        keys = tl.blocked_order_keys(state)
        other = dict(intent, intent_id="other",
                     target={"scene": "res://x/vehicle_factory.tscn"})
        self.assertNotIn(tl.order_key_of_intent(other), keys,
                         "换目标的意图不属于同一失败方案，不得被抑制")

    def test_non_blocked_task_not_suppressed(self):
        state, intent = self._state_with_blocked_task()
        state["task_ledger"]["rule-build-ore_refinery"]["state"] = tl.TASK_RUNNING
        self.assertEqual(tl.blocked_order_keys(state), {})

    def test_arbitrate_drops_blocked_plan_candidate(self):
        """端到端：node_arbitrate_intent 丢弃命中受阻键的候选（reason 可见）。"""
        from adjutant_coordinator.graph.nodes import GraphServices, node_arbitrate_intent
        state, intent = self._state_with_blocked_task()
        state["candidate_intents"] = [dict(intent, intent_id="cand-1")]
        services = GraphServices()
        ctx = type("Ctx", (), {"services": services, "observation": {}, "tick": 1000,
                               "config": None})()
        out = node_arbitrate_intent(state, ctx)
        dropped = out.get("intent_arbitration", {}).get("dropped", [])
        self.assertTrue(any(str(item.get("reason", "")).startswith("task_loop_blocked_plan")
                            for item in dropped),
                        "受阻方案必须在仲裁层被丢弃：%s" % dropped)


class LoopConfigChannelTest(unittest.TestCase):
    """闭环/经济配置必须跨节点流转（round-04 最终审计抓到的通道漏声明 bug）。

    `loop_config` 只写在 `node_ingest`、由 `campaign.update` 读。漏声明图通道时
    LangGraph 在节点间静默过滤它（Fallback 不受影响）——表现为 langgraph 引擎下
    `--econ-*`/`--loop-*` 只有默认值生效。这里对两条引擎都断言它活着走到图状态里。
    """

    def _config_reaches_graph_state(self, engine):
        with tempfile.TemporaryDirectory() as tmp:
            fixture = RuntimeFixture(
                strategy_script=[{"behavior": "completed", "plan": make_plan()}],
                config=base_config(engine=engine, trace_enabled=False,
                                   loop_no_progress_seconds=7.0,
                                   econ_grace_seconds=33.0))
            out = fixture.runtime.runner.run_tick(
                fixture.runtime.state.to_dict(),
                observation=observation(0), tick=0)
            return out

    def test_loop_config_flows_in_both_engines(self):
        for engine in ("fallback", "langgraph"):
            with self.subTest(engine=engine):
                try:
                    out = self._config_reaches_graph_state(engine)
                except RuntimeError as exc:
                    self.skipTest("langgraph 不可用：%s" % exc)
                config = out.get("loop_config") if isinstance(out, dict) else None
                self.assertIsInstance(config, dict,
                                      "%s 引擎下图状态里没有 loop_config（通道漏声明）" % engine)
                self.assertEqual(config.get("loop_no_progress_seconds"), 7.0)
                self.assertEqual(config.get("econ_grace_seconds"), 33.0)


class TimeoutAndAttemptLifecycleTest(unittest.TestCase):
    """R3/R4 返修跨轮集成（独立复核要求：不能只测 evaluate_record 的返回值）。"""

    def test_timeout_goes_through_diagnose_to_recovery_then_blocked(self):
        """R3：总期限到达 → diagnosing → 预算内恢复 → 耗尽受阻（跨轮）。"""
        state = make_state(server_tick=0, active_tasks={"rule-build-vehicle_factory": "running"})
        record = build_task_record(deadline_tick=100, state=tl.TASK_RUNNING)
        state["task_ledger"] = {"rule-build-vehicle_factory": record}
        facts = make_facts()  # 指标永远不变（0 座完工）
        # 期限前：正常等待，不结束。
        tl.evaluate(state, tick=50, facts=facts)
        self.assertFalse(record["ended"])
        # 期限到达：进诊断（不是终态），同轮诊断给出恢复。
        report = tl.evaluate(state, tick=100, facts=facts)
        codes = [c.get("reason_code") for c in report["changes"]]
        self.assertIn("total_deadline", codes)
        self.assertIn("recovery_attempt", codes)
        self.assertEqual(record["state"], tl.TASK_RECOVERING)
        self.assertEqual(record["attempt"], 1)
        self.assertFalse(record["ended"])
        # 冷却内保持诊断，冷却后第二次恢复……直到预算耗尽转受阻。
        seen_blocked = False
        for tick in range(200, 4000, 100):
            tl.evaluate(state, tick=tick, facts=facts)
            if record["state"] == tl.TASK_BLOCKED:
                seen_blocked = True
                break
        self.assertTrue(seen_blocked, "恢复预算耗尽后必须进入受阻")
        self.assertTrue(record["blocked_missing"])

    def test_recovery_does_not_refresh_last_progress(self):
        """R4：恢复是状态切换，不是实际进展——last_progress 不许被刷新。"""
        state = make_state(server_tick=1000)
        record = build_task_record(state=tl.TASK_DIAGNOSING)
        record["last_progress_tick"] = 100
        record["last_progress_mono"] = 1.0
        facts = make_facts()  # 指标毫无变化
        outcome, code, cn = tl.diagnose(record, facts=facts, state=state,
                                        tick=1000, mono=50.0)
        self.assertEqual(outcome, tl.TASK_RECOVERING)
        self.assertEqual(record["last_progress_tick"], 100,
                         "状态切换不得刷新实际进展时间")
        self.assertEqual(record["attempt_started_tick"], 1000)
        self.assertEqual(record["attempt_started_mono"], 50.0)
        self.assertEqual(record["attempt"], 1)

    def test_stall_keeps_counting_across_recovery(self):
        """R4：恢复后若无实际进展，停滞计时继续累计（不因状态重启而截短）。"""
        state = make_state(server_tick=0, active_tasks={"rule-build-vehicle_factory": "running"})
        record = build_task_record(deadline_tick=10 ** 9, state=tl.TASK_RUNNING)
        state["task_ledger"] = {"rule-build-vehicle_factory": record}
        facts = make_facts()
        tl.evaluate(state, tick=0, facts=facts)
        # 无进展期限 = 45s × 30Hz(夹具) = 1350 tick：跨过它才沿 no_progress 边进诊断。
        tl.evaluate(state, tick=2000, facts=facts)
        self.assertEqual(record["state"], tl.TASK_RECOVERING)
        self.assertEqual(record["last_progress_tick"], 0)
        verdict, code, _, metrics = tl.evaluate_record(
            record, facts=facts, state=state, tick=5000, mono=50.0)
        # 诊断/恢复流程中不每轮重报 no_progress（churn 返修），只报保持；
        # 但停滞计时仍从最后一次**实际**进展算起（不是从恢复授权算起）。
        self.assertEqual(verdict, "waiting")
        self.assertEqual(code, "diagnose_hold")
        self.assertEqual(metrics["stalled_ticks"], 5000)


class SecondReviewReworkTest(unittest.TestCase):
    """第二轮独立复核 C1-C5 反例的回归测试。"""

    # ---- C1：计划先于动作 ----
    def test_plan_first_task_gets_type_and_deadline_exit(self):
        """C1：先建计划后产生动作时，台账必须补全类型/单位/目标；
        缺证据也不是终态——总期限到了照样沿 timeout 边进诊断。"""
        state = make_state(server_tick=100, active_tasks={"t-1": "pending"})
        tl.sync_ledger(state, 100)
        record = state["task_ledger"]["t-1"]
        self.assertEqual(record["kind"], "")
        # 动作到来后补全（旧实现只补 order_key，kind/metric/units 永远为空）。
        state["active_intents"] = [{
            "intent_id": "i-1", "task_id": "t-1", "action": "move",
            "unit_ids": ["Unit_1"], "target": {"pos": [10.0, 10.0]},
            "issued_tick": 5, "expires_tick": 100000}]
        tl.sync_ledger(state, 200)
        record = state["task_ledger"]["t-1"]
        self.assertEqual(record["kind"], "move")
        self.assertEqual(record["progress_metric"], "arrival_tick")
        self.assertEqual(record["units"], ["Unit_1"])
        self.assertTrue(record["order_key"])
        # 超期 + 仍无证据 → timeout 边（不是 evidence_missing 常驻）。
        record["deadline_tick"] = 3700
        verdict, code, _, _ = tl.evaluate_record(
            record, facts={}, state=state, tick=1000000, mono=1.0)
        self.assertEqual(verdict, "timeout")
        self.assertEqual(code, "total_deadline")

    def test_evidence_missing_has_bounded_wait_then_diagnose(self):
        """C1：证据不足的任务有无进展期限出口（到期沿 no_progress 边）。"""
        state = make_state(server_tick=0, active_tasks={"t-1": "running"})
        record = tl.new_record("t-1", tick=0)
        state["task_ledger"] = {"t-1": record}
        verdict, code, cn, _ = tl.evaluate_record(
            record, facts={}, state=state, tick=10, mono=1.0)
        self.assertEqual(verdict, "unknown")
        self.assertEqual(code, "evidence_missing")
        # 无进展期限（45s×30Hz=1350 tick）过后 → no_progress 边。
        verdict, code, _, _ = tl.evaluate_record(
            record, facts={}, state=state, tick=2000, mono=20.0)
        self.assertEqual(verdict, "no_progress")
        self.assertEqual(code, "no_progress_limit")

    # ---- C2：预算按尝试结论消耗 ----
    def test_authorization_does_not_consume_budget_without_execution(self):
        """C2：零下发/零回执时，授权不消耗预算；每次尝试要等自己的窗口。"""
        state = make_state(server_tick=100, active_tasks={"t": "running"},
                           command_receipts=[], measured_tick_hz=1.0)
        record = tl.new_record("t", kind="build", tick=100)
        record["building_type"] = "ore_refinery"
        record["state"] = tl.TASK_DIAGNOSING
        record["deadline_tick"] = 10 ** 9      # 期限另测；这里只看尝试生命周期
        # 1Hz：尝试窗口=30 tick、冷却=15 tick，序列可预测
        state["task_ledger"] = {"t": record}
        facts = make_facts()
        seen = []
        for tick in (100, 110, 129, 130, 131, 159, 160, 161, 189, 190, 191):
            tl.evaluate(state, tick=tick, facts=facts)
            seen.append((tick, record["state"], record["attempt"], record["retries_used"]))
        # 授权当轮：attempt=1 但预算不消耗。
        self.assertEqual((seen[0][2], seen[0][3]), (1, 0))
        # 窗口内（30s×1Hz=30 tick）：保持等待，不计失败。
        self.assertEqual(seen[1][3], 0, "授权后窗口内不得计失败")
        self.assertEqual(seen[2][3], 0)
        # D1/语义边界返修：零下发走**调度等待预算**，不计执行失败。
        # 第 3 次也要等自己的窗口才 blocked；retries_used 始终为 0。
        self.assertEqual(seen[-1][1], "blocked")
        self.assertEqual(seen[-1][3], 0, "零执行不得记为执行失败")
        self.assertEqual(record["schedule_waits"], tl.DEFAULT_RETRY_BUDGET)
        self.assertEqual(record["attempt_fail_kind"], "no_dispatch")
        self.assertGreaterEqual(seen[-1][0], 190, "最后一次尝试必须等到自己的窗口")
        # 三次授权全部发生，且每次都等到了自己的窗口（130/160/190 = 100+30k）。
        self.assertEqual([row[2] for row in seen if row[2]], [1, 1, 1, 2, 2, 2, 3, 3, 3, 3, 3])

    def test_result_concludes_attempt_immediately(self):
        """D1：拒绝回执立即结论并计预算；Accepted 是在途，不消耗预算。"""

        def _attempt_with_receipt(accepted):
            state = make_state(server_tick=100, active_tasks={"t": "running"})
            record = tl.new_record("t", kind="build", tick=100)
            record["building_type"] = "ore_refinery"
            record["state"] = tl.TASK_RECOVERING
            record["attempt"] = 1
            record["attempt_started_tick"] = 100
            record["attempt_counted_tick"] = -1
            record["attempt_intents"] = ["i-1"]
            record["attempt_receipts"] = [{
                "key": "i-1|c1", "intent_id": "i-1", "command_id": "c1",
                "status": "Accepted" if accepted else "Rejected",
                "accepted": accepted, "tick": 150}]
            state["task_ledger"] = {"t": record}
            return state, record

        # 拒绝回执 → 尝试结论，计入执行预算并授权下一次。
        state, record = _attempt_with_receipt(False)
        outcome, code, cn = tl.diagnose(record, facts=make_facts(), state=state,
                                        tick=160, mono=1.6)
        self.assertEqual(record["retries_used"], 1)
        self.assertEqual(record["attempt_fail_kind"], "execution_failed")
        self.assertEqual(record["attempt"], 2)
        self.assertEqual(code, "recovery_attempt")
        self.assertIn("已结论 1/3", cn)

        # D1：**接受**回执 → 正常在途，不消耗预算（生产/建造需要时间）。
        state, record = _attempt_with_receipt(True)
        outcome, code, cn = tl.diagnose(record, facts=make_facts(), state=state,
                                        tick=160, mono=1.6)
        self.assertEqual(outcome, tl.TASK_RECOVERING)
        self.assertEqual(code, "attempt_in_flight")
        self.assertEqual(record["retries_used"], 0)
        self.assertEqual(record["attempt_counted_tick"], -1)

    def test_attempt_results_sync_from_receipts(self):
        """C2：evaluate 从 command_receipts 关联 attempt_result_tick。"""
        state = make_state(server_tick=200, active_tasks={"t": "running"})
        state["active_intents"] = [{
            "intent_id": "i-1", "task_id": "t", "action": "build",
            "unit_ids": ["Unit_w"], "target": {"scene": "res://x/ore_refinery.tscn"},
            "issued_tick": 100, "expires_tick": 100000}]
        state["command_receipts"] = [
            {"intent_id": "i-1", "status": "Rejected", "server_tick": 150}]
        tl.sync_ledger(state, 100)
        record = state["task_ledger"]["t"]
        # 授权早于意图 issued_tick → 该意图属于本次尝试，回执按身份结算。
        record["attempt_started_tick"] = 90
        record["attempt_counted_tick"] = -1
        tl.evaluate(state, tick=200, facts=make_facts())
        self.assertEqual(record["attempt_result_tick"], 150)
        self.assertEqual([i["intent_id"] for i in record["attempt_receipts"]], ["i-1"])
        # 旧命令（授权前 issued）不归属本次尝试：不结算、不结论（D2 返修）。
        state["command_receipts"] = [
            {"intent_id": "i-old", "command_id": "c0", "status": "Rejected",
             "accepted": False, "server_tick": 95}]
        state["active_intents"].append({
            "intent_id": "i-old", "task_id": "t", "action": "build",
            "unit_ids": ["Unit_w"], "target": {"scene": "res://x/ore_refinery.tscn"},
            "issued_tick": 50, "expires_tick": 100000})
        record["attempt_started_tick"] = 90
        record["attempt_counted_tick"] = -1
        record["attempt_receipts"] = []
        tl.evaluate(state, tick=200, facts=make_facts())
        self.assertEqual(record["attempt_receipts"], [],
                         "授权前的旧命令回执不得结算新尝试")

    # ---- C3：冷却门禁与同轮决定 ----
    def test_cooldown_blocks_new_retry_but_allows_first_execution(self):
        """C3-a：冷却中拦新重试；本次尝试还没回执时放行首次执行。"""
        state = make_state(server_tick=100, active_tasks={"t": "running"})
        state["active_intents"] = [{
            "intent_id": "i-1", "task_id": "t", "action": "produce",
            "unit_ids": ["Unit_f"], "target": {"producer": "Unit_f", "product": "tank"},
            "issued_tick": 100, "expires_tick": 100000}]
        tl.sync_ledger(state, 100)
        record = state["task_ledger"]["t"]
        record["state"] = tl.TASK_RECOVERING
        record["cooldown_until_tick"] = 10000
        record["attempt_started_tick"] = 90
        record["attempt_result_tick"] = 95     # 尝试已结论 → 冷却内拦
        keys = tl.blocked_order_keys(state, 100)
        self.assertIn(record["order_key"], keys)
        # 无回执 → 放行本次尝试的首次执行。
        record["attempt_result_tick"] = 0
        self.assertEqual(tl.blocked_order_keys(state, 100), {})

    def test_recheck_completes_budget_decision_same_round(self):
        """C3-b：受阻重评放行后，同轮必须完成预算决定再让仲裁看到状态。"""
        state = make_state(server_tick=100, active_tasks={"t": "running"})
        state["active_intents"] = [{
            "intent_id": "i-1", "task_id": "t", "action": "produce",
            "unit_ids": ["Unit_f"], "target": {"producer": "Unit_f", "product": "tank"},
            "issued_tick": 100, "expires_tick": 100000}]
        tl.sync_ledger(state, 100)
        record = state["task_ledger"]["t"]
        record["state"] = tl.TASK_BLOCKED
        record["retries_used"] = 3
        record["retry_budget"] = 3
        record["blocked_missing"] = ["重试预算已耗尽（3/3）"]
        record["blocked_signature"] = "old"
        facts = make_facts(producers=["Unit_f"])
        report = tl.evaluate(state, tick=200, facts=facts)
        # 预算仍耗尽 → 当轮回到 blocked，且仲裁键当轮有效。
        self.assertEqual(record["state"], tl.TASK_BLOCKED)
        codes = [c.get("reason_code") for c in report["changes"]]
        self.assertIn("recheck_conditions_met", codes)
        self.assertIn("retry_budget_exhausted", codes)
        self.assertTrue(tl.blocked_order_keys(state, 200))

    # ---- C4：结果归因 ----
    def test_concurrent_produce_orders_do_not_share_result(self):
        """C4：只新增一辆坦克，只有对应订单判成功（台账归因）。"""
        state = make_state(server_tick=100, active_tasks={}, production_ledger={})
        for task in ("order-A", "order-B"):
            state["active_tasks"][task] = "running"
            state["active_intents"].append({
                "intent_id": task + "-i1", "task_id": task, "action": "produce",
                "unit_ids": ["Unit_f"],
                "target": {"producer": "Unit_f", "product": "tank"},
                "issued_tick": 100, "expires_tick": 100000})
        tl.sync_ledger(state, 100)
        facts = make_facts(producers=["Unit_f"], counts={"tank": 0})
        tl.evaluate(state, tick=100, facts=facts)
        # 台账里只有 A 的订单完成了一件。
        state["production_ledger"] = {"item-1": {
            "producer": "Unit_f", "product_id": "tank",
            "intent_id": "order-A-i1", "finished_tick": 150}}
        tl.evaluate(state, tick=200, facts=facts)
        self.assertEqual(state["task_ledger"]["order-A"]["state"], tl.TASK_SUCCEEDED)
        self.assertEqual(state["task_ledger"]["order-B"]["state"], tl.TASK_WAITING)
        self.assertEqual(state["task_ledger"]["order-A"]["success_basis"], "order")

    def test_build_attribution_prefers_named_site(self):
        """C4：指定了工地的建造任务只认那个工地完工（类型共享要标明）。"""
        state = make_state(server_tick=100,
                           active_tasks={"rule-build-ore_refinery": "running"})
        state["active_intents"] = [{
            "intent_id": "i-1", "task_id": "rule-build-ore_refinery", "action": "build",
            "unit_ids": ["Unit_w"],
            "target": {"entity_id": "Unit_ref", "scene": "res://x/ore_refinery.tscn"},
            "issued_tick": 100, "expires_tick": 100000}]
        tl.sync_ledger(state, 100)
        record = state["task_ledger"]["rule-build-ore_refinery"]
        # 目标工地在观测里但未完工；另一座同类建筑已完工（全局计数=1）。
        facts = make_facts(constructed={"ore_refinery": 1},
                           own_constructed={"Unit_ref": False, "Unit_other": True})
        verdict, _, cn, _ = tl.evaluate_record(
            record, facts=facts, state=state, tick=200, mono=2.0)
        self.assertEqual(verdict, "waiting", "别人的工地完工不算本任务成功")
        self.assertEqual(record["success_basis"], "order")
        # 基线按"本工地是否完工"采集（0），工地完工才成功。
        facts["own_constructed"]["Unit_ref"] = True
        verdict, _, _, _ = tl.evaluate_record(
            record, facts=facts, state=state, tick=300, mono=3.0)
        self.assertEqual(verdict, "succeeded")

    # ---- C5：去重保留 attempt 变化 ----
    def test_attempt_increment_is_not_deduped(self):
        """C5：相同状态+原因码但 attempt 增加，必须记事件（时间线不能漏）。"""
        state = make_state(server_tick=100, active_tasks={"t": "running"},
                           command_receipts=[])
        record = tl.new_record("t", kind="build", tick=100)
        record["building_type"] = "ore_refinery"
        record["state"] = tl.TASK_RECOVERING
        record["attempt"] = 2
        record["attempt_started_tick"] = 100
        record["attempt_counted_tick"] = 100
        record["attempt_result_tick"] = 150
        record["attempt_window_ticks"] = 30
        record["cooldown_until_tick"] = 115
        record["_last_diag_code"] = "recovery_attempt"
        record["deadline_tick"] = 10 ** 9
        state["task_ledger"] = {"t": record}
        report = tl.evaluate(state, tick=200, facts=make_facts())
        self.assertEqual(record["attempt"], 3)
        codes = [(c.get("reason_code"), c.get("attempt")) for c in report["changes"]]
        self.assertIn(("recovery_attempt", 3), codes,
                      "attempt 2→3 是真实事件，不得被去重吞掉")


class ThirdReviewReworkTest(unittest.TestCase):
    """第三轮独立复核 D1-D4 反例的回归测试。"""

    RULES = {
        "unit_types": [
            {"id": "tank", "scene_path": "res://source/match/units/Tank.tscn"},
            {"id": "worker", "scene_path": "res://source/match/units/Worker.tscn"},
        ],
        "constructions": [
            {"id": "ore_refinery",
             "blueprint_scene_path": "res://source/match/units/OreRefinery.tscn"},
        ],
        "productions": [{"product_type_id": "tank",
                         "allowed_producer_type_ids": ["vehicle_factory"]}],
    }

    # ---- D1：Accepted 不消耗预算；受阻任务仍能凭自身证据成功 ----
    def test_accepted_receipt_does_not_exhaust_budget(self):
        """D1：命令被接受只是开始执行；慢速产出期间不得耗尽预算。"""
        state = make_state(server_tick=100, active_tasks={"t": "running"},
                           command_receipts=[])
        record = tl.new_record("t", kind="produce", tick=100)
        record["product_type"] = "tank"
        record["retry_budget"] = 1                    # 单次预算放大问题
        record["state"] = tl.TASK_DIAGNOSING
        state["task_ledger"] = {"t": record}
        # tick 100 授权 attempt=1；tick 101 命令被接受（尚无产出）。
        tl.evaluate(state, tick=100, facts=make_facts(producers=["Unit_f"]))
        self.assertEqual(record["attempt"], 1)
        self.assertEqual(record["retries_used"], 0)
        state["command_receipts"] = [{
            "intent_id": "i-1", "command_id": "c1", "status": "Accepted",
            "accepted": True, "server_tick": 101}]
        state["active_intents"] = [{
            "intent_id": "i-1", "task_id": "t", "action": "produce",
            "unit_ids": ["Unit_f"], "target": {"producer": "Unit_f", "product": "tank"},
            "issued_tick": 100, "expires_tick": 100000}]
        report = tl.evaluate(state, tick=101, facts=make_facts(producers=["Unit_f"]))
        self.assertNotEqual(record["state"], tl.TASK_BLOCKED,
                            "Accepted 是在途，不得据此耗尽预算转受阻")
        self.assertEqual(record["retries_used"], 0)
        # tick 200 订单实际完成（台账归因）→ 任务成功。
        state["production_ledger"] = {"item-1": {
            "producer": "Unit_f", "product_id": "tank",
            "intent_id": "i-1", "finished_tick": 200}}
        tl.evaluate(state, tick=201, facts=make_facts(producers=["Unit_f"]))
        self.assertEqual(record["state"], tl.TASK_SUCCEEDED)

    def test_blocked_task_can_still_succeed_with_own_evidence(self):
        """D1：订单在受阻期间完成时，任务必须能凭自身归因证据关闭。"""
        state = make_state(server_tick=100, active_tasks={"t": "running"},
                           production_ledger={"item-1": {
                               "producer": "Unit_f", "product_id": "tank",
                               "intent_id": "i-1", "finished_tick": 200}})
        state["active_intents"] = [{
            "intent_id": "i-1", "task_id": "t", "action": "produce",
            "unit_ids": ["Unit_f"], "target": {"producer": "Unit_f", "product": "tank"},
            "issued_tick": 100, "expires_tick": 100000}]
        tl.sync_ledger(state, 100)
        record = state["task_ledger"]["t"]
        record["state"] = tl.TASK_BLOCKED
        record["retries_used"] = 3
        record["retry_budget"] = 3
        record["blocked_missing"] = ["恢复执行预算已耗尽（3/3）"]
        record["blocked_signature"] = "sig"
        report = tl.evaluate(state, tick=201, facts=make_facts(producers=["Unit_f"]))
        self.assertEqual(record["state"], tl.TASK_SUCCEEDED,
                         "受阻期间订单完成：必须能关闭，不能永远 blocked")
        codes = [c.get("reason_code") for c in report["changes"]]
        self.assertIn("success_evidence", codes)

    # ---- D2：旧回执不结算新尝试 ----
    def test_old_same_tick_receipt_does_not_settle_new_attempt(self):
        """D2：旧命令拒绝回执与恢复授权同 tick，也不得消耗新尝试预算。"""
        state = make_state(server_tick=100, active_tasks={"t": "running"},
                           command_receipts=[{
                               "intent_id": "i-old", "command_id": "c0",
                               "status": "Rejected", "accepted": False,
                               "server_tick": 100}])
        state["active_intents"] = [{
            "intent_id": "i-old", "task_id": "t", "action": "build",
            "unit_ids": ["Unit_w"],
            "target": {"scene": "res://source/match/units/OreRefinery.tscn"},
            "issued_tick": 50, "expires_tick": 100000}]
        tl.sync_ledger(state, 100, rules=self.RULES)
        record = state["task_ledger"]["t"]
        record["state"] = tl.TASK_DIAGNOSING
        record["deadline_tick"] = 100
        # 第一次 evaluate（tick=100）：授权 attempt=1（旧回执同 tick 但不归属）。
        tl.evaluate(state, tick=100, facts=make_facts())
        self.assertEqual(record["attempt"], 1)
        self.assertEqual(record["retries_used"], 0)
        self.assertEqual(record["attempt_receipts"], [])
        # 同 tick 第二次 evaluate：没有新命令，预算仍不被消耗。
        tl.evaluate(state, tick=100, facts=make_facts())
        self.assertEqual(record["retries_used"], 0)
        self.assertNotEqual(record["state"], tl.TASK_BLOCKED)

    # ---- D3：指定工地丢失不认领别处完工 ----
    def test_missing_named_site_does_not_claim_other_completion(self):
        """D3：SiteA 消失后，别处 SiteB 完工不得算作 A 成功。"""
        state = make_state(server_tick=100, active_tasks={"t": "running"})
        state["active_intents"] = [{
            "intent_id": "i-1", "task_id": "t", "action": "build",
            "unit_ids": ["Unit_w"],
            "target": {"entity_id": "SiteA",
                       "scene": "res://source/match/units/OreRefinery.tscn"},
            "issued_tick": 100, "expires_tick": 100000}]
        tl.sync_ledger(state, 100, rules=self.RULES)
        record = state["task_ledger"]["t"]
        self.assertEqual(record["site_entity"], "SiteA")
        # tick 100：SiteA 在但未完工 → 基线 0，等待。
        facts = make_facts(constructed={"ore_refinery": 0},
                           own_constructed={"SiteA": False})
        verdict, _, _, _ = tl.evaluate_record(
            record, facts=facts, state=state, tick=100, mono=1.0)
        self.assertEqual(verdict, "waiting")
        # tick 200：SiteA 消失，别处 SiteB 同类型完工 → unknown，不算成功。
        facts2 = make_facts(constructed={"ore_refinery": 1},
                            own_constructed={"SiteB": True})
        verdict, code, cn, _ = tl.evaluate_record(
            record, facts=facts2, state=state, tick=200, mono=2.0)
        self.assertEqual(verdict, "unknown")
        self.assertIn("不在观测中", cn)
        self.assertEqual(record["attribution"], "site")
        # tick 300：SiteA 真的完工 → 成功（判据未切换过）。
        facts3 = make_facts(constructed={"ore_refinery": 1},
                            own_constructed={"SiteA": True})
        verdict, _, _, _ = tl.evaluate_record(
            record, facts=facts3, state=state, tick=300, mono=3.0)
        self.assertEqual(verdict, "succeeded")

    def test_named_site_first_observed_late_still_succeeds(self):
        """D3 反方向：SiteA 起初不可观测，出现并完工后必须能成功
        （基线与当前指标同语义，不拿类型计数当基线）。"""
        state = make_state(server_tick=100, active_tasks={"t": "running"})
        state["active_intents"] = [{
            "intent_id": "i-1", "task_id": "t", "action": "build",
            "unit_ids": ["Unit_w"],
            "target": {"entity_id": "SiteA",
                       "scene": "res://source/match/units/OreRefinery.tscn"},
            "issued_tick": 100, "expires_tick": 100000}]
        tl.sync_ledger(state, 100, rules=self.RULES)
        record = state["task_ledger"]["t"]
        # 起初不可观测（全局类型计数=2）→ unknown，不采类型基线。
        facts = make_facts(constructed={"ore_refinery": 2}, own_constructed={})
        verdict, code, _, _ = tl.evaluate_record(
            record, facts=facts, state=state, tick=100, mono=1.0)
        self.assertEqual(verdict, "unknown")
        self.assertFalse(record.get("baseline_captured"),
                         "未可判定不得采集基线")
        # SiteA 出现且完工 → 成功。
        facts2 = make_facts(constructed={"ore_refinery": 2},
                            own_constructed={"SiteA": True})
        verdict, _, _, _ = tl.evaluate_record(
            record, facts=facts2, state=state, tick=200, mono=2.0)
        self.assertEqual(verdict, "succeeded")

    # ---- D4：合法 scene+producer 合同解析产品类型 ----
    def test_valid_produce_contract_resolves_product_type(self):
        """D4：target.scene + target.producer 的合法合同必须解析出产品类型
        （经规则视图反查；模型任务 ID 无 rule-produce 前缀也要成立）。"""
        state = make_state(server_tick=100, active_tasks={"model-prod": "running"})
        state["active_intents"] = [{
            "intent_id": "m-1", "task_id": "model-prod", "action": "produce",
            "unit_ids": ["Unit_f"],
            "target": {"scene": "res://source/match/units/Tank.tscn",
                       "producer": "Unit_f"},
            "issued_tick": 100, "expires_tick": 100000}]
        # 计划先于动作：先建空记录，再补全（与首次登记同一口径）。
        state2 = make_state(server_tick=100, active_tasks={"model-prod": "pending"})
        tl.sync_ledger(state2, 100, rules=self.RULES)
        tl.sync_ledger(state, 100, rules=self.RULES)
        record = state["task_ledger"]["model-prod"]
        self.assertEqual(record["kind"], "produce")
        self.assertEqual(record["product_type"], "tank",
                         "scene+producer 合法合同必须经规则视图解析出 tank")
        # 可判定：台账有本订单完成 → 成功。
        state["production_ledger"] = {"item-1": {
            "producer": "Unit_f", "product_id": "tank",
            "intent_id": "m-1", "finished_tick": 150}}
        verdict, code, cn, _ = tl.evaluate_record(
            record, facts=make_facts(producers=["Unit_f"]), state=state,
            tick=200, mono=2.0)
        self.assertEqual(verdict, "succeeded")

    def test_build_scene_resolves_building_type(self):
        """D4：建造合同的 scene 同样经规则视图解析（ Infantry 类不同名陷阱）。"""
        state = make_state(server_tick=100, active_tasks={"model-build": "running"})
        state["active_intents"] = [{
            "intent_id": "b-1", "task_id": "model-build", "action": "build",
            "unit_ids": ["Unit_w"],
            "target": {"scene": "res://source/match/units/OreRefinery.tscn"},
            "issued_tick": 100, "expires_tick": 100000}]
        tl.sync_ledger(state, 100, rules=self.RULES)
        record = state["task_ledger"]["model-build"]
        self.assertEqual(record["building_type"], "ore_refinery")

    # ---- P2 边界：建立后首采前的完成计入成功 ----
    def test_completion_between_creation_and_first_sample_counts(self):
        """P2 边界：created=100、订单 finished=110、首次评估 tick=120，
        该完成必须计入成功（不被误采为基线）。"""
        state = make_state(server_tick=120, active_tasks={"t": "running"})
        state["active_intents"] = [{
            "intent_id": "i-1", "task_id": "t", "action": "produce",
            "unit_ids": ["Unit_f"], "target": {"producer": "Unit_f", "product": "tank"},
            "issued_tick": 100, "expires_tick": 100000}]
        state["production_ledger"] = {"item-1": {
            "producer": "Unit_f", "product_id": "tank",
            "intent_id": "i-1", "finished_tick": 110}}
        tl.sync_ledger(state, 100)
        record = state["task_ledger"]["t"]
        verdict, code, cn, _ = tl.evaluate_record(
            record, facts=make_facts(producers=["Unit_f"]), state=state,
            tick=120, mono=1.2)
        self.assertEqual(verdict, "succeeded")
        # 建立前就已完成的订单不算本任务成果。
        state["production_ledger"]["item-1"]["finished_tick"] = 50
        record2 = tl.new_record("t2", kind="produce", tick=100)
        record2["product_type"] = "tank"
        record2["intent_ids"] = ["i-1"]
        record2["target_key"] = "Unit_f"
        verdict, _, _, _ = tl.evaluate_record(
            record2, facts=make_facts(producers=["Unit_f"]), state=state,
            tick=120, mono=1.2)
        self.assertEqual(verdict, "waiting")


class FourthReviewReceiptStateTest(unittest.TestCase):
    """第四轮回执复核：非终态等待，同一命令身份允许状态推进。"""

    @staticmethod
    def _attempt_state(receipt):
        state = make_state(
            server_tick=100,
            active_tasks={"t": "running"},
            command_receipts=[dict(receipt)],
            active_intents=[{
                "intent_id": "i-1", "task_id": "t", "action": "build",
                "unit_ids": ["Unit_w"],
                "target": {"entity_id": "SiteA",
                           "scene": "res://source/match/units/OreRefinery.tscn"},
                "issued_tick": 100, "expires_tick": 100000,
            }],
        )
        record = tl.new_record("t", kind="build", tick=100)
        record.update({
            "building_type": "ore_refinery", "site_entity": "SiteA",
            "attribution": "site", "state": tl.TASK_RECOVERING,
            "attempt": 1, "attempt_started_tick": 100,
            "attempt_counted_tick": -1, "attempt_window_ticks": 30,
        })
        state["task_ledger"] = {"t": record}
        return state, record

    def test_pending_authority_and_unknown_do_not_consume_failure_budget(self):
        for status in ("PendingAuthority", "Unknown", ""):
            with self.subTest(status=status):
                state, record = self._attempt_state({
                    "intent_id": "i-1", "command_id": "c-1",
                    "status": status, "accepted": False, "server_tick": 100,
                })
                tl._sync_attempt_results(state, state["task_ledger"])
                outcome, code, _ = tl.diagnose(
                    record, facts=make_facts(), state=state, tick=101, mono=1.01)
                self.assertEqual(outcome, tl.TASK_RECOVERING)
                self.assertEqual(code, "awaiting_authority")
                self.assertEqual(record["retries_used"], 0)
                self.assertEqual(record["attempt_fail_kind"], "")

                # 超过本地尝试窗口仍未获权威终态，仍是未知等待，不计执行失败。
                outcome, code, _ = tl.diagnose(
                    record, facts=make_facts(), state=state, tick=140, mono=1.40)
                self.assertEqual(outcome, tl.TASK_RECOVERING)
                self.assertEqual(code, "awaiting_authority")
                self.assertEqual(record["retries_used"], 0)

    def test_same_command_pending_advances_to_terminal_and_late_pending_cannot_revert(self):
        state, record = self._attempt_state({
            "intent_id": "i-1", "command_id": "c-1",
            "status": "PendingAuthority", "accepted": False, "server_tick": 100,
        })
        tl._sync_attempt_results(state, state["task_ledger"])
        state["command_receipts"].append({
            "intent_id": "i-1", "command_id": "c-1",
            "status": "Accepted", "accepted": True, "server_tick": 101,
        })
        tl._sync_attempt_results(state, state["task_ledger"])
        self.assertEqual(len(record["attempt_receipts"]), 1)
        self.assertEqual(record["attempt_receipts"][0]["status"], "Accepted")
        self.assertEqual(record["attempt_receipts"][0]["status_history"],
                         ["PendingAuthority", "Accepted"])
        outcome, code, _ = tl.diagnose(
            record, facts=make_facts(), state=state, tick=102, mono=1.02)
        self.assertEqual(outcome, tl.TASK_RECOVERING)
        self.assertEqual(code, "attempt_in_flight")
        self.assertEqual(record["retries_used"], 0)

        # 重放终态与更晚到达的旧 Pending 都不能重复结算或覆盖终态。
        state["command_receipts"].extend([
            {"intent_id": "i-1", "command_id": "c-1",
             "status": "Accepted", "accepted": True, "server_tick": 101},
            {"intent_id": "i-1", "command_id": "c-1",
             "status": "PendingAuthority", "accepted": False, "server_tick": 100},
        ])
        tl._sync_attempt_results(state, state["task_ledger"])
        self.assertEqual(len(record["attempt_receipts"]), 1)
        self.assertEqual(record["attempt_receipts"][0]["status"], "Accepted")
        self.assertEqual(record["retries_used"], 0)

    def test_pending_then_accepted_waits_for_real_site_completion(self):
        state, record = self._attempt_state({
            "intent_id": "i-1", "command_id": "c-1",
            "status": "PendingAuthority", "accepted": False, "server_tick": 100,
        })
        unfinished = make_facts(constructed={"ore_refinery": 0},
                                own_constructed={"SiteA": False})
        tl.evaluate(state, tick=101, facts=unfinished)
        self.assertEqual(record["retries_used"], 0)
        state["command_receipts"].append({
            "intent_id": "i-1", "command_id": "c-1",
            "status": "Accepted", "accepted": True, "server_tick": 102,
        })
        tl.evaluate(state, tick=102, facts=unfinished)
        self.assertEqual(record["attempt_receipts"][0]["status"], "Accepted")
        self.assertEqual(record["retries_used"], 0)

        completed = make_facts(constructed={"ore_refinery": 1},
                               own_constructed={"SiteA": True})
        report = tl.evaluate(state, tick=103, facts=completed)
        self.assertEqual(record["state"], tl.TASK_SUCCEEDED)
        self.assertIn("success_evidence", [c.get("reason_code")
                                           for c in report["changes"]])

    def test_unknown_or_pending_to_rejected_is_terminal_and_duplicate_is_idempotent(self):
        for initial_status in ("Unknown", "PendingAuthority"):
            with self.subTest(initial_status=initial_status):
                state, record = self._attempt_state({
                    "intent_id": "i-1", "command_id": "c-1",
                    "status": initial_status, "accepted": False, "server_tick": 100,
                })
                tl._sync_attempt_results(state, state["task_ledger"])
                state["command_receipts"].append({
                    "intent_id": "i-1", "command_id": "c-1",
                    "status": "Rejected", "accepted": False, "server_tick": 101,
                })
                tl._sync_attempt_results(state, state["task_ledger"])
                self.assertEqual(len(record["attempt_receipts"]), 1)
                self.assertEqual(record["attempt_receipts"][0]["status"], "Rejected")
                self.assertEqual(tl.diagnose(
                    record, facts=make_facts(), state=state, tick=102, mono=1.02)[1],
                    "recovery_attempt")
                self.assertEqual(record["retries_used"], 1)


class StableAttemptIdentityTest(unittest.TestCase):
    """E2：恢复授权身份跨意图/命令/异步回执传递，隔离旧尝试。"""

    def _record(self, attempt_id="m:t:attempt-2"):
        record = tl.new_record("t", kind="build", tick=90)
        record.update({
            "building_type": "ore_refinery", "site_entity": "SiteA",
            "attribution": "site", "state": tl.TASK_RECOVERING,
            "attempt": 2, "attempt_id": attempt_id,
            "attempt_identity_version": 1,
            "attempt_started_tick": 100, "attempt_counted_tick": -1,
            "attempt_counted_id": "", "attempt_window_ticks": 30,
            "attempt_intents": [], "attempt_commands": [],
            "attempt_receipts": [], "attempt_result_tick": 0,
            "retries_used": 1, "retry_budget": 3,
        })
        return record

    def test_same_tick_old_intent_and_late_receipt_do_not_enter_new_attempt(self):
        record = self._record()
        state = make_state(
            active_intents=[{
                "intent_id": "i-reused", "task_id": "t", "action": "build",
                "issued_tick": 100, "task_attempt_id": "m:t:attempt-1",
            }],
            command_receipts=[{
                "intent_id": "i-reused", "command_id": "c-old",
                "task_attempt_id": "m:t:attempt-1", "status": "Rejected",
                "accepted": False, "server_tick": 100,
            }],
            task_ledger={"t": record},
        )
        tl._sync_attempt_results(state, state["task_ledger"])
        self.assertEqual(record["attempt_intents"], [])
        self.assertEqual(record["attempt_commands"], [])
        self.assertEqual(record["attempt_receipts"], [])
        outcome, code, _ = tl.diagnose(
            record, facts=make_facts(), state=state, tick=101, mono=1.01)
        self.assertEqual(outcome, tl.TASK_RECOVERING)
        self.assertEqual(code, "awaiting_attempt_result")
        self.assertEqual(record["retries_used"], 1)

    def test_same_intent_can_have_multiple_current_commands_without_replay_leak(self):
        record = self._record()
        record["attempt_intents"] = ["i-reused"]
        record["attempt_commands"] = ["c-new-1", "c-new-2"]
        state = make_state(
            active_intents=[{
                "intent_id": "i-reused", "task_id": "t", "action": "build",
                "issued_tick": 10, "task_attempt_id": "m:t:attempt-2",
            }],
            command_receipts=[
                {"intent_id": "i-reused", "command_id": "c-old",
                 "task_attempt_id": "m:t:attempt-1", "status": "Rejected",
                 "accepted": False, "server_tick": 100},
                {"intent_id": "i-reused", "command_id": "c-new-1",
                 "task_attempt_id": "m:t:attempt-2", "status": "PendingAuthority",
                 "accepted": False, "server_tick": 101},
                {"intent_id": "i-reused", "command_id": "c-new-2",
                 "task_attempt_id": "m:t:attempt-2", "status": "Rejected",
                 "accepted": False, "server_tick": 102},
            ],
            task_ledger={"t": record},
        )
        tl._sync_attempt_results(state, state["task_ledger"])
        self.assertEqual({item["command_id"] for item in record["attempt_receipts"]},
                         {"c-new-1", "c-new-2"})
        # 相同命令身份重放只合并状态，不复制记录；旧尝试的拒绝不污染结论。
        state["command_receipts"].append(dict(state["command_receipts"][2]))
        tl._sync_attempt_results(state, state["task_ledger"])
        self.assertEqual(len(record["attempt_receipts"]), 2)
        self.assertEqual(record["retries_used"], 1)
        outcome, code, _ = tl.diagnose(
            record, facts=make_facts(), state=state, tick=103, mono=1.03)
        self.assertEqual(outcome, tl.TASK_RECOVERING)
        self.assertEqual(code, "recovery_attempt")
        self.assertEqual(record["retries_used"], 2)

    def test_current_attempt_command_id_fallback_is_narrow_and_blocked_order_isolated(self):
        record = self._record()
        record["attempt_intents"] = ["i-current"]
        record["attempt_commands"] = ["c-current"]
        record["order_key"] = "t|build|refinery"
        state = make_state(
            active_intents=[{
                "intent_id": "i-current", "task_id": "t", "action": "build",
                "issued_tick": 1, "task_attempt_id": "m:t:attempt-2",
            }],
            command_receipts=[{
                # Older transport lacks task_attempt_id; only the registered current
                # command may use the compatibility path.
                "intent_id": "i-current", "command_id": "c-current",
                "status": "Accepted", "accepted": True, "server_tick": 101,
            }],
            task_ledger={"t": record},
        )
        tl._sync_attempt_results(state, state["task_ledger"])
        self.assertEqual(record["attempt_receipts"][0]["attempt_id"], "m:t:attempt-2")
        record["cooldown_until_tick"] = 200
        self.assertIn(record["order_key"], tl.blocked_order_keys(state, 150))
        # 第二次授权会清空本次命令集合，旧回执不可阻止它的首次下发。
        record["attempt_id"] = "m:t:attempt-3"
        record["attempt_started_tick"] = 150
        record["attempt_counted_id"] = ""
        record["attempt_commands"] = []
        record["attempt_intents"] = []
        record["attempt_receipts"] = []
        record["attempt_result_tick"] = 0
        self.assertEqual(tl.blocked_order_keys(state, 151), {})

    def test_dispatch_recheck_and_checkpoint_keep_submission_attempt(self):
        import json
        from adjutant_coordinator.graph.nodes import (
            GraphServices, NodeContext, node_dispatch_to_godot, node_observe_receipt)
        record = self._record()
        intent = make_intent("i-current", action="build", task_id="t", issued_tick=100,
                             target={"scene": "res://Refinery.tscn", "producer": "Unit_w"})
        intent.update({"task_attempt_id": record["attempt_id"], "state": "active"})
        state = make_state(server_tick=100, task_ledger={"t": record},
                           active_intents=[intent], active_tasks={"t": "running"},
                           dispatch_pending=["i-current"], pending_requests={})
        sent = []
        def dispatch(envelopes):
            sent.extend(envelopes)
            return [{"status": "PendingAuthority", "accepted": False}]
        services = GraphServices(dispatch=dispatch, recheck=lambda command_id: {
            "command_id": command_id, "status": "Accepted", "accepted": True})
        ctx = NodeContext(services=services, observation={}, tick=100)
        node_dispatch_to_godot(state, ctx)
        original_id = record["attempt_id"]
        self.assertEqual(state["command_receipts"][0]["task_attempt_id"], original_id)
        self.assertEqual(state["pending_requests"]["i-current"]["task_attempt_id"], original_id)
        self.assertEqual(len(record["attempt_commands"]), 1)
        # Restore exactly as a JSON checkpoint does, then change the live task's attempt.
        restored = json.loads(json.dumps(state))
        restored["server_tick"] = 101
        restored["task_ledger"]["t"]["attempt_id"] = "m:t:attempt-3"
        node_observe_receipt(restored, NodeContext(services, {}, 101))
        self.assertEqual(restored["command_receipts"][-1]["task_attempt_id"], original_id)
        self.assertEqual(restored["command_receipts"][-1]["intent_id"], "i-current")
        self.assertEqual(len(sent), 1, "recheck must never resubmit the command")


class RuntimeLoopIntegrationTest(unittest.TestCase):
    """真实图轮次里的闭环：追踪事件 + 状态推进。"""

    def test_loop_events_and_states_in_real_ticks(self):
        with tempfile.TemporaryDirectory() as tmp:
            fixture = RuntimeFixture(
                strategy_script=[{"behavior": "completed", "plan": make_plan()}],
                tactics_script=[{"behavior": "completed", "intents": make_batch(
                    [make_intent("i-1", issued_tick=5, expires_tick=100000)])}],
                config=base_config(trace_enabled=True,
                                   trace_path=os.path.join(tmp, "trace.jsonl"),
                                   # 无进展期限压到 1 tick，让停滞边在测试里可达。
                                   loop_no_progress_seconds=0.001,
                                   loop_deadline_seconds=0.002))
            self.addCleanup(fixture.runtime.trace.close)
            fixture.tick(0)
            fixture.tick(5, events=[events_for("enemy_spotted", ["Unit_1"], 5)])
            for tick in (100, 200, 300):
                fixture.tick(tick)
            ledger = fixture.runtime.state.task_ledger
            self.assertTrue(ledger)
            record = ledger.get("t-1") or {}
            self.assertTrue(record)
            # move 类任务：没有到达事实 → 不应虚报成功；状态在等待/诊断/恢复之一。
            self.assertIn(record.get("state"),
                          (tl.TASK_WAITING, tl.TASK_DIAGNOSING, tl.TASK_RECOVERING,
                           tl.TASK_BLOCKED, tl.TASK_RUNNING, tl.TASK_PENDING))
            events = load_trace(os.path.join(tmp, "trace.jsonl"))
            fixture.runtime.trace.close()
            task_events = [e for e in events if e.get("kind") == "task"]
            self.assertTrue(task_events)
            # 闭环事件必须带判定依据（状态 + 原因码），不是裸状态。
            for entry in task_events:
                self.assertIn("reason_code", entry)


class ReceiptRuntimeBoundaryTest(unittest.TestCase):
    def test_tick_zero_stable_attempt_can_receive_its_own_receipt(self):
        record = StableAttemptIdentityTest()._record()
        record["attempt_started_tick"] = 0
        record["attempt_intents"] = ["at-zero"]
        record["attempt_commands"] = ["zero-command"]
        state = make_state(task_ledger={"t": record}, command_receipts=[{
            "intent_id": "at-zero", "command_id": "zero-command",
            "task_attempt_id": record["attempt_id"], "status": "Rejected", "accepted": False}])
        tl._sync_attempt_results(state, state["task_ledger"])
        self.assertEqual(len(record["attempt_receipts"]), 1)
        self.assertEqual(record["attempt_receipts"][0]["command_id"], "zero-command")

    def test_arbitrated_but_unsent_attempt_consumes_only_schedule_budget(self):
        from adjutant_coordinator.graph import nodes as nd
        record = StableAttemptIdentityTest()._record()
        intent = make_intent("accepted-unsent", action="build", task_id="t", issued_tick=100,
                             target={"scene": "res://Refinery.tscn", "producer": "Unit_w"})
        intent.update(state="active", task_attempt_id=record["attempt_id"])
        state = make_state(server_tick=100, task_ledger={"t": record}, active_intents=[intent],
                           dispatch_pending=["accepted-unsent"])
        nd.node_dispatch_to_godot(state, nd.NodeContext(nd.GraphServices(), {}, 100))
        tl._sync_attempt_results(state, state["task_ledger"])
        tl.diagnose(record, facts=make_facts(), state=state, tick=1000, mono=10)
        self.assertEqual(record["retries_used"], 1)
        self.assertEqual(record["schedule_waits"], 1)
        self.assertEqual(record["attempt_fail_kind"], "no_dispatch")

    def test_unknown_rechecks_original_command_until_accepted_without_resubmit(self):
        from adjutant_coordinator.graph import nodes as nd
        intent = make_intent("receipt-chain")
        intent.update(state="active", command_id="cmd-original")
        state = make_state(server_tick=10, active_intents=[intent], pending_requests={})
        nd._apply_receipt_to_state(state, "receipt-chain", {
            "status": "PendingAuthority", "command_id": "cmd-original"})
        replies = iter([{"status": "Unknown"}, {}, {"status": "Accepted", "accepted": True}])
        queried = []
        def recheck(command):
            queried.append(command)
            return next(replies)
        services = nd.GraphServices(recheck=recheck)
        for tick in (11, 12, 13):
            state["server_tick"] = tick
            nd.node_observe_receipt(state, nd.NodeContext(services, {}, tick))
        self.assertEqual(queried, ["cmd-original"] * 3)
        self.assertEqual(intent["state"], "active")
        self.assertFalse(state["pending_requests"])
        nd._apply_receipt_to_state(state, "receipt-chain", {
            "status": "PendingAuthority", "command_id": "cmd-original"})
        self.assertEqual(intent["state"], "active")
        self.assertFalse(state["pending_requests"])

    def test_checkpoint_state_keeps_unknown_and_rejects_old_submission(self):
        from adjutant_coordinator.graph.state import AdjutantGraphState
        state = AdjutantGraphState(match_id="m", player_id="p")
        state.add_intent({"intent_id": "reuse", "task_attempt_id": "old"}, "failed", "old-command")
        current = state.add_intent({"intent_id": "reuse", "task_attempt_id": "new"}, "active", "new-command")
        state.record_receipt({"intent_id": "reuse", "command_id": "new-command"})
        self.assertEqual(current["state"], "pending_authority")
        self.assertIn("reuse", state.pending_requests)
        state.record_receipt({"intent_id": "reuse", "command_id": "old-command",
                              "task_attempt_id": "old", "status": "Rejected"})
        self.assertEqual(current["state"], "pending_authority")
        state.record_receipt({"intent_id": "reuse", "command_id": "new-command",
                              "task_attempt_id": "new", "status": "Accepted", "accepted": True})
        self.assertFalse(state.pending_requests)

    def test_transport_lost_response_retains_actual_submission_for_recheck(self):
        from adjutant_coordinator.graph import nodes as nd
        record = StableAttemptIdentityTest()._record()
        intent = make_intent("lost-response", action="build", task_id="t",
                             target={"scene": "res://Refinery.tscn", "producer": "Unit_w"})
        intent.update(state="active", task_attempt_id=record["attempt_id"])
        state = make_state(server_tick=100, task_ledger={"t": record}, active_intents=[intent],
                           dispatch_pending=["lost-response"], pending_requests={})
        sent = []
        def dispatch(envelopes):
            sent.extend(envelopes)
            raise TimeoutError("response lost after submission")
        services = nd.GraphServices(dispatch=dispatch, recheck=lambda command: {
            "status": "Accepted", "accepted": True, "command_id": command})
        nd.node_dispatch_to_godot(state, nd.NodeContext(services, {}, 100))
        self.assertEqual(record["attempt_commands"], [sent[0]["command_id"]])
        self.assertEqual(state["command_receipts"][-1]["status"], "Unknown")
        self.assertEqual(intent["state"], "pending_authority")
        state["server_tick"] = 101
        nd.node_observe_receipt(state, nd.NodeContext(services, {}, 101))
        self.assertEqual(len(sent), 1)
        self.assertEqual(intent["state"], "active")


if __name__ == "__main__":
    unittest.main()
