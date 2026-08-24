# 局部避让拥挤窄路 Implementation Plan

## Overview
按审核矩阵第 29 项建议「重点测试拥挤、窄路」。补齐基础避让参数，并加对向交错与并排移动验收。

## Current State Analysis
`Movement.tscn` 默认 `max_neighbors = 1`，拥挤时几乎只躲一个邻居。策划要求多单位不能长期完全重叠。

## Implementation Strategy
不重写 RVO。把默认邻居数和预测时间对齐到已验证的 Tank 参数，并加自动交错测试。

## Implementation Steps
1. ✅ 修正默认避让参数
2. ✅ 拥挤/对向交错冒烟
3. ✅ 2026-08-24 已验收

## Timeline
本轮只做基础避让稳定，不做正式阵型。

## Risk Assessment
邻居数提高会增加避障计算，当前 Demo 单位量可接受。

## Success Criteria
- 可移动单位默认 `max_neighbors >= 8`
- 两辆 Tank 对向交错后不应长期重叠
- 多单位同向移动结束后仍保持间距

## Progress Tracking
✅ 默认参数
✅ 冒烟测试
✅ 人工验收

## Related Files
- `source/match/units/traits/Movement.tscn`
- `source/match/units/traits/Movement.gd`
- `tests/automated/LocalAvoidanceSmokeTest.gd`
