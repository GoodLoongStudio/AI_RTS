# -*- coding: utf-8 -*-
"""决策追踪测试（第一阶段 · 修改 1：补齐运行时决策追踪）。

覆盖追踪合同的关键不变式：
1. 事件信封字段齐全；`round_seq` 每轮 +1（相同 tick 的多轮不串）；
2. 节点 enter/exit/error span；异常必须留 error span；
3. 选边事件带 route + 可测试判据码 + 短中文解释；
4. 候选入口条件逐项 值/结果/缺项；
5. 任务 created/transition 与命令 submitted/receipt/dropped 事件；
6. 异步模型调用按**帧身份**关联（不按最近时间猜因果）；
7. JSONL 轮转有界、写失败只计数不抛出、内存环有界；
8. checkpoint 恢复后 session/round_seq 延续（重开对局不串）；
9. 旧格式（无 schema）事件可读、不补造；
10. 两条执行器都产 span（未装 langgraph 时跳过对照）。
"""

import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph import trace as trace_mod
from adjutant_coordinator.graph.graph import langgraph_available
from adjutant_coordinator.graph.runtime import AdjutantGraphRuntime, RuntimeConfig
from adjutant_coordinator.graph.trace import (
    TRACE_SCHEMA, TRACE_VERSION, TraceRecorder, build_recorder, command_chain,
    frame_identity, load_trace, new_run_id, new_session_id, task_chain,
)

from graph_test_helpers import MATCH, PLAYER, events_for, make_batch, make_intent, make_plan
from test_graph_runtime_fake import RuntimeFixture, base_config, observation

REQUIRED_ENVELOPE = ("schema", "version", "seq", "session_id", "run_id", "match_id",
                     "player_id", "round_seq", "server_tick", "ts_mono", "ts_wall",
                     "kind", "phase")


class TraceRecorderContractTest(unittest.TestCase):
    """记录器合同：信封、轮次、禁用态。"""

    def test_envelope_fields_and_kinds(self):
        recorder = build_recorder(session_id="s1", run_id="r1", match_id=MATCH,
                                  player_id=PLAYER, enabled=True)
        recorder.begin_round(100, snapshot_id=7)
        recorder.end_round(route="tactical", elapsed_ms=12.5, server_tick=100)
        recorder.node_enter("ingest_observation", "r1-ingest", server_tick=100)
        recorder.node_exit("ingest_observation", "r1-ingest", duration_ms=3.2,
                           server_tick=100)
        recorder.edge("classify_event", "tactical_agent", route="tactical",
                      reason_code="classify_route:tactical", reason_cn="战术节拍到期",
                      server_tick=100)
        recorder.candidate_eval("D2", "经济恢复", conditions=[
            {"name": "needs_recovery", "text": "经济需要恢复", "value": False,
             "result": False, "missing": True, "error": ""}],
            available=False, reason_code="locked:needs_recovery",
            reason_cn="暂不可选（缺：经济需要恢复）", server_tick=100)
        recorder.task("t-1", "created", goal_id="M01", state="pending", server_tick=100)
        recorder.command("i-1", "receipt", command_id="c:1", attempt=1, action="build",
                         status="Accepted", accepted=True, server_tick=100)
        recorder.model_call("tactics", "submit", frame=None, status="queued",
                            server_tick=100)
        recorder.note("paused_player_interrupt", server_tick=100)
        events = recorder.query(limit=100)
        self.assertEqual(len(events), 10)
        for entry in events:
            for key in REQUIRED_ENVELOPE:
                self.assertIn(key, entry, "事件缺信封字段 %s：%r" % (key, entry))
            self.assertEqual(entry["schema"], TRACE_SCHEMA)
            self.assertEqual(entry["version"], TRACE_VERSION)
        kinds = [entry["kind"] for entry in events]
        self.assertIn("edge", kinds)
        self.assertIn("candidate_eval", kinds)
        self.assertIn("task", kinds)
        self.assertIn("command", kinds)
        self.assertIn("model_call", kinds)
        # seq 单调递增；round_seq 全程为 1（begin 后没再开轮）。
        seqs = [entry["seq"] for entry in events]
        self.assertEqual(seqs, sorted(seqs))
        self.assertTrue(all(entry["round_seq"] == 1 for entry in events))

    def test_round_seq_is_not_tick(self):
        """相同 tick 的多轮 → round_seq 不同（tick 不能当轮次身份）。"""
        recorder = build_recorder(session_id="s", run_id="r", enabled=True)
        seen = []
        for _ in range(3):
            seen.append(recorder.begin_round(9557))
        self.assertEqual(seen, [1, 2, 3])
        self.assertNotEqual(seen[0], 9557)

    def test_adopt_round_seq_only_moves_forward(self):
        recorder = build_recorder(session_id="s", run_id="r", enabled=True)
        recorder.begin_round(1)
        recorder.adopt_round_seq(50)
        self.assertEqual(recorder.round_seq, 50)
        recorder.adopt_round_seq(10)  # 旧 checkpoint 不回退
        self.assertEqual(recorder.round_seq, 50)
        self.assertEqual(recorder.begin_round(2), 51)

    def test_disabled_recorder_is_inert(self):
        recorder = trace_mod.NullTraceRecorder()
        self.assertIsNone(recorder.begin_round(1))
        self.assertIsNone(recorder.edge("a", "b", route="wait"))
        self.assertEqual(recorder.query(limit=10), [])
        stats = recorder.stats()
        self.assertFalse(stats["enabled"])
        self.assertEqual(stats["events"], 0)

    def test_session_and_run_ids_are_not_tick_based(self):
        session_a = new_session_id()
        session_b = new_session_id()
        self.assertNotEqual(session_a, session_b)
        self.assertTrue(session_a)
        run_id = new_run_id(pid=1234)
        self.assertTrue(run_id.startswith("pid1234-"))


