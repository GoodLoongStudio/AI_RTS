# 副官连通 / 无人机可见 / 单位贴地 Implementation Plan

## Overview
修三件同时出现在单机与联机里的问题：副官连通性测试误报、无人机模型看不见、地面单位悬空。

## Current State Analysis
- 连通测试只认本机 `agent_runner.pid`。外部/服端副官正在指挥时，面板已显示“外部进程”，测试却报“没有运行中的副官”。
- “岚”标题行写死“副官已接入”，且缺少 `set_adjutant_state_text`，真实状态同步不到。
- 联机客户端优先连本进程 DCS，和服端 `EconomyRuntime.MatchId`（每进程一个 Guid）对不上，出现 match_id 拼报。
- `Air.Y = 40` 被导航对齐当成飞机所在高度；或 3m 投地护栏把出生点留在 Y=0，无人机埋进地里/飞出镜头。
- 高度采样用世界 XZ 当语义坐标，且不乘 Map 缩放，单位站在错误高度。

## Implementation Strategy
1. 连通测试与状态面板共用权威口租约/意图证据；联机客户端优先有对局的服端口。
2. 补齐标题行同步 API，默认“尚未启动”。
3. 地面单位始终投到世界高度；空中单位用地表 + 离地高度，不再钉全局 Y=40。
4. `GeneratedTerrain` 提供世界空间高度采样，移动/出生共用。

## Implementation Steps
1. 本计划文档
2. 副官连通测试 + 权威口选择 + 标题行
3. 世界高度采样与出生投地
4. 无人机离地悬停（空域不再走 Recast 高度面）
5. 守门测试

## Timeline
改完必须重新进单机与联机各一局验收。

## Risk Assessment
- 空中改走平面逻辑移动：大图本来就跳过 Recast；小图飞机不再贴 Y=40 空域网格。
- 投地取消 3m 护栏：地面单位不再因高差被跳过；飞机单独加离地。

## Success Criteria
- 点“副官连通测试”时，若权威口已有租约/外部 runner，显示接通，不报“没有运行中的副官”
- 标题行与接管按钮状态一致
- 开局无人机在基地旁可见，相对地面悬停
- 工人/建筑贴在可视地表，单机与联机一致

## Progress Tracking
- ✅ 计划
- ✅ 副官连通
- ✅ 投地与无人机
- ✅ 守门测试

## Related Files
- `AI_RTS/source/ui/AdjutantButton.gd`
- `AI_RTS/source/match/hud/AICommandHUD.gd`
- `AI_RTS/source/match/Match.gd`
- `AI_RTS/source/match/MatchUtils.gd`
- `AI_RTS/source/match/MatchConstants.gd`
- `AI_RTS/source/match/maps/generated/GeneratedTerrain.gd`
- `AI_RTS/source/match/units/traits/Movement.gd`
- `AI_RTS/source/match/units/traits/MovementObstacle.gd`
- `AI_RTS/tests/automated/AdjutantConnectivitySmokeTest.gd`
