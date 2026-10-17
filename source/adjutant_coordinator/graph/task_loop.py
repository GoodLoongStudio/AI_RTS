# -*- coding: utf-8 -*-
"""任务反馈闭环合同（第一阶段 · 修改 2：把任务分支接成可执行闭环）。

## 定位（先读这段，防止建成第二套决策权威）

本模块**不选择动作**：任务从哪来、做什么仍由既有计划层 / 规则中台 / 模型决定
（唯一权威链不变）。本模块只做三件事：

1. **判定**：按任务类型对应的**权威指标**（建造进度 / 部署实体 / 真实交货 /
   到达 / 战果）判断每个活动任务处于 成功 / 正常等待 / 无进展 / 失败 / 超时 /
   受阻 / 未知，模型的自然语言理由不参与判定；
2. **记账**：`last_progress` 只由任务相关的实际变化更新（重复输出、计划保持、
   Accepted 回执、重复回执都不刷新）；期限与预算按**游戏时钟**（server_tick）
   计，暂停与玩家接管不消耗；模型网络超时按单调墙钟单独处理（既有
   `pending_timeout` 语义，不混用）；
3. **反馈**：失败/超时进诊断并给上层目标留状态；恢复按预算+冷却+方案指纹
   受控重试；耗尽或证据不足明确受阻（缺项 + 重评条件）。

## 任务状态机（合同）

    pending ──任务建立──▶ running ──成功证据──▶ succeeded（关闭并通知目标）
                              │
                              ├─有进展且未到期限──▶ waiting（保持；记录等待原因）
                              │
                              ├─明确失败──▶ diagnosing ──预算内且条件变化──▶ recovering
                              │                    （attempt+1，方案指纹记入冷却）
                              ├─总期限到──▶ diagnosing（timeout 边）
                              └─无进展期限到──▶ diagnosing（no_progress 边）
    diagnosing ──无合法替代/证据不足──▶ blocked（缺项 + 重评条件；条件变化可重评）

结束态（succeeded/failed/blocked）**不重开**：加载恢复、时钟重置、过期异步结果
都不得修改已结束任务。

## 指标口径（权威来源）

| kind | 进展指标 | 成功判据 | 依据 |
|---|---|---|---|
| build | `constructed[建筑类型]` | ≥1 座完工 | 权威观测 `constructed=True`（不是"已下单"） |
| produce | `counts[产品类型]` | ≥1 个部署实体 | 队列项消失不算；要看到实体 |
| gather | `refinery_delivered` | ≥1 次真实交货 | 权威 `OreRefinery.delivery_stats()`（余额可能同时受支出影响，不用余额） |
| move 类 | `unit_arrival_tick[单位]` | 到达目标半径 | 观测到达事件 |
| attack | `enemy_damage_events` | 战果事件增加 | 掉血/确认死亡（不是"发过 attack"） |

## 期限与预算（单位：秒，按实测 tick 率换算；取值依据见各常量注释）

- 无进展期限：正常建造/生产等待的**下界**——低于它一律判"正常等待"，
  不能把"正在施工"误报成卡死；
- 总期限：单任务允许的**上界**——到点无论有无进展都进诊断（timeout 边）；
- 重试预算 / 冷却 / 方案指纹：治"同一失败点反复撞"；指纹按
  `kind|目标|失败原因` 归并，冷却内不重试同指纹。
"""

from __future__ import annotations

import time
from typing import Any, Dict, List, Optional, Tuple

# ---- 任务状态 ----
TASK_PENDING = "pending"
TASK_RUNNING = "running"
TASK_WAITING = "waiting"
TASK_SUCCEEDED = "succeeded"
TASK_FAILED = "failed"
TASK_TIMED_OUT = "timed_out"
TASK_DIAGNOSING = "diagnosing"
TASK_RECOVERING = "recovering"
TASK_BLOCKED = "blocked"

#: 仍在活动（每轮都要评估）的状态。
LIVE_TASK_STATES = (TASK_PENDING, TASK_RUNNING, TASK_WAITING, TASK_DIAGNOSING,
                    TASK_RECOVERING)
#: 结束态：不重开、不因恢复/时钟重置改写。
ENDED_TASK_STATES = (TASK_SUCCEEDED, TASK_FAILED, TASK_TIMED_OUT, TASK_BLOCKED)

#: 进展指标名（与 facts 口径一一对应；写进追踪供回放）。
METRIC_BUILD = "constructed_count"
METRIC_PRODUCE = "deployed_count"
METRIC_GATHER = "delivered_count"
METRIC_ARRIVAL = "arrival_tick"
METRIC_DAMAGE = "enemy_damage_events"

#: 动作 → 任务类型（决定用哪套指标）。
KIND_OF_ACTION: Dict[str, str] = {
    "build": "build", "produce": "produce", "gather": "gather",
    "move": "move", "attack_move": "move", "scout": "move", "defend": "move",
    "retreat": "move", "regroup": "move", "attack": "attack", "hold": "hold",
}

# ---- 期限（秒）----
#: 取值依据：无进展期限取"该类任务一次正常往返/施工的可观测量级 + 余量"——
#: 建造要看工地出现→施工→完工（真机观测数十秒级）；采集要看往返交货；
#: 移动按最大地图穿越时间。都可用宿主配置覆盖（单位：秒）。
NO_PROGRESS_SECONDS: Dict[str, float] = {
    "build": 45.0, "produce": 60.0, "gather": 60.0,
    "move": 30.0, "attack": 45.0, "hold": 30.0,
}
#: 总期限：单任务允许的上界（到点走 timeout 边进诊断，不等无进展）。
DEADLINE_SECONDS: Dict[str, float] = {
    "build": 240.0, "produce": 240.0, "gather": 300.0,
    "move": 150.0, "attack": 180.0, "hold": 120.0,
}
DEFAULT_NO_PROGRESS_SECONDS = 45.0
DEFAULT_DEADLINE_SECONDS = 180.0

#: 默认重试预算与冷却（秒）。预算=同一目标允许的**已结论**恢复尝试次数；
#: 冷却=失败后同一方案指纹的静默期（按游戏 tick 计）。
DEFAULT_RETRY_BUDGET = 3
DEFAULT_COOLDOWN_SECONDS = 15.0
#: C2 返修：单次恢复尝试的**结果等待窗**（秒）。授权后在这段时间内没有收到
#: 任何命令回执，不算失败（未调度/被门禁挡住/在途都不计）；窗口过后本次尝试
#: 才结论并计入预算——最后一次已授权尝试总能等到自己的窗口。
DEFAULT_ATTEMPT_WINDOW_SECONDS = 30.0

#: 没有实测 tick 率时的换算回退（Hz）。保守取中低档：换算出更长的 tick 期限，
#: 不会把正常等待误判成超时；实测率到手后自动切换。
FALLBACK_TICK_HZ = 30.0

#: 台账保留的已结束任务条数（有界；回放要能查最近失败，但不无限增长）。
LEDGER_ENDED_LIMIT = 64
ATTEMPT_HISTORY_LIMIT = 16


def seconds_to_ticks(seconds: float, tick_hz: float) -> int:
    """秒 → tick（用实测 tick 率；没有就用保守回退值）。"""
    try:
        hz = float(tick_hz or 0.0)
    except (TypeError, ValueError):
        hz = 0.0
    if hz <= 0:
        hz = FALLBACK_TICK_HZ
    return max(1, int(round(float(seconds) * hz)))


def _as_int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _receipt_outcome(receipt: Dict[str, Any]) -> str:
    """Return accepted/rejected/unknown for a command receipt.

    The receipt status is authoritative: `PendingAuthority`, `Unknown`, and a
    missing status are observations of an unresolved command, not rejection.
    """
    status = str(receipt.get("status", "") or "").strip().casefold()
    if status in ("", "pendingauthority", "unknown"):
        return "unknown"
    if status in ("accepted", "completed", "partiallyaccepted"):
        return "accepted"
    if bool(receipt.get("accepted", False)):
        return "accepted"
    return "rejected" if status in ("rejected", "partialrejected") else "unknown"


def _attempt_is_counted(record: Dict[str, Any]) -> bool:
    """Check conclusion by stable attempt id, with legacy tick fallback."""
    attempt_id = str(record.get("attempt_id", "") or "")
    if attempt_id:
        return str(record.get("attempt_counted_id", "") or "") == attempt_id
    started = _as_int(record.get("attempt_started_tick"))
    return _as_int(record.get("attempt_counted_tick"), -1) == started


def _archive_attempt(record: Dict[str, Any], tick: int) -> None:
    """Keep a bounded snapshot before a new attempt replaces the live view."""
    attempt_id = str(record.get("attempt_id", "") or "")
    if not attempt_id:
        return
    history = [item for item in (record.get("attempt_history") or [])
               if isinstance(item, dict)]
    if any(str(item.get("attempt_id", "")) == attempt_id for item in history):
        return
    history.append({
        "attempt_id": attempt_id,
        "attempt": _as_int(record.get("attempt")),
        "started_tick": _as_int(record.get("attempt_started_tick")),
        "concluded_tick": _as_int(tick),
        "outcome": str(record.get("attempt_fail_kind", "")),
        "intent_ids": list(record.get("attempt_intents") or [])[:16],
        "command_ids": list(record.get("attempt_commands") or [])[:16],
        "receipts": [dict(item) for item in (record.get("attempt_receipts") or [])
                     if isinstance(item, dict)][-16:],
    })
    record["attempt_history"] = history[-ATTEMPT_HISTORY_LIMIT:]


