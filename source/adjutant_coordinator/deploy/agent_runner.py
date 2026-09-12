#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""常驻副官 runner：LangGraph 指挥主循环（Phase 7 接线）。

与隔离测试入口（`deploy/server_e2e.py`）的区别：
- **常驻循环**：按游戏 tick 节奏持续推进图，不是固定场景脚本；
- **连玩家局服权威端点**（默认 `127.0.0.1:24571`）；隔离测试端口默认拒绝（反向纪律，防误连）；
- **由 adjutant daemon 启停**：pidfile + SIGTERM 优雅退出；异常退出由 daemon 看门狗兜底。

职责边界（与 `langgraph-refactor.md` §7 一致）：
- LangGraph 负责 `dispatch_to_godot`（`op=adjutant_intent`）；
- Hermes 只承载对局记忆/复盘，**不进入本路径**。

节流（慢模型不阻塞循环）：
- 战略模型按 `strategy_interval_ticks` 触发、战术模型按 `tactics_interval_ticks` 触发；
- 模型超时/异常由图内降级（`ModelTimeout`/`ModelUnavailable`/`ModelInvalidOutput` → degraded），
  循环继续推进，不等待、不重试风暴。

用法（服务器）：
  cd /opt/airts-agent/app && ../.venv/bin/python -m adjutant_coordinator.deploy.agent_runner \
      --authority-port 24571 --provider real
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import socket
import sys
import time
from typing import Any, Dict, List, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))
sys.path.insert(0, HERE)

from env_file import load_env_file  # noqa: E402
from adjutant_coordinator.graph.checkpoint import JsonCheckpointStore  # noqa: E402
from adjutant_coordinator.graph.graph import langgraph_available  # noqa: E402
from adjutant_coordinator.graph.pydantic_agents import (  # noqa: E402
    GraphModelSettings, ModelInvalidOutput, ModelTimeout, ModelUnavailable,
    PydanticAIStrategyAgent, PydanticAITacticsAgent, PydanticAITaskPatchAgent,
    pydantic_ai_available,
)
from adjutant_coordinator.graph.runtime import (  # noqa: E402
    AdjutantGraphRuntime, RuntimeConfig,
)
from adjutant_coordinator.structured_log import (  # noqa: E402
    JsonlFileSink, StructuredLogger,
)

#: 玩家局服权威调试端点（生产路径）。
AUTHORITY_PORT = 24571
#: 隔离测试端口：常驻 runner 默认拒绝（防把生产副官指向测试局）。
TEST_PORTS = {24569, 24570, 24572}
#: 单次 TCP 请求默认超时（秒）。
DEFAULT_TCP_TIMEOUT = 30.0


class RunnerError(RuntimeError):
    """runner 装配/端口纪律错误（启动即失败，不带病运行）。"""


# ---------------- 端口纪律与 TCP ----------------

def assert_port_allowed(port: int, allow_other: bool) -> None:
    if port == AUTHORITY_PORT:
        return
    if port in TEST_PORTS and not allow_other:
        raise RunnerError(
            "拒绝：%d 是隔离测试端口；常驻 runner 只连玩家局服 %d"
            "（自测请显式加 --allow-other-port）。" % (port, AUTHORITY_PORT))
    if not allow_other:
        raise RunnerError("拒绝：%d 不是权威端口 %d（需 --allow-other-port 显式放行）。" % (
            port, AUTHORITY_PORT))


def tcp_json(port: int, payload: Dict[str, Any], timeout: float = DEFAULT_TCP_TIMEOUT) -> Dict[str, Any]:
    """与游戏调试端点同协议：一行 JSON 请求 → 一行 JSON 回包。

    注意：端点响应后不一定关闭连接，因此按"第一个 '{' 到其后第一个换行"截取。
    """
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        buffer = b""
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                chunk = sock.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                break
            buffer += chunk
            start = buffer.find(b"{")
            end = buffer.find(b"\n", start)
            if start >= 0 and end > start:
                line = buffer[start:end].decode("utf-8", errors="replace")
                try:
                    return json.loads(line)
                except ValueError:
                    return {"error": "non-json", "raw": line[:500]}
    return {"error": "timeout", "raw": buffer.decode("utf-8", "replace")[:500]}


def port_listening(port: int, timeout: float = 1.0) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=timeout):
            return True
    except OSError:
        return False


# ---------------- 观测 ----------------

def pick_human_player(port: int) -> str:
    """取对局中的真人玩家名（副官只指挥真人部队）。"""
    status = tcp_json(port, {"op": "status"})
    for player in status.get("players") or []:
        if player.get("human"):
            return str(player.get("name", ""))
    return ""


def match_active(port: int) -> bool:
    status = tcp_json(port, {"op": "status"})
    return bool(status.get("match"))


def own_unit_ids(tactical: Dict[str, Any]) -> List[str]:
    """战术视图里属于被指挥玩家的单位名（kind=unit_self）。"""
    return [str(entity.get("name")) for entity in (tactical or {}).get("entities", []) or []
            if entity.get("kind") == "unit_self" and entity.get("name")]


