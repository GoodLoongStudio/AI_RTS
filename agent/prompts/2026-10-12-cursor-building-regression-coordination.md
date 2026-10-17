# 发给 Cursor：与建筑和副官修复验收协调

> **2026-10-12 19:43 已失效，由用户要求接管。下面全部暂停写入、冻结构建、等待 Codex 与等待用户转达的要求已解除，不再执行。请立即使用 [Cursor 接管提示词](G:/AIRTS/AI_RTS/agent/prompts/2026-10-12-cursor-takeover-building-adjutant-and-performance.md)。Codex 自有测试已停止并核验清理，剩余验收及原性能任务由 Cursor 接管。以下正文仅保留为历史协调记录。**

你正在执行 `G:/AIRTS/AI_RTS/agent/prompts/2026-10-12-ai-stutter-gpu-quality-optimization.md`。请继续该性能任务，但先遵守以下共享工程协调要求。当前 Codex 正在完成建筑布局、资源分基地、采矿链路及副官状态/侦察事件的修复验收；你的 P0 选址和规则 AI 优化与它直接重叠。

## 当前先做什么

1. 阅读 `G:/AIRTS/AI_RTS/AGENTS.md`、工作区边界 skill，以及当前闭环报告 `G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-12-ai-building-layout.md`。开发根仍为 `G:/AIRTS/AI_RTS`。
2. 暂停修改下面列出的共用源码和回归测试。当前完整回归期间也暂停游戏产品源码、场景和配表写入、`dotnet build`、Godot editor/import/export，以及其他会覆盖 DLL/资源缓存的操作，避免让正在验收的实例加载混合版本。
3. 不回滚、覆盖、清理或移动已有改动；不把代码替换成你启动任务时的旧版本。已经完成的未提交修改保留原样。若你有正在运行的写入或构建，停止继续发起，并在自己的报告中记录实际变更时间和文件。
4. 等待期间可只读分析现有 profiler/日志、梳理调用链，准备纯文本优化假设和补丁方案。写入只放在你自己的计划、报告或独立证据目录，不修改 Codex 的计划、报告、探针及 `agent/runs/20261012-ai-building-layout/`。
5. 暂时不启动新的 GPU 性能 A/B、压力对局、录像或批量回归。已有本轮自有测试可安全收尾，但只清理你自己核验过身份的进程；不要终止 Codex、用户或其他会话的进程。

## 正在保护的共用范围

- `source/csharp/GodotAdapter/Construction/StructurePlacementRuntime.cs`
- `source/csharp/GodotAdapter/Construction/GodotStructurePlacementWorldPort.cs`
- `source/csharp/GodotAdapter/Composition/CommandRuntime.cs`
- `source/csharp/Application/Construction/`、`source/csharp/Domain/Construction/`
- `source/match/players/simple-clairvoyant-ai/`，尤其 `SimpleClairvoyantAI.gd`、`AiBuildAnchors.gd`、`EconomyController.gd`、`ConstructionWorksController.gd`、`DefenseController.gd`、`OffenseController.gd`
- `source/adjutant_coordinator/graph/`，尤其 `observation_view.py`、`task_patch.py`、`rules_fallback.py`、`state.py`、`graph.py`、`nodes.py`
- `source/match/units/Unit.gd`、`OreRefinery.gd`、`traits/Movement.gd`、`actions/Moving.gd`、`actions/MovingToUnit.gd`
- `source/match/utils/UnitMovementUtils.gd`、`UnitPlacementUtils.gd`
- `source/net/DebugControlServer.gd`
- 相关自动化测试、场景和 balance 配表，以及 `.godot/mono/temp/bin/Debug/` 两个游戏 DLL。

当前回归还覆盖地形、导航、迷雾和 HUD，故不能在同一时段编辑这些产品文件，或通过构建/导入间接替换运行依赖。此协调不是取消你的 GPU 优化任务。

## 已验证行为必须保留

- 电脑和副官共用分散选址：建筑逻辑半径边缘至少留 5.6m，偏好约 8m；保护生产出口和矿场至矿点的双向路线。这些数字不是物理盒边距，不能混淆各层尺寸语义。
- 分基地用于新矿扩张并补矿场、对空和对地防御；没有新矿不在家旁假扩张；普通生产优先开局基地；不抢矿车施工。
- 自动施工以最近完工己方基地计距，排除自身和其他在建基地：20m以内全速，20–50m连续下降，50m以外0.2倍；小数工量保留。
- 矿车在服务矿点侧安全出生，Box 表面接触可交矿；正常生产默认方向保留。
- Movement 在清除目标前保存真实终态，DCS采样发布真实发生 tick 和目标；上一段迟到的 arrival/path_failed 不结束下一段命令。
- 开局基地锚点、紧急移动标记、已消费事件在副官状态和检查点中保留；信号在运动下发之前连接，避免漏掉同步终态。

当前 R23 产品候选的专项证据：副官声明运行时 1045 项 unittest，1044通过、1跳过、0失败；独立自然电脑局两基地相距81.0873m，远矿59次交货/23600矿，对地/对空防御各1，普通生产留主基地；5FPS建造、采矿和出兵录像已实际查看。完整Godot回归仍存在红项，当前状态为 needs-review，不能当成全项目全绿。

## 怎样确认测量时段和交接

本提示词写入时，Codex 正在运行绝对用户数据目录的完整127项回归及失败串行复查：

```text
Python 父 PID：39680
创建时间：2026-10-12T18:30:50.164416+08:00
命令：D:/software/anaconda3/python.exe agent/runs/20261012-ai-building-layout/regress.py --ids all --jobs 4 --out G:/AIRTS/AI_RTS/agent/runs/20261012-ai-building-layout/r24-full-absolute
证据目录：G:/AIRTS/AI_RTS/agent/runs/20261012-ai-building-layout/r24-full-absolute
```

以上 PID 只作身份线索，可能复用。查询时同时核验创建时间和完整命令；**不要杀这个进程或它的子进程**。它结束后仍可能有相关补验，不能只见一个 PID 消失就立刻覆盖源码。

先回复用户你已暂停哪些写入、当前自有实例是否已收尾，以及等待期间准备做的只读工作。由用户转达本轮回归和补验已经结束后，再从磁盘重读最新文件、diff、源码/DLL hash和闭环报告，继续实施。不要恢复旧快照。依照原性能提示词保持 P0/P1/P2 目标，每个候选单独新局验证。

正式性能窗口必须确认无批量回归、构建、导入、录制或另一个压力实例竞争；记录副官及模型的正常工作负载。竞争样本标受污染，不能写成优化收益。不要通过关闭副官、减少单位或降低画质获得最终成绩。