def _merge_attempt_receipt(record: Dict[str, Any], receipt: Dict[str, Any]) -> None:
    """Merge receipt state by command identity, allowing pending → terminal."""
    intent_id = str(receipt.get("intent_id", "") or "")
    command_id = str(receipt.get("command_id", "") or "")
    if not intent_id:
        return
    intent_ids = list(record.get("attempt_intents") or [])
    if intent_id not in intent_ids:
        intent_ids.append(intent_id)
    record["attempt_intents"] = intent_ids[-16:]
    if command_id:
        command_ids = list(record.get("attempt_commands") or [])
        if command_id not in command_ids:
            command_ids.append(command_id)
        record["attempt_commands"] = command_ids[-16:]
    key = "%s|%s" % (intent_id, command_id)
    settled = [item for item in (record.get("attempt_receipts") or [])
               if isinstance(item, dict)]
    previous = next((item for item in settled if str(item.get("key", "")) == key), None)
    incoming = {
        "key": key, "intent_id": intent_id, "command_id": command_id,
        "status": str(receipt.get("status", "")),
        "accepted": bool(receipt.get("accepted", False)),
        "tick": _as_int(receipt.get("server_tick")),
    }
    if previous is None:
        incoming["status_history"] = [incoming["status"]] if incoming["status"] else []
        settled.append(incoming)
    elif _receipt_outcome(previous) == "unknown":
        history = list(previous.get("status_history") or [])
        if incoming["status"] and (not history or history[-1] != incoming["status"]):
            history.append(incoming["status"])
        previous.update(incoming)
        previous["status_history"] = history[-8:]
    # A terminal snapshot is immutable: duplicate finals and late Pending are no-ops.
    record["attempt_receipts"] = settled[-16:]
    if settled:
        record["attempt_result_tick"] = max(_as_int(item.get("tick")) for item in settled)


def task_kind_of(intent: Dict[str, Any]) -> str:
    return KIND_OF_ACTION.get(str(intent.get("action", "")), "")


def metric_of_kind(kind: str) -> str:
    return {
        "build": METRIC_BUILD, "produce": METRIC_PRODUCE, "gather": METRIC_GATHER,
        "move": METRIC_ARRIVAL, "attack": METRIC_DAMAGE, "hold": METRIC_ARRIVAL,
    }.get(str(kind or ""), "")


def new_record(task_id: str, *, goal_id: str = "", parent_task_id: str = "",
               plan_version: str = "", kind: str = "", tick: int = 0,
               mono: Optional[float] = None, config: Optional[Dict[str, Any]] = None
               ) -> Dict[str, Any]:
    """建一条任务台账记录（默认值全部显式；缺测字段写 unknown 语义的 0/空）。"""
    cfg = config or {}
    now_mono = time.monotonic() if mono is None else float(mono)
    budget = _as_int(cfg.get("loop_retry_budget"))
    if budget <= 0:
        budget = DEFAULT_RETRY_BUDGET
    return {
        "task_id": str(task_id),
        "goal_id": str(goal_id or ""),
        "parent_task_id": str(parent_task_id or ""),
        "plan_version": str(plan_version or ""),
        "kind": str(kind or ""),
        "attempt": 0,
        "state": TASK_PENDING,
        "created_tick": _as_int(tick),
        "created_mono": round(now_mono, 6),
        "last_progress_tick": _as_int(tick),
        "last_progress_mono": round(now_mono, 6),
        "progress_metric": metric_of_kind(kind),
        "progress_value": 0,
        "progress_peak": 0,
        #: 任务建立时的指标基线（R2 返修）：成功必须**超过基线**（本任务带来的增量），
        #: 不是"世界上已经有 1 个"——否则任务尚未执行就会因历史事实被判成功。
        #: 首次评估时采集（与任务建立同轮），`baseline_captured` 防重复覆盖。
        "baseline": 0,
        "baseline_captured": False,
        "baseline_tick": _as_int(tick),
        #: 尝试生命周期（R4/C2 返修）：attempt_started_* 只由"恢复授权"写，
        #: last_progress_* 只由实际指标变化写——状态切换绝不刷新实际进展。
        "attempt_started_tick": 0,
        "attempt_started_mono": 0.0,
        # E2：恢复授权的稳定身份；不再用 tick 猜测同一尝试。
        "attempt_id": "",
        # 0 = 旧 checkpoint（允许 issued_tick 兼容判定）；1 = 已绑定明确身份。
        "attempt_identity_version": 0,
        "attempt_counted_id": "",
        "attempt_commands": [],
        "attempt_history": [],
        #: D2 返修：本次尝试的**下发身份**——授权之后实际产生的 intent_id 集合
        #: 与按 `intent_id|command_id` 只结算一次的回执明细。尝试结论按身份
        #: 结算：旧命令/同 tick 旧回执/重放回执都不能结算新尝试。
        "attempt_intents": [],
        "attempt_receipts": [],
        #: 本次尝试最新回执 tick（追踪显示用）；结论规则见 diagnose。
        "attempt_result_tick": 0,
        "attempt_counted_tick": -1,
        "attempt_window_ticks": 0,
        #: D1 返修：尝试结论分类——execution_failed（明确拒绝）/ no_result
        #: （下发无结果）/ no_dispatch（授权后无下发=调度等待）。
        "attempt_fail_kind": "",
        #: 调度等待预算（第三轮复核语义边界）：授权后始终没有下文的次数，
        #: 与执行失败预算 **分开计量**，零执行不被统计成多次执行失败。
        "schedule_waits": 0,
        "schedule_budget": 0,
        #: 归因模式（D3 返修，首次可判定时登记且**不再切换**）：
        #: site=指定工地实体 / type=建筑类型增量 / order=生产台账订单 /
        #: delivered=交货计数 / arrival=到达 / damage=战果。
        #: 登记后基线与当前指标同语义同单位，杜绝"判据切换"造成的假成功/假等待。
        "attribution": "",
        #: 指定工地实体名（target.entity_id；场景路径不算工地身份）。
        "site_entity": "",
        #: 成功判据的归因说明（C4 返修）：order=按订单/工地归因，
        #: type_shared=按类型增量（共享里程碑语义，两者在记录里可区分）。
        "success_basis": "",
        "timeout_count": 0,
        "deadline_tick": 0,          # 首次评估时按 kind 配置换算
        "no_progress_limit_ticks": 0,
        "retry_budget": budget,
        "retries_used": 0,
        "failure_fingerprint": "",
        "cooldown_until_tick": 0,
        "waiting_reason": "",
        "blocked_missing": [],
        "recheck_conditions": [],
        "goal_feedback": "",
        "last_reason_code": "created",
        "last_reason_cn": "任务建立",
        "updated_tick": _as_int(tick),
        "ended": False,
    }


# ---------------------------------------------------------------------------
# 指标求值（唯一实现：与 progress / campaign 同口径，不另写一套事实）
# ---------------------------------------------------------------------------


