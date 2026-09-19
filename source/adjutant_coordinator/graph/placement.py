"""落点与命令可行性的**唯一事实来源**：什么坐标是"权威端会接受"的。

## 为什么必须有这个模块（2026-09-12 反复踩同一坑的根因）

此前"落点可行性"的知识散在四处：

1. `rules_fallback.in_map_bounds` / `_clamp_into_bounds`（自己一份几何判定）；
2. `squads._in_map_bounds` + **再次定义**的 `BUILD_BOUND_MARGIN_M`（第二份口径）；
3. `nodes._apply_receipt_to_state` 里对 `NotVisible/Occupied/OutOfBounds` 做**字符串匹配**、
   只记坐标点、且**全局退避**（一个坏点让全部建造停 15 秒）；
4. 各处凭经验写的半径常量（`BUILD_PLACEMENT_RADII` 是 20/32m，而实测视野只有 5m 量级）。

后果就是**同类问题换皮复发**：先越界（163/169 条 `OutOfBounds`）→ 补 `map_bounds`；
再换视野（172 条 `NotVisible`）→ 再补半径；下一次换个拒绝原因又要重新发现一遍。

本模块把三件事收成一处，**新增拒绝原因时只改这里**：

1. **几何判定**：`in_bounds` / `within_vision` / `too_close_to_own`（唯一口径）；
2. **候选生成**：`candidate_spots()` —— 任何产出落点的代码都用它，
   它只返回"界内 ∧ 视野内 ∧ 有净空 ∧ 未被拉黑"的点（"注定被拒的命令"在下发前就消失）；
3. **拒绝分类与账本**：`classify_rejection()` 把权威端的自由文本归到**有限类别**，
   `RejectionLedger` 按类记账、**按类修正维度**（几何类→收几何；契约类→不再产出该类意图），
   而不是"同一点无限重发"或"一点坏全局停摆"。

## 用法

```python
spots = candidate_spots(anchor_x, anchor_z, bounds=..., own_points=...,
                        rejected=ledger, radii=(4.0, 6.0, 8.0))
if spots:                      # 列表已按净空→近→确定性排序，取 [0] 即最优
    use(spots[0])
```
"""
from __future__ import annotations

import math
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

# --------------------------------------------------------------------------- 常量

#: 落点距地图边缘的最小余量（米）= 建筑 footprint 半径 + 裕度。
BUILD_BOUND_MARGIN_M = 3.0
#: 落点必须落在己方**任一实体**的这个半径内（米）。
#: 依据：建造被拒的唯一原因是 `NotVisible`，而视野半径是 5m 量级
#: （历史事实："基地+5m"能建成兵营，8/12/16m 全被拒）→ 8m 是保守上界。
VISION_SAFE_RADIUS_M = 8.0
#: 落点与己方实体的最小净空（米）：太近会把工人/部队堵住（实测被堵在 1.5m 口袋）。
MIN_OWN_CLEARANCE_M = 3.5
#: 防御塔"内圈"半径（米）：距基地锚点 < 此值算"留在基地内"。
#: 与 GDScript `DefenseController.TURRET_OUTER_RADIUS_M = 8.0` 同值（两侧必须同口径）。
TURRET_INNER_RADIUS_M = 8.0
#: 防御塔的**目标落点带**外缘（米）：站在基地外缘，但不一路外推到视野尽头。
#: 用户 2026-09-15 晚实测："AI副官让防御塔造的位置太靠外面了，这不对的" ——
#: 原实现以"离基地越远越优先"排序 + 候选上限 24/26m（有塔当视野锚点时继续外推），
#: 塔会越建越远，最后落在视野边缘、脱离基地支援。
TURRET_BAND_OUTER_M = 12.0


def turret_band_rank(distance_m: float) -> float:
    """防御塔"离基地远近"的打分：**带内越外越好，出了带越远越差**。

    唯一实现：`rules_fallback.pick_turret_spot`（规则地板）与
    `task_patch._build_placement`（四列模型路径）都调它，避免两条路径各自定义口径
    （历史事故全是"同一个常量两处各自定义"）。
    """
    if distance_m <= TURRET_BAND_OUTER_M:
        return distance_m
    return 2.0 * TURRET_BAND_OUTER_M - distance_m
#: 判定"同一个坏点"的量化网格（米）：避免浮点抖动把同一个点当成新点。
SPOT_GRID_M = 1.0

