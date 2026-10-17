# -*- coding: utf-8 -*-
"""持续任务监督：从**观测事实**推导任务真实进展（方案 §4）。

为什么必须单独一层：
- `record_receipt()` 处理的是**命令接受回执**（Godot 说"收到了"），
  方案 §4 明确要求"命令接受回执与任务执行结果分开"；
- 游戏侧只导出观测（tactical/strategic/production），**不伪造任务进展**
  （`_op_strategic` 注释原文："任务进展由协调器管理，不在游戏端伪造"）；
- 因此"到达了没有 / 打死没有 / 采到没有 / 造出来没有"必须由本模块
  对观测做**跨轮差分**得出，而不是把 Accepted 当成成功。

可用的真实信号（来自 `op=tactical` / `op=strategic`）：
- `unit_self`: pos / hp / carried[2] / constructed / action / queue
- `resource`: 只有 kind/name/pos —— **没有余量字段**，耗尽只能靠"从完整观测消失"推断
- `unit_enemy*`: pos / hp / confirmed_dead / last_seen_tick
- `production[]`: 每个生产者的队列项 item_id / definition_id / state / completed_work / required_work

设计约束：
- 不引入第二套平衡数据，不构造观测之外的事实；
- 每个结论都带 `detail` 与 `metrics`，供 HUD 与诊断复用；
- 未观察到 ≠ 已死亡（沿用 `truncated` 语义：截断时不判定"消失=完成"）。
"""

from __future__ import annotations

import time
from typing import Any, Dict, List, Optional, Tuple

from .state import (
    INTENT_ACTIVE_UNKNOWN, INTENT_COMPLETED, INTENT_FAILED, INTENT_LIVE_STATES,
    TASK_COMPLETED, TASK_FAILED, TASK_INTERRUPTED, TASK_RUNNING, TASK_UNKNOWN,
)

#: 判定"已到达"的平面距离（米）。与单位半径同量级即可，避免永远差最后一步。
ARRIVE_RADIUS_M = 3.0
#: 连续多少次观测无实质进展判定 stalled（观测间隔由 runner 的 --tactics-interval 决定）。
STALL_LIMIT = 3
#: 目标脱离视野多久才判定"中断"（tick，60Hz → 600≈10 秒）。
#: 视野抖动很常见（单位走出视野再走回来），太早判中断会产生大量假警报。
LOST_SIGHT_TICKS = 600
#: 单次观测判定"有进展"的最小变化量（米）。
PROGRESS_EPSILON_M = 0.1

MOVEMENT_ACTIONS = ("move", "attack_move", "scout", "defend", "regroup", "retreat")

# ---------------------------------------------------------------------------
# 连续行动监督（prompt §3-C）：停滞/闲置必须有**有界的诊断与对账/恢复**记录
# ---------------------------------------------------------------------------
#
# 【为什么必须单独一层 · 2026-10-07】`_movement_progress` 在连续无进展时返回 `unknown`
# 并把意图留在 `active_unknown`（这是对的：未知不许判失败），但**没有任何人处理它** ——
# 单位继续被占用、命令不再重发、日志里只有一条 `stall_count` 在涨。真实局实测读到
# `stall_count` 22/27/28 的意图静静躺着，而 4 秒~30 秒的空档就是这么来的。
# `interrupts.EVT_TASK_STALLED` 这个词表常量此前**从未在生产路径出现过**。
#
# 这一层只回答三个问题，且都只能**记录**、不能判死：
#   ① 这个单位/意图停了多久（游戏时钟 + 墙钟各自记）？
#   ② 有没有一份说明它为什么停的**依据**（到达/受阻/等待资源/交战/集结/玩家接管）？
#   ③ 没有依据且超阈值 → 发一条**有界去重**的对账/恢复请求（作废旧路让下一轮重规划），
#      并把结论落进审计账。**绝不**因为"连着几次没动"就宣告失败、死亡或释放单位。

#: 游戏时钟到秒的换算（`Countdown`/物理 tick 口径：60Hz）。游戏时钟是权威，
#: 墙钟只是旁证；两者都记，避免用 tick 猜秒数时把"暂停/变速"算错。
GAME_TICKS_PER_SECOND = 60.0
#: 无理由停住多久需要**诊断记录**（秒，prompt §4 的公开工程目标）。
CONTINUITY_DIAGNOSE_SECONDS = 2.0
#: 无理由停住多久必须有**对账/恢复记录**（秒）。
CONTINUITY_RECOVER_SECONDS = 5.0
#: 无理由停住多久判**失败**（秒）。本层只把它记成 `unexplained_fail` 供验收统计，
#: 不做任何释放/判死动作（"未知仍未知"）。
CONTINUITY_FAIL_SECONDS = 10.0
#: 同一单位同一目标的恢复请求**重复下发**的最小间隔（tick）——有界去重的唯一实现。
CONTINUITY_RECOVERY_REPEAT_TICKS = 300
#: 训练账的有界长度（防状态无限增长）。
CONTINUITY_RECORD_LIMIT = 64
#: 该单位位置变化超过它才算"真的动了"（米）——与 `PROGRESS_EPSILON_M` 同量级的移动口径。
CONTINUITY_MOVED_EPSILON_M = 0.5


