# -*- coding: utf-8 -*-
"""副官图契约：StrategicPlan / TacticalIntent / 玩家控制事件。

纪律（docs/plan/AI副官_LangGraph重构方案.md §5、§6、§7、§13）：
- 模型只能输出结构化计划或意图；不能输出 Godot 节点路径、不能绕过 CommandRuntime；
- 意图必带 plan_version / based_on_snapshot / issued_tick / expires_tick / generation；
- 目标只允许引用观测中存在的稳定实体 ID、坐标或规则视图中的场景；
  未知字段与未知目标键一律拒绝（防止模型构造任意资源路径/场景）；
- 校验失败抛 ContractError（结构化 errors），由节点层转成降级或拒绝，不炸图。
"""

from __future__ import annotations

from typing import Any, Callable, Dict, List, Optional

from pydantic import BaseModel, ConfigDict, Field, ValidationError, model_validator

# ---------------- 动作词表 ----------------

ACTION_MOVE = "move"
ACTION_ATTACK = "attack"
ACTION_ATTACK_MOVE = "attack_move"
ACTION_DEFEND = "defend"
ACTION_RETREAT = "retreat"
ACTION_SCOUT = "scout"
ACTION_HOLD = "hold"
ACTION_REGROUP = "regroup"
ACTION_GATHER = "gather"
ACTION_STOP = "stop"
ACTION_PRODUCE = "produce"
ACTION_BUILD = "build"

# 方案 §6 的高层动作（战略/战术模型主用）。
HIGH_LEVEL_ACTIONS = (
    ACTION_MOVE, ACTION_ATTACK, ACTION_ATTACK_MOVE, ACTION_DEFEND,
    ACTION_RETREAT, ACTION_SCOUT, ACTION_HOLD, ACTION_REGROUP,
)
# 游戏侧已实现权威执行的直通动作（观测与命令均支持；见 architecture.md §2）。
GODOT_ACTIONS = (ACTION_GATHER, ACTION_STOP, ACTION_PRODUCE, ACTION_BUILD)
ALLOWED_ACTIONS = HIGH_LEVEL_ACTIONS + GODOT_ACTIONS

# 需要坐标目标 / 实体目标 / 场景目标的动作分类。
POSITION_ACTIONS = (ACTION_MOVE, ACTION_ATTACK_MOVE, ACTION_DEFEND,
                    ACTION_RETREAT, ACTION_SCOUT, ACTION_REGROUP)
ENTITY_ACTIONS = (ACTION_ATTACK,)
SCENE_ACTIONS = (ACTION_PRODUCE, ACTION_BUILD)
UNIT_TARGETED_ACTIONS = POSITION_ACTIONS + ENTITY_ACTIONS + (
    ACTION_GATHER, ACTION_STOP, ACTION_HOLD, ACTION_ATTACK_MOVE)

ALLOWED_TARGET_KEYS = ("entity_id", "pos", "scene", "producer", "resource", "dest", "area")

# 中止条件词表（行为执行层据此在 Godot 内自行中止，不需要等模型）。
ABORT_CONDITIONS = (
    "enemy_spotted", "base_under_attack", "unit_lost", "target_dead",
    "path_failed", "task_completed", "timeout", "player_override", "low_hp",
)


class ContractError(ValueError):
    """契约校验失败：携带结构化错误列表（不抛裸 ValidationError）。"""

    def __init__(self, errors: List[str], source: str = "") -> None:
        self.errors = list(errors)
        self.source = source
        prefix = "%s: " % source if source else ""
        super().__init__(prefix + "; ".join(self.errors))


def _format_validation_errors(exc: ValidationError) -> List[str]:
    errors: List[str] = []
    for item in exc.errors():
        loc = ".".join(str(part) for part in item.get("loc", ())) or "$"
        errors.append("%s: %s" % (loc, item.get("msg", "非法取值")))
    return errors


# ---------------- 战略计划 ----------------

class PlanTask(BaseModel):
    """计划内任务：稳定 task_id + 优先级 + 完成条件 + 允许动作与单位约束。"""

    model_config = ConfigDict(extra="forbid")

    task_id: str
    priority: int = 0
    completion: str
    units: List[str] = Field(default_factory=list)
    unit_constraint: str = ""
    target_type: str = ""
    allowed_actions: List[str] = Field(default_factory=list)

    @model_validator(mode="after")
    def _check(self) -> "PlanTask":
        if not self.task_id:
            raise ValueError("task_id 必须是非空字符串")
        if not self.completion:
            raise ValueError("completion 必须说明完成条件")
        unknown = [a for a in self.allowed_actions if a not in ALLOWED_ACTIONS]
        if unknown:
            raise ValueError("allowed_actions 含未知动作 %s" % ",".join(unknown))
        return self