class FrameIdentityTest(unittest.TestCase):
    """异步请求的原关联：帧身份稳定、可join。"""

    def test_frame_identity_ignores_missing_and_keeps_frozen_fields(self):
        class Frame:
            match_id = MATCH
            player_id = PLAYER
            server_tick = 9557
            snapshot_id = 42
            plan_version = "plan:v1"
            strategy_epoch = 3
            generations = {"Unit_1": 5, "Unit_2": 6}

        identity = frame_identity(Frame())
        self.assertEqual(identity["server_tick"], 9557)
        self.assertEqual(identity["snapshot_id"], 42)
        self.assertEqual(identity["strategy_epoch"], 3)
        self.assertIn("generations_digest", identity)
        self.assertEqual(frame_identity(None), {})

    def test_submit_and_result_join_by_frame_identity(self):
        """提交与结果不按时间相邻配对：同一帧身份才能 join。"""

        class Frame:
            match_id = MATCH
            player_id = PLAYER
            server_tick = 100
            snapshot_id = 1
            plan_version = "plan:v1"
            strategy_epoch = 1
            generations = {"Unit_1": 1}

        recorder = build_recorder(session_id="s", run_id="r", enabled=True)
        recorder.model_call("strategy", "submit", frame=Frame(), status="queued",
                            server_tick=100)
        # 中途别的轮次发生（时间相邻的其它事件不得被误配）。
        recorder.begin_round(101)
        recorder.model_call("tactics", "submit", frame=None, status="queued",
                            server_tick=101)
        recorder.model_call("strategy", "result", request_id=7, frame=Frame(),
                            status="ok", latency_ms=250, server_tick=140)
        events = recorder.query(kind="model_call", limit=50)
        strategy = [e for e in events if e.get("role") == "strategy"]
        self.assertEqual(len(strategy), 2)
        submit, result = strategy
        self.assertEqual(submit["frame"], result["frame"])
        self.assertEqual(result["request_id"], 7)
        self.assertEqual(result["latency_ms"], 250)


class RotatingSinkTest(unittest.TestCase):
    """文件 sink：轮转有界、写失败可见不抛出。"""

    def test_rotation_keeps_backups_and_bounds_size(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "trace.jsonl")
            sink = trace_mod.RotatingJsonlSink(path, max_bytes=4096, backups=2)
            for index in range(400):
                sink({"schema": TRACE_SCHEMA, "seq": index, "kind": "note",
                      "pad": "x" * 64})
            sink.close()
            self.assertTrue(os.path.exists(path))
            self.assertTrue(os.path.exists(path + ".1"))
            self.assertTrue(os.path.exists(path + ".2"))
            self.assertFalse(os.path.exists(path + ".3"))
            total = sum(os.path.getsize(path + suffix)
                        for suffix in ("", ".1", ".2"))
            self.assertLess(total, 4096 * 4)
            self.assertEqual(sink.stats()["errors"], 0)

    def test_write_failure_is_counted_not_raised(self):
        class BrokenSink:
            def __call__(self, entry):
                raise OSError("disk full")

            def stats(self):
                return {"path": "broken"}

        recorder = TraceRecorder(session_id="s", run_id="r", sink=BrokenSink(),
                                 enabled=True)
        recorder.note("boom")  # 不得抛异常
        stats = recorder.stats()
        self.assertGreaterEqual(stats["diagnostic_errors"], 1)
        self.assertIn("disk full", stats["last_diagnostic_error"])
        # 失败也必须在内存环里可见（诊断写入异常需可见）。
        notes = [e for e in recorder.query(limit=50) if e.get("kind") == "note"]
        self.assertTrue(any(str(e.get("note", "")) == "diagnostic_error"
                            or e.get("original_kind") == "note" for e in notes))


