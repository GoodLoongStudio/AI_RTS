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

#: 受保护单位类型：**不许**野外移动（工人/基地/建筑）。计划 §7 第 ④ 条。
PROTECTED_TYPES = ("worker", "command_center")

#: 中继点必须落在"己方已有视野"内：超出该半径（米）的路段算**未侦察空间**，不能进。
#: 与 `placement.VISION_SAFE_RADIUS_M` 同量级（权威端只认视野内的落点）。
RELAY_VISION_RADIUS_M = 8.0

#: 侦察确认的有效期（tick）：超过它没再看到，视为"侦察确认丢失"（计划 §7 第 ⑤ 条）。
SCOUT_CONFIRM_TTL_TICKS = 600

#: 威胁评估半径（米）：路径上这个范围内有可见敌人 → 记威胁分。
THREAT_RADIUS_M = 12.0

#: 威胁分阈值：达到就不许推进（改为集结/守卫）。
#: 最低分 1.0 = "有可见敌人进入路径 12 米内" —— 也就是**遇敌即停**（计划 §7
#: "敌情出现…尚未重规划 → 不得野外移动"）。分数本身用于报告"离得多近"。
THREAT_BLOCK_SCORE = 1.0

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
    #: 统计用：路径是否被地图边界夹过（`end_clamped` = 目标点原本在图外）。
    bound_clamped: bool = False
    #: 计划要求的事件：遇敌/受阻/路径失败要送 `urgent` 线。
    urgent_event: str = ""

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


def threat_score(tactical: Dict[str, Any], waypoints: Sequence[Sequence[float]],
                 *, radius: float = THREAT_RADIUS_M) -> float:
    """路径威胁分：可见敌人离路径越近、数量越多，分越高。

    口径**故意简单**（可复现、可解释）：每个敌人在 `radius` 内贡献 `1 + (radius-d)/radius`，
    取最大值而不是累加 —— 一个近敌足以否决推进，但不会因为一串远敌把分数堆到天上。
    """
    enemies = [entity for entity in (tactical or {}).get("entities", []) or []
               if str(entity.get("kind", "")).startswith("unit_enemy")
               and not bool(entity.get("confirmed_dead"))]
    best = 0.0
    for enemy in enemies:
        position = _pos2d(enemy)
        if position is None:
            continue
        nearest = min((point_distance(position, point) for point in waypoints),
                      default=float("inf"))
        if nearest <= radius:
            best = max(best, 1.0 + (radius - nearest) / max(radius, 0.001))
    return round(best, 2)


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


#: 角色：主力（要中继点 + 侦察确认）与专职侦察（只要求边界/路径/无敌情）。
ROLE_MAIN = "main"
ROLE_SCOUT = "scout"


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
                     target=[float(target[0]), float(target[1])])
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
        plan.reason = REJECT_NO_PATH
        return plan
    reply = nav_query(unit, target) or {}
    if not reply.get("ok"):
        plan.reason = REJECT_NO_PATH
        plan.nav_revision = int(reply.get("nav_revision", -1) or -1)
        plan.urgent_event = "path_failed"
        return plan
    plan.nav_revision = int(reply.get("nav_revision", -1) or -1)
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
    # ④ 威胁评估：路径上出现敌人 → 停止推进并送 urgent（等重规划/集结）。
    plan.threat_score = threat_score(tactical, waypoints)
    if plan.threat_score >= THREAT_BLOCK_SCORE:
        plan.reason = REJECT_THREAT
        plan.urgent_event = "enemy_on_route"
        return plan
    # 撤退点 = 该单位**当前所在点**（打不动/受阻就回这里，不是继续往深处走）。
    here = _pos2d(by_name.get(str(unit), {}))
    plan.retreat_point = [here[0], here[1]] if here else list(waypoints[0])
    plan.ok = True
    return plan


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
    def hop_distance(plan: "RoutePlan") -> float:
        own = positions.get(str(plan.unit))
        if not own:
            return float("inf")
        return point_distance(own, plan.relay_point)
    chosen = min(usable, key=hop_distance)
    relay = [float(chosen.relay_point[0]), float(chosen.relay_point[1])]
    if hop_distance(chosen) == float("inf"):
        return relay, ""            # 位置未知时不判散开（宁可放行，也不因缺数据卡死整队）
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
    stats = state.setdefault("movement_stats", {})
    stats["arrivals"] = int(stats.get("arrivals", 0)) + 1


def previous_route(state: Dict[str, Any], unit: str) -> Dict[str, Any]:
    routes = state.get("routes") or {}
    if isinstance(routes, dict):
        entry = routes.get(str(unit))
        if isinstance(entry, dict):
            return entry
    return {}


def record_route(state: Dict[str, Any], plan: RoutePlan) -> None:
    """把路线记录进状态（计划 §7 要求逐字段留痕 + 供统计）。"""
    routes = state.setdefault("routes", {})
    routes[str(plan.unit)] = plan.to_dict()
    # 统计累加（验收要"无路径移动数 / 越界数 / 侦察先行覆盖率"）。
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
    if plan.scout_confirmation:
        stats["scout_confirmed"] = int(stats.get("scout_confirmed", 0)) + 1
    # 派生指标**必须写回 state**：`movement_stats()` 是算出来的视图，
    # 只在日志里调用它 → `state["movement_stats"]` 里永远没有
    # `unsafe_dispatches`/`scout_first_coverage`（实测集成局报告读到 None）。
    state["movement_stats"] = movement_stats(state)


def movement_stats(state: Dict[str, Any]) -> Dict[str, Any]:
    """验收口径：把"无路径主力移动数"这类硬指标算出来。

    `unsafe_dispatches` 必须恒为 0 —— 它统计的是"规则/行为树发出了移动意图，
    但那条意图**没有**对应的合法路线记录"。非 0 就意味着闸门被绕过。
    """
    stats = dict(state.get("movement_stats") or {})
    allowed = int(stats.get("allowed", 0) or 0)
    confirmed = int(stats.get("scout_confirmed", 0) or 0)
    stats["scout_first_coverage"] = round(confirmed / allowed, 3) if allowed else 0.0
    stats["unsafe_dispatches"] = int(stats.get("unsafe_dispatches", 0) or 0)
    return stats
