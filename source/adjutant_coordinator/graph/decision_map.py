# -*- coding: utf-8 -*-
"""决策地图：把策划手册的经济 / 侦察 / 军事章节编译成**运行时节点**。

## 为什么不是"提示词参考"

纠偏文档（`docs/程序文档/AI副官_长期主线与决策地图接入纠偏_2026-09-12.md`）明确要求：

> 把 `docs/策划文档/AI副官决策手册/01-总则与决策地图.md` 及其经济建造、侦察、军事
> 章节接入运行时。不要让模型每轮重新发明整局计划，也不要把 Markdown 原文塞进每次 prompt。

所以本模块做的是**编译**，不是搬运：

| 手册原文 | 运行时形态 |
|---|---|
| `ECO-01 开工摸底` 的「适用条件」 | `PRECONDITIONS` 里的可判定谓词（如 `has_worker`） |
| 「可选任务」 | `candidates`（技能 + 目标类别的**结构**，不是自然语言） |
| 「成功证据 / 失败分支 / 退出条件」 | `success` / `failure` / `exit` 文本（进日志与面板，不进提示词） |
| 章节之间的先后关系 | `milestone`（挂到 `campaign.MILESTONES` 的哪个节点）与 `priority` |

运行时每 tick 用**观测事实**求值全部前置条件，得到：

- `available`：当前**可以选**的决策地图节点（模型只在这张表里选，不能自造）；
- `locked`：当前**还不满足前置条件**的节点（连同缺什么），
  这正是纠偏 §7 要求的"可选决策地图节点及其前置条件"。

规则中台（`rules_fallback` / `behavior_tree`）不读这张表的自然语言，只读
`campaign.frontier_preferences()`；本模块负责把"模型的选择"翻译成同一组偏好
（`order_override` / `allow_attack` / `probe`），保证**只有一条权威链**。
"""

from __future__ import annotations

from typing import Any, Callable, Dict, List, Sequence, Tuple

from . import campaign as campaign_mod

# ---------------------------------------------------------------------------
# 前置条件：**只做单步判定**（2B 模型做不了多步运算；程序侧也保持同一口径，
# 这样"程序筛出的候选"与"模型看到的条件"永远一致）
# ---------------------------------------------------------------------------

PRECONDITION_TEXT: Dict[str, str] = {
    "has_worker": "有可用工人",
    "has_builder": "有可建造的工人",
    "has_producer": "有可生产的设施",
    "has_production_building": "已有产能建筑",
    "has_barracks": "已有兵营",
    "missing_barracks": "尚无兵营",
    "has_combat": "已有作战单位",
    "combat_ready": "作战单位已达集结规模",
    "below_army": "作战单位未达集结规模",
    "has_resource": "有可见资源点",
    "no_enemy_intel": "尚无任何敌情",
    "has_enemy_intel": "已有敌情",
    "has_visible_enemy": "有可见敌人",
    "no_visible_enemy": "无可见敌人",
    "under_attack": "基地正在受袭",
    "not_under_attack": "基地未受袭",
    "outnumbered": "可见敌人数多于我方作战单位",
    "production_loss": "有产能建筑被摧毁",
    "under_attack_seen": "本局发生过基地受袭",
    "recent_combat_loss": "近期有交战损失",
    "has_expansion_candidate": "已算出分基地候选落点",
    "has_far_resource": "有远端矿点（尚未形成落点）",
    "needs_recovery": "经济需要恢复",
    "always": "无前置条件",
}


def _interrupt_active(campaign: Dict[str, Any], kind: str) -> bool:
    for entry in campaign.get("interrupt_stack") or []:
        if str(entry.get("kind", "")) == kind and str(entry.get("status")) == "active":
            return True
    return False


def _exists(campaign: Dict[str, Any], key: str) -> bool:
    return bool(campaign.get(key))


