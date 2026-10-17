# RSI Checklist 目录

这是 AI_RTS 的可积累问题清单约定。每个任务的实际清单放在
`agent/runs/<run-id>/checklist.md`，本目录只保存模板、字段说明和长期可复用的检查项。

## 使用规则

1. 新问题先登记 ID、现象、复现步骤和证据路径，再改代码。
2. `fixed` 只能由回放验证角色写入，并附本轮截图、日志、mtime 和测试 rc。
3. 三轮没有提升时，回到 champion，换诊断方向或停止当前阶段。
4. 清单不能替代 `skills/闭环验证工作法.md` 的六条硬要求。

模板：`agent/templates/rsi-checklist.md`。