# --------------------------------------------------------------------- 拒绝分类

#: 类别 → 修正维度（生产者据此决定"改哪一维"，而不是重发同一条命令）。
#: - geometry / vision / occupancy → **改几何**（换点、收半径）
#: - contract / capability          → **不再产出该类意图**（源头上停发）
#: - stale                          → 换代际 / 丢弃（链路问题，不是内容问题）
REJECT_GEOMETRY = "geometry"
REJECT_VISION = "vision"
REJECT_OCCUPANCY = "occupancy"
REJECT_CONTRACT = "contract"
REJECT_CAPABILITY = "capability"
REJECT_STALE = "stale"
REJECT_OTHER = "other"
#: **目标本身打不了**（实测原文：`当前武器无法攻击该目标所处的域（地面/空中不匹配），
#: 请改打地面目标或用对空单位。`）→ 修正维度是**换目标**：
#: 换点没用、停发前缀也没用（换个敌人就能打）。2026-09-13 实测：一局 347 条命令里
#: **124 条**被这条原因拒掉，同一单位反复重发（Unit_43 攻击命令被拒 10 次）——
#: 用户原话"你下达命令不能瞎下达啊"的这一半就是它。
REJECT_TARGET = "target"
#: **链路没给任何原因**（只有 status、`reason` 为空）。与 OTHER 的区别：
#: OTHER 是"给了原因但我们不认识"（记账即可），UNSPECIFIED 是"什么都没给" ——
#: 对它重发同一条命令是**纯噪音**，必须按前缀停发。
REJECT_UNSPECIFIED = "unspecified"
#: **工地不存在 / 已完工 / 已失效**（实测原文错误码：`ConstructionSiteNotFound`）。
#: 修正维度与其它类别都不同：换点没用、换工人没用、换目标也没用 ——
#: 这个"工地"在权威端已经不是一个可施工的现场了，唯一正确的动作是
#: **把这个工地从"未完工清单"里清账**（并停发它的续建意图），否则：
#:   2026-09-14 真机实测 a局：阶梯输入 `unfinished_buildings=['Unit_5']` 从 tick 3k 挂到 26k，
#:   `rule-finish-site-Unit_5-*` 每 10~20 秒重发一次、每次都是 `ConstructionSiteNotFound`，
#:   而阶梯"有未完工工地就先续建"这一步**短路了后面所有步骤** →
#:   整局不再开新工地、闲工人（Unit_2）也一直用不上 = 玩家看到的"有建设需求但工人不去建"。
REJECT_SITE = "site"
#: 工地类拒绝的拉黑时长（tick）：**几乎等于本局不再重试**（100 tick/s 下 ≈ 30 分钟）。
#: 依据：工地不存在是**终态**（已完工 / 已被摧毁）；留一个上限只是为了让账本数值可解释。
SITE_BAN_TICKS = 180_000

#: 几何类拒绝：都可以靠"换一个点"解决。
GEOMETRY_KINDS = (REJECT_GEOMETRY, REJECT_VISION, REJECT_OCCUPANCY)
#: 内容类拒绝：换点没用，必须**停止产出**这类意图（否则就是刷屏噪音）。
CONTENT_KINDS = (REJECT_CONTRACT, REJECT_CAPABILITY)
#: 目标类拒绝：**换目标**才能解决（同一条命令对这个目标永远打不了）。
TARGET_KINDS = (REJECT_TARGET,)
#: 工地类拒绝：**清账**（把该工地移出未完工清单 + 停发它的续建意图）。见 `REJECT_SITE`。
SITE_KINDS = (REJECT_SITE,)
#: 按**意图前缀**停发的类别（= 内容类 + 无原因 + 工地类）。这些拒绝换点/换单位都没用。
PREFIX_BAN_KINDS = CONTENT_KINDS + (REJECT_UNSPECIFIED, REJECT_SITE)

#: 状态名本身不携带"为什么被拒"，归类前先剥掉。
#: 不剥的话，`"Rejected "`（空原因）会被当成一个"没见过的新原因"而混进 OTHER。
_STATUS_WORDS = ("PartiallyAccepted", "PendingAuthority", "Rejected", "Accepted",
                 "Failed", "Error")

