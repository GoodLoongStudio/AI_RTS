# 副官第一阶段交付复核提示词

在 G:/AIRTS/AI_RTS 中按 AGENTS.md 及相关规则，只读复核第一阶段交付，先区分任务诊断台账与实际执行权威状态。读取原实施提示词、实施报告、task_loop.py、economy_recovery.py、trace.py、nodes.py、仲裁与进度链。

不要将日志出现 recovering／blocked、D2 可选次数或现有单测通过直接当成可执行闭环完成。用自有探针分别检验：旧到达／既有实体是否误报新任务成功；total_deadline 后是否进入诊断和恢复；无实际进展时 diagnose 是否刷新 last_progress；预算耗尽是否约束后续真实候选；工人／矿场损失是否在下一轮被误清除；持续支出是否掩盖交货中断；索引总键数是否受控。

读取 agent/runs/2026-10-15-adjutant-phase1/round-04/match-600s-b/runner-logs/trace.jsonl，独立核验轮数、任务状态与后续命令关系，标出每个证据的 seq／round／task_id。核对当前源码与 source-before.json，晚于 600 秒证据的改动不能声称已被该局验证。探针仅证明局部反例，不能冒充真实 Match 复验。

将可复现缺陷、代码位置、影响、最低补验要求、命令与 rc 写入独立报告。保护既有运行源码和证据，发现阻断问题则维持 needs-review；未经用户后续要求不开始修复或发消息给其他任务。