PRECONDITIONS: Dict[str, Callable[[Dict[str, Any], Dict[str, Any]], bool]] = {
    "has_worker": lambda facts, camp: bool(facts.get("workers")),
    "has_builder": lambda facts, camp: bool(facts.get("builders")),
    "has_producer": lambda facts, camp: bool(facts.get("producers")),
    "has_production_building": lambda facts, camp: any(
        int(facts.get("constructed", {}).get(key, 0)) > 0
        for key in ("barracks", "vehicle_factory", "aircraft_factory")),
    "has_barracks": lambda facts, camp: int(
        facts.get("constructed", {}).get("barracks", 0)) > 0,
    "missing_barracks": lambda facts, camp: int(facts.get("counts", {}).get(
        "barracks", 0)) <= 0,
    "has_combat": lambda facts, camp: int(facts.get("combat_count", 0)) > 0,
    "combat_ready": lambda facts, camp: int(facts.get("combat_count", 0)) >= int(
        camp.get("army_threshold", 2) or 2),
    "below_army": lambda facts, camp: int(facts.get("combat_count", 0)) < int(
        camp.get("army_threshold", 2) or 2),
    "has_resource": lambda facts, camp: int(facts.get("resource_count", 0)) > 0,
    "no_enemy_intel": lambda facts, camp: (int(facts.get("enemy_intel_count", 0)) <= 0
                                          and not facts.get("visible_enemies")),
    "has_enemy_intel": lambda facts, camp: (int(facts.get("enemy_intel_count", 0)) > 0
                                           or bool(facts.get("visible_enemies"))),
    "has_visible_enemy": lambda facts, camp: bool(facts.get("visible_enemies")),
    "no_visible_enemy": lambda facts, camp: not facts.get("visible_enemies"),
    "under_attack": lambda facts, camp: _interrupt_active(camp, "base_under_attack"),
    "not_under_attack": lambda facts, camp: not _interrupt_active(camp, "base_under_attack"),
    "outnumbered": lambda facts, camp: (
        len(facts.get("visible_enemies") or []) > int(facts.get("combat_count", 0)) > 0),
    "production_loss": lambda facts, camp: _exists(camp, "lost_buildings"),
    "under_attack_seen": lambda facts, camp: int(camp.get("under_attack_total", 0) or 0) > 0,
    "recent_combat_loss": lambda facts, camp: int(camp.get("combat_loss_events", 0) or 0) > 0,
    "has_expansion_candidate": lambda facts, camp: bool(
        camp.get("expansion_candidates") or []),
    "has_far_resource": lambda facts, camp: bool(facts.get("far_resources")),
    "needs_recovery": lambda facts, camp: _exists(camp, "needs_recovery"),
    "always": lambda facts, camp: True,
}

# ---------------------------------------------------------------------------
# 决策地图节点（与手册章节一一对应）
# ---------------------------------------------------------------------------
#
# 字段说明：
#   id/node   —— 运行时 ref（`D*`）与手册编号（`ECO-01`），模型只看到 `D*`；
#   track     —— 属于四条线中的哪一条；
#   phases    —— 哪些阶段相关（用于排序与上下文裁剪，**不是**硬门控）；
#   milestone —— 选中它就等于选择推进哪个里程碑（空 = 不绑定里程碑）；
#   build_order —— 选中它时规则阶梯的建造优先级（空 = 用默认）；
#   candidates  —— 结构化的可选任务（技能 + 目标类别），供候选筛选与验收核对。