#: 权威端自由文本 → 有限类别。**新增拒绝原因只在这里加一行。**
_REASON_MAP: Tuple[Tuple[str, str], ...] = (
    ("OutOfBounds", REJECT_GEOMETRY),
    ("SurfaceNotBuildable", REJECT_GEOMETRY),
    ("NotBuildable", REJECT_GEOMETRY),
    ("NotVisible", REJECT_VISION),
    ("Occupied", REJECT_OCCUPANCY),
    ("NotEnoughSpace", REJECT_OCCUPANCY),
    ("InvalidScene", REJECT_CONTRACT),
    ("UnknownProduct", REJECT_CONTRACT),
    ("MissingTarget", REJECT_CONTRACT),
    ("InvalidTarget", REJECT_CONTRACT),
    ("ContractInvalid", REJECT_CONTRACT),
    ("NotAllowed", REJECT_CAPABILITY),
    ("CannotExecute", REJECT_CAPABILITY),
    ("MissingAbility", REJECT_CAPABILITY),
    ("StaleGeneration", REJECT_STALE),
    ("Expired", REJECT_STALE),
    ("StalePlan", REJECT_STALE),
    # 武器域不匹配（英文错误码 + 权威端中文原文，两种写法都认）；
    # 判定"这个目标打不了"，修正维度 = **换目标**（见 REJECT_TARGET）。
    ("WeaponCannotTargetDomain", REJECT_TARGET),
    ("武器无法攻击该目标", REJECT_TARGET),
    ("地面/空中不匹配", REJECT_TARGET),
    # 工地类（见 REJECT_SITE）：权威端明确说"这个现场不是一个可施工的工地"。
    ("ConstructionSiteNotFound", REJECT_SITE),
    ("ConstructionAlreadyCompleted", REJECT_SITE),
    ("ConstructionSiteNotActive", REJECT_SITE),
    ("SiteNotFound", REJECT_SITE),
)


def classify_rejection(reason_text: Any) -> str:
    """把权威端返回的自由文本（status + reason）归到有限类别。

    三档而不是两档：

    - 认得的原因 → 对应类别（几何类换点 / 内容类停发）；
    - **什么都不给**（`"Rejected "`、`reason` 为空）→ ``REJECT_UNSPECIFIED``：
      这不是"未知原因"，而是"链路没给信息"。对它重发同一条命令是纯噪音 ——
      2026-09-12 实测 `build` 续建被误报成空原因拒绝，5 分钟刷了 30 条同一条命令；
    - 给了但不认识 → ``REJECT_OTHER``：记账但不过度反应（既不盲目重发，
      也不误判成几何问题去乱换点）。
    """
    text = str(reason_text or "")
    for token, kind in _REASON_MAP:
        if token in text:
            return kind
    stripped = text
    for status_word in _STATUS_WORDS:
        stripped = stripped.replace(status_word, " ")
    if not stripped.strip():
        return REJECT_UNSPECIFIED
    return REJECT_OTHER


# ------------------------------------------------------------------- 几何判定


def _as_pair(value: Any) -> Optional[Tuple[float, float]]:
    """把 `[x, z]` / `[x, y, z]` / `(x, z)` 统一成 `(x, z)`；拿不到返回 None。

    注意：游戏坐标是 3 维 `[x, y, z]`，**平面坐标是 (x, z)**（y 是高度），
    这里是踩过的坑：直接把 `pos[1]` 当 z 用会把"高度"当地图纵坐标。
    """
    if not isinstance(value, (list, tuple)) or len(value) < 2:
        return None
    try:
        if len(value) >= 3:
            return float(value[0]), float(value[2])
        return float(value[0]), float(value[1])
    except (TypeError, ValueError):
        return None


def has_bounds(bounds: Any) -> bool:
    """是否拿到了**可用**的地图尺寸（否则任何"越界/视野"判断都无从谈起）。"""
    if not (isinstance(bounds, (list, tuple)) and len(bounds) >= 2):
        return False
    try:
        return float(bounds[0]) > 0.0 and float(bounds[1]) > 0.0
    except (TypeError, ValueError):
        return False


