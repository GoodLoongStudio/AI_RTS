# 单机大厅：随机地图 + 去掉 8 人图 Implementation Plan

## Overview
单机对局页「随机地图」按当前槽位直接开局；加载界面里现跑 G1–G4 生成一张随机四人图，再进入对局。加载会比选现成图更久。大厅清单只保留 4 人图。

## Current State Analysis
上一版把按钮接到了地图工作台页（`MapGeneration.autostart_random`）。用户要的是：点按钮 = 新开对局，生成发生在 `Loading.tscn`，不进工作台 UI。

## Implementation Strategy
1. 「随机地图」走与「开始游戏」同一条本机开房 + Loading 链路，并带上 `generate_random_map`。
2. `RandomMapRuntime` 在加载页拉起本机 `tools/mapgen` 服务、提交 `target=full` 随机任务、轮询到完成，返回已安装 `map_*.tscn`。
3. 生成失败停在加载页报错，不偷偷改用旧图。
4. 主菜单「地图生成器」仍进工作台，互不影响。

## Implementation Steps
1. 本计划（按用户更正重写）
2. `RandomMapRuntime` 工作台客户端
3. Loading 在载入地图前生成
4. 大厅按钮改走开局

## Timeline
本轮改大厅与加载页。

## Risk Assessment
- 本机没 `.venv-g2` 时加载页报错，可回大厅重开或先跑 setup。
- 工作台已有任务时跟已有任务，避免 409 卡死。
- 生成可能数分钟；加载条显示阶段文案。

## Success Criteria
- 点「随机地图」进入加载界面，而不是地图工作台
- 加载文案出现生成阶段，完成后进新图对局
- 选现成图点「开始游戏」行为不变
- 下拉里没有 8 人图

## Progress Tracking
- ✅ 计划更正
- ✅ 运行时客户端
- ✅ 加载页生成
- ✅ 大厅接线

## Related Files
- `source/main-menu/RandomMapRuntime.gd`
- `source/main-menu/Loading.gd`
- `source/main-menu/Play.gd`
- `source/main-menu/MatchSetupPage.gd`
- `source/main-menu/MapGeneration.gd`
