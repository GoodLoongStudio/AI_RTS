# 命令栏显示快捷键 Implementation Plan

## Overview
在底部传统单位命令栏按钮上显示当前键位，方便对照 `C/R/F/G/X/Z` 操作。

## Current State Analysis
按钮只有中文名。正式键位在 `InputBindingRuntime.GetBinding`，面板没有读出来。

## Implementation Strategy
按钮文案写成「名称 [键]」。无键位的按钮保持原名。选目标时的「取消…」同样带键。

## Implementation Steps
1. ✅ HUD 从 Runtime 读键并刷新文案
2. ✅ 更新冒烟断言
3. ⏳ 待人工验收

## Timeline
只改展示，不改按键语义。

## Risk Assessment
「停止移动」是 Halt，完整停止是 F，不能把 F 标在 Halt 上以免点按和按键不一致。

## Success Criteria
- 强制移动 [C]、移动并攻击 [R]、强制攻击 [X]、撤退 [Z]、固守 [G]
- 无官方键的按钮不编造快捷键

## Progress Tracking
✅ 展示
✅ 测试
⏳ 人工验收

## Related Files
- `source/match/hud/TraditionalUnitCommandHUD.gd`
- `tests/automated/TraditionalUnitCommandHudSmokeTest.gd`
