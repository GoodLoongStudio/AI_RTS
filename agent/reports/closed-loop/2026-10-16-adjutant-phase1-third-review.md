# 副官第一阶段第三轮独立复核：C1–C5 第二轮返修

- 日期：2026-10-16
- 开发根：`G:/AIRTS/AI_RTS`
- 范围：独立审查当前代码、复现边界反例、核对 round-06 原始证据；未修改产品代码或已有测试。
- 计划：[第三轮计划](G:/AIRTS/AI_RTS/agent/plans/2026-10-16-adjutant-phase1-third-review.md)
- 提示词：[第三轮审查提示词](G:/AIRTS/AI_RTS/agent/prompts/2026-10-16-adjutant-phase1-third-review.md)
- 审查已完成；产品结论：**needs-review，暂不晋级**。

## 1. 结论与已确认的修复

返修有效，但“C1–C5 全部解决”的结论仍超出证据。当前还存在四项主要缺口：Accepted 回执提前结算失败预算、旧回执认领新尝试、指定工地丢失后退回全局类型计数、合法生产指令无法补全产品类型。其中前两项使“授权→命令→执行结果”尚未形成可靠的因果链；第三项仍可误判建造成功。

| 原复核项 | 第三轮独立结论 | 证据及限制 |
|---|---|---|
| C1：计划先于动作、缺证据绕过期限 | 部分修复 | 原完整图移动夹具现在得到 `kind=move / metric=arrival_tick / units=[Unit_1]`；总期限先于证据判定。合法生产合同仍可留下空产品类型，见 D4。 |
| C2：恢复预算与尝试生命周期 | 未满足核心目标 | 授权本身不再立即计数、等待窗口存在；但 Accepted 被当作已结论，旧同 tick 回执也能消耗新尝试，见 D1、D2。 |
| C3：冷却门禁、同轮重评 | 原反例已修 | 门禁已接入；预算 3/3 的受阻任务改变签名后，同一次 evaluate 完成重评与预算决定，仍受阻。最终对局记录 462 条受阻方案丢弃。尝试状态质量仍受 D1、D2 影响。 |
| C4：生产/建造结果归因 | 部分修复 | 原“两条生产任务只完成 A”反例现在为 A 成功、B 等待。指定工地缺失时仍认领别处完工，且判据切换会混用基线，见 D3。 |
| C5：去重吞掉 attempt 变化 | 原反例已修 | 同状态、同 reason 的 attempt 2→3 现在仍产生 attempt=3 的事件。 |

新样本 `receipt_failed` 仅 1 条，支持重复诊断事件显著减少；“197→1”的 197 为实施方前一闸门计数，本轮直接重数的是最终样本的 1。

## 2. 剩余缺陷与下一轮验收条件

以下反例直接调用当前生产模块；其中移动正例使用现有完整图运行夹具，生产合同通过 `parse_tactical_intent` 校验。探针退出码 0 表示反例按断言复现，**不表示产品通过验收**。

### D1 / P1：Accepted 被当作尝试最终结论，尚未产出便耗尽预算

位置：[回执同步](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_loop.py:870)、[尝试结算](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_loop.py:543)、[受阻任务早退](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_loop.py:929)。

`_sync_attempt_results` 不区分回执状态，只把该任务最新回执 tick 写入 `attempt_result_tick`。`diagnose` 看到结果 tick 不早于授权 tick 就消耗预算。生产命令被接受仅表明开始执行，此时没有产出属于正常在途。

复现：设置合法的单次恢复预算，tick 100 授权 attempt=1、已用预算 0；tick 101 收到 Accepted，既无 production_finished，坦克数也为 0，任务立即变为 `blocked / retries_used=1`。随后 tick 200 该订单实际完成、tick 201 再评估，任务仍 blocked、changes 为空。生产成功不改变当前受阻重评签名，因而成功证据也没有被检查。

对应探针：`C2_accepted_is_treated_as_final`、`C2_completed_after_early_block`。单次预算用于缩小反例；配置为三次时，同一问题会发生在最后一次授权上。

