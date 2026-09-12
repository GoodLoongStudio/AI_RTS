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

#: 兜底最多派几个工人去采集（避免一次灌太多意图）。
MAX_GATHER_INTENTS = 4
#: 工人少于该数量时，基地尝试补工人。
WORKER_TARGET = 4

# ---------------- 发展阶梯（决策手册 BLD-01） ----------------
#: 有作战单位达到该数量且存在可见敌人时，阶梯给出 attack 候选。
#: 【待实测】参考值，不是平衡事实；由配置覆盖，禁止在别处硬编码。
ARMY_ATTACK_THRESHOLD = 2
#: 视为"作战单位"的单位类型（drone 无武器，不计入）。
COMBAT_TYPES = ("soldier", "tank", "helicopter")
#: 发展阶梯的建造顺序（每级只在前一级已具备时才考虑下一级）。
BUILD_LADDER = ("barracks", "vehicle_factory")
#: 各建造物对应的"由谁生产什么"（产品 id → 生产建筑类型）。
PRODUCT_LADDER = (("soldier", "barracks"), ("tank", "vehicle_factory"))
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
#: 实测（2026-09-12 用户截图）：3 个工人全挤在一个矿点上、部队被堵、有人闲置——
#: 因为所有路径都"各自取最近的矿点"，没有分配层。资源点本身没有容量字段，
#: 先用该常量做去冲突；等观测提供容量/矿量后再改为按容量分配。
RESOURCE_WORKERS_PER_NODE = 2


def assign_resources(by_name: Dict[str, Dict[str, Any]],
                     resources: List[Dict[str, Any]],
                     unit_names: Optional[List[str]] = None,
                     per_node: int = RESOURCE_WORKERS_PER_NODE) -> Dict[str, str]:
    """给采集单位**分配矿点**：{单位名: 资源 entity_id}。

    直接照搬游戏内传统 AI 的成熟做法（`simple-clairvoyant-ai/EconomyController`）：
    > `_find_visible_resource`：按**资源节点**统计已分配人数，**优先人少且近**的节点，
    > "避免多个工人挤同一矿点造成寻路拥塞和原地转圈"（该文件 2026-09-03 的注释）。
    另外照搬它的**资源类型均衡**：优先分给"已分配人数更少的那种资源"（A/B 摊平）。

    为什么必须由程序分配（实测 2026-09-12 用户截图）：行为树原来取"最近的矿"，
    3 个工人必然全部指向同一个矿点 → 互相卡住、部队被堵、其余人闲置。
    """
    names = [str(n) for n in (unit_names if unit_names is not None else by_name.keys())]
    names = [n for n in names if by_name.get(n, {}).get("gather")]
    load_node: Dict[str, int] = {}
    load_type: Dict[str, int] = {}
    assigned: Dict[str, str] = {}
    for name in names:
        info = by_name.get(name) or {}
        origin = _pos2d(info)
        best = None
        best_key = None
        for resource in resources or []:
            eid = str(entity_id_of(resource))
            if not eid:
                continue
            node_load = int(load_node.get(eid, 0))
            if per_node and node_load >= per_node:
                continue        # 该矿点已满：换下一个（分配去冲突的核心）
            rtype = str(resource.get("kind", "") or resource.get("unit_type", ""))
            rp = _pos2d(resource)
            distance = (rp[0] - origin[0]) ** 2 + (rp[1] - origin[1]) ** 2
            # 排序键：① 该资源类型已分配人数（A/B 均衡）② 该矿点已分配人数 ③ 距离
            key = (int(load_type.get(rtype, 0)), node_load, distance)
            if best_key is None or key < best_key:
                best, best_key, best_eid, best_type = resource, key, eid, rtype
        if best is None:
            continue            # 所有矿点都满：本轮不分配（下游退回最近）
        assigned[name] = best_eid
        load_node[best_eid] = int(load_node.get(best_eid, 0)) + 1
        load_type[best_type] = int(load_type.get(best_type, 0)) + 1
    return assigned


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


