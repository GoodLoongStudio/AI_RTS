# -*- coding: utf-8 -*-
"""整局主线（`campaign_state`）：阶段推进 + 里程碑 + 四条 track + 中断栈。

## 为什么必须有这一层（2026-09-12 纠偏 §问题判断）

LangGraph 已经能打断/恢复、有任务账本和 `active_plan`，但那**不等于拥有整局主线**：
`active_plan` 是"一次战略请求产出的计划"，`active_tasks` 是"某批意图的状态"，
`task_progress` 是"某条意图的观测进度"。三者都无法回答：

- 我们现在处在整局的哪个**阶段**（摸底 / 立足 / 扩张 / 施压 / 收束）？
- 这一局要打的**主线**是什么？**下一个该推进的节点**（next_frontier）是哪个？
- 主基地稳定、产能建筑、首支作战队、分基地/分矿这些**里程碑**完成了没有，
  靠什么**权威证据**判定完成？
- 紧急事件插进来之后，**原来的主线推进到哪里了**，处理完怎么回去？

把上面这些放进 `campaign_state`（本模块），并让它**跨 tick / 跨 checkpoint 保留**，
才谈得上"维护整局主线"。纪律：

1. **规则是地板**：本模块不依赖任何模型调用。即使模型全程关闭，规则中台也按
   `next_frontier` 推进（采集 → 产能建筑 → 兵力 → 扩张选址 → 分基地/分矿 → 防守/施压）。
2. **只有一条权威链**：本模块只产出"该推进哪个节点"与"候选参数"，
   实际命令仍由 `rules_fallback` / `behavior_tree` / 模型候选汇入同一条仲裁与下发链。
3. **完成证据只能来自权威**：里程碑的 `success_evidence` 一律由**观测事实** +
   **权威回执**判定，禁止用"生成了 plan / 生成了 task / 打了日志"代替游戏内完成。
4. **紧急事件只进 `interrupt_stack`**：主线与四条 track 只被**挂起（suspend）**，
   不被清空；处理完（回执闭环 / 威胁消失 / 超时）弹出并恢复原主线。
5. **玩家局部接管只暂停受影响对象**：写进 `suspended_objects`，主线不动。

所有字段都是 JSON / msgpack 友好类型（dict / list / str / int / float / bool），
因为它要进 LangGraph state 并被 checkpoint 落盘。
"""

from __future__ import annotations

import math
from typing import Any, Dict, List, Optional, Sequence, Tuple

from .observation_view import (
    entities as _entities, entity_id_of, living_enemies as _living_enemies,
    normalized_units, own_units as _own_units, pos2d as _pos2d, resources as _resources,
)
from . import placement

# ---------------------------------------------------------------------------
# 常量：阶段 / 主线 / 四条线
# ---------------------------------------------------------------------------

PHASE_RECON = "摸底"
PHASE_FOOTHOLD = "立足"
PHASE_EXPAND = "扩张"
PHASE_PRESSURE = "施压"
PHASE_CONVERGE = "收束"
PHASES: Tuple[str, ...] = (PHASE_RECON, PHASE_FOOTHOLD, PHASE_EXPAND,
                           PHASE_PRESSURE, PHASE_CONVERGE)

TRACK_ECONOMY = "economy"
TRACK_BUILD = "build"
TRACK_SCOUT = "scout"
TRACK_MILITARY = "military"
TRACKS: Tuple[str, ...] = (TRACK_ECONOMY, TRACK_BUILD, TRACK_SCOUT, TRACK_MILITARY)

TRACK_TITLE_CN: Dict[str, str] = {
    TRACK_ECONOMY: "经济", TRACK_BUILD: "建造", TRACK_SCOUT: "侦察",
    TRACK_MILITARY: "军事",
}

#: 主线标识与版本：`mainline_id` 说明"这一局按哪张主线跑"，
#: `mainline_version` 在主线定义变化时递增（旧 checkpoint 的主线状态按版本兼容处理）。
MAINLINE_ID = "mainline-default"
MAINLINE_VERSION = 1

#: 中断栈最大深度（超出丢弃最旧：中断本身也必须是有界的）。
MAX_INTERRUPT_DEPTH = 8
#: 里程碑重试窗口：同一里程碑最多"实际尝试"这么多次后标记 blocked（不阻塞其它节点）。
DEFAULT_RETRY_MAX = 6
#: 里程碑停滞窗口（tick）：一直在前沿却毫无进展 → blocked（避免整局卡在一个节点）。
DEFAULT_STALL_TICKS = 12000
#: 中断"静默多久"才允许弹出（tick）：事件风暴时不要把刚压入的紧急任务立刻弹掉。
INTERRUPT_QUIET_TICKS = 240
#: 中断最短驻留（tick）：保证紧急任务的命令至少下发过一次、有机会生效。
INTERRUPT_MIN_HOLD_TICKS = 120
#: 中断最长驻留（tick）：超时弹出（标记 expired），不许无限挂起主线。
INTERRUPT_MAX_TICKS = 7200

#: 作战单位类型（drone 无武器，不算作战单位 —— 与 `rules_fallback.COMBAT_TYPES` 同口径）。
COMBAT_TYPES: Tuple[str, ...] = ("soldier", "tank", "helicopter")

#: 分基地/分矿的"远离主基地"门槛（米）：与 `rules_fallback.EXPANSION_MIN_DISTANCE_M`
#: 同口径（那边是落点判定，这里是里程碑证据判定，必须一致）。
EXPANSION_MIN_DISTANCE_M = 30.0

# 【唯一事实来源】"执行者仍在忙"的意图状态直接引用 `graph.state`（不再手抄一份：
# 手抄件漏过一次 `active_unknown`，导致"在途"在本模块与仲裁/微调层口径不同）。
from .state import INTENT_LIVE_STATES as LIVE_INTENT_STATES  # noqa: E402

#: 权威接受态（里程碑证据只认这两个 + Completed）。
ACCEPTED_STATUSES: Tuple[str, ...] = ("Accepted", "Completed")

#: 动作 → 四条线。
ACTION_TRACK: Dict[str, str] = {
    "gather": TRACK_ECONOMY,
    "build": TRACK_BUILD,
    "scout": TRACK_SCOUT,
    "attack": TRACK_MILITARY,
    "attack_move": TRACK_MILITARY,
    "defend": TRACK_MILITARY,
    "retreat": TRACK_MILITARY,
    "regroup": TRACK_MILITARY,
    "move": TRACK_MILITARY,
    "hold": TRACK_MILITARY,
    "produce": TRACK_BUILD,
}


def track_of_action(action: Any) -> str:
    """动作归到哪条线（未知动作归军事线：它是默认的"机动"语义）。"""
    return ACTION_TRACK.get(str(action or ""), TRACK_MILITARY)


# ---------------------------------------------------------------------------
# 里程碑定义（程序侧主线骨架）
# ---------------------------------------------------------------------------
#
# 每个里程碑的字段与纠偏文档 §"必须实现的语义"逐项对应：
#   id / name / phase / track / priority
#   preconditions   —— 前置条件（其它里程碑 id 或事实条件名）
#   success_evidence—— 人类可读的完成判据（程序判定实现见 EVIDENCE）
#   exit            —— 完成时的退出语义
#   failure         —— 失败分支（对应手册 ECO-02/BLD-02/RET-01…）
#   retry           —— 重试/退避（max_attempts / stall_ticks）
#   build_order     —— 该节点为前沿时，规则阶梯的**建造优先级**（体现"沿主线发展"）
#
# 纪律：这里只写"整局骨架"，不写实现细节；候选与落点仍由 `rules_fallback` /
# `placement` 产出（唯一实现），避免第二套几何/策略。

M01 = "M01"
M02 = "M02"
M03 = "M03"
M04 = "M04"
M05 = "M05"
M06 = "M06"
M07 = "M07"

