# -*- coding: utf-8 -*-
"""副官协调器核心与确定性假模型。

协调器职责（architecture.md 第 1、4 节）：
- 调度战略/战术两个角色；战略输出计划，战术输出有限命令批次；
- 模型并行提出意图，协调器按顺序提交权威入口（逐条、非原子）；
- 同一角色同一对局最多一个活动模型请求；超时请求按代际丢弃；
- 资源预留是副官花费约束：已接受的实际支出累计计入，禁止重复计扣；
- 模型不可用时保持既有合法任务，显式降级，不捏造决策。

假模型仅用于确定性协议测试，不代表真实双模型闭环。
"""

import time
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, Tuple

from .events import Event, EventBus
from .protocol import Receipt, validate_command_envelope, validate_plan
from .state import (
    TASK_CANCELLED, TASK_FAILED, TASK_PENDING, TASK_RUNNING, TASK_UNKNOWN,
    AdoptedPlan, ControlLease, PlanStore, TaskTracker,
)

REQUEST_STATUS_PENDING = "pending"
REQUEST_STATUS_TIMED_OUT = "timed_out"
REQUEST_STATUS_COMPLETED = "completed"
REQUEST_STATUS_STALE = "stale"


@dataclass
class ModelRequest:
    """一次模型请求的代际记录；迟到返回必须按代际与状态重新校验。"""

    request_id: str
    role: str
    issued_tick: int
    deadline_tick: int
    status: str = REQUEST_STATUS_PENDING
    result: Any = None


