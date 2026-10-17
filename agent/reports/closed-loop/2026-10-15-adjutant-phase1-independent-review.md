# 副官第一阶段交付：独立复核

结论：**需要返修，暂不能按原第 1～3 项的完成标准验收。** 运行追踪和经济入口已有实际改动，600 秒日志也确实存在；但独立探针发现任务成功判据、超时恢复和预算执行之间仍有实质缺口。应先补齐这些问题，再处理后续战略优化。

本轮是审查，没有修改副官运行代码或原始对局记录。[原实施报告](G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-15-adjutant-phase1-implementation.md) 的 needs-review 保持；这里不把独立审查完成当作 S3 通过。

## 已确认的有效工作

- 三个新模块及接线实际存在：trace.py、task_loop.py、economy_recovery.py。
- 独立读取本轮最终 600 秒 trace，得到 **2,121 个 round begin、76,257 条事件**，与交付报告一致。
- 重跑现有 test_decision_trace、test_task_loop、test_economy_recovery，当前 **64 项通过，rc=0**；报告原写 63 项，当前树已有数量差异，不据此推断产品行为。
- D2 新入口及 M01 判据的改动存在，不能把本轮说成完全没有实现。但“有入口／有状态记录”不证明恢复已按任务合同控制执行。

## P1：必须先补的执行和判据问题

### R1：预算耗尽／受阻台账没有约束实际执行

位置：[task_loop.py 的评估与反馈](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_loop.py:606)、[nodes.py 的仲裁链](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/nodes.py:3434)、[经济恢复计划](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/economy_recovery.py:319)。

读取链显示 task_loop 主要更新 task_ledger／task_ledger_feedback／task_loop_report，task_ledger_feedback 的业务读取处是经济异常检测；仲裁、规则动作和真实 active_tasks 没有按这个台账的 budget／blocked 状态做对应约束。economy_recovery_plan 保存为上下文／诊断建议，具体动作仍依赖原规则层，不存在仅凭该建议即可证明的“恢复任务→实际执行→结果”链。

独立探针给同一合法意图分别设置 running 和 blocked（retries_used=3，retry_budget=3）台账，生产代码 arbitrate_intents 两次都得到 **accepted=1、dropped=[]**。这是仲裁待下发结果，不是声称探针真的向游戏发过命令。

原 600 秒日志也有实际例子：

| task_id | 预算耗尽事件 | 后续回执事件 | 事实 |
|---|---:|---:|---|
| rule-build-ore_refinery | seq 11186 | seq 11212、11248 | round 320/321，tick 2584，继续收到矿场建造 Rejected/NoValidSite |
| rule-build-ore_refinery | seq 24054 | seq 24081、26217 | 后续继续出现同任务建造拒绝 |
| rule-gather | seq 51608 | seq 58340、58341 | round 1627，tick 10005，仍有同任务 Accepted 回执 |

扫描规则：最近一次新闭环预算耗尽／总超时后，下一次有记录的条件重评、恢复尝试或成功关闭前，寻找同 task_id 的命令回执。共找到 19 条；这不是断言每条回执都非法，而是证明台账受阻不等于实际任务被约束，需要逐条解释其授权和尝试身份。

影响：报告中的“恢复 9 次、预算耗尽 7 次”只能描述新台账状态，不能等价为实际动作已受重试预算控制。也不能把经济最终失败全归到放置层就认为控制闭环达标。

最低补验：复用现有权威任务／命令链消费诊断结果；实际恢复动作必须关联 attempt，并以采纳／下发及结果闭合。没有可行方案或预算用尽时抑制对应失败方案，条件变化有明确恢复授权；避免简单冻结全部正常动作。用真实对局证明预算和执行一致。

### R2：历史事实会被误算为新任务成功

位置：[task_loop.py 指标](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_loop.py:194) 和[统一成功阈值](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_loop.py:238)。

