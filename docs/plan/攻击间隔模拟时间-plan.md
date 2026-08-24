# 攻击间隔模拟时间 Implementation Plan

## Overview
按矩阵第 36 项「时间源需要统一」和第 88 项「改统一战局模拟时间」，把攻击间隔从墙钟改为受暂停冻结的战局时钟。

## Current State Analysis
`AttackingWhileInRange` 与地面强制攻击用 `Time.get_ticks_msec()`。暂停时 Timer 会停，但冷却时间戳仍按真实时间流逝，恢复后会立刻开火。

## Implementation Strategy
Match 增加只在 `_physics_process` 推进的 `SimulationClock`。攻击冷却读写该时钟。战役计时（第 89 项）本轮不动。

## Implementation Steps
1. ✅ 战局时钟
2. ✅ 两处攻击间隔改用模拟时间
3. ✅ 暂停冒烟
4. ✅ 2026-08-24 已验收

## Timeline
本轮完成攻击时间。战役任务计时另做第 89 项。

## Risk Assessment
时钟挂在 Match 上，测试场景需实例化完整 Match。

## Success Criteria
- 暂停期间模拟毫秒不增加
- 攻击间隔剩余时间在暂停后保持
- 恢复后从剩余间隔继续，不会因墙钟立刻开火

## Progress Tracking
✅ 时钟与攻击改写
✅ 测试
✅ 人工验收

## Related Files
- `source/match/SimulationClock.gd`
- `source/match/Match.gd`
- `source/match/units/actions/AttackingWhileInRange.gd`
- `source/match/units/actions/ExplicitGroundForceAttacking.gd`
