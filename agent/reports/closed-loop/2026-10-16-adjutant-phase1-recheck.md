# 副官第一阶段返修：第二次独立复核

**结论：返修确有成效，但核心执行闭环仍需返修，产品保持 needs-review。** 上次的旧事实立即判成功、损失只报一轮、花钱掩盖断交货、追踪索引无上界和 dropped 缺任务关联等反例已有有效修复；不能沿用上轮结论说它们完全没改。但“R1–R6 + P2 全部修复”仍不成立：战略任务的动作信息可能永远补不齐，恢复预算可以在零下发时耗尽，冷却及条件重评没有完整控制执行，任务结果归因也仍有缺口。

本次只审查代码、运行离线测试和自有探针、核对既有真实对局原件。**未修改产品代码、既有测试或原始证据，没有新开游戏或调用模型。** 本报告对应 [复核计划](G:/AIRTS/AI_RTS/agent/plans/2026-10-16-adjutant-phase1-recheck.md) 和 [可复用提示词](G:/AIRTS/AI_RTS/agent/prompts/2026-10-16-adjutant-phase1-recheck.md)。

## 先确认有效修复

| 上轮问题 | 这次独立结果 | 状态 |
|---|---|---|
| R1：受阻台账完全不约束执行 | 实际 node_arbitrate_intent 已能拦截命中的受阻方案；新局有 187 条此类丢弃。但冷却与重评授权仍有缺口，见 C2/C3 | 部分修复 |
| R2：旧到达、已存在产品立即算新任务成功 | tick=5 的旧到达不再完成 tick=100 的任务；已有 1 辆坦克也不再立即完成新生产任务。但全局增量仍会跨订单共用，见 C4 | 部分修复 |
| R3：已知任务到总期限后 ended=true，无法诊断 | 原跨轮反例现在能走 total_deadline → diagnosing → recovering，ended=false。新局没有 total_deadline 事件，不能说本局真实覆盖了超时边；无类型任务另见 C1 | 原反例已修，范围有限 |
| R4：恢复状态刷新实际进展／无执行也计尝试 | diagnose 不再把 last_progress 从 100 改到 1000；但零执行仍会计满重试，见 C2 | 部分修复 |
| R5：损失只持续一轮 | 工人 6→0→0、矿场 1→0→0 的原反例均持续 active | 原反例已修 |
| R6：支出掩盖交货中断 | 交货固定 3 次、余额 1000→600 的原轨迹，在 tick=700 起仍报 post_delivery_stall | 原反例已修 |
| P2-1：索引键数无上界 | 1,000 个不同命令、memory_limit=4、index_limit=64，当前内存事件 4 条、命令索引 64 键；原为 2,000 键 | 原反例已修 |
| P2-2：丢弃事件缺 task_id | 新局 316 条 dropped，316 条均有 task_id；旧 600 秒局为 0/1,559 | 新局已证实修复 |

旧探针直接调用 arbitrate_intents，绕过这次新增的节点过滤，仍会得到 accepted。**这不能再用来证明 R1 完全未修。** 本次补充调用实际 node_arbitrate_intent，确认过滤确实生效后，再测冷却和跨轮重评。

## C1 · P1：先建立计划、后产生动作，任务可能始终没有可评估类型

位置：[task_loop.py 台账同步](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_loop.py:587)、[缺证据提前返回](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_loop.py:355)。

sync_ledger 首次看到 active_tasks 时若没有活动意图，会建立 kind=""、progress_metric="" 的记录。后续意图到来，已存在记录的分支只补 order_key，然后 continue；单位、任务类型、目标和指标都不补。evaluate_record 又在 evidence_missing 时提前返回，位于 deadline 判定之前。因此这类任务即使超过总期限，也没有沿超时边进入诊断。

独立复现包含两层：

