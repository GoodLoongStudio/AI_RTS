# -*- coding: utf-8 -*-
"""安全移动硬闸门（计划 §7）。

## 计划原文（本模块逐条实现的对象）

> 禁止继续以"基地坐标 + 罗盘方向 + 半径"作为主力移动依据。固定流程：
> 侦察单位探路 → **权威导航查询得到路径** → 评估威胁和地图边界 → 生成安全中继点 →
> 侦察确认 → 主力按小队推进 → 到达由观测确认 → 重新观测并规划下一跳。
> 以下任一条件不满足，**主力不得野外移动**：
> ①`map_bounds` 缺失、非法或坐标系未确认；②没有权威导航路径或路径版本已过期；
> ③没有安全中继点或侦察确认；④单位属于工人、建造者、基地或其他重要保护对象；
> ⑤敌情出现、路径失败或侦察确认丢失后尚未重规划。

> 每个移动任务记录 `route_id/nav_revision/waypoints/route_length/threat_score/`
> `scout_confirmation/retreat_point/last_replan_tick`。
> 遇敌、受阻或路径失败立即停止当前推进并把事件送入 `urgent`；
> **不得用 `attack_move` 绕过检查**。到达只表示移动段完成。

## 为什么必须有这一层（改造前的事实）

改造前的"前压"是 `rules_fallback.military_waypoint()` 的**纯几何航点**（朝地图内侧 +
半径上限），行为树也是同一套 —— 两者都**不查导航路径**。后果：单位朝一个"图上看起来
合理、实际走不通"的点直线推进（实测就是"把兵送到地图边缘、中途遇敌被逐个击破"），
而且没有任何机制能证明"这条路走过得去"。

## 边界（刻意保守）

- 本模块**只读**：查询路径、算威胁、给判据；不发命令、不改游戏状态。
- 路径**只能**来自权威导航（`op=adjutant_nav_path`），Python 侧**不伪造**安全路线
  —— 计划明令。拿不到路径就是"不能走"，而不是"退化成直线"。
"""

from __future__ import annotations

import hashlib
import math
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

#: 角色：主力（要中继点 + 侦察确认）与专职侦察（只要求边界/路径/无敌情）。
#: **必须定义在 `RoutePlan` 之前**：该 dataclass 的字段默认值引用它们
#: （定义在后面 = 模块导入时 NameError，整个图都起不来）。
ROLE_MAIN = "main"
ROLE_SCOUT = "scout"
#: 求生移动（撤退/集结）：**不计入主力的侦察覆盖率**（那会把"被追着跑"算成"侦察到位"）。
ROLE_DISENGAGE = "disengage"

#: 受保护单位类型：**不许**野外移动（工人/基地/建筑）。计划 §7 第 ④ 条。
PROTECTED_TYPES = ("worker", "command_center")

#: 中继点必须落在"己方已有视野"内：超出该半径（米）的路段算**未侦察空间**，不能进。
#: 与 `placement.VISION_SAFE_RADIUS_M` 同量级（权威端只认视野内的落点）。
#:
#: 【2026-09-15 用户："只会直线进攻，要能绕路"】8.0 太短：一跳只有 8 米，
#: 每跳都要重观测重规划，观感就是"一段段直线蠕动"。放宽到 14.0 ≈ 单位视野量级，
#: 一跳能走到"它自己刚好看得见的最远处"，既保持"只推进到看得见的地方"的语义，
#: 又让推进明显更连贯。
#: ⚠ 放宽本值**不会**绕过"劣势必须撤退"：那条纪律由 `local_force` +
#: `ENGAGE_ADVANTAGE_RATIO`（下方）独立判定（实测把本值回滚到 8.0 时
#: `test_outnumbered_retreat_preempts_model_attack` 依然红 ⇒ 两者无关）。
RELAY_VISION_RADIUS_M = 14.0

#: 侦察确认的有效期（tick）：超过它没再看到，视为"侦察确认丢失"（计划 §7 第 ⑤ 条）。
SCOUT_CONFIRM_TTL_TICKS = 600

#: 威胁评估半径（米）：路径上这个范围内有可见敌人 → 记威胁分。
THREAT_RADIUS_M = 12.0

#: 威胁分阈值：达到就不再无条件放行，**改为进入局部战力判断**（见 `local_force`）。
#: 最低分 1.0 = "有可见敌人进入路径 12 米内"。
#:
#: 【2026-09-14 U2 · 计划 §4.1 明确替换】旧口径是"任何敌方实体进入固定半径 →
#: 一律禁止主力推进"（实测一局 `threat_too_high` 拦了 **11656** 次、放行 37 条，
#: 部队在基地门口发呆；审查 F03 还证明**一个工人与一辆坦克的威胁分相同**）。
#: 现在的口径：先看**可达性与地形**（不变），再按**局部战力**决定接敌/绕行/撤离。
THREAT_BLOCK_SCORE = 1.0

#: 局部接战评估半径（米）：只有落在这个圈里的双方单位才算"这一仗的参战方"。
#: 计划 U2 原文："远方友军不算即时支援；无武器目标不按等价战斗单位计数"。
LOCAL_CONTACT_RADIUS_M = 30.0
#: 允许**主动接敌**所需的局部优势（己方有效战力 / 敌方有效战力）。
#: 1.2 = "至少多两成才打"：低于它就走集结/撤离（不硬换）。这是本轮初始工程目标，
#: 由本模块单独登记，**不散落到别处**。
#:
#: 【2026-09-15 曾经试过降到 1.05，已回滚 —— 别再降】
#: 用户当时反馈"不派去探索和进攻"，我一度把它降到 1.05，但 `test_ladder_batch_integration`
#: 的「劣势撤离必须顶掉模型 attack」立刻红：那是**保命纪律**（避免"拿 1 个兵硬冲 3 个"）。
#: "让部队出门"应由 `RELAY_VISION_RADIUS_M`（视野/中继）解决，**不要靠下调接敌门槛**——
#: 后者会把"打不过就撤"变成"打不过也上"。
ENGAGE_ADVANTAGE_RATIO = 1.2


def parse_nav_revision(value, default: int = -1) -> int:
    """导航网格版本。0 是合法首版，不许写成 `value or -1`。"""
    if value is None:
        return default
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def local_force(tactical: Dict[str, Any], point: Sequence[float], *,
                combat_types: Sequence[str] = (),
                radius: float = LOCAL_CONTACT_RADIUS_M
                ) -> Tuple[float, float]:
    """接触点附近的**双方有效战力**（确定性；只数作战单位 × 血量比）。

    口径（刻意保守，不编造兵种权重）：
    - 只算 `combat_types` 里的类型（**唯一口径**来自 `rules_fallback.combat_types_from_rules`）——
      工人、建筑、无武装目标**不计入**（计划 U2："无武器目标不按等价战斗单位计数"）；
    - 单兵战力 = 血量百分比（0..1）；阵亡/缺血如实折算；
    - 只算 `radius` 内的单位：**远方友军不算即时支援**（计划 U2 原文）。

    返回 `(own_strength, enemy_strength)`。
    """
    if not isinstance(tactical, dict) or len(point) < 2:
        return 0.0, 0.0
    px, pz = float(point[0]), float(point[1])
    types = tuple(str(item) for item in (combat_types or ()))
    own = enemy = 0.0
    for entity in tactical.get("entities") or []:
        if not isinstance(entity, dict):
            continue
        kind = str(entity.get("kind", ""))
        is_enemy = kind.startswith("unit_enemy")
        if not (is_enemy or kind == "unit_self"):
            continue
        if is_enemy and entity.get("confirmed_dead"):
            continue
        unit_type = str(entity.get("unit_type", ""))
        # **类型未知 → 一律按"可能有武器"计入**（保守方向）：
        # 漏掉一个真敌人会让部队从敌人身边大摇大摆走过去，代价远大于多算一个非战斗单位；
        # 而"明确是已知非作战类型"（工人/建筑）才排除 —— 这也正是计划 U2 说的
        # "无武器目标不按等价战斗单位计数"。
        if types and unit_type and unit_type not in types:
            continue
        pos = entity.get("pos") or []
        if len(pos) < 3:
            continue
        if math.hypot(float(pos[0]) - px, float(pos[2]) - pz) > float(radius):
            continue
        hp, hp_max = entity.get("hp"), entity.get("hp_max")
        try:
            fraction = (float(hp) / float(hp_max)) if float(hp_max or 0) > 0 else 1.0
        except (TypeError, ValueError):
            fraction = 1.0
        if is_enemy:
            enemy += max(0.0, min(1.0, fraction))
        else:
            own += max(0.0, min(1.0, fraction))
    return round(own, 3), round(enemy, 3)


