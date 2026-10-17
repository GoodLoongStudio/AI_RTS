# E1–E4 返修 checklist — 2026-10-17

| 项目 | 当前状态 | 必需证据 |
|---|---|---|
| 工作区/目标校验与 baseline | done | `baseline.json`；全部目标 rc=0；共享 dirty 状态保持 |
| E1 Pending / Unknown 非终态及回执状态推进 | pending | Pending→Accepted→完成；Pending→Rejected；Unknown→终态；终态乱序/重放幂等；S1 Match |
| E2 稳定 attempt identity 与迟到回执隔离 | pending | 同 tick 授权边界；一次 intent 多次 dispatch；旧回执晚到；第二次授权无下发；重放；checkpoint 恢复；S1 Match |
| E3 指定工地事实接线 | pending | 原始观测→facts→task 判据：SiteA 未完工/完工/消失/SiteB 完工/SiteA 重现；S1 Match |
| E4 完工未知值语义 | pending | True / False / None / 缺字段及 campaign 晋级正反例；S1 Match |
| task-loop 与图运行相邻回归 | pending | `test_task_loop`, `test_economy_recovery`, `test_decision_trace`, graph runtime / campaign / state suites rc=0 |
| 600 秒真实单人房观察 | pending | 实际模拟时长、LangGraph/plan 模式/真实模型、轨迹导出、源码冻结、进程与清理 |
| 独立反例探针与完整回归 | pending | 自有 oracle 的新鲜探针；全部相关套件；全量回归结果及既有基线红分类 |
| candidate/champion 决策 | pending | 质量比较、champion 保持不变或有完整晋级门槛；连续未提升轮数准确 |
| 闭环报告 | pending | 改动文件、基线/新值、命令/rc、日志/截图（若关键视觉）、未验证项、共享风险 |

纪律：E1→E2→E3→E4 顺序串行；任何 S1 未通过就暂停后续补丁。现有 champion 和 `round-08` 四审证据不可覆盖。