DECISION_NODES: Tuple[Dict[str, Any], ...] = (
    {
        "id": "D1", "node": "ECO-01", "name": "开工摸底", "track": campaign_mod.TRACK_ECONOMY,
        "phases": (campaign_mod.PHASE_RECON, campaign_mod.PHASE_FOOTHOLD), "priority": 10,
        "preconditions": ("has_worker", "has_resource"), "milestone": campaign_mod.M01,
        "build_order": (),
        "candidates": ({"skill": "GAT", "target": "resource"},
                       {"skill": "PROD", "target": "product"}),
        "success": "每个工人收到 Accepted 回执，且下一轮观测里余额上升或载量变化",
        "failure": "无可见资源 → 转 SCT-01（先探矿）；资源不可达 → 改派其它资源点",
        "exit": "已为授权对象分配合理任务，或明确记录「维持」",
    },
    {
        "id": "D2", "node": "ECO-02", "name": "经济恢复", "track": campaign_mod.TRACK_ECONOMY,
        "phases": (campaign_mod.PHASE_FOOTHOLD, campaign_mod.PHASE_EXPAND), "priority": 25,
        "preconditions": ("needs_recovery", "has_worker"), "milestone": "",
        "build_order": (),
        "candidates": ({"skill": "GAT", "target": "resource"},
                       {"skill": "PROD", "target": "product"}),
        "success": "工人数回升且余额恢复上升",
        "failure": "生产建筑被毁且无法重建 → 转 D4（重建产能）",
        "exit": "工人数达到目标且余额上升",
    },
    {
        "id": "D3", "node": "BLD-01", "name": "推进发展阶梯", "track": campaign_mod.TRACK_BUILD,
        "phases": (campaign_mod.PHASE_FOOTHOLD, campaign_mod.PHASE_EXPAND), "priority": 20,
        "preconditions": ("has_builder",), "milestone": campaign_mod.M02,
        "build_order": ("barracks", "vehicle_factory", "aircraft_factory"),
        "candidates": ({"skill": "BLD", "target": "product"},
                       {"skill": "PROD", "target": "product"}),
        "success": "后续观测出现该建筑实体且 constructed=True（生产类要看到新单位）",
        "failure": "建造被拒（位置被占/不可建）→ 换位置或换建筑",
        "exit": "该建筑完工 / 该产品已部署",
    },
    {
        "id": "D4", "node": "BLD-02", "name": "重建产能", "track": campaign_mod.TRACK_BUILD,
        "phases": (campaign_mod.PHASE_FOOTHOLD, campaign_mod.PHASE_EXPAND,
                   campaign_mod.PHASE_PRESSURE), "priority": 26,
        "preconditions": ("production_loss", "has_builder"), "milestone": "",
        "build_order": (),
        "candidates": ({"skill": "BLD", "target": "product"},
                       {"skill": "PROD", "target": "product"}),
        "success": "被毁建筑类型重新出现并完工",
        "failure": "连续无法建造 → 降级为「只维持经济」并上报 degraded 原因",
        "exit": "关键建筑恢复",
    },
    {
        "id": "D5", "node": "BLD-03", "name": "补防御塔", "track": campaign_mod.TRACK_BUILD,
        "phases": (campaign_mod.PHASE_EXPAND, campaign_mod.PHASE_PRESSURE), "priority": 45,
        "preconditions": ("under_attack_seen", "has_builder", "not_under_attack"),
        "milestone": "",
        "build_order": ("anti_air_turret", "anti_ground_turret"),
        "candidates": ({"skill": "BLD", "target": "product"},),
        "success": "塔建成且位于基地朝向敌情一侧",
        "failure": "位置被占 → 换位置（账本按点拉黑）",
        "exit": "已建成计划数量的塔",
    },
    {
        "id": "D6", "node": "SCT-01", "name": "开局散点探路", "track": campaign_mod.TRACK_SCOUT,
        "phases": (campaign_mod.PHASE_RECON, campaign_mod.PHASE_EXPAND), "priority": 15,
        "preconditions": ("no_enemy_intel",), "milestone": campaign_mod.M04,
        "build_order": (),
        "candidates": ({"skill": "SCT", "target": "location"},),
        "success": "后续观测的可见资源或可见敌人增加",
        "failure": "目标不可达 → 换方向；连续两次不可达 → 标记该方向",
        "exit": "已发现新的资源点或敌情",
    },
    {
        "id": "D7", "node": "SCT-02", "name": "定向侦察敌方基地", "track": campaign_mod.TRACK_SCOUT,
        "phases": (campaign_mod.PHASE_EXPAND, campaign_mod.PHASE_PRESSURE), "priority": 35,
        "preconditions": ("has_enemy_intel",), "milestone": "",
        "build_order": (),
        "candidates": ({"skill": "SCT", "target": "location"},),
        "success": "后续观测新增敌方实体（尤其建筑类）",
        "failure": "侦察单位被击毁 → 记录 unit_lost，本轮起「信息不足」，不得盲目进攻",
        "exit": "已获得敌方基地位置或确认该方向无敌方基地",
    },
    {
        "id": "D8", "node": "SCT-03", "name": "信息不足时的合法选择",
        "track": campaign_mod.TRACK_SCOUT, "phases": campaign_mod.PHASES, "priority": 55,
        "preconditions": ("always",), "milestone": "",
        "build_order": (),
        "candidates": ({"skill": "SCT", "target": "location"},
                       {"skill": "HOLD", "target": "-"},
                       {"skill": "GAT", "target": "resource"}),
        "success": "维持只记录等待理由与已有任务进展，不伪造完成",
        "failure": "长期无情报且无经济进展 → 上升为 degraded 原因供玩家查看",
        "exit": "获得情报 / 玩家给出目标 / 有足够军队需要集结",
    },
    {
        "id": "D9", "node": "ARM-01", "name": "补兵", "track": campaign_mod.TRACK_MILITARY,
        "phases": (campaign_mod.PHASE_FOOTHOLD, campaign_mod.PHASE_EXPAND,
                   campaign_mod.PHASE_PRESSURE), "priority": 30,
        "preconditions": ("has_production_building", "below_army"), "milestone": campaign_mod.M03,
        "build_order": (),
        "candidates": ({"skill": "PROD", "target": "product"},),
        "success": "观测到新单位实体（队列项消失本身不算成功）",
        "failure": "队列项消失但无新单位 → 不得当成功；资源不足 → 回经济线",
        "exit": "已下单一支目标规模的部队",
    },
    {
        "id": "D10", "node": "DEF-01", "name": "基地防守", "track": campaign_mod.TRACK_MILITARY,
        "phases": campaign_mod.PHASES, "priority": 5,
        "preconditions": ("under_attack",), "milestone": "",
        "build_order": (),
        "candidates": ({"skill": "DEF", "target": "anchor"},
                       {"skill": "AMOV", "target": "anchor"}),
        "success": "敌方单位从观测中消失或 confirmed_dead；不再收到 base_under_attack",
        "failure": "敌人多于我方作战单位 → 转 D13（撤离保存兵力）",
        "exit": "威胁解除",
    },
    {
        "id": "D11", "node": "ATK-01", "name": "集结（不添油）",
        "track": campaign_mod.TRACK_MILITARY,
        "phases": (campaign_mod.PHASE_FOOTHOLD, campaign_mod.PHASE_EXPAND,
                   campaign_mod.PHASE_PRESSURE), "priority": 40,
        "preconditions": ("has_combat", "below_army", "not_under_attack"), "milestone": "",
        "build_order": (),
        "candidates": ({"skill": "GRP", "target": "anchor"},
                       {"skill": "AMOV", "target": "anchor"}),
        "success": "作战单位在集结点附近聚集（位置接近目标）",
        "failure": "集结点被敌占据 → 改集结点",
        "exit": "达到进攻规模 或 玩家指定目标",
    },
    {
        "id": "D12", "node": "ATK-02", "name": "进攻", "track": campaign_mod.TRACK_MILITARY,
        "phases": (campaign_mod.PHASE_PRESSURE, campaign_mod.PHASE_CONVERGE), "priority": 50,
        "preconditions": ("combat_ready", "has_visible_enemy", "not_under_attack"),
        "milestone": campaign_mod.M06,
        "build_order": (),
        "candidates": ({"skill": "ATK", "target": "enemy"},
                       {"skill": "AMOV", "target": "location"}),
        "success": "敌方单位 confirmed_dead 或从观测消失",
        "failure": "我方作战单位数 < 敌方可见数 → 转 D13；目标失去视野 → interrupted（非失败）",
        "exit": "目标被消灭 / 视野内无敌可打",
    },
    {
        "id": "D13", "node": "RET-01", "name": "撤退", "track": campaign_mod.TRACK_MILITARY,
        "phases": campaign_mod.PHASES, "priority": 8,
        "preconditions": ("outnumbered",), "milestone": "",
        "build_order": (),
        "candidates": ({"skill": "RET", "target": "anchor"},
                       {"skill": "AMOV", "target": "location"}),
        "success": "与最近敌人的距离增大，或脱离敌人视野",
        "failure": "被追击且无法脱离 → 允许边打边走（AMOV 向基地）",
        "exit": "脱离接触 / 到达集结点或基地范围",
    },
    {
        "id": "D14", "node": "REG-01", "name": "重组与再次出击",
        "track": campaign_mod.TRACK_MILITARY,
        "phases": (campaign_mod.PHASE_EXPAND, campaign_mod.PHASE_PRESSURE), "priority": 42,
        "preconditions": ("has_combat", "recent_combat_loss", "not_under_attack"),
        "milestone": "",
        "build_order": (),
        "candidates": ({"skill": "GRP", "target": "anchor"},
                       {"skill": "PROD", "target": "product"}),
        "success": "兵力回升且重新集结到集结点",
        "failure": "产能不足 → 转 D2（先恢复经济）",
        "exit": "达到进攻规模 → 回 D12",
    },
)

