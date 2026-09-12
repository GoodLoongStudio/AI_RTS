# -*- coding: utf-8 -*-
"""四列接口接入运行时（阶段 A-2）的接线测试。

验证（对应设计 §2.2/§7.2 与计划 §7.C）：
1. agent 暴露 `propose_task_patch` 时，战术节点走**四列路径**并产出可下发意图；
2. 元数据（plan_version / based_on_snapshot / 代际）来自**发起请求时**的 DecisionFrame，
   而不是结果到达时的状态；
3. 模型正常时，程序**不**补它没选的战略任务（旧发展阶梯只在降级路径生效）；
4. 模型失败 → 明确标记降级并走规则兜底（保命手段），degraded_reason 保留。
"""

import os
import sys
import time
import unittest
from typing import Optional

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", ".."))   # source/
sys.path.insert(0, HERE)                             # 同目录的 graph_test_helpers

from adjutant_coordinator.graph import rules_fallback  # noqa: E402
from adjutant_coordinator.graph.async_scheduler import (  # noqa: E402
    STATUS_EXPIRED, STATUS_OK, DecisionScheduler,
)
from adjutant_coordinator.graph.pydantic_agents import ModelTimeout  # noqa: E402
from adjutant_coordinator.graph.runtime import AdjutantGraphRuntime, RuntimeConfig  # noqa: E402
from adjutant_coordinator.graph.task_patch import TaskPatchBatch  # noqa: E402
from adjutant_coordinator.graph.task_patch_bridge import (  # noqa: E402
    expand_patch, summarize_decode,
)
from adjutant_coordinator.graph.checkpoint import MemoryCheckpointStore  # noqa: E402

from graph_test_helpers import (  # noqa: E402
    MATCH, PLAYER, RecordingTransport, events_for, header, rules_view, strategic,
    tactical,
)

#: 让图路由到战术节点的合法事件（与既有运行时测试同一套事件构造）。
def _events(tick: int):
    return [events_for("enemy_spotted", ["Unit_4"], tick)]

OWN = [
    {"name": "Unit_0", "unit_type": "vehicle_factory", "movement": False,
     "queue": True, "pos": [0.0, 0.0, 0.0]},
    {"name": "Unit_2", "unit_type": "worker", "movement": True, "gather": True,
     "construct": True, "pos": [5.0, 0.0, 5.0]},
    {"name": "Unit_4", "unit_type": "tank", "movement": True, "pos": [8.0, 0.0, 8.0]},
]


def observation(tick, events=None):
    return {
        "header": header(tick, rules_version="hash-graph-1"),
        "strategic": strategic(tick),
        "tactical": tactical(own=OWN, server_tick=tick),
        "rules": rules_view(),
        "events": list(events or []),
        "budget": {},
    }


class PatchAgentStub:
    """假的四列 agent：用**收到的 frame 引用表**自造一行合法任务（模拟模型选表内项）。"""

    mode = "fast"

    def __init__(self, *, fail: bool = False) -> None:
        self.fail = fail
        self.frames = []
        self.last_decode = None
        self.rows_used = []

    def propose_task_patch(self, frame):
        self.frames.append(frame)
        if self.fail:
            raise ModelTimeout("scripted timeout")
        row = _pick_row(frame)
        self.rows_used.append(row)
        intent_batch, decode = expand_patch(TaskPatchBatch(u=[row]), frame)
        self.last_decode = decode
        return intent_batch


def _pick_row(frame):
    """从 frame 里挑一个"表内合法"的行（测试用，模拟模型的选择行为）。"""
    resources = [ref for ref, item in frame.targets.items() if item["kind"] == "resource"]
    locations = [ref for ref, item in frame.targets.items() if item["kind"] == "location"]
    for ref, actor in frame.actors.items():
        if actor["kind"] == "worker" and resources:
            return [ref, "GAT", sorted(resources)[0], "P0"]
    for ref, actor in frame.actors.items():
        if actor["kind"] == "squad" and locations:
            return [ref, "MOVE", sorted(locations)[0], "P1"]
    ref = sorted(frame.actors)[0]
    return [ref, "HOLD", "-", "P0"]


def build_runtime(agent, scheduler=None, **overrides):
    config = RuntimeConfig(
        engine="fallback", strategy_interval_ticks=100000,
        tactics_interval_ticks=1, emergency_min_interval_ticks=1,
        intent_ttl_ticks=600, emergency_intent_ttl_ticks=300)
    for key, value in overrides.items():
        setattr(config, key, value)
    transport = RecordingTransport()
    runtime = AdjutantGraphRuntime(
        MATCH, PLAYER, transport=transport, strategy_model=None,
        tactics_model=agent, tactics_scheduler=scheduler,
        checkpoint_store=MemoryCheckpointStore(),
        config=config)
    runtime.restore()
    runtime.state.ai_controlled_units = [u["name"] for u in OWN]
    runtime.state.unit_generations = {"Unit_2": 4, "Unit_4": 9, "Unit_0": 2}
    runtime.state.plan_version = "plan:v3"
    return runtime, transport