MILESTONES: Dict[str, Dict[str, Any]] = {
    M01: {
        "id": M01, "name": "工人开采", "phase": PHASE_RECON, "track": TRACK_ECONOMY,
        "priority": 10,
        "preconditions": (),
        "success_evidence": "至少一条采集命令被权威接受，且观测里仍有可采集单位",
        "exit": "工人按分配后的矿点持续往返（有 Accepted 回执）",
        "failure": "无可见资源 → 转侦察找矿（SCT-01）；资源不可达 → 改派其它矿点",
        "retry": {"max_attempts": DEFAULT_RETRY_MAX, "stall_ticks": DEFAULT_STALL_TICKS},
        "intent_prefixes": ("rule-gather", "bt-gather"),
        "build_order": (),
    },
    M02: {
        "id": M02, "name": "产能建筑", "phase": PHASE_FOOTHOLD, "track": TRACK_BUILD,
        "priority": 20,
        "preconditions": (M01,),
        "success_evidence": "观测里出现产能建筑（兵营/车厂/机场）且 constructed=True",
        "exit": "至少一座产能建筑完工（不是「已下单」）",
        "failure": "连续被拒 → 换落点/换建筑（BLD-02 重建产能）",
        "retry": {"max_attempts": DEFAULT_RETRY_MAX, "stall_ticks": DEFAULT_STALL_TICKS},
        "intent_prefixes": ("rule-build-barracks", "rule-build-vehicle_factory",
                            "rule-build-aircraft_factory"),
        "build_order": ("barracks", "vehicle_factory", "aircraft_factory"),
    },
    M03: {
        "id": M03, "name": "首支作战队", "phase": PHASE_FOOTHOLD, "track": TRACK_MILITARY,
        "priority": 30,
        "preconditions": (M02,),
        "success_evidence": "观测到作战单位数量达到阈值（兵/坦克/直升机）",
        "exit": "首支作战队成形（观测到实体，不是「队列里在生产」）",
        "failure": "产能建筑未完工 → 回 M02 续建；余额不足 → 回经济线",
        "retry": {"max_attempts": DEFAULT_RETRY_MAX, "stall_ticks": DEFAULT_STALL_TICKS},
        "intent_prefixes": ("rule-produce-soldier", "rule-produce-tank",
                            "rule-produce-helicopter"),
        # 这个节点要的是**兵力**：产能建筑已就位时先补兵、别再无限扩建
        # （2026-09-12 真机实测：5 分钟把兵营/车厂/机场/两座塔全建完，作战单位 0 个）。
        "produce_first": True,
        "build_order": (),
    },
    M04: {
        "id": M04, "name": "扩张选址", "phase": PHASE_EXPAND, "track": TRACK_SCOUT,
        "priority": 40,
        "preconditions": (M02,),
        "success_evidence": "程序按「离主基地足够远的可见矿点」算出至少一个合法落点",
        "exit": "已有可执行的分基地落点（位置在己方视野内）",
        "failure": "无可选矿点 → 派机动单位向远端矿点/未探索方向前探（SCT-01/SCT-02）",
        "retry": {"max_attempts": DEFAULT_RETRY_MAX, "stall_ticks": DEFAULT_STALL_TICKS},
        "intent_prefixes": ("rule-probe-expansion",),
        "build_order": (),
    },
    M05: {
        "id": M05, "name": "分基地/分矿", "phase": PHASE_EXPAND, "track": TRACK_BUILD,
        "priority": 45,
        "preconditions": (M04,),
        "success_evidence": "观测到第二座指挥中心（command_center）且 constructed=True",
        "exit": "分基地实际建成（游戏内实体存在，不是「已发 build 意图」）",
        "failure": "落点被拒 → 换点（账本按点拉黑）；无法建成 → 标记 blocked 并继续施压",
        "retry": {"max_attempts": DEFAULT_RETRY_MAX, "stall_ticks": 18000},
        "intent_prefixes": ("rule-build-command_center",),
        "build_order": ("command_center",),
    },
    M06: {
        "id": M06, "name": "持续施压", "phase": PHASE_PRESSURE, "track": TRACK_MILITARY,
        "priority": 50,
        "preconditions": (M03,),
        "success_evidence": "出击命令被权威接受，且观测到敌方单位死亡或掉血",
        "exit": "持续对敌方施压（不是「发过一条 attack」）",
        "failure": "劣势 → 撤离重组（RET-01/REG-01）；无损无果 → 补兵再压",
        "retry": {"max_attempts": DEFAULT_RETRY_MAX, "stall_ticks": DEFAULT_STALL_TICKS},
        "intent_prefixes": ("rule-attack", "bt-attack"),
        # 施压阶段以**打**为主：兵力补充优先于继续铺建筑。
        "produce_first": True,
        "build_order": ("anti_air_turret", "anti_ground_turret"),
    },
    M07: {
        "id": M07, "name": "收束", "phase": PHASE_CONVERGE, "track": TRACK_MILITARY,
        "priority": 60,
        "preconditions": (M06,),
        "success_evidence": "已侦察到的敌方单位全部确认死亡，或对局结算完成",
        "exit": "对局进入收束（敌方失去抵抗）",
        "failure": "敌方反推 → 回防守（DEF-01）并重建产能（BLD-02）",
        "retry": {"max_attempts": DEFAULT_RETRY_MAX, "stall_ticks": DEFAULT_STALL_TICKS},
        "intent_prefixes": (),
        # 收束阶段同理：边打边补，不再铺建筑。
        "produce_first": True,
        "build_order": ("anti_air_turret", "anti_ground_turret", "command_center"),
    },
}

#: 里程碑的稳定顺序（判定"阶段推进到哪"用）。
MILESTONE_ORDER: Tuple[str, ...] = (M01, M02, M03, M04, M05, M06, M07)


# ---------------------------------------------------------------------------
# 事实快照（里程碑证据的统一输入）
# ---------------------------------------------------------------------------


def _balance_of(tactical: Optional[Dict[str, Any]]) -> Dict[str, int]:
    out: Dict[str, int] = {}
    for key, value in ((tactical or {}).get("balance") or {}).items():
        try:
            out[str(key).upper()] = int(value)
        except (TypeError, ValueError):
            continue
    return out


def _base_anchor(by_name: Dict[str, Dict[str, Any]]) -> Optional[Tuple[float, float]]:
    """主基地锚点：只认不动的建筑（指挥中心优先），拿不到就 None（不猜）。"""
    for info in by_name.values():
        if "command_center" in str(info.get("type", "")):
            return _pos2d(info)
    for info in by_name.values():
        if info.get("queue"):
            return _pos2d(info)
    return None


def build_facts(state: Dict[str, Any], observation: Optional[Dict[str, Any]],
                tick: int) -> Dict[str, Any]:
    """观测 + 权威回执 → 里程碑判据用的**纯事实**快照（确定性、可序列化）。

    不伪造任何字段：拿不到就是 0 / 空列表。所有读取都走 `observation_view`
    （唯一解析层），避免第三份观测解析。
    """
    tactical = (observation or {}).get("tactical")
    strategic = (observation or {}).get("strategic")
    by_name = normalized_units(tactical)
    own = _own_units(tactical)
    enemies = _living_enemies(tactical)
    resources = _resources(tactical)

    counts: Dict[str, int] = {}
    constructed: Dict[str, int] = {}
    for info in by_name.values():
        key = str(info.get("type", ""))
        if not key:
            continue
        counts[key] = counts.get(key, 0) + 1
        if info.get("constructed") is not False:
            constructed[key] = constructed.get(key, 0) + 1

    workers = [name for name, info in by_name.items() if info.get("gather")]
    builders = [name for name, info in by_name.items() if info.get("construct")]
    producers = [name for name, info in by_name.items() if info.get("queue")]
    combat = [name for name, info in by_name.items()
              if str(info.get("type", "")) in COMBAT_TYPES]

    receipts = [item for item in (state.get("command_receipts") or [])
                if isinstance(item, dict)]
    accepted_actions: Dict[str, int] = {}
    accepted_prefixes: Dict[str, int] = {}
    rejected_prefixes: Dict[str, int] = {}
    # 内容类拒绝（契约/能力不匹配）**才是"这条路走不通"**；几何类（越界/视野/占用）
    # 按既有纪律是"换个点就行"，不该消耗里程碑的重试预算（否则一个视野外落点
    # 就能把"分基地"节点整条判阻塞 —— 2026-09-12 真机 `--model on` 档实测如此）。
    content_rejected_prefixes: Dict[str, int] = {}
    for receipt in receipts:
        status = str(receipt.get("status", ""))
        action = str(receipt.get("action", ""))
        prefix = placement.intent_prefix(receipt.get("intent_id", ""))
        if bool(receipt.get("accepted", False)) and status in ACCEPTED_STATUSES:
            if action:
                accepted_actions[action] = accepted_actions.get(action, 0) + 1
            if prefix:
                accepted_prefixes[prefix] = accepted_prefixes.get(prefix, 0) + 1
        elif not bool(receipt.get("accepted", False)) and prefix:
            rejected_prefixes[prefix] = rejected_prefixes.get(prefix, 0) + 1
            kind = placement.classify_rejection("%s %s" % (status, receipt.get("reason", "")))
            if kind in placement.CONTENT_KINDS:
                content_rejected_prefixes[prefix] = \
                    content_rejected_prefixes.get(prefix, 0) + 1

    enemy_intel = []
    enemy_dead = 0
    if isinstance(strategic, dict):
        for item in strategic.get("enemy_intel") or []:
            if not isinstance(item, dict):
                continue
            enemy_intel.append(item)
            if bool(item.get("confirmed_dead")):
                enemy_dead += 1

    base = _base_anchor(by_name)
    far_resources: List[List[float]] = []
    if base is not None:
        for resource in resources:
            pos = _pos2d(resource)
            if math.hypot(pos[0] - base[0], pos[1] - base[1]) >= EXPANSION_MIN_DISTANCE_M:
                far_resources.append([round(pos[0], 1), round(pos[1], 1)])

    return {
        "tick": int(tick),
        "own": sorted(by_name.keys()),
        "counts": counts,
        "constructed": constructed,
        "workers": workers,
        "builders": builders,
        "producers": producers,
        "combat": combat,
        "combat_count": len(combat),
        "visible_enemies": [entity_id_of(e) for e in enemies if entity_id_of(e)],
        "enemy_intel_count": len(enemy_intel),
        "enemy_dead_count": enemy_dead,
        "resources": [[round(_pos2d(r)[0], 1), round(_pos2d(r)[1], 1)] for r in resources],
        "resource_count": len(resources),
        "far_resources": far_resources,
        "base": [round(base[0], 1), round(base[1], 1)] if base else [],
        "balance": _balance_of(tactical),
        "map_bounds": list(state.get("map_bounds") or []),
        "accepted_actions": accepted_actions,
        "accepted_prefixes": accepted_prefixes,
        "rejected_prefixes": rejected_prefixes,
        "content_rejected_prefixes": content_rejected_prefixes,
        "outcome_finished": bool(((tactical or {}).get("outcome") or {}).get("finished")),
        "truncated": (tactical or {}).get("truncated"),
    }