def in_bounds(spot: Any, bounds: Any,
              margin: float = BUILD_BOUND_MARGIN_M) -> bool:
    """点是否落在地图内（**原点在角上**：`bounds = [size_x, size_z]`）。

    拿不到 bounds 时返回 True（不猜地图形状，保持旧行为）。
    """
    point = _as_pair(spot)
    if point is None or not (isinstance(bounds, (list, tuple)) and len(bounds) >= 2):
        return True
    try:
        size_x, size_z = float(bounds[0]), float(bounds[1])
    except (TypeError, ValueError):
        return True
    if size_x <= 0.0 or size_z <= 0.0:
        return True
    x, z = point
    return (margin <= x <= size_x - margin) and (margin <= z <= size_z - margin)


def clamp_into_bounds(spot: Any, bounds: Any,
                      margin: float = BUILD_BOUND_MARGIN_M) -> List[float]:
    """把点夹进地图内（最后兜底：至少保证"在地图里"，不再必然越界）。"""
    point = _as_pair(spot) or (0.0, 0.0)
    x, z = point
    if not (isinstance(bounds, (list, tuple)) and len(bounds) >= 2):
        return [round(x, 1), round(z, 1)]
    try:
        size_x, size_z = float(bounds[0]), float(bounds[1])
    except (TypeError, ValueError):
        return [round(x, 1), round(z, 1)]
    if size_x <= 0.0 or size_z <= 0.0:
        return [round(x, 1), round(z, 1)]
    return [round(min(max(x, margin), max(margin, size_x - margin)), 1),
            round(min(max(z, margin), max(margin, size_z - margin)), 1)]


def within_vision(spot: Any, own_points: Iterable[Any],
                  radius: float = VISION_SAFE_RADIUS_M) -> bool:
    """点是否在己方视野内（近似：离某个己方实体不过远）。

    **没有己方实体时返回 True**：此时"看不见任何地方"是事实缺失，不是否决理由，
    交由其它判定处理（不在这里替调用方猜）。
    """
    point = _as_pair(spot)
    if point is None:
        return False
    own = [_as_pair(item) for item in own_points or ()]
    own = [item for item in own if item is not None]
    if not own:
        return True
    x, z = point
    return any((x - ox) ** 2 + (z - oz) ** 2 <= radius * radius for ox, oz in own)


def first_own_distance(spot: Any, own_points: Iterable[Any]) -> float:
    """点到最近己方实体的距离；没有己方实体时返回 ``inf``。"""
    point = _as_pair(spot)
    if point is None:
        return float("inf")
    own = [_as_pair(item) for item in own_points or ()]
    own = [item for item in own if item is not None]
    if not own:
        return float("inf")
    x, z = point
    return min(math.hypot(x - ox, z - oz) for ox, oz in own)


def too_close_to_own(spot: Any, own_points: Iterable[Any],
                     clearance: float = MIN_OWN_CLEARANCE_M) -> bool:
    """点是否离己方实体太近（会把工人/部队堵住）。"""
    return first_own_distance(spot, own_points) < clearance


def spot_issue(spot: Any,
               bounds: Any = None,
               own_points: Iterable[Any] = (),
               rejected: Any = None,
               margin: float = BUILD_BOUND_MARGIN_M,
               vision_radius: float = VISION_SAFE_RADIUS_M,
               clearance: float = MIN_OWN_CLEARANCE_M) -> Optional[str]:
    """返回该落点的**问题类别**（`None` = 可用）。

    这是全项目唯一的"落点能不能用"判据：越界 → `geometry`；视野外 → `vision`；
    贴住己方实体 → `occupancy`；已被拉黑 → 原类别。调用方只需判 `None`。
    """
    if not in_bounds(spot, bounds, margin):
        return REJECT_GEOMETRY
    if not within_vision(spot, own_points, vision_radius):
        return REJECT_VISION
    if too_close_to_own(spot, own_points, clearance):
        return REJECT_OCCUPANCY
    if rejected is not None and is_banned(rejected, spot):
        return REJECT_OCCUPANCY
    return None


def spot_key(spot: Any) -> str:
    """落点的量化键（用于账本去重）：`"x,z"`，按 `SPOT_GRID_M` 取整。"""
    point = _as_pair(spot) or (0.0, 0.0)
    return "%.0f,%.0f" % (point[0] / SPOT_GRID_M, point[1] / SPOT_GRID_M)


# ------------------------------------------------------------------- 候选生成