def _combat_types_of(state: Dict[str, Any]) -> Tuple[str, ...]:
    """作战单位口径（延迟导入 `rules_fallback`，避免模块级循环依赖）。"""
    from . import rules_fallback

    return tuple(rules_fallback.combat_types_of(state or {}))

#: 路径版本过期判据：`nav_revision` 变了 → 旧路径作废，必须重规划。
#: （烘焙期间查询会返回空路径 —— 双缓冲注释里记过"全地图单位查不到路径"。）

#: 小队**最大允许散开距离**（米）：队员与小隊中继点的距离超过它就不许继续推进。
#: 取值 = 2 × `RELAY_VISION_RADIUS_M`：队员之间已经互相看不见时，继续推进等于各自送死
#: （计划 §7「主力使用稳定小队和中继点，**不让单位各自散开**」）。
SQUAD_MAX_SPREAD_M = 2.0 * RELAY_VISION_RADIUS_M

#: 拒绝原因（**有限集合**，便于统计与守门测试）。
REJECT_NO_BOUNDS = "no_bounds"
REJECT_NO_PATH = "no_path"
REJECT_NO_RELAY = "no_relay"
REJECT_PROTECTED_UNIT = "protected_unit"
REJECT_ENEMY_UNREPLANNED = "enemy_unreplanned"
REJECT_STALE_REVISION = "stale_nav_revision"
REJECT_THREAT = "threat_too_high"
REJECT_NO_SCOUT_CONFIRMATION = "no_scout_confirmation"
#: 小队里有人过不了闸门 → **全队不推进**（不许"能走的先走、剩下的留在原地挨打"）。
REJECT_SQUAD_BLOCKED = "squad_blocked"
#: 队形已经散开（队员离小队中继点超过 `SQUAD_MAX_SPREAD_M`）→ 先集结，不推进。
REJECT_SQUAD_SCATTER = "squad_scatter"
#: 本轮路径查询配额不够验证整队 → 本轮不推进（宁可晚一轮，不许"验了一半就走"）。
REJECT_SQUAD_UNVERIFIED = "squad_unverified"
#: 求生移动（撤退）的脱离判据不成立：目标点/路径比现在更靠近敌人 → 不许"换个方向送"。
REJECT_NOT_DISENGAGING = "not_disengaging"
#: **没接上权威路径查询**（`nav_query is None`）：接线/配置问题，不是"这张图上没路"。
#: 【为什么必须与 `no_path` 分开】2026-09-14 U1：档案里 608 次 `no_path` 被折叠成一个原因，
#: 复盘根本分不出是"没接线""网格没烘""两点不连通"还是"端点被吸附"。计划 U1 明令
#: "移动域、地图 RID、网格版本 0、路径端点、视图位置、到达即空路径、网络超时分别记录"。
REJECT_NO_QUERY = "nav_query_unwired"
#: 权威端明确回答"导航网格当前不可用"（RID 非法 / 网格退化 / 正在重烘 / 查询平面不对）。
#: 这一类**不是单位走不过去**，而是那一域的网格本身不可用 —— 处理方式完全不同
#: （不该继续给同域单位规划移动，应换执行者或等网格）。
REJECT_NAVMESH_UNAVAILABLE = "navmesh_unavailable"
#: 权威端返回 ok 但路径点数 < 2：端点吸附/退化路径（与"两点不连通"不同）。
REJECT_PATH_TOO_SHORT = "path_too_short"
#: 查询本身失败（TCP 超时/抖动）：环境问题，下一轮可重试。
REJECT_NAV_TIMEOUT = "nav_timeout"

#: 权威端 `reason` → 我们的拒绝原因（**唯一映射处**，别处不许再自己判字符串）。
NAV_REPLY_REASONS = {
    "navmesh_unavailable": REJECT_NAVMESH_UNAVAILABLE,
    "no_path": REJECT_NO_PATH,
    "bad_request": REJECT_NO_PATH,
}


def no_path_reason(reply: Dict[str, Any]) -> str:
    """把权威端的失败回执**归类**成我们的拒绝原因（不折叠成单一 `no_path`）。

    依据（计划 U1）："不能统统折叠成『没路』"——不同原因的正确处置是相反的：
    网格不可用 → 换执行者/等网格；两点不连通 → 换目标；查询超时 → 下一轮重试。
    """
    if not isinstance(reply, dict):
        return REJECT_NO_PATH
    raw = str(reply.get("reason", "") or "")
    if raw in ("transport_error", "timeout", "bad_reply"):
        return REJECT_NAV_TIMEOUT
    return NAV_REPLY_REASONS.get(raw, REJECT_NO_PATH)

# ---------------------------------------------------------------------------
# 受阻降级（计划 §7：没有证据时**只能**集结、守卫、回基地或等待）
# ---------------------------------------------------------------------------
#
# 2026-09-13 结局局（10 分钟真实交战，我方战败、单位归零）的复盘结论之一：
# 部队被 `threat_too_high` 拦下之后**什么都不做**（丢弃意图、下一轮再试），
# 于是"停在原地挨打"。计划原文允许的四个归宿（集结/守卫/回基地/等待）里，
# 实现只做了"等待"，而且是**隐式**的 —— 日志上看起来像"决策失败"。
# 这里把四个归宿变成**显式**结果：每个被拦下的推进意图都必须落进其中之一。

#: 降级动作（值为**游戏侧已有动作**；`retreat/regroup→move`、`hold→stop` 由游戏侧翻译）。
FALLBACK_RETREAT = "retreat"
FALLBACK_REGROUP = "regroup"
FALLBACK_GUARD = "hold"
FALLBACK_WAIT = "wait"

#: 拒绝原因 → 降级动作（**唯一分档处**：按原因分档，不按调用方分档）。
#: 只有"敌人挡在路上"才需要"回基地/集结"；其余原因（拿不到边界/路径/中继点/侦察确认）
#: 属于"**没证据**"而不是"在挨打"，计划允许"等待" —— 强行移动反而等于绕过闸门。
REASON_FALLBACK: Dict[str, str] = {
    REJECT_THREAT: FALLBACK_RETREAT,
    REJECT_ENEMY_UNREPLANNED: FALLBACK_RETREAT,
    REJECT_SQUAD_SCATTER: FALLBACK_REGROUP,
    # 【U1 · 2026-09-14】**网格/接线类失败显式落进 `wait`**（而不是靠默认值）：
    # 它们不是"在挨打"，四个归宿里只有等待是安全的；**换执行者/换目标由上层负责**
    # （计划 U1："侦察者受阻/阵亡后转交合适单位；对持久不可达目标退避并换目标"）。
    REJECT_NAVMESH_UNAVAILABLE: FALLBACK_WAIT,
    REJECT_NO_QUERY: FALLBACK_WAIT,
    REJECT_PATH_TOO_SHORT: FALLBACK_WAIT,
    REJECT_NAV_TIMEOUT: FALLBACK_WAIT,
}

