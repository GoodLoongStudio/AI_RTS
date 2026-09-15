# 主菜单地图生成入口 Implementation Plan

## Overview
主菜单「地图生成」做成铺满屏幕的游戏内工作台，把 `RTS_Map_Tool` 网页工作台的 G1–G4 生成、阶段进度、图层预览和任务历史迁到 Godot 里，视觉跟现有系统 UI 对齐。

## Current State Analysis
- 入口按钮已在「成长系统」与「设置」之间。
- 第一版是居中小面板：调参 + 磁盘地图列表，没有图层、阶段条、任务历史。
- 网页工作台是三栏：左设置 / 中预览+历史 / 右检查；接口为 bootstrap、generate、jobs、retry、rebuild_visual、artifacts。
- 主菜单页面必须继承 `MenuPage.gd`；全屏后左/右栏需要按需滚动。

## Implementation Strategy
- 去掉居中小面板，改为安全区内铺满（约 20px 边距）的三栏指挥台。
- 左侧：网页同款简单选项（河湖/距离/河流/湖泊/水域/高地/通路）+ Seed + 生成完整地图 / 快速预览地形。
- 中间：六图层页签、生成中横幅、预览、任务历史。
- 右侧：G1→G2→G3→G4→引擎 五阶段、指标、重试/重建视觉、已安装图试玩。
- 仍走本机工作台 HTTP，不把 Python 管线嵌进引擎。

## Implementation Steps
1. 更新本计划（全屏 + 全阶段）
2. 重做 `MapGeneration.tscn` 全屏壳
3. 重写 `MapGeneration.gd` 为工作台客户端
4. 取证/冒烟改为允许滚动，并检查全屏与阶段文案
5. 无头冒烟

## Timeline
本轮完成全屏工作台主路径。工作台离线时仍可看已安装图并试玩。

## Risk Assessment
- 720p 三栏会挤：左/右用 ScrollContainer，中间优先预览。
- HTTP 图与 JSON 抢同一个 `HTTPRequest` 会互相取消：API 与图片分两个请求器。
- 延迟 `SystemUIStyle.apply` 会刷掉选中芯片样式：主题后再刷一次选择态。
- `probe_system_ui` 原先禁止本页滚动：改为允许按需滚动。

## Success Criteria
- 工坊页铺满屏幕，不再是主菜单那种居中小卡片。
- 能提交完整地图（G1–G4）和 G2 快速预览。
- 运行中能看到五阶段状态与进度横幅。
- 完成后能切图层看预览，并能从历史切换任务。
- ESC / 返回主菜单可用。

## Progress Tracking
- ✅ 计划改到全屏工作台
- ✅ 全屏三栏布局
- ✅ G1–G4 生成与阶段
- ✅ 取证/冒烟
- ✅ 验证（`verify_map_generation_menu.gd` 通过）
- ✅ 地图显示框改正方形并铺满（对局小地图 / 大厅预览 / 工坊预览）
- ✅ 工作台启动改走 `.venv-g2`，避开 Anaconda 全局 NumPy/SciPy 冲突
- ✅ 游戏内工坊只静默拉起本机生成服务，不再打开浏览器
- ✅ G2 图例加大：预览下方中文色块、裁掉 64px 边框、台地/水域对比加强

## Related Files
- `AI_RTS/source/main-menu/MapGeneration.tscn`
- `AI_RTS/source/main-menu/MapGeneration.gd`
- `AI_RTS/source/main-menu/MatchSetupPage.gd`
- `AI_RTS/source/main-menu/MatchSetupPage.tscn`
- `AI_RTS/source/match/hud/Minimap.gd`
- `AI_RTS/source/match/hud/ra3/Ra3Sidebar.gd`
- `AI_RTS/source/match/Match.tscn`
- `AI_RTS/tools/probe_system_ui.gd`
- `AI_RTS/tools/verify_menu_panel.gd`
- `AI_RTS/tools/verify_map_generation_menu.gd`
- `RTS_Map_Tool/rtsmap/workbench/static/index.html`
- `RTS_Map_Tool/rtsmap/workbench/static/app.js`
