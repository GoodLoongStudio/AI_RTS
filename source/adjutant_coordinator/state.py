# -*- coding: utf-8 -*-
"""协调器状态：计划采纳代际、任务状态机、控制租约。

关键纪律：
- 战略新计划经协调器采纳后才生效，旧计划输出不能直接覆盖（版本必须递增）；
- 任务状态与命令接受状态分离：Accepted 仅代表命令接受，不代表任务完成；
- 玩家手动接管立即取消副官租约；重新接管需要显式授权（reacquire）。
"""

from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Set, Tuple

# 任务状态机（面向玩家的可见状态；unknown 表示需要复核而非失败）。
TASK_PENDING = "pending"
TASK_RUNNING = "running"
TASK_COMPLETED = "completed"
TASK_FAILED = "failed"
TASK_CANCELLED = "cancelled"
TASK_UNKNOWN = "unknown"

TASK_STATES = (
    TASK_PENDING, TASK_RUNNING, TASK_COMPLETED, TASK_FAILED,
    TASK_CANCELLED, TASK_UNKNOWN,
)


@dataclass
class AdoptedPlan:
    """已采纳的计划快照；adopt_generation 单调递增。"""

    plan: Dict[str, Any]
    adopted_tick: int
    adopt_generation: int


class PlanStore:
    """每个 (match, player) 一个逻辑计划库；版本倒退的提交被拒绝。"""

    def __init__(self) -> None:
        self._active: Optional[AdoptedPlan] = None
        self._adopt_generation = 0

    @property
    def active(self) -> Optional[AdoptedPlan]:
        return self._active

    @property
    def adopt_generation(self) -> int:
        return self._adopt_generation

    def submit(self, plan: Dict[str, Any], current_tick: int) -> "Tuple[bool, str]":
        """尝试采纳新计划；返回 (accepted, reason)。

        规则：
        - 同 plan_id 且 plan_version 不大于已采纳版本 → 拒绝（旧输出不能覆盖）；
        - plan_id 不同视为换计划，允许直接采纳（记录换代）；
        - valid_until_tick 已过期的计划可以采纳（其命令会被过期校验拦截），
          但协调器会立即视为需要新计划。
        """
        plan_id = plan.get("plan_id", "")
        plan_version = plan.get("plan_version", 0)
        if self._active is not None:
            current = self._active.plan
            if current.get("plan_id") == plan_id and plan_version <= current.get("plan_version", 0):
                return False, "plan_version 未递增（旧输出不能覆盖已采纳计划）"
        self._adopt_generation += 1
        self._active = AdoptedPlan(plan=plan, adopted_tick=current_tick,
                                   adopt_generation=self._adopt_generation)
        return True, "adopted generation=%d" % self._adopt_generation

    def plan_version(self) -> str:
        if self._active is None:
            return ""
        return "%s:v%d" % (self._active.plan.get("plan_id", ""), self._active.plan.get("plan_version", 0))

    def expired(self, current_tick: int) -> bool:
        if self._active is None:
            return True
        return current_tick > self._active.plan.get("valid_until_tick", 0)


class TaskTracker:
    """按 task_id 跟踪任务状态；命令回执驱动 running，完成条件由上层评估。"""

    def __init__(self) -> None:
        self._states: Dict[str, str] = {}

    def register(self, task_id: str) -> None:
        if task_id and task_id not in self._states:
            self._states[task_id] = TASK_PENDING

    def mark(self, task_id: str, state: str) -> None:
        if state not in TASK_STATES:
            raise ValueError("unknown task state: %s" % state)
        self._states[task_id] = state

    def on_receipt(self, task_id: str, accepted: bool, status: str) -> None:
        """命令回执只影响任务到 running/unknown；完成与失败必须来自任务评估。"""
        if not task_id:
            return
        if task_id not in self._states:
            self._states[task_id] = TASK_PENDING
        if accepted and status == "Accepted" and self._states[task_id] in (TASK_PENDING, TASK_UNKNOWN):
            self._states[task_id] = TASK_RUNNING
        elif status == "PendingAuthority":
            # PendingAuthority 不改变任务状态，等待复核（不重复下单）。
            self._states[task_id] = self._states.get(task_id, TASK_PENDING)

    def state_of(self, task_id: str) -> str:
        return self._states.get(task_id, TASK_UNKNOWN)

    def snapshot(self) -> Dict[str, str]:
        return dict(self._states)


@dataclass
class ControlLease:
    """副官对单位的控制租约；generation 单调递增。

    - acquire(unit_ids)：首次租用登记代际；
    - player_override(unit_ids)：玩家手动命令 → 立即失效（保留记录）；
    - reacquire(unit_ids, reason)：显式授权后重新接管（记录原因）。
    """

    generation: int = 0
    leases: Dict[str, Dict[str, Any]] = field(default_factory=dict)

    def _key_set(self, unit_ids: List[str]) -> Set[str]:
        return {str(u) for u in unit_ids}

    def acquire(self, unit_ids: List[str]) -> None:
        for unit_id in self._key_set(unit_ids):
            if unit_id not in self.leases:
                self.generation += 1
                self.leases[unit_id] = {"generation": self.generation, "active": True}

    def is_controlled(self, unit_ids: List[str]) -> bool:
        return all(
            self.leases.get(str(u), {}).get("active", False)
            for u in self._key_set(unit_ids)
        ) if unit_ids else True

    def overridden_units(self, unit_ids: List[str]) -> List[str]:
        return [u for u in self._key_set(unit_ids)
                if str(u) in self.leases and not self.leases[str(u)]["active"]]

    def player_override(self, unit_ids: List[str]) -> None:
        for unit_id in self._key_set(unit_ids):
            if unit_id in self.leases:
                self.leases[unit_id]["active"] = False

    def reacquire(self, unit_ids: List[str], reason: str) -> None:
        for unit_id in self._key_set(unit_ids):
            self.generation += 1
            self.leases[unit_id] = {
                "generation": self.generation,
                "active": True,
                "reacquire_reason": reason,
            }
