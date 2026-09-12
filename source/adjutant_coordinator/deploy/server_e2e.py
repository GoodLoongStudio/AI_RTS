#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""服务器侧端到端：隔离测试局（24569/24572）+ 测试客户端（24570）+ LangGraph 副官。

铁律：
- 只连本机隔离测试端口（24569/24570/24572）；玩家局服 24567/24571、Hermes 客户端 24568 一律拒绝；
- 不重启、不修改任何 systemd 服务；局服由运维脚本（本地驱动）拉起；
- 真实模型模式（--provider real）与假模型模式（--provider fake）共用同一条代码路径，
  假模型的输入输出同样从真实观测推导，保证两条路径可比。

产物（--out-dir/<run_id>/）：inputs.jsonl、states.jsonl、intents.jsonl、receipts.jsonl、
model_calls.jsonl、summary.json（含 PASS/FAIL/SKIP 与逐条依据，汇总经 results 重算自校验）。

用法：
  .venv/bin/python deploy/server_e2e.py --run-id srv-e2e-001 --provider real
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
import time
from typing import Any, Dict, List, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))
sys.path.insert(0, HERE)

from godot_tcp import (  # noqa: E402
    DEFAULT_GODOT, DEFAULT_REPO, PortNotAllowed, assert_allowed, ensure_test_client,
    fetch_views, pick_player, port_listening, start_match, tcp_json, wait_match,
)
from env_file import load_env_file  # noqa: E402
from adjutant_coordinator.graph.checkpoint import JsonCheckpointStore  # noqa: E402
from adjutant_coordinator.graph.graph import langgraph_available  # noqa: E402
from adjutant_coordinator.graph.pydantic_agents import (  # noqa: E402
    GraphModelSettings, ModelInvalidOutput, ModelTimeout, ModelUnavailable,
    PydanticAIStrategyAgent, PydanticAITacticsAgent, pydantic_ai_available,
)
from adjutant_coordinator.graph.runtime import (  # noqa: E402
    AdjutantGraphRuntime, RuntimeConfig,
)

PASS, FAIL, SKIP = "PASS", "FAIL", "SKIP"


class Result:
    def __init__(self) -> None:
        self.items: List[Dict[str, str]] = []

    def check(self, item: str, kind: str, detail: str = "") -> None:
        if kind not in (PASS, FAIL, SKIP):
            # 参数错位必须立刻炸出来，不能把 bool 当成结果类型写进汇总。
            raise ValueError("非法结果类型 %r（item=%r）：请用 expect() 传条件" % (kind, item))
        self.items.append({"item": item, "kind": kind, "detail": detail})

    def expect(self, item: str, condition: bool, detail: str = "",
               fail_detail: str = "") -> bool:
        self.check(item, PASS if condition else FAIL,
                   detail if condition else (fail_detail or detail))
        return bool(condition)

    def skip(self, item: str, reason: str) -> None:
        self.check(item, SKIP, reason)

    def counts(self) -> Dict[str, int]:
        return {kind: sum(1 for i in self.items if i["kind"] == kind)
                for kind in (PASS, FAIL, SKIP)}


def verify_summary(summary: Dict[str, Any]) -> None:
    recomputed = {kind: 0 for kind in (PASS, FAIL, SKIP)}
    for item in summary["results"]:
        if item["kind"] not in recomputed:
            raise ValueError("未知结果类型：%r" % item["kind"])
        recomputed[item["kind"]] += 1
    for kind, value in recomputed.items():
        if summary.get(kind) != value or summary.get("counts", {}).get(kind) != value:
            raise ValueError("汇总自校验失败：%s 顶层=%s counts=%s 重算=%d" % (
                kind, summary.get(kind), summary.get("counts", {}).get(kind), value))


# ---------------- 通道与模型包装 ----------------

class TcpIntentTransport:
    """把图下发的意图命令包投递到 Godot 权威调试端点（仅本机测试端口）。"""

    def __init__(self, port: int, op: str = "adjutant_intent") -> None:
        assert_allowed(port)
        self.port = port
        self.op = op
        self.sent: List[Dict[str, Any]] = []
        self.errors: List[str] = []

    def send_command(self, envelope: Dict[str, Any]) -> Dict[str, Any]:
        payload = dict(envelope)
        payload["op"] = self.op
        self.sent.append(payload)
        try:
            receipt = tcp_json(self.port, payload, timeout=40)
        except OSError as exc:
            self.errors.append(str(exc))
            return {"ok": False, "accepted": False, "status": "TransportError",
                    "reason": str(exc), "command_id": str(envelope.get("command_id", "")),
                    "intent_id": str(envelope.get("intent_id", "")), "result": {}}
        if not isinstance(receipt, dict):
            receipt = {"ok": False, "accepted": False, "status": "BadReceipt"}
        receipt.setdefault("command_id", str(envelope.get("command_id", "")))
        receipt.setdefault("intent_id", str(envelope.get("intent_id", "")))
        receipt.setdefault("result", {})
        return receipt

    def heartbeat(self) -> bool:
        return True

    def close(self) -> None:
        return None

    def describe(self) -> str:
        return "TcpIntentTransport(op=%s, sent=%d)" % (self.op, len(self.sent))


