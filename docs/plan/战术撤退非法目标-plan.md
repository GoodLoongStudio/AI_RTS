# 战术撤退非法目标 Implementation Plan

## Overview
按审核矩阵第 21 项建议「修正非法目标处理」：撤退只接受玩家明确指定的地面点，点单位不得悄悄取坐标或改成跟随。

## Current State Analysis
`_on_unit_targeted` 未处理撤退选目标，会落到普通右键单位逻辑。

## Implementation Strategy
与第 19 项强制移动相同：实体点击拒绝并保持 Targeting，地面点击才提交并退出。

## Implementation Steps
1. ✅ 撤退选目标时拒绝实体点击
2. ✅ HUD 冒烟补非法目标断言
3. ✅ 2026-08-24 已验收

## Timeline
本轮改完即验收。

## Risk Assessment
不改撤退执行语义和倒车降级，只改 Targeting 边界。

## Success Criteria
- 撤退中右键单位：不移动、不跟随，仍处于选目标，反馈为拒绝
- 随后右键地面：正常提交撤退

## Progress Tracking
✅ 控制器拒绝实体目标
✅ 冒烟测试
✅ 人工验收

## Related Files
- `source/match/players/human/UnitActionsController.gd`
- `tests/automated/TraditionalUnitCommandHudSmokeTest.gd`
