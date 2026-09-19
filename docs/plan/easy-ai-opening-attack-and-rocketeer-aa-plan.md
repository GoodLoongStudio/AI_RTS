# 简单 AI 开局进攻 + 炮兵对空 Implementation Plan

## Overview
简单档电脑开局就出兵进攻，不再空等四分钟。步兵里的炮兵（火箭兵）武器改为对地+对空。

## Current State Analysis
简单档 `first_wave_delay_s = 240`，这段时间不生产作战单位。编组必须满 4 人才出击。炮兵 `rocket_launcher` 的 `targetDomains` 只有 `terrain`。

## Implementation Strategy
1. 简单档第一波延迟改为 0，满 2 人即可出击。
2. `rocket_launcher` 增加 `air`。
3. 简单档兵营兼产少量炮兵，编组里带上对空。

## Implementation Steps
1. 本计划
2. 简单档出击节奏
3. 炮兵对空
4. 简单档产炮兵入编

## Timeline
本轮只改简单档节奏与炮兵域，不改中等/困难延迟。

## Risk Assessment
开局两名步兵就推，仍比中等弱（编制 2×4、重型上限 1）。炮兵对空后玩家飞机要避开火箭兵。

## Success Criteria
- 简单档开局即生产并在凑齐 2 人后出击
- 炮兵武器可锁定空中单位
- 简单档编组能带上炮兵

## Progress Tracking
- ✅ 计划
- ✅ 出击节奏
- ✅ 炮兵对空
- ✅ 产炮兵

## Related Files
- `source/match/players/simple-clairvoyant-ai/SimpleClairvoyantAI.gd`
- `source/match/players/simple-clairvoyant-ai/OffenseController.gd`
- `source/match/players/simple-clairvoyant-ai/AutoAttackingBattlegroup.gd`
- `config/balance/demo.balance.v1.json`
- `config/balance/adjutant-e2e.balance.v1.json`
