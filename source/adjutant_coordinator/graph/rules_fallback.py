# -*- coding: utf-8 -*-
"""确定性规则兜底：模型不可用时让部队继续工作（不抢模型的决策权）。

为什么需要（2026-09-10 实测）：本地模型链路是
「云 runner → Cloudflare 隧道 → 家宽 → 代理 → Ollama」，
任一环抖动都会让单轮卡满 LLM 超时（实测 elapsed_ms=120015），
期间**全部单位空转**，经济一动不动 —— 用户看到的正是"非常慢且瞎操作"。
提示词要求："模型两次回答之间，部队必须继续工作。"

设计边界（刻意保守）：
- 兜底只做**事实可判定**的事：谁空闲、谁能采集、资源点在哪、基地能不能造工人；
- **不做**目标推理 —— 守哪、打谁、往哪侦察仍归模型；
- 因此兜底产出永远是三件事：工人采集、基地补工人、其余待命。
这样即使模型彻底不可用，部队也在推进经济，而不是站着不动。
"""
from typing import Any, Dict, List, Optional, Tuple

from .contracts import (
    ACTION_ATTACK, ACTION_ATTACK_MOVE, ACTION_BUILD, ACTION_DEFEND, ACTION_GATHER,
    ACTION_HOLD, ACTION_MOVE, ACTION_PRODUCE, ACTION_REGROUP, ACTION_RETREAT,
    ACTION_SCOUT,
)
import math

from .model_context import rules_scene_index
from . import campaign as campaign_mod
from . import placement

#: 兜底最多派几个工人去采集（避免一次灌太多意图）。
#: 【2026-09-12 晚改 4 → 8】工人目标提到 6/基地（见 `WORKERS_PER_BASE`）后，
#: 4 条/tick 的采集配额会让第 5 个以后的工人**长期没有采集意图**（"有钱不采"）。
MAX_GATHER_INTENTS = 8
#: 地板建造落点的半径环（米）：与 `placement.VISION_SAFE_RADIUS_M` 同口径（视野内）。
#: 依据：`NotVisible` 是建造被拒的头号原因，视野半径是 5m 量级
#: （"基地+5m"能建成兵营，8/12/16m 全被拒）；"别堵住部队"由净空排序解决。
BUILD_PLACEMENT_RADII_FLOOR: Tuple[float, ...] = (4.0, 6.0, 8.0)
#: 工人少于该数量时，基地尝试补工人。
WORKER_TARGET = 4
#: 每座"会造工人的建筑"（指挥中心）的目标工人数。
#: **必须与传统 AI 同值**（`SimpleClairvoyantAI.workers_per_command_center = 6`）：
#: 铁律是"副官永不弱于传统 AI"，而这里曾经写 4 —— 开局 5 万时我们比传统 AI
#: 少 1/3 的采集工，属于**规则档位本身**就落后。
#: 实际目标 = max(WORKER_TARGET, 基地数 × 本值)。
WORKERS_PER_BASE = 6
#: "富局"门槛（A 资源）：余额高于此值时**不做穷局节流**（见 `_rich_bank`）。
#: 依据：开局 5 万 = 250 个工人 / 100 辆坦克 / 83 座兵营的购买力，
#: 此时瓶颈是"转化速度"（产能建筑 × 工人 × 并行工地），不是钱。
RICH_BANK_A = 10000
#: 同一产品"队列 + 在途"的上限（计划 §三：AI 不得占满生产队列，玩家订单优先）。
WORKER_QUEUE_CAP = 2
# 【唯一事实来源】"仍算在途占用"的意图状态**直接引用** `graph.state`，不再手抄一份。
# 手抄那一份曾经漏掉 `active_unknown` / `retry_wait`，于是"存活状态"在本模块里
# 与仲裁/微操层口径不一致（同一句判据在不同文件里答案不同）。
from .state import INTENT_LIVE_STATES as LIVE_INTENT_STATES  # noqa: E402

# ---------------- 发展阶梯（决策手册 BLD-01） ----------------
#: 有作战单位达到该数量且存在可见敌人时，阶梯给出 attack 候选。
#: 【待实测】参考值，不是平衡事实；由配置覆盖，禁止在别处硬编码。
ARMY_ATTACK_THRESHOLD = 2
#: 视为"作战单位"的单位类型（drone 无武器，不计入）。
COMBAT_TYPES = ("soldier", "tank", "helicopter")
#: 发展阶梯的建造顺序（逐级推进；每级达到 `BUILD_LIMITS` 的座数就往下走）。
#: 【2026-09-12 晚扩线，用户反馈"不会发展、不会多造建筑、防御、分子基地"】
#: 顺序 = 产能（兵营→车厂→机场）→ 防御（防空→反地）→ 分基地（第二座指挥中心）。
#: 不在规则视图里的类型会被 `scene_index` 过滤掉（`continue`），所以这份表可以
#: 写得比实际可建项更全 —— 拿不到就不建，不会发出非法命令。
BUILD_LADDER = ("barracks", "vehicle_factory", "aircraft_factory",
                "anti_air_turret", "anti_ground_turret", "command_center")
#: 每类建造物的**座数上限**（没有条目 = 1 座）。
#: 为什么需要"多座"：旧实现是"有一座就跳过"，于是兵营+车厂之后发展线彻底停摆
#: （实测余额 46800 花不出去、既没有防御也没有第二个基地）。
BUILD_LIMITS = {
    # 【2026-09-12 晚：按开局购买力对齐传统 AI】
    # 原表（各 1 座 + 2 基地）= 整局规划只值 **6,800 A**，即开局 5 万的 **13.6%** ——
    # 实测 5 分钟只花掉 9,550（19%），40,450 一直闲置。钱花不出去**不是执行问题，
    # 是这张上限表本身的设计**：它按"穷局"标定。
    # 传统 AI 的口径是 `max_command_centers = 3` + 3 个编组 × 6 人 = 18 个战斗单位，
    # 也就是"至少 3 座基地、多条产线"。铁律"副官永不弱于传统 AI"要求我们不少于它。
    "barracks": 2,
    "vehicle_factory": 2,
    "aircraft_factory": 1,
    # 防御：一防一空各一座 + 分矿各一座（两处基地都要覆盖）。
    "anti_air_turret": 2,
    "anti_ground_turret": 2,
    # 基地上限对齐传统 AI `max_command_centers = 3`。
    "command_center": 3,
}
#: 各建造物对应的"由谁生产什么"（产品 id → 生产建筑类型）。
#: 【2026-09-12 晚扩线】补上机场产品（`helicopter`）—— 否则新建的机场**永远闲着**，
#: 又变成"有建筑不用"（用户反馈"不会发展"）。只加作战单位，不加 `drone`：
#: 无人机无武器、侦察已由"前压探索 + 专职侦察"覆盖，避免无人机制造堆积。
PRODUCT_LADDER = (("soldier", "barracks"), ("tank", "vehicle_factory"),
                  ("helicopter", "aircraft_factory"))
#: 整批里出现这些动作，才算"这批已经在发展"，否则补阶梯。
DEVELOPMENT_ACTIONS = (ACTION_BUILD, ACTION_PRODUCE, ACTION_ATTACK)
#: **可被发展动作抢占**的低优先动作：这些动作占用的单位不算"忙"。
#: 按**优先级语义**定义（低优先即让位），不要按某个具体动作名硬编码 ——
#: 实测两次踩同一个坑：只认 gather 时，模型一发 scout/move 就让建造阶梯再次饿死
#: （整局只有 gather/scout、没有兵营）。
PREEMPTIBLE_ACTIONS = (ACTION_GATHER, ACTION_SCOUT, ACTION_MOVE, ACTION_HOLD)

#: 跨产者的**抢占序**（数字越大越优先）。模型意图与阶梯/行为树意图会落到同一个
#: 单位上，必须有**确定性**的胜负规则，否则要么两套决策打架、要么一方被静默饿死
#: （实测"有兵无营"就是后者：阶梯的 build 每轮都被模型那条 gather 顶掉）。
#:
#: **不要用各自的 `priority` 字段直接比**：两套产者量纲不同
#: （阶梯是 2~4，行为树是 30~95），比数字会得出错误结论。
#: 语义顺序：求生 > 交战 > 发展 > 防御/本职采集 > 机动 > 待命。
ACTION_PREEMPT_RANK = {
    ACTION_RETREAT: 90,
    ACTION_ATTACK: 70,
    ACTION_ATTACK_MOVE: 70,
    ACTION_BUILD: 60,
    ACTION_PRODUCE: 60,
    ACTION_DEFEND: 55,
    ACTION_GATHER: 40,
    ACTION_REGROUP: 30,
    ACTION_SCOUT: 20,
    ACTION_MOVE: 20,
    ACTION_HOLD: 10,
}


def action_rank(action: Any) -> int:
    """动作的抢占序。**未知动作取 100（最高）**：只抢占我们明确认定为低优先的动作，
    拿不准就不抢 —— 保守失败比无依据地打断既有任务安全。
    """
    return int(ACTION_PREEMPT_RANK.get(str(action), 100))
