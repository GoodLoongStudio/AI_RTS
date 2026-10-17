# AI 副官战略实验交付：独立验收

日期：2026-10-13。开发根：`G:/AIRTS/AI_RTS`。被验收批次：`20261013-strategy-run1`。

**结论：完成了一轮有用的探索，没有完成原长任务，也没有修好正常游戏的战略层。此次产品验收不通过；D0 保留为实验候选，不晋级产品 champion。** 原报告自身的准确状态也是 `delivered-needs-review`，其“经过真实验证的组合”只能限定为同地图、无对手、实验包装器下的短时经济观测。

本次只新增审计证据、报告、计划与续跑提示词；没有修改游戏源码、配置、默认启动器或模型，没有启动新游戏、结束其他进程或清理原证据。

## 1. 判据和独立证据

原要求见[长任务计划](G:/AIRTS/AI_RTS/agent/plans/2026-10-13-adjutant-strategy-long-experiment-plan.md)：独立快照验证、实际执行追踪、带敌方的真实对局、跨地图与 seed、20 分钟长局、玩家接管、故障与正常退重开、性能、回归门禁。局数多或 JSON 合法不能代替这些要求。

原交付：[实验报告](G:/AIRTS/AI_RTS/agent/reports/closed-loop/2026-10-13-adjutant-strategy-long-experiment-20261013-strategy-run1.md)、[状态](G:/AIRTS/AI_RTS/agent/runs/20261013-strategy-run1/status.json)、[champion 声明](G:/AIRTS/AI_RTS/agent/runs/20261013-strategy-run1/champion.json)。

本次独立生成的[证据 JSON](G:/AIRTS/AI_RTS/agent/runs/20261013-strategy-delivery-audit/audit_evidence.json)直接逐行读取原始模型、决策、回执和状态记录，没有调用原 `analyze_runs.py`，没有调用模型服务。附[复算脚本](G:/AIRTS/AI_RTS/agent/runs/20261013-strategy-delivery-audit/audit_evidence.py)。

## 2. 需要修正的主要结论

### 2.1 正常游戏没有接入新增策略

[`agent_runner.py:2134`](G:/AIRTS/AI_RTS/source/adjutant_coordinator/deploy/agent_runner.py:2134)的 `--strategy-mode` 仍只接受 `off/plan/rules`，默认 `plan`。产品源码没有 import 新增 `strategy_variants`；只有新增单测引用它。

B/C/D/D0 通过 `agent/runs/.../scripts/capture_runner.py` 的 monkeypatch 和 `AIRTS_STRATEGY_VARIANT` 注入实验 runner。正常启动不能选择这些模式，更没有把 D0 设成默认。原报告关于“写入被其他会话还原”的归因本次没有独立复现；当前 mtime 只能证明现存文件状态，不能证明是谁回写。

### 2.2 “程序候选都已验证可执行”被真实上下文反例否定

本次对 `harvest-k0-01` 的首个真实冻结上下文重新生成候选（tick 527）：AI 控制 `Unit_0/1/2`；其中 `Unit_0=command_center`，`Unit_2=vehicle_factory`。

| 候选 | 实际生成的任务 | 与真实规则的冲突 |
|---|---|---|
| 侦察 C-RECON | `Unit_0/Unit_1` 执行 scout | 把指挥中心当成可移动侦察单位 |
| 防守 C-DEFEND | `Unit_0/Unit_1/Unit_2` 执行 defend/hold | 把指挥中心、车厂计为作战单位，不能代表主力回防 |
| 集结 C-ASSAULT | 同上执行 regroup/move | 静态建筑进入移动集结任务 |
| 经济 C-ECO | `Unit_0` produce，完成条件为“指挥中心补到 6 名工人” | 当次 `production_relations` 明确 worker 仅由 vehicle_factory 生产 |

来源是 [`build_facts/spare_units/combat_units`](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/strategy_variants.py:90)按 track/空闲集合推断能力，并在缺乏 military track 时把剩余所有实体当作作战单位；[`generate_candidates`](G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/strategy_variants.py:236)没有按真实生产关系、移动能力、当前可用路线和资源约束逐个验证。这 10 个冻结上下文中，独立发现 30 条候选记录把生产建筑放入移动/侦察/作战任务。

另外两个独立 provider 输入反例也成立：

- 将当次 `ai_controlled_units` 清空、全部交给玩家，保留原生产视图，仍生成引用 `Unit_0` 的生产任务；结构解析仍通过。
- `current_plan` 只有 plan_id、已过期且来自另一局，仍提供 KEEP；目前只检查 plan_id 存在。

