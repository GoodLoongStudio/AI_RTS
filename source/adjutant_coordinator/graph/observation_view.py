# -*- coding: utf-8 -*-
"""观测（`op=tactical`）的**唯一**解析层：实体判定 / id 取值 / 坐标降维。

## 为什么必须有这个模块（2026-09-12 结构性整改）
`tactical` 观测是给副官看的"战场事实"，但它的解析口径原先**散落在各处**：
`rules_fallback`（950 行）里定义 `_entities` / `_own_units` / `_resources` /
`entity_id_of` / `_pos2d` / `_normalized_units`，行为树、任务补丁、资源分配又各自
按自己的理解再抄一份 —— 同一件事存在多份实现，**改一处不会同步到另一处**：
- `entity_id_of` 的注释就是血的教训：行为树曾自己按 `entity_id` 取 id →
  `visible_enemies` / `visible_resources` **恒为空** → 就近交火、劣势撤离、
  工人采集兜底**全部静默失效**（不报错、不降级，只是"什么都不做"）。
- `_normalized_units` 也有两份：一份在这里（带 `constructed` 三态），
  `rules_fallback.batch_from_rules` 里还有一份手写的（**没有 `constructed`**）→
  同一份观测，两条路径看到的字段不一样。

**纪律（任何新增代码都必须遵守）**：
1. 要读观测，只能从本模块取（`entities` / `own_units` / `resources` /
   `normalized_units` / `entity_id_of` / `pos2d`），**不许再写第二份解析**；
2. id 一律走 `entity_id_of`（游戏端导出的实体只有 `name` 字段）；
3. 坐标一律走 `pos2d`（观测里的 `pos` 是三维 `[x, y, z]`，直接当 `[x, z]` 用会错位）。
"""

from typing import Any, Dict, List, Optional, Tuple

__all__ = [
    "entities",
    "own_units",
    "resources",
    "living_enemies",
    "entity_id_of",
    "pos2d",
    "normalized_units",
]


def entities(tactical: Optional[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """观测里的全部实体（非 dict 项直接丢弃，坏观测不许冒泡成异常）。"""
    if not isinstance(tactical, dict):
        return []
    raw = tactical.get("entities") or []
    return [item for item in raw if isinstance(item, dict)]


def own_units(tactical: Optional[Dict[str, Any]]) -> List[Dict[str, Any]]:
    return [e for e in entities(tactical) if str(e.get("kind", "")) == "unit_self"]


def resources(tactical: Optional[Dict[str, Any]]) -> List[Dict[str, Any]]:
    return [e for e in entities(tactical) if str(e.get("kind", "")) == "resource"]


def living_enemies(tactical: Optional[Dict[str, Any]]) -> List[Dict[str, Any]]:
    return [e for e in entities(tactical)
            if str(e.get("kind", "")).startswith("unit_enemy")
            and not bool(e.get("confirmed_dead"))]


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


def pos2d(entity: Dict[str, Any]) -> Tuple[float, float]:
    """观测坐标 `[x, y, z]` → 平面 `(x, z)`；缺字段/坏值一律退回原点（不抛异常）。"""
    raw = entity.get("pos") or [0.0, 0.0, 0.0]
    if not isinstance(raw, (list, tuple)) or len(raw) < 3:
        return (0.0, 0.0)
    try:
        return (float(raw[0]), float(raw[2]))
    except (TypeError, ValueError):
        return (0.0, 0.0)


def normalized_units(tactical: Optional[Dict[str, Any]]) -> Dict[str, Dict[str, Any]]:
    """观测单位 → {name: {type, gather, construct, queue, movement, pos, constructed}}。

    `constructed` 必须保留**三态**（True / False / None=未知）：
    2026-09-12 实测，`vehicle_factory constructed=False` 被当成"已建成"，
    导致权威端连续 38 次 `ProducerNotConstructed`（派未完工建筑去生产）。

    `movement`（2026-09-12 补）：**区分"会动的单位"与"不动的建筑"**。
    缺这一项时，"挑一个机动单位去前探"会挑到炮塔/机场这类静态建筑，
    权威端只能 `Rejected`（实测：6 条 `rule-probe-expansion` 全被拒 →
    扩张选址被误判成"命令一直失败"而阻塞）。它是**加法字段**，
    既有读取方不受影响。
    """
    return {
        str(unit.get("name", "")): {
            "type": str(unit.get("unit_type", "") or unit.get("type", "")),
            "gather": bool(unit.get("gather")),
            "construct": bool(unit.get("construct")),
            "queue": bool(unit.get("queue")),
            "movement": bool(unit.get("movement")),
            "pos": unit.get("pos"),
            "constructed": unit.get("constructed"),
        }
        for unit in own_units(tactical)
    }