def pick_build_spot(by_name, resources, anchor, blocked=None) -> list:
    """选建造落点：**离己方单位与采矿通道最远**，且离基地不过远（确定性）。

    实测依据（2026-09-12 用户反馈："兵营造的位置会卡住工人采矿"）：
    旧落点是"基地 + 5m、按 tick 轮换方位"，实测 barracks(10,12) 正好压在
    工人 (8~10, 13~14.6) 的采矿通道上，把工人堵在 1.5m 口袋里。
    改为多方位候选 + 三重打分：离己方实体 ≥8m / 离采矿通道与资源点越远越好 / 半径接近 18m。
    """
    units = [_pos2d(info) for info in by_name.values() if info.get("pos")]
    resource = _nearest_resource_pos(by_name, resources)
    best, best_score = None, None
    # 半径必须**留在视野内**：实测 `NotVisible` 是建造被拒的唯一原因（64/64 条）。
    # 历史事实：旧的"基地+5m"落点能成功建成兵营；8/12/16m 全部被拒 →
    # 说明视野半径很小（~5m 量级）。因此候选降到 4/6/8m，并在同等净空下**优先更近**。
    for radius in (4.0, 6.0, 8.0):
        for slot in range(8):
            angle = math.pi / 4 * slot
            spot = (anchor[0] + math.cos(angle) * radius,
                    anchor[1] + math.sin(angle) * radius)
            # 已被权威端拒过的点（NotVisible/Occupied/…）直接跳过 —— 换位置重试，
            # 不做"同一坏点无限重发"（GPT Q6 要求；实测同点被拒 31 次）。
            if blocked and any(((spot[0] - float(b[0])) ** 2
                                + (spot[1] - float(b[1])) ** 2) < 4.0
                               for b in blocked if len(b) >= 2):
                continue
            near_unit = min(((spot[0] - u[0]) ** 2 + (spot[1] - u[1]) ** 2) ** 0.5
                            for u in units) if units else 999.0
            # 阈值不能太严：6m 会把 4~8m 环上的候选全部排除 → 走到兜底点 → 必然 NotVisible。
            if near_unit < 3.5:
                continue
            if resource is not None:
                clear = min(_dist_point_segment(spot, anchor, resource),
                            ((spot[0] - resource[0]) ** 2
                             + (spot[1] - resource[1]) ** 2) ** 0.5)
            else:
                clear = 999.0
            # 净空优先；同等净空时**取更近的半径**（更可能在视野内、也少堵路）。
            score = (clear, -radius, -slot)
            if best_score is None or score > best_score:
                best, best_score = spot, score
    if best is None:
        # 兜底也必须**留在视野内**：5m 是与"曾经成功建成兵营"同量级的距离
        # （旧实现正是"基地+5m"；12m 的兜底实测必然 NotVisible）。
        return [round(anchor[0] + 5.0, 1), round(anchor[1], 1)]
    return [round(best[0], 1), round(best[1], 1)]


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


def _entities(tactical: Optional[Dict[str, Any]]) -> List[Dict[str, Any]]:
    if not isinstance(tactical, dict):
        return []
    raw = tactical.get("entities") or []
    return [item for item in raw if isinstance(item, dict)]


def _own_units(tactical) -> List[Dict[str, Any]]:
    return [e for e in _entities(tactical) if str(e.get("kind", "")) == "unit_self"]


def _resources(tactical) -> List[Dict[str, Any]]:
    return [e for e in _entities(tactical) if str(e.get("kind", "")) == "resource"]


def entity_id_of(entity: Dict[str, Any]) -> str:
    """观测实体的稳定 id：**一律取 `name`**（`entity_id` 只是历史/测试兼容别名）。

    为什么必须单点定义：游戏端导出的实体**只有 `name`** ——
    敌人见 `DebugControlServer._tactical_enemy_entry`，资源见 `_op_tactical`
    的 resource 分支，全仓没有任何 `entity_id` 字段。
    行为树曾按 `entity_id` 取 enemy/resource 的 id，于是
    `visible_enemies` / `visible_resources` **恒为空**
    → 就近交火、劣势撤离、工人采集兜底**全部静默失效**
    （不报错、不降级，就是"什么都不做"，极难从日志看出）。
    所以统一到这一个函数，任何适配器都不许自己解析 id。
    """
    if not isinstance(entity, dict):
        return ""
    return str(entity.get("name") or entity.get("entity_id") or "")


def _pos2d(entity: Dict[str, Any]) -> Tuple[float, float]:
    raw = entity.get("pos") or [0.0, 0.0, 0.0]
    if not isinstance(raw, (list, tuple)) or len(raw) < 3:
        return (0.0, 0.0)
    try:
        return (float(raw[0]), float(raw[2]))
    except (TypeError, ValueError):
        return (0.0, 0.0)