def metric_value(record: Dict[str, Any], *, facts: Dict[str, Any],
                 state: Dict[str, Any], tick: int) -> Tuple[Any, str]:
    """当前指标值 + 中文说明。取不到权威字段时返回 ("unknown", 原因)。

    `unknown` 是**合法返回值**：证据不足时不许猜 0（0 会被当成"测过了是 0"）。

    R2 返修（独立复核反例）：指标必须是**本任务建立之后、与本次目标相符**的权威证据：
    - build/produce/gather：全局计数在任务建立时采集基线，只认**超过基线的增量**；
    - move：到达 tick 必须**晚于任务建立**（旧到达事实不算），且目标位置相符
      （记录了对目标pos时用 `seen_arrivals` 的 unit|target 键核对）。
    """
    kind = str(record.get("kind", ""))
    metric = str(record.get("progress_metric", ""))
    if not metric:
        return "unknown", "该任务还没有可判定的动作类型"
    created_tick = _as_int(record.get("created_tick"))
    if metric == METRIC_BUILD:
        building = str(record.get("building_type", "") or "")
        constructed = facts.get("constructed") or {}
        if not building:
            return "unknown", "尚未从意图/工地推定建筑类型"
        # D3 返修：归因模式**首次可判定时登记且不再切换**。
        # - site：任务指定了工地实体 → 只认那个工地；工地不在观测里 =
        #   "工地丢失/不可观测"（unknown），**禁止**退回类型计数认领别处完工
        #   （第三轮反例：SiteA 消失后 SiteB 完工被算成 A 成功）；
        # - type：没有指定工地（自动落点）→ 类型增量（共享里程碑语义）。
        site = str(record.get("site_entity", "") or "")
        own_constructed = facts.get("own_constructed") or {}
        if site:
            if not record.get("attribution"):
                record["attribution"] = "site"
            if site not in own_constructed:
                return ("unknown",
                        "指定工地 %s 不在观测中（丢失或不可观测，不认领别处完工）" % site)
            record["success_basis"] = "order"
            status = own_constructed.get(site)
            if status is None:
                return ("unknown", "指定工地 %s 的 constructed 状态未知" % site)
            done = 1 if status is True else 0
            return done, "工地 %s %s" % (site, "已完工" if done else "未完工")
        if not record.get("attribution"):
            record["attribution"] = "type"
        record["success_basis"] = "type_shared"
        value = _as_int(constructed.get(building, 0))
        unknown_count = _as_int((facts.get("constructed_unknown") or {}).get(building, 0))
        baseline = (_as_int(record.get("baseline"))
                    if record.get("baseline_captured") else None)
        threshold = _as_int(record.get("success_threshold"), 1) or 1
        # 明确完工增量足以通过时可直接使用；否则未定状态不能当作 0 或成功。
        if unknown_count > 0 and (baseline is None or value < baseline + threshold):
            return ("unknown", "建筑类型 %s 另有 %d 个工地完工状态未知" %
                    (building, unknown_count))
        return value, "已完工 %s=%d（类型共享判定）" % (building, value)
    if metric == METRIC_PRODUCE:
        product = str(record.get("product_type", "") or "")
        if not product:
            return "unknown", "尚未从意图/台账推定产品类型"
        # C4/D3 返修：按**生产台账归因**——只数"本任务订单产出"的已完成 item
        # （intent_id 属于本任务，或生产者是本任务指定设施）。全局 counts 会让
        # 并发同类型订单互相认领成果（独立复核反例：只新增一辆坦克，
        # 两条生产任务都判成功）。
        # P2 边界：只数**任务建立之后**完成的 item——建立时已在队列/更早完成
        # 的订单不算本任务成果；建立后、首次采样前完成的订单要能算成功
        # （第三轮反例：created=100、finished=110、首采=120 被误采成基线）。
        ledger = state.get("production_ledger") or {}
        own_intents = {str(i) for i in (record.get("intent_ids") or [])}
        producer = str(record.get("target_key", "") or "")
        attributable = 0
        for entry in ledger.values():
            if not isinstance(entry, dict):
                continue
            finished = _as_int(entry.get("finished_tick"))
            if not finished or finished < created_tick:
                continue
            if product and str(entry.get("product_id", "")) not in ("", product):
                continue
            entry_intent = str(entry.get("intent_id", ""))
            entry_producer = str(entry.get("producer", ""))
            if (own_intents and entry_intent in own_intents) or \
                    (producer and entry_producer == producer):
                attributable += 1
        if not record.get("attribution"):
            record["attribution"] = "order"
        record["success_basis"] = "order"
        return attributable, "本订单建立后已完成生产 %d 件（台账归因）" % attributable
    if metric == METRIC_GATHER:
        delivered = facts.get("refinery_delivered")
        if delivered is None:
            return "unknown", "观测缺少矿场交付统计"
        return _as_int(delivered), "累计交货 %d 次" % _as_int(delivered)
    if metric == METRIC_ARRIVAL:
        units = record.get("units") or []
        if not units:
            return "unknown", "任务没有关联单位"
        arrivals = state.get("unit_arrival_tick") or {}
        # 只认任务建立之后的到达：旧到达事实（早于 created_tick）不是本任务的成果。
        best = max((_as_int(arrivals.get(str(u), 0)) for u in units), default=0)
        if best <= 0 or best < created_tick:
            return 0, "尚无任务建立后的到达事实（tick<%d）" % created_tick
        target_pos = record.get("target_pos")
        if isinstance(target_pos, (list, tuple)) and len(target_pos) >= 2:
            # 目标位置相符性：seen_arrivals 的键是 "unit|[x,z]（0.1m）"。
            seen = state.get("seen_arrivals") or {}
            wanted_x = round(float(target_pos[0]), 1)
            wanted_z = round(float(target_pos[1]), 1)
            for unit in units:
                key = "%s|[%s, %s]" % (str(unit), wanted_x, wanted_z)
                arrival_tick = _as_int(seen.get(key))
                if arrival_tick >= created_tick and arrival_tick > 0:
                    return arrival_tick, "单位 %s 已于 tick %d 到达目标（%.1f,%.1f）" % (
                        unit, arrival_tick, wanted_x, wanted_z)
            return 0, "有到达事实但目标位置不相符（未到本任务目标）"
        return best, "单位最近到达 tick=%d（晚于任务建立）" % best
    if metric == METRIC_DAMAGE:
        events = (state.get("campaign_state") or {}).get("enemy_damage_events")
        if events is None:
            return "unknown", "campaign 未记录战果事件"
        return _as_int(events), "战果事件 %d" % _as_int(events)
    return "unknown", "未知指标 %s" % metric


def success_reached(record: Dict[str, Any], value: Any) -> bool:
    """成功判据：指标**超过任务建立时的基线**（本任务带来的增量 ≥1）。

    R2 返修：旧判据是"全局值 ≥1"，新生产任务会因为"世界上原来就有一辆坦克"
    被立即判成功（独立复核反例）。建造/生产/采集都按增量判；移动/攻击按
    "建立后发生的事实"判（见 metric_value）。
    """
    if value == "unknown":
        return False
    baseline = record.get("baseline")
    if baseline is None or not record.get("baseline_captured"):
        # 基线未采集（异常路径）：不许放行"≥1"的旧口径，按证据不足处理。
        return False
    threshold = _as_int(record.get("success_threshold"), 1) or 1
    return _as_int(value) >= _as_int(baseline) + threshold


def failure_fingerprint(record: Dict[str, Any], reason: str) -> str:
    """方案指纹：kind|目标|失败原因——同一失败点的重试按它归并冷却。"""
    target = str(record.get("target_key", "") or record.get("building_type", "")
                 or record.get("product_type", "") or "")
    return "%s|%s|%s" % (str(record.get("kind", "")), target, str(reason or "")[:60])


# ---------------------------------------------------------------------------
# 评估（每轮一次；纯判定 + 台账更新，不选新动作）
# ---------------------------------------------------------------------------


def _config_seconds(config: Optional[Dict[str, Any]], kind: str, key: str,
                    table: Dict[str, float], default: float) -> float:
    """取期限配置（秒）。**0/负值 = 不覆盖**（用按类型默认表）——

    0 是"用默认"的显式标记，不是"1 秒"：把 0.0 当覆盖值会让所有期限塌缩成
    1 秒（真实对局里表现为满屏假超时，round-02 闸门实测抓到过）。
    """
    cfg = config or {}

    def _positive(value: Any) -> float:
        try:
            number = float(value)
        except (TypeError, ValueError):
            return 0.0
        return number if number > 0 else 0.0

    override = _positive(cfg.get("%s_%s" % (key, kind)))
    if override:
        return override
    override = _positive(cfg.get(key))
    if override:
        return override
    return float(table.get(kind, default))


def evaluate_record(record: Dict[str, Any], *, facts: Dict[str, Any],
                    state: Dict[str, Any], tick: int, mono: float,
                    config: Optional[Dict[str, Any]] = None
                    ) -> Tuple[str, str, str, Dict[str, Any]]:
    """评估一条任务记录。

    返回 `(verdict, reason_code, reason_cn, metrics)`：
    verdict ∈ succeeded / waiting / no_progress / timeout / failed /
              diagnosing / recovering / blocked / unknown / running。
    只依据**权威指标与时钟**，不读模型理由。
    """
    cfg = config or {}
    kind = str(record.get("kind", ""))
    tick_hz = float(state.get("measured_tick_hz", 0) or 0)
    no_progress_limit = _as_int(record.get("no_progress_limit_ticks"))
    if no_progress_limit <= 0:
        no_progress_limit = seconds_to_ticks(
            _config_seconds(cfg, kind, "loop_no_progress_seconds",
                            NO_PROGRESS_SECONDS, DEFAULT_NO_PROGRESS_SECONDS), tick_hz)
        record["no_progress_limit_ticks"] = no_progress_limit
    deadline_tick = _as_int(record.get("deadline_tick"))
    if deadline_tick <= 0:
        deadline_tick = _as_int(record.get("created_tick")) + seconds_to_ticks(
            _config_seconds(cfg, kind, "loop_deadline_seconds",
                            DEADLINE_SECONDS, DEFAULT_DEADLINE_SECONDS), tick_hz)
        record["deadline_tick"] = deadline_tick
    stalled_ticks = _as_int(tick) - _as_int(record.get("last_progress_tick"))
    total_ticks = _as_int(tick) - _as_int(record.get("created_tick"))
    metrics: Dict[str, Any] = {"metric": record.get("progress_metric", ""),
                               "stalled_ticks": stalled_ticks, "total_ticks": total_ticks}

    # ① 总期限（游戏时钟）：**先于证据判定**。缺证据的任务（计划先于动作、
    #    观测缺失）也必须到期沿 timeout 边进诊断——"一直证据不足"不是终态
    #    （C1 返修：旧实现在 evidence_missing 处提前返回，超期任务永远 pending）。
    if deadline_tick and _as_int(tick) >= deadline_tick:
        if str(record.get("state")) in (TASK_DIAGNOSING, TASK_RECOVERING) \
                and record.get("_deadline_reported"):
            pass  # 诊断流程中已报过：交给 diagnose（冷却/预算）决定去向
        else:
            record["_deadline_reported"] = True
            return ("timeout", "total_deadline",
                    "总期限已到（%d/%d tick）" % (total_ticks, deadline_tick), metrics)

    value, value_cn = metric_value(record, facts=facts, state=state, tick=tick)
    metrics["value"] = value
    metrics["detail"] = value_cn
    metrics["peak"] = record.get("progress_peak", 0)
    if value == "unknown":
        # 证据不足：不是失败、不是成功。但有**有界等待**：无进展期限到了
        # 就沿 no_progress 边进诊断（C1 返修），由 diagnose 给出去向。
        if stalled_ticks >= no_progress_limit:
            return ("no_progress", "no_progress_limit",
                    "证据不足且无进展已达期限（%d/%d tick：%s）" % (
                        stalled_ticks, no_progress_limit, value_cn), metrics)
        return "unknown", "evidence_missing", "证据不足：%s" % value_cn, metrics

    # ② 基线采集（R2 返修）：首次拿到可判定指标时记下"任务建立时的世界状态"，
    #    之后成功只认增量。采集与任务建立同轮发生（sync→evaluate 一轮完成）。
    #    D3/P2 返修：**身份绑定指标不套基线增量**——指定工地（site）、生产订单
    #    （order）、到达（arrival）的指标本身就只数"本任务建立之后的自身成果"
    #    （metric_value 已按 created_tick / intent 身份过滤），基线定义性为 0；
    #    否则"建立后、首采前完成"的订单会被误采成基线，导致永远等第二件
    #    （第三轮反例：created=100、finished=110、首采=120）。
    if not record.get("baseline_captured"):
        identity_bound = (str(record.get("attribution", "")) in ("site", "order")
                          or str(record.get("progress_metric", "")) == METRIC_ARRIVAL)
        record["baseline"] = 0 if identity_bound else value
        record["baseline_captured"] = True
        record["baseline_tick"] = _as_int(tick)
        metrics["baseline"] = record["baseline"]

    # ③ 实际进展 → 刷新 last_progress（只此一处；回执/重复输出/状态切换不刷新）。
    #    成功判据达成的那一次变化**也是进展**：先记账再判成功，否则"刚完成"
    #    的任务 last_progress 还停在上一轮，回放会把完工瞬间显示成旧进展。
    previous_peak = record.get("progress_peak", 0)
    try:
        advanced = _as_int(value) > _as_int(previous_peak)
    except (TypeError, ValueError):
        advanced = False
    if advanced:
        record["progress_peak"] = value
        record["last_progress_tick"] = _as_int(tick)
        record["last_progress_mono"] = round(float(mono), 6)
        metrics["peak"] = value

    # ④ 成功证据 → 关闭并推进（通知目标由调用方落）。
    if success_reached(record, value):
        return "succeeded", "success_evidence", "成功判据达成：%s" % value_cn, metrics

    # ⑤ 诊断/恢复流程中的任务：期限判定已在顶部完成（每轮只报一次），
    #    这里只报保持；重试节奏由 diagnose 的冷却+预算+尝试结论控制。
    if str(record.get("state")) in (TASK_DIAGNOSING, TASK_RECOVERING):
        return ("waiting", "diagnose_hold",
                "诊断/恢复中（停滞 %d tick，指标 %s）" % (stalled_ticks, value_cn), metrics)

    # ⑥ 无进展期限：正常推进中的等待不得误判（stalled 未到限 → waiting）。
    if stalled_ticks >= no_progress_limit:
        return ("no_progress", "no_progress_limit",
                "无进展已达期限（%d/%d tick，指标 %s）" % (
                    stalled_ticks, no_progress_limit, value_cn), metrics)
    return "waiting", "in_progress", "正常推进：%s" % value_cn, metrics


