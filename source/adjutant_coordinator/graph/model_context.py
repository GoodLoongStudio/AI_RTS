# -*- coding: utf-8 -*-
"""模型上下文构造：只暴露观测里真实存在的事实，不伪造、不补默认值。

纪律（architecture.md §2、方案 §5/§6）：
- 战术上下文必须足以选择实体/坐标/场景目标；截断时显式报告 truncated，
  模型不得把未返回的单位理解为阵亡；
- 不提供 full_vision；敌方数据只来自该玩家视野情报（含 last_seen_tick）；
- 目标引用校验：模型只能引用观测中存在的稳定实体 ID 与规则视图中的场景。
"""

from __future__ import annotations

from typing import Any, Dict, Iterable, List, Optional, Set, Tuple


def rules_scene_paths(rules: Optional[Dict[str, Any]]) -> Set[str]:
    """规则视图里的受信任场景路径（unit_types + constructions）。"""
    paths: Set[str] = set()
    if not isinstance(rules, dict) or rules.get("error"):
        return paths
    for unit_type in rules.get("unit_types", []) or []:
        scene = str(unit_type.get("scene_path", ""))
        if scene:
            paths.add(scene)
    for construction in rules.get("constructions", []) or []:
        scene = str(construction.get("blueprint_scene_path", ""))
        if scene:
            paths.add(scene)
    return paths


def rules_scene_index(rules: Optional[Dict[str, Any]]) -> Dict[str, str]:
    """规则视图里的 id → 场景路径索引（unit_types + constructions）。

    提示词要求模型用产品类型 id / 建造 id 填 target.scene（模型记 id 比记长路径稳），
    而权威层 load() 只认真实场景路径。下发前用本索引把 id 归一化成路径，
    使"提示词允许的写法"与"权威层能执行的写法"对齐，避免合法意图被
    scene_not_in_rules 误拒（实测：worker 生产意图因此全数被丢弃）。
    """
    index: Dict[str, str] = {}
    if not isinstance(rules, dict) or rules.get("error"):
        return index
    for unit_type in rules.get("unit_types", []) or []:
        unit_id = str(unit_type.get("id", ""))
        scene = str(unit_type.get("scene_path", ""))
        if unit_id and scene:
            index.setdefault(unit_id, scene)
    for construction in rules.get("constructions", []) or []:
        build_id = str(construction.get("id", ""))
        scene = str(construction.get("blueprint_scene_path", ""))
        if build_id and scene:
            index.setdefault(build_id, scene)
    return index


def known_entity_ids(*views: Optional[Dict[str, Any]]) -> Set[str]:
    """观测中出现过的稳定实体 ID（我方可命令实体 + 已侦察敌方实体）。"""
    ids: Set[str] = set()
    for view in views:
        if not isinstance(view, dict):
            continue
        for entity in view.get("entities", []) or []:
            name = str(entity.get("name", ""))
            if name:
                ids.add(name)
    return ids


def own_unit_ids(tactical: Optional[Dict[str, Any]]) -> Set[str]:
    if not isinstance(tactical, dict):
        return set()
    return {str(e.get("name", "")) for e in tactical.get("entities", []) or []
            if e.get("kind") == "unit_self" and e.get("name")}


def visible_enemy_ids(tactical: Optional[Dict[str, Any]]) -> Set[str]:
    if not isinstance(tactical, dict):
        return set()
    return {str(e.get("name", "")) for e in tactical.get("entities", []) or []
            if str(e.get("kind", "")).startswith("unit_enemy") and e.get("name")}