# ---------------------------------------------------------------------------
# 证据判定器（唯一实现：里程碑完成只认这里）
# ---------------------------------------------------------------------------


def _evidence_workers_gathering(facts: Dict[str, Any], campaign: Dict[str, Any]
                                ) -> Tuple[bool, str]:
    has_worker = bool(facts["workers"])
    accepted = int(facts["accepted_actions"].get("gather", 0))
    if has_worker and accepted > 0:
        return True, "采集命令已被权威接受（%d 条）且观测到工人" % accepted
    if has_worker and facts["accepted_prefixes"].get("rule-gather"):
        return True, "规则采集命令已被权威接受"
    return False, "等待采集命令被权威接受（当前 accepted gather=%d）" % accepted


def _evidence_production_building(facts: Dict[str, Any], campaign: Dict[str, Any]
                                 ) -> Tuple[bool, str]:
    for key in ("barracks", "vehicle_factory", "aircraft_factory"):
        if int(facts["constructed"].get(key, 0)) > 0:
            return True, "观测到已完工的产能建筑 %s" % key
    pending = [k for k, v in facts["counts"].items()
               if k in ("barracks", "vehicle_factory", "aircraft_factory") and v > 0]
    return False, ("产能建筑工地已出现但未完工：%s" % ",".join(pending)) if pending \
        else "尚无产能建筑（等待建造完成）"


def _evidence_first_squad(facts: Dict[str, Any], campaign: Dict[str, Any]
                          ) -> Tuple[bool, str]:
    threshold = int(campaign.get("army_threshold", 2) or 2)
    if facts["combat_count"] >= threshold:
        return True, "观测到 %d 个作战单位（≥%d）" % (facts["combat_count"], threshold)
    return False, "作战单位 %d/%d（队列里生产不算完成）" % (facts["combat_count"], threshold)


def _evidence_expansion_candidate(facts: Dict[str, Any], campaign: Dict[str, Any]
                                  ) -> Tuple[bool, str]:
    spots = campaign.get("expansion_candidates") or []
    if spots:
        return True, "已算出 %d 个分基地候选落点（如 %s）" % (len(spots), spots[0])
    if facts["far_resources"]:
        return False, "已有 %d 处远端矿点，但落点尚未通过可行性校验" % len(facts["far_resources"])
    return False, "尚无「离主基地 >=%dm 的可见矿点」（需要前探）" % int(EXPANSION_MIN_DISTANCE_M)


def _evidence_second_base(facts: Dict[str, Any], campaign: Dict[str, Any]
                          ) -> Tuple[bool, str]:
    total = int(facts["counts"].get("command_center", 0))
    done = int(facts["constructed"].get("command_center", 0))
    if done >= 2:
        return True, "观测到 %d 座已完工指挥中心（分基地已建成）" % done
    if total >= 2:
        return False, "第二座指挥中心在建（工地已出现，未完工）"
    return False, "指挥中心 %d 座（分基地尚未开工）" % total


def _evidence_pressure(facts: Dict[str, Any], campaign: Dict[str, Any]
                       ) -> Tuple[bool, str]:
    accepted = (int(facts["accepted_actions"].get("attack", 0))
                + int(facts["accepted_actions"].get("attack_move", 0)))
    if accepted <= 0:
        return False, "尚无被权威接受的出击命令"
    # 施压的**结果证据**：只有"敌方单位确认死亡 / 掉血 / 从 intel 消失"才算，不认"发过一条 attack"。
    damage = int(campaign.get("enemy_damage_events", 0) or 0)
    if facts["enemy_dead_count"] > 0 or damage > 0:
        return True, "已对敌方造成损失（死亡 %d / 掉血事件 %d）" % (
            facts["enemy_dead_count"], damage)
    return False, "出击命令已被接受（%d 条），等待战果证据" % accepted


def _evidence_converge(facts: Dict[str, Any], campaign: Dict[str, Any]
                       ) -> Tuple[bool, str]:
    if facts["outcome_finished"]:
        return True, "对局已结算"
    if facts["enemy_intel_count"] > 0 and \
            facts["enemy_dead_count"] >= facts["enemy_intel_count"]:
        return True, "已侦察到的敌方单位全部确认死亡（%d）" % facts["enemy_dead_count"]
    if not facts["enemy_intel_count"] and not facts["visible_enemies"]:
        return False, "尚无任何敌情（收束无从判定）"
    return False, "敌方仍有存活（死亡 %d / 已知 %d）" % (
        facts["enemy_dead_count"], facts["enemy_intel_count"])


EVIDENCE: Dict[str, Any] = {
    M01: _evidence_workers_gathering,
    M02: _evidence_production_building,
    M03: _evidence_first_squad,
    M04: _evidence_expansion_candidate,
    M05: _evidence_second_base,
    M06: _evidence_pressure,
    M07: _evidence_converge,
}


# ---------------------------------------------------------------------------
# campaign_state 生命周期
# ---------------------------------------------------------------------------


def default_campaign(tick: int = 0) -> Dict[str, Any]:
    """每局开局由程序建立的**默认主线**：摸底 → 立足 → 扩张 → 施压 → 收束。

    四条线开局即并行存在（不是串行剧本）：经济采集、建造补产能、侦察探路、
    军事集结；`next_frontier` 只表示"当前最值得推进的一个节点"。
    """
    milestones: Dict[str, Dict[str, Any]] = {}
    for key in MILESTONE_ORDER:
        spec = MILESTONES[key]
        milestones[key] = {
            "id": key, "name": str(spec["name"]), "phase": str(spec["phase"]),
            "track": str(spec["track"]), "priority": int(spec["priority"]),
            "status": "pending", "attempts": 0, "done_tick": 0,
            "frontier_since": 0, "last_evidence": "", "blocked_reason": "",
            "rejections": 0, "updated_tick": int(tick),
        }
    tracks: Dict[str, Dict[str, Any]] = {}
    for name in TRACKS:
        tracks[name] = {
            "status": "running", "current": None, "last_update_tick": int(tick),
            "suspended_objects": [], "suspensions": 0,
        }
    return {
        "mainline_id": MAINLINE_ID,
        "mainline_version": MAINLINE_VERSION,
        "mainline_branch": "",
        "branch_source": "",
        "branch_tick": 0,
        "created_tick": int(tick),
        "updated_tick": int(tick),
        "phase": PHASE_RECON,
        "phase_changed_tick": int(tick),
        "phase_history": [{"phase": PHASE_RECON, "tick": int(tick)}],
        "milestones": milestones,
        "tracks": tracks,
        "next_frontier": M01,
        "frontier_kind": "milestone",
        "blocked_milestones": [],
        "expansion_candidates": [],
        "expansion_probe": [],
        "interrupt_stack": [],
        "interrupt_total": 0,
        "interrupt_resolved": 0,
        "suspended_objects": [],
        "player_overrides": 0,
        "player_releases": 0,
        "army_threshold": 2,
        "enemy_damage_events": 0,
        "enemy_hp_watch": {},
        "transitions": [],
    }


