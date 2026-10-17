# -*- coding: utf-8 -*-
"""副官运行时决策追踪（第一阶段 · 修改 1：补齐运行时决策追踪）。

## 要回答的问题

从某次分支选择出发，能一路查到任务、命令、回执、后续事实和最终去向；也能反向
查询一个失败结果来自哪个目标和哪次尝试。相同 tick 的多轮、跨轮异步返回、重试
及暂停都不能串错。

## 合同（`TRACE_VERSION`）

每条事件是一个 JSON 对象（JSONL 一行一条），公共信封：

| 字段 | 含义 |
|---|---|
| `schema` / `version` | 固定 `airts-adjutant-trace` / 1；旧样本没有这些字段，读取方按缺失降级显示，**不得**为旧样本补造 |
| `seq` | 记录器内单调序号（跨轮有序；不用 tick 排序） |
| `session_id` | 对局会话 id（进程启动/新对局生成；checkpoint 恢复后沿用，重开对局=新 id） |
| `run_id` | 进程运行 id（`pid-<pid>-<rand>`）：重启/恢复后 round_seq 延续但 run_id 变，可区分"同一会话的不同进程段" |
| `match_id` / `player_id` | 对局身份（串局回执/观测按它隔离） |
| `round_seq` | 轮次序号（每 tick +1；**不是 tick**，相同 tick 的多轮不会串） |
| `server_tick` | 世界 tick（可与多轮相同；只作参考，不作顺序依据） |
| `ts_mono` / `ts_wall` | 单调时钟与墙钟（单调时钟算耗时；墙钟对时间轴） |
| `kind` / `phase` | 事件类别与阶段（enter/exit/error/submit/result/begin/end…） |

事件类别：`round`、`node_span`、`edge`、`candidate_eval`、`task`、`command`、
`model_call`、`note`。

## 关联纪律

- 任务身份：`task_id` + `attempt`（每次重试 attempt+1，任务 id 保持连续）；
  目标层级 `goal_id` / `parent_task_id`。
- 命令身份：`intent_id` + `command_id` + `attempt`（`command_id` 已含 attempt，
  不是纯 tick 构造）。
- 异步模型调用：提交与结果都用**请求帧身份**（match/player/server_tick/
  snapshot_id/plan_version/epoch/generations）关联，`request_id` 只作交叉索引；
  **不按"最近一次"猜因果**。
- 结果证据必须引用真实权威观测/回执/事件；未采集字段写 `unknown`，禁止用空值、
  0 或邻近事件冒充已测事实。

## 写入纪律

- 全量进 JSONL 流式文件（轮转、有界）；内存只保留有界环供进程内查询。
- **不塞进模型每轮上下文**：模型输入构建不读本模块。
- 任何写入异常只计数并可见（`stats()["diagnostic_errors']` + `note` 事件），
  **绝不抛回调用方**、绝不改变原任务结果。
- 只对**重复轮询**做聚合（`merged` 计数），不丢失状态变化、失败原因与关键证据。
"""

from __future__ import annotations

import json
import os
import threading
import time
import uuid
from collections import deque
from typing import Any, Callable, Deque, Dict, Iterable, List, Optional

#: 追踪合同标识。旧日志/旧样本没有这两个字段 → 读取方按"旧证据能力"显示，
#: 不得为旧样本补造 node span 或因果 ID。
TRACE_SCHEMA = "airts-adjutant-trace"
TRACE_VERSION = 1

# ---- 事件类别 ----
KIND_ROUND = "round"
KIND_NODE = "node_span"
KIND_EDGE = "edge"
KIND_CANDIDATE = "candidate_eval"
KIND_TASK = "task"
KIND_COMMAND = "command"
KIND_MODEL = "model_call"
KIND_NOTE = "note"

# ---- 阶段 ----
PHASE_BEGIN = "begin"
PHASE_END = "end"
PHASE_ENTER = "enter"
PHASE_EXIT = "exit"
PHASE_ERROR = "error"
PHASE_SUBMIT = "submit"
PHASE_RESULT = "result"