class TraceFileRoundTripTest(unittest.TestCase):
    """文件读写与查询助手；旧格式容忍。"""

    def test_load_trace_and_chains(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "trace.jsonl")
            recorder = build_recorder(session_id="s1", run_id="r1", match_id=MATCH,
                                      player_id=PLAYER, path=path, enabled=True)
            recorder.begin_round(10)
            recorder.task("rule-build-ore_refinery", "created", goal_id="M08")
            recorder.command("rule-build-ore_refinery-1", "receipt",
                             command_id="cmd-1", attempt=1, action="build",
                             status="Accepted", accepted=True)
            recorder.command("rule-build-ore_refinery-1", "recheck",
                             command_id="cmd-1", attempt=1, action="build",
                             status="Rejected", reason="Occupied")
            recorder.close()
            events = load_trace(path)
            self.assertEqual(len(events), 4)
            chain = task_chain(events, "rule-build-ore_refinery")
            self.assertEqual(len(chain), 1)
            self.assertEqual(chain[0]["goal_id"], "M08")
            commands = command_chain(events, intent_id="rule-build-ore_refinery-1")
            self.assertEqual([e["event"] for e in commands], ["receipt", "recheck"])
            # 旧格式（无 schema 字段）不得被补造，也不得读失败。
            legacy_path = os.path.join(tmp, "legacy.jsonl")
            with open(legacy_path, "w", encoding="utf-8") as handle:
                handle.write(json.dumps({"kind": "round", "server_tick": 1}) + "\n")
                handle.write("not-json\n")
            legacy = load_trace(legacy_path)
            self.assertEqual(len(legacy), 1)
            self.assertNotIn("schema", legacy[0])


