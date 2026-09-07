# -*- coding: utf-8 -*-
"""副官协议数据结构：计划、任务、命令包、回执。

所有契约字段与 docs/ai-adjutant-dual-layer/architecture.md 第 3 节对应；
校验失败返回结构化错误，不抛裸异常（便于模型输出校验循环）。
"""

from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

# 计划/命令契约的当前 schema 版本（与游戏侧包头 schema_version 对齐）。
SCHEMA_VERSION = 1

REQUIRED_COMMAND_FIELDS = (
    "command_id", "request_id", "match_id", "player_id", "rules_version",
    "plan_version", "task_id", "based_on_snapshot", "issued_tick",
    "expires_tick", "action",
)

REQUIRED_PLAN_FIELDS = (
    "plan_id", "plan_version", "match_id", "player_id", "rules_version",
    "based_on_snapshot", "valid_until_tick", "phase_goal", "tasks",
)

# 命令包中计划/任务关联字段允许为空（自由行动命令），但存在即须为字符串。
OPTIONAL_STRING_FIELDS = ("task_id", "plan_version", "request_id")


def _errors_append(errors: List[str], path: str, message: str) -> None:
    errors.append("%s: %s" % (path, message))


def validate_command_envelope(command: Any, context: Dict[str, Any]) -> List[str]:
    """校验单个命令包；context 提供 match_id/player_id/rules_version/current_tick。

    返回错误列表（空列表 = 合法）。规则：
    - 必填字段齐全且类型正确；
    - 对局/玩家/规则版本必须与当前一致；
    - expires_tick 必须为正且未过期（以服务器 tick 为准）；
    - based_on_snapshot 不得晚于当前已知快照。
    """
    errors: List[str] = []
    if not isinstance(command, dict):
        return ["$: 命令包必须是对象"]
    for name in REQUIRED_COMMAND_FIELDS:
        if name not in command:
            _errors_append(errors, name, "缺少必填字段")
    if errors:
        return errors
    for name in ("command_id", "match_id", "player_id", "rules_version", "action"):
        value = command.get(name)
        if not isinstance(value, str) or not value:
            _errors_append(errors, name, "必须是非空字符串")
    current_tick = context.get("current_tick", 0)
    expires_tick = command.get("expires_tick")
    if not isinstance(expires_tick, int) or expires_tick <= 0:
        _errors_append(errors, "expires_tick", "必须是正整数（服务器 tick）")
    elif current_tick > expires_tick:
        _errors_append(errors, "expires_tick", "命令已过期（当前 tick %s）" % current_tick)
    issued_tick = command.get("issued_tick")
    if not isinstance(issued_tick, int) or issued_tick < 0:
        _errors_append(errors, "issued_tick", "必须是非负整数（服务器 tick）")
    based_on_snapshot = command.get("based_on_snapshot")
    if not isinstance(based_on_snapshot, int):
        _errors_append(errors, "based_on_snapshot", "必须是整数快照序号")
    else:
        latest = context.get("latest_snapshot_id")
        if latest is not None and based_on_snapshot > latest:
            _errors_append(errors, "based_on_snapshot", "晚于当前已知快照")
    if context.get("match_id") and command["match_id"] != context["match_id"]:
        _errors_append(errors, "match_id", "与当前对局不一致")
    if context.get("player_id") and command["player_id"] != context["player_id"]:
        _errors_append(errors, "player_id", "与授权玩家不一致")
    if context.get("rules_version") and command["rules_version"] != context["rules_version"]:
        _errors_append(errors, "rules_version", "与当前对局规则不一致")
    params = command.get("params", {})
    if not isinstance(params, dict):
        _errors_append(errors, "params", "必须是对象")
    return errors


def validate_plan(plan: Any, context: Dict[str, Any]) -> List[str]:
    """校验战略计划：必填语义、版本递增由 PlanStore 采纳时检查。"""
    errors: List[str] = []
    if not isinstance(plan, dict):
        return ["$: 计划必须是对象"]
    for name in REQUIRED_PLAN_FIELDS:
        if name not in plan:
            _errors_append(errors, name, "缺少必填字段")
    if errors:
        return errors
    for name in ("plan_id", "match_id", "player_id", "rules_version"):
        value = plan.get(name)
        if not isinstance(value, str) or not value:
            _errors_append(errors, name, "必须是非空字符串")
    plan_version = plan.get("plan_version")
    if not isinstance(plan_version, int) or plan_version < 1:
        _errors_append(errors, "plan_version", "必须是正整数版本号")
    valid_until = plan.get("valid_until_tick")
    if not isinstance(valid_until, int) or valid_until < 0:
        _errors_append(errors, "valid_until_tick", "必须是非负整数（服务器 tick）")
    if not isinstance(plan.get("phase_goal"), str) or not plan["phase_goal"]:
        _errors_append(errors, "phase_goal", "必须是非空字符串（阶段目标）")
    tasks = plan.get("tasks")
    if not isinstance(tasks, list):
        _errors_append(errors, "tasks", "必须是任务数组")
    else:
        seen_ids = set()
        for index, task in enumerate(tasks):
            path = "tasks[%d]" % index
            if not isinstance(task, dict):
                _errors_append(errors, path, "任务必须是对象")
                continue
            task_id = task.get("task_id")
            if not isinstance(task_id, str) or not task_id:
                _errors_append(errors, path + ".task_id", "必须是非空字符串")
            elif task_id in seen_ids:
                _errors_append(errors, path + ".task_id", "任务 ID 重复")
            else:
                seen_ids.add(task_id)
            if not isinstance(task.get("priority", 0), int):
                _errors_append(errors, path + ".priority", "必须是整数")
            if not isinstance(task.get("completion"), str) or not task["completion"]:
                _errors_append(errors, path + ".completion", "必须说明完成条件")
    if context.get("match_id") and plan["match_id"] != context["match_id"]:
        _errors_append(errors, "match_id", "与当前对局不一致")
    if context.get("player_id") and plan["player_id"] != context["player_id"]:
        _errors_append(errors, "player_id", "与授权玩家不一致")
    if context.get("rules_version") and plan["rules_version"] != context["rules_version"]:
        _errors_append(errors, "rules_version", "与当前对局规则不一致")
    return errors


@dataclass
class Receipt:
    """游戏侧命令回执的规范化视图（兼容 ok/accepted/status/reason 字段）。"""

    command_id: str
    status: str
    accepted: bool
    reason: str = ""
    raw: Dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_json(cls, payload: Dict[str, Any]) -> "Receipt":
        return cls(
            command_id=str(payload.get("command_id", "")),
            status=str(payload.get("status", "")),
            accepted=bool(payload.get("accepted", False)),
            reason=str(payload.get("reason", "")),
            raw=payload,
        )

    @property
    def is_terminal(self) -> bool:
        """Accepted/拒绝均为命令级终态；PendingAuthority 不是终态。"""
        return self.status not in ("PendingAuthority", "Unknown")
