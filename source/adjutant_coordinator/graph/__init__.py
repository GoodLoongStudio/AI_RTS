# -*- coding: utf-8 -*-
"""副官 LangGraph 重构包（单局一副官状态图）。

职责划分（docs/plan/AI副官_LangGraph重构方案.md §1）：
- 本包负责单局副官状态、战略/战术编排、玩家打断、恢复与仲裁；
- PydanticAI 只作为图内的结构化模型节点（pydantic_agents.py）；
- Godot 仍是唯一权威执行入口（CommandRuntime / UnitCommandGateway）；
- 长期记忆与玩家画像在 Hermes 侧，不在本包内。

依赖纪律：
- 核心图逻辑只依赖标准库 + pydantic（契约校验）；
- langgraph / pydantic-ai 为可选依赖：缺失时走等价的内置确定性执行器
  （graph.py 的 FallbackRunner），测试不需要 API Key、不需要额外安装。
"""

from .contracts import (  # noqa: F401
    ALLOWED_ACTIONS, ContractError, IntentBatch, PlayerControlEvent,
    StrategicPlan, TacticalIntent, parse_intent_batch, parse_strategic_plan,
)
from .state import AdjutantGraphState, CHECKPOINT_VERSION  # noqa: F401

__all__ = [
    "ALLOWED_ACTIONS", "ContractError", "IntentBatch", "PlayerControlEvent",
    "StrategicPlan", "TacticalIntent", "parse_intent_batch",
    "parse_strategic_plan", "AdjutantGraphState", "CHECKPOINT_VERSION",
]