NODE_BY_ID: Dict[str, Dict[str, Any]] = {str(node["id"]): node for node in DECISION_NODES}
NODE_BY_MANUAL_ID: Dict[str, Dict[str, Any]] = {
    str(node["node"]): node for node in DECISION_NODES}


def _precondition_status(node: Dict[str, Any], facts: Dict[str, Any],
                         campaign: Dict[str, Any]) -> Tuple[bool, List[str]]:
    unmet: List[str] = []
    for name in node.get("preconditions") or ():
        evaluator = PRECONDITIONS.get(str(name))
        if evaluator is None:
            unmet.append(str(name))
            continue
        try:
            ok = bool(evaluator(facts, campaign))
        except Exception:  # noqa: BLE001 —— 条件判定失败按"不满足"处理（保守）
            ok = False
        if not ok:
            unmet.append(str(name))
    return (not unmet), unmet


def retrieve(facts: Dict[str, Any], campaign: Dict[str, Any],
             *, limit: int = 6) -> Dict[str, Any]:
    """按当前事实检索决策地图：可用节点（`available`）+ 尚不满足条件的节点（`locked`）。

    返回的是**程序筛过的候选**（纠偏 §"候选筛选只做合法性粗筛"）：
    模型只能在这张表里选，不能自造路线；`locked` 连同"缺什么"一起给，
    这正是"候选保留竞争项 + 维持"的落地方式。
    """
    available: List[Dict[str, Any]] = []
    locked: List[Dict[str, Any]] = []
    for node in DECISION_NODES:
        ok, unmet = _precondition_status(node, facts, campaign)
        entry = {
            "id": str(node["id"]),
            "node": str(node["node"]),
            "name": str(node["name"]),
            "track": str(node["track"]),
            "milestone": str(node.get("milestone", "") or ""),
            "priority": int(node.get("priority", 100)),
            "needs": [PRECONDITION_TEXT.get(name, name) for name in
                      (node.get("preconditions") or ())],
            "unmet": [PRECONDITION_TEXT.get(name, name) for name in unmet],
        }
        if ok:
            available.append(entry)
        else:
            locked.append(entry)
    available.sort(key=lambda item: (int(item["priority"]), str(item["id"])))
    locked.sort(key=lambda item: (len(item["unmet"]), int(item["priority"]), str(item["id"])))
    return {"available": available[:max(1, int(limit))],
            "locked": locked[:max(1, int(limit))]}