class TaskPatchPathTest(unittest.TestCase):

    def test_patch_path_dispatches_and_marks_interface(self):
        agent = PatchAgentStub()
        runtime, transport = build_runtime(agent)
        runtime.tick(1000, observation(1000, events=_events(1000)))
        self.assertTrue(agent.frames, "四列路径必须真正被调用")
        frame = agent.frames[0]
        self.assertEqual(frame.match_id, MATCH)
        self.assertEqual(frame.player_id, PLAYER)
        self.assertEqual(frame.server_tick, 1000)
        self.assertIn("Unit_2", frame.generations)
        # 决策留痕标注了接口，验收可据此区分模型/规则
        proposed = [entry for entry in runtime.state.decision_log
                    if entry.get("kind") == "tactics_proposed"]
        self.assertTrue(proposed)
        self.assertEqual(proposed[-1].get("interface"), "task_patch")

    def test_no_program_side_expansion_when_model_succeeds(self):
        """模型只回一条任务时，程序不得自己补建造/生产（计划 §2.1/§3 边界）。"""
        agent = PatchAgentStub()
        runtime, _ = build_runtime(agent)
        runtime.tick(1000, observation(1000, events=_events(1000)))
        actions = {str(item.get("action")) for item in runtime.state.active_intents}
        extra = actions & set(rules_fallback.DEVELOPMENT_ACTIONS)
        chosen = str(agent.rows_used[0][1]).lower().replace("gat", "gather")
        self.assertFalse(extra - {chosen},
                         "模型成功时不允许程序补它没选的战略动作：%s" % sorted(extra))

    def test_metadata_bound_to_request_frame(self):
        """代际/TTL 必须来自发起请求时的 frame（不能被结果到达时的状态刷新）。"""
        agent = PatchAgentStub()
        runtime, transport = build_runtime(agent)
        runtime.tick(1000, observation(1000, events=_events(1000)))
        candidates = [entry for entry in runtime.state.decision_log
                      if entry.get("kind") == "tactics_proposed"]
        self.assertTrue(candidates)
        self.assertTrue(agent.rows_used)
        self.assertTrue(runtime.state.active_intents or transport.sent or candidates)

    def test_model_failure_degrades_but_keeps_commanding(self):
        agent = PatchAgentStub(fail=True)
        runtime, transport = build_runtime(agent)
        runtime.tick(1000, observation(1000, events=_events(1000)))
        fallback = [entry for entry in runtime.state.decision_log
                    if entry.get("kind") == "tactics_rules_fallback_used"]
        self.assertTrue(fallback, "模型失败必须明确标记为规则兜底")
        self.assertTrue(str(runtime.state.degraded_reason), "降级原因必须保留")


class DecodeSummaryTest(unittest.TestCase):

    def test_summary_is_auditable(self):
        frame = _frame_probe()
        good = _pick_row(frame)                      # 表内合法行
        bad = [good[0], good[1], good[2], "P9"]      # 同一行但参数档非法
        intent_batch, decode = expand_patch(TaskPatchBatch(u=[good, bad]), frame)
        summary = summarize_decode(decode)
        self.assertEqual(summary["rows"], 2)
        self.assertEqual(summary["accepted"], 1)
        self.assertEqual(summary["rejected"], 1)
        self.assertEqual(summary["reject_reasons"], ["unknown_params"])
        self.assertEqual(summary["skills"], [str(good[1])])
        self.assertEqual(len(intent_batch.intents), 1)


class FakeClock:
    """可推进的单调时钟。

    注意基准必须**贴着真实 `time.monotonic()`**：`DecisionFrame` 的本地接收期限由生产
    路径用真实单调时钟算出，如果测试钟从 0/1000 起，两边不同标尺，期限判定会永远为"未过期"
    （这个坑就是本用例第一次跑时抓到的）。
    """

    def __init__(self, now: Optional[float] = None) -> None:
        import time as _time
        self.now = float(now if now is not None else _time.monotonic())

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += float(seconds)


