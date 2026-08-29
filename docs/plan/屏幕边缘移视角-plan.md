# 屏幕边缘移视角 Implementation Plan

## Overview
启用已有的屏幕边缘滚屏：鼠标移到屏幕四边时镜头平移，与 WASD 共用同一套移动路径。

## Current State Analysis
`IsometricCamera3D` 已实现边缘检测与平滑移动，但 `FeatureFlags.enable_edge_scroll` 与默认 `edge_scroll_enabled` 均为 false，Demo 运行时不会贴边移动。

## Implementation Strategy
打开功能开关并改默认值为开启；设置面板可关闭。不新建第二套镜头系统。

## Implementation Steps
1. 打开 Feature Flag 与 Globals 默认
2. 更新设置文案与战役冒烟断言

## Timeline
单次改动。

## Risk Assessment
用户本地若已有 `user://camera.cfg` 且写了关闭，仍会保持关闭，需在设置里勾选。跟随英雄时边缘移动仍被抑制（原设计）。

## Success Criteria
对局中鼠标贴边镜头移动；设置可关；WASD 仍可用。

## Progress Tracking
✓ 打开边缘滚屏默认（待验收）

## Related Files
- `source/FeatureFlags.gd`
- `source/Globals.gd`
- `source/match/IsometricCamera3D.gd`
- `source/main-menu/Options.gd`
- `tests/automated/CampaignSmokeTest.gd`