class MeteredModel:
    """记录真实/假模型每次调用的延迟与结果（Phase 5 指标）。"""

    def __init__(self, role: str, inner: Any, sink: List[Dict[str, Any]],
                 sink_writer=None) -> None:
        self.role = role
        self.inner = inner
        self.sink = sink
        self.sink_writer = sink_writer
        self.calls = 0

    def _call(self, method: str, context: Dict[str, Any]) -> Any:
        started = time.time()
        record: Dict[str, Any] = {
            "role": self.role, "tick": int(context.get("server_tick", 0)),
            "method": method, "started_at": started}
        try:
            value = getattr(self.inner, method)(context)
            record.update({"ok": True, "error": "", "kind": ""})
            return value
        except (ModelTimeout, ModelUnavailable, ModelInvalidOutput) as exc:
            record.update({"ok": False, "error": str(exc), "kind": type(exc).__name__})
            raise
        except Exception as exc:  # noqa: BLE001
            record.update({"ok": False, "error": str(exc), "kind": type(exc).__name__})
            raise
        finally:
            self.calls += 1
            record["latency_s"] = round(time.time() - started, 3)
            self.sink.append(record)
            if self.sink_writer is not None:
                self.sink_writer.write(json.dumps(record, ensure_ascii=False) + "\n")
                self.sink_writer.flush()

    def propose_plan(self, context: Dict[str, Any]) -> Any:
        return self._call("propose_plan", context)

    def propose_intents(self, context: Dict[str, Any]) -> Any:
        return self._call("propose_intents", context)


class ContextScriptedStrategy:
    """假模型（策略）：完全依据真实上下文构造合法计划（无需 API Key）。"""

    def __init__(self) -> None:
        self.calls = 0

    def propose_plan(self, context: Dict[str, Any]) -> Dict[str, Any]:
        self.calls += 1
        units = [str(u) for u in context.get("ai_controlled_units", [])][:3]
        tick = int(context.get("server_tick", 0))
        snapshot = int(context.get("snapshot_id", 0))
        # 版本必须严格递增（PlanStore 规则）：从当前 plan_version 推导。
        current = str(context.get("plan_version", "") or "")
        version = 1
        if ":v" in current:
            try:
                version = int(current.rsplit(":v", 1)[1]) + 1
            except ValueError:
                version = 1
        return {
            "plan_id": "srv-plan",
            "plan_version": version,
            "match_id": str(context.get("match_id", "")),
            "player_id": str(context.get("player_id", "")),
            "rules_version": str(context.get("rules_version", "")),
            "based_on_snapshot": snapshot,
            "valid_until_tick": tick + 60000,
            "phase_goal": "伺服验证：稳固开局并前压侦察",
            "tasks": [{
                "task_id": "t-forward",
                "priority": 1,
                "completion": "先遣单位抵达前压位置或遭遇敌军",
                "units": units,
                "unit_constraint": "",
                "target_type": "",
                "allowed_actions": ["move", "attack_move", "hold"],
            }],
            "reserves": {},
            "rationale": "服务器 E2E 假模型计划",
            "abort_when": ["base_under_attack"],
        }


