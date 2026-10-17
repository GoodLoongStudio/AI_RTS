# 副官第一阶段 E1–E4 返修提示词 — 2026-10-17

请仅在主工程 `G:/AIRTS/AI_RTS` 延续第四轮复核后的返修。先读仓库 `AGENTS.md`、`skills/airts-workspace-boundaries/SKILL.md`、`skills/闭环验证工作法.md`、`skills/AI_RSI自校验循环.md`、`skills/airts-temporal-playtest/SKILL.md` 和第四轮复核报告。保持所有既有共享工作区改动；不 reset/clean、不覆盖 `round-08`、不结束现有用户实例或模型服务。

按独立补丁顺序解决：

- E1：`PendingAuthority` / `Unknown` 不算拒绝、不耗失败预算；同一 command ID 的 pending 状态后续能提升为终态；重放同一终态幂等；乱序较旧 Pending 不能覆盖已有终态。
- E2：恢复授权不依赖 tick 做身份；显式 attempt ID 绑定实际 dispatch / command / receipt；同 tick 授权前后可区分；二次授权开始时当前尝试集合重置但旧尝试留有界历史；迟到的旧回执不结算新尝试。
- E3：完整 `observation_view.normalized_units → campaign.build_facts → task_loop` 的 named site 指定工地路径，验证未完工、完工、消失、别的同类工地完工、重现。
- E4：只有 `constructed=True` 纳入类型完工数；False 仍表示在建，None/缺字段保持 unknown，不促成成功或阶段晋升。

每项都先用正式回归重现，再修改产品实现。每个逻辑补丁单独做 Python 解析、相关测试和新进程真实 Match S1 闸门；通过前不得推进下一项。真实 Match 使用 `G:/AIRTS/AI_RTS` 源码、保留真实 LangGraph 与模型服务，记录命令、PID、时间、源码 hash、日志、旧链路断言和 cleanup。随后运行相关测试、独立探针、600 秒真实观察及阶段所需复核。新证据 mtime 必须新鲜。未通过的候选不得提升。

不做无关战略/模型/经济重构，不改测试判据以求变绿。保持 `champion.json` 原样；更新本轮独立 candidate 记录、计划 checklist 和闭环报告，明确残余风险和未通过门槛。
