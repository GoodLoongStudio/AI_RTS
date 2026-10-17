# RSI Checklist：<任务名>

- run_id：`<run-id>`
- champion：`<agent/runs/<run-id>/champion.json>`
- 当前阶段：`<stage>`
- 连续未提升轮数：`<0-3>`

| ID | 优先级 | 现象/目标 | 可证伪假设 | 证据路径 | 状态 | Verifier 结论 |
|---|---|---|---|---|---|---|
| C-001 | P0 | | | | open | |

状态只能使用：`open`、`in-progress`、`fixed`、`rejected`、`blocked`。

## 本阶段出口

- [ ] 没有未解释的 P0/P1 项
- [ ] 正向和反向场景都有证据
- [ ] 相关套件和独立复核均记录 rc/marker
- [ ] 关键截图已打开检查，且 mtime 晚于本轮开始时间
- [ ] 已决定 promote champion、换阶段或停止
