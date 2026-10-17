# AI_RTS Agent Contract

本文件是仓库级 Agent 入口。任何自动化编码 Agent、DeepSeek Harness、Cursor 或人工协作者，在读代码和改文件前先读本文件，再读 `skills/airts-workspace-boundaries/SKILL.md`、`skills/闭环验证工作法.md`、`skills/AI_RSI自校验循环.md` 与 `agent/manifest.json`。RSI 规范是每次开发都必须参考的常驻流程，不是某个任务的可选建议。

## 开发工程与打包边界

本机默认开发根为 **`G:/AIRTS/AI_RTS`**；**`G:/AIRTS/打包版`** 是交付成品，不是游戏源码修改位置。`RTS_Map_Tool` 是独立工程，备份/临时目录里的 `project.godot` 不代表当前开发目标。详细分区见 `skills/airts-workspace-boundaries/SKILL.md`，机器清单见 `agent/manifest.json` 的 `workspace_layout`。

编辑游戏前运行 `python tools/check_workspace_target.py --mode develop --target <实际文件或目录绝对路径>`，必须确认目标属于主工程源码。检查只读，不接入游戏启动链路。测试源码明确使用 Godot `--path G:/AIRTS/AI_RTS` 并核对实例身份；不能用旧打包 exe 验收新源码。

`build` 保持现有导出位置，其中 `build/adjutant_runtime` 是小模型运行依赖，禁止整目录按缓存清理或迁移。不得为整理目录改名工程、修改启动/导出路径、覆盖未提交工作或结束用户实例。明确指定其他工程/worktree、打包或运行时维护的任务按其实际授权范围执行，不能伪装成默认源码修改。

## 工作原则

性能优化、卡顿诊断，以及可能扩大每帧开销的寻路/避障、视野、渲染、特效或大部队开发，另读 `skills/airts-performance-optimization/SKILL.md`。先测热点、保留玩法和画质，再按该 skill 的候选/门禁实施；普通开发至少检查是否引入按单位相乘的扫描、同步读回或无界缓存，不强制加载全部参考页。

1. 先建立证据，再改代码。先检查 `git status`、目标文件 mtime、现有测试和运行日志；不要凭截图或旧对话猜当前状态。
2. 一个任务一个计划。新任务在 `agent/plans/` 建立计划，在 `agent/prompts/` 保存可重复执行的提示词；历史设计文档继续留在 `docs/plan/`。
3. 权威口径只允许一个来源。尺寸、碰撞、导航、建造、速度、射程和视野必须分别指出权威来源，禁止只改视觉或只改一处常量。
4. 改动要有闭环。至少完成静态校验、运行时实测、必要截图、相关测试、结果记录；关键改动还要有独立复核。多轮任务必须按 RSI 的 Controller → Explorer → Editor → Verifier 循环执行，维护 checklist 和 champion。没有闭环报告不得称为“已完成”。
5. 不要把测试判据改绿当作修复。先区分“判据过期”和“行为回归”，只有确实改变产品口径时才更新断言，并在报告中说明。
6. 共享工作区可能有其他 Agent。动笔前检查目标文件是否刚被修改；不覆盖、不回滚、不清理其他 Agent 的未提交工作。
7. 修改尽量小而可回滚。使用精确补丁；避免正则批量删代码、生成大量临时文件或把本机缓存混入提交。

## 标准流程

```text
读取契约 → 读取 RSI 常驻流程 → 建立任务计划 → 记录基线 → 精确实现
→ Controller/Explorer/Editor/Verifier 循环 → 编译/脚本校验
→ 真实 Match 探针 → 可见截图并打开查看 → 相关回归 → 独立复核
→ 写闭环报告 → 更新计划状态 → 才能交付
```

## 目录约定

| 内容 | 位置 |
|---|---|
| 项目级强制工作法 | `skills/闭环验证工作法.md` |
| 开发工程/成品/备份边界 | `skills/airts-workspace-boundaries/SKILL.md`，定位数据在 `agent/manifest.json` |
| RSI 常驻开发流程 | `skills/AI_RSI自校验循环.md` |
| Agent 入口与命令清单 | `agent/manifest.json` |
| 当前任务计划 | `agent/plans/` |
| 可直接交给模型的提示词 | `agent/prompts/` |
| Godot MCP 与运行时端点说明 | `agent/mcp/` |
| 可长期保留的闭环报告 | `agent/reports/closed-loop/` |
| 计划/提示词/报告模板 | `agent/templates/` |
| 临时日志、截图、JSON 运行产物 | `agent/runs/`，不提交 |
| 已有设计文档和历史报告 | `docs/plan/`、`docs/程序文档/` |
| Godot 自动化测试 | `tests/automated/`、`tests/core/`、`tests/performance/` |
| 回归套件清单和运行器 | `config/full_regression_suite.json`、`tools/run_full_regression.ps1` |

## 交付最低格式

最终回复必须链接到闭环报告，并说明：改动文件、基线与新数值、截图路径、测试命令及 rc、未验证项、是否有并行工作区风险。多轮任务还必须说明 candidate/champion 决策和连续未提升轮数。

## 禁止事项

- 不得把 `tmp_logs/`、`.test-results/`、`build/` 中的本机产物当作唯一证据。
- 不得因为截图“看起来对”就跳过权威逻辑和自动化测试。
- 不得在没有用户明确要求时重置、清理或覆盖其他人的改动。