def ensure_campaign(state: Dict[str, Any], tick: int = 0) -> Dict[str, Any]:
    """读取 `state["campaign_state"]`；缺失就按默认主线建立（幂等）。

    为什么必须由程序建立而不是等模型：纠偏 §"每局开局必须由程序根据地图、资源、
    可用建筑和决策地图创建一个可执行的默认主线"。
    """
    campaign = state.get("campaign_state")
    if not isinstance(campaign, dict) or not campaign.get("milestones"):
        campaign = default_campaign(tick=int(tick))
        state["campaign_state"] = campaign
        return campaign
    # 兼容性补齐：旧 checkpoint / 手工构造的 campaign 可能缺字段。
    template = default_campaign(tick=int(tick))
    for key, value in template.items():
        if key not in campaign:
            campaign[key] = value
    milestones = campaign.get("milestones")
    if not isinstance(milestones, dict):
        campaign["milestones"] = template["milestones"]
    else:
        for key, entry in template["milestones"].items():
            current = milestones.get(key)
            if not isinstance(current, dict):
                milestones[key] = entry
                continue
            for field, value in entry.items():
                current.setdefault(field, value)
    tracks = campaign.get("tracks")
    if not isinstance(tracks, dict):
        campaign["tracks"] = template["tracks"]
    else:
        for key, entry in template["tracks"].items():
            current = tracks.get(key)
            if not isinstance(current, dict):
                tracks[key] = entry
                continue
            for field, value in entry.items():
                current.setdefault(field, value)
    if campaign.get("mainline_version") != MAINLINE_VERSION:
        # 主线定义变化：里程碑表按新版本对齐（保留已完成状态，避免"重开一局"）。
        campaign["mainline_version"] = MAINLINE_VERSION
    return campaign


# ---------------------------------------------------------------------------
# 四条 track 的推进（挂起/恢复）
# ---------------------------------------------------------------------------


def _live_intents(state: Dict[str, Any], tick: int) -> List[Dict[str, Any]]:
    out = []
    for intent in state.get("active_intents") or []:
        if not isinstance(intent, dict):
            continue
        if str(intent.get("state", "")) not in LIVE_INTENT_STATES:
            continue
        try:
            expires = int(intent.get("expires_tick", 0) or 0)
        except (TypeError, ValueError):
            expires = 0
        if expires and expires < int(tick):
            continue
        out.append(intent)
    return out


def _refresh_tracks(campaign: Dict[str, Any], state: Dict[str, Any], tick: int) -> None:
    """四条线各自记录**当前任务**（来自仍在执行的意图）与挂起对象。

    关键语义：挂起 ≠ 清空。`suspended_objects` 只列受影响对象；
    `current` 保留最后一次已知任务，恢复时无需重算。
    """
    tracks = campaign["tracks"]
    suspended = {str(u) for u in (campaign.get("suspended_objects") or [])}
    for name in TRACKS:
        entry = tracks.setdefault(name, {})
        entry["suspended_objects"] = [u for u in (entry.get("suspended_objects") or [])
                                      if str(u) in suspended]
        entry["status"] = "suspended" if entry["suspended_objects"] else "running"

    for intent in _live_intents(state, tick):
        track = track_of_action(intent.get("action"))
        units = [str(u) for u in (intent.get("unit_ids") or [])]
        if units and all(u in suspended for u in units):
            continue
        entry = tracks.setdefault(track, {})
        entry["current"] = {
            "intent_id": str(intent.get("intent_id", "")),
            "task_id": str(intent.get("task_id", "")),
            "action": str(intent.get("action", "")),
            "units": units,
            "since_tick": int(intent.get("issued_tick", 0) or 0),
        }
        entry["last_update_tick"] = int(tick)


# ---------------------------------------------------------------------------
# 中断栈（紧急事件）与玩家接管
# ---------------------------------------------------------------------------


def note_emergency(campaign: Dict[str, Any], kind: str, tick: int,
                   units: Sequence[str] = (), detail: str = "") -> Dict[str, Any]:
    """紧急事件**只压入 `interrupt_stack`**：主线与四条 track 保持不动。

    同一类紧急事件在栈里已存在且仍活跃 → 只更新 `last_tick`（不堆叠），
    避免"事件风暴把栈灌满"从而丢掉更早的恢复点。
    """
    stack = campaign.setdefault("interrupt_stack", [])
    for entry in stack:
        if str(entry.get("kind", "")) == str(kind) and str(entry.get("status")) == "active":
            entry["last_tick"] = int(tick)
            entry["count"] = int(entry.get("count", 1)) + 1
            for unit in units:
                if str(unit) and str(unit) not in entry["units"]:
                    entry["units"].append(str(unit))
            return entry
    entry = {
        "interrupt_id": "int-%s-%d" % (str(kind), int(tick)),
        "kind": str(kind),
        "status": "active",
        "detail": str(detail or "")[:120],
        "units": [str(u) for u in units if str(u)],
        "pushed_tick": int(tick),
        "last_tick": int(tick),
        "expires_tick": int(tick) + INTERRUPT_MAX_TICKS,
        "count": 1,
        # 恢复点：记下压栈时的主线状态（**不是**"清空后的状态"）。
        "resume": {
            "phase": str(campaign.get("phase", PHASE_RECON)),
            "next_frontier": str(campaign.get("next_frontier", "")),
            "mainline_branch": str(campaign.get("mainline_branch", "")),
            "tracks": {name: str((campaign.get("tracks", {}).get(name) or {})
                                 .get("status", "running")) for name in TRACKS},
        },
    }
    stack.append(entry)
    campaign["interrupt_total"] = int(campaign.get("interrupt_total", 0)) + 1
    while len(stack) > MAX_INTERRUPT_DEPTH:
        dropped = stack.pop(0)
        dropped["status"] = "dropped"
        campaign.setdefault("interrupt_dropped", []).append(dropped["interrupt_id"])
    return entry


def _visible_enemies_near_base(facts: Dict[str, Any], radius: float = 40.0) -> int:
    base = facts.get("base") or []
    if not base:
        return 0
    count = 0
    for pos in facts.get("enemy_positions") or []:
        try:
            if math.hypot(float(pos[0]) - float(base[0]),
                          float(pos[1]) - float(base[1])) <= radius:
                count += 1
        except (TypeError, ValueError, IndexError):
            continue
    return count


def resolve_interrupts(campaign: Dict[str, Any], facts: Dict[str, Any],
                       tick: int) -> List[Dict[str, Any]]:
    """把已处理完 / 超时的紧急任务弹出，并**恢复原主线和四条 track**。

    弹出条件（全部成立）：
      ① 已驻留 ≥ `INTERRUPT_MIN_HOLD_TICKS`（保证紧急任务至少下发过一次）；
      ② 距最近一次同类事件 ≥ `INTERRUPT_QUIET_TICKS`（事件不再刷屏）；
      ③ 威胁消失（基地受袭类要求基地附近无可见敌人）。
    或 ④ 超过 `expires_tick`（超时弹出，标记 expired，同样恢复主线）。
    """
    resolved: List[Dict[str, Any]] = []
    stack = campaign.get("interrupt_stack") or []
    keep: List[Dict[str, Any]] = []
    for entry in stack:
        status = str(entry.get("status", "active"))
        if status != "active":
            continue
        quiet = int(tick) - int(entry.get("last_tick", tick))
        held = int(tick) - int(entry.get("pushed_tick", tick))
        expired = int(tick) > int(entry.get("expires_tick", 0) or 0)
        threat_clear = True
        if str(entry.get("kind", "")) == "base_under_attack":
            threat_clear = _visible_enemies_near_base(facts) <= 0
        ready = (held >= INTERRUPT_MIN_HOLD_TICKS and quiet >= INTERRUPT_QUIET_TICKS
                 and threat_clear)
        if expired or ready:
            entry["status"] = "expired" if expired and not ready else "resolved"
            entry["resolved_tick"] = int(tick)
            entry["resolution"] = "timeout" if expired and not ready else "handled"
            resolved.append(entry)
            continue
        keep.append(entry)
    if resolved:
        campaign["interrupt_stack"] = keep
        campaign["interrupt_resolved"] = int(campaign.get("interrupt_resolved", 0)) \
            + len(resolved)
        for name in TRACKS:
            entry = campaign["tracks"].setdefault(name, {})
            entry["status"] = ("suspended" if entry.get("suspended_objects") else "running")
        # 恢复原主线：`next_frontier` 会由 `_recompute_frontier` 重新算，
        # 这里只保证"主线标识/分支"不因中断而漂移。
        resume = resolved[-1].get("resume") or {}
        if resume.get("mainline_branch"):
            campaign["mainline_branch"] = str(resume["mainline_branch"])
    return resolved


