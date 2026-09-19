# 锁 30 帧 + 单人单位穿建筑 Implementation Plan

## Overview
渲染锁 30 帧减轻负载。生成图不烘 Recast，建筑未进逻辑寻路，地面单位会穿模。

## Current State Analysis
- 默认与 `project.godot` 已改为 30；旧 `user://performance.cfg` 的 60/50 会迁到 30/24。
- 256 图跳过 Recast：建筑 `MovementObstacle` 现登记障碍组并盖路径格。

## Implementation Strategy
锁帧 + 治理器门槛。逻辑地形把建筑足迹打进 `AStarGrid2D`，移动逐步与落点推出建筑圈。

## Implementation Steps
1. 锁 30 帧与治理器门槛
2. MovementObstacle 在逻辑地形登记并盖路径格
3. GeneratedTerrain 建筑格不可走
4. Movement 落点/步进推出建筑

## Timeline
本轮完成。

## Risk Assessment
- 路径格过狠会让工人贴不上基地：足迹用 0.85 半径，外圈可走。
- 矿点不盖格，避免采不到。

## Success Criteria
- 右上角 FPS 上限约 30，不因 30 帧掉到最低画质
- 单人生成图工人/坦克绕开指挥中心与兵营，不从模型中间穿过

## Progress Tracking
- ✅ 锁 30 帧
- ✅ 穿模

## Related Files
- `source/PerformanceGovernor.gd`
- `project.godot`
- `source/match/units/traits/MovementObstacle.gd`
- `source/match/units/traits/Movement.gd`
- `source/match/maps/generated/GeneratedTerrain.gd`
