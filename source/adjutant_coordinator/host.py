# -*- coding: utf-8 -*-
"""副官宿主调度器（第二阶段离线准备）。

职责（architecture.md §1、§5；delivery 第二阶段范围预告）：
- 包装第一阶段 AdjutantCoordinator：战略按周期或重大事件触发，
  战术按事件触发并支持有界合并（事件合并由 EventBus 承担）。
- 战略与战术请求挂在不互相阻塞的独立槽位：战略结果未就绪（迟到模拟/挂起）
  不影响战术命令照常提交。
- 请求超时后保留当前有效计划与基础防守行为（degraded：不发新命令，
  游戏内自动接战等既有行为照常），不重复下单。
- 迟到结果按代际丢弃并记录 stale/timed_out 原因。
- 全部关键节点写结构化日志；进程级异常进入 fatal 可诊断状态，不静默吞错。
- 断线重连后重新读取状态并校验 match_id/player_id/rules_version，
  断线期间不丢失计划/任务/待诊断信息。
"""

from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional

from .coordinator import AdjutantCoordinator
from .provider import (
    ModelCallContext, ModelOutcome, OUTCOME_COMPLETED, OUTCOME_ERROR,
    OUTCOME_REJECTED, OUTCOME_TIMEOUT, ROLE_STRATEGY, ROLE_TACTICS,
)
from .structured_log import NullLogger, StructuredLogger
from .transport import ConnectionState, ResilientTransport, Transport, TransportError

HOST_OK = "ok"
HOST_DEGRADED = "degraded"
HOST_FATAL = "fatal"

STRATEGY_STATUS_PENDING = "pending"
STRATEGY_STATUS_STALE = "stale"
STRATEGY_STATUS_ADOPTED = "adopted"
STRATEGY_STATUS_REJECTED = "rejected"
STRATEGY_STATUS_TIMED_OUT = "timed_out"


@dataclass
class PendingOutcome:
    """已产出但尚未到 available_at_tick 的模型结果（乱序/迟到模拟）。"""

    outcome: ModelOutcome
    issued_tick: int
    deadline_tick: int


@dataclass
class HostConfig:
    strategy_interval_ticks: int = 3600          # 战略周期（60s @60Hz 起点，配置化）
    tactics_interval_ticks: int = 30             # 战术最小间隔
    request_timeout_ticks: int = 120             # 模型请求超时（计入，不只统计成功）
    heartbeat_interval_ticks: int = 600          # 心跳周期（10s @60Hz 起点）
    heartbeat_failure_limit: int = 3             # 连续失败阈值 → 触发重连
    strategy_event_trigger_kinds: tuple = ("match_started", "outcome_changed")