def candidate_spots(anchor_x: float,
                    anchor_z: float,
                    bounds: Any = None,
                    own_points: Iterable[Any] = (),
                    rejected: Any = None,
                    radii: Sequence[float] = (4.0, 6.0, 8.0),
                    slots: int = 8,
                    clearance: float = MIN_OWN_CLEARANCE_M,
                    vision_radius: float = VISION_SAFE_RADIUS_M) -> List[Tuple[float, float]]:
    """围绕锚点生成**可行**落点候选，按"净空大 → 半径近 → 槽位序"降序返回。

    **任何产出建造落点的代码都必须用这个函数**（地板 `rules_fallback` 与模型侧
    `squads` 两侧共用），它保证返回的每个点都：界内 ∧ 视野内 ∧ 有净空 ∧ 未被拉黑。
    外圈相对内圈错开半格（`pi / slots`），避免两圈落在同一条辐射线上互相遮挡。

    两条不可动摇的纪律：
    - **先量化再校验**：返回的就是被校验过的那个点。曾踩过"校验未舍入值、
      返回舍入值"的坑：8.000m 的候选被舍入成 8.058m，恰好越出视野边界 → 又变成 `NotVisible`。
    - **只保留逐点筛选这一个机制**：不要在这里做"按锚点到边的距离统一收缩半径"——
      那会把**朝内侧那些本来合法**的候选一起杀掉（贴边基地甚至会把整圈清空），
      是"两个机制各管一半"的老毛病。界外/视野外/压占/被拉黑的点在这里**逐点**剔除即可。
    """
    own = [_as_pair(item) for item in own_points or ()]
    own = [item for item in own if item is not None]
    scored: List[Tuple[Tuple[float, float, int], Tuple[float, float]]] = []
    for radius_index, radius in enumerate(radii):
        offset = math.pi / slots * radius_index
        for slot in range(slots):
            angle = 2 * math.pi / slots * slot + offset
            spot = (round(anchor_x + math.cos(angle) * radius, 1),
                    round(anchor_z + math.sin(angle) * radius, 1))
            if spot_issue(spot, bounds, own, rejected, clearance=clearance,
                          vision_radius=vision_radius) is not None:
                continue
            distance = first_own_distance(spot, own)
            # 净空优先；同等净空取更近的半径（更可能在视野内、也少堵路）；再按槽位定序。
            scored.append(((distance, -radius, -slot), spot))
    scored.sort(key=lambda item: item[0], reverse=True)
    return [spot for _, spot in scored]


def farthest_on_bearing(origin_x: float,
                        origin_z: float,
                        direction: Sequence[float],
                        bounds: Any = None,
                        own_points: Iterable[Any] = (),
                        rejected: Any = None,
                        min_radius: float = 6.0,
                        max_radius: float = 24.0,
                        step: float = 2.0,
                        clearance: float = MIN_OWN_CLEARANCE_M,
                        vision_radius: float = VISION_SAFE_RADIUS_M
                        ) -> Optional[Tuple[float, float]]:
    """沿一个方位从近走到远，返回**最后一个**合法点（当前视野能伸到的最外沿）。

    中间出现坏点不中断：远处若有己方单位/建筑提供视野，外圈仍可能合法。
    一个合法点都没有则返回 None（宁可不建，不返回注定被拒的坐标）。
    """
    if not isinstance(direction, (list, tuple)) or len(direction) < 2:
        return None
    try:
        dx, dz = float(direction[0]), float(direction[1])
    except (TypeError, ValueError):
        return None
    norm = math.hypot(dx, dz)
    if norm < 1e-6:
        return None
    ux, uz = dx / norm, dz / norm
    last: Optional[Tuple[float, float]] = None
    radius = float(min_radius)
    while radius <= float(max_radius) + 1e-6:
        spot = (round(origin_x + ux * radius, 1), round(origin_z + uz * radius, 1))
        if spot_issue(spot, bounds, own_points, rejected, clearance=clearance,
                      vision_radius=vision_radius) is None:
            last = spot
        radius += float(step)
    return last


def _unique_bearings(bearings: Iterable[Any]) -> List[Tuple[float, float]]:
    seen = set()
    out: List[Tuple[float, float]] = []
    for item in bearings or ():
        if not isinstance(item, (list, tuple)) or len(item) < 2:
            continue
        try:
            dx, dz = float(item[0]), float(item[1])
        except (TypeError, ValueError):
            continue
        norm = math.hypot(dx, dz)
        if norm < 1e-6:
            continue
        key = (round(dx / norm, 3), round(dz / norm, 3))
        if key in seen:
            continue
        seen.add(key)
        out.append(key)
    return out


