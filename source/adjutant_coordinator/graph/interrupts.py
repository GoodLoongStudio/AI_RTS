# -*- coding: utf-8 -*-
"""中断语义：玩家打断优先、紧急战术事件可打断普通战略任务。

纪律（方案 §4、§6、§7）：
- 玩家打断（player_override / player_release）：最高优先级路由，立即增加控制代际、
  撤销相关 AI lease、使相关意图失效，但不清空战略计划；
- 紧急战术事件（基地受袭、发现敌军）：抢占同单位的低优先级意图；
- 其余事件只在战术触发窗口内进入战术节点；
- 本模块只做状态语义，不直接发命令（发命令在节点 dispatch 阶段，走权威入口）。
"""

from __future__ import annotations

from typing import Any, Dict, Iterable, List, Optional, Set

from .state import (
    INTENT_LIVE_STATES, TASK_PARTIALLY_OVERRIDDEN, TASK_REASSIGNED,
    TASK_WAITING_FOR_PLAYER,
)

# ---------------- 事件词表 ----------------

EVT_MATCH_STARTED = "match_started"
EVT_BASE_UNDER_ATTACK = "base_under_attack"
EVT_ENEMY_SPOTTED = "enemy_spotted"
EVT_FORMATION_LOSS = "formation_loss"
EVT_TARGET_DEAD = "target_dead"
EVT_PATH_FAILED = "path_failed"
EVT_QUEUE_IDLE = "queue_idle"
EVT_TASK_COMPLETED = "task_completed"
EVT_TASK_STALLED = "task_stalled"
EVT_OUTCOME_CHANGED = "outcome_changed"
EVT_PLAYER_OVERRIDE = "player_override"
EVT_PLAYER_RELEASE = "player_release"

EVENT_KINDS = (
    EVT_MATCH_STARTED, EVT_BASE_UNDER_ATTACK, EVT_ENEMY_SPOTTED, EVT_FORMATION_LOSS,
    EVT_TARGET_DEAD, EVT_PATH_FAILED, EVT_QUEUE_IDLE, EVT_TASK_COMPLETED,
    EVT_TASK_STALLED, EVT_OUTCOME_CHANGED, EVT_PLAYER_OVERRIDE, EVT_PLAYER_RELEASE,
)

# 紧急战术事件：可以打断普通战略任务（但永远不能打断玩家）。
#
# 【2026-09-13 试过把 `path_failed` 也放进来，已撤回】金标准回放
# `fixtures/replay_path_failed.jsonl` 钉死的是另一套语义：
# 「路径失败**不取消**在途意图（同目标重复下单被拦、**改目标的重规划才放行**）」。
# 把它接进紧急路由会让图立刻丢弃在途意图（金标准 4 条断言同时红）。
# 计划 §7 的"送入 `urgent`"按 §5 的线路定义执行 = 送进 **urgent 线路**
# （见 `nodes._raise_movement_urgent`），不改变图的紧急路由。
EMERGENCY_EVENT_KINDS = (EVT_BASE_UNDER_ATTACK, EVT_ENEMY_SPOTTED)
# 玩家控制事件：最高优先级。
CONTROL_EVENT_KINDS = (EVT_PLAYER_OVERRIDE, EVT_PLAYER_RELEASE)
# 战略层重大事件（低频触发战略重排）。
STRATEGIC_EVENT_KINDS = (EVT_MATCH_STARTED, EVT_OUTCOME_CHANGED)

ROUTE_WAIT = "wait"
ROUTE_PLAYER_INTERRUPT = "player_interrupt"
ROUTE_EMERGENCY_TACTICAL = "emergency_tactical"
ROUTE_STRATEGIC = "strategic"
ROUTE_TACTICAL = "tactical"


def classify_event_kind(kind: str) -> str:
    if kind in CONTROL_EVENT_KINDS:
        return "control"
    if kind in EMERGENCY_EVENT_KINDS:
        return "emergency"
    if kind in STRATEGIC_EVENT_KINDS:
        return "major"
    return "normal"


def has_control_event(events: Iterable[Dict[str, Any]]) -> bool:
    return any(str(e.get("kind", "")) in CONTROL_EVENT_KINDS for e in events)


def has_emergency_event(events: Iterable[Dict[str, Any]]) -> bool:
    return any(str(e.get("kind", "")) in EMERGENCY_EVENT_KINDS for e in events)


def has_major_event(events: Iterable[Dict[str, Any]]) -> bool:
    return any(str(e.get("kind", "")) in STRATEGIC_EVENT_KINDS for e in events)


