# -*- coding: utf-8 -*-
"""经济恢复入口与恢复计划（第一阶段 · 修改 3：修正经济恢复入口与里程碑）。

## 要解决的问题（旧样本实测）

374 份已保存的调用上下文里，D2「经济恢复」可选 **0** 次：旧入口
`needs_recovery = under_attack_total > 0 AND M01 != done AND worker_count < 2`
把"6 工人、M01 done、矿场任务失败、零交货"的局永久挡在恢复之外——经济链明明
断了，却因为没有受袭而进不了诊断。

## 本模块的判据（全部可测试、可回放）

异常入口 = **证据 + 时间窗**，不靠单一事件：

| 种类 | 判据 | 时间窗 |
|---|---|---|
| `attack_recovery` | 受袭>0 且 M01 未完成且工人<2（**原条件原样保留**） | 无 |
| `key_econ_task_failed` | 关键经济任务（矿场/车厂/矿车）失败或被内容类拒绝，或闭环台账里 M01/M02/M08 目标 at_risk/blocked | 无（失败是事实） |
| `delivery_stall` | 矿场已完工但交付计数长期为 0 且无施工进展 | `delivery_stall_seconds`（默认 90s） |
| `post_delivery_stall` | 曾交货，随后交付计数与余额长期不变且无施工进展 | `post_delivery_stall_seconds`（默认 120s） |
| `econ_unit_loss` | 工人数掉到 2 以下（不论是否受袭） | 开局宽限 `grace_seconds`（默认 60s） |
| `econ_facility_loss` | 矿场数量相对上一记录值减少（被毁） | 开局宽限 |

玩法事实（2026-10-15 核验，`CollectingResourcesSequentially.find_drop_off`）：
**指挥中心不是交货点；唯一交货点是已完工矿场**。因此"没有任何可用矿场时
满车持货、不回主基地"——收入链的前提是矿场，这一点按事实使用，但不把某种
建筑一概设为所有经济状态的前提（判据走证据，不走假设）。

## 恢复 ≠ 入口

- 入口（`needs_recovery`）：经济异常**可能存在**，需要诊断/恢复评估；
- 可执行（`recovery_plan.executable`）：现在就有合法动作（有工人/建造者/
  资金/可见资源/路径可达）。零工人、资金不足、无建造者、无可见资源、
  路径不可达时给出**实际缺项**与可行替代（如先侦察找矿），或明确受阻——
  不为了开放 D2 绕过资源/权限/单位前提，也不把所有异常映射到同一动作。
"""

from __future__ import annotations

import time
from typing import Any, Dict, List, Optional, Tuple

from . import task_loop as task_loop_mod

# ---- 异常种类 ----
ANOMALY_ATTACK = "attack_recovery"
ANOMALY_TASK_FAILED = "key_econ_task_failed"
ANOMALY_DELIVERY_STALL = "delivery_stall"
ANOMALY_POST_DELIVERY_STALL = "post_delivery_stall"
ANOMALY_UNIT_LOSS = "econ_unit_loss"
ANOMALY_FACILITY_LOSS = "econ_facility_loss"

ANOMALY_CN: Dict[str, str] = {
    ANOMALY_ATTACK: "受袭后经济恢复（原条件保留）",
    ANOMALY_TASK_FAILED: "关键经济任务失败",
    ANOMALY_DELIVERY_STALL: "矿场已完工但长期零交付且无进展",
    ANOMALY_POST_DELIVERY_STALL: "曾交货后经济链中断（交付与余额长期不变）",
    ANOMALY_UNIT_LOSS: "经济执行单位损失（工人不足）",
    ANOMALY_FACILITY_LOSS: "关键经济设施损失（矿场减少）",
}

# ---- 时间窗（秒；按实测 tick 率换算；0=用默认）----
DEFAULT_DELIVERY_STALL_SECONDS = 90.0
DEFAULT_POST_DELIVERY_STALL_SECONDS = 120.0
#: 开局宽限：首次建造/首次交货的正常等待不得因"初始交货为 0"立刻判失败。
DEFAULT_GRACE_SECONDS = 60.0

#: 工人数下限：低于它算"执行单位不足"（与旧条件的 <2 同口径）。
WORKER_FLOOR = 2