返修条件：将命令接受、执行在途、明确拒绝/失败、完成、执行超时分开；Accepted 不消耗失败预算。受阻任务仍须接收与自身订单相关的最终成功证据。回归必须包含“最后一次恢复被接受、慢速执行、稍后完成”的完整过程。

### D2 / P1：只有 task+tick 的关联，旧回执可结算刚授权的新尝试

位置：[task 级回执聚合](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_loop.py:880)、[tick 大小判断](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_loop.py:547)。

当前记录没有把一次授权绑定到不可变的 intent/command 集合。只要旧命令与新授权处在相同模拟 tick，`result_tick >= attempt_started_tick` 就成立；模拟暂停或同 tick 多轮评估会产生这种情况。

复现：旧命令 issued_tick=50，拒绝回执 tick=100。第一次 evaluate(tick=100) 授权 attempt=1；同 tick 第二次 evaluate，没有新增命令或回执，预算就被消耗并转为 blocked。对应探针：`C2_old_same_tick_receipt`，新增命令数 0。

最终真实对局也存在对应的时序缺口，原始事件按 `seq` 定位：

| seq | round | tick | 炼矿厂任务事件 |
|---:|---:|---:|---|
| 1318 | 41 | 704 | 原始建造命令被拒绝 |
| 1331 | 42 | 704 | 随后才授权恢复 attempt=1 |
| 3632 | 105 | 1024 | 授权 attempt=2 |
| 3659 | 105 | 1024 | 下一条实际建造命令回执 |
| 5820 | 165 | 1326 | 授权 attempt=3 |
| 5847 | 165 | 1326 | 第三次授权后的实际拒绝回执 |
| 5860 | 166 | 1326 | 预算耗尽 |

因此，第一次“恢复尝试”在计数前没有新命令回执；不能把三次授权都表述为三次实际执行。第二、第三次有真实拒绝回执，不能反过来宣称它们都是空尝试。

返修条件：保留 attempt→intent_id→command_id 的明确关联，以实际下发建立尝试身份，回执按身份结算且只结算一次。添加重复 tick、旧回执晚到、回执重放、同任务多命令的回归。

### D3 / P1：指定工地缺失时静默退回类型共享，且基线语义会切换

位置：[建造判据](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_loop.py:234)、[统一增量阈值](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_loop.py:313)。

代码以“目标是否存在于本轮 own_constructed”决定归因模式。目标消失时，即使明确指定了实体名，也会退回 `type_shared`。已新增 `own_constructed` 字段属实，但字段存在不等于这一分支满足合同。

独立反例有两个方向：

1. tick 100 工地 SiteA 存在但未完成，基线 0；tick 200 SiteA 消失，别处 SiteB 同类型完工，类型计数为 1。SiteA 任务被判 `succeeded / success_basis=type_shared`。对应 `C4_missing_named_site`。
2. SiteA 起初不可观测，全局类型计数为 2，被采作 baseline=2；随后 SiteA 出现并完工，指标切为本工地布尔值 1。因为仍比较 `1 >= 2+1`，任务继续 waiting。对应 `C4_metric_basis_switch`。

返修条件：登记稳定的归因模式，区分工地实体、建筑类型和场景路径；指定工地丢失进入未知/工地丢失判定，禁止自动认领类型共享成果。基线与当前指标必须同语义、同单位；若需要转换模式，须定义明确的转换规则并覆盖两个方向。

### D4 / P1：真实生产合同的 scene+producer 没有转成产品类型

位置：[合法 target 字段](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/contracts.py:51)、[生产合同校验](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/contracts.py:249)、[已有台账补全](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_loop.py:687)、[新台账字段提取](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/task_loop.py:710)。

生产合同使用 `target.scene + target.producer`；台账却只读取 `target.product / target.definition_id`。新记录还可从 `rule-produce-*` 命名兜底，但模型任务 ID 没有这种保证，已有空记录的补全分支也没有该兜底。

