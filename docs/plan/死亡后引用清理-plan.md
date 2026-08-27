# 死亡后引用清理 Implementation Plan

## Overview
按矩阵第 44 项建议「做完整端到端验收」：命令、选择、编队、战斗目标、镜头跟随、AI 小队和 Query 在单位死亡后都不再指向死者。

## Current State Analysis
第 43 项已覆盖选择、控制组和订单终态。镜头跟随、AI 小队组和命令注册表仍可能短暂留着失效引用。

## Implementation Strategy
死亡时移除 AI 小队组；命令运行时注销稳定 ID；镜头和 AI HUD 在 `unit_died` 时解除跟随。用同一条冒烟把 Query 也验上。

## Implementation Steps
1. ✅ 注册表注销、跟随解除、小队组移除
2. ✅ 端到端冒烟扩展
3. ✅ 已验收

## Timeline
本轮做引用失效。不重做 AI 副官命令链。

## Risk Assessment
`unit_died` 仍在离树前发出，注销后同一帧不应再对该 ID 下新命令。

## Success Criteria
- 跟随目标死亡后镜头不再锁它
- `HasLiveRuntimeUnit` 为假
- `legacy_ai_squad_*` 与 GetOwnForces 不再包含死者

## Progress Tracking
✅ 清理入口
✅ 测试
✅ 人工验收

## Related Files
- `source/match/units/Unit.gd`
- `source/csharp/GodotAdapter/Composition/CommandRuntime.cs`
- `source/match/IsometricCamera3D.gd`
- `source/match/hud/AICommandHUD.gd`
- `tests/automated/DeathCleanupSmokeTest.gd`
