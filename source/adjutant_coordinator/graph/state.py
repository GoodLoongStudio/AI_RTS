# -*- coding: utf-8 -*-
"""单局副官图状态：可序列化、可 checkpoint、单局隔离。

字段与 docs/plan/AI副官_LangGraph重构方案.md §4 对应：
match_id / player_id / rules_version / server_tick / latest_snapshot_id /
active_plan / plan_version / active_tasks / active_intents /
ai_controlled_units / player_controlled_units / control_generation /
pending_events / pending_requests / command_receipts / degraded_reason

控制权纪律（§7）：
- 每个单位维护自己的控制代际 generation；玩家手动命令使该单位代际 +1 并撤销 AI lease；
- 旧意图在 generation 不一致 / plan_version 不一致 / 已过期 / 单位已被玩家接管时失效；
- 玩家局部接管只影响相关单位与任务（任务标记 partially_overridden），不清空战略计划；
- 只有显式归还（player_release / player_release_group）才允许 AI 重新接管。
"""

from __future__ import annotations

import copy
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Tuple

from ..state import (
    TASK_CANCELLED, TASK_COMPLETED, TASK_FAILED, TASK_PENDING, TASK_RUNNING,
    TASK_STATES, TASK_UNKNOWN,
)

CHECKPOINT_VERSION = 1

# 任务状态扩展（方案 §7：任务状态区分）
TASK_PARTIALLY_OVERRIDDEN = "partially_overridden"
TASK_WAITING_FOR_PLAYER = "waiting_for_player"
TASK_REASSIGNED = "reassigned"
TASK_EXPIRED = "expired"
# 方案 §4 要求的 interrupted：与 failed 区分开——"目标暂时脱离视野/被玩家接管"
# 是可恢复的，不应记成失败（否则任务统计会把可恢复情形当损失）。
TASK_INTERRUPTED = "interrupted"

EXTENDED_TASK_STATES = TASK_STATES + (
    TASK_PARTIALLY_OVERRIDDEN, TASK_WAITING_FOR_PLAYER, TASK_REASSIGNED, TASK_EXPIRED,
)

# 意图生命周期状态
INTENT_ACTIVE = "active"
INTENT_PENDING_AUTHORITY = "pending_authority"
INTENT_COMPLETED = "completed"
INTENT_FAILED = "failed"
INTENT_EXPIRED = "expired"
INTENT_DROPPED = "dropped"
#: 可恢复的中断（失去视野等）：不并入 failed，避免把"暂时看不见"当成损失。
INTENT_INTERRUPTED = "interrupted"
#: 拥塞类拒绝（LedgerFull/Busy/TransportError…）：**不是失败，是稍后重试**。
INTENT_RETRY_WAIT = "retry_wait"
#: 已送达但权威端未确认（PendingAuthority 超时）：**未知不等于失败**。
#: 【2026-09-12 实测】把超时当失败丢掉会让单位"变空闲"→ 微操层下一轮重发同一条命令
#: （同局 `pending_timeout` 33 次、`Unit_2|gather` 被下发 76 次）。
#: 计划也明确禁止"用超时推断任务状态"，所以保留占用、等回执复核。
INTENT_ACTIVE_UNKNOWN = "active_unknown"
#: 视为"执行者仍在忙"的状态（去重、微操守卫、任务表都据此判定）。
INTENT_LIVE_STATES = (INTENT_ACTIVE, INTENT_PENDING_AUTHORITY, INTENT_RETRY_WAIT,
                      INTENT_ACTIVE_UNKNOWN)

MAX_PENDING_EVENTS = 256
MAX_RECEIPT_HISTORY = 256
MAX_DECISION_LOG = 512


