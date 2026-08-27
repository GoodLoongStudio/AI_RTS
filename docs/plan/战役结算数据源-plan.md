# 战役结算数据源 Implementation Plan

## Overview
按矩阵第 84 项建议「UI 可保留，数据源统一」：成功/失败和任务结果仍显示在统一结算面板里，文案只读 `MatchOutcome` 快照，不再由战役脚本自行判定胜负。

## Current State Analysis
胜负已进 Outcome，但战役详细结果还写死在 `_show_result`，默认路径又不展示。MatchEndHandler 只有 Victory / Defeat 色块，没有任务结果。

## Implementation Strategy
快照增加 `local_result`。MatchEndHandler 用该字段切面板，并向 `CampaignController.BuildSettlementText` 取任务文案。战役 overlay 只在 Runtime 不可用时回退，且同样按快照写。

## Implementation Steps
1. ✅ 快照增加 local_result
2. ✅ Handler 展示战役摘要
3. ✅ 冒烟改认统一面板数据
4. ✅ 已验收

## Timeline
本轮不做重开（85）和下一任务入口。

## Risk Assessment
非战役对局不得出现战役摘要。结算文案不得反向改写 Outcome。

## Success Criteria
- 胜利可见「任务结果：成功」，且 `local_result=Victory`
- 失败可见「任务结果：失败」，且 `local_result=Defeat`
- 仍只有一张结算层，没有第二套胜负源

## Progress Tracking
✅ Runtime / Handler / Campaign
✅ 测试
✅ 人工验收

## Related Files
- `source/csharp/GodotAdapter/Match/MatchOutcomeRuntime.cs`
- `source/match/handlers/MatchEndHandler.gd`
- `source/match/handlers/MatchEndHandler.tscn`
- `source/campaign/CampaignController.gd`
- `tests/automated/CampaignSmokeTest.gd`
- `tests/automated/MatchOutcomeRuntimeSmokeTest.gd`
