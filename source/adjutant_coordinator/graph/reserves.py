# -*- coding: utf-8 -*-
"""资源预留（方案 §6）：预留是**玩家设定**，不是模型产出。

方案原文要求：
- 按资源类型分别提供**绝对值**；
- 初始值 = **本局首次开启副官时余额的 20%**，取整并保持固定，直到玩家调整；
  **不能每次花费后按剩余余额重算**；
- 关闭重开副官要保留本局已调整的额度（因此标志位挂在**对局状态**而不是进程上）；
- 设为零表示允许使用全部资源；
- AI 下单时由权威端检查余额、预留与**已承诺成本**（多个候选不能重复花同一笔钱）；
- 玩家可以使用预留资源。

与模型 `StrategicPlan.reserves` 的关系：那个字段是模型建议，**不覆盖**玩家设定
（否则"玩家可调整预留"就名不副实）。本模块的 `state["reserves"]` 才是权威来源。
"""

from __future__ import annotations

from typing import Any, Dict, Iterable, List, Optional, Tuple

#: 首次开启副官时的默认预留比例（%）。取整按向下取整，避免出现小数余额。
DEFAULT_RESERVE_PERCENT = 20

#: 规则视图里成本项的 kind 用 "A"/"B"；观测余额用 "a"/"b"。统一成大写。
KIND_A = "A"
KIND_B = "B"


def normalize_balance(observation: Optional[Dict[str, Any]]) -> Dict[str, int]:
    """从观测里取本玩家余额（tactical.balance 优先，回落到 strategic.resources）。"""
    tactical = (observation or {}).get("tactical")
    strategic = (observation or {}).get("strategic")
    raw: Dict[str, Any] = {}
    if isinstance(tactical, dict) and isinstance(tactical.get("balance"), dict):
        raw = tactical["balance"]
    elif isinstance(strategic, dict) and isinstance(strategic.get("resources"), dict):
        raw = strategic["resources"]
    balance: Dict[str, int] = {}
    for key, value in (raw or {}).items():
        name = str(key).upper()
        try:
            balance[name] = int(value)
        except (TypeError, ValueError):
            continue
    return balance


def _normalize_kinds(values: Optional[Dict[str, Any]]) -> Dict[str, int]:
    out: Dict[str, int] = {}
    for key, value in (values or {}).items():
        try:
            out[str(key).upper()] = int(value)
        except (TypeError, ValueError):
            continue
    return out


def normalize_reserve_setting(observation: Optional[Dict[str, Any]]
                              ) -> Optional[Dict[str, int]]:
    """读取**权威端导出**的玩家预留（tactical.reserves 优先，回落 strategic.reserves）。

    返回值语义：
    - `None`：权威端没有导出该字段（旧构建 / 测试桩）→ 调用方按 20% 本地初始化；
    - 字典：以权威端为准，**即使为空字典**（空 = 玩家把预留全设为 0 = 不限制）。
    区分这两者是必要的：把"玩家显式设为不预留"误判成"没配置"会让预留白设。
    """
    tactical = (observation or {}).get("tactical")
    strategic = (observation or {}).get("strategic")
    raw: Optional[Dict[str, Any]] = None
    if isinstance(tactical, dict) and isinstance(tactical.get("reserves"), dict):
        raw = tactical["reserves"]
    elif isinstance(strategic, dict) and isinstance(strategic.get("reserves"), dict):
        raw = strategic["reserves"]
    if raw is None:
        return None
    return _normalize_kinds(raw)


