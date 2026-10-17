# Grok 4.7 安全修复流程更新

日期：2026-10-10（北京时间）  
状态：**文档流程已更新；未修改游戏代码，未声称任何游戏问题已修复。**

## 结论

现有规范不是完全错误，但“真实 Match”和“回归”主要被写成一轮任务结束时的交付要求，缺少“每个关键补丁之后立即重开一局无头真实对局”的硬闸门。这允许模型连续堆叠多个修改，最后才发现移动、经济、视觉或生命周期被破坏，形成“拆东墙补西墙”。

本轮把规则收紧为：**单补丁循环 + S0/S1/S2/S3 阶段闸门 + candidate/champion 拒绝机制**。

## 已更新文件

- `skills/闭环验证工作法.md`：新增 §1.5。关键补丁后必须新开独立无头真实 Match，验证新行为、旧功能轨迹、模拟速度和清理；失败立即拒绝候选。
- `skills/AI_RSI自校验循环.md`：新增 2.3，把单补丁真实对局闸门设为所有 Agent 的常驻 RSI 要求。
- `skills/airts-performance-optimization/SKILL.md`：性能候选也必须逐补丁复验真实实体、命令、位移/到达、攻击或产出、模拟秒/墙钟秒和 `cleanup_ok`。
- `agent/templates/rsi-execution-prompt.md`：加入关键补丁后的无头 Match 硬门禁。
- `agent/templates/rsi-round.md`：增加 `headless_match.json`、PID/实例、实体/命令/位移、模拟速度、退出码和清理字段。
- `agent/plans/2026-10-10-grok47-safe-game-fix-plan.md`：新 Grok 4.7 阶段计划。
- `agent/prompts/2026-10-10-grok47-safe-game-fix.md`：可直接交给 Grok 4.7 的执行提示词。

## 验证

- 7 个改动/新增文档均通过主工程 `check_workspace_target.py --mode develop`，rc=0。
- UTF-8、非空、Markdown 代码围栏和 `git diff --check` 均通过，输出 `SAFE_FIX_DOCS_VALIDATED`。
- 本轮没有运行 Godot、没有跑真实 Match、没有编译游戏、没有生成截图；这是流程文档更新，不是产品修复验收。
- 共享工作区仍有大量其他未提交改动，未执行 reset、clean、批量回滚或进程清理。

## 交付口径

把以下文件发给 Grok 4.7：

`G:/AIRTS/AI_RTS/agent/prompts/2026-10-10-grok47-safe-game-fix.md`

同时要求它读取：

`G:/AIRTS/AI_RTS/agent/plans/2026-10-10-grok47-safe-game-fix-plan.md`

只有通过 S3（独立复核、全量回归、candidate/champion 比较和清理验证）才能写“已修好”；否则必须写 `needs-review` 或 `blocked`。
