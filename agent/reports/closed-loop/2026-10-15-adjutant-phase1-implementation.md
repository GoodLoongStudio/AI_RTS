# AIRTS 副官第一阶段：追踪、闭环与经济恢复 — 闭环验证报告

- 实施提示词：[`agent/prompts/2026-10-15-adjutant-phase1-implementation.md`](../prompts/2026-10-15-adjutant-phase1-implementation.md)
- 实施计划：[`agent/plans/2026-10-15-adjutant-phase1-implementation-plan.md`](../plans/2026-10-15-adjutant-phase1-implementation-plan.md)
- 独立复核：[`2026-10-15-adjutant-phase1-independent-review.md`](2026-10-15-adjutant-phase1-independent-review.md)（R1–R6 + P2，**已逐条返修，见第七节**）
- 运行记录：`agent/runs/2026-10-15-adjutant-phase1/`（baseline / checklist / champion / round-01…05）
- 日期：2026-10-15；分支 `yyp_test` @ `4851de3`（共享 dirty tree；全程未 reset/clean/覆盖他人改动）
- 开发根：`G:/AIRTS/AI_RTS`（每个编辑目标均通过 `tools/check_workspace_target.py --mode develop`，rc=0）

## TLDR

三项修改全部落地并通过阶段闸门：**运行时决策追踪**（新模块 `graph/trace.py`，真实对局 2,121 轮 / 76,257 条事件 / 0 诊断错误）、**任务反馈闭环**（新模块 `graph/task_loop.py`，成功/等待/无进展/失败/超时/受阻六类边在真实对局全部真实触发）、**经济恢复入口与里程碑**（新模块 `graph/economy_recovery.py`，原案例类场景不再被"未受袭"屏蔽；M01 改按真实交货判完成，基线红测试转绿）。

**三轮独立复核（另一会话）共指出 17 项问题，本报告第七、八、九节记录逐条返修与新闸门证据**：

- 第一轮 R1–R6 + P2（8 项）：受阻台账不约束执行、历史事实误算成功、超时不进诊断、恢复刷新进展、损失异常只保一轮、支出掩盖收入中断、索引无键数上界、dropped 事件缺 task_id——**全部成立并已修复**（例：预算耗尽后同任务回执从 19 处降为 0；冷却事件从 290 条降为 4 条；dropped task_id 填充 316/316）。
- 第二轮 C1–C5（5 项）：计划先于动作的任务无可评估类型、恢复预算按时间消耗（零执行也烧完三次）、冷却不拦候选+重评先开门后决定、全局增量被多订单认领、去重漏记 attempt——**全部成立并已修复**（尝试生命周期：授权不耗预算、等自己的窗口、回执结论；生产按台账归因订单；冷却门禁；重评同轮完成预算决定），并附带修掉闸门暴露的 receipt_failed churn（197→1 条）。

产品状态：**needs-review**。理由：① 三轮返修已完成并用真实对局复验，但**第四轮独立复核尚未做**；② 局内经济最终未真实恢复（根因是放置层 `NoValidSite`，既有问题，且"它是唯一剩余问题"未获证明）；③ 正常玩家 UI 未做可视验收（证据层级为 command-level/headless）。

**用户能从时间图看清某个任务卡在哪一步、触发了哪条失败/超时边、恢复为何可行或受阻**——见 [600 秒运行时追踪时间表与交互回放](2026-10-15-adjutant-phase1-runtime-trace.md)（[HTML 交互版](2026-10-15-adjutant-phase1-runtime-trace.html)）。

---

## 一、改动清单（源码/测试/配置/工具）

### 新增

| 文件 | 作用 |
|---|---|
| `source/adjutant_coordinator/graph/trace.py` | 决策追踪合同（schema `airts-adjutant-trace` v1）：`TraceRecorder`（信封 seq/session_id/run_id/round_seq/server_tick/ts_mono/ts_wall + 有界内存环 + JSONL 轮转 sink + 进程内查询）、`frame_identity`（异步原关联）、`load_trace`/`task_chain`/`command_chain` |
| `source/adjutant_coordinator/graph/task_loop.py` | 任务反馈闭环合同：九态状态机（pending/running/waiting/succeeded/failed/timed_out/diagnosing/recovering/blocked，结束态不重开）；权威指标（build=完工数、produce=部署实体、gather=真实交货、move=到达、attack=战果事件）；期限按秒配置→实测 tick 率换算；`last_progress` 只由指标实际上涨刷新；诊断→恢复（attempt+1 + 冷却 + 方案指纹 + 前置重核验）→受阻（缺项+重评条件，重评需条件签名真变化） |
| `source/adjutant_coordinator/graph/economy_recovery.py` | 六类经济异常（受袭恢复**原条件保留为 OR 项** / 关键任务失败 / 交付停滞 / 曾交货后中断 / 执行单位损失 / 设施损失），全部证据+时间窗+开局宽限；`recovery_plan`（入口开放≠可执行；按异常种类给动作/缺项/替代，不绕过资源/权限/单位前提）；异常追踪留痕 |
| `source/adjutant_coordinator/tests/test_decision_trace.py` | 16 项追踪合同测试 |
| `source/adjutant_coordinator/tests/test_task_loop.py` | 23 项闭环测试 |
| `source/adjutant_coordinator/tests/test_economy_recovery.py` | 24 项经济入口/里程碑测试（正反场景表全覆盖） |
| `tools/dev/export_adjutant_runtime_trace.py` | 真实对局 trace → 中文 Markdown 时间表 + 交互 HTML + **由追踪生成的实际分支图**（mermaid）+ manifest（输入哈希/计数/缺失项） |