- 完整图测试夹具按既有路径运行：先采纳计划，再在 tick=5 接受并向通道桩下发模型的 i-1 移动命令，tick=100 后权威任务状态 running；新台账仍为 pending、kind/metric/units 为空、attempt=0，只有 order_key=t-1|move|10,10。这是实际图节点链，使用假模型和通道桩，未向游戏发命令。
- 跨期限反例：任务建立 tick=100，后续补合法生产意图；在 tick=1,000,000 评估，deadline_tick=3,700，仍为 pending/evidence_missing、attempt=0、changes=[]。

真实 150 秒局最终 checkpoint 中，战略任务 rebuild_refinery 也有 kind/metric/units 为空、pending、attempt=0 的同类现象。但该真实样本没有超过自身期限；“超过期限仍不诊断”由上述独立反例证明，不冒充真实局已覆盖。

**影响：战略任务可在真实命令链上活动，新闭环却无法监督它；一直显示“证据不足”也不能定位期限后的明确去向。**

最低补验：在动作合同确定时绑定或补全任务类型、单位、目标、基线与身份；缺证据本身也要有有界等待和诊断出口。覆盖计划先于动作、动作目标更新、首份结果先于登记等顺序，不能只用规则任务 ID 可推类型的案例。

## C2 · P1：恢复预算仍按时间消耗；第 3 次尝试可能下一轮就被拦

位置：[diagnose 增加 attempt/retries_used](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_loop.py:512)、[先检查预算、后检查冷却](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_loop.py:489)、[每轮恢复态继续诊断](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_loop.py:843)。

last_progress 的修复是有效的，但 attempt_started_* 只是新命名。当前 diagnose 在冷却到期时直接加 attempt/retries_used，不要求恢复动作进入候选、获仲裁采纳、实际下发或得到结果。达到预算后，又在检查当前尝试冷却之前转 blocked。

独立反例保持事实不变，始终没有候选、下发或回执：

| tick | 台账 | attempt / retries_used | 事实 |
|---:|---|---:|---|
| 100 | waiting | 0 / 0 | 正常建立 |
| 102 | recovering | 1 / 1 | deadline 进入诊断 |
| 403 | recovering | 2 / 2 | 仅时间过去 |
| 704 | recovering | 3 / 3 | 仍无命令；冷却至 1004 |
| 705 | blocked | 3 / 3 | 尚未等到 1004，就因预算耗尽转受阻 |

**全过程 command_receipts=0。** 这说明计的是诊断授权次数，不能直接称为实际恢复尝试次数；第三次授权也没有独立等待结果的生命周期。

真实新局同样提供证据：矿场最初在 tick=706、786 收到 NoValidSite 回执，此后没有该任务新的建造回执；却在 tick=1066（seq 3856）、1369（seq 5982）记录第 2、3 次恢复，并在同 tick=1369 的下一轮（seq 6018）转预算耗尽。零后续回执不能单独说明它正确约束了三次真实恢复。

最低补验：分开恢复建议、获准、待执行、已下发、等待结果和本次尝试结束；attempt 必须与实际动作身份关联，明确什么事件消费预算。未调度、被资源门禁挡住、尚在执行的动作不能因计时被记成多次失败。最后一次已授权尝试应能等到自己的结果／期限。

## C3 · P1：冷却不拦实际候选；条件重评会先开执行门，再做预算诊断

位置：[blocked_order_keys 仅检查 blocked](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_loop.py:679)、[受阻重评分支](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_loop.py:764)、[仲裁过滤](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/nodes.py:3463)。

目前门禁只拦 state==blocked，diagnosing/recovering 的失败方案均不被该门禁拦截，也不检查 cooldown_until_tick 或当前执行许可。

用同一个合法生产候选调用实际节点，结果如下。观测、权限和现有资源门禁一致，只有台账条件变化：

| 条件 | 实际节点结果 |
|---|---|
| blocked，预算耗尽 | 被 task_loop_blocked_plan 丢弃，证明新增门禁有效 |
| recovering，cooldown_until_tick=10000，当前 tick=100 | accepted，进入 dispatch_pending |
| blocked，attempt=retries_used=budget=3；事实签名变化后只运行本轮 evaluate | 状态变 diagnosing，预算仍为 3/3，没有新恢复授权；同方案已 accepted，进入 dispatch_pending |