复现：先登记计划任务 `model-prod`，再输入经合同解析通过的 `action=produce, target={scene:坦克场景, producer:Unit_1}`。台账得到 kind=produce，但 product_type 仍为空，状态 pending、原因 evidence_missing。对应 `C1_valid_produce_fields`。

原来的“永远绕过期限”已经修复，这里剩下的是无法观察正常生产结果，最终只能走停滞/期限诊断。最终对局中规则生产任务有类型，不能据此证明模型任务也正常。

返修条件：通过既有规则视图/场景映射解析规范类型，初次登记与后补使用同一口径；不能依赖任务 ID 字符串。回归必须使用合法合同字段和任意模型任务 ID，同时覆盖计划先于动作与首轮已有动作。

### 相关 P2 边界：首个可判定样本已经包含本任务产出

`C4_first_attributed_completion_in_baseline`：任务 created_tick=100，其自身 intent 对应订单 finished_tick=110；首次可判定评估在 tick 120，已完成的本任务订单被采为 baseline=1，之后没有第二件产出便一直 waiting。此为时序边界复现，未声称最终 Match 已触发。订单已按身份归因后，应明确如何接受任务建立后、首次采样前的完成事件。

## 3. 零执行超时的语义边界

本轮实现明确规定“无回执超过 30 秒窗口也结算一次”。独立探针 `C2_zero_dispatch_after_windows` 在 20Hz 下经历 tick 100→700→1300→1900，没有任何命令，仍耗尽三次预算。

这符合此次新增的窗口定义，不能把它直接当作“没有实现窗口”的旧问题。但它代表三次授权/调度等待超时，不能统计为三次实际执行失败；也不能继续声称“计时不会把零执行烧成多次失败”。下一轮应明确区分调度等待预算与执行恢复预算，至少在事件、统计和中文说明中分别呈现。D1、D2 不依赖是否接受这项超时策略。

## 4. 最终 180 秒 Match 的独立核对

证据目录：[round-06/match-c-rework-final](G:/AIRTS/AI_RTS/agent/runs/2026-10-15-adjutant-phase1/round-06/match-c-rework-final)。本轮重新解析原始 trace 与 checkpoint，没有重新启动对局。

| 项目 | 第三轮重数 |
|---|---:|
| 轮数 / 总事件 | 629 / 22,868 |
| 命令 receipt / dropped | 51 / 701 |
| dropped 缺 task_id | 0 |
| task_loop_blocked_plan 丢弃 | 462 |
| recovery_attempt / awaiting_attempt_result | 10 / 5 |
| retry_budget_exhausted 事件 / recheck_conditions_met | 7 / 5 |
| success_evidence / receipt_failed | 4 / 1 |
| 旧 task_progress running→completed 事件 | 13，另一个口径，不能与 4 次闭环成功混算 |
| 源码冻结 | before=after；62 个登记文件与当前 SHA256 全部一致 |
| 退出清理 | 已记录的 runner/game alive=false、rc=0、forced=[] |

当前 `task_loop.py` 的 SHA256：`da1b8380ef39e9724f40431e6ac4b9de1b1d2caea07c6b0f6aff2068cf9a6bfd`。不能只用 Git 的 `+dirty` 描述代替文件身份；本轮按 62 文件冻结清单比较。

“耗尽后同任务回执 0 条”需要限定范围：炼矿厂样本确为 0；独立扫描全部任务，在耗尽至已记录重评/恢复/成功之间仍有 3 条 `rule-gather` 回执（seq 19930、20082、20084）。实施报告已说明该 task_id 汇集多个单位×矿点分配、其它方案仍可执行，因此本轮不把这三条直接认定为非法穿透；同样不能把局部 0 条推广为全部任务 0 条。

最终 checkpoint 中 W1/W2 已有 gather 类型并进入恢复。该最终样本的关键事件及 checkpoint 没有提供 `rebuild_refinery` 同名任务的证据，不使用交接文字补足这一覆盖。经济仍未恢复，NoValidSite 的位置层问题也未由本轮解决。

