# 战役失败统一 MatchOutcome Implementation Plan

## Overview
按矩阵第 82 项建议「接统一 MatchOutcome」：战役失败目标产生 Defeat，不再缺结算链。本轮只接通失败入口和第一关已有失败事实（先锋英雄死亡）。

## Current State Analysis
第 81 项已把胜利锁进 Outcome。失败仍没有对称入口；歼灭规则在英雄死后可能碰巧判敌胜，但战役脚本不主动锁定，也不保证走 Defeat 面板。

## Implementation Strategy
`DeclareCampaignDefeat()` 把非本机阵营写成胜方。`CampaignController` 在英雄 `unit_died` 时调用。通用「任务失败条件」仍属第 78 项，本轮不新建条件类型。

## Implementation Steps
1. ✅ Runtime 失败入口
2. ✅ 英雄死亡接入
3. ✅ 核心测试与冒烟
4. ✅ 已验收

## Timeline
本轮只做失败进统一 Defeat。结果锁定复用、结算文案、重开留 83–85。

## Risk Assessment
英雄死亡信号在离树前发出，应先于歼灭评估锁定，避免和后续 `tree_exited` 抢写。胜利已锁定后忽略失败。

## Success Criteria
- 敌军仍在时宣告失败也是 Defeat
- 本机阵营不在 `winning_side_ids`
- `MatchEndHandler` 显示 Defeat
- 终态只锁一次

## Progress Tracking
✅ 服务与 Runtime
✅ 战役接入
✅ 测试
✅ 人工验收

## Related Files
- `source/csharp/GodotAdapter/Match/MatchOutcomeRuntime.cs`
- `source/campaign/CampaignController.gd`
- `tests/core/MatchOutcomeServiceTests.cs`
- `tests/automated/MatchOutcomeRuntimeSmokeTest.gd`
- `tests/automated/CampaignSmokeTest.gd`