第三种来自重评分支改变状态后直接 continue；本轮尚未重新 diagnose，blocked 键却已失效。探针使用生产任务，工人数变化即可改变签名；它不是本次生产订单的新执行许可。下一轮可能再次受阻，但本轮候选已可下发。

**这不是要求冻结所有正常动作。** 应按具体失败方案／尝试保留执行许可，在同一轮完成前置核验和预算决定后再开放；冷却约束新重试，不能阻止合法在途动作继续完成。换目标、换动作和其他任务的独立路线仍应可执行。

真实局预算耗尽后矿场回执为 0；rule-gather 仍有 3 条回执，实施方注明来自其他分配。这里不把那 3 条一概判为违规，也不把“矿场为 0”概括为所有任务预算约束已通过。上表缺口由实际节点独立反例证明。

## C4 · P1：全局增量仍可被多个独立任务同时认领

位置：[生产指标读取全局 counts](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_loop.py:228)、[统一与 baseline 比较](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_loop.py:271)。

基线修复挡住了“旧坦克立即完成新任务”，但没有补齐“这次新结果属于哪条订单”。独立建立 order-A/P1 与 order-B/P2 两个生产任务，分别记录基线 0；只给 A 的回执和 1 个新增 tank 的世界事实，两个任务都返回 succeeded/success_evidence。B 没有自己的部署证据，其单位和订单也没有参与指标判定。

建造读取全局同类型完工数，同样存在归因不足。若某条任务本来就定义为共享里程碑“世界上新增一座／一个即可”，可以使用共享证据，但必须与具体建造／生产订单的成功合同区分，不能统一记为各订单完成。

新局 4 条 success_evidence 确有任务基线后的增量／匹配目标到达证据，不能说这 4 次全是假成功；它们也不能覆盖并发订单／无关新实体的反例。

最低补验：使用任务／订单／部署实体或工地的关联事实，覆盖并发同类型订单、其他生产者完成、玩家自行建造和任务改目标；共享目标完成与执行任务完成分开判定。

## C5 · P2：降低重复事件时，漏记了真正增加的 attempt

位置：[诊断事件去重](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_loop.py:844)。

当前去重只比较 outcome 状态与 diag_code；冷却跨过后，即使 attempt 从 2 变 3，只要前后都是 recovering/recovery_attempt，就不写 changes，追踪也无事件。C2 的独立反例在 tick=704 确认 attempt=3、changes=[]。下一轮能直接出现 attempt=3 的预算耗尽，时间线缺失第 3 次授权。

最低补验：事件去重应保留 attempt／方案／授权身份变化；相同状态、相同原因码但新尝试是新事件。把无意义轮询合并，与丢弃真实尝试变化分开。

## 新对局原件与版本身份

本次独立读取 round-05/match-rework-final2 原始追踪、summary 和 source-before/source-after，确认：

| 项 | 独立结果 |
|---|---|
| 对局时长 | 约 150 秒；不是返修后的新 600 秒证据 |
| 轮数／事件 | 503 / 18,005 |
| command | 46 receipt、316 dropped；dropped 缺 task_id 为 0 |
| 受阻方案丢弃 | 187 |
| 新台账成功 | success_evidence 4；另有既有 progress 层 completed 13，不混作同一判据 |
| 恢复／预算耗尽／冷却事件 | 6 / 3 / 4；这些是日志事件数，受 C2/C5 限制，不能等价为执行次数 |
| total_deadline | 0；本局没有真实覆盖超时边 |
| source freeze | 运行前后相同；冻结清单 62 个文件与本次当前文件全部匹配 |
| 清理记录 | summary 记录自有 runner/game alive=false、rc=0、forced=[]；本次未重新检查运行当时的系统状态 |
| 经济恢复后交货 | 尚无真实恢复样本，NoValidSite 仍存在；不能说它是唯一剩余问题 |