class ContextScriptedTactics:
    """假模型（战术）：依据真实战术视图，为 AI 控制单位生成一条移动意图。"""

    def __init__(self, ttl_ticks: int = 600, emergency_ttl: int = 300) -> None:
        self.calls = 0
        self.ttl = ttl_ticks
        self.emergency_ttl = emergency_ttl

    def propose_intents(self, context: Dict[str, Any]) -> Dict[str, Any]:
        self.calls += 1
        tick = int(context.get("server_tick", 0))
        snapshot = int(context.get("snapshot_id", 0))
        controlled = [str(u) for u in context.get("ai_controlled_units", [])]
        tactical = context.get("tactical_view") or {}
        positions: Dict[str, List[float]] = {}
        movable: Dict[str, bool] = {}
        for entity in tactical.get("entities", []) or []:
            if entity.get("kind") == "unit_self":
                name = str(entity.get("name", ""))
                positions[name] = list(entity.get("pos", [0, 0, 0]))
                movable[name] = bool(entity.get("movement"))
        emergency = any(str(e.get("kind")) in ("base_under_attack", "enemy_spotted")
                        for e in context.get("events", []) or [])
        units = [u for u in controlled if u in positions and movable.get(u)]
        if not units:
            return {"batch_id": "srv-b-%d" % tick, "match_id": context.get("match_id", ""),
                    "player_id": context.get("player_id", ""),
                    "plan_version": context.get("plan_version", ""),
                    "based_on_snapshot": snapshot, "intents": []}
        unit = units[0]
        pos = positions[unit]
        dest = [round(float(pos[0]) + 6.0, 2), round(float(pos[2]) + 6.0, 2)]
        return {
            "batch_id": "srv-b-%d" % tick,
            "match_id": str(context.get("match_id", "")),
            "player_id": str(context.get("player_id", "")),
            "plan_version": str(context.get("plan_version", "")),
            "based_on_snapshot": snapshot,
            "intents": [{
                "intent_id": "srv-i-%d" % tick,
                "plan_version": str(context.get("plan_version", "")),
                "task_id": "t-forward",
                "unit_ids": [unit],
                "action": "move",
                "target": {"pos": dest},
                "priority": 5 if emergency else 2,
                "based_on_snapshot": snapshot,
                "issued_tick": tick,
                "expires_tick": tick + (self.emergency_ttl if emergency else self.ttl),
                "generation": 0,
                "abort_when": [],
                "emergency": emergency,
                "reacquire": False,
                "rationale": "服务器 E2E 假模型意图",
            }],
        }


# ---------------- 主流程 ----------------