def busy_units(state: Dict[str, Any]) -> set:
    """已被活跃/在途意图占用的单位：兜底绝不抢这些单位。"""
    busy = set()
    for intent in state.get("active_intents") or []:
        if intent.get("state") in ("active", "pending_authority"):
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


def batch_from_rules(state: Dict[str, Any], *, tactical=None, rules=None,
                     ttl_ticks: int = 3600, server_tick: int = 0,
                     snapshot_id: int = 0) -> Dict[str, Any]:
    """产出保守的兜底意图批次；形状与模型输出一致，后续走同一套校验与仲裁。"""
    owned = _own_units(tactical)
    # 观测里的类型字段是 unit_type（不是 type）。这里统一规范化一份，
    # 否则 owned_types 会是空集、_worker_product 永远匹配不到生产者 → 永不补工人。
    by_name = {
        str(unit.get("name", "")): {
            "type": str(unit.get("unit_type", "") or unit.get("type", "")),
            "gather": bool(unit.get("gather")),
            "construct": bool(unit.get("construct")),
            "queue": bool(unit.get("queue")),
            "pos": unit.get("pos"),
        }
        for unit in owned
    }
    ai_units = [str(u) for u in (state.get("ai_controlled_units") or [])]
    busy = busy_units(state)
    tick = int(server_tick or state.get("server_tick", 0) or 0)
    snapshot = int(snapshot_id or state.get("latest_snapshot_id", 0) or 0)
    expires = tick + max(1, int(ttl_ticks or 3600))

    resources = _resources(tactical)
    intents: List[Dict[str, Any]] = []

    # 在工地上的工人**不许被抢去采集**（2026-09-12 实测）：施工是指派制，
    # 工人被调走 → 工地永远建不完 → 生产全被 `ProducerNotConstructed` 拒（实测 38 次）。
    on_site: set = set()
    for info in by_name.values():
        if info.get("type") and info.get("constructed") is False:
            sx, sz = _pos2d(info)
            for name, unit in by_name.items():
                if not unit.get("gather"):
                    continue
                ux, uz = _pos2d(unit)
                if (ux - sx) ** 2 + (uz - sz) ** 2 <= SITE_KEEP_RADIUS_M ** 2:
                    on_site.add(name)
    gatherers = [name for name in ai_units
                 if name not in busy and name not in on_site
                 and bool(by_name.get(name, {}).get("gather"))]
    resource_load: Dict[str, int] = {}
    for name in gatherers[:MAX_GATHER_INTENTS]:
        resource = _nearest_resource(by_name.get(name, {}), resources,
                                     load=resource_load,
                                     cap=RESOURCE_WORKERS_PER_NODE)
        if resource is None:
            break
        entity = str(entity_id_of(resource))
        resource_load[entity] = resource_load.get(entity, 0) + 1
        target: Dict[str, Any] = {"entity_id": entity_id_of(resource)}
        target["pos"] = [round(_pos2d(resource)[0], 1), round(_pos2d(resource)[1], 1)]
        intents.append({
            "intent_id": "rule-gather-%s" % name,
            "task_id": "rule-gather",
            "unit_ids": [name],
            "action": ACTION_GATHER,
            "target": target,
            "priority": 4,
            "based_on_snapshot": snapshot,
            "issued_tick": tick,
            "expires_tick": expires,
            "generation": 0,
            "rationale": "规则兜底：模型未就绪，先让工人采集",
        })

    workers = [name for name in ai_units if bool(by_name.get(name, {}).get("gather"))]
    producers = [name for name in ai_units
                 if name not in busy and bool(by_name.get(name, {}).get("queue"))]
    owned_types = {info["type"] for info in by_name.values() if info["type"]}
    product = _worker_product(rules, owned_types)
    if producers and product and len(workers) < WORKER_TARGET:
        producer_type, product_id = product
        producer = next((n for n in producers
                         if str(by_name.get(n, {}).get("type", "")) == producer_type),
                        producers[0])
        scene = rules_scene_index(rules).get(product_id, "")
        if scene:
            intents.append({
                "intent_id": "rule-produce-worker-%s" % producer,
                "task_id": "rule-train-worker",
                "unit_ids": [producer],
                "action": ACTION_PRODUCE,
                "target": {"scene": scene, "producer": producer},
                "priority": 3,
                "based_on_snapshot": snapshot,
                "issued_tick": tick,
                "expires_tick": expires,
                "generation": 0,
                "rationale": "规则兜底：工人不足，基地补工人",
            })

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
    """观测单位 → {name: {type, gather, construct, queue, pos, constructed}}。

    `constructed` 必须保留**三态**（True / False / None=未知）：
    2026-09-12 实测，`vehicle_factory constructed=False` 被当成"已建成"，
    导致权威端连续 38 次 `ProducerNotConstructed`（派未完工建筑去生产）。
    """
    return {
        str(unit.get("name", "")): {
            "type": str(unit.get("unit_type", "") or unit.get("type", "")),
            "gather": bool(unit.get("gather")),
            "construct": bool(unit.get("construct")),
            "queue": bool(unit.get("queue")),
            "pos": unit.get("pos"),
            "constructed": unit.get("constructed"),
        }
        for unit in _own_units(tactical)
    }