def _unique_spots(spots: Iterable[Any]) -> List[Tuple[float, float]]:
    seen = set()
    out: List[Tuple[float, float]] = []
    for item in spots or ():
        point = _as_pair(item)
        if point is None:
            continue
        key = spot_key(point)
        if key in seen:
            continue
        seen.add(key)
        out.append((round(point[0], 1), round(point[1], 1)))
    return out


def collect_perimeter_candidates(
        home: Sequence[float],
        bounds: Any = None,
        own_points: Iterable[Any] = (),
        rejected: Any = None,
        extra_origins: Iterable[Any] = (),
        bearings: Iterable[Any] = (),
        min_radius: float = 6.0,
        max_radius: float = 24.0,
        step: float = 2.0,
        ring_radii: Sequence[float] = (6.0, 8.0),
        slots: int = 8,
        vision_radius: float = VISION_SAFE_RADIUS_M) -> List[Tuple[float, float]]:
    """外围建造候选：沿方位取当前视野最远合法点，并绕已有建筑再扩一圈。

    开局只有基地时最远约等于 ``VISION_SAFE_RADIUS_M``；兵营/已有塔在外侧时，
    它们会提供视野，下一座就能继续外推。越界/看不见/贴住己方的点不会进表。

    ``vision_radius`` 由调用方按"场上有什么视野锚点"给：防御塔视野 16→64
    （2026-09-15 用户要求）后，已有塔时可以用远大于 8m 的半径继续外推。
    """
    home_point = _as_pair(home)
    if home_point is None:
        return []
    hx, hz = home_point
    extras = [_as_pair(item) for item in extra_origins or ()]
    extras = [item for item in extras if item is not None
              and math.hypot(item[0] - hx, item[1] - hz) > 0.5]
    compass = [(math.cos(2 * math.pi * index / 12), math.sin(2 * math.pi * index / 12))
               for index in range(12)]
    rays = _unique_bearings(list(bearings or ()) + compass)
    for ox, oz in extras:
        rays = _unique_bearings(rays + [(ox - hx, oz - hz)])
    spots: List[Tuple[float, float]] = []
    for ray in rays:
        spot = farthest_on_bearing(hx, hz, ray, bounds=bounds, own_points=own_points,
                                  rejected=rejected, min_radius=min_radius,
                                  max_radius=max_radius, step=step,
                                  vision_radius=vision_radius)
        if spot is not None:
            spots.append(spot)
    for origin in [(hx, hz)] + extras:
        spots.extend(candidate_spots(origin[0], origin[1], bounds=bounds,
                                    own_points=own_points, rejected=rejected,
                                    radii=ring_radii, slots=slots,
                                    vision_radius=vision_radius))
    return _unique_spots(spots)


def retreat_spot(anchor_x: float, anchor_z: float,
                 bounds: Any = None,
                 own_points: Iterable[Any] = (),
                 rejected: Any = None,
                 steps: Sequence[float] = (3.0, 5.0, 7.0),
                 margin: float = BUILD_BOUND_MARGIN_M,
                 clearance: float = MIN_OWN_CLEARANCE_M,
                 vision_radius: float = VISION_SAFE_RADIUS_M) -> Optional[List[float]]:
    """环上候选全被淘汰时的兜底：**朝地图中心**逐级后退，跳过不可用的点。

    为什么不是固定的"x + 5"：基地贴边时那个点本身就在界外，于是兜底点变成
    **永远的坏点**（实测死循环：同两个坏点被重试 160+ 次）。朝中心退在几何上必然收敛。
    """
    direction = (1.0, 0.0)
    if isinstance(bounds, (list, tuple)) and len(bounds) >= 2:
        try:
            dx = float(bounds[0]) / 2.0 - anchor_x
            dz = float(bounds[1]) / 2.0 - anchor_z
            norm = math.hypot(dx, dz)
            if norm > 1e-6:
                direction = (dx / norm, dz / norm)
        except (TypeError, ValueError):
            pass
    for step in steps:
        # 先量化再校验（同 `candidate_spots`）：返回值必须就是被校验过的点。
        spot = (round(anchor_x + direction[0] * step, 1),
                round(anchor_z + direction[1] * step, 1))
        if spot_issue(spot, bounds, own_points, rejected, margin=margin,
                      vision_radius=vision_radius, clearance=clearance) is not None:
            continue
        return [spot[0], spot[1]]
    return None


