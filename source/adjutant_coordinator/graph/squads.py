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

#: 集群粒度（米）：同一格内的作战单位归为一个小队；这是**派生的缺省**，
#: 阶段 B 会换成游戏权威端维护的稳定小队。
CLUSTER_SIZE = 20.0
#: 单个执行者最多包含的单位数（设计 §3：默认约 12-20 个作战单位）。
MAX_UNITS_PER_ACTOR = 20

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


def derive_squads(tactical: Optional[Dict[str, Any]], *,
                  authorized: Optional[Set[str]] = None,
                  authoritative: Optional[Sequence[Dict[str, Any]]] = None
                  ) -> List[Dict[str, Any]]:
    """从观测派生小队/工人组/生产设施（确定性）。

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
    for kind in (ACTOR_SQUAD, ACTOR_WORKER):
        clusters: Dict[str, List[Dict[str, Any]]] = {}
        for entity in sorted(buckets[kind], key=lambda e: str(e.get("name", ""))):
            clusters.setdefault(_cluster_key([entity]), []).append(entity)
        for key in sorted(clusters):
            for part in _chunk(sorted(clusters[key], key=lambda e: str(e.get("name", ""))),
                               MAX_UNITS_PER_ACTOR):
                groups.append({"role": kind, "key": key,
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
                       "units": list(group["units"])})
    return _renumber(squads)


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
                           authoritative=authoritative_squads)
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
            radii=_placement_radii(base_x, base_z, map_bounds),
            slots=BUILD_PLACEMENT_SLOTS):
        if spot in build_spots:      # 贴边时多圈会退化到同一半径 → 去重
            continue
        build_spots.append(spot)
        spot_index += 1
        locations.append({"kind": TARGET_LOCATION, "pos": [spot[0], spot[1]],
                          "cn": "建造落点%d" % spot_index})
    if not build_spots:
        # 极端情况（基地几乎贴角 / 候选全被拉黑）：至少给一个**夹进地图**的落点，
        # 不留空菜单（模型没有落点可选 = 整局无法建造）。
        fallback = placement.retreat_spot(base_x, base_z, bounds=map_bounds,
                                          own_points=own_points)
        if fallback is None:
            fallback = placement.clamp_into_bounds((base_x, base_z), map_bounds)
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
