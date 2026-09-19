#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""常驻副官 runner：LangGraph 指挥主循环（Phase 7 接线）。

与隔离测试入口（`deploy/server_e2e.py`）的区别：
- **常驻循环**：按游戏 tick 节奏持续推进图，不是固定场景脚本；
- **连玩家局服权威端点**（默认 `127.0.0.1:24571`）；隔离测试端口默认拒绝（反向纪律，防误连）；
- **由 adjutant daemon 启停**：pidfile + SIGTERM 优雅退出；异常退出由 daemon 看门狗兜底。

职责边界（与 `langgraph-refactor.md` §7 一致）：
- LangGraph 负责 `dispatch_to_godot`（`op=adjutant_intent`）；
- Hermes 局内只给加成三选一排序（`op=augment_recommend`），**不进入下发路径、不代点**。

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
import io
import json
import os
import re
import signal
import socket
import sys
import threading
import time
from typing import Any, Dict, List, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))
sys.path.insert(0, HERE)

#: 【冷启动体检】本模块被加载的时刻：父进程（面板引导文件 / 验收工装）没给
#: `ADJUTANT_SPAWN_TS` 时用它兜底算 `since_spawn_ms`。放在 import 之后立刻取值，
#: 尽量贴近"进程刚起来"。
_MODULE_LOAD_TS = time.time()

from env_file import load_env_file  # noqa: E402
from fast_scan import FastScanner  # noqa: E402  （10Hz 缓存型扫描层，计划 §3.1）
from match_archive import (  # noqa: E402  （对局留档：每局尽可能留数据给后续分析）
    MatchArchive, compact_enemies, compact_production, compact_units)
from adjutant_coordinator.structured_log import (  # noqa: E402
    JsonlFileSink, StructuredLogger,
)
# 重依赖（pydantic-ai / langgraph / 图运行时）故意不在模块顶层导入：
# 引导文件 `from ...agent_runner import main` 必须尽快进入 setup 的等待循环，
# 才能和游戏加载页并行；这些模块改到 `_warm_imports` / 装配函数里再加载。

#: 玩家局服权威调试端点（生产路径）。
AUTHORITY_PORT = 24571
#: 隔离测试端口：常驻 runner 默认拒绝（防把生产副官指向测试局）。
TEST_PORTS = {24569, 24570, 24572}
#: 【2026-09-15 用户授权】临时测试房间端口区间：按需另起一套测试房（服务器/本机）时，
#: 端口落在该区间即视为隔离测试端口，**无需再显式 `--allow-other-port`**。
#: 与 `godot_tcp.TEST_PORT_RANGE` 同值 —— 端口策略单点定义的第二个引用点，
#: 改值必须两处一起改（skill「规则/账本收敛」）。区间已避开玩家局服/Hermes/验收口。
TEST_PORT_RANGE = (24600, 24699)
#: Hermes 客户端调试端口 + 玩家局服 UDP：**任何情况下都拒绝**（铁律）。
#: 注意 24571 是 AUTHORITY_PORT（生产权威口），在 assert_port_allowed 里单独放行。
FORBIDDEN_PORTS = {24567, 24568}
#: 单次 TCP 请求默认超时（秒）。
DEFAULT_TCP_TIMEOUT = 30.0
#: 等权威口/对局/视图时的轮询间隔。1.0s 会在对局刚就绪后再白等一轮；
#: 0.2s 足够避开忙等，单机挂上能少掉大约一秒。
WAIT_POLL_SECONDS = 0.2


class FaultTacticsModel:
    """**故障注入档**（验收专用）：`timeout` / `empty` / `invalid` 三选一。

    为什么必须有它（纠偏 §五-2）："注入 timeout/empty/invalid 时，经济、建造、生产和
    已有战斗任务继续推进"是硬验收项；如果只能靠改代码/断网/拔网线来制造这些状态，
    验收就不可复现、也没法在同一局里逐档对比。这里把三档做成 runner 开关，
    与真实模型共用同一条调用路径（`propose_task_patch`），因此测的就是生产代码路径。
    """

    mode = "fast"

    def __init__(self, kind: str) -> None:
        self.kind = str(kind)

    def propose_task_patch(self, frame):  # noqa: ANN001 - 与真实 Agent 同签名
        if self.kind == "timeout":
            from adjutant_coordinator.graph.pydantic_agents import ModelTimeout
            raise ModelTimeout("fault-injection: timeout")
        if self.kind == "invalid":
            from adjutant_coordinator.graph.pydantic_agents import ModelInvalidOutput
            raise ModelInvalidOutput("fault-injection: invalid")
        return None          # "empty"：成功但空批次


class RunnerError(RuntimeError):
    """runner 装配/端口纪律错误（启动即失败，不带病运行）。"""


# ---------------- 端口纪律与 TCP ----------------

def is_test_port(port: int) -> bool:
    """隔离测试端口：固定测试口 ∪ 临时测试房间区间（硬禁端口永远不算）。"""
    if int(port) in FORBIDDEN_PORTS:
        return False
    if int(port) in TEST_PORTS:
        return True
    return TEST_PORT_RANGE[0] <= int(port) <= TEST_PORT_RANGE[1]


def assert_port_allowed(port: int, allow_other: bool) -> None:
    if int(port) in FORBIDDEN_PORTS:
        raise RunnerError("拒绝：%d 属于玩家局服 UDP/Hermes 链路（铁律，永不放行）。" % port)
    if port == AUTHORITY_PORT:
        return
    # 【2026-09-15 用户授权】隔离测试端口（含临时测试房间区间）默认放行：
    # "服务器可以开临时测试房间"，跑副官验收是常规操作，不必再显式 --allow-other-port。
    # 生产路径不受影响：不传 --authority-port 时仍然连 24571。
    if is_test_port(port):
        return
    if not allow_other:
        raise RunnerError(
            "拒绝：%d 既不是权威端口 %d，也不是隔离测试端口（%s 或临时房间区间 %s）；"
            "确需连接请显式加 --allow-other-port。" % (
                port, AUTHORITY_PORT, sorted(TEST_PORTS), TEST_PORT_RANGE))


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


#: 只有 `op=status` 才会出现的字段（用于识别"这确实是一个 status 响应"）。
#: `balance`/`server_tick` 之类**不能**用：战术视图也有。
_STATUS_ONLY_FIELDS = ("players", "is_server", "camera", "full_vision",
                       "all_balances", "fog_debug", "fog_visible",
                       "local_player_name", "viewport_size")


