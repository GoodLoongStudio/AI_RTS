# 单位死亡后续清理 Implementation Plan

## Overview
按矩阵第 43 项建议「验收后续清理」：死亡后选择、编队、自身订单和战斗目标必须失效。

## Current State Analysis
死亡链已有。选中单位死亡时不一定发 `unit_deselected`。编队、订单、攻击目标已有退出订阅，缺端到端验收。

## Implementation Strategy
死亡时先 `deselect` 再 `unit_died`。增加覆盖选择、控制组、UnitLost、TargetLost 的冒烟。

## Implementation Steps
1. ✅ 死亡前取消选择
2. ✅ 端到端冒烟
3. ✅ 2026-08-24 已验收

## Timeline
本轮只做死亡后续清理验收。AI 副官引用留给第 44 项。

## Risk Assessment
死亡信号仍在离树前发出，不影响 Space 跳转坐标。

## Success Criteria
- 死亡单位离开 selected_units 并发出取消选择
- 控制组召回不再包含死者
- 死者活动订单为 UnitLost
- 以其为攻击目标的订单为 TargetLost

## Progress Tracking
✅ 死亡前取消选择
✅ 冒烟测试
✅ 人工验收

## Related Files
- `source/match/units/Unit.gd`
- `tests/automated/DeathCleanupSmokeTest.gd`