#: 内存环默认上限（条）。超出只丢最旧的；全量永远在文件里。
DEFAULT_MEMORY_LIMIT = 8192
#: 单文件默认字节上限（64 MiB）与轮转备份数。
DEFAULT_MAX_FILE_BYTES = 64 * 1024 * 1024
DEFAULT_BACKUPS = 2


def new_session_id() -> str:
    """对局会话 id：新对局生成；checkpoint 恢复沿用（保证跨进程段可关联）。"""
    return uuid.uuid4().hex[:16]


def new_run_id(pid: Optional[int] = None) -> str:
    """进程运行 id：runner 每进程一个；恢复后 round_seq 延续但 run_id 变。"""
    return "pid%s-%s" % (pid if pid is not None else os.getpid(), uuid.uuid4().hex[:8])


def frame_identity(frame: Any) -> Dict[str, Any]:
    """请求帧身份：异步"提交→结果"的**原关联**（不按最近时间猜因果）。

    只取提交时冻结的字段；结果到达时不得用新观测替换它们。
    """
    if frame is None:
        return {}
    out: Dict[str, Any] = {}
    for key in ("match_id", "player_id", "rules_version", "plan_version"):
        value = getattr(frame, key, None)
        if value not in (None, ""):
            out[key] = str(value)
    for key in ("server_tick", "snapshot_id", "strategy_epoch",
                "plan_adopt_generation", "control_generation"):
        value = getattr(frame, key, None)
        if isinstance(value, int):
            out[key] = int(value)
    generations = getattr(frame, "generations", None)
    if isinstance(generations, dict) and generations:
        # 代际表可能很大：只留稳定摘要（按键排序的轻量哈希），完整值在请求帧里。
        out["generations_digest"] = hash(tuple(sorted(
            (str(k), int(v or 0)) for k, v in generations.items()))) & 0xFFFFFFFF
    return out


class RotatingJsonlSink:
    """UTF-8 JSONL 文件 sink：逐行追加 + 大小轮转 + 写失败只计数不抛出。

    为什么不用 `logging`：追踪是**证据流**，要的是"进程被杀时已写行不丢"，
    所以每行 flush；轮转让单文件有界（磁盘写入限额的落实处）。
    """

    def __init__(self, path: str, *, max_bytes: int = DEFAULT_MAX_FILE_BYTES,
                 backups: int = DEFAULT_BACKUPS) -> None:
        self.path = str(path)
        self.max_bytes = max(4096, int(max_bytes))
        self.backups = max(0, int(backups))
        self._lock = threading.Lock()
        self._handle = None
        self._size = 0
        self._writes = 0
        self.errors = 0
        self.last_error = ""
        self._open()

    def _open(self) -> None:
        directory = os.path.dirname(os.path.abspath(self.path))
        if directory:
            os.makedirs(directory, exist_ok=True)
        self._handle = open(self.path, "a", encoding="utf-8")
        try:
            self._size = self._handle.tell()
        except OSError:
            self._size = 0

    def __call__(self, entry: Dict[str, Any]) -> None:
        line = json.dumps(entry, ensure_ascii=False, sort_keys=True, default=str)
        with self._lock:
            try:
                if self._handle is None:
                    self._open()
                self._handle.write(line + "\n")
                self._handle.flush()
                self._size += len(line) + 1
                self._writes += 1
                if self._size >= self.max_bytes:
                    self._rotate_locked()
            except Exception as exc:  # noqa: BLE001 —— 诊断写入永不拖垮指挥链
                self.errors += 1
                self.last_error = "%s: %s" % (type(exc).__name__, str(exc)[:200])
                # 句柄可能已损坏：丢掉它，下次重开（不静默继续往坏句柄写）。
                try:
                    if self._handle is not None:
                        self._handle.close()
                except Exception:  # noqa: BLE001
                    pass
                self._handle = None

    def _rotate_locked(self) -> None:
        try:
            if self._handle is not None:
                self._handle.close()
        except Exception:  # noqa: BLE001
            pass
        self._handle = None
        if self.backups <= 0:
            # 不保留备份：直接截断（有界优先于保留）。
            self._open()
            return
        for index in range(self.backups - 1, 0, -1):
            src = "%s.%d" % (self.path, index)
            dst = "%s.%d" % (self.path, index + 1)
            if os.path.exists(src):
                os.replace(src, dst)
        if os.path.exists(self.path):
            os.replace(self.path, "%s.1" % self.path)
        self._open()

    def close(self) -> None:
        with self._lock:
            if self._handle is not None:
                try:
                    self._handle.close()
                except Exception:  # noqa: BLE001
                    pass
                self._handle = None

    def stats(self) -> Dict[str, Any]:
        with self._lock:
            return {"path": self.path, "writes": self._writes, "bytes": self._size,
                    "errors": self.errors, "last_error": self.last_error,
                    "max_bytes": self.max_bytes, "backups": self.backups}


