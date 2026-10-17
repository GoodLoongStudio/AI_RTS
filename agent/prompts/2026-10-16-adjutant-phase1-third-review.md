# 第三次独立复核提示词

按 G:/AIRTS/AI_RTS/AGENTS.md、边界、闭环、RSI 和 manifest，独立审查用户提供的 C1–C5 返修记录与当前源码，保留共享 dirty tree。检查 sync_ledger 后补字段、生产订单归因、指定工地与类型共享分支、尝试授权/实际下发/回执/执行结果的因果关系、预算及冷却、重复 tick/旧回执，以及 attempt 事件完整性。

使用实际合同字段和实际 node_arbitrate_intent；单测通过不替代独立反例。生产 Accepted 与最终完成须区分。新探针写自有脚本和第三轮专用输出，保留旧探针结果。独立读取 round-06/match-c-rework-final 的 trace、checkpoint、source-before/source-after、summary，核验版本与统计口径。对每项分别给已修/部分修复/未证实，避免仅依据日志标签认定恢复发生。无需为审查缺陷新开游戏。最终保存闭环报告，明确未运行 Match/UI/全量游戏回归，不提升 champion 或修改计数。