def apply_verdict(record: Dict[str, Any], verdict: str, reason_code: str,
                  reason_cn: str, *, tick: int, mono: float) -> List[Dict[str, Any]]:
    """把判定写回台账，返回**发生的变化**（供追踪/决策日志；空=无变化）。"""
    changes: List[Dict[str, Any]] = []
    previous_state = str(record.get("state", ""))
    record["updated_tick"] = _as_int(tick)
    record["last_reason_code"] = str(reason_code)
    record["last_reason_cn"] = str(reason_cn)[:160]
    new_state = previous_state
    if verdict == "succeeded":
        new_state = TASK_SUCCEEDED
        record["ended"] = True
        record["waiting_reason"] = ""
    elif verdict in ("timeout", "no_progress"):
        new_state = TASK_DIAGNOSING
        record["waiting_reason"] = ""
    elif verdict == "waiting":
        new_state = TASK_WAITING if previous_state in (
            TASK_RUNNING, TASK_WAITING, TASK_PENDING) else previous_state
        record["waiting_reason"] = str(reason_cn)[:120]
    elif verdict == "unknown":
        record["waiting_reason"] = "证据不足：%s" % str(reason_cn)[:100]
        new_state = previous_state if previous_state in LIVE_TASK_STATES else TASK_RUNNING
    if new_state != previous_state:
        record["state"] = new_state
        changes.append({"task_id": record.get("task_id"), "from": previous_state,
                        "to": new_state, "reason_code": reason_code,
                        "reason_cn": reason_cn, "tick": tick})
    # succeeded 时把进展峰值同步成当前值（回放要看到最终值）。
    if verdict == "succeeded":
        record["progress_value"] = record.get("progress_peak", record.get("progress_value"))
    else:
        record["progress_value"] = record.get("progress_peak", record.get("progress_value"))
    return changes


def diagnose(record: Dict[str, Any], *, facts: Dict[str, Any], state: Dict[str, Any],
             tick: int, mono: float, config: Optional[Dict[str, Any]] = None,
             failed_reason: str = "") -> Tuple[str, str, str]:
    """诊断步：决定 recovering / blocked / 保持（冷却或等待本次尝试结果）。

    尝试结论规则（D1/D2 返修，按**身份结算**）：

    - `attempt_intents` / `attempt_receipts` 记录本次授权之后实际下发的
      intent/command 与回执（旧命令、同 tick 旧回执、重放回执都不结算）；
    - **Accepted 回执不消耗失败预算**——命令被接受只说明开始执行，没有产出
      属于正常在途；
    - `PendingAuthority` / `Unknown` / 缺状态保持待确认，不算拒绝，也不因恢复等待窗
      到期而伪装成“已执行但无结果”；只有终态拒绝才记执行失败；
    - 终态 Accepted 在执行窗到期且无任务结果时可结论为 no_result；
    - 窗口已到仍**没有任何下发**（未调度/被门禁挡住）记 `schedule_waits`
      （调度等待），与执行失败预算 `retries_used` **分开计量**：零执行不能
      被统计成三次实际执行失败（第三轮复核语义边界）；
    - 任一预算耗尽 → 受阻，原因里写明是哪一种。
    """
    cfg = config or {}
    tick_hz = float(state.get("measured_tick_hz", 0) or 0)
    fingerprint = failure_fingerprint(record, failed_reason or
                                      str(record.get("last_reason_cn", "")))
    record["failure_fingerprint"] = fingerprint
    retries = _as_int(record.get("retries_used"))
    budget = _as_int(record.get("retry_budget"))
    if budget <= 0:
        budget = _as_int(cfg.get("loop_retry_budget"))
    if budget <= 0:
        budget = DEFAULT_RETRY_BUDGET
    schedule_waits = _as_int(record.get("schedule_waits"))
    schedule_budget = _as_int(record.get("schedule_budget"))
    if schedule_budget <= 0:
        schedule_budget = _as_int(cfg.get("loop_schedule_budget"))
    if schedule_budget <= 0:
        schedule_budget = budget
    cooldown_ticks = seconds_to_ticks(
        _config_seconds(cfg, str(record.get("kind", "")), "loop_cooldown_seconds",
                        {}, DEFAULT_COOLDOWN_SECONDS), tick_hz)
    attempt_window = _as_int(record.get("attempt_window_ticks"))
    if attempt_window <= 0:
        attempt_window = seconds_to_ticks(
            _config_seconds(cfg, str(record.get("kind", "")),
                            "loop_attempt_window_seconds", {},
                            DEFAULT_ATTEMPT_WINDOW_SECONDS), tick_hz)
        record["attempt_window_ticks"] = attempt_window
    preconditions_ok, missing = preconditions_of(record, facts=facts, state=state)
    if not preconditions_ok:
        record["state"] = TASK_BLOCKED
        record["ended"] = False
        record["blocked_missing"] = missing
        record["recheck_conditions"] = list(missing)
        record["blocked_signature"] = _recheck_signature(
            record, facts=facts, state=state)
        record["updated_tick"] = _as_int(tick)
        return (TASK_BLOCKED, "precondition_lost",
                "恢复前置条件不再满足，缺：%s" % "/".join(missing))

    # ---- 尝试结论（D1/D2）：按身份结算；Accepted 是在途，不是失败 ----
    attempt_started = _as_int(record.get("attempt_started_tick"))
    attempt_id = str(record.get("attempt_id", "") or "")
    if (attempt_id or attempt_started > 0) and not _attempt_is_counted(record):
        settled = [item for item in (record.get("attempt_receipts") or [])
                   if isinstance(item, dict)]
        dispatched = bool(record.get("attempt_commands")) if _as_int(
            record.get("attempt_identity_version")) >= 1 else bool(
                record.get("attempt_commands") or record.get("attempt_intents"))
        outcomes = [_receipt_outcome(item) for item in settled]
        rejected = "rejected" in outcomes
        accepted_seen = "accepted" in outcomes
        unresolved_seen = "unknown" in outcomes
        window_over = _as_int(tick) - attempt_started >= attempt_window
        if rejected:
            # 明确拒绝/失败 → 执行失败，计入执行预算。
            record["attempt_counted_tick"] = attempt_started
            record["attempt_counted_id"] = attempt_id
            retries += 1
            record["retries_used"] = retries
            record["attempt_fail_kind"] = "execution_failed"
            _archive_attempt(record, tick)
        elif accepted_seen and not window_over:
            # 已接受、仍在窗口内：正常在途（生产/建造需要时间），不算失败。
            held = str(record.get("state"))
            if held not in (TASK_DIAGNOSING, TASK_RECOVERING):
                held = TASK_DIAGNOSING
            record["state"] = held
            record["updated_tick"] = _as_int(tick)
            return (held, "attempt_in_flight",
                    "恢复尝试已下发并被接受，等待产出（授权于 tick %d，窗口 %d tick）"
                    % (attempt_started, attempt_window))
        elif unresolved_seen and not accepted_seen:
            # 权威仍未给出终态。即使本地尝试窗口结束，也不把未知改写为执行失败；
            # 保持占用并等待下一次权威复核或任务自身的实际结果事实。
            held = str(record.get("state"))
            if held not in (TASK_DIAGNOSING, TASK_RECOVERING):
                held = TASK_DIAGNOSING
            record["state"] = held
            record["updated_tick"] = _as_int(tick)
            return (held, "awaiting_authority",
                    "命令回执仍未有权威终态（%d tick 后仍未知），不计执行失败" %
                    max(0, _as_int(tick) - attempt_started))
        elif window_over:
            # 窗口已到：有下发无结果 → 执行失败；完全没下发 → 调度等待。
            record["attempt_counted_tick"] = attempt_started
            record["attempt_counted_id"] = attempt_id
            if dispatched:
                retries += 1
                record["retries_used"] = retries
                record["attempt_fail_kind"] = "no_result"
            else:
                schedule_waits += 1
                record["schedule_waits"] = schedule_waits
                record["attempt_fail_kind"] = "no_dispatch"
            _archive_attempt(record, tick)
        else:
            # 尚未下发、窗口未到：等待本次尝试被调度。
            held = str(record.get("state"))
            if held not in (TASK_DIAGNOSING, TASK_RECOVERING):
                held = TASK_DIAGNOSING
            record["state"] = held
            record["updated_tick"] = _as_int(tick)
            return (held, "awaiting_attempt_result",
                    "等待本次恢复尝试的结果（授权于 tick %d，窗口 %d tick，"
                    "未调度/在途不计失败）" % (attempt_started, attempt_window))

    if retries >= budget:
        record["state"] = TASK_BLOCKED
        record["ended"] = False
        record["blocked_missing"] = ["恢复执行预算已耗尽（失败 %d/%d，调度等待 %d/%d）"
                                     % (retries, budget, schedule_waits, schedule_budget)]
        record["recheck_conditions"] = ["失败方案条件变化（指纹 %s 的前提改变）" % fingerprint[:40]]
        record["blocked_signature"] = _recheck_signature(
            record, facts=facts, state=state)
        record["updated_tick"] = _as_int(tick)
        return (TASK_BLOCKED, "retry_budget_exhausted",
                "恢复执行预算耗尽（失败 %d/%d；调度等待 %d/%d 另计），保持受阻"
                % (retries, budget, schedule_waits, schedule_budget))
    if schedule_waits >= schedule_budget:
        record["state"] = TASK_BLOCKED
        record["ended"] = False
        record["blocked_missing"] = ["调度等待预算已耗尽（%d/%d 次授权后无下发）"
                                     % (schedule_waits, schedule_budget)]
        record["recheck_conditions"] = ["出现可执行的下发通道（候选/资源/门禁放行）"]
        record["blocked_signature"] = _recheck_signature(
            record, facts=facts, state=state)
        record["updated_tick"] = _as_int(tick)
        return (TASK_BLOCKED, "schedule_budget_exhausted",
                "调度等待预算耗尽（%d/%d 次授权均未产生下发；执行失败 %d/%d 另计）"
                % (schedule_waits, schedule_budget, retries, budget))
    # 冷却只对**此前已失败过的方案**生效：首次诊断（cooldown=0）直接放行恢复，
    # 否则"刚失败就永远等冷却"会把恢复边界推后一轮且语义重复。
    cooldown_until = _as_int(record.get("cooldown_until_tick"))
    if cooldown_until and _as_int(tick) < cooldown_until:
        # 保持当前流程态（RECOVERING 不翻成 DIAGNOSING）：两者都表示
        # "在诊断/恢复流程里等冷却"，翻来翻去只是噪声。
        held = str(record.get("state"))
        if held not in (TASK_DIAGNOSING, TASK_RECOVERING):
            held = TASK_DIAGNOSING
        record["state"] = held
        record["updated_tick"] = _as_int(tick)
        return (held, "cooldown_active",
                "失败方案冷却中（至 tick %d）" % cooldown_until)
    # 授权新尝试：attempt+1（任务 id 不变，尝试序号递增）；实际动作由既有层产出。
    # 【R4 返修】这里只写**尝试生命周期**（attempt_started_*/cooldown），
    # 绝不碰 last_progress_*——"恢复了"是状态切换，不是实际进展；
    # 用状态切换刷新进展会把停滞计时截短（独立复核反例：指标毫无变化，
    # diagnose 后 last_progress 从 100 变成 1000）。
    # 【C2 返修】授权不消耗预算：retries_used 只由"已结论尝试"增加（见上）。
    record["state"] = TASK_RECOVERING
    record["attempt"] = _as_int(record.get("attempt")) + 1
    record["attempt_id"] = "%s:%s:attempt-%d" % (
        str(state.get("match_id", "") or "match"),
        str(record.get("task_id", "") or "task"),
        _as_int(record.get("attempt")))
    record["attempt_identity_version"] = 1
    record["cooldown_until_tick"] = _as_int(tick) + cooldown_ticks
    record["attempt_started_tick"] = _as_int(tick)
    record["attempt_started_mono"] = round(float(mono), 6)
    record["attempt_counted_tick"] = -1
    record["attempt_counted_id"] = ""
    record["attempt_intents"] = []
    record["attempt_commands"] = []
    record["attempt_receipts"] = []
    record["attempt_result_tick"] = 0
    record["blocked_missing"] = []
    record["recheck_conditions"] = []
    record["updated_tick"] = _as_int(tick)
    return (TASK_RECOVERING, "recovery_attempt",
            "按预算恢复（第 %d 次尝试，已结论 %d/%d）" % (
                record["attempt"], retries, budget))


