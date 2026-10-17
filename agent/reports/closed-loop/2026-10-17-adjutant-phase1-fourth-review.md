# 副官第一阶段第四轮独立复核：D1–D4 返修与 round-07

- 完成日期：2026-10-17（接续 2026-10-16 中断的审查）。
- 开发根：`G:/AIRTS/AI_RTS`；Git HEAD：以本轮 [identity.json](C:/Users/Administrator/.codex/visualizations/2026/10/16/01a14571-751b-7ad0-a09f-6d3f35356522/phase1-fourth-review/identity.json) 为准。
- 范围：只读审查产品源码、已有测试和 round-07 原始证据；新增独立探针、审查产物和本报告，更新第四轮计划。未修改产品代码、已有测试断言、旧报告或 champion。
- 计划：[第四轮计划](G:/AIRTS/AI_RTS/agent/plans/2026-10-16-adjutant-phase1-fourth-review.md)；提示词：[第四轮审查提示词](G:/AIRTS/AI_RTS/agent/prompts/2026-10-16-adjutant-phase1-fourth-review.md)。
- **审查已完成；产品结论仍为 needs-review，不建议晋级。**

## 1. 核心结论

D1 的 Accepted 正常等待、D3 的直接工地判据、D4 的规则视图类型映射以及首采前完成的归因均有有效改进，但当前实现仍有四项 P1 缺口。其中尝试污染已在最终 180 秒真实 Match 的原始记录和 checkpoint 中得到印证，不能把它解释成仅有人工夹具才会出现的问题。

| 项目 | 本轮结论 | 证据能力 |
|---|---|---|
| D1：Accepted 不立即消耗失败预算，随后自身订单可成功 | 原直接反例已修；PendingAuthority 边界未修 | 独立正反探针，见 E1；最终局没有 PendingAuthority 回执，不能声称该网络路径已在对局中验证 |
| D2：按 intent/command 绑定尝试 | 未满足：同 tick 旧意图仍可认领；新尝试继承旧回执 | 独立反例 + 最终对局 seq/checkpoint，见 E2 |
| D3：指定工地丢失不认领别处完工 | 直接传入正确 facts 时已修；实际观测解析未接通工地身份 | 独立调用真实 `campaign.build_facts → evaluate_record`，见 E3 |
| D4：scene+producer 解析类型 | 有效修复 | 用合法合同、任意任务 ID、`Infantry→soldier` 非同名映射验证初次登记及计划先于动作的补全 |
| P2：建立后、首采前已经完成的本订单 | 身份明确时可成功；相关现有测试通过 | 不能推广为任意只有 producer/item 的台账都能正确归因 |
| 调度与执行预算分离 | 台账和 checkpoint 确实分离；追踪呈现不完整 | 零下发探针 `retries_used=0 / schedule_waits=3`；对局 checkpoint 有实际值，但 task trace 无结构化计数字段 |
| 未知完工事实 | 当前仍能被当作类型完工，见 E4 | 独立观测解析反例；没有声称最终局触发了缺字段观测 |

本轮重跑 **95 + 149 = 244 项相关测试，均 rc=0**；另外建立 **14 组独立正反探针**，确认以上已修行为和剩余缺陷。探针 rc=0 表示“预先声明的行为及反例按断言复现”，不表示产品验收通过。

## 2. E1 / P1：等待权威确认被结算为失败，后续终态又被去重

位置：[尝试回执分类](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_loop.py:598)、[按身份去重](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_loop.py:1053)。真实接入路径：[下发保存首份回执](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/nodes.py:3691)、[PendingAuthority 保留等待](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/nodes.py:3823)、[后续回执复核](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/nodes.py:4049)。

`diagnose` 以 `not accepted` 判定拒绝，没有先检查 `status` 是否为终态。正常的 `PendingAuthority / accepted=false` 因此被计为 `execution_failed`。这与既有协议“等待权威确认不等于失败”的语义冲突。

