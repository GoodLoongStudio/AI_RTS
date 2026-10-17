# AI 工作台

这里是 AI_RTS 的自动化开发入口，目标是让项目可以长期进行可追踪的 vibe coding，而不是依赖某一次聊天的上下文。

## 开始一个任务

1. 读取根目录 `AGENTS.md`、`skills/airts-workspace-boundaries/SKILL.md`、`skills/闭环验证工作法.md` 和 `agent/manifest.json`；先定位主工程和实际目标，再按范围进入开发。
2. 在 `agent/plans/` 创建一个短计划，写明目标、非目标、权威数据源、验证方式和停止条件。
3. 在 `agent/prompts/` 保存给执行 Agent 的提示词。提示词必须引用计划文件，不要复制一大段易过期的代码背景。
4. 运行前把基线写入 `agent/runs/<run-id>/baseline.md`；日志和截图都放在该 run 目录。
5. 完成后在 `agent/reports/closed-loop/` 写一份长期报告，并在计划末尾标记 `complete`、`blocked` 或 `needs-review`。
6. 需要多轮迭代的任务使用 RSI 循环：每轮留下 `direction`、`exploration`、`patch`、`verification`，并把通过硬门禁且质量不退化的版本记录为 `champion`。

## 现有能力

- `skills/闭环验证工作法.md`：已有的强制闭环规则，继续作为事实上的测试宪法。
- `skills/AI_RSI自校验循环.md`：RSIGame 风格的局部探索-诊断-修改-回放循环与全局 champion/阶段饱和控制。
- `addons/godot_mcp/`：Godot 内置 MCP；`autoload/mcp_interaction_server.gd` 和 `source/net/DebugControlServer.gd` 提供运行时交互/调试入口。
- `tests/automated/`：真实 Match 冒烟测试、探针和截图测试。
- `tools/run_full_regression.ps1`：全量回归入口；`config/full_regression_suite.json` 定义测试、期望 marker 和禁用日志模式。
- `docs/plan/` 与 `docs/程序文档/`：历史计划、提示词、实施报告和复盘资料。

## 这套目录解决什么问题

现有资料很丰富，但以前容易出现“提示词在聊天里、截图在临时目录、测试日志在另一个会话、最终没有状态记录”的断链。以后：

- `plans` 记录要做什么；
- `prompts` 记录怎么让模型执行；
- `runs` 记录每次实际运行的原始证据；
- `reports/closed-loop` 记录可以长期引用的结论；
- `manifest.json` 记录 Agent 应该调用哪些项目工具。
- `checklists` 记录跨轮次的问题、证据和验证状态；`champion.json` 记录当前最佳检查点，避免在坏候选上继续堆补丁。
