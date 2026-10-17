# 副官第一阶段第四次独立复核

审查第三轮 D1–D4 返修及其 round-07 证据；只读当前产品代码与已有证据，新增本计划、提示词、报告和独立探针，不修改产品代码、测试断言、原报告或 champion。

- [x] 读取第三轮复核、D1–D4 返修报告、当前源码与工作区身份。
- [x] 重跑 D1–D4 相关测试及相邻图运行测试。
- [x] 用独立探针复现 PendingAuthority/同 tick 意图、生产者台账归因和未知工地事实边界。
- [x] 独立重算 round-07 trace、checkpoint、source-before/source-after 与实际统计口径。
- [x] 写第四轮闭环报告，确认已修项和残余缺口；不修改 champion/计数。

停止条件：反例结论有源码和原始证据支撑，源码身份稳定，报告明确未验证项。第四轮审查不重新启动 Match，除非已有证据不足以作出结论。

2026-10-17 接续中断并完成：244 项相关测试 rc=0，14 组独立正反探针完成；E2 尝试污染在最终对局 seq 与 checkpoint 中得到印证；E1 非终态回执、E3 工地身份接线、E4 未知完工事实仍待返修。gate 局有效前缀可读但末尾存在 NUL 且无完整收尾，final 局记录完整。111 个源码/测试/champion 文件审查前后 hash 和 mtime 未变；不改产品代码、已有测试和 champion，连续未提升计数仍为 1。审查完成，产品 needs-review。

报告：[2026-10-17 第四轮独立复核](G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-17-adjutant-phase1-fourth-review.md)。
