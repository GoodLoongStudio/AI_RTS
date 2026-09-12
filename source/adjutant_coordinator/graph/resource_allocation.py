# -*- coding: utf-8 -*-
"""资源点分配：**全仓库唯一**的"谁在哪个矿、一个矿几个人"账本 + 分配器 + 自愈再平衡。

## 为什么独立成一个模块（2026-09-12 实机事故 + 用户要求"从根上解决，同类问题不要再出现"）

用户现场：基地旁边一圈矿，4 个工人却有 3 个挤在同一个矿上，5~7 米外的矿一个都没人用，
而且**不会自己散开**。逐层查下来这是一**类**问题：

1. **账本只看得见局部**：分配器只统计"本轮新派出去的人"。已经在采矿的工人是 busy，
   被调用方的 `gatherers` 过滤掉了，**根本不在负载里** → 第 3 个工人算出来"该矿 0 人"
   → 又派到同一个矿。
2. **同一规则被抄成多份**：`_nearest_resource` 在 `rules_fallback` 与 `behavior_tree` 各一份；
   `RESOURCE_WORKERS_PER_NODE` 在 `rules_fallback` 与 `task_patch` 各定义一份 ——
   改一处不会同步到另一处（仓库已有先例教训：`entity_id_of` 的注释写着"必须单点定义"）。
3. **没有反馈/自愈**：游戏侧 `CollectingResourcesSequentially` 是"**认死一个矿**"的循环
   （采满 → 回城交货 → 再回**同一个**矿），所以**分配那一刻**放错就永久错。
4. 观测没有矿点容量/存量字段，只能用一个保守常量近似（等观测提供容量后再改为按容量分配）。

## 不可协商的不变式（本模块是唯一实现处）

- **任何"派遣工人去矿点"的决策，都必须先扣这份在途占用账**（`occupancy()`），
  不许各路径自己算"本轮新派了几个"。`assign()` 的 `existing_load` / `skip` 就是这条的接口。
- 观测解析一律走 `observation_view`（本模块只从那里取 id 与坐标）。
- `RESOURCE_WORKERS_PER_NODE` **只在这里定义**；其他模块必须 import，不许再写一份。
- `assign()` 只负责"**还没上岗的人**去哪"；已经在岗的人不许被它二次占位（否则会把
  真正待分配的人挤到"无矿可分"）。超员矿点的纠正属于 `rebalance()`。
"""

from typing import Any, Dict, List, Optional, Set, Tuple

from .observation_view import entity_id_of, pos2d
from .state import INTENT_LIVE_STATES

#: 采集动作 id（与 contracts/rules 视图一致）。
ACTION_GATHER = "gather"

#: 同一个矿点最多同时派几个工人。矿点本身没有容量字段（观测也未提供），
#: 先用这个保守常量替代；等观测出现容量/存量后改为按容量分配。
RESOURCE_WORKERS_PER_NODE = 2


def _kind(resource: Dict[str, Any]) -> str:
    """资源类型（A/B）：用于"两种资源摊平"的均衡（照搬游戏内传统 AI 的做法）。"""
    return str(resource.get("kind", "") or resource.get("unit_type", "") or "")


def _distance_sq(unit: Dict[str, Any], resource: Dict[str, Any]) -> float:
    ux, uz = pos2d(unit or {})
    rx, rz = pos2d(resource or {})
    return (rx - ux) ** 2 + (rz - uz) ** 2


def live_gather_holders(intents: Optional[List[Dict[str, Any]]],
                        by_name: Optional[Dict[str, Dict[str, Any]]] = None,
                        ) -> Dict[str, str]:
    """在途采集意图 → `{单位名: 矿点 id}`（同一工人多条意图时取最后一条）。

    只认**在途意图**，不按距离猜"谁站在矿边"：距离猜测会把**待分配的工人自己**也算成占用
    （自己把自己挤掉）。意图过期后由行为树下一轮重新分配，届时负载已经正确。
    """
    holder: Dict[str, str] = {}
    for intent in intents or []:
        if str(intent.get("action", "")) != ACTION_GATHER:
            continue
        if str(intent.get("state", "")) not in INTENT_LIVE_STATES:
            continue
        eid = str((intent.get("target") or {}).get("entity_id", "") or "")
        if not eid:
            continue
        for unit in intent.get("unit_ids") or []:
            name = str(unit)
            if by_name is not None and not (by_name.get(name) or {}).get("gather"):
                continue          # 只统计真正能采集的单位
            holder[name] = eid
    return holder


def occupancy(by_name: Dict[str, Dict[str, Any]],
              resources: List[Dict[str, Any]],
              intents: Optional[List[Dict[str, Any]]] = None,
              ) -> Tuple[Dict[str, int], Dict[str, int], Dict[str, str]]:
    """统计"**已经在采**的人" → `({矿点 id: 人数}, {资源类型: 人数}, {工人: 矿点 id})`。

    为什么必须有这一层（用户实测：基地旁边一堆矿，工人却全挤在一个矿上）：
    调用方过滤 busy 单位时，**已上岗的人会被一起过滤掉**，于是新工人看到的是"这些矿都没人"。
    这里把已上岗的人补回账里 —— 之后的分配自然去其它矿点（`assign()` 的排序键里
    "节点负载"优先于距离）。第三个返回值是"谁在哪个矿"，`assign()` 用它跳过已在岗的人。
    """
    kind_of: Dict[str, str] = {}
    for resource in resources or []:
        eid = str(entity_id_of(resource))
        if eid:
            kind_of[eid] = _kind(resource)
    holder = {name: eid for name, eid in
              live_gather_holders(intents, by_name).items() if eid in kind_of}
    load_node: Dict[str, int] = {}
    load_type: Dict[str, int] = {}
    for eid in holder.values():
        load_node[eid] = int(load_node.get(eid, 0)) + 1
        kind = kind_of.get(eid, "")
        load_type[kind] = int(load_type.get(kind, 0)) + 1
    return load_node, load_type, holder