class MemoryRingSink:
    """内存 sink（测试/回放用）：保留全部条目供断言，条数有界。"""

    def __init__(self, limit: int = DEFAULT_MEMORY_LIMIT) -> None:
        self.entries: Deque[Dict[str, Any]] = deque(maxlen=max(1, int(limit)))
        self.errors = 0
        self.last_error = ""

    def __call__(self, entry: Dict[str, Any]) -> None:
        self.entries.append(entry)

    def close(self) -> None:
        return None

    def stats(self) -> Dict[str, Any]:
        return {"path": "memory", "writes": len(self.entries),
                "errors": self.errors, "last_error": self.last_error}


class TraceRecorder:
    """追踪记录器：事件信封 + 有界内存环 + 可选 JSONL 文件 + 进程内查询。

    所有公共方法都不抛异常：追踪是旁路证据链，失败只计数（`diagnostic_errors`）
    并以 `note` 事件留在内存环里可见。
    """

    def __init__(self, *, session_id: str, run_id: str, match_id: str = "",
                 player_id: str = "", sink: Optional[Callable[[Dict[str, Any]], None]] = None,
                 memory_limit: int = DEFAULT_MEMORY_LIMIT,
                 index_limit: int = 4096, enabled: bool = True) -> None:
        self.session_id = str(session_id or "")
        self.run_id = str(run_id or "")
        self.match_id = str(match_id or "")
        self.player_id = str(player_id or "")
        self.enabled = bool(enabled)
        self._sink = sink
        self._memory: Deque[Dict[str, Any]] = deque(maxlen=max(1, int(memory_limit)))
        self._index_limit = max(64, int(index_limit))
        # 有界索引：task/命令/节点 → 事件序号（查询用；丢最旧不丢文件证据）。
        self._by_task: Dict[str, Deque[int]] = {}
        self._by_command: Dict[str, Deque[int]] = {}
        self._by_node: Dict[str, Deque[int]] = {}
        self._seq = 0
        self._round_seq = 0
        self._lock = threading.Lock()
        self.diagnostic_errors = 0
        self.last_diagnostic_error = ""
        self._closed = False

    # ---------- 基础 ----------

    def set_identity(self, match_id: str, player_id: str) -> None:
        """重连/换局后更新身份（只影响后续事件信封）。"""
        self.match_id = str(match_id or "")
        self.player_id = str(player_id or "")

    def _emit(self, kind: str, phase: str, **fields: Any) -> Optional[Dict[str, Any]]:
        if not self.enabled or self._closed:
            return None
        with self._lock:
            self._seq += 1
            seq = self._seq
        entry: Dict[str, Any] = {
            "schema": TRACE_SCHEMA, "version": TRACE_VERSION, "seq": seq,
            "session_id": self.session_id, "run_id": self.run_id,
            "match_id": self.match_id, "player_id": self.player_id,
            "round_seq": self._round_seq,
            "server_tick": int(fields.pop("server_tick", 0) or 0),
            "ts_mono": round(time.monotonic(), 6), "ts_wall": time.time(),
            "kind": str(kind), "phase": str(phase or ""),
        }
        for key, value in fields.items():
            if value is None:
                continue
            entry[key] = value
        self._memory.append(entry)
        self._index(entry)
        if self._sink is not None:
            try:
                self._sink(entry)
            except Exception as exc:  # noqa: BLE001 —— 写入异常可见但不改结果
                self.diagnostic_errors += 1
                self.last_diagnostic_error = "%s: %s" % (type(exc).__name__, str(exc)[:200])
                self._memory.append(dict(entry, kind=KIND_NOTE, phase="diagnostic_error",
                                         error=self.last_diagnostic_error,
                                         original_kind=str(kind)))
        return entry

    def _index(self, entry: Dict[str, Any]) -> None:
        seq = int(entry.get("seq", 0))
        kind = str(entry.get("kind", ""))
        if kind == KIND_TASK:
            task_id = str(entry.get("task_id", ""))
            if task_id:
                self._push_index(self._by_task, task_id, seq)
        elif kind == KIND_COMMAND:
            for key in ("intent_id", "command_id"):
                value = str(entry.get(key, ""))
                if value:
                    self._push_index(self._by_command, value, seq)
        elif kind == KIND_NODE:
            node = str(entry.get("node", ""))
            if node:
                self._push_index(self._by_node, node, seq)

    def _push_index(self, table: Dict[str, Deque[int]], key: str, seq: int) -> None:
        """有界索引：每个键的 deque 有上限，**键总数也有上限**。

        P2-1 返修：旧实现只限每个键的 deque 长度，键数无上限——真实对局里
        intent_id 每轮都新（含 tick），1,559 条 dropped 事件就是 1,559 个键，
        索引本身变成无界缓存。现在超限时按插入顺序淘汰最旧的键（dict 保序），
        全量历史仍在 JSONL 文件里，查询只是进程内便利功能。
        """
        bucket = table.get(key)
        if bucket is None:
            if len(table) >= self._index_limit:
                for stale in list(table.keys())[:max(1, len(table) - self._index_limit + 1)]:
                    table.pop(stale, None)
            bucket = deque(maxlen=self._index_limit)
            table[key] = bucket
        bucket.append(seq)

    # ---------- 轮次 ----------

    def adopt_round_seq(self, seq: int) -> None:
        """恢复对局后沿袭 checkpoint 的轮次序号（避免与已写出的历史撞号）。

        只允许**前进**：恢复出的序号比当前还小（旧 checkpoint）时保持现值，
        绝不让序号回退（回退会让"同一 round_seq 两段历史"分不开）。
        """
        try:
            value = int(seq)
        except (TypeError, ValueError):
            return
        if value > self._round_seq:
            self._round_seq = value

    def begin_round(self, server_tick: int = 0, *, snapshot_id: int = 0,
                    observation: Optional[Dict[str, Any]] = None) -> Optional[int]:
        """开一轮；返回 round_seq（每 tick +1，与 tick 值无关）。禁用时返回 None。"""
        if not self.enabled or self._closed:
            return None
        self._round_seq += 1
        meta: Dict[str, Any] = {}
        if isinstance(observation, dict):
            events = observation.get("events")
            if isinstance(events, list):
                meta["observation_events"] = len(events)
            meta["observation_keys"] = sorted(str(k) for k in observation.keys())[:12]
        self._emit(KIND_ROUND, PHASE_BEGIN, server_tick=server_tick,
                   snapshot_id=int(snapshot_id or 0), **meta)
        return self._round_seq

    def end_round(self, *, route: str = "", elapsed_ms: float = 0.0,
                  server_tick: int = 0, extra: Optional[Dict[str, Any]] = None) -> None:
        payload: Dict[str, Any] = {"route": str(route or ""),
                                   "elapsed_ms": round(float(elapsed_ms or 0.0), 2)}
        if extra:
            payload.update(extra)
        self._emit(KIND_ROUND, PHASE_END, server_tick=server_tick, **payload)

    # ---------- 节点与边 ----------

    def node_enter(self, node: str, span_id: str = "", server_tick: int = 0) -> None:
        self._emit(KIND_NODE, PHASE_ENTER, node=str(node), span_id=str(span_id or ""),
                   server_tick=server_tick)

    def node_exit(self, node: str, span_id: str = "", *, duration_ms: float = 0.0,
                  server_tick: int = 0, summary: Optional[Dict[str, Any]] = None) -> None:
        payload: Dict[str, Any] = {"node": str(node), "span_id": str(span_id or ""),
                                   "duration_ms": round(float(duration_ms or 0.0), 2)}
        if summary:
            payload["summary"] = summary
        self._emit(KIND_NODE, PHASE_EXIT, server_tick=server_tick, **payload)

    def node_error(self, node: str, span_id: str = "", *, duration_ms: float = 0.0,
                   error: str = "", server_tick: int = 0) -> None:
        self._emit(KIND_NODE, PHASE_ERROR, node=str(node), span_id=str(span_id or ""),
                   duration_ms=round(float(duration_ms or 0.0), 2),
                   error=str(error or "")[:300], server_tick=server_tick)

    def edge(self, from_node: str, to_node: str, *, route: str = "",
             reason_code: str = "", reason_cn: str = "",
             detail: Optional[Dict[str, Any]] = None, server_tick: int = 0) -> None:
        """实际选择的边（含为什么）。异常/超时/取消/玩家打断也走这里留终态。"""
        payload: Dict[str, Any] = {
            "from": str(from_node or ""), "to": str(to_node or ""),
            "route": str(route or ""), "reason_code": str(reason_code or ""),
            "reason_cn": str(reason_cn or "")}
        if detail:
            payload["detail"] = detail
        self._emit(KIND_EDGE, PHASE_END, server_tick=server_tick, **payload)

    # ---------- 候选评估 ----------

    def candidate_eval(self, node_id: str, name: str, *, conditions: List[Dict[str, Any]],
                       available: bool, reason_code: str = "", reason_cn: str = "",
                       server_tick: int = 0) -> None:
        """候选入口条件逐项值/结果/缺项（可选、被排除、实际选择在此区分）。"""
        self._emit(KIND_CANDIDATE, PHASE_END, node=str(node_id), name=str(name),
                   conditions=list(conditions or []), available=bool(available),
                   reason_code=str(reason_code or ""), reason_cn=str(reason_cn or ""),
                   server_tick=server_tick)

    # ---------- 任务 ----------

    def task(self, task_id: str, event: str, *, goal_id: str = "",
             parent_task_id: str = "", attempt: int = 0, plan_version: str = "",
             state: str = "", reason_code: str = "", reason_cn: str = "",
             metric: Optional[Dict[str, Any]] = None, server_tick: int = 0,
             **extra: Any) -> None:
        """任务生命周期事件：created/progress/waiting/succeeded/failed/timeout/
        blocked/diagnose/recovering/reassigned/interrupted/expired。"""
        payload: Dict[str, Any] = {
            "task_id": str(task_id or ""), "event": str(event or ""),
            "goal_id": str(goal_id or ""), "parent_task_id": str(parent_task_id or ""),
            "attempt": int(attempt or 0), "plan_version": str(plan_version or ""),
            "state": str(state or ""), "reason_code": str(reason_code or ""),
            "reason_cn": str(reason_cn or "")}
        if metric:
            payload["metric"] = metric
        payload.update(extra)
        self._emit(KIND_TASK, PHASE_END, server_tick=server_tick, **payload)

    # ---------- 命令 ----------

    def command(self, intent_id: str, event: str, *, command_id: str = "",
                attempt: int = 0, action: str = "", unit_ids: Optional[List[str]] = None,
                task_id: str = "", status: str = "", reason: str = "",
                server_tick: int = 0, **extra: Any) -> None:
        """命令生命周期：submitted/accepted/rejected/pending/timeout/recheck/executed。"""
        payload: Dict[str, Any] = {
            "intent_id": str(intent_id or ""), "event": str(event or ""),
            "command_id": str(command_id or ""), "attempt": int(attempt or 0),
            "action": str(action or ""), "task_id": str(task_id or ""),
            "unit_ids": [str(u) for u in (unit_ids or [])][:16],
            "status": str(status or ""), "reason": str(reason or "")[:300]}
        payload.update(extra)
        self._emit(KIND_COMMAND, PHASE_END, server_tick=server_tick, **payload)

    # ---------- 模型调用 ----------

    def model_call(self, role: str, phase: str, *, request_id: int = 0,
                   frame: Any = None, status: str = "", reason: str = "",
                   latency_ms: int = 0, waited_ms: int = 0, merged: int = 0,
                   server_tick: int = 0, **extra: Any) -> None:
        """异步模型调用：submit 与 result 用帧身份关联（request_id 交叉索引）。"""
        payload: Dict[str, Any] = {
            "role": str(role or ""), "request_id": int(request_id or 0),
            "status": str(status or ""), "reason": str(reason or "")[:300],
            "latency_ms": int(latency_ms or 0), "waited_ms": int(waited_ms or 0),
            "merged": int(merged or 0)}
        identity = frame_identity(frame)
        if identity:
            payload["frame"] = identity
        payload.update(extra)
        self._emit(KIND_MODEL, str(phase or ""), server_tick=server_tick, **payload)

    # ---------- 其它留痕 ----------

    def note(self, kind: str, **fields: Any) -> None:
        """异常/超时/取消/玩家打断/恢复评估等结构化留痕（含短中文解释）。"""
        server_tick = int(fields.pop("server_tick", 0) or 0)
        self._emit(KIND_NOTE, PHASE_END, note=str(kind), server_tick=server_tick, **fields)

    # ---------- 查询与统计 ----------

    @property
    def round_seq(self) -> int:
        return self._round_seq

    def query(self, *, kind: str = "", task_id: str = "", node: str = "",
              intent_id: str = "", command_id: str = "", limit: int = 200
              ) -> List[Dict[str, Any]]:
        """进程内查询（内存环 + 有界索引）。全量历史读 JSONL 文件。"""
        seqs: Optional[Iterable[int]] = None
        if task_id:
            seqs = list(self._by_task.get(str(task_id), ()))
        if intent_id or command_id:
            wanted: List[int] = []
            if intent_id:
                wanted.extend(self._by_command.get(str(intent_id), ()))
            if command_id:
                wanted.extend(self._by_command.get(str(command_id), ()))
            seqs = wanted if seqs is None else [s for s in seqs if s in set(wanted)]
        if node:
            by_node = list(self._by_node.get(str(node), ()))
            seqs = by_node if seqs is None else [s for s in seqs if s in set(by_node)]
        out: List[Dict[str, Any]] = []
        for entry in reversed(self._memory):
            if len(out) >= max(1, int(limit)):
                break
            if seqs is not None and int(entry.get("seq", 0)) not in set(seqs):
                continue
            if kind and str(entry.get("kind", "")) != str(kind):
                continue
            out.append(dict(entry))
        out.reverse()
        return out

    def stats(self) -> Dict[str, Any]:
        sink_stats: Dict[str, Any] = {}
        if self._sink is not None and hasattr(self._sink, "stats"):
            try:
                sink_stats = dict(self._sink.stats())
            except Exception:  # noqa: BLE001 —— 统计失败不影响主链
                sink_stats = {}
        return {
            "enabled": self.enabled, "session_id": self.session_id,
            "run_id": self.run_id, "match_id": self.match_id,
            "player_id": self.player_id, "events": self._seq,
            "rounds": self._round_seq, "memory": len(self._memory),
            "memory_limit": self._memory.maxlen,
            "diagnostic_errors": self.diagnostic_errors,
            "last_diagnostic_error": self.last_diagnostic_error,
            "sink": sink_stats,
        }

    def close(self) -> None:
        self._closed = True
        if self._sink is not None and hasattr(self._sink, "close"):
            try:
                self._sink.close()
            except Exception:  # noqa: BLE001 —— 关闭失败只留统计
                self.diagnostic_errors += 1