class StrategicPlan(BaseModel):
    """战略计划：只描述阶段目标、任务与资源预留，不直接下发单位命令。"""

    model_config = ConfigDict(extra="forbid")

    plan_id: str
    plan_version: int
    match_id: str
    player_id: str
    rules_version: str
    based_on_snapshot: int = 0
    valid_until_tick: int
    phase_goal: str
    tasks: List[PlanTask]
    reserves: Dict[str, int] = Field(default_factory=dict)
    rationale: str = ""
    abort_when: List[str] = Field(default_factory=list)

    @model_validator(mode="after")
    def _check(self) -> "StrategicPlan":
        if not self.plan_id:
            raise ValueError("plan_id 必须是非空字符串")
        if self.plan_version < 1:
            raise ValueError("plan_version 必须是 >= 1 的整数")
        if self.based_on_snapshot < 0:
            raise ValueError("based_on_snapshot 必须是非负整数")
        if self.valid_until_tick < 0:
            raise ValueError("valid_until_tick 必须是非负整数")
        if not self.phase_goal:
            raise ValueError("phase_goal 必须是非空字符串")
        if not self.tasks:
            raise ValueError("tasks 至少包含一个任务")
        seen = set()
        for task in self.tasks:
            if task.task_id in seen:
                raise ValueError("tasks.task_id 重复：%s" % task.task_id)
            seen.add(task.task_id)
        for kind in self.reserves:
            if int(self.reserves[kind]) < 0:
                raise ValueError("reserves.%s 必须是非负整数" % kind)
        unknown_abort = [c for c in self.abort_when if c not in ABORT_CONDITIONS]
        if unknown_abort:
            raise ValueError("abort_when 含未知条件 %s" % ",".join(unknown_abort))
        return self

    def to_plan_dict(self) -> Dict[str, Any]:
        """转成既有协调器协议可校验的计划 dict（protocol.validate_plan 兼容）。"""
        return {
            "plan_id": self.plan_id,
            "plan_version": self.plan_version,
            "match_id": self.match_id,
            "player_id": self.player_id,
            "rules_version": self.rules_version,
            "based_on_snapshot": self.based_on_snapshot,
            "valid_until_tick": self.valid_until_tick,
            "phase_goal": self.phase_goal,
            # 既有协议只要求 task_id/priority/completion；其余字段保留在任务对象里。
            "tasks": [
                {
                    "task_id": task.task_id,
                    "priority": task.priority,
                    "completion": task.completion,
                    "units": list(task.units),
                    "unit_constraint": task.unit_constraint,
                    "target_type": task.target_type,
                    "allowed_actions": list(task.allowed_actions),
                }
                for task in self.tasks
            ],
            "reserves": dict(self.reserves),
            "rationale": self.rationale,
            "abort_when": list(self.abort_when),
        }


# ---------------- 战术意图 ----------------

