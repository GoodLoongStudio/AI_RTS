# 镜头地图边界（256 图推不过去）Implementation Plan

## Overview
大地图上镜头停在画面左下/出生点附近，右边小地图和部队都表明还有可走空间，却推不过去。

## Current State Analysis
- `Match.tscn` 镜头默认包围面是 50×50（旧手做图）。
- `_recalculate_camera_bounding_planes` 用 `bounding_planes[i] = …` 改导出的 `Array[Plane]`，Godot 可能拿到副本，赋值不回写，大图仍卡在 x/z≤50。
- 右侧指挥栏约 288px 盖住窗口右缘；贴边滚屏先判 HUD 再判边缘，鼠标贴右边永远滚不动。

## Implementation Strategy
在镜头上整表写回包围面（含 Map 缩放后的世界米）。贴边条带优先于 HUD 拦截。

## Implementation Steps
1. `IsometricCamera3D.set_map_bounds` 整表赋值包围面
2. 贴边滚屏：窗口边缘条带即使在侧栏/副官面板上也能滚
3. 冒烟：写 256 边界后 `bounding_planes[1].d` 必须是 -256

## Timeline
本轮修完。

## Risk Assessment
- 整表赋值若漏调用，仍停在 50
- 贴边条带在侧栏最外沿会一边悬停一边滚，与主流 RTS 一致

## Success Criteria
- 256 图可推到东/南侧出生点一带
- 鼠标贴窗口右缘能向右滚屏
- 镜头冒烟 0 failure

## Progress Tracking
- ✅ 整表写回包围面
- ✅ 贴边滚屏
- ✅ 冒烟（含 256 边界写回）

## Related Files
- `source/match/IsometricCamera3D.gd`
- `source/match/Match.gd`
- `tests/automated/BattlefieldEventCameraSmokeTest.gd`
