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

from typing import Any, Dict, List, Optional

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


def _flat_distance(pos_a: Any, pos_b: Any) -> Optional[float]:
    """只取 [x, z] 平面距离（Godot 里 y 是高度，地形起伏不该算进"走到了没"）。"""
    try:
        ax, az = float(pos_a[0]), float(pos_a[2])
        bx, bz = float(pos_b[0]), float(pos_b[2])
    except (TypeError, ValueError, IndexError):
        return None
    return ((ax - bx) ** 2 + (az - bz) ** 2) ** 0.5


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
    if resource_id and resource_id not in facts["resources"] and facts["truncated"] is False:
        # 资源点从**完整**观测里消失 = 已耗尽；截断观测下不判定（缺席不等于消失）。
        return "completed", "资源点 %s 已不在观测中（判定耗尽）" % resource_id, metrics
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


def _produce_progress(intent, facts, tick, params):
    record = _progress_of(intent)
    target = intent.get("target") or {}
    producer = str(target.get("producer", ""))
    product = str(target.get("scene", ""))
    if not producer or not product:
        return "failed", "生产意图缺少 producer/scene", {"reason": "missing_producer_or_product"}
    if producer not in facts["own"]:
        return "unknown", "生产者暂不在观测中（不判失败）", {"producer": producer}
    view = facts["production"].get(producer) or {}
    items = [item for item in (view.get("items") or [])
             if str(item.get("definition_id", "")) == product]
    # 产物数量必须在**每一轮**都记录，否则队列项消失时才建立基线 → 永远比不出"新增单位"。
    has_baseline = "product_count" in record["metrics"]
    baseline = int(record["metrics"].get("product_count") or 0)
    current = sum(1 for entity in facts["own"].values()
                  if str(entity.get("unit_type", "")) == product)
    record["metrics"]["product_count"] = current
    metrics = {"producer": producer, "product": product,
               "queue_size": int(view.get("queue_size", 0) or 0),
               "product_count": current, "product_count_before": baseline}
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
        return "completed", "产物已部署（%s 数量 %d→%d）" % (product, baseline, current), metrics
    # 关键（方案 §4）：项目从队列消失**不能**一律当作生产成功。
    if view:
        # 队列项消失但没看到新单位：**不判成功也不判失败**（可能是还没走出来/名字不在视野）。
        # 【2026-09-12 实测】从前判 failed → 生产任务被判失败 → 微操层重发生产（produce 152 次）。
        return "unknown", "队列项已消失但未观察到新单位（保持未知）", metrics
    return "in_progress", "等待队列信息", metrics


def _build_progress(intent, facts, tick, params):
    stall_limit = params["stall_limit"]
    record = _progress_of(intent)
    target = intent.get("target") or {}
    builder = str(target.get("producer", ""))
    building = str(target.get("scene", ""))
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