class TacticalIntent(BaseModel):
    """有限期战术意图：Godot 侧仍会按 generation/lease/TTL 做最终校验。"""

    model_config = ConfigDict(extra="forbid")

    intent_id: str = Field(description="本意图唯一 ID（同一批次内不要重复）")
    plan_version: str = Field(default="",
                              description="可留空（系统按上下文填写）；给出时必须与上下文一致")
    task_id: str = Field(default="", description="对应 StrategicPlan.tasks[].task_id")
    unit_ids: List[str] = Field(description="只能是上下文 ai_controlled_units 里的单位名")
    action: str = Field(description="只能取：move / attack / attack_move / defend / "
                                    "retreat / scout / hold / regroup / gather / stop / "
                                    "produce / build")
    target: Dict[str, Any] = Field(
        default_factory=dict,
        description="只允许这些键：entity_id（attack 目标，须来自 visible_enemy_ids）、"
                    "pos（[x,z] 坐标，move/attack_move/defend/retreat/scout/regroup 必填）、"
                    "scene（produce/build，用 buildable[].id 或产品类型 id）、producer、resource")
    priority: int = Field(default=0, description="数字越大越优先；紧急事件用 5 以上")
    based_on_snapshot: int = Field(default=0, description="可填 0（系统按上下文填写）")
    issued_tick: int = Field(default=0, description="可填 0（系统按上下文填写）")
    expires_tick: int = Field(default=0,
                              description="可填 0（系统按当前 tick + 窗口填写）；"
                                          "给出时必须大于 server_tick 且不超过 "
                                          "server_tick + 上下文 intent_ttl_ticks")
    generation: int = Field(default=0, description="填 0，由系统按控制租约填写")
    abort_when: List[str] = Field(default_factory=list)
    emergency: bool = False
    # 显式重新接管申请：只对“玩家显式归还”的单位有效（仲裁层做授权校验），
    # 不允许模型自行抢回玩家正在控制的单位。
    reacquire: bool = False
    rationale: str = ""

    @model_validator(mode="after")
    def _check(self) -> "TacticalIntent":
        if not self.intent_id:
            raise ValueError("intent_id 必须是非空字符串")
        if self.action not in ALLOWED_ACTIONS:
            raise ValueError("action %r 不在允许动作集 %s 内" % (self.action, ",".join(ALLOWED_ACTIONS)))
        if self.based_on_snapshot < 0:
            raise ValueError("based_on_snapshot 必须是非负整数")
        if self.issued_tick < 0:
            raise ValueError("issued_tick 必须是非负整数")
        # expires_tick == 0 表示“由系统按当前 tick + 窗口填写”（真实模型常省略元数据）。
        if self.expires_tick < 0:
            raise ValueError("expires_tick 不得为负数")
        if self.expires_tick and self.expires_tick < self.issued_tick:
            raise ValueError("expires_tick 不得早于 issued_tick")
        if self.generation < 0:
            raise ValueError("generation 必须是非负整数")
        unknown_keys = [k for k in self.target if k not in ALLOWED_TARGET_KEYS]
        if unknown_keys:
            raise ValueError("target 含未知键 %s（禁止构造任意目标/路径）" % ",".join(unknown_keys))
        if self.action in UNIT_TARGETED_ACTIONS and not self.unit_ids:
            raise ValueError("action %s 必须指定 unit_ids" % self.action)
        if self.action in POSITION_ACTIONS:
            pos = self.target.get("pos", self.target.get("dest"))
            if not (isinstance(pos, (list, tuple)) and len(pos) >= 2):
                raise ValueError("action %s 必须在 target.pos 提供 [x,z] 坐标" % self.action)
        if self.action in ENTITY_ACTIONS:
            if not isinstance(self.target.get("entity_id"), str) or not self.target["entity_id"]:
                raise ValueError("action attack 必须在 target.entity_id 提供观测中的稳定实体 ID")
        if self.action in SCENE_ACTIONS:
            if not isinstance(self.target.get("scene"), str) or not self.target["scene"]:
                raise ValueError("action %s 必须在 target.scene 提供规则视图中的场景路径" % self.action)
            if not isinstance(self.target.get("producer"), str) or not self.target["producer"]:
                raise ValueError("action %s 必须在 target.producer 提供执行单位 ID" % self.action)
        unknown_abort = [c for c in self.abort_when if c not in ABORT_CONDITIONS]
        if unknown_abort:
            raise ValueError("abort_when 含未知条件 %s" % ",".join(unknown_abort))
        return self

    def to_dict(self) -> Dict[str, Any]:
        return self.model_dump()


class IntentBatch(BaseModel):
    """战术模型一次产出的有限期意图批次（顶层必须给 match_id/player_id/plan_version）。"""

    model_config = ConfigDict(extra="forbid")

    batch_id: str = Field(default="", description="批次 ID（可留空）")
    match_id: str = Field(default="", description="可留空（系统按上下文填写）；给出时必须一致")
    player_id: str = Field(default="", description="可留空（系统按上下文填写）；给出时必须一致")
    plan_version: str = Field(default="", description="可留空（系统按上下文填写）；给出时必须一致")
    based_on_snapshot: int = Field(default=0, description="可填 0；不得超过上下文 snapshot_id")
    intents: List[TacticalIntent] = Field(
        default_factory=list,
        description="意图数组；没有可执行动作时给空数组，不要编造单位")

    @model_validator(mode="after")
    def _check(self) -> "IntentBatch":
        seen = set()
        for intent in self.intents:
            if intent.intent_id in seen:
                raise ValueError("intents.intent_id 重复：%s" % intent.intent_id)
            seen.add(intent.intent_id)
        return self


# ---------------- 极简战术指令（缩小模型职责） ----------------