def match_active(port: int) -> bool:
    """对局是否仍在进行（决定 runner 是否继续常驻）。

    【为什么不能只看 `match` 是否存在】DCS 是"裸 TCP + 一行 JSON"，同机并发查询时
    可能收到**串台/异常载荷**：2026-09-12 实测 runner 连续 6 次读到没有 `match` 键的
    响应 → 判 `match_active=false` → 以 `no_active_match` **正常退出**，
    而同一个对局几十秒后仍然 `match=True`；表现出来就是"这一局只发展到 M02"
    （很容易被当成规则退化）。纪律：**异常响应不等于事实**——
    只有"看起来确实是 status 响应、且其中没有 match"才允许判定对局结束。
    """
    try:
        status = tcp_json(port, {"op": "status"})
    except (ConnectionRefusedError, ConnectionResetError, ConnectionAbortedError):
        # 【2026-09-14 实测 m1combat】对局进程退出后端口拒连，原实现把异常穿透到
        # `_match_alive()`，runner 以 traceback 收尾（明明已经正常退出过一轮）。
        # 端口拒连 = "对局/进程已退出"的**事实**（不是"异常响应"）→ 据此正常结束常驻。
        return False
    except OSError:
        # 超时等瞬时故障 → 未知，不据此结束对局（下一轮再判）。
        return True
    if not isinstance(status, dict):
        return True                    # 响应形态不对 → 未知，不据此结束对局
    if "match" in status:
        return bool(status["match"])
    if any(key in status for key in _STATUS_ONLY_FIELDS):
        return False                   # 确实是 status 且没有 match → 对局结束
    return True                        # 串台/异常载荷 → 保持常驻（下一轮再判）


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
        #: 批量提交统计（计划 §9 要"批量提交效果"）：批次数 / 批内命令数。
        self.batch_count = 0
        self.batch_commands = 0
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

    def send_batch(self, envelopes: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        """一次 TCP 提交多条意图（计划 §5：优先使用批量意图接口）。

        **批量传输 ≠ 批量成功**：权威端逐项回执，这里按 `intent_id` 把回执对回原意图；
        对不上的那一项显式标 `BadReceipt`（绝不允许"没收到回执"被当成成功）。

        单条时直接走 `send_command`（批量只有一条没有收益，且少一层解析）。
        """
        items = [item for item in (envelopes or []) if isinstance(item, dict)]
        if not items:
            return []
        if len(items) == 1:
            return [self.send_command(items[0])]
        commands: List[Dict[str, Any]] = []
        for envelope in items:
            payload = dict(envelope)
            payload.pop("op", None)
            commands.append(payload)
        self.batch_count += 1
        self.batch_commands += len(commands)
        try:
            response = tcp_json(self.port, {"op": "adjutant_batch", "mode": "intent",
                                            "commands": commands}, timeout=self.timeout)
        except OSError as exc:
            self.errors.append(str(exc))
            self.errors = self.errors[-20:]
            return [{"ok": False, "accepted": False, "status": "TransportError",
                     "reason": str(exc),
                     "command_id": str(item.get("command_id", "")),
                     "intent_id": str(item.get("intent_id", "")), "result": {}}
                    for item in items]
        receipts = (response or {}).get("receipts") or []
        by_intent = {str(item.get("intent_id", "")): item
                     for item in receipts if isinstance(item, dict)}
        out: List[Dict[str, Any]] = []
        for item in items:
            intent_id = str(item.get("intent_id", ""))
            receipt = by_intent.get(intent_id)
            if not isinstance(receipt, dict):
                receipt = {"ok": False, "accepted": False, "status": "BadReceipt",
                           "reason": "批量回执里没有这一条（不按成功处理）",
                           "command_id": str(item.get("command_id", "")),
                           "intent_id": intent_id, "result": {}}
            receipt.setdefault("command_id", str(item.get("command_id", "")))
            receipt.setdefault("intent_id", intent_id)
            receipt.setdefault("result", {})
            out.append(receipt)
        self.sent_count += len(out)
        return out

    def heartbeat(self) -> bool:
        return True

    def close(self) -> None:
        return None

    def describe(self) -> str:
        return "AuthorityIntentTransport(port=%d, op=%s, sent=%d)" % (
            self.port, self.op, self.sent_count)


class MeteredModel:
    """记录模型调用延迟与结果（慢模型调度节流的依据）。

    `sink_writer`：额外的落点（用在**对局留档**上）——记录"这次调用**提议了什么**"，
    否则复盘只能看到"模型被调用了 12 次、耗时 3s"，看不到它说了什么（那是分析的关键输入）。
    """

    def __init__(self, role: str, inner: Any, sink: List[Dict[str, Any]],
                 sink_writer=None) -> None:
        self.role = role
        self.inner = inner
        self.sink = sink
        self.sink_writer = sink_writer

    def _emit(self, record: Dict[str, Any]) -> None:
        self.sink.append(record)
        if self.sink_writer is not None:
            try:
                self.sink_writer(record)
            except Exception:  # noqa: BLE001 —— 留档失败绝不影响指挥链
                pass

    def _invoke(self, method: str, context: Dict[str, Any]) -> Any:
        started = time.time()
        record: Dict[str, Any] = {"role": self.role, "method": method,
                                  "tick": int(context.get("server_tick", 0) or 0),
                                  "started_at": started}
        try:
            value = getattr(self.inner, method)(context)
            record.update({"ok": True, "kind": "", "error": "",
                           "proposal": _proposal_digest(value)})
        except Exception as exc:
            if not _is_model_error(exc):
                raise
            record.update({"ok": False, "kind": type(exc).__name__, "error": str(exc)})
            self._emit(dict(record, latency_ms=int((time.time() - started) * 1000)))
            raise
        record["latency_ms"] = int((time.time() - started) * 1000)
        self._emit(record)
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
        # 【留档缺口修复 2026-09-14】四列接口是**现在唯一在跑的决策入口**，但它原来只写
        # 内存 `self.sink`、不调 `_emit`，于是 `model.jsonl` 永远 0 条（实测 m1on2 局：
        # 19 次真实调用、17 条模型意图被采纳，档案里却查不到模型说过什么）——
        # 违反计划 §9"模型层要记录调用与提议摘要"。这里与 `propose_plan/propose_intents`
        # 走同一条 `_emit`（含失败），保证"调用是否发生/多久/提议了什么"可复盘。
        started = time.time()
        record: Dict[str, Any] = {"role": self.role, "method": "propose_task_patch",
                                  "tick": int(getattr(frame, "server_tick", 0) or 0),
                                  "started_at": started}
        try:
            value = self.inner.propose_task_patch(frame)
            record.update({"ok": True, "kind": "", "error": "",
                           "proposal": _proposal_digest(value)})
        except Exception as exc:
            if not _is_model_error(exc):
                raise
            record.update({"ok": False, "kind": type(exc).__name__, "error": str(exc)})
            self._emit(dict(record, latency_ms=int((time.time() - started) * 1000)))
            raise
        record["latency_ms"] = int((time.time() - started) * 1000)
        self._emit(record)
        return value


def _is_model_error(exc: BaseException) -> bool:
    """是否为模型层三类受控失败（懒导入，避免模块顶层拖 pydantic-ai）。"""
    from adjutant_coordinator.graph.pydantic_agents import (
        ModelInvalidOutput, ModelTimeout, ModelUnavailable)
    return isinstance(exc, (ModelTimeout, ModelUnavailable, ModelInvalidOutput))


# ---------------- runner ----------------

def _dig_receipt(receipt: Dict[str, Any], *keys: str) -> Any:
    """从回执的嵌套结构里取字段（`result.result.unit_results[0]...`）。

    为什么用"挖"而不是写死路径：回执有两层转发（统一入口 + 权威端），
    不同动作分组的层级不同；写死路径会在部分动作上取到 None（实测 `error_code` 就踩过）。
    """
    seen: List[Any] = [receipt]
    for _ in range(4):
        deeper: List[Any] = []
        for item in seen:
            if isinstance(item, dict):
                for key in keys:
                    if item.get(key) not in (None, "", []):
                        return item[key]
                for value in item.values():
                    if isinstance(value, dict):
                        deeper.append(value)
                    elif isinstance(value, list):
                        deeper.extend(value[:4] if isinstance(value, list) else [])
            elif isinstance(item, list):
                deeper.extend(item[:4])
        seen = deeper
        if not seen:
            break
    return ""


def _compact_intents(intents: List[Dict[str, Any]], limit: int = 80) -> List[Dict[str, Any]]:
    """把活跃意图压成紧凑表（每轮进档案）。

    为什么必须有（GPT 复盘计划 P0："证据链要能串起 产生候选→仲裁→回执→开产→完成→**任务结算**"）：
    原来的每轮记录只有"世界"没有"我们的任务状态"，于是"生产完成了但任务仍是 unknown"
    这件事在档案里**看不到**（只能靠 raw 逐行猜）。有了它，完成事件与任务状态可以直接对齐。
    """
    out: List[Dict[str, Any]] = []
    for intent in intents or []:
        if not isinstance(intent, dict):
            continue
        target = intent.get("target") if isinstance(intent.get("target"), dict) else {}
        progress = intent.get("progress") if isinstance(intent.get("progress"), dict) else {}
        out.append({
            "id": str(intent.get("intent_id", "")),
            "action": str(intent.get("action", "")),
            "units": [str(u) for u in (intent.get("unit_ids") or [])][:8],
            "state": str(intent.get("state", "")),
            "drop_reason": str(intent.get("drop_reason", "")),
            "issued": intent.get("issued_tick"),
            "expires": intent.get("expires_tick"),
            "scene": str(target.get("scene", "")),
            "pos": (target.get("pos") or [])[:2] or None,
            "item_id": str((intent.get("production") or {}).get("item_id", "")),
            "progress": str(progress.get("status") or ""),
            "progress_tick": progress.get("tick"),
        })
        if len(out) >= limit:
            break
    return out


def _read_jsonl(path: str, limit: int = 200000) -> List[Dict[str, Any]]:
    """读一份 JSONL（容错：坏行跳过、最多 `limit` 行）。

    用途：收尾时把图内 `command_timing` 合并进命令生命周期表（读的是本进程刚写的日志）。
    """
    out: List[Dict[str, Any]] = []
    try:
        with io.open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if not line or not line.startswith("{"):
                    continue
                try:
                    out.append(json.loads(line))
                except ValueError:
                    continue
                if len(out) >= limit:
                    break
    except OSError:
        return []
    return out


def _first_error_code(receipt: Dict[str, Any]) -> str:
    return str(_dig_receipt(receipt, "error_code") or "")


def _first_order_id(receipt: Dict[str, Any]) -> str:
    return str(_dig_receipt(receipt, "order_id") or "")


def _proposal_digest(value: Any, limit: int = 600) -> str:
    """模型产出的**一行摘要**（留档用）：意图/计划要点，超长截断并标 `…`。

    只留摘要不留全文：全文里有大幅上下文，体积大且含无关内容；分析要的是
    "它提议了什么动作、打哪、谁去打"。
    """
    try:
        if hasattr(value, "model_dump"):
            value = value.model_dump()
        elif hasattr(value, "to_dict"):
            value = value.to_dict()
    except Exception:  # noqa: BLE001
        pass
    try:
        if isinstance(value, dict):
            keep = {key: value.get(key) for key in
                    ("plan_id", "phase_goal", "intents", "task_patch", "reasoning",
                     "rationale", "notes")
                    if value.get(key) not in (None, "", [], {})}
            if keep:
                value = keep
    except Exception:  # noqa: BLE001
        pass
    return _digest_json(value, limit)


def _digest_json(value: Any, limit: int) -> str:
    try:
        text = json.dumps(value, ensure_ascii=False, default=str)
    except (TypeError, ValueError):
        text = str(value)
    return text if len(text) <= limit else text[:limit] + "…"


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
        #: 对局留档（`deploy/match_archive.py`）：**每一局都留**（用户 2026-09-13：
        #: "每个对局都有意义，要尽可能把数据留档，我要给高级模型分析"）。写失败不影响对局。
        self.archive: Optional[Any] = None
        self._structured_path = ""
        self._log_handle = None
        #: 图内结构化日志 sink（`ctx.services.log`）。**必须显式注入**，
        #: 否则 `GraphServices.logger` 为 None → 所有 `_log(...)` 打点静默丢弃。
        self.structured_logger: Optional[StructuredLogger] = None
        #: 已落盘的 decision_log tick（单调守卫，避免同一 tick 重复打印）。
        self._decision_logged_tick = 0
        self._stopping = False
        self._stop_reason = ""
        self._last_event_tick = 0
        #: 最近一次看到的对局结局（`op=tactical` 的 `outcome`）与扫描统计，供留档收尾用。
        self._last_outcome: Dict[str, Any] = {}
        self._last_scan_stats: Dict[str, Any] = {}
        #: 【冷启动体检】装配各阶段耗时（毫秒，相对 setup 起点）——随 `start` 事件落盘。
        #: 用户 2026-09-15 反馈"点接管后要等一分钟才挂上"，过去只能靠猜；现在每局都有
        #: `setup_ms` 可查（哪一段慢一目了然）。`since_spawn_ms` ＝ 从"进程被拉起"到
        #: "挂上对局"的真实冷启动：父进程给了 `ADJUTANT_SPAWN_TS`（面板引导文件会写）
        #: 就用它，否则退化为**本模块被加载的时刻**（验收工装直接拉起 runner 时也能量）。
        self._setup_ms: Dict[str, int] = {}
        self._setup_t0 = 0.0
        #: 本局已向 Godot 提交过 Hermes 排序的加成轮次（避免重复打模型）。
        self._augment_ranked_round = -1
        self._augment_rank_inflight = False
        self._spawn_ts = 0.0
        try:
            self._spawn_ts = float(os.environ.get("ADJUTANT_SPAWN_TS", "") or 0.0)
        except ValueError:
            self._spawn_ts = 0.0
        if not self._spawn_ts:
            self._spawn_ts = _MODULE_LOAD_TS

    # ---------- 装配 ----------

    def _mark(self, name: str) -> None:
        """记一段启动耗时（毫秒，相对 setup 起点）。见 `_setup_ms` 的说明。"""
        if not self._setup_t0:
            self._setup_t0 = time.monotonic()
        self._setup_ms[name] = int((time.monotonic() - self._setup_t0) * 1000)

    def _since_spawn_ms(self) -> int:
        """从"进程被拉起"到现在的毫秒（见 `_spawn_ts`：父进程给时刻则更精确）。"""
        if not self._spawn_ts:
            return -1
        return int((time.time() - self._spawn_ts) * 1000)

    def _warm_imports(self) -> None:
        """【冷启动优化①】把重依赖提前到"等权威口/等对局"的空档里导入。

        实测（2026-09-15，本机 venv，均在关键路径上）：`pydantic_ai` 2.4s、
        `PydanticAITaskPatchAgent(settings)` 2.1s、`langgraph.graph` 0.7s ≈ 5s。
        而对局还在加载时 runner 本来就要在下面等十几秒 —— 那段时间是纯干等，正好拿来预热。
        这里只把模块**导进 `sys.modules`**（不构造任何客户端、不发请求），
        后续 `_build_models()` / 建图里的懒导入就变成瞬时；失败**静默忽略**，
        照旧走懒导入路径（行为不变）。
        """
        try:
            import pydantic_ai  # noqa: F401
            from pydantic_ai.models.openai import OpenAIChatModel  # noqa: F401
            from pydantic_ai.providers.openai import OpenAIProvider  # noqa: F401
            import langgraph.graph  # noqa: F401
            from adjutant_coordinator.graph import pydantic_agents as _pydantic_agents  # noqa: F401
            from adjutant_coordinator.graph import runtime as _graph_runtime  # noqa: F401
            from adjutant_coordinator.graph import checkpoint as _graph_checkpoint  # noqa: F401
            from adjutant_coordinator.graph.graph import langgraph_available  # noqa: F401
        except Exception:  # noqa: BLE001 —— 预热失败不是错误：懒导入路径仍然有效
            pass

    def setup(self) -> None:
        self._setup_t0 = time.monotonic()
        self._mark("begin")
        assert_port_allowed(self.port, bool(self.args.allow_other_port))
        loaded = load_env_file(self.args.env_file)
        if loaded:
            print("[runner] 已从 .env 注入 %d 个键（不打印取值）" % len(loaded))
        self._mark("env")
        # 【冷启动优化①】重依赖预热与"等权威口/等对局"并行跑（见 `_warm_imports`）。
        self._warm_thread = None
        if str(getattr(self.args, "model", "on") or "on") != "off":
            import threading
            self._warm_thread = threading.Thread(target=self._warm_imports, daemon=True)
            self._warm_thread.start()
        # 【冷启动优化②】等待条件从"端口就绪"改成"**端口 + 对局**都就绪"（2026-09-15）。
        # 旧实现只要那一瞬 `match=false` 就 `RunnerError` 退出 —— 对局还在加载时点"接管"
        # 必然白起一个进程、玩家得再过一会儿手动重点一次（用户实测："进去连不上，玩一会
        # 才好"）。现在在同一窗口内等到对局就绪为止；**不改变"绝不盲发命令"**：下面仍必须
        # 先取到 rules/match_id/rules_version 才会继续装配。
        deadline = time.time() + float(self.args.wait_port_seconds)
        wait_state = "port"
        wait_reported = ""
        views: Dict[str, Any] = {}
        rules: Dict[str, Any] = {}
        while time.time() < deadline:
            if wait_state != wait_reported:
                wait_reported = wait_state
                print("[runner] 等待对局就绪…（%s）" % wait_state, flush=True)
            if not port_listening(self.port):
                wait_state = "port"
                time.sleep(WAIT_POLL_SECONDS)
                continue
            if not match_active(self.port):
                wait_state = "match"
                time.sleep(WAIT_POLL_SECONDS)
                continue
            if not self.player:
                self.player = pick_human_player(self.port)
            if not self.player:
                wait_state = "player"
                time.sleep(WAIT_POLL_SECONDS)
                continue
            # 【为什么把"取视图"也放进轮询】对局刚加载完时游戏主线程还在建场景/烘焙导航，
            # DCS 会**接受连接但长时间不回包**。旧实现只等"端口+对局"就往下走，取不到
            # rules/match_id 就直接 `RunnerError` 退出 —— 于是"加载页里预热出来的 runner"
            # 会白死（玩家反而更懵）。现在取不到就再等一轮，窗口内自愈。
            try:
                views = fetch_views(self.port, self.player, self.rules_cache)
            except OSError:
                views = {}
            rules = (views.get("rules") or {})
            if rules.get("match_id") and (rules.get("rules_version") or {}).get("content_hash"):
                wait_state = "ready"
                break
            wait_state = "views"
            time.sleep(WAIT_POLL_SECONDS)
        if wait_state != "ready":
            if wait_state == "port":
                raise RunnerError("权威端点 %d 在 %.0fs 内未就绪。"
                                  % (self.port, self.args.wait_port_seconds))
            if wait_state == "match":
                raise RunnerError("权威端点 %d 在 %.0fs 内没有出现进行中的对局（match=false）。"
                                  % (self.port, self.args.wait_port_seconds))
            if wait_state == "player":
                raise RunnerError("对局里没有可指挥的真人玩家（players 里找不到 human=true）。")
            raise RunnerError("对局在 %.0fs 内取不到 rules/match_id（DCS 忙或对局仍在加载）。"
                              % self.args.wait_port_seconds)
        self._mark("ready_wait")
        tactical = views.get("tactical") or {}
        self.match_id = str(rules.get("match_id", "") or "")
        self.rules_version = str((rules.get("rules_version") or {}).get("content_hash", "") or "")
        if not self.match_id or not self.rules_version:
            raise RunnerError("无法取到 match_id / rules_version，拒绝启动（避免盲发命令）。")
        self._mark("fetch_views")
        tick = int(tactical.get("server_tick", 0) or 0)
        # 恢复上次 checkpoint（同一 match/player 才认；在途请求保持 pending 不重复下单）。
        restore = {"restored": False, "reason": "not_attempted"}

        os.makedirs(self.args.state_dir, exist_ok=True)
        os.makedirs(self.args.log_dir, exist_ok=True)
        self._open_log()
        self._mark("open_log")
        # 【冷启动优化③】★先登记"已挂上本局"，再去做重装配（模型/图/留档）。
        # 面板 `is_attached()` = pidfile + 心跳。心跳原来已经提前，pidfile 却还在
        # 整段装配之后才写 —— 加载页 12s 上限经常等不到。对局身份已齐就写握手；
        # 后面装配失败由 `run()` 删掉，不会留下死 pid。
        self._write_pidfile()
        self._log({"kind": "attached", "match_id": self.match_id, "player": self.player,
                   "server_tick": tick, "port": self.port,
                   "setup_ms": dict(self._setup_ms)})
        if self._warm_thread is not None:
            # 等预热线程把重依赖导完（它多半早已完成——等待窗通常比导入长）。
            self._warm_thread.join(timeout=30.0)
        strategy_model, tactics_model = self._build_models()
        self._mark("build_models")
        self.transport = AuthorityIntentTransport(self.port)
        # 【10Hz 扫描层】只读缓存型快速状态 + 增量事件；线程只写有界队列，
        # 不碰 LangGraph 状态（单写者 = 协调线程，见计划 §3.1/§3.2）。
        if str(getattr(self.args, "scan", "on")) == "on":
            self.scanner = FastScanner(
                self.port, self.player, tcp_json=tcp_json,
                interval=float(getattr(self.args, "scan_interval", 0.1)))
            self.scanner.start()
        self._mark("scanner")
        # 有界异步调度（计划 §7.C）：模型调用在工作线程里跑，主循环不再被 1~15s 的
        # 推理阻塞；结果到达时按"本地接收期限 / 观测推进 / 逐对象代际"判定接受或拒绝。
        scheduler = self._build_scheduler(tactics_model)
        self._mark("scheduler")
        # 副官强度（面板三个等级按钮 → 生产/面板写进 runner 参数 → 规则地板的出击阈值）：
        # 唯一实现见 `graph/intensity.py`。**放在这里而不是参数解析期**：导入 `graph` 包会
        # 连带 pydantic 契约（实测 ~2.1s），提前到 `build_parser()` 会把冷启动握手推迟 2 秒；
        # 此刻 `_warm_imports` 已经预热过，且早于第一次 `ensure_campaign`（首个 tick），
        # 所以既有零成本也保证生效。
        from adjutant_coordinator.graph import intensity as intensity_mod
        self._intensity = intensity_mod.set_active(self.args.intensity)
        print("[runner] 副官强度=%s（%s）" % (
            intensity_mod.label(), intensity_mod.hint()), flush=True)
        from adjutant_coordinator.graph.checkpoint import JsonCheckpointStore
        from adjutant_coordinator.graph.runtime import AdjutantGraphRuntime, RuntimeConfig
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
            tick_provider=self._tick_provider,
            # 安全移动硬闸门的权威路径来源（必须在 `setup` 之前定义好，见 run()）。
            nav_query=self._nav_query)
        self._mark("runtime")
        restore = self.runtime.restore(expect_rules_version=self.rules_version)
        self._mark("restore")
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
        self._mark("describe")
        self._open_archive(describe)
        self._mark("archive")
        # 模型层的**提议摘要**也进留档（复盘要能回答"它当时提议了什么、多久、成没成"）。
        # 在这里挂而不是构造时传：模型先于留档装配（`_build_models` 在 runtime 之前）。
        for model in (strategy_model, tactics_model):
            if isinstance(model, MeteredModel) and self.archive is not None:
                model.sink_writer = self.archive.model
        self._log({
            "kind": "start", "match_id": self.match_id, "player": self.player,
            "rules_version": self.rules_version, "server_tick": tick,
            "engine": describe.get("engine"),
            "langgraph_available": describe.get("langgraph_available"),
            "provider": self.args.provider, "restore": restore,
            "config": describe.get("config"), "port": self.port,
            # 强度等级进 start 事件：留档/复盘要能回答"那一局副官是几级、出击阈值多少"。
            "intensity": intensity_mod.describe(),
            "handover": handover,
            # 【冷启动体检】各阶段耗时（毫秒）+ 从"进程被拉起"起的真实冷启动。
            "setup_ms": dict(self._setup_ms), "since_spawn_ms": self._since_spawn_ms(),
        })
        print("[runner] match=%s player=%s engine=%s restore=%s" % (
            self.match_id[:8], self.player, describe.get("engine"),
            json.dumps(restore, ensure_ascii=False)))
        print("[runner] 冷启动：%s%s" % (
            " ".join("%s=%dms" % (key, value) for key, value in self._setup_ms.items()),
            ("  自进程拉起=%dms" % self._since_spawn_ms()) if self._spawn_ts else ""))
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
        # 【验收档】`--model off|timeout|empty|invalid`：纠偏 §五要求"模型关闭/超时/空/
        # 非法时副官仍靠规则中台持续运营"。off 必须能在**没有凭据**的机器上直接起，
        # 否则验收根本执行不了（真实 Provider 缺 key 会在装配期直接 RunnerError）。
        model_mode = str(getattr(self.args, "model", "on") or "on")
        if model_mode == "off":
            print("[runner] 决策模型=off：仅规则中台 + 行为树（baseline 验收档）")
            return None, None
        if model_mode in ("timeout", "empty", "invalid"):
            print("[runner] 决策模型=故障注入档(%s)：走真实调用路径，按档抛错/回空"
                  % model_mode)
            return None, MeteredModel("tactics", FaultTacticsModel(model_mode),
                                      self.model_sink)
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
            from adjutant_coordinator.graph.pydantic_agents import (
                GraphModelSettings, ModelUnavailable, PydanticAIStrategyAgent,
                PydanticAITacticsAgent, PydanticAITaskPatchAgent,
                pydantic_ai_available,
            )
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

    def _nav_query(self, unit: str, target) -> Dict[str, Any]:
        """权威路径查询（计划 §7）：接到游戏侧 `op=adjutant_nav_path`。

        起点取**单位当前位置**（从 10Hz 缓存快照读，不额外往返）——不能拿目标点当起点：
        实测基地坐标 (10,7) 不在网格上，会被吸附到 (7.96,7.26)，起点错了路径就没意义。

        纪律：查不到路就返回 `ok=false`，**绝不**在 Python 侧伪造直线
        （计划明令"不在 Python 伪造安全路线"）。异常同样按 `no_path` 处理。
        """
        goal = ([float(target[0]), float(target[1])]
                if isinstance(target, (list, tuple)) and len(target) >= 2 else [0.0, 0.0])
        start = self._unit_position(unit) or [0.0, 0.0]
        try:
            reply = tcp_json(self.port, {"op": "adjutant_nav_path", "as_player": self.player,
                                         "unit": str(unit), "from": start, "to": goal},
                             timeout=8)
        except OSError as exc:
            return {"ok": False, "reason": "transport_error", "detail": str(exc)[:120]}
        return reply if isinstance(reply, dict) else {"ok": False, "reason": "bad_reply"}

    def _unit_position(self, unit: str) -> Optional[List[float]]:
        """从 10Hz 快照里取单位当前位置（`[x, z]`）；拿不到返回 None。"""
        if self.scanner is None:
            return None
        snapshot = self.scanner.latest() or {}
        for entry in snapshot.get("units") or []:
            if str(entry.get("name")) != str(unit):
                continue
            position = entry.get("pos") or []
            if len(position) >= 3:
                return [float(position[0]), float(position[2])]
            if len(position) == 2:
                return [float(position[0]), float(position[1])]
        return None

    def _match_alive(self) -> Optional[bool]:
        """**廉价**存活探针（计划 P0：协调层不该每轮拉一次全量 status）。

        `op=status` 会全扫单位并逐单位做相机投影 —— 实测单位涨到 32 个时，
        它是主循环被拖慢到 0.75Hz 的头号成本。这里优先用 10Hz 扫描层的缓存快照
        （2ms）判断"对局还活着"；只有当快照过期（= DCS 不再响应）时才退化到
        昂贵的 `match_active`，**保持原有判据不变**（异常响应不等于事实）。
        """
        if self.scanner is not None:
            latest = self.scanner.latest()
            if latest:
                try:
                    age = time.time() - float(latest.get("sampled_at") or 0)
                except (TypeError, ValueError):
                    age = 99.0
                if 0.0 <= age <= 3.0:
                    return True
        return match_active(self.port)

    def _tick_provider(self) -> Optional[Dict[str, int]]:
        # 【先走 10Hz 快照】它带权威端的 `server_tick`/`snapshot_id`，且读取免费。
        # 改造前这里每轮都发一次 `op=tactical&limit=1`（仍要全扫场景）—— 纯粹重复往返。
        if self.scanner is not None:
            latest = self.scanner.latest()
            if latest:
                cached_tick = int(latest.get("server_tick", 0) or 0)
                if cached_tick > 0:
                    return {"server_tick": cached_tick,
                            "snapshot_id": int(latest.get("snapshot_id", cached_tick)
                                               or cached_tick)}
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
        self.scanner: Optional[FastScanner] = None
        #: 完整视图缓存（`op=strategic`/`op=tactical`）：按 `--full-view-interval` 刷新。
        self._full_views: Dict[str, Any] = {}
        #: 协调轮次时间戳（有界，120 个）：用来算真实的**协调频率**（`coord_hz`）。
        self._coord_stamps: List[float] = []
        # 【一对一硬约束】必须在 `setup()` **之前**判定：否则"对局没跑起来"这类
        # setup 失败会先返回 3，被重复启动的那个 runner 反而不被判重复（实测踩到）。
        occupant = self._acquire_single_instance()
        if occupant != 0:
            print("[runner] 本局已有 runner 在跑（pid=%s，authority_port=%s player=%s），"
                  "拒绝启动第二个。" % (occupant, self.port, self.player), file=sys.stderr)
            self._log({"kind": "single_instance_rejected", "occupant_pid": occupant,
                       "authority_port": self.port, "player": self.player})
            self._close_log()
            return 4
        try:
            self.setup()
        except RunnerError as exc:
            print("[runner] 启动失败：%s" % exc, file=sys.stderr)
            self._log({"kind": "setup_failed", "error": str(exc)})
            self._close_log()
            self._remove_pidfile()
            self._release_single_instance()
            return 3
        except Exception as exc:  # noqa: BLE001 —— 装配期异常统一留痕后退出
            print("[runner] 装配异常：%r" % exc, file=sys.stderr)
            self._log({"kind": "setup_error", "error": repr(exc)})
            self._close_log()
            self._remove_pidfile()
            self._release_single_instance()
            return 3

        self._install_signal_handlers()
        self._write_pidfile()
        bad_ticks = 0
        idle_checks = 0
        exit_code = 0
        try:
            while not self._stopping:
                try:
                    loop_started = time.time()
                    observe_started = time.time()
                    tick_value, obs = self._observe()
                    observe_ms = int((time.time() - observe_started) * 1000)
                    # 对局结局（打到结算/投降）——留档要能回答"这局谁赢了"。
                    outcome = (obs.get("tactical") or {}).get("outcome")
                    if isinstance(outcome, dict) and outcome.get("finished"):
                        self._last_outcome = dict(outcome)
                    self._sync_control(obs.get("tactical") or {})
                    # 【增量事件消费】把扫描层攒下的新事件交给本轮（按 seq 去重，只消费新增）。
                    # 事件带"游戏内真实发生的事"（回执/受击/建成/生产开始…），
                    # 协调层据此更新进度，而不是靠每轮重拉全量视图去猜。
                    if self.scanner is not None:
                        fast_events = self.scanner.drain_events()
                        if fast_events:
                            obs["fast_events"] = fast_events
                        latest = self.scanner.latest()
                        if latest:
                            obs["fast_state"] = latest
                    self._maybe_rank_augments(obs)
                    started = time.time()
                    result = self.runtime.tick(tick_value, obs)
                    elapsed_ms = int((time.time() - started) * 1000)
                    bad_ticks = 0
                    # 【协调频率与观测开销】计划 §9 要报"协调频率"与耗时。
                    # 只有 `elapsed_ms`（协调本身）看不出"为什么到不了 2Hz" ——
                    # 实测瓶颈在 `_observe`（全量视图），所以观测耗时必须单列（2026-09-13）。
                    self._coord_stamps.append(time.time())
                    if len(self._coord_stamps) > 120:
                        self._coord_stamps.pop(0)
                    coord_hz = 0.0
                    if len(self._coord_stamps) >= 2:
                        span = self._coord_stamps[-1] - self._coord_stamps[0]
                        coord_hz = round((len(self._coord_stamps) - 1) / max(0.001, span), 2)
                    self._log({
                        "kind": "tick", "server_tick": tick_value, "elapsed_ms": elapsed_ms,
                        "coord_hz": coord_hz, "observe_ms": observe_ms,
                        "route": result.route, "paused": bool(getattr(result, "paused", False)),
                        "accepted": list(result.accepted_intents),
                        "dropped": list(result.dropped_intents),
                        "degraded_reason": result.degraded_reason,
                        "live_intents": self.runtime.state.live_intents(
                            self.runtime.state.server_tick),
                        "model_calls": len(self.model_sink),
                        "sent": self.transport.sent_count,
                        # 【P1 验收指标】五条线路的处理次数/饿死账 + 批量提交效果。
                        "lanes": dict(result.state.get("lanes") or {}),
                        # 【P2 验收指标】安全移动：allowed / blocked_reasons / ungated /
                        # scout_first_coverage / bound_clamped。`ungated` 必须为 0
                        # （非 0 = 有移动意图没经过权威寻路闸门）。
                        "movement": dict(result.state.get("movement_stats") or {}),
                        "nav_revision": int(result.state.get("nav_revision")
                                           if result.state.get("nav_revision") is not None
                                           else -1),
                        "batch": {
                            "calls": int(getattr(self.transport, "batch_count", 0)),
                            "commands": int(getattr(self.transport, "batch_commands", 0)),
                            "batches_submitted": int(getattr(
                                self.runtime.coordinator.metrics, "batches_submitted", 0)),
                        },
                    })
                    # 扫描层指标（计划 §9：快照年龄 p50/p95/max、扫描频率、事件延迟）。
                    #
                    # 【加固 · 2026-09-13 血泪】**只看的埋点绝不允许把整轮日志搞掉**：
                    # 这里曾经把统计变量写成不存在的 `scan_stats` → 每轮 `NameError` →
                    # 被外层 `except` 吞成 `tick_error`，于是**同轮后面的留档/决策/HUD/回执
                    # 全部被跳过**（实测 186/186 轮全中：`scan_hz=0`、档案 rounds 全空）。
                    # 所以这段单独包一层：埋点自己出错只记一行，绝不牵连后面的正经记录。
                    if self.scanner is not None:
                        try:
                            snapshot = self.scanner.latest() or {}
                            production = snapshot.get("production") or []
                            # 每轮只取一次扫描统计（留档与日志共用；重复调用会有锁竞争开销）。
                            scan_stats = self.scanner.stats()
                            self._last_scan_stats = scan_stats
                            # 【生产接续的可测事实】只有"队列项总数"看不出**有几座设施在同时干活**：
                            # 6 座设施共 1 个队列项 与 1 座设施 1 个队列项，前者是"整体在动、
                            # 局部空转"，后者是"只有一条线在动"。验收要的是前者，所以必须分开数。
                            busy_producers = sum(
                                1 for entry in production
                                if isinstance(entry, dict) and (entry.get("items") or []))
                            self._log({"kind": "fast_scan", "server_tick": tick_value,
                                       # 生产增量链路的自证：这两个数为 0 说明
                                       # "production_*" 事件永远不会产生（不能靠猜）。
                                       "fast_units": len(snapshot.get("units") or []),
                                       "fast_production_units": len(production),
                                       "fast_production_busy": busy_producers,
                                       "fast_production_items": sum(
                                           len(entry.get("items") or [])
                                           for entry in production if isinstance(entry, dict)),
                                       # 游戏侧 10Hz 采样的自身耗时（**副官通道对帧率的开销**）：
                                       # 玩家反馈掉帧时用它回答"是不是副官吃的"（实测踩过
                                       # `is_target_reachable` 每单位每 100ms 一次真寻路）。
                                       "sample_ms_p50": scan_stats.get("sample_ms_p50"),
                                       "sample_ms_p95": scan_stats.get("sample_ms_p95"),
                                       "sample_ms_max": scan_stats.get("sample_ms_max"),
                                       # 游戏帧率：与单位数/采样耗时同一条时间线（玩家最在意的数）。
                                       "fps": scan_stats.get("fps_last"),
                                       "fps_min": scan_stats.get("fps_min"),
                                       # 画质档（帧率治理）：验收据此验证"部队涨上来时画质降了没"。
                                       "quality_tier": scan_stats.get("quality_tier_last"),
                                       "quality_tier_max": scan_stats.get("quality_tier_max"),
                                       "quality_scale": scan_stats.get("quality_scale_last"),
                                       "fast_nav_revision": snapshot.get("nav_revision"),
                                       **scan_stats})
                        except Exception as exc:  # noqa: BLE001 —— 埋点出错只记一行
                            self._log({"kind": "scan_log_error", "server_tick": tick_value,
                                       "error": repr(exc)[:200]})
                    self._log_decision_delta(tick_value)
                    # 游戏内面板的"思考"内容：由 runner 直接给结论，HUD 只渲染。
                    self._log_hud_status(tick_value, result)
                    for receipt in result.receipts:
                        self._log({"kind": "receipt", "server_tick": tick_value,
                                   "receipt": receipt})
                    self._archive_round(tick_value, obs, result, {
                        "elapsed_ms": elapsed_ms, "coord_hz": coord_hz,
                        "observe_ms": observe_ms})
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
                if not self._match_alive():
                    idle_checks += 1
                    self._log({"kind": "idle", "consecutive": idle_checks,
                               "note": "match_active=false"})
                    if idle_checks >= int(self.args.max_idle_checks):
                        self._log({"kind": "stop", "reason": "no_active_match"})
                        break
                else:
                    idle_checks = 0
                # 【固定**节奏**而不是固定 sleep】原来每轮固定睡 `tick_interval`，
                # 处理耗时（观测 + 协调 + 写日志 + 扫描线程的 GIL 争用）被**叠加**上去：
                # 实测 tick_interval=0.5s 时实际只有 1.47~1.75Hz（计划要 2Hz）。
                # 改成"睡掉本轮剩余时间"，协调频率才真正等于 1/tick_interval。
                spent = time.time() - loop_started
                self._sleep(max(0.0, float(self.args.tick_interval) - spent))
        finally:
            if self.scanner is not None:
                self.scanner.stop()
                self._log({"kind": "fast_scan_final", **self.scanner.stats()})
            # 留档收尾：写 MANIFEST + 给分析模型的 digest（**每局都要有**）。
            state = getattr(self.runtime, "state", None)
            self._close_archive(status=self._stop_reason or "stopped", extra={
                "outcome": self._last_outcome,
                "exit_code": exit_code,
                "sent": self.transport.sent_count if self.transport else 0,
                "model_calls": len(self.model_sink),
                "degraded_reason": str(getattr(state, "degraded_reason", "") or ""),
                "route": str(getattr(state, "route", "") or ""),
                "plan_version": str(getattr(state, "plan_version", "") or ""),
                "units": len(getattr(state, "ai_controlled_units", None) or []),
            })
            try:
                if self.runtime is not None:
                    self.runtime.checkpoint()
            except Exception as exc:  # noqa: BLE001
                self._log({"kind": "checkpoint_error", "error": repr(exc)})
            self._remove_pidfile()
            self._release_single_instance()
            self._log({"kind": "exit", "code": exit_code, "reason": self._stop_reason,
                       "sent": self.transport.sent_count if self.transport else 0,
                       "model_calls": len(self.model_sink)})
            self._close_log()
        return exit_code

    def _maybe_rank_augments(self, obs: Dict[str, Any]) -> None:
        """看到本轮 offer 后异步请 Hermes 排序。失败则保持 Godot 规则星标。

        只发 `op=augment_recommend`，从不 `augment_pick` / `adjutant_intent`。
        """
        fast = obs.get("fast_state") or {}
        tactical = obs.get("tactical") or {}
        aug = fast.get("augments") if isinstance(fast.get("augments"), dict) else None
        if not isinstance(aug, dict):
            aug = tactical.get("augments") if isinstance(tactical.get("augments"), dict) else {}
        offer = aug.get("offer") or []
        if not offer:
            return
        try:
            round_index = int(aug.get("round_index", -1))
        except (TypeError, ValueError):
            round_index = -1
        if round_index < 0 or round_index == self._augment_ranked_round:
            return
        if self._augment_rank_inflight:
            return
        self._augment_rank_inflight = True
        units = fast.get("units") or []
        enemies = fast.get("visible_enemies") or []
        facts = {
            "army_count": len(units) if isinstance(units, list) else 0,
            "enemy_count": len(enemies) if isinstance(enemies, list) else 0,
            "structure_count": 0,
            "balance_a": int(((tactical.get("balance") or {}) if isinstance(tactical, dict) else {}).get("a") or 0),
        }
        payload = {
            "offer": offer,
            "facts": facts,
            "profile": {},
            "round_index": round_index,
        }
        port = self.port
        player = self.player

        def _work() -> None:
            source = "rules"
            try:
                from adjutant_coordinator.graph.augment_rank import rank_offer
                ranked = rank_offer(payload)
                source = str((ranked or {}).get("source") or "rules")
                tcp_json(port, {
                    "op": "augment_recommend",
                    "as_player": player,
                    "order": (ranked or {}).get("order") or [],
                    "reasons": (ranked or {}).get("reasons") or [],
                }, timeout=20.0)
                self._augment_ranked_round = round_index
                self._log({"kind": "augment_recommend", "round": round_index, "source": source})
            except Exception as exc:  # noqa: BLE001 —— 推荐失败不得影响指挥循环
                self._log({"kind": "augment_recommend_failed", "round": round_index,
                           "error": str(exc)[:200]})
            finally:
                self._augment_rank_inflight = False

        threading.Thread(target=_work, name="hermes-augment", daemon=True).start()

    def _observe(self):
        """取本轮观测：**完整视图按需刷新**，不每轮重拉（计划 §3.2 "按需读取"）。

        实测依据（2026-09-13，32 单位）：`op=tactical` + `op=strategic` 都是全场景扫描
        （tactical 还要对每个敌人再全扫一遍 = O(敌×我)），两者合计把协调主循环拖到
        **0.85Hz**，而 coordination 自身的处理只要 **70ms**。
        计划 P0 的完成条件是"协调平均频率接近 2Hz"，所以贵的那部分必须**按间隔刷新**：
        中间轮次复用上一份完整视图（它们仍然会被 `fast_state` 的新鲜事实覆盖——
        `node_ingest` 会先用扫描层的增量事件与 `nav_revision` 更新状态）。
        """
        now = time.time()
        cached = self._full_views
        fresh = (cached and now - float(cached.get("at", 0.0))
                 < float(getattr(self.args, "full_view_interval", 1.0) or 1.0))
        if fresh:
            views = cached["views"]
        else:
            views = fetch_views(self.port, self.player, self.rules_cache)
            self._full_views = {"at": now, "views": views}
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

    # ---------- 一对一硬约束（同一局只允许一个 runner） ----------

    @staticmethod
    def _pid_alive(pid: int) -> bool:
        """进程是否还活着（Windows 用 OpenProcess/GetExitCodeProcess）。"""
        if int(pid) <= 0:
            return False
        if os.name == "nt":
            import ctypes
            handle = ctypes.windll.kernel32.OpenProcess(0x1000, False, int(pid))
            if not handle:
                return False
            try:
                code = ctypes.c_ulong()
                ok = ctypes.windll.kernel32.GetExitCodeProcess(handle, ctypes.byref(code))
                return bool(ok) and code.value == 259      # STILL_ACTIVE
            finally:
                ctypes.windll.kernel32.CloseHandle(handle)
        try:
            os.kill(int(pid), 0)
        except OSError:
            return False
        return True

    def _single_instance_file(self) -> str:
        """本局 runner 的一对一锁文件（键 = authority_port + player）。

        与 `--pidfile` 分开：pidfile 是给游戏里"停止按钮"用的**固定路径**，
        而锁必须按**局**区分（不同端口/玩家互不影响）。
        """
        name = "agent_runner_%s_%s.lock" % (int(self.port), str(self.player or "auto"))
        return os.path.join(self.args.log_dir, name)

    def _acquire_single_instance(self) -> int:
        """抢本局唯一 runner 的锁：0 = 拿到；>0 = 已在跑的 runner 的 pid。

        为什么必须做（用户 2026-09-12 晚指出"一个对局会启动多个 runner"）：
        两个 runner 同时指挥同一局会 ① 对同一批单位下发**互相冲突**的命令
        （各自以为自己在执行计划）；② 在单并发的本地模型上互相排队 ——
        实测把"一次思考 0.7 秒"拖到 **4.7 秒**（当时的节拍测量就是这么被污染的）。
        陈旧锁（进程已死）会被自动接管，不会把下一次启动锁死。
        """
        path = self._single_instance_file()
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
        except OSError:
            pass
        try:
            handle = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError:
            occupant = 0
            try:
                with open(path, encoding="utf-8") as existing:
                    occupant = int((existing.read() or "0").strip() or "0")
            except (OSError, ValueError):
                occupant = 0
            if self._pid_alive(occupant):
                return occupant or -1
            try:                      # 陈旧锁：接管
                os.unlink(path)
            except OSError:
                return -1
            try:
                handle = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            except OSError:
                return -1
        except OSError:
            # 拿不到锁文件（权限/路径异常）不该把 runner 卡死：放行但留痕。
            self._log({"kind": "single_instance_unavailable", "path": path})
            return 0
        with os.fdopen(handle, "w", encoding="utf-8") as target:
            target.write(str(os.getpid()))
        return 0

    def _release_single_instance(self) -> None:
        try:
            os.unlink(self._single_instance_file())
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

    def _open_archive(self, describe: Dict[str, Any]) -> None:
        """打开本局留档（**只写事实、失败不影响对局**）。

        为什么不塞进 `runner.out`：那是运行日志，刻意只记摘要（事件只记计数、单位只记名字），
        复盘缺的恰是逐条明细。留档层写 `events/rounds/commands/model/decisions` 五个明细流
        + `MANIFEST.json` + `digest.md`（给分析模型的第一读物）。
        """
        try:
            self.archive = MatchArchive(
                self.args.log_dir, match_id=self.match_id, player=self.player,
                rules_version=self.rules_version,
                config={"provider": str(self.args.provider),
                        "interface": str(getattr(self.args, "interface", "")),
                        "model": str(getattr(self.args, "model", "")),
                        "strategy_mode": str(getattr(self.args, "strategy_mode", "")),
                        "tick_interval": float(getattr(self.args, "tick_interval", 0.5) or 0.5),
                        "engine": describe.get("engine"),
                        "port": self.port,
                        "graph_config": describe.get("config")})
            print("[runner] 留档：%s" % self.archive.dir)
        except Exception as exc:  # noqa: BLE001 —— 留档失败绝不影响指挥链
            self.archive = None
            print("[runner] 留档不可用（不影响对局）：%r" % exc, file=sys.stderr)

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
            # 记下路径：收尾时要从这里读 `command_timing` 合并进命令表（生命周期）。
            self._structured_path = path
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
    #: 面板专用措辞（比 ACTION_CN 的动作名更贴玩家看的"在干什么"）。
    LANE_CN = {"attack_move": "前压探索"}

    def _lane_summary(self) -> str:
        """把"四条线此刻各在干什么"压成一句面板文案（事实来自活跃意图）。

        用户 2026-09-12 晚："有这么多钱还在想着等待时机" —— 旧兜底文案在
        "规则中台正在维持采集/建造/生产/前压、本轮只是没有变化"时会被读成
        "AI 在发呆"。面板必须陈述事实，而不是给一句情绪化的空话。
        """
        try:
            intents = list(getattr(self.runtime.state, "active_intents", []) or [])
        except Exception:  # noqa: BLE001 —— 面板文案失败绝不影响指挥链
            return "正在维持既有任务"
        counted: Dict[str, int] = {}
        for intent in intents:
            if not isinstance(intent, dict):
                continue
            if str(intent.get("state", "")) not in ("active", "pending_authority",
                                                    "retry_wait", "active_unknown"):
                continue
            action = str(intent.get("action", ""))
            counted[action] = counted.get(action, 0) + max(
                1, len(intent.get("unit_ids") or []))
        if not counted:
            return "正在维持既有任务"
        parts = ["%s×%d" % (self.LANE_CN.get(action, self.ACTION_CN.get(action, action)),
                            number)
                 for action, number in sorted(counted.items(), key=lambda item: -item[1])[:4]]
        return "正在维持：" + "、".join(parts)

    #: 降级原因前缀 → 玩家能看懂的一句话（不暴露模型名/校验细节）。
    DEGRADE_CN = {
        "strategy_model_": "战略思考这一轮没成功，先用规则顶住",
        "tactics_model_": "战术思考这一轮没成功，先用规则顶住",
    }
    #: 仲裁丢弃原因前缀 → 面板中文标签（顺序即匹配优先级，长前缀在前）。
    #: 【2026-09-12 实机教训】副官"一条命令都发不出去"时，面板过去只写"本轮没有新命令"，
    #: 看上去像"一切正常"——用户当时报的是"看不到 AI 副官指挥部队的信标"，
    #: 实际原因却是全部被判重丢弃（`duplicate_of_live_intent`）卡死。丢弃原因不该只躺在日志里。
    DROP_CN = (
        ("duplicate_of_live_intent", "重复在途"),
        ("pending_authority_unresolved", "等待权威确认"),
        ("duplicate_intent_id_in_batch", "批次内重复"),
        ("duplicate_of", "重复批次"),
        ("lease_owner_player", "玩家已接管"),
        ("generation_mismatch", "控制代际过期"),
        ("reacquire_not_authorized", "未获重新接管授权"),
        ("batch_limit_exceeded", "超出本轮配额"),
        ("contract_invalid", "模型输出不合法"),
        ("intent_already_tracked", "已在执行"),
    )

    @classmethod
    def _dropped_reason_counts(cls, dropped: Any) -> Dict[str, int]:
        """把本轮丢弃原因聚合成 `{中文标签: 条数}`（键顺序 = 首次出现顺序）。"""
        counts: Dict[str, int] = {}
        for item in dropped or []:
            reason = str((item or {}).get("reason", "") or "").strip()
            label = "其他"
            for prefix, text in cls.DROP_CN:
                if reason.startswith(prefix):
                    label = text
                    break
            counts[label] = counts.get(label, 0) + 1
        return counts

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
                # 【不许再写"等待时机"】2026-09-12 晚用户质问："有这么多钱还在想着等待时机"。
                # 这句话在"规则中台正维持四条线、本轮只是没有**变化**"时会被读成"AI 在发呆"。
                # 面板要陈述事实：各条线此刻各有多少单位在执行什么。
                thinking = (("正在执行：%s" % "、".join(actions)) if actions
                            else self._lane_summary())
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
            # 2026-09-12：把"为什么没有（或少了）命令"一并写上面板。
            # 原先丢弃原因只进日志，面板仍显示"一切正常"，于是整局停摆只能靠
            # "看不到指挥信标"来猜 —— 这类静默失效必须在面板上直接可见。
            dropped_counts = self._dropped_reason_counts(
                getattr(result, "dropped_intents", None))
            if dropped_counts:
                result_text += "（丢弃 %d 条：%s）" % (
                    sum(dropped_counts.values()),
                    "、".join("%s×%d" % (label, count)
                              for label, count in dropped_counts.items()))
            mainline = self._mainline_text(state)
            payload = {
                "server_tick": int(tick_value),
                "phase": phase,
                "thinking": thinking[:60],
                "why": why[:60],
                "result": result_text[:80],
                # 战略阶段目标由模型产出（本来就是中文），给玩家一个"大方向"。
                # 整局主线（阶段 + 下一目标）优先，因为它**一定存在**（程序建立），
                # 而战略层默认是关闭的（`active_plan` 恒空 → 面板那一行永远是空的）。
                "goal": (mainline or str((state.active_plan or {}).get("phase_goal", "")))[:60],
                # 额外字段：HUD 不认识就忽略（旧面板不受影响），排查/验收直接读。
                "mainline": mainline[:60],
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

    @staticmethod
    def _mainline_text(state: Any) -> str:
        """整局主线的一句话（中文人话）：`阶段：扩张 · 下一目标：分基地/分矿`。

        为什么由 runner 生成：面板只渲染 `hud_status.json`（副官侧），游戏侧不改；
        而"这一局打到哪一步了"是玩家最该看到的一条信息（此前面板完全没有）。
        """
        campaign = getattr(state, "campaign_state", None) or {}
        if not isinstance(campaign, dict) or not campaign.get("milestones"):
            return ""
        try:
            from ..graph import campaign as campaign_mod
            summary = campaign_mod.summary(campaign)
        except Exception:  # noqa: BLE001 —— 表现层失败不影响指挥链
            return ""
        phase = str(summary.get("phase", "") or "")
        frontier = str(summary.get("frontier_name", "") or "")
        text = "阶段：%s" % (phase or "进行中")
        if frontier:
            text += " · 下一目标：%s" % frontier
        blocked = summary.get("blocked") or []
        if blocked:
            text += " · 受阻：%d 项" % len(blocked)
        return text

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
            # 同一份决策也进留档（分析时不必再解析 runner.out）。
            if self.archive is not None:
                try:
                    self.archive.decision(dict(entry))
                except Exception:  # noqa: BLE001 —— 留档失败绝不影响对局
                    pass

    def _archive_round(self, tick: int, obs: Dict[str, Any], result: Any,
                       metrics: Dict[str, Any]) -> None:
        """每轮把**世界事实**写进档（余额 / 我方单位 / 可见敌情 / 生产队列 / 扫描指标）。

        「世界事实」与「决策事实」分开：决策在 `decisions.jsonl`，世界在 `rounds.jsonl` ——
        分析时要能把"它做了什么"和"当时世界是什么样"按 tick 对上。
        """
        archive = self.archive
        if archive is None:
            return
        try:
            fast = obs.get("fast_state") or {}
            tactical = obs.get("tactical") or {}
            scan_stats = getattr(self, "_last_scan_stats", {}) or {}
            # 【必须先绑定】`intents` 字段用它，而它原来在**下面**才赋值 →
            # 每轮 `UnboundLocalError` → 被本函数的 `except` 记成 `archive_error`，
            # 于是 `rounds.jsonl`（每轮世界事实）**从来没有落过盘**（2026-09-13 实测
            # 档案里只有 decisions、没有 rounds，MANIFEST 只能写"runner 未写留档"）。
            live_intents = list((getattr(result, "state", {}) or {}).get("active_intents") or [])
            archive.round_({
                "server_tick": int(tick),
                "ts": time.time(),
                "balance": (tactical.get("balance") or {}).get("a"),
                "map_bounds": fast.get("map_bounds"),
                "nav_revision": fast.get("nav_revision"),
                "units": compact_units(fast.get("units")),
                "enemies": compact_enemies(fast.get("visible_enemies")),
                "production": compact_production(fast.get("production")),
                "route": str(getattr(result, "route", "")),
                "degraded_reason": str(getattr(result, "degraded_reason", "") or ""),
                "paused": bool(getattr(result, "paused", False)),
                "elapsed_ms": metrics.get("elapsed_ms"),
                "coord_hz": metrics.get("coord_hz"),
                "observe_ms": metrics.get("observe_ms"),
                "scan_hz": scan_stats.get("scan_hz"),
                "snapshot_age_p95": scan_stats.get("snapshot_age_p95"),
                # 【帧率与采样成本也写进每轮档案】档案里已经有"当时有多少单位"，
                # 加上这两个数，任何一局都能**直接**画出"帧率 vs 单位数 vs 副官开销"，
                # 不必再去 runner.out 里翻（用户 2026-09-13："掉帧到底谁吃的"）。
                "fps": scan_stats.get("fps_last"),
                # 【画质档也写进每轮档案】帧率治理（锁 60 + 单位多降画质）的验证就在这一行：
                # 档案里 `units` 与 `quality_tier` 同一条时间线，一眼能看出"降档有没有跟着规模"。
                "quality_tier": scan_stats.get("quality_tier_last"),
                "quality_scale": scan_stats.get("quality_scale_last"),
                "sample_ms_p50": scan_stats.get("sample_ms_p50"),
                "event_seq": fast.get("event_seq"),
                "augments": fast.get("augments"),
                "movement": dict((getattr(result, "state", {}) or {}).get("movement_stats") or {}),
                "lanes": dict((getattr(result, "state", {}) or {}).get("lanes") or {}),
                # 【任务侧事实】每轮把"我们的意图状态"也落档：否则"生产完成了但任务仍 unknown"
                # 这类问题在档案里看不见（只能去 raw 逐行猜）。见 `_compact_intents`。
                "intents": _compact_intents(live_intents),
                "tasks": {str(key): str(value) for key, value in
                          ((getattr(result, "state", {}) or {}).get("active_tasks") or {}).items()},
                # 【兵力上限留档】为什么这一轮没有出兵：达到上限（设计）还是没轮到（故障）。
                # 复盘时"没有意图"这一条必须有解释，否则分不清两者。
                "army_cap": dict((getattr(result, "state", {}) or {}).get("army_cap") or {}),
                # 【命令纪律的可测事实】"打不了的目标"记忆与敌人类型表各有多大 ——
                # 没有这两个数，"按域拉黑到底有没有生效"在档案里查不出来（用户要求可溯源）。
                "target_memory": dict((getattr(result, "state", {}) or {}
                                       ).get("target_memory") or {}),
                # 探索前沿（U1/F01）：`covered` = 真的到达过并换过的前沿数 ——
                # T01 的"≥3 个不同可达前沿"就用它判，且必须能在档案里复核。
                "explore": dict((getattr(result, "state", {}) or {}
                                 ).get("explore") or {}),
            })
            # 逐条游戏事件（复盘缺的就是这一层：谁被打了、谁死了、谁路走不通）。
            # 受伤/阵亡类事件额外补**上下文**（那时我们命令它干什么、附近有谁）——
            # 位置与命令都是已有事实的组合，不带归因（游戏侧受伤信号不带攻击者）。
            units_snapshot = compact_units(fast.get("units"))
            enemies_snapshot = compact_enemies(fast.get("visible_enemies"))
            for event in obs.get("fast_events") or []:
                if not isinstance(event, dict):
                    continue
                enriched = archive.enrich_event(
                    dict(event, server_tick=int(event.get("server_tick", tick) or tick)),
                    units=units_snapshot, enemies=enemies_snapshot, intents=live_intents)
                archive.event(enriched)
            # 命令生命周期：下发 → 权威回执。
            for receipt in getattr(result, "receipts", []) or []:
                if isinstance(receipt, dict):
                    archive.command({
                        "server_tick": int(tick),
                        "intent_id": str(receipt.get("intent_id", "")),
                        "command_id": str(receipt.get("command_id", "")),
                        "action": str(receipt.get("intent_action", "")
                                      or receipt.get("action", "")),
                        "unit_ids": list(receipt.get("unit_ids") or []),
                        "issued_tick": receipt.get("issued_tick"),
                        "expires_tick": receipt.get("expires_tick"),
                        "status": str(receipt.get("status", "")),
                        "accepted": bool(receipt.get("accepted", False)),
                        "reason": str(receipt.get("reason", ""))[:300],
                        "error_code": _first_error_code(receipt),
                        "order_id": _first_order_id(receipt),
                        "generation": receipt.get("generation"),
                        "task_id": str(receipt.get("task_id", "")),
                    })
            # 主线时间线：抽成 `MatchArchive.campaign_moments`（纯逻辑、有单测）。
            # 放这里只是为了"每轮调一次"，判断与去重都在留档层。
            archive.campaign_moments((getattr(result, "state", {}) or {}).get("campaign") or {})
            # 每轮刷一次缓冲（进程随时可能被打断，留档必须已经落盘）。
            archive.flush()
        except Exception as exc:  # noqa: BLE001 —— 留档失败绝不影响对局
            self._log({"kind": "archive_error", "error": repr(exc)})

    def _close_archive(self, *, status: str, extra: Dict[str, Any]) -> None:
        if self.archive is None:
            return
        try:
            # 命令生命周期：把图内 `command_timing`（决定→下发）合并进命令表，
            # 否则 `commands.jsonl` 只有回执，"为什么慢/为什么没接上"两段拼不起来。
            if self._structured_path and os.path.isfile(self._structured_path):
                merged = self.archive.command_lifecycle(
                    _read_jsonl(self._structured_path))
                if merged.get("merged"):
                    print("[runner] 命令生命周期合并：%s" % merged, flush=True)
        except Exception as exc:  # noqa: BLE001 —— 合并失败不影响收尾
            print("[runner] 命令生命周期合并失败：%r" % exc, file=sys.stderr)
        try:
            # 摘要以**磁盘上的明细**为准（进程被强杀时进度文件只到最近 10 轮）。
            self.archive.rebuild_from_files()
        except Exception:  # noqa: BLE001 —— 反推失败不影响收尾
            pass
        try:
            payload = self.archive.close(status=status, extra=extra)
            print("[runner] 留档完成：%s（%s，事件 %s 条，命令 %s 条，模型 %s 次）"
                  % (self.archive.dir, status,
                     (payload.get("counts") or {}).get("events", 0),
                     (payload.get("counts") or {}).get("commands", 0),
                     (payload.get("counts") or {}).get("model_calls", 0)))
        except Exception as exc:  # noqa: BLE001
            print("[runner] 留档收尾失败：%r" % exc, file=sys.stderr)

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
    parser.add_argument("--model", choices=("on", "off", "timeout", "empty", "invalid"),
                        default="on",
                        help="决策模型档位：on=真实/假模型（默认）；off=只跑规则中台+行为树；"
                             "timeout/empty/invalid=故障注入（验收混合架构的抗打断性）")
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
    # 副官强度等级（面板三个按钮 → 这里 → 规则地板的出击阈值）。映射单点定义在
    # `graph/intensity.py`；默认 standard 与历史行为完全一致，不带本参数时行为零变化。
    # ⚠ 这里**不用 `choices=`**：那会在 `build_parser()` 里提前导入 `graph` 包（连带
    # pydantic 契约，实测 ~2.1s），把 runner 冷启动握手推迟；等级照样在 setup 里规整，
    # 非法值回落 standard 而不是让进程起不来（见 intensity.normalize 的不变式 3）。
    parser.add_argument("--intensity", default="standard",
                        help="副官强度：conservative=保守（攒够 4 个作战单位才出击）；"
                             "standard=标准（默认，2 个）；aggressive=激进（1 个就出击）")
    parser.add_argument("--strategy-interval", type=int, default=1800,
                        help="战略模型最小间隔（tick，默认 1800≈30s）。"
                             "【不要砍到 900 以下】实测把战略间隔砍半后，战略模型失败次数与"
                             "重试耗时反而把主循环占满：5 分钟内 strategy_request=28 次、"
                             "tactics_request 只剩 **2** 次 → 微操层（发展阶梯+行为树）被饿死、"
                             "整局 0 生产、看不到任何批量指挥。战略层是低频慢层，"
                             "提速要靠微操高频跑（见 --tactics-interval / --event-interval）。")
    parser.add_argument("--tactics-interval", type=int, default=15,
                        help="战术决策最小间隔（tick，默认 15）。"
                        "【2026-09-15 用户反复要求提高操控频率】原默认 60≈1s → 30 → 现在 15。"
                        "⚠ **按 server_tick 计，不是按秒**：小图 60Hz ≈0.25s，"
                        "而**大地图物理只有 20Hz ⇒ 同一数值实际慢 3 倍**（大地图 15 tick ≈0.75s，"
                        "旧值 30 tick ≈1.5s）—— 这正是大地图上“操作频率低”的主因。"
                        "模型决策间隔与协调、命令下发频率分别记录。"
                        "验收重点是多线并发、生产接续和任务持续执行，不要求每秒下令。")
    parser.add_argument("--emergency-interval", type=int, default=30,
                        help="紧急事件最小间隔（tick，默认 30；⚠ 按 server_tick 计："
                             "小图 60Hz≈0.5s、大地图 20Hz≈1.5s）")
    parser.add_argument("--ttl", type=int, default=3600,
                        help="意图有效期（tick，默认 3600≈60s）。必须大于模型单次延迟"
                             "（实测 14~40s），否则意图会在下一批到来前过期，部队出现空窗。")
    parser.add_argument("--emergency-ttl", type=int, default=1200,
                        help="紧急意图有效期（tick，默认 1200≈20s）")
    parser.add_argument("--tick-interval", type=float, default=0.25,
                        help="协调周期（秒，默认 0.25=4Hz；原 0.5=2Hz 是"
                             "“操作频率低”的主频上限）。实测单轮 elapsed_ms 150~350ms，"
                             "0.25s 不会被处理耗时反超（主循环按"
                             "「睡掉本轮剩余时间」实现，频率=1/tick_interval）。"
                             "大规模对局如出现拥塞可回调到 0.5。")
    parser.add_argument("--full-view-interval", type=float, default=1.0,
                        help="完整 tactical/strategic 视图的刷新间隔（秒，默认 1.0）。"
                             "两者都是全场景扫描（tactical 还是 O(敌×我)），每轮重拉会把"
                             "协调主循环拖到 0.85Hz（实测 32 单位）；中间轮次复用缓存，"
                             "新鲜事实由 10Hz 扫描层的增量事件补上。")
    parser.add_argument("--scan-interval", type=float, default=0.1,
                        help="高频扫描节拍（秒，默认 0.1=10Hz；计划 §3.1 要求扫描约 10Hz）。"
                             "扫描走 op=adjutant_fast_state（读游戏侧缓存），不再全量重拉场景。")
    parser.add_argument("--scan", default="on", choices=("on", "off"),
                        help="是否启用 10Hz 缓存型扫描层（off = 退回旧的 0.5s 全量轮询，"
                             "用于对照与排障）")
    parser.add_argument("--event-interval", type=int, default=10,
                        help="观测事件节流（tick，默认 10）。"
                        "【2026-09-15 用户反复要求提高操控频率】原默认 60≈1s → 20 → 现在 10；"
                        "图侧的 `is_tactics_due` 要求「有事件」才会走战术分支 ⇒ 事件节流"
                        "实际就是决策频率的上限（与 `--tactics-interval` 取更严者）。"
                        "⚠ **按 server_tick 计**：大地图 20Hz 时 10 tick ≈0.5s。"
                        "须验证关键事件及时处理，不以命令发送次数作为验收门槛。")
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
    from adjutant_coordinator.graph.graph import langgraph_available
    availability = langgraph_available()
    print("[runner] langgraph_available=%s%s" % (
        availability["available"],
        "" if availability["available"] else " (%s)" % availability["reason"]))
    return AgentRunner(args).run()


if __name__ == "__main__":
    sys.exit(main())