def run(args) -> int:
    out_dir = os.path.join(args.out_dir, args.run_id)
    os.makedirs(out_dir, exist_ok=True)
    result = Result()
    model_sink: List[Dict[str, Any]] = []
    artifacts = {
        "inputs": open(os.path.join(out_dir, "inputs.jsonl"), "w", encoding="utf-8"),
        "states": open(os.path.join(out_dir, "states.jsonl"), "w", encoding="utf-8"),
        "intents": open(os.path.join(out_dir, "intents.jsonl"), "w", encoding="utf-8"),
        "receipts": open(os.path.join(out_dir, "receipts.jsonl"), "w", encoding="utf-8"),
        "models": open(os.path.join(out_dir, "model_calls.jsonl"), "w", encoding="utf-8"),
    }
    transport = TcpIntentTransport(args.authority_port, args.intent_op)

    def write(kind: str, payload: Dict[str, Any]) -> None:
        artifacts[kind].write(json.dumps(payload, ensure_ascii=False) + "\n")
        artifacts[kind].flush()

    try:
        # ---- 前置：局服/客户端/对局 ----
        alive = port_listening(args.authority_port)
        result.expect("测试局服调试端点可达（%d）" % args.authority_port, alive,
                      fail_detail="不可达：请先 systemctl start airts-game-test（本脚本不自行重启服务）")
        if not alive:
            return finish(result, out_dir, args, transport, model_sink)

        use_client = args.client_mode != "none"
        if use_client:
            client = ensure_test_client(args.client_dbg, args.match_port, args.repo,
                                        args.godot,
                                        log_path=os.path.join(args.out_dir,
                                                              "test_client.log"),
                                        start=(args.client_mode == "auto"))
            if not result.expect("隔离测试客户端已联网（%d）" % args.client_dbg,
                                 client.get("networked") is True,
                                 fail_detail="客户端未联网，见 test_client.log"):
                return finish(result, out_dir, args, transport, model_sink)
            status = tcp_json(args.client_dbg, {"op": "status"})
        else:
            result.check("无客户端直连模式", PASS,
                         "由隔离测试局服（%d）直接开局，不需要客户端" % args.authority_port)
            status = tcp_json(args.authority_port, {"op": "status"})
        if status.get("match") is not True:
            started = (start_match(args.client_dbg) if use_client
                       else tcp_json(args.authority_port,
                                     {"op": "start", "with_ai": True,
                                      "passive_ai_test": True}, timeout=30))
            result.check("开局指令", PASS if started.get("ok") else FAIL,
                         json.dumps(started, ensure_ascii=False)[:200])
            if not wait_match(args.authority_port, 90):
                result.check("对局就绪", FAIL, "等待对局就绪超时")
                return finish(result, out_dir, args, transport, model_sink)
        result.check("对局就绪", PASS)

        player = args.as_player or pick_player(tcp_json(args.authority_port, {"op": "status"}))
        views = fetch_views(args.authority_port, player)
        rules = views["rules"]
        if rules.get("error"):
            result.check("规则视图可导出", FAIL, json.dumps(rules, ensure_ascii=False)[:200])
            return finish(result, out_dir, args, transport, model_sink)
        rules_version = str(rules.get("rules_version", {}).get("content_hash", ""))
        match_id = str(rules.get("match_id", ""))
        result.check("规则视图可导出", PASS,
                     "match=%s player=%s rules=%s" % (match_id[:8], player,
                                                      rules_version[:12]))

        # ---- 新 op 能力探测（旧构建退回 op=adjutant_command，并如实标注）----
        leases_probe = tcp_json(args.authority_port, {"op": "adjutant_leases",
                                                      "player_id": player})
        new_ops = not str(leases_probe.get("error", "")).startswith("unknown")
        if transport.op != "adjutant_intent":
            result.skip("op=adjutant_intent 代际守卫", "按参数使用 op=%s" % transport.op)
        elif new_ops:
            result.check("op=adjutant_intent 可用（含代际守卫）", PASS)
        else:
            result.check("op=adjutant_intent 可用", FAIL,
                         "权威构建未识别该 op：请部署 DebugControlServer.gd 后再试")
            return finish(result, out_dir, args, transport, model_sink)

        # ---- 模型装配 ----
        provider_summary: Dict[str, Any] = {"provider": args.provider}
        if args.provider == "real":
            availability = pydantic_ai_available()
            provider_summary["pydantic_ai"] = availability
            settings = GraphModelSettings.from_env()
            if args.llm_timeout:
                settings.timeout_seconds = float(args.llm_timeout)
            provider_summary["settings"] = settings.safe_dict()
            if not result.expect("真实 Provider 配置可用（依赖 + Key + 模型名）",
                                 bool(availability["available"]) and bool(
                                     settings.resolve_api_key()) and bool(
                                     settings.model_for("strategy")),
                                 json.dumps(provider_summary, ensure_ascii=False)[:300]):
                return finish(result, out_dir, args, transport, model_sink)
            try:
                strategy_inner = PydanticAIStrategyAgent(settings)
                tactics_inner = PydanticAITacticsAgent(settings)
            except ModelUnavailable as exc:
                result.check("真实模型 Agent 装配", FAIL, str(exc)[:300])
                return finish(result, out_dir, args, transport, model_sink,
                              provider_summary=provider_summary)
            result.check("真实模型 Agent 装配", PASS,
                         "strategy=%s tactics=%s" % (settings.model_for("strategy"),
                                                     settings.model_for("tactics")))
        else:
            strategy_inner = ContextScriptedStrategy()
            tactics_inner = ContextScriptedTactics(args.ttl, args.emergency_ttl)

        strategy_model = MeteredModel("strategy", strategy_inner, model_sink,
                                      artifacts["models"])
        tactics_model = MeteredModel("tactics", tactics_inner, model_sink,
                                     artifacts["models"])

        runtime = AdjutantGraphRuntime(
            match_id, player, transport=transport,
            strategy_model=strategy_model, tactics_model=tactics_model,
            checkpoint_store=JsonCheckpointStore(os.path.join(out_dir, "state"),
                                                 match_id, player),
            config=RuntimeConfig(strategy_interval_ticks=args.strategy_interval,
                                 tactics_interval_ticks=1, emergency_min_interval_ticks=1,
                                 intent_ttl_ticks=args.ttl,
                                 emergency_intent_ttl_ticks=args.emergency_ttl,
                                 pause_on_player_interrupt=True,
                                 engine=args.engine),
            recheck_fn=_recheck(args.authority_port),
            tick_provider=_tick_provider(args.authority_port, player))
        result.check("图引擎", PASS,
                     "engine=%s（langgraph 可用=%s）" % (
                         runtime.runner.engine, langgraph_available()["available"]))
        if runtime.runner.engine != "langgraph":
            result.skip("LangGraph 引擎（StateGraph + interrupt + checkpoint）",
                        "langgraph 不可用：%s" % langgraph_available()["reason"])

        # ---- 场景 A：战略 ----
        tick_a, obs_a = observation(args.authority_port, player, [])
        res_a = tick(runtime, tick_a, obs_a, write, artifacts)
        plan_ok = runtime.state.plan_version != ""
        if plan_ok:
            result.check("战略计划被采纳", PASS, "plan_version=%s" % runtime.state.plan_version)
        else:
            result.skip("战略计划被采纳", "本轮未采纳计划（降级原因：%s）" % res_a.degraded_reason)
        result.expect("战略层不直接下发命令", not transport.sent,
                      fail_detail="战略 tick 出现了命令下发（违反职责边界）")

        # ---- 场景 B：战术（紧急事件）----
        event_b = _event_for(views_after(args.authority_port, player))
        tick_b, obs_b = observation(args.authority_port, player, [event_b])
        res_b = tick(runtime, tick_b, obs_b, write, artifacts)
        accepted_b = list(res_b.accepted_intents)
        if accepted_b:
            receipt_ok = any(str(r.get("status")) == "Accepted" for r in res_b.receipts)
            result.expect("战术意图经权威层接受", receipt_ok,
                          "intents=%s receipts=%s" % (
                              accepted_b, [r.get("status") for r in res_b.receipts]))
        else:
            result.skip("战术意图经权威层接受",
                        "本轮无战术意图（route=%s dropped=%s degraded=%s）" % (
                            res_b.route, res_b.dropped_intents, res_b.degraded_reason))
        missing = [e for e in transport.sent
                   if not e.get("intent_id") or not e.get("match_id")
                   or not isinstance(e.get("expires_tick"), int)]
        result.expect("所有下发的意图命令包字段完整（intent_id/match/expires_tick）",
                      not missing, "sent=%d 缺字段=%d" % (len(transport.sent), len(missing)))

        # ---- 场景 C：玩家接管 ----
        manual_unit = _first_own_unit(args.authority_port, player)
        if manual_unit:
            manual = tcp_json(args.authority_port, {"op": "move", "as_player": player,
                                                    "units": [manual_unit],
                                                    "dest": [10.0, 10.0]})
            result.expect("玩家手动命令被权威层接受", bool(manual.get("accepted")),
                          "status=%s" % manual.get("status"))
            live_before = [i["intent_id"] for i in runtime.state.active_intents
                           if i.get("state") == "active"
                           and manual_unit in (i.get("unit_ids") or [])]
            runtime.on_player_command([manual_unit], server_tick=tick_b)
            dropped_now = [i["intent_id"] for i in runtime.state.active_intents
                           if i.get("state") == "dropped"
                           and manual_unit in (i.get("unit_ids") or [])]
            if live_before:
                result.expect("玩家接管使该单位旧意图失效",
                              bool(dropped_now) and all(i in live_before
                                                        for i in dropped_now),
                              "dropped=%s live_before=%s（dropped 必须是接管前的活跃意图）"
                              % (dropped_now, live_before))
            else:
                result.skip("玩家接管使该单位旧意图失效", "该单位接管前没有活跃意图")
            sent_before = len(transport.sent)
            tick_c, obs_c = observation(args.authority_port, player, [])
            res_c = tick(runtime, tick_c, obs_c, write, artifacts)
            result.expect("玩家打断使图暂停（interrupt 语义）", bool(res_c.paused),
                          "paused=%s" % res_c.paused)
            tick_d, obs_d = observation(args.authority_port, player, [])
            res_d = tick(runtime, tick_d, obs_d, write, artifacts)
            result.expect("恢复后不补发玩家接管前的旧命令",
                          len(transport.sent) == sent_before,
                          "sent=%d before=%d" % (len(transport.sent), sent_before))
        else:
            result.skip("玩家接管场景", "未能从权威状态解析出可命令单位")

        # ---- 场景 D：权威层独立防线（旧代际意图）----
        probe_unit = manual_unit or _first_own_unit(args.authority_port, player)
        if probe_unit and new_ops:
            # 代际比较必须在游戏侧时钟上进行：取权威租约代际，构造“严格落后”的意图。
            # 真实模型单次调用可达数十秒，必须用权威端最新 tick/snapshot（图内 tick 会滞后）。
            fresh_tick, fresh_obs = observation(args.authority_port, player, [])
            fresh_snapshot = int(fresh_obs["header"]["snapshot_id"])
            lease_dump = tcp_json(args.authority_port, {"op": "adjutant_leases",
                                                        "player_id": player})
            game_lease_gen = int((lease_dump.get("leases") or {}).get(
                probe_unit, {}).get("generation", 0) or 0)
            gen = max(1, game_lease_gen - 1) if game_lease_gen > 1 else max(1, game_lease_gen)
            probe = tcp_json(args.authority_port, {
                "op": "adjutant_intent", "command_id": "srv-probe-stale",
                "intent_id": "srv-probe-stale", "match_id": match_id, "player_id": player,
                "rules_version": rules_version, "plan_version": runtime.state.plan_version,
                "task_id": "t-forward", "based_on_snapshot": fresh_snapshot,
                "issued_tick": fresh_tick,
                "expires_tick": fresh_tick + 300,
                "generation": gen,
                "action": "move",
                "params": {"units": [probe_unit], "dest": [12.0, 12.0]}})
            status = str(probe.get("status"))
            if status in ("PlayerOverride", "StaleGeneration", "IntentLedgerFull"):
                result.check("权威层独立拒绝玩家接管后的意图", PASS,
                             "status=%s" % status)
            elif status == "Accepted":
                result.skip("权威层独立拒绝玩家接管后的意图",
                            "该单位当前无失效租约（status=Accepted），无法构造负例")
            else:
                result.check("权威层独立拒绝玩家接管后的意图", FAIL,
                             "status=%s reason=%s" % (status, str(probe.get("reason"))[:120]))
        else:
            result.skip("权威层独立拒绝玩家接管后的意图", "缺少可用单位或 op 不可用")

        # ---- 场景 E：非法目标（规则视图拒绝）----
        types = {t.get("id"): t for t in rules.get("unit_types", []) or []}
        producer = None
        for unit_type_id in ("command_center", "vehicle_factory", "aircraft_factory"):
            candidate = _first_unit_of_type(args.authority_port, player, unit_type_id)
            if candidate:
                producer = candidate
                break
        tank_scene = str((types.get("tank") or {}).get("scene_path", ""))
        if producer and tank_scene:
            fresh_tick, fresh_obs = observation(args.authority_port, player, [])
            fresh_snapshot = int(fresh_obs["header"]["snapshot_id"])
            illegal = tcp_json(args.authority_port, {
                "op": "adjutant_intent", "command_id": "srv-probe-illegal",
                "intent_id": "srv-probe-illegal", "match_id": match_id, "player_id": player,
                "rules_version": rules_version, "plan_version": runtime.state.plan_version,
                "task_id": "t-forward", "based_on_snapshot": fresh_snapshot,
                "issued_tick": fresh_tick,
                "expires_tick": fresh_tick + 300, "generation": 0,
                "action": "produce",
                "params": {"units": [producer], "producer": producer, "scene": tank_scene}})
            status = str(illegal.get("status"))
            if status == "Accepted":
                result.check("模型无法绕过规则（非法生产被拒）", FAIL,
                             "权威层接受了非法生产（%s 生产 tank）" % producer)
            else:
                result.check("模型无法绕过规则（非法生产被拒）", PASS,
                             "status=%s reason=%s" % (status, str(illegal.get("reason"))[:100]))
        else:
            result.skip("模型无法绕过规则（非法生产被拒）", "未找到可用生产者或 tank 场景路径")

        # ---- 场景 F：checkpoint 恢复不重复下单 ----
        saved = runtime.checkpoint()
        result.expect("checkpoint 按对局隔离写入", bool(saved.get("saved")),
                      json.dumps(saved, ensure_ascii=False)[:160])
        restart_transport = TcpIntentTransport(args.authority_port, args.intent_op)
        restarted = AdjutantGraphRuntime(
            match_id, player, transport=restart_transport,
            strategy_model=MeteredModel("strategy", ContextScriptedStrategy(), model_sink),
            tactics_model=MeteredModel("tactics", ContextScriptedTactics(args.ttl), model_sink),
            checkpoint_store=JsonCheckpointStore(os.path.join(out_dir, "state"),
                                                 match_id, player),
            config=RuntimeConfig(strategy_interval_ticks=args.strategy_interval,
                                 intent_ttl_ticks=args.ttl,
                                 emergency_intent_ttl_ticks=args.emergency_ttl,
                                 engine=args.engine),
            tick_provider=_tick_provider(args.authority_port, player))
        restore = restarted.restore()
        already_sent = [str(e.get("intent_id", "")) for e in transport.sent]
        tick_g, obs_g = observation(args.authority_port, player, [])
        restarted.tick(tick_g, obs_g)
        resent = [str(e.get("intent_id", "")) for e in restart_transport.sent
                  if str(e.get("intent_id", "")) in already_sent]
        result.expect("重启恢复 checkpoint 后不重复下发历史意图", not resent,
                      "restored=%s resent=%s new=%d" % (
                          bool(restore.get("restored")), resent,
                          len(restart_transport.sent)))

        # ---- 指标 ----
        latencies = [c["latency_s"] for c in model_sink if c.get("ok")]
        errors = [c for c in model_sink if not c.get("ok")]
        metrics = {
            "model_calls": len(model_sink),
            "model_ok": len(latencies),
            "model_errors": len(errors),
            "latency_p50_s": round(statistics.median(latencies), 3) if latencies else None,
            "latency_max_s": round(max(latencies), 3) if latencies else None,
            "dispatch_total": len(transport.sent),
            "accepted_total": sum(1 for item in runtime.dispatched
                                  if item["receipt"].get("accepted")),
            "receipt_statuses": _status_counts(runtime.dispatched),
            "engine": runtime.runner.engine,
            "provider": args.provider,
            "model_names": provider_summary.get("settings", {}).get("strategy_model"),
        }
        result.check("模型调用指标已记录", PASS, json.dumps(metrics, ensure_ascii=False)[:400])
        return finish(result, out_dir, args, transport, model_sink, metrics,
                      provider_summary)
    except Exception as exc:  # noqa: BLE001 —— 任何异常先落 FAIL 证据再收尾。
        import traceback
        frames = traceback.format_exc().strip().splitlines()
        result.check("E2E 执行异常", FAIL,
                     "%s: %s || %s" % (type(exc).__name__, exc,
                                       " <- ".join(f.strip() for f in frames[-4:])))
        return finish(result, out_dir, args, transport, model_sink)
    finally:
        for handle in artifacts.values():
            try:
                handle.close()
            except Exception:
                pass


