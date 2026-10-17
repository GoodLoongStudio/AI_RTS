# E1–E4 返修 checklist — 2026-10-17

| 项目 | 当前状态 | 必需证据 |
|---|---|---|
| 工作区/目标校验与 baseline | done | `baseline.json`；全部目标 rc=0；共享 dirty 状态保持 |
| E1 Pending / Unknown 非终态及回执状态推进 | logic-pass | 正式专项241项和独立29项；最终S1见 round-replay/s1-identity-match；自然局未覆盖全部反例 |
| E2 稳定 attempt identity 与迟到回执隔离 | logic-pass | 新发现权威按intent缓存，旧3/3失败→新3/3通过；按attempt隔离intent并验证四类身份，transport4/4通过 |
| E3 指定工地事实接线 | logic-pass / gate-gap | SiteA未完工/完工/消失/SiteB/重现正式与独立探针通过；最初缺单独逐项S1，保留流程偏差 |
| E4 完工未知值语义 | logic-pass / gate-gap | True/False/None/缺字段及晋级反例通过；最初合并补丁后开局，不能补写逐项门槛 |
| task-loop 与图运行相邻回归 | pass | 最终冻结后241项rc=0；round-replay/related-tests-frozen.log |
| 600 秒真实单人房观察 | observing / video-failed | 最终 round-replay/final-600；实测时钟补采从113秒开始；录像partial9.4秒，后补录因隐藏/最小化拒绝 |
| 独立反例探针与完整回归 | partial / red | 独立逻辑29/29；Python1148有四基线红；native严格78/128；其他构建/核心/authority结果见闭环报告 |
| candidate/champion 决策 | no-promotion | E候选因权威重放拒绝；F逻辑通过但全量红，不提升；连续未提升2 |
| 闭环报告 | drafted / finalizing | agent/reports/closed-loop/2026-10-17-adjutant-phase1-repair.md；新运行结束后补最终量化 |

纪律：E1→E2→E3→E4 顺序串行；任何 S1 未通过就暂停后续补丁。现有 champion 和 `round-08` 四审证据不可覆盖。

实际偏差已如实记录：最初E2/E3/E4合并后才开新局，不能把后补S1冒称原顺序合规；新replay子轮单独解析/专项/独立/新局。共享区后续出现C#合并冲突，本任务未修改或覆盖这些文件。
