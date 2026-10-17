# AIRTS 共享工程协作交接：停止与 Codex 的建筑布局任务交叉写入

我正在让 Codex 修复电脑玩家和 AI 副官的建筑布局、远程施工，以及“扩张采矿并补防御”的分基地链路。你与它使用同一个工作区。请立即按以下要求调整工作范围，保留已经做的工作，不要回滚或覆盖任何会话的修改。

## 先完成一次只读交接

1. 读取 `G:/AIRTS/AI_RTS/AGENTS.md`、`G:/AIRTS/AI_RTS/skills/airts-workspace-boundaries/SKILL.md` 和 `G:/AIRTS/AI_RTS/agent/manifest.json`，确认开发根是 `G:/AIRTS/AI_RTS`，打包版和历史副本不能代替它。
2. 立即停止安排新的产品源码修改、共享工程编译、资源导入/导出和对局测试。不要为了停止工作而结束其他会话或用户的进程。
3. 将你已经修改过的文件、修改目的、最近执行的编译/测试命令、仍在运行的自有任务及 PID 列给我。如果你确实改过下列文件，请具体说明改了哪一段；如果没有，就明确说明没有，不要猜测别的会话。
4. 把交接保存到你自己的 `agent/runs/<你的任务目录>/handoff-to-codex.md`，并直接回复我文件路径。只写交接和你自己的证据文档，不要改 Codex 的计划、报告、测试夹具或证据。

## 本轮由 Codex 负责，暂时禁止你修改的范围

以下路径均相对于 `G:/AIRTS/AI_RTS`：

- `source/csharp/GodotAdapter/Construction/` 整个目录，尤其是 `StructurePlacementRuntime.cs`、`GodotStructurePlacementWorldPort.cs`。
- `source/csharp/Application/Construction/`、`source/csharp/Domain/Construction/`。
- `source/csharp/GodotAdapter/Composition/CommandRuntime.cs`、`source/csharp/GodotAdapter/Configuration/BalanceConfigRuntime.cs`。
- `source/match/players/simple-clairvoyant-ai/` 整个目录，包括经济、进攻、防御、工人施工控制器和 `AiBuildAnchors.gd`。
- `source/adjutant_coordinator/graph/observation_view.py`、`task_patch.py`、`rules_fallback.py`、`placement.py`。
- `source/match/maps/generated/GeneratedTerrain.gd`。
- `source/match/units/traits/Movement.gd`、`MovementObstacle.gd`。
- `source/match/utils/UnitMovementUtils.gd`、`UnitPlacementUtils.gd`。
- `source/match/units/OreRefinery.gd` 和采矿、靠近目标、移动相关动作脚本。
- 与上述链路有关的建筑/矿车场景、平衡表、地图、`project.godot`、`source/ui/MouseClamp.gd`。
- `tests/automated/AiBuildingLayoutSmokeTest.*`、`AiExpansionSupportSmokeTest.*`、`RuleAiExpansionSmokeTest.gd`，以及本轮相关建造、经济、导航测试。
- `agent/plans/2026-10-12-ai-building-layout.md`、对应 checklist/prompt/report，以及 `agent/runs/20261012-ai-building-layout/` 整个目录。

不要改同一逻辑的相邻文件或新建替代实现来绕过上述边界。发现问题可以记录建议，由 Codex 核对后落地。

## 编译和测试也需要避开冲突

Codex 正在用真实 Match、源码及 DLL 哈希、独立后台游戏窗口和 5 FPS 录像验收。共享源码或 DLL 被替换，会使这一轮证据失效；多开对局、推理压力测试也会污染性能测量。

- 暂时不要运行 `dotnet build/run/test`、Godot 编辑器自动构建、资源重新导入、导出、打包等可能写入主工程 `.godot/mono/`、`bin/`、`obj/`、共享构建产物的动作。
- 暂时不要启动本工程的 Godot 对局、AI 性能探针、自动回归、录像或 GPU/小模型压力测试。已开始且可正常完成的自有测试，请正常收尾并报告 PID、退出码；不能无限循环继续开局。
- 不得执行 `git reset`、`git checkout --`、`git restore`、`git clean` 或用备份覆盖共享文件；不要撤销你自己的旧改动，因为其中可能已包含其他会话后续的精确补丁。
- 不要按 Godot、Python、dotnet、ollama 等进程名批量结束进程，不要关闭用户游戏/编辑器，不要移动或清空模型运行时。

## 你可以继续做的工作

你可以只读检查当前源码、已有日志和已完成的测试结果，分析电脑 AI 性能、线程分工和潜在回归，并把发现写到你自己的证据目录。建议逐项写出：现象、文件/函数、支持它的证据、最小修复建议、建议验收方式；没有实测的性能判断标为待验证。

如果需要实施，请先把具体文件清单和方案发给我。我确认新的分工后，你再动这些产品文件或启动共享测试。在此之前保持只读分析，不必等着空闲，也不要自行切换到旧工程或打包版继续修改。

请先回复：已经停止哪些写入/测试；交接文件在哪里；还有哪些属于你自己的任务尚未收尾。
