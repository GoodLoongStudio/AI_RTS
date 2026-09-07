# -*- coding: utf-8 -*-
"""离线模型沙盒（第三阶段）：固定战况快照下的 Provider 协议演练。

边界（本轮硬约束）：
- 只做"生成计划/任务/命令 + 协议校验 + 计划采纳代际演练"；
- 不连接正式对局、不发送任何真实游戏命令、没有 transport；
- 默认且唯一入口为 Fake 模式；真实 HTTP Provider 只能在测试里以
  脚本假客户端驱动，沙盒 CLI 不提供任何联网选项。

固定快照是纯离线示例数据，不代表任何真实对局状态。
"""

import time
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

from .provider import (
    ModelCallContext, ModelOutcome, OUTCOME_COMPLETED, ROLE_STRATEGY,
)
from .protocol import validate_command_envelope, validate_plan
from .redaction import REDACTED
from .state import PlanStore

SANDBOX_MATCH_ID = "sandbox-match"
SANDBOX_PLAYER_ID = "Player_1"
SANDBOX_RULES_VERSION = "sandbox-rules-v1"

# 固定战况快照（离线示例；结构对齐游戏侧 op=tactical 输出的子集）。
FIXED_SNAPSHOT: Dict[str, Any] = {
    "schema_version": 1,
    "match_id": SANDBOX_MATCH_ID,
    "player_id": SANDBOX_PLAYER_ID,
    "rules_version": SANDBOX_RULES_VERSION,
    "snapshot_id": 1,
    "server_tick": 0,
    "balance": {"a": 8000, "b": 500},
    "map_bounds": [50.0, 50.0],
    "production_relations": [
        {"product_type_id": "worker", "cost": [{"kind": "A", "amount": 200}],
         "allowed_producer_type_ids": ["command_center"]},
        {"product_type_id": "tank", "cost": [{"kind": "A", "amount": 500}],
         "allowed_producer_type_ids": ["vehicle_factory"]},
    ],
    "entities": [
        {"kind": "unit_self", "name": "Unit_0", "unit_type": "command_center",
         "hp": 20.0, "hp_max": 20.0, "pos": [10.0, 0.0, 10.0], "queue": True,
         "constructed": True},
        {"kind": "unit_self", "name": "Unit_1", "unit_type": "worker",
         "hp": 6.0, "hp_max": 6.0, "pos": [12.0, 0.0, 11.0], "movement": True,
         "construct": True},
        {"kind": "unit_self", "name": "Unit_2", "unit_type": "worker",
         "hp": 6.0, "hp_max": 6.0, "pos": [11.0, 0.0, 12.0], "movement": True,
         "construct": True},
        {"kind": "resource", "name": "ResourceA1", "resource_kind": "a",
         "pos": [16.0, 0.0, 14.0]},
    ],
    "enemy_intel": [],
    "truncated": False,
}

# 沙盒固定预算（副官花费约束演示；非游戏余额）。
SANDBOX_BUDGET = {"A": 2000}


@dataclass
class RoundRecord:
    """单轮沙盒结果留证。"""

    round_index: int
    server_tick: int
    plan_status: str = ""          # adopted / rejected / stale / empty / error
    plan_reason: str = ""
    commands_total: int = 0
    commands_valid: int = 0
    commands_invalid: int = 0
    invalid_details: List[str] = field(default_factory=list)
    outcome_errors: List[str] = field(default_factory=list)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "round_index": self.round_index,
            "server_tick": self.server_tick,
            "plan_status": self.plan_status,
            "plan_reason": self.plan_reason,
            "commands_total": self.commands_total,
            "commands_valid": self.commands_valid,
            "commands_invalid": self.commands_invalid,
            "invalid_details": list(self.invalid_details),
            "outcome_errors": list(self.outcome_errors),
        }