def note_player_override(campaign: Dict[str, Any], units: Sequence[str], tick: int,
                         reason: str = "") -> None:
    """玩家局部接管：**只暂停受影响对象**，不清空整局主线。

    - `suspended_objects` 记受影响对象（会被 `frontier_preferences` / 候选生成排除）；
    - 四条 track 的 `current` 保留（恢复后继续），只把对应 track 标 suspended；
    - 里程碑状态一律不动（未完成里程碑不丢失、不重置）。
    """
    suspended = campaign.setdefault("suspended_objects", [])
    for unit in units:
        key = str(unit)
        if key and key not in suspended:
            suspended.append(key)
    campaign["player_overrides"] = int(campaign.get("player_overrides", 0)) + 1
    campaign.setdefault("player_events", []).append(
        {"kind": "override", "units": [str(u) for u in units],
         "tick": int(tick), "reason": str(reason or "")[:80]})
    del campaign["player_events"][:-16]      # 有界：只留最近 16 条
    # 只挂在**确实包含这些对象**的 track 上：玩家接管 1 个工人不该让军事线也显示挂起。
    for name in TRACKS:
        entry = campaign["tracks"].setdefault(name, {})
        current_units = {str(u) for u in ((entry.get("current") or {}).get("units") or [])}
        hits = current_units & {str(u) for u in units}
        if not hits:
            continue
        entry["suspended_objects"] = sorted(set(entry.get("suspended_objects") or []) | hits)
        entry["status"] = "suspended"
        entry["suspensions"] = int(entry.get("suspensions", 0)) + 1
    campaign.setdefault("suspension_log", []).append(
        {"tick": int(tick), "units": [str(u) for u in units]})
    del campaign["suspension_log"][:-16]


def note_player_release(campaign: Dict[str, Any], units: Sequence[str], tick: int) -> None:
    """玩家显式归还：解除挂起（主线与里程碑从未被清空，因此无需重建）。"""
    suspended = set(str(u) for u in (campaign.get("suspended_objects") or []))
    for unit in units:
        suspended.discard(str(unit))
    campaign["suspended_objects"] = sorted(suspended)
    campaign["player_releases"] = int(campaign.get("player_releases", 0)) + 1
    for name in TRACKS:
        entry = campaign["tracks"].setdefault(name, {})
        entry["suspended_objects"] = [u for u in (entry.get("suspended_objects") or [])
                                      if str(u) in suspended]
        entry["status"] = "suspended" if entry["suspended_objects"] else "running"
    campaign.setdefault("suspension_log", []).append(
        {"tick": int(tick), "released": [str(u) for u in units]})
    del campaign["suspension_log"][:-16]


# ---------------------------------------------------------------------------
# 里程碑推进
# ---------------------------------------------------------------------------


def _transition(campaign: Dict[str, Any], **event: Any) -> Dict[str, Any]:
    """记一条主线变迁（有界）；同时留一份"本 tick 新增"供节点写决策日志。

    为什么要有 `new_transitions`：`transitions` 是有界历史（用于诊断），
    节点每轮需要的是"**这一轮**发生了什么"（用于 `decision_log` 与面板），
    从有界历史里靠下标去猜会在裁剪后错位。
    """
    entry = dict(event)
    history = campaign.setdefault("transitions", [])
    history.append(entry)
    del history[:-32]
    fresh = campaign.setdefault("new_transitions", [])
    fresh.append(entry)
    del fresh[:-32]
    return entry


def _preconditions_met(campaign: Dict[str, Any], milestone_id: str,
                       facts: Dict[str, Any]) -> Tuple[bool, str]:
    spec = MILESTONES.get(milestone_id) or {}
    for requirement in spec.get("preconditions") or ():
        entry = campaign["milestones"].get(str(requirement)) or {}
        if str(entry.get("status", "")) != "done":
            return False, "前置里程碑 %s(%s) 未完成" % (
                requirement, str(entry.get("name", "")))
        if not entry.get("done_tick"):
            return False, "前置里程碑 %s 缺少权威证据 tick" % requirement
    return True, ""


def _advance_milestone(campaign: Dict[str, Any], milestone_id: str, tick: int,
                       detail: str) -> None:
    entry = campaign["milestones"].setdefault(milestone_id, {})
    if str(entry.get("status")) == "done":
        return
    entry["status"] = "done"
    entry["done_tick"] = int(tick)
    entry["last_evidence"] = str(detail)[:160]
    entry["blocked_reason"] = ""
    entry["updated_tick"] = int(tick)
    # 曾经被标记阻塞、后来真的做成了（例：扩张候选晚到）→ 从阻塞清单移除，
    # 否则"阻塞=已完成的里程碑"会同时出现在报告与模型上下文里（自相矛盾）。
    blocked = campaign.get("blocked_milestones") or []
    if milestone_id in blocked:
        campaign["blocked_milestones"] = [x for x in blocked if x != milestone_id]
    _transition(campaign, kind="milestone_done", id=milestone_id, tick=int(tick),
                evidence=str(detail)[:160])


def _note_rejections(campaign: Dict[str, Any], facts: Dict[str, Any], tick: int) -> None:
    """按**权威拒绝证据**累计里程碑的重试次数（重试/退避的判据）。

    **只数内容类拒绝**（契约/能力不匹配 = 这条路真走不通）。
    几何类拒绝（越界/视野外/被占）按既有纪律是"换个点就行"，由落点账本按点处理；
    把它也算进里程碑预算，会让"分基地"因为"那个点当时不在视野里"整条判阻塞
    （2026-09-12 真机 `--model on` 档实测：6 条 `build/Rejected` → M05 被阻塞）。
    """
    rejected = facts.get("content_rejected_prefixes") or {}
    for milestone_id in MILESTONE_ORDER:
        spec = MILESTONES[milestone_id]
        entry = campaign["milestones"][milestone_id]
        if str(entry.get("status")) in ("done", "blocked"):
            continue
        count = 0
        for prefix in spec.get("intent_prefixes") or ():
            count += int(rejected.get(prefix, 0))
        if count > int(entry.get("rejections", 0)):
            entry["rejections"] = count
            entry["updated_tick"] = int(tick)
            limit = int((spec.get("retry") or {}).get("max_attempts", DEFAULT_RETRY_MAX))
            if count >= limit and str(entry.get("status")) != "done":
                _block_milestone(campaign, milestone_id, tick,
                                 "连续 %d 条命令被权威拒绝（内容类）" % count)


def _block_milestone(campaign: Dict[str, Any], milestone_id: str, tick: int,
                     reason: str) -> None:
    entry = campaign["milestones"].setdefault(milestone_id, {})
    if str(entry.get("status")) in ("done", "blocked"):
        return
    entry["status"] = "blocked"
    entry["blocked_reason"] = str(reason)[:120]
    entry["updated_tick"] = int(tick)
    blocked = campaign.setdefault("blocked_milestones", [])
    if milestone_id not in blocked:
        blocked.append(milestone_id)
    _transition(campaign, kind="milestone_blocked", id=milestone_id, tick=int(tick),
                reason=str(reason)[:120])


def _recompute_frontier(campaign: Dict[str, Any], facts: Dict[str, Any], tick: int
                        ) -> str:
    """`next_frontier`：当前**最值得推进**的一个主线节点。

    规则：按优先级遍历未完成里程碑，取第一个**前置条件已满足且未被阻塞**的；
    若全部不可行，则退回"最早的未完成节点"（只做诊断用，不产生命令）。
    模型显式选择的分支（`mainline_branch`）在条件满足时优先。
    """
    branch = str(campaign.get("mainline_branch", "") or "")
    frontier = ""
    if branch and branch in campaign["milestones"]:
        entry = campaign["milestones"][branch]
        if str(entry.get("status")) != "done":
            ok, _ = _preconditions_met(campaign, branch, facts)
            if ok:
                frontier = branch
    if not frontier:
        for milestone_id in sorted(MILESTONE_ORDER,
                                   key=lambda key: int(MILESTONES[key]["priority"])):
            entry = campaign["milestones"][milestone_id]
            if str(entry.get("status")) in ("done", "blocked"):
                continue
            ok, _ = _preconditions_met(campaign, milestone_id, facts)
            if ok:
                frontier = milestone_id
                break
    if not frontier:
        for milestone_id in MILESTONE_ORDER:
            entry = campaign["milestones"][milestone_id]
            if str(entry.get("status")) in ("done", "blocked"):
                continue
            frontier = milestone_id
            break
    previous = str(campaign.get("next_frontier", ""))
    campaign["next_frontier"] = frontier
    if frontier and frontier != previous:
        entry = campaign["milestones"].setdefault(frontier, {})
        entry["frontier_since"] = int(tick)
        _transition(campaign, kind="frontier", id=frontier, tick=int(tick),
                    **{"from": previous})
    return frontier


