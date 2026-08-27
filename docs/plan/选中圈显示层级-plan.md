# 选中圈显示层级 Implementation Plan

## Overview
选中绿圈不再被地面雾、战争迷雾或贴地网格挡住。

## Current State Analysis
选中圈是贴地 `PlaneMesh`，`render_priority = 1`。战争迷雾全屏叠层是 `2`，高度雾是 `0`。迷雾圆形可见区在镜头下看起来像中间隆起的球，会盖住绿圈。血条已 `no_depth_test`，所以仍能看见。

## Implementation Strategy
地面标记圈关闭深度测试且不写深度，并把绘制优先级提到迷雾之上、点击特效之下。

## Implementation Steps
1. ✅ 圈 shader：`depth_test_disabled` + `depth_draw_never`
2. ✅ Selection / Highlight / Targetability 优先级改为 10
3. ✅ 2026-08-25 已人工验收
4. ✅ 点击绿圈：关闭深度测试并抬高，避免被路面挡住

## Timeline
只改地面圈显示，不改选中逻辑。

## Risk Assessment
绿圈会透过建筑/岩石显示，这是 RTS 常规做法。

## Success Criteria
- 坦克在可见区中心或贴着“球形”边缘时，绿圈完整
- 血条、点击地面特效不受影响

## Progress Tracking
✅ Shader
✅ 优先级
✅ 人工验收

## Related Files
- `source/shaders/3d/faded_circle.gdshader`
- `source/shaders/3d/circle.gdshader`
- `source/match/units/traits/Selection.tscn`
- `source/match/units/traits/Highlight.tscn`
- `source/match/units/traits/Targetability.tscn`
- `source/generic-scenes-and-nodes/3d/MouseClickAnimation3D.tscn`
- `source/match/utils/MouseClickAnimation.tscn`