class ModelSandbox:
    """固定快照沙盒：Provider 输出 → 协议校验 → 计划代际演练。

    不持有 transport、不触碰网络与游戏进程。
    """

    def __init__(self, strategy_provider, tactics_provider,
                 match_id: str = SANDBOX_MATCH_ID,
                 player_id: str = SANDBOX_PLAYER_ID,
                 rules_version: str = SANDBOX_RULES_VERSION,
                 snapshot: Optional[Dict[str, Any]] = None,
                 request_timeout_ticks: int = 150,
                 logger: Optional[Any] = None) -> None:
        self.strategy = strategy_provider
        self.tactics = tactics_provider
        self.match_id = match_id
        self.player_id = player_id
        self.rules_version = rules_version
        self.snapshot = dict(snapshot or FIXED_SNAPSHOT)
        self.request_timeout_ticks = request_timeout_ticks
        self.logger = logger
        self.plan_store = PlanStore()
        self.rounds: List[RoundRecord] = []
        self.cancelled = False

    # ---------- 轮次 ----------

    def run_round(self, round_index: int, server_tick: int) -> RoundRecord:
        record = RoundRecord(round_index=round_index, server_tick=server_tick)
        context = self._make_context(round_index, server_tick)

        # --- 战略：产出 → 协议校验 → 代际采纳 ---
        strategy_outcome = self._safe_propose(self.strategy, context)
        if strategy_outcome is not None:
            self._absorb_strategy(strategy_outcome, context, record)

        # --- 战术：产出 → 逐条命令校验（不发送任何游戏命令） ---
        tactics_outcome = self._safe_propose(self.tactics, context)
        if tactics_outcome is not None:
            self._absorb_tactics(tactics_outcome, context, record)

        self.rounds.append(record)
        if self.logger is not None:
            self.logger.log("sandbox_round", status=record.plan_status or "empty",
                            server_tick=server_tick,
                            round_index=round_index,
                            plan_reason=record.plan_reason,
                            commands_valid=record.commands_valid,
                            commands_invalid=record.commands_invalid)
        return record

    # ---------- 战略吸收 ----------

    def _absorb_strategy(self, outcome: ModelOutcome, context: ModelCallContext,
                         record: RoundRecord) -> None:
        errors = outcome.validate()
        if errors:
            record.plan_status = "invalid"
            record.plan_reason = "; ".join(errors)
            record.outcome_errors.extend(errors)
            return
        if outcome.available_at_tick > 0 and \
                outcome.available_at_tick > context.deadline_tick:
            record.plan_status = "stale"
            record.plan_reason = "arrives %d > deadline %d" % (
                outcome.available_at_tick, context.deadline_tick)
            return
        if outcome.status != OUTCOME_COMPLETED:
            record.plan_status = outcome.status
            record.plan_reason = outcome.reason
            return
        plan = outcome.payload
        if plan is None:
            record.plan_status = "empty"
            record.plan_reason = "empty response"
            return
        plan_errors = validate_plan(plan, self._plan_context(context))
        if plan_errors:
            record.plan_status = "invalid"
            record.plan_reason = "; ".join(plan_errors)
            record.outcome_errors.extend(plan_errors)
            return
        accepted, reason = self.plan_store.submit(plan, context.server_tick)
        record.plan_status = "adopted" if accepted else "rejected"
        record.plan_reason = reason

    # ---------- 战术吸收 ----------

    def _absorb_tactics(self, outcome: ModelOutcome, context: ModelCallContext,
                        record: RoundRecord) -> None:
        errors = outcome.validate()
        if errors:
            record.outcome_errors.extend(errors)
            return
        if outcome.available_at_tick > 0 and \
                outcome.available_at_tick > context.deadline_tick:
            record.plan_reason = record.plan_reason or "tactics stale: arrives %d > deadline %d" % (
                outcome.available_at_tick, context.deadline_tick)
            return
        if outcome.status != OUTCOME_COMPLETED:
            record.outcome_errors.append("%s: %s" % (outcome.status, outcome.reason))
            return
        commands = outcome.payload
        if not commands:
            return
        if not isinstance(commands, list):
            record.outcome_errors.append("commands payload is not a list")
            return
        plan_context = self._plan_context(context)
        for command in commands:
            record.commands_total += 1
            command_errors = validate_command_envelope(command, plan_context)
            if command_errors:
                record.commands_invalid += 1
                record.invalid_details.append(
                    "%s: %s" % (command.get("command_id", "?") if isinstance(command, dict) else "?",
                                "; ".join(command_errors)))
            else:
                record.commands_valid += 1

    # ---------- 辅助 ----------

    def _safe_propose(self, provider, context: ModelCallContext) -> Optional[ModelOutcome]:
        try:
            return provider.propose(context)
        except Exception as exc:  # noqa: BLE001 —— provider 异常留证不炸沙盒。
            return ModelOutcome(status="error", role=context.role,
                                request_id=context.request_id,
                                reason="provider raised: %s" % exc)

    def _make_context(self, round_index: int, server_tick: int) -> ModelCallContext:
        return ModelCallContext(
            request_id="sandbox-%d" % round_index,
            role=ROLE_STRATEGY,  # 角色由各 provider 自身语义决定；上下文仅承载身份。
            match_id=self.match_id,
            player_id=self.player_id,
            rules_version=self.rules_version,
            plan_version=self.plan_store.plan_version(),
            snapshot_id=int(self.snapshot.get("snapshot_id", 0)),
            server_tick=server_tick,
            issued_tick=server_tick,
            deadline_tick=server_tick + self.request_timeout_ticks,
            budget=dict(SANDBOX_BUDGET),
            observation=dict(self.snapshot),
            is_cancelled=lambda: self.cancelled,
        )

    def _plan_context(self, context: ModelCallContext) -> Dict[str, Any]:
        return {
            "match_id": self.match_id,
            "player_id": self.player_id,
            "rules_version": self.rules_version,
            "current_tick": context.server_tick,
            "latest_snapshot_id": int(self.snapshot.get("snapshot_id", 0)),
        }

    # ---------- 汇总 ----------

    def summary(self) -> Dict[str, Any]:
        totals = {"rounds": len(self.rounds), "plans_adopted": 0,
                  "plans_rejected": 0, "commands_valid": 0, "commands_invalid": 0}
        for record in self.rounds:
            if record.plan_status == "adopted":
                totals["plans_adopted"] += 1
            elif record.plan_status == "rejected":
                totals["plans_rejected"] += 1
            totals["commands_valid"] += record.commands_valid
            totals["commands_invalid"] += record.commands_invalid
        return {
            "sandbox": "offline-fake-only",
            "match_id": self.match_id,
            "player_id": self.player_id,
            "rules_version": self.rules_version,
            "totals": totals,
            "rounds": [r.to_dict() for r in self.rounds],
            # 明确声明：无凭证、无网络、无游戏命令。
            "api_key": REDACTED,
            "network": "none",
            "game_commands_sent": 0,
        }


