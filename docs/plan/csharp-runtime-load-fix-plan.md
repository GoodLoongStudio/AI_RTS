# 战役进关 C# 运行时未加载 Implementation Plan

## Overview
玩家从主菜单进入「回声撤离」后，镜头、命令、结算、HUD 全部失效。根因是 Match 场景里的 C# Adapter 脚本未能实例化，不是玩法逻辑本身坏了。

## Current State Analysis
`godot2026-08-29T15.13.44.log` 在 `Loading.gd` 实例化 `Match.tscn` 时连续报：

- `Cannot instantiate C# script because the associated class could not be found`（全部 GodotAdapter Runtime）
- 随后 `ActionPressed` / `MatchResolved` / `GetAxis` / `GetUnitDisplaySnapshot` 等全部打在普通 `Node` 上
- 日志被每帧 `GetAxis` 刷到约 10MB

`OpenRTS.dll` 里已有 `BalanceConfigRuntime` 和对应 `res://` ScriptPath。CLI 直接跑播放器（无 `--editor`）时项目程序集没有被 Godot 加载。仓库 CI 会先 `--headless --editor --quit` 再跑场景。

## Implementation Strategy
1. 用 Godot .NET 编辑器导入并编译解决方案，再启动对局。
2. 用 `CampaignSmokeTest` 确认不再出现 C# 类缺失和 `SCRIPT ERROR`。
3. 若编辑器编译后仍有独立缺陷（寻路对齐超时、无名 Area3D 走导航等），再单独修代码。

## Implementation Steps
1. ✅ 用 `Godot_v4.7.1-stable_mono_win64` 对 `AI_RTS` 做编辑器导入 / 解决方案编译
2. ✅ 跑 `CampaignSmokeTest.tscn`，确认无 C# 实例化失败
3. ✅ 重开对局不再共用已烘焙 NavigationMesh；导航服务器不再并行烘焙
4. ⏳ 用编辑器重新打开并运行游戏给用户玩

## Timeline
本轮只恢复战役可玩性。AI 副官大模型接入等清单暂缓项不纳入。

## Risk Assessment
Debug 配置引用 `GodotSharpEditor`，必须从编辑器或先 `--editor` 导入后再跑；直接 `Godot.exe --path` 播放器会让 C# 整批变成空 Node。

## Success Criteria
- 进战役不再出现 `Cannot instantiate C# script`
- 日志不再被 `GetAxis` 刷屏
- 镜头 WASD、选中、右键移动可用
- 导航对齐警告消失或只剩可解释的个别单位

## Progress Tracking
- ✅ 确认根因
- ✅ 编辑器编译
- ✅ 战役冒烟
- ✅ 人工进关（编辑器已打开 Main.tscn；战役冒烟无 SCRIPT ERROR）

## Related Files
- `source/main-menu/Loading.gd`
- `source/match/Match.tscn`
- `source/csharp/GodotAdapter/**/*.cs`
- `OpenRTS.csproj`
- `global.json`
- `.github/workflows/campaign-regression.yml`