这些证明的是候选生成器没有实现其宣称的前置校验，**不表示游戏已绕过下游权限守卫实际指挥了玩家单位**。正常输入约束及下游拒绝机制仍需动态验证。

### 2.3 B 的“10/10 成功”实际上是 10/10 规则回退

独立读取 `offline_records.jsonl`：B-template 的 10 次 `variant_meta` 全部为：

```json
{"fallback":"template_out_of_enum:C-ECO","chosen":"RULES"}
```

对应 `plan_id` 全是 `rules-mainline-default`。模型把候选 ID `C-ECO` 填进 template，而模板枚举要求 `economy` 等名称。因此应报告 **B 原生模板选择成功 0/10；规则恢复成功 10/10**，不能把 137ms 的规则回退结果说成 B 的模型战略成功。

原离线 `check_plan` 把“非 KEEP 且 tasks 非空”定义为 actionable，没有验证每个任务的真实能力、目标、预算和生产关系。“10/10 有任务”不等于“10/10 可执行”。

### 2.4 C 的置换验证不能证明 70% 的内容理解

重算结果确实是 7/10 三次名称一致，匿名 ID 条件中 **20/20 都选 P1**。更关键的是 seed 23、37 这两个乱序都把 `基地防守` 放在 P1；所有 10 个上下文的候选结构类似。这一设计没有把最关键的候选均匀放到不同位置。

因此 7/10 一致与“匿名时总选第一项”仍不可区分，不能给 C 记 70% 语义选择质量，也不足以单独判定模型能力上限。需候选轮转/均衡置换、独立快照、明确行为判据后重测。当前 C 不适合晋级。

### 2.5 D0 的经济趋势不能证明它改善了战略执行

独立复算的六局配对数据与原报告基本一致：

| 模式 | seed 11 / 22 最终己方实体数 | seed 11 / 22 计划采纳数 | 条件 |
|---|---:|---:|---|
| A 规则 | 15 / 18 | 1 / 1 | 同一地图、无敌方、各 3 墙钟分钟 |
| C 选择 | 15 / 21 | 8 / 9 | 同上，实验包装器 |
| D0 评分 | 22 / 23 | 9 / 7 | 同上，实验包装器 |

原 K0 收集局：10 次战略请求，6 次返回结构，0 次采纳；调用延迟中位数 9589ms。D0 长局：479.13 秒状态采样跨度、101 个己方实体、159 条 Accepted 回执。上述是可保留的观测事实。

但这 6 局乃至所查全部归档命令都没有 `strat-*` task_id，来源为 `rule-*` 和战术执行者行。静态链确实会把 phase_goal 和 `task_id:completion` 摘要送入 DecisionFrame/Laya 文本，所以**不能据缺少 task_id 就说战略完全无效**。缺的是本次请求、被采纳方案、Laya 当时实际输入和候选变化、输出、回执、单位进度之间的关联证据；目前不能把经济差异因果归给 D0。

D 和 D0 的离线 10 次都选 C-ECO，D 仲裁 0 次。可认为“这组无敌情样本未触发仲裁”，不能认为已经证伪仲裁在复杂局面的收益。

## 3. 覆盖范围未达到原任务

独立盘点得到 **15 个含 summary.json 的实验目录**（包括启动诊断、录像失败重试、换图尝试），全部 `with_ai=false`，服务端实际地图全部 `PlainAndSimple`。原报告“12 局”不是完整产物盘点口径；这些目录也不能都计成合格评测局。

- 冻结态势只有同一局的 10 个，不是要求的 24 pilot + 独立 24 validation；60 次离线调用和 30 次置换复用这同一组上下文。
- 配对仅 2 个 seed、1 张地图、约 3 墙钟分钟；无真实敌方攻防，不具备战斗质量结论。
- 最长配置 8 墙钟分钟，缺少 A 与优胜者各 20 模拟分钟长局，缺跨图 10 模拟分钟配对。
- 模拟时钟没有直接采集。`CurrentServerTick()` 是物理帧，Match 大地图路径会切到 20Hz；不能固定除以 60 当模拟秒。应读取已有 `Match.get_simulation_msec()` 并核验暂停口径。
- 玩家接管、受控故障、暂停、退重开、旧局结果拒绝、正常菜单生命周期和动态战斗均缺证据。
- 原采样器在 `op=status` 查 perf 字段失败，不代表性能不可采；当前 DCS 已有 `op=perf`。缺可见帧时间、长帧、模拟吞吐、内存及录像开关对照。
- 没有完成全量 Godot 回归、正常玩家输入验收和晋级前独立复核。