def run_fake_sandbox(rounds: int = 2, strategy_provider=None, tactics_provider=None,
                     logger=None) -> Dict[str, Any]:
    """离线沙盒入口：默认 Fake 模式；不接受任何联网配置。"""
    if strategy_provider is None:
        from .fakes import ScriptedStrategyProvider, make_valid_plan
        strategy_provider = ScriptedStrategyProvider([
            {"behavior": "completed", "plan": make_valid_plan(
                plan_id="sandbox-plan", version=index + 1,
                match_id=SANDBOX_MATCH_ID, player_id=SANDBOX_PLAYER_ID,
                rules_version=SANDBOX_RULES_VERSION)}
            for index in range(max(1, rounds))
        ])
    if tactics_provider is None:
        from .fakes import ScriptedTacticsProvider
        tactics_provider = ScriptedTacticsProvider([])
    sandbox = ModelSandbox(strategy_provider, tactics_provider, logger=logger)
    for index in range(max(1, rounds)):
        sandbox.run_round(index + 1, server_tick=100 * (index + 1))
    return sandbox.summary()


if __name__ == "__main__":
    import argparse
    import json as _json
    import os as _os
    import sys as _sys

    _sys.path.insert(0, _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__))))

    parser = argparse.ArgumentParser(description="离线模型沙盒（Fake 模式，无网络无游戏命令）")
    parser.add_argument("--rounds", type=int, default=2)
    args = parser.parse_args()
    print(_json.dumps(run_fake_sandbox(rounds=args.rounds),
                      ensure_ascii=False, indent=2))
