# -*- coding: utf-8 -*-
"""四列紧凑任务修改（TaskPatchBatch）与请求绑定视图（DecisionFrame）。

依据（`docs/程序文档/AI副官_单模型高效指挥_技术实现设计_2026-09-11.md` §2.1/§2.2）：

- 模型只输出 `{"u":[[actor_ref, skill_ref, target_ref, params_ref], ...]}`；
  每行严格 4 项字符串，程序按列做类型/能力/目标/参数相容性校验；
- **不为战场构造庞大的动态 JSON Schema**：PydanticAI 侧只约束"字符串二维数组、
  每行 4 项"，语义合法性由本模块用普通 Python 判定；
- `{"u":[]}` = 本轮不修改任何任务；未提及的小队继续执行既有任务；
- 模型**不**生成 command_id / generation / snapshot / expires 等权威元数据：
  这些一律取自发起请求时的 `DecisionFrame`（不可在结果到达时换成最新代际）；
- 旧 `DirectiveBatch` 保留为历史格式（A/B 对照用），新链路走 `TaskPatchBatch`。

设计要点：**程序提供候选、模型只做选择**。所有 ref 表（actor/skill/target/params）
由本模块从真实观测确定性生成，并随日志一起落盘，便于事后核对"模型选的到底是哪一项"。
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Sequence, Tuple

from pydantic import BaseModel, ConfigDict, Field, model_validator

from .contracts import (
    ACTION_ATTACK, ACTION_ATTACK_MOVE, ACTION_BUILD, ACTION_DEFEND, ACTION_GATHER,
    ACTION_HOLD, ACTION_MOVE, ACTION_PRODUCE, ACTION_REGROUP, ACTION_RETREAT,
    ACTION_SCOUT, ACTION_STOP, ALLOWED_ACTIONS, ContractError, IntentBatch,
    TacticalIntent,
)

# ---------------- 模式与容量 ----------------

MODE_FAST = "fast"
MODE_DEEP = "deep"
MODES = (MODE_FAST, MODE_DEEP)

#: 同一个资源点最多派几个工人 —— **唯一实现在 `resource_allocation`**，这里只引用（不许再写一份）。
#: 【2026-09-12 结构性整改】原先本模块与 `rules_fallback` 各定义一份同值常量，
#: 改一处不会同步到另一处。另外记住分工：这里只做"**一行/一组里最多几个工人同目标**"的截断，
#: 真正的**跨矿点分散**归 `resource_allocation`（它管在途占用账 + 去冲突 + 自愈再平衡）。
from .resource_allocation import RESOURCE_WORKERS_PER_NODE as RESOURCE_WORKERS_PER_NODE  # noqa: E402

#: 计划 §2 的容量与期限（实施起点；**容量按实测证据调整过一次**）。
#:
#: 调整依据（2026-09-12，120 条真实观测 A/B）：计划初始容量是 fast 4 行 / deep 8 行，
#: 但实测 2B 在"8 个执行者"的观测上稳定想输出 5~7 行（每个工人组一条采集 +
#: 每个设施一条生产），**输出仅 90 token，仍在 96 输出预算内、无截断**；
#: 按 4 行硬卡会把合法任务判成 row_limit_exceeded，语义合法率被压到 54%。
#: 计划明确允许"实际 token 与截断率决定能否使用该容量"，故上调容量并继续监测截断率。
MODE_LIMITS: Dict[str, Dict[str, Any]] = {
    MODE_FAST: {"max_rows": 6, "input_budget": 1024, "output_budget": 96,
                "deadline_seconds": 1.5},
    MODE_DEEP: {"max_rows": 10, "input_budget": 2048, "output_budget": 256,
                "deadline_seconds": 3.0},
}

# ---------------- 技能词表（短语义 ID） ----------------
# 保留可辨别含义（ATK/DEF…），不把语义压成无说明整数（设计 §2.1）。

SKILL_ATTACK = "ATK"
SKILL_DEFEND = "DEF"
SKILL_RETREAT = "RET"
SKILL_SCOUT = "SCT"
SKILL_REGROUP = "GRP"
SKILL_GATHER = "GAT"
SKILL_BUILD = "BLD"
SKILL_PRODUCE = "PROD"
SKILL_MOVE = "MOVE"
SKILL_ATTACK_MOVE = "AMOV"
SKILL_HOLD = "HOLD"
SKILL_STOP = "STOP"

SKILL_ORDER: Tuple[str, ...] = (
    SKILL_ATTACK, SKILL_ATTACK_MOVE, SKILL_DEFEND, SKILL_RETREAT, SKILL_SCOUT,
    SKILL_REGROUP, SKILL_GATHER, SKILL_BUILD, SKILL_PRODUCE,
    SKILL_MOVE, SKILL_HOLD, SKILL_STOP,
)

#: 技能 → 游戏侧既有动作词（复用同一条权威链，不新增动作语义）。
SKILL_TO_ACTION: Dict[str, str] = {
    SKILL_ATTACK: ACTION_ATTACK,
    SKILL_DEFEND: ACTION_DEFEND,
    SKILL_RETREAT: ACTION_RETREAT,
    SKILL_SCOUT: ACTION_SCOUT,
    SKILL_REGROUP: ACTION_REGROUP,
    SKILL_GATHER: ACTION_GATHER,
    SKILL_BUILD: ACTION_BUILD,
    SKILL_PRODUCE: ACTION_PRODUCE,
    SKILL_MOVE: ACTION_MOVE,
    SKILL_ATTACK_MOVE: ACTION_ATTACK_MOVE,
    SKILL_HOLD: ACTION_HOLD,
    SKILL_STOP: ACTION_STOP,
}

#: 反向映射：既有的任务（权威链）→ 四列技能。用于"任务没变就不要重发"。
ACTION_TO_SKILL: Dict[str, str] = {action: skill for skill, action in SKILL_TO_ACTION.items()}

SKILL_TITLE_CN: Dict[str, str] = {
    SKILL_ATTACK: "攻击", SKILL_DEFEND: "防守", SKILL_RETREAT: "撤退",
    SKILL_SCOUT: "侦察", SKILL_REGROUP: "集结", SKILL_GATHER: "采集",
    SKILL_BUILD: "建造", SKILL_PRODUCE: "生产", SKILL_MOVE: "移动",
    SKILL_ATTACK_MOVE: "攻击移动", SKILL_HOLD: "待命", SKILL_STOP: "停止",
}

# ---------------- actor / target 类别 ----------------

ACTOR_SQUAD = "squad"
ACTOR_WORKER = "worker"
ACTOR_FACILITY = "facility"

TARGET_ENEMY = "enemy"
TARGET_ANCHOR = "anchor"        # 己方基点（基地/兵营/集结点）
TARGET_RESOURCE = "resource"
TARGET_PRODUCT = "product"
TARGET_LOCATION = "location"    # 战场点位（前压点/侦察方向/建造落点）

#: actor 类别 → 允许的技能（"能力匹配"由程序判定，模型不能自行越权）。
ACTOR_ALLOWED_SKILLS: Dict[str, Tuple[str, ...]] = {
    ACTOR_SQUAD: (SKILL_ATTACK, SKILL_ATTACK_MOVE, SKILL_DEFEND, SKILL_RETREAT,
                  SKILL_SCOUT, SKILL_REGROUP, SKILL_MOVE, SKILL_HOLD, SKILL_STOP),
    ACTOR_WORKER: (SKILL_GATHER, SKILL_BUILD, SKILL_MOVE, SKILL_RETREAT, SKILL_STOP),
    ACTOR_FACILITY: (SKILL_PRODUCE, SKILL_STOP),
}

#: 技能 → 允许的目标类别（None 表示必须给 `-`，即无目标）。
SKILL_ALLOWED_TARGETS: Dict[str, Optional[Tuple[str, ...]]] = {
    SKILL_ATTACK: (TARGET_ENEMY,),
    SKILL_ATTACK_MOVE: (TARGET_LOCATION, TARGET_ANCHOR),
    SKILL_DEFEND: (TARGET_LOCATION, TARGET_ANCHOR),
    SKILL_RETREAT: (TARGET_ANCHOR, TARGET_LOCATION),
    SKILL_SCOUT: (TARGET_LOCATION,),
    SKILL_REGROUP: (TARGET_ANCHOR, TARGET_LOCATION),
    SKILL_GATHER: (TARGET_RESOURCE,),
    # 建造与生产的"造什么"都取自程序给出的候选项（U*/V*）：
    # 落点由程序算（设计 §4.2「模型选路线意图，程序算精确阵位」），模型不猜坐标。
    SKILL_BUILD: (TARGET_PRODUCT,),
    SKILL_PRODUCE: (TARGET_PRODUCT,),
    SKILL_MOVE: (TARGET_LOCATION, TARGET_ANCHOR),
    SKILL_HOLD: None,
    SKILL_STOP: None,
}

#: 无目标占位符：四列结构固定，用 `-` 表示"本列不适用"。
NO_TARGET = "-"
KEEP_PARAMS = "P0"

# ---------------- 参数档（程序提供，模型只选） ----------------
#: 参数档语义（设计 §2.1）：路线 / 阵型 / 节奏 / 追击范围。

PARAM_PRESETS: Tuple[Dict[str, str], ...] = (
    {"ref": "P1", "route": "direct", "formation": "column", "tempo": "normal",
     "pursuit": "normal", "cn": "直线推进·纵队·常速"},
    {"ref": "P2", "route": "direct", "formation": "line", "tempo": "fast",
     "pursuit": "short", "cn": "正面压上·横队·快速"},
    {"ref": "P3", "route": "flank", "formation": "loose", "tempo": "normal",
     "pursuit": "normal", "cn": "侧翼迂回·疏散·常速"},
    {"ref": "P4", "route": "rally", "formation": "column", "tempo": "careful",
     "pursuit": "short", "cn": "经集结点·纵队·谨慎"},
    {"ref": "P5", "route": "direct", "formation": "loose", "tempo": "fast",
     "pursuit": "short", "cn": "快速展开·疏散·快速"},
    {"ref": "P6", "route": "rally", "formation": "line", "tempo": "careful",
     "pursuit": "none", "cn": "固守待命·横队·不追击"},
)
PARAM_PRESET_BY_REF: Dict[str, Dict[str, str]] = {p["ref"]: p for p in PARAM_PRESETS}


class RowRejection:
    """单行拒绝原因（逐项回执，不把非原子批次伪装成全部成功）。"""

    __slots__ = ("row_index", "row", "reason", "detail")

    def __init__(self, row_index: int, row: Sequence[str], reason: str,
                 detail: str = "") -> None:
        self.row_index = int(row_index)
        self.row = [str(x) for x in row]
        self.reason = str(reason)
        self.detail = str(detail)

    def to_dict(self) -> Dict[str, Any]:
        return {"row_index": self.row_index, "row": list(self.row),
                "reason": self.reason, "detail": self.detail}


# ---------------- 契约模型 ----------------

class TaskPatchBatch(BaseModel):
    """模型唯一输出：短任务修改（四列二维字符串数组）。

    - `u`：任务修改行；空数组表示"本轮不改任务"；
    - `g`：可选阶段目标引用（当前阶段 ID）；不要求每轮重复；
    - 语义合法性（能力/目标/参数相容）由 `decode_task_patch` 判定。

    **结构层刻意宽松（只保证"是二维数组"）**，逐行问题一律交给解码器做**逐项拒绝**。
    实测依据（2026-09-12，真机卡死数小时的根因）：
    早期版本在结构层硬校验"每行必须恰好 4 项、且都是字符串"，只要模型有一行写歪，
    PydanticAI 就**整批**打回重试；重试时模型最省事、且一定合法的答案就是 `{"u":[]}`
    ——于是副官看起来"每秒都在决策"，实际**每一轮都派 0 个任务**（`intent_ids` 恒空、
    0 回执、游戏里毫无变化）。这正违反计划要求的"非原子批次、逐项回执"：
    一行的格式问题绝不能让整批任务作废。
    """

    model_config = ConfigDict(extra="forbid")

    u: List[List[str]] = Field(
        default_factory=list,
        description="任务修改行；每行 [actor_ref, skill_ref, target_ref, params_ref]，"
                    "四列都是字符串；没有修改时给空数组")
    g: str = Field(default="", description="可选：主线分支 ID（取「可选路线」的 ref，"
                                          "如 D3）；不改分支时留空")

    @model_validator(mode="before")
    @classmethod
    def _coerce_rows(cls, data: Any) -> Any:
        """宽容读入：非数组的行/非字符串的列一律**就地转换**，不做整批拒绝。"""
        if not isinstance(data, dict):
            return data
        rows = data.get("u")
        if not isinstance(rows, list):
            return data
        coerced: List[List[str]] = []
        for row in rows:
            if isinstance(row, (list, tuple)):
                coerced.append(["" if v is None else str(v) for v in row])
            elif row is None:
                continue
            else:
                coerced.append([str(row)])
        return dict(data, u=coerced)

    def rows(self) -> List[List[str]]:
        return [[str(v) for v in row] for row in (self.u or [])]


# ---------------- 请求绑定视图 ----------------

@dataclass(frozen=True)
class DecisionFrame:
    """不可变的请求视图：引用表 + 对局身份 + 快照 + 逐对象代际 + 本地期限。

    纪律（设计 §2.2）：解码时**只能**用本对象里的元数据；结果到达时即使权威端
    已经前进，也不能换成最新代际/快照（旧结果只能被拒绝，不能被刷新）。
    """

    match_id: str
    player_id: str
    rules_version: str
    snapshot_id: int
    server_tick: int
    mode: str
    #: ref → 条目（actor / target / param）
    actors: Dict[str, Dict[str, Any]] = field(default_factory=dict)
    targets: Dict[str, Dict[str, Any]] = field(default_factory=dict)
    params: Dict[str, Dict[str, Any]] = field(default_factory=dict)
    #: 逐对象控制代际（权威值；缺失则视为 0，由权威端最终校验）
    generations: Dict[str, int] = field(default_factory=dict)
    #: 任务版本（小队/执行者 → 版本号），同任务重复返回只确认现状
    task_versions: Dict[str, int] = field(default_factory=dict)
    #: 小队成员版本（成员集合的哈希/版本，用于失效判断）
    member_versions: Dict[str, str] = field(default_factory=dict)
    plan_version: str = ""
    intent_ttl_ticks: int = 3600
    emergency_intent_ttl_ticks: int = 1200
    #: 本地接收期限（单调时钟，秒）。超期结果一律拒绝执行。
    created_monotonic: float = field(default_factory=time.monotonic)
    deadline_seconds: float = 3.0
    #: 可选阶段目标（程序维护）
    phase_goal: str = ""
    #: 合法建造落点候选（程序算，模型不猜坐标；解码 BLD 时按"离已占用点最远"挑一个）
    build_spots: Tuple[Tuple[float, float], ...] = ()
    #: 已占用点（我方单位与建筑的坐标）：挑落点时用来避开"把部队堵住"的位置。
    occupied_points: Tuple[Tuple[float, float], ...] = ()
    #: 当前余额（{资源: 数量}）。**必须给模型看**：实测（2026-09-12 用户反馈）
    #: 生产链路的 user 提示从未渲染余额，模型不知道"钱够不够"，于是钱再多也不建造/生产。
    balance: Dict[str, int] = field(default_factory=dict)
    #: 执行者**当前正在执行的任务**（权威任务表）：{actor_ref: {"skill":…, "target":…}}。
    #: 用途有两个：① 渲染给模型看（已在执行的任务不要重复输出）；② 解码时判定"这行等于现状"
    #: → 记为 `unchanged`，**不下发新命令**（计划 §4.1：模型只发"任务修改"，未提及的继续执行）。
    current_tasks: Dict[str, Dict[str, Any]] = field(default_factory=dict)
    #: **整局主线上下文**（纠偏 §7 的硬要求）。必须包含：当前阶段、主线目标、
    #: 已完成/阻塞里程碑、四条线任务、下一前沿、可选决策地图节点及其前置条件。
    #: 这里的每个字段都来自 `campaign.context_view()`（唯一实现），
    #: 渲染层只负责排版，不自行推导主线状态。
    campaign: Dict[str, Any] = field(default_factory=dict)

    @property
    def deadline_monotonic(self) -> float:
        return float(self.created_monotonic) + float(self.deadline_seconds)

    def expired(self, now: Optional[float] = None) -> bool:
        return (time.monotonic() if now is None else float(now)) > self.deadline_monotonic

    def actor(self, ref: str) -> Optional[Dict[str, Any]]:
        return self.actors.get(str(ref))

    def target(self, ref: str) -> Optional[Dict[str, Any]]:
        return self.targets.get(str(ref))

    def param(self, ref: str) -> Optional[Dict[str, Any]]:
        return self.params.get(str(ref))

    def to_context(self) -> Dict[str, Any]:
        """给模型的可见表格（只有玩家可见事实 + 明确允许的历史记忆）。"""
        return {
            "mode": self.mode,
            "actors": [dict(item) for item in self.actors.values()],
            "skills": [
                {"ref": skill, "cn": SKILL_TITLE_CN.get(skill, skill),
                 "targets": list(SKILL_ALLOWED_TARGETS.get(skill) or []),
                 "actors": [kind for kind, allowed in ACTOR_ALLOWED_SKILLS.items()
                            if skill in allowed]}
                for skill in SKILL_ORDER
            ],
            "targets": [dict(item) for item in self.targets.values()],
            "params": [dict(item) for item in self.params.values()],
            "no_target": NO_TARGET,
            "keep_params": KEEP_PARAMS,
            "campaign": dict(self.campaign or {}),
        }


# ---------------- 任务修改（解码结果） ----------------

@dataclass
class TaskModification:
    """一行解码成功后的任务修改（已绑定真实对象与发起请求时的元数据）。"""

    row_index: int
    actor_ref: str
    skill: str
    target_ref: str
    params_ref: str
    actor_kind: str
    squad_id: str
    units: List[str]
    action: str
    target: Dict[str, Any]
    params: Dict[str, Any]
    intent_id: str
    task_id: str
    task_version: int
    generations: Dict[str, int]
    #: True = 这一行与执行者**当前任务完全相同**（模型在复述现状）→ 只确认，不下发新命令。
    unchanged: bool = False

    def to_dict(self) -> Dict[str, Any]:
        return {
            "row_index": self.row_index, "row": [self.actor_ref, self.skill,
                                                 self.target_ref, self.params_ref],
            "skill": self.skill, "action": self.action, "actor_kind": self.actor_kind,
            "squad_id": self.squad_id, "units": list(self.units),
            "target": dict(self.target), "params": dict(self.params),
            "intent_id": self.intent_id, "task_id": self.task_id,
            "task_version": self.task_version, "unchanged": self.unchanged,
        }


@dataclass
class DecodeResult:
    """解码结果：成功行 + 逐行拒绝原因（部分拒绝必须显式）。"""

    modifications: List[TaskModification] = field(default_factory=list)
    rejections: List[RowRejection] = field(default_factory=list)
    goal_ref: str = ""

    @property
    def ok(self) -> bool:
        return bool(self.modifications)

    @property
    def changed(self) -> List[TaskModification]:
        """真正**改变了任务**的行（排除复述现状的 `unchanged`）。"""
        return [item for item in self.modifications if not item.unchanged]

    @property
    def unchanged(self) -> List[TaskModification]:
        return [item for item in self.modifications if item.unchanged]

    def to_dict(self) -> Dict[str, Any]:
        return {
            "goal_ref": self.goal_ref,
            "modifications": [m.to_dict() for m in self.modifications],
            "rejections": [r.to_dict() for r in self.rejections],
        }


# ---------------- 解码（逐行逐列校验） ----------------

def effective_max_rows(frame: DecisionFrame) -> int:
    """本轮真实行上限 = min(模式容量, 执行者数量)。

    实测依据（2026-09-12，120 条真实观测）：deep 模式容量 10 行、而观测里只有 3 个
    执行者时，2B 会**为凑行数重复同一执行者**（duplicate_actor），语义合法率从 97.6% 掉到
    78.4%。权威任务表本来就是"每个执行者一条当前任务"（设计 §4.1），所以行上限不可能
    超过执行者数量；把这个事实直接告诉模型，比事后拒绝更省 token 也更准。
    """
    cap = int(MODE_LIMITS.get(frame.mode, MODE_LIMITS[MODE_FAST])["max_rows"])
    return max(1, min(cap, len(frame.actors) or 1))


def decode_task_patch(batch: Any, frame: DecisionFrame,
                      *, max_rows: Optional[int] = None) -> DecodeResult:
    """把模型的四列输出按 `frame` 的引用表展开成任务修改。

    逐行独立校验：某一行非法**不影响**其它行（非原子批次，逐项回执）。
    """
    limit = int(max_rows if max_rows is not None
                else effective_max_rows(frame))
    result = DecodeResult()
    rows = _coerce_rows(batch)
    result.goal_ref = str(getattr(batch, "g", "") or "")
    seen_actors: set = set()
    #: 本轮已承接建造的执行者（工地 → 执行者）；见下方"一个工地一个建造者"守卫。
    seen_build_sites: Dict[str, str] = {}
    for index, row in enumerate(rows):
        if index >= limit:
            result.rejections.append(RowRejection(
                index, row, "row_limit_exceeded",
                "本轮容量 %d 行（模式 %s）" % (limit, frame.mode)))
            continue
        modification, rejection = _decode_row(index, row, frame)
        if rejection is not None:
            result.rejections.append(rejection)
            continue
        # 权威任务表是"每个执行者一条当前任务"（设计 §4.1）：同一执行者本轮出现多次
        # 会互相覆盖，属无意义输出（实测 2B 会把 4 行全用在同一个工人组上）。
        if modification.actor_ref in seen_actors:
            result.rejections.append(RowRejection(
                index, row, "duplicate_actor",
                "%s 本轮已有任务" % modification.actor_ref))
            continue
        # 【一个工地一个建造者】同一轮里同一座建筑只允许 1 个执行者。
        # 实测依据（2026-09-12 晚用户反馈"建造 1 个建筑就让一堆工人上，那矿不采了？"）：
        # 候选表里同一集群的 N 个工人都能选到同一座建筑 → 模型发 N 条 BLD 完全合理 →
        # 全队停工去盖房子、采集线停摆（违反手册 01 §3"四条线同时推进"）。
        # 这条守卫在**任何**候选生成方式（含集群划分变化）下都成立。
        if modification.skill == SKILL_BUILD:
            site = str((modification.target or {}).get("scene", ""))
            if site and site in seen_build_sites:
                result.rejections.append(RowRejection(
                    index, row, "duplicate_build_site",
                    "同一工地本轮只派 1 个建造者（%s 已由 %s 承接）"
                    % (site, seen_build_sites[site])))
                continue
            seen_build_sites[site] = modification.actor_ref
        seen_actors.add(modification.actor_ref)
        result.modifications.append(modification)
    return result


def _coerce_rows(batch: Any) -> List[List[str]]:
    """接受 TaskPatchBatch / dict / 行列表（回放与单测友好）。"""
    if isinstance(batch, TaskPatchBatch):
        return batch.rows()
    if isinstance(batch, dict):
        raw = batch.get("u", [])
    else:
        raw = getattr(batch, "u", batch)
    rows: List[List[str]] = []
    for row in list(raw or []):
        if isinstance(row, (list, tuple)):
            rows.append([str(v) for v in row])
        else:
            rows.append([str(row)])
    return rows


def _decode_row(index: int, row: Sequence[str],
                frame: DecisionFrame) -> Tuple[Optional[TaskModification], Optional[RowRejection]]:
    def reject(reason: str, detail: str = "") -> Tuple[None, RowRejection]:
        return None, RowRejection(index, row, reason, detail)

    if len(row) != 4:
        return reject("bad_arity", "需要 4 列，收到 %d 列" % len(row))
    actor_ref, skill_ref, target_ref, params_ref = (str(row[0]), str(row[1]),
                                                    str(row[2]), str(row[3]))
    actor = frame.actor(actor_ref)
    if actor is None:
        return reject("unknown_actor", "actor_ref=%s 不在本轮授权表" % actor_ref)
    skill = skill_ref.strip().upper()
    if skill not in SKILL_TO_ACTION:
        return reject("unknown_skill", "skill_ref=%s 不是已知任务模板" % skill_ref)
    actor_kind = str(actor.get("kind", ""))
    allowed_skills = ACTOR_ALLOWED_SKILLS.get(actor_kind, ())
    if skill not in allowed_skills:
        return reject("skill_not_allowed_for_actor",
                      "%s 不能执行 %s（允许：%s）" % (actor_kind, skill,
                                                  "/".join(allowed_skills)))
    allowed_targets = SKILL_ALLOWED_TARGETS.get(skill)
    target: Dict[str, Any] = {}
    if allowed_targets is None:
        if target_ref not in ("", NO_TARGET):
            return reject("target_not_applicable", "%s 不需要目标" % skill)
        target_ref = NO_TARGET
    else:
        entry = frame.target(target_ref)
        if entry is None:
            return reject("unknown_target", "target_ref=%s 不在本轮目标表" % target_ref)
        if str(entry.get("kind", "")) not in allowed_targets:
            return reject("target_kind_mismatch",
                          "%s 需要 %s，收到 %s(%s)" % (skill, "/".join(allowed_targets),
                                                     entry.get("kind"), target_ref))
        target = _target_payload(entry)
    capability_error = _check_actor_capability(skill, actor, target)
    if capability_error:
        return reject("capability_mismatch", capability_error)
    if skill == SKILL_BUILD:
        # 落点由程序算（模型不猜坐标）：取最近的合法建造落点候选。
        pos = _build_placement(frame, actor)
        if pos is None:
            return reject("no_build_placement", "本轮没有可用建造落点")
        target["pos"] = pos
    params_ref = (params_ref or KEEP_PARAMS).strip().upper()
    if params_ref == KEEP_PARAMS:
        params = {"ref": KEEP_PARAMS, "keep": True}
    else:
        preset = frame.param(params_ref)
        if preset is None:
            return reject("unknown_params", "params_ref=%s 不在本轮参数档" % params_ref)
        params = dict(preset)
    units = [str(u) for u in actor.get("units", []) or [] if str(u)]
    if not units:
        return reject("actor_has_no_units", "%s 当前没有可指挥成员" % actor_ref)
    # 采集**分配去冲突**（实测 2026-09-12：一个执行者组里 3 个工人同目标 →
    # 全挤在同一个矿点上，互相卡住、部队被堵、有人闲置）。
    # 一行只能带一个目标，所以这里只让前 N 个工人去该矿点；其余由程序侧
    # 分配层（`rules_fallback`）分到别的矿点，避免"一组人盯一个矿"。
    if skill == SKILL_GATHER and len(units) > RESOURCE_WORKERS_PER_NODE:
        units = units[:RESOURCE_WORKERS_PER_NODE]
    squad_id = str(actor.get("squad_id", actor_ref))
    task_id = str(actor.get("task_id", "") or squad_id)
    task_version = int(frame.task_versions.get(squad_id, 0) or 0)
    # 与执行者**当前任务**比对：完全相同 → 只确认，不下发新命令。
    # 实测依据（2026-09-12 用户反馈）：模型没有记忆，每轮都会把同一行（如 W1 采集 R13）
    # 重新发一次；若不判定"未变化"，下游每轮都会当成新命令下发（工人采集被反复下令）。
    current = (frame.current_tasks or {}).get(squad_id) or {}
    unchanged = bool(current) and _task_signature(
        skill, target) == _task_signature(str(current.get("skill", "")),
                                          current.get("target") or {})
    modification = TaskModification(
        row_index=index, actor_ref=actor_ref, skill=skill, target_ref=target_ref,
        params_ref=params_ref, actor_kind=actor_kind, squad_id=squad_id, units=units,
        action=SKILL_TO_ACTION[skill], target=target, params=params,
        intent_id="tp-%s-%d" % (squad_id, index + 1), task_id=task_id,
        task_version=task_version,
        generations={u: int(frame.generations.get(u, 0) or 0) for u in units},
        unchanged=unchanged,
    )
    return modification, None


def _task_signature(skill: str, target: Dict[str, Any]) -> Tuple[str, str]:
    """任务指纹：技能 + 目标关键字段（实体/产物/位置）。

    只比"决定任务是否变化"的字段：坐标按 0.1 米取整（同一目标点的抖动不算变化）。
    """
    payload = target or {}
    entity = str(payload.get("entity_id", "") or payload.get("resource", "") or "")
    scene = str(payload.get("scene", "") or "")
    pos = payload.get("pos")
    pos_key = ""
    if isinstance(pos, (list, tuple)) and len(pos) >= 2:
        try:
            pos_key = "%.1f,%.1f" % (float(pos[0]), float(pos[1]))
        except (TypeError, ValueError):
            pos_key = ""
    return (str(skill or ""), entity or scene or pos_key)


def _check_actor_capability(skill: str, actor: Dict[str, Any],
                            target: Dict[str, Any]) -> str:
    """生产/建造必须"整条取自候选"：设施只能生产它被授权生产的产品。

    设计 §2.1：`PROD`/`BLD` 的候选项由程序按规则视图交叉匹配算出；
    模型自己拼装（把生产建筑与产物填反）是本项目实测出现过的错误。
    """
    scene = str(target.get("scene", ""))
    if skill == SKILL_PRODUCE:
        allowed = [str(x) for x in actor.get("products", []) or []]
        if allowed and scene not in allowed:
            return "%s 不能生产 %s（可生产：%s）" % (actor.get("ref"), scene,
                                                "/".join(allowed))
    if skill == SKILL_BUILD:
        allowed = [str(x) for x in actor.get("buildings", []) or []]
        if allowed and scene not in allowed:
            return "%s 不能建造 %s（可建造：%s）" % (actor.get("ref"), scene,
                                                "/".join(allowed))
    return ""


def _build_placement(frame: "DecisionFrame",
                     actor: Dict[str, Any]) -> Optional[List[float]]:
    """挑建造落点：**优先"空"**（离我方单位与建筑最远），再考虑离执行者近。

    实测依据（2026-09-12 用户反馈）：从前只按"离执行者最近"挑点，加上候选半径只有
    12m，结果 `barracks`/`vehicle_factory` 距指挥中心仅 5m，3 个工人被建筑堵在
    半径 1.5m 的小口袋里（实测坐标：CC(10,7)、barracks(10,12)、factory(5,7)、
    工人(8.4~10.1, 13.4~14.6)）——即"位置太紧把部队挡住了"。
    改为：最大化"到最近已占用点的距离"（净空），同分时取离执行者近的；
    净空完全相同时用坐标排序保证确定性（同观测 → 同落点）。
    """
    spots = list(getattr(frame, "build_spots", ()) or ())
    if not spots:
        return None
    pos = actor.get("pos") or [0.0, 0.0]
    try:
        ax, az = float(pos[0]), float(pos[1])
    except (TypeError, ValueError, IndexError):
        ax, az = 0.0, 0.0
    occupied = [tuple(p) for p in (getattr(frame, "occupied_points", ()) or ())
                if isinstance(p, (list, tuple)) and len(p) >= 2]

    def clearance(spot: Tuple[float, float]) -> float:
        if not occupied:
            return float("inf")
        return min((float(spot[0]) - float(o[0])) ** 2 + (float(spot[1]) - float(o[1])) ** 2
                   for o in occupied)

    best = max(spots, key=lambda s: (clearance(s),
                                     -((float(s[0]) - ax) ** 2 + (float(s[1]) - az) ** 2),
                                     (-float(s[0]), -float(s[1]))))
    return [round(float(best[0]), 1), round(float(best[1]), 1)]


def _target_payload(entry: Dict[str, Any]) -> Dict[str, Any]:
    """目标条目 → 既有权威链认识的 target 键（只暴露认识的键）。"""
    kind = str(entry.get("kind", ""))
    payload: Dict[str, Any] = {"kind": kind, "ref": str(entry.get("ref", ""))}
    if kind == TARGET_ENEMY:
        payload["entity_id"] = str(entry.get("entity_id", ""))
    elif kind in (TARGET_ANCHOR, TARGET_LOCATION):
        pos = entry.get("pos")
        if isinstance(pos, (list, tuple)) and len(pos) >= 2:
            payload["pos"] = [float(pos[0]), float(pos[1])]
    elif kind == TARGET_RESOURCE:
        payload["entity_id"] = str(entry.get("entity_id", ""))
        pos = entry.get("pos")
        if isinstance(pos, (list, tuple)) and len(pos) >= 2:
            payload["pos"] = [float(pos[0]), float(pos[1])]
    elif kind == TARGET_PRODUCT:
        payload["scene"] = str(entry.get("scene") or entry.get("product")
                               or entry.get("building") or "")
        payload["category"] = str(entry.get("category", "unit"))
    return payload


# ---------------- 展开成既有意图（兼容旧权威链） ----------------

def modifications_to_intents(result: DecodeResult, frame: DecisionFrame) -> IntentBatch:
    """把任务修改展开为 `IntentBatch`：元数据全部来自 `frame`。

    - `generation` 用**发起请求时绑定**的逐对象代际（权威端最终校验）；
    - `expires_tick` 用 frame.server_tick + TTL（不做续期）；
    - produce/build 的 producer 取 actor 指定的执行单位（权威端仍会复核权限）。
    """
    intents: List[TacticalIntent] = []
    for index, modification in enumerate(result.modifications):
        if modification.unchanged:
            # 复述现状：**不下发**（权威任务表里这条任务已在执行，行为树会自己循环）。
            # 计划 §4.1：模型只发"任务修改"；未提及/未变化的任务继续执行。
            continue
        target: Dict[str, Any] = {}
        action = modification.action
        payload = dict(modification.target)
        if action == ACTION_ATTACK:
            target["entity_id"] = str(payload.get("entity_id", ""))
        if action in (ACTION_MOVE, ACTION_ATTACK_MOVE, ACTION_DEFEND, ACTION_RETREAT,
                      ACTION_SCOUT, ACTION_REGROUP):
            pos = payload.get("pos")
            if isinstance(pos, (list, tuple)) and len(pos) >= 2:
                target["pos"] = [float(pos[0]), float(pos[1])]
        if action in (ACTION_PRODUCE, ACTION_BUILD):
            target["scene"] = str(payload.get("scene", ""))
            producer = ""
            if modification.units:
                producer = str(modification.units[0])
            target["producer"] = producer
            if action == ACTION_BUILD:
                pos = payload.get("pos")
                if isinstance(pos, (list, tuple)) and len(pos) >= 2:
                    target["pos"] = [float(pos[0]), float(pos[1])]
        if action == ACTION_GATHER:
            entity = str(payload.get("entity_id", ""))
            if entity:
                target["entity_id"] = entity
                target["resource"] = entity
        generation = max([modification.generations.get(u, 0) for u in modification.units]
                         or [0])
        # 【一个工地一个建造者】建造只派 **1 个**工人。
        # 为什么（2026-09-12 晚用户反馈："建造 1 个建筑就让一堆工人上，那矿不采了？"）：
        # 工人执行者是**集群**（`derive_squads` 按位置聚合，最多 `MAX_UNITS_PER_ACTOR` 个），
        # `unit_ids` 直接取整个集群 → 一条 `BLD` 就等于"全队上工地"，采集线当场停摆，
        # 违反决策手册 01 §3"四条线同时推进"。生产/采集/作战不受影响（那些本来就该整组动）。
        builder_units = list(modification.units)
        if action == ACTION_BUILD and builder_units:
            builder_units = builder_units[:1]
        intents.append(TacticalIntent(
            intent_id=modification.intent_id,
            plan_version=frame.plan_version,
            task_id=modification.task_id,
            unit_ids=builder_units,
            action=action,
            target=target,
            based_on_snapshot=int(frame.snapshot_id),
            issued_tick=int(frame.server_tick),
            expires_tick=int(frame.server_tick) + int(
                frame.emergency_intent_ttl_ticks if _is_emergency(modification.skill)
                else frame.intent_ttl_ticks),
            generation=int(generation),
        ))
    return IntentBatch(match_id=frame.match_id, player_id=frame.player_id,
                       plan_version=frame.plan_version,
                       based_on_snapshot=int(frame.snapshot_id), intents=intents)


def _is_emergency(skill: str) -> bool:
    return skill in (SKILL_RETREAT, SKILL_DEFEND, SKILL_ATTACK)


# ---------------- 语义合法性（验收 §7.A 用） ----------------

def semantic_problems(result: DecodeResult, frame: DecisionFrame) -> List[str]:
    """在解码之上再复核一遍语义：解码已逐列校验，这里给验收提供统一口径。"""
    problems: List[str] = []
    for modification in result.modifications:
        if modification.action not in ALLOWED_ACTIONS:
            problems.append("未知动作:%s" % modification.action)
        for unit in modification.units:
            if unit not in frame.generations and unit not in _all_actor_units(frame):
                problems.append("单位不在本轮授权:%s" % unit)
    return problems


def _all_actor_units(frame: DecisionFrame) -> set:
    units = set()
    for actor in frame.actors.values():
        units.update(str(u) for u in actor.get("units", []) or [])
    return units


def parse_task_patch(raw: Any) -> TaskPatchBatch:
    """解析入口：结构非法抛 ContractError（与旧契约一致的错误风格）。"""
    if isinstance(raw, TaskPatchBatch):
        return raw
    # 宽容一条**实测高频**的形态：模型把外层 `{"u": …}` 省了，直接回裸行数组
    # （模型输出 `[["W1","GAT","R5","P0"]]`）。语义完全等价（那正是 `u` 的值），
    # 整批打回只会换来一次无谓的降级——2026-09-12 真机实测：
    # `ContractError: task_patch: $: Input should be a valid dictionary or instance of
    # TaskPatchBatch` 在 100 秒里出现 16 次，每次都把战术模型降级成规则。
    if isinstance(raw, (list, tuple)):
        raw = {"u": list(raw)}
    from pydantic import ValidationError

    try:
        return TaskPatchBatch.model_validate(raw)
    except ValidationError as exc:
        from .contracts import _format_validation_errors  # 复用既有格式化
        raise ContractError(_format_validation_errors(exc), source="task_patch") from exc
    except TypeError as exc:
        raise ContractError(["$: 必须是对象（收到 %s）" % type(raw).__name__],
                            source="task_patch") from exc