移动读取关联单位历史 unit_arrival_tick 的最大值，统一与默认阈值 1 比较，没有要求晚于任务／尝试建立，也没有匹配本次目标。生产和建造读取全局现有同类型实体数量，没有本任务的增量／实体归属基线。

独立反例：

- 新移动任务创建 tick=100，只有 tick=5 的旧到达事实，返回 **succeeded/success_evidence**。
- 新生产任务没有新增部署，仅原来已有 1 辆同类型坦克，返回 **succeeded/success_evidence**。

影响：任务可能尚未执行就关闭，当前“成功次数”和“等待零误判”的统计不能单独作为正确性证据。不是断言原局 22 次成功全部错误，而是成功判据已被反例证实不足。

最低补验：用任务／attempt 之后、与本次单位和目标相符的权威证据；生产／新建任务记录创建基线和对应订单／实体，就绪目标与新增任务语义分别定义。旧事实、新任务、改目标、旧异步结果和重复执行均需反向断言。

### R3：总期限到达后直接结束，未沿超时边进入恢复

位置：[task_loop.py 超时处理](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_loop.py:662)。

timeout 分支设置 timed_out 和 ended=true；同轮只有 state==diagnosing 才调用 diagnose，下一轮 ended 会在入口被跳过。因此没有落实原提示词要求的“超时→诊断→恢复／受阻”。

独立探针在恢复前提齐全时触发 deadline，结果为 **timed_out、ended=true、attempt=0**；下一轮 changes 为空，真实 active_tasks 仍为 running。

原局 seq 49280、round 1377、tick 8341 的 rule-build-ore_refinery 也记录 total_deadline。该事件证明超时被记下，不证明之后恢复。

最低补验：区分“本次尝试超时”与“整个目标关闭”；超时必须进入有明确去向的诊断／替代或有证据的最终受阻。补 evaluate 的跨轮集成测试，不能只测试 evaluate_record 返回 timeout。

### R4：没有实际进展，恢复状态仍刷新 last_progress

位置：[task_loop.py diagnose](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_loop.py:445)。

进入 recovering 时直接把 last_progress_tick／mono 设置为当前值，并增加 attempt／retries_used。此处没有核验动作真的被规则层采纳、下发或产生世界进展。

独立反例：实际指标与动作均无变化，调用 diagnose 后 **last_progress 从 100 改为 1000，attempt 从 0 改为 1**。

影响：逻辑上的恢复计划被记成真实进展，停滞持续时间被截短，可能消费没有实际执行的重试预算。这与提示词“last_progress 仅由实际进展变化刷新”的要求冲突。

最低补验：分开 attempt_started_at、cooldown_until 和 last_actual_progress；状态切换不能刷新实际进展。尝试生命周期与真实采纳／命令关联，统计长期无进展时不能把状态重启当进展。

### R5：单位／设施损失只保留一轮异常

位置：[economy_recovery.py 损失检测](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/economy_recovery.py:223)。

当前检测比较“本轮数量小于上轮”，随即更新基线，active 每轮由当轮 kinds 重新计算。在没有其他并行异常遮蔽的情形，损失持续但下一轮数量不再下降，异常就解除。

独立三轮反例（无受袭、M01 done、宽限期已过、没有其他任务失败）：

| 场景 | tick 100 | tick 101 | tick 102 |
|---|---|---|---|
| 工人 6→0→0 | inactive | econ_unit_loss active | inactive，仍是 0 工人 |
| 矿场 1→0→0 | inactive | econ_facility_loss active | inactive，矿场仍未恢复 |

最低补验：把异常触发与恢复解除分开保存；故障在恢复条件未达成前保持，事实不足另记 unknown。必须有多轮“损失后仍未恢复”的反向测试，再验证有真实恢复证据后解除。

### R6：持续支出会掩盖交货中断

位置：[economy_recovery.py post-delivery 判定](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/economy_recovery.py:203)。

post_delivery_stall 要求交货数、余额和施工签名同时不变。余额因支出下降时会清零停滞起点；没有新增交货仍会被当作“有变化”。