def event_units(events: Iterable[Dict[str, Any]], kinds: Optional[Iterable[str]] = None) -> Set[str]:
    """从事件 payload 提取相关单位（subject 支持逗号分隔；缺失则返回空集合）。"""
    scope = set(kinds) if kinds is not None else None
    units: Set[str] = set()
    for event in events:
        kind = str(event.get("kind", ""))
        if scope is not None and kind not in scope:
            continue
        payload = event.get("payload") or {}
        subject = payload.get("subject", "")
        if isinstance(subject, str):
            for item in subject.split(","):
                item = item.strip()
                if item:
                    units.add(item)
        elif isinstance(subject, (list, tuple)):
            units.update(str(item) for item in subject if str(item))
    return units


def is_strategy_due(state, current_tick: int, events: Iterable[Dict[str, Any]],
                    config: Dict[str, Any]) -> bool:
    """战略触发：开局/周期到期/重大事件（且当前计划已过期或尚无计划）。"""
    if state.active_plan is None:
        return True
    interval = int(config.get("strategy_interval_ticks", 3600))
    last = state.last_strategy_tick
    if last is None:
        return True
    if current_tick - int(last) >= interval:
        return True
    return has_major_event(events) and plan_expired(state, current_tick)


def strategy_in_cooldown(state, current_tick: int, config: Dict[str, Any]) -> bool:
    """战略模型连续失败已进冷却：此时不应让战略独占路由。

    为什么必须让位：`node_strategic_agent` 在冷却期内会直接 skip（不做任何决策），
    而 `active_plan` 为空时 `is_strategy_due` 恒为真 → `classify_route` 永远返回
    strategic → 战术轮永远轮不到 → 整局一个命令都发不出（实测连续 6 轮全 strategic、
    sent=0）。让位后战术层（含 rules_fallback 兜底）可以继续指挥部队。
    冷却判据与 `nodes.model_calls_allowed` 保持一致，避免两处语义分叉。
    """
    errors = int(state.model_errors or 0)
    if errors < int(config.get("model_error_limit", 3)):
        return False
    last = state.last_model_error_tick
    if last is None:
        return True
    return ((int(current_tick) - int(last))
            < int(config.get("model_retry_cooldown_ticks", 600)))


def plan_expired(state, current_tick: int) -> bool:
    if state.active_plan is None:
        return True
    return int(current_tick) > int(state.active_plan.get("valid_until_tick", 0))


def is_tactics_due(state, current_tick: int, events: Iterable[Dict[str, Any]],
                   config: Dict[str, Any], pending_authority: bool = False) -> bool:
    """战术触发：事件驱动（`tactics_interval_ticks` 节流 + 有事件）。

    【2026-09-12 晚修：取消"全局 PendingAuthority 压制"】
    原实现是 `if pending_authority: return False` —— 只要**任意一个**请求在等权威确认
    （`state.pending_requests` 非空），**整轮战术决策就被跳过**。实测后果（用户质问
    "既然每秒一次思考，为什么没看到副官持续下命令"）：
      主循环 0.58 秒/轮，而模型实际每 **4.7 秒**才被问一次 —— 因为 `produce`/`attack_move`
      这类命令会先回 `PendingAuthority`（等 `op=commands` 账本复核），期间路由恒为 `wait`。
    "不要对同一单位重复下发"是**仲裁层**的职责（`pending_authority_unresolved` 指纹去重
    + `duplicate_of_live_intent`），不需要在路由层再全局掐一次；而且它是**单位级**语义，
    不该由一条在途命令代表全队。
    参数 `pending_authority` 保留（调用方兼容），只作诊断用，不再参与判定。
    """
    interval = int(config.get("tactics_interval_ticks", 30))
    if last_gap_ok(state, current_tick, interval) is False:
        return False
    return bool(list(events))


def last_gap_ok(state, current_tick: int, interval: int) -> bool:
    last = state.last_tactics_tick
    if last is None:
        return True
    return int(current_tick) - int(last) >= interval