def coverage_note(tactical: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    """显式覆盖范围：truncated 时不把未返回实体解释为阵亡。"""
    if not isinstance(tactical, dict):
        return {"truncated": None, "next_offset": None,
                "note": "未提供战术快照；禁止基于缺失数据下结论"}
    truncated = tactical.get("truncated")
    return {
        "truncated": truncated,
        "next_offset": tactical.get("next_offset"),
        "covered": tactical.get("covered", {}),
        "totals": tactical.get("totals", {}),
        "note": ("快照被截断：未返回实体不代表阵亡，需要用 offset/next_offset 续取"
                 if truncated else "快照完整"),
    }


def summarize_events(events: Optional[Iterable[Dict[str, Any]]],
                     max_kinds: int = 8) -> List[Dict[str, Any]]:
    """把原始事件压成 **`{kind, count, last_tick}` 摘要**（供战略层使用）。

    ## 为什么战略层**不能**直接吃原始事件（2026-09-11 实测，同一对局、同一模型）

    | 事件形态 | 结果 |
    |---|---|
    | 无事件 | OK 6.6s |
    | **原始 1 条** | **FAIL** 26.9s（= 1 次调用 + 2 次重试） |
    | 原始 5 / 10 / 30 / 60 条 | FAIL 18~28s |
    | **摘要 10 条** | **OK 5.4s** |
    | **摘要 60 条** | **OK 5.6s** |

    结论：**失败与体积无关，与"喂了多少可照抄的身份字段"有关**。原始事件带
    `event_id / match_id / player_id / payload`，2B 模型会去照抄这些字段或试图
    "处理事件"，产出的 JSON 不匹配 `StrategyPlan` → PydanticAI 校验失败 →
    `ModelInvalidOutput: Exceeded maximum output retries (2)`；每次烧 ~27s，
    而战略是低频层，直接表现为"开局几分钟副官什么都不做"。
    这是"输入精简"（方案 §1）的又一个实证案例：**该砍的不是体积，是噪声字段**。

    附注：战术层不需要这样处理 —— 同一实验下战术层吃原始事件仍是 OK 2.0s
    （`DirectiveBatch` 只含 action/units/target，模型没有可照抄的模板）。
    """
    buckets: Dict[str, Dict[str, Any]] = {}
    for event in events or []:
        if not isinstance(event, dict):
            continue
        kind = str(event.get("kind", "") or "")
        if not kind:
            continue
        item = buckets.get(kind)
        if item is None:
            item = {"kind": kind, "count": 0, "last_tick": 0}
            buckets[kind] = item
        item["count"] += 1
        item["last_tick"] = max(int(item["last_tick"]),
                                int(event.get("server_tick", 0) or 0))
    ordered = sorted(buckets.values(), key=lambda item: item["last_tick"], reverse=True)
    return ordered[:max(1, int(max_kinds))]


def build_strategy_context(
    state,
    *,
    strategic: Optional[Dict[str, Any]],
    rules: Optional[Dict[str, Any]],
    events: Optional[Iterable[Dict[str, Any]]] = None,
    budget: Optional[Dict[str, int]] = None,
    config: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """战略模型输入：低频、全局、可解释；不含单位级微操数据。

    事件以**摘要**形式给出（见 `summarize_events` 的实测依据）：
    原始事件会让本地小模型产出非法 `StrategyPlan`。
    """
    context: Dict[str, Any] = {
        "role": "strategy",
        "match_id": state.match_id,
        "player_id": state.player_id,
        "rules_version": state.rules_version,
        "server_tick": state.server_tick,
        "snapshot_id": state.latest_snapshot_id,
        "current_plan": state.active_plan,
        "plan_version": state.plan_version,
        "plan_adopt_generation": state.plan_adopt_generation,
        "active_tasks": dict(state.active_tasks),
        "ai_controlled_units": list(state.ai_controlled_units),
        "player_controlled_units": list(state.player_controlled_units),
        "released_units": list(state.released_units),
        "degraded_reason": state.degraded_reason,
        "budget": dict(budget or {}),
        # 只给"发生了什么类别的事"，不给逐条原始记录（实测见 summarize_events）。
        "event_summary": summarize_events(events),
        "strategic_summary": strategic if isinstance(strategic, dict) else None,
        "strategic_summary_available": isinstance(strategic, dict) and not strategic.get("error"),
        "rules_available": bool(rules_scene_paths(rules)),
        "hint": "只输出 StrategicPlan；不要输出单位命令；不能引用观测之外的目标。",
    }
    context.update(config or {})
    context["hint"] = (
        context["hint"]
        + "based_on_snapshot 必须不超过上下文 snapshot_id；"
        + "valid_until_tick 必须大于 server_tick（建议 server_tick + 6000 以内）；"
        + "tasks[].units 只能使用 ai_controlled_units 中的实体 ID；"
        + "plan_version 必须是比 plan_version 字段更大的正整数。")
    return context


def _live_intents_by_unit(state) -> List[Dict[str, Any]]:
    """每个单位只保留一条最新活跃意图。

    实测（2026-09-10）：同一 intent（i-1/i-2）会在 active_intents 里反复登记，
    上下文随之膨胀，既拖慢本地模型，又让模型看到重复指令而重复下发。
    这里按单位取 expires_tick 最大的一条，且同一 intent_id 只出现一次。
    """
    latest: Dict[str, Dict[str, Any]] = {}
    for intent in state.active_intents or []:
        if intent.get("state") not in ("active", "pending_authority"):
            continue
        for unit in intent.get("unit_ids", []) or []:
            key = str(unit)
            prev = latest.get(key)
            if prev is None or int(intent.get("expires_tick", 0) or 0) >= \
                    int(prev.get("expires_tick", 0) or 0):
                latest[key] = intent
    seen: set = set()
    out: List[Dict[str, Any]] = []
    for intent in latest.values():
        intent_id = str(intent.get("intent_id", ""))
        if intent_id in seen:
            continue
        seen.add(intent_id)
        out.append(intent)
    return out


def build_tactics_context(
    state,
    *,
    tactical: Optional[Dict[str, Any]],
    rules: Optional[Dict[str, Any]],
    events: Optional[Iterable[Dict[str, Any]]] = None,
    strategic: Optional[Dict[str, Any]] = None,
    config: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """战术模型输入：局部事件 + 当前计划 + 最新观测（含覆盖范围与截断标记）。"""
    events_list = list(events or [])
    # 单位能力清单：既给模型看（只读事实），也用于派生候选组合（production_options/build_options）。
    own_units_list = [
        {"name": str(entity.get("name", "")),
         "type": str(entity.get("unit_type", "")),
         "can_move": bool(entity.get("movement", False)),
         "can_build": bool(entity.get("construct", False)),
         "can_gather": bool(entity.get("gather", False)),
         "can_produce": bool(entity.get("queue", False))}
        for entity in (tactical or {}).get("entities", []) or []
        if str(entity.get("kind", "")) == "unit_self"
    ] if isinstance(tactical, dict) else []
    context: Dict[str, Any] = {
        "role": "tactics",
        "match_id": state.match_id,
        "player_id": state.player_id,
        "rules_version": state.rules_version,
        "server_tick": state.server_tick,
        "snapshot_id": state.latest_snapshot_id,
        "plan_version": state.plan_version,
        "current_plan": state.active_plan,
        "active_tasks": dict(state.active_tasks),
        "active_intents": _live_intents_by_unit(state),
        "pending_requests": sorted(state.pending_requests.keys()),
        "ai_controlled_units": list(state.ai_controlled_units),
        "player_controlled_units": list(state.player_controlled_units),
        "released_units": list(state.released_units),
        "degraded_reason": state.degraded_reason,
        "events": events_list,
        # 不再整包塞 tactical_view：实测 21 个实体的完整观测约 4.5KB，
        # 加上 rules 后上下文到 16KB，本地小模型 prefill + decode 合计要 34 秒。
        # 模型只需要"谁可用、能干什么、资源点在哪、敌人在哪"，其余由执行器负责。
        "tactical_summary": coverage_note(tactical),
        "own_unit_ids": sorted(own_unit_ids(tactical)),
        "visible_enemy_ids": sorted(visible_enemy_ids(tactical)),
        "visible_resources": [
            {"entity_id": str(entity.get("name", "")),
             "pos": [round(float((entity.get("pos") or [0, 0, 0])[0]), 1),
                     round(float((entity.get("pos") or [0, 0, 0])[2]), 1)]}
            for entity in (tactical or {}).get("entities", []) or []
            if str(entity.get("kind", "")) == "resource"
        ] if isinstance(tactical, dict) else [],
        # trust_scene_paths 已移除：与 buildable[].scene / production_options 重复，
        # 且系统提示词明确要求模型只写 id（路径由程序归一化），纯属浪费上下文。
        # 单位名 → 单位类型 + 能力：模型据此匹配 production_relations[].allowed_producers，
        # 也据此判断"谁能建造/采集/生产"。只给 can_move 时模型会派侦察机去建造
        # （实测 i-2 build 选了 drone → OutOfBounds/不可执行），故把事实能力全量暴露。
        "own_units": own_units_list,
        # 候选选项：把"可执行的 (执行单位 → 产物)"组合**预先算好**，模型只做选择。
        # 实测让模型自己拼 producer/scene 会出错：把两者填反，
        # 或派 can_produce=false 的 drone 去生产。这里按规则视图里的
        # productions/allowed_producer_type_ids 与单位实际能力交叉匹配，模型不许自造组合。
        "production_options": [
            {"producer": unit["name"], "product": str(rel.get("product_type_id", ""))}
            for rel in (rules or {}).get("productions", []) or []
            for unit in own_units_list
            if unit["can_produce"]
            and unit["type"] in [str(t) for t in
                                 rel.get("allowed_producer_type_ids", []) or []]
        ] if isinstance(rules, dict) else [],
        # 注意：这里**不再**带 cost。实测成本项让本字段膨胀到 3.8KB（4 建造物 × 8 工人
        # 的笛卡尔积，每项重复一份 cost），而模型选"谁造什么"并不需要价格；
        # 扣费与预留由权威端按规则视图算（见 graph/reserves.intent_cost）。
        # 这是把请求压回 4096 上下文窗口以内的主要手段之一。
        "build_options": [
            {"builder": unit["name"], "building": str(item.get("id", ""))}
            for item in (rules or {}).get("constructions", []) or []
            for unit in own_units_list
            if unit["can_build"]
        ] if isinstance(rules, dict) else [],
        # 规则视图里的“可建造/可生产关系”：让模型能选出权威层接受的场景与生产者。
        "buildable": [
            {"id": str(item.get("id", "")),
             "scene": str(item.get("blueprint_scene_path", ""))}
            for item in (rules or {}).get("constructions", []) or []
        ] if isinstance(rules, dict) else [],
        "production_relations": [
            {"product": str(item.get("product_type_id", "")),
             "allowed_producers": [str(p) for p in
                                   item.get("allowed_producer_type_ids", []) or []],
             "cost": item.get("cost", [])}
            for item in (rules or {}).get("productions", []) or []
        ] if isinstance(rules, dict) else [],
        "strategic_summary": strategic if isinstance(strategic, dict) else None,
    }
    # 【关键】战术上下文的 hint 必须与 TACTICS_SYSTEM_PROMPT 的 DirectiveBatch 契约一致。
    # 旧版这里写的是"只输出 IntentBatch；plan_version 必须等于…；expires_tick…；
    # generation 填 0…"，而系统提示词明令"**严禁**输出 intent_id/plan_version/snapshot/
    # tick/expires_tick/generation 等元数据，系统会自动补齐"。两套指令直接冲突，
    # 实测 2B 模型因此频繁回空 `{"directives": []}`（108 次基准里 26 次为空，
    # "撤退"场景几乎必然为空）。这里统一成只讲 directive 字段的合法取值来源。
    context.update(config or {})
    hint_parts = []
    if context.get("hint"):
        # 调用方（config）显式提供了 hint：保留并置于最前，其余约束追加在后。
        hint_parts.append(str(context["hint"]))
    hint_parts.extend([
        "只输出 DirectiveBatch（顶层只有 directives 数组）。",
        "**不要**输出 intent_id/plan_version/snapshot/tick/expires_tick/generation 等元数据，"
        "系统会按请求上下文自动补齐。",
        "directives[].units 只能取自 own_units[].name，且不得包含 player_controlled_units。",
        "gather 的 target_id 只能取自 visible_resources[].entity_id；"
        "attack 的 target_id 只能取自 visible_enemy_ids。",
        "移动类动作（move/attack_move/defend/retreat/scout/regroup）必须给 "
        "target_pos=[x,z] 数字坐标。",
        "produce 必须整条取自 production_options（producer 与 product 同项）；"
        "build 必须整条取自 build_options（builder 与 building 同项）。",
    ])
    if context.get("visible_enemy_ids"):
        # 只有确实存在可见敌情时才加这条，避免和平局面被过度约束。
        # 判据用**单步数量比较**：2B 模型做不了"数量≥2倍"这类多步运算，
        # 实测写成 ×2 时"撤退"场景仍会拿单个士兵硬冲三个敌人。
        hint_parts.append(
            "当前有可见敌人：若 visible_enemy_ids 数量多于我方作战单位数量，"
            "作战单位必须 retreat 或 move 撤离（给远离敌人的 target_pos），不要 attack；"
            "否则 attack 最近的可见敌人（target_id 取 visible_enemy_ids）。"
            "不得给空数组。")
    hint_parts.append(
        "未被分配任务、且能力允许的单位应当派活，不要让它空转"
        "（工人 gather、机动单位 scout/前压）；每个单位在同一批里只能出现一次。")
    if context.get("player_controlled_units"):
        # 必须显式再说一次：上面"不许空转"的规则会诱导模型把玩家接管的单位也算进去
        # （实测回归：玩家接管的 Unit_3 被下了 gather）。玩家重获控制的单位不属于副官。
        hint_parts.append(
            "player_controlled_units 里的单位已被玩家亲自指挥，"
            "**绝对不要**出现在 directives 里，也不要算作可派活的空闲单位。")
    hint_parts.append("只有确实不存在任何可执行动作时才给 {\"directives\": []}。")
    context["hint"] = "".join(hint_parts)
    return context


def validate_intent_references(
    intents: List[Dict[str, Any]],
    *,
    known_entities: Set[str],
    scene_paths: Set[str],
    allowed_units: Optional[Set[str]] = None,
) -> List[Tuple[str, str]]:
    """目标引用校验：返回 [(intent_id, 错误原因)]，空列表表示全部合法。

    - unit_ids 必须是本玩家可见/可命令的实体（allowed_units 缺省 = known_entities）；
    - attack 的 entity_id 必须出现在观测中（不能凭空攻击）；
    - produce/build 的 scene 必须来自规则视图（不能构造任意资源路径）。
    """
    problems: List[Tuple[str, str]] = []
    units_scope = allowed_units if allowed_units is not None else known_entities
    for intent in intents:
        intent_id = str(intent.get("intent_id", ""))
        for unit_id in intent.get("unit_ids", []) or []:
            if str(unit_id) not in units_scope:
                problems.append((intent_id, "unit_not_in_observation:%s" % unit_id))
        target = intent.get("target", {}) or {}
        action = str(intent.get("action", ""))
        entity_id = target.get("entity_id")
        if action == "attack":
            if not entity_id:
                problems.append((intent_id, "attack_without_entity_id"))
            elif str(entity_id) not in known_entities:
                problems.append((intent_id, "entity_not_in_observation:%s" % entity_id))
        scene = target.get("scene")
        if action in ("produce", "build"):
            if not scene:
                problems.append((intent_id, "missing_scene"))
            elif scene not in scene_paths:
                problems.append((intent_id, "scene_not_in_rules:%s" % scene))
            producer = str(target.get("producer", ""))
            if producer and producer not in units_scope:
                problems.append((intent_id, "producer_not_in_observation:%s" % producer))
    return problems