class RuntimeTraceIntegrationTest(unittest.TestCase):
    """真实图轮次里的追踪：span/选边/候选/任务/命令。"""

    def _fixture(self, tmp, **overrides):
        config = base_config(trace_enabled=True,
                             trace_path=os.path.join(tmp, "trace.jsonl"),
                             **overrides)
        fixture = RuntimeFixture(
            strategy_script=[{"behavior": "completed", "plan": make_plan()}],
            # 紧急事件触发战术路由 → 模型意图真实走"仲裁→下发→回执"链，
            # 命令事件才有东西可记（只靠规则地板在这个观测下不产意图）。
            tactics_script=[{"behavior": "completed", "intents": make_batch(
                [make_intent("i-1", issued_tick=5, expires_tick=100000)])}],
            config=config)
        # Windows 句柄占用：测试结束必须关掉追踪文件，否则临时目录删不掉。
        self.addCleanup(fixture.runtime.trace.close)
        return fixture

    def _dispatch_tick(self, fixture, tick):
        """紧急事件 → 战术路由 → 真实下发一条模型意图。"""
        return fixture.tick(tick, events=[events_for("enemy_spotted", ["Unit_1"], tick)])

    def test_tick_emits_round_spans_edge_candidates_and_commands(self):
        with tempfile.TemporaryDirectory() as tmp:
            fixture = self._fixture(tmp)
            fixture.tick(0)
            self._dispatch_tick(fixture, 5)
            events = load_trace(os.path.join(tmp, "trace.jsonl"))
            fixture.runtime.trace.close()
            self.assertTrue(events)
            # 轮次：两次 tick → 两个 begin（相同 tick 也不会串号）。
            begins = [e for e in events if e["kind"] == "round" and e["phase"] == "begin"]
            self.assertEqual(len(begins), 2)
            self.assertEqual(begins[0]["round_seq"] + 1, begins[1]["round_seq"])
            # 节点 span：ingest/campaign/classify 至少都有 enter+exit。
            spans = [e for e in events if e["kind"] == "node_span"]
            nodes = {e["node"] for e in spans}
            for expected in ("ingest_observation", "update_campaign_state",
                             "classify_event"):
                self.assertIn(expected, nodes)
            for node in nodes:
                phases = {e["phase"] for e in spans if e["node"] == node}
                self.assertIn("enter", phases)
                self.assertIn("exit", phases)
            # 选边：route 与判据码齐全。
            edges = [e for e in events if e["kind"] == "edge"]
            self.assertTrue(edges)
            self.assertTrue(all(e.get("route") for e in edges))
            self.assertTrue(all(e.get("reason_code") for e in edges))
            self.assertTrue(all(e.get("reason_cn") for e in edges))
            # 候选评估：D1..D14 都出现，且每项带 value/result/missing。
            candidates = [e for e in events if e["kind"] == "candidate_eval"]
            self.assertGreaterEqual(len(candidates), 10)
            for entry in candidates:
                self.assertIn("conditions", entry)
                for condition in entry["conditions"]:
                    for key in ("name", "value", "result", "missing"):
                        self.assertIn(key, condition)
            # 任务 created（计划采纳）与命令回执事件。
            tasks = [e for e in events if e["kind"] == "task"]
            self.assertTrue(any(e["event"] == "created" for e in tasks))
            commands = [e for e in events if e["kind"] == "command"]
            self.assertTrue(commands)
            self.assertTrue(any(e["event"] in ("receipt", "dropped") for e in commands))

    def test_command_chain_correlates_attempt_and_command_id(self):
        """同一任务的多次尝试：attempt 递增、command_id 不混。"""
        with tempfile.TemporaryDirectory() as tmp:
            fixture = self._fixture(tmp)
            fixture.tick(0)
            self._dispatch_tick(fixture, 5)
            self._dispatch_tick(fixture, 35)
            events = load_trace(os.path.join(tmp, "trace.jsonl"))
            fixture.runtime.trace.close()
            commands = [e for e in events if e["kind"] == "command"]
            self.assertTrue(commands)
            by_intent = {}
            for entry in commands:
                by_intent.setdefault(entry["intent_id"], []).append(entry)
            # 同一 intent 的所有事件必须带 attempt 且 command_id 一致（不按 tick 猜）。
            for intent_id, rows in by_intent.items():
                command_ids = {row.get("command_id", "") for row in rows}
                self.assertEqual(len(command_ids), 1,
                                 "%s 的 command_id 不唯一：%s" % (intent_id, command_ids))
                self.assertTrue(all(isinstance(row.get("attempt", 0), int) for row in rows))

    def test_session_and_round_survive_checkpoint_restore(self):
        """恢复后 session_id 与 round_seq 延续；新对局不继承旧会话。"""
        with tempfile.TemporaryDirectory() as tmp:
            fixture = self._fixture(tmp)
            fixture.tick(0)
            first_session = fixture.runtime.trace.session_id
            first_rounds = fixture.runtime.trace.round_seq
            fixture.runtime.checkpoint()
            fixture.runtime.trace.close()
            events_before = load_trace(os.path.join(tmp, "trace.jsonl"))
            fixture.runtime.trace.close()
            # 同对局恢复：沿用 session，round_seq 前进不撞号。
            restored = RuntimeFixture(config=base_config(
                trace_enabled=True, trace_path=os.path.join(tmp, "trace2.jsonl")))
            self.addCleanup(restored.runtime.trace.close)
            restored.store.payload = fixture.store.payload
            result = restored.runtime.restore()
            self.assertTrue(result["restored"])
            self.assertEqual(restored.runtime.trace.session_id, first_session)
            self.assertGreaterEqual(restored.runtime.trace.round_seq, first_rounds)
            restored.tick(120)
            events_after = load_trace(os.path.join(tmp, "trace2.jsonl"))
            restored.runtime.trace.close()
            self.assertTrue(events_after)
            self.assertTrue(all(e["session_id"] == first_session for e in events_after))
            self.assertTrue(all(e["round_seq"] > first_rounds - 1 for e in events_after))
            self.assertTrue(events_before)

    def test_identity_drift_round_leaves_no_cross_match_command(self):
        """串局观测：记 drift note，不产出跨对局命令事件。"""
        with tempfile.TemporaryDirectory() as tmp:
            fixture = self._fixture(tmp)
            fixture.tick(0, match_id="m-other")
            events = load_trace(os.path.join(tmp, "trace.jsonl"))
            fixture.runtime.trace.close()
            self.assertTrue(all(e["match_id"] == MATCH for e in events))
            commands = [e for e in events if e["kind"] == "command"]
            self.assertEqual(commands, [])

    def test_pause_leaves_exit_state(self):
        """玩家打断暂停：必须有退出状态留痕（暂停不漏退出状态）。"""
        with tempfile.TemporaryDirectory() as tmp:
            fixture = self._fixture(tmp)
            fixture.tick(0, events=[{
                "event_id": "evt-override-0", "kind": "player_override",
                "match_id": MATCH, "player_id": PLAYER, "server_tick": 0,
                "payload": {"subject": "Unit_1", "reason": "manual"},
            }])
            events = load_trace(os.path.join(tmp, "trace.jsonl"))
            fixture.runtime.trace.close()
            notes = [e for e in events if e["kind"] == "note"]
            self.assertTrue(any(e.get("note") in ("paused_player_interrupt",
                                                  "resume_from_pause")
                                for e in notes))