def classify_route(state, events: List[Dict[str, Any]], current_tick: int,
                   config: Dict[str, Any]) -> str:
    """本轮路由决策（方案 §4 的 player_override_gate 分支）。"""
    if has_control_event(events):
        return ROUTE_PLAYER_INTERRUPT
    if has_emergency_event(events) and last_gap_ok(
            state, current_tick, int(config.get("emergency_min_interval_ticks", 6))):
        return ROUTE_EMERGENCY_TACTICAL
    # 战略层缺省（--strategy-mode off / 模型缺失）时必须跳过战略分支：
    # is_strategy_due 在 active_plan=None 时恒为真，而战略层关闭后既不产出计划
    # 也不进冷却 → 路由永远 strategic，战术节点（唯一决策/下发入口）被饿死
    # （2026-09-12 实测：556/556 全 strategic、task_patch_submitted=0、own=4 全程不变）。
    strategy_active = not bool(getattr(state, "strategy_disabled", False))
    if strategy_active and is_strategy_due(state, current_tick, events, config) and not \
            strategy_in_cooldown(state, current_tick, config):
        return ROUTE_STRATEGIC
    if is_tactics_due(state, current_tick, events, config,
                      pending_authority=bool(state.pending_requests)):
        return ROUTE_TACTICAL
    if has_control_event(events):
        return ROUTE_PLAYER_INTERRUPT
    return ROUTE_WAIT


# ---------------- 玩家控制事件处理 ----------------

def apply_player_control_events(state, events: List[Dict[str, Any]],
                                current_tick: int) -> Dict[str, Any]:
    """消费玩家控制事件（player_override / player_release），返回处理摘要。

    玩家打断只影响相关单位与任务：计划保留，未涉及单位继续执行 AI 任务。
    """
    handled: List[Dict[str, Any]] = []
    for event in events:
        kind = str(event.get("kind", ""))
        if kind not in CONTROL_EVENT_KINDS:
            continue
        payload = event.get("payload") or {}
        raw_units = payload.get("subject", "")
        if isinstance(raw_units, str):
            units = [item.strip() for item in raw_units.split(",") if item.strip()]
        elif isinstance(raw_units, (list, tuple)):
            units = [str(item) for item in raw_units if str(item)]
        else:
            units = []
        if not units:
            continue
        if kind == EVT_PLAYER_OVERRIDE:
            record = state.mark_player_override(units, current_tick,
                                                str(payload.get("reason", "")))
        else:
            record = state.release_units(units, current_tick,
                                        str(payload.get("reason", "")))
        if state.pending_requests:
            # 已被玩家接管的单位不再等待权威复核（避免后续用旧回执抢回控制）。
            stale = [intent_id for intent_id, item in state.pending_requests.items()
                     if set(item.get("unit_ids", [])) & set(units)]
            for intent_id in stale:
                state.pending_requests.pop(intent_id, None)
        handled.append(record)
    state.decide("player_control_handled",
                 handled=[{"kind": item["kind"], "unit_ids": item["unit_ids"]}
                          for item in handled])
    return {"handled": handled, "interrupted": bool(handled)}


def interrupt_emergency_intents(state, emergency_units: Set[str],
                                current_tick: int) -> List[Dict[str, Any]]:
    """紧急战术事件抢占同单位的低优先级意图（不触碰玩家控制的单位）。"""
    preempted: List[Dict[str, Any]] = []
    if not emergency_units:
        return preempted
    for record in state.active_intents:
        if record.get("state") not in INTENT_LIVE_STATES:
            continue
        if bool(record.get("emergency", False)):
            continue
        if not (set(str(u) for u in record.get("unit_ids", [])) & emergency_units):
            continue
        record["state"] = "dropped"
        record["drop_reason"] = "preempted_by_emergency"
        preempted.append(record)
        task_id = str(record.get("task_id", ""))
        if task_id and state.active_tasks.get(task_id) in ("running", "pending", "unknown"):
            state.set_task_state(task_id, TASK_REASSIGNED)
    if preempted:
        state.decide("emergency_preempted", tick=current_tick,
                     intents=[r["intent_id"] for r in preempted],
                     unit_ids=sorted(emergency_units))
    return preempted


def mark_tasks_waiting_for_player(state, unit_ids: Set[str]) -> None:
    """玩家局部接管：相关任务标记 waiting_for_player（计划本身保留）。"""
    state.mark_tasks_for_units(sorted(unit_ids), TASK_WAITING_FOR_PLAYER)


def player_interrupt_summary(state) -> Dict[str, Any]:
    return {
        "player_controlled_units": list(state.player_controlled_units),
        "control_generation": state.control_generation,
        "plan_preserved": state.active_plan is not None,
        "plan_version": state.plan_version,
        "task_states": dict(state.active_tasks),
        "partially_overridden": [
            task_id for task_id, value in state.active_tasks.items()
            if value in (TASK_PARTIALLY_OVERRIDDEN, TASK_WAITING_FOR_PLAYER)
        ],
    }