def resolve_branch(ref: str) -> Dict[str, Any]:
    """把模型给的 `g`（分支引用）解析成决策地图节点。

    接受两种写法：决策地图 ref（`D3`）与手册编号（`BLD-01`）——
    模型在上下文里看到的是 `D*`，但手册编号在日志/对话里更可读，两者都认。
    """
    key = str(ref or "").strip().upper()
    node = NODE_BY_ID.get(key) or NODE_BY_MANUAL_ID.get(key)
    if node is None:
        return {}
    return dict(node)


def order_override(ref: str) -> Tuple[str, ...]:
    """该分支对规则阶梯建造顺序的覆盖（空 = 不覆盖）。"""
    node = resolve_branch(ref)
    return tuple(str(item) for item in (node.get("build_order") or ()))


def context_lines(retrieved: Dict[str, Any], *, limit: int = 4) -> List[str]:
    """把检索结果压成**一到两行**紧凑文本（2B 的输入预算只够这个粒度）。"""
    lines: List[str] = []
    available = retrieved.get("available") or []
    if available:
        lines.append("可选路线: " + " ".join(
            "%s%s%s" % (item["id"], item["name"],
                        ("(需:%s)" % "/".join(item["needs"]))
                        if item["needs"] and item["needs"] != ["无前置条件"] else "")
            for item in available[:limit]))
    locked = retrieved.get("locked") or []
    if locked:
        lines.append("暂不可选: " + " ".join(
            "%s%s(缺:%s)" % (item["id"], item["name"], "/".join(item["unmet"]))
            for item in locked[:limit]))
    return lines


def candidate_refs(retrieved: Dict[str, Any]) -> List[str]:
    return [str(item["id"]) for item in (retrieved.get("available") or [])]


__all__ = [
    "DECISION_NODES", "NODE_BY_ID", "NODE_BY_MANUAL_ID", "PRECONDITIONS",
    "PRECONDITION_TEXT", "candidate_refs", "context_lines", "order_override",
    "resolve_branch", "retrieve",
]