def preconditions_of(record: Dict[str, Any], *, facts: Dict[str, Any],
                     state: Dict[str, Any]) -> Tuple[bool, List[str]]:
    """恢复前的**重新核验**：前置条件、资源、权限、目标可达性（最小集）。

    只做本阶段所需的窄核验：任务类型对应的最小前提（工人/建造者/可见资源/
    产品设施）。缺项逐条列出（给玩家与回放看），不猜"也许还有"。
    """
    kind = str(record.get("kind", ""))
    missing: List[str] = []
    if kind in ("build",):
        if not facts.get("builders"):
            missing.append("没有可建造的工人")
        if not facts.get("resource_count"):
            missing.append("没有可见资源")
    elif kind == "produce":
        if not facts.get("producers"):
            missing.append("没有可生产的设施")
    elif kind == "gather":
        if not facts.get("workers"):
            missing.append("没有工人")
        if not facts.get("resource_count"):
            missing.append("没有可见资源点")
    elif kind in ("move", "attack"):
        if not facts.get("own"):
            missing.append("没有己方单位")
    # 资源检查（权威余额；build/produce 才需要——移动/采集不花钱）。
    if kind in ("build", "produce"):
        balance = facts.get("balance") or {}
        if not balance:
            missing.append("余额未知（证据不足）")
    return (not missing), missing


# ---------------------------------------------------------------------------
# 台账同步与每轮评估（节点调用入口）
# ---------------------------------------------------------------------------


def resolve_intent_types(intent: Dict[str, Any],
                         rules: Optional[Dict[str, Any]] = None
                         ) -> Tuple[str, str]:
    """从意图目标解析规范 (产品类型, 建筑类型)——D4 返修。

    生产/建造合同的合法字段是 `target.scene + target.producer`
    （`contracts.py` 的 TacticalIntent 校验的就是这两个），而场景名与
    定义 id **不是同一套命名**（`Infantry.tscn` → `soldier`）。解析顺序：
    ① 显式 product/definition_id/building 字段；② 回执已带的生产身份
    （`intent["production"]["product_id"]`）；③ **规则视图的场景→id 反查**
    （复用 `reserves._scene_to_id_index`，权威）；④ 场景基名兜底（可能不规范，
    但优于空缺）。规则任务名（`rule-produce-*`）的兜底只在 ①–④ 都失败时使用，
    **不依赖任务 ID 字符串**作为主口径。
    """
    target = intent.get("target") if isinstance(intent.get("target"), dict) else {}
    product = str(target.get("product", "") or target.get("definition_id", "") or "")
    building = str(intent.get("building_type", "") or target.get("building", "") or "")
    production = intent.get("production") if isinstance(intent.get("production"), dict) else {}
    if not product:
        product = str(production.get("product_id", "") or "")
    scene = str(target.get("scene", "") or "")
    if scene and (not product or not building):
        product_by_scene, building_by_scene = _scene_id_index(rules)
        if not product:
            product = product_by_scene.get(scene, "")
        if not building:
            building = building_by_scene.get(scene, "")
    if scene:
        base = scene.rsplit("/", 1)[-1].split(".")[0].lower()
        if base and not product:
            product = base
        if base and not building:
            building = base
    return product, building


def _scene_id_index(rules: Optional[Dict[str, Any]]) -> Tuple[Dict[str, str], Dict[str, str]]:
    """规则视图的场景→id 反查（复用 reserves 的唯一实现，不另抄一份）。"""
    from . import reserves as _reserves
    return _reserves._scene_to_id_index(rules)