### 修改

| 文件 | 改动 |
|---|---|
| `graph/state.py` | 新字段 `trace_session`/`trace_round_seq`/`task_ledger`/`task_ledger_feedback`/`task_loop_report`（dataclass + to_dict/from_dict/summary 全通） |
| `graph/graph.py` | 六个新图通道声明（trace_session/trace_round_seq/task_ledger/task_ledger_feedback/task_loop_report/**loop_config**）；`GraphRunner._run_node` 记录节点 enter/exit/error span（LangGraph 与内置执行器共用，阶段计时键保持历史口径） |
| `graph/nodes.py` | `GraphServices.trace`；选边（route+判据码+中文解释）、候选逐项条件值、命令事件（receipt/recheck/dropped/timeout）、模型调用 submit/result（帧身份关联）、任务 created/transition 追踪；`node_ingest` 接线任务闭环评估（facts 用 `campaign.build_facts` 唯一事实源）；`GraphConfig` 增加闭环与经济窗口配置 |
| `graph/decision_map.py` | `condition_report`（候选入口逐项 值/结果/缺项）；D2 语义文本随新入口更新（preconditions 不变） |
| `graph/campaign.py` | `needs_recovery` = 经济异常集合（`needs_recovery_attack` 兼容标志）；`_econ_facts` 最小经济事实子集；**M01 判据改为"首座矿场完工且真实交付"**，`economy_assigned`/`economy_established` 拆分；`_economy_context` 增加异常/恢复计划/两个就绪标志（进模型上下文） |
| `graph/runtime.py` | RuntimeConfig 追踪/闭环/经济配置；`tick()` 轮次 begin/end + 暂停/恢复留痕；`restore()` 沿用 session 与 round_seq；snapshot/describe 带追踪统计 |
| `graph/replay.py` | 回放同步落 `trace.jsonl` + `trace-events.jsonl`；summary 带追踪概览 |
| `deploy/agent_runner.py` | `--trace on/off`、`--trace-file`、`--loop-no-progress-seconds`、`--loop-deadline-seconds`、`--loop-retry-budget`、`--loop-cooldown-seconds`、`--econ-delivery-stall-seconds`、`--econ-post-delivery-stall-seconds`、`--econ-grace-seconds`；tick 日志带追踪开销；退出时统计并关闭追踪 |
| `tests/test_graph_state_channels.py` | `TRANSIENT_STATE_KEYS` 增加 `loop_config`（每轮从 GraphConfig 重算；持久化会用过期配置——附理由） |

---

## 二、追踪合同（`graph/trace.py`，schema v1）

每条事件一行 JSONL，公共信封：`schema/version/seq`（记录器单调序号，**不用 tick 排序**）、`session_id`（对局会话；恢复沿用、重开对局新建）、`run_id`（进程段）、`match_id/player_id`（串局隔离）、`round_seq`（每 tick +1，相同 tick 的多轮不串）、`server_tick`、`ts_mono`（算耗时）/`ts_wall`（对时间轴）、`kind/phase`。

| 类别 | 内容 |
|---|---|
| `round` | begin/end：轮次边界、route、elapsed_ms、暂停/恢复留痕 |
| `node_span` | 每个实际节点的 enter/exit/**error** + 耗时（span_id 用 round_seq+节点名，不用 tick 构造） |
| `edge` | 实际选边：from/to/route/reason_code（可测试判据）/reason_cn（短中文）+ detail（事件种类、在途状态） |
| `candidate_eval` | 候选入口**逐项 值/结果/缺项**（含 D2 经济入口六项：受袭数/M01 状态/工人数/已完工矿场/累计交货/关键任务失败） |
| `task` | created/progress/waiting/succeeded/failed/timeout/blocked/diagnosing/recovering/…，带 goal_id/attempt/plan_version/指标值 |
| `command` | receipt/recheck/dropped/timeout，带 intent_id/command_id/attempt（同一 intent 的 command_id 唯一，不按 tick 猜） |
| `model_call` | submit/result 按**帧身份**（match/player/server_tick/snapshot/plan_version/epoch/generations 摘要）关联，request_id 交叉索引 |
| `note` | 异常激活/解除、恢复计划、经济异常、暂停、恢复、意图过期等 |

写入纪律：全量进 JSONL（默认 64MiB 轮转、留 2 备份）；内存环 8,192 条；**写入异常只计数并可见**（`diagnostic_errors` + note 事件），绝不抛回调用方；**不进模型每轮上下文**（模型输入构建不读本模块）。旧样本没有这些字段 → 读取方按缺失降级显示，**不补造**（`load_trace` 对无 schema 行原样保留）。

---

## 三、阶段闸门与测试（命令与 rc）

### 静态与单测（venv：`G:/AIRTS/临时文件夹/airts_agent_venv/Scripts/python.exe`）

```text
cd source/adjutant_coordinator/tests && python -m unittest test_decision_trace test_task_loop test_economy_recovery
rc=0（16 + 23 + 24 = 63 项全过）

cd source && python -m unittest discover -s adjutant_coordinator/tests -p "test_*.py"
rc=2（1093 ran, 1 failure, 3 errors, 1 skipped——全部为基线既有，见下）
```

基线既有红（对照组证明与本次改动无关，记录不改绿）：
- `test_rule_floor_develops_along_mainline_without_model`：把 M01 判据临时改回旧口径后**同样失败在同一断言**（`phases>=3`，实测 `['立足','扩张']`）；
- 3 个 ImportError（`test_build_identity`/`test_task_progress` 引用已删除的 `capture_build_site`；`test_economy_bootstrap` 引用不存在的 `economy_bootstrap` 模块）。
- **基线红→绿**：`test_campaign_mainline.test_economy_requires_real_refinery_delivery`（工作树早已改好 M01 新口径断言、代码未跟上；本阶段实现后转绿）。

### 回放回归（旧链路，rc=0）

```text
python -m adjutant_coordinator.graph.replay --fixture .../replay_base_attack.jsonl      rc=0（8 PASS）
python -m adjutant_coordinator.graph.replay --fixture .../replay_player_takeover.jsonl  rc=0（17 PASS）
python -m adjutant_coordinator.graph.replay --fixture .../replay_model_timeout.jsonl    rc=0（12 PASS）
```

### 真实 Match 闸门（`tools/dev/adjutant_observe.py observe --seconds 150 --model-port 11434`）

| 轮次 | 补丁 | 结果 | 闸门抓到的问题 |
|---|---|---|---|
| round-01 | 修改 1 追踪 | observed；423 轮/13,883 事件/0 诊断错误；scout 16、produce 12、gather 5、build 1 接受 | — |
| round-02 | 修改 2 闭环（首跑） | observed | **`0.0` 配置值被当成"1 秒"覆盖 → 20 tick 假超时**（已修 + 回归测试） |
| round-02 | 闭环（复跑） | observed；509 轮；timeout 边 0 次假超时；no_progress/receipt_failed/recovering/blocked 真实触发 | — |
| round-03 | 修改 3 经济入口（首跑） | observed | **反馈判据漏报**：任务长期 diagnosing/recovering 不在触发集合 → D2 仍 0 次可选（已修 + 4 个回归测试） |
| round-03 | 经济入口（复跑） | observed；异常激活、D2 可选 924/972、恢复计划 462 条（112 可执行） | — |
| round-04 | 600s 观察后最终审计 | 静态+全量测试+浏览器验证 | **`loop_config` 漏声明图通道**：langgraph 引擎下 `--econ-*`/`--loop-*` 只有默认值生效（Fallback 不受影响）；已补通道声明 + 双引擎回归测试（对照组验证过：移除声明即红） |

---

## 四、600 秒单人房观察（最终证据）

**配置**：正常 Main→Play→Loading→Match 菜单入口（无夹具、无注入）；`PlainAndSimple.tscn`，seed 11；单人练习房；MiniCPM `minicpm5-adj-16k`（16K 上下文，参数 SHA `ff4ea8cf…`，复用既有服务 11434 未关闭）；战术 Laya；引擎 langgraph；墙钟 600.0005 秒；源码变更=无（source freeze 前后一致）。**实际模拟秒数：tick 532 → 12,529（世界采样跨度 595.1s，≈19.7 tick/s）**。

**总量**：2,121 轮 / 76,257 条追踪事件 / 单 session（`46aa438988d14b64`）/ 0 诊断写入错误；轮次耗时 p50 94ms、p95 156ms、max 1907ms；每轮 36.0 条事件（有界）；trace 文件 43.4MB（64MiB 轮转上限内）。

**路由与命令**：战略 1,474 / 战术 260 / 等待 387；回执 111 接受（move 53、gather 39、produce 18、build 1）、12 拒绝（build `NoValidSite`）、1,559 仲裁丢弃（预留/去重等正常门禁）；模型调用 116 次（战术 102 成功、战略 9 成功/5 异常、2 过期被拒）。

**闭环判定分布**（全部来自真实追踪）：`no_progress_limit` 10、`recovery_attempt` 9、`retry_budget_exhausted` 7、`recheck_conditions_met` 5、`success_evidence` 4、`receipt_failed` 5、`total_deadline` 1、`in_progress` 6；任务事件 156 条（成功关闭 22、未知/证据不足 57、受阻 7、恢复 9、diagnosing 20、timed_out 1）。**最长无进展 5,759 tick**（`rule-build-ore_refinery`，指标"已完工=0"，走 total_deadline 边；其次 5,739 tick 走 receipt_failed 边、`rule-gather` 2,126 tick 走 no_progress 边）——三项提示词要求的指标（最长无进展、失败→诊断延迟=当轮、恢复尝试 9 次/重复失败至预算耗尽 7 次）均可在 trace 与 decisions.jsonl 复核。

**经济时间线**（本局经济链实际断裂，完整证据链）：
- 开工 6 工人、`gather_assigned=true`、`economy_established=false`；唯一建成的建筑是车厂（tick 594，M02 done）；**12 次矿场建造全部被 `NoValidSite` 拒绝**，build_backoff 逐级升到 level 4（7,200 tick）。
- round 45（tick 737，9.8s）经济异常激活：`key_econ_task_failed`——"目标 M08 的任务恢复尝试中（按预算恢复（第 1 次尝试，预算 3））"；此后一直保持激活（经济未恢复，诚实保持）。
- 恢复计划 2,077 条事件，在两种状态间按事实切换：**可执行**（退避窗外 → `rebuild_refinery`，有建造者+资金，172 条）与**入口开放但受阻**（退避期内 → 缺项"建造退避中（连续被拒，至 tick N）"，随真实退避窗口 1741/4384/8308/15521 同步切换）。
- 模型的输入上下文从 `strategy-0003` 起携带 `anomaly_active/anomaly_kind/anomaly_reasons/recovery_*` 字段——入口计算、候选列表、模型菜单、执行门禁、回放解释同源。
- 余额 10,000→600（12 辆坦克）：旧样本里"经济没起来却一路推进"的病理，本局被如实判为"M01 未完成 + 经济异常 + 恢复受阻（放置层找不到合法落点）"。

**完整中文时间表**（2,121 轮全量：逐轮选边原因/span/候选/任务/命令/模型调用、任务链、命令链、模型输入输出全文索引、关键轮次详情、实际分支图）：
- [2026-10-15-adjutant-phase1-runtime-trace.md](2026-10-15-adjutant-phase1-runtime-trace.md)
- [交互 HTML（浏览器已验证）](2026-10-15-adjutant-phase1-runtime-trace.html)

**浏览器验证**（本地 127.0.0.1 临时服务 + 受控浏览器，只读）：标题/身份行渲染；8 个过滤器计数合理（全部 2,121 / 失败·超时 18 / 成功 22 / 正常等待 380 / 未知 56 / 模型调用 286 / 命令 1,612）；轮次跳转（输入 1500 → tick 8952 · 421.2s）；失败轮详情（选边+判据码、候选条件逐项值、任务/命令表）实际打开查看并截图。

---

## 五、正反场景覆盖（提示词表格逐项）

| 场景 | 证据 |
|---|---|
| 原案例（6 工人、M01 done、矿场失败、零交货） | 单测 `test_original_case_enters_diagnosis_not_blocked_by_old_condition`：`key_econ_task_failed`+`delivery_stall` 双异常、D2 可选、恢复分支可执行；真实对局 round-03/match-s1-econ-b 与 600s 局同构（M01 pending、零交货、无受袭 → 异常激活） |
| 从未受袭但关键经济链失败 | `test_unit_loss_without_attack_is_recognized` / `test_content_rejection_without_attack_is_recognized`；600s 局全程无受袭而异常激活 |
| 正常开局未首次交货但有进展 | `test_opening_with_progress_is_not_anomaly` / `test_built_refinery_recently_is_not_stall` / `test_construction_progress_resets_stall_window`；600s 局 380 轮正常等待零误判 |
| 收入支出同时发生、余额不变 | `test_flat_balance_with_deliveries_is_healthy`（交货计数在涨即健康，不用余额判收入） |
| 采集命令 Accepted 但无交货 | `test_m01_requires_delivery_not_gather_receipt`（assigned=true 但 M01 不 done；delivered=1 才 done 且证据含"交付"） |
| 曾经交货后链中断 | `test_flat_delivery_and_balance_is_post_delivery_stall` + `test_done_m01_is_not_rewritten_by_later_stall`（历史 done 不篡改，当前异常仍触发） |
| 受袭且工人不足 | `test_attack_condition_still_opens_recovery`（原条件原样保留，动作 defend_and_regather） |
| 零工人/无建造者/资源不足/路径不可达 | `test_zero_worker_blocks_with_missing_and_alternative`（替代路线 produce_worker）/ `test_no_builder_no_funds_blocks_rebuild`（缺项逐条）/ `test_build_backoff_blocks_rebuild_action`（真实对局同款受阻原因） |
| 恢复后实际交货且持续进展 | `test_delivery_resumes_clears_anomaly`（异常解除）+ `test_anomaly_is_sticky_within_window_not_every_round`（不每轮重复） |

**未覆盖/证据层级说明**：600 秒局内经济未真实恢复（放置层 `NoValidSite` 是既有问题，恢复动作被既有退避机制正确挡住），"恢复后异常解除"由单测覆盖、未在 600s 局内取得真实样本；正常玩家 UI（鼠标键盘操作）未做可视验收，全部证据为 headless/command-level；没有敌人的单人房已验证经济建立判据不依赖敌情。

---

## 六、剩余风险

1. **放置层 `NoValidSite`（经济 bootstrap 的真实阻塞点）**：本局 12 次矿场建造全部因自动放置找不到合法落点被拒（`DebugControlServer.gd` 的 FindAutoSpot 在基地周围/已探明矿点带内找不到可建地面）。本阶段的恢复入口能正确报告"建造退避中（连续被拒，至 tick N）"，但**修复放置不在本阶段范围**——它是经济能否真正恢复的前提，建议作为下一阶段第一优先。
2. **`rule-gather` 类微指令任务的指标粒度**：采集任务的成功判据是全局交货计数（语义＝"经济循环已建立"），单条采集命令的结果归因不在本阶段范围。
3. **恢复动作是建议而非指令**：`recovery_plan` 给出的动作仍由既有规则/计划层与仲裁门禁执行（不建第二权威）；"计划→执行"的闭环依赖既有层对这些动作的既有支持。
4. **追踪体积**：600s 局 43.4MB/76k 事件；轮转与内存环有界，但长时间排障需注意磁盘（`--trace off` 可关）。
5. **共享 dirty tree**：本轮只写自有新文件与精确补丁；两个守门/契约测试的修改（`TRANSIENT_STATE_KEYS` 增项）已附理由，未放宽任何判据。

---

## 七、共享工作区影响

- 未执行 `git reset/checkout/clean`，未覆盖、未回滚任何他人未提交改动；编辑目标均通过 `--mode develop` 边界检查（rc=0）。
- 本轮自有产物：3 个新模块、3 个新测试、1 个新工具、8 个既有文件的精确补丁；运行证据在 `agent/runs/2026-10-15-adjutant-phase1/`；报告与时间表在 `agent/reports/closed-loop/`。
- 模型服务（11434）与用户实例未动；每轮只清理本轮自有进程（收尾复核：无 Godot/runner 残留）。

---

## 八、candidate/champion 决策

- champion：基线（`4851de3`+dirty，任务起点）。
- 候选 `cand-mod1-trace`（round-01）：S1 通过。
- 候选 `cand-mod2-loop`（round-02）：S1 通过（修复后复跑）。
- 候选 `cand-mod3-econ`（round-03）：S1 通过（修复后复跑）。
- 合并候选 `cand-phase1-all`（round-04，600s 观察）：**S1/S2 通过，S3 待独立复核**——按仓库 RSI 纪律，"关键改动要有独立探针或新会话复核"尚未完成（本轮的独立校验是同一会话内的分离实现探针：回放回归 + 全量发现 + 浏览器验证，不冒充另一位 AI 的评审）。因此**不提升产品 champion，连续未提升计数 +1（累计 1）**，产品状态 `needs-review`。
- 晋级条件（建议）：① 另一会话/独立探针用自有判据复核 600s  trace 的关键结论；② 放置层 `NoValidSite` 修复后重取"经济真实恢复"样本；③ 正常玩家 UI 的可视验收（如需 command-level 以上证据）。

---

## 九、证据索引

| 证据 | 路径 |
|---|---|
| 600s 中文时间表 / 交互 HTML / manifest | `agent/reports/closed-loop/2026-10-15-adjutant-phase1-runtime-trace.{md,html,manifest.json}` |
| 600s 原始对局（trace/留档/模型输入输出/世界采样） | `agent/runs/2026-10-15-adjutant-phase1/round-04/match-600s-b/` |
| 600s（修复前对照，含受阻重评空转样本） | `agent/runs/2026-10-15-adjutant-phase1/round-04/match-600s/` |
| round-01…03 闸门与验证记录 | `agent/runs/2026-10-15-adjutant-phase1/round-0*/` |
| 基线/checklist/champion | `agent/runs/2026-10-15-adjutant-phase1/{baseline.md,checklist.md,champion.json}` |
| 旧样本（未被改写） | `agent/reports/closed-loop/2026-10-15-adjutant-loop-trace.*`、`2026-10-15-adjutant-chinese-timeline.*` |

---

## 七、独立复核返修（R1–R6 + P2）

独立复核（[2026-10-15-adjutant-phase1-independent-review.md](2026-10-15-adjutant-phase1-independent-review.md)）用自有探针复现了 8 项缺陷。逐条核实后**全部成立**，返修如下；每项都有"复核反例 → 回归测试"的转化与真实对局证据。

### R1：预算耗尽/受阻台账没有约束实际执行 → 已修

- 修法：受阻台账变成**执行门禁**。`task_loop.blocked_order_keys()` 产出受阻任务的失败方案键（`task_id|action|目标`，与仲裁侧同一派生函数 `order_key_of_intent`），`node_arbitrate_intent` 在仲裁前按键丢弃命中候选（reason=`task_loop_blocked_plan: <缺项>`，进决策日志与追踪）；任务因条件变化重评回诊断时键自动失效。拦的是**这一个失败方案**，换目标/换动作的新意图不受影响（不冻结正常动作）。
- 真实对局证据（round-05/match-rework-final2，150s）：`rule-build-ore_refinery` 预算耗尽后**同任务回执 0 条**（修复前 600s 局为 19 处）；`task_loop_blocked_plan` 丢弃 187 条且全部带 task_id。
- 已知边界（如实记录）：`rule-gather` 是一个 task_id 覆盖多个"单位×矿点"分配，预算耗尽只抑制首条失败分配的方案键；其它分配仍可执行（这是有意的粒度——全部冻结会冻死经济），任务级状态保持受阻直至指标（交货）恢复。

### R2：历史事实会被误算为新任务成功 → 已修

- 修法：`metric_value`/`success_reached` 改为**任务基线增量**判据——建立轮采集基线（`baseline`/`baseline_captured`），成功必须"超过基线"；移动类还要求到达 tick **晚于任务建立**且目标位置相符（用 `seen_arrivals` 的 `unit|[x,z]` 键核对）；基线未采集时不许放行旧口径（按证据不足）。
- 真实对局证据：4 次成功关闭全部有增量依据（`rule-scout` 到达 tick 568 且目标相符、`rule-build-vehicle_factory` 0→1、`rule-produce-worker` 0→1、`rule-produce-tank` 0→1）。
- 回归测试：`test_preexisting_building_is_not_task_success`、`test_build_completion_is_success_evidence`（两段式：先建基线再出现事实）等。

### R3：总期限到达后直接结束，未沿超时边进入恢复 → 已修

- 修法：timeout/no_progress 是**边不是终态**——一律进 `diagnosing`，由同轮 `diagnose` 决定恢复（预算内）/受阻（耗尽或前置丢失）；仅"权威回执明确失败且预算已尽"才记 `failed` 终态。诊断/恢复流程中的期限判定每轮只报一次（`_deadline_reported` 去重）。
- 回归测试：`test_timeout_goes_through_diagnose_to_recovery_then_blocked`（跨轮集成：deadline→diagnosing→recovery_attempt→…→blocked，attempt 递增、ended 不预设）。

### R4：没有实际进展，恢复状态仍刷新 last_progress → 已修

- 修法：`diagnose` 的恢复分支只写**尝试生命周期**（`attempt_started_tick/mono` + cooldown），绝不碰 `last_progress_*`；停滞计时从最后一次**实际**指标变化算起。
- 回归测试：`test_recovery_does_not_refresh_last_progress`（指标毫无变化时 diagnose 后 last_progress 保持 100、attempt_started=1000）、`test_stall_keeps_counting_across_recovery`（停滞 5000 tick 从实际进展算起）。

### R5：单位/设施损失只保留一轮异常 → 已修

- 修法：损失是**持续状态**——低于下限即激活（`unit_loss_active`/`facility_loss_active` 粘性标志），恢复到下限/重建才解除；不再靠"数量下降沿"触发。
- 回归测试：`test_unit_loss_stays_active_until_recovery`（6→0→0→0 四轮全 active，恢复后解除）、`test_facility_loss_stays_active_until_rebuilt`。

### R6：持续支出会掩盖交货中断 → 已修

- 修法：`post_delivery_stall` 的"无变化"判定去掉余额项，只比**交货数与施工进展**——收入链的健康证据是交付/入账，余额同时受支出影响。
- 回归测试：`test_spending_does_not_mask_delivery_stall`（交付数固定、每轮花 100：必须报停滞；对照：交付数在涨则健康）。

### P2-1：trace 索引键数无上界 → 已修

- 修法：索引改为**键总数 + 每键 deque 双限**（超限按插入序淘汰最旧键；全量历史仍在 JSONL）。回归测试 `test_command_index_keys_are_bounded`（1,000 个不同命令 ID → 索引 ≤64 键）。

### P2-2：dropped 命令事件 task_id 全为空 → 已修

- 修法：仲裁丢弃时从**候选表**按 intent_id 补 task_id/unit_ids/action（丢弃结果常常只带 intent_id/reason）。
- 真实对局证据：round-05/match-rework-final2 的 316 条 dropped 事件 **task_id 填充率 316/316**（修复前 600s 局 1,559/1,559 为空）。

### 返修附带发现并修复：诊断期事件churn

返修闸门（round-05/match-rework-gate）暴露：诊断中的任务每轮重报 `no_progress`+`cooldown_active`（290 条里只有 6 次真恢复）。已修：诊断/恢复流程中期限判定只报一次、diagnose 结论按 `_last_diag_code` 去重（300 轮模拟仅 8 个事件）。复跑闸门 cooldown_active 290→4。

### 版本与证据对应（复核版本来历要求的标注）

hash 口径：**SHA256 前 12 位**（与 `adjutant_observe.py` 的 source freeze 一致；
早期报告里写的 `dfcbaf` 等前缀是 `git hash-object` 的 blob 值，算法不同，已按独立
复核的指正统一为 SHA256）。

| 运行 | 代码版本（SHA256 前 12 位） | 验证内容 |
|---|---|---|
| round-04/match-600s-b（600s） | task_loop `7c692f566c99` / econ `c32995803b86` / nodes `87b1487a1f5a` / trace `185e14bfdedf` | **返修前**代码：追踪/闭环/经济入口首版 |
| round-05/match-rework-gate（240s） | task_loop `04c3d07da37c` / econ `584194ca281b` / nodes `c34692bac4fc` / trace `cdba6c2ac2b5` | R1–R6+P2 修复（churn 修复前） |
| round-05/match-rework-final2（150s） | task_loop `4af22a0e938b` / econ `584194ca281b` / nodes `c34692bac4fc` / trace `cdba6c2ac2b5` | R1–R6+P2+churn 修复全量（独立复核核对过：冻结 62 文件与当时当前树一致） |
| round-06/match-c-rework-gate（240s） | task_loop `ed5aa3ad3185` / econ `584194ca281b` / nodes `c7375cafa6e1` / trace `cdba6c2ac2b5` | **C1–C5 返修后**（见第八节） |

每轮 source-before/source-after 均记录于对应运行目录；各运行互不覆盖，证据与代码版本一一对应。

### 返修后的测试与闸门

```text
cd source/adjutant_coordinator/tests && python -m unittest test_task_loop test_economy_recovery test_decision_trace …
rc=0（task_loop 32 + economy 27 + decision_trace 18 …）

