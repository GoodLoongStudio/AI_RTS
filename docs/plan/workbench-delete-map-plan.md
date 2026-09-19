# 地图工作台：删除当前地图 Implementation Plan

## Overview
在地图工作台右侧「试玩这张地图」下增加「删除这张地图」，删掉当前选中的生成任务及其装进工程的场景。

## Current State Analysis
工作台只能重试、重建视觉、试玩。任务目录在 `tools/mapgen/workbench_output/`，装机目录在 `source/match/maps/generated/<map_id>/`。服务端没有删除接口。

## Implementation Strategy
1. 工作台 `DELETE /api/jobs/<id>`：去掉任务、输出目录、已安装场景和大厅预览图。
2. 不删原版参考、不删正在生成的任务。
3. 游戏内按钮先二次确认，再调接口并刷新记录条。

## Implementation Steps
1. 本计划
2. 服务端删除
3. 工作台按钮
4. 单测

## Timeline
本轮只加删除，不改生成流水线。

## Risk Assessment
旧进程若还在跑，新接口要等重开工作台才生效。删错用二次确认挡住。

## Success Criteria
- 能删掉选中的已完成/失败任务
- 对应 `generated/<map_id>` 和预览 PNG 一并消失
- 原版参考与生成中的任务不能删

## Progress Tracking
- ✅ 计划
- ✅ 服务端
- ✅ 按钮
- ✅ 单测
- ✅ 修复「正在生成」锁死：轮询与提交拆开 HTTP，任务结束后或连不上就松开按钮

## Related Files
- `tools/mapgen/rtsmap/workbench/server.py`
- `tools/mapgen/tests/test_g2_workbench.py`
- `source/main-menu/MapGeneration.gd`
