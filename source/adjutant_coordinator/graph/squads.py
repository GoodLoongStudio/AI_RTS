# -*- coding: utf-8 -*-
"""稳定小队（程序侧派生）与观测 → 引用表绑定。

依据（设计 §2.1/§2.2/§3.3）：
- 授权小队、合法目标、预算、生产关系、任务反馈和可选方案**由程序提供**；
  模型只做选择，不枚举全军单位、不猜坐标、不填资源账本；
- 引用表必须**每轮确定性生成**（同一观测 → 同一 ref），并在日志里留档，
  否则"模型选了什么"事后无法复核；
- `ref` 的稳定性边界：本模块派生的小队 ID 在**同一观测**下稳定；跨 tick 的长期
  归属由游戏权威端的小队表（阶段 B）提供，可通过 `authoritative_squads` 注入，
  一旦注入即以权威表为准（程序派生只作缺省兜底）。

单位事实字段来自游戏 `op=tactical` 的实体（kind/nane/unit_type/pos/hp/movement/
construct/gather/queue/attack），与 `model_context.build_tactics_context` 完全一致。
"""

from __future__ import annotations

import math
from typing import Any, Dict, List, Optional, Sequence, Set, Tuple

from . import placement
from .task_patch import (
    ACTOR_FACILITY, ACTOR_SQUAD, ACTOR_WORKER, KEEP_PARAMS, MODE_FAST, MODE_LIMITS,
    NO_TARGET, PARAM_PRESETS, DecisionFrame, SKILL_ORDER,
    TARGET_ANCHOR, TARGET_ENEMY, TARGET_LOCATION, TARGET_PRODUCT, TARGET_RESOURCE,
)

#: 集群粒度（米）：**同一格**是编队的候选范围（先按位置靠近，再按编制切分；
#: 见 `_compose_squads`）。这是**派生的缺省**，阶段 B 会换成游戏权威端维护的稳定小队。
CLUSTER_SIZE = 20.0

# ---------------- AI 小队编制（2026-09-14 用户规格）----------------
#: 用户原话："小队可以是步兵多一点，坦克 1-2 个就行，小队是给 AI 去指挥的，
#: 玩家也会有另一套分组小队系统。"
#:
#: 两条边界（都别越界）：
#: 1. 这里编的是 **AI 的指挥单位**；玩家侧的分组小队由游戏内那套系统自己管
#:    （`legacy_ai_squad_*` 那些组），本模块**不读、不写、不复用**；
#: 2. 编制只描述"谁跟谁一起走"，不涉及权限 —— 授权单位仍由 `authorized` 决定。
#:
#: 编成：**步兵为主（≤ `SQUAD_INFANTRY_MAX`）+ 坦克 1~2 个（≤ `SQUAD_TANK_MAX`）**。
#: 旧口径是"按 20m 格切，每 20 个一队" —— 实测（2026-09-14）出现"20 人一坨、
#: 队内最大间距 22m、坦克和步兵各走各的"，玩家看到的就是一堆单位挤在一个信标上。
SQUAD_INFANTRY_MAX = 6
SQUAD_TANK_MAX = 2
#: 单个执行者最多包含的单位数 = 步兵上限 + 坦克上限（**派生值**，不另写一个数）。
MAX_UNITS_PER_ACTOR = SQUAD_INFANTRY_MAX + SQUAD_TANK_MAX
#: 工人组上限：工人是**集群**语义（按位置聚合去采/去建），不是战斗编队，
#: 所以不受战斗编成约束（保持历史行为，别把采集线拆散）。
WORKER_GROUP_MAX = 20

#: 编制角色判据：类型名取自观测 `unit_type`（`op=tactical` 的实体字段）。
SQUAD_INFANTRY_TYPES = ("soldier",)
SQUAD_TANK_TYPES = ("tank", "heavy_tank")
#: 空中单位（`Domain.AIR`）：**不与地面同队** —— 空中/地面是**两套导航网格**
#: （`MatchConstants.gd`: `enum Domain { AIR, TERRAIN }`；`Drone/Helicopter/Scout.tscn`
#: 里 `Movement.domain = 0` = AIR），小队"一个中继点/一个队形"在空中+地面混合队里
#: 根本没有意义（实测确实出现过 `drone` 被编进地面小队）。
SQUAD_AIR_TYPES = ("drone", "helicopter", "scout")

#: 建造落点距地图边缘的最小余量（米）；**唯一口径在 `placement`**（此处只是别名）。
BUILD_BOUND_MARGIN_M = placement.BUILD_BOUND_MARGIN_M
#: 落点必须落在己方视野安全半径内（米）：**唯一口径在 `placement`**。
VISION_SAFE_RADIUS_M = placement.VISION_SAFE_RADIUS_M
#: 建造落点候选：**三圈（4/6/8m）**绕基地，槽位在圈上均布并互相错开。
#:
#: 实测依据（2026-09-12 晚，`model=on` 5 分钟真实局）：模型侧落点原本是 **20/32m**，
#: 结果是 213 条命令里 **172 条 `build` 被 `NotVisible` 拒** —— 权威端只接受"己方
#: 视野内的落点"，而视野半径是 **5m 量级**（历史事实：旧的"基地+5m"能成功建出兵营，
#: 8/12/16m 全被拒）。
#: 所以候选半径必须**收进视野**（与地板 `rules_fallback.pick_build_spot` 的 4/6/8 同口径）；
#: "别把部队挡住"这件事改由 `decode_task_patch._build_placement` 的**净空排序**
#: （离已占用点最远）解决，而不是靠把落点推到视野外 —— 那只会换来清一色 NotVisible。
BUILD_PLACEMENT_RADII: Tuple[float, ...] = (4.0, 6.0, 8.0)
#: 每圈槽位数（8 → 每 45° 一个）。
BUILD_PLACEMENT_SLOTS = 8
#: 兼容旧引用（旧名仍表示"最内圈半径"）。
BUILD_PLACEMENT_RADIUS = BUILD_PLACEMENT_RADII[0]
#: 侦察方向候选相对基地的半径（米）。
SCOUT_RADIUS = 35.0
#: 移动点相对"建筑实体"往外推的距离（米）。实测问题：把建筑自身坐标当移动点，
#: 单位奉命走过去就会"往建筑里钻"（寻路进不去、贴着墙抖）。据点/基点都推到外侧。
OUTSIDE_OFFSET_M = 8.0
#: 前压点相对基地的半径（米）。
FRONT_RADIUS = 25.0


