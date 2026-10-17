# 任务计划：RSIGame 自校验流程标准化

- 状态：`complete`
- 创建时间：2026-10-02
- 负责人 Agent：Codex
- 关联提示词：`agent/prompts/2026-10-02-rsigame-self-validation-standard-prompt.md`

## 目标

把 RSIGame 的局部探索-诊断-修改-回放循环和全局 champion/饱和控制，落成 AI_RTS 可重复执行的 Agent 流程、产物合同和 DeepSeek Harness 提示词。

## 非目标

- 不在本轮修改游戏运行时代码、尺寸、碰撞、导航或玩法数值。
- 不宣称当前工作区的游戏行为已经通过回归。
- 不替换现有六条闭环硬要求或现有动态端口运行器。

## 当前证据

- 论文：<https://arxiv.org/html/2609.39045v1>
- 现有项目规则：`skills/闭环验证工作法.md`
- 现有自动测试技能：`G:/AIRTS/.codebuddy/skills/airts-auto-loop-testing/SKILL.md`
- 基线：`agent/runs/2026-10-02-rsigame-self-validation/baseline.md`

## 改动范围

- `AGENTS.md`、`skills/AI_RSI自校验循环.md`
- `skills/目录.md`
- `agent/manifest.json`、`agent/README.md`
- `agent/checklists/` 和 `agent/templates/`
- `agent/prompts/`、`agent/reports/closed-loop/`
- `G:/AIRTS/.codebuddy/skills/airts-auto-loop-testing/SKILL.md`

## 验证矩阵

| 层级 | 命令/探针 | 通过条件 | 结果 |
|---|---|---|---|
| JSON | `python -m json.tool agent/manifest.json`、champion JSON | rc=0 | 通过 |
| 文档 | `git diff --check`（本轮受影响的已跟踪文件） | rc=0 | 通过 |
| 技能 | 人工审阅角色、门禁、champion、饱和和 stale-evidence 规则 | 无冲突、可执行 | 通过 |
| 运行时 | 本轮不适用 | 未修改游戏行为 | 未运行 |

## 停止条件

流程文件能被 DeepSeek Harness 直接定位，且不引入与现有闭环宪法冲突的第二套口径。

## 完成标准

- [x] 有项目级 RSI skill、模板、清单目录和执行提示词
- [x] 根目录 Agent 契约把 RSI 列为每次开发的强制阅读项
- [x] manifest/README/skills 索引可发现
- [x] 外部 `airts-auto-loop-testing` 技能与 RSI 规则对齐
- [x] 写入闭环报告并列出未运行的游戏回归