cd source && python -m unittest discover -s adjutant_coordinator/tests -p "test_*.py"
rc=2（1112 ran, 1 failure, 3 errors, 1 skipped——全部为基线既有，对照组证明见 baseline.md）

回放回归 3 剧本 rc=0（8/12/17 PASS，trace 事件 101/131/201，0 诊断错误）

round-05/match-rework-final2（150s 真实 Match）：observed，源码未变；
503 轮 / 18,005 事件 / 0 诊断错误；轮次耗时 p50 78ms（返修前 600s 局 p50 94ms，无性能回归）
```

---

## 八、第二轮独立复核返修（C1–C5）

第二轮独立复核（[2026-10-16-adjutant-phase1-recheck.md](2026-10-16-adjutant-phase1-recheck.md)）确认 R2/R5/R6/P2 的原反例已修，但指出核心执行闭环仍有 5 项问题。逐条复现后**全部成立**，返修如下；每项都有"复核反例 → 回归测试"的转化与真实对局证据（round-06/match-c-rework-final，180s，代码版本见第七节表格）。

### C1：计划先于动作的任务可能始终没有可评估类型 → 已修

- 修法：① `sync_ledger` 对已登记任务**补全**类型/单位/目标/指标/意图 id（旧实现只补 order_key）；② `evaluate_record` 的**总期限判定先于证据判定**——缺证据不再是终态，到期沿 timeout 边进诊断；证据不足但有**无进展期限出口**（到期沿 no_progress 边）。
- 回归测试：`test_plan_first_task_gets_type_and_deadline_exit`、`test_evidence_missing_has_bounded_wait_then_diagnose`。
- 真实对局证据：经济恢复计划产生的战略任务（`rebuild_refinery`/`W1`/`W2`，计划先于动作）本局出现完整恢复授权记录（round 395/439/447/539/559），不再是永远 pending/kind 为空。

### C2：恢复预算按时间消耗，第 3 次尝试可能下一轮就被拦 → 已修

- 修法：引入**尝试生命周期**——授权（attempt+1、`attempt_started_tick`）不消耗预算；预算只被**已结论的尝试**消耗：结论 = 本次尝试已有命令回执（`attempt_result_tick`，每轮从 `command_receipts` 按 intent_id→task_id 关联），或尝试窗口（`loop_attempt_window_seconds`，默认 30s）已过仍无任何回执。未调度/被门禁挡住/在途都不计失败；最后一次已授权尝试总能等到自己的窗口。
- 回归测试：`test_authorization_does_not_consume_budget_without_execution`（零执行序列：三次授权各等自己的窗口，第 3 次窗口过后才 blocked）、`test_result_concludes_attempt_immediately`、`test_attempt_results_sync_from_receipts`。
- 真实对局证据：`awaiting_attempt_result` 5 条与 `recovery_attempt` 10 条交替出现；`rule-build-ore_refinery` 三次授权分布在 round 42/105/165（间隔约 60 轮，非计时连发），round 166 预算耗尽 → **同任务后续回执 0 条**。

### C3：冷却不拦实际候选；条件重评先开执行门再做预算决定 → 已修

- 修法：① `blocked_order_keys` 增加**冷却门禁**——DIAGNOSING/RECOVERING 且冷却未到时，同方案候选不许再进待下发（例外：本次尝试还没有任何回执时放行它的首次执行，否则恢复永远无法执行）；换目标/换动作/其他任务不受影响。② 受阻重评分支**不再 `continue`**——放行后同轮完成 diagnose 的预算/冷却决定，仲裁门禁当轮看到的就是最终状态。
- 回归测试：`test_cooldown_blocks_new_retry_but_allows_first_execution`、`test_recheck_completes_budget_decision_same_round`。
- 真实对局证据：本局 462 条 `task_loop_blocked_plan` 丢弃；6 次预算耗尽事件后同任务回执均为 0（`rule-gather` 的 3 条来自不同"单位×矿点"分配——任务级受阻但未冻结其它合法路线，是有意的粒度）。

### C4：全局增量仍可被多个独立任务同时认领 → 已修

- 修法：生产成功改按**生产台账归因**（`production_ledger` 里 intent_id 属于本任务、或生产者是本任务指定设施的已完成 item 数），不再数全局 counts；建造在任务指定了具体工地时只认**那个工地**完工（`own_constructed`），未指定工地才退化为类型增量，并在 `success_basis` 字段标明 `order`/`type_shared` 两种判据。
- 回归测试：`test_concurrent_produce_orders_do_not_share_result`（只新增一辆坦克，只有对应订单成功）、`test_build_attribution_prefers_named_site`。
- 真实对局证据：4 次成功关闭的 detail 分别标明判据来源——`rule-produce-tank/worker`「台账归因」、`rule-build-vehicle_factory`「类型共享判定」、`rule-scout`「到达目标（坐标相符）」。
- 已知边界：自动落点的建造任务在工地实体可观测前只能按类型共享判定（`success_basis=type_shared` 明示）；这是当前观测字段下的保守口径。

### C5：降低重复事件时漏记真正增加的 attempt → 已修

- 修法：诊断事件去重增加 **attempt 比较**——相同状态+原因码但 attempt 增加（新授权）必须记录。
- 回归测试：`test_attempt_increment_is_not_deduped`。
- 真实对局证据：`recovery_attempt` 事件带 attempt=1/2/3 序列，时间线可见每次授权。

### 返修附带发现并修复：receipt_failed 每轮重报

round-06 首轮闸门暴露：权威层把任务标记 failed 后，`receipt_failed` 每轮重复进入诊断（197 条事件，绝大多数是重复）。已修：只在任务**尚未进入诊断流程**时应用该覆盖；诊断中的任务由尝试生命周期治理。复跑闸门 197→1 条（40 轮模拟仅 2 个事件）。

### 第二轮返修后的测试与闸门

```text
cd source/adjutant_coordinator/tests && python -m unittest test_task_loop test_economy_recovery test_decision_trace
rc=0（87 项，含第二轮新增 10 项反例回归）