def assign(by_name: Dict[str, Dict[str, Any]],
           resources: List[Dict[str, Any]],
           unit_names: Optional[List[str]] = None,
           per_node: int = RESOURCE_WORKERS_PER_NODE,
           *,
           existing_load: Optional[Dict[str, int]] = None,
           existing_type_load: Optional[Dict[str, int]] = None,
           skip: Optional[Set[str]] = None,
           ) -> Dict[str, str]:
    """给**还没上岗**的采集单位分配矿点 → `{单位名: 矿点 entity_id}`。

    排序键：① 该**资源类型**已分配人数（A/B 摊平）② 该**矿点**已分配人数（去冲突的核心）
    ③ 距离。`existing_*` 是"已经在采的人"的占用账（见 `occupancy()`），`skip` 是已在岗的人
    （他们不需要新位置，也不该再占一个名额）。**不传 `existing_*` 就会出现"4 个工人挤一个矿"**。
    """
    names = [str(n) for n in (unit_names if unit_names is not None else (by_name or {}).keys())]
    names = [n for n in names
             if (by_name or {}).get(n, {}).get("gather") and n not in (skip or set())]
    load_node: Dict[str, int] = {str(k): int(v) for k, v in (existing_load or {}).items()}
    load_type: Dict[str, int] = {str(k): int(v) for k, v in (existing_type_load or {}).items()}
    assigned: Dict[str, str] = {}
    for name in names:
        info = (by_name or {}).get(name) or {}
        best = None
        best_key = None
        best_eid = ""
        best_type = ""
        for resource in resources or []:
            eid = str(entity_id_of(resource))
            if not eid:
                continue
            node_load = int(load_node.get(eid, 0))
            if per_node and node_load >= per_node:
                continue          # 该矿点已满：换下一个（分配去冲突的核心）
            rtype = _kind(resource)
            key = (int(load_type.get(rtype, 0)), node_load, _distance_sq(info, resource))
            if best_key is None or key < best_key:
                best, best_key, best_eid, best_type = resource, key, eid, rtype
        if best is None:
            continue              # 所有矿点都满：本轮不分配（下游可退回"最近"）
        assigned[name] = best_eid
        load_node[best_eid] = int(load_node.get(best_eid, 0)) + 1
        load_type[best_type] = int(load_type.get(best_type, 0)) + 1
    return assigned


def rebalance(by_name: Dict[str, Dict[str, Any]],
              resources: List[Dict[str, Any]],
              intents: Optional[List[Dict[str, Any]]] = None,
              per_node: int = RESOURCE_WORKERS_PER_NODE,
              ) -> List[Tuple[str, str]]:
    """**自愈**：把超员矿点上"多出来的人"改派到还有空位的矿点 → `[(单位名, 新矿点 id)]`。

    为什么必须有（类的根因之一，见模块头注释）：游戏侧采集是"认死一个矿"的循环，
    分配错一次就永久错 —— 没有这一层，"4 个工人挤 1 个矿、旁边 3 个矿没人用"
    会一直持续到那个矿被采空。

    选择被改派的人：同矿里**意图签发最晚**的那个（投入最少、最可能还在路上，浪费最小）。
    幂等/防抖：只在"存在还有空位的矿点"时改派，且改派目标同样按
    (类型负载, 节点负载, 距离) 选、并即时更新账本 → 连续两轮不会产生新的重派意图。
    """
    load_node, load_type, holder = occupancy(by_name, resources, intents)
    issued: Dict[str, int] = {}
    for intent in intents or []:
        eid = str((intent.get("target") or {}).get("entity_id", "") or "")
        for unit in intent.get("unit_ids") or []:
            name = str(unit)
            if name in holder and holder[name] == eid:
                issued[name] = max(issued.get(name, 0),
                                   int(intent.get("issued_tick", 0) or 0))
    moves: List[Tuple[str, str]] = []
    per_node = max(1, int(per_node))
    for eid in [k for k, v in load_node.items() if int(v) > per_node]:
        excess = int(load_node.get(eid, 0)) - per_node
        candidates = sorted(
            [n for n, node in holder.items() if node == eid],
            key=lambda n: (-issued.get(n, 0), n))          # 签发最晚的先改派
        for name in candidates:
            if excess <= 0:
                break
            free = [r for r in (resources or [])
                    if int(load_node.get(str(entity_id_of(r)), 0)) < per_node]
            if not free:
                return moves      # 没有空位就不折腾（宁可挤，也不让工人闲置）
            info = (by_name or {}).get(name) or {}
            best = min(free, key=lambda r: (
                int(load_type.get(_kind(r), 0)),
                int(load_node.get(str(entity_id_of(r)), 0)),
                _distance_sq(info, r)))
            target = str(entity_id_of(best))
            load_node[target] = int(load_node.get(target, 0)) + 1
            load_type[_kind(best)] = int(load_type.get(_kind(best), 0)) + 1
            load_node[eid] = int(load_node.get(eid, 0)) - 1
            holder.pop(name, None)
            moves.append((name, target))
            excess -= 1
    return moves