class TacticalDirective(BaseModel):
    """模型只需表达"谁去做什么、目标是什么"。

    与 TacticalIntent 的区别：去掉 intent_id / plan_version / based_on_snapshot /
    issued_tick / expires_tick / generation / abort_when / emergency / reacquire /
    rationale —— 这些元数据一律由程序按发起请求时的上下文补齐（方案要求：
    "命令 ID、控制代际、快照和时限等元数据交由程序根据发起请求时的上下文生成绑定"）。

    动机（实测）：让模型回填这些字段，单次输出从约 100 token 膨胀到 744 token，
    而本地小模型解码约 35 tok/s，直接多出 20 秒延迟。
    """

    model_config = ConfigDict(extra="forbid")

    intent_id: str = Field(default="", description="可留空；系统会自动生成")
    action: str = Field(
        description="只能取 move / attack / attack_move / defend / retreat / scout / "
                    "hold / regroup / gather / stop / produce / build")
    units: List[str] = Field(description="执行单位名，必须来自上下文 own_units[].name")
    target_id: str = Field(default="", description="attack 填敌人 entity_id；gather 填资源点 entity_id")
    target_pos: List[float] = Field(default_factory=list,
                                    description="移动类动作的目标 [x,z]；gather 可填资源点坐标")
    producer: str = Field(default="", description="produce/build 的执行单位名")
    scene: str = Field(default="", description="produce/build 的建造物 id（见 buildable/production_relations）")
    task_id: str = Field(default="", description="对应战略任务 id，可留空")


class DirectiveBatch(BaseModel):
    """极简批次：顶层没有 match_id/plan_version/snapshot，系统按上下文补齐。"""

    model_config = ConfigDict(extra="forbid")

    directives: List[TacticalDirective] = Field(
        default_factory=list,
        description="没有可执行动作时给空数组，不要编造单位或坐标")


def directives_to_intents(batch: "DirectiveBatch", *, plan_version: str,
                          snapshot_id: int, server_tick: int,
                          intent_ttl_ticks: int,
                          action_for: Optional[Callable[[str], str]] = None) -> "IntentBatch":
    """把极简指令翻译成既有 IntentBatch：所有元数据由程序按请求上下文补齐。

    action_for：可选的动作名归一化回调（例如把 scout 保留、把未知动作交回原样），
    默认原样透传，保证不引入新的规则推导。
    """
    intents: List[TacticalIntent] = []
    for index, item in enumerate(getattr(batch, "directives", []) or []):
        action = str(item.action or "").strip()
        if action_for is not None:
            action = action_for(action)
        target: Dict[str, Any] = {}
        if item.target_id:
            target["entity_id"] = str(item.target_id)
        if item.target_pos and len(item.target_pos) >= 2:
            target["pos"] = [float(item.target_pos[0]), float(item.target_pos[1])]
        if item.producer:
            target["producer"] = str(item.producer)
        if item.scene:
            target["scene"] = str(item.scene)
        intents.append(TacticalIntent(
            intent_id=str(item.intent_id or "") or ("i-%d" % (index + 1)),
            plan_version=plan_version,
            task_id=str(item.task_id or ""),
            unit_ids=[str(u) for u in item.units],
            action=action,
            target=target,
            based_on_snapshot=snapshot_id,
            expires_tick=int(server_tick) + int(intent_ttl_ticks),
        ))
    return IntentBatch(
        match_id="", player_id="", plan_version=plan_version,
        based_on_snapshot=snapshot_id, intents=intents)


# ---------------- 玩家控制事件 ----------------

EVENT_OVERRIDE = "player_override"
EVENT_RELEASE = "player_release"
EVENT_RELEASE_GROUP = "player_release_group"
PLAYER_CONTROL_EVENT_KINDS = (EVENT_OVERRIDE, EVENT_RELEASE, EVENT_RELEASE_GROUP)


class PlayerControlEvent(BaseModel):
    """玩家控制事件：手动接管立即增加代际；显式归还才允许 AI 重新接管。"""

    model_config = ConfigDict(extra="forbid")

    kind: str
    match_id: str
    player_id: str
    unit_ids: List[str]
    server_tick: int = 0
    generation: int = 0
    reason: str = ""

    @model_validator(mode="after")
    def _check(self) -> "PlayerControlEvent":
        if self.kind not in PLAYER_CONTROL_EVENT_KINDS:
            raise ValueError("kind %r 不支持（仅 %s）" % (self.kind, ",".join(PLAYER_CONTROL_EVENT_KINDS)))
        if not self.unit_ids:
            raise ValueError("unit_ids 不能为空")
        return self