#: 求生移动的容差（米）：目标点必须比**当前位置**离最近可见敌人远这么多，才算"真的在脱离"。
#: 路径上任意一点都不许比现在更靠近敌人（容差同值）—— 否则就是"换个方向送"。
DISENGAGE_TOLERANCE_M = 1.0

#: 降级移动自己的路径查询配额（每 tick）。**不与推进共用**：共用的话，
#: 一波大推进打满配额时"正在被围攻的单位一个都撤不了"（顺序由候选表决定，不可控）。
FALLBACK_QUERIES_PER_TICK = 2

#: 降级意图的**窗口 id**（tick 粒度）：同一窗口内重复生成的降级意图 id 相同 →
#: 被仲裁层的 `intent_already_tracked` / 单位级判重挡掉，不会每轮重复下令
#: （"不重发仍在执行的命令"这条纪律仍然只有一处实现：仲裁层）。
FALLBACK_WINDOW_TICKS = 300

#: 求生移动结论的**复用窗口**（tick）：同一单位、同一目标在窗口内复用上一次的结论
#: —— 包括"撤不动"这种拒绝，不再重复查权威路径。
#: 为什么：2026-09-13 实测（240 秒局）218 次求生规划里有 71% 是 `not_disengaging`
#: （敌人正挡在回基地的路上），每次都花一次 DCS 往返；而 5 秒内结论几乎不会翻转。
SURVIVAL_REUSE_TICKS = 300

#: 求生移动的安全判据（`plan_survival_route(rule=...)`）。
RULE_DISENGAGE = "disengage"      # 撤退：目标点与路径都不许更靠近敌人
RULE_SAFE_SPOT = "safe_spot"      # 集结：目标点本身必须在敌人威胁半径之外


@dataclass
class RoutePlan:
    """一次安全移动的**完整记录**（计划 §7 要求逐字段留痕）。"""

    ok: bool = False
    reason: str = ""
    route_id: str = ""
    unit: str = ""
    #: 本次规划的**目标点**（原始意图点，不是中继点）—— 用于判断"目标变了要重规划"。
    target: List[float] = field(default_factory=list)
    nav_revision: int = -1
    waypoints: List[List[float]] = field(default_factory=list)
    route_length: float = 0.0
    threat_score: float = 0.0
    scout_confirmation: str = ""
    retreat_point: List[float] = field(default_factory=list)
    last_replan_tick: int = 0
    #: 本次只推进到哪个中继点（不是整条路径的终点）——"推进一跳、重观测再规划"。
    relay_point: List[float] = field(default_factory=list)
    #: 本次推进的**小队成员**（计划 §7「主力使用稳定小队」）。单人 = `[unit]`。
    squad: List[str] = field(default_factory=list)
    #: 角色（`main` / `scout`）。**统计必需**：侦察覆盖率的分母只能是主力规划 ——
    #: 侦察兵本来就"自带确认"（它的任务是扩大视野），把它算进分子会得到 >1 的比率
    #: （实测 454/1 = 455.0，一眼就是错的）。
    role: str = ROLE_MAIN
    #: 统计用：路径是否被地图边界夹过（`end_clamped` = 目标点原本在图外）。
    bound_clamped: bool = False
    #: 计划要求的事件：遇敌/受阻/路径失败要送 `urgent` 线。
    urgent_event: str = ""
    #: 受阻降级动作（`retreat/regroup/hold/wait`）；空 = 这条路线不是降级产物。
    fallback: str = ""
    #: 威胁判断用到的**局部战力**（计划 U2："按局部接战区域估算双方有效火力"）。
    #: 必须留痕：复盘要能回答"为什么这仗打了/没打"（旧口径只有一个威胁分，
    #: 一个工人和一辆坦克同分，根本看不出战力差）。
    local_own: float = 0.0
    local_enemy: float = 0.0

    def to_dict(self) -> Dict[str, Any]:
        return {
            "ok": self.ok, "reason": self.reason, "route_id": self.route_id,
            "unit": self.unit, "target": self.target, "nav_revision": self.nav_revision,
            "waypoints": self.waypoints, "route_length": self.route_length,
            "threat_score": self.threat_score,
            "scout_confirmation": self.scout_confirmation,
            "retreat_point": self.retreat_point,
            "last_replan_tick": self.last_replan_tick,
            "relay_point": self.relay_point, "squad": self.squad,
            "bound_clamped": self.bound_clamped,
            "urgent_event": self.urgent_event,
            "fallback": self.fallback,
            "local_own": self.local_own, "local_enemy": self.local_enemy,
        }


def is_protected(info: Dict[str, Any]) -> bool:
    """该单位是否属于"重要保护对象"（不许野外移动）。"""
    if not isinstance(info, dict):
        return True
    unit_type = str(info.get("type", ""))
    if unit_type in PROTECTED_TYPES:
        return True
    # 建造者（有 construct 能力的工人）同样受保护：把它派出去等于停工。
    if bool(info.get("construct")):
        return True
    # 不会动的单位（建筑）当然也不许"野外移动"。
    return not bool(info.get("movement"))


def valid_bounds(bounds: Any) -> bool:
    """`map_bounds` 是否**可用**：两元素、有限、> 0。缺失/非法一律判不可用。"""
    if not isinstance(bounds, (list, tuple)) or len(bounds) < 2:
        return False
    try:
        size_x, size_z = float(bounds[0]), float(bounds[1])
    except (TypeError, ValueError):
        return False
    if not (math.isfinite(size_x) and math.isfinite(size_z)):
        return False
    return size_x > 0.0 and size_z > 0.0


def inside_bounds(point: Sequence[float], bounds: Any, *, margin: float = 1.0) -> bool:
    if not valid_bounds(bounds) or len(point) < 2:
        return False
    size_x, size_z = float(bounds[0]), float(bounds[1])
    return (margin <= float(point[0]) <= size_x - margin
            and margin <= float(point[1]) <= size_z - margin)


def point_distance(a: Sequence[float], b: Sequence[float]) -> float:
    return math.hypot(float(a[0]) - float(b[0]), float(a[1]) - float(b[1]))


def route_id_for(unit: str, target: Sequence[float], nav_revision: int, tick: int) -> str:
    """稳定的路线标识：同一单位、同一目标、同一网格版本、同一次规划 = 同一个 id。"""
    raw = "%s|%.1f,%.1f|%d|%d" % (unit, float(target[0]), float(target[1]),
                                  int(nav_revision), int(tick))
    return "route-" + hashlib.sha1(raw.encode("utf-8")).hexdigest()[:10]


def visible_enemy_positions(tactical: Dict[str, Any]) -> List[Tuple[float, float]]:
    """可见敌人的平面坐标 —— **唯一口径**（威胁分 / 脱离判据 / 安全落点共用）。

    以前这段过滤条件（`kind` 前缀 + 未确认死亡）在 `threat_score` 里内联写了一份，
    脱离判据如果自己再抄一份，抄歪一次就会出现"威胁分说有敌人、脱离判据说没有"
    这种自相矛盾的闸门 —— 所以先收敛成一处，两边都调它。
    """
    positions: List[Tuple[float, float]] = []
    for entity in (tactical or {}).get("entities", []) or []:
        if not str(entity.get("kind", "")).startswith("unit_enemy"):
            continue
        if bool(entity.get("confirmed_dead")):
            continue
        position = _pos2d(entity)
        if position is not None:
            positions.append(position)
    return positions