class StrategyModel:
    """战略角色接口：输出阶段计划，不直接调用游戏命令。"""

    def propose_plan(self, context: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        raise NotImplementedError


class TacticsModel:
    """战术角色接口：按计划与局部事件提出有限命令批次。"""

    def propose_commands(self, context: Dict[str, Any]) -> List[Dict[str, Any]]:
        raise NotImplementedError


class FakeStrategyModel(StrategyModel):
    """确定性假战略模型：按脚本序列输出计划，用于协议测试。"""

    def __init__(self, script: List[Dict[str, Any]]) -> None:
        self._script = list(script)
        self.calls = 0

    def propose_plan(self, context: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        self.calls += 1
        if self._script:
            return self._script.pop(0)
        return None


class FakeTacticsModel(TacticsModel):
    """确定性假战术模型：按脚本序列输出命令批次，用于协议测试。"""

    def __init__(self, script: List[List[Dict[str, Any]]]) -> None:
        self._script = list(script)
        self.calls = 0

    def propose_commands(self, context: Dict[str, Any]) -> List[Dict[str, Any]]:
        self.calls += 1
        if self._script:
            return self._script.pop(0)
        return []


@dataclass
class CoordinatorConfig:
    """全部间隔与预算均配置化；数值是起点，以实测为准，不是响应时延保证。"""

    strategy_interval_ticks: int = 3600          # 60s @60Hz
    strategy_event_trigger_kinds: tuple = ("match_started", "outcome_changed")
    tactics_interval_ticks: int = 30             # 0.5s @60Hz
    request_timeout_ticks: int = 120             # 2s 模型请求超时
    retry_limit: int = 3
    retry_backoff_ticks: int = 30
    max_batch_size: int = 8                      # 战术每批上限
    budget_reserve_ticks: int = 600              # 预留约束的复核窗口


@dataclass
class CoordinatorMetrics:
    strategy_calls: int = 0
    tactics_calls: int = 0
    strategy_timeouts: int = 0
    tactics_timeouts: int = 0
    retries: int = 0
    stale_returns: int = 0
    commands_submitted: int = 0
    commands_accepted: int = 0
    commands_rejected: int = 0
    commands_pending: int = 0
    #: 批量提交效果（计划 §9 要"批量提交效果"这一项）：批次数 / 批内命令总数。
    #: 用它算"平均每批几条"，直接对比"逐条 TCP"降到多少往返。
    batches_submitted: int = 0
    batched_commands: int = 0
    budget_rejected: int = 0
    degraded_ticks: int = 0
    started_at: float = field(default_factory=time.time)


class AdjutantCoordinator:
    """单个 (match, player) 的逻辑写入协调器。

    transport: command_id -> receipt dict；由接入层注入（真实 TCP 或测试桩）。
    协调器在提交前做协议校验、租约校验与预算校验；游戏侧权威校验兜底。
    """

    def __init__(
        self,
        match_id: str,
        player_id: str,
        transport: Callable[[Dict[str, Any]], Dict[str, Any]],
        strategy_model: Optional[StrategyModel] = None,
        tactics_model: Optional[TacticsModel] = None,
        config: Optional[CoordinatorConfig] = None,
    ) -> None:
        self.match_id = match_id
        self.player_id = player_id
        # transport 归一化：既接受第一阶段裸 Callable(envelope)->receipt，
        # 也接受第二阶段 Transport 对象（有 send_command 方法）。
        if hasattr(transport, "send_command"):
            self._transport = transport.send_command
        else:
            self._transport = transport
        self._strategy = strategy_model
        self._tactics = tactics_model
        self.config = config or CoordinatorConfig()

        self.plans = PlanStore()
        self.tasks = TaskTracker()
        self.leases = ControlLease()
        self.events = EventBus()

        self.metrics = CoordinatorMetrics()
        self.decisions: List[Dict[str, Any]] = []
        self.degraded = False
        self._degrade_reason = ""
        self._retry_counts = {"strategy": 0, "tactics": 0}
        self._last_strategy_tick = None
        self._last_tactics_tick = None
        self._active_requests: Dict[str, ModelRequest] = {}
        self._latest_snapshot_id = 0
        self._rules_version = ""
        self._reserve_budget: Dict[str, int] = {}
        self._spent: Dict[str, int] = {}
        self._last_event_tick_by_kind: Dict[str, int] = {}

    # ---------- 上下文与观测 ----------

    def ingest_snapshot(self, header: Dict[str, Any], context: Dict[str, Any]) -> None:
        """消费观测包头：快照序号、规则版本；断线恢复后由快照重建事实。"""
        self._latest_snapshot_id = max(
            self._latest_snapshot_id, int(header.get("snapshot_id", 0)))
        self._rules_version = str(header.get("rules_version", self._rules_version))
        outcome = context.get("outcome")
        if outcome is not None:
            self._last_event_tick_by_kind.setdefault("outcome_changed", -1)

    def push_event(self, kind: str, server_tick: int, payload: Optional[Dict] = None,
                   event_id: str = "") -> None:
        self.events.push(Event(
            event_id=event_id or "evt-%d-%s" % (server_tick, kind),
            kind=kind,
            match_id=self.match_id,
            player_id=self.player_id,
            server_tick=server_tick,
            payload=payload or {},
        ))

    # ---------- 玩家优先权 ----------

    def notify_player_override(self, unit_ids: List[str]) -> None:
        """玩家手动命令：立即取消副官对相关单位的租约（玩家优先权）。"""
        self.leases.player_override(unit_ids)
        self.push_event("player_override", self._current_tick_hint(), {"subject": ",".join(unit_ids)})

    # ---------- 主循环 ----------

    def tick(self, current_tick: int, context: Optional[Dict[str, Any]] = None) -> None:
        """协调器逻辑时钟入口；current_tick 必须来自服务器 tick。"""
        context = context or {}
        self._reap_timed_out_requests(current_tick)
        self._maybe_request_plan(current_tick, context)
        self._maybe_request_tactics(current_tick, context)

    def _reap_timed_out_requests(self, current_tick: int) -> None:
        for request_id, request in list(self._active_requests.items()):
            if request.status == REQUEST_STATUS_PENDING and current_tick > request.deadline_tick:
                request.status = REQUEST_STATUS_TIMED_OUT
                if request.role == "strategy":
                    self.metrics.strategy_timeouts += 1
                else:
                    self.metrics.tactics_timeouts += 1

    def _maybe_request_plan(self, current_tick: int, context: Dict[str, Any]) -> None:
        if self._strategy is None:
            return
        interval_due = (
            self._last_strategy_tick is None
            or current_tick - self._last_strategy_tick >= self.config.strategy_interval_ticks
        )
        event_due = any(
            self._last_event_tick_by_kind.get(kind, -10**9) >= 0
            for kind in self.config.strategy_event_trigger_kinds
        ) and self.plans.expired(current_tick)
        if not (interval_due or event_due):
            return
        if self._has_pending_request("strategy"):
            return
        self._last_strategy_tick = current_tick
        self._call_strategy(current_tick, context)

    def adopt_plan(self, plan: Dict[str, Any], current_tick: int) -> "Tuple[bool, str]":
        """公共计划采纳入口（第二阶段 HostScheduler 使用）。

        校验 + 采纳 + 任务注册 + 预留同步；旧计划（版本不递增）被 PlanStore 拒绝。
        返回 (accepted, reason)。"""
        errors = validate_plan(plan, self._validation_context(current_tick))
        if errors:
            self.append_decision("plan_invalid", {"errors": errors, "tick": current_tick})
            return False, "invalid plan: %s" % "; ".join(errors)
        accepted, reason = self.plans.submit(plan, current_tick)
        if accepted:
            for task in plan.get("tasks", []):
                self.tasks.register(task.get("task_id", ""))
            self._reserve_budget = dict(plan.get("reserves", {}) or {})
            self.append_decision("plan_adopted", {
                "plan_id": plan.get("plan_id"), "plan_version": plan.get("plan_version"),
                "reason": reason, "tick": current_tick,
            })
        else:
            self.append_decision("plan_rejected", {"reason": reason, "tick": current_tick})
        return accepted, reason

    def submit_commands_batch(self, commands: List[Dict[str, Any]],
                              current_tick: int) -> List[Receipt]:
        """公共批次入口：逐条提交，返回逐条回执（明确非原子）。"""
        receipts: List[Receipt] = []
        for command in commands:
            receipts.append(self.submit_command(command, current_tick))
        return receipts

    def _call_strategy(self, current_tick: int, context: Dict[str, Any]) -> None:
        self.metrics.strategy_calls += 1
        request_id = "strat-%d-%d" % (current_tick, self.metrics.strategy_calls)
        request = ModelRequest(
            request_id=request_id, role="strategy", issued_tick=current_tick,
            deadline_tick=current_tick + self.config.request_timeout_ticks)
        self._active_requests[request_id] = request
        try:
            plan = self._strategy.propose_plan(self._strategy_context(current_tick, context))
        except Exception:  # 模型异常：限次退避重试，不无限调用。
            request.status = REQUEST_STATUS_TIMED_OUT
            self._retry("strategy", current_tick, context)
            self._set_degraded(True, "strategy model error")
            return
        request.result = plan
        request.status = REQUEST_STATUS_COMPLETED
        self._set_degraded(False, "")
        if plan is None:
            return
        accepted, reason = self.adopt_plan(plan, current_tick)
        if not accepted and reason.startswith("invalid plan"):
            self._retry("strategy", current_tick, context)

    def _maybe_request_tactics(self, current_tick: int, context: Dict[str, Any]) -> None:
        if self._tactics is None:
            return
        if self._last_tactics_tick is not None and \
                current_tick - self._last_tactics_tick < self.config.tactics_interval_ticks:
            return
        if self._has_pending_request("tactics"):
            return
        self._last_tactics_tick = current_tick
        self._call_tactics(current_tick, context)

    def _call_tactics(self, current_tick: int, context: Dict[str, Any]) -> None:
        self.metrics.tactics_calls += 1
        request_id = "tact-%d-%d" % (current_tick, self.metrics.tactics_calls)
        request = ModelRequest(
            request_id=request_id, role="tactics", issued_tick=current_tick,
            deadline_tick=current_tick + self.config.request_timeout_ticks)
        self._active_requests[request_id] = request
        try:
            commands = self._tactics.propose_commands(self._tactics_context(current_tick, context))
        except Exception:
            request.status = REQUEST_STATUS_TIMED_OUT
            self._retry("tactics", current_tick, context)
            self._set_degraded(True, "tactics model error")
            return
        request.result = commands
        request.status = REQUEST_STATUS_COMPLETED
        self._set_degraded(False, "")
        if not commands:
            return
        for command in commands[: self.config.max_batch_size]:
            self.submit_command(command, current_tick)

    def _retry(self, role: str, current_tick: int, context: Dict[str, Any]) -> None:
        count = self._retry_counts.get(role, 0)
        if count >= self.config.retry_limit:
            self._set_degraded(True, "%s retry limit reached" % role)
            return
        self._retry_counts[role] = count + 1
        self.metrics.retries += 1
        next_tick = current_tick + self.config.retry_backoff_ticks
        if role == "strategy":
            self._last_strategy_tick = next_tick - self.config.strategy_interval_ticks
        else:
            self._last_tactics_tick = next_tick - self.config.tactics_interval_ticks

    def deliver_late_result(self, request_id: str, result: Any, current_tick: int) -> bool:
        """迟到的模型返回：按代际与状态重新校验，超时请求不抢回控制。"""
        request = self._active_requests.get(request_id)
        if request is None:
            return False
        if request.status != REQUEST_STATUS_PENDING:
            self.metrics.stale_returns += 1
            request.status = REQUEST_STATUS_STALE
            return False
        request.result = result
        request.status = REQUEST_STATUS_COMPLETED
        return True

    # ---------- 命令提交 ----------

    def _local_gate(self, command: Dict[str, Any],
                    current_tick: int) -> Optional[Receipt]:
        """提交前的**本地闸门**（协议校验 / 玩家接管 / 资源预留）。

        抽出来的原因：批量与单条必须走**同一套**闸门 —— 否则"批量为了省往返"
        会顺手绕开玩家优先权或预算约束。返回 None 表示放行。
        """
        errors = validate_command_envelope(command, self._validation_context(current_tick))
        task_id = str(command.get("task_id", ""))
        if errors:
            self.metrics.commands_rejected += 1
            if task_id:
                self.tasks.mark(task_id, TASK_CANCELLED)
            self.append_decision("command_rejected_local", {
                "command_id": command.get("command_id"), "errors": errors, "tick": current_tick,
            })
            return Receipt(command_id=str(command.get("command_id", "")),
                           status="InvalidCommand", accepted=False,
                           reason="; ".join(errors), raw={"errors": errors})

        unit_ids = list((command.get("params", {}) or {}).get("units", []) or [])
        overridden = self.leases.overridden_units(unit_ids)
        if overridden:
            # 协调器侧也拦截：玩家接管后不再向游戏提交，除非请求显式 reacquire。
            if not bool((command.get("params", {}) or {}).get("reacquire", False)):
                self.metrics.commands_rejected += 1
                if task_id:
                    self.tasks.mark(task_id, TASK_UNKNOWN)
                return Receipt(command_id=str(command.get("command_id", "")),
                               status="PlayerOverride", accepted=False,
                               reason="units overridden by player: %s" % ",".join(overridden),
                               raw={})

        if not self._budget_allows(command):
            self.metrics.budget_rejected += 1
            self.metrics.commands_rejected += 1
            return Receipt(command_id=str(command.get("command_id", "")),
                           status="BudgetExceeded", accepted=False,
                           reason="资源预留约束：剩余预算不足以支付该命令",
                           raw={})
        return None

    def _settle(self, command: Dict[str, Any], receipt: Receipt, unit_ids: List[str],
                task_id: str, current_tick: int) -> Receipt:
        """回执结算（租约 / 预算承诺 / 任务状态 / 指标）—— **唯一实现**，单条与批量共用。"""
        if receipt.accepted:
            self.metrics.commands_accepted += 1
            self.leases.acquire(unit_ids)
            self._budget_commit(command)
            if task_id:
                self.tasks.on_receipt(task_id, receipt.accepted, receipt.status)
        else:
            self.metrics.commands_rejected += 1
            if receipt.status == "PendingAuthority":
                self.metrics.commands_pending += 1
                if task_id:
                    self.tasks.on_receipt(task_id, False, receipt.status)
            elif task_id and receipt.status not in ("PlayerOverride",):
                self.tasks.mark(task_id, TASK_UNKNOWN)
        self.append_decision("command_receipt", {
            "command_id": receipt.command_id, "status": receipt.status,
            "accepted": receipt.accepted, "tick": current_tick,
        })
        return receipt

    def submit_command(self, command: Dict[str, Any], current_tick: int) -> Receipt:
        """逐条提交命令；返回规范化回执（明确非原子，调用方逐条处理）。"""
        self.metrics.commands_submitted += 1
        blocked = self._local_gate(command, current_tick)
        if blocked is not None:
            return blocked
        unit_ids = list((command.get("params", {}) or {}).get("units", []) or [])
        task_id = str(command.get("task_id", ""))
        receipt = Receipt.from_json(self._transport(command))
        return self._settle(command, receipt, unit_ids, task_id, current_tick)

    def submit_batch(self, commands: List[Dict[str, Any]],
                     current_tick: int) -> List[Receipt]:
        """**批量提交**：本地逐条过闸门 → 一次 TCP 批量下发 → 逐项结算（计划 §5）。

        两条纪律：

        1. **批量传输 ≠ 批量成功**：权威端逐项回执，这里逐项 `_settle`；
           本地就拦下的项（协议/接管/预算）不进批量请求，直接按原顺序返回。
        2. **顺序必须与入参对齐**：调用方按 `envelopes` 的顺序读回执，
           所以这里用下标回填，而不是"过滤掉 None 再拼接"。
        """
        items = [item for item in (commands or []) if isinstance(item, dict)]
        if len(items) < 2 or not hasattr(self._transport, "send_batch"):
            return [self.submit_command(item, current_tick) for item in items]
        results: List[Optional[Receipt]] = [None] * len(items)
        prepared: List[Dict[str, Any]] = []
        prepared_index: List[int] = []
        for index, command in enumerate(items):
            self.metrics.commands_submitted += 1
            blocked = self._local_gate(command, current_tick)
            if blocked is not None:
                results[index] = blocked
                continue
            prepared.append(command)
            prepared_index.append(index)
        if prepared:
            self.metrics.batches_submitted += 1
            self.metrics.batched_commands += len(prepared)
            raw_receipts = self._transport.send_batch(prepared)
            for position, index in enumerate(prepared_index):
                command = items[index]
                raw = raw_receipts[position] if position < len(raw_receipts) else {}
                unit_ids = list((command.get("params", {}) or {}).get("units", []) or [])
                task_id = str(command.get("task_id", ""))
                results[index] = self._settle(command, Receipt.from_json(raw), unit_ids,
                                              task_id, current_tick)
        return [item for item in results if item is not None]

    # ---------- 资源预留 ----------

    def set_reserves(self, reserves: Dict[str, int]) -> None:
        """计划采纳时同步预留约束（副官花费约束，不是第二套游戏余额）。"""
        self._reserve_budget = dict(reserves or {})

    def observe_spent(self, spent: Dict[str, int]) -> None:
        """由权威快照对账：已接受命令的实际支出（禁止重复计扣 PendingAuthority）。"""
        self._spent = dict(spent or {})

    def _budget_allows(self, command: Dict[str, Any]) -> bool:
        if not self._reserve_budget:
            return True
        cost = (command.get("params", {}) or {}).get("est_cost", {}) or {}
        for kind, amount in cost.items():
            budget = int(self._reserve_budget.get(kind, 0))
            spent = int(self._spent.get(kind, 0))
            if spent + int(amount) > budget:
                return False
        return True

    def _budget_commit(self, command: Dict[str, Any]) -> None:
        cost = (command.get("params", {}) or {}).get("est_cost", {}) or {}
        for kind, amount in cost.items():
            self._spent[kind] = int(self._spent.get(kind, 0)) + int(amount)

    # ---------- 辅助 ----------

    def _validation_context(self, current_tick: int) -> Dict[str, Any]:
        return {
            "match_id": self.match_id,
            "player_id": self.player_id,
            "rules_version": self._rules_version,
            "current_tick": current_tick,
            "latest_snapshot_id": self._latest_snapshot_id,
        }

    def _strategy_context(self, current_tick: int, context: Dict[str, Any]) -> Dict[str, Any]:
        merged = dict(context)
        merged.update({
            "match_id": self.match_id, "player_id": self.player_id,
            "current_tick": current_tick,
            "active_plan": self.plans.active.plan if self.plans.active else None,
        })
        return merged

    def _tactics_context(self, current_tick: int, context: Dict[str, Any]) -> Dict[str, Any]:
        merged = dict(context)
        merged.update({
            "match_id": self.match_id, "player_id": self.player_id,
            "current_tick": current_tick,
            "plan_version": self.plans.plan_version(),
            "events": [event.__dict__ for event in self.events.drain()],
        })
        return merged

    def _has_pending_request(self, role: str) -> bool:
        return any(
            request.role == role and request.status == REQUEST_STATUS_PENDING
            for request in self._active_requests.values()
        )

    def _set_degraded(self, degraded: bool, reason: str) -> None:
        if degraded and not self.degraded:
            self.degraded = True
            self._degrade_reason = reason
        elif not degraded and self.degraded:
            self.degraded = False
            self._degrade_reason = ""

    @property
    def degrade_reason(self) -> str:
        return self._degrade_reason

    def _current_tick_hint(self) -> int:
        pending = [r for r in self._active_requests.values() if r.status == REQUEST_STATUS_PENDING]
        return pending[-1].issued_tick if pending else 0

    def append_decision(self, kind: str, payload: Dict[str, Any]) -> None:
        """决策留痕入口；由宿主把日志落到持久层（store.append_event_log）。"""
        self.decisions.append({"kind": kind, **payload})