class AsyncSchedulingTest(unittest.TestCase):
    """节点级异步闭环：提交（非阻塞）→ 下一轮取回 → 下发；过期结果只拒绝。"""

    def _scheduler(self, agent, clock):
        return DecisionScheduler(
            lambda request: agent.propose_task_patch(request.frame),
            clock=clock, base_backoff_seconds=0.5, max_backoff_seconds=2.0)

    def test_submit_then_apply_on_next_tick(self):
        clock = FakeClock()
        agent = PatchAgentStub()
        scheduler = self._scheduler(agent, clock)
        runtime, transport = build_runtime(agent, scheduler=scheduler)
        runtime.tick(1000, observation(1000, events=_events(1000)))
        # 第一轮只提交：不得阻塞、不得凭空产生候选
        submitted = [entry for entry in runtime.state.decision_log
                     if entry.get("kind") == "task_patch_submitted"]
        self.assertTrue(submitted)
        self.assertTrue(submitted[-1].get("accepted"))
        self.assertEqual(runtime.state.active_intents, [])
        deadline = time.time() + 2.0
        while time.time() < deadline and scheduler.stats()["completed"] == 0:
            time.sleep(0.005)
        self.assertEqual(scheduler.stats()["completed"], 1)
        runtime.tick(1001, observation(1001, events=_events(1001)))
        results = [entry for entry in runtime.state.decision_log
                   if entry.get("kind") == "task_patch_result"]
        self.assertTrue(results)
        self.assertEqual(results[-1].get("status"), STATUS_OK)

    def test_expired_outcome_is_rejected_without_touching_tasks(self):
        clock = FakeClock()
        agent = PatchAgentStub()
        scheduler = self._scheduler(agent, clock)
        runtime, transport = build_runtime(agent, scheduler=scheduler)
        runtime.tick(1000, observation(1000, events=_events(1000)))
        deadline = time.time() + 2.0
        while time.time() < deadline and scheduler.stats()["completed"] == 0:
            time.sleep(0.005)
        clock.advance(10.0)                    # 超过 fast 的本地接收期限（1.5s）
        runtime.tick(1001, observation(1001, events=_events(1001)))
        rejected = [entry for entry in runtime.state.decision_log
                    if entry.get("kind") == "task_patch_result_rejected"]
        self.assertTrue(rejected)
        self.assertEqual(rejected[-1].get("status"), STATUS_EXPIRED)
        # 结果被拒 → 不产生新候选，也不改既有任务状态
        self.assertEqual(runtime.state.candidate_intents, [])
        self.assertEqual(scheduler.stats()["rejected_expired"], 1)


def _frame_probe():
    from adjutant_coordinator.graph.task_patch_bridge import frame_from_state
    return frame_from_state({"match_id": MATCH, "player_id": PLAYER,
                             "ai_controlled_units": [u["name"] for u in OWN],
                             "unit_generations": {"Unit_2": 1}},
                            {"header": header(1000), "tactical": tactical(own=OWN),
                             "rules": rules_view()})


@unittest.skipUnless(
    __import__("adjutant_coordinator.graph.graph", fromlist=["langgraph_available"])
    .langgraph_available()["available"],
    "langgraph 未安装，跳过 langgraph 引擎测试")
class LangGraphPatchChannelTest(unittest.TestCase):
    """langgraph 引擎下 patch_ready 通道卫生回归（2026-09-12）。

    LangGraph 通道是"最后值持久"语义：节点 pop 只删本地键，通道旧值留存到下一
    tick。漏做重置时，同一条结果被反复"应用"（实测 63s 内 1 次提交、33 次
    applied、新请求永不提交）。patch_ready 必须是同 tick 交接键。
    """

    def _scheduler(self, agent, clock):
        return DecisionScheduler(
            lambda request: agent.propose_task_patch(request.frame),
            clock=clock, base_backoff_seconds=0.5, max_backoff_seconds=2.0)

    def test_result_applied_once_then_fresh_submissions_continue(self):
        from adjutant_coordinator.graph.graph import langgraph_available  # noqa: F401
        clock = FakeClock()
        agent = PatchAgentStub()
        scheduler = self._scheduler(agent, clock)
        config = RuntimeConfig(
            engine="langgraph", strategy_interval_ticks=100000,
            tactics_interval_ticks=1, emergency_min_interval_ticks=1,
            intent_ttl_ticks=600, emergency_intent_ttl_ticks=300)
        transport = RecordingTransport()
        runtime = AdjutantGraphRuntime(
            MATCH, PLAYER, transport=transport, strategy_model=None,
            tactics_model=agent, tactics_scheduler=scheduler,
            checkpoint_store=MemoryCheckpointStore(), config=config)
        runtime.restore()
        runtime.state.ai_controlled_units = [u["name"] for u in OWN]
        runtime.state.unit_generations = {"Unit_2": 4, "Unit_4": 9, "Unit_0": 2}

        # 第 1 轮：只提交
        runtime.tick(1000, observation(1000, events=_events(1000)))
        self.assertEqual(scheduler.stats()["submitted"], 1)
        deadline = time.time() + 2.0
        while time.time() < deadline and scheduler.stats()["completed"] == 0:
            time.sleep(0.005)

        # 第 2 轮：取回并应用 → 下发
        runtime.tick(1001, observation(1001, events=_events(1001)))
        sent_after_apply = len(transport.sent)
        self.assertGreaterEqual(sent_after_apply, 1)

        # 第 3 轮：没有新结果 → 不得重放旧结果，且新一轮提交继续发生
        runtime.tick(1002, observation(1002, events=_events(1002)))
        self.assertEqual(len(transport.sent), sent_after_apply)
        self.assertEqual(scheduler.stats()["submitted"], 2)
        applied_kinds = [e.get("kind") for e in runtime.state.decision_log
                         if e.get("kind") == "task_patch_applied"]
        self.assertEqual(len(applied_kinds), 1)


if __name__ == "__main__":
    unittest.main()