class NullTraceRecorder(TraceRecorder):
    """禁用追踪的显式实现（不写文件、不留内存，方法仍可安全调用）。"""

    def __init__(self) -> None:
        super().__init__(session_id="", run_id="", enabled=False)


def build_recorder(*, session_id: str, run_id: str, match_id: str = "",
                   player_id: str = "", path: str = "", memory_limit: int = DEFAULT_MEMORY_LIMIT,
                   max_file_bytes: int = DEFAULT_MAX_FILE_BYTES, backups: int = DEFAULT_BACKUPS,
                   enabled: bool = True) -> TraceRecorder:
    """按配置构造记录器：给路径 → JSONL 文件 + 内存环；不给 → 仅内存环。"""
    if not enabled:
        return NullTraceRecorder()
    sink: Optional[Callable[[Dict[str, Any]], None]] = None
    if str(path or "").strip():
        sink = RotatingJsonlSink(str(path), max_bytes=int(max_file_bytes),
                                 backups=int(backups))
    return TraceRecorder(session_id=session_id, run_id=run_id, match_id=match_id,
                         player_id=player_id, sink=sink, memory_limit=int(memory_limit),
                         enabled=True)


def load_trace(path: str) -> List[Dict[str, Any]]:
    """流式读取一个 trace JSONL（回放/导出用；坏行跳过并保留行号供诊断）。"""
    events: List[Dict[str, Any]] = []
    with open(path, "r", encoding="utf-8") as handle:
        for line_no, raw in enumerate(handle, start=1):
            line = raw.strip()
            if not line:
                continue
            try:
                item = json.loads(line)
            except ValueError:
                continue
            if isinstance(item, dict):
                item.setdefault("_line", line_no)
                events.append(item)
    return events


