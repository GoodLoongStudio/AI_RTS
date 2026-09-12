# -*- coding: utf-8 -*-
"""有界异步决策调度：单一在途工作槽 + 有界队列 + 观测合并 + 过期拒绝 + 单调时钟退避。

依据（计划 §3「调度模型」、§7.C「有界异步调度」与实施顺序门槛 ②）：

- 同一时刻**至多一个在途工作槽**；普通观测**合并**（同一工作槽只保留最新观测）；
  紧急任务可在容量允许时插队，且有界队列满时按明确原因丢弃（不得静默）；
- **客户端等待超时 != 服务端停止推理**：本模块不"取消"已发出的请求，也不因为
  停止等待就允许新请求进入；只有工作**真正结束**才释放槽位（与 `pydantic_agents`
  现有的 `_INFLIGHT` 语义一致）；
- **过期结果只能拒绝**：结果到达时对照"本地接收期限 / 观测推进 / 逐对象代际"判定；
  不把结果里的旧信息刷新成新指令，也绝不据此推断单位或任务状态；
- **失败退避用单调时钟**：失败后一段时间内不再提交（指数退避、有上限），
  退避期间继续执行既有任务；
- 本模块**不改任何对局状态**：只产出"被接受的响应 / 被拒绝的原因"，状态变更仍由
  权威通道与图节点负责（避免出现第二个调度中心）。
"""

from __future__ import annotations

import threading
import time
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import Any, Callable, Deque, Dict, List, Optional, Tuple

#: 工作类别：普通观测（可合并）/ 紧急（插队）/ 对账（阶段 B 用）。
KIND_NORMAL = "normal"
KIND_EMERGENCY = "emergency"
KIND_RECONCILE = "reconcile"

#: 结果状态。
STATUS_OK = "ok"
STATUS_EXPIRED = "expired"
STATUS_STALE_SNAPSHOT = "stale_snapshot"
STATUS_STALE_GENERATION = "stale_generation"
STATUS_SUPERSEDED = "superseded"
STATUS_ERROR = "error"

#: 提交被拒原因。
REASON_BACKOFF = "backoff_active"
REASON_QUEUE_FULL = "queue_full"
REASON_IN_FLIGHT_EMERGENCY = "in_flight_emergency"


@dataclass
class Request:
    """一次决策请求（含发起时的观测、期限与逐对象代际绑定）。"""

    request_id: int
    kind: str
    frame: Any
    submitted_monotonic: float
    deadline_monotonic: float
    priority: int = 0
    merged: int = 0          # 该槽位在等待期间被更新的次数（观测合并）
    live_generations: Dict[str, int] = field(default_factory=dict)

    def to_dict(self) -> Dict[str, Any]:
        return {"request_id": self.request_id, "kind": self.kind, "priority": self.priority,
                "merged": self.merged, "server_tick": int(getattr(self.frame, "server_tick", 0) or 0),
                "snapshot_id": int(getattr(self.frame, "snapshot_id", 0) or 0),
                "deadline_seconds": round(self.deadline_monotonic - self.submitted_monotonic, 3)}


@dataclass
class Outcome:
    """一次决策结果（附"为什么接受/拒绝"，供逐项回执与验收）。"""

    request_id: int
    kind: str
    status: str
    reason: str = ""
    frame: Any = None
    value: Any = None
    decode: Any = None
    latency_ms: int = 0
    waited_ms: int = 0
    merged: int = 0

    @property
    def accepted(self) -> bool:
        return self.status == STATUS_OK

    def to_dict(self) -> Dict[str, Any]:
        return {"request_id": self.request_id, "kind": self.kind, "status": self.status,
                "reason": self.reason, "latency_ms": self.latency_ms,
                "waited_ms": self.waited_ms, "merged": self.merged}