独立复现：tick 100 授权 attempt=1，单次预算；tick 101 本次指令返回 PendingAuthority，立即得到 `blocked / retries_used=1 / attempt_fail_kind=execution_failed`。tick 102 同一命令返回 Accepted，记录仍保留 PendingAuthority。另一个隔离同步反例证明：即使尚未计预算，`intent_id|command_id` 相同也会把后到的 Accepted 当重复事件丢掉。

因此这里有两个相邻缺口：非终态误分类，以及同一命令的状态推进被当作重复回执。权威图的 pending 处理本身保留了等待，错误发生在新增闭环台账的二次结算中。

**返修验收：** PendingAuthority/Unknown 保持未知或等待；明确拒绝才记拒绝；相同命令允许非终态升级为终态，重放同一终态不重复结算。至少覆盖 Pending→Accepted→真实完成、Pending→Rejected、Unknown→终态和乱序终态，且保持命令级接受与游戏实际完成的区分。

探针组：`E1_pending_is_failed_and_final_receipt_not_adopted`、`E1_same_identity_status_update_deduped`。正向对照：`D1_accepted_then_own_completion_fixed`。

## 3. E2 / P1：尝试仍靠 tick 切分，且新授权没有清空旧尝试的关联

位置：[issued_tick 筛选](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_loop.py:1041)、[继承已知 intent](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_loop.py:1044)、[新恢复授权](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_loop.py:685)。

本轮确认两条独立失败路径：

1. 授权前已存在的命令若 `issued_tick=100`，而新授权也发生在 tick 100，`issued_tick >= started` 仍把旧意图纳入新尝试。两次同 tick evaluate、没有新增命令，单次预算即被旧拒绝耗尽。原第三轮反例中的 issued_tick=50 已被拦住，但不能据此认为同 tick 顺序已可靠区分。
2. 授权 attempt=2 时只更新 started/count 标记，没有清空或重新归属 `attempt_intents`、`attempt_receipts`。独立轨迹 tick 100 授权、101 拒绝，401 授权第二次、402 无新命令，`retries_used` 仍从 1 变为 2；结算的仍是第一次回执。

### 最终 180 秒对局中的同一问题

证据：[原始 trace](G:/AIRTS/AI_RTS/agent/runs/2026-10-15-adjutant-phase1/round-07/match-d-rework-final/runner-logs/trace.jsonl)、[本轮提取的事件与 checkpoint 对照](C:/Users/Administrator/.codex/visualizations/2026/10/16/01a14571-751b-7ad0-a09f-6d3f35356522/phase1-fourth-review/runtime-findings.json)。

| seq | round | tick | 炼矿厂任务事件 |
|---:|---:|---:|---|
| 267 | 8 | 1016 | 原指令收到 Rejected |
| 283 | 9 | 1016 | 随后授权闭环 attempt=1，已结论 0/3 |
| 309 | 9 | 1016 | 再次记录 Rejected，与 seq 267 的 intent_id、command_id 完全相同 |
| 954 | 28 | 1119 | 授权 attempt=2，已结论 1/3 |
| 4928 | 140 | 1684 | 授权 attempt=3，已结论 2/3 |
| 4965 | 141 | 1684 | 执行预算耗尽，失败 3/3、调度等待 0/3 |

全局扫描该任务仅有上述 **2 条 receipt 事件、1 个唯一 command_id**。第 2、3 次闭环授权之后没有新的该任务命令回执。checkpoint 仍保留：

- `attempt_started_tick=1684 / attempt=3 / retries_used=3`；
- `attempt_intents` 只有 `rule-build-ore_refinery-Unit_3-1016`；
- `attempt_receipts` 只有该旧命令的拒绝，保存 tick=1022；
- 当前意图中的 issued_tick=1016，早于后两次授权。

这里的 command 事件 `attempt=1/2` 是既有意图下发计数，task 事件 `attempt=1/2/3` 是闭环授权次数，两者不能混算。seq 309 说明发生过旧命令的再次下发/回执，不能描述为“从未重发任何命令”；但它没有提供三次各自独立的恢复执行证据。