def _ticks_to_seconds(ticks: float) -> float:
    return round(float(ticks) / float(GAME_TICKS_PER_SECOND), 2)


def _eligible_units(state: Dict[str, Any], facts: Dict[str, Any]) -> List[str]:
    """参加连续行动监督的单位：**AI 授权** + 会动 + 在观测里。

    玩家接管的单位**仍进名单**（它要有一条 `player_control` 的等待理由记录，
    供验收读"玩家接管后副官没有继续追责"），但**不会**被判停滞、更不会被下发恢复动作
    —— 那是 prompt §3-C「不得抢玩家接管单位」的实现处。
    """
    out: List[str] = []
    for name in (state.get("ai_controlled_units") or []):
        unit = str(name)
        info = facts["own"].get(unit)
        if not info or not info.get("movement"):
            continue
        if _xz_plane(info.get("pos")) is None:
            continue
        out.append(unit)
    return out


def supervise_continuity(state: Dict[str, Any], *, observation: Optional[Dict[str, Any]],
                         tick: int, facts: Optional[Dict[str, Any]] = None,
                         config: Optional[Dict[str, Any]] = None
                         ) -> Dict[str, Any]:
    """连续行动监督：给每个 AI 单位的停滞/闲置**留痕**，超阈值时发有界对账/恢复。

    返回本轮监督报告（同时写进 `state["continuity_supervision"]`，有界）。

    职责边界（与 `track_task_progress` 的分工）：
    - `track_task_progress` 判"任务相对目标有没有进展"；
    - 本函数判"**单位有没有在动**、停了多久、有没有理由"，并对"没理由"的那种追责。

    反过来说：**不会**在这里改任务状态、**不会**释放单位、**不会**发新意图。
    它只推 `task_stalled` 事件 + 作废旧路（让下一轮正常重规划）+ 记审计账。
    """
    config = config or {}
    diagnose_s = float(config.get("continuity_diagnose_seconds",
                                  CONTINUITY_DIAGNOSE_SECONDS))
    recover_s = float(config.get("continuity_recover_seconds", CONTINUITY_RECOVER_SECONDS))
    fail_s = float(config.get("continuity_fail_seconds", CONTINUITY_FAIL_SECONDS))
    repeat_ticks = int(config.get("continuity_recovery_repeat_ticks",
                                  CONTINUITY_RECOVERY_REPEAT_TICKS))
    tick = int(tick)
    facts = facts if facts is not None else index_observation(observation)
    ledger: Dict[str, Dict[str, Any]] = state.setdefault("continuity_units", {})

    # 每个 AI 单位当前"到底在干什么"：活意图 → 阶段/目标/游标；没意图 → idle。
    live_intents: Dict[str, Dict[str, Any]] = {}
    for intent in state.get("active_intents") or []:
        if not isinstance(intent, dict) or intent.get("state") not in INTENT_LIVE_STATES:
            continue
        for unit in _units_of(intent):
            live_intents.setdefault(str(unit), intent)

    events: List[Dict[str, Any]] = []
    rows: Dict[str, Dict[str, Any]] = {}
    eligible = _eligible_units(state, facts)
    for unit in eligible:
        info = facts["own"].get(unit) or {}
        position = _xz_plane(info.get("pos"))
        if position is None:
            continue
        record = ledger.get(unit) or {}
        intent = live_intents.get(unit)
        previous_position = record.get("last_position")
        moved = (previous_position is None
                 or _flat_distance(position, previous_position)
                 > CONTINUITY_MOVED_EPSILON_M)
        progress = (intent or {}).get("progress") or {}
        metrics = progress.get("metrics") or {}
        # 【进展的共同判据】位移、路径阶段、攻击/采集/生产事实**一起**看：
        # 只看"离目标更近"会把正常绕路判成停滞（prompt §3-C 明令）。这里的口径：
        #   ① 这一轮位移 > 阈值；或
        #   ② 停滞计数比上一轮**下降**（说明某个模型判定了进展）；或
        #   ③ 状态刚变成 in_progress（同上）；或
        #   ④ 攻击/采集类事实指标真的变了（血量、载量、完成工作量）。
        # 没有这些信号才叫"没动"。
        stall_count = int(metrics.get("stall_count", 0) or 0)
        previous_stall = record.get("stall_count")
        progressed_fact = False
        for key in ("carried_total", "completed_work", "hp", "target_hp", "product_count"):
            if key in metrics and record.get("fact_" + key) not in (None, metrics[key]):
                progressed_fact = True
            if key in metrics:
                record["fact_" + key] = metrics[key]
        advancing = (bool(moved) or progressed_fact
                     or (previous_stall is not None and stall_count < previous_stall)
                     or (record.get("phase") not in (None, "in_progress")
                         and str(progress.get("status", "")) == "in_progress"))
        if advancing:
            record["last_moved_tick"] = tick
            record["last_moved_wall"] = time.monotonic()
        if moved:
            # 只在**真的动了**时更新基准位置：否则阈值内的抖动会把基准拖着走，
            # 让"缓慢挪动"看起来一直有位移。
            record["last_position"] = [float(position[0]), float(position[1])]
        record.setdefault("last_moved_tick", tick)
        record.setdefault("last_moved_wall", time.monotonic())
        stop_seconds = _ticks_to_seconds(max(0, tick - int(record["last_moved_tick"])))
        stop_wall_seconds = round(time.monotonic() - float(record["last_moved_wall"]), 2)
        record.update({
            "tick": tick,
            "intent_id": str((intent or {}).get("intent_id", "")),
            "phase": str(progress.get("status", "idle" if intent is None else "")),
            "target": list(((intent or {}).get("target") or {}).get("pos") or []),
            "route_relay": list(((state.get("routes") or {}).get(unit) or {})
                                .get("relay_point") or []),
            "stop_reason": str((progress.get("metrics") or {}).get("detail", "")
                               or progress.get("detail", "")),
            "stall_count": stall_count,
            "stop_seconds": stop_seconds,
            "stop_wall_seconds": stop_wall_seconds,
            "moved_this_round": bool(moved),
        })
        # ---- 依据：没有依据的停住才算"无理由" ----
        waiting_reason = ""
        if unit in {str(name) for name in (state.get("player_units") or [])}:
            waiting_reason = "player_control"
        elif intent is None:
            waiting_reason = ""            # 没任务也没在动 = 正是要监督的闲置
        elif str((intent.get("action") or "")) not in MOVEMENT_ACTIONS:
            waiting_reason = "task_%s" % str(intent.get("action", "unknown"))
        elif "arrive" in str(progress.get("detail", "")):
            waiting_reason = "arrived"
        if waiting_reason:
            record["waiting_reason"] = waiting_reason
            record["next_reconcile_tick"] = tick
        else:
            record["waiting_reason"] = record.get("waiting_reason", "")

        level = ""
        action = ""
        if not waiting_reason:
            if stop_seconds >= fail_s:
                level = "unexplained_fail"
            elif stop_seconds >= recover_s:
                level = "recover"
            elif stop_seconds >= diagnose_s:
                level = "diagnose"
            if level in ("recover", "unexplained_fail"):
                last_request = int(record.get("last_recovery_tick", -10 ** 9))
                if tick - last_request >= repeat_ticks:
                    record["last_recovery_tick"] = tick
                    record["recovery_count"] = int(record.get("recovery_count", 0)) + 1
                    if level == "recover":
                        # 【恢复动作】只作废**旧路缓存**：下一轮规则地板会照常重规划，
                        # 不重发、不抢权、不改任务状态。对"已经到达/在路上"的单位，
                        # `note_arrival`/`hop_in_progress` 的正常语义不受影响。
                        from . import movement as movement_mod
                        movement_mod.invalidate_route(
                            state, unit, reason="continuity_stall")
                        action = "invalidate_route"
                    else:
                        action = "report_unexplained"
                    events.append({
                        "event_id": "continuity-%s-%s-%d" % (level, unit, tick),
                        "kind": "task_stalled",
                        "match_id": str(state.get("match_id", "")),
                        "player_id": str(state.get("player_id", "")),
                        "server_tick": tick,
                        "payload": {"subject": unit, "level": level,
                                    "stop_seconds": stop_seconds,
                                    "stall_count": stall_count,
                                    "intent_id": str((intent or {}).get("intent_id", "")),
                                    "source": "continuity_supervisor"},
                    })
        record["level"] = level
        record["action"] = action
        ledger[unit] = record
        rows[unit] = {key: record[key] for key in
                      ("phase", "stop_seconds", "stop_wall_seconds", "waiting_reason",
                       "level", "action", "stall_count", "intent_id")}

    # 有界：只保留**当前** AI 授权单位，且单元记录数有上限。
    for stale in [name for name in ledger if name not in set(eligible)]:
        ledger.pop(stale, None)
    while len(ledger) > CONTINUITY_RECORD_LIMIT:
        ledger.pop(next(iter(ledger)))

    counts: Dict[str, int] = {}
    for row in rows.values():
        if row["level"]:
            counts[row["level"]] = counts.get(row["level"], 0) + 1
    idle_units = [name for name, row in rows.items() if not row["intent_id"]]
    report = {
        "updated_tick": tick,
        "ticks_per_second": GAME_TICKS_PER_SECOND,
        "thresholds": {"diagnose_s": diagnose_s, "recover_s": recover_s, "fail_s": fail_s},
        "units": rows,
        "idle_units": sorted(idle_units),
        "levels": counts,
        "events": len(events),
        "recoveries": sum(1 for item in rows.values() if item["action"] == "invalidate_route"),
        "truncated": bool(facts.get("truncated")),
    }
    state["continuity_supervision"] = report
    if events:
        pending = state.setdefault("pending_events", [])
        pending.extend(events)
        if len(pending) > CONTINUITY_RECORD_LIMIT * 4:
            del pending[:-CONTINUITY_RECORD_LIMIT * 4]
    return report


