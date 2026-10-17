# 每局战报都要记下来

## Overview
每一把对局结束时都留下一份真实战报：时长、本方生产与建造、本方损失、打出的伤害与承受的伤害、采集与消耗。开局还没双方建筑时，不得立刻判胜并写成 0 秒空报告。

## Current State Analysis
`MR-20261012231121-local-20261012231121-1` 在 `2026-10-12T23:11:21` 同一秒写成，时长 0。时间线只有「记录器已挂载」。

两条断点叠在一起：

1. `MatchOutcomeRuntime.Initialize` 在 `match_started` 之前调用 `StartMatch()`。此时若有一方还没有计入胜负的建造建筑，`LastSurvivingSideRule` 会把另一方判胜。`MatchHistoryHook` 发现记录器还不存在，就当场建档并收尾，然后再被延迟的 `match_started` 另开一个记录器。玩家看到的是那份 0 秒胜利。
2. 记录器即使活过整局，也只订了生产、建造、死亡和资源不足。伤害金额、击杀归属、采集与消耗没有订阅，所以这些格子一直是「—」。死亡信号不区分敌我，敌方阵亡会被算进「单位损失」。

## Implementation Strategy
- 胜负服务增加「尚未登场」：参战方还没有过任何计入建筑时，歼灭规则的终局改回进行中。双方都曾有过计入建筑之后，清空建筑仍按原规则判胜负。
- 记录钩子：胜负早于建档时先记住结果，等这一局的记录器挂上再收尾，只落一份。找不到对局根时，再按 `match_root` 组找。
- 记录器：收局时用已累计的模拟时长；订阅余额变化（按原因记采集/消耗/退款）、`unit_damaged`（伤害金额与来源玩家）、只把本方单位算进生产/建造/损失，本方伤害击杀才算敌方击杀。

## Implementation Steps
- [x] 写本计划
- [x] 胜负服务：未登场不算被歼灭，并补 C# 回归（16 项，0 失败）
- [x] 记录钩子：早到的结算并进同一份报告；对局根可从组里找到
- [x] 记录器：时长、经济、伤害、敌我归属
- [x] 投射物结算把伤害金额和来源玩家放进 `damage_presentation`
- [x] 跑胜负回归与战报钩子冒烟（钩子冒烟 0 失败）

## Timeline
一次改完上述接线。不回填已经写成的 0 秒报告。

## Risk Assessment
- 某一方开局始终没有建造建筑时，这局不会自动判胜，要等玩家退出才收成中止报告。这比开局 0 秒假胜利更接近「这一把还在打」。
- 没有来源玩家的伤害只记承受、不记为击杀，避免把不明掉血写成战功。
- 成长赠款和初始余额不是采集，不进「总采集」。

## Success Criteria
- 一方有建筑、另一方还没有时，`StartMatch` 保持进行中；后者建筑被清空后才判胜。
- 胜利信号早于 `match_started` 时只落 1 份报告，且不会再挂一个空转记录器。
- 本方生产会计入，敌方生产不计入；带金额的本方受伤计入承受伤害。

## Progress Tracking
- ✅ 计划
- ✅ 实现
- ✅ 回归：胜负服务 16 项 0 失败；战报钩子冒烟 0 失败

## Related Files
- `source/csharp/Application/Match/MatchOutcomeService.cs`
- `tests/core/MatchOutcomeServiceTests.cs`
- `source/history/MatchHistoryHook.gd`
- `source/history/MatchReportRecorder.gd`
- `source/csharp/GodotAdapter/Combat/ProjectileRuntime.cs`
- `source/match/Match.gd`
- `tests/automated/MatchHistoryHookSmokeTest.gd`
