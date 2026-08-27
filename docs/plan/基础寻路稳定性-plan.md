# 基础寻路稳定性 Implementation Plan

## Overview
按审核矩阵第 27 项建议「不重构，重点提高稳定性」：保持 `LegacyMovementPort` + 现有 Navigation，收敛卡住、贴边踱步和反复横移。

## Current State Analysis
卡住侧移没有次数上限，狭缝和建筑 footprint 外会左右反复走，订单长期停在 InProgress。

## Implementation Strategy
在 `Movement.gd` 增加脱困次数上限、无进展超时和方向翻转检测；超限后停止并回传 `Unreachable`。不改 Domain 命令契约，不重写寻路。

## Implementation Steps
1. ✅ 脱困上限与振荡/无进展收敛
2. ✅ 稳定性冒烟
3. ✅ 2026-08-24 已验收

## Timeline
本轮只做单单位稳定收敛。拥挤窄路留给第 29 项。

## Risk Assessment
脱困过早结束可能把短暂拥挤判成不可达。阈值按约 3 次侧移和 3 秒无进展设置。

## Success Criteria
- 空地短距离移动仍能到达
- 冲进建筑占地后应停下，不再长时间踱步
- 订单变为 Unreachable 或 Arrived，不长期 InProgress

## Progress Tracking
✅ Movement 收敛
✅ 冒烟测试
✅ 人工验收

## Related Files
- `source/match/units/traits/Movement.gd`
- `tests/automated/NavigationStabilitySmokeTest.gd`