def _phase_of(campaign: Dict[str, Any]) -> str:
    frontier = str(campaign.get("next_frontier", ""))
    spec = MILESTONES.get(frontier)
    if spec:
        return str(spec["phase"])
    return PHASE_CONVERGE


def _stall_check(campaign: Dict[str, Any], facts: Dict[str, Any], tick: int) -> None:
    """前沿节点长期无进展 → blocked（避免整局卡在一个里程碑上）。

    判据是"停在前沿太久且证据仍未达成"，与"是否下过命令"无关 ——
    所以既覆盖"命令一直被拒"，也覆盖"根本没产生命令"（如找不到扩张矿点）。
    """
    frontier = str(campaign.get("next_frontier", ""))
    spec = MILESTONES.get(frontier)
    if not spec:
        return
    entry = campaign["milestones"][frontier]
    if str(entry.get("status")) != "pending":
        return
    since = int(entry.get("frontier_since", 0) or 0)
    if not since:
        entry["frontier_since"] = int(tick)
        return
    stall = int(tick) - since
    limit = int((spec.get("retry") or {}).get("stall_ticks", DEFAULT_STALL_TICKS))
    if stall >= limit:
        _block_milestone(campaign, frontier, tick,
                         "停在前沿 %d tick 无进展（超过 %d）" % (stall, limit))


# ---------------------------------------------------------------------------
# 扩张候选（分基地/分矿）：程序算，模型选
# ---------------------------------------------------------------------------


def _expansion_candidates(state: Dict[str, Any], facts: Dict[str, Any],
                          campaign: Dict[str, Any],
                          tactical: Optional[Dict[str, Any]] = None
                          ) -> List[List[float]]:
    """算出分基地候选落点（唯一实现：委派 `rules_fallback.pick_expansion_spot`）。

    迟导入 `rules_fallback`：那个模块需要读 campaign（前沿偏好），
    顶层互相 import 会成环。
    """
    from . import rules_fallback as rf
    by_name = normalized_units(tactical)
    if not by_name:
        return []
    anchor = rf.base_anchor_pos(by_name) or rf._base_anchor_pos(by_name)
    if anchor is None:
        return []
    blocked = placement.ledger_from_state(state)
    spot = rf.pick_expansion_spot(by_name, _resources(tactical), anchor,
                                  blocked=blocked, bounds=state.get("map_bounds"))
    return [spot] if spot else []


def _expansion_probe(state: Dict[str, Any], facts: Dict[str, Any]) -> List[float]:
    """扩张前探点：没有候选时，朝**最远的可见矿点**（或地图内侧）派机动单位前探。

    为什么需要：分基地落点必须**在己方视野内**（权威端只接受视野内的建造点），
    而远端矿点没有己方单位就不会进入视野 —— 于是"有远端矿点"与"有合法落点"
    之间缺一环。这一环由**前探**补上（手册 SCT-01 开局散点探路 / SCT-02 定向侦察）。
    """
    base = facts.get("base") or []
    if not base:
        return []
    candidates: List[Tuple[float, List[float]]] = []
    for pos in facts.get("far_resources") or []:
        distance = math.hypot(float(pos[0]) - float(base[0]),
                              float(pos[1]) - float(base[1]))
        candidates.append((distance, [float(pos[0]), float(pos[1])]))
    if candidates:
        candidates.sort(key=lambda item: (-item[0], item[1][0], item[1][1]))
        return candidates[0][1]
    bounds = facts.get("map_bounds") or []
    if len(bounds) >= 2:
        center = [float(bounds[0]) / 2.0, float(bounds[1]) / 2.0]
        return [round(center[0], 1), round(center[1], 1)]
    return []


# ---------------------------------------------------------------------------
# 对外：模型分支选择 / 前沿偏好 / 上下文视图
# ---------------------------------------------------------------------------


def note_model_branch(state: Dict[str, Any], ref: str, tick: int,
                      candidate_ids: Sequence[str] = ()) -> Dict[str, Any]:
    """模型通过四列输出的 `g` 字段做**主线分支选择**（低频、可校验）。

    纪律（纠偏 §"小模型只选择主线分支和参数"）：
    - 只接受"前置条件已满足"的分支（候选集由 `decision_map.retrieve` 每 tick 筛出）；
    - 非法 / 未知 / 条件不满足 → **沿用当前主线**，不报错、不清空任何东西
      （空输出 ≠ 无战略，这是纠偏明令）；
    - 记 `branch_source`，便于事后区分"基线沿主线推进"与"模型改的分支"。

    接受两种引用：决策地图 ref（`D3`）与手册编号（`BLD-01`）；
    节点没有绑定里程碑时（如 D7 定向侦察）只影响"前沿偏好"，不改主线骨架。
    """
    campaign = ensure_campaign(state, tick)
    text = str(ref or "").strip()
    if not text:
        return {"accepted": False, "reason": "empty_ref"}
    available = [str(x) for x in (campaign.get("decision_available") or [])]
    if candidate_ids:
        available = [str(x) for x in candidate_ids]
    from . import decision_map

    node = decision_map.resolve_branch(text)
    if node:
        node_id = str(node["id"])
        if available and node_id not in available:
            return {"accepted": False, "reason": "precondition_unmet", "detail": node_id}
        milestone = str(node.get("milestone") or "")
        campaign["preferred_node"] = node_id
        campaign["preferred_node_tick"] = int(tick)
        if milestone:
            entry = campaign["milestones"].get(milestone) or {}
            if str(entry.get("status")) in ("done", "blocked"):
                return {"accepted": False,
                        "reason": "branch_%s" % entry.get("status"), "detail": milestone}
            campaign["mainline_branch"] = milestone
        campaign["branch_source"] = "model"
        campaign["branch_tick"] = int(tick)
        _transition(campaign, kind="branch_selected", id=node_id, tick=int(tick),
                    source="model", **{"milestone": milestone})
        return {"accepted": True, "reason": "adopted", "node": node_id,
                "branch": milestone}

    if text in campaign["milestones"]:
        entry = campaign["milestones"][text]
        if str(entry.get("status")) in ("done", "blocked"):
            return {"accepted": False, "reason": "branch_%s" % entry.get("status")}
        ok, why = _preconditions_met(campaign, text, campaign.get("_facts") or {})
        if not ok:
            return {"accepted": False, "reason": "precondition_unmet", "detail": why}
        campaign["mainline_branch"] = text
        campaign["branch_source"] = "model"
        campaign["branch_tick"] = int(tick)
        _transition(campaign, kind="branch_selected", id=text, tick=int(tick),
                    source="model", **{"milestone": text})
        return {"accepted": True, "reason": "adopted", "branch": text}
    return {"accepted": False, "reason": "unknown_branch"}