**返修验收：** 给授权、实际提交和尝试建立稳定身份或单调序列，不能仅靠 tick；每次尝试的意图/命令/回执集合有明确归属，历史结论独立保留且只消费一次。覆盖同 tick 授权前后、同一 intent 多次提交、旧回执晚到、第二次授权无下发、重放和状态恢复。重放上述真实轨迹，零新增执行不能再被计成多次执行失败。

探针组：`E2_old_intent_issued_50_before_authorization_100`（已修对照）、`E2_old_intent_issued_100_before_authorization_100`、`E2_previous_attempt_receipts_burn_second_attempt`。

## 4. E3 / P1：真实观测中的指定工地没有进入 own_constructed

位置：[归一化实体表](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/observation_view.py:127)、[建立工地事实](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/campaign.py:427)、[闭环实际入口](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/nodes.py:894)。

`normalized_units` 将实体名放在字典键中，值里没有 `name`。`build_facts` 却遍历 `by_name.values()`，再从值的 `info.get('name')` 取名字，因而不能填入 `own_constructed`。

本轮把真实形状的观测 `kind=unit_self / name=SiteA / unit_type=ore_refinery / constructed=True` 交给实际 `campaign.build_facts`，结果类型完工数为 1，但 `own_constructed={}`。再交给指定 SiteA 的任务，结果为 `unknown / 指定工地不在观测中`，没有成功。不是在探针里手工构造一个空工地表来制造反例。

直接传入 `own_constructed={'SiteA':True}` 的 D3 判据是有效的；已有测试恰好覆盖这一层，遗漏了从观测解析到判据的接线。最终对局成功的生产任务不能证明指定工地路径通过，最终炼矿厂任务使用的是 `attribution=type`。

**返修验收：** 从唯一实体解析层正确传递实体身份，使用完整观测→facts→闭环入口验证：SiteA 未完工、真实完工、消失、只有 SiteB 完工、SiteA 重现；不能只直接灌入 `own_constructed`。

探针组：`D3_stable_site_attribution_fixed`（直接判据正反对照）、`E3_real_named_site_true_still_missing`。

## 5. E4 / P1：constructed=None 仍被当成“类型已完工”

位置：[类型完工计数](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/campaign.py:432)。

唯一观测解析层明确保留 `constructed=True / False / None=未知`。但类型计数使用 `info.get('constructed') is not False`，使 None 也进入已完工计数。

独立反例：tick 100 没有炼矿厂，类型基线采为 0；tick 110 出现 SiteA，但原始观测 `constructed=None`。实际 `build_facts` 给出 `constructed['ore_refinery']=1`，普通类型建造任务随即被判 `succeeded / success_evidence`。缺字段经归一化同样得到 None，因此这个问题不限于显式写 null。

这属于当前实现中既有的事实语义缺口；本轮没有将它归因于本次返修引入，也没有声称最终 Match 已出现未知完工字段。它仍违反本阶段“缺测写 unknown、建筑成功必须有完工观测”的验收要求。

**返修验收：** 只有明确完成的权威事实才进入完成计数；未知、缺失、未完工分别保留其语义。使用相同的真实观测解析入口验证 True/False/None/缺字段，以及消费者的阶段晋升，不能仅替换日志文案或放宽测试。

探针组：`E3_constructed_None_falsely_completes_type_task`。

## 6. 另外核对的 P2 边界

### producer/item 事实不等于唯一任务归因

合法的 `scene+producer` 合同已能解析产品类型，但 `sync_ledger` 的 `target_key` 仍取 entity_id/scene，通常保存的是场景路径。一个已知 `intent.production.item_id`、而生产事件台账只带 item 键、producer、finished_tick 的样本，没有沿 item_id 认领，仍 waiting。真实快速事件确实可以先形成这种不带 intent/product 的条目，见 [事件台账接入](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/nodes.py:714)。

另一方面，`metric_value` 允许仅按 producer 匹配并接受缺失 product_id；当记录已有 `target_key=Factory` 时，两条不同 intent 的任务会认领同一个缺身份条目。该后者是兼容/直接台账边界，正常 scene+producer 路径并不会自动生成这个 target_key；本轮没有把它冒充最终对局已发生的串单。

