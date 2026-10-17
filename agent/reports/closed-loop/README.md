# Closed-loop Reports

这里放可以长期引用的闭环验证报告，建议文件名：

```text
YYYY-MM-DD-短任务名-report.md
```

报告不是日志转储，而是证据索引。最少记录：

1. 目标和验收条件；
2. 实际改动文件与关键数值；
3. 运行时探针结果；
4. 关键截图及肉眼观察；
5. 测试命令、rc、expected marker 和 forbidden output；
6. 独立复核结果；
7. 未验证项、并发风险和回滚方式。

原始 stdout/stderr 不要全部粘进报告，放在 `agent/runs/`，报告只链接到它们。报告完成后才允许在提示词或 README 中引用“已修复”。