def _living_enemies(tactical) -> List[Dict[str, Any]]:
    return [e for e in _entities(tactical)
            if str(e.get("kind", "")).startswith("unit_enemy")
            and not bool(e.get("confirmed_dead"))]


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
    }


def development_intents(state: Dict[str, Any], *, tactical=None, rules=None,
                        ttl_ticks: int = 3600, server_tick: int = 0,
                        snapshot_id: int = 0,
                        army_threshold: int = ARMY_ATTACK_THRESHOLD
                        ) -> List[Dict[str, Any]]:
    """确定性**发展阶梯**（决策手册 BLD-01），返回 0~2 条意图。

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
    ai_units = list(inputs["ai_units"])
    busy = set(inputs["busy"])
    tick = int(server_tick or state.get("server_tick", 0) or 0)
    snapshot = int(snapshot_id or state.get("latest_snapshot_id", 0) or 0)
    expires = tick + max(1, int(ttl_ticks or 3600))
    scene_index = rules_scene_index(rules)

    def _intent(intent_id, action, unit, target, priority, rationale, task_id):
        return {
            "intent_id": intent_id, "task_id": task_id, "unit_ids": [unit],
            "action": action, "target": target, "priority": priority,
            "based_on_snapshot": snapshot, "issued_tick": tick,
            "expires_tick": expires, "generation": 0, "rationale": rationale,
        }

    idle_builders = list(inputs["idle_builders"])
    idle_producers = list(inputs["idle_producers"])
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

    # 阶梯 1：补齐缺失的建造物（barracks → vehicle_factory），只往前推一级。
    # 退避期内**不尝试建造**（连续被拒 3 次 → 停 15 秒；GPT Q6：不得用无限重试掩盖拒绝），
    # 生产/采集等其它骨架不受影响。
    build_backoff = tick < int(state.get("build_backoff_until_tick", 0) or 0)
    for building in [] if build_backoff else BUILD_LADDER:
        if building in own_types or building in built_types:
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
        # 传"已被拒的坏点"：同一落点不再重发（实测同点被拒 31 次，全是 NotVisible）。
        place = pick_build_spot(by_name, resources, anchor,
                               blocked=list(state.get("blocked_build_spots") or []))
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
        # target 同时带 `entity_id`：游戏侧 `Constructing.is_applicable`（工人 + 未完工己方建筑）
        # 需要**目标实体**才能挂 `ConstructUnits`；只给坐标会被当成"新建"→ `PlaceStructure`
        # → 必然 `Occupied`（实测 Rejected ×32）。带上实体名后，游戏侧即可路由到续建。
        return [_intent("rule-finish-site-%s-%d" % (site, tick), ACTION_BUILD,
                        idle_builders[0],
                        {"producer": idle_builders[0], "entity_id": site,
                         "pos": [round(x, 1), round(z, 1)]}, 3,
                        "发展阶梯：%s 未完工，派工人续建（实体续建，不是新建）" % site,
                        "rule-finish-site-%s" % site)]

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
    for product, producer_type in PRODUCT_LADDER:
        if producer_type not in own_types:
            continue
        scene = scene_index.get(product, "")
        if not scene:
            continue
        producer = next((n for n in idle_producers
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
    enemies = _living_enemies(tactical)
    combat = [n for n in ai_units
              if n not in busy and by_name.get(n, {}).get("type") in COMBAT_TYPES]
    if enemies and len(combat) >= max(1, int(army_threshold)):
        target = min(enemies, key=lambda e: _pos2d(e))
        target_id = entity_id_of(target)
        if target_id:
            return [_intent("rule-attack-%s" % combat[0], ACTION_ATTACK, combat[0],
                            {"entity_id": target_id}, 2,
                            "发展阶梯：兵力达标且可见敌人，出击", "rule-attack")]
    return []
