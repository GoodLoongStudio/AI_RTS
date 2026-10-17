# G4 生产出生点 Implementation Plan

## Overview
生成图不烘导航网格。生产单位仍按“选中圈对角线 + 导航代理半径 2.8 米”往外找落点，兵从厂房门口外面很远的空地冒出来。改为贴着碰撞体朝向的那一面出门。

## Current State Analysis
- `production_spawn_spot` 扫建筑整棵子树的 `GeometryInstance3D`。选中圈是一块平面，对角比圆半径大约 1.41 倍；航空工厂选中圈半径 4.11 米，外缘被算成 5.82 米。
- 随后无条件加上导航 `agent_radius`。生成图没有导航网格，读不到就用 2.8 米兜底。
- 实测航空工厂产出半径 2.2 米的单位时，落点距建筑中心 10.92 米。车厂 10.14 米，兵营 9.40 米，矿场 9.95 米。
- 门口若再被邻楼足迹挡住，径向搜索继续外扩，单位落到基地外侧空地。
- 有导航网格的地图仍要留在 carve 洞外，这条路径不能改。

## Implementation Strategy
`occupancy` 非空表示逻辑地形（生成图）。这条路径只量 `Geometry` 模型沿出门方向的前伸，以及碰撞体沿同一方向的前伸，取较大者，再留 0.2 米。不加导航代理半径，不把选中圈、血条、集结点标记算进外缘。有导航网格时仍走原来的外缘加代理半径。

## Implementation Steps
1. ✅ 计划
2. ✅ `MovementObstacle.collision_extent_along`：碰撞体沿给定方向的前伸，不含导航外扩
3. ✅ `production_spawn_spot` 在逻辑地形改用门口距离
4. ✅ 无头探针核对四座生产建筑的落点距离

## Timeline
本轮完成。

## Risk Assessment
- 导航图路径保持原公式，避免把单位放进 carve 洞。
- 门口距离取模型和碰撞的较大值，避免网格伸出碰撞时单位嵌进模型。
- 0.2 米皮只为躲开足迹边界上的采样点，不再把整圈往外推数米。

## Success Criteria
- 航空工厂、车厂、兵营、矿场在逻辑地形上的出生点距中心小于 8.5 米，且大于各自碰撞前伸
- 落点在建筑局部 +Z
- 导航图出生公式不改

## Progress Tracking
- ✅ 计划
- ✅ 碰撞前伸
- ✅ 门口出生
- ✅ 探针：航空工厂 6.89 米（原 10.92）、车厂 5.20、兵营 4.29、矿场 4.57，都在局部 +Z。门口被挡住时改到同半径侧面 (5.88, 3.61)
- ✅ PlainAndSimple 实局：`try_deploy_authoritative` 出战斗机，距机场中心 6.89 米、正前方，离地 y=4.1。建筑足迹只封到 +Z 4.0 米，门口没被自己的足迹挤走

## Related Files
- `source/match/utils/UnitPlacementUtils.gd`
- `source/match/units/traits/MovementObstacle.gd`
- `source/match/units/traits/ProductionQueue.gd`
- `source/match/units/OreRefinery.gd`
