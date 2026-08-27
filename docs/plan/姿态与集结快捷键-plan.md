# 姿态与集结快捷键 Implementation Plan

## Overview
给命令栏「侵略 / 警戒 / 停火 / 清除集结」补官方默认键，并显示在按钮上。

## Current State Analysis
这四项目前是 ButtonOnly 或未建动作。固守已有 G。停止移动仍不绑键，避免和 F 完整停止混淆。

## Implementation Strategy
默认：T 侵略、Y 警戒、H 停火、B 清除集结。HUD 复用现有按钮入口，文案带 `[键]`。

## Implementation Steps
1. ✅ 默认绑定与 clear_rally 动作
2. ✅ HUD 监听并展示
3. ✅ 核心测试与冒烟
4. ⏳ 待人工验收

## Timeline
只补这四键。不给停止移动绑键。

## Risk Assessment
T/Y/H/B 不与现有单位命令、镜头、编组冲突。语音 V 仍空着。

## Success Criteria
- 四键能驱动对应按钮逻辑
- 面板显示 [T] [Y] [H] [B]
- unit.halt 仍无玩家键

## Progress Tracking
✅ 绑定
✅ HUD
✅ 测试
⏳ 人工验收

## Related Files
- `source/csharp/Application/Input/DefaultInputBindings.cs`
- `source/match/hud/TraditionalUnitCommandHUD.gd`
- `tests/core/InputBindingServiceTests.cs`
- `tests/automated/TraditionalUnitCommandHudSmokeTest.gd`