def threat_score(tactical: Dict[str, Any], waypoints: Sequence[Sequence[float]],
                 *, radius: float = THREAT_RADIUS_M) -> float:
    """路径威胁分：可见敌人离路径越近、数量越多，分越高。

    口径**故意简单**（可复现、可解释）：每个敌人在 `radius` 内贡献 `1 + (radius-d)/radius`，
    取最大值而不是累加 —— 一个近敌足以否决推进，但不会因为一串远敌把分数堆到天上。
    """
    best = 0.0
    for position in visible_enemy_positions(tactical):
        nearest = min((point_distance(position, point) for point in waypoints),
                      default=float("inf"))
        if nearest <= radius:
            best = max(best, 1.0 + (radius - nearest) / max(radius, 0.001))
    return round(best, 2)


def nearest_enemy_distance(tactical: Dict[str, Any], point: Sequence[float]) -> float:
    """最近可见敌人到该点的距离（米）；没有可见敌人 → `inf`（"没有可脱离的对象"）。"""
    return min((point_distance(position, point)
                for position in visible_enemy_positions(tactical)),
               default=float("inf"))


def disengaging(tactical: Dict[str, Any], *, from_point: Sequence[float],
                to_point: Sequence[float],
                margin: float = DISENGAGE_TOLERANCE_M) -> bool:
    """**撤退的唯一判据**：目标点必须真的比原地更远离敌人。

    为什么不能用推进的那套判据（侦察确认 + 视野内中继点）去卡撤退：
    敌人就在前面时，"前方没有己方视野"恰恰是**要撤**的原因；用推进判据会把
    "敌人在前面"变成"不许撤" —— 那正是 2026-09-13 结局局"停在原地挨打"的一半成因。
    没有可见敌人 → 允许（谈不上"送"）。
    """
    enemies = visible_enemy_positions(tactical)
    if not enemies:
        return True
    now = min(point_distance(position, from_point) for position in enemies)
    dest = min(point_distance(position, to_point) for position in enemies)
    return dest > now + float(margin)


def route_not_toward_enemy(tactical: Dict[str, Any], waypoints: Sequence[Sequence[float]],
                           *, from_point: Sequence[float],
                           margin: float = DISENGAGE_TOLERANCE_M) -> bool:
    """撤退路径逐点检查：**任何一点**都不许比现在更靠近敌人。

    只检查终点是不够的：绕行路线可能先贴着敌人过去再回家（"看起来在撤，实际去送"）。
    """
    enemies = visible_enemy_positions(tactical)
    if not enemies:
        return True
    now = min(point_distance(position, from_point) for position in enemies)
    for point in waypoints:
        nearest = min(point_distance(position, point) for position in enemies)
        if nearest < now - float(margin):
            return False
    return True


def _pos2d(entity: Dict[str, Any]) -> Optional[Tuple[float, float]]:
    position = entity.get("pos")
    if not isinstance(position, (list, tuple)) or len(position) < 2:
        return None
    try:
        return (float(position[0]), float(position[2]) if len(position) > 2
                else float(position[1]))
    except (TypeError, ValueError):
        return None


def covered_by_own(by_name: Dict[str, Dict[str, Any]], point: Sequence[float],
                   *, radius: float = RELAY_VISION_RADIUS_M,
                   exclude: str = "") -> bool:
    """该点是否落在**己方某个单位**的视野圈里（= 已经看得见的地方）。"""
    for name, info in (by_name or {}).items():
        if str(name) == exclude:
            continue
        if not info.get("movement"):
            continue          # 建筑不提供"推进视野"（它不会动，视野是静态的）
        position = _pos2d(info)
        if position is None:
            continue
        if point_distance(position, point) <= radius:
            return True
    return False


def safe_relay_point(waypoints: Sequence[Sequence[float]],
                     by_name: Dict[str, Dict[str, Any]], *,
                     unit: str = "",
                     radius: float = RELAY_VISION_RADIUS_M) -> List[float]:
    """**安全中继点**：路径上"仍被己方视野覆盖"的**最远**那一点。

    语义（计划 §7）：主力只推进到看得见的地方，到了以后再重新侦察、重新规划下一跳。
    路径全在视野外 → 返回空（= 没有安全中继点 → 不许推进，而不是"照直走"）。

    注意**推进单位自己算覆盖**：它当然看得见自己前方这个半径内的地面，
    "一跳 = 自己视野覆盖的最远点"正是"推进 → 到达 → 重观测 → 下一跳"的实现。
    真正要被排除的是"靠敌人方向"——那由威胁分单独拦（见 `threat_score`）。
    """
    relay: List[float] = []
    for point in waypoints:
        if not covered_by_own(by_name, point, radius=radius, exclude=""):
            break
        relay = [float(point[0]), float(point[1])]
    return relay


def scout_confirmation(state: Dict[str, Any], tactical: Dict[str, Any],
                       point: Sequence[float], *,
                       tick: int, ttl: int = SCOUT_CONFIRM_TTL_TICKS) -> str:
    """侦察确认证据：`""` = 没有；否则返回**证据描述**（谁、什么时候看到过）。

    只认两类**事实**（不许猜）：
    1. 己方某机动单位此刻就在该点附近（直接看得到）；
    2. 情报表里该点附近有 `last_seen_tick` 未过期的记录（之前确认过）。
    """
    by_name = _by_name(tactical)
    for name, info in by_name.items():
        position = _pos2d(info)
        if position is None or not info.get("movement"):
            continue
        if point_distance(position, point) <= RELAY_VISION_RADIUS_M:
            return "unit:%s@%d" % (name, int(tick))
    intel = state.get("intel") or {}
    if isinstance(intel, dict):
        for name, entry in intel.items():
            if not isinstance(entry, dict):
                continue
            last_seen = int(entry.get("last_seen_tick", 0) or 0)
            if last_seen <= 0 or int(tick) - last_seen > int(ttl):
                continue
            position = _pos2d(entry)
            if position is not None and point_distance(position, point) <= RELAY_VISION_RADIUS_M:
                return "intel:%s@%d" % (name, last_seen)
    return ""