def _pos_of(entity: Dict[str, Any]) -> Tuple[float, float]:
    """实体坐标 → 运动平面 (x, z)，缺省 (0,0)。"""
    pos = entity.get("pos") or [0.0, 0.0, 0.0]
    try:
        return float(pos[0]), float(pos[2])
    except (TypeError, ValueError, IndexError):
        return 0.0, 0.0


def _self_entities(tactical: Optional[Dict[str, Any]]) -> List[Dict[str, Any]]:
    if not isinstance(tactical, dict):
        return []
    return [e for e in (tactical.get("entities") or [])
            if isinstance(e, dict) and str(e.get("kind", "")) == "unit_self"]


def classify(entity: Dict[str, Any]) -> str:
    """单位角色：facility（可生产）/ worker（可建造或采集）/ squad（作战）。"""
    if bool(entity.get("queue")):
        return ACTOR_FACILITY
    if bool(entity.get("gather")) or bool(entity.get("construct")):
        return ACTOR_WORKER
    return ACTOR_SQUAD


def _cluster_key(units: Sequence[Dict[str, Any]], size: float = CLUSTER_SIZE) -> str:
    """按质心取整格 + 单位类型集合作为集群键（确定性、与遍历顺序无关）。"""
    if not units:
        return "0,0"
    xs = [p for p, _ in (_pos_of(u) for u in units)]
    zs = [z for _, z in (_pos_of(u) for u in units)]
    cx = int(math.floor((sum(xs) / len(xs)) / size))
    cz = int(math.floor((sum(zs) / len(zs)) / size))
    types = ",".join(sorted({str(u.get("unit_type", "")) for u in units}))
    return "%d,%d|%s" % (cx, cz, types)


def _chunk(units: List[Dict[str, Any]], size: int) -> List[List[Dict[str, Any]]]:
    return [units[i:i + size] for i in range(0, len(units), size)]


def _cell_key(entity: Dict[str, Any], size: float = CLUSTER_SIZE) -> str:
    """单位所在格（**只按位置，不含类型**）。

    与 `_cluster_key` 的区别是编制必需的：`_cluster_key` 把单位类型并进键里，
    于是"同一格的坦克"和"同一格的步兵"落在**两个不同集群**，永远组不成一支小队
    （这就是"编成只有单类型、坦克步兵各走各的"的机制）。
    """
    x, z = _pos_of(entity)
    return "%d,%d" % (int(math.floor(x / size)), int(math.floor(z / size)))


def squad_role(entity: Dict[str, Any]) -> str:
    """编制角色：`infantry` / `tank` / `air`。

    `_compose_squads` 只会收到**口径内的作战类型**（见 `_is_composable`），
    所以这里的兜底只覆盖"口径内的非坦克/非空中类型"（例如 `apc`）→ 按步兵计入。
    """
    unit_type = str(entity.get("unit_type", ""))
    if unit_type in SQUAD_AIR_TYPES:
        return "air"
    if unit_type in SQUAD_TANK_TYPES:
        return "tank"
    return "infantry"


def _combat_types(rules: Optional[Dict[str, Any]]) -> Tuple[str, ...]:
    """作战单位类型口径：**唯一实现在 `rules_fallback`**（此处只调用，不抄一份）。

    延迟导入：避免本模块与 `rules_fallback` 形成模块级循环依赖。
    """
    from . import rules_fallback

    return tuple(rules_fallback.combat_types_of({}, rules))


def _is_composable(entity: Dict[str, Any], combat_types: Sequence[str]) -> bool:
    """这个单位能不能进**战斗编队**：必须在作战口径内 **且可移动**。

    两道闸缺一不可：
    - **口径内**（`rules_fallback.combat_types_from_rules`：能打 ∧ 能动）—— 防止把工人/
      建筑（能力标志缺失时会被 `classify` 误判成作战）编进小队，那会变成"让建筑去移动"；
    - **可移动** —— 固定炮塔也在"能打"口径里，但它们动不了。
    """
    if str(entity.get("unit_type", "")) not in tuple(combat_types or ()):
        return False
    return bool(entity.get("movement"))