因此修复不能只是把 `target_key` 改成 producer。应优先使用已绑定的 item_id / intent / command，只有生产者事实而无法唯一归属时保持证据不足。探针：`P2_item_and_producer_only_not_attributed`、`P2_producer_fallback_shared_identity_unsafe`。

### schedule_waits 已持久化，但还不能完整按时间回放

独立零下发轨迹结束时 `schedule_waits=3 / retries_used=0`，预算区分成立。旧对局 checkpoint 也确实保存了计数：长局车厂任务为 3，最终局为 1，因此不能指控“没有持久化”。

但两个样本的 task 事件中包含 `schedule_waits` 字段的数量均为 0，`task_loop_report.tasks` 也没有两个预算计数。最终局从首次等待到第二次授权期间，trace 仅见授权次数与“已结论 0/3”的文案，不能据此完整重建一次调度等待何时计入、当时预算是多少。建议在关键状态变化中结构化记录分开的计数、预算及本次尝试关联，仍聚合无变化轮询。

## 7. round-07 原始运行证据重算

| 项目 | 240s 请求的 gate 局 | 最终 180s 局 |
|---|---:|---:|
| 有效 round begin / 有效事件 | 466 / 16,940 | 336 / 11,969 |
| 有效事件 seq 连续 | 是 | 是 |
| trace 解析失败行 | **1：末行 38,775 字节 NUL** | 0 |
| summary 实际状态 | observing，缺结束/清理字段 | observed |
| 实际完整观察时长 | 无结束记录，不能确认 240 秒完成 | 180.000518 秒 |
| 世界样本末次相对墙钟 | 215.192 秒 | 175.145 秒；总观察末尾没有同频世界快照 |
| success_evidence | 3 | 3 |
| recovery_attempt | 10 | 5 |
| awaiting_attempt_result / attempt_in_flight | 6 / 3 | 2 / 0 |
| retry_budget_exhausted | 6 | 1 |
| blocked-plan 丢弃 / dropped 缺 task_id | 282 / 0 | 59 / 0 |
| receipt/recheck 状态 | Accepted 43、Rejected 3 | Accepted 27、Rejected 2 |
| 冻结文件与当前 SHA256 相符 | 62/62 | 62/62 |
| source-before/source-after | 缺 after，无法确认前后冻结 | 两份完全一致 |
| 清理证据 | summary 无完整清理，不能替它补造成功 | runner/game alive=false、rc=0、forced=[] |

长局能证明其有效前缀中出现过 3 条 attempt_in_flight；但不能再称“trace 文件完整”，也不能把请求时长当作已完整采样时长。本轮未修改 NUL 尾部或重写原 summary。最终局文件没有同样的解析问题。

当前 `task_loop.py` SHA256：`c97019c53c23c9741b9dab9b718267cb3dc0311a05313f43aacf4eab6c0e796a`。两个样本登记的 62 文件均匹配本次审查源码；这比 Git 的 dirty 描述提供了更明确的版本身份。当前审查期间另对 **111 个图模块、测试文件及 champion 文件**比对 hash 与 mtime，前后完全一致。

最终局源码身份和已有进程命令行已核对：Godot `--headless --path G:/AIRTS/AI_RTS`、种子 11；原 summary 记录的 game PID 40024、runner PID 40116 均已正常退出。这里只是复核历史运行证据，没有启动或清理新的游戏进程。

重算产物：[runtime-audit.json](C:/Users/Administrator/.codex/visualizations/2026/10/16/01a14571-751b-7ad0-a09f-6d3f35356522/phase1-fourth-review/runtime-audit.json)。

## 8. 本轮验证、改动与限制

解释器：`G:/AIRTS/临时文件夹/airts_agent_venv/Scripts/python.exe`。测试工作目录：`G:/AIRTS/AI_RTS/source/adjutant_coordinator/tests`。