# ------------------------------------------------------------------- 拒绝账本


def is_banned(rejected: Any, spot: Any) -> bool:
    """点是否已被拉黑（`rejected` 可以是 `RejectionLedger` 或旧的坐标列表）。"""
    if rejected is None:
        return False
    if isinstance(rejected, RejectionLedger):
        return rejected.is_banned(spot_key(spot))
    key = spot_key(spot)
    for item in rejected:
        point = _as_pair(item)
        if point is not None and spot_key(point) == key:
            return True
    return False


class RejectionLedger:
    """按**类别**记账的拒绝账本（替代"只存坐标点 + 全局退避"）。

    两类键，对应的修正维度不同：

    - 几何类（geometry/vision/occupancy）→ 键是**落点**：换点即可，只影响这个点；
    - 内容类（contract/capability）     → 键是**意图前缀**（如 `rule-produce-worker`）：
      换点没用，达到阈值后**停止产出**该类意图，从源头掐掉"同一条坏命令刷屏"。

    阈值与拉黑时长与既有 `build_backoff` 同口径（3 次 / 900 tick），
    但作用域是**按键**而不是全局 —— 一个坏点不再让全部建造停摆。
    """

    #: 同一个键被拒几次后拉黑。
    BAN_AFTER = 3
    #: 拉黑时长（tick）。
    BAN_TICKS = 900

    def __init__(self) -> None:
        self.entries: Dict[str, Dict[str, Any]] = {}

    def add(self, kind: str, key: str, tick: int = 0, ban_now: bool = False,
            ban_ticks: Optional[int] = None) -> int:
        """记一次拒绝，返回该键的累计次数。

        `ban_now=True`：这一类拒绝**一次就够**（例：`ConstructionSiteNotFound` ——
        工地已经不存在了，再等 3 次只是白烧 3 轮命令），立刻拉黑；
        `ban_ticks` 覆盖默认拉黑时长（工地类用 `SITE_BAN_TICKS`）。
        """
        entry = self.entries.setdefault(str(key), {"kind": str(kind), "count": 0,
                                                   "last_tick": 0, "banned_until": 0})
        entry["kind"] = str(kind)
        entry["count"] = int(entry["count"]) + 1
        entry["last_tick"] = int(tick)
        if ban_now:
            entry["count"] = max(int(entry["count"]), self.BAN_AFTER)
        if int(entry["count"]) >= self.BAN_AFTER:
            window = self.BAN_TICKS if ban_ticks is None else int(ban_ticks)
            entry["banned_until"] = int(tick) + window
        return int(entry["count"])

    def is_banned(self, key: str, tick: Optional[int] = None) -> bool:
        entry = self.entries.get(str(key))
        if not entry:
            return False
        if tick is None:
            return int(entry["count"]) >= self.BAN_AFTER
        if int(tick) < int(entry.get("banned_until", 0) or 0):
            return True
        # 兜底：计数已到阈值却没写 banned_until（例如 tick=0 的历史数据）也算拉黑。
        return (int(entry.get("banned_until", 0) or 0) == 0
                and int(entry["count"]) >= self.BAN_AFTER)

    def banned_keys(self, tick: Optional[int] = None) -> List[str]:
        return sorted(key for key in self.entries if self.is_banned(key, tick))

    def counts_by_kind(self) -> Dict[str, int]:
        out: Dict[str, int] = {}
        for entry in self.entries.values():
            kind = str(entry.get("kind", REJECT_OTHER))
            out[kind] = out.get(kind, 0) + int(entry.get("count", 0) or 0)
        return out

    def snapshot(self) -> Dict[str, Any]:
        """进诊断：类别计数 + 被拉黑的键（排查"为什么它不造东西了"的第一眼）。"""
        return {
            "counts_by_kind": self.counts_by_kind(),
            "banned_keys": self.banned_keys(),
            "entries": {key: dict(value) for key, value in sorted(self.entries.items())},
        }


def plane_point(value: Any) -> Optional[Tuple[float, float]]:
    """公开的平面坐标归一化：`[x, y, z]` / `[x, z]` → `(x, z)`；拿不到返回 None。"""
    return _as_pair(value)


