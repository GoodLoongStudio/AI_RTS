# 战斗手感与弹道 Implementation Plan

## Overview
拉开射程、提高单发可读伤害，并让飞行时间随距离变化，使弹道和交火一眼能看懂。

## Current State Analysis
坦克/直升机射程 5m，伤害 1～2，炮弹固定飞 0.5 秒。近距离对打像瞬发，血条变化慢。

## Implementation Strategy
只改 Demo 平衡表和投射物飞行时间，不改伤害公式。镜头略加快，贴边规则保持现状。

## Implementation Steps
1. 武器射程与伤害上调
2. 炮弹/火箭按距离计算飞行时间
3. 同步 Catalog / 冒烟断言

## Timeline
单次改动。

## Risk Assessment
冒烟里写死了旧射程和伤害，必须一起改。飞行变长后生命周期测试仍按秒级等待。

## Success Criteria
坦克对打能看到炮弹飞一段再掉血；几发内能看清血条下降。

## Progress Tracking
✅ 武器射程与伤害上调
✅ 炮弹/火箭按距离计算飞行时间
✅ 同步 Catalog / 冒烟断言
✓ 进对局肉眼验收（待用户）

## Related Files
- `config/balance/demo.balance.v1.json`
- `source/match/units/projectiles/CannonShell.gd`
- `source/match/units/projectiles/Rocket.gd`
- `source/Globals.gd`
- `tests/core/BalanceConfigLoaderTests.cs`
- `tests/automated/BalanceConfigRuntimeSmokeTest.gd`
- `tests/automated/ProjectileLifecycleSmokeTest.gd`