| 命令（以上述解释器执行） | 结果 |
|---|---|
| `-B -m unittest test_task_loop test_economy_recovery test_decision_trace` | 95 项，rc=0，OK |
| `-B -m unittest test_graph_runtime_fake test_intent_arbitration test_campaign_mainline test_graph_state_channels test_graph_state_checkpoint` | 149 项，rc=0，OK；保留原有未关闭文件句柄 ResourceWarning |
| `-B <fourth_review.py>` | rc=0；14 组独立探针按断言复现，重算两个 Match，执行上述两组测试，检查源码/测试/champion 稳定 |
| `python tools/check_workspace_target.py --mode develop --target <本轮计划/报告绝对路径>` | 各 rc=0；Git 根为 `G:/AIRTS/AI_RTS` |

原始审查产物：

- [独立审查脚本](C:/Users/Administrator/.codex/visualizations/2026/10/16/01a14571-751b-7ad0-a09f-6d3f35356522/phase1-fourth-review/fourth_review.py)、[完整探针输出](C:/Users/Administrator/.codex/visualizations/2026/10/16/01a14571-751b-7ad0-a09f-6d3f35356522/phase1-fourth-review/probes.json)。
- [测试命令、时刻及 rc](C:/Users/Administrator/.codex/visualizations/2026/10/16/01a14571-751b-7ad0-a09f-6d3f35356522/phase1-fourth-review/tests.json)、[95 项日志](C:/Users/Administrator/.codex/visualizations/2026/10/16/01a14571-751b-7ad0-a09f-6d3f35356522/phase1-fourth-review/targeted-tests.log)、[149 项日志](C:/Users/Administrator/.codex/visualizations/2026/10/16/01a14571-751b-7ad0-a09f-6d3f35356522/phase1-fourth-review/adjacent-tests.log)。
- [审查前文件身份](C:/Users/Administrator/.codex/visualizations/2026/10/16/01a14571-751b-7ad0-a09f-6d3f35356522/phase1-fourth-review/source-before.json)、[审查后文件身份](C:/Users/Administrator/.codex/visualizations/2026/10/16/01a14571-751b-7ad0-a09f-6d3f35356522/phase1-fourth-review/source-after.json)。

仓库写入范围仅为本报告和第四轮计划；聊天产物目录增加本轮自有脚本、JSON、日志与审查记录。共享工作区原有大量未提交改动保持原状，未 reset/clean、切分支、提交、修改测试断言或覆盖他人工作。本轮检查到的 111 个受保护文件前后未变；其他共享文件未据此被宣称全局冻结。

**未验证：** 本轮没有重启 Match、没有新的 UI-player/可见窗口/录像/截图（截图路径：无，不适用只读审查），没有重新跑全量 1,130 项、dotnet/Godot 全量回归或最终代码的 600 秒观察，也没有重新验证追踪开销、异常终止和正常退局重开的全部矩阵。原长局、旧截图和测试绿不能替代这些未覆盖项。“全量只有 4 个基线红”是实施记录的结论，本轮没有独立重证。NoValidSite 和真实经济恢复仍未由本轮解决。

## 9. RSI 决策与下一轮门槛

- 被审候选：`cand-phase1-d-rework`（round-07）。独立审查结论 **needs-review，不建议晋级**。
- champion 仍为原登记基线 `4851de361b4c924cde0eacbe2d113b14fc6c9798+dirty`；本轮未修改 champion、promotion_history 或既有 checklist 的 fixed 标记。
- 登记的连续未提升轮数保持 **1**；这是只读复核，不新增产品候选，也不虚增计数。
- 质量比较：Accepted 直接路径、工地判据的局部逻辑、scene 规范类型解析已改善；尝试因果绑定在真实对局仍失败，工地观测接线和未知事实也未过门槛，因此没有 S3 晋级依据。

下一次返修先处理 E1/E2 的回执终态与尝试身份，再修 E3/E4 的事实接入与未知语义；逐项把这里的独立反例转为正式回归，并按单补丁新 Match 闸门验证旧链路。保留已通过的 D4 非同名/后补映射以及身份明确的生产成功路径。完成相关回归和独立复核后，补最终源码的 600 秒观察及其追踪回放；不能仅增加 Accepted 或 D2 可选次数就宣布经济闭环完成。