#: 建造落点相对**主基地**的偏移（米）。游戏侧 `_op_build` 必须拿到 position，
#: 缺省 (0,0) 会被拒（NotVisible/OutOfBounds/SurfaceNotBuildable）。
#: 取 5m：贴近基地 → 完全可见、可导航的概率最高。【待实测】偏移量与轮换策略。
BUILD_PLACEMENT_OFFSET_M = 5.0
#: 换方位的时间粒度（tick，60Hz → 600≈10 秒）。
BUILD_PLACEMENT_ROTATE_TICKS = 600
#: "在工地上的工人"判定半径（米）。这个范围内的工人**不许被抢去采集**：
#: 施工是指派制，工人被调走工地就永远建不完（实测车厂挂十几分钟、38 次生产被拒）。
SITE_KEEP_RADIUS_M = 10.0
#: 同一个资源点最多派几个工人（**分配层**的保守常量）。
#: 【2026-09-12 结构性整改】常量与分配算法都已收敛到**唯一实现** `resource_allocation`：
#: 原先 `rules_fallback` 与本文件、`task_patch`、`behavior_tree` 各有一份实现/各写一次常量，
#: 于是"4 个工人挤 1 个矿、旁边 3 个矿没人用"（用户实测）在一条路径上修好了、另一条还是坏的。
#: 这里只做**后向兼容的再导出**：旧调用点 `rf.RESOURCE_WORKERS_PER_NODE` /
#: `rf.assign_resources(...)` 继续可用，但实现只有一处。
from . import resource_allocation as _resource_allocation  # noqa: E402
from .resource_allocation import RESOURCE_WORKERS_PER_NODE as RESOURCE_WORKERS_PER_NODE  # noqa: E402


def assign_resources(by_name: Dict[str, Dict[str, Any]],
                     resources: List[Dict[str, Any]],
                     unit_names: Optional[List[str]] = None,
                     per_node: int = RESOURCE_WORKERS_PER_NODE,
                     *,
                     intents: Optional[List[Dict[str, Any]]] = None,
                     **kwargs: Any) -> Dict[str, str]:
    """（保留旧名）给采集单位分配矿点 → 唯一实现在 `resource_allocation.assign`。

    **调用方只需要传 `intents=`（在途意图）**，占用账（"谁已经在采哪个矿"）会自动补上：
    这是刻意的 —— 让"正确用法"成为默认用法。不传就会出现
    "已经在采的人不在负载里 → 新工人被重复派到同一个矿"（2026-09-12 用户实测：
    4 个工人 3 个挤一个矿、部队被堵、5 米外的矿没人用，而且不会自己散开）。
    """
    if intents is not None and "existing_load" not in kwargs:
        load, type_load, holders = _resource_allocation.occupancy(by_name, resources, intents)
        kwargs.setdefault("existing_load", load)
        kwargs.setdefault("existing_type_load", type_load)
        kwargs.setdefault("skip", set(holders))
    return _resource_allocation.assign(by_name, resources, unit_names, per_node, **kwargs)


def _dist_point_segment(p, a, b) -> float:
    """点 p 到线段 ab 的距离（判断落点是否压在"基地→矿点"的采矿通道上）。"""
    ax, az = a
    bx, bz = b
    px, pz = p
    dx, dz = bx - ax, bz - az
    if dx == 0 and dz == 0:
        return ((px - ax) ** 2 + (pz - az) ** 2) ** 0.5
    t = ((px - ax) * dx + (pz - az) * dz) / (dx * dx + dz * dz)
    t = max(0.0, min(1.0, t))
    cx, cz = ax + t * dx, az + t * dz
    return ((px - cx) ** 2 + (pz - cz) ** 2) ** 0.5


def _nearest_resource_pos(by_name, resources):
    """采矿通道终点：最近资源点的 (x,z)；无资源返回 None。"""
    anchor = None
    for info in by_name.values():
        if info.get("queue") or info.get("gather"):
            anchor = _pos2d(info)
            break
    if anchor is None:
        return None
    best = None
    for res in resources or []:
        if not isinstance(res, dict):
            continue
        rp = _pos2d(res)
        d = (rp[0] - anchor[0]) ** 2 + (rp[1] - anchor[1]) ** 2
        if best is None or d < best[0]:
            best = (d, rp)
    return best[1] if best else None


# 【几何口径**只有一份**】越界/视野/净空/坏点的判定全部委派给 `placement`
# （唯一事实来源）。这里保留同名薄壳只是为了兼容既有调用与测试 ——
# 本文件不再自行实现第二份几何逻辑（那正是 2026-09-12 同类问题换皮复发的根因）。
BUILD_BOUND_MARGIN_M = placement.BUILD_BOUND_MARGIN_M


def in_map_bounds(spot, bounds, margin: float = BUILD_BOUND_MARGIN_M) -> bool:
    """点是否落在地图内（委派 `placement.in_bounds`）。"""
    return placement.in_bounds(spot, bounds, margin)


def _clamp_into_bounds(spot, bounds, margin: float = BUILD_BOUND_MARGIN_M) -> list:
    """把点夹进地图内（委派 `placement.clamp_into_bounds`）。"""
    return placement.clamp_into_bounds(spot, bounds, margin)


#: 分基地落点距矿点的外推距离（米）：贴着矿点但略微避开采集往返通道。
#: **必须留在视野内**：原值 12m 是结构性错误 —— 矿点旁采矿的工人视野只有 5m 量级，
#: 12m 外的点必然 `NotVisible`（探针实测 172 条 build 被拒的主因之一）。
#: 收到 6m（落在工人视野内），"远离主基地"由 `EXPANSION_MIN_DISTANCE_M` 保证。
EXPANSION_RESOURCE_OFFSET_M = 6.0
#: 分基地落点距主基地的最小距离（米）：比这更近的矿点不算"分基地"，只是主基地圈内。
EXPANSION_MIN_DISTANCE_M = 30.0


def pick_expansion_spot(by_name, resources, anchor, blocked=None, bounds=None) -> list:
    """分基地选址：**离主基地较远的可见矿点附近**（而不是主基地旁边再盖一座）。

    为什么不能复用 `pick_build_spot`（4/6/8m 环绕主基地）：
    - 分基地的意义是圈地/靠近新矿；贴着主基地盖第二座基地毫无收益
      （用户 2026-09-12 晚明确要"分子基地"）；
    - 但落点**必须在己方视野内**（实测建造被拒的唯一原因就是 `NotVisible`），
      而**矿点附近一定在视野里**（有工人在那儿采矿）→ "挨着远端矿点"既安全又有收益；
    - 拿不到符合条件的矿点就返回 `[]`（宁可不建，也不在主基地旁边堆一座假分基地）。
    """
    if anchor is None:
        return []
    blocked = blocked if blocked is not None else []
    units = [_pos2d(info) for info in by_name.values() if info.get("pos")]
    best, best_distance = None, 0.0
    for resource in resources or []:
        if not isinstance(resource, dict):
            continue
        pos = _pos2d(resource)
        distance = math.hypot(pos[0] - anchor[0], pos[1] - anchor[1])
        if distance < EXPANSION_MIN_DISTANCE_M:
            continue
        # 从矿点朝"离开主基地"的方向再外推一点，避免压在采集往返通道上。
        dx, dz = pos[0] - anchor[0], pos[1] - anchor[1]
        norm = math.hypot(dx, dz) or 1.0
        spot = (pos[0] + dx / norm * EXPANSION_RESOURCE_OFFSET_M,
                pos[1] + dz / norm * EXPANSION_RESOURCE_OFFSET_M)
        # 可行性走**同一套判据**（界内 + 视野内 + 有净空 + 未被拉黑）。
        # 这里"视野内"天然等于"有己方单位在附近"——远端矿点有工人采矿才算数，
        # 于是"看不见的远方基地"根本不会被产出（那正是 172 条 NotVisible 的来源）。
        if placement.spot_issue(spot, bounds, units, blocked) is not None:
            continue
        if best is None or distance > best_distance:   # 越远越优先：真正的新地盘
            best, best_distance = spot, distance
    if best is None:
        return []
    return [round(best[0], 1), round(best[1], 1)]


def pick_build_spot(by_name, resources, anchor, blocked=None, bounds=None) -> list:
    """选建造落点：**离己方单位与采矿通道最远**，且在地图内、视野内、有净空。

    实测依据（2026-09-12 用户反馈："兵营造的位置会卡住工人采矿"）：
    旧落点是"基地 + 5m、按 tick 轮换方位"，实测 barracks(10,12) 正好压在
    工人 (8~10, 13~14.6) 的采矿通道上，把工人堵在 1.5m 口袋里。
    改为多方位候选 + 三重打分：离己方实体足够远 / 离采矿通道与资源点越远越好 / 半径近优先。

    **几何可行性不再由本函数判断**：候选生成与"界内/视野内/净空/坏点"筛选
    全部委派 `placement.candidate_spots`（唯一事实来源）—— 越界（`OutOfBounds`）
    与视野外（`NotVisible`）这两类**必然被拒**的点在下发前就已被剔除，
    本函数只负责在可行点里按"离采矿通道最远"排序（业务目标）。
    """
    units = [_pos2d(info) for info in by_name.values() if info.get("pos")]
    resource = _nearest_resource_pos(by_name, resources)
    spots = placement.candidate_spots(anchor[0], anchor[1], bounds=bounds,
                                      own_points=units, rejected=blocked,
                                      radii=BUILD_PLACEMENT_RADII_FLOOR)
    if spots:
        best, best_score = None, None
        for spot in spots:
            if resource is not None:
                clear = min(_dist_point_segment(spot, anchor, resource),
                            ((spot[0] - resource[0]) ** 2
                             + (spot[1] - resource[1]) ** 2) ** 0.5)
            else:
                clear = 999.0
            # 净空（相对采矿通道）优先；同分时取**列表中更靠前**的点
            # （`candidate_spots` 已按 净空→近半径→槽位序 排好，确定性）。
            if best_score is None or clear > best_score:
                best, best_score = spot, clear
        return [round(best[0], 1), round(best[1], 1)]
    # 兜底：环上候选全被淘汰（贴边基地 / 点都被拉黑）→ **朝地图中心**逐级后退。
    retreat = placement.retreat_spot(anchor[0], anchor[1], bounds=bounds,
                                     own_points=units, rejected=blocked)
    if retreat is not None:
        return retreat
    return placement.clamp_into_bounds(anchor, bounds)