原始证据：[trace.jsonl](G:/AIRTS/AI_RTS/agent/runs/2026-10-15-adjutant-phase1/round-06/match-c-rework-final/runner-logs/trace.jsonl)、[source-before](G:/AIRTS/AI_RTS/agent/runs/2026-10-15-adjutant-phase1/round-06/match-c-rework-final/source-before.json)、[source-after](G:/AIRTS/AI_RTS/agent/runs/2026-10-15-adjutant-phase1/round-06/match-c-rework-final/source-after.json)、[summary](G:/AIRTS/AI_RTS/agent/runs/2026-10-15-adjutant-phase1/round-06/match-c-rework-final/summary.json)。

## 5. 本轮验证与产物

测试工作目录：`G:/AIRTS/AI_RTS/source/adjutant_coordinator/tests`；测试解释器：`G:/AIRTS/临时文件夹/airts_agent_venv/Scripts/python.exe`。

| 命令（使用上述解释器） | 结果 |
|---|---|
| `-B -m unittest test_decision_trace test_task_loop test_economy_recovery` | 87 项，rc=0，OK |
| `-B -m unittest test_graph_runtime_fake test_intent_arbitration test_campaign_mainline test_graph_state_channels test_graph_state_checkpoint` | 149 项，rc=0，OK；既有未关闭文件句柄 ResourceWarning，不构成测试失败 |
| `D:/software/anaconda3/python.exe -B <下方 phase1_third_probes.py>` | rc=0；独立正例与剩余缺陷按断言复现；探针前后图模块 hash 稳定 |
| `D:/software/anaconda3/python.exe -B <下方 phase1_third_runtime.py>` | rc=0；重算上述运行计数与 62 文件身份 |
| `tools/check_workspace_target.py --mode develop --target <本轮各文档绝对路径>` | 计划、提示词、报告均 rc=0 |

独立审查产物保留在本聊天工作目录：

- [反例脚本](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/phase1_third_probes.py)；[反例原始输出](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/phase1-third-probes.json)。
- [运行证据扫描脚本](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/phase1_third_runtime.py)；[运行证据重算输出](C:/Users/Administrator/.codex/visualizations/2026/10/14/01a13a75-a7c7-7152-be8c-9f467f7f82d3/phase1-third-runtime.json)。

本轮新增/修改仅为第三轮计划、审查提示词、本报告及聊天目录中的自有探针/审查产物。没有改写原报告、原对局证据、生产模块或测试断言。

## 6. RSI 决策、未验证项及共享工作区

- 现候选：`cand-phase1-c-rework`，登记于 round-06；独立审查结论仍为 needs-review，不建议晋级。
- champion 登记：`4851de361b4c924cde0eacbe2d113b14fc6c9798+dirty` 基线；本轮不改变 champion 文件或 promotion_history。
- 当前连续未提升轮数登记为 1；这是审查回合，不另加产品候选计数。
- 质量结论：C1 移动补全、C3 同轮决定、C5 事件保留及重复事件治理改善；尝试因果关系、在途结果处理、建造判据稳定性未过。
- 没有新开 Match，没有 UI/玩家输入验收，没有新截图或视频，没有重新跑全量 1,122 项及全量 Godot 回归；“只剩 4 个基线既有红”未由本轮独立重新证明。旧 600 秒对局不能替代最终代码的 600 秒复验。
- 工作区已有大量共享未提交改动；本轮未清理、回退、切换分支或触碰他人代码。探针前后图模块稳定，最终对局冻结的 62 文件与审查版本一致；后续修改须重新确认身份。
- 审查无产品补丁可回滚；如需撤回本轮产物，仅处理本轮三个第三轮文档和自有审查脚本，保留已有源码、证据和 champion。

下一轮先修 D1/D2 的尝试身份与在途状态，再修 D3 的稳定归因模式和 D4 的合同字段映射；将上述反例转为正式回归后，按单补丁真实 Match 闸门复验，最后补最终版本的长局与产品验收。