cd source && python -m unittest discover -s adjutant_coordinator/tests -p "test_*.py"
rc=2（1122 ran, 1 failure, 3 errors, 1 skipped——全部为基线既有，对照组证明见 baseline.md）

round-06/match-c-rework-gate（240s）：observed；556 轮/20,689 事件/0 诊断错误
round-06/match-c-rework-final（180s，**当前最终代码**）：observed、源码未变；
629 轮/22,868 事件/0 诊断错误；receipt_failed 197→1；attempt 生命周期/归因/冷却门禁全部有真实证据
```

---

## 九、第三轮独立复核返修（D1–D4 + P2 边界 + 语义边界）

第三轮独立复核（[2026-10-16-adjutant-phase1-third-review.md](2026-10-16-adjutant-phase1-third-review.md)）确认 C1 移动补全、C3 同轮决定、C5 事件保留及重复事件治理有效，但指出尝试因果链仍有 4 项缺口。逐条复现后**全部成立**，返修如下；每项都有“复核反例 → 回归测试”的转化与真实对局证据（round-07，当前代码 task_loop `c97019c53c23`，冻结 hash 与当前树一致）。

### D1：Accepted 被当作尝试最终结论，尚未产出便耗尽预算 → 已修

- 修法：尝试结论按**回执身份+状态**分类——`attempt_intents`（授权之后实际下发的 intent 集合）/`attempt_receipts`（按 `intent_id|command_id` 只结算一次的回执明细）。**Accepted 是在途，不消耗失败预算**（生产/建造需要时间），保持 `attempt_in_flight` 直至指标推进（成功路径）或窗口已到；只有**明确拒绝/失败**才计执行失败。同时：受阻任务**不屏蔽成功证据**——订单在受阻期间完成时，凭自身归因证据直接关闭（不再永远 blocked、changes 为空）。
- 回归测试：`test_accepted_receipt_does_not_exhaust_budget`（单次预算：Accepted 后不 blocked，订单完成即 succeeded）、`test_blocked_task_can_still_succeed_with_own_evidence`、`test_result_concludes_attempt_immediately`（拒绝计预算/接受在途双分支）。
- 真实对局证据：`attempt_in_flight` 3 条、`awaiting_attempt_result` 6 条、`recovery_attempt` 10 条（attempt=1/2/3 序列分布多轮，非计时连发）；`rule-produce-worker`/`rule-produce-tank` 凭台账归因成功关闭。

### D2：只有 task+tick 的关联，旧回执可结算刚授权的新尝试 → 已修

- 修法：尝试身份绑定**实际下发**——只把 `issued_tick ≥ attempt_started_tick` 的本任务意图计入本次尝试；回执按 intent/command 身份结算且只结算一次。旧命令、同 tick 旧回执、重放回执都不能结算新尝试。
- 回归测试：`test_old_same_tick_receipt_does_not_settle_new_attempt`（旧命令拒绝回执与授权同 tick：attempt=1、retries=0、receipts=[]，同 tick 二次评估仍不 blocked）、`test_attempt_results_sync_from_receipts`（授权前 issued 的旧命令不回执结算）。
- 说明：复核给出的真实局时序（seq 1318 旧拒绝 → seq 1331 同 tick 授权 attempt=1）按新规则第一次尝试不再被旧回执结算；第二、三次有真实拒绝回执，仍正常计预算。

### D3：指定工地缺失时静默退回类型共享，且基线语义会切换 → 已修

- 修法：归因模式**首次可判定时登记且不再切换**（`attribution`）：`site`（指定工地实体）/ `type`（类型增量）/ `order`（生产台账）/ `delivered` / `arrival` / `damage`。指定工地不在观测中 → `unknown`（工地丢失/不可观测），**禁止**退回类型计数认领别处完工；工地起初不可观测时不采基线，出现并完工后按同语义判定成功（两个方向都有回归）。
- 回归测试：`test_missing_named_site_does_not_claim_other_completion`（SiteA 消失+SiteB 完工→unknown；SiteA 真完工→succeeded）、`test_named_site_first_observed_late_still_succeeds`（起初不可观测不采类型基线，后来完工→succeeded）。
- 附带：`site_entity` 只在 `target.entity_id` 是实体名（非 `res://` 场景路径）时登记，自动落点任务仍走 `type` 共享判定并在 `success_basis` 标明。