def base_anchor_pos(by_name: Dict[str, Dict[str, Any]]):
    """**严格**的基地锚点：只认"我方不动的建筑"（command_center 优先，其次带生产队列的建筑）。

    为什么不直接用 `_base_anchor_pos`（后者有"任意非采集单位"的兜底）：
    那条兜底会在**没有基地**时把会动的单位（步兵/坦克/无人机）当成基地，
    于是"以基地为圆心/终点"的行为全部失真：
      - 侦察航点变成**绕着自己转**：每换一个槽位就朝外漂 10m，等价于无依据游走；
      - 集结/撤离的"基地"跟着部队跑，失去意义。
    所以凡"必须以基地为圆心/终点"的地方都用严格版；拿不到就返回 None，
    由调用方决定"不动"（宁可不发，也不凭空猜坐标）。
    """
    for info in by_name.values():
        if "command_center" in str(info.get("type", "")):
            return _pos2d(info)
    for info in by_name.values():
        if info.get("queue"):
            return _pos2d(info)
    return None


def _base_anchor_pos(by_name: Dict[str, Dict[str, Any]]):
    """找"主基地"位置：优先 command_center，其次任意非采集单位（建筑）。"""
    for name, info in by_name.items():
        if "command_center" in str(info.get("type", "")):
            return _pos2d(info)
    for info in by_name.values():
        if info.get("type") and not info.get("gather"):
            return _pos2d(info)
    return None


# ── 观测解析原语已收敛到 `observation_view`（全仓库唯一实现）────────────────
# 2026-09-12 结构性整改：实体判定 / id 取值 / 坐标降维原先定义在这个模块里，
# 行为树、任务补丁、资源分配各自再抄一份 —— 抄歪一次就是"某功能静默失效"。
# 现在只保留**一个**定义处（`observation_view`），这里只做后向兼容的再导出，
# 旧调用点（`rf._pos2d` / `rf.entity_id_of` / …）继续可用，不需要同时改一圈调用方。
from .observation_view import (  # noqa: E402  （语义上是模块级导入，放这里只为紧贴原定义位置）
    entities as _entities,
    own_units as _own_units,
    resources as _resources,
    entity_id_of as entity_id_of,
    normalized_units as normalized_units,
    pos2d as _pos2d,
)


def busy_units(state: Dict[str, Any]) -> set:
    """已被活跃/在途意图占用的单位：兜底绝不抢这些单位。

    口径 = `graph.state.INTENT_LIVE_STATES`（唯一事实来源），不再手写状态名。
    """
    busy = set()
    for intent in state.get("active_intents") or []:
        if intent.get("state") in LIVE_INTENT_STATES:
            for unit in intent.get("unit_ids") or []:
                busy.add(str(unit))
    for request in (state.get("pending_requests") or {}):
        busy.add(str(request))
    return busy


def _nearest_resource(unit: Dict[str, Any],
                      resources: List[Dict[str, Any]],
                      *, load: Optional[Dict[str, int]] = None,
                      cap: int = 0) -> Optional[Dict[str, Any]]:
    """最近资源点；带**分配去冲突**：已经站了 cap 个工人的矿点不再分给新工人。

    实测依据（2026-09-12 用户反馈截图）：3 个工人全被派到**同一个**矿点，
    互相挤在一起、部队也被堵住，而余额 5 万却有人闲置。
    根因：所有路径都是"各自取最近的矿点"，**没有任何分配层**负责"谁去哪个矿、
    一个矿最多几个人"。这里给兜底/阶梯路径补上最基础的一版：优先未占用的矿点，
    同矿最多 `RESOURCE_WORKERS_PER_NODE` 人（资源点本身没有容量字段，
    用"每个矿点不超过 2 个工人"这个保守常量代替，避免 3~4 个人挤同一个点）。
    """
    if not resources:
        return None
    load = load if load is not None else {}
    origin = _pos2d(unit)
    best = None
    best_distance = None
    for resource in resources:
        entity = entity_id_of(resource)
        if cap and int(load.get(str(entity), 0)) >= cap:
            continue
        target = _pos2d(resource)
        distance = (target[0] - origin[0]) ** 2 + (target[1] - origin[1]) ** 2
        if best_distance is None or distance < best_distance:
            best, best_distance = resource, distance
    if best is None:
        # 所有矿点都满了：退回"最近的"（宁可挤，也不要让工人闲置）。
        return _nearest_resource(unit, resources)
    return best


def _worker_product(rules, owned_types: set) -> Optional[Tuple[str, str]]:
    """找"可被现有单位生产的工人产品"，返回 (producer 类型要求, 产品 id)。

    只认名字里含 worker 的产品，并且其 allowed_producer_type_ids 与现有单位类型相交；
    找不到就返回 None（宁可不造，也不造错东西）。
    """
    if not isinstance(rules, dict):
        return None
    for relation in rules.get("productions") or []:
        if not isinstance(relation, dict):
            continue
        product = str(relation.get("product_type_id", "") or "")
        if "worker" not in product.lower():
            continue
        allowed = {str(t) for t in (relation.get("allowed_producer_type_ids") or [])}
        matched = allowed & owned_types
        if matched:
            return (sorted(matched)[0], product)
    return None


#: 优先执行"扩张前探"的单位类型（专职侦察；没有它们才退到其它机动单位）。
PROBE_TYPES = ("drone", "scout")
#: 视为"产能建筑"的类型：只有它们存在时，"先补兵"才有意义（没有产能时先建造）。
PRODUCTION_BUILDINGS = ("barracks", "vehicle_factory", "aircraft_factory")


def _pick_probe_unit(by_name: Dict[str, Dict[str, Any]], ai_units: List[str],
                     busy: set) -> str:
    """挑一个空闲的**机动**单位去做扩张前探（拿不到就返回空串，宁可不发）。

    排除采集单位（前探不该抽走经济线）、设施（queue）与**所有静态建筑**。
    【必须查 `movement`】不查的话会挑到炮塔/机场这类不动的建筑，
    权威端只能 `Rejected`（实测 6 条 `rule-probe-expansion` 全被拒 →
    扩张选址被误判成"命令一直失败"而阻塞，同时那条坏命令还会把意图前缀拉黑）。
    """
    def usable(name: str) -> bool:
        info = by_name.get(name) or {}
        if name in busy:
            return False
        if info.get("gather") or info.get("queue"):
            return False
        return bool(info.get("movement"))

    for wanted in PROBE_TYPES:
        for name in ai_units:
            if usable(name) and str((by_name.get(name) or {}).get("type", "")) == wanted:
                return name
    for name in ai_units:
        if usable(name):
            return name
    return ""


def batch_from_rules(state: Dict[str, Any], *, tactical=None, rules=None,
                     ttl_ticks: int = 3600, server_tick: int = 0,
                     snapshot_id: int = 0) -> Dict[str, Any]:
    """产出保守的兜底意图批次；形状与模型输出一致，后续走同一套校验与仲裁。"""
    owned = _own_units(tactical)
    # 观测里的类型字段是 unit_type（不是 type）。**统一走唯一实现**（`observation_view`）：
    # 这里曾经手写第三份解析，少了 `constructed` 三态（就是"38 次 ProducerNotConstructed"
    # 的成因），后来又在同类问题上少了 `movement`。字段口径只允许有一处定义。
    by_name = _normalized_units(tactical)
    ai_units = [str(u) for u in (state.get("ai_controlled_units") or [])]
    busy = busy_units(state)
    tick = int(server_tick or state.get("server_tick", 0) or 0)
    snapshot = int(snapshot_id or state.get("latest_snapshot_id", 0) or 0)
    expires = tick + max(1, int(ttl_ticks or 3600))

    intents: List[Dict[str, Any]] = []

    # 【采集与补工人**都只有一处实现**】本函数曾经自己造 `rule-gather-*` 与
    # `rule-produce-worker-*`，而 `development_intents()` 的并行填充（经济轨/生产轨）
    # 现在也会产出同一条 —— 同批次里出现两份 → 契约层直接判"intent_id 重复"并整批打回
    # （实测：`intent_batch: intents.intent_id 重复：rule-gather-Unit_2`）。
    # 动作现在**全部**由下面那一处产出（含"工地上的工人不许被抽走"、占用账、
    # 目标工人数、队列/在途去重），这里不再自建任何采集/生产意图。

    # 发展阶梯（BLD-01）：兜底**必须**包含发展动作，否则"工人全去采集"就成了死循环。
    # 放在采集/补工人之后：两者不冲突（阶梯会挑一个可被抢占的采集者）。
    intents.extend(development_intents(
        state, tactical=tactical, rules=rules, ttl_ticks=ttl_ticks,
        server_tick=tick, snapshot_id=snapshot))

    # 没有任何可判定动作时**不生成** hold：hold 对游戏侧等价于"原地不动"，
    # 本来就不需要下发；下发反而会因为模型耗时把 expires_tick 拖过期
    # （实测 `rule-hold-Unit_1` 报 "expires_tick: 命令已过期（当前 tick 120152）"），
    # 只增加拒绝噪音、干扰"失败率"统计。

    return {
        "match_id": "", "player_id": "", "plan_version": "",
        "based_on_snapshot": snapshot, "intents": intents,
    }


