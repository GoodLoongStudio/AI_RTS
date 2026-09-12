# -*- coding: utf-8 -*-
"""运行时桥接：对局状态/观测 → `DecisionFrame`，四列输出 → 既有意图链。

依据（设计 §2.2）：
- 元数据只能取自**发起请求时**的 `DecisionFrame`（不可在结果到达时换成最新代际）；
- 旧 `StrategicPlan` 不再是模型必须先生成成功才能下令的前置条件：模型选中的任务
  由程序展开成内部兼容计划/意图，身份与版本由程序给；
- 程序**不**补充模型未选择的战略任务（旧"发展阶梯"只允许在降级路径使用）。

本模块只做转换，不做调度（调度在 runner 与图节点）。
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional, Set, Tuple

from .squads import build_decision_frame
from .task_patch import (
    ACTION_TO_SKILL, MODE_FAST, DecisionFrame, DecodeResult, TaskPatchBatch,
    decode_task_patch, effective_max_rows, modifications_to_intents,
)

#: 观测/状态里读取字段的缺省（缺失即视为空，不伪造）。
_DEFAULT_TTL = 3600
_DEFAULT_EMERGENCY_TTL = 1200


def frame_from_state(state: Any, observation: Dict[str, Any],
                     *, mode: str = MODE_FAST,
                     authoritative_squads: Optional[List[Dict[str, Any]]] = None
                     ) -> DecisionFrame:
    """用**当前轮**的状态与观测构造 `DecisionFrame`（所有元数据的唯一来源）。"""
    header = dict((observation or {}).get("header") or {})
    tactical = (observation or {}).get("tactical")
    rules = (observation or {}).get("rules")
    authorized: Optional[Set[str]] = None
    ai_units = _get(state, "ai_controlled_units")
    if isinstance(ai_units, (list, tuple, set)):
        authorized = {str(u) for u in ai_units if str(u)}
    generations = _get(state, "unit_generations")
    if not isinstance(generations, dict):
        generations = {}
    task_versions: Dict[str, int] = {}
    for squad in (authoritative_squads or []):
        try:
            task_versions[str(squad.get("squad_id") or squad.get("id"))] = int(
                squad.get("task_version", 0) or 0)
        except (TypeError, ValueError):
            continue
    current_tasks = current_tasks_from_intents(
        _get(state, "active_intents") or [], tactical=tactical)
    return build_decision_frame(
        match_id=str(header.get("match_id") or _get(state, "match_id") or ""),
        player_id=str(header.get("player_id") or _get(state, "player_id") or ""),
        rules_version=str(header.get("rules_version")
                          or _get(state, "rules_version") or ""),
        snapshot_id=int(header.get("snapshot_id") or 0),
        server_tick=int(header.get("server_tick") or 0),
        tactical=tactical, rules=rules, mode=mode,
        authorized_units=authorized,
        generations={str(k): int(v or 0) for k, v in generations.items()},
        task_versions=task_versions,
        authoritative_squads=authoritative_squads,
        current_tasks=current_tasks,
        plan_version=str(_get(state, "plan_version") or ""),
        phase_goal=str(((_get(state, "active_plan") or {}) or {}).get("phase_goal", "")),
        intent_ttl_ticks=int(_get(state, "intent_ttl_ticks") or _DEFAULT_TTL),
        emergency_intent_ttl_ticks=int(
            _get(state, "emergency_intent_ttl_ticks") or _DEFAULT_EMERGENCY_TTL),
    )


#: 视为"已结束"的意图状态（不再算作执行者正在执行的任务）。
_TERMINAL_INTENT_STATES = ("dropped", "completed", "failed", "expired", "done",
                           "cancelled", "rejected")


def current_tasks_from_intents(intents: Any, *, tactical: Any = None
                               ) -> Dict[str, Dict[str, Any]]:
    """把**仍在执行的意图**整理成"执行者 → 当前任务"（按单位名索引）。

    用途：① 渲染进模型输入表（已在执行的任务不要重复输出）；② 解码时判定"这行等于现状"
    → 记为 `unchanged`，不下发新命令。实测依据（2026-09-12 用户反馈）：模型没有记忆，
    每轮都会把同一行（如"W1 采集 R13"）重发一次，若不判定未变化，工人采集会被反复下令
    （行为树本来就会自己循环，重复命令纯属噪声，还会挤占配额、触发代际冲突）。
    """
    out: Dict[str, Dict[str, Any]] = {}
    for intent in intents or []:
        if not isinstance(intent, dict):
            continue
        if str(intent.get("state", "")) in _TERMINAL_INTENT_STATES:
            continue
        skill = ACTION_TO_SKILL.get(str(intent.get("action", "")))
        if not skill:
            continue
        entry = {"skill": skill, "action": str(intent.get("action", "")),
                 "target": dict(intent.get("target") or {})}
        for unit in intent.get("unit_ids") or []:
            out[str(unit)] = dict(entry)
    return out


def expand_patch(batch: TaskPatchBatch, frame: DecisionFrame
                 ) -> Tuple[Any, DecodeResult]:
    """四列输出 → (IntentBatch, 解码结果)。解码结果供逐项回执与日志留痕。"""
    result = decode_task_patch(batch, frame, max_rows=effective_max_rows(frame))
    return modifications_to_intents(result, frame), result


def patch_to_intent_dicts(intent_batch: Any) -> List[Dict[str, Any]]:
    """意图 → 候选意图 dict（与旧路径 `parsed.intents` 展开后的形状一致）。"""
    return [intent.to_dict() for intent in getattr(intent_batch, "intents", []) or []]


def summarize_decode(result: Optional[DecodeResult]) -> Dict[str, Any]:
    """给日志/面板用的一句摘要（不含隐藏推理，只含可复核字段）。"""
    if result is None:
        return {"rows": 0, "accepted": 0, "rejected": 0, "reject_reasons": []}
    return {
        "rows": len(result.modifications) + len(result.rejections),
        "accepted": len(result.modifications),
        # 其中"复述现状"的行数（与执行者当前任务相同）：这类行**不下发命令**，
        # 是"没有变化"而不是"又下了一次令"（用户实测反馈：工人采集被反复下令）。
        "unchanged": len(result.unchanged),
        "rejected": len(result.rejections),
        "reject_reasons": sorted({item.reason for item in result.rejections}),
        "actors": sorted({item.actor_ref for item in result.modifications}),
        "skills": sorted({item.skill for item in result.modifications}),
    }


def _get(state: Any, key: str) -> Any:
    if isinstance(state, dict):
        return state.get(key)
    return getattr(state, key, None)