## 4. 测试门禁

| 检查 | 本次独立结果 | 验收解释 |
|---|---|---|
| 新增 provider 单测 | 11 项，rc=0 | 接口单测通过；未覆盖上述真实能力/规则反例 |
| 原失败用例单独新进程运行 | rc=1 | 仍失败：`test_campaign_mainline.InterruptStackTest.test_defense_branch_only_when_interrupt_active`；不能凭其他文件是 WIP 就标 rejected/不计门禁 |
| 原副官全量单测 | 原报告 1062 项、rc=1 | 本次未重跑全量；保留失败状态，未判定其责任属于新增代码 |
| 原定向 Godot 日志 | 3 个 marker + rc=0，但 forbidden_hits 均非空 | 不满足原任务的日志门禁；工具 passed 不能代替综合验收 |
| 全量 Godot | 清单当前 128 项 | 原交付未运行，本次审计也未执行 |
| 本次只读复算 | rc=0 | 提取事实，不是产品测试通过 |
| 工程 Git 根及三个文档目标边界 | rc=0 | 主工程身份正确 |

独立测试命令（cwd=`G:/AIRTS/AI_RTS/source`，Python 为既有副官 venv）：

```text
python -m unittest -v adjutant_coordinator.tests.test_strategy_variants
python -m unittest -v adjutant_coordinator.tests.test_campaign_mainline.InterruptStackTest.test_defense_branch_only_when_interrupt_active
```

日志：[11 项单测](G:/AIRTS/AI_RTS/agent/runs/20261013-strategy-delivery-audit/variants.log)、[单独失败用例](G:/AIRTS/AI_RTS/agent/runs/20261013-strategy-delivery-audit/reported_failure_alone.log)。

Godot 观测日志有两处真实错误：`SCRIPT ERROR: Invalid call. Nonexistent 'float' constructor`，位于 `MatchReportScoring.gd:120` 的 `_economy`，发生于历史报告结束链。其他两条套件含资源/对象退出泄漏。是否为已有测试夹具问题需要复核，不能吞掉或自动当良性。已复制原日志，避免共享 build 目录后续运行覆盖：[原始观测日志副本](G:/AIRTS/AI_RTS/agent/runs/20261013-strategy-delivery-audit/original_targeted_logs/adjutant-observation.log:349)。

本次没有修改测试判据，也没有因为失败属于其他模块就自行修其他工作。

## 5. 实际查看的图像

已打开并查看[原 D0 长局最后截图](G:/AIRTS/AI_RTS/agent/runs/20261013-strategy-run1/m5-d0-long/screenshots/final.png)：坦克集中于两座车厂周围，资金 33045；副官面板显示“摸底/经济点火”，并提示“战略思考这一轮没成功，先用规则顶住”。这只能证明该静态帧状态，不能证明持续推进、战斗或停滞原因。本次没有把打开一张截图算作视频动态验收。

## 6. 保留、续跑与回退

可以保留：接口收缩方向、候选 provider 的实验框架、规则回退、原始上下文和对局数据、K0 高延迟与 0 采纳的新证据。当前证据支持“完整长计划接口在这台本机的这一组局面不可靠”，没有证明“所有 2B 战略都不行”，也没有证明 D0 能正确打仗。

下一轮首先修真实候选校验和统计口径，再完成可开关接线、实际战略到执行关联证据，随后回到原计划补带对手、独立快照、跨地图、长局和所有门禁。[可直接交给执行 AI 的续跑提示词](G:/AIRTS/AI_RTS/agent/prompts/2026-10-13-adjutant-strategy-review-continuation.md)已包含具体反例和停止条件。原任务不是只补约 15 行入口就完成。

正常产品不接入变体，因此此次审计没有需要回滚的行为补丁。保留原实验目录，**不执行原报告要求删除整套证据的回退步骤**。若未来淘汰新增模块，只能在检查调用方/活动实验进程后精确撤销它自己的文件；日志、上下文和报告应保留。

共享工作区有大量未提交修改。此次复算开始/结束记录并比较 runner、variant、单测、campaign、behavior_tree、Match 和定向运行器 SHA-256，均保持一致。这说明本次审计区间所查文件稳定，不证明原实验每局都运行在同一棵源码树。

本次新增文件：审计计划、本报告、续跑提示词、独立复算脚本/JSON/测试日志及原始定向日志副本。未修改其他 AI 的计划、checklist 或 champion 声明。审计状态完成；被验收交付保持 `needs-review`，连续未提升次数本次不重新计数、不覆盖原记录。
