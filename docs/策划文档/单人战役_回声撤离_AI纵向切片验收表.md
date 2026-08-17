# 单人战役｜回声撤离 AI 纵向切片验收表

> 文档状态：P0 实施与验收规格  
> 原流程：`单人战役_回声撤离_实现流程.md`  
> AI 总规格：`AI副官_下一阶段开发训练与评测规格.md`  
> 权限 / 情报：`AI副官_权限与情报规则_P0.md`

---

# 0. 目标

《回声撤离》当前已经存在一条可玩流程：

```text
进入战役
→ 三支小队就位
→ AI 开场简报
→ 侦察二队推进
→ 发现重复 63 小时的异常求救信号
→ 突击一队原地防守、不追击
→ 发现废弃车队信标
→ 一队前进
→ 取得黑箱信标
→ 玩家请求撤离
→ 结算
```

本文件不改剧情，而是把这条流程转换为 AI、RTS Core、训练和评测都能共同使用的第一个纵向切片。

P0 的成功标准不是“LLM 能聊天”，而是：

> **同一条任务可以由 Human、ScriptedPolicy、未来 LLM / LocalModel 通过同一受限 Observation + Structured Intent 合同跑通，并产生可比较 Trace。**

---

# 1. P0 Slice 范围

## 必须包含

- 任务加载；
- 三支小队的 Controller / Scope；
- AI 指挥频道所需的合法剧情信息；
- 侦察 / 移动；
- 固守 + 不追击；
- 任务触发；
- 黑箱 / 信标目标；
- 任务级撤离确认；
- 玩家手动接管；
- AI timeout / invalid intent fallback；
- 胜败 / 结束；
- Episode Trace；
- Headless 自动运行版本。

## P0 可以简化

- 北辰最终地图资源；
- 完整敌军生态；
- 20 / 40 / 60 分钟多结局；
- 白鸦支线；
- 地下维修通道；
- 多撤离点；
- 完整演出；
- 最终配音；
- 复杂生产 / 科技。

当前 PlainAndSimple 验证地图可以继续承担 P0 自动化流程。

---

# 2. 参与对象

## 玩家侧

- Player Controller；
- AI Adjutant Controller；
- 可手动接管的小队 Scope。

## 三支小队

沿用现有流程：

1. `1：突击队`
2. `2：侦察队`
3. `3：支援队`

P0 不要求用这些显示名作为代码 ID，但 Scenario 配置必须有稳定逻辑标识，避免测试依赖 UI 文本。

## AI 角色

当前叙事角色沿用岚、隼。

角色语言表现与 Policy 决策分层：

- Policy 决定“做什么”；
- Presentation / Narrative 决定“怎么说”；
- 不允许因为某个角色知道剧情真值，就把隐藏战场数据塞进 Policy。

---

# 3. 阶段状态机

建议将当前流程至少映射为以下逻辑阶段。

```text
S0 MissionStart
→ S1 Briefing
→ S2 ScoutOuterCamp
→ S3 SignalAnomalyConfirmed
→ S4 HoldAndDoNotChase
→ S5 BeaconConvoyDiscovered
→ S6 RetrieveBlackBox
→ S7 ExtractionAvailable
→ S8 ExtractionConfirmed
→ S9 MissionComplete
```

代码可以使用其他命名，但需要有稳定的 Scenario Phase / Objective State，方便 Headless Runner 和 Evaluator 判断阶段推进。

---

# 4. 阶段验收矩阵

| 阶段 | 当前剧情 / 玩法 | AI 合法 Observation | P0 允许 Intent | 必须确认 | 程序依赖 | 自动验收 |
| --- | --- | --- | --- | --- | --- | --- |
| S0 | 进入任务，三队编组 | 自己三队、公开任务信息 | 无 / 初始化 | 无 | Scenario Load、Controller Scope | 三队状态稳定，隐藏真值未进入 Policy |
| S1 | 岚、隼开场简报 | 公开简报与初始任务目标 | Suggest / 无战斗命令 | 任务级选择按剧情规则 | Narrative Event、AI Channel | 简报不会泄露后续敌情 |
| S2 | 玩家选择侦察二队并推进 | 二队状态、合法区域摘要、当前目标 | Scout、Move、Hold | 非授权小队命令按模式处理 | Observation、Move、Scout、Trigger | 二队进入外围营地后阶段推进 |
| S3 | 发现求救信号重复至少 63 小时 | 已确认信号事件，不能提前知道车队 / 黑箱 | Scout、Move、Suggest | 无 | Mission Event、Intel | 事件仅在合法触发后进入 AI 可见流 |
| S4 | 一队原地防守、不要追击 | 一队状态、当前可见威胁 | Hold + no_chase constraint、Attack | Suggest 模式需确认 | Intent Constraint、Combat、Behavior | 一队不会因局部敌人自动脱离防区追击 |
| S5 | 隼报告废弃车队仍有信标 | 经触发确认的车队 / 信标任务情报 | Move、Scout、AttackMove | 无 | Trigger、Intel、Narrative | 未触发前模型无法访问车队真实信息 |
| S6 | 一队前进并取得黑箱信标 | 一队状态、合法目标区域、接敌信息 | Move、AttackMove、Hold、Retreat、Focus | 高风险技能按权限表 | Combat、Objective、Pickup/Event | 黑箱取得由真实世界事件确认，不由 LLM 文本直接置完成 |
| S7 | AI 提示可以撤离 | `ExtractionAvailable=true` 或等价公开任务状态 | Suggest RequestExtraction | **是** | Mission State、Confirmation | AI 不能自动结束任务 |
| S8 | 玩家请求撤离 | 已确认撤离请求 | 无 / 防守等待 | 玩家已确认 | Mission Controller | 合法进入结算 |
| S9 | 任务结算 | 公开结果 + Evaluator 内部真值分离 | 无 | 无 | Result、Trace、Evaluator | 输出完整 Episode 结果和指标 |

