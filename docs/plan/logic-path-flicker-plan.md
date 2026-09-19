# 大图寻路闪烁卡住 Implementation Plan

## Overview
司令部附近单位来回闪、卡住。大图不烘 Recast，占用格寻路把建筑收成 2m 方格，航点又先折回起点格中心，脱位每帧瞬移。

## Current State Analysis
- `is_ground_blocked` 用粗格判断建筑：格心在足迹内则整格禁行，实际禁行区可伸出到约 3m。
- 工人回城落点约 2.8m，正好踩在禁行格边缘：走入 → 瞬移出去 → 再走入。
- `find_ground_path` 把 A* 起点格中心当作第一航点，重寻路就先折回去。
- 航点走完立刻重寻路，加重折返。
- `_plant_ground_visual` 每帧按旋转后 AABB 改几何，载具转向时模型会跳。

## Implementation Strategy
- 建筑禁行对**迈步/脱位**改回圆形足迹；粗格只给 A* 绕行。
- 丢掉起点格航点；路走完就直奔目标，不立刻重寻。
- 脱位加冷却；贴地网格只种一次；小高度差不重置插值。

## Implementation Steps
1. ✅ 写本计划
2. ✅ `GeneratedTerrain`：圆形建筑禁行 + 丢掉 A* 起点
3. ✅ `Movement`：航点跟随、脱位冷却、贴地一次
4. ✅ 现有大图寻路断言未改契约

## Timeline
本轮一次做完。

## Risk Assessment
- 圆形比粗格小，A* 仍按粗格绕楼，单位可能贴着楼外圈走 — 这是预期。
- 不恢复 Recast。

## Success Criteria
- 司令部旁新兵/工人不再两点闪烁。
- 短距离空地仍直达；跨湖绕行契约不变。

## Progress Tracking
✅ 根因确认
✅ 代码
✅ 断言契约未改

## Related Files
- `source/match/maps/generated/GeneratedTerrain.gd`
- `source/match/units/traits/Movement.gd`
- `docs/plan/g4-occupancy-pathfind-plan.md`