def _compose_squads(members: Sequence[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """同一格内的作战单位 → 若干小队（步兵为主 + 坦克 1~2 个，**确定性**）。

    返回 `[{"entities": [...], "mix": {"infantry": n, "tank": m, "air": k}}, ...]`。

    ## 规则（用户 2026-09-14 规格）
    - **步兵为主**：每队 ≤ `SQUAD_INFANTRY_MAX`；
    - **坦克 1~2 个**：每队 ≤ `SQUAD_TANK_MAX`，且**先保证每队都有 1 个**再补第 2 个
      （轮转分配），不是"前几队吃满、后面的队没有"；
    - **空中单独成队**：见 `SQUAD_AIR_TYPES`（空中/地面两套导航网格，混合队没有意义）；
    - 队数 = `max(ceil(步兵/上限), ceil(坦克/上限))` → 两边上限**同时**不会被突破；
    - **确定性**：按「离格内质心距离 → 名字」排序后再切分 —— 同一观测必得同一编组，
      且与输入遍历顺序无关（引用表可复核的前提）。
    """
    buckets: Dict[str, List[Dict[str, Any]]] = {"infantry": [], "tank": [], "air": []}
    for entity in members:
        buckets[squad_role(entity)].append(entity)
    if not members:
        return []
    cx, cz = _center(members)

    def ordered(items: Sequence[Dict[str, Any]]) -> List[Dict[str, Any]]:
        def sort_key(entity: Dict[str, Any]):
            x, z = _pos_of(entity)
            return (round(math.hypot(x - cx, z - cz), 3), str(entity.get("name", "")))
        return sorted(items, key=sort_key)

    infantry = ordered(buckets["infantry"])
    tanks = ordered(buckets["tank"])
    out: List[Dict[str, Any]] = []
    # 空中：单独成队，规模沿用同一上限（用户没给空中编制，不编造"1-2 个坦克"这类地面口径）。
    for part in _chunk(ordered(buckets["air"]), MAX_UNITS_PER_ACTOR):
        out.append({"entities": part, "mix": _mix_of(part)})
    if infantry or tanks:
        count = max(1,
                    math.ceil(len(infantry) / SQUAD_INFANTRY_MAX) if infantry else 0,
                    math.ceil(len(tanks) / SQUAD_TANK_MAX) if tanks else 0)
        squads: List[List[Dict[str, Any]]] = [[] for _ in range(count)]
        for index, tank in enumerate(tanks):
            squads[index % count].append(tank)          # 轮转：先每队 1 个，再补第 2 个
        for index, part in enumerate(_chunk(infantry, SQUAD_INFANTRY_MAX)):
            squads[index].extend(part)
        for part in squads:
            if part:
                part.sort(key=lambda e: str(e.get("name", "")))
                out.append({"entities": part, "mix": _mix_of(part)})
    return out


def _mix_of(units: Sequence[Dict[str, Any]]) -> Dict[str, int]:
    """小队的编制构成（留痕用：复盘能看出"这队是 6 步 2 坦还是 3 个无人机"）。"""
    mix = {"infantry": 0, "tank": 0, "air": 0}
    for entity in units:
        mix[squad_role(entity)] += 1
    return mix


def derive_squads(tactical: Optional[Dict[str, Any]], *,
                  authorized: Optional[Set[str]] = None,
                  authoritative: Optional[Sequence[Dict[str, Any]]] = None,
                  rules: Optional[Dict[str, Any]] = None
                  ) -> List[Dict[str, Any]]:
    """从观测派生小队/工人组/生产设施（确定性）。

    **作战小队按编制切**（`_compose_squads`）：步兵为主 + 坦克 1~2 个，
    空中单独成队；工人组与生产设施沿用各自口径（见 `WORKER_GROUP_MAX`）。

    `authoritative`：游戏权威端给的小队表（阶段 B）；给了就直接用，不做派生。
    `authorized`：AI 授权单位集合；None = 观测中的全部己方单位。
    """
    if authoritative:
        squads: List[Dict[str, Any]] = []
        for index, item in enumerate(authoritative, start=1):
            entry = dict(item)
            entry.setdefault("squad_id", str(entry.get("id") or ("S%d" % index)))
            entry.setdefault("units", [])
            squads.append(entry)
        return squads

    entities = []
    for entity in _self_entities(tactical):
        name = str(entity.get("name", ""))
        if not name:
            continue
        if authorized is not None and name not in authorized:
            continue
        # 不可移动又不生产的静态对象（防空/反地炮塔等）不进入执行者候选：
        # 它们无法执行移动/采集/建造，正常自卫由游戏行为树自己完成。
        if not (bool(entity.get("movement")) or bool(entity.get("queue"))):
            continue
        entities.append(entity)

    buckets: Dict[str, List[Dict[str, Any]]] = {ACTOR_SQUAD: [], ACTOR_WORKER: [],
                                                ACTOR_FACILITY: []}
    for entity in entities:
        buckets[classify(entity)].append(entity)

    groups: List[Dict[str, Any]] = []
    # 作战单位：先按**格**聚（不含类型，否则坦克/步兵永远组不到一起），再按编制切分。
    # 只有**口径内的作战类型**参与编队；其余（工人/建筑，或口径外的新类型）走"各自成组"
    # 的旧路径 —— 既不会把建筑编进小队，也**不许**让任何单位因为"没被认出来"而消失。
    combat_types = _combat_types(rules)
    squad_cells: Dict[str, List[Dict[str, Any]]] = {}
    others: List[Dict[str, Any]] = []
    for entity in sorted(buckets[ACTOR_SQUAD], key=lambda e: str(e.get("name", ""))):
        if _is_composable(entity, combat_types):
            squad_cells.setdefault(_cell_key(entity), []).append(entity)
        else:
            others.append(entity)
    for key in sorted(squad_cells):
        for squad in _compose_squads(squad_cells[key]):
            groups.append({"role": ACTOR_SQUAD, "key": key, "mix": dict(squad["mix"]),
                           "units": [str(u.get("name")) for u in squad["entities"]]})
    # 口径外对象：**按 (格, 类型) 聚合**（与历史上限一致）—— 类型不同就分到不同组，
    # 不会把"没认出来的东西"互相编到一起（拿不准就不编队，这是保守方向）。
    other_clusters: Dict[str, List[Dict[str, Any]]] = {}
    for entity in others:
        other_clusters.setdefault(_cluster_key([entity]), []).append(entity)
    for key in sorted(other_clusters):
        for part in _chunk(sorted(other_clusters[key], key=lambda e: str(e.get("name", ""))),
                           MAX_UNITS_PER_ACTOR):
            groups.append({"role": ACTOR_SQUAD, "key": key, "mix": {},
                           "units": [str(u.get("name")) for u in part]})
    # 工人：位置聚合的集群（历史上限 `WORKER_GROUP_MAX`，不受战斗编成约束）。
    worker_clusters: Dict[str, List[Dict[str, Any]]] = {}
    for entity in sorted(buckets[ACTOR_WORKER], key=lambda e: str(e.get("name", ""))):
        worker_clusters.setdefault(_cluster_key([entity]), []).append(entity)
    for key in sorted(worker_clusters):
        for part in _chunk(sorted(worker_clusters[key], key=lambda e: str(e.get("name", ""))),
                           WORKER_GROUP_MAX):
            groups.append({"role": ACTOR_WORKER, "key": key,
                           "units": [str(u.get("name")) for u in part]})
    for entity in sorted(buckets[ACTOR_FACILITY], key=lambda e: str(e.get("name", ""))):
        groups.append({"role": ACTOR_FACILITY, "key": str(entity.get("name", "")),
                       "units": [str(entity.get("name", ""))]})

    # 稳定排序：角色优先 → 集群键 → 首个单位名 → 统一编号。
    groups.sort(key=lambda g: (("squad", "worker", "facility").index(
        {ACTOR_SQUAD: "squad", ACTOR_WORKER: "worker",
         ACTOR_FACILITY: "facility"}[g["role"]]), g["key"], g["units"][0] if g["units"] else ""))
    squads = []
    for index, group in enumerate(groups, start=1):
        # 编号按类型分列：S1.. / W1.. / F1..（设计示例 S2/F1 即此含义）。
        squads.append({"squad_id": "%s%d" % (group["role"][0].upper(), index),
                       "index": index, "kind": group["role"], "cluster": group["key"],
                       # 编制构成留痕（复盘能一眼看出"这队是 6 步 2 坦还是 3 架无人机"）。
                       "mix": dict(group.get("mix") or {}),
                       "units": list(group["units"])})
    return _renumber(squads)


def persist_squads(previous, derived, living) -> List[Dict[str, Any]]:
    """跨轮稳定小队身份：重叠成员继承旧 `squad_id`，阵亡不整队重建。

    T08：不永久等满编、成员死亡不拆成全新编号。工人/设施每轮跟派生表走。
    """
    living_set = {str(name) for name in (living or [])}
    prev_list = [item for item in (previous or []) if isinstance(item, dict)]
    new_list = [item for item in (derived or []) if isinstance(item, dict)]
    prev_combat = [item for item in prev_list if str(item.get("kind")) == ACTOR_SQUAD]
    new_combat = [item for item in new_list if str(item.get("kind")) == ACTOR_SQUAD]
    extras = [item for item in new_list if str(item.get("kind")) != ACTOR_SQUAD]
    used_new = set()
    assigned = set()
    out: List[Dict[str, Any]] = []
    used_ids = set()
    for old in prev_combat:
        old_units = [str(name) for name in (old.get("units") or []) if str(name) in living_set]
        if not old_units:
            continue
        best_index, best_overlap = -1, 0
        for index, neu in enumerate(new_combat):
            if index in used_new:
                continue
            overlap = len(set(old_units) & {str(name) for name in (neu.get("units") or [])})
            if overlap > best_overlap:
                best_overlap, best_index = overlap, index
        if best_index >= 0 and best_overlap > 0:
            used_new.add(best_index)
            entry = dict(new_combat[best_index])
            entry["squad_id"] = old.get("squad_id")
            entry["task"] = old.get("task") or entry.get("task")
            entry["target"] = old.get("target") or entry.get("target")
            entry["rally"] = old.get("rally") or entry.get("rally")
            prior = max(1, len(old.get("units") or []))
            entry["status"] = "understrength" if len(entry.get("units") or []) < prior else (
                old.get("status") or "active")
            out.append(entry)
            used_ids.add(str(entry.get("squad_id")))
            assigned.update(str(name) for name in (entry.get("units") or []))
        else:
            remnant = dict(old)
            remnant["units"] = old_units
            remnant["count"] = len(old_units)
            remnant["status"] = "understrength"
            out.append(remnant)
            used_ids.add(str(old.get("squad_id")))
            assigned.update(old_units)

    def next_id() -> str:
        number = 1
        while ("S%d" % number) in used_ids:
            number += 1
        squad_id = "S%d" % number
        used_ids.add(squad_id)
        return squad_id

    for index, neu in enumerate(new_combat):
        if index in used_new:
            continue
        free = [str(name) for name in (neu.get("units") or []) if str(name) not in assigned]
        if not free:
            continue
        entry = dict(neu)
        entry["units"] = free
        entry["count"] = len(free)
        entry["squad_id"] = next_id()
        entry["status"] = entry.get("status") or "forming"
        assigned.update(free)
        out.append(entry)
    return out + _renumber(extras)


def _renumber(squads: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """按类型分别从 1 编号（S1/S2、W1/W2、F1/F2），保留稳定顺序。"""
    counters = {ACTOR_SQUAD: 0, ACTOR_WORKER: 0, ACTOR_FACILITY: 0}
    out: List[Dict[str, Any]] = []
    for squad in squads:
        kind = str(squad.get("kind", ACTOR_SQUAD))
        counters[kind] = counters.get(kind, 0) + 1
        entry = dict(squad)
        entry["squad_id"] = "%s%d" % (kind[0].upper(), counters[kind])
        out.append(entry)
    return out


def _cost_of(entry: Dict[str, Any]) -> int:
    """规则条目的造价（取第一条 cost 的 amount；缺失给 0，不编造）。"""
    for item in entry.get("cost") or []:
        if isinstance(item, dict):
            try:
                return int(item.get("amount", 0) or 0)
            except (TypeError, ValueError):
                return 0
    return 0


def _hp_pct(entity: Dict[str, Any]) -> int:
    """实体血量百分比（取整）；缺失或异常时给 -1（表示未知，不伪造 100%）。"""
    try:
        hp = float(entity.get("hp"))
        hp_max = float(entity.get("hp_max"))
        if hp_max <= 0:
            return -1
        return max(0, min(100, int(round(hp / hp_max * 100))))
    except (TypeError, ValueError):
        return -1


def _center(units: Sequence[Dict[str, Any]]) -> Tuple[float, float]:
    if not units:
        return 0.0, 0.0
    xs = [p for p, _ in (_pos_of(u) for u in units)]
    zs = [z for _, z in (_pos_of(u) for u in units)]
    return sum(xs) / len(xs), sum(zs) / len(zs)


def _structure_positions(tactical: Optional[Dict[str, Any]]) -> List[Tuple[str, float, float]]:
    """己方静态建筑（不可移动的己方实体）→ (name, x, z)。"""
    out: List[Tuple[str, float, float]] = []
    for entity in _self_entities(tactical):
        if bool(entity.get("movement")):
            continue
        x, z = _pos_of(entity)
        out.append((str(entity.get("name", "")), x, z))
    return sorted(out)


def _enemy_positions(tactical: Optional[Dict[str, Any]]) -> List[Tuple[str, float, float]]:
    enemies = [e for e in (tactical or {}).get("entities", []) or []
               if isinstance(e, dict) and str(e.get("kind", "")).startswith("unit_enemy")]
    return [(str(e.get("name", "")), *(_pos_of(e))) for e in sorted(
        enemies, key=lambda e: str(e.get("name", "")))]


def _resource_positions(tactical: Optional[Dict[str, Any]]
                        ) -> List[Tuple[str, float, float]]:
    resources = [e for e in (tactical or {}).get("entities", []) or []
                 if isinstance(e, dict) and str(e.get("kind", "")) == "resource"]
    return [(str(e.get("name", "")), *(_pos_of(e))) for e in sorted(
        resources, key=lambda e: str(e.get("name", "")))]


def _product_options(rules: Optional[Dict[str, Any]],
                     facility_units: Set[str], unit_type_of: Dict[str, str]
                     ) -> List[Dict[str, Any]]:
    """（设施 → 可生产产品）候选：来自规则视图的 productions 与设施能力交叉。"""
    options: List[Dict[str, Any]] = []
    if not isinstance(rules, dict):
        return options
    for relation in rules.get("productions", []) or []:
        product = str(relation.get("product_type_id", ""))
        if not product:
            continue
        for unit in sorted(facility_units):
            if unit_type_of.get(unit, "") in [str(t) for t in
                                              relation.get("allowed_producer_type_ids",
                                                           []) or []]:
                options.append({"producer": unit, "product": product})
    return options


def _build_options(rules: Optional[Dict[str, Any]],
                   worker_units: Set[str]) -> List[Dict[str, Any]]:
    """建造候选：**每座建筑只挂给一个工人**（其余工人留在地里继续采矿）。

    为什么必须收窄（2026-09-12 晚用户反馈："建造 1 个建筑就让一堆工人上，那矿不采了？"）：
    旧实现是 `for building: for unit in workers:` —— 同一集群里 N 个工人**都**拿到
    同一座建筑的候选，模型据此发 N 条 `BLD` 是**完全合理**的（候选即允许），
    结果全队停工去盖房子、采集线停摆。手册要求四条线**同时推进**，
    所以分工纪律是：**一个工地 ≤1 个建造者**，剩下的人干本职。
    这里按"建筑序号轮转"分配建造者，天然错开（第 i 座给第 i%N 个工人），
    避免所有建筑都压在同一个人身上。
    """
    options: List[Dict[str, Any]] = []
    if not isinstance(rules, dict):
        return options
    ordered = sorted(worker_units)
    if not ordered:
        return options
    for index, item in enumerate(rules.get("constructions", []) or []):
        building = str(item.get("id", ""))
        if not building:
            continue
        options.append({"builder": ordered[index % len(ordered)], "building": building})
    return options


def _in_map_bounds(spot, map_bounds) -> bool:
    """点是否在地图内（委派 `placement.in_bounds`，全项目唯一口径）。"""
    return placement.in_bounds(spot, map_bounds, BUILD_BOUND_MARGIN_M)


def _placement_radii(base_x: float, base_z: float,
                     map_bounds: Optional[Sequence[float]]) -> Tuple[float, ...]:
    """落点半径环 = **配置的环**（`BUILD_PLACEMENT_RADII`，已收在视野安全半径内）。

    **刻意不做"按锚点到边的距离统一收缩"**（曾经这么写过，是错的）：
    统一收缩会把"朝地图内侧、本来完全合法"的候选一起杀掉 —— 基地贴边时
    `usable` 会缩到 2m，而 2m 又低于最小净空，于是**整圈候选全被清空**，
    表现成"基地一贴边就再也建不出东西"。
    越界与否是**每个点各自的事**，交给 `placement.candidate_spots` 逐点筛
    （配合同一个账本，被拒的点会被拉黑并自动换点）。

    `map_bounds` 保留在签名里：调用方与既有测试都按这个契约传，且它决定了
    "哪些方位的候选能活下来"（逐点判定的输入）。
    """
    if not placement.has_bounds(map_bounds):
        return BUILD_PLACEMENT_RADII        # 没有地图尺寸：按配置环给，逐点再筛
    # 视野是硬上限：候选不得超出 `VISION_SAFE_RADIUS_M`（超出必被 NotVisible 拒）。
    return tuple(min(radius, VISION_SAFE_RADIUS_M) for radius in BUILD_PLACEMENT_RADII)


def build_decision_frame(
    *,
    match_id: str,
    player_id: str,
    rules_version: str,
    snapshot_id: int,
    server_tick: int,
    tactical: Optional[Dict[str, Any]],
    rules: Optional[Dict[str, Any]] = None,
    mode: str = MODE_FAST,
    authorized_units: Optional[Set[str]] = None,
    generations: Optional[Dict[str, int]] = None,
    task_versions: Optional[Dict[str, int]] = None,
    authoritative_squads: Optional[Sequence[Dict[str, Any]]] = None,
    current_tasks: Optional[Dict[str, Dict[str, Any]]] = None,
    #: 拒绝账本（`placement.RejectionLedger` 或旧坐标列表）：**建造落点候选必须过它**，
    #: 否则模型会看到已被权威拒过的坏点（实测同一点被拒 13 次）。
    rejected: Any = None,
    plan_version: str = "",
    phase_goal: str = "",
    intent_ttl_ticks: int = 3600,
    emergency_intent_ttl_ticks: int = 1200,
    created_monotonic: Optional[float] = None,
    deadline_seconds: Optional[float] = None,
    map_bounds: Optional[Sequence[float]] = None,
    campaign: Optional[Dict[str, Any]] = None,
) -> DecisionFrame:
    """观测 → `DecisionFrame`（含 actor/skill/target/params 四张引用表）。"""
    squads = derive_squads(tactical, authorized=authorized_units,
                           authoritative=authoritative_squads, rules=rules)
    by_name = {str(e.get("name", "")): e for e in _self_entities(tactical)}
    unit_type_of = {name: str(e.get("unit_type", "")) for name, e in by_name.items()}

    actors: Dict[str, Dict[str, Any]] = {}
    for squad in squads:
        units = [u for u in squad.get("units", []) or [] if u in by_name or not by_name]
        if not units:
            continue
        members = [by_name[u] for u in units if u in by_name]
        cx, cz = _center(members) if members else (0.0, 0.0)
        entry: Dict[str, Any] = {
            "ref": str(squad.get("squad_id")),
            "kind": str(squad.get("kind", ACTOR_SQUAD)),
            "squad_id": str(squad.get("squad_id")),
            "units": units,
            "count": len(units),
            "pos": [round(cx, 1), round(cz, 1)],
            "types": sorted({unit_type_of.get(u, "") for u in units}),
        }
        if members:
            pcts = [_hp_pct(m) for m in members]
            known = [p for p in pcts if p >= 0]
            if known:
                entry["hp_pct"] = int(round(sum(known) / len(known)))
        if entry["kind"] == ACTOR_FACILITY:
            entry["products"] = sorted({option["product"] for option in
                                        _product_options(rules, set(units), unit_type_of)})
        if entry["kind"] == ACTOR_WORKER:
            entry["buildings"] = sorted({option["building"] for option in
                                         _build_options(rules, set(units))})
        actors[entry["ref"]] = entry

    targets: Dict[str, Dict[str, Any]] = {}
    structures = _structure_positions(tactical)
    base_x, base_z = (structures[0][1], structures[0][2]) if structures else (0.0, 0.0)
    enemies = _enemy_positions(tactical)
    # 前压点 / 侦察方向都以"基地 → 最近敌人"为参考方向；无敌情时朝地图中心偏置。
    if enemies:
        ref_x, ref_z = enemies[0][1], enemies[0][2]
    else:
        ref_x, ref_z = base_x + 1.0, base_z + 1.0
    direction = (ref_x - base_x, ref_z - base_z)
    norm = math.hypot(*direction) or 1.0
    unit_dir = (direction[0] / norm, direction[1] / norm)
    perp = (-unit_dir[1], unit_dir[0])

    for index, (name, x, z) in enumerate(enemies, start=1):
        source = next((e for e in (tactical or {}).get("entities", []) or []
                       if str(e.get("name", "")) == name), {})
        targets["E%d" % index] = {"ref": "E%d" % index, "kind": TARGET_ENEMY,
                                  "entity_id": name, "pos": [round(x, 1), round(z, 1)],
                                  "hp_pct": _hp_pct(source),
                                  "cn": "敌人%d" % index}
    for index, (name, x, z) in enumerate(_resource_positions(tactical), start=1):
        targets["R%d" % index] = {"ref": "R%d" % index, "kind": TARGET_RESOURCE,
                                  "entity_id": name, "pos": [round(x, 1), round(z, 1)],
                                  "cn": "资源%d" % index}
    for index, (name, x, z) in enumerate(structures, start=1):
        # 基点也推到建筑**外侧**：防守/集结/撤回的目标点若落在建筑体内，
        # 单位会试图走进建筑（实测"往建筑里钻"）。基地锚点（不动的那座）除外。
        dx, dz = (x - base_x, z - base_z) if not (abs(x - base_x) < 1e-6
                                                 and abs(z - base_z) < 1e-6) else (1.0, 0.0)
        norm = math.hypot(dx, dz) or 1.0
        bx = x + dx / norm * OUTSIDE_OFFSET_M
        bz = z + dz / norm * OUTSIDE_OFFSET_M
        targets["B%d" % index] = {"ref": "B%d" % index, "kind": TARGET_ANCHOR,
                                  "entity_id": name, "pos": [round(bx, 1), round(bz, 1)],
                                  "cn": "基点%d外侧" % index}
    locations: List[Dict[str, Any]] = [
        {"kind": TARGET_LOCATION, "pos": [round(base_x, 1), round(base_z, 1)],
         "cn": "基地"},
        {"kind": TARGET_LOCATION,
         "pos": [round(base_x + unit_dir[0] * FRONT_RADIUS, 1),
                 round(base_z + unit_dir[1] * FRONT_RADIUS, 1)],
         "cn": "前压点"},
    ]
    for sign in (1, -1):
        locations.append({"kind": TARGET_LOCATION,
                          "pos": [round(base_x + perp[0] * SCOUT_RADIUS * sign, 1),
                                  round(base_z + perp[1] * SCOUT_RADIUS * sign, 1)],
                          "cn": "侧翼侦察点"})
    locations.append({"kind": TARGET_LOCATION,
                      "pos": [round(base_x + unit_dir[0] * SCOUT_RADIUS, 1),
                              round(base_z + unit_dir[1] * SCOUT_RADIUS, 1)],
                      "cn": "纵深侦察点"})
    # 据点：**建筑外侧**点（实测问题：把建筑实体坐标当移动点 → 单位奉命"往建筑里钻"）。
    # 沿"基地 → 建筑"方向再往外推 OUTSIDE_OFFSET_M 米，落到建筑外面。
    for index, (name, x, z) in enumerate(structures[:2], start=1):
        dx, dz = x - base_x, z - base_z
        norm = math.hypot(dx, dz)
        if norm < 1e-6:
            dx, dz, norm = 1.0, 0.0, 1.0
        ox = x + dx / norm * OUTSIDE_OFFSET_M
        oz = z + dz / norm * OUTSIDE_OFFSET_M
        locations.append({"kind": TARGET_LOCATION, "pos": [round(ox, 1), round(oz, 1)],
                          "cn": "据点%d外侧" % index})
    build_spots: List[Tuple[float, float]] = []
    spot_index = 0
    own_points = [_pos_of(entity) for entity in _self_entities(tactical)]
    # 候选生成走**唯一事实来源** `placement.candidate_spots`：返回的每个点都满足
    # 「界内 ∧ 视野内（离己方实体 ≤ VISION_SAFE_RADIUS_M）∧ 有净空 ∧ 未被拉黑」，
    # 已按 净空→近半径→槽位序 排好（确定性）。
    # 这里是**唯一**生成建造落点的地方：模型侧与地板侧的几何口径由此统一，
    # 不再出现"一边 4/6/8m 能建成、另一边 20/32m 清一色 NotVisible"的割裂。
    for spot in placement.candidate_spots(
            base_x, base_z,
            bounds=map_bounds,
            own_points=own_points,
            # 拒绝账本**必须传进来**（2026-09-14 迭代3 现场修）：漏传时模型仍会看到
            # 已被拒的坏点 → 选它 → 又一条注定被拒的命令（"瞎下达"的另一半）。
            rejected=rejected,
            radii=_placement_radii(base_x, base_z, map_bounds),
            slots=BUILD_PLACEMENT_SLOTS):
        if spot in build_spots:      # 贴边时多圈会退化到同一半径 → 去重
            continue
        build_spots.append(spot)
        spot_index += 1
        locations.append({"kind": TARGET_LOCATION, "pos": [spot[0], spot[1]],
                          "cn": "建造落点%d" % spot_index})
    if not build_spots:
        # 极端情况（基地几乎贴角 / 候选全被拉黑）：给"朝地图中心后退"的点。
        # ⚠**兜底也必须过账本与几何判据**：老实现直接 `clamp_into_bounds((base_x, base_z))`
        # = 基地自身坐标 → 必然 `SurfaceNotBuildable`（实测同一点被拒 13 次）。
        # 全不可用就**不给落点**（空菜单好过一条注定被拒的命令 —— 用户："不能瞎下达"）。
        fallback = placement.retreat_spot(base_x, base_z, bounds=map_bounds,
                                          own_points=own_points, rejected=rejected)
        if fallback is None:
            clamped = placement.clamp_into_bounds((base_x, base_z), map_bounds)
            fallback = (clamped if placement.spot_issue(
                clamped, map_bounds, own_points, rejected) is None else None)
        if fallback is not None:
            build_spots.append((fallback[0], fallback[1]))
            locations.append({"kind": TARGET_LOCATION, "pos": [fallback[0], fallback[1]],
                              "cn": "建造落点1"})
    for index, item in enumerate(locations, start=1):
        targets["L%d" % index] = dict(item, ref="L%d" % index)

    # 可生产/可建造候选：U* = 单位，V* = 建筑（都来自规则视图，模型只选不造）。
    # 带上**造价**：模型必须能看到"这条要花多少钱"才能在有余额时决定发展
    # （实测用户反馈：余额 49750 却不建造——生产链路的提示里从来没有钱与造价）。
    products = sorted({str(r.get("product_type_id", ""))
                       for r in (rules or {}).get("productions", []) or []
                       if r.get("product_type_id")})
    product_cost = {str(r.get("product_type_id", "")): _cost_of(r)
                    for r in (rules or {}).get("productions", []) or []}
    for index, product in enumerate(products, start=1):
        targets["U%d" % index] = {"ref": "U%d" % index, "kind": TARGET_PRODUCT,
                                  "scene": product, "category": "unit",
                                  "cost": product_cost.get(product, 0),
                                  "cn": "可生产：%s" % product}
    buildings = sorted({str(c.get("id", ""))
                        for c in (rules or {}).get("constructions", []) or []
                        if c.get("id")})
    building_cost = {str(c.get("id", "")): _cost_of(c)
                     for c in (rules or {}).get("constructions", []) or []}
    for index, building in enumerate(buildings, start=1):
        targets["V%d" % index] = {"ref": "V%d" % index, "kind": TARGET_PRODUCT,
                                  "scene": building, "category": "building",
                                  "cost": building_cost.get(building, 0),
                                  "cn": "可建造：%s" % building}

    params: Dict[str, Dict[str, Any]] = {p["ref"]: dict(p) for p in PARAM_PRESETS}
    params[KEEP_PARAMS] = {"ref": KEEP_PARAMS, "keep": True, "cn": "维持当前参数"}
    for quantity in range(1, 9):
        params["Q%d" % quantity] = {"ref": "Q%d" % quantity, "qty": quantity,
                                    "cn": "批准数量 %d" % quantity}

    # 已有任务（权威任务表）：解析出可展示的目标 ref，并附到执行者上。
    # 渲染（"已在执行的任务不要重复输出"）与解码（`unchanged` 判定"未变化不下发"）共用这份数据。
    resolved_current: Dict[str, Dict[str, Any]] = {}
    if current_tasks:
        entity_ref = {str(t.get("entity_id")): str(t.get("ref"))
                      for t in targets.values() if t.get("entity_id")}
        scene_ref = {str(t.get("scene")): str(t.get("ref"))
                     for t in targets.values() if t.get("scene")}
        for actor_ref, actor in actors.items():
            entry = None
            for unit in actor.get("units", []):
                if unit in current_tasks:
                    entry = current_tasks[unit]
                    break
            if not entry:
                continue
            target = dict(entry.get("target") or {})
            ref = (entity_ref.get(str(target.get("entity_id", "")), "")
                   or scene_ref.get(str(target.get("scene", "")), ""))
            actor["current_task"] = {"skill": str(entry.get("skill", "")),
                                     "target_ref": ref, "target": target}
            resolved_current[actor_ref] = {"skill": str(entry.get("skill", "")),
                                           "target": target}

    limits = MODE_LIMITS.get(mode, MODE_LIMITS[MODE_FAST])
    # 已占用点（我方单位+建筑）：挑建造落点时避开，避免"建筑把部队堵住"。
    occupied: List[Tuple[float, float]] = []
    for entity in _self_entities(tactical):
        x, z = _pos_of(entity)
        occupied.append((round(x, 1), round(z, 1)))
    # 余额：**必须进 frame** —— 生产链路的提示渲染依赖它（模型据此决定建造/生产）。
    balance: Dict[str, int] = {}
    for key, value in ((tactical or {}).get("balance") or {}).items():
        try:
            balance[str(key)] = int(value)
        except (TypeError, ValueError):
            continue
    return DecisionFrame(
        match_id=str(match_id), player_id=str(player_id),
        rules_version=str(rules_version), snapshot_id=int(snapshot_id),
        server_tick=int(server_tick), mode=str(mode), actors=actors, targets=targets,
        params=params, generations=dict(generations or {}),
        task_versions=dict(task_versions or {}),
        plan_version=str(plan_version), phase_goal=str(phase_goal),
        intent_ttl_ticks=int(intent_ttl_ticks),
        emergency_intent_ttl_ticks=int(emergency_intent_ttl_ticks),
        created_monotonic=(created_monotonic if created_monotonic is not None
                           else __import__("time").monotonic()),
        deadline_seconds=float(deadline_seconds if deadline_seconds is not None
                               else limits["deadline_seconds"]),
        build_spots=tuple(build_spots),
        occupied_points=tuple(occupied),
        balance=balance,
        current_tasks=resolved_current,
        # 整局主线上下文（阶段/前沿/里程碑/四线/决策地图候选）：由 `frame_from_state`
        # 从 campaign_state 取 `context_view()`，本函数只透传（不自行推导）。
        campaign=dict(campaign or {}),
    )


def frame_to_prompt_tables(frame: DecisionFrame) -> Dict[str, Any]:
    """给模型的可见表（供 A/B 与生产提示词复用）。"""
    return frame.to_context()


def skill_matrix() -> List[Dict[str, Any]]:
    """技能表（模型据此知道"哪个 actor 能做什么、要什么目标"）。"""
    from .task_patch import ACTOR_ALLOWED_SKILLS, SKILL_ALLOWED_TARGETS, SKILL_TITLE_CN
    return [
        {"ref": skill, "cn": SKILL_TITLE_CN.get(skill, skill),
         "targets": [NO_TARGET] if SKILL_ALLOWED_TARGETS.get(skill) is None
         else list(SKILL_ALLOWED_TARGETS.get(skill) or []),
         "actors": [kind for kind, allowed in ACTOR_ALLOWED_SKILLS.items()
                    if skill in allowed]}
        for skill in SKILL_ORDER
    ]
