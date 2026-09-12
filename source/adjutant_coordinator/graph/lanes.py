# -*- coding: utf-8 -*-
"""五条独立线路：分类、轮转排序、下线账与饿死保护（计划 §5）。

## 计划要求（原文）

「协调器建立以下独立队列和统计：economy / build / scout / military / urgent」
「每条线路维护当前任务、下次到期、重试退避、最后处理 tick 和饿死时间」
「紧急线可抢占当前提交，但要有**老化上限和轮转**，不能永久饿死经济、建造或侦察」

## 改造前的事实（为什么必须有这个模块）

意图此前是"每轮重算的候选集 + 一次**全局排序**（priority 降序 → issued_tick → id）"。
后果有两个，都在真机见过：

1. 数量多的线路会把配额整批吃掉：建造/交战意图一多，低优先级线路（采集、侦察）
   在 `max_batch` 截断处**整条消失**，且日志只写 `batch_limit_exceeded`，看不出是哪条线被饿死；
2. 没有任何"哪条线多久没被服务"的账 → 饿了也发现不了。

本模块把"线路"变成一等公民：分类（唯一口径）+ **轮转排序**（紧急线每轮先出，
但每轮都要走完其它线路）+ 下线账（供饿死判据与验收指标）。
"""

from __future__ import annotations

from typing import Any, Dict, Iterable, List, Optional, Tuple

from .contracts import (
    ACTION_ATTACK, ACTION_ATTACK_MOVE, ACTION_BUILD, ACTION_DEFEND, ACTION_GATHER,
    ACTION_HOLD, ACTION_MOVE, ACTION_PRODUCE, ACTION_RETREAT, ACTION_SCOUT,
)

LANE_ECONOMY = "economy"
LANE_BUILD = "build"
LANE_SCOUT = "scout"
LANE_MILITARY = "military"
LANE_URGENT = "urgent"

#: 轮转顺序：紧急线在最前（可以抢占），但**每一轮都要走完其余四条线**，
#: 所以"紧急事件多"不会永久饿死经济/建造/侦察（计划 §5 原文要求）。
LANE_ORDER: Tuple[str, ...] = (LANE_URGENT, LANE_ECONOMY, LANE_BUILD, LANE_SCOUT,
                               LANE_MILITARY)

LANE_TITLE_CN: Dict[str, str] = {
    LANE_ECONOMY: "经济", LANE_BUILD: "建造", LANE_SCOUT: "侦察",
    LANE_MILITARY: "军事", LANE_URGENT: "紧急",
}

#: 一条有活的线路连续这么多 tick 没被服务 → 记一次饿死（默认 900≈15s）。
STARVE_TICKS = 900

#: 动作 → 线路。**新增动作只在这里加一行**（别处不许再写一份映射）。
_ACTION_LANE: Dict[str, str] = {
    ACTION_GATHER: LANE_ECONOMY,
    ACTION_BUILD: LANE_BUILD,
    ACTION_SCOUT: LANE_SCOUT,
    ACTION_MOVE: LANE_MILITARY,
    ACTION_ATTACK_MOVE: LANE_MILITARY,
    ACTION_ATTACK: LANE_MILITARY,
    ACTION_DEFEND: LANE_MILITARY,
    ACTION_RETREAT: LANE_MILITARY,
    ACTION_HOLD: LANE_MILITARY,
}

#: 哪个产品算"经济线"：工人（指挥中心产）归经济；其余作战单位归军事。
_ECONOMY_PRODUCTS = ("worker",)


def product_of(intent: Dict[str, Any]) -> str:
    """意图产品 id：优先看 `target.scene` 的文件名（权威口径），再看 task_id。"""
    target = intent.get("target")
    scene = ""
    if isinstance(target, dict):
        scene = str(target.get("scene", ""))
    if scene:
        name = scene.rsplit("/", 1)[-1]
        name = name.split(".")[0]
        if name:
            return name.lower()
    for key in ("task_id", "intent_id"):
        parts = str(intent.get(key, "")).split("-")
        if len(parts) >= 3 and parts[1] == "produce":
            return "-".join(parts[2:]).lower()
    return ""


def lane_of(intent: Dict[str, Any]) -> str:
    """意图属于哪条线路（**唯一口径**）。

    紧急优先：`emergency=true` 或显式标了 `lane=urgent` 的意图直接进紧急线
    （来源：受袭、路径失败、玩家接管等中断事件）。
    """
    if intent.get("emergency") or str(intent.get("lane", "")) == LANE_URGENT:
        return LANE_URGENT
    action = str(intent.get("action", ""))
    if action == ACTION_PRODUCE:
        return (LANE_ECONOMY if product_of(intent) in _ECONOMY_PRODUCTS
                else LANE_MILITARY)
    return _ACTION_LANE.get(action, LANE_MILITARY)


def _sort_key(intent: Dict[str, Any]):
    return (
        0 if intent.get("emergency") else 1,
        -int(intent.get("priority", 0) or 0),
        int(intent.get("issued_tick", 0) or 0),
        str(intent.get("intent_id", "")),
    )


