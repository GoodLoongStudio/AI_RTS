# 闭环验证报告：RSIGame 自校验流程标准化

- 日期：2026-10-02
- 计划：`agent/plans/2026-10-02-rsigame-self-validation-standard-plan.md`
- 提示词：`agent/prompts/2026-10-02-rsigame-self-validation-standard-prompt.md`
- 运行目录：`agent/runs/2026-10-02-rsigame-self-validation/`
- 状态：`complete`

## 1. 目标与验收条件

将 RSIGame 的“局部探索-诊断-修改-回放”和“全局 champion-比较-饱和控制”变成 AIRTS 可发现、可重复的流程，不改变游戏运行时代码。

## 2. 实施改动

| 文件 | 改动 | 作用 |
|---|---|---|
| `skills/AI_RSI自校验循环.md` | 新增 | 项目级局部/全局 RSI 规范、硬门禁、质量向量、checklist、停止条件 |
| `AGENTS.md` | 更新 | 将 RSI 规范列为每次开发的强制阅读项和交付字段 |
| `skills/目录.md` | 更新 | 让 Agent 能发现 RSI skill |
| `agent/manifest.json` | 更新 | 增加 RSI skill、checklist 目录和产物合同入口 |
| `agent/README.md` | 更新 | 增加 champion、阶段饱和和角色产物说明 |
| `agent/checklists/README.md` | 新增 | 可积累问题清单约定 |
| `agent/templates/rsi-*.md` | 新增 | round、checklist、执行提示词模板 |
| `G:/AIRTS/.codebuddy/skills/airts-auto-loop-testing/SKILL.md` | 更新 | 把现有无人化运行器接入 RSI 角色和 champion 规则 |

## 3. 运行时实测

本轮没有修改 Godot/C#/GDScript、场景、配置或资源，因此没有声称运行时行为已修复，也没有伪造 Match 读数。

## 4. 截图验收

不适用。本轮只改流程文档和模板；下一次使用该流程处理游戏改动时，必须按模板生成并打开真实 Match 截图。

## 5. 自动化验证

| 命令 | rc | 结论 |
|---|---:|---|
| `python -m json.tool agent/manifest.json` | 0 | manifest JSON 可解析 |
| `git diff --check` | 0 | 本轮补丁无空白错误 |

## 6. 独立复核

人工对照了现有 `skills/闭环验证工作法.md`、动态端口 `airts-auto-loop-testing` 技能和论文流程；新增规范没有降低原有六条硬要求，也没有把运行时验证改成文档自证。

## 7. 未验证项与风险

- 尚未用 DeepSeek Harness 执行一整轮真实游戏任务；角色产物和 champion 选择需要下一次运行验证。
- 本轮没有跑 Godot 全量回归；这是有意的，因为没有运行时代码改动。
- champion 目前是流程合同，不自动创建 git 提交或执行破坏性回滚；后续 Agent 必须在用户允许的工作树范围内保存和恢复。

## 8. 回滚方式

删除本轮新增的 RSI skill、模板、清单和报告，并恢复 `agent/manifest.json`、`agent/README.md`、`skills/目录.md` 及外部 `airts-auto-loop-testing/SKILL.md` 的本轮行即可；不触碰其他 Agent 的未提交改动。