def frontier_preferences(state: Dict[str, Any], observation: Optional[Dict[str, Any]] = None,
                         *, tick: Optional[int] = None) -> Dict[str, Any]:
    """规则中台的**主线偏好**（阶梯顺序 / 是否允许出击 / 是否需要前探）。

    **没有 campaign_state 时返回宽松默认值**：直接调用规则阶梯的单测/回放不应该
    因为"没有整局主线"而改变既有语义（那不是本模块的职责）。
    """
    campaign = state.get("campaign_state")
    if not isinstance(campaign, dict) or not campaign.get("milestones"):
        from . import rules_fallback as rf
        return {"active": False, "phase": "", "milestone_id": "", "milestone_name": "",
                "build_order": tuple(rf.BUILD_LADDER), "allow_attack": True,
                "allow_expansion": True, "expand_probe": False, "produce_first": False,
                "probe_point": [], "model_branch": "", "suspended_objects": [],
                "blocked": [], "frontier_reason": "", "decision_lines": []}

    tick_value = int(tick if tick is not None else state.get("server_tick", 0) or 0)
    frontier = str(campaign.get("next_frontier", ""))
    spec = MILESTONES.get(frontier) or {}
    from . import decision_map
    from . import rules_fallback as rf

    phase = str(campaign.get("phase", PHASE_RECON))
    allow_attack = phase in (PHASE_PRESSURE, PHASE_CONVERGE)
    expand_probe = (frontier == M04 and not (campaign.get("expansion_candidates") or []))
    order_override: Tuple[str, ...] = ()
    # 模型的**分支选择**通过 `preferred_node` 生效；过期（默认 30s 无更新）自动失效，
    # 避免"一条早期选择永久盖住主线"。
    preferred = str(campaign.get("preferred_node") or "")
    fresh_window = int(campaign.get("preferred_node_tick", 0) or 0) + 1800
    if preferred and int(tick_value) > fresh_window:
        campaign["preferred_node"] = ""
        preferred = ""
    if preferred and preferred not in (campaign.get("decision_available") or []):
        preferred = ""
    if preferred:
        node = decision_map.resolve_branch(preferred)
        order_override = tuple(str(x) for x in (node.get("build_order") or ()))
        if str(node.get("id", "")) in ("D6", "D7"):
            expand_probe = not (campaign.get("expansion_candidates") or [])
        if str(node.get("id", "")) == "D12":
            allow_attack = True

    build_order = list(order_override)
    for item in (spec.get("build_order") or ()):
        if item not in build_order:
            build_order.append(item)
    # 其余建造项按默认阶梯补在后（保证"主线优先、其它不丢"）。
    for item in rf.BUILD_LADDER:
        if item not in build_order:
            build_order.append(item)
    entry = campaign["milestones"].get(frontier) or {}
    return {
        "active": True,
        "phase": phase,
        "milestone_id": frontier,
        "milestone_name": str(spec.get("name", "")),
        "build_order": tuple(build_order),
        # 施压/收束阶段才允许规则阶梯主动出击（手册：集结 → 前压 → 进攻）。
        "allow_attack": allow_attack,
        "allow_expansion": True,
        "expand_probe": expand_probe,
        # 【先补兵还是先扩建】由前沿节点决定（M03/M06/M07 = 兵力/施压 → True）。
        # 不做这个区分就会出现"永远还有下一座建筑可建 → 阶梯永远走不到生产级 → 整局 0 兵"。
        "produce_first": bool(spec.get("produce_first")),
        "probe_point": [float(x) for x in (campaign.get("expansion_probe") or [])][:2],
        "model_branch": preferred,
        "suspended_objects": [str(u) for u in (campaign.get("suspended_objects") or [])],
        "blocked": [str(x) for x in (campaign.get("blocked_milestones") or [])],
        "frontier_reason": str(entry.get("blocked_reason", "") or ""),
        "decision_lines": [str(x) for x in (campaign.get("decision_context") or [])],
    }


def context_view(campaign: Dict[str, Any], limit_milestones: int = 4) -> Dict[str, Any]:
    """给模型的**主线上下文**（纠偏 §"模型上下文必须包含"逐项对应）。

    只给"当前阶段 / 主线目标 / 已完成与阻塞里程碑 / 四条线任务 / 下一前沿"，
    不给整张里程碑表的原文（避免挤爆 2B 的输入预算）。
    """
    milestones = campaign.get("milestones") or {}
    done = [entry for entry in milestones.values() if str(entry.get("status")) == "done"]
    blocked = [entry for entry in milestones.values()
               if str(entry.get("status")) == "blocked"]
    pending = [entry for entry in milestones.values()
               if str(entry.get("status")) == "pending"]
    pending.sort(key=lambda item: int(item.get("priority", 0)))
    frontier = str(campaign.get("next_frontier", ""))
    frontier_entry = milestones.get(frontier) or {}
    tracks: Dict[str, Any] = {}
    for name in TRACKS:
        entry = (campaign.get("tracks") or {}).get(name) or {}
        current = entry.get("current") or {}
        tracks[name] = {
            "status": str(entry.get("status", "running")),
            "task": str(current.get("action", "")),
            "units": [str(u) for u in (current.get("units") or [])],
        }
    return {
        "phase": str(campaign.get("phase", "")),
        "mainline_id": str(campaign.get("mainline_id", "")),
        "mainline_version": int(campaign.get("mainline_version", 0) or 0),
        "frontier": frontier,
        "frontier_name": str(frontier_entry.get("name", "")),
        "frontier_expects": str((MILESTONES.get(frontier) or {}).get("success_evidence", "")),
        "done": [str(entry.get("id", "")) for entry in done],
        "done_names": [str(entry.get("name", "")) for entry in done],
        "blocked": [{"id": str(entry.get("id", "")), "name": str(entry.get("name", "")),
                     "reason": str(entry.get("blocked_reason", ""))[:60]}
                    for entry in blocked],
        "pending": [{"id": str(entry.get("id", "")), "name": str(entry.get("name", ""))}
                    for entry in pending[:limit_milestones]],
        "tracks": tracks,
        "interrupts": [{"kind": str(item.get("kind", "")),
                        "status": str(item.get("status", "")),
                        "units": [str(u) for u in (item.get("units") or [])]}
                       for item in (campaign.get("interrupt_stack") or [])][:4],
        "suspended": [str(u) for u in (campaign.get("suspended_objects") or [])][:8],
        "expansion_candidates": [list(item) for item in
                                 (campaign.get("expansion_candidates") or [])][:3],
        # 决策地图候选：`available_routes` = 模型**可以选**的分支 ref；
        # `decision_lines` = 已经排版好的一到两行（渲染层直接用，不重新推导）。
        "available_routes": [str(x) for x in (campaign.get("decision_available") or [])],
        "decision_lines": [str(x) for x in (campaign.get("decision_context") or [])],
    }


def summary(campaign: Dict[str, Any]) -> Dict[str, Any]:
    """诊断/日志视图（HUD 与验收报告都从这里读，避免两处口径分叉）。"""
    if not isinstance(campaign, dict):
        return {}
    milestones = campaign.get("milestones") or {}
    return {
        "phase": str(campaign.get("phase", "")),
        "mainline_id": str(campaign.get("mainline_id", "")),
        "mainline_version": int(campaign.get("mainline_version", 0) or 0),
        "branch": str(campaign.get("mainline_branch", "")),
        "branch_source": str(campaign.get("branch_source", "")),
        "frontier": str(campaign.get("next_frontier", "")),
        "frontier_name": str((MILESTONES.get(str(campaign.get("next_frontier", "")))
                              or {}).get("name", "")),
        "milestones": {key: str(value.get("status", ""))
                       for key, value in sorted(milestones.items())},
        "done": [key for key, value in sorted(milestones.items())
                 if str(value.get("status")) == "done"],
        "blocked": [{"id": key, "reason": str(value.get("blocked_reason", ""))[:60]}
                    for key, value in sorted(milestones.items())
                    if str(value.get("status")) == "blocked"
                    and str(value.get("done_tick", 0) or 0) == 0],
        "tracks": {name: str(((campaign.get("tracks") or {}).get(name) or {})
                             .get("status", "running")) for name in TRACKS},
        "interrupts": len([item for item in (campaign.get("interrupt_stack") or [])
                           if str(item.get("status")) == "active"]),
        "interrupt_total": int(campaign.get("interrupt_total", 0) or 0),
        "interrupt_resolved": int(campaign.get("interrupt_resolved", 0) or 0),
        "suspended_objects": list(campaign.get("suspended_objects") or []),
        "expansion_candidates": [list(item) for item in
                                 (campaign.get("expansion_candidates") or [])],
        # 前探点是**单个平面坐标**（不是坐标列表），别照 candidates 的样子套一层。
        "expansion_probe": [float(x) for x in (campaign.get("expansion_probe") or [])][:2],
        "updated_tick": int(campaign.get("updated_tick", 0) or 0),
    }


# ---------------------------------------------------------------------------
# 主入口：每 tick 推进整局主线
# ---------------------------------------------------------------------------