def _xz_plane(pos: Any) -> Optional[Tuple[float, float]]:
    """观测坐标 → 平面 (x, z)。

    权威实体是 `[x, y, z]`；规则层航点（`military_waypoint` / 侦察前沿）是 `[x, z]`。
    只认 3D 会让 `pos=[17.5, 17.5]` 的侦察令永远算不出距离 → 意图活到 TTL，
    无人机到了第一格也拿不到下一跳（`u1t01d` / `archive_2325cc87`）。
    """
    if not isinstance(pos, (list, tuple)) or len(pos) < 2:
        return None
    try:
        if len(pos) >= 3:
            return float(pos[0]), float(pos[2])
        return float(pos[0]), float(pos[1])
    except (TypeError, ValueError, IndexError):
        return None


def _flat_distance(pos_a: Any, pos_b: Any) -> Optional[float]:
    """只取 [x, z] 平面距离（Godot 里 y 是高度，地形起伏不该算进"走到了没"）。"""
    left = _xz_plane(pos_a)
    right = _xz_plane(pos_b)
    if left is None or right is None:
        return None
    return ((left[0] - right[0]) ** 2 + (left[1] - right[1]) ** 2) ** 0.5


def _carried_total(entity: Dict[str, Any]) -> int:
    carried = entity.get("carried") or [0, 0]
    try:
        return int(carried[0]) + int(carried[1])
    except (TypeError, ValueError, IndexError):
        return 0