---

# 5. P0 关键设计细节

## 5.1 “63 小时重复信号”是任务情报，不是全知信息

AI 角色可以在任务触发后得知：

> 求救信号时间戳异常，已经重复至少 63 小时。

但它不能因此自动知道：

- 敌人具体位置；
- 废弃车队具体位置（除非任务规则已经确认）；
- 黑箱已经存在；
- 后续敌军部署。

这个事件应该进入合法 Mission Intel，再由 AI 频道表现。

## 5.2 “原地防守、不要追击”必须成为结构化约束

这不是一句只用于展示的自然语言。

至少需要表达：

```text
intent = Hold
area / anchor = 当前防区
constraints:
  pursue_outside_area = false
```

或现有 Core 的等价结构。

验收重点：

- 敌军短暂进入射程：可以合法交战；
- 敌军离开防区：单位不持续追出；
- 行为树负责局部执行；
- LLM 不逐帧纠正单位位置。

## 5.3 “取得黑箱”必须由世界事件驱动

AI 文本说“已取得黑箱”不能改变任务状态。

正确顺序：

```text
单位满足真实取得条件
→ 权威 Scenario / Objective 更新
→ 产生内部事件
→ 可见性 / 任务规则过滤
→ AI 频道收到“已取得”可见事件
→ AI 提示可以撤离
```

这样 Narrative 不会变成游戏规则入口。

## 5.4 “请求撤离”属于任务级不可逆操作

P0 即使处于 TacticalDelegate，也必须让玩家确认。

AI 可以：

- 建议撤离；
- 说明风险；
- 展示撤离按钮 / 卡片。

AI 不可以直接完成 RequestExtraction。

---

# 6. 玩家接管验收

P0 必须在本任务中加入至少一个可重复测试点。

## 场景

1. AI TacticalDelegate 控制侦察二队向外围营地移动；
2. 玩家在移动过程中手动给二队下达新的 Move / Hold；
3. Manual Override 生效；
4. AI 旧 Intent 停止；
5. 如果远程 AI 稍后返回旧决策，不执行；
6. 玩家恢复托管；
7. AI 根据当前新位置重新规划。

## 通过标准

- AI 不与玩家来回抢单位；
- 旧命令没有“延迟夺权”；
- Trace 能看到 scope revision / override / rejected stale decision 或等价记录。

---

# 7. Headless 版本如何处理叙事

Headless Runner 不需要实际显示 AI 对话 UI。

叙事事件转换为结构化 Mission Event：

```text
SignalLoopAnomalyConfirmed
BeaconConvoyDiscovered
BlackBoxRetrieved
ExtractionAvailable
```

测试只验证：

- 事件是否在正确条件发生；
- Policy 是否能合法看到；
- 后续状态是否推进。

实际中文文案、头像、动画属于 Presentation，不影响 Headless 判定。

---

# 8. ScriptedPolicy 基线行为

第一版 ScriptedPolicy 只需要“够用且合法”，不追求像真人。

建议流程：

```text
S2:
  授权侦察二队 → Scout/Move 至外围营地区域

S3:
  收到信号异常 → 保持二队安全 / 等待阶段指令

S4:
  对突击一队 → Hold + no_chase

S5:
  收到车队 / 信标合法情报 → 一队 Move/AttackMove

S6:
  遇敌按简单规则交战；生命 / 损失达到阈值时 Retreat

S7:
  ProposedIntent = RequestExtraction
  因任务级动作需要确认 → 在 Headless 自动化中由测试 Harness 模拟 PlayerConfirm

S8-S9:
  完成撤离并输出结果
```

重要：ScriptedPolicy 必须消费与 LLM 相同的 Policy Observation，不得直接读取 CampaignController 内部 Phase 来作弊。

它可以根据 Observation 中公开的 `mission_context / objective` 进行判断。

---

# 9. 最小 Benchmark Manifest 语义