class DecisionScheduler:
    """有界异步调度器。

    `call(request) -> Any`：真正执行模型调用的可调用对象（阻塞式，运行在工作线程里）；
    返回值由调用方约定（生产链路返回 `(IntentBatch, DecodeResult)` 或 `IntentBatch`）。
    """

    def __init__(self, call: Callable[[Request], Any], *,
                 clock: Callable[[], float] = time.monotonic,
                 max_normal_queue: int = 1,
                 max_emergency_queue: int = 2,
                 base_backoff_seconds: float = 0.5,
                 max_backoff_seconds: float = 8.0,
                 max_tick_drift: int = 600,
                 hard_timeout_seconds: float = 30.0) -> None:
        self._call = call
        self._clock = clock
        self._max_normal = max(0, int(max_normal_queue))
        self._max_emergency = max(0, int(max_emergency_queue))
        self._base_backoff = float(base_backoff_seconds)
        self._max_backoff = float(max_backoff_seconds)
        self._max_tick_drift = int(max_tick_drift)
        self._hard_timeout = float(hard_timeout_seconds)
        self._pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="adjutant-sched")
        self._lock = threading.Lock()
        self._results: Deque[Outcome] = deque()
        self._normal: Optional[Request] = None
        self._emergency: Deque[Request] = deque()
        self._reconcile: Deque[Request] = deque()
        self._in_flight: Optional[Request] = None
        self._next_id = 1
        self._failures = 0
        self._next_attempt_monotonic = 0.0
        self._last_error = ""
        self._stats: Dict[str, int] = {
            "submitted": 0, "merged": 0, "dropped": 0, "started": 0,
            "completed": 0, "rejected_expired": 0, "rejected_stale": 0,
            "errors": 0, "refused_backoff": 0, "refused_queue_full": 0,
        }

    # ---------------- 提交 ----------------

    def submit(self, frame: Any, *, kind: str = KIND_NORMAL,
               deadline_seconds: Optional[float] = None,
               live_generations: Optional[Dict[str, int]] = None,
               priority: int = 0) -> Tuple[bool, str]:
        """提交一次决策请求；**绝不阻塞**。返回 (是否被接受, 原因/说明)。"""
        now = self._clock()
        with self._lock:
            if now < self._next_attempt_monotonic:
                self._stats["refused_backoff"] += 1
                return False, "%s(%.1fs后重试)" % (
                    REASON_BACKOFF, self._next_attempt_monotonic - now)
            request = Request(
                request_id=self._next_id, kind=str(kind), frame=frame,
                submitted_monotonic=now,
                deadline_monotonic=now + float(deadline_seconds
                                               if deadline_seconds is not None else
                                               getattr(frame, "deadline_seconds", 3.0)),
                priority=int(priority),
                live_generations=dict(live_generations or {}))
            self._next_id += 1
            self._stats["submitted"] += 1
            if self._in_flight is not None and self._in_flight.kind == KIND_EMERGENCY \
                    and request.kind != KIND_EMERGENCY:
                # 紧急任务在途：普通观测不插队（避免抢占正在算的紧急决策）。
                self._stats["dropped"] += 1
                return False, REASON_IN_FLIGHT_EMERGENCY
            queued = self._enqueue_locked(request)
            if not queued:
                return False, REASON_QUEUE_FULL
            self._pump_locked()
            return True, "queued" if self._in_flight else "started"

    def _enqueue_locked(self, request: Request) -> bool:
        kind = request.kind
        if kind == KIND_EMERGENCY or kind == KIND_RECONCILE:
            bucket = self._emergency if kind == KIND_EMERGENCY else self._reconcile
            limit = self._max_emergency
            if len(bucket) >= limit:
                # 有界：优先丢最老的同一类；丢不掉就明确拒绝。
                if bucket:
                    bucket.popleft()
                    self._stats["dropped"] += 1
                else:
                    self._stats["refused_queue_full"] += 1
                    return False
            bucket.append(request)
            return True
        # 普通观测：同一工作槽**只保留最新**（合并），这才是"观测合并"的落点。
        # 容量只约束"待命槽"：系统闲置时任何提交都立即进槽（否则 0 容量会在空闲时也拒单）。
        if self._normal is None and self._in_flight is None:
            self._normal = request
            return True
        if self._max_normal <= 0:
            self._stats["dropped"] += 1
            return False
        if self._normal is None:
            self._normal = request
            return True
        merged = self._normal.merged + 1     # 合并计数要累加（不是重置）
        self._normal = request
        request.merged = merged
        self._stats["merged"] += 1
        return True

    def _pump_locked(self) -> None:
        if self._in_flight is not None:
            return
        request = self._take_next_locked()
        if request is None:
            return
        self._in_flight = request
        self._stats["started"] += 1
        self._pool.submit(self._work, request)

    def _take_next_locked(self) -> Optional[Request]:
        if self._emergency:
            return self._emergency.popleft()
        if self._reconcile:
            return self._reconcile.popleft()
        if self._normal is not None:
            request, self._normal = self._normal, None
            return request
        return None

    # ---------------- 工作线程 ----------------

    def _work(self, request: Request) -> None:
        started = self._clock()
        outcome = Outcome(request_id=request.request_id, kind=request.kind,
                          status=STATUS_OK, frame=request.frame, merged=request.merged)
        try:
            value = self._call(request)
            if isinstance(value, tuple) and len(value) == 2:
                outcome.value, outcome.decode = value
            else:
                outcome.value = value
            with self._lock:
                self._failures = 0
                self._next_attempt_monotonic = 0.0
        except Exception as exc:  # noqa: BLE001 —— 一切失败都归一化为失败退避
            outcome.status = STATUS_ERROR
            outcome.reason = "%s: %s" % (type(exc).__name__, str(exc)[:200])
            with self._lock:
                self._failures += 1
                backoff = min(self._max_backoff,
                              self._base_backoff * (2 ** max(0, self._failures - 1)))
                self._next_attempt_monotonic = self._clock() + backoff
                self._last_error = outcome.reason
                self._stats["errors"] += 1
        outcome.latency_ms = int((self._clock() - started) * 1000)
        outcome.waited_ms = int((started - request.submitted_monotonic) * 1000)
        with self._lock:
            self._results.append(outcome)
            self._in_flight = None
            self._stats["completed"] += 1
            # 槽位空出后继续排空队列（这一层保证"永远只有一个在途"）。
            self._pump_locked()

    # ---------------- 取结果（做新鲜度判定） ----------------

    def poll(self, *, current_generations: Optional[Dict[str, int]] = None,
             current_tick: Optional[int] = None) -> Optional[Outcome]:
        """非阻塞取一个已完成结果；就地做新鲜度判定并给出拒绝原因。"""
        with self._lock:
            if not self._results:
                return None
            outcome = self._results.popleft()
        if outcome.status != STATUS_OK:
            return outcome
        reason = self._freshness_problem(outcome.frame, current_generations, current_tick)
        if reason:
            # 注意：`reason` 是**状态码**（expired / stale_snapshot / stale_generation），
            # 一个字符串不能解包成两个字段（单测抓到的低级错误）。
            outcome.status = reason
            outcome.reason = reason
            with self._lock:
                if reason == STATUS_EXPIRED:
                    self._stats["rejected_expired"] += 1
                else:
                    self._stats["rejected_stale"] += 1
            # 过期/过期代际的结果**只拒绝**：不刷新、不覆盖新任务、不改状态。
        return outcome

    def _freshness_problem(self, frame: Any, current_generations: Optional[Dict[str, int]],
                           current_tick: Optional[int]) -> str:
        now = self._clock()
        if now > float(getattr(frame, "deadline_monotonic", now)):
            return STATUS_EXPIRED
        if current_tick is not None:
            drift = int(current_tick) - int(getattr(frame, "server_tick", 0) or 0)
            if drift > self._max_tick_drift:
                return STATUS_STALE_SNAPSHOT
        if current_generations:
            for unit, generation in (getattr(frame, "generations", {}) or {}).items():
                live = current_generations.get(str(unit))
                if live is not None and int(live) > int(generation or 0):
                    return STATUS_STALE_GENERATION
        return ""

    # ---------------- 观测与收尾 ----------------

    def stats(self) -> Dict[str, Any]:
        with self._lock:
            backoff = max(0.0, self._next_attempt_monotonic - self._clock())
            return dict(self._stats, pending_normal=1 if self._normal else 0,
                        pending_emergency=len(self._emergency),
                        pending_reconcile=len(self._reconcile),
                        in_flight=(self._in_flight.request_id
                                   if self._in_flight is not None else 0),
                        failures=self._failures,
                        backoff_seconds=round(backoff, 2),
                        last_error=self._last_error)

    def shutdown(self, wait: bool = False) -> None:
        self._pool.shutdown(wait=wait)


def build_scheduler_for_agent(agent: Any, **kwargs: Any) -> DecisionScheduler:
    """把四列 Agent 包装成调度器可调用的形式（生产接线用）。

    **只使用请求自带的 frame**：绝不在这里重新读取更新的状态——否则会把"发起时的
    观测"换成"结果到达时的观测"，正是计划禁止的刷新行为。

    返回 `(IntentBatch, DecodeResult)`：把**逐行接受/拒绝明细**一并交给调度器，
    这样决策日志才能落"模型到底选了什么"，而不是只看到"应用了但 0 任务"
    （2026-09-12 实测：异步路径只带 IntentBatch，导致 `summarize_decode(None)` 打出
    误导性的 `rows=0 accepted=0`，让接手方无法从日志看出"模型回了空"）。
    """
    def _call(request: Request) -> Any:
        value = agent.propose_task_patch(request.frame)
        return value, getattr(agent, "last_decode", None)

    return DecisionScheduler(_call, **kwargs)
