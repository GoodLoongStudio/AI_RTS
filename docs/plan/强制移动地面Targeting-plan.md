# 强制移动地面 Targeting Implementation Plan

## Overview
按审核矩阵第 19 项，强制移动只接受地面目标。点单位或建筑不再把实体坐标当成落点。

## Current State Analysis
`UnitActionsController._on_unit_targeted` 在 ForceMove 选目标时会用实体表面坐标提交命令。这和策划「右键地面」以及 HUD「请右键地面指定强制移动目标」不一致。

## Implementation Strategy
实体点击只拒绝、不消费 Targeting。地面点击仍提交 `ForceMove`。不改命令服务本身。

## Implementation Steps
1. ✅ 点单位时拒绝强制移动并保持选目标
2. ✅ 更新实体 ForceMove 冒烟测试
3. ✅ 2026-08-24 已验收

## Timeline
本轮完成代码与测试，验收通过后关闭第 19 项。

## Risk Assessment
旧验收 CMD-029 允许点建筑当位置。本项按矩阵覆盖该行为。

## Success Criteria
- 强制移动中右键单位：不移动、不攻击、仍处于选目标
- 随后右键地面：正常提交强制移动

## Progress Tracking
✅ 控制器拒绝实体目标
✅ 冒烟测试改写
✅ 人工验收

## Related Files
- `source/match/players/human/UnitActionsController.gd`
- `tests/automated/EntityForceMoveSmokeTest.gd`
- `docs/plan/基础功能完善清单.md`