def index_observation(observation: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    """把观测整理成按名字索引的事实表（缺失即空表，不伪造）。"""
    tactical = (observation or {}).get("tactical")
    strategic = (observation or {}).get("strategic")
    own: Dict[str, Dict[str, Any]] = {}
    resources: Dict[str, Dict[str, Any]] = {}
    enemies: Dict[str, Dict[str, Any]] = {}
    production: Dict[str, Dict[str, Any]] = {}
    truncated = None
    if isinstance(tactical, dict):
        truncated = tactical.get("truncated")
        for entity in tactical.get("entities") or []:
            if not isinstance(entity, dict):
                continue
            kind = str(entity.get("kind", ""))
            name = str(entity.get("name", ""))
            if not name:
                continue
            if kind == "unit_self":
                own[name] = entity
            elif kind == "resource":
                resources[name] = entity
            elif kind.startswith("unit_enemy"):
                enemies[name] = entity
        for view in tactical.get("production") or []:
            if isinstance(view, dict) and view.get("producer"):
                production[str(view["producer"])] = view
    # 敌情：即使当前不可见，strategic.enemy_intel 仍带 last_seen 与 confirmed_dead，
    # 这是判断"打死了没有 / 失去视野"的合法来源（不做全局视野泄露）。
    intel: Dict[str, Dict[str, Any]] = {}
    if isinstance(strategic, dict):
        for item in strategic.get("enemy_intel") or []:
            if isinstance(item, dict) and item.get("name"):
                intel[str(item["name"])] = item
    return {"own": own, "resources": resources, "enemies": enemies,
            "production": production, "intel": intel, "truncated": truncated}


def production_events_facts(state: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    """生产台账（按 **item_id** 索引）：`{item_id: {producer, product_id, started_tick,
    finished_tick, produced_unit}}`。

    为什么必须要它：队列是"当前状态"，队列项一消失就什么都不剩 —— 而"这一项到底完成了没有"
    只能靠**事件**回答（`production_finished` 带 item_id）。台账由回执与快速事件共同维护，
    结算时按 item_id 查，不靠猜。
    """
    ledger = (state or {}).get("production_ledger")
    return dict(ledger) if isinstance(ledger, dict) else {}


def _units_of(intent: Dict[str, Any]) -> List[str]:
    return [str(u) for u in intent.get("unit_ids") or []]


def _progress_of(intent: Dict[str, Any]) -> Dict[str, Any]:
    record = intent.get("progress")
    if not isinstance(record, dict):
        record = {"units": {}, "metrics": {}, "stall_count": 0}
        intent["progress"] = record
    record.setdefault("units", {})
    metrics = record.get("metrics")
    if not isinstance(metrics, dict):
        record["metrics"] = {}
    record.setdefault("stall_count", 0)
    return record


def _movement_progress(intent, facts, tick, params):
    arrive_radius = params["arrive_radius"]
    stall_limit = params["stall_limit"]
    record = _progress_of(intent)
    target_pos = (intent.get("target") or {}).get("pos")
    if not target_pos:
        return "failed", "缺少目标坐标", {"reason": "missing_target_pos"}
    distances: Dict[str, float] = {}
    lost: List[str] = []
    for unit_name in _units_of(intent):
        entity = facts["own"].get(unit_name)
        if entity is None:
            lost.append(unit_name)
            continue
        distance = _flat_distance(entity.get("pos"), target_pos)
        if distance is None:
            continue
        distances[unit_name] = distance
        record["units"].setdefault(unit_name, {})["last_distance"] = distance
        record["units"][unit_name]["last_tick"] = tick
    if lost and len(lost) == len(_units_of(intent)):
        # 全部单位暂时不在观测里（迷雾/截断）→ **unknown**，不判失败也不释放单位。
        # 【2026-09-12 实测】从前判 failed → 单位被释放 → 微操层重发同一条命令（正反馈）。
        return "unknown", "全部单位暂不在观测中（迷雾，不判失败）", {"lost_units": lost}
    if not distances:
        return "in_progress", "等待单位位置数据", {}
    if all(distance <= arrive_radius for distance in distances.values()):
        return "completed", "已到达目标位置（%.1fm 内）" % arrive_radius, {
            "distances": {k: round(v, 2) for k, v in distances.items()}}
    improved = False
    for unit_name, distance in distances.items():
        previous = record["units"].get(unit_name, {}).get("previous_distance")
        if previous is not None and distance < previous - PROGRESS_EPSILON_M:
            improved = True
        record["units"].setdefault(unit_name, {})["previous_distance"] = distance
    if improved:
        record["stall_count"] = 0
    else:
        record["stall_count"] = int(record.get("stall_count", 0)) + 1
    metrics = {"distances": {k: round(v, 2) for k, v in distances.items()},
               "stall_count": record["stall_count"], "lost_units": lost}
    if record["stall_count"] >= stall_limit:
        # 连续无接近进展 → **unknown**（不判失败）。理由：单位可能在绕路/被地形卡、
        # 或观测间隔抖动；把它判失败会释放单位并触发微操重发（实测 47/50 条意图被标 failed、
        # `Unit_3|gather` 重发 22 次）。计划要求"任务失败只能来自权威回执"。
        return "unknown", ("连续 %d 次观测无接近进展（不判失败，等权威回执）"
                           % record["stall_count"]), metrics
    return "in_progress", "向目标推进中", metrics


def _attack_progress(intent, facts, tick, params):
    stall_limit = params["stall_limit"]
    record = _progress_of(intent)
    target_id = str((intent.get("target") or {}).get("entity_id", ""))
    if not target_id:
        return "failed", "缺少攻击目标", {"reason": "missing_target"}
    living_units = [u for u in _units_of(intent) if u in facts["own"]]
    if not living_units:
        return "unknown", "攻击单位暂不在观测中（不判失败）", {"lost_units": _units_of(intent)}
    enemy = facts["enemies"].get(target_id)
    intel = facts["intel"].get(target_id) or {}
    if bool(intel.get("confirmed_dead")) or (enemy and enemy.get("confirmed_dead")):
        return "completed", "目标已确认死亡", {"target": target_id}
    if enemy is None:
        # 目标不可见要分三档，不能一见不到就判中断/失败：
        #   ① 刚看不见（<= grace）      → in_progress（视野抖动，等它回来）
        #   ② 持续不可见（<= 4×grace）  → interrupted（可恢复，HUD 要显示"失去视野"）
        #   ③ 长时间不可见（> 4×grace） → failed（目标很可能已不在该区域）
        lost_sight = params.get("lost_sight_ticks", LOST_SIGHT_TICKS)
        last_seen = int(intel.get("last_seen_tick", 0) or 0)
        metrics = {"target": target_id, "last_seen_tick": last_seen}
        if not last_seen:
            return "in_progress", "等待目标出现", metrics
        age = tick - last_seen
        metrics["sight_age_ticks"] = age
        if age <= lost_sight:
            return "in_progress", "目标暂时不可见（%d tick）" % age, metrics
        if age <= 4 * lost_sight:
            return "interrupted", "目标脱离视野（最后可见 tick=%d）" % last_seen, metrics
        # 目标长时间不可见 → unknown（迷雾不等于目标已死；判失败会误放单位并触发重发）。
        return "unknown", "目标长时间不可见（%d tick），保持未知" % age, metrics
    hp = float(enemy.get("hp", 0) or 0)
    previous_hp = record["metrics"].get("target_hp")
    record["metrics"]["target_hp"] = hp
    own_hp = {name: float(facts["own"][name].get("hp", 0) or 0) for name in living_units}
    record["metrics"]["own_hp"] = own_hp
    metrics = {"target": target_id, "target_hp": hp,
               "target_hp_max": float(enemy.get("hp_max", 0) or 0), "own_hp": own_hp}
    if previous_hp is not None and hp < previous_hp:
        record["stall_count"] = 0
        return "in_progress", "已造成伤害（目标 %.0f→%.0f）" % (previous_hp, hp), metrics
    record["stall_count"] = int(record.get("stall_count", 0)) + 1
    metrics["stall_count"] = record["stall_count"]
    if record["stall_count"] >= stall_limit and previous_hp is not None:
        return "unknown", ("连续 %d 次观测目标未受创（保持未知，等权威回执）"
                           % record["stall_count"]), metrics
    return "in_progress", "交战中", metrics


def _gather_progress(intent, facts, tick, params):
    stall_limit = params["stall_limit"]
    record = _progress_of(intent)
    resource_id = str((intent.get("target") or {}).get("entity_id", ""))
    units = _units_of(intent)
    living = [u for u in units if u in facts["own"]]
    if not living:
        return "unknown", "采集单位暂不在观测中（不判失败）", {"lost_units": units}
    carried = {name: _carried_total(facts["own"][name]) for name in living}
    previous = record["metrics"].get("carried") or {}
    record["metrics"]["carried"] = carried
    increased = any(carried.get(name, 0) > int(previous.get(name, 0) or 0) for name in living)
    metrics = {"carried": carried, "resource": resource_id}
    resource = facts["resources"].get(resource_id) if resource_id else None
    if resource_id and facts["truncated"] is False:
        from .observation_view import resource_available
        gone = resource_id not in facts["resources"]
        empty = bool(resource) and not resource_available(resource)
        if gone or empty:
            # 资源点从完整观测消失，或存量已报 0 = 已耗尽；截断观测下不判定。
            return "completed", "资源点 %s 已耗尽，工人转岗" % resource_id, metrics
    if increased:
        record["stall_count"] = 0
        return "in_progress", "正在装载资源（载量 %s）" % carried, metrics
    record["stall_count"] = int(record.get("stall_count", 0)) + 1
    metrics["stall_count"] = record["stall_count"]
    if record["stall_count"] >= stall_limit:
        # 载量没变可能只是"正在走过去/在排队"——保持未知，不释放单位（否则微操重发）。
        return "unknown", ("连续 %d 次观测载量无变化（保持未知）"
                           % record["stall_count"]), metrics
    return "in_progress", "采集中", metrics


def product_ids_of(intent: Dict[str, Any]) -> List[str]:
    """这条生产意图的**产品身份候选**（权威优先）。

    为什么需要多个候选（2026-09-13 归档复盘的根因）：
    `target.scene` 是 `res://source/match/units/Infantry.tscn`，而队列项与实体的
    `definition_id`/`unit_type` 都是 **`soldier`** —— 场景名与产品 ID **不是同一套命名**
    （`Barracks.tscn`→`barracks` 恰好同名，`Infantry.tscn`→`soldier` 不同名），
    所以"拿 scene 直接比 definition_id"必然判不出，任务永远停在 `active_unknown`。

    权威来源是**生产回执**：`receipt.result.item.definition_id`（下单时就返回），
    存在 `intent["production"]["product_id"]`；scene 名只作兜底。
    """
    out: List[str] = []
    production = intent.get("production") if isinstance(intent.get("production"), dict) else {}
    for value in (production.get("product_id"),):
        if value and str(value) not in out:
            out.append(str(value))
    scene = str((intent.get("target") or {}).get("scene", ""))
    if scene:
        base = scene.rsplit("/", 1)[-1].split(".")[0].lower()
        if base and base not in out:
            out.append(base)
    return out


def _produce_progress(intent, facts, tick, params):
    record = _progress_of(intent)
    target = intent.get("target") or {}
    producer = str(target.get("producer", ""))
    product_ids = product_ids_of(intent)
    if not producer or not product_ids:
        return "failed", "生产意图缺少 producer/scene", {"reason": "missing_producer_or_product"}
    if producer not in facts["own"]:
        return "unknown", "生产者暂不在观测中（不判失败）", {"producer": producer}
    production = intent.get("production") if isinstance(intent.get("production"), dict) else {}
    item_id = str(production.get("item_id", ""))
    ledger = (facts.get("production_events") or {}).get(item_id) or {}
    view = facts["production"].get(producer) or {}
    items = [item for item in (view.get("items") or [])
             if (item_id and str(item.get("item_id", "")) == item_id)
             or str(item.get("definition_id", "")) in product_ids]
    # 产物数量必须在**每一轮**都记录，否则队列项消失时才建立基线 → 永远比不出"新增单位"。
    has_baseline = "product_count" in record["metrics"]
    baseline = int(record["metrics"].get("product_count") or 0)
    current = sum(1 for entity in facts["own"].values()
                  if str(entity.get("unit_type", "")) in product_ids)
    record["metrics"]["product_count"] = current
    metrics = {"producer": producer, "product": product_ids[0],
               "product_ids": product_ids, "item_id": item_id or None,
               "queue_size": int(view.get("queue_size", 0) or 0),
               "product_count": current, "product_count_before": baseline}
    # ① 【权威完成证据】生产完成事件（同一 item_id）→ 直接结算。
    #    这条是本次修复的核心：以前只看"队列里还在不在 + 产物数量差"，两者都会被命名错配毁掉。
    if ledger.get("finished_tick"):
        metrics["confirmed_by"] = "production_finished@%s" % ledger["finished_tick"]
        return "completed", ("权威完成事件：%s（item %s，tick %s）"
                             % (product_ids[0], item_id[:8], ledger["finished_tick"])), metrics
    if items:
        item = items[0]
        required = int(item.get("required_work", 0) or 0)
        done = int(item.get("completed_work", 0) or 0)
        ratio = (float(done) / float(required)) if required > 0 else None
        metrics.update({"item_state": str(item.get("state", "")),
                        "completed_work": done, "required_work": required,
                        "ratio": None if ratio is None else round(ratio, 3)})
        return "in_progress", "队列中生产中（%s %d/%d）" % (
            item.get("state", ""), done, required), metrics
    if has_baseline and current > baseline:
        return "completed", "产物已部署（%s 数量 %d→%d）" % (product_ids[0], baseline, current), metrics
    # 关键（方案 §4）：项目从队列消失**不能**一律当作生产成功。
    if view:
        # 队列项消失但**没有完成事件**、也没看到新单位：保持未知（可能是还没走出来/名字不在视野），
        # 并且记下"该去对账什么"（item_id + 生产者），下一轮继续查。
        metrics.update({"recheck": {"producer": producer, "item_id": item_id or None,
                                    "why": "queue_item_vanished_without_finish_event"}})
        return "unknown", "队列项已消失但未观察到新单位/完成事件（保持未知，继续对账）", metrics
    return "in_progress", "等待队列信息", metrics


def building_type_of(intent, facts=None) -> str:
    """这条建造意图的**建筑类型 ID**（权威优先）。

    同一个坑（2026-09-13 修复）：`target.scene` = `…/AircraftFactory.tscn`，而实体的
    `unit_type` = `aircraft_factory` —— 场景名去掉扩展名后**不等于**类型 ID
    （蛇形命名 vs 驼峰命名），拿 scene 直接比 `unit_type` 会永远判不出"已建成"。
    权威来源有两个（按可靠性排序）：
    ① 意图目标里的工地实体（`target.entity_id`/`site`）在观测里的 `unit_type`；
    ② 意图上已记录的 `building_type`（由回执/工地实体回填）。
    scene 名只作最后兜底。
    """
    target = intent.get("target") if isinstance(intent.get("target"), dict) else {}
    # 【不许看 `producer`】它是**建造者**（工人），不是工地 —— 拿它取类型会得出 "worker"，
    # 于是"工地已建成"永远判不出来（实测：改完这个 key 立刻挂了两条既有测试）。
    for key in ("entity_id", "site", "building"):
        name = str(target.get(key, ""))
        if not name or not facts:
            continue
        entity = (facts.get("own") or {}).get(name)
        if isinstance(entity, dict) and entity.get("unit_type"):
            return str(entity["unit_type"])
    recorded = str(intent.get("building_type", ""))
    if recorded:
        return recorded
    scene = str(target.get("scene", ""))
    return scene.rsplit("/", 1)[-1].split(".")[0].lower() if scene else ""


def _build_progress(intent, facts, tick, params):
    stall_limit = params["stall_limit"]
    record = _progress_of(intent)
    target = intent.get("target") or {}
    builder = str(target.get("producer", ""))
    building = building_type_of(intent, facts)
    if not building:
        return "failed", "建造意图缺少 scene", {"reason": "missing_scene"}
    if builder and builder not in facts["own"]:
        return "unknown", "建造单位暂不在观测中（不判失败）", {"builder": builder}
    structured = [entity for entity in facts["own"].values()
                  if str(entity.get("unit_type", "")) == building]
    metrics = {"building": building, "builder": builder, "instances": len(structured)}
    if not structured:
        record["stall_count"] = int(record.get("stall_count", 0)) + 1
        metrics["stall_count"] = record["stall_count"]
        if record["stall_count"] >= stall_limit:
            return "unknown", ("连续 %d 次观测未出现施工对象（保持未知）"
                               % record["stall_count"]), metrics
        return "in_progress", "已下单，等待工地出现", metrics
    if all(bool(entity.get("constructed", False)) for entity in structured):
        return "completed", "建筑已完成（%s）" % building, metrics
    metrics["constructed"] = [bool(e.get("constructed", False)) for e in structured]
    return "in_progress", "施工中（%s）" % building, metrics


HANDLERS = {
    "move": _movement_progress, "attack_move": _movement_progress,
    "scout": _movement_progress, "defend": _movement_progress,
    "regroup": _movement_progress, "retreat": _movement_progress,
    "attack": _attack_progress, "gather": _gather_progress,
    "produce": _produce_progress, "build": _build_progress,
}

#: 进度结论 → 意图状态（in_progress / interrupted 都**不改**意图状态）。
#: interrupted 刻意保留意图存活：失去视野是可恢复的，若写死状态就再也不会恢复。
#:
#: 【2026-09-12 实机实测修正】`unknown`（连续无进展 / 单位或目标脱离视野）**不判失败**，
#: 而是记 `active_unknown`（仍在 `INTENT_LIVE_STATES` 里 → 仍占用单位）。
#: 旧行为把它判 failed → 单位被释放 → 微操层下一轮重发同一条命令
#: （实测同局 `Unit_3|gather` 22 次、`Unit_5|gather` 21 次，47/50 条意图被标 failed）。
#: 计划明确禁止"用观测时序/超时推断单位或任务状态"：任务失败只能来自权威回执。
_STATUS_TO_INTENT = {
    "completed": INTENT_COMPLETED, "failed": INTENT_FAILED,
    "unknown": INTENT_ACTIVE_UNKNOWN,
}
#: 进度结论 → 任务状态。
_STATUS_TO_TASK = {
    "completed": TASK_COMPLETED, "failed": TASK_FAILED, "interrupted": TASK_INTERRUPTED,
    # 未知 ≠ 失败：任务状态保持未知，等权威回执/复核结论（不自造失败）。
    "unknown": TASK_UNKNOWN,
}


def track_task_progress(state: Dict[str, Any], *, observation: Optional[Dict[str, Any]],
                        tick: int, config: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """按观测差分推进每个活跃意图/任务的真实状态；返回本轮快照（供 HUD 与日志）。

    只对 `INTENT_LIVE_STATES`（active / pending_authority）的意图做判定：
    interrupt 是可恢复的，因此**不写死**意图状态，只在下一次观测里继续判定
    （避免"看不见一次就永久判定失败"）。
    """
    config = config or {}
    arrive_radius = float(config.get("progress_arrive_radius", ARRIVE_RADIUS_M))
    stall_limit = int(config.get("progress_stall_limit", STALL_LIMIT))
    facts = index_observation(observation)
    # 生产台账（item_id → 完成事件）挂进 facts：`_produce_progress` 按它做权威结算。
    facts["production_events"] = production_events_facts(state)
    tick = int(tick)
    params = {"arrive_radius": arrive_radius, "stall_limit": stall_limit,
              "lost_sight_ticks": int(config.get("progress_lost_sight_ticks",
                                                 LOST_SIGHT_TICKS))}

    per_intent: Dict[str, Dict[str, Any]] = {}
    for intent in state.get("active_intents") or []:
        if not isinstance(intent, dict):
            continue
        if intent.get("state") not in INTENT_LIVE_STATES:
            continue
        intent_id = str(intent.get("intent_id", ""))
        action = str(intent.get("action", ""))
        handler = HANDLERS.get(action)
        if handler is None:
            per_intent[intent_id] = {
                "intent_id": intent_id, "action": action,
                "task_id": str(intent.get("task_id", "")),
                "status": "in_progress", "detail": "该动作暂无观测级进度模型",
                "unit_ids": _units_of(intent), "metrics": {}, "updated_tick": tick}
            continue
        status, detail, metrics = handler(intent, facts, tick, params)
        record = _progress_of(intent)
        record["status"] = status
        record["detail"] = detail
        record["updated_tick"] = tick
        record["metrics"] = {**record.get("metrics", {}), **metrics}
        if status in _STATUS_TO_INTENT:
            intent["state"] = _STATUS_TO_INTENT[status]
            intent["drop_reason"] = "progress_%s" % status
        if status == "completed" and action in MOVEMENT_ACTIONS:
            # 观测已确认走到目标：作废当前跳，下一轮才能规划下一跳。
            # 游戏侧 arrival 事件会走同一条 `note_arrival`；无事件的模拟局/延迟回执
            # 不能把单位锁在 hop_in_progress 里直到 HOP_HOLD_MAX_TICKS。
            from . import movement as movement_mod
            for unit_name in _units_of(intent):
                movement_mod.note_arrival(state, unit_name, tick)
        per_intent[intent_id] = {
            "intent_id": intent_id, "action": action,
            "task_id": str(intent.get("task_id", "")), "status": status,
            "detail": detail, "unit_ids": _units_of(intent),
            "metrics": metrics, "updated_tick": tick}

    per_task = _aggregate_tasks(state, tick)
    report = {"updated_tick": tick, "intents": per_intent, "tasks": per_task,
              "truncated": facts.get("truncated")}
    state["task_progress"] = report
    return report


def _aggregate_tasks(state: Dict[str, Any], tick: int) -> Dict[str, Any]:
    """把意图级结论汇总到任务：**只要还有活跃意图就保持 running**，不提前闭环。"""
    buckets: Dict[str, Dict[str, Any]] = {}
    for intent in state.get("active_intents") or []:
        if not isinstance(intent, dict):
            continue
        task_id = str(intent.get("task_id", ""))
        if not task_id:
            continue
        bucket = buckets.setdefault(task_id, {"live": [], "closed": []})
        if intent.get("state") in INTENT_LIVE_STATES:
            bucket["live"].append(intent)
        else:
            progress = intent.get("progress") or {}
            bucket["closed"].append(str(progress.get("status", ""))
                                    or str(intent.get("state", "")))

    active_tasks = state.setdefault("active_tasks", {})
    summary: Dict[str, Any] = {}
    for task_id, bucket in buckets.items():
        live = bucket["live"]
        if live:
            new_state = TASK_RUNNING
            detail = "%d 条意图进行中" % len(live)
        else:
            closed = bucket["closed"]
            if closed and all(item == "completed" for item in closed):
                new_state = TASK_COMPLETED
                detail = "全部意图已完成"
            elif any(item == "failed" for item in closed):
                new_state = TASK_FAILED
                detail = "存在失败意图"
            elif any(item == "interrupted" for item in closed):
                new_state = TASK_INTERRUPTED
                detail = "意图中断（可恢复）"
            else:
                new_state = TASK_UNKNOWN
                detail = "意图已闭环但结果未知"
        previous = active_tasks.get(task_id)
        active_tasks[task_id] = new_state
        summary[task_id] = {"state": new_state, "detail": detail,
                            "live_intents": [str(i.get("intent_id", "")) for i in live],
                            "previous_state": previous, "updated_tick": tick}
    return summary