def fetch_views(port: int, player: str, rules_cache: Dict[str, Any]) -> Dict[str, Any]:
    rules = rules_cache.get("rules")
    if not rules:
        fetched = tcp_json(port, {"op": "rules"})
        if not fetched.get("error"):
            rules_cache["rules"] = fetched
            rules = fetched
    return {
        "rules": rules or {},
        "strategic": tcp_json(port, {"op": "strategic", "as_player": player}),
        "tactical": tcp_json(port, {"op": "tactical", "as_player": player}),
    }


# ---------------- 通道 ----------------

class AuthorityIntentTransport:
    """把图下发的意图命令包投递到玩家局服权威端点（`op=adjutant_intent`）。

    关键换算：图内控制代际（`unit_generations`）与游戏侧租约代际是**两套独立计数器**
    （见 `e2e_langgraph.py` 的说明：两个计数器各自独立递增，不能直接比较绝对数值）。
    权威端 `op=adjutant_intent` 按**游戏侧**数值校验，所以提交前必须把意图代际换成
    受令单位的权威租约代际，否则合法意图会被判 `StaleGeneration` 永远下发不出去
    （实测：`i_worker_produce` 因此一直造不出兵）。
    """

    def __init__(self, port: int, op: str = "adjutant_intent",
                 timeout: float = 45.0, lease_ttl_s: float = 5.0) -> None:
        self.port = port
        self.op = op
        self.timeout = timeout
        self.lease_ttl_s = lease_ttl_s
        self.sent_count = 0
        self.errors: List[str] = []
        self.lease_translated = 0
        self._lease_cache: Dict[str, int] = {}
        self._lease_cache_player = ""
        self._lease_cache_at = 0.0

    def _lease_generations(self, player_id: str) -> Dict[str, int]:
        """读权威租约代际（按 player 缓存数秒，避免每个意图都多一次往返）。"""
        now = time.time()
        if (self._lease_cache_player == player_id
                and now - self._lease_cache_at < self.lease_ttl_s):
            return self._lease_cache
        data = tcp_json(self.port, {"op": "adjutant_leases", "player_id": player_id},
                        timeout=20.0)
        leases = (data or {}).get("leases") or {}
        self._lease_cache = {str(key): int((value or {}).get("generation", 0) or 0)
                             for key, value in leases.items()}
        self._lease_cache_player = player_id
        self._lease_cache_at = now
        return self._lease_cache

    def _translate_generation(self, payload: Dict[str, Any]) -> None:
        """已停用（2026-09-11 本地完整副官重构）。

        原实现会读最新租约、取**受令单位代际的最大值**并**在提交时覆盖** `generation`。
        新方案（`docs/plan/AI副官_本地完整副官重构方案_2026-09-11.md` §6）明确禁止：
        「代际以游戏权威端为准，**不能提交时换成最新代际**，也不能用**多个单位的最大代际
        代替逐对象校验**」，并要求检查该逻辑**是否使旧模型结果重新有效**——答案是**会**：
        它用"取最新"绕过了 `StaleGeneration`，等于拆掉过时结果保护。

        因此这里**不做任何代际改写**：意图必须携带**请求发起时绑定**的代际，
        逐对象由权威端校验；代际不匹配就该被拒，交由上层重取观测后重新决策。
        """
        return

    def send_command(self, envelope: Dict[str, Any]) -> Dict[str, Any]:
        payload = dict(envelope)
        payload["op"] = self.op
        # 注意：**不做**代际换算（见 _translate_generation 的停用说明）。
        self.sent_count += 1
        try:
            receipt = tcp_json(self.port, payload, timeout=self.timeout)
        except OSError as exc:
            self.errors.append(str(exc))
            self.errors = self.errors[-20:]
            return {"ok": False, "accepted": False, "status": "TransportError",
                    "reason": str(exc),
                    "command_id": str(envelope.get("command_id", "")),
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
        return "AuthorityIntentTransport(port=%d, op=%s, sent=%d)" % (
            self.port, self.op, self.sent_count)


class MeteredModel:
    """记录模型调用延迟与结果（慢模型调度节流的依据）。"""

    def __init__(self, role: str, inner: Any, sink: List[Dict[str, Any]]) -> None:
        self.role = role
        self.inner = inner
        self.sink = sink

    def _invoke(self, method: str, context: Dict[str, Any]) -> Any:
        started = time.time()
        record: Dict[str, Any] = {"role": self.role, "method": method,
                                  "tick": int(context.get("server_tick", 0) or 0),
                                  "started_at": started}
        try:
            value = getattr(self.inner, method)(context)
            record.update({"ok": True, "kind": "", "error": ""})
        except (ModelTimeout, ModelUnavailable, ModelInvalidOutput) as exc:
            record.update({"ok": False, "kind": type(exc).__name__, "error": str(exc)})
            self.sink.append(dict(record, latency_ms=int((time.time() - started) * 1000)))
            raise
        record["latency_ms"] = int((time.time() - started) * 1000)
        self.sink.append(record)
        return value

    def propose_plan(self, context: Dict[str, Any]) -> Any:  # pragma: no cover - 透传
        return self._invoke("propose_plan", context)

    def propose_intents(self, context: Dict[str, Any]) -> Any:  # pragma: no cover - 透传
        return self._invoke("propose_intents", context)

    # ---- 四列接口（设计 §2）：节点靠 `propose_task_patch` 的存在选择新路径 ----
    @property
    def mode(self) -> str:
        return str(getattr(self.inner, "mode", "fast"))

    @property
    def last_decode(self) -> Any:
        return getattr(self.inner, "last_decode", None)

    def propose_task_patch(self, frame: Any) -> Any:
        started = time.time()
        record: Dict[str, Any] = {"role": self.role, "method": "propose_task_patch",
                                  "tick": int(getattr(frame, "server_tick", 0) or 0),
                                  "started_at": started}
        try:
            value = self.inner.propose_task_patch(frame)
            record.update({"ok": True, "kind": "", "error": ""})
        except (ModelTimeout, ModelUnavailable, ModelInvalidOutput) as exc:
            record.update({"ok": False, "kind": type(exc).__name__, "error": str(exc)})
            self.sink.append(dict(record, latency_ms=int((time.time() - started) * 1000)))
            raise
        record["latency_ms"] = int((time.time() - started) * 1000)
        self.sink.append(record)
        return value


# ---------------- runner ----------------

class AgentRunner:
    """常驻循环：观测 → 图推进 → 下发 → 日志。"""

    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.port = int(args.authority_port)
        self.player = str(args.player or "")
        self.match_id = ""
        self.rules_version = ""
        self.runtime: Optional[AdjutantGraphRuntime] = None
        self.transport: Optional[AuthorityIntentTransport] = None
        self.rules_cache: Dict[str, Any] = {}
        self.model_sink: List[Dict[str, Any]] = []
        self._log_handle = None
        #: 图内结构化日志 sink（`ctx.services.log`）。**必须显式注入**，
        #: 否则 `GraphServices.logger` 为 None → 所有 `_log(...)` 打点静默丢弃。
        self.structured_logger: Optional[StructuredLogger] = None
        #: 已落盘的 decision_log tick（单调守卫，避免同一 tick 重复打印）。
        self._decision_logged_tick = 0
        self._stopping = False
        self._stop_reason = ""
        self._last_event_tick = 0

    # ---------- 装配 ----------

    def setup(self) -> None:
        assert_port_allowed(self.port, bool(self.args.allow_other_port))
        loaded = load_env_file(self.args.env_file)
        if loaded:
            print("[runner] 已从 .env 注入 %d 个键（不打印取值）" % len(loaded))
        deadline = time.time() + float(self.args.wait_port_seconds)
        while time.time() < deadline:
            if port_listening(self.port):
                break
            time.sleep(1.0)
        else:
            raise RunnerError("权威端点 %d 在 %.0fs 内未就绪。" % (self.port, self.args.wait_port_seconds))
        if not match_active(self.port):
            raise RunnerError("权威端点 %d 当前没有进行中的对局（match=false）。" % self.port)
        if not self.player:
            self.player = pick_human_player(self.port)
        if not self.player:
            raise RunnerError("对局中没有可指挥的真人玩家（players 里找不到 human=true）。")
        views = fetch_views(self.port, self.player, self.rules_cache)
        rules = views["rules"] or {}
        tactical = views["tactical"] or {}
        self.match_id = str(rules.get("match_id", "") or "")
        self.rules_version = str((rules.get("rules_version") or {}).get("content_hash", "") or "")
        if not self.match_id or not self.rules_version:
            raise RunnerError("无法取到 match_id / rules_version，拒绝启动（避免盲发命令）。")
        tick = int(tactical.get("server_tick", 0) or 0)
        # 恢复上次 checkpoint（同一 match/player 才认；在途请求保持 pending 不重复下单）。
        restore = {"restored": False, "reason": "not_attempted"}

        os.makedirs(self.args.state_dir, exist_ok=True)
        os.makedirs(self.args.log_dir, exist_ok=True)
        self._open_log()

        strategy_model, tactics_model = self._build_models()
        self.transport = AuthorityIntentTransport(self.port)
        # 有界异步调度（计划 §7.C）：模型调用在工作线程里跑，主循环不再被 1~15s 的
        # 推理阻塞；结果到达时按"本地接收期限 / 观测推进 / 逐对象代际"判定接受或拒绝。
        scheduler = self._build_scheduler(tactics_model)
        self.runtime = AdjutantGraphRuntime(
            self.match_id, self.player, transport=self.transport,
            strategy_model=strategy_model, tactics_model=tactics_model,
            tactics_scheduler=scheduler,
            checkpoint_store=JsonCheckpointStore(self.args.state_dir,
                                                self.match_id, self.player),
            logger=self.structured_logger,
            config=RuntimeConfig(
                strategy_interval_ticks=int(self.args.strategy_interval),
                tactics_interval_ticks=int(self.args.tactics_interval),
                emergency_min_interval_ticks=int(self.args.emergency_interval),
                intent_ttl_ticks=int(self.args.ttl),
                emergency_intent_ttl_ticks=int(self.args.emergency_ttl),
                # 每轮意图配额（原默认 8 太小，见 --max-batch 的说明）。
                max_batch=int(self.args.max_batch),
                pause_on_player_interrupt=True,
                engine=str(self.args.engine)),
            recheck_fn=self._recheck,
            tick_provider=self._tick_provider)
        restore = self.runtime.restore(expect_rules_version=self.rules_version)
        # 控制权交接（点"接管"= 玩家把部队交给副官）：只登记 AI 托管代际。
        # 注意**不能**用 release_units —— 它会把单位写进 released_units，而 node_ingest
        # 每轮用 `observed_own - player_controlled - released` 覆盖 ai_controlled_units，
        # 等于自己把单位踢出托管（2026-09-10 实测踩坑）。
        # 玩家手动命令仍由 player_override 正常夺回优先级，不需要我们主动 release。
        own_units = own_unit_ids(views["tactical"] or {})
        if own_units:
            # 点"接管"= 重新授权 AI 控制：清空"已归还"名单。否则 node_ingest 每轮用
            # `observed_own - player_controlled - released` 覆盖 ai_controlled_units，
            # 历史 released 单位会被持续剔除（实测踩坑，2026-09-10）。
            self.runtime.state.released_units = []
            self.runtime.state.ensure_units(own_units)
        handover = {"units": own_units, "reason": "adjutant_takeover"}
        describe = self.runtime.describe()
        self._log({
            "kind": "start", "match_id": self.match_id, "player": self.player,
            "rules_version": self.rules_version, "server_tick": tick,
            "engine": describe.get("engine"),
            "langgraph_available": describe.get("langgraph_available"),
            "provider": self.args.provider, "restore": restore,
            "config": describe.get("config"), "port": self.port,
            "handover": handover,
        })
        print("[runner] match=%s player=%s engine=%s restore=%s" % (
            self.match_id[:8], self.player, describe.get("engine"),
            json.dumps(restore, ensure_ascii=False)))
        if str(describe.get("engine")) != "langgraph":
            print("[runner] 警告：当前引擎不是 langgraph（%s）——检查依赖安装。"
                  % describe.get("engine"))

    def _build_scheduler(self, tactics_model):
        """按开关装配有界异步调度器；`sync` 表示保留旧的同步等待路径（回退用）。"""
        if str(self.args.scheduling) != "async":
            print("[runner] 调度=同步（legacy）：模型调用会阻塞主循环，仅用于对照/回退")
            return None
        if not hasattr(tactics_model, "propose_task_patch"):
            print("[runner] 调度=同步：当前接口不是四列（%s），无异步调度"
                  % self.args.interface)
            return None
        from adjutant_coordinator.graph.async_scheduler import build_scheduler_for_agent
        scheduler = build_scheduler_for_agent(
            tactics_model,
            hard_timeout_seconds=float(self.args.llm_timeout or 30.0))
        print("[runner] 调度=async：单一在途工作槽 + 观测合并 + 过期结果拒绝 + 单调时钟退避")
        return scheduler

    def _build_models(self):
        # 战略层默认关闭：计划 §6 阶段 A 允许"省略高层的单一模型决策入口，并在状态里标注
        # 高层意图缺省"。实测依据（2026-09-12）：战略模型在真实对局里 18 次
        # `ModelInvalidOutput: Exceeded maximum retries`，每次重试都是**同步阻塞**调用，
        # 把主循环拖到 4.7s/轮，并让战术决策结果来不及被取（全部 expired）。
        strategy_enabled = str(self.args.strategy_mode) == "plan"
        if not strategy_enabled:
            print("[runner] 战略层=off（四列单入口，高层意图缺省；--strategy-mode plan 可开）")
        if self.args.provider == "fake":
            try:
                from server_e2e import ContextScriptedStrategy, ContextScriptedTactics
            except ImportError as exc:  # pragma: no cover
                raise RunnerError("fake 模式需要同目录 server_e2e.py：%s" % exc)
            strategy_inner = (ContextScriptedStrategy() if strategy_enabled else None)
            tactics_inner = ContextScriptedTactics(int(self.args.ttl), int(self.args.emergency_ttl))
        else:
            availability = pydantic_ai_available()
            settings = GraphModelSettings.from_env()
            if self.args.llm_timeout:
                settings.timeout_seconds = float(self.args.llm_timeout)
            if not availability["available"]:
                raise RunnerError("pydantic-ai 不可用：%s" % availability["reason"])
            if not settings.resolve_api_key() or not settings.model_for("strategy"):
                raise RunnerError("真实 Provider 配置缺失（LLM_API_KEY / 模型名）。")
            try:
                strategy_inner = (PydanticAIStrategyAgent(settings)
                                  if strategy_enabled else None)
                if str(self.args.interface) == "four-col":
                    # 四列接口（默认）：单一决策入口，输出短任务修改。
                    tactics_inner = PydanticAITaskPatchAgent(
                        settings, mode=str(self.args.tactics_mode))
                else:
                    tactics_inner = PydanticAITacticsAgent(settings)
            except ModelUnavailable as exc:
                raise RunnerError("真实模型 Agent 装配失败：%s" % exc)
            print("[runner] 真实模型 strategy=%s tactics=%s(%s) timeout=%ss" % (
                settings.model_for("strategy"), settings.model_for("tactics"),
                self.args.interface, settings.timeout_seconds))
        # 关掉的层必须返回 **None**，不能包成"里层为 None 的空壳 MeteredModel"：
        # 实测（2026-09-12）空壳会让 `ctx.services.strategy_model is None` 判断失效，
        # 战略节点照样去调 propose_plan → 46 次 `'NoneType' object has no attribute
        # 'propose_plan'` 降级 → 冷却 → 战术节点被跳过 → 决策结果永远不落地（applied=0）。
        return (MeteredModel("strategy", strategy_inner, self.model_sink)
                if strategy_inner is not None else None,
                MeteredModel("tactics", tactics_inner, self.model_sink))

    # ---------- 下发前/复核钩子 ----------

    def _tick_provider(self) -> Optional[Dict[str, int]]:
        snapshot = tcp_json(self.port, {"op": "tactical", "as_player": self.player,
                                        "limit": 1}, timeout=15)
        tick = int(snapshot.get("server_tick", 0) or 0)
        if tick <= 0:
            return None
        return {"server_tick": tick,
                "snapshot_id": int(snapshot.get("snapshot_id", tick) or tick)}

    def _recheck(self, command_id: str) -> Optional[Dict[str, Any]]:
        if not command_id:
            return None
        result = tcp_json(self.port, {"op": "commands", "command_id": command_id})
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

    # ---------- 主循环 ----------

    def run(self) -> int:
        try:
            self.setup()
        except RunnerError as exc:
            print("[runner] 启动失败：%s" % exc, file=sys.stderr)
            self._log({"kind": "setup_failed", "error": str(exc)})
            self._close_log()
            return 3
        except Exception as exc:  # noqa: BLE001 —— 装配期异常统一留痕后退出
            print("[runner] 装配异常：%r" % exc, file=sys.stderr)
            self._log({"kind": "setup_error", "error": repr(exc)})
            self._close_log()
            return 3

        self._install_signal_handlers()
        self._write_pidfile()
        bad_ticks = 0
        idle_checks = 0
        exit_code = 0
        try:
            while not self._stopping:
                try:
                    tick_value, obs = self._observe()
                    self._sync_control(obs.get("tactical") or {})
                    started = time.time()
                    result = self.runtime.tick(tick_value, obs)
                    elapsed_ms = int((time.time() - started) * 1000)
                    bad_ticks = 0
                    self._log({
                        "kind": "tick", "server_tick": tick_value, "elapsed_ms": elapsed_ms,
                        "route": result.route, "paused": bool(getattr(result, "paused", False)),
                        "accepted": list(result.accepted_intents),
                        "dropped": list(result.dropped_intents),
                        "degraded_reason": result.degraded_reason,
                        "live_intents": self.runtime.state.live_intents(
                            self.runtime.state.server_tick),
                        "model_calls": len(self.model_sink),
                        "sent": self.transport.sent_count,
                    })
                    self._log_decision_delta(tick_value)
                    # 游戏内面板的"思考"内容：由 runner 直接给结论，HUD 只渲染。
                    self._log_hud_status(tick_value, result)
                    for receipt in result.receipts:
                        self._log({"kind": "receipt", "server_tick": tick_value,
                                   "receipt": receipt})
                except Exception as exc:  # noqa: BLE001 —— 单轮异常不终止常驻循环
                    bad_ticks += 1
                    self._log({"kind": "tick_error", "error": repr(exc),
                               "consecutive": bad_ticks, "stopping": self._stopping})
                    if bad_ticks >= int(self.args.bad_tick_limit):
                        self._log({"kind": "fatal", "error": repr(exc),
                                   "reason": "连续异常超过阈值"})
                        exit_code = 2
                        break
                if self._stopping:
                    break
                # 对局结束（或权威端点消失）→ 正常退出，交给 daemon 判定是否重启。
                if not match_active(self.port):
                    idle_checks += 1
                    self._log({"kind": "idle", "consecutive": idle_checks,
                               "note": "match_active=false"})
                    if idle_checks >= int(self.args.max_idle_checks):
                        self._log({"kind": "stop", "reason": "no_active_match"})
                        break
                else:
                    idle_checks = 0
                self._sleep(float(self.args.tick_interval))
        finally:
            try:
                if self.runtime is not None:
                    self.runtime.checkpoint()
            except Exception as exc:  # noqa: BLE001
                self._log({"kind": "checkpoint_error", "error": repr(exc)})
            self._remove_pidfile()
            self._log({"kind": "exit", "code": exit_code, "reason": self._stop_reason,
                       "sent": self.transport.sent_count if self.transport else 0,
                       "model_calls": len(self.model_sink)})
            self._close_log()
        return exit_code

    def _observe(self):
        views = fetch_views(self.port, self.player, self.rules_cache)
        tactical = views["tactical"] or {}
        tick = int(tactical.get("server_tick", 0) or 0)
        header = {
            "schema_version": 1,
            "match_id": self.match_id,
            "player_id": self.player,
            "rules_version": self.rules_version,
            "snapshot_id": int(tactical.get("snapshot_id", tick) or tick),
            "server_tick": tick,
        }
        return tick, {"header": header, "strategic": views["strategic"],
                      "tactical": tactical, "rules": views["rules"],
                      "events": self._events_for(tactical, tick), "budget": {}}


    def _events_for(self, tactical: Dict[str, Any], tick: int) -> List[Dict[str, Any]]:
        """派生观测事件。

        图的 `is_tactics_due` 要求 `pending_events` 非空才会走战术分支（出意图），
        因此常驻 runner 必须持续供事件；按 event-interval 节流避免事件堆积。
        """
        interval = int(self.args.event_interval)
        if interval > 0 and self._last_event_tick and tick - self._last_event_tick < interval:
            return []
        self._last_event_tick = tick
        own_units = own_unit_ids(tactical)
        enemies = [str(entity.get("name"))
                   for entity in (tactical or {}).get("entities", []) or []
                   if str(entity.get("kind", "")).startswith("unit_enemy")]
        if enemies:
            return [{"event_id": "runner-enemy-%d" % tick, "kind": "enemy_spotted",
                     "server_tick": tick,
                     "payload": {"subject": enemies[0], "observer": own_units[:1]}}]
        return [{"event_id": "runner-idle-%d" % tick, "kind": "queue_idle",
                 "server_tick": tick, "payload": {"subject": own_units[:1]}}]


    def _sync_control(self, tactical: Dict[str, Any]) -> None:
        """把新出现的己方单位登记到 AI 托管（不动已被玩家接管的单位）。"""
        if self.runtime is None:
            return
        own_units = own_unit_ids(tactical or {})
        if own_units:
            self.runtime.state.ensure_units(own_units)

    def _sleep(self, seconds: float) -> None:
        deadline = time.time() + max(0.0, seconds)
        while not self._stopping and time.time() < deadline:
            time.sleep(min(0.1, max(0.0, deadline - time.time())))

    # ---------- 生命周期 ----------

    def _install_signal_handlers(self) -> None:
        def handler(signum, _frame):
            self._stop_reason = "signal_%d" % signum
            self._stopping = True
        for sig in (signal.SIGTERM, signal.SIGINT):
            try:
                signal.signal(sig, handler)
            except (ValueError, OSError):  # pragma: no cover
                pass

    def _write_pidfile(self) -> None:
        if not self.args.pidfile:
            return
        try:
            with open(self.args.pidfile, "w", encoding="utf-8") as handle:
                handle.write(str(os.getpid()))
        except OSError as exc:
            self._log({"kind": "pidfile_error", "error": str(exc)})

    def _remove_pidfile(self) -> None:
        if not self.args.pidfile:
            return
        try:
            os.unlink(self.args.pidfile)
        except OSError:
            pass

    # ---------- 日志 ----------

    def _open_log(self) -> None:
        if self._log_handle is not None:
            return
        stamp = time.strftime("%Y%m%d_%H%M%S")
        name = "agent_runner_%s_%s.jsonl" % (stamp, (self.match_id or "nomatch")[:8])
        path = os.path.join(self.args.log_dir, name)
        try:
            self._log_handle = open(path, "a", encoding="utf-8")
            print("[runner] 日志：%s" % path)
        except OSError as exc:
            print("[runner] 日志文件不可写（仅 stdout）：%s" % exc, file=sys.stderr)
        self._open_structured_log(stamp)

    def _open_structured_log(self, stamp: str) -> None:
        """打开**图内结构化日志**（`ctx.services.log` 的 sink）。

        为什么必须显式注入（2026-09-11 排查到的最根本原因）：
        `nodes._log()` 走 `GraphServices.log` → `self.logger.log(...)`，而
        `GraphServices.logger` 缺省是 **None**，`log()` 第一行就 `return`。
        也就是说**此前所有 `_log(...)` 打点是一行都没写**（不是"落点不对"）。
        这正是"加了 micro_empty 打点却不出现在 runner.out"的答案：
        runner 从来没有创建过 logger，也没有把它传进 `AdjutantGraphRuntime`。
        """
        if self.structured_logger is not None:
            return
        name = "agent_runner_events_%s_%s.jsonl" % (
            stamp, (self.match_id or "nomatch")[:8])
        path = os.path.join(self.args.log_dir, name)
        try:
            self.structured_logger = StructuredLogger(
                JsonlFileSink(path),
                base={"match_id": self.match_id, "player_id": self.player,
                      "rules_version": self.rules_version})
            print("[runner] 结构日志：%s" % path)
        except OSError as exc:
            # 日志不可用不阻断指挥链，但必须显式告警：没有它就只能靠猜。
            print("[runner] 结构日志不可用（图内事件将不可见）：%s" % exc,
                  file=sys.stderr)
            self.structured_logger = None

    #: 动作 id → 中文（面板文案纪律：**只给玩家看中文、说人话**，不出现英文 id）。
    ACTION_CN = {
        "gather": "采集", "build": "建造", "produce": "生产", "attack": "交战",
        "attack_move": "攻击移动", "move": "移动", "scout": "侦察", "retreat": "撤离",
        "defend": "防守", "hold": "待命", "stop": "停止", "regroup": "集结",
    }
    #: 降级原因前缀 → 玩家能看懂的一句话（不暴露模型名/校验细节）。
    DEGRADE_CN = {
        "strategy_model_": "战略思考这一轮没成功，先用规则顶住",
        "tactics_model_": "战术思考这一轮没成功，先用规则顶住",
    }

    def _write_hud_status_file(self, payload: Dict[str, Any]) -> None:
        """把最新一条状态**覆盖**写入 `<log-dir>/hud_status.json`。

        为什么单独一个文件、而不是让游戏去 tail 事件 jsonl：
        面板侧扫目录 + `get_line_count()` 逐行读，实测在游戏进程里**读出来是空的**
        （同一目录同一文件，外部工具读得到）；而它只是表现层，不值得为此继续深挖。
        改成"runner 维护一个只有一行的状态文件"后，游戏侧只需一次
        `FileAccess.get_as_text()` + `JSON.parse_string()`：没有目录扫描、没有行数统计，
        失败面最小，且**文案由 runner 统一保证是中文人话**。
        """
        try:
            path = os.path.join(self.args.log_dir, "hud_status.json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(payload, handle, ensure_ascii=False)
        except OSError:
            pass

    def _log_hud_status(self, tick_value: int, result: Any) -> None:
        """把"副官此刻在想什么"写进结构化日志，供游戏内 HUD 面板 **1:1 渲染**。

        为什么要专门写这一条（而不是让 HUD 从零散事件里凑字段）：
        HUD 之前只能猜，实际显示成"当前状态：正在连接战场 / 最近行动：—"，
        等于**没有信息**；而用户明确要求"左上角面板我要看它的思考信息"。
        runner 是唯一知道决策内情的一方，所以由它直接给出结论（阶段/在想什么/为什么/结果）。
        写失败绝不影响指挥链（HUD 只是表现层）。
        """
        if self.runtime is None:
            return
        try:
            state = self.runtime.state
            route = str(getattr(result, "route", ""))
            phase = {"strategic": "规划中", "tactical": "分派任务",
                     "emergency_tactical": "应急反应", "wait": "观察中"}.get(route, "运行中")
            accepted = {str(i) for i in (getattr(result, "accepted_intents", None) or [])}
            actions: List[str] = []
            for intent in getattr(state, "active_intents", None) or []:
                if str(intent.get("intent_id", "")) not in accepted:
                    continue
                cn = self.ACTION_CN.get(str(intent.get("action", "")), "")
                if cn and cn not in actions:
                    actions.append(cn)
            thinking = ""
            for entry in reversed(list(getattr(state, "decision_log", None) or [])):
                if int(entry.get("server_tick", -1) or 0) != int(tick_value):
                    continue
                # 只取 `rationale`：`decision_log` 里的 `reason` 往往是**错误文案**
                # （如"模型输出不合法：Exceeded maximum output retries"），
                # 当"思考"显示会误导玩家（实测面板上出现过）。
                text = self._humanize_rationale(entry.get("rationale"))
                if text:
                    thinking = text
                    break
            if not thinking:
                thinking = ("正在执行：%s" % "、".join(actions)) if actions else "正在观察战况，等待时机"
            degraded = str(getattr(result, "degraded_reason", "") or "")
            why = "一切正常"
            for prefix, text in self.DEGRADE_CN.items():
                if degraded.startswith(prefix):
                    why = text
                    break
            else:
                if degraded:
                    why = "本轮有点状况，副官已自动兜底"
            result_text = ("下发 %d 条：%s" % (len(accepted), "、".join(actions))
                           if actions else "本轮没有新命令")
            payload = {
                "server_tick": int(tick_value),
                "phase": phase,
                "thinking": thinking[:60],
                "why": why[:60],
                "result": result_text[:80],
                # 战略阶段目标由模型产出（本来就是中文），给玩家一个"大方向"。
                "goal": str((state.active_plan or {}).get("phase_goal", ""))[:60],
                "units": len(getattr(state, "ai_controlled_units", None) or []),
            }
            # 事件日志：字段是给机器/排查用的（保留英文 key 便于检索）。
            if self.structured_logger is not None:
                self.structured_logger.log(
                    "hud_status", server_tick=int(tick_value),
                    phase=payload["phase"], thinking=payload["thinking"],
                    why=payload["why"], result=payload["result"],
                    plan_version=str(getattr(state, "plan_version", "") or ""),
                    units=payload["units"])
            # 面板专用文件：**玩家看的就是这一份**，文案在这里保证是中文人话。
            self._write_hud_status_file(payload)
        except Exception:  # noqa: BLE001 —— 状态写失败绝不允许影响指挥链
            pass

    def _humanize_rationale(self, text: Any) -> str:
        """把决策理由洗成**玩家能看懂的中文**。

        文案纪律（用户明确要求："AI 输出的文字内容应该是用户想看到的，至少要翻译成中文、
        简单易懂"）：面板上不许出现 `res://` 路径、`Unit_3`、`gather` 这类内部标识。
        我们自己的叶子 rationale 本来就是中文；模型产出的可能夹带内部标识，这里统一清掉。
        """
        raw = str(text or "").strip()
        if not raw:
            return ""
        raw = re.sub(r"\bres://\S+", " ", raw)
        raw = re.sub(r"\bUnit_\d+\b", "部队", raw)
        for key, cn in self.ACTION_CN.items():
            raw = raw.replace(key, cn)
        raw = re.sub(r"[\"'`{}\[\]]", " ", raw)
        return " ".join(raw.split())[:60]

    def _log_decision_delta(self, tick: int) -> None:
        """把本轮 `_decide()` 的留痕落进 runner 日志。

        为什么必须单独捞：`_decide()` 写的是**图内 `state.decision_log`**，
        **不经过** `GraphServices.log` —— 所以"只注入 logger"仍然看不到它。
        交接时"grep runner.out 找不到 `behavior_tree_added`"正是这个原因。
        按 tick 过滤 + 单调守卫：同一 tick 重复跑不会重复打印。
        """
        runtime = self.runtime
        if runtime is None:
            return
        if int(tick) <= int(self._decision_logged_tick):
            return
        self._decision_logged_tick = int(tick)
        try:
            entries = list(getattr(runtime.state, "decision_log", []) or [])
        except Exception:  # noqa: BLE001 —— 日志失败绝不影响指挥链
            return
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            if int(entry.get("server_tick", -1) or 0) != int(tick):
                continue
            self._log({"kind": "decision", "server_tick": int(tick),
                       "decision": entry})

    def _log(self, record: Dict[str, Any]) -> None:
        record.setdefault("ts", time.time())
        line = json.dumps(record, ensure_ascii=False, default=str)
        print("[runner] " + line, flush=True)
        if self._log_handle is not None:
            try:
                self._log_handle.write(line + "\n")
                self._log_handle.flush()
            except OSError:
                pass

    def _close_log(self) -> None:
        if self._log_handle is not None:
            try:
                self._log_handle.close()
            except OSError:
                pass
            self._log_handle = None


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="常驻副官 runner（LangGraph 指挥循环）")
    parser.add_argument("--authority-port", type=int, default=AUTHORITY_PORT,
                        help="游戏权威调试端点（默认玩家局服 24571）")
    parser.add_argument("--allow-other-port", action="store_true",
                        help="自测用：允许连非权威端口（隔离测试端口）")
    parser.add_argument("--player", default="", help="被指挥的真人玩家名（默认自动发现）")
    parser.add_argument("--provider", choices=("real", "fake"), default="real")
    parser.add_argument("--interface", choices=("four-col", "legacy"), default="four-col",
                        help="决策接口：four-col=四列任务修改（默认，唯一决策入口）；"
                             "legacy=旧极简 DirectiveBatch（保留用于 A/B 与回退）")
    parser.add_argument("--tactics-mode", choices=("fast", "deep"), default="fast",
                        help="四列接口的推理模式：fast=关注范围小/输出 96 token（默认）；"
                             "deep=信息范围更完整/输出 256 token")
    parser.add_argument("--strategy-mode", choices=("off", "plan"), default="off",
                        help="战略层：off=关闭（默认，四列单入口/高层意图缺省）；"
                             "plan=启用低频战略计划")
    parser.add_argument("--scheduling", choices=("async", "sync"), default="async",
                        help="调度方式：async=有界异步（默认，主循环不被推理阻塞）；"
                             "sync=旧同步等待（仅对照/回退）")
    parser.add_argument("--strategy-interval", type=int, default=1800,
                        help="战略模型最小间隔（tick，默认 1800≈30s）。"
                             "【不要砍到 900 以下】实测把战略间隔砍半后，战略模型失败次数与"
                             "重试耗时反而把主循环占满：5 分钟内 strategy_request=28 次、"
                             "tactics_request 只剩 **2** 次 → 微操层（发展阶梯+行为树）被饿死、"
                             "整局 0 生产、看不到任何批量指挥。战略层是低频慢层，"
                             "提速要靠微操高频跑（见 --tactics-interval / --event-interval）。")
    parser.add_argument("--tactics-interval", type=int, default=120,
                        help="战术模型最小间隔（tick，默认 120≈2s）")
    parser.add_argument("--emergency-interval", type=int, default=60,
                        help="紧急事件最小间隔（tick，默认 60≈1s）")
    parser.add_argument("--ttl", type=int, default=3600,
                        help="意图有效期（tick，默认 3600≈60s）。必须大于模型单次延迟"
                             "（实测 14~40s），否则意图会在下一批到来前过期，部队出现空窗。")
    parser.add_argument("--emergency-ttl", type=int, default=1200,
                        help="紧急意图有效期（tick，默认 1200≈20s）")
    parser.add_argument("--tick-interval", type=float, default=0.5,
                        help="循环节奏（秒；模型本身耗时不受此限制）")
    parser.add_argument("--event-interval", type=int, default=120,
                        help="观测事件节流（tick；图需事件才会走战术分支，默认 120≈2s，"
                             "应不大于 --tactics-interval）")
    parser.add_argument("--max-batch", type=int, default=24,
                        help="每轮最多下发多少条意图（默认 24，原为 8）。"
                             "实测默认 8 在对局激烈时大量触发 batch_limit_exceeded"
                             "（AI 局 178 次 / 5 分钟），把本可执行的命令截掉。"
                             "注意：同动作+同目标的意图已在仲裁层合并成一条多单位意图"
                             "（arbitration.merge_same_orders），因此这个配额现在按"
                             "**命令条数**消耗，而不是按单位个数。")
    parser.add_argument("--llm-timeout", type=float, default=0.0,
                        help="模型超时（秒，0=用 .env 默认）")
    parser.add_argument("--engine", default="auto", choices=("auto", "langgraph", "fallback"))
    parser.add_argument("--state-dir", default="/opt/airts-agent/state")
    parser.add_argument("--log-dir", default="/opt/airts-agent/logs")
    parser.add_argument("--env-file", default="", help=".env 路径（默认 /opt/airts-agent/.env）")
    parser.add_argument("--pidfile", default="/opt/airts-agent/state/agent_runner.pid")
    parser.add_argument("--wait-port-seconds", type=float, default=60.0)
    parser.add_argument("--bad-tick-limit", type=int, default=20,
                        help="连续单轮异常上限（超过则退出，交 daemon 重启）")
    parser.add_argument("--max-idle-checks", type=int, default=6,
                        help="连续 match=false 检查上限（超过则正常退出）")
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    availability = langgraph_available()
    print("[runner] langgraph_available=%s%s" % (
        availability["available"],
        "" if availability["available"] else " (%s)" % availability["reason"]))
    return AgentRunner(args).run()


if __name__ == "__main__":
    sys.exit(main())