# ---------------- 解析入口 ----------------

def _parse(model_cls, raw: Any, source: str):
    if isinstance(raw, model_cls):
        return raw
    try:
        return model_cls.model_validate(raw)
    except ValidationError as exc:
        raise ContractError(_format_validation_errors(exc), source=source) from exc
    except TypeError as exc:  # 非 dict/model 的裸输入
        raise ContractError(["$: 必须是对象（收到 %s）" % type(raw).__name__], source=source) from exc


def parse_strategic_plan(raw: Any) -> StrategicPlan:
    return _parse(StrategicPlan, raw, "strategic_plan")


def parse_intent_batch(raw: Any) -> IntentBatch:
    return _parse(IntentBatch, raw, "intent_batch")


def parse_tactical_intent(raw: Any) -> TacticalIntent:
    return _parse(TacticalIntent, raw, "tactical_intent")


def parse_player_control_event(raw: Any) -> PlayerControlEvent:
    return _parse(PlayerControlEvent, raw, "player_control_event")


# ---------------- 与既有协议的一致性 ----------------

def intent_to_command_envelope(intent: TacticalIntent, *, match_id: str, player_id: str,
                               rules_version: str, command_id: str, request_id: str,
                               op: str = "adjutant_intent",
                               attempt: int = 0) -> Dict[str, Any]:
    """把意图转成 Godot 侧命令包（含 generation/intent_id，供权威层做代际校验）。

    - expires_tick 直接沿用意图 TTL（不做延长）；
    - params 只暴露权威入口认识的键；未知键不进入 params；
    - 不在本函数里做任何资源/合法性判断（那是 Godot 权威层的职责）。
    """
    params: Dict[str, Any] = {"units": list(intent.unit_ids)}
    action = intent.action
    target = dict(intent.target)
    if action == ACTION_ATTACK:
        params["target"] = target["entity_id"]
    if action in POSITION_ACTIONS:
        pos = target.get("pos", target.get("dest"))
        params["dest"] = [float(pos[0]), float(pos[1])]
    if action in SCENE_ACTIONS:
        params["scene"] = target["scene"]
        params["producer"] = target["producer"]
        params["unit"] = target["producer"]
        # build 必须带落点：游戏侧 `_op_build` 读的是 `parsed.pos`，缺省 (0,0)，
        # 实测被拒 {"primary_issue":"NotVisible","issues":["NotVisible","OutOfBounds",
        # "SurfaceNotBuildable"]} —— 即"看不到/界外/不可建"。
        # 只有 target 里确实带 pos 时才透传（不臆造坐标）。
        if action == ACTION_BUILD:
            place = target.get("pos", target.get("dest"))
            if isinstance(place, (list, tuple)) and len(place) >= 2:
                params["pos"] = [float(place[0]), float(place[1])]
    if action == ACTION_GATHER:
        if "resource" in target:
            params["resource"] = target["resource"]
        if "entity_id" in target:
            params["target"] = target["entity_id"]
    if getattr(intent, "reacquire", False):
        params["reacquire"] = True
    params["intent_action"] = action
    return {
        "op": op,
        "command_id": command_id,
        "request_id": request_id,
        "intent_id": intent.intent_id,
        "match_id": match_id,
        "player_id": player_id,
        "rules_version": rules_version,
        "plan_version": intent.plan_version,
        "task_id": intent.task_id,
        "based_on_snapshot": intent.based_on_snapshot,
        "issued_tick": intent.issued_tick,
        "expires_tick": intent.expires_tick,
        "generation": intent.generation,
        "action": action,
        "attempt": attempt,
        "params": params,
    }


def intent_public_view(intent: TacticalIntent) -> Dict[str, Any]:
    """UI/日志用的意图视图（不含隐藏推理，只含可观察依据）。"""
    return {
        "intent_id": intent.intent_id,
        "task_id": intent.task_id,
        "plan_version": intent.plan_version,
        "unit_ids": list(intent.unit_ids),
        "action": intent.action,
        "target": dict(intent.target),
        "priority": intent.priority,
        "generation": intent.generation,
        "issued_tick": intent.issued_tick,
        "expires_tick": intent.expires_tick,
        "emergency": intent.emergency,
        "reacquire": bool(getattr(intent, "reacquire", False)),
        "rationale": intent.rationale,
    }


def optional_int(value: Any, default: Optional[int] = None) -> Optional[int]:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default
