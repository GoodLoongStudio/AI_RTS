# -*- coding: utf-8 -*-
"""副官模型 Provider 稳定接口（第二阶段离线准备）。

设计纪律（architecture.md §1、§5）：
- Provider 接口只承载结构与语义：输入观测/计划版本/请求 ID/截止时间/预算/取消状态，
  输出结构化的完成/拒绝/超时/错误/取消结果。
- API 凭证、具体模型名称、网络客户端一律不进入协调器核心：
  真实 provider 由宿主在装配时注入，核心只依赖本模块的抽象。
- Provider 契约要求 propose() 快速返回 ModelOutcome（不做长阻塞 IO）；
  真实异步 provider 的网络细节由其自身实现管理，调度器不等待网络。
"""

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional

# ModelOutcome.status 的稳定取值。
OUTCOME_COMPLETED = "completed"    # 正常产出（payload 为计划或命令列表）
OUTCOME_REJECTED = "rejected"      # provider 侧主动拒绝（如预算/内容策略）
OUTCOME_TIMEOUT = "timeout"        # provider 侧判定超时（调度器另按代际复核）
OUTCOME_ERROR = "error"            # provider 内部错误（可带 retryable 标记）
OUTCOME_CANCELLED = "cancelled"    # 请求在产出前被取消

OUTCOME_STATUSES = (
    OUTCOME_COMPLETED, OUTCOME_REJECTED, OUTCOME_TIMEOUT,
    OUTCOME_ERROR, OUTCOME_CANCELLED,
)

ROLE_STRATEGY = "strategy"
ROLE_TACTICS = "tactics"


@dataclass
class ModelCallContext:
    """一次模型调用的完整输入语义；调度器构造，provider 只读。"""

    request_id: str
    role: str
    match_id: str
    player_id: str
    rules_version: str
    plan_version: str = ""
    snapshot_id: int = 0
    server_tick: int = 0
    issued_tick: int = 0
    deadline_tick: int = 0
    budget: Dict[str, int] = field(default_factory=dict)
    observation: Dict[str, Any] = field(default_factory=dict)
    # 取消状态查询：provider 应在长耗时阶段周期性检查（离线假模型立即检查一次）。
    is_cancelled: Optional[Callable[[], bool]] = None

    def cancelled(self) -> bool:
        if self.is_cancelled is None:
            return False
        try:
            return bool(self.is_cancelled())
        except Exception:  # 取消钩子异常不改变主流程（记录权在调度器）。
            return False


@dataclass
class ModelOutcome:
    """模型调用的结构化结果。

    available_at_tick 用于离线模拟"迟到返回"：
    调度器在 server_tick < available_at_tick 时视为结果未就绪（挂起）；
    若 available_at_tick > deadline_tick，结果按 stale 丢弃，不抢回控制。
    """

    status: str
    role: str
    request_id: str
    payload: Any = None                      # 计划 dict 或命令 list；拒绝/错误时为 None
    reason: str = ""
    retryable: bool = False
    available_at_tick: int = 0               # 0 = 立即可用
    raw: Any = None                          # 原始输出留证（如 malformed payload）

    def is_late_at(self, server_tick: int, deadline_tick: int) -> bool:
        if self.available_at_tick <= 0:
            return False
        return self.available_at_tick > server_tick or self.available_at_tick > deadline_tick

    def validate(self) -> List[str]:
        """结构自检；返回错误列表（空 = 合法）。

        completed + payload=None 是合法空响应（空响应属正常业务路径，
        由调度器按空处理）；payload 内容合法性由协议层判定。
        """
        errors: List[str] = []
        if self.status not in OUTCOME_STATUSES:
            errors.append("status: 未知结果状态 %r" % (self.status,))
        if not self.request_id:
            errors.append("request_id: 不能为空")
        if self.role not in (ROLE_STRATEGY, ROLE_TACTICS):
            errors.append("role: 未知角色 %r" % (self.role,))
        return errors


class StrategyProvider(ABC):
    """战略角色：输出阶段计划；不直接调用游戏命令。"""

    @abstractmethod
    def propose(self, context: ModelCallContext) -> ModelOutcome:
        raise NotImplementedError


class TacticsProvider(ABC):
    """战术角色：按计划与局部事件提出有限命令批次。"""

    @abstractmethod
    def propose(self, context: ModelCallContext) -> ModelOutcome:
        raise NotImplementedError


class LegacyModelAdapter(StrategyProvider, TacticsProvider):
    """把第一阶段 Legacy 模型接口（返回裸 dict/list）适配为 Provider。

    兼容规则：
    - 返回 dict（战略）→ completed；
    - 返回 list（战术）→ completed；
    - 返回 None / 空列表 → completed + 空 payload（由上层按空响应处理）；
    - 抛异常 → error（retryable=True，退避权在调度器）。
    这样第一阶段测试与既有 FakeStrategyModel/FakeTacticsModel 无需改动。
    """

    def __init__(self, legacy_model: Any, role: str) -> None:
        self._legacy = legacy_model
        self._role = role

    def propose(self, context: ModelCallContext) -> ModelOutcome:
        try:
            if self._role == ROLE_STRATEGY:
                payload = self._legacy.propose_plan(self._legacy_context(context))
            else:
                payload = self._legacy.propose_commands(self._legacy_context(context))
        except Exception as exc:  # noqa: BLE001 —— 异常转结构化 error，不在核心炸断。
            return ModelOutcome(status=OUTCOME_ERROR, role=self._role,
                                request_id=context.request_id,
                                reason="legacy model raised: %s" % exc, retryable=True)
        if payload is None or (isinstance(payload, list) and not payload):
            return ModelOutcome(status=OUTCOME_COMPLETED, role=self._role,
                                request_id=context.request_id, payload=None,
                                reason="empty response")
        return ModelOutcome(status=OUTCOME_COMPLETED, role=self._role,
                            request_id=context.request_id, payload=payload)

    @staticmethod
    def _legacy_context(context: ModelCallContext) -> Dict[str, Any]:
        # 第一阶段 legacy 模型消费扁平 dict 观测；保留全部语义字段。
        return {
            "request_id": context.request_id,
            "match_id": context.match_id,
            "player_id": context.player_id,
            "rules_version": context.rules_version,
            "plan_version": context.plan_version,
            "snapshot_id": context.snapshot_id,
            "server_tick": context.server_tick,
            "current_tick": context.server_tick,
            "issued_tick": context.issued_tick,
            "deadline_tick": context.deadline_tick,
            "budget": dict(context.budget),
            **(context.observation or {}),
        }
