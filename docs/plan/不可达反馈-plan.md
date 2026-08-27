# 不可达反馈 Implementation Plan

## Overview
按审核矩阵第 30 项建议「必须补齐」：不可达不但要写入订单终态，还要让玩家和 AI 能读到明确结果。

## Current State Analysis
第 25/27 项已把执行端回传成 `Unreachable`。传统 HUD 只显示即时接受数，AI 也没有最近终态查询。

## Implementation Strategy
订单终态变化时：Human 控制器转成命令反馈；HUD 显示「无法到达目标」；Gateway 提供 `GetLastTerminalOrder`。

## Implementation Steps
1. ✅ 终态缓存与查询
2. ✅ HUD 明确文案
3. ✅ 冒烟覆盖
4. ✅ 2026-08-24 已验收

## Timeline
本轮只补结果通道，不再改寻路。

## Risk Assessment
不可达反馈可能覆盖正在进行的选目标提示。仅在真正进入 Unreachable 时显示。

## Success Criteria
- `GetOrderState` / `GetLastTerminalOrder` 为 Unreachable
- 传统命令栏出现「无法到达目标」

## Progress Tracking
✅ 查询与 HUD
✅ 测试
✅ 人工验收

## Related Files
- `source/csharp/GodotAdapter/Composition/CommandRuntime.cs`
- `source/match/players/human/UnitActionsController.gd`
- `source/match/hud/TraditionalUnitCommandHUD.gd`
- `tests/automated/TankCommandBridgeSmokeTest.gd`
