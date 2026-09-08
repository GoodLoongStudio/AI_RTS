# -*- coding: utf-8 -*-
"""确定性离线假模型（协议与调度测试专用，不构成真实模型闭环）。

支持的 behavior（脚本条目，按序消费；耗尽后返回空响应）：
- completed  : 正常产出（strategy 提供 plan，tactics 提供 commands）
- timeout    : 返回 timeout 结果（调度器保留当前计划）
- error      : 返回 error 结果（可配 retryable）
- empty      : completed 且 payload=None（空响应路径）
- malformed  : completed 且 payload 为非法结构（协议校验拒绝路径）
- late       : completed 且 available_at_tick = arrives_at_tick（迟到返回路径）
- raise      : provider 抛出运行时异常（调度器异常捕获路径）

全部确定性：无随机、无睡眠、无网络；时钟由 ModelCallContext 注入。
"""

from typing import Any, Dict, List, Optional

from .provider import (
    ModelCallContext, ModelOutcome, OUTCOME_COMPLETED, OUTCOME_ERROR,
    OUTCOME_TIMEOUT, ROLE_STRATEGY,
)


class ScriptedProviderBase:
    """按脚本序列返回 ModelOutcome 的确定性 provider 基类。"""

    def __init__(self, role: str, script: Optional[List[Dict[str, Any]]] = None) -> None:
        self._role = role
        self._script = list(script or [])
        self.calls: List[ModelCallContext] = []

    def propose(self, context: ModelCallContext) -> ModelOutcome:
        self.calls.append(context)
        if context.cancelled():
            return ModelOutcome(status=OUTCOME_COMPLETED, role=self._role,
                                request_id=context.request_id, payload=None,
                                reason="cancelled before propose")
        if not self._script:
            return ModelOutcome(status=OUTCOME_COMPLETED, role=self._role,
                                request_id=context.request_id, payload=None,
                                reason="script exhausted (empty)")
        step = self._script.pop(0)
        return self._render(step, context)

    def _render(self, step: Dict[str, Any], context: ModelCallContext) -> ModelOutcome:
        behavior = str(step.get("behavior", "completed"))
        base = {"role": self._role, "request_id": context.request_id}
        if behavior == "completed":
            payload = step.get("plan") if self._role == ROLE_STRATEGY else step.get("commands")
            return ModelOutcome(status=OUTCOME_COMPLETED, payload=payload, **base)
        if behavior == "timeout":
            return ModelOutcome(status=OUTCOME_TIMEOUT,
                                reason=str(step.get("reason", "provider timeout")), **base)
        if behavior == "error":
            return ModelOutcome(status=OUTCOME_ERROR,
                                reason=str(step.get("reason", "provider error")),
                                retryable=bool(step.get("retryable", True)), **base)
        if behavior == "empty":
            return ModelOutcome(status=OUTCOME_COMPLETED, payload=None,
                                reason="empty response", **base)
        if behavior == "malformed":
            # 故意非法的结构：交给协议校验拒绝（不在这里伪装合法）。
            payload = step.get("payload", {"not": "a valid plan"})
            return ModelOutcome(status=OUTCOME_COMPLETED, payload=payload,
                                reason="malformed payload", **base)
        if behavior == "late":
            arrives = int(step.get("arrives_at_tick", context.deadline_tick + 1))
            payload = step.get("plan") if self._role == ROLE_STRATEGY else step.get("commands")
            return ModelOutcome(status=OUTCOME_COMPLETED, payload=payload,
                                available_at_tick=arrives,
                                reason="late arrival at %d" % arrives, **base)
        if behavior == "raise":
            raise RuntimeError(str(step.get("reason", "scripted provider exception")))
        return ModelOutcome(status=OUTCOME_ERROR, payload=None,
                            reason="unknown behavior %r" % behavior, **base)

    # 供测试断言注入确实发生。
    @property
    def call_count(self) -> int:
        return len(self.calls)


class ScriptedStrategyProvider(ScriptedProviderBase):
    """战略角色假模型：脚本条目用 plan 键携带计划。"""

    def __init__(self, script: Optional[List[Dict[str, Any]]] = None) -> None:
        super().__init__(ROLE_STRATEGY, script)


class ScriptedTacticsProvider(ScriptedProviderBase):
    """战术角色假模型：脚本条目用 commands 键携带命令列表。"""

    def __init__(self, script: Optional[List[Dict[str, Any]]] = None) -> None:
        super().__init__("tactics", script)


def make_valid_plan(plan_id: str = "plan-a", version: int = 1,
                    match_id: str = "m-1", player_id: str = "Player_1",
                    rules_version: str = "hash-1", tasks: Optional[List[Dict]] = None) -> Dict:
    """构造一个协议合法的最小计划（测试辅助；与 test_coordinator.make_plan 同构）。"""
    return {
        "plan_id": plan_id,
        "plan_version": version,
        "match_id": match_id,
        "player_id": player_id,
        "rules_version": rules_version,
        "based_on_snapshot": 1,
        "valid_until_tick": 100000,
        "phase_goal": "离线假模型阶段目标",
        "tasks": tasks if tasks is not None else [
            {"task_id": "t-1", "priority": 1, "completion": "完成条件"},
        ],
        "reserves": {},
        "rationale": "离线协议测试",
    }
