# 战役重开本关 Implementation Plan

## Overview
按矩阵第 85 项建议「统一 Restart 当前战役」：结算增加重开本关，用当前任务初始配置重新进战斗，不沿用已锁定的战局现场。

## Current State Analysis
结算只有离开。`CampaignMenu` 用 Loading 进关，但结束面板没有复用这条链路。暂停未解除时 Loading 的 `await physics_frame` 会卡住。

## Implementation Strategy
抽出 `CampaignFlow`：按任务初始数据重建 settings 并走 Loading。MatchEndHandler 战役结算显示「重开本关」；回退 overlay 同样提供。普通对局不出现该按钮。

## Implementation Steps
1. ✅ CampaignFlow 重载入口
2. ✅ 结算按钮
3. ✅ 冒烟：锁定后重开为新的 InProgress
4. ✅ 已验收

## Timeline
本轮只做当前战役重开。下一任务解锁不在本项。

## Risk Assessment
必须先取消暂停再进 Loading。重开必须释放旧 Match，避免双 Runtime 订阅全局信号。

## Success Criteria
- 胜利/失败结算都有「重开本关」
- 重开后 Outcome 为 InProgress，且有新的 CampaignController
- 普通对局没有该按钮

## Progress Tracking
✅ Flow 与 UI
✅ 测试
✅ 人工验收

## Related Files
- `source/campaign/CampaignFlow.gd`
- `source/campaign/CampaignMenu.gd`
- `source/campaign/CampaignController.gd`
- `source/match/handlers/MatchEndHandler.gd`
- `source/match/handlers/MatchEndHandler.tscn`
- `tests/automated/CampaignSmokeTest.gd`
- `tests/automated/MatchOutcomeRuntimeSmokeTest.gd`