def _by_name(tactical: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    """单位视图（委派 `observation_view.normalized_units`，全仓唯一口径）。"""
    from .observation_view import normalized_units
    return normalized_units(tactical)


#: 角色常量在**文件顶部**定义（见 `ROLE_MAIN`/`ROLE_SCOUT` 上方注释）——
#: 它们被 `RoutePlan` 的字段默认值引用，放在类之后会让整个模块**导入即 NameError**。


def plan_safe_route(state: Dict[str, Any], tactical: Dict[str, Any], *,
                    unit: str, target: Sequence[float], tick: int,
                    nav_query: Optional[Callable[..., Dict[str, Any]]] = None,
                    role: str = ROLE_MAIN,
                    ) -> RoutePlan:
    """**唯一入口**：给一个移动尝试做完整的安全审查，返回可执行的中继点或拒绝原因。

    调用方（规则阶梯 / 行为树）**只允许**在 `plan.ok` 时发出移动意图，
    且目标必须是 `plan.relay_point`（一跳），不是原始目标点。

    两种角色（计划 §7 的流程本身就把它们分开了）：

    - `ROLE_MAIN`（主力）：额外要求**安全中继点 + 侦察确认** —— 只推进到看得见的地方；
    - `ROLE_SCOUT`（专职侦察）：它本来就负责**扩大视野**，所以不受"中继点必须在视野内"
      限制，但仍然要求边界合法、路径可达、路上没有可见敌人（侦察兵也不该一头撞进敌群）。
    """
    plan = RoutePlan(unit=str(unit), last_replan_tick=int(tick), squad=[str(unit)],
                     role=str(role), target=[float(target[0]), float(target[1])])
    bounds = state.get("map_bounds")
    if not valid_bounds(bounds):
        plan.reason = REJECT_NO_BOUNDS
        return plan
    by_name = _by_name(tactical)
    info = by_name.get(str(unit)) or {}
    if not info:
        plan.reason = REJECT_NO_PATH
        return plan
    if is_protected(info):
        # 工人/建造者/基地/建筑：**原地干自己的活**，不许野外移动。
        plan.reason = REJECT_PROTECTED_UNIT
        return plan
    if nav_query is None:
        # 没接上权威路径查询 = **接线/配置问题**，与"这张图上没有路"是两回事。
        plan.reason = REJECT_NO_QUERY
        return plan
    reply = nav_query(unit, target) or {}
    if not reply.get("ok"):
        plan.reason = no_path_reason(reply)
        plan.nav_revision = parse_nav_revision(reply.get("nav_revision"))
        plan.urgent_event = "path_failed"
        return plan
    plan.nav_revision = parse_nav_revision(reply.get("nav_revision"))
    waypoints = [[float(point[0]), float(point[1])]
                 for point in (reply.get("waypoints") or []) if len(point) >= 2]
    if len(waypoints) < 2:
        # `ok=true` 却不足两点：与"权威端直接说没路"不同（端点吸附/退化），单列。
        plan.reason = REJECT_PATH_TOO_SHORT
        plan.urgent_event = "path_failed"
        return plan
    plan.waypoints = waypoints
    plan.route_length = float(reply.get("route_length", 0.0) or 0.0)
    plan.bound_clamped = bool(reply.get("end_clamped")) or not inside_bounds(
        waypoints[-1], bounds)
    plan.route_id = route_id_for(str(unit), target, plan.nav_revision, tick)
    # ① 路径版本过期：上一次规划用的网格版本和现在不一致 → 作废重规划。
    previous = previous_route(state, str(unit))
    if previous and int(previous.get("nav_revision", -1)) != plan.nav_revision:
        plan.reason = REJECT_STALE_REVISION
        return plan
    if str(role) == ROLE_SCOUT:
        # 侦察兵：目标是**扩大视野**，允许走向未确认区域；中继点就用路径终点。
        plan.relay_point = list(waypoints[-1])
        plan.scout_confirmation = "scout:%s@%d" % (str(unit), int(tick))
    else:
        # ② 安全中继点：只推进到"己方视野覆盖得到"的最远点。
        plan.relay_point = safe_relay_point(waypoints, by_name, unit=str(unit))
        if not plan.relay_point:
            plan.reason = REJECT_NO_RELAY
            return plan
        # ③ 侦察确认：中继点必须有事实支撑（单位在附近 / 情报未过期）。
        plan.scout_confirmation = scout_confirmation(state, tactical, plan.relay_point,
                                                     tick=tick)
        if not plan.scout_confirmation:
            plan.reason = REJECT_NO_SCOUT_CONFIRMATION
            return plan
    # ④ 威胁评估：路径上出现敌人 → **按局部战力**决定接敌还是停（计划 §4.1/U2）。
    plan.threat_score = threat_score(tactical, waypoints)
    if plan.threat_score >= THREAT_BLOCK_SCORE:
        contact = waypoints[-1] if waypoints else plan.relay_point
        own, foe = local_force(tactical, contact, combat_types=_combat_types_of(state))
        plan.local_own, plan.local_enemy = own, foe
        advantage = (own / foe) if foe > 0 else float("inf")
        if str(role) == ROLE_SCOUT:
            # 侦察**优先避战**（计划 §4.1 原文）→ 仍然停下（换目标是上层的事）。
            plan.reason = REJECT_THREAT
            plan.urgent_event = "enemy_on_route"
            return plan
        if foe > 0 and advantage < ENGAGE_ADVANTAGE_RATIO:
            # 局部劣势/势均力敌 → 不许推进（集结/撤离由降级动作负责）。
            plan.reason = REJECT_THREAT
            plan.urgent_event = "enemy_on_route"
            return plan
        # 局部**优势**（或对方全是不算战力的目标）→ 允许沿合法路径进入交战距离。
        # 这不是"绕过闸门"：可达性、边界、权限、中继点、侦察确认都已经在上面验过了，
        # 这里只是把"是否值得打"从"有没有敌人"换成"打不打得过"（计划 §4.1）。
        plan.urgent_event = ""
    # 撤退点 = 该单位**当前所在点**（打不动/受阻就回这里，不是继续往深处走）。
    here = _pos2d(by_name.get(str(unit), {}))
    plan.retreat_point = [here[0], here[1]] if here else list(waypoints[0])
    plan.ok = True
    return plan


def fallback_action_for(blocked_action: str, reason: str) -> str:
    """被拦下的移动意图 → **降级动作**（四个合法归宿之一）。

    两条规则（都只有一处实现）：

    1. 被拦下的本来就是**求生移动**（撤退/集结）→ 说明"撤都撤不了"，
       只剩原地守卫/等待可选：直接退化到 `hold`，**不许**再生成一条撤退
       （那会和刚被拒的意图撞车，每轮重复下单）。
    2. 其余按**原因**分档（`REASON_FALLBACK`）：敌人挡路 → 回基地/集结；
       没证据（无边界/无路径/无中继点/无侦察确认）→ 等待。
    """
    if str(blocked_action) in (FALLBACK_RETREAT, FALLBACK_REGROUP):
        return FALLBACK_GUARD
    return REASON_FALLBACK.get(str(reason), FALLBACK_WAIT)


def plan_survival_route(state: Dict[str, Any], tactical: Dict[str, Any], *,
                        unit: str, target: Sequence[float], tick: int,
                        nav_query: Optional[Callable[..., Dict[str, Any]]] = None,
                        rule: str = RULE_DISENGAGE) -> RoutePlan:
    """**求生移动（撤退 / 集结）的唯一入口**：可执行 or 明确拒绝原因。

    与 `plan_safe_route`（主力**推进**）刻意分开，因为两者要证明的事情相反：

    - 推进要证明"前方是安全的、看得见的"（中继点 + 侦察确认）；
    - 撤退要证明"**我真的在变远**"（`RULE_DISENGAGE`）；
      集结要证明"**落点本身不在敌人威胁圈里**"（`RULE_SAFE_SPOT`）。

    共同点（一条都不放宽）：边界合法、权威路径可达、保护单位不许走、
    没有路径就是"不能走"（不许退化成直线）。
    """
    plan = RoutePlan(unit=str(unit), last_replan_tick=int(tick), squad=[str(unit)],
                     role=ROLE_DISENGAGE, target=[float(target[0]), float(target[1])])
    bounds = state.get("map_bounds")
    if not valid_bounds(bounds):
        plan.reason = REJECT_NO_BOUNDS
        return plan
    by_name = _by_name(tactical)
    info = by_name.get(str(unit)) or {}
    if not info:
        plan.reason = REJECT_NO_PATH
        return plan
    if is_protected(info):
        plan.reason = REJECT_PROTECTED_UNIT
        return plan
    if nav_query is None:
        plan.reason = REJECT_NO_PATH
        return plan
    reply = nav_query(unit, target) or {}
    if not reply.get("ok"):
        plan.reason = REJECT_NO_PATH
        plan.nav_revision = parse_nav_revision(reply.get("nav_revision"))
        plan.urgent_event = "path_failed"
        return plan
    plan.nav_revision = parse_nav_revision(reply.get("nav_revision"))
    waypoints = [[float(point[0]), float(point[1])]
                 for point in (reply.get("waypoints") or []) if len(point) >= 2]
    if len(waypoints) < 2:
        plan.reason = REJECT_NO_PATH
        plan.urgent_event = "path_failed"
        return plan
    plan.waypoints = waypoints
    plan.route_length = float(reply.get("route_length", 0.0) or 0.0)
    plan.bound_clamped = bool(reply.get("end_clamped")) or not inside_bounds(
        waypoints[-1], bounds)
    plan.route_id = route_id_for(str(unit), target, plan.nav_revision, tick)
    here = _pos2d(info) or tuple(waypoints[0])
    # 求生移动的**唯一安全判据**（见函数文档）：两条规则都读同一份"可见敌人"口径。
    if str(rule) == RULE_SAFE_SPOT:
        if nearest_enemy_distance(tactical, waypoints[-1]) < THREAT_RADIUS_M:
            plan.reason = REJECT_THREAT
            plan.urgent_event = "enemy_on_route"
            return plan
    else:
        if not disengaging(tactical, from_point=here, to_point=waypoints[-1]):
            plan.reason = REJECT_NOT_DISENGAGING
            return plan
        if not route_not_toward_enemy(tactical, waypoints, from_point=here):
            plan.reason = REJECT_NOT_DISENGAGING
            return plan
    plan.threat_score = threat_score(tactical, waypoints)
    plan.relay_point = [float(waypoints[-1][0]), float(waypoints[-1][1])]
    plan.retreat_point = [float(here[0]), float(here[1])]
    plan.scout_confirmation = "survival:%s@%d" % (str(rule), int(tick))
    plan.ok = True
    return plan


def rally_point(plans: Sequence["RoutePlan"], positions: Dict[str, Sequence[float]],
                ) -> List[float]:
    """小队**集结点** = 各成员中继点里离**自己**最近的那个（最慢的队友决定节奏）。

    `squad_hop` 的"选点"部分（唯一实现）；集结点与推进点同源，但**不**做散开判定：
    散开时正是要用这个点去把人叫回来。
    """
    usable = [plan for plan in plans if plan.ok and len(plan.relay_point) >= 2]
    if not usable:
        return []

    def hop_distance(plan: "RoutePlan") -> float:
        own = positions.get(str(plan.unit))
        if not own:
            return float("inf")
        return point_distance(own, plan.relay_point)

    chosen = min(usable, key=hop_distance)
    return [float(chosen.relay_point[0]), float(chosen.relay_point[1])]


#: 同一单位的安全路线**最短重规划间隔**（tick，默认 300≈10 秒）。
#: 为什么要它：路径查询是 2Hz 协调层里的 I/O，15 个单位每轮都查会打满 DCS
#: （实测扫描层一个人就用掉 10 次/秒）。目标没变、网格没换版本时复用在算的路线。
RELAY_REPLAN_TICKS = 300

#: 一轮协调最多发几次路径查询（保护 DCS：它是单线程处理请求的）。
#: 取 6 的理由（2026-09-13）：小队语义要求**整队每个成员**都有合法路径
#: （编队常见 1-3 人，见真机日志 `attack_move:active:Unit_23,Unit_28,Unit_8`），
#: 3 会让"3 人小队"永远因为配额不足被 `squad_unverified` 推迟；
#: 而路线在 `RELAY_REPLAN_TICKS` 内会被复用，稳态下几乎不重复查询。
NAV_QUERIES_PER_TICK = 6

#: **单人意图的保底配额**（在 `NAV_QUERIES_PER_TICK` 之外额外允许的查询次数）。
#: 为什么必须保底（2026-09-15 用户实测）：配额是**整个闸门一轮共享**的 ——
#: 前面的大部队推进把 6 次吃光后，**后面的单人侦察/单人前探**会被判
#: `squad_unverified` 拦下，"一个人、一条路"却永远出不了门。
#: 单人一次只要 1 次查询，给它一条独立额度既不打爆 DCS（单线程），
#: 又能保证侦察线每一轮都有推进机会。
SOLO_QUERY_RESERVE = 3


def needs_replan(state: Dict[str, Any], unit: str, target: Sequence[float],
                 nav_revision: int, tick: int) -> bool:
    """该单位是否需要**重新**规划路线（否则复用上一次的结论）。"""
    previous = previous_route(state, unit)
    if not previous:
        return True
    if int(previous.get("nav_revision", -1)) != int(nav_revision):
        return True
    old_target = previous.get("target") or []
    if len(old_target) >= 2 and point_distance(old_target, target) > 0.5:
        return True
    return int(tick) - int(previous.get("last_replan_tick", 0) or 0) >= RELAY_REPLAN_TICKS


def route_stale_only(state: Dict[str, Any], unit: str, target: Sequence[float],
                     nav_revision: int) -> bool:
    """旧路线只是"到了例行重规划间隔"（**目标与网格都没变**）→ 仍然可用。

    与 `needs_replan` 的分工：那个函数回答"要不要重新算"（含例行间隔），
    本函数回答"**旧的还能不能用**"。配额不足时（`SOLO_QUERY_RESERVE` 也用完）
    用它兜底：复用旧路，而不是把"明明有路可走"的单位判成
    `squad_unverified` 拦下来（2026-09-15 用户实测：侦察单位被长期拦截）。

    注意：目标变了 / 网格换版 → 返回 False（必须重新规划，不能拿旧路当新目标）。
    """
    previous = previous_route(state, unit)
    if not previous or not bool(previous.get("ok")):
        return False
    if int(previous.get("nav_revision", -1)) != int(nav_revision):
        return False
    old_target = previous.get("target") or []
    if len(old_target) >= 2 and point_distance(old_target, target) > 0.5:
        return False
    return len(previous.get("relay_point") or []) >= 2


#: 一条已批准的中继跳**最长复用时长**（tick，默认 1800 ≈ 30 秒）。
#: 为什么要有上限：复用是为了"别在半路改主意"，但也要防"卡在一条陈旧路线上永远不动"。
#: 到达 / 路径失败 / 遇敌 / 换网格都会自然作废它（`note_arrival` / `invalidate_route`），
#: 这里是第二道保险：超过它必须重新规划一次。
HOP_HOLD_MAX_TICKS = 1800


def hop_in_progress(state: Dict[str, Any], unit: str, nav_revision: int,
                    tick: int) -> bool:
    """该单位是否**正在执行**一条已批准的中继跳（在路上的，不许半路换目标）。

    ## 为什么要它（2026-09-13 用户实测原话）
    > "你下达命令不能瞎下达啊，部队还没到位，你就下达下一个命令了，这部队怎么跟得过来啊"

    根因：每个决策轮都会用**新算出来的**前压/推进点当目标（`rule-fill-advance-<单位>-<tick>`
    每轮一个 id、点也跟着敌情/基地位置重算），而 `needs_replan()` 看到"目标变了 >0.5m"
    就重规划 → **中继点每轮都变** → 单位在路上被反复改方向：
    表现为原地打转、队伍散开、永远走不到目的地（也让路径查询量随轮数暴涨）。

    ## 纪律
    **到位再下一条**：到达由观测确认（`note_arrival` 作废路线）→ 下一轮才规划下一跳。
    半路只有三种情况可以改：①路线被作废（路径失败/遇敌/玩家接管）；②网格换版本；
    ③这条跳已经老过 `HOP_HOLD_MAX_TICKS`（防卡死）。
    """
    entry = previous_route(state, unit)
    if not entry or not bool(entry.get("ok")):
        return False
    if int(entry.get("nav_revision", -1)) != int(nav_revision):
        return False
    if len(entry.get("relay_point") or []) < 2:
        return False
    age = int(tick) - int(entry.get("last_replan_tick", 0) or 0)
    return age <= HOP_HOLD_MAX_TICKS


def unit_en_route(state: Dict[str, Any], unit: str, tick: int) -> bool:
    """该单位是否正在执行已批准的一跳（`nav_revision=0` 是合法首版）。"""
    revision = parse_nav_revision(state.get("nav_revision") if isinstance(state, dict)
                                  else None)
    return hop_in_progress(state, str(unit), revision, int(tick))


def allowed_relay(state: Dict[str, Any], unit: str) -> Optional[List[float]]:
    """该单位**当前**被批准推进到的中继点；没有合法路线时返回 None。

    **唯一出口**：规则阶梯/行为树只能从这里拿移动目标 —— 它们不许自己算坐标，
    否则"无路径也能移动"这条闸门就形同虚设（计划 §7 第 ② 条）。
    """
    entry = previous_route(state, unit)
    if not entry or not entry.get("ok"):
        return None
    relay = entry.get("relay_point") or []
    if len(relay) < 2:
        return None
    return [float(relay[0]), float(relay[1])]


def squad_hop(plans: Sequence["RoutePlan"], positions: Dict[str, Sequence[float]],
              *, max_spread: float = SQUAD_MAX_SPREAD_M) -> Tuple[List[float], str]:
    """小队推进点：**各成员中最保守的那一跳**，并保证队形没散。

    返回 `(relay_point, reason)`；`reason` 非空 = 不许推进（全队原地）。

    设计（把"稳定小队、不各自散开"变成可判定的规则）：

    - 全队只认**一个**目标点：各成员中继点里**离自己最近**的那个 —— 最慢的队友决定节奏，
      这样队伍不会因为某个跑得快的成员而拉成长蛇阵；
    - 该点离任一队员超过 `max_spread` → `squad_scatter`：队形已经散到互相看不见，
      继续往前推就是各自送死。
    """
    usable = [plan for plan in plans if plan.ok and len(plan.relay_point) >= 2]
    if not usable:
        return [], REJECT_NO_RELAY
    relay = rally_point(plans, positions)
    if not relay:
        return [], REJECT_NO_RELAY
    if all(not positions.get(str(plan.unit)) for plan in usable):
        # 全部成员位置未知 → 不判散开（宁可放行，也不因缺数据卡死整队）。
        return relay, ""
    for plan in usable:
        own = positions.get(str(plan.unit))
        if own and point_distance(own, relay) > float(max_spread):
            return [], REJECT_SQUAD_SCATTER
    return relay, ""


def invalidate_route(state: Dict[str, Any], unit: str, *, reason: str = "") -> None:
    """作废该单位当前的路线（路径失败 / 敌情变化 / 网格换版本）。

    **作废而不是删除**：留着记录才能算"重规划延迟"（计划 §9 要报的指标），
    也才能让"下次是否真的重规划了"这件事可审计。
    作废后下一轮必然重新规划（`needs_replan` 与复用判据都要求 `ok`）。
    """
    entry = previous_route(state, unit)
    if not entry:
        return
    entry["ok"] = False
    entry["invalidated_reason"] = str(reason)
    entry["invalidated_tick"] = int(state.get("server_tick", 0) or 0)
    stats = state.setdefault("movement_stats", {})
    stats["invalidations"] = int(stats.get("invalidations", 0)) + 1


def note_arrival(state: Dict[str, Any], unit: str, tick: int) -> None:
    """到达确认（计划 §7「到达由观测确认 → 重新观测并规划下一跳」）。

    纪律：**到达只表示移动段完成**，不自动表示侦察/防守/攻击任务完成 ——
    所以这里只作废路线（逼出"下一跳重新规划"），不替任何任务打完成标记。
    """
    entry = previous_route(state, unit)
    if not entry:
        return
    entry["arrived_tick"] = int(tick)
    entry["ok"] = False
    entry["invalidated_reason"] = "arrived"
    # 到达同样让路线失效 → 也记 `invalidated_tick`，否则"重规划延迟"只覆盖
    # 路径失败类作废（实测 240 秒局 arrivals=440 但延迟样本恒 0：漏了这个字段）。
    entry["invalidated_tick"] = int(tick)
    stats = state.setdefault("movement_stats", {})
    stats["arrivals"] = int(stats.get("arrivals", 0)) + 1


def previous_route(state: Dict[str, Any], unit: str) -> Dict[str, Any]:
    routes = state.get("routes") or {}
    if isinstance(routes, dict):
        entry = routes.get(str(unit))
        if isinstance(entry, dict):
            return entry
    return {}


def _accumulate_replan_latency(state: Dict[str, Any], previous: Dict[str, Any],
                              plan: RoutePlan) -> None:
    """**重规划延迟**埋点（计划 §9）：从"路线失效"到"重新放行"隔了多少 tick。

    为什么要它：安全闸门的代价全在这里 —— 路线一失效（到达 / 路径失败 / 网格换版本 /
    敌情变化）就必须重规划，重规划要查一次权威路径（有配额）。只看"放行了几条路"
    看不出**部队多久才能真正动起来**；这条延迟是"闸门是不是把部队卡住了"的唯一数字。
    """
    invalidated = int(previous.get("invalidated_tick", 0) or 0)
    if not invalidated or not previous.get("invalidated_reason"):
        return
    latency = max(0, int(plan.last_replan_tick) - invalidated)
    stats = state.setdefault("movement_stats", {})
    samples = int(stats.get("replan_latency_samples", 0) or 0)
    stats["replan_latency_samples"] = samples + 1
    stats["replan_latency_last"] = latency
    stats["replan_latency_max"] = max(int(stats.get("replan_latency_max", 0) or 0), latency)
    total = int(stats.get("replan_latency_total", 0) or 0) + latency
    stats["replan_latency_total"] = total
    stats["replan_latency_avg"] = round(total / float(samples + 1), 2)


def record_route(state: Dict[str, Any], plan: RoutePlan) -> None:
    """把路线记录进状态（计划 §7 要求逐字段留痕 + 供统计）。"""
    routes = state.setdefault("routes", {})
    previous = routes.get(str(plan.unit)) or {}
    if isinstance(previous, dict):
        _accumulate_replan_latency(state, previous, plan)
    routes[str(plan.unit)] = plan.to_dict()
    # 统计累加（验收要"无路径移动数 / 越界数 / 侦察先行覆盖率"）。
    # 【求生移动不进这张账】它走 `record_survival()`：混进来会把"撤退不安全"报成"推进受阻"
    # （实测 240 秒局 `not_disengaging` 155 次盖过了真正的推进拒绝），所以 `plan_survival_route`
    # 的产物一律由调用方交给 `record_survival`，不经过这里。
    stats = state.setdefault("movement_stats", {})
    stats["planned"] = int(stats.get("planned", 0)) + 1
    if plan.ok:
        stats["allowed"] = int(stats.get("allowed", 0)) + 1
    else:
        blocked = stats.setdefault("blocked_reasons", {})
        blocked[plan.reason] = int(blocked.get(plan.reason, 0)) + 1
    if plan.bound_clamped:
        stats["bound_clamped"] = int(stats.get("bound_clamped", 0)) + 1
    if plan.threat_score:
        stats["threat_blocks"] = int(stats.get("threat_blocks", 0)) + 1
    # 【降级账本只在 `record_fallback` 记】这里**不**数 `plan.fallback`：
    # 同一个归宿会被记两次（本函数 + `record_fallback`）→ 实测"撤退 1 次"报成 2 次。
    if str(plan.role) == ROLE_MAIN:
        # 侦察覆盖率的分母 = **主力**规划数（侦察兵自带确认，算进去会得出 >1 的比率）。
        stats["main_plans"] = int(stats.get("main_plans", 0)) + 1
        if plan.scout_confirmation:
            stats["main_confirmed"] = int(stats.get("main_confirmed", 0)) + 1
    if plan.scout_confirmation:
        stats["scout_confirmed"] = int(stats.get("scout_confirmed", 0)) + 1
    # 派生指标**必须写回 state**：`movement_stats()` 是算出来的视图，
    # 只在日志里调用它 → `state["movement_stats"]` 里永远没有
    # `unsafe_dispatches`/`scout_first_coverage`（实测集成局报告读到 None）。
    state["movement_stats"] = movement_stats(state)


def survival_route_key(unit: str) -> str:
    """求生路线在 `routes` 里的键（前缀 + 单位名，不新占状态键）。"""
    return "survival|%s" % str(unit)


def previous_survival(state: Dict[str, Any], unit: str) -> Dict[str, Any]:
    routes = state.get("routes") or {}
    entry = routes.get(survival_route_key(unit)) if isinstance(routes, dict) else None
    return entry if isinstance(entry, dict) else {}


def nav_revision_changed(state: Dict[str, Any], unit: str) -> bool:
    """网格版本刚换过（缓存路线的版本 ≠ 当前版本）→ 权威端很可能正在重烘。

    用途：**别在重烘期间去查路径**。重烘时寻路查询会阻塞（实测单轮 3.24 秒：那一轮
    既在重烘、又发了一条求生撤退查询，协调线程整轮被卡住）。撤退/集结晚一轮再算完全安全，
    而这一轮查出来的还是过期网格上的路。
    """
    current = parse_nav_revision(state.get("nav_revision"))
    cached = parse_nav_revision(previous_route(state, unit).get("nav_revision"))
    if current < 0 or cached < 0:
        return False
    return current != cached


def survival_blocked(state: Dict[str, Any], unit: str, target: Sequence[float],
                     tick: int, *, ttl: int = SURVIVAL_REUSE_TICKS) -> str:
    """上一次"求生移动被拒"的结论是否还在有效窗口内（同一目标）→ 返回原因。

    复用拒绝结论是**唯一**省掉这次权威路径查询的办法；语义上等同于
    "5 秒内不要重复问同一个问题"，而不是放宽判据（窗口一过照样重查）。
    """
    entry = previous_survival(state, unit)
    reason = str(entry.get("reason", ""))
    if not reason or bool(entry.get("ok")):
        return ""
    old_target = entry.get("target") or []
    if len(old_target) < 2 or len(target) < 2:
        return ""
    if point_distance(old_target, target) > 0.5:
        return ""
    if int(tick) - int(entry.get("last_replan_tick", 0) or 0) >= int(ttl):
        return ""
    return reason


def record_survival(state: Dict[str, Any], plan: RoutePlan) -> None:
    """求生移动的留痕 + 记账（**不**写 `routes[unit]`）。

    为什么不能写 `routes[unit]`：那是"该单位当前被批准**推进**的路线"，
    `allowed_relay()` / `needs_replan()` 都读它。把求生路线写进去有两个后果：
    ①被拒的求生路线（`ok=False`）会把合法推进路线顶掉 → 下一轮被迫重规划；
    ②撤退终点会被当成"可推进中继点"发回给规则阶梯。
    """
    state.setdefault("routes", {})[survival_route_key(str(plan.unit))] = plan.to_dict()
    stats = state.setdefault("movement_stats", {})
    stats["disengage_plans"] = int(stats.get("disengage_plans", 0)) + 1
    stats["disengage_last_verdict"] = str(plan.reason) if not plan.ok else "ok"
    if plan.ok:
        stats["disengage_allowed"] = int(stats.get("disengage_allowed", 0)) + 1
    else:
        reasons = stats.setdefault("disengage_blocked_reasons", {})
        reasons[str(plan.reason)] = int(reasons.get(str(plan.reason), 0)) + 1
    state["movement_stats"] = movement_stats(state)


def record_fallback(state: Dict[str, Any], *, action: str, reason: str) -> None:
    """记一次**受阻降级**（计划 §7 的四个归宿之一）。

    为什么要记：`threat_too_high` 这类拦截以前只进 `blocked_reasons`，
    报告里看起来就是"某条路被拒"，看不出**部队接下来做了什么**。
    降级账本就是回答"拦住之后有没有归宿"的唯一口径。
    """
    stats = state.setdefault("movement_stats", {})
    by_action = stats.setdefault("fallbacks", {})
    by_action[str(action)] = int(by_action.get(str(action), 0)) + 1
    # 原因单独记一份（任何归宿都记）：报告要能回答"为什么只能这样"。
    reasons = stats.setdefault("fallback_reasons", {})
    reasons[str(reason)] = int(reasons.get(str(reason), 0)) + 1
    if str(action) == FALLBACK_WAIT:
        waits = stats.setdefault("fallback_wait_reasons", {})
        waits[str(reason)] = int(waits.get(str(reason), 0)) + 1
    state["movement_stats"] = movement_stats(state)


def movement_stats(state: Dict[str, Any]) -> Dict[str, Any]:
    """验收口径：把"无路径主力移动数"这类硬指标算出来。

    `unsafe_dispatches` 必须恒为 0 —— 它统计的是"规则/行为树发出了移动意图，
    但那条意图**没有**对应的合法路线记录"。非 0 就意味着闸门被绕过。

    `scout_first_coverage` = **主力**规划里走到"侦察确认"这一步的比例。
    分母只算主力（侦察兵自带确认，算进去会得出 455.0 这种不可能的比率 —— 实测踩过），
    分子是拿到确认的主力规划数（哪怕之后被威胁/边界挡掉）。
    """
    stats = dict(state.get("movement_stats") or {})
    # 侦察先行覆盖率 = **主力**规划里带侦察确认的比例（分母是主力规划数，不是"放行数"）。
    # 用"放行数"当分母会把侦察兵自己的规划算进分子 → 实测得出 455.0 这种不可能的比率。
    main_plans = int(stats.get("main_plans", 0) or 0)
    main_confirmed = int(stats.get("main_confirmed", 0) or 0)
    stats["scout_first_coverage"] = (round(min(1.0, main_confirmed / main_plans), 3)
                                     if main_plans else 0.0)
    stats["unsafe_dispatches"] = int(stats.get("unsafe_dispatches", 0) or 0)
    # 求生移动的拒绝原因单独成表（见 `record_route`：不许混进主力推进的 blocked_reasons）。
    disengage_reasons = stats.get("disengage_blocked_reasons")
    stats["disengage_blocked_reasons"] = (
        {str(k): int(v or 0) for k, v in disengage_reasons.items()}
        if isinstance(disengage_reasons, dict) else {})
    # 这几个键在"没发生"时**不存在**（不是 0）。报告里读出 `None` 会被误读成"没统计"，
    # 所以在这里补成 0 —— 口径：**没发生 = 0**，不许是 None。
    for key in ("ungated", "invalidations", "arrivals", "squad_advances", "squad_multi",
                "disengage_plans", "disengage_allowed",
                # 重规划延迟（计划 §9）：没发生 = 0，不是 None。
                "replan_latency_last", "replan_latency_max", "replan_latency_samples"):
        stats[key] = int(stats.get(key, 0) or 0)
    stats["replan_latency_avg"] = float(stats.get("replan_latency_avg", 0.0) or 0.0)
    # 受阻降级账本（"拦住之后有没有归宿"）：没发生 = 0 / 空表，绝不是 None。
    fallbacks = stats.get("fallbacks")
    stats["fallbacks"] = ({str(k): int(v or 0) for k, v in fallbacks.items()}
                          if isinstance(fallbacks, dict) else {})
    stats["fallback_total"] = sum(stats["fallbacks"].values())
    waits = stats.get("fallback_wait_reasons")
    stats["fallback_wait_reasons"] = ({str(k): int(v or 0) for k, v in waits.items()}
                                      if isinstance(waits, dict) else {})
    reasons = stats.get("fallback_reasons")
    stats["fallback_reasons"] = ({str(k): int(v or 0) for k, v in reasons.items()}
                                 if isinstance(reasons, dict) else {})
    return stats
