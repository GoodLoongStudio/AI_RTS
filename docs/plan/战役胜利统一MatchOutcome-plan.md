# 战役胜利统一 MatchOutcome Implementation Plan

## Overview
按矩阵第 81 项建议「统一进入 MatchOutcome」：完成战役目标后不再由 `CampaignController` 自建「任务完成」层作为胜负源，改为一次性锁定 `Won`，由现有 `MatchEndHandler` 显示 Victory。

## Current State Analysis
撤离按钮走 `_show_result()`，叠一层 `CampaignResult`。敌军通常仍存活，`LastSurvivingSideRule` 不会自然判胜。必须有显式终局入口。

## Implementation Strategy
在 `MatchOutcomeService` 增加一次性 `ResolveExplicit`；`MatchOutcomeRuntime.DeclareCampaignVictory()` 把本机 Human 阵营写成胜方并发布 `MatchResolved`。战役脚本只触发该入口。Runtime 未初始化时才回退旧 overlay。

## Implementation Steps
1. ✅ 领域服务显式终局
2. ✅ 战役撤离接入 DeclareCampaignVictory
3. ✅ 核心测试与冒烟
4. ✅ 已验收

## Timeline
本轮只做战役胜利进统一 Outcome。战役失败、结算文案数据源、重开留 82–85。

## Risk Assessment
若 `handle_match_end` 关闭则不会初始化 Runtime，需保留 overlay 回退。胜利后树会暂停，测试必须恢复再释放。

## Success Criteria
- 敌军仍在时撤离也能 `Won`
- 本机阵营在 `winning_side_ids` 中
- 不再叠 `CampaignResult`（默认 Feature Flag）
- `MatchEndHandler` 显示 Victory
- 终态不可被后续歼灭评估改写

## Progress Tracking
✅ 服务与 Runtime
✅ 战役接入
✅ 测试
✅ 人工验收

## Related Files
- `source/csharp/Application/Match/MatchOutcomeContracts.cs`
- `source/csharp/Application/Match/MatchOutcomeService.cs`
- `source/csharp/GodotAdapter/Match/MatchOutcomeRuntime.cs`
- `source/campaign/CampaignController.gd`
- `tests/core/MatchOutcomeServiceTests.cs`
- `tests/automated/MatchOutcomeRuntimeSmokeTest.gd`
- `tests/automated/CampaignSmokeTest.gd`
