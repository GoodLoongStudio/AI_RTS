# -*- coding: utf-8 -*-
"""LangGraph 副官运行时：与既有协调器/权威通道的兼容适配层。

职责（方案 §8、§9、§13）：
- 每个 (match, player) 一个运行时实例，内部持有图执行器与单局状态；
- 命令下发仍走既有 AdjutantCoordinator.submit_command → Transport（Godot 权威入口），
  因此协议校验、玩家优先权、资源预留、幂等与回执复核语义完全复用；
- 玩家手动命令/显式归还：立即更新控制代际并镜像到协调器租约，图内旧意图随之失效；
- 模型/通道异常只写降级原因，不阻塞 tick；Godot 侧继续按有效意图与规则 AI 运行；
- checkpoint 按 (match, player) 隔离，重启后可恢复且不重复下单。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional

from ..coordinator import AdjutantCoordinator
from ..protocol import Receipt
from ..state import TASK_UNKNOWN
from .checkpoint import CheckpointStore, NullCheckpointStore
from .graph import ENGINE_FALLBACK, GraphRunner, build_runner, langgraph_available
from .nodes import GraphConfig, GraphServices
from .state import AdjutantGraphState


@dataclass
class RuntimeConfig:
    """运行时配置（与图配置一一对应；全部可配置化）。"""

    strategy_interval_ticks: int = 3600
    tactics_interval_ticks: int = 30
    emergency_min_interval_ticks: int = 6
    intent_ttl_ticks: int = 600
    emergency_intent_ttl_ticks: int = 300
    max_batch: int = 8
    model_error_limit: int = 3
    model_retry_cooldown_ticks: int = 60
    #: `PendingAuthority`（命令已送达、等待权威确认）的等待上限。
    #: 【2026-09-12 实测修正】原来是 240 tick（约 2~5 秒），而权威端的确认是异步的，
    #: 于是大量请求在确认前就"超时"→ 单位被当成空闲 → 微操层重发同一条命令
    #: （同局 `pending_timeout` 33 次、`Unit_2|gather` 下发 76 次）。
    #: 现在超时**不再当作任务失败**（转 `active_unknown` 保留占用），并把等待放宽到
    #: 分钟级；真正的结算靠 `op=commands` 复核提前完成。
    pending_timeout_ticks: int = 3000
    recheck_pending: bool = True
    pause_on_player_interrupt: bool = True
    engine: str = "auto"

    def to_graph_config(self) -> GraphConfig:
        return GraphConfig(
            strategy_interval_ticks=self.strategy_interval_ticks,
            tactics_interval_ticks=self.tactics_interval_ticks,
            emergency_min_interval_ticks=self.emergency_min_interval_ticks,
            intent_ttl_ticks=self.intent_ttl_ticks,
            emergency_intent_ttl_ticks=self.emergency_intent_ttl_ticks,
            max_batch=self.max_batch,
            model_error_limit=self.model_error_limit,
            model_retry_cooldown_ticks=self.model_retry_cooldown_ticks,
            pending_timeout_ticks=self.pending_timeout_ticks,
            recheck_pending=self.recheck_pending,
            pause_on_player_interrupt=self.pause_on_player_interrupt,
        )


@dataclass
class TickResult:
    """单 tick 结果（供宿主/日志/回放使用；不含隐藏推理）。"""

    server_tick: int
    route: str
    engine: str
    paused: bool
    accepted_intents: List[str] = field(default_factory=list)
    dropped_intents: List[Dict[str, Any]] = field(default_factory=list)
    receipts: List[Dict[str, Any]] = field(default_factory=list)
    degraded_reason: str = ""
    checkpoint: Dict[str, Any] = field(default_factory=dict)
    state: Dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "server_tick": self.server_tick,
            "route": self.route,
            "engine": self.engine,
            "paused": self.paused,
            "accepted_intents": list(self.accepted_intents),
            "dropped_intents": list(self.dropped_intents),
            "receipts": list(self.receipts),
            "degraded_reason": self.degraded_reason,
            "checkpoint": dict(self.checkpoint),
            "state": dict(self.state),
        }


class AdjutantGraphRuntime:
    """单局副官运行时（图 + 既有协调器 + 权威通道）。"""

    def __init__(
        self,
        match_id: str,
        player_id: str,
        transport: Any = None,
        strategy_model: Any = None,
        tactics_model: Any = None,
        checkpoint_store: Optional[CheckpointStore] = None,
        config: Optional[RuntimeConfig] = None,
        logger: Any = None,
        coordinator: Optional[AdjutantCoordinator] = None,
        recheck_fn: Optional[Callable[[str], Optional[Dict[str, Any]]]] = None,
        tick_provider: Optional[Callable[[], Optional[Dict[str, int]]]] = None,
        tactics_scheduler: Any = None,
    ) -> None:
        if coordinator is None and transport is None:
            raise ValueError("必须提供 transport 或 coordinator（禁止无通道的静默空转）")
        self.match_id = match_id
        self.player_id = player_id
        self.config = config or RuntimeConfig()
        self.logger = logger
        self.coordinator = coordinator or AdjutantCoordinator(
            match_id=match_id, player_id=player_id, transport=transport)
        self.state = AdjutantGraphState(match_id=match_id, player_id=player_id)
        # 计划 §6 阶段 A："省略高层 → 单一四列决策入口，并在状态里标注高层意图缺省"。
        # 战略模型缺失（None 或里层为 None 的包装器）时立标志，路由直接走战术分支；
        # 否则 is_strategy_due 因 active_plan 恒 None 恒真，战术节点被永久饿死。
        self._strategy_disabled = (
            strategy_model is None
            or getattr(strategy_model, "inner", strategy_model) is None)
        self.state.strategy_disabled = self._strategy_disabled
        self._current_tick = 0
        self._recheck_fn = recheck_fn
        # 观测新鲜度提供者：真实模型单次调用可达数十秒，下发前必须按“最新 tick/快照”
        # 复核意图窗口，否则结构合法但已过期的意图会被权威层一律判 Expired。
        self._tick_provider = tick_provider
        self._ttl_recomputed = 0
        self.services = GraphServices(
            strategy_model=strategy_model,
            tactics_model=tactics_model,
            # 有界异步调度（计划 §7.C）：模型调用不再阻塞观测/回执/玩家事件。
            tactics_scheduler=tactics_scheduler,
            dispatch=self._dispatch,
            recheck=self._recheck,
            adoption=self._adopt_plan,
            player_event_hook=self._mirror_player_event,
            checkpoint_store=checkpoint_store or NullCheckpointStore(),
            config=self.config.to_graph_config(),
            logger=logger,
        )
        self.runner: GraphRunner = build_runner(
            self.services, engine=self.config.engine,
            thread_id="%s|%s" % (match_id, player_id))
        self.dispatched: List[Dict[str, Any]] = []
        self.last_result: Optional[TickResult] = None

    # ---------- 兼容层：协调器 ----------

    def _adopt_plan(self, plan_dict: Dict[str, Any], tick: int):
        """计划采纳仍由既有协调器裁决（版本递增、任务注册、预留同步）。

        预留**以玩家设定为准**（方案 §6）：`plan.reserves` 只是模型建议，
        不能覆盖玩家额度。采纳后把玩家预留同步给协调器，
        保证"图内预算闸门"与"权威端预算检查"用的是同一份数字。
        """
        accepted = self.coordinator.adopt_plan(plan_dict, tick)
        player_reserves = dict(getattr(self.state, "reserves", {}) or {})
        if player_reserves:
            self.coordinator.set_reserves(player_reserves)
        return accepted

    def set_player_reserves(self, values: Dict[str, Any]) -> Dict[str, int]:
        """玩家调整预留额度（绝对值，按资源类型）。设 0 表示该项不预留。

        注意 `self.state` 是 `AdjutantGraphState` **对象**（不是图内 dict），
        所以这里直接改字段，不能复用 dict 版的 `reserves.set_reserves`。
        """
        current = {str(k).upper(): int(v)
                   for k, v in (getattr(self.state, "reserves", {}) or {}).items()}
        for key, value in (values or {}).items():
            try:
                current[str(key).upper()] = int(value)
            except (TypeError, ValueError):
                continue
        self.state.reserves = current
        self.state.reserves_initialized = True
        self.coordinator.set_reserves(current)
        return current

    def _refresh_observation_clock(self, envelopes: List[Dict[str, Any]]) -> Optional[int]:
        """在下发前用宿主提供的 tick/快照刷新时间基准，并按新基准重算过期窗口。

        语义：`expires_tick` 表示“决策时刻起算的有限窗口”；真实模型耗时期间 tick 会大幅推进，
        因此下发前若窗口已过，则按当前 tick + intent_ttl_ticks 重算（显式留痕），
        既不伪造快照，也不把合法意图静默丢弃。
        """
        if self._tick_provider is None:
            return None
        try:
            fresh = self._tick_provider() or {}
        except Exception:  # noqa: BLE001 —— 刷新失败不阻塞，退回原窗口
            return None
        fresh_tick = int(fresh.get("server_tick", 0) or 0)
        fresh_snapshot = int(fresh.get("snapshot_id", 0) or 0)
        if fresh_tick <= 0:
            return None
        self._current_tick = max(self._current_tick, fresh_tick)
        if fresh_snapshot > int(self.state.latest_snapshot_id or 0):
            self.state.latest_snapshot_id = fresh_snapshot
            self.coordinator.ingest_snapshot(
                {"match_id": self.match_id, "player_id": self.player_id,
                 "snapshot_id": fresh_snapshot, "server_tick": fresh_tick,
                 "rules_version": self.state.rules_version}, {})
        recomputed = 0
        for envelope in envelopes:
            expires = envelope.get("expires_tick")
            if isinstance(expires, int) and expires <= self._current_tick:
                envelope["expires_tick"] = self._current_tick + int(self.config.intent_ttl_ticks)
                recomputed += 1
        if recomputed:
            self._ttl_recomputed += recomputed
        return self._current_tick

    def _dispatch(self, envelopes: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        """经既有协调器逐条提交（协议校验 + 玩家优先权 + 预算），返回结构化回执。"""
        self._refresh_observation_clock(envelopes)
        receipts: List[Dict[str, Any]] = []
        for envelope in envelopes:
            receipt = self.coordinator.submit_command(envelope, self._current_tick)
            data = self._receipt_to_dict(receipt, envelope)
            self.dispatched.append({"envelope": envelope, "receipt": data})
            receipts.append(data)
        return receipts

    @staticmethod
    def _receipt_to_dict(receipt: Receipt, envelope: Dict[str, Any]) -> Dict[str, Any]:
        data = dict(receipt.raw or {})
        data.update({
            "command_id": receipt.command_id or str(envelope.get("command_id", "")),
            "status": receipt.status,
            "accepted": bool(receipt.accepted),
            "reason": receipt.reason,
            "intent_id": str(data.get("intent_id", envelope.get("intent_id", ""))),
            "action": str(data.get("action", envelope.get("action", ""))),
        })
        return data

    def _recheck(self, command_id: str) -> Optional[Dict[str, Any]]:
        """按 command_id 复核终态（超时不重下单；查询不到保留 unknown）。"""
        if self._recheck_fn is None or not command_id:
            return None
        try:
            return self._recheck_fn(command_id)
        except Exception as exc:  # noqa: BLE001 —— 复核失败保留在途状态。
            if self.logger is not None:
                self.logger.log("receipt_recheck_error", command_id=command_id, reason=str(exc))
            return None

    def _mirror_player_event(self, record: Dict[str, Any]) -> None:
        """把玩家控制事件镜像到既有协调器（权威层仍会独立校验一次）。"""
        units = [str(u) for u in record.get("unit_ids", [])]
        if not units:
            return
        if record.get("kind") == "player_override":
            self.coordinator.notify_player_override(units)
        else:
            self.coordinator.leases.reacquire(units, "player_release")

    # ---------- 玩家控制 ----------

    def on_player_command(self, unit_ids: List[str], server_tick: int = 0,
                          reason: str = "") -> Dict[str, Any]:
        """玩家手动命令：立即增加代际、撤销 AI lease、使相关意图失效（最高优先级）。"""
        tick = int(server_tick or self.state.server_tick)
        unit_ids = [str(u) for u in unit_ids]
        record = self.state.mark_player_override(unit_ids, tick,
                                                reason or "player_manual_command")
        self._mirror_player_event(record)
        self.state.push_event({
            "event_id": "player_override-%d-%s" % (tick, ",".join(sorted(str(u) for u in unit_ids))),
            "kind": "player_override",
            "match_id": self.match_id,
            "player_id": self.player_id,
            "server_tick": tick,
            "payload": {"subject": ",".join(str(u) for u in unit_ids),
                        "reason": record["reason"], "already_applied": True},
        })
        self.state.decide("player_override_immediate",
                          unit_ids=record["unit_ids"], generation=record["generation"],
                          dropped_intents=record["dropped_intents"])
        return record

    def on_player_release(self, unit_ids: List[str], server_tick: int = 0,
                          reason: str = "") -> Dict[str, Any]:
        """玩家显式归还：AI 才能重新接管（新代际，旧意图不会复活）。"""
        tick = int(server_tick or self.state.server_tick)
        unit_ids = [str(u) for u in unit_ids]
        record = self.state.release_units(unit_ids, tick, reason or "player_release")
        self._mirror_player_event(record)
        self.state.push_event({
            "event_id": "player_release-%d-%s" % (tick, ",".join(sorted(str(u) for u in unit_ids))),
            "kind": "player_release",
            "match_id": self.match_id,
            "player_id": self.player_id,
            "server_tick": tick,
            "payload": {"subject": ",".join(str(u) for u in unit_ids),
                        "reason": record["reason"], "already_applied": True},
        })
        self.state.decide("player_release_immediate",
                          unit_ids=record["unit_ids"], generation=record["generation"])
        return record

    # ---------- tick ----------

    def on_observation(self, header: Dict[str, Any],
                       strategic: Optional[Dict[str, Any]] = None,
                       tactical: Optional[Dict[str, Any]] = None,
                       rules: Optional[Dict[str, Any]] = None,
                       events: Optional[List[Dict[str, Any]]] = None,
                       budget: Optional[Dict[str, int]] = None) -> TickResult:
        observation = {
            "header": dict(header or {}),
            "strategic": strategic,
            "tactical": tactical,
            "rules": rules,
            "events": list(events or []),
            "budget": dict(budget or {}),
        }
        tick = int((header or {}).get("server_tick", self.state.server_tick))
        return self.tick(tick, observation)

    def push_event(self, kind: str, server_tick: int = 0,
                   payload: Optional[Dict[str, Any]] = None,
                   event_id: str = "") -> bool:
        tick = int(server_tick or self.state.server_tick)
        return self.state.push_event({
            "event_id": event_id or "evt-%d-%s" % (tick, kind),
            "kind": kind,
            "match_id": self.match_id,
            "player_id": self.player_id,
            "server_tick": tick,
            "payload": payload or {},
        })

    def tick(self, server_tick: int, observation: Optional[Dict[str, Any]] = None) -> TickResult:
        """推进一轮：图执行（或从暂停点恢复）+ 状态回写 + checkpoint。"""
        self._current_tick = int(server_tick)
        observation = dict(observation or {})
        observation.setdefault("header", {})
        # 兼容层：把观测包头同步给既有协调器（快照时效与规则版本校验依赖它）。
        header = observation.get("header") or {}
        if header:
            self.coordinator.ingest_snapshot(header, {})
        state_dict = self.state.to_dict()
        state_dict["server_tick"] = max(int(state_dict.get("server_tick", 0)), self._current_tick)
        receipt_start = len(state_dict.get("command_receipts", []))

        if self.runner.paused:
            # 上一轮因玩家打断暂停：先完成该决策轮的收尾（仲裁/下发/回执/持久化），
            # 再按本轮观测完整推进一次，保证本轮事件与观测不被跳过。
            out = self.runner.resume(state_dict, observation=observation,
                                     tick=self._current_tick)
            out = self.runner.run_tick(out, observation=observation,
                                       tick=self._current_tick)
        else:
            out = self.runner.run_tick(state_dict, observation=observation,
                                       tick=self._current_tick)
        self.state = AdjutantGraphState.from_dict(out)
        if self._ttl_recomputed:
            # 决策留痕要写在“本轮最终状态”上（图返回的是另一个状态对象）。
            self.state.decide("intent_ttl_recomputed", tick=self._current_tick,
                              count=self._ttl_recomputed,
                              window=int(self.config.intent_ttl_ticks))
            self._ttl_recomputed = 0
        result = TickResult(
            server_tick=self._current_tick,
            route=str(out.get("route", "")),
            engine=self.runner.engine,
            paused=bool(self.runner.paused),
            accepted_intents=list((out.get("intent_arbitration") or {}).get("accepted", [])),
            dropped_intents=list((out.get("intent_arbitration") or {}).get("dropped", [])),
            receipts=self.state.command_receipts[receipt_start:],
            degraded_reason=self.state.degraded_reason,
            checkpoint=dict(out.get("last_checkpoint") or {}),
            state=self.state.summary(),
        )
        self.last_result = result
        return result

    # ---------- 持久化与恢复 ----------

    def checkpoint(self) -> Dict[str, Any]:
        return self.services.checkpoint_store.save(self.state)

    def restore(self, expect_rules_version: str = "") -> Dict[str, Any]:
        """从 checkpoint 恢复对局状态（隔离校验 + 规则版本校验）。

        恢复后在途请求保持 pending：等权威终态复核，绝不重复下单。
        """
        stored = self.services.checkpoint_store.load()
        if stored is None:
            return {"restored": False, "reason": "no_checkpoint"}
        if stored.match_id != self.match_id or stored.player_id != self.player_id:
            return {"restored": False, "reason": "identity_mismatch"}
        if expect_rules_version and stored.rules_version and \
                stored.rules_version != expect_rules_version:
            return {"restored": False, "reason": "rules_version_mismatch",
                    "bound": stored.rules_version, "observed": expect_rules_version}
        self.state = stored
        # checkpoint 可能来自"战略层开启"的旧会话（或没有该字段的旧代码）：
        # 恢复后按本运行时的实际模型装配重申标志，避免路由重新死锁。
        self.state.strategy_disabled = self._strategy_disabled
        # 恢复后立刻按 TTL 复核活跃意图：过期即失效（不复活旧命令）。
        expired = self.state.expire_intents(self.state.server_tick)
        self.state.decide("runtime_restored", pending_requests=sorted(self.state.pending_requests),
                          expired_intents=[item["intent_id"] for item in expired])
        return {"restored": True, "reason": "", "pending_requests": sorted(self.state.pending_requests),
                "active_intents": len(self.state.live_intents(self.state.server_tick))}

    def snapshot(self) -> Dict[str, Any]:
        return {
            "engine": self.runner.engine,
            "paused": self.runner.paused,
            "state": self.state.summary(),
            "dispatched": len(self.dispatched),
            "checkpoint": self.services.checkpoint_store.describe(),
        }

    def describe(self) -> Dict[str, Any]:
        availability = langgraph_available()
        return {
            "engine": self.runner.engine,
            "langgraph_available": availability["available"],
            "langgraph_reason": availability["reason"],
            "checkpoint_store": self.services.checkpoint_store.describe(),
            "coordinator": "AdjutantCoordinator",
            "config": {
                "strategy_interval_ticks": self.config.strategy_interval_ticks,
                "tactics_interval_ticks": self.config.tactics_interval_ticks,
                "intent_ttl_ticks": self.config.intent_ttl_ticks,
                "emergency_intent_ttl_ticks": self.config.emergency_intent_ttl_ticks,
                "max_batch": self.config.max_batch,
                "pause_on_player_interrupt": self.config.pause_on_player_interrupt,
            },
        }


def quick_runtime(match_id: str = "m-1", player_id: str = "Player_1", **kwargs: Any) -> AdjutantGraphRuntime:
    """测试/回放便捷构造：默认假通道（全部回执 Unknown，需显式注入真实通道）。"""

    def _no_transport(envelope: Dict[str, Any]) -> Dict[str, Any]:
        return {"ok": False, "accepted": False, "status": "NoTransport",
                "reason": "未注入权威通道（测试默认桩）",
                "command_id": str(envelope.get("command_id", "")),
                "intent_id": str(envelope.get("intent_id", ""))}

    kwargs.setdefault("transport", _no_transport)
    kwargs.setdefault("config", RuntimeConfig(engine=ENGINE_FALLBACK))
    return AdjutantGraphRuntime(match_id, player_id, **kwargs)