def interleave(intents: Iterable[Dict[str, Any]], *,
               cursor: int = 0) -> Tuple[List[Dict[str, Any]], Dict[str, Any]]:
    """按**线路轮转**排序（取代"一次全局排序"）。

    规则：先按线路分桶、桶内按原有优先级排序，然后**逐轮**从每条线路取一条
    （每轮顺序 = 紧急 → 经济 → 建造 → 侦察 → 军事，起点按 `cursor` 旋转）。

    这样 `max_batch` 截断时，被截掉的一定是"各条线各自的次优意图"，
    而不是"整条线路"—— 这就是计划要的"每条线路每周期至少获得一次处理机会"。

    `cursor` 每次 +1（由调用方持久化），保证轮转起点不只偏向第一条线。
    """
    buckets: Dict[str, List[Dict[str, Any]]] = {lane: [] for lane in LANE_ORDER}
    for intent in intents or []:
        if not isinstance(intent, dict):
            continue
        buckets[lane_of(intent)].append(intent)
    for lane in buckets:
        buckets[lane].sort(key=_sort_key)
    order = list(LANE_ORDER)
    if order:
        shift = int(cursor) % len(order)
        order = order[shift:] + order[:shift]
    ordered: List[Dict[str, Any]] = []
    while any(buckets.values()):
        for lane in order:
            if buckets[lane]:
                ordered.append(buckets[lane].pop(0))
    trace = {
        "cursor": int(cursor),
        "next_cursor": (int(cursor) + 1) % max(1, len(LANE_ORDER)),
        "rotation": order,
        "pending": {lane: len(buckets[lane]) for lane in LANE_ORDER},
        "total": len(ordered),
    }
    return ordered, trace


def lane_snapshot(intents: Iterable[Dict[str, Any]], *,
                  tick: int, last_served: Optional[Dict[str, int]] = None,
                  pending: Optional[Dict[str, int]] = None,
                  starve_ticks: int = STARVE_TICKS) -> Dict[str, Any]:
    """每条线路的当前任务数 / 下次到期 / 最后处理 tick / 饿死时长（计划 §5 要求）。

    只读聚合，供日志与验收指标使用；`starved` 非空即为"有活却长期没被服务"。

    ## 饿死判据必须看**本轮候选**，不能看"活跃意图数"（2026-09-13 实测修正）

    第一版用"该线有活跃意图 + 很久没有新 accepted"判饿死 —— 结果 5 分钟集成局报了
    **383 次假饿死**：活跃意图的 TTL 是 3600 tick（2 分钟），一条正在执行的长任务
    会让"活跃意图数"长期 > 0，而 `last_served` 只在**新意图被接受**时才更新，
    于是"任务正在跑"被误判成"这条线被饿死了"。

    真实语义（也是计划 §5 的原意）：**该线本轮有候选、却因为配额/排序没拿到处理机会**。
    所以判据用调用方给的 `pending`（本轮各线候选数）。
    """
    served = dict(last_served or {})
    waiting = dict(pending or {})
    out: Dict[str, Any] = {}
    starved: List[Dict[str, Any]] = []
    now = int(tick or 0)
    for lane in LANE_ORDER:
        lane_intents = [item for item in (intents or [])
                        if isinstance(item, dict) and lane_of(item) == lane]
        expiries = [int(item.get("expires_tick", 0) or 0) for item in lane_intents]
        last = int(served.get(lane, 0) or 0)
        idle = (now - last) if last > 0 else 0
        queued = int(waiting.get(lane, 0) or 0)
        entry = {
            "tasks": len(lane_intents),
            "pending": queued,
            "next_expiry_tick": min([value for value in expiries if value > now],
                                    default=0),
            "last_served_tick": last,
            "idle_ticks": idle,
        }
        out[lane] = entry
        if queued > 0 and last > 0 and idle >= int(starve_ticks):
            starved.append({"lane": lane, "pending": queued, "tasks": len(lane_intents),
                            "idle_ticks": idle, "last_served_tick": last})
    out["starved"] = starved
    return out


def mark_served(last_served: Dict[str, int], lanes: Iterable[str],
                tick: int) -> Dict[str, int]:
    """把"这一轮服务了哪些线路"记进下线账（返回新字典，不原地改）。"""
    out = dict(last_served or {})
    for lane in lanes:
        if str(lane) in LANE_TITLE_CN:
            out[str(lane)] = int(tick)
    return out


def count_by_lane(intents: Iterable[Dict[str, Any]]) -> Dict[str, int]:
    """本轮各线候选数（供 `lane_snapshot` 判饿死）。"""
    counts = {lane: 0 for lane in LANE_ORDER}
    for item in intents or []:
        if isinstance(item, dict):
            counts[lane_of(item)] += 1
    return counts


def lanes_of(intents: Iterable[Dict[str, Any]]) -> List[str]:
    """这批意图**实际用到**的线路（去重、稳定顺序）。"""
    used = {lane_of(item) for item in (intents or []) if isinstance(item, dict)}
    return [lane for lane in LANE_ORDER if lane in used]