#: 关键经济目标（这些目标失败 = 经济异常，不论是否受袭）。
KEY_ECON_GOALS = ("M01", "M02", "M08")

#: 关键经济任务的意图前缀（内容类拒绝 = 这条路走不通）。
KEY_ECON_PREFIXES = ("rule-build-ore_refinery", "rule-build-vehicle_factory",
                     "rule-produce-worker", "rule-gather")

#: campaign 里记住的经济基线键（跨轮比较"有没有变化"用）。
_MEM_KEYS = ("last_worker_count", "last_refinery_count", "last_refinery_constructed",
             "last_delivered", "last_balance", "last_construction_signature",
             "delivery_stall_since", "post_delivery_stall_since", "anomaly_since",
             "_econ_tick", "_econ_grace_until_tick")


def _as_int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _seconds_to_ticks(seconds: float, tick_hz: float) -> int:
    return task_loop_mod.seconds_to_ticks(seconds, tick_hz)


def _config_seconds(config: Optional[Dict[str, Any]], key: str, default: float) -> float:
    """0/负值 = 用默认（与 task_loop 同一语义：0 不是"1 秒"）。"""
    cfg = config or {}
    try:
        value = float(cfg.get(key, 0) or 0)
    except (TypeError, ValueError):
        value = 0.0
    return value if value > 0 else float(default)


def _construction_signature(facts: Dict[str, Any]) -> str:
    """施工进展签名：完工/工地计数变了就算"有进展"（防止把在建当成停滞）。"""
    constructed = facts.get("constructed") or {}
    counts = facts.get("counts") or {}
    return "%s|%s" % (json_key(constructed), json_key(counts))


def json_key(mapping: Any) -> str:
    import json
    try:
        return json.dumps(mapping, sort_keys=True, ensure_ascii=False, default=str)
    except (TypeError, ValueError):
        return "?"


