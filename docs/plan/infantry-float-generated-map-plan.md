# 单机图步兵浮空 Implementation Plan

## Overview
单机生成图上步兵脚底离开沙面。载具/建筑看起来更贴地。把单位原点钉在高度场，并把步兵视觉脚底落到原点平面。

## Current State Analysis
- 生成图跳过 Recast，高度靠 `sample_world_height`。
- 出生点作者 Y 约 3.8m；生产落点先被压成 Y=0。
- `Infantry_native_v3` 原点在脚底，但出生/插值/Idle 后视觉最低点仍可能高于原点。
- `_snap_logic_height` 改 Y 后没有 `reset_physics_interpolation`。

## Implementation Strategy
出场先入树再写世界坐标并贴地。逻辑地形每帧按高度场钉 Y。步兵 Idle 后按脚骨把 Geometry 落到原点。

## Implementation Steps
1. 本计划
2. 出场与移动贴地
3. 步兵视觉落脚

## Timeline
本轮完成。

## Risk Assessment
- 只在脚底明显高于原点时下移 Geometry，避免埋进地里。
- 矿点/载具不改视觉偏移。

## Success Criteria
- 单机生成图步兵站立、走动脚底贴沙
- 载具、建筑、工人回城不受影响

## Progress Tracking
- ✅ 计划
- ✅ 贴地
- ✅ 步兵落脚
- ✅ 出场不再先出现在原点
- ✅ 不再把单位吸到桥板/原点
- ✅ 站定每帧按 Toes/Ball 钉脚；载具每帧按 AABB 贴地
- ✅ 运输车去掉悬停抬高，右键点地靠近即登车

## Related Files
- `source/match/Match.gd`
- `source/match/units/traits/Movement.gd`
- `source/match/units/InfantryAnimationDriver.gd`