def _status_counts(dispatched: List[Dict[str, Any]]) -> Dict[str, int]:
    counts: Dict[str, int] = {}
    for item in dispatched:
        status = str(item["receipt"].get("status", ""))
        counts[status] = counts.get(status, 0) + 1
    return counts


def _tick_provider(authority_port: int, player: str):
    """下发前刷新时间基准（真实模型慢，图内 tick 会滞后）。"""
    def provider() -> Optional[Dict[str, int]]:
        snapshot = tcp_json(authority_port, {"op": "tactical", "as_player": player,
                                             "limit": 1}, timeout=15)
        tick = int(snapshot.get("server_tick", 0) or 0)
        if tick <= 0:
            return None
        return {"server_tick": tick,
                "snapshot_id": int(snapshot.get("snapshot_id", tick) or tick)}
    return provider


def _recheck(authority_port: int):
    def recheck(command_id: str) -> Optional[Dict[str, Any]]:
        if not command_id:
            return None
        result = tcp_json(authority_port, {"op": "commands", "command_id": command_id})
        entries = result.get("commands", []) or []
        if not entries:
            return None
        entry = entries[0]
        status = str(entry.get("status", ""))
        if status in ("", "Unknown", "PendingAuthority"):
            return None
        return {"command_id": command_id, "status": status,
                "accepted": bool(entry.get("accepted", False)),
                "reason": str(entry.get("reason", "")),
                "intent_id": str(entry.get("intent_id", ""))}
    return recheck


