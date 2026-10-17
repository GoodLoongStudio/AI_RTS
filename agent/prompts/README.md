# Prompts

这里放交给执行 Agent 的可重复提示词，而不是聊天备忘录。

每个提示词必须：

- 指向一个 `agent/plans/*.md`；
- 明确允许修改的目录和禁止触碰的目录；
- 要求先检查 mtime、git diff 和基线；
- 要求运行时探针、截图、相关回归和闭环报告；
- 失败时保留日志并停在 `blocked`/`needs-review`，不能用改测试断言的方式强行收尾。

推荐文件名：`YYYY-MM-DD-短任务名-execution-prompt.md`。