独立对照使用相同交货数 3、相同建筑及工人、跨越停滞时间窗：固定余额时产生 post_delivery_stall；每次观测花掉 100 时，余额 1000→600，五次观测全无异常。

最低补验：经济进展基于真实交货／入账及相关执行进展，支出不应抵消收入链停滞；覆盖持续生产花钱但没有收入的轨迹。

## P2：追踪仍有完整性和上界缺口

1. [trace.py 索引](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/trace.py:303) 只限制每个 ID 的 deque 长度，没有限制字典键数。独立写入 1,000 条不同命令后，内存环只有 4 条，命令索引仍保留 2,000 个 ID，index_limit=64 不能约束总大小。应随环淘汰／用总量受限索引。
2. 原 600 秒 trace 中 **1,559 条 dropped 命令事件的 task_id 全为空**，仅 123 条 receipt 有 task_id。代码从丢弃结果读取 task_id，但许多丢弃结果只包含 intent_id 和 reason。需要用原始候选补充关联；不能概括为每条未下发任务都能直接完整回溯。

以上不否认回放可以按其他原件进一步关联，但当前追踪合同本身没有满足完整字段保证。

## 版本与证据边界

原 600 秒运行期间 source-before/source-after 未变，与“当前最终源码已获 600 秒验证”是两件事。独立比对发现当前 graph.py、task_loop.py 与 match-600s-b 冻结 hash 不同。graph.py 匹配后续 match-smoke-final，task_loop.py 与该 90 秒冒烟的冻结 hash 也不同；原报告说明了最后补追踪指标等后续变动。不能据此断言所有差异都是行为回归，但最终版本的验证层级必须分别标清。

本次局部探针对七份生产文件记录前后 hash，复核期间全部不变；这些缺陷来自已存在的实现，没有通过临时改生产代码制造。

## 复现命令与原始结果

```text
工作目录 G:/AIRTS/AI_RTS/source/adjutant_coordinator/tests
G:/AIRTS/临时文件夹/airts_agent_venv/Scripts/python.exe -B -m unittest test_decision_trace test_task_loop test_economy_recovery
rc=0，64 tests，OK

G:/AIRTS/临时文件夹/airts_agent_venv/Scripts/python.exe -B C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/audit_phase1_independent.py
rc=0，成功运行独立反例探针并核对现有 trace；此 rc 不代表产品门槛通过

G:/AIRTS/临时文件夹/airts_agent_venv/Scripts/python.exe -B C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/audit_phase1_trace_followup.py
rc=0，输出预算耗尽后回执位置、缺失 task_id 数量及版本身份比对
```

- [独立探针结果](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/phase1-independent-audit.json)
- [原局回执和版本复核结果](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/phase1-trace-followup.json)
- [原 600 秒追踪](G:/AIRTS/AI_RTS/agent/runs/2026-10-15-adjutant-phase1/round-04/match-600s-b/runner-logs/trace.jsonl)

## 本轮范围、未验证项与后续顺序

开发根 G:/AIRTS/AI_RTS；新增本报告、对应计划和审查提示词，三个文件开发边界检查均 rc=0。共享 dirty tree 保留，未修改任何生产代码、现有测试、原运行证据或原候选记录；只运行不会连接游戏／模型的测试及自有探针。

未重新运行真实 Match、600 秒观察、全量游戏回归或浏览器视觉验收，没有新增截图。因此独立探针证明的是上述局部缺陷，不是修复结果；原报告中“所有旧失败都是基线”也没有在本次全面复验，不当作新的独立结论。

建议先返修 R1～R6，以任务级执行和真实结果判据补齐第 1～3 项，同时修正追踪上界及缺失关联。完成后再验证 NoValidSite 的几何／可见性／选址链，取得至少一条真实经济恢复后交货的完整轨迹。现有 NoValidSite 是实际拒绝原因，但“它是唯一剩余问题”没有成立。

不提升 champion，连续未提升计数本轮保持原登记值 1，不自行把这次文档审查计为新产品候选轮。产品保持 needs-review。