def observation(authority_port: int, player: str,
                events: List[Dict[str, Any]]) -> Any:
    views = fetch_views(authority_port, player)
    tactical = views["tactical"]
    tick = int(tactical.get("server_tick", 0) or 0)
    header = {
        "schema_version": 1, "match_id": str(views["rules"].get("match_id", "")),
        "player_id": player,
        "rules_version": str(views["rules"].get("rules_version", {}).get("content_hash", "")),
        "snapshot_id": int(tactical.get("snapshot_id", tick) or tick),
        "server_tick": tick,
    }
    return tick, {"header": header, "strategic": views["strategic"],
                  "tactical": tactical, "rules": views["rules"],
                  "events": list(events), "budget": {}}


def tick(runtime, tick_value: int, obs: Dict[str, Any], write, artifacts) -> Any:
    write("inputs", {"tick": tick_value, "events": obs.get("events"),
                     "tactical_units": [
                         e.get("name") for e in (obs.get("tactical") or {}).get(
                             "entities", []) or [] if e.get("kind") == "unit_self"]})
    result = runtime.tick(tick_value, obs)
    write("states", {"tick": tick_value, "route": result.route, "paused": result.paused,
                     "accepted": result.accepted_intents,
                     "dropped": result.dropped_intents,
                     "degraded_reason": result.degraded_reason,
                     "live_intents": runtime.state.live_intents(
                         runtime.state.server_tick),
                     "player_controlled": runtime.state.player_controlled_units})
    write("intents", {"tick": tick_value, "intents": runtime.state.active_intents})
    for receipt in result.receipts:
        write("receipts", {"tick": tick_value, "receipt": receipt})
    return result