@dataclass
class AdjutantGraphState:
    """单局图状态；所有字段都是 JSON 友好类型（checkpoint 直接落盘）。"""

    match_id: str
    player_id: str
    rules_version: str = ""
    server_tick: int = 0
    latest_snapshot_id: int = 0

    active_plan: Optional[Dict[str, Any]] = None
    plan_version: str = ""
    plan_adopt_generation: int = 0
    # 被替换的历史计划版本（有界）：模型回显历史版本 = 真·旧计划意图，仲裁丢弃。
    plan_version_history: List[str] = field(default_factory=list)

    active_tasks: Dict[str, str] = field(default_factory=dict)
    active_intents: List[Dict[str, Any]] = field(default_factory=list)

    ai_controlled_units: List[str] = field(default_factory=list)
    player_controlled_units: List[str] = field(default_factory=list)
    control_generation: int = 0
    unit_generations: Dict[str, int] = field(default_factory=dict)
    released_units: List[str] = field(default_factory=list)

    pending_events: List[Dict[str, Any]] = field(default_factory=list)
    pending_requests: Dict[str, Dict[str, Any]] = field(default_factory=dict)
    command_receipts: List[Dict[str, Any]] = field(default_factory=list)

    degraded_reason: str = ""
    last_strategy_tick: Optional[int] = None
    last_tactics_tick: Optional[int] = None
    model_errors: int = 0
    last_model_error_tick: Optional[int] = None
    # 战略层缺省（计划 §6 阶段 A：省略高层、单一四列决策入口时在状态里标注）。
    # 路由据此不再押在 is_strategy_due 上——active_plan 恒为 None 会让战略分支
    # 永远独占路由、战术节点永远轮不到（2026-09-12 实测 556/556 全 strategic、0 下发）。
    strategy_disabled: bool = False

    decision_log: List[Dict[str, Any]] = field(default_factory=list)
    overrides: List[Dict[str, Any]] = field(default_factory=list)

    # 本轮路由结果（节点间传递；持久化仅作诊断）。
    route: str = ""
    paused: bool = False
    # 本轮候选意图 / 待下发 / 仲裁结果（节点间传递，随 checkpoint 一起落盘便于诊断）。
    candidate_intents: List[Dict[str, Any]] = field(default_factory=list)
    dispatch_pending: List[str] = field(default_factory=list)
    intent_arbitration: Dict[str, Any] = field(default_factory=dict)
    last_checkpoint: Dict[str, Any] = field(default_factory=dict)

    # 玩家资源预留（方案 §6）：**必须是显式字段**，否则 to_dict/from_dict
    # 会把它们丢掉——"关闭重开副官保留本局已调整额度"就无从谈起。
    reserves: Dict[str, int] = field(default_factory=dict)
    reserves_initialized: bool = False
    reserves_percent: int = 0
    # 观测驱动的任务进度快照（方案 §4）：供 HUD 展示真实进展，与命令回执分离。
    task_progress: Dict[str, Any] = field(default_factory=dict)

    # 整局主线（2026-09-12 纠偏）：阶段 / 里程碑 / 四条 track / next_frontier /
    # interrupt_stack。**必须是显式字段**，否则 to_dict/from_dict 会把它丢掉 ——
    # "跨 tick / 跨 checkpoint 保留整局主线"就无从谈起（这正是纠偏要修的病根）。
    campaign_state: Dict[str, Any] = field(default_factory=dict)

    # ---------- 高频链路与五线路（2026-09-12 计划 P0/P1） ----------
    # 【必须是显式字段】`to_dict/from_dict` 是**显式字段表**：任何没写进来的键
    # 每轮都会被静默丢掉（同一类坑在本文件已经踩过一次，见上面两条注释）。
    # 这三个键若被丢掉：`fast_event_seq` 会让增量事件游标每轮归零；
    # `lane_cursor` 会让五线路轮转永远从第一条线开始；
    # `lanes_last_served` 会让"饿死保护"永远算不出饿死 —— 全是"功能在但不生效"。
    fast_event_seq: int = -1
    lane_cursor: int = 0
    lanes_last_served: Dict[str, int] = field(default_factory=dict)
    #: 每条线路的当前任务数/下次到期/最后处理 tick（只读诊断视图，供日志与验收）。
    lanes: Dict[str, Any] = field(default_factory=dict)
    #: 安全移动（计划 §7）：导航网格版本 + 每单位路线记录 + 闸门统计 + 紧急事件。
    #: 同样**必须是显式字段**（漏了就是"闸门看着在工作、记录每轮清空"）。
    nav_revision: int = -1
    routes: Dict[str, Any] = field(default_factory=dict)
    movement_stats: Dict[str, Any] = field(default_factory=dict)
    movement_urgent: List[Dict[str, Any]] = field(default_factory=list)

    # ---------- 代际与租约 ----------

    def next_generation(self) -> int:
        self.control_generation += 1
        return self.control_generation

    def generation_of(self, unit_id: str) -> int:
        return int(self.unit_generations.get(str(unit_id), 0))

    def ensure_units(self, unit_ids: List[str]) -> None:
        """首次由 AI 接管的单位登记代际（不动已被玩家接管的单位）。"""
        for unit_id in unit_ids:
            key = str(unit_id)
            if key in self.unit_generations:
                continue
            if key in self.player_controlled_units:
                continue
            self.unit_generations[key] = self.next_generation()
            if key not in self.ai_controlled_units:
                self.ai_controlled_units.append(key)

    def mark_player_override(self, unit_ids: List[str], server_tick: int,
                             reason: str = "") -> Dict[str, Any]:
        """玩家手动命令：代际 +1、撤销 AI lease、相关意图失效、任务标记局部接管。"""
        record = {
            "kind": "player_override",
            "unit_ids": [str(u) for u in unit_ids],
            "server_tick": int(server_tick),
            "reason": reason,
            "generation": 0,
        }
        for unit_id in unit_ids:
            key = str(unit_id)
            self.unit_generations[key] = self.next_generation()
            record["generation"] = self.control_generation
            if key in self.ai_controlled_units:
                self.ai_controlled_units.remove(key)
            if key not in self.player_controlled_units:
                self.player_controlled_units.append(key)
            if key in self.released_units:
                self.released_units.remove(key)
        dropped = self.invalidate_intents(set(str(u) for u in unit_ids), "player_override")
        record["dropped_intents"] = [item["intent_id"] for item in dropped]
        self.mark_tasks_for_units(unit_ids, TASK_PARTIALLY_OVERRIDDEN)
        self.overrides.append(record)
        return record

    def release_units(self, unit_ids: List[str], server_tick: int,
                      reason: str = "") -> Dict[str, Any]:
        """玩家显式归还单位：代际 +1（新的 AI 控制代际），允许重新接管。"""
        record = {
            "kind": "player_release",
            "unit_ids": [str(u) for u in unit_ids],
            "server_tick": int(server_tick),
            "reason": reason,
            "generation": 0,
        }
        for unit_id in unit_ids:
            key = str(unit_id)
            if key in self.player_controlled_units:
                self.player_controlled_units.remove(key)
            self.unit_generations[key] = self.next_generation()
            record["generation"] = self.control_generation
            if key not in self.released_units:
                self.released_units.append(key)
            if key not in self.ai_controlled_units:
                self.ai_controlled_units.append(key)
        # 被玩家接管的单位归还后，相关任务从 waiting_for_player 回到 running。
        for task_id, state in list(self.active_tasks.items()):
            if state in (TASK_WAITING_FOR_PLAYER, TASK_PARTIALLY_OVERRIDDEN):
                self.active_tasks[task_id] = TASK_RUNNING
        self.overrides.append(record)
        return record

    def is_unit_player_controlled(self, unit_id: str) -> bool:
        return str(unit_id) in self.player_controlled_units

    # ---------- 任务 ----------

    def register_task(self, task_id: str, state: str = TASK_PENDING) -> None:
        if task_id:
            self.active_tasks[str(task_id)] = state

    def set_task_state(self, task_id: str, state: str) -> None:
        if state not in EXTENDED_TASK_STATES:
            raise ValueError("unknown task state: %s" % state)
        if task_id:
            self.active_tasks[str(task_id)] = state

    def mark_tasks_for_units(self, unit_ids: List[str], state: str) -> None:
        """按单位反查计划任务：只把相关任务标记为局部接管，其余任务保持运行。"""
        wanted = {str(u) for u in unit_ids}
        plan = self.active_plan or {}
        for task in plan.get("tasks", []) or []:
            task_units = {str(u) for u in (task.get("units") or [])}
            if task_units & wanted:
                task_id = str(task.get("task_id", ""))
                if task_id:
                    self.active_tasks[task_id] = state
        if not plan.get("tasks"):
            # 没有任务声明单位时，退化为“计划仍在，任务状态待复核”。
            for task_id in list(self.active_tasks.keys()):
                self.active_tasks[task_id] = state

    def task_state(self, task_id: str) -> str:
        return self.active_tasks.get(str(task_id), TASK_UNKNOWN)

    # ---------- 意图 ----------

    def add_intent(self, intent: Dict[str, Any], state: str = INTENT_ACTIVE,
                   command_id: str = "") -> Dict[str, Any]:
        record = dict(intent)
        record["state"] = state
        record["drop_reason"] = ""
        record["attempts"] = int(record.get("attempts", 0))
        record["command_id"] = command_id or ""
        self.active_intents.append(record)
        self.ensure_units(list(record.get("unit_ids", [])))
        return record

    def find_intent(self, intent_id: str) -> Optional[Dict[str, Any]]:
        for record in self.active_intents:
            if record.get("intent_id") == intent_id:
                return record
        return None

    def live_intents(self, current_tick: int) -> List[Dict[str, Any]]:
        return [r for r in self.active_intents
                if r.get("state") in INTENT_LIVE_STATES
                and int(r.get("expires_tick", 0)) >= int(current_tick)]

    def units_of_live_intents(self) -> List[str]:
        units: List[str] = []
        for record in self.active_intents:
            if record.get("state") in INTENT_LIVE_STATES:
                for unit_id in record.get("unit_ids", []):
                    if unit_id not in units:
                        units.append(str(unit_id))
        return units

    def invalidate_intents(self, unit_ids: set, reason: str) -> List[Dict[str, Any]]:
        dropped: List[Dict[str, Any]] = []
        for record in self.active_intents:
            if record.get("state") not in INTENT_LIVE_STATES:
                continue
            if set(str(u) for u in record.get("unit_ids", [])) & unit_ids:
                record["state"] = INTENT_DROPPED
                record["drop_reason"] = reason
                dropped.append(record)
        return dropped

    def expire_intents(self, current_tick: int) -> List[Dict[str, Any]]:
        expired: List[Dict[str, Any]] = []
        for record in self.active_intents:
            if record.get("state") not in INTENT_LIVE_STATES:
                continue
            if int(record.get("expires_tick", 0)) < int(current_tick):
                record["state"] = INTENT_EXPIRED
                record["drop_reason"] = "expires_tick < server_tick"
                expired.append(record)
        return expired

    def is_intent_valid(self, intent: Dict[str, Any], current_tick: int) -> Tuple[bool, str]:
        """方案 §7 的四条丢弃条件（任一成立即失效；判定顺序=过期→玩家接管→代际→计划版本）。

        先判“玩家优先权”再判版本，保证玩家接管永远是最强理由（不被版本理由掩盖）。
        """
        unit_ids = [str(u) for u in intent.get("unit_ids", [])]
        if int(intent.get("expires_tick", 0)) < int(current_tick):
            return False, "expired"
        for unit_id in unit_ids:
            if self.is_unit_player_controlled(unit_id):
                return False, "lease_owner_player"
            # generation == 0 视为“未指定代际”（首次接管），其余必须与当前一致。
            expected = int(intent.get("generation", 0))
            if expected and expected != self.generation_of(unit_id):
                return False, "generation_mismatch"
        active_plan_version = self.plan_version or ""
        if active_plan_version and str(intent.get("plan_version", "")) != active_plan_version:
            return False, "plan_version_mismatch"
        return True, ""

    # ---------- 事件与回执 ----------

    def push_event(self, event: Dict[str, Any]) -> bool:
        """有界事件队列 + event_id 去重（队列满时丢弃最旧并保留新事件）。"""
        event_id = str(event.get("event_id", ""))
        if event_id:
            for existing in self.pending_events:
                if existing.get("event_id") == event_id:
                    return False
        self.pending_events.append(dict(event))
        while len(self.pending_events) > MAX_PENDING_EVENTS:
            self.pending_events.pop(0)
        return True

    def drain_events(self) -> List[Dict[str, Any]]:
        events = self.pending_events
        self.pending_events = []
        return events

    def record_receipt(self, receipt: Dict[str, Any]) -> None:
        self.command_receipts.append(dict(receipt))
        while len(self.command_receipts) > MAX_RECEIPT_HISTORY:
            self.command_receipts.pop(0)
        intent_id = str(receipt.get("intent_id", ""))
        if not intent_id:
            return
        record = self.find_intent(intent_id)
        if record is None:
            return
        status = str(receipt.get("status", ""))
        accepted = bool(receipt.get("accepted", False))
        if status == "PendingAuthority":
            record["state"] = INTENT_PENDING_AUTHORITY
            self.pending_requests[intent_id] = {
                "intent_id": intent_id,
                "command_id": str(receipt.get("command_id", "")),
                "state": INTENT_PENDING_AUTHORITY,
                "since_tick": int(self.server_tick),
                "task_id": str(record.get("task_id", "")),
                "action": str(record.get("action", "")),
                "unit_ids": [str(u) for u in record.get("unit_ids", [])],
            }
            return
        self.pending_requests.pop(intent_id, None)
        if accepted:
            record["state"] = INTENT_COMPLETED if status in ("Accepted", "Completed") else INTENT_ACTIVE
            task_id = str(record.get("task_id", ""))
            if task_id and self.task_state(task_id) in (TASK_PENDING, TASK_UNKNOWN):
                self.set_task_state(task_id, TASK_RUNNING)
            if status == "Completed":
                record["state"] = INTENT_COMPLETED
                if task_id:
                    self.set_task_state(task_id, TASK_COMPLETED)
        else:
            record["state"] = INTENT_FAILED
            record["drop_reason"] = "receipt_%s" % status
            if status == "PlayerOverride":
                # 权威层拒绝：按玩家优先权处理，避免下一轮继续抢控制。
                self.mark_player_override(list(record.get("unit_ids", [])),
                                          int(self.server_tick), "authority_player_override")
            elif status == "Expired":
                record["state"] = INTENT_EXPIRED
            elif status == "StaleGeneration":
                record["state"] = INTENT_DROPPED
            task_id = str(record.get("task_id", ""))
            if task_id and self.task_state(task_id) in (TASK_RUNNING, TASK_PENDING, TASK_UNKNOWN):
                self.set_task_state(task_id, TASK_UNKNOWN)

    def decide(self, kind: str, /, **payload: Any) -> Dict[str, Any]:
        """写一条决策日志（`kind` 位置专用，见 `nodes._decide` 的加固说明）。"""
        entry = {**payload, "kind": kind, "server_tick": int(self.server_tick)}
        self.decision_log.append(entry)
        while len(self.decision_log) > MAX_DECISION_LOG:
            self.decision_log.pop(0)
        return entry

    # ---------- 序列化 ----------

    def to_checkpoint(self) -> Dict[str, Any]:
        return {
            "checkpoint_version": CHECKPOINT_VERSION,
            "saved_tick": int(self.server_tick),
            "state": self.to_dict(),
        }

    def to_dict(self) -> Dict[str, Any]:
        return copy.deepcopy({
            "match_id": self.match_id,
            "player_id": self.player_id,
            "rules_version": self.rules_version,
            "server_tick": int(self.server_tick),
            "latest_snapshot_id": int(self.latest_snapshot_id),
            "active_plan": self.active_plan,
            "plan_version": self.plan_version,
            "plan_adopt_generation": int(self.plan_adopt_generation),
            "plan_version_history": list(self.plan_version_history),
            "active_tasks": dict(self.active_tasks),
            "active_intents": list(self.active_intents),
            "ai_controlled_units": list(self.ai_controlled_units),
            "player_controlled_units": list(self.player_controlled_units),
            "control_generation": int(self.control_generation),
            "unit_generations": dict(self.unit_generations),
            "released_units": list(self.released_units),
            "pending_events": list(self.pending_events),
            "pending_requests": dict(self.pending_requests),
            "command_receipts": list(self.command_receipts),
            "degraded_reason": self.degraded_reason,
            "last_strategy_tick": self.last_strategy_tick,
            "last_tactics_tick": self.last_tactics_tick,
            "model_errors": int(self.model_errors),
            "last_model_error_tick": self.last_model_error_tick,
            "strategy_disabled": bool(self.strategy_disabled),
            "decision_log": list(self.decision_log),
            "overrides": list(self.overrides),
            "route": self.route,
            "paused": bool(self.paused),
            "candidate_intents": list(self.candidate_intents),
            "dispatch_pending": list(self.dispatch_pending),
            "intent_arbitration": dict(self.intent_arbitration),
            "last_checkpoint": dict(self.last_checkpoint),
            "reserves": dict(self.reserves),
            "reserves_initialized": bool(self.reserves_initialized),
            "reserves_percent": int(self.reserves_percent),
            "task_progress": dict(self.task_progress),
            "campaign_state": dict(self.campaign_state),
            "fast_event_seq": int(self.fast_event_seq),
            "lane_cursor": int(self.lane_cursor),
            "lanes_last_served": dict(self.lanes_last_served),
            "lanes": {str(key): dict(value) if isinstance(value, dict) else value
                      for key, value in (self.lanes or {}).items()},
            "nav_revision": int(self.nav_revision),
            "routes": {str(key): dict(value) if isinstance(value, dict) else value
                       for key, value in (self.routes or {}).items()},
            "movement_stats": dict(self.movement_stats),
            "movement_urgent": list(self.movement_urgent),
        })

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "AdjutantGraphState":
        state = cls(match_id=str(data.get("match_id", "")),
                    player_id=str(data.get("player_id", "")))
        state.rules_version = str(data.get("rules_version", ""))
        state.server_tick = int(data.get("server_tick", 0))
        state.latest_snapshot_id = int(data.get("latest_snapshot_id", 0))
        state.active_plan = data.get("active_plan")
        state.plan_version = str(data.get("plan_version", ""))
        state.plan_adopt_generation = int(data.get("plan_adopt_generation", 0))
        state.plan_version_history = [str(item) for item in
                                      (data.get("plan_version_history") or [])]
        state.active_tasks = dict(data.get("active_tasks", {}))
        state.active_intents = [dict(item) for item in data.get("active_intents", [])]
        state.ai_controlled_units = [str(u) for u in data.get("ai_controlled_units", [])]
        state.player_controlled_units = [str(u) for u in data.get("player_controlled_units", [])]
        state.control_generation = int(data.get("control_generation", 0))
        state.unit_generations = {str(k): int(v) for k, v in (data.get("unit_generations") or {}).items()}
        state.released_units = [str(u) for u in data.get("released_units", [])]
        state.pending_events = [dict(item) for item in data.get("pending_events", [])]
        state.pending_requests = {str(k): dict(v) for k, v in (data.get("pending_requests") or {}).items()}
        state.command_receipts = [dict(item) for item in data.get("command_receipts", [])]
        state.degraded_reason = str(data.get("degraded_reason", ""))
        state.last_strategy_tick = data.get("last_strategy_tick")
        state.last_tactics_tick = data.get("last_tactics_tick")
        state.model_errors = int(data.get("model_errors", 0))
        state.last_model_error_tick = data.get("last_model_error_tick")
        state.strategy_disabled = bool(data.get("strategy_disabled", False))
        state.decision_log = [dict(item) for item in data.get("decision_log", [])]
        state.overrides = [dict(item) for item in data.get("overrides", [])]
        state.route = str(data.get("route", ""))
        state.paused = bool(data.get("paused", False))
        state.candidate_intents = [dict(item) for item in data.get("candidate_intents", [])]
        state.dispatch_pending = [str(item) for item in data.get("dispatch_pending", [])]
        state.intent_arbitration = dict(data.get("intent_arbitration") or {})
        state.last_checkpoint = dict(data.get("last_checkpoint") or {})
        state.reserves = {str(k).upper(): int(v)
                          for k, v in (data.get("reserves") or {}).items()}
        state.reserves_initialized = bool(data.get("reserves_initialized", False))
        state.reserves_percent = int(data.get("reserves_percent", 0) or 0)
        state.task_progress = dict(data.get("task_progress") or {})
        state.campaign_state = dict(data.get("campaign_state") or {})
        state.fast_event_seq = int(data.get("fast_event_seq", -1) or -1)
        state.lane_cursor = int(data.get("lane_cursor", 0) or 0)
        state.lanes_last_served = {str(key): int(value) for key, value
                                   in (data.get("lanes_last_served") or {}).items()}
        state.lanes = dict(data.get("lanes") or {})
        state.nav_revision = int(data.get("nav_revision", -1) or -1)
        state.routes = dict(data.get("routes") or {})
        state.movement_stats = dict(data.get("movement_stats") or {})
        state.movement_urgent = [dict(item) for item in (data.get("movement_urgent") or [])
                                 if isinstance(item, dict)]
        return state

    @classmethod
    def from_checkpoint(cls, payload: Dict[str, Any]) -> "AdjutantGraphState":
        version = int(payload.get("checkpoint_version", 0))
        if version != CHECKPOINT_VERSION:
            raise ValueError("checkpoint_version %s 不受支持（当前 %s）" % (
                version, CHECKPOINT_VERSION))
        return cls.from_dict(payload.get("state") or {})

    def summary(self) -> Dict[str, Any]:
        """诊断/日志视图（不含隐藏推理）。"""
        return {
            "match_id": self.match_id,
            "player_id": self.player_id,
            "rules_version": self.rules_version,
            "server_tick": self.server_tick,
            "latest_snapshot_id": self.latest_snapshot_id,
            "plan_version": self.plan_version,
            "plan_id": (self.active_plan or {}).get("plan_id", ""),
            "plan_phase_goal": (self.active_plan or {}).get("phase_goal", ""),
            "tasks": dict(self.active_tasks),
            "live_intents": [r.get("intent_id") for r in self.live_intents(self.server_tick)],
            "ai_controlled_units": list(self.ai_controlled_units),
            "player_controlled_units": list(self.player_controlled_units),
            "released_units": list(self.released_units),
            "control_generation": self.control_generation,
            "pending_requests": sorted(self.pending_requests.keys()),
            "degraded_reason": self.degraded_reason,
            "route": self.route,
            "paused": self.paused,
            # 五条线路账（计划 §5）：runner 的 tick 日志与验收都读这里。
            "lanes": dict(self.lanes),
            "lane_cursor": int(self.lane_cursor),
            # 安全移动（计划 §7）：闸门统计与网格版本，供验收读"无路径移动数/越界数"。
            "movement_stats": dict(self.movement_stats),
            "nav_revision": int(self.nav_revision),
            # 整局主线（诊断/HUD/验收共用一份口径，避免两处各算一套）。
            # 迟导入避免模块加载顺序耦合（campaign 只依赖 observation_view/placement）。
            "campaign": self._campaign_summary(),
        }

    def _campaign_summary(self) -> Dict[str, Any]:
        if not isinstance(self.campaign_state, dict) or not self.campaign_state:
            return {}
        try:
            from . import campaign as campaign_mod
            return campaign_mod.summary(self.campaign_state)
        except Exception:  # noqa: BLE001 —— 诊断视图失败绝不影响主链路
            return {}