### D4：合法生产指令（scene+producer）仍可能缺少产品类型 → 已修

- 修法：新增 `resolve_intent_types(intent, rules)`——显式字段 → 回执生产身份 → **规则视图 scene→id 反查**（复用 `reserves._scene_to_id_index` 唯一实现）→ 场景基名兜底；`rule-produce-*` 任务名兜底降级为最后手段。**首次登记与后补全使用同一函数**（`sync_ledger` 两条路径），不依赖任务 ID 字符串。
- 回归测试：`test_valid_produce_contract_resolves_product_type`（模型任务 ID `model-prod` + scene+producer → product_type=tank 且可判定成功）、`test_build_scene_resolves_building_type`。

### P2 边界：首个可判定样本已包含本任务产出 → 已修

- 修法：生产指标只数**任务建立之后**完成的订单（`finished_tick ≥ created_tick`）；身份绑定指标（site/order/arrival）的基线定义性为 0，不把“建立后、首采前完成”的订单误采成基线。
- 回归测试：`test_completion_between_creation_and_first_sample_counts`（created=100、finished=110、首采=120 → succeeded；建立前完成 → waiting）。

### 语义边界：调度等待预算与执行恢复预算分开 → 已落实

- 实现：窗口已到且**完全没有任何下发**（未调度/被门禁挡住）记 `schedule_waits`（调度等待预算），与执行失败 `retries_used`（恢复执行预算）**分开计量**；任一耗尽即受阻，原因里写明是哪一种（`retry_budget_exhausted` / `schedule_budget_exhausted`），事件与中文说明分别呈现。零执行不再被统计为三次实际执行失败。
- 回归测试：`test_authorization_does_not_consume_budget_without_execution`（零执行：`retries_used` 始终 0、`schedule_waits` 累计至预算、`attempt_fail_kind=no_dispatch`）。

### 第三轮返修后的测试与闸门

```text
cd source/adjutant_coordinator/tests && python -m unittest test_task_loop test_economy_recovery test_decision_trace
rc=0（95 项，含第三轮新增 8 项反例回归）

cd source && python -m unittest discover -s adjutant_coordinator/tests -p "test_*.py"
rc=2（1130 ran, 1 failure, 3 errors, 1 skipped——全部为基线既有，对照组证明见 baseline.md）

round-07/match-d-rework-gate（240s）：观测数据完整（466 轮/16,940 事件，世界采样至 215s），
  收尾写证据被既有工具问题中断（status=incomplete；trace 与留档本身完整）
round-07/match-d-rework-final（180s，**当前最终代码**，冻结 hash 与当前树一致）：
  observed、源码未变；336 轮/11,969 事件/0 诊断错误；attempt 生命周期
  （recovery 5/awaiting 2/in_flight 0——本局节奏下 Accepted 回执均在窗口内被指标推进吸收）、
  成功关闭 3 次（含生产台账归因 2 次）、受阻丢弃 59 条、耗尽后同任务回执 0 条
```