def detect(campaign: Dict[str, Any], facts: Dict[str, Any], *, state: Dict[str, Any],
           tick: int, config: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """评估经济异常（每 tick 一次，按 tick 幂等）。

    返回结构（全部字段可回放）：
    `active / kind / kinds / reasons_cn / evidence / since_tick / window_ticks`。
    """
    cfg = config or {}
    tick_hz = float(state.get("measured_tick_hz", 0) or 0)
    tick = _as_int(tick)
    if _as_int(campaign.get("_econ_tick"), -1) == tick:
        # 同一 tick 的二次调用（update + advance）不重复记基线。
        return campaign.get("economy_anomaly") or _empty_anomaly()
    campaign["_econ_tick"] = tick

    workers = facts.get("workers") or []
    worker_count = len(workers) if isinstance(workers, (list, tuple)) else 0
    delivered = facts.get("refinery_delivered")
    delivered = None if delivered is None else _as_int(delivered)
    built = _as_int(facts.get("refinery_constructed"))
    refinery_count = _as_int((facts.get("counts") or {}).get("ore_refinery"))
    balance = facts.get("balance") or {}
    construction = _construction_signature(facts)

    # 开局宽限：从对局开始（campaign.created_tick）算一段正常起步时间。
    created = _as_int(campaign.get("created_tick"))
    grace_ticks = _seconds_to_ticks(_config_seconds(cfg, "econ_grace_seconds",
                                                    DEFAULT_GRACE_SECONDS), tick_hz)
    if not _as_int(campaign.get("_econ_grace_until_tick")):
        campaign["_econ_grace_until_tick"] = created + grace_ticks
    in_grace = tick < _as_int(campaign.get("_econ_grace_until_tick"))

    evidence: Dict[str, Any] = {
        "workers": worker_count, "refinery_constructed": built,
        "refinery_count": refinery_count, "refinery_delivered": delivered,
        "balance": balance, "in_grace": in_grace,
    }
    kinds: List[str] = []
    reasons: List[str] = []

    # ① 原条件（受袭后恢复）——原样保留，作为 OR 项之一。
    under_attack = _as_int(campaign.get("under_attack_total"))
    m01_status = str((campaign.get("milestones") or {}).get("M01", {}).get("status", ""))
    if under_attack > 0 and m01_status != "done" and worker_count < WORKER_FLOOR:
        kinds.append(ANOMALY_ATTACK)
        reasons.append("受袭 %d 次且 M01 未完成且工人 %d<%d" % (
            under_attack, worker_count, WORKER_FLOOR))
    evidence["under_attack_total"] = under_attack
    evidence["m01_status"] = m01_status

    # ② 关键经济任务失败（不依赖受袭）。
    task_failed, task_reason = _key_task_failure(campaign, state, facts)
    if task_failed:
        kinds.append(ANOMALY_TASK_FAILED)
        reasons.append(task_reason)
    evidence["key_task_failure"] = task_reason or ""

    # ③ 交付停滞（矿场已完工、零交付、无施工进展）。
    stall_ticks = _seconds_to_ticks(_config_seconds(cfg, "econ_delivery_stall_seconds",
                                                    DEFAULT_DELIVERY_STALL_SECONDS), tick_hz)
    if built > 0 and delivered == 0 and not in_grace:
        since = _as_int(campaign.get("delivery_stall_since"))
        if not since:
            campaign["delivery_stall_since"] = tick
            since = tick
        if construction != str(campaign.get("last_construction_signature", "")):
            # 施工在动 → 刷新起点（正常等待，不是停滞）。
            campaign["delivery_stall_since"] = tick
            since = tick
        if tick - since >= stall_ticks:
            kinds.append(ANOMALY_DELIVERY_STALL)
            reasons.append("矿场已完工 %d 座但交付 0 次且无施工进展已 %d tick（超 %d）" % (
                built, tick - since, stall_ticks))
        evidence["delivery_stall_ticks"] = tick - since
    else:
        campaign["delivery_stall_since"] = 0
        evidence["delivery_stall_ticks"] = 0

    # ④ 曾交货后中断（健康状态退化为异常；历史 done 不屏蔽）。
    # 【R6 返修】"没有变化"只比**交货数与施工进展**，不比的余额：
    # 收入链的健康证据是交付/入账，余额同时受支出影响（持续生产花钱会把
    # 收入中断洗成"有变化"——独立复核对照：每次花 100，五轮全无异常）。
    post_ticks = _seconds_to_ticks(_config_seconds(cfg, "econ_post_delivery_stall_seconds",
                                                   DEFAULT_POST_DELIVERY_STALL_SECONDS),
                                   tick_hz)
    if delivered and delivered > 0 and not in_grace:
        since = _as_int(campaign.get("post_delivery_stall_since"))
        unchanged = (delivered == _as_int(campaign.get("last_delivered"))
                     and construction == str(campaign.get("last_construction_signature", "")))
        if unchanged:
            if not since:
                campaign["post_delivery_stall_since"] = tick
                since = tick
            if tick - since >= post_ticks:
                kinds.append(ANOMALY_POST_DELIVERY_STALL)
                reasons.append("曾交货 %d 次，但交付与施工已 %d tick 无变化（超 %d）" % (
                    delivered, tick - since, post_ticks))
            evidence["post_delivery_stall_ticks"] = tick - since
        else:
            campaign["post_delivery_stall_since"] = 0
            evidence["post_delivery_stall_ticks"] = 0
    else:
        campaign["post_delivery_stall_since"] = 0

    # ⑤ 执行单位损失（不论是否受袭；宽限内不判）。
    # 【R5 返修】损失是**持续状态**，不是"下降沿事件"：工人数低于下限即激活，
    # 恢复到下限才解除。旧实现只在本轮数量下降的那一轮报异常，下一轮数量
    # 不再下降就解除（独立复核反例：6→0→0，第三轮回到 inactive 但仍是 0 工人）。
    previous_workers = campaign.get("last_worker_count")
    unit_loss_active = bool(campaign.get("unit_loss_active"))
    if worker_count < WORKER_FLOOR and not in_grace:
        if not unit_loss_active:
            campaign["unit_loss_since"] = tick
        campaign["unit_loss_active"] = True
        unit_loss_active = True
    elif worker_count >= WORKER_FLOOR:
        # 恢复条件达成（工人回到下限）→ 解除并清起点。
        campaign["unit_loss_active"] = False
        campaign["unit_loss_since"] = 0
        unit_loss_active = False
    if unit_loss_active:
        since = _as_int(campaign.get("unit_loss_since")) or tick
        kinds.append(ANOMALY_UNIT_LOSS)
        reasons.append("工人数 %d 低于 %d 已持续 %d tick（未恢复）" % (
            worker_count, WORKER_FLOOR, tick - since))
    evidence["previous_workers"] = previous_workers

    # ⑥ 经济设施损失（矿场数量减少）——同为持续状态：有矿场才算恢复。
    previous_refinery = campaign.get("last_refinery_count")
    facility_loss_active = bool(campaign.get("facility_loss_active"))
    if refinery_count <= 0 and _as_int(campaign.get("last_refinery_count")) is not None \
            and _as_int(campaign.get("last_refinery_count")) > 0 and not in_grace:
        if not facility_loss_active:
            campaign["facility_loss_since"] = tick
        campaign["facility_loss_active"] = True
        facility_loss_active = True
    elif refinery_count > 0:
        campaign["facility_loss_active"] = False
        campaign["facility_loss_since"] = 0
        facility_loss_active = False
    if facility_loss_active:
        since = _as_int(campaign.get("facility_loss_since")) or tick
        kinds.append(ANOMALY_FACILITY_LOSS)
        reasons.append("矿场数量为 0（原有矿场损失）已持续 %d tick（未恢复）" % (tick - since))
    evidence["previous_refinery_count"] = previous_refinery

    # ⑦ 基线记忆（供下一轮比较；只记标量，不进大对象）。
    campaign["last_worker_count"] = worker_count
    campaign["last_refinery_count"] = refinery_count
    campaign["last_delivered"] = delivered if delivered is not None else 0
    campaign["last_balance"] = json_key(balance)
    campaign["last_construction_signature"] = construction

    active = bool(kinds)
    anomaly = {
        "active": active,
        "kind": kinds[0] if kinds else "",
        "kinds": kinds,
        "reasons_cn": reasons,
        "evidence": evidence,
        "since_tick": _as_int(campaign.get("anomaly_since")) or (tick if active else 0),
        "window_ticks": {"delivery_stall": stall_ticks, "post_delivery_stall": post_ticks,
                         "grace": grace_ticks},
    }
    if active:
        if not _as_int(campaign.get("anomaly_since")):
            campaign["anomaly_since"] = tick
            anomaly["since_tick"] = tick
    else:
        campaign["anomaly_since"] = 0
    campaign["economy_anomaly"] = anomaly
    campaign["needs_recovery"] = bool(anomaly.get("active"))
    campaign["needs_recovery_attack"] = bool(ANOMALY_ATTACK in kinds)
    return anomaly


def _empty_anomaly() -> Dict[str, Any]:
    return {"active": False, "kind": "", "kinds": [], "reasons_cn": [],
            "evidence": {}, "since_tick": 0, "window_ticks": {}}


def _key_task_failure(campaign: Dict[str, Any], state: Dict[str, Any],
                      facts: Dict[str, Any]) -> Tuple[bool, str]:
    """关键经济任务失败证据：内容类拒绝 / 闭环台账目标反馈 / 里程碑阻塞。

    内容类拒绝（契约/能力不匹配）才算"这条路走不通"；几何类（越界/占用/视野）
    是"换个点就行"，不触发经济异常（既有纪律，见 campaign.build_facts 注释）。

    闭环台账的反馈状态里，`diagnosing` / `recovering` 也算失败证据：任务已经
    沿 failure/timeout/no_progress 边进了诊断（或正在按预算恢复），经济链
    客观上仍处于断裂状态——不能因为"系统正在自理"就当作没有异常
    （round-03 真机闸门实测：矿场任务 56 次无进展 + 3 次恢复尝试，
     反馈长期停在 diagnosing，旧判据漏报）。
    """
    # (a) 内容类拒绝：关键经济意图前缀被权威端按内容拒绝。
    content_rejected = facts.get("content_rejected_prefixes") or {}
    for prefix in KEY_ECON_PREFIXES:
        count = _as_int(content_rejected.get(prefix))
        if count > 0:
            return True, "关键经济命令 %s 被内容类拒绝 %d 次（换点无用，需换方案）" % (
                prefix, count)
    # (b) 闭环台账的目标反馈（修改 2 的失败/受阻/诊断/恢复 → 上层目标）。
    feedback = state.get("task_ledger_feedback") or {}
    failure_states = ("at_risk", "blocked", "diagnosing", "recovering")
    state_cn = {"at_risk": "失败/超时", "blocked": "受阻", "diagnosing": "诊断中",
                "recovering": "恢复尝试中"}
    for goal in KEY_ECON_GOALS:
        entry = feedback.get(goal)
        if isinstance(entry, dict) and str(entry.get("state")) in failure_states:
            return True, "目标 %s 的任务%s（%s）" % (
                goal, state_cn.get(str(entry.get("state")), "异常"),
                str(entry.get("reason_cn", ""))[:60])
    # (c) 里程碑自己记的阻塞原因（_stall_check/_block_milestone 写）。
    milestones = campaign.get("milestones") or {}
    for goal in KEY_ECON_GOALS:
        entry = milestones.get(goal) or {}
        if str(entry.get("status")) == "blocked" and str(entry.get("blocked_reason", "")):
            return True, "目标 %s 已阻塞：%s" % (goal, str(entry.get("blocked_reason"))[:60])
    return False, ""


# ---------------------------------------------------------------------------
# 恢复计划：入口开放 ≠ 动作可执行
# ---------------------------------------------------------------------------


def recovery_plan(campaign: Dict[str, Any], facts: Dict[str, Any], *,
                  state: Dict[str, Any], config: Optional[Dict[str, Any]] = None
                  ) -> Dict[str, Any]:
    """按异常种类给出**可执行**的恢复动作 / 缺项 / 替代路线。

    动作是**建议**（给规则层与模型菜单的同一份结构）：执行仍走既有仲裁门禁
    （合法性/资源/预留/去重），本模块不绕过任何前提。
    """
    anomaly = campaign.get("economy_anomaly") or _empty_anomaly()
    entry_open = bool(anomaly.get("active"))
    kind = str(anomaly.get("kind", ""))
    workers = facts.get("workers") or []
    worker_count = len(workers) if isinstance(workers, (list, tuple)) else 0
    builders = facts.get("builders") or []
    built = _as_int(facts.get("refinery_constructed"))
    resource_count = _as_int(facts.get("resource_count"))
    balance = facts.get("balance") or {}
    funds = _as_int((balance or {}).get("A", (balance or {}).get("a", 0)))

    actions: List[Dict[str, Any]] = []
    blocked: List[str] = []

    def add(action: str, skill: str, target: str, reason_cn: str, *,
            preconditions_met: bool, missing: List[str]) -> None:
        actions.append({"action": action, "skill": skill, "target": target,
                        "reason_cn": reason_cn, "preconditions_met": preconditions_met,
                        "missing": missing})
        if not preconditions_met:
            blocked.extend(missing)

    if kind in (ANOMALY_DELIVERY_STALL, ANOMALY_POST_DELIVERY_STALL):
        # 矿场在但没有交付：把工人派到矿场服务范围内的矿点（GAT）。
        missing = []
        if worker_count <= 0:
            missing.append("没有工人可分配")
        if resource_count <= 0:
            missing.append("没有可见资源点：先侦察（SCT）")
        add("assign_gather", "GAT", "resource",
            "矿场已完工但无交付：把工人分配到矿点并往返交货",
            preconditions_met=bool(worker_count > 0 and resource_count > 0),
            missing=missing)
        if not worker_count:
            add("produce_worker", "PROD", "product",
                "零工人：若有产能建筑则生产工人，否则受阻",
                preconditions_met=bool(facts.get("producers")),
                missing=[] if facts.get("producers") else ["没有可生产的设施"])
    elif kind == ANOMALY_TASK_FAILED:
        missing = []
        if not builders:
            missing.append("没有可建造的工人")
        if funds <= 0:
            missing.append("资金不足（余额 %d）" % funds)
        # 建造退避中（连续被拒的换点重试窗口）：此时重建动作同样不可执行——
        # 退避是既有机制对"这片地形不可建"的响应，恢复计划必须尊重它。
        backoff_until = _as_int(state.get("build_backoff_until_tick"))
        current_tick = _as_int(state.get("server_tick"))
        in_backoff = backoff_until > 0 and current_tick < backoff_until
        if in_backoff:
            missing.append("建造退避中（连续被拒，至 tick %d）" % backoff_until)
        add("rebuild_refinery", "BLD", "ore_refinery",
            "矿场/车厂任务失败：重验建造者与资金后重建（受重试预算约束）",
            preconditions_met=bool(builders) and funds > 0 and not in_backoff,
            missing=missing)
        if not builders and worker_count <= 0:
            add("scout_for_resource", "SCT", "location",
                "无工人且无建造者：先侦察确认资源与路线，保持受阻记录",
                preconditions_met=False, missing=["没有可执行单位"])
    elif kind == ANOMALY_UNIT_LOSS:
        missing = []
        if worker_count <= 0:
            missing.append("零工人：需要先生产或等待增援")
        if resource_count <= 0:
            missing.append("没有可见资源点：先侦察（SCT）")
        add("regather_remaining", "GAT", "resource",
            "工人不足：把剩余工人派往矿点，保持最低采集",
            preconditions_met=bool(worker_count > 0 and resource_count > 0),
            missing=missing)
        if worker_count <= 0:
            add("produce_worker", "PROD", "product",
                "零工人：若有产能建筑则生产工人，否则受阻",
                preconditions_met=bool(facts.get("producers")),
                missing=[] if facts.get("producers") else ["没有可生产的设施"])
    elif kind == ANOMALY_FACILITY_LOSS:
        missing = []
        if not builders:
            missing.append("没有可建造的工人")
        if funds <= 0:
            missing.append("资金不足（余额 %d）" % funds)
        add("rebuild_refinery", "BLD", "ore_refinery",
            "矿场被毁：重建（BLD-02 语义），前置与预算重验",
            preconditions_met=bool(builders) and funds > 0,
            missing=missing)
    elif kind == ANOMALY_ATTACK:
        add("defend_and_regather", "DEF", "anchor",
            "受袭后先防守，再恢复采集（保留原恢复场景行为）",
            preconditions_met=bool(worker_count > 0),
            missing=[] if worker_count > 0 else ["没有工人"])
    executable = bool(actions) and any(item["preconditions_met"] for item in actions)
    return {
        "entry_open": entry_open,
        "anomaly_kind": kind,
        "anomaly_reasons": list(anomaly.get("reasons_cn") or []),
        "executable": executable,
        "actions": actions,
        "blocked_missing": sorted(set(blocked)),
        "blocked_reason": "" if executable else (
            "经济异常已识别，但当前没有可执行恢复动作：缺 %s" %
            "/".join(sorted(set(blocked))) if blocked else "经济异常已识别，等待条件变化"),
        "updated_tick": _as_int((campaign.get("milestones") or {}).get(
            "M01", {}).get("updated_tick", 0)),
    }


def context_lines(plan: Dict[str, Any]) -> List[str]:
    """模型上下文的一到两行（2B 预算只够这个粒度；结构明细在追踪里）。"""
    if not plan.get("entry_open"):
        return []
    lines = ["经济异常: " + "/".join(plan.get("anomaly_reasons") or [])[:80]]
    executable = [item for item in plan.get("actions") or []
                  if item.get("preconditions_met")]
    if executable:
        lines.append("可执行恢复: " + " ".join(
            "%s->%s" % (item["skill"], item["target"]) for item in executable[:3]))
    elif plan.get("blocked_missing"):
        lines.append("恢复受阻(缺): " + "/".join(plan["blocked_missing"][:3]))
    return lines


def record_anomaly_trace(ctx: Any, state: Dict[str, Any], campaign: Dict[str, Any],
                         tick: int) -> None:
    """把经济异常评估写进追踪（入口条件逐项值 + 异常激活/解除 + 恢复计划）。

    与 decision_map 的 candidate_eval 同一纪律：判据是程序真值，中文解释只是
    展示层；异常从无到有/从有到无都留事件（回放要能看到"何时进入、为何解除"）。
    """
    recorder = getattr(ctx.services, "trace", None)
    if recorder is None:
        return
    anomaly = campaign.get("economy_anomaly") or _empty_anomaly()
    evidence = anomaly.get("evidence") or {}
    previous_active = bool(campaign.get("_econ_prev_active"))
    active = bool(anomaly.get("active"))
    try:
        if active != previous_active:
            recorder.note(
                "economy_anomaly_" + ("activated" if active else "cleared"),
                kinds=list(anomaly.get("kinds") or []),
                reasons_cn=list(anomaly.get("reasons_cn") or []),
                since_tick=_as_int(anomaly.get("since_tick")),
                server_tick=tick,
                reason_cn=("；".join(anomaly.get("reasons_cn") or [])[:200]
                           if active else "经济异常解除：恢复证据已出现"))
        # 候选入口条件逐项值（D2 的 needs_recovery 展开）。
        conditions = [
            {"name": "under_attack_total", "text": "本局受袭次数",
             "value": _as_int(evidence.get("under_attack_total")),
             "result": _as_int(evidence.get("under_attack_total")) > 0,
             "missing": _as_int(evidence.get("under_attack_total")) <= 0, "error": ""},
            {"name": "m01_status", "text": "M01 状态",
             "value": str(evidence.get("m01_status", "")),
             "result": str(evidence.get("m01_status", "")) != "done",
             "missing": str(evidence.get("m01_status", "")) == "done", "error": ""},
            {"name": "worker_count", "text": "工人数",
             "value": _as_int(evidence.get("workers")),
             "result": _as_int(evidence.get("workers")) < WORKER_FLOOR,
             "missing": _as_int(evidence.get("workers")) >= WORKER_FLOOR, "error": ""},
            {"name": "refinery_constructed", "text": "已完工矿场",
             "value": _as_int(evidence.get("refinery_constructed")),
             "result": _as_int(evidence.get("refinery_constructed")) > 0,
             "missing": _as_int(evidence.get("refinery_constructed")) <= 0, "error": ""},
            {"name": "refinery_delivered", "text": "累计交货次数",
             "value": evidence.get("refinery_delivered"),
             "result": (evidence.get("refinery_delivered") or 0) > 0
             if isinstance(evidence.get("refinery_delivered"), int) else None,
             "missing": (evidence.get("refinery_delivered") or 0) <= 0
             if isinstance(evidence.get("refinery_delivered"), int) else True,
             "error": "" if isinstance(evidence.get("refinery_delivered"), int)
             else "观测缺少交付统计"},
            {"name": "key_task_failure", "text": "关键经济任务失败",
             "value": str(evidence.get("key_task_failure", "")),
             "result": bool(evidence.get("key_task_failure")),
             "missing": not bool(evidence.get("key_task_failure")), "error": ""},
        ]
        recorder.candidate_eval(
            "D2", "经济恢复入口", conditions=conditions, available=active,
            reason_code="economy_anomaly:%s" % (anomaly.get("kind") or "none"),
            reason_cn=("；".join(anomaly.get("reasons_cn") or [])[:120] or "经济健康"),
            server_tick=tick)
        # 恢复计划（入口开放 ≠ 可执行）。
        facts = _facts_for_plan(campaign)
        plan = recovery_plan(campaign, facts, state=state)
        if plan.get("entry_open"):
            recorder.note("economy_recovery_plan",
                          executable=bool(plan.get("executable")),
                          actions=[item["action"] for item in plan.get("actions") or []],
                          blocked_missing=list(plan.get("blocked_missing") or []),
                          server_tick=tick,
                          reason_cn=str(plan.get("blocked_reason", ""))[:200]
                          or "恢复动作可执行")
        campaign["_econ_prev_active"] = active
    except Exception:  # noqa: BLE001 —— 旁路追踪永不拖垮主线
        pass


def _facts_for_plan(campaign: Dict[str, Any]) -> Dict[str, Any]:
    """恢复计划用的最小事实（campaign 每轮留存的经济子集；缺项按 unknown 处理）。"""
    facts = campaign.get("_econ_facts") if isinstance(campaign.get("_econ_facts"), dict) else {}
    return {
        "workers": list(facts.get("workers") or []),
        "builders": list(facts.get("builders") or []),
        "producers": list(facts.get("producers") or []),
        "resource_count": _as_int(facts.get("resource_count")),
        "refinery_constructed": _as_int(facts.get("refinery_constructed")),
        "balance": dict(facts.get("balance") or {}),
    }


__all__ = [
    "ANOMALY_ATTACK", "ANOMALY_TASK_FAILED", "ANOMALY_DELIVERY_STALL",
    "ANOMALY_POST_DELIVERY_STALL", "ANOMALY_UNIT_LOSS", "ANOMALY_FACILITY_LOSS",
    "ANOMALY_CN", "KEY_ECON_GOALS", "WORKER_FLOOR", "detect", "recovery_plan",
    "context_lines", "record_anomaly_trace",
]