def intent_prefix(intent_id: Any) -> str:
    """意图前缀（**内容类拒绝的记账键**）：`rule-produce-worker-Unit_0-1234` →
    `rule-produce-worker`。

    内容类问题（scene 不对 / 单位没这个能力 / 目标形态错）**换点、换单位都没用**，
    只能按"这一类意图"停发；用单位名或 tick 当键会让同一个问题被重复记成无数条，
    永远到不了阈值 —— 这正是 2026-09-12 "同一条坏命令刷屏 976 次"的机制。
    """
    parts = str(intent_id or "").split("-")
    while parts and (parts[-1].isdigit() or parts[-1].startswith("Unit_")):
        parts.pop()
    return "-".join(parts)


def filter_rejected(intents: Any, state: Dict[str, Any],
                    tick: Optional[int] = None) -> List[Any]:
    """按账本过滤：被判"内容类不可行"的意图类别**本轮不再下发**。

    统一在出口过滤（而不是让每个生产者各自判断）："这条命令已被拒过 N 次"是
    **全局知识**，只应有一个地方执行 —— 否则同类问题会在每个生产者里各犯一次。
    """
    ledger = ledger_from_state(state)
    if tick is None:
        try:
            tick = int(state.get("server_tick", 0) or 0)
        except (TypeError, ValueError):
            tick = 0
    out: List[Any] = []
    for intent in intents or []:
        if not isinstance(intent, dict):
            continue
        prefix = intent_prefix(intent.get("intent_id", ""))
        if prefix and ledger.is_banned(prefix, tick):
            continue
        out.append(intent)
    return out


def ledger_from_state(state: Dict[str, Any]) -> RejectionLedger:
    """从状态恢复账本（兼容旧 `blocked_build_spots` 坐标列表）。"""
    ledger = RejectionLedger()
    raw = state.get("rejection_ledger")
    if isinstance(raw, dict):
        for key, entry in raw.items():
            if isinstance(entry, dict):
                ledger.entries[str(key)] = {
                    "kind": str(entry.get("kind", REJECT_OTHER)),
                    "count": int(entry.get("count", 0) or 0),
                    "last_tick": int(entry.get("last_tick", 0) or 0),
                    "banned_until": int(entry.get("banned_until", 0) or 0),
                }
    for point in state.get("blocked_build_spots") or []:
        pair = _as_pair(point)
        if pair is None:
            continue
        key = spot_key(pair)
        entry = ledger.entries.setdefault(key, {"kind": REJECT_GEOMETRY, "count": 0,
                                                "last_tick": 0, "banned_until": 0})
        entry["count"] = max(int(entry["count"]), RejectionLedger.BAN_AFTER)
    return ledger


def ledger_to_state(ledger: RejectionLedger, state: Dict[str, Any],
                    keep: int = 16) -> None:
    """把账本写回状态（有界：只留最近 `keep` 个键，避免无界增长）。"""
    entries = ledger.entries
    if len(entries) > keep:
        ordered = sorted(entries.items(),
                         key=lambda item: int(item[1].get("last_tick", 0) or 0))
        entries = dict(ordered[-keep:])
    state["rejection_ledger"] = {key: dict(value) for key, value in entries.items()}


__all__ = [
    "BUILD_BOUND_MARGIN_M", "VISION_SAFE_RADIUS_M", "MIN_OWN_CLEARANCE_M",
    "REJECT_GEOMETRY", "REJECT_VISION", "REJECT_OCCUPANCY", "REJECT_CONTRACT",
    "REJECT_CAPABILITY", "REJECT_STALE", "REJECT_OTHER", "REJECT_TARGET",
    "REJECT_SITE", "SITE_BAN_TICKS",
    "GEOMETRY_KINDS", "CONTENT_KINDS", "TARGET_KINDS", "SITE_KINDS", "RejectionLedger",
    "candidate_spots", "clamp_into_bounds", "collect_perimeter_candidates",
    "classify_rejection", "farthest_on_bearing", "filter_rejected",
    "first_own_distance", "has_bounds",
    "in_bounds",
    "intent_prefix", "is_banned", "ledger_from_state", "ledger_to_state",
    "plane_point", "retreat_spot", "spot_issue", "spot_key", "too_close_to_own",
    "within_vision",
]
