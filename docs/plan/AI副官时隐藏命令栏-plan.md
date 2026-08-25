# AI副官时隐藏命令栏 Implementation Plan

## Overview
打开 AI 副官后隐藏底部传统命令栏，关闭后再显示，避免两套操作栏叠在一起。

## Current State Analysis
Tab / 按钮只切 AI HUD，传统命令栏一直显示。

## Implementation Strategy
`Match` 的 AI 显隐回调里同步 `TraditionalUnitCommandHUD.visible`。打开副官时取消未完成的选目标。

## Implementation Steps
1. ✅ 显隐联动
2. ✅ 冒烟
3. ⏳ 待人工验收

## Timeline
只改 HUD 显隐，不改命令语义。

## Risk Assessment
命令栏节点若尚未创建，用 get_node_or_null 跳过。

## Success Criteria
- 默认命令栏可见
- 打开 AI 副官后命令栏隐藏
- 关闭后命令栏回来

## Progress Tracking
✅ 联动
✅ 测试
⏳ 人工验收

## Related Files
- `source/match/Match.gd`
- `tests/automated/LegacyHudVisibilitySmokeTest.gd`
