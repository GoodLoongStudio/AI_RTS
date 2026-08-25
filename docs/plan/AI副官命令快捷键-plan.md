# AI副官命令快捷键 Implementation Plan

## Overview
让 AI 副官底部命令条的快捷键能真正触发命令，且不占用镜头、单位命令和编组键。

## Current State Analysis
`legacy.command_*` 被设为 `ButtonOnly`，按钮仍画着 Q/W/E/R/D/F。这些键已给镜头旋转/平移和单位攻击移动/停止，因此解析不到副官命令。

## Implementation Strategy
给副官命令分配空闲字母键，只在 `LegacyAgent` 上下文生效。HUD 从 `InputBindingRuntime.GetBinding` 显示真实键位。本地 `controls.cfg` 升到 schema 2，避免旧 QWERDF 覆盖把冲突键带回来。

默认键：U 移动、I 攻击、O 防守、P 侦察、J 撤退、K 停止。

## Implementation Steps
1. ✅ 默认绑定改为非冲突键
2. ✅ HUD 按绑定刷新文案
3. ✅ 核心测试与冒烟
4. ⏳ 待人工验收

## Timeline
只修副官命令条六键，不改 F1 / 数字小队 / 对话发送。

## Risk Assessment
玩家本地旧 `controls.cfg` 若仍写 QWERDF，会重新抢镜头键。用 schema 升级并重写默认文件规避。

## Success Criteria
- 副官打开时 U/I/O/P/J/K 能进入对应命令
- 同时打开副官时 Q/W/E/R/D/F 仍归镜头或单位命令
- 按钮文案与绑定一致

## Progress Tracking
✅ 绑定
✅ HUD
✅ 测试
⏳ 人工验收

## Related Files
- `source/csharp/Application/Input/DefaultInputBindings.cs`
- `source/csharp/GodotAdapter/Input/InputBindingRuntime.cs`
- `source/match/hud/AICommandHUD.gd`
- `tests/core/InputBindingServiceTests.cs`
- `tests/automated/LegacyHudVisibilitySmokeTest.gd`
