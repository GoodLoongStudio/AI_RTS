# 弹道可见性 Implementation Plan

## Overview
让现有投射物飞行过程肉眼可见；炮弹不再只靠几乎看不见的炮口粒子结算。

## Current State Analysis
坦克与对地炮塔用 `CannonShell`：只有 0.05 的粒子、没有弹体，飞行几乎看不出来。直升机与对空炮塔用 `Rocket`：弹体半径 0.02，偏小。战斗武器已是 `projectile`，工人/无人机没有武器。

## Implementation Strategy
炮弹改为沿瞄准点飞行的可见弹体 + 尾迹 + 轻微抛弧；火箭加大弹体和尾焰、略加长飞行时间。不改权威伤害快照与命中结算。

## Implementation Steps
1. 重写 CannonShell 视觉与飞行
2. 放大 Rocket 弹体与尾焰

## Timeline
单次改动。

## Risk Assessment
飞行变长会推迟扣血，冒烟测试已按秒级等待，应仍通过。技能即时伤害本步不改。

## Success Criteria
坦克开火能看到炮弹飞过去再掉血；火箭弹体和尾焰更明显。

## Progress Tracking
✓ 弹道可见性（待验收）

## Related Files
- `source/match/units/projectiles/CannonShell.gd`
- `source/match/units/projectiles/CannonShell.tscn`
- `source/match/units/projectiles/Rocket.tscn`