def sync_ledger(state: Dict[str, Any], tick: int, mono: Optional[float] = None,
                rules: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """把 `active_tasks` 里还没有台账记录的任务补进来（幂等）。

    类型/目标从该任务的**在途意图**或计划任务推定（`resolve_intent_types`，
    经规则视图解析 scene→规范 id；推不出就留空，metric_value 按 unknown 处理）。
    """
    ledger = state.setdefault("task_ledger", {})
    now_mono = time.monotonic() if mono is None else float(mono)
    plan_tasks = {}
    for task in ((state.get("active_plan") or {}).get("tasks") or []):
        if isinstance(task, dict) and task.get("task_id"):
            plan_tasks[str(task.get("task_id"))] = task
    for task_id, task_state in list((state.get("active_tasks") or {}).items()):
        task_id = str(task_id)
        if not task_id:
            continue
        intents = [i for i in (state.get("active_intents") or [])
                   if isinstance(i, dict) and str(i.get("task_id", "")) == task_id]
        if task_id in ledger:
            # 已登记任务：计划先于动作时首轮只能建空记录，之后必须**补全**
            # 类型/单位/目标/指标（C1 返修：旧实现只补 order_key，导致战略任务
            # 永远 kind=""、evaluate_record 每轮 evidence_missing，连超期都不诊断）。
            existing = ledger[task_id]
            if intents:
                kind = task_kind_of(intents[0])
                if kind and not existing.get("kind"):
                    existing["kind"] = kind
                    existing["progress_metric"] = metric_of_kind(kind)
                units = sorted({str(u) for intent in intents
                                for u in (intent.get("unit_ids") or [])})[:16]
                if units:
                    existing["units"] = units
                intent_ids = sorted({str(i.get("intent_id", "")) for i in intents
                                     if i.get("intent_id")})[:16]
                if intent_ids:
                    merged = sorted(set(existing.get("intent_ids") or []) | set(intent_ids))
                    existing["intent_ids"] = merged[:16]
                for intent in intents:
                    # D4 返修：登记与补全使用**同一**解析口径（规则视图 scene→id）。
                    product, building = resolve_intent_types(intent, rules)
                    target = intent.get("target") if isinstance(intent.get("target"), dict) else {}
                    if not existing.get("building_type") and building:
                        existing["building_type"] = building
                    if not existing.get("product_type") and product:
                        existing["product_type"] = product
                    if not existing.get("target_key"):
                        existing["target_key"] = str(
                            target.get("entity_id", "") or target.get("scene", "") or "")
                    if not existing.get("site_entity"):
                        entity = str(target.get("entity_id", "") or "")
                        if entity and not entity.startswith("res://"):
                            existing["site_entity"] = entity
                    if not existing.get("target_pos"):
                        pos = target.get("pos")
                        if isinstance(pos, (list, tuple)) and len(pos) >= 2:
                            try:
                                existing["target_pos"] = [round(float(pos[0]), 1),
                                                          round(float(pos[1]), 1)]
                            except (TypeError, ValueError):
                                pass
                    if not existing.get("order_key"):
                        existing["order_key"] = order_key_of_intent(intent)
            continue
        kind = ""
        units: List[str] = []
        building = ""
        product = ""
        target_key = ""
        target_pos: List[float] = []
        site_entity = ""
        for intent in intents:
            kind = kind or task_kind_of(intent)
            units.extend(str(u) for u in (intent.get("unit_ids") or []))
            # D4 返修：统一解析口径（显式字段 → 回执身份 → 规则视图 scene→id → 基名）。
            resolved_product, resolved_building = resolve_intent_types(intent, rules)
            target = intent.get("target") if isinstance(intent.get("target"), dict) else {}
            building = building or resolved_building
            product = product or resolved_product
            target_key = target_key or str(target.get("entity_id", "") or
                                           target.get("scene", "") or "")
            if not site_entity:
                entity = str(target.get("entity_id", "") or "")
                if entity and not entity.startswith("res://"):
                    site_entity = entity
            if not target_pos:
                pos = target.get("pos")
                if isinstance(pos, (list, tuple)) and len(pos) >= 2:
                    try:
                        target_pos = [round(float(pos[0]), 1), round(float(pos[1]), 1)]
                    except (TypeError, ValueError):
                        target_pos = []
        # 最后兜底：规则意图 id 形如 `rule-build-<类型>` / `rule-produce-<产品>`——
        # 这是既有命名合同；模型任务 ID 无此保证，因此只作 ④ 之后的兜底。
        if not building and "build-" in task_id:
            building = task_id.split("build-", 1)[1].split("-", 1)[0]
        if not product and "produce-" in task_id:
            product = task_id.split("produce-", 1)[1].split("-", 1)[0]
        plan_task = plan_tasks.get(task_id) or {}
        record = new_record(
            task_id,
            goal_id=_goal_of_task(task_id),
            parent_task_id=str(plan_task.get("parent_task_id", "") or ""),
            plan_version=str(state.get("plan_version", "") or ""),
            kind=kind, tick=tick, mono=now_mono)
        record["units"] = sorted(set(units))[:16]
        record["building_type"] = building
        record["product_type"] = product
        record["target_key"] = target_key
        record["site_entity"] = site_entity
        record["target_pos"] = target_pos
        # C4 返修：本任务的意图 id 集合（生产台账按 intent_id 归因订单成果）。
        record["intent_ids"] = sorted({str(i.get("intent_id", "")) for i in intents
                                       if i.get("intent_id")})[:16]
        # 方案键（R1）：从该任务首条意图采集，仲裁侧用同一函数派生。
        record["order_key"] = order_key_of_intent(intents[0]) if intents else ""
        record["progress_metric"] = metric_of_kind(kind)
        ledger[task_id] = record
    # 有界：结束态只留最近 N 条（进行中的一条都不丢）。
    ended = [item for item in ledger.values() if item.get("ended")]
    if len(ended) > LEDGER_ENDED_LIMIT:
        ended.sort(key=lambda item: _as_int(item.get("updated_tick")))
        for item in ended[:len(ended) - LEDGER_ENDED_LIMIT]:
            ledger.pop(item.get("task_id"), None)
    return ledger


def order_key_of_intent(intent: Dict[str, Any]) -> str:
    """意图的"方案键"：`task_id|action|目标`（与台账同一派生规则）。

    R1 返修：受阻台账要能抑制**对应失败方案**的重发，两边必须用同一把钥匙——
    台账侧在 sync_ledger 时从该任务的首条意图采集，仲裁侧从候选用同一函数算。
    目标优先级：entity_id → scene → building → product/definition_id → 坐标。
    """
    target = intent.get("target") if isinstance(intent.get("target"), dict) else {}
    key = str(target.get("entity_id", "") or target.get("scene", "")
              or target.get("building", "") or target.get("product", "")
              or target.get("definition_id", "") or "")
    if not key:
        pos = target.get("pos")
        if isinstance(pos, (list, tuple)) and len(pos) >= 2:
            try:
                key = "%.0f,%.0f" % (float(pos[0]), float(pos[1]))
            except (TypeError, ValueError):
                key = ""
    return "%s|%s|%s" % (str(intent.get("task_id", "") or ""),
                         str(intent.get("action", "") or ""), key)


def blocked_order_keys(state: Dict[str, Any], tick: int = 0) -> Dict[str, str]:
    """当前**不可重发**的失败方案键 → 原因（仲裁按它抑制重发）。

    R1 返修：受阻状态变成**执行门禁**——方案键命中且任务仍处 BLOCKED 时，
    该意图在仲裁层丢弃（reason 可见）；任务因条件变化重评回诊断时键自动失效
    （不冻结正常动作）。

    C3-a 返修：冷却期同样拦**新重试**。DIAGNOSING/RECOVERING 且冷却未到
    （`cooldown_until_tick > tick`）时，同方案候选不许再进待下发——否则
    "授权了一次尝试"会被规则层每轮重生成，冷却形同虚设（独立复核反例：
    recovering + cooldown=10000 的候选仍 accepted 进 dispatch_pending）。
    例外：本次尝试**还没有任何回执**时放行（那是被授权的尝试在等首次执行，
    不是新重试）；已有回执/窗口已过说明这次尝试已结论，冷却内不再重发。
    换目标、换动作、其他任务的路线一律不受影响。
    """
    out: Dict[str, str] = {}
    ledger = state.get("task_ledger") or {}
    for record in ledger.values():
        if not isinstance(record, dict) or record.get("ended"):
            continue
        key = str(record.get("order_key", "") or "")
        if not key:
            continue
        task_state = str(record.get("state", ""))
        if task_state == TASK_BLOCKED:
            missing = record.get("blocked_missing") or []
            out[key] = (str(missing[0]) if missing else "失败方案受阻")[:120]
            continue
        if task_state in (TASK_DIAGNOSING, TASK_RECOVERING):
            cooldown_until = _as_int(record.get("cooldown_until_tick"))
            if not cooldown_until or _as_int(tick) < cooldown_until:
                stable_identity = (bool(str(record.get("attempt_id", "") or ""))
                                   and _as_int(record.get("attempt_identity_version")) >= 1)
                if stable_identity and not (record.get("attempt_commands") or []) \
                        and not (record.get("attempt_receipts") or []):
                    # 新尝试还没有任何实际下发：放行它的首次执行。
                    continue
                attempt_started = _as_int(record.get("attempt_started_tick"))
                result_tick = _as_int(record.get("attempt_result_tick"))
                if not stable_identity and attempt_started and result_tick < attempt_started:
                    # 本次尝试尚未拿到任何回执：放行它的首次执行。
                    continue
                out[key] = "失败方案冷却中（至 tick %d）" % cooldown_until
    return out


def _goal_of_task(task_id: str) -> str:
    """任务 → 上层目标（里程碑）：规则意图前缀是唯一映射来源。"""
    from . import campaign as campaign_mod
    text = str(task_id or "")
    if not text:
        return ""
    for milestone_id, spec in campaign_mod.MILESTONES.items():
        for prefix in spec.get("intent_prefixes") or ():
            if text.startswith(str(prefix)):
                return str(milestone_id)
    return ""


def _recheck_signature(record: Dict[str, Any], *, facts: Dict[str, Any],
                       state: Dict[str, Any]) -> str:
    """受阻重评用的条件签名：只有**这些条件变了**才算"条件变化"。

    取该任务类型真正依赖的条件（工人/建造者/资源/交货/施工/买得起/退避），
    不取无关活动：余额用"买得起"布尔而不是具体数值——否则每买一次坦克
    都会把受阻任务拉起来重评（600s 观察实测过的空转来源）；施工只取该任务
    目标类型的工地数，无关建筑的增减不算"条件变化"。
    """
    kind = str(record.get("kind", ""))
    balance = facts.get("balance") or {}
    funds = _as_int(balance.get("A", balance.get("a", 0)))
    building = str(record.get("building_type", "") or "")
    backoff_until = _as_int(state.get("build_backoff_until_tick"))
    current_tick = _as_int(state.get("server_tick"))
    parts = [
        "kind=%s" % kind,
        "workers=%d" % len(facts.get("workers") or []),
        "resource=%d" % _as_int(facts.get("resource_count")),
        "delivered=%s" % str(facts.get("refinery_delivered")),
        # 退避用"是否生效中"布尔：退避生效/到期都是真实的条件变化；
        # 用具体 until_tick 会把"每次新设退避"也算变化（那也是真变化，但布尔更稳）。
        "backoff=%s" % ("1" if backoff_until > current_tick else "0"),
        "affordable=%s" % ("1" if funds > 0 else "0"),
    ]
    if kind == "build":
        parts.append("builders=%d" % len(facts.get("builders") or []))
        parts.append("built=%s" % str((facts.get("constructed") or {}).get(building, 0)))
        parts.append("sites=%s" % str((facts.get("counts") or {}).get(building, 0)))
    elif kind == "produce":
        parts.append("producers=%d" % len(facts.get("producers") or []))
    return "|".join(parts)


def _sync_attempt_results(state: Dict[str, Any], ledger: Dict[str, Any]) -> None:
    """把**本次尝试**的下发与回执按身份关联进台账（D2 返修）。

    尝试身份 = 授权之后实际下发的 intent/command 集合：
    - `attempt_intents`：该任务 issued_tick ≥ attempt_started_tick 的意图
      （授权同轮或之后才产生的命令；旧命令的 intent 不进来）；
    - `attempt_receipts`：按 `intent_id|command_id` 合并回执状态；同一身份可以从
      Pending/Unknown 推进为终态，终态重放不重复结算，迟到的非终态不覆盖终态；
    - 新授权使用显式 attempt identity；仅旧 checkpoint 保留 tick 兼容路径。

    同时保留任务级 `attempt_result_tick`（本次尝试最新回执 tick）供追踪显示。
    """
    intents = [i for i in (state.get("active_intents") or []) if isinstance(i, dict)]
    receipts = [r for r in (state.get("command_receipts") or []) if isinstance(r, dict)]
    if not intents and not receipts:
        return
    for record in ledger.values():
        if not isinstance(record, dict) or record.get("ended"):
            continue
        started = _as_int(record.get("attempt_started_tick"))
        attempt_id = str(record.get("attempt_id", "") or "")
        identity_version = _as_int(record.get("attempt_identity_version"))
        if (started <= 0 and not (attempt_id and identity_version >= 1)) or _attempt_is_counted(record):
            continue  # 没有在途尝试，或本次尝试已结论
        task_id = str(record.get("task_id", ""))
        known = {str(x) for x in (record.get("attempt_intents") or [])}
        # 新 checkpoint 只认仲裁时绑定的稳定身份；issued_tick 仅用于旧 checkpoint。
        if attempt_id and identity_version >= 1:
            mine = [i for i in intents
                    if str(i.get("task_id", "")) == task_id
                    and str(i.get("task_attempt_id", "") or "") == attempt_id]
        else:
            mine = [i for i in intents
                    if str(i.get("task_id", "")) == task_id
                    and _as_int(i.get("issued_tick")) >= started]
        for intent in mine:
            key = str(intent.get("intent_id", ""))
            if key:
                known.add(key)
        record["attempt_intents"] = sorted(known)[:16]
        known_commands = {str(item) for item in (record.get("attempt_commands") or [])
                          if str(item)}
        # ② 回执按身份结算（只结算一次）。
        settled = [item for item in (record.get("attempt_receipts") or [])
                   if isinstance(item, dict)]
        settled_by_key = {str(item.get("key", "")): item
                          for item in settled if item.get("key")}
        for receipt in receipts[-160:]:
            if receipt.get("identity_mismatch"):
                continue  # 异属回执只作原件留证，不能走无标签旧格式兼容路径。
            if any(receipt.get(key) not in (None, "") and
                   str(receipt[key]) != str(state.get(key, ""))
                   for key in ("match_id", "player_id")):
                continue
            intent_id = str(receipt.get("intent_id", ""))
            command_id = str(receipt.get("command_id", ""))
            receipt_attempt_id = str(receipt.get("task_attempt_id", "") or "")
            if attempt_id and identity_version >= 1:
                if receipt_attempt_id:
                    belongs = (receipt_attempt_id == attempt_id and intent_id in known
                               and bool(command_id) and command_id in known_commands)
                else:
                    # 旧 transport 没有扩展字段时，只接受本次 dispatch 登记的 command_id。
                    belongs = bool(command_id and command_id in known_commands
                                   and intent_id in known)
            else:
                belongs = intent_id in known
            if not belongs:
                continue
            key = "%s|%s" % (intent_id, command_id)
            incoming = {
                "key": key, "intent_id": intent_id, "command_id": command_id,
                "attempt_id": receipt_attempt_id or attempt_id,
                "status": str(receipt.get("status", "")),
                "accepted": bool(receipt.get("accepted", False)),
                "tick": _as_int(receipt.get("server_tick")),
            }
            previous = settled_by_key.get(key)
            if previous is None:
                incoming["status_history"] = [incoming["status"]]
                settled.append(incoming)
                settled_by_key[key] = incoming
                continue
            previous_outcome = _receipt_outcome(previous)
            incoming_outcome = _receipt_outcome(incoming)
            if previous_outcome in ("accepted", "rejected"):
                # 一个终态已经关闭这个 command identity；重复终态及乱序旧 Pending
                # 只留在原始 command_receipts 流，不改变任务的结算快照。
                continue
            history = list(previous.get("status_history") or [])
            if incoming["status"] and (not history or history[-1] != incoming["status"]):
                history.append(incoming["status"])
            previous.update(incoming)
            previous["status_history"] = history[-8:]
        record["attempt_receipts"] = settled[-16:]
        if settled:
            record["attempt_result_tick"] = max(
                _as_int(item.get("tick")) for item in settled)


def evaluate(state: Dict[str, Any], observation: Optional[Dict[str, Any]] = None,
             tick: int = 0, config: Optional[Dict[str, Any]] = None,
             trace: Any = None, facts: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """每轮评估一次任务闭环（`node_ingest` 调用）。

    `facts` 传 `campaign.build_facts(state, observation, tick)` 的结果（唯一事实源）；
    不传则退回 campaign 里留存的签名级事实（证据少时按 unknown 处理，不猜）。
    返回本轮报告（供 HUD/日志/追踪）；任何异常都由调用方兜底
    （闭环判定失效绝不允许拖垮指挥链）。
    """
    mono = time.monotonic()
    rules = None
    if isinstance(observation, dict):
        rules = observation.get("rules")
    ledger = sync_ledger(state, int(tick), mono, rules=rules)
    if facts is None:
        facts = _facts_from_state(state)
    # C2 返修：把该任务**最新一条命令回执的 tick** 关联进台账
    # （attempt_result_tick）——尝试是否"已结论"要看真实回执，不能只看计时。
    _sync_attempt_results(state, ledger)
    changes: List[Dict[str, Any]] = []
    feedback: Dict[str, Dict[str, Any]] = {}
    for task_id, record in list(ledger.items()):
        if record.get("ended"):
            continue
        state_name = str(record.get("state"))
        # 受阻态：**只在条件签名变化时重评**。放在 LIVE 检查之前——
        # 放在后面是死代码（BLOCKED 不在 LIVE_TASK_STATES 里，跨轮受阻永远重评不了；
        # 而同一轮内 diagnose 刚设的 BLOCKED 又会按旧冷却无条件放行，形成
        # diagnosing→blocked→diagnosing 每轮空转，600s 观察实测 369+368 次）。
        if state_name == TASK_BLOCKED:
            # D1 返修：受阻**不屏蔽成功证据**——授权被接受、慢速执行、订单在
            # 受阻期间完成时，任务必须能凭自身归因证据关闭（第三轮反例：预算被
            # Accepted 提前耗尽后订单完成，任务却永远 blocked、changes 为空）。
            blocked_verdict, blocked_code, blocked_cn, blocked_metrics = evaluate_record(
                record, facts=facts, state=state, tick=int(tick), mono=mono, config=config)
            if blocked_verdict == "succeeded":
                row_changes = apply_verdict(record, blocked_verdict, blocked_code,
                                            blocked_cn, tick=int(tick), mono=mono)
                for change in row_changes:
                    change["metrics"] = blocked_metrics
                changes.extend(row_changes)
                if record.get("goal_id"):
                    feedback[str(record["goal_id"])] = {
                        "state": "progressed", "task_id": task_id,
                        "reason_code": blocked_code,
                        "reason_cn": "受阻期间订单完成：%s" % blocked_cn,
                        "tick": int(tick)}
                continue
            ok, missing = preconditions_of(record, facts=facts, state=state)
            signature = _recheck_signature(record, facts=facts, state=state)
            previous = str(record.get("blocked_signature", ""))
            if ok and previous and signature != previous:
                record["state"] = TASK_DIAGNOSING
                record["blocked_missing"] = []
                record["recheck_conditions"] = []
                record["blocked_signature"] = ""
                record["updated_tick"] = int(tick)
                changes.append({"task_id": task_id, "to": TASK_DIAGNOSING,
                                "reason_code": "recheck_conditions_met",
                                "reason_cn": "受阻条件已变化，重新评估",
                                "tick": int(tick)})
                if record.get("goal_id"):
                    feedback[str(record["goal_id"])] = {
                        "state": "diagnosing", "task_id": task_id,
                        "reason_code": "recheck_conditions_met",
                        "reason_cn": "受阻条件已变化，重新评估", "tick": int(tick)}
                # C3-b 返修：**不 continue**——重评放行后必须同轮完成诊断决定
                # （预算/冷却），再让仲裁门禁看到最终状态。旧实现直接 continue，
                # 本轮 blocked 键已失效、diagnose 还没跑，候选当轮就能下发
                # （独立复核反例：预算仍 3/3，同方案 accepted 进 dispatch_pending）。
                state_name = TASK_DIAGNOSING
            elif ok and not previous:
                # 首次进入受阻后的签名基线（没有基线就无从比较"变化"）。
                record["blocked_signature"] = signature
                continue
            else:
                continue
        if state_name not in LIVE_TASK_STATES:
            continue
        verdict, reason_code, reason_cn, metrics = evaluate_record(
            record, facts=facts, state=state, tick=int(tick), mono=mono, config=config)
        # 权威回执/进度层已判 failed 的任务：直接进诊断（不重复计时）。
        # 只在**尚未进入诊断流程**时覆盖判定：已在 DIAGNOSING/RECOVERING 的任务
        # 由 diagnose 的尝试生命周期治理，每轮重复覆盖只会制造事件churn
        # （round-06 闸门实测：197 条 receipt_failed 里绝大多数是重复进入）。
        task_state = str((state.get("active_tasks") or {}).get(task_id, ""))
        if task_state == "failed" and str(record.get("state")) not in (
                TASK_FAILED, TASK_DIAGNOSING, TASK_RECOVERING):
            verdict, reason_code = "no_progress", "receipt_failed"
            reason_cn = "权威回执/进度判定失败：进入诊断"
        if verdict in ("timeout", "no_progress"):
            # 【R3 返修】超时/无进展是**边**，不是终态：一律进 diagnosing，
            # 由同轮的 diagnose 决定 恢复（预算内）/受阻（耗尽或前置丢失）。
            # 旧实现把 timeout 直接设 ended=True，任务再也没有下一步
            # （独立复核反例：deadline 触发后 changes 为空、attempt 永远是 0）。
            # 例外：权威回执明确判失败（receipt_failed）且本任务没有恢复预算时，
            # 才记 TASK_FAILED 终态（"明确失败且无替代"）。
            receipt_failed = str(reason_code) == "receipt_failed"
            budget = _as_int(record.get("retry_budget"))
            if budget <= 0:
                budget = _as_int((config or {}).get("loop_retry_budget"))
            if budget <= 0:
                budget = DEFAULT_RETRY_BUDGET
            no_budget_left = _as_int(record.get("retries_used")) >= budget
            if receipt_failed and no_budget_left:
                record["state"] = TASK_FAILED
                record["ended"] = True
            else:
                record["state"] = TASK_DIAGNOSING
                record["ended"] = False
                if verdict == "timeout":
                    # "本次尝试超时"计数（整个目标的去向由 diagnose 决定）。
                    record["timeout_count"] = _as_int(record.get("timeout_count")) + 1
            record["updated_tick"] = int(tick)
            record["waiting_reason"] = ""
            changes.append({"task_id": task_id, "to": record["state"],
                            "reason_code": reason_code, "reason_cn": reason_cn,
                            "tick": int(tick), "metrics": metrics})
            if record.get("goal_id"):
                feedback[str(record["goal_id"])] = {
                    "state": "at_risk", "task_id": task_id,
                    "reason_code": reason_code, "reason_cn": reason_cn,
                    "tick": int(tick)}
        else:
            row_changes = apply_verdict(record, verdict, reason_code, reason_cn,
                                        tick=int(tick), mono=mono)
            for change in row_changes:
                change["metrics"] = metrics
            changes.extend(row_changes)
            if verdict == "succeeded" and record.get("goal_id"):
                feedback[str(record["goal_id"])] = {
                    "state": "progressed", "task_id": task_id,
                    "reason_code": "success_evidence", "reason_cn": reason_cn,
                    "tick": int(tick)}
        # 诊断/恢复态：本轮做诊断决策（恢复/受阻/保持冷却）。
        # DIAGNOSING 与 RECOVERING 都走 diagnose：恢复授权后的等待也受冷却约束，
        # 冷却到期才发下一次恢复（预算内）。
        if str(record.get("state")) in (TASK_DIAGNOSING, TASK_RECOVERING):
            before_state = str(record.get("state"))
            # 去重基准必须是**上一轮 diagnose 的结论**：evaluate_record 本轮会把
            # last_reason_code 改写成 diagnose_hold，拿它当基准等于每周都"有变化"
            # （返修闸门实测：290 条 cooldown_active 里只有 6 次真恢复）。
            before_code = str(record.get("_last_diag_code", ""))
            before_attempt = _as_int(record.get("attempt"))
            outcome, diag_code, diag_cn = diagnose(
                record, facts=facts, state=state, tick=int(tick), mono=mono,
                config=config,
                failed_reason=str(record.get("last_reason_cn", "")))
            record["_last_diag_code"] = diag_code
            # C5 返修：去重只合并**无意义轮询**；attempt/授权身份变化是真实事件，
            # 必须记录（旧实现只比状态+原因码，冷却跨过后 attempt 2→3 被吞，
            # 时间线看不到第 3 次授权——独立复核反例）。
            if outcome != before_state or diag_code != before_code \
                    or _as_int(record.get("attempt")) != before_attempt:
                changes.append({"task_id": task_id, "to": outcome,
                                "reason_code": diag_code, "reason_cn": diag_cn,
                                "tick": int(tick), "attempt": record.get("attempt", 0)})
                if record.get("goal_id"):
                    feedback[str(record["goal_id"])] = {
                        "state": ("recovering" if outcome == TASK_RECOVERING else
                                  "blocked" if outcome == TASK_BLOCKED else "diagnosing"),
                        "task_id": task_id, "reason_code": diag_code,
                        "reason_cn": diag_cn, "tick": int(tick)}
            record["last_reason_code"] = diag_code
            record["last_reason_cn"] = str(diag_cn)[:160]
        # 注意：受阻态的重评在循环开头处理（BLOCKED 不在 LIVE_TASK_STATES，
        # 放在这里对"跨轮受阻"是死代码）。同一轮内 diagnose 刚设的 BLOCKED
        # 由下一轮开头的分支按签名比较决定是否重评。
    if feedback:
        state.setdefault("task_ledger_feedback", {}).update(feedback)
    report = {"updated_tick": int(tick), "changes": changes,
              "feedback": feedback,
              "tasks": {task_id: {"state": str(record.get("state", "")),
                                  "attempt": _as_int(record.get("attempt")),
                                  "metric": record.get("progress_metric", ""),
                                  "value": record.get("progress_value"),
                                  "last_progress_tick": _as_int(record.get("last_progress_tick")),
                                  "waiting_reason": str(record.get("waiting_reason", "")),
                                  "blocked_missing": list(record.get("blocked_missing") or [])}
                        for task_id, record in ledger.items() if not record.get("ended")},
              "ended": sum(1 for record in ledger.values() if record.get("ended"))}
    state["task_loop_report"] = report
    if trace is not None and changes:
        for change in changes:
            metrics = change.get("metrics") or {}
            try:
                trace.task(str(change.get("task_id", "")), str(change.get("to", "")),
                           goal_id=str((ledger.get(change.get("task_id")) or {}).get("goal_id", "")),
                           attempt=_as_int(change.get("attempt")),
                           state=str(change.get("to", "")),
                           reason_code=str(change.get("reason_code", "")),
                           reason_cn=str(change.get("reason_cn", "")),
                           metric=str(metrics.get("metric", "")),
                           # 无进展时长与当前指标值：时间表的"最长无进展时间"
                           # 与"卡在哪一步"直接从事件读，不必回查台账。
                           stalled_ticks=_as_int(metrics.get("stalled_ticks")),
                           total_ticks=_as_int(metrics.get("total_ticks")),
                           metric_value=metrics.get("value"),
                           metric_detail=str(metrics.get("detail", ""))[:80],
                           server_tick=int(tick))
            except Exception:  # noqa: BLE001 —— 旁路永不拖垮闭环
                pass
    return report


def _facts_from_state(state: Dict[str, Any]) -> Dict[str, Any]:
    """闭环判定用的事实快照（只读既有权威字段，不重新解析观测）。

    `campaign_state._facts` 是 campaign 每轮算好的最小事实签名；这里按需补
    余额/建造者等（同一份观测的既有解析结果，不引入第二份事实源）。
    """
    campaign = state.get("campaign_state") or {}
    facts = dict(campaign.get("_facts") or {})
    tactical_facts = state.get("_last_tactical_facts")
    if isinstance(tactical_facts, dict):
        for key in ("constructed", "constructed_unknown", "own_constructed", "counts",
                    "builders", "producers", "balance",
                    "resource_count", "refinery_delivered", "workers"):
            if key in tactical_facts and key not in facts:
                facts[key] = tactical_facts[key]
    return facts


__all__ = [
    "TASK_PENDING", "TASK_RUNNING", "TASK_WAITING", "TASK_SUCCEEDED", "TASK_FAILED",
    "TASK_TIMED_OUT", "TASK_DIAGNOSING", "TASK_RECOVERING", "TASK_BLOCKED",
    "LIVE_TASK_STATES", "ENDED_TASK_STATES", "NO_PROGRESS_SECONDS",
    "DEADLINE_SECONDS", "DEFAULT_RETRY_BUDGET", "DEFAULT_COOLDOWN_SECONDS",
    "new_record", "metric_value", "success_reached", "failure_fingerprint",
    "evaluate_record", "apply_verdict", "diagnose", "preconditions_of",
    "sync_ledger", "evaluate", "seconds_to_ticks", "metric_of_kind", "task_kind_of",
]