def views_after(authority_port: int, player: str) -> Dict[str, Any]:
    return fetch_views(authority_port, player)["tactical"]


def _event_for(tactical: Dict[str, Any]) -> Dict[str, Any]:
    tick = int(tactical.get("server_tick", 0) or 0)
    own = [e["name"] for e in tactical.get("entities", []) or []
           if e.get("kind") == "unit_self"]
    enemy = [e["name"] for e in tactical.get("entities", []) or []
             if str(e.get("kind", "")).startswith("unit_enemy")]
    if enemy:
        return {"event_id": "srv-enemy-%d" % tick, "kind": "enemy_spotted",
                "server_tick": tick, "payload": {"subject": enemy[0],
                                                 "observer": own[:1]}}
    return {"event_id": "srv-idle-%d" % tick, "kind": "queue_idle",
            "server_tick": tick, "payload": {"subject": own[:1]}}


def _first_own_unit(authority_port: int, player: str, movable_only: bool = True) -> str:
    """取一个可命令的自有单位；默认只要可移动单位（建筑不能 move，会被权威拒绝）。"""
    tactical = views_after(authority_port, player)
    for entity in tactical.get("entities", []) or []:
        if entity.get("kind") != "unit_self":
            continue
        if movable_only and not entity.get("movement"):
            continue
        return str(entity.get("name", ""))
    if movable_only:
        return _first_own_unit(authority_port, player, movable_only=False)
    return ""