def ensure_reserves(state: Dict[str, Any], balance: Dict[str, int], *,
                    percent: int = DEFAULT_RESERVE_PERCENT) -> bool:
    """首次开启副官时按余额百分比初始化预留；已初始化则原样保留（玩家调整不被覆盖）。

    返回是否**本次**初始化。
    """
    if state.get("reserves_initialized"):
        return False
    ratio = max(0, min(100, int(percent)))
    reserves = {kind: int(amount) * ratio // 100 for kind, amount in (balance or {}).items()}
    state["reserves"] = reserves
    state["reserves_initialized"] = True
    state["reserves_percent"] = ratio
    return True


def set_reserves(state: Dict[str, Any], values: Dict[str, Any]) -> Dict[str, int]:
    """玩家调整预留（绝对值）。只覆盖显式给出的资源类型。"""
    current = _normalize_kinds(state.get("reserves"))
    current.update(_normalize_kinds(values))
    state["reserves"] = current
    state["reserves_initialized"] = True
    return current


def committed_costs(state: Dict[str, Any], rules: Optional[Dict[str, Any]],
                    live_states: Iterable[str]) -> Dict[str, int]:
    """已承诺成本：仍然活跃的意图所占用的资源（防止多个候选重复花同一笔钱）。"""
    live = set(live_states)
    committed: Dict[str, int] = {}
    for intent in state.get("active_intents") or []:
        if not isinstance(intent, dict) or intent.get("state") not in live:
            continue
        for kind, amount in intent_cost(intent, rules).items():
            committed[kind] = committed.get(kind, 0) + int(amount)
    return committed


def spendable(balance: Dict[str, int], reserves: Dict[str, int],
              committed: Dict[str, int]) -> Dict[str, int]:
    """可花费额度 = 余额 - 预留 - 已承诺（下限 0）。预留为 0 表示不限制预留。"""
    out: Dict[str, int] = {}
    for kind, amount in (balance or {}).items():
        reserved = int((reserves or {}).get(kind, 0) or 0)
        spent = int((committed or {}).get(kind, 0) or 0)
        out[kind] = max(0, int(amount) - reserved - spent)
    return out


def _scene_to_id_index(rules: Optional[Dict[str, Any]]) -> Tuple[Dict[str, str], Dict[str, str]]:
    """场景路径 → 定义 id 的反查表。

    仲裁前 `target.scene` 已被归一化成**场景路径**（`rules_scene_index` 的逆操作），
    所以查成本必须按路径反查，不能再按 id 查。
    """
    product_by_scene: Dict[str, str] = {}
    building_by_scene: Dict[str, str] = {}
    if not isinstance(rules, dict) or rules.get("error"):
        return product_by_scene, building_by_scene
    for item in rules.get("unit_types") or []:
        if not isinstance(item, dict):
            continue
        # 产品类型 id 与 unit_type 同源：produce 的 scene 是产品类型 id 对应的场景路径。
        unit_id = str(item.get("id", ""))
        scene = str(item.get("scene_path", ""))
        if unit_id and scene:
            product_by_scene.setdefault(scene, unit_id)
    for item in rules.get("constructions") or []:
        if not isinstance(item, dict):
            continue
        build_id = str(item.get("id", ""))
        scene = str(item.get("blueprint_scene_path", ""))
        if build_id and scene:
            building_by_scene.setdefault(scene, build_id)
    return product_by_scene, building_by_scene


def intent_cost(intent: Dict[str, Any], rules: Optional[Dict[str, Any]]) -> Dict[str, int]:
    """按规则视图估算意图成本（produce/build 才有）。查不到就返回空，不猜数值。"""
    action = str(intent.get("action", ""))
    target = intent.get("target") or {}
    scene = str(target.get("scene", ""))
    if action not in ("produce", "build") or not scene:
        return {}
    if not isinstance(rules, dict) or rules.get("error"):
        return {}
    product_by_scene, building_by_scene = _scene_to_id_index(rules)
    wanted_id = (product_by_scene.get(scene) if action == "produce"
                 else building_by_scene.get(scene))
    if not wanted_id:
        return {}
    definitions = (rules.get("productions") if action == "produce"
                   else rules.get("constructions")) or []
    key = "product_type_id" if action == "produce" else "id"
    for definition in definitions:
        if not isinstance(definition, dict) or str(definition.get(key, "")) != wanted_id:
            continue
        cost: Dict[str, int] = {}
        for entry in definition.get("cost") or []:
            if not isinstance(entry, dict):
                continue
            try:
                cost[str(entry.get("kind", "")).upper()] = int(entry.get("amount", 0))
            except (TypeError, ValueError):
                continue
        return cost
    return {}


def apply_budget(state: Dict[str, Any], intents: List[Dict[str, Any]], *,
                 rules: Optional[Dict[str, Any]], observation: Optional[Dict[str, Any]],
                 live_states: Iterable[str], percent: int = DEFAULT_RESERVE_PERCENT
                 ) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
    """按玩家预留过滤意图：返回 (保留, 丢弃[{intent_id, reason}])。

    只拦**确有成本**且超出可花费额度的意图；成本未知时不拦（不猜数值、不误杀）。
    """
    balance = normalize_balance(observation)
    # 预留以**权威端**为准（方案 §6："由权威端检查"）：权威端每轮随观测下发玩家设定，
    # 玩家改额度后立刻生效，不需要额外的下行通道。权威端没导出时才本地按 20% 初始化。
    authority = normalize_reserve_setting(observation)
    if authority is not None:
        state["reserves"] = authority
        state["reserves_initialized"] = True
    elif balance:
        ensure_reserves(state, balance, percent=percent)
    reserves = _normalize_kinds(state.get("reserves"))
    committed = committed_costs(state, rules, live_states)
    available = spendable(balance, reserves, committed)
    kept: List[Dict[str, Any]] = []
    dropped: List[Dict[str, Any]] = []
    for intent in intents:
        cost = intent_cost(intent, rules)
        short = [kind for kind, amount in cost.items()
                 if int(amount) > int(available.get(kind, 0))]
        if short:
            dropped.append({"intent_id": str(intent.get("intent_id", "")),
                            "reason": "insufficient_reserve:%s" % ",".join(sorted(short)),
                            "cost": cost, "available": dict(available)})
            continue
        # 采纳后先记账，保证同批次多个候选不会重复花同一笔钱。
        for kind, amount in cost.items():
            available[kind] = max(0, int(available.get(kind, 0)) - int(amount))
        kept.append(intent)
    return kept, dropped


def snapshot(state: Dict[str, Any], observation: Optional[Dict[str, Any]] = None
             ) -> Dict[str, Any]:
    """给 HUD/诊断用的预留快照（余额、预留、已承诺、可花费）。"""
    balance = normalize_balance(observation)
    reserves = _normalize_kinds(state.get("reserves"))
    return {
        "initialized": bool(state.get("reserves_initialized")),
        "percent": int(state.get("reserves_percent", DEFAULT_RESERVE_PERCENT) or 0),
        "balance": balance,
        "reserves": reserves,
        "spendable": spendable(balance, reserves, {}),
        "player_editable": True,
    }