def task_chain(events: List[Dict[str, Any]], task_id: str) -> List[Dict[str, Any]]:
    """反向/正向查询：一个失败结果来自哪个目标、哪次尝试（按 seq 排序）。"""
    wanted = str(task_id or "")
    rows = [e for e in events if str(e.get("task_id", "")) == wanted]
    rows.sort(key=lambda item: int(item.get("seq", 0)))
    return rows


def command_chain(events: List[Dict[str, Any]], intent_id: str = "",
                  command_id: str = "") -> List[Dict[str, Any]]:
    """命令链：提交 → 回执 → 复核 → 结果（同一 intent/command 的全部事件）。"""
    rows = []
    for entry in events:
        if intent_id and str(entry.get("intent_id", "")) == str(intent_id):
            rows.append(entry)
        elif command_id and str(entry.get("command_id", "")) == str(command_id):
            rows.append(entry)
    rows.sort(key=lambda item: int(item.get("seq", 0)))
    return rows


__all__ = [
    "TRACE_SCHEMA", "TRACE_VERSION", "KIND_ROUND", "KIND_NODE", "KIND_EDGE",
    "KIND_CANDIDATE", "KIND_TASK", "KIND_COMMAND", "KIND_MODEL", "KIND_NOTE",
    "PHASE_BEGIN", "PHASE_END", "PHASE_ENTER", "PHASE_EXIT", "PHASE_ERROR",
    "PHASE_SUBMIT", "PHASE_RESULT", "TraceRecorder", "NullTraceRecorder",
    "RotatingJsonlSink", "MemoryRingSink", "build_recorder", "new_session_id",
    "new_run_id", "frame_identity", "load_trace", "task_chain", "command_chain",
]