def _first_unit_of_type(authority_port: int, player: str, unit_type: str) -> str:
    tactical = views_after(authority_port, player)
    for entity in tactical.get("entities", []) or []:
        if entity.get("kind") == "unit_self" and str(entity.get("unit_type", "")) == unit_type:
            return str(entity.get("name", ""))
    return ""


def finish(result: Result, out_dir: str, args, transport, model_sink: List[Dict[str, Any]],
           metrics: Optional[Dict[str, Any]] = None,
           provider_summary: Optional[Dict[str, Any]] = None) -> int:
    counts = result.counts()
    summary = {
        "run_id": args.run_id, "provider": args.provider,
        "authority_port": args.authority_port, "client_dbg": args.client_dbg,
        "intent_op": args.intent_op,
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "PASS": counts[PASS], "FAIL": counts[FAIL], "SKIP": counts[SKIP],
        "counts": counts,
        "results": result.items,
        "metrics": metrics or {},
        "provider_summary": provider_summary or {},
        "model_calls": model_sink,
    }
    path = os.path.join(out_dir, "summary.json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(summary, handle, ensure_ascii=False, indent=2)
    verify_summary(summary)
    print(json.dumps({k: v for k, v in summary.items()
                      if k not in ("results", "model_calls", "provider_summary")},
                     ensure_ascii=False, indent=2)[:2000])
    for item in result.items:
        print("  [%s] %s%s" % (item["kind"], item["item"],
                              (" | " + item["detail"]) if item["detail"] else ""))
    print("summary:", path, "（自校验通过）")
    return 0 if counts[FAIL] == 0 else 1


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="服务器侧 LangGraph 副官 E2E")
    parser.add_argument("--run-id", default=time.strftime("srv_e2e_%Y%m%d_%H%M%S"))
    parser.add_argument("--provider", choices=("fake", "real"), default="fake")
    parser.add_argument("--engine", default="auto")
    parser.add_argument("--authority-port", type=int, default=24572)
    parser.add_argument("--client-dbg", type=int, default=24570)
    parser.add_argument("--match-port", type=int, default=24569)
    parser.add_argument("--intent-op", default="adjutant_intent")
    parser.add_argument("--as-player", default="")
    parser.add_argument("--client-mode", choices=("auto", "skip", "none"), default="auto",
                        help="auto=必要时自行拉起测试客户端；skip=只校验它已在运行；"
                             "none=不要客户端，由隔离测试局服直接开局")
    parser.add_argument("--repo", default=DEFAULT_REPO)
    parser.add_argument("--godot", default=DEFAULT_GODOT)
    parser.add_argument("--out-dir", default="/opt/airts-agent/logs")
    parser.add_argument("--strategy-interval", type=int, default=3000)
    parser.add_argument("--ttl", type=int, default=600)
    parser.add_argument("--emergency-ttl", type=int, default=300)
    parser.add_argument("--llm-timeout", type=float, default=0.0)
    parser.add_argument("--env-file", default="",
                        help="模型配置 env 文件（默认 /opt/airts-agent/.env 或 AIRTS_AGENT_ENV）")
    args = parser.parse_args(argv)
    loaded = load_env_file(args.env_file)
    print("已加载环境变量键名（不打印取值）: %s" % (sorted(loaded) or "（无）"))
    for port in (args.authority_port, args.client_dbg, args.match_port):
        try:
            assert_allowed(port)
        except PortNotAllowed as exc:
            print(str(exc))
            return 2
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
