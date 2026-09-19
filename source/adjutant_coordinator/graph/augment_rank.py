# -*- coding: utf-8 -*-
"""局内加成窄契约：三张已抽出的牌进，排序 + evidence 出。

纪律：
- 只能重排本轮 offer 里的 id，不得发明第四张牌；
- 每条理由必须带 evidence（facts.* 或 growth.levels.* 或 rules.fallback）；
- **禁止**走 `dispatch_to_godot` / `adjutant_intent` / 代点。
Godot 才是落选权威；本模块超时未返回时由规则地板顶上。
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

from pydantic import BaseModel, ConfigDict, Field, ValidationError

HERMES_PROMPT = (
    "你是 Hermes。只对给出的三张局内加成牌排序。"
    "不得发明第四张牌，不得输出单位命令或 Godot 操作。"
    "每条理由必须带 evidence，路径只能是 facts.*、growth.levels.* 或 rules.fallback。"
    "没有把握时保持输入顺序并写 rules.fallback。"
)

_ALLOWED_EVIDENCE_PREFIX = ("facts.", "growth.levels.", "rules.")


class AugmentReason(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: str
    text: str
    evidence: List[str] = Field(min_length=1)


class AugmentRankResult(BaseModel):
    model_config = ConfigDict(extra="forbid")
    order: List[str]
    reasons: List[AugmentReason]
    source: str = "live"


def offer_ids(offer: List[Any]) -> List[str]:
    ids: List[str] = []
    for item in offer or []:
        if isinstance(item, dict):
            card_id = str(item.get("id") or "")
            if card_id:
                ids.append(card_id)
        elif item:
            ids.append(str(item))
    return ids


def is_permutation(order: List[str], ids: List[str]) -> bool:
    return sorted(str(x) for x in order) == sorted(str(x) for x in ids) and len(order) == len(ids)


def evidence_ok(paths: List[str]) -> bool:
    if not paths:
        return False
    for path in paths:
        text = str(path or "")
        if not text.startswith(_ALLOWED_EVIDENCE_PREFIX):
            return False
    return True


def rules_floor(offer: List[Any], facts: Optional[Dict[str, Any]] = None,
                profile: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """与 Godot AugmentRanker 同口径的规则地板。没有画像时 source=rules。"""
    facts = facts if isinstance(facts, dict) else {}
    profile = profile if isinstance(profile, dict) else {}
    scored: List[Dict[str, Any]] = []
    idx = 0
    for item in offer or []:
        if not isinstance(item, dict):
            continue
        card_id = str(item.get("id") or "")
        if not card_id:
            continue
        scored.append({
            "id": card_id,
            "score": _score(item, facts, profile),
            "idx": idx,
            "item": item,
        })
        idx += 1
    # ⚠️ 平局必须**显式**按键定序，不能依赖 `list.sort` 恰好稳定：
    # Godot 的 `Array.sort_custom` 官方不保证稳定（实测 n≤16 保序、n=32 起就乱），
    # 两侧地板要在平局上一致，只能靠 idx 这个显式契约，不能靠两个语言的排序实现巧合。
    scored.sort(key=lambda row: (-int(row["score"]), int(row["idx"])))
    order = [str(row["id"]) for row in scored]
    reasons = [_reason(row["item"], facts, profile) for row in scored]
    return {
        "order": order,
        "reasons": reasons,
        "source": "cache" if profile else "rules",
        "starred_id": order[0] if order else "",
    }


def sanitize_live(live: Dict[str, Any], ids: List[str],
                  floor: Dict[str, Any]) -> Dict[str, Any]:
    """非法排列 / 缺 evidence → 丢弃 live，退回地板。禁止编造。"""
    if not isinstance(live, dict):
        return floor
    order = [str(item) for item in (live.get("order") or [])]
    if not is_permutation(order, ids):
        return floor
    reasons_in = live.get("reasons") or []
    by_id = {}
    for row in reasons_in:
        if not isinstance(row, dict):
            continue
        card_id = str(row.get("id") or "")
        evidence = [str(item) for item in (row.get("evidence") or []) if str(item)]
        if card_id and evidence_ok(evidence):
            by_id[card_id] = {
                "id": card_id,
                "text": str(row.get("text") or "Hermes 按本局事实排序。"),
                "evidence": evidence,
            }
    if len(by_id) != len(ids):
        return floor
    reasons = [by_id[card_id] for card_id in order]
    return {
        "order": order,
        "reasons": reasons,
        "source": "live",
        "starred_id": order[0] if order else "",
    }


_UNSET = object()


def rank_offer(payload: Optional[Dict[str, Any]] = None, *,
               live: Any = _UNSET) -> Dict[str, Any]:
    """主入口。`live=_UNSET` 时尝试 PydanticAI；`live=None` 强制只用规则地板。"""
    data = payload if isinstance(payload, dict) else {}
    offer = data.get("offer") or []
    ids = offer_ids(offer)
    floor = rules_floor(offer, data.get("facts") or {}, data.get("profile") or {})
    if not ids:
        return floor
    if live is _UNSET:
        live = _try_live_rank(data)
    if not live:
        return floor
    return sanitize_live(live, ids, floor)


def _profile_level(profile: Dict[str, Any], node_id: str) -> int:
    levels = profile.get("levels") if isinstance(profile.get("levels"), dict) else {}
    if node_id in levels:
        return int(levels.get(node_id, 0) or 0)
    growth = profile.get("growth_levels") if isinstance(profile.get("growth_levels"), dict) else {}
    return int(growth.get(node_id, 0) or 0)


# 规则地板的数值口径。⚠️ 与 Godot `source/match/augments/AugmentRanker.gd`
# 的同名常量必须一致（`tests/test_augment_rank.py` 会读那个文件逐条核对）。
# `LOW_BALANCE_A` 是「近乎破产」检测，不是相对开局的比例。
LOW_BALANCE_A = 400
GRANT_UNIT_A = 1000
GRANT_BONUS_CAP = 6


def _score(item: Dict[str, Any], facts: Dict[str, Any], profile: Dict[str, Any]) -> int:
    score = 10
    if str(item.get("rarity") or "") == "gold":
        score += 8
    tag = str(item.get("tag") or "")
    army = int(facts.get("army_count", 0) or 0)
    balance = int(facts.get("balance_a", 0) or 0)
    enemies = int(facts.get("enemy_count", 0) or 0)
    if tag == "economy":
        score += 6 if balance < LOW_BALANCE_A else 2
        score += _profile_level(profile, "economy_gather") * 3
    elif tag == "construction":
        score += 4 if int(facts.get("structure_count", 0) or 0) >= 1 else 1
        score += _profile_level(profile, "construction_speed") * 3
    elif tag == "scout":
        score += 8 if enemies <= 0 else 2
    elif tag == "military":
        score += 8 if army < 4 else 3
        score += _profile_level(profile, "combat_power") * 3
        if enemies > army:
            score += 6
    # 额度加分与 tag 无关：「工程备料」是 construction 标签但同样给 5000，
    # 只在 economy 分支里加会让它拿不到本该有的权重，副官仍会把它排末位。
    score += _grant_bonus(item)
    return score


def _grant_bonus(item: Dict[str, Any]) -> int:
    """资金赠予卡的**额度本身**参与排序（与 Godot `AugmentRanker._grant_bonus` 同口径）。

    开局 10000，一张 5000 的「加钱」牌等于半个开局，不该只在「近乎破产」时才被看见；
    250 那种小额牌则不该白拿分。每 GRANT_UNIT_A 记 1 分，封顶 GRANT_BONUS_CAP。
    用截断而非四舍五入，避免与 GDScript 的 round 半进舍入规则分叉。
    ⚠️ 改这里必须同步改 `source/match/augments/AugmentRanker.gd`。
    """
    effect = item.get("effect") if isinstance(item.get("effect"), dict) else {}
    if str(effect.get("type") or "") != "resource_grant":
        return 0
    amount = int(effect.get("resource_a", 0) or 0)
    return max(0, min(GRANT_BONUS_CAP, int(amount / GRANT_UNIT_A)))


def _reason(item: Dict[str, Any], facts: Dict[str, Any],
            profile: Dict[str, Any]) -> Dict[str, Any]:
    tag = str(item.get("tag") or "")
    evidence: List[str] = []
    text = "规则按当前兵力与库存排序。"
    if tag == "economy":
        text = "库存偏低、或这张牌能立刻补一大笔资金时优先经济。"
        evidence.append("facts.balance_a")
        if _profile_level(profile, "economy_gather") > 0:
            evidence.append("growth.levels.economy_gather")
    elif tag == "military":
        text = "作战单位少或对面可见兵力更多时优先军事。"
        evidence.append("facts.army_count")
        if _profile_level(profile, "combat_power") > 0:
            evidence.append("growth.levels.combat_power")
    elif tag == "scout":
        text = "还没有稳定敌情时优先侦察视野。"
        evidence.append("facts.enemy_count")
    elif tag == "construction":
        text = "已有基地时加固或备料更划算。"
        evidence.append("facts.structure_count")
    if not evidence:
        evidence.append("rules.fallback")
        text = "无画像数据，使用规则地板默认序。"
    return {"id": str(item.get("id") or ""), "text": text, "evidence": evidence}


_LIVE_AGENT: Any = None


def _try_live_rank(payload: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """PydanticAI Hermes 角色。失败返回 None，由调用方用规则地板。"""
    global _LIVE_AGENT
    try:
        from .pydantic_agents import (
            GraphModelSettings, ModelInvalidOutput, ModelTimeout, ModelUnavailable,
            ROLE_HERMES, _PydanticAgentBase, pydantic_ai_available,
        )
    except Exception:  # noqa: BLE001
        return None
    probe = pydantic_ai_available()
    if not probe.get("available"):
        return None
    if _LIVE_AGENT is False:
        return None
    if _LIVE_AGENT is None:
        class HermesAugmentAgent(_PydanticAgentBase):
            system_prompt = HERMES_PROMPT
            output_type = AugmentRankResult

            def __init__(self, settings: Any, model: Any = None) -> None:
                super().__init__(ROLE_HERMES, settings, model)

            def rank(self, context: Dict[str, Any]) -> Any:
                return self._run(context)

        try:
            _LIVE_AGENT = HermesAugmentAgent(GraphModelSettings.from_env())
        except ModelUnavailable:
            _LIVE_AGENT = False
            return None
    agent = _LIVE_AGENT
    if agent is False or agent is None:
        return None
    try:
        result = agent.rank({
            "offer": payload.get("offer") or [],
            "facts": payload.get("facts") or {},
            "profile": payload.get("profile") or {},
        })
    except (ModelUnavailable, ModelTimeout, ModelInvalidOutput, ValidationError):
        return None
    except Exception:  # noqa: BLE001 —— 模型链路任何失败都降级，不堵选牌
        return None
    if result is None:
        return None
    if hasattr(result, "model_dump"):
        return result.model_dump()
    if isinstance(result, dict):
        return result
    return None