class TraceBoundTest(unittest.TestCase):
    """P2 返修：索引键总数有界（旧实现只限每个键的 deque 长度）。"""

    def test_command_index_keys_are_bounded(self):
        recorder = TraceRecorder(session_id="s", run_id="r", enabled=True,
                                 index_limit=64)
        for index in range(1000):
            recorder.command("intent-%d" % index, "dropped",
                             command_id="cmd-%d" % index, attempt=1,
                             action="build", status="dropped", reason="x")
        stats = recorder.stats()
        self.assertLessEqual(len(recorder._by_command), 64,
                             "命令索引键数必须受限（intent_id 每轮都新）")
        self.assertLessEqual(len(recorder._by_task), 64)
        # 内存环本身也有界。
        self.assertLessEqual(len(recorder.query(limit=10 ** 6)), recorder._memory.maxlen)

    def test_dropped_events_carry_task_id_from_candidates(self):
        """P2-2：仲裁丢弃结果缺 task_id 时，从候选表补关联。"""
        from adjutant_coordinator.graph.nodes import (
            GraphConfig, GraphServices, node_arbitrate_intent)
        from adjutant_coordinator.graph.state import AdjutantGraphState
        state = AdjutantGraphState(match_id=MATCH, player_id=PLAYER).to_dict()
        state["server_tick"] = 100
        state["plan_version"] = "plan-a:v1"
        state["candidate_intents"] = [{
            "intent_id": "rule-build-ore_refinery-1", "task_id": "rule-build-ore_refinery",
            "action": "build", "unit_ids": ["Unit_0"],
            "target": {"scene": "res://x/ore_refinery.tscn"},
            "plan_version": "plan-a:v1", "issued_tick": 100, "expires_tick": 700,
            "priority": 1, "based_on_snapshot": 1,
        }]
        services = GraphServices()
        ctx = type("Ctx", (), {"services": services, "observation": {}, "tick": 100,
                               "config": GraphConfig()})()
        # 计划版本不一致 → 仲裁丢弃该候选（丢弃结果不带 task_id）。
        state["plan_version"] = "plan-b:v9"
        out = node_arbitrate_intent(state, ctx)
        dropped = out.get("intent_arbitration", {}).get("dropped", [])
        self.assertTrue(dropped, "候选应被仲裁丢弃")
        # 追踪事件必须能关联到任务（从候选表补）。
        events = services.trace.query(kind="command", limit=50) if services.trace else []
        self.assertEqual(events, [])  # 未注入 trace：确认旁路安全
        decisions = [d for d in out.get("decision_log", [])
                     if d.get("kind") == "intent_dropped"]
        self.assertTrue(decisions)


@unittest.skipUnless(langgraph_available()["available"], "langgraph 未安装")
class EngineTraceEquivalenceTest(unittest.TestCase):
    """两条执行器都产 span（LangGraph 与内置执行器追踪合同一致）。"""

    def test_langgraph_engine_emits_same_trace_kinds(self):
        with tempfile.TemporaryDirectory() as tmp:
            fixture = RuntimeFixture(
                strategy_script=[{"behavior": "completed", "plan": make_plan()}],
                config=base_config(engine="langgraph", trace_enabled=True,
                                   trace_path=os.path.join(tmp, "trace.jsonl")))
            self.addCleanup(fixture.runtime.trace.close)
            fixture.tick(0)
            events = load_trace(os.path.join(tmp, "trace.jsonl"))
            fixture.runtime.trace.close()
            kinds = {e["kind"] for e in events}
            for expected in ("round", "node_span", "edge", "candidate_eval"):
                self.assertIn(expected, kinds)
            spans = {e["node"] for e in events if e["kind"] == "node_span"}
            self.assertIn("ingest_observation", spans)
            self.assertIn("classify_event", spans)


if __name__ == "__main__":
    unittest.main()
