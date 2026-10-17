# 执行提示词：RSIGame 自校验流程标准化

请把 RSIGame 的递归自校验思想吸收到 AI_RTS 的长期开发流程，不要修改游戏运行时代码。

先读取：

1. `AGENTS.md`
2. `skills/闭环验证工作法.md`
3. `skills/AI_RSI自校验循环.md`
4. `agent/manifest.json`
5. `agent/plans/2026-10-02-rsigame-self-validation-standard-plan.md`
6. `G:/AIRTS/.codebuddy/skills/airts-auto-loop-testing/SKILL.md`

完成并校验计划中列出的流程文件。保留现有动态端口、截图、运行时实测、相关套件、独立复核和防僵尸房规则；新增 Controller/Explorer/Editor/Verifier 的局部循环、champion 检查点、质量向量、连续三轮不提升换阶段、checklist 和 stale-evidence 门禁。DeepSeek Harness 后续执行任何游戏任务时，都必须按 `agent/templates/rsi-execution-prompt.md` 和 `agent/templates/rsi-round.md` 留下证据。

不要用本轮文档改动来声称游戏修复完成。完成后运行 `git diff --check` 和 `python -m json.tool agent/manifest.json`，写 `agent/reports/closed-loop/2026-10-02-rsigame-self-validation-standard.md`，明确本轮没有运行 Godot 行为回归。