def _normalized_units(tactical) -> Dict[str, Dict[str, Any]]:
    """观测单位视图（**委派** `observation_view.normalized_units`，全仓唯一实现）。

    【为什么这里是薄壳而不是再写一份】本函数曾经是一份**独立副本**：
    `constructed` 三态与后来的 `movement` 字段都只加在 `observation_view` 那一份上，
    于是"同一份观测、两条路径看到不同字段"。2026-09-12 真机就因此出事：
    前探挑选单位时读不到 `movement` → 挑中炮塔这类**不会动的建筑** → `move` 被权威端
    `Rejected`（6 条）→ 扩张选址被误判成"命令连续失败"而阻塞。
    纪律：几何/观测的解析只允许 `observation_view` 一处实现，别处只能转调。
    """
    return normalized_units(tactical)


def _living_enemies(tactical) -> List[Dict[str, Any]]:
    return [e for e in _entities(tactical)
            if str(e.get("kind", "")).startswith("unit_enemy")
            and not bool(e.get("confirmed_dead"))]


def bank_a(tactical) -> int:
    """本玩家 A 资源余额（观测口径 `tactical.balance`，与 `op=tactical` 同源）。

    取不到就返回 0（按"穷局"处理）—— **宁可保守也不猜**：把未知余额当成富局会让
    规则在真没钱时乱铺工地（那正是 172 条 `NotVisible` + 采集线停摆的成因）。
    """
    raw = (tactical or {}).get("balance") if isinstance(tactical, dict) else None
    if not isinstance(raw, dict):
        return 0
    for key, value in raw.items():
        if str(key).lower() == "a":
            try:
                return int(value)
            except (TypeError, ValueError):
                return 0
    return 0


def _worker_queue_cap(bank: int, target: int, deployed: int) -> int:
    """工人"队列 + 在途"上限。

    穷局 = `WORKER_QUEUE_CAP`（计划 §三铁律：AI 不得占满生产队列，玩家订单优先）。
    富局 = **缺几个就排几个** —— 钱不缺时让指挥中心空着是纯浪费（实测余额 4 万+、
    指挥中心闲置、整局只出 3 个工人）。

    注意：富局放宽的是**数量**，不是"绕过玩家预留"（预留由 `reserves` 独立把关）。
    """
    if int(bank) >= RICH_BANK_A:
        return max(WORKER_QUEUE_CAP, int(target) - int(deployed))
    return WORKER_QUEUE_CAP


def ladder_inputs(state: Dict[str, Any], *, tactical=None, rules=None) -> Dict[str, Any]:
    """发展阶梯的**输入快照**（决策与诊断共用同一份口径）。

    为什么要单独暴露（交接教训）：离线调用 `development_intents` 能正常产出
    `barracks` build，但运行时一局 90s **一条 build 都到不了游戏**。说明断点在
    "喂给阶梯的 state"，不在算法。只有把输入打点出来，才能判定是
    (a) 压根没生成 还是 (b) 生成后被仲裁丢弃/过期 —— 否则只能反复试探
    （交接前已经因此绕了三圈）。

    返回值刻意**只含 JSON 安全的标量与字符串列表**：`GraphServices.log` 会吞掉
    序列化异常，塞进 set 就会让整行日志静默消失（与上面同一类失败模式）。
    """
    by_name = _normalized_units(tactical)
    ai_units = [str(u) for u in (state.get("ai_controlled_units") or [])]
    busy = busy_units(state)
    preemptible = set()
    live_intents: List[str] = []
    for intent in state.get("active_intents") or []:
        if not isinstance(intent, dict):
            continue
        if intent.get("state") not in ("active", "pending_authority"):
            continue
        action = str(intent.get("action", ""))
        units = [str(u) for u in (intent.get("unit_ids") or [])]
        # 留痕形状："动作:状态:单位" —— 用于确认"阶梯的候选池单位是否真被占着"。
        live_intents.append("%s:%s:%s" % (action, intent.get("state"), ",".join(units)))
        if action in PREEMPTIBLE_ACTIONS:
            preemptible.update(units)

    idle_builders = [n for n in ai_units
                     if n not in busy and bool(by_name.get(n, {}).get("construct"))]
    idle_producers = [n for n in ai_units
                      if n not in busy and bool(by_name.get(n, {}).get("queue"))]
    # 逐角色抢占（不能要求两个角色同时为空，见 development_intents 的长注释）。
    if not idle_builders and preemptible:
        idle_builders = [n for n in ai_units
                         if n in preemptible
                         and bool(by_name.get(n, {}).get("construct"))]
    if not idle_producers and preemptible:
        idle_producers = [n for n in ai_units
                          if n in preemptible
                          and bool(by_name.get(n, {}).get("queue"))]

    own_types = {info["type"] for info in by_name.values() if info["type"]}
    built_types = {info["type"] for info in by_name.values()
                   if info["type"] and not info["gather"]}
    # 未完工的工地：**只有显式 constructed=False** 才算（None=未知，不当未完工，
    # 否则会把"观测没给该字段"误判成工地，导致反复派工去"施工"）。
    unfinished = [name for name, info in by_name.items()
                  if info["type"] and not info["gather"]
                  and info.get("constructed") is False]
    # 可用于生产的设施：constructed 不是 False（None=未知仍放行，交由权威端裁决）。
    constructed_producers = [name for name, info in by_name.items()
                             if info.get("queue") and info.get("constructed") is not False]
    return {
        "observed_units": sorted(by_name.keys()),
        "ai_units": ai_units,
        "busy": sorted(busy),
        "preemptible": sorted(preemptible),
        "idle_builders": idle_builders,
        "idle_producers": idle_producers,
        "own_types": sorted(own_types),
        "built_types": sorted(built_types),
        "unfinished_buildings": unfinished,
        "constructed_producers": constructed_producers,
        "live_intents": live_intents,
        # 地图边界进诊断：落点越界曾经是"发展停摆"的头号原因（160/169 条 OutOfBounds），
        # 没有这一项就只能对着 `build_spot_blocked` 的坐标反推地图有多大。
        "map_bounds": list(state.get("map_bounds") or []),
    }


# ------------------------------------------------------- 前压方向（唯一判据）
#: 作战单位"前压"的半径硬上限（米）。**不许把部队送到地图边缘**。
ADVANCE_SAFE_RADIUS_M = 40.0
#: 前压的最小半径（米）：基地已经贴着地图内侧时要仍然往外站一点。
ADVANCE_MIN_RADIUS_M = 15.0
#: 有敌情时的逼近系数：前压距离 ≤ 最近已知敌人距离 × 本值（推进到能打，但不扎进敌群）。
ADVANCE_ENEMY_STANDOFF = 0.5
#: 航点距地图边缘的最小余量（米）。
ADVANCE_EDGE_MARGIN_M = 10.0
#: 无情报时的前压半径系数：不超过"基地到最近地图边"的一半。
ADVANCE_EDGE_FACTOR = 0.5


def military_waypoint(base, *, bounds=None, enemies=(), ring: int = 1,
                      bearing=None, max_radius=None) -> Optional[List[float]]:
    """作战单位"往哪前压"的**唯一方向判据**（行为树与并行填充共用）。

    ## 用户实测问题（2026-09-12）
    部队按罗盘方位一圈圈往外走（步长 25m、上限 120m）—— 实际效果就是**把兵送到地图边缘**；
    实战途中遇敌被逐个击破（"这样很危险，中途都会遇到敌人的"）。

    ## 三条硬约束（取代"罗盘均匀撒"）
    1. **方向有依据**：有已知敌情 → 朝**最近敌人**方向；没有敌情 → 朝**地图中心**
       （那里通常才是交战区/要道；地图边缘是死角，占了也没价值）。
    2. **不越过交战线**：有敌情时半径 ≤ 最近敌人距离 × `ADVANCE_ENEMY_STANDOFF`。
    3. **不离地图内侧**：半径 ≤ `ADVANCE_SAFE_RADIUS_M`，且不超过"基地到最近地图边"
       的一半；落点再按 `ADVANCE_EDGE_MARGIN_M` 内缩。

    返回 `[x, z]`；**没有任何依据时返回 None**（宁可不发，也不乱派一路兵出去）。
    """
    if not base or len(base) < 2:
        return None
    try:
        base_x, base_z = float(base[0]), float(base[1])
    except (TypeError, ValueError):
        return None
    has_bounds = isinstance(bounds, (list, tuple)) and len(bounds) >= 2 \
        and float(bounds[0]) > 0 and float(bounds[1]) > 0
    size_x, size_z = (float(bounds[0]), float(bounds[1])) if has_bounds else (0.0, 0.0)
    # 硬上限：配置给的上限与安全上限取小（安全上限永远是赢家，配置只能更保守）。
    hard_radius = ADVANCE_SAFE_RADIUS_M
    try:
        if max_radius and float(max_radius) > 0:
            hard_radius = min(ADVANCE_SAFE_RADIUS_M, float(max_radius))
    except (TypeError, ValueError):
        hard_radius = ADVANCE_SAFE_RADIUS_M
    # ---- 1. 方向 ----
    nearest: Optional[Tuple[float, float, float]] = None
    for enemy in enemies or ():
        point = _pos2d(enemy)
        distance = math.hypot(float(point[0]) - base_x, float(point[1]) - base_z)
        if nearest is None or distance < nearest[0]:
            nearest = (distance, float(point[0]), float(point[1]))
    if nearest is not None and nearest[0] > 1e-3:
        direction = (nearest[1] - base_x, nearest[2] - base_z)
        radius_cap = min(hard_radius, nearest[0] * ADVANCE_ENEMY_STANDOFF)
    elif has_bounds:
        direction = (size_x / 2.0 - base_x, size_z / 2.0 - base_z)
        if math.hypot(*direction) < 1e-3:
            direction = tuple(bearing) if bearing else (1.0, 0.0)
        # 无情报时不越过"基地到最近地图边"的一半 —— 这一项直接禁止"派往地图边缘"。
        edge_distance = min(base_x, base_z, size_x - base_x, size_z - base_z)
        radius_cap = min(hard_radius,
                         max(ADVANCE_MIN_RADIUS_M, edge_distance * ADVANCE_EDGE_FACTOR))
    elif bearing:
        direction = (float(bearing[0]), float(bearing[1]))
        radius_cap = min(hard_radius,
                         max(ADVANCE_MIN_RADIUS_M, ADVANCE_MIN_RADIUS_M * max(1, int(ring))))
    else:
        return None
    length = math.hypot(direction[0], direction[1])
    if length < 1e-3:
        return None
    radius = min(hard_radius,
                 max(ADVANCE_MIN_RADIUS_M, ADVANCE_MIN_RADIUS_M * max(1, int(ring))),
                 radius_cap)
    point = [base_x + direction[0] / length * radius,
             base_z + direction[1] / length * radius]
    if has_bounds:
        point[0] = min(max(point[0], ADVANCE_EDGE_MARGIN_M), size_x - ADVANCE_EDGE_MARGIN_M)
        point[1] = min(max(point[1], ADVANCE_EDGE_MARGIN_M), size_z - ADVANCE_EDGE_MARGIN_M)
    return [round(point[0], 1), round(point[1], 1)]


