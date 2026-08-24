# 命令生命周期终态回传 Implementation Plan

## Overview
按审核矩阵第 25 项建议「补执行端到命令终态的可靠回传」。C# 订单枚举已齐，执行端要把 Arrived / Unreachable / TargetLost / Cancelled / UnitLost 真正写回订单。

## Current State Analysis
Accepted、InProgress、Cancelled、UnitLost、部分 Arrived / TargetLost 已有。`movement_finished` 一律当到达，导航结束但目标不可达时不会变成 `Unreachable`。

## Implementation Strategy
移动结束时由 Movement 判定 Arrived 或 Unreachable；CommandRuntime 按原因转订单终态。不在本项重做寻路或卡住检测。

## Implementation Steps
1. ✅ Movement 结束时给出到达/不可达原因
2. ✅ CommandRuntime 映射 Unreachable
3. ✅ 冒烟覆盖 Unreachable
4. ✅ 2026-08-24 已验收

## Timeline
本轮完成回传闭环，卡住振荡留给第 27/30 项。

## Risk Assessment
Godot 在最近可达点也会发 `navigation_finished`，必须用 `is_target_reachable()` 区分，避免把贴边停下误报成 Arrived。

## Success Criteria
- 可到达并走完：订单 `Arrived`
- 导航结束且目标不可达：订单 `Unreachable`
- 已有停止、替换、单位死亡终态不被破坏

## Progress Tracking
✅ Movement 原因
✅ Runtime 映射
✅ 测试
✅ 人工验收

## Related Files
- `source/match/units/traits/Movement.gd`
- `source/csharp/GodotAdapter/Composition/CommandRuntime.cs`
- `tests/automated/TankCommandBridgeSmokeTest.gd`
