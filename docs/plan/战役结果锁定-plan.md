# 战役结果锁定 Implementation Plan

## Overview
按矩阵第 83 项建议「Campaign 共用它」：最终结果只能产生一次。战役不再用本地 `_resolved` 或自建 overlay 做第二次结算，只认 `MatchOutcome` 终态。

## Current State Analysis
普通对局已有一次性终局。战役仍有 `_resolved`，且 `Declare*` 失败时会回退弹出 `CampaignResult`。歼灭先锁定后点撤离，会叠第二层结算。

## Implementation Strategy
`IsOutcomeLocked()` 作为唯一门闩。撤离 / 英雄死亡 / 任务推进先问 Outcome。Runtime 可用时即使宣告失败也不再弹战役层。本地 overlay 只留给 Runtime 未初始化。

## Implementation Steps
1. ✅ Runtime 暴露锁定查询
2. ✅ Campaign 去掉平行锁
3. ✅ 冒烟：胜利后再失败不得改写
4. ✅ 已验收

## Timeline
本轮只做一次锁定。结算文案数据源和第 85 项重开不在本项。

## Risk Assessment
`handle_match_end` 关闭时 Runtime 未初始化，仍需本地 overlay，且本地也只能出一次。

## Success Criteria
- 胜利后撤离 / 英雄死亡不改 `kind` / `version`
- 失败后撤离不改结果、不出 Victory
- 默认路径没有第二张 `CampaignResult`

## Progress Tracking
✅ Runtime 与 Campaign
✅ 测试
✅ 人工验收

## Related Files
- `source/csharp/GodotAdapter/Match/MatchOutcomeRuntime.cs`
- `source/campaign/CampaignController.gd`
- `tests/core/MatchOutcomeServiceTests.cs`
- `tests/automated/MatchOutcomeRuntimeSmokeTest.gd`
- `tests/automated/CampaignSmokeTest.gd`