每次跑“回声撤离 P0 Slice”至少指定：

```text
benchmark_id: echo_extraction_p0
scenario_id
scenario_version
map_id
seed
policy_id
policy_version
control_mode
observation_schema_version
intent_schema_version
timeout_profile
```

第一阶段先准备少量固定 Seed，具体数量由 Runner 稳定后确定。

不要先写死高胜率门槛；先采集 Scripted baseline。

---

# 10. 本任务必须输出的评测项

## L0 正确性

- schema_parse_ok；
- hidden_info_leak_detected；
- invalid_intent_count；
- stale_decision_rejected；
- timeout_fallback_count；
- deterministic_replay_check。

## L1 任务能力

- reached_outer_camp；
- signal_anomaly_confirmed；
- hold_no_chase_success；
- beacon_discovered；
- black_box_retrieved；
- extraction_available；
- extraction_confirmed；
- mission_completed；
- completion_tick / time；
- squad_losses；
- critical_unit_survival。

## L2 AI 工程

- proposed_intent_count；
- accepted_intent_count；
- rejected_intent_count；
- fallback_rate；
- decision_latency_p50 / p95；
- token_usage / cost（LLM 时）；
- parse_failure_count。

---

# 11. 自动化测试清单

## ECHO-001｜Human 基础流程

沿用当前可玩流程，确认策划流程本身没有被 AI 重构破坏。

## ECHO-002｜ScriptedPolicy 完整流程

不用 LLM，ScriptedPolicy 跑通最小任务。

## ECHO-003｜隐藏信息

在 S2 / S3 前检查 Policy Observation：

- 不含后续黑箱真值；
- 不含未触发车队位置；
- 不含隐藏敌军全量状态。

## ECHO-004｜Hold + No Chase

制造一个会离开防区的敌方目标，验证一队不会无限追击。

## ECHO-005｜玩家抢回控制

AI 控制二队移动时玩家接管，验证优先级与旧响应失效。

## ECHO-006｜非法目标

Policy 提交一个不可合法引用的目标，验证失败不泄露目标是否真实存在。

## ECHO-007｜模型超时

模拟 Policy 不返回，验证 fallback 后任务仍可继续。

## ECHO-008｜解析失败

MockPolicy 返回不可解析结果，验证不会污染 Core。

## ECHO-009｜撤离确认

TacticalDelegate 提议 RequestExtraction，验证必须经过玩家确认。

## ECHO-010｜黑箱权威事件

AI 文本或 ProposedIntent 不能直接把 `BlackBoxRetrieved` 改为 true；只能由场景真实条件完成。

## ECHO-011｜固定 Seed 回归

同版本 + 同 Seed + 同 ScriptedPolicy 运行多次，验证项目定义的确定性输出保持一致。

## ECHO-012｜Trace 完整性

失败或成功一局后，都能回溯每个 Decision Step 的 Observation → ProposedIntent → Validation → Applied Result。

---

# 12. 程序任务拆分建议

## Ticket A｜Scenario Phase 暴露

- 给 Evaluator 提供稳定的任务阶段；
- 给 Policy 只暴露策划允许公开的 mission context；
- 不把完整 CampaignController 内部状态直接序列化给 Policy。

## Ticket B｜Mission Event → Observation

把剧情事件经过过滤后转为可版本化任务情报。

优先支持：

- signal anomaly；
- convoy beacon；
- black box retrieved；
- extraction available。

## Ticket C｜Hold Constraint

确保 `Hold + 不追击` 是真实底层行为，不是 Prompt 约定。

## Ticket D｜Player Override

把 UI 手动接管与 Controller Scope / Intent 生命周期对齐。

## Ticket E｜Headless Echo Runner

能通过参数启动该 Scenario，注入 ScriptedPolicy，输出 terminal result + trace。

## Ticket F｜Echo Evaluator

把第 10 节指标从场景真值计算出来，但不回流 Policy。

---

# 13. Definition of Done

《回声撤离》P0 AI Slice 完成，需要同时满足：

- [ ] Human 原流程仍能玩；
- [ ] ScriptedPolicy 使用受限 Observation 跑通；
- [ ] AI 不直接访问 Node；
- [ ] 后续剧情 / 敌军真值不会提前泄露；
- [ ] Hold + no_chase 能被底层确定性执行；
- [ ] 玩家能随时接管托管小队；
- [ ] 旧 AI 响应不会延迟夺权；
- [ ] 黑箱取得由权威世界事件驱动；
- [ ] 撤离必须玩家确认；
- [ ] timeout / parse failure / invalid intent 不会卡死任务；
- [ ] 可以 Headless 运行；
- [ ] 固定 Seed 可做回归；
- [ ] 每局有完整 Trace；
- [ ] Evaluator 能输出 L0 / L1 / L2 指标；
- [ ] 后续替换成 LLM / LocalModel 时不需要修改关卡核心规则。