# --------------------------------------------------------------- 意图构造（唯一）
def make_intent(intent_id, action, unit, target, priority, rationale, task_id,
                *, tick: int, snapshot: int, expires: int) -> Dict[str, Any]:
    """意图字面量的**唯一构造点**（阶梯与并行填充共用）。

    并行填充产出的意图必须与阶梯**同形状**（走同一套契约校验/仲裁/回执），
    形状在两处各写一遍必然分叉 —— 本项目已有多次先例，所以收敛成一个函数。
    """
    return {
        "intent_id": intent_id, "task_id": task_id, "unit_ids": [unit],
        "action": action, "target": target, "priority": priority,
        "based_on_snapshot": snapshot, "issued_tick": tick,
        "expires_tick": expires, "generation": 0, "rationale": rationale,
    }


# ---------------------------------------------------------------- 并行填充
#: 一次决策最多补多少条并行意图（其余下一轮继续）。
#: 与 `GraphConfig.max_batch` 同量级；决策 ~1.4 轮/秒 × 上限 8 ⇒ 上限约 11 条/秒，
#: 这是"每秒至少一次操作"在结构上得以成立的原因。
PARALLEL_FILL_CAP = 8


def _parallel_intents(state: Dict[str, Any], *, tactical=None, rules=None,
                      primary: Optional[List[Dict[str, Any]]] = None,
                      ttl_ticks: int = 3600, server_tick: int = 0,
                      snapshot_id: int = 0,
                      army_threshold: int = ARMY_ATTACK_THRESHOLD
                      ) -> List[Dict[str, Any]]:
    """**多轨并行填充**：让还没拿到任务的空闲单位各自执行当前该做的事。

    ## 为什么必须有这一步（2026-09-12 用户要求）
    用户原话："不能做到每秒至少一次操作，不能同时处理多线情况，现在远不及要求。"

    结构根因：发展阶梯是"逐级 `return` **一条**"的写法 ——
    实测决策 **1.4 轮/秒**，但每轮最多产出 **1 条**命令，而且**同一时刻只有一条线在动**
    （建造时不出兵、出兵时不采集）。一局 15 个单位的局面里，绝大多数单位整轮拿不到命令，
    实测只有 **0.3~0.45 条命令/秒**。

    本函数把"空闲单位"当作第一类公民，**四条轨各自独立产出、互不排斥**：
    经济（采集）/ 生产（每个空闲产能建筑各一条）/ 侦察（专职侦察）/ 军事（每个空闲作战单位）；
    合计不超过 `PARALLEL_FILL_CAP`，其余下一轮继续 —— 于是"每秒 ≥1 次操作"成为稳态。
    """
    out: List[Dict[str, Any]] = list(primary or [])
    by_name = _normalized_units(tactical)
    if not by_name:
        return out
    inputs = ladder_inputs(state, tactical=tactical, rules=rules)
    ai_units = list(inputs["ai_units"])
    busy = set(inputs["busy"])
    tick = int(server_tick or state.get("server_tick", 0) or 0)
    snapshot = int(snapshot_id or state.get("latest_snapshot_id", 0) or 0)
    expires = tick + max(1, int(ttl_ticks or 3600))
    used = {str(u) for intent in out for u in (intent.get("unit_ids") or [])}
    prefs = campaign_mod.frontier_preferences(state, tick=tick)
    suspended = {str(u) for u in (prefs.get("suspended_objects") or [])}

    def _add(intent_id, action, unit, target, priority, rationale, task_id) -> None:
        out.append(make_intent(intent_id, action, unit, target, priority, rationale,
                               task_id, tick=tick, snapshot=snapshot, expires=expires))
        used.add(str(unit))

    def _room() -> bool:
        return len(out) < PARALLEL_FILL_CAP

    def _free(name: str) -> bool:
        return name not in busy and name not in used and name not in suspended

    # ---- 轨 1：经济（还没上岗的采集单位 → 最近且人少的矿）----
    resources = _resources(tactical)
    if resources:
        # 工地上的工人不许被抽走（施工是指派制，人被调走工地永远建不完）。
        on_site: set = set()
        for info in by_name.values():
            if info.get("type") and info.get("constructed") is False:
                site_x, site_z = _pos2d(info)
                for name, unit in by_name.items():
                    if not unit.get("gather"):
                        continue
                    unit_x, unit_z = _pos2d(unit)
                    if (unit_x - site_x) ** 2 + (unit_z - site_z) ** 2 <= SITE_KEEP_RADIUS_M ** 2:
                        on_site.add(name)
        load, _type_load, _holders = _resource_allocation.occupancy(
            by_name, resources, state.get("active_intents") or [])
        for name in ai_units:
            if not _room():
                break
            info = by_name.get(name) or {}
            if not _free(name) or name in on_site or not info.get("gather"):
                continue
            resource = _nearest_resource(info, resources, load=load,
                                         cap=RESOURCE_WORKERS_PER_NODE)
            if resource is None:
                break
            entity = str(entity_id_of(resource))
            load[entity] = load.get(entity, 0) + 1
            _add("rule-fill-gather-%s-%d" % (name, tick), ACTION_GATHER, name,
                 {"entity_id": entity_id_of(resource),
                  "pos": [round(_pos2d(resource)[0], 1), round(_pos2d(resource)[1], 1)]},
                 4, "并行填充：经济轨（空闲工人采集）", "rule-gather")

    # ---- 轨 2：生产（每个还没在产的产能建筑各一条，而不是只发一条）----
    scene_index = rules_scene_index(rules)
    own_types = set(inputs["own_types"])
    # 工人目标（与阶梯 1.8 同口径）：填充补工人时不得越过它。
    worker_product = _worker_product(rules, own_types)
    worker_id = str((worker_product or ("", ""))[1])
    producer_type_id = str((worker_product or ("", ""))[0])
    deployed_workers = sum(1 for name in ai_units
                           if str(by_name.get(name, {}).get("type", "")) == worker_id)
    base_count = sum(1 for name in ai_units
                     if str(by_name.get(name, {}).get("type", "")) == producer_type_id)
    target_workers = max(WORKER_TARGET, base_count * WORKERS_PER_BASE)
    queued_workers = 0
    for entry in (tactical or {}).get("production") or []:
        if not isinstance(entry, dict):
            continue
        for item in entry.get("items") or []:
            if str((item or {}).get("product_type_id", "")) == worker_id:
                queued_workers += 1
    producing = {str(unit)
                 for intent in (state.get("active_intents") or [])
                 if str(intent.get("action", "")) == ACTION_PRODUCE
                 and str(intent.get("state", "")) in LIVE_INTENT_STATES
                 for unit in (intent.get("unit_ids") or [])}
    counts: Dict[str, int] = {}
    for info in by_name.values():
        key = str(info.get("type", ""))
        if key:
            counts[key] = counts.get(key, 0) + 1
    for name in sorted(inputs["constructed_producers"]):
        if not _room():
            break
        # `used` 必须一起判：骨架已经给这个设施派了活，填充不得再派同一条
        # （否则同一批次里出现两条一模一样的 produce —— 契约层会直接判 id 重复）。
        if name in producing or name not in ai_units or name in used:
            continue
        producer_type = str(by_name.get(name, {}).get("type", ""))
        options = [(product, scene_index.get(product, ""))
                   for product, producer in PRODUCT_LADDER
                   if producer == producer_type and producer in own_types
                   and scene_index.get(product, "")]
        if not options:
            continue
        product, scene = min(options, key=lambda item: counts.get(item[0], 0))
        # 补工人要守**目标工人数**（与阶梯 1.8 同口径）：否则会绕过"够用就停手"，
        # 把指挥中心一直挂在"造工人"上（实测会挤掉出兵）。
        if product == worker_product:
            if deployed_workers + queued_workers >= target_workers:
                continue
        counts[product] = counts.get(product, 0) + 1
        _add("rule-produce-%s-%s-%d" % (product, name, tick), ACTION_PRODUCE, name,
             {"scene": scene, "producer": name}, 3,
             "并行填充：生产轨（%s 空闲，补 %s）" % (name, product),
             "rule-produce-%s" % product)

    # ---- 轨 3：侦察（专职侦察单位各自前探，互不排队）----
    enemies = _living_enemies(tactical)
    base = base_anchor_pos(by_name)
    bounds = state.get("map_bounds")
    combat_all = [n for n in ai_units
                  if str(by_name.get(n, {}).get("type", "")) in COMBAT_TYPES]
    # 主动交火的门槛与阶梯 3 **同口径**（兵力达标 ∧ 阶段允许 ∧ 有可见敌人）：
    # 并行填充只放宽"谁能拿到任务"，绝不放宽"什么时候能打"（手册禁止未达规模就添油）。
    may_attack = (bool(enemies) and bool(prefs.get("allow_attack", True))
                  and len(combat_all) >= max(1, int(army_threshold)))
    for name in ai_units:
        if not _room():
            break
        info = by_name.get(name) or {}
        if not _free(name) or str(info.get("type", "")) not in PROBE_TYPES:
            continue
        point = military_waypoint(base, bounds=bounds, enemies=enemies)
        if not point:
            break
        # `rule-fill-` 前缀：与阶梯骨架的 id 明确区分（同一批次里绝不允许 id 重复，
        # 契约层会直接判非法），日志/报告里也能一眼看出"这条是并行填充发的"。
        _add("rule-fill-scout-%s-%d" % (name, tick), ACTION_SCOUT, name, {"pos": point}, 3,
             "并行填充：侦察轨（朝已知敌情/地图内侧前探）", "rule-scout")

    # ---- 轨 4：军事（每个空闲作战单位各一条：能打就打、不能打就**有界**前压）----
    # `attack_move` 而不是 `move`：一路遇敌就地交火，不用再等下一轮决策。
    for index, name in enumerate(ai_units):
        if not _room():
            break
        info = by_name.get(name) or {}
        if not _free(name) or str(info.get("type", "")) not in COMBAT_TYPES:
            continue
        if enemies:
            # **有可见敌人时，作战单位只走"打"这一条路**：够格才打，不够格就**不发**。
            # 绝不能"不够格也往前顶" —— 那就是"拿 1 个兵硬冲 3 个敌人"，
            # 微操树同时还要负责劣势撤离（`test_outnumbered_retreat_preempts_model_attack`）。
            # 交火/撤离的威胁判断归行为树（它看得见数量对比），这里只做"规模够了就开打"。
            if may_attack:
                target_id = entity_id_of(min(enemies, key=lambda e: _pos2d(e)))
                if target_id:
                    _add("rule-fill-attack-%s" % name, ACTION_ATTACK, name,
                         {"entity_id": target_id}, 2,
                         "并行填充：军事轨（交火最近的可见敌人）", "rule-attack")
            continue
        # 无可见敌人：才谈"前压"。前压点由 `military_waypoint` 给
        # （朝地图内侧、不越交战线、不贴边）。
        point = military_waypoint(base, bounds=bounds, enemies=enemies, ring=1 + index // 4)
        if not point:
            break
        _add("rule-fill-advance-%s-%d" % (name, tick), ACTION_ATTACK_MOVE, name,
             {"pos": point}, 3,
             "并行填充：军事轨（前压到 %s，遇敌即交火）" % (point,), "rule-advance")

    return out


def development_intents(state: Dict[str, Any], *, tactical=None, rules=None,
                        ttl_ticks: int = 3600, server_tick: int = 0,
                        snapshot_id: int = 0,
                        army_threshold: int = ARMY_ATTACK_THRESHOLD
                        ) -> List[Dict[str, Any]]:
    """确定性**发展阶梯**（决策手册 BLD-01）的**对外出口**。

    返回 = 阶梯骨架（0~1 条，"当前主线最该做的那件事"）
         + **多轨并行填充**（其余空闲单位各自的活，见 `_parallel_intents`），
    最后按拒绝账本过滤。

    为什么过滤放在出口（而不是每个阶梯各自判断）："这条命令已被权威端拒过 N 次"
    是**全局知识**，只应有一个地方执行 —— 否则同类问题会在每个生产者里各犯一次
    （2026-09-12 实测：同一条坏命令刷屏 976 次）。
    """
    primary = _development_intents_raw(state, tactical=tactical, rules=rules,
                                      ttl_ticks=ttl_ticks, server_tick=server_tick,
                                      snapshot_id=snapshot_id, army_threshold=army_threshold)
    filled = _parallel_intents(state, tactical=tactical, rules=rules, primary=primary,
                               ttl_ticks=ttl_ticks, server_tick=server_tick,
                               snapshot_id=snapshot_id, army_threshold=army_threshold)
    return placement.filter_rejected(filled, state)


def _development_intents_raw(state: Dict[str, Any], *, tactical=None, rules=None,
                            ttl_ticks: int = 3600, server_tick: int = 0,
                            snapshot_id: int = 0,
                            army_threshold: int = ARMY_ATTACK_THRESHOLD
                            ) -> List[Dict[str, Any]]:
    """发展阶梯的实际实现（不经账本过滤；过滤在 `development_intents` 出口统一做）。

    为什么需要：实测两条路都不会发展 ——
      ① `rules_fallback` 只在模型失败时触发，而模型是"成功但只回 gather"；
      ② 2B 模型在 worker 全在采集时每轮重复 gather，整局不造建筑/不出兵。
    因此由调用方在"模型这一批没有任何发展动作"时用本函数**补上骨架**。

    边界（刻意保守，与本模块既有纪律一致）：
    - 只做**事实可判定**的事：缺什么建筑、谁空闲能造、谁能生产什么、有没有可见敌人；
    - **不做目标推理**：守哪、打谁、往哪侦察仍归模型；
    - 费用与预留不在这里判（下游 `reserves.apply_budget` 统一拦），这里只保证"能力+组合合法"。
    """
    by_name = _normalized_units(tactical)
    if not by_name:
        return []
    # 候选池严格取 `ai_controlled_units`（AI 租约列表）。
    # 【曾试图放宽，已撤回】一度改成"我方单位 − 玩家接管"，被安全边界用例
    # `test_player_controlled_units_never_appear` 拦住 —— 该用例证明
    # "不在 ai_controlled_units 里就不该碰"是**刻意设计的安全边界**，
    # 不能因为"想让它多干活"就放宽。要放宽必须先查清 `ai_controlled_units`
    # 由谁填充（`state.register_unit_generation` 的调用方），拿证据说话。
    # 输入统一由 ladder_inputs 计算：决策与诊断打点用**同一份口径**，
    # 否则"日志里看到的输入"和"实际喂给阶梯的输入"会分叉，
    # 排查又会退化成猜（这个坑本项目已经踩过）。
    inputs = ladder_inputs(state, tactical=tactical, rules=rules)
    busy = set(inputs["busy"])
    tick = int(server_tick or state.get("server_tick", 0) or 0)
    snapshot = int(snapshot_id or state.get("latest_snapshot_id", 0) or 0)
    expires = tick + max(1, int(ttl_ticks or 3600))
    scene_index = rules_scene_index(rules)
    # 【整局主线】规则中台按 `next_frontier` 推进（建造顺序 / 是否出击 / 是否前探），
    # 这就是"模型关闭时规则也沿主线发展"的落点。**没有 campaign_state 时返回宽松默认**，
    # 所以直接调用本函数的单测/回放语义不变。
    prefs = campaign_mod.frontier_preferences(state, tick=tick)
    suspended = {str(u) for u in (prefs.get("suspended_objects") or [])}
    ai_units = [u for u in inputs["ai_units"] if u not in suspended]
    busy = {u for u in busy if u not in suspended}

    def _intent(intent_id, action, unit, target, priority, rationale, task_id):
        # 唯一构造点在 `make_intent`（并行填充产出同形状意图，两处各写必然分叉）。
        return make_intent(intent_id, action, unit, target, priority, rationale,
                           task_id, tick=tick, snapshot=snapshot, expires=expires)

    # 挂起对象（玩家接管 / 中断）**不参与**阶梯：候选池必须与 `ai_units` 同一口径，
    # 否则"暂停受影响对象"会被 ladder_inputs 里未过滤的空闲清单绕过（实测会复发）。
    idle_builders = [u for u in inputs["idle_builders"] if u not in suspended]
    idle_producers = [u for u in inputs["idle_producers"] if u not in suspended]
    own_types = set(inputs["own_types"])
    built_types = set(inputs["built_types"])   # 建筑不是采集单位
    # 【三个叠加缺陷，2026-09-11 逐个修掉，勿回退】现由 `ladder_inputs()` 单点实现：
    #  A. 抢占判据曾要求**两个角色同时**为空。基地（command_center, queue=True）
    #     天然是"空闲生产者"，条件恒 False → 工人全忙时**永远没人去建造**。
    #     这就是"有兵无营"的直接成因。→ 改为**逐角色**判定。
    #  B. 候选池曾**试图**放宽成"我方单位 − 玩家接管"，被安全边界用例
    #     `test_player_controlled_units_never_appear` 拦下并撤回。纪律：
    #     不碰 `ai_controlled_units` 之外的单位是刻意设计的边界；
    #     **测试拦住你时，先假设测试是对的。**
    #  C. 抢占动作曾按具体动作名硬编码（只认 gather）→ 模型一发 scout/move
    #     就让建造阶梯再次饿死。→ 改为按**优先级语义**（PREEMPTIBLE_ACTIONS）。

    # 阶梯 1：按 `BUILD_LADDER` 补齐/扩建建造物（产能 → 防御 → 分基地），只往前推一级。
    # 退避期内**不尝试建造**（连续被拒 3 次 → 停 15 秒；GPT Q6：不得用无限重试掩盖拒绝），
    # 生产/采集等其它骨架不受影响。
    #
    # 【2026-09-12 晚扩线，用户反馈"不会发展、不会多造建筑、防御、分子基地"】
    # 旧实现是 `if building in own_types or building in built_types: continue` —— 只要
    # 有**一座**该类型就永远跳过，于是兵营+车厂建完发展线就彻底停（余额 46800 花不出去）。
    # 现在按**数量上限**判定（`BUILD_LIMITS`），于是"多造建筑 / 防御塔 / 第二座基地"
    # 才可能出现；同一类型需要几座由限额表说了算，不是"有一座就够"。
    building_counts: Dict[str, int] = {}
    for info in by_name.values():
        key = str(info.get("type", ""))
        if key:
            building_counts[key] = building_counts.get(key, 0) + 1
    # 【只建"规则视图里真能建的东西"】`rules_scene_index` 同时收 `unit_types[].scene_path`
    # 和 `constructions[].blueprint_scene_path`（unit_type 优先），所以 `scene_index` 里
    # **存在**某个 id ≠ 它能被建造。实测教训：规则视图里没有 `constructions` 时，
    # 阶梯仍会拿 `command_center` 的**单位**场景去发 build（=发一条必被权威端拒的命令）。
    # 建造清单以 `constructions` 为准（那才是"可建造"的权威声明）。
    buildable_ids = {str(item.get("id", ""))
                     for item in (rules or {}).get("constructions", []) or []
                     if isinstance(item, dict) and item.get("id")}
    build_backoff = tick < int(state.get("build_backoff_until_tick", 0) or 0)
    # 【施工串行】已有工地在施工 → 本轮**不开新工地**。
    # 依据（传统 AI 优点 #2"施工单工地串行：有任何建筑在施工就整轮不动，空工地才派 1 个工人"；
    # 2026-09-12 晚实测）：同时铺开多个工地时 `build` 命令 181 条、其中 **172 条被
    # `NotVisible` 拒**（落点在视野外），还把工人成批从采集里抽走 —— 采集线当场停摆。
    # 施工进度由下面的阶梯 1.5 保障（只派 1 个工人到场续建，其余继续干本职）。
    unfinished_now = list(inputs.get("unfinished_buildings") or [])
    # 落点可行性**账本**（几何类按点拉黑 / 内容类按意图前缀拉黑），整个循环共用：
    # 传账本本体而不是坐标列表 —— 落点生成器据此一次筛干净（含旧 `blocked_build_spots` 兼容）。
    blocked_spots = placement.ledger_from_state(state)
    # 【主线优先：兵力 or 扩建】当主线要的是"兵力/施压"（`produce_first`）且产能建筑
    # 已经就位时，**本轮不开新工地**，把这一轮让给生产级。
    # 依据（2026-09-12 真机 5 分钟实测）：阶梯是"逐级 return"结构，而建造序列
    # （兵营→车厂→机场→两座塔→第二座基地）永远还有下一座 → 生产级**一次都轮不到**，
    # 结果"建筑全建完、作战单位 0 个"。让位后 M03 秒级完成，前沿推进到扩张/施压，
    # 建造线随后自然恢复（前沿一换就重建 build_order）。
    # 施工串行与续建（阶梯 1.5）不受影响：工地上还有人干活。
    # 【富局不"二选一"】`produce_first` 是**穷局纪律**（钱只够一头：先补兵、别铺工地）。
    # 开局 5 万的购买力（250 工人 / 100 坦克 / 83 兵营）下钱不是瓶颈，**并行**才是对的：
    # 一边补兵一边继续铺产能/防御/分基地。实测穷局纪律用在富局上的后果就是
    # 5 分钟只花掉 9,550（19%）、余额 40,450 闲置、第二座基地拖到第 7.5 分钟。
    build_order = list(prefs.get("build_order") or BUILD_LADDER)
    if (prefs.get("produce_first") and (built_types & set(PRODUCTION_BUILDINGS))
            and bank_a(tactical) < RICH_BANK_A):
        build_order = []

    # 阶梯 0：**扩张前探**（只在"扩张选址"是前沿、且尚无合法落点时）。
    # 依据（手册 SCT-01 开局散点探路 / SCT-02 定向侦察）：分基地落点必须落在
    # **己方视野内**，而远端矿点没有己方单位就不会进视野 —— 缺的正是"派人过去"这一环。
    # 纪律：前探只能占用非采集的机动单位，且**绝不打断采集/建造**（四条线同时推进）。
    if prefs.get("expand_probe") and prefs.get("probe_point"):
        probe_unit = _pick_probe_unit(by_name, ai_units, busy)
        point = prefs.get("probe_point") or []
        if probe_unit and len(point) >= 2:
            return [_intent("rule-probe-expansion-%s-%d" % (probe_unit, tick),
                            ACTION_MOVE, probe_unit,
                            {"pos": [round(float(point[0]), 1), round(float(point[1]), 1)]},
                            2,
                            "扩张选址：派 %s 前探远端矿点方向（视野内的落点才合法）"
                            % probe_unit,
                            "rule-probe-expansion")]

    for building in [] if (build_backoff or unfinished_now) else build_order:
        if building not in buildable_ids:
            continue
        if building_counts.get(building, 0) >= int(BUILD_LIMITS.get(building, 1)):
            continue
        scene = scene_index.get(building, "")
        if not scene or not idle_builders:
            continue
        builder = idle_builders[0]
        # 【必须带落点】游戏侧 `_op_build` 取的是 `parsed.pos`，缺省为 (0,0) →
        # 实测被拒：{"primary_issue":"NotVisible","issues":["NotVisible","OutOfBounds",
        # "SurfaceNotBuildable"]}。这里取**主基地附近**的偏移点：基地一定在视野内，
        # 且周围通常是可建平地（比用建造者自身位置更稳）。
        anchor = _base_anchor_pos(by_name) or _pos2d(by_name.get(builder, {}))
        # 落点：**离己方单位与采矿通道最远**（实测旧落点"基地+5m 轮换方位"压在
        # 基地→矿点的通道上：barracks(10,12) 对工人 (8~10,13~14.6)，把工人堵在
        # 1.5m 口袋里采矿——用户反馈"兵营造的位置会卡住工人采矿"）。
        resources = [e for e in _entities(tactical)
                     if str(e.get("kind", "")).startswith("resource")]
        if building == "command_center":
            # 分基地：**不能**贴着主基地盖（那样毫无收益），要选远端矿点附近。
            place = pick_expansion_spot(by_name, resources, anchor,
                                        blocked=blocked_spots,
                                        bounds=state.get("map_bounds"))
            if not place:
                continue      # 没有"离主基地较远的可见矿点"→ 不建假分基地，继续看下级
        else:
            place = pick_build_spot(by_name, resources, anchor,
                                   blocked=blocked_spots,
                                   bounds=state.get("map_bounds"))
        # intent_id 必须**带上 tick**：游戏侧按 intent_id 幂等缓存回执，
        # 若沿用固定 id，重试会一直命中最早那次拒绝（实测 `intent_replay: true` +
        # `issued_tick` 停在旧值），换落点也永远不会被执行。
        return [_intent("rule-build-%s-%s-%d" % (building, builder, tick), ACTION_BUILD,
                        builder, {"scene": scene, "producer": builder, "pos": place}, 3,
                        "发展阶梯：尚无 %s，派工人到基地附近建造" % building,
                        "rule-build-%s" % building)]

    # 阶梯 1.5：**未完工的工地，派工人"到场"继续施工**（2026-09-12 实测真凶链）。
    #
    # 为什么是 `move` 而不是再发一次 `build`（关键，吃过亏）：
    # 游戏侧 `build` 走 `PlaceStructure` —— 它**新建**一座建筑；车厂已经放置过
    # （`constructed=False` 是"已放置、未完工"），重复放置必然被判 `Occupied`/不可建
    # （实测该 `rule-build-finish-*` 被权威端 **连续 Rejected ×32**）。
    # 施工本身在 `PlaceStructure` 成功时就通过 `AssignBuilders` 指给了工人，
    # **工人留在工地就会自动建完**；真正的病根是我们的指挥层把工人调走去采集，
    # 工地从此没人干活。所以这里只负责"把工人送回去"。
    unfinished = list(inputs.get("unfinished_buildings") or [])
    if unfinished and idle_builders:
        site = str(unfinished[0])
        x, z = _pos2d(by_name.get(site, {}))
        # 【必须带 scene】契约 `contracts.TacticalIntent` 对 `SCENE_ACTIONS`（build/produce）
        # 同时要求 `target.scene` 与 `target.producer`：缺 scene 直接判 `contract_invalid`
        # 丢掉。实测依据：`rule-finish-site-Unit_4-*` 就是这么被丢的。
        # scene 取**工地自身类型**的场景路径；取不到就整条不发 —— 阶梯继续往下走，
        # 不能因为"续建发不出去"把后面的出兵一起堵死。
        site_scene = scene_index.get(str(by_name.get(site, {}).get("type", "")), "")
        # target 同时带 `entity_id`：游戏侧 `Constructing.is_applicable`（工人 + 未完工己方建筑）
        # 需要**目标实体**才能挂 `ConstructUnits`；只给坐标会被当成"新建"→ `PlaceStructure`
        # → 必然 `Occupied`（实测 Rejected ×32）。带上实体名后，游戏侧即可路由到续建。
        if site_scene:
            return [_intent("rule-finish-site-%s-%d" % (site, tick), ACTION_BUILD,
                            idle_builders[0],
                            {"producer": idle_builders[0], "entity_id": site,
                             "scene": site_scene,
                             "pos": [round(x, 1), round(z, 1)]}, 3,
                            "发展阶梯：%s 未完工，派工人续建（实体续建，不是新建）" % site,
                            "rule-finish-site-%s" % site)]

    # 阶梯 1.8：**补工人**（纠偏 §一：默认策略里明确含"工人数目标"）。
    #
    # 为什么必须补这一步（实测 2026-09-12 晚）：`model=off` 的 5 分钟真实局里工人数
    # 一直停在 2、余额不动 —— 旧实现把"补工人"挂在 `batch_from_rules`（**降级批次**）里，
    # 而纠偏要求"规则中台常驻、模型只做稀疏覆盖"之后降级批次不再被调用，
    # 于是**整局没人造工人**，经济彻底停摆（这正是"地板必须自己完整"的意思）。
    #
    # **顺序刻意放在建造之后**：阶梯 1（补关键建筑）是手册 BLD-01 的第一优先，
    # 被既有回归 `test_builds_barracks_when_missing` /
    # `test_ladder_build_preempts_model_gather_on_same_worker` 钉住；
    # 而建造进入 `build_backoff`（连续被拒）时这里就能接管 —— 经济不会跟着建造一起停。
    #
    # 目标 = max(WORKER_TARGET, 会造工人的建筑数 × WORKERS_PER_BASE)，
    # 再减**已部署 + 队列中 + 在途**（三重去重），且**不占满生产队列**
    # （队列+在途 ≤ WORKER_QUEUE_CAP，遵循计划 §三"AI 不得占满生产队列"）。
    owned_types = {str(info.get("type", "")) for info in by_name.values()
                   if info.get("type")}
    worker_product = _worker_product(rules, owned_types)
    if worker_product:
        producer_type, product_id = worker_product
        deployed_workers = sum(1 for name in ai_units
                               if str(by_name.get(name, {}).get("type", "")) == product_id)
        base_count = sum(1 for name in ai_units
                         if str(by_name.get(name, {}).get("type", "")) == producer_type)
        target_workers = max(WORKER_TARGET, base_count * WORKERS_PER_BASE)
        queued_workers = 0
        for entry in (tactical or {}).get("production") or []:
            if not isinstance(entry, dict):
                continue
            for item in entry.get("items") or []:
                if str((item or {}).get("product_type_id", "")) == product_id:
                    queued_workers += 1
        in_flight_workers = sum(
            1 for intent in (state.get("active_intents") or [])
            if str(intent.get("intent_id", "")).startswith("rule-produce-%s" % product_id)
            and str(intent.get("state", "")) in LIVE_INTENT_STATES)
        producer = next((name for name in idle_producers
                         if str(by_name.get(name, {}).get("type", "")) == producer_type), "")
        worker_scene = scene_index.get(product_id, "")
        if in_flight_workers:
            # 【关键】本级已在推进时**绝不 return 同一条**：下游 `duplicate_of_live_intent`
            # 会把它拦下（它按"执行者+动作+产品"去重，不认 intent_id 里的 tick），而阶梯是
            # "逐级 return"结构 → **后面的出兵（阶梯 2）永远轮不到**。
            # 实测（2026-09-12 晚，model=off 5 分钟真实局）：`rule-produce-worker-Unit_0`
            # 被重复生成 **391 次**、全部因去重丢弃，结果是"兵营/车厂都建好了、余额一分没花、
            # 整局一个兵都没出"。这里改成"已在推进 → 往下走"。
            pass
        elif (producer and worker_scene
                and deployed_workers + queued_workers < target_workers
                and queued_workers < _worker_queue_cap(bank_a(tactical), target_workers,
                                                       deployed_workers)):
            return [_intent("rule-produce-%s-%s-%d" % (product_id, producer, tick),
                            ACTION_PRODUCE, producer,
                            {"scene": worker_scene, "producer": producer}, 4,
                            "发展阶梯：工人 %d/%d（队列 %d），基地补工人"
                            % (deployed_workers, target_workers, queued_workers),
                            "rule-produce-%s" % product_id)]

    # 阶梯 2：已有生产建筑且空闲 → 补作战单位（只补一级，避免一次灌太多）。
    #
    # **必须按"现有兵力构成"选级，不能总是返回第一级**（2026-09-11 实测修正）：
    # 兵营一旦建成，第一级 (soldier, barracks) 就永远命中 → 车厂全程闲置、
    # 整局只出士兵 —— "多兵种"名存实亡（实测 8 分钟只有 soldier，没有一辆坦克）。
    # 选级规则刻意做成**单步比较**（与 2B 模型口径一致，也便于单测）：
    # 在"产能可用"的级里，选**当前数量最少**的产品；并列时按阶梯顺序。
    options: List[Tuple[str, str, str]] = []
    # 生产只能派给**已完工**的设施（constructed 不是 False）。实测未加这条时，
    # 未完工的车厂被反复派产坦克 → 38 次 `ProducerNotConstructed`（纯噪音 + 卡住发展）。
    usable_producers = set(inputs.get("constructed_producers") or [])
    # 【2026-09-12 晚修：有钱不出兵 / 产线被"忙"整体挡死】
    # 判据从"整个 busy 集合"收窄到"**这个执行者是否已有在途的 produce 意图**"。
    # 为什么必须收窄（用户截图实测）：余额 46550、四座生产建筑全部 `queue_size=0`，
    # HUD 却是"本轮没有新命令" —— 因为 `idle_producers` 用的是 `busy`，而 `busy` 把
    # **任何**非可抢占的在途意图都算成占用；模型丢一条 `produce` 意图在途，再加上
    # 生产本身要 180~360 tick（3~6 秒）才结算，整条生产线就被判"占用"而停摆。
    # 收窄后：只有"该设施确实正在生产"才跳过，其它已完工设施照常补货。
    #
    # 【必须过滤存活状态】只看 `action == produce` 是不够的：`active_intents`
    # 是**追加式历史**（永不清理），第一次生产完之后，那条 `completed/expired` 的
    # 生产意图仍然留在表里 → 该设施被**永久**判为"正在生产"→ 再也不会被派生产。
    # 2026-09-12 真机 5 分钟实测：整局只出了 1 个兵（唯一一条 produce 回执），
    # 兵营/车厂/机场全部闲置，M03"首支作战队"卡了 12000 tick 才被超时阻塞。
    # 状态口径取 `graph.state.INTENT_LIVE_STATES`（唯一事实来源）；过期由
    # `runtime.tick()` 每轮统一标记为 expired，所以不需要在这里再查 TTL。
    producing_units = {str(unit)
                       for intent in (state.get("active_intents") or [])
                       if str(intent.get("action", "")) == ACTION_PRODUCE
                       and str(intent.get("state", "")) in LIVE_INTENT_STATES
                       for unit in (intent.get("unit_ids") or [])}
    free_producers = [name for name in idle_producers if name not in producing_units]
    for name in sorted(usable_producers):
        if name not in producing_units and name not in free_producers:
            free_producers.append(name)
    for product, producer_type in PRODUCT_LADDER:
        if producer_type not in own_types:
            continue
        scene = scene_index.get(product, "")
        if not scene:
            continue
        producer = next((n for n in free_producers
                         if by_name.get(n, {}).get("type") == producer_type
                         and n in usable_producers), "")
        if not producer:
            continue
        options.append((product, producer, scene))
    if options:
        counts: Dict[str, int] = {}
        for info in by_name.values():
            key = str(info.get("type", ""))
            if key:
                counts[key] = counts.get(key, 0) + 1
        product, producer, scene = min(options,
                                       key=lambda item: counts.get(item[0], 0))
        # 同样带 tick：生产被拒（如队列已满/资源不足）后要有机会重试，
        # 不能被游戏侧按 intent_id 幂等缓存成"永远同一个回执"。
        return [_intent("rule-produce-%s-%s-%d" % (product, producer, tick), ACTION_PRODUCE,
                        producer, {"scene": scene, "producer": producer}, 3,
                        "发展阶梯：现有 %s 最少，补充 %s" % (product, product),
                        "rule-produce-%s" % product)]

    # 阶梯 3：兵力达标且有可见敌人 → 出击（打谁由"最近"这一事实决定，不做威胁评估）。
    # 【整局主线】出击只在**施压/收束**阶段由规则发起（手册：集结 → 前压 → 进攻，
    # 禁止"未达规模就添油"）。`allow_attack` 缺省为 True，所以无 mainline 的调用不受影响。
    enemies = _living_enemies(tactical)
    combat = [n for n in ai_units
              if n not in busy and by_name.get(n, {}).get("type") in COMBAT_TYPES]
    if (enemies and len(combat) >= max(1, int(army_threshold))
            and bool(prefs.get("allow_attack", True))):
        target = min(enemies, key=lambda e: _pos2d(e))
        target_id = entity_id_of(target)
        if target_id:
            return [_intent("rule-attack-%s" % combat[0], ACTION_ATTACK, combat[0],
                            {"entity_id": target_id}, 2,
                            "发展阶梯：兵力达标且可见敌人，出击", "rule-attack")]
    return []