def update(state: Dict[str, Any], observation: Optional[Dict[str, Any]], tick: int
           ) -> Dict[str, Any]:
    """**每 tick** 推进 campaign_state（唯一入口）。

    顺序刻意固定：
      ① 建立/补齐 mainline（开局即默认主线）；
      ② 采集事实快照（观测 + 权威回执）；
      ③ 紧急事件入栈（不打断主线）→ 已处理的弹出并恢复；
      ④ 里程碑证据判定 → 完成推进 / 拒绝重试 / 停滞阻塞；
      ⑤ 四条 track 刷新（含挂起对象）；
      ⑥ 前沿与阶段重算；
      ⑦ 扩张候选与扩张前探点（供规则阶梯与模型上下文共用）。
    """
    campaign = ensure_campaign(state, tick=int(tick))
    # 本 tick 的变迁只统计这一轮（节点据此写 decision_log / 面板）。
    campaign["new_transitions"] = []
    campaign["resolved_interrupts"] = []
    facts = build_facts(state, observation, tick)
    tactical = (observation or {}).get("tactical")
    enemies_now = _living_enemies(tactical)
    # 敌方血量监视 → "施压"里程碑的**结果证据**（掉血，不是"发过命令"）。
    # 同一 tick 内 `update` 会被调用两次（开局推进 + 回执结算后补判），
    # 因此这里必须**按 tick 幂等**，否则掉血事件会被重复计数。
    if int(campaign.get("_damage_tick", -1)) != int(tick):
        campaign["_damage_tick"] = int(tick)
        watch = campaign.setdefault("enemy_hp_watch", {})
        damage_events = int(campaign.get("enemy_damage_events", 0) or 0)
        for entity in enemies_now:
            key = entity_id_of(entity)
            if not key:
                continue
            try:
                hp = float(entity.get("hp", 0) or 0)
            except (TypeError, ValueError):
                continue
            previous = watch.get(key)
            if previous is not None and hp < float(previous) - 0.5:
                damage_events += 1
            watch[key] = hp
        if len(watch) > 64:
            for key in list(watch.keys())[:-64]:
                watch.pop(key, None)
        campaign["enemy_damage_events"] = damage_events
        # 建筑损失 → "重建产能"（BLD-02）与里程碑返工的证据。
        previous_counts = campaign.get("_building_counts")
        if isinstance(previous_counts, dict):
            lost = [key for key, value in previous_counts.items()
                    if int(value or 0) > 0
                    and int(facts["counts"].get(key, 0)) < int(value or 0)]
            if lost:
                campaign["lost_buildings"] = sorted(set(
                    (campaign.get("lost_buildings") or []) + lost))
                campaign.setdefault("loss_log", []).append(
                    {"tick": int(tick), "lost": lost})
                del campaign["loss_log"][:-16]
        campaign["_building_counts"] = {
            key: int(value) for key, value in facts["counts"].items()
            if not key.isdigit()}

    # 敌人的位置（供"基地威胁"判定）：也走唯一解析层。
    facts["enemy_positions"] = [
        [round(_pos2d(e)[0], 1), round(_pos2d(e)[1], 1)] for e in enemies_now]

    # ③ 中断：先推进新事件，再结算可弹出的。
    for event in (observation or {}).get("events") or []:
        if not isinstance(event, dict):
            continue
        kind = str(event.get("kind", ""))
        if kind not in EMERGENCY_KINDS:
            continue
        units = _event_units(event)
        note_emergency(campaign, kind, int(event.get("server_tick", tick) or tick),
                       units=units, detail=str((event.get("payload") or {}).get("reason", "")))
        if kind == "base_under_attack":
            campaign["under_attack_total"] = int(
                campaign.get("under_attack_total", 0) or 0) + 1
        if kind in ("formation_loss", "target_dead"):
            campaign["combat_loss_events"] = int(
                campaign.get("combat_loss_events", 0) or 0) + 1
    resolved = resolve_interrupts(campaign, facts, tick)

    # ④ 里程碑证据与推进（**循环到不动点**：后一个里程碑可能在同一 tick 就满足）。
    for _ in range(len(MILESTONE_ORDER) + 1):
        progressed = False
        for milestone_id in MILESTONE_ORDER:
            entry = campaign["milestones"][milestone_id]
            if str(entry.get("status")) == "done":
                continue
            evaluator = EVIDENCE.get(milestone_id)
            if evaluator is None:
                continue
            try:
                ok, detail = evaluator(facts, campaign)
            except Exception as exc:  # noqa: BLE001 —— 证据判定失败绝不允许拖垮主线
                ok, detail = False, "证据判定异常：%s" % str(exc)[:80]
            entry["last_evidence"] = str(detail)[:160]
            entry["updated_tick"] = int(tick)
            if ok:
                _advance_milestone(campaign, milestone_id, tick, detail)
                progressed = True
        if not progressed:
            break
    _note_rejections(campaign, facts, tick)

    # ⑤ 四条 track。
    _refresh_tracks(campaign, state, tick)

    # ⑥ 前沿与阶段。
    previous_phase = str(campaign.get("phase", PHASE_RECON))
    _recompute_frontier(campaign, facts, tick)
    _stall_check(campaign, facts, tick)
    frontier_after = str(campaign.get("next_frontier", ""))
    if str(campaign["milestones"].get(frontier_after, {}).get("status")) == "blocked":
        _recompute_frontier(campaign, facts, tick)
    phase = _phase_of(campaign)
    if phase != previous_phase:
        campaign["phase"] = phase
        campaign["phase_changed_tick"] = int(tick)
        history = campaign.setdefault("phase_history", [])
        history.append({"phase": phase, "tick": int(tick)})
        del history[:-16]
        _transition(campaign, kind="phase", id=phase, tick=int(tick),
                    **{"from": previous_phase})

    # ⑦ 扩张候选与前探点。
    #    经济恢复（ECO-02）的判据：刚处理完基地受袭且工人不足目标 → 需要恢复。
    campaign["needs_recovery"] = bool(
        int(campaign.get("under_attack_total", 0) or 0) > 0
        and int(campaign["milestones"].get(M01, {}).get("status", "") != "done")
        and len(facts.get("workers") or []) < 2)
    try:
        candidates = _expansion_candidates(state, facts, campaign, tactical)
    except Exception:  # noqa: BLE001 —— 扩张选址失败不影响主线推进
        candidates = []
    campaign["expansion_candidates"] = candidates
    # 前探点**只在"扩张选址"是前沿**时给：其它阶段把侦察单位调去矿区方向是浪费
    # （虽然无害，但会让"当前该干什么"的语义变混）。
    campaign["expansion_probe"] = (
        [] if candidates or str(campaign.get("next_frontier", "")) != M04
        else _expansion_probe(state, facts))

    # ⑧ 决策地图检索（**每 tick 一次**，唯一入口）：可用节点 = 模型可选的路线候选；
    #    不可用节点连同"缺什么"一起进上下文 —— 这就是纠偏要求的
    #    "可选决策地图节点及其前置条件"。
    try:
        from . import decision_map
        retrieved = decision_map.retrieve(facts, campaign)
        campaign["decision_available"] = [str(item["id"])
                                         for item in retrieved.get("available") or []]
        campaign["decision_locked"] = [
            {"id": str(item["id"]), "name": str(item["name"]),
             "unmet": [str(x) for x in item.get("unmet") or []]}
            for item in retrieved.get("locked") or []]
        campaign["decision_context"] = decision_map.context_lines(retrieved)
    except Exception as exc:  # noqa: BLE001 —— 决策地图检索失败不影响主线推进
        campaign["decision_available"] = []
        campaign["decision_locked"] = []
        campaign["decision_context"] = ["决策地图检索失败：%s" % str(exc)[:60]]

    campaign["_facts"] = _facts_signature(facts)

    campaign["updated_tick"] = int(tick)
    campaign["resolved_interrupts"] = [
        {"kind": str(item.get("kind", "")), "resolution": str(item.get("resolution", "")),
         "units": [str(u) for u in (item.get("units") or [])]}
        for item in resolved]
    state["campaign_state"] = campaign
    return campaign


def _facts_signature(facts: Dict[str, Any]) -> Dict[str, Any]:
    """留在 campaign 里的**最小事实签名**（供分支选择时校验前置条件）。

    刻意只留标量与短列表：完整 facts 里含坐标数组，进 checkpoint 会明显变大，
    而分支校验只需要"哪些里程碑已完成、有没有工人在采集"这类单步判据。
    """
    return {
        "tick": int(facts.get("tick", 0)),
        "combat_count": int(facts.get("combat_count", 0)),
        "workers": list(facts.get("workers") or [])[:8],
        "resource_count": int(facts.get("resource_count", 0)),
        "far_resources": [list(item) for item in (facts.get("far_resources") or [])][:8],
        "enemy_intel_count": int(facts.get("enemy_intel_count", 0)),
    }


EMERGENCY_KINDS: Tuple[str, ...] = ("base_under_attack", "enemy_spotted",
                                    "formation_loss", "path_failed", "target_dead")


def _event_units(event: Dict[str, Any]) -> List[str]:
    payload = event.get("payload") or {}
    subject = payload.get("subject", "")
    if isinstance(subject, str):
        return [item.strip() for item in subject.split(",") if item.strip()]
    if isinstance(subject, (list, tuple)):
        return [str(item) for item in subject if str(item)]
    return []


__all__ = [
    "PHASES", "PHASE_RECON", "PHASE_FOOTHOLD", "PHASE_EXPAND", "PHASE_PRESSURE",
    "PHASE_CONVERGE", "TRACKS", "TRACK_ECONOMY", "TRACK_BUILD", "TRACK_SCOUT",
    "TRACK_MILITARY", "TRACK_TITLE_CN", "MAINLINE_ID", "MAINLINE_VERSION",
    "MILESTONES", "MILESTONE_ORDER", "M01", "M02", "M03", "M04", "M05", "M06", "M07",
    "EVIDENCE", "EMERGENCY_KINDS", "build_facts", "context_view", "default_campaign",
    "ensure_campaign", "frontier_preferences", "note_emergency", "note_model_branch",
    "note_player_override", "note_player_release", "resolve_interrupts", "summary",
    "track_of_action", "update",
]
