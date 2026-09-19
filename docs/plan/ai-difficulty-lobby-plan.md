# 大厅电脑 AI：简单 / 中等 / 困难 Implementation Plan

## Overview
单机对局槽位把「Simple AI」拆成简单、中等、困难三档，并写进已有 `SimpleClairvoyantAI.Difficulty`。

## Current State Analysis
规则 AI 已有 EASY / NORMAL / HARD 参数表，但大厅只有一个 Simple AI，开局永远是默认 NORMAL（联机还会再改）。

## Implementation Strategy
1. `PlayerType` 增加 `AI_EASY`、`AI_HARD`；原 `SIMPLE_CLAIRVOYANT_AI` 当作中等。
2. 三档共用同一控制器场景；`Match` 在 `add_child` 前写入 `difficulty`。
3. 槽位下拉用 item id，顺序：空位、指挥官、简单、中等、困难。

## Implementation Steps
1. 本计划
2. 枚举与控制器表
3. 大厅下拉与开局传参
4. Match 应用难度

## Timeline
本轮改大厅与开局接线。

## Risk Assessment
联机协议仍只识别一种 AI，默认中等。旧测试继续用 `SIMPLE_CLAIRVOYANT_AI`。

## Success Criteria
- 单机可选三档 AI
- 简单更晚出兵、编制更小，重型（坦克/直升机）最多 1 辆、其余用步兵；困难工人和编制更高
- 人类槽位规则不变

## Progress Tracking
- ✅ 计划
- ✅ 枚举与开局
- ✅ 大厅 UI

## Related Files
- `source/Constants.gd`
- `source/match/Match.gd`
- `source/main-menu/MatchSetupPage.gd`
- `source/main-menu/Play.gd`
