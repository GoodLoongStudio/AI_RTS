# 执行提示词：<任务名>

你正在修改 `G:/AIRTS/AI_RTS`。先读取：

1. `AGENTS.md`
2. `skills/闭环验证工作法.md`
3. `agent/manifest.json`
4. 关联计划：`agent/plans/<plan>.md`

如果任务需要多轮探索，继续读取 `skills/AI_RSI自校验循环.md`，并使用 `agent/templates/rsi-execution-prompt.md`、`agent/templates/rsi-round.md` 和 `agent/templates/rsi-checklist.md`。

严格按计划执行。开始前报告 git status、目标文件 mtime 和基线测试；只修改计划允许的范围。每次写入后立即做解析/构建校验，不要用正则批量删除代码。

完成实现后必须：

- 在真实 Match 中测量受影响的运行时值；
- 对关键视觉变化启动可见实例并截图，打开截图后描述观察结果；
- 运行计划中的相关测试，记录命令、rc、marker 和 forbidden output；
- 对关键改动做独立探针或独立复核；
- 在 `agent/reports/closed-loop/` 写报告，列出所有未验证项。
- 每轮比较 candidate 与 champion；硬门禁失败时拒绝候选并从 champion 重来，连续三轮无提升时换阶段或停止。

如果不能满足闭环，不要说“完成”，改为报告 `blocked` 或 `needs-review`，保留原始日志和截图路径。
