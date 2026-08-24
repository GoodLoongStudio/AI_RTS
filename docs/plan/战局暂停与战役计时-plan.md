# 战局暂停与战役计时 Implementation Plan

## Overview
按矩阵第 87、88、89 项：暂停后单位、战斗、AI、任务停止推进；攻击间隔与战役计时都走 `SimulationClock`。第 88 项此前已验收，本轮复核并补 87 / 89。

## Current State Analysis
`get_tree().paused` 已冻结大部分 `_physics_process`。攻击冷却已用模拟时钟。战役结算虽读 `get_simulation_msec()`，但起点仍是墙钟，简报/读信标 `create_timer` 默认 `process_always=true`，暂停时任务时间仍会走。

## Implementation Strategy
战役起点改为模拟毫秒；任务等待改为不在暂停时推进的 timer。冒烟同时验时钟、单位位置和任务经过时间。Input / 菜单 / 语音保持 ALWAYS。

## Implementation Steps
1. ✅ 战役计时改模拟时钟
2. ✅ 任务 timer 吃暂停
3. ✅ 暂停冒烟覆盖单位与任务时间
4. ⏳ 待人工验收（87–89）
5. ✓ 游玩反馈：警戒步骤只认 AI HUD、撤离点无标记、简报误导边缘滚屏 — 已修

## Timeline
本轮完成 87–89。坚守时间通用条件仍属第 75 项。

## Risk Assessment
菜单、输入、结算层必须继续 ALWAYS，否则 F10 / 重开会失效。

## Success Criteria
- 暂停时模拟时钟、单位位置、战役经过时间都不增加
- 恢复后三者继续
- 攻击间隔剩余时间在暂停期间不变（88 回归）

## Progress Tracking
✅ 战役时间源
✅ 暂停审计与测试
⏳ 人工验收

## Related Files
- `source/campaign/CampaignController.gd`
- `source/match/SimulationClock.gd`
- `source/match/Match.gd`
- `tests/automated/AttackSimulationTimeSmokeTest.gd`
- `tests/automated/CampaignSmokeTest.gd`