class HostScheduler:
    """单个 (match, player) 的离线宿主调度器。

    identity_provider：重连后重新读取状态的回调（E2E/真实装配时=拉取 rules/status
    包头）；返回 {match_id, player_id, rules_version, snapshot_id}。
    """

    def __init__(
        self,
        coordinator: AdjutantCoordinator,
        strategy_provider,
        tactics_provider,
        transport: Transport,
        logger: Optional[StructuredLogger] = None,
        config: Optional[HostConfig] = None,
        identity_provider: Optional[Callable[[], Dict[str, Any]]] = None,
    ) -> None:
        self.coordinator = coordinator
        self.strategy_provider = strategy_provider
        self.tactics_provider = tactics_provider
        self.transport = transport
        self.logger = logger or NullLogger()
        self.config = config or HostConfig()
        self.identity_provider = identity_provider

        self.state = HOST_OK
        self.fatal_reason = ""
        self._strategy_request_seq = 0
        self._tactics_request_seq = 0
        self._pending_strategy: Optional[PendingOutcome] = None
        self._pending_tactics: Optional[PendingOutcome] = None
        self._last_strategy_tick: Optional[int] = None
        self._last_tactics_tick: Optional[int] = None
        self._last_heartbeat_tick: Optional[int] = None
        self._heartbeat_failures = 0
        self._identity: Dict[str, Any] = {
            "match_id": coordinator.match_id,
            "player_id": coordinator.player_id,
            "rules_version": coordinator._rules_version,
            "snapshot_id": 0,
        }
        self.logger.update_identity(
            match_id=coordinator.match_id, player_id=coordinator.player_id,
            rules_version=coordinator._rules_version)

    # ---------- 身份 ----------

    def validate_identity(self, observed: Dict[str, Any]) -> Dict[str, Any]:
        """重连后身份校验；返回 drift 字典（空 = 一致）。"""
        drift = {}
        for key in ("match_id", "player_id", "rules_version"):
            bound = str(self._identity.get(key, ""))
            seen = str(observed.get(key, ""))
            if bound and seen != bound:
                drift[key] = {"bound": bound, "observed": seen}
        return drift

    def ingest_header(self, header: Dict[str, Any]) -> None:
        """消费新的观测包头（重连恢复后调用）；刷新身份并同步协调器。"""
        self._identity.update({
            "match_id": str(header.get("match_id", self._identity.get("match_id", ""))),
            "player_id": str(header.get("player_id", self._identity.get("player_id", ""))),
            "rules_version": str(header.get("rules_version", self._identity.get("rules_version", ""))),
            "snapshot_id": int(header.get("snapshot_id", 0)),
        })
        self.coordinator.ingest_snapshot(header, {})
        self.logger.update_identity(
            match_id=self._identity["match_id"], player_id=self._identity["player_id"],
            rules_version=self._identity["rules_version"],
            snapshot_id=self._identity["snapshot_id"])

    # ---------- 主循环 ----------

    def run_tick(self, server_tick: int, observation: Optional[Dict[str, Any]] = None) -> str:
        """宿主逻辑时钟入口；返回当前状态 ok/degraded/fatal。

        进程级异常被捕获并转为 fatal 可诊断状态（记录后重抛给宿主进程），
        绝不静默吞错继续运行。
        """
        try:
            return self._run_tick_inner(server_tick, observation or {})
        except Exception as exc:  # noqa: BLE001 —— 捕获留证后必须重抛，不静默。
            self.state = HOST_FATAL
            self.fatal_reason = "%s: %s" % (type(exc).__name__, exc)
            self.logger.log("host_fatal", status=HOST_FATAL,
                            reason=self.fatal_reason, server_tick=server_tick)
            raise

    def _run_tick_inner(self, server_tick: int, observation: Dict[str, Any]) -> str:
        if self.state == HOST_FATAL:
            return HOST_FATAL

        self._heartbeat(server_tick)

        # --- 战略槽：先收前面 tick 挂起的结果（不阻塞本 tick 战术） ---
        self._settle_pending(self._pending_strategy, server_tick, is_strategy=True)
        self._settle_pending(self._pending_tactics, server_tick, is_strategy=False)

        # --- 超时复核：挂起结果超过 deadline → timed_out，保留当前计划 ---
        self._expire_pending(server_tick)

        # --- 战略触发：周期 or 重大事件 ---
        if self._strategy_due(server_tick, observation):
            self._request_strategy(server_tick, observation)

        # --- 战术触发：事件驱动（EventBus 有界合并后派发）---
        if self._tactics_due(server_tick):
            self._request_tactics(server_tick, observation)

        self.state = HOST_DEGRADED if self.coordinator.degraded else HOST_OK
        return self.state

    # ---------- 心跳与连接 ----------

    def _heartbeat(self, server_tick: int) -> None:
        if self._last_heartbeat_tick is not None and \
                server_tick - self._last_heartbeat_tick < self.config.heartbeat_interval_ticks:
            return
        self._last_heartbeat_tick = server_tick
        if self.transport.heartbeat():
            self._heartbeat_failures = 0
            return
        self._heartbeat_failures += 1
        self.logger.log("heartbeat_failed", status="failed",
                        reason="attempt %d" % self._heartbeat_failures,
                        server_tick=server_tick)
        if self._heartbeat_failures >= self.config.heartbeat_failure_limit:
            self._handle_disconnect(server_tick)

    def _handle_disconnect(self, server_tick: int) -> None:
        """断线处理：保留计划/任务/待诊断，尝试重连并重新校验身份。

        身份最终裁决在 Host 层（identity_provider 重新读状态）；transport 层的
        指纹校验只是第一道防线。漂移时保持断开，绝不能把命令发进别的对局。
        """
        self.logger.log("disconnected", status="disconnected",
                        reason="heartbeat failures=%d" % self._heartbeat_failures,
                        server_tick=server_tick)
        if isinstance(self.transport, ResilientTransport):
            # 传输层尽力恢复；其结果不作为身份结论。
            self.transport.try_reconnect(server_tick)
        if self.identity_provider is None:
            if self.transport.heartbeat():
                self.logger.log("reconnected", status="connected",
                                reason="no identity provider; transport restored",
                                server_tick=server_tick)
                self._heartbeat_failures = 0
            else:
                self.coordinator._set_degraded(True, "transport disconnected")
                self.logger.log("reconnect_failed", status="disconnected",
                                reason="probe unavailable or failed",
                                server_tick=server_tick)
            return
        try:
            observed = self.identity_provider()
        except Exception as exc:  # noqa: BLE001 —— 探测失败保持断开并留证。
            self.coordinator._set_degraded(True, "reconnect probe failed")
            self.logger.log("reconnect_failed", status="disconnected",
                            reason="identity probe raised: %s" % exc,
                            server_tick=server_tick)
            return
        drift = self.validate_identity(observed)
        if drift:
            # 身份漂移：拒绝恢复，保持断开（不得把命令发进别的对局）。
            if isinstance(self.transport, ResilientTransport):
                self.transport.state = ConnectionState.DISCONNECTED
            self.coordinator._set_degraded(True, "reconnect identity drift")
            self.logger.log("reconnect_rejected", status="identity_drift",
                            reason=str(drift), server_tick=server_tick, drift=str(drift))
            return
        self.ingest_header(observed)
        self.logger.log("reconnected", status="connected",
                        reason="identity verified",
                        server_tick=server_tick,
                        snapshot_id=self._identity["snapshot_id"])
        self._heartbeat_failures = 0

    # ---------- 战略 ----------

    def _strategy_due(self, server_tick: int, observation: Dict[str, Any]) -> bool:
        if self._pending_strategy is not None or self._last_strategy_tick is None:
            return self._last_strategy_tick is None and self._pending_strategy is None
        interval_due = server_tick - self._last_strategy_tick >= self.config.strategy_interval_ticks
        # 重大事件由宿主进程在 observation.major_event 标记（避免与战术事件流互相消耗）。
        event_due = str(observation.get("major_event", "")) in \
            self.config.strategy_event_trigger_kinds and \
            self.coordinator.plans.expired(server_tick)
        return interval_due or event_due

    def _request_strategy(self, server_tick: int, observation: Dict[str, Any]) -> None:
        self._strategy_request_seq += 1
        request_id = "host-strat-%d" % self._strategy_request_seq
        issued = server_tick
        deadline = server_tick + self.config.request_timeout_ticks
        context = ModelCallContext(
            request_id=request_id, role=ROLE_STRATEGY,
            match_id=self._identity["match_id"], player_id=self._identity["player_id"],
            rules_version=self._identity["rules_version"],
            plan_version=self.coordinator.plans.plan_version(),
            snapshot_id=int(self._identity["snapshot_id"]),
            server_tick=server_tick, issued_tick=issued, deadline_tick=deadline,
            budget=dict(self.coordinator._reserve_budget),
            observation=observation,
        )
        self.logger.log("strategy_request", status="issued",
                        request_id=request_id, server_tick=server_tick,
                        plan_version=context.plan_version)
        try:
            outcome = self.strategy_provider.propose(context)
        except Exception as exc:  # noqa: BLE001 —— provider 异常结构化，不炸调度器。
            outcome = ModelOutcome(status=OUTCOME_ERROR, role=ROLE_STRATEGY,
                                   request_id=request_id,
                                   reason="provider raised: %s" % exc, retryable=True)
        self._handle_outcome(outcome, context, server_tick, is_strategy=True)

    # ---------- 战术 ----------

    def _tactics_due(self, server_tick: int) -> bool:
        if self._pending_tactics is not None:
            return False
        if self._last_tactics_tick is None:
            return True
        return server_tick - self._last_tactics_tick >= self.config.tactics_interval_ticks

    def _request_tactics(self, server_tick: int, observation: Dict[str, Any]) -> None:
        self._tactics_request_seq += 1
        request_id = "host-tact-%d" % self._tactics_request_seq
        issued = server_tick
        deadline = server_tick + self.config.request_timeout_ticks
        context = ModelCallContext(
            request_id=request_id, role=ROLE_TACTICS,
            match_id=self._identity["match_id"], player_id=self._identity["player_id"],
            rules_version=self._identity["rules_version"],
            plan_version=self.coordinator.plans.plan_version(),
            snapshot_id=int(self._identity["snapshot_id"]),
            server_tick=server_tick, issued_tick=issued, deadline_tick=deadline,
            observation={"events_pending": self.coordinator.events.pending()},
        )
        self.logger.log("tactics_request", status="issued",
                        request_id=request_id, server_tick=server_tick,
                        plan_version=context.plan_version)
        try:
            outcome = self.tactics_provider.propose(context)
        except Exception as exc:  # noqa: BLE001
            outcome = ModelOutcome(status=OUTCOME_ERROR, role=ROLE_TACTICS,
                                   request_id=request_id,
                                   reason="provider raised: %s" % exc, retryable=True)
        self._handle_outcome(outcome, context, server_tick, is_strategy=False)

    # ---------- 结果处理 ----------

    def _handle_outcome(self, outcome: ModelOutcome, context: ModelCallContext,
                        server_tick: int, is_strategy: bool) -> None:
        errors = outcome.validate()
        if errors:
            self.logger.log("model_outcome_invalid", status=outcome.status,
                            reason="; ".join(errors), server_tick=server_tick,
                            request_id=outcome.request_id)
            return
        # 时间倒流防御：结果到达时间早于请求发出时间 → 无效结果，丢弃留证。
        if 0 < outcome.available_at_tick < context.issued_tick:
            self.logger.log("model_outcome_invalid", status=outcome.status,
                            reason="arrival %d before issue %d" % (
                                outcome.available_at_tick, context.issued_tick),
                            server_tick=server_tick, request_id=outcome.request_id)
            return
        # 迟到：结果可用时间晚于请求 deadline → stale 丢弃，不抢回控制。
        if outcome.available_at_tick > 0 and \
                outcome.available_at_tick > context.deadline_tick:
            self.logger.log("model_outcome_stale", status=STRATEGY_STATUS_STALE,
                            reason="arrives %d > deadline %d" % (
                                outcome.available_at_tick, context.deadline_tick),
                            server_tick=server_tick, request_id=outcome.request_id)
            return
        # 尚未到达：挂起槽位（战略/战术互不阻塞）。
        if outcome.available_at_tick > server_tick:
            pending = PendingOutcome(outcome=outcome, issued_tick=context.issued_tick,
                                     deadline_tick=context.deadline_tick)
            if is_strategy:
                self._pending_strategy = pending
            else:
                self._pending_tactics = pending
            self.logger.log("model_outcome_pending", status=STRATEGY_STATUS_PENDING,
                            reason="available at %d" % outcome.available_at_tick,
                            server_tick=server_tick, request_id=outcome.request_id)
            return
        if outcome.status == OUTCOME_COMPLETED:
            self._apply_completed(outcome, server_tick, is_strategy)
        elif outcome.status == OUTCOME_TIMEOUT:
            # 超时：保留当前有效计划与基础防守行为（coordinator 状态不动）。
            self.coordinator._set_degraded(True, "model timeout")
            self.logger.log("model_outcome_timeout", status=OUTCOME_TIMEOUT,
                            reason=outcome.reason, server_tick=server_tick,
                            request_id=outcome.request_id)
        elif outcome.status in (OUTCOME_ERROR, OUTCOME_REJECTED):
            self.coordinator._set_degraded(True, "model %s" % outcome.status)
            self.logger.log("model_outcome_error", status=outcome.status,
                            reason=outcome.reason, server_tick=server_tick,
                            request_id=outcome.request_id)
        else:  # cancelled：记录即可，不改降级状态。
            self.logger.log("model_outcome_cancelled", status=outcome.status,
                            reason=outcome.reason, server_tick=server_tick,
                            request_id=outcome.request_id)

    def _apply_completed(self, outcome: ModelOutcome, server_tick: int,
                         is_strategy: bool) -> None:
        payload = outcome.payload
        if is_strategy:
            self._last_strategy_tick = server_tick
            if payload is None:
                # 空响应：非致命，保留当前计划。
                self.logger.log("strategy_empty", status="empty",
                                reason=str(outcome.reason), server_tick=server_tick,
                                request_id=outcome.request_id)
                return
            accepted, reason = self.coordinator.adopt_plan(payload, server_tick)
            self.logger.log(
                "plan_adoption", status=STRATEGY_STATUS_ADOPTED if accepted
                else STRATEGY_STATUS_REJECTED,
                reason=reason, server_tick=server_tick,
                request_id=outcome.request_id,
                plan_version="%s:v%s" % (payload.get("plan_id", ""),
                                         payload.get("plan_version", ""))
                if isinstance(payload, dict) else "")
            if accepted:
                self.coordinator._set_degraded(False, "")
            return
        self._last_tactics_tick = server_tick
        if not payload:
            self.logger.log("tactics_empty", status="empty",
                            reason=str(outcome.reason), server_tick=server_tick,
                            request_id=outcome.request_id)
            return
        if not isinstance(payload, list):
            # 格式错误：命令批次必须是列表；记录并丢弃，不影响协调器状态。
            self.logger.log("tactics_malformed", status="malformed",
                            reason="commands payload is not a list",
                            server_tick=server_tick, request_id=outcome.request_id)
            return
        for receipt in self.coordinator.submit_commands_batch(payload, server_tick):
            self.logger.log("command_receipt", status=receipt.status,
                            reason=receipt.reason, server_tick=server_tick,
                            command_id=receipt.command_id,
                            accepted=str(receipt.accepted))

    # ---------- 挂起槽位 ----------

    def _settle_pending(self, pending: Optional[PendingOutcome], server_tick: int,
                        is_strategy: bool) -> None:
        if pending is None:
            return
        if server_tick < pending.outcome.available_at_tick:
            return
        if is_strategy:
            self._pending_strategy = None
        else:
            self._pending_tactics = None
        # 宿主跳帧导致 settle 时已过 deadline：按超时丢弃，保留当前计划。
        if server_tick > pending.deadline_tick:
            self.coordinator._set_degraded(True, "model request timed out")
            self.logger.log("model_request_timed_out",
                            status=STRATEGY_STATUS_TIMED_OUT if is_strategy else "timed_out",
                            reason="settled at %d > deadline %d; current plan retained" % (
                                server_tick, pending.deadline_tick),
                            server_tick=server_tick,
                            request_id=pending.outcome.request_id)
            return
        self._handle_outcome(pending.outcome,
                             ModelCallContext(
                                 request_id=pending.outcome.request_id,
                                 role=pending.outcome.role,
                                 match_id=self._identity["match_id"],
                                 player_id=self._identity["player_id"],
                                 rules_version=self._identity["rules_version"],
                                 issued_tick=pending.issued_tick,
                                 deadline_tick=pending.deadline_tick,
                             ),
                             server_tick, is_strategy)

    def _expire_pending(self, server_tick: int) -> None:
        """结果永远不会到达的请求（provider 挂起无产出）由 timeout outcome 表达；
        本函数只清理已被 settle 语义覆盖的场景，保留防御性检查。"""
        for slot_name in ("_pending_strategy", "_pending_tactics"):
            pending = getattr(self, slot_name)
            if pending is None:
                continue
            if pending.outcome.available_at_tick <= 0 and server_tick > pending.deadline_tick:
                setattr(self, slot_name, None)
                self.coordinator._set_degraded(True, "model request timed out")
                self.logger.log(
                    "model_request_timed_out",
                    status=STRATEGY_STATUS_TIMED_OUT if slot_name == "_pending_strategy"
                    else "timed_out",
                    reason="deadline %d passed; current plan retained" % pending.deadline_tick,
                    server_tick=server_tick, request_id=pending.outcome.request_id)