当前 task_loop.py SHA256 为 4af22a0e938bbbf63e8c864ee1a46f97c597fa73e5f2a6802c2bbdeac97ae3c4，与 final2 冻结一致。实施报告表格写的 dfcbaf（当前树）前缀需校正，这是文档不一致，本次没有发现 final2 与当前树的实际版本缺口。

原 600 秒局保留作返修前基线，不能替代返修后的长时间验收。不同长度／状态的对局 p50 差异也不足以单独证明没有性能回归。

## 复现、结果与原件

以下均使用 G:/AIRTS/临时文件夹/airts_agent_venv/Scripts/python.exe -B；单测工作目录为 G:/AIRTS/AI_RTS/source/adjutant_coordinator/tests。

```text
-m unittest test_decision_trace test_task_loop test_economy_recovery
rc=0，77 tests，OK

-m unittest test_graph_runtime_fake test_intent_arbitration test_campaign_mainline test_graph_state_channels test_graph_state_checkpoint
rc=0，149 tests，OK
有 test_graph_state_channels 的文件句柄 ResourceWarning，未出现测试失败。

audit_phase1_independent_1016.py
rc=0；旧反例重放与原 600 秒日志读取

recheck_phase1_edges_1016.py
rc=0；实际节点、跨轮预算、完整图夹具、跨订单归因及漏记尝试均按预设断言复现

recheck_phase1_runtime_1016.py / recheck_phase1_runtime_brief_1016.py
rc=0；新局原件统计与关键事件位置

recheck_phase1_identity_1016.py
rc=0；62 个冻结文件无缺失、无 hash 不一致；审查源文件期间未变
```

**探针 rc=0 表示探针正常运行并验证了预期缺陷，不表示产品门禁通过。** 第一版新增探针因缺少合法 produce target.producer 被契约门禁挡住；补齐探针合同字段后才得到上文候选接受结果，未修改产品契约或放松断言。

自有复现脚本与新结果目录：C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/。

- [旧反例本轮结果](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/phase1-independent-audit-1016.json)
- [新增边界反例与完整图复现脚本](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/recheck_phase1_edges_1016.py)／[结果](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/phase1-edge-recheck-1016.json)
- [新对局读取结果](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/phase1-runtime-recheck-1016.json)／[源码身份结果](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/phase1-identity-recheck-1016.json)
- [150 秒原始追踪](G:/AIRTS/AI_RTS/agent/runs/2026-10-15-adjutant-phase1/round-05/match-rework-final2/runner-logs/trace.jsonl)／[该局源码冻结](G:/AIRTS/AI_RTS/agent/runs/2026-10-15-adjutant-phase1/round-05/match-rework-final2/source-before.json)

## 范围、风险与下一步

主工程身份、根目录和本次三个文档编辑目标的开发边界检查均 rc=0。本次只新增本报告、计划、提示词及自有审查产物；共享 dirty tree、运行代码、原测试和原证据保持。源文件 hash 在独立探针前后一致，并与最新对局冻结再次核对；未覆盖其他会话工作。

未新增真实 Match、600 秒观察、截图／录像、玩家 UI 验收或全量游戏回归；因此截图路径为无，不把既有截图当本轮证据。此次复核的 226 项相关单测均通过，但没有重新独立验证实施报告中“全量四红均为基线”的结论。

建议先返修 C1，再统一处理 C2/C3 的尝试与执行合同，同时补 C4 结果归因和 C5 追踪完整性。然后用冻结版本取一条“失败 → 合法恢复实际下发 → 新结果／交货 → 异常解除”的真实轨迹，配对验证冷却、预算耗尽和无执行时的行为，最后处理长时间观察与放置链问题。

本轮为独立审查，不创建新产品候选、不提升 champion，不修改连续未提升计数（沿用已登记的 1）。产品仍为 needs-review，不能按第 1–3 项完成标准验收。
