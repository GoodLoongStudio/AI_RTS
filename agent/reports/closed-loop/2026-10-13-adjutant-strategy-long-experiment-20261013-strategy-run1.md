# AI 副官战略层长任务：收缩接口对照实验（run-id `20261013-strategy-run1`）

日期：2026-10-13（北京时间）。状态：**delivered / needs-review**。
执行入口：[长任务提示词](../../prompts/2026-10-13-adjutant-strategy-long-task.md)。
口径来源：[完整实验计划](../../plans/2026-10-13-adjutant-strategy-long-experiment-plan.md)、[跟踪表](../../plans/2026-10-13-adjutant-strategy-experiment-tracker.md)。
本轮产物：`agent/runs/20261013-strategy-run1/`（status.json / checklist.md / champion.json / comparison.json / 12 个对局目录 / offline 对照 / 置换检查 / 录像与解码帧）。

## 0. 一句话结论

**服务健康问题已排除；K0 的失败形态从"5/5 超时"变成"计划合法但采纳 0（10 次请求 → 0 采纳，p50 9.6s）"。把战略模型职责收缩成"在程序生成的合法候选里选一个"后，可用计划率从 1/10 升到 10/10、延迟从秒级降到毫秒级；但 2B 的"选择"被置换检查证明主要是位置偏置，而程序自身评分（D0）在同一批局面上指标与 D 完全相同且真实对局不劣于 A/C，因此本轮收敛到 `D0 + A 回退`——`--strategy-mode plan` 这套让 2B 自由生成战略的接口，本轮未过门槛。**

模型战略未达标、程序战略与执行可用，这是如实结论，不是"已完成"。

## 1. 本轮实际跑了什么

| 项 | 值 |
|---|---|
| 开发根 / 引擎 | `G:/AIRTS/AI_RTS`；`Godot_v4.7.1-stable_mono_win64_console.exe`（`--path` 明确指向主工程） |
| 模型端点 | `http://127.0.0.1:11436/v1`，别名 `minicpm5-adj-16k`（ollama，2.5B Q8_0，`llama-server -c 16384 -np 1`，`openai_reasoning_effort=none`） |
| Git | `4851de361b4c924cde0eacbe2d113b14fc6c9798`（战略链路文件带他人未提交改动，本轮**未** reset/checkout） |
| 真实对局 | 12 局（含 selftest 1 局）：配对 6 局（A/C/D0 × seed 11/22，3 分钟）+ 长局 3 局（8/6/6 分钟）+ 冒烟/诊断 3 局 |
| 每局固定 | 单机 Demo（headless 专用服 + 可见客户端 + 副官 runner）、`with_ai=False`、PlainAndSimple、`--seed` 11/22/33、`--strategy-review-seconds 10`、`AIRTS_S1_BACKEND=laya`、`--model on` |
| 离线对照 | 10 个**真实对局捕获**的冻结战略上下文 × 6 方案（A/K0/B/C/D/D0） |
| 录像 | 2 段 5FPS `printwindow` 录像（90s/450 帧、300s/1500 帧，`duplicate_frames=0`），实际打开 6 张解码帧 |

### 有效样本与局数

- 战略层真实请求：`m0-k0-initial` 1 次、`harvest-k0-01` 10 次、A 29 次、C 32 次、D0 149 次（含长局），合计 **221** 次。
- 离线请求：10 局面 × 6 方案 = **60** 次（K0/B/C 各含真实模型调用）。
- 置换检查：10 局面 × 3 种排列 = **30** 次真实模型调用。
- 按局为独立样本，**不**把同局多次决策算成多局。

## 2. M0：基础设施与测量（先排除误判）

- 小请求（同端点、同别名）：**6/6 成功**，稳态 p50 **54ms**、max 63ms（`m0_service.json`）。`ollama ps` 冷/热已区分。
- `tools/dev/match_instance.py selftest` → **rc=0**，34s，PASS×8（登记可控、开局 2 单位、move Accepted、位移实测、截图、按 pid 树清场、登记无残留）。
- 结论：**上一轮"5/5 ModelTimeout"的服务未就绪条件已消失**。因此本轮 K0 基线必须重测，不能继承旧数字（旧诊断只作线索）。

### K0 的真实失败形态（新鲜基线）

| 局 | 时长 | 战略请求 | 结构合法 | 采納 | 失败明细 | 延迟 |
|---|---|---|---|---|---|---|
| `m0-k0-initial` | 2 min | 1（完成后被退避挡住） | 0 | 0 | `ModelInvalidOutput`（11.25s，"Exceeded maximum output retries (0)"） | 11.25s |
| `harvest-k0-01` | 3 min | 10 | 6 | **0** | `strategy_result_rejected` 7 = `control_generation`×3 + 真超时 15.0s×2 + 「上一轮仍在推理」跳过×2；`plan_hold` 3 = 全部 `no_active_plan` | p50 **9589ms** / p95 10837ms |

进一步读原始输出：6 份合法回应里 **9/10 个局面（含 2 分钟局）模型回的是 `maintain_current=true` 且 `tasks=[]`**，即"维持现计划"；而当时 `active_plan` 为空 → 落到 `plan_hold(no_active_plan)`，版本与任务都不变。**这是"合法但零信息"的典型**：格式对、语义没用。

## 3. M2/M3：收缩接口的离线对照（同一批真实冻结态势）

10 个上下文来自 `harvest-k0-01` 的真实对局（真事实、真单位 ID、真 campaign 视图），每个方案跑一遍。
证据：`harvest-k0-01/offline/offline_summary.json`、`offline_records.jsonl`。

| 方案 | 契约合法 | **可执行计划率** | p50 | p95 | 说明 |
|---|---|---|---|---|---|
| A-rules | 10/10 | **10/10** | 0.3ms | 0.4ms | 程序主线计划，不调模型 |
| K0-plan | 10/10 | **1/10** | 2518ms | 3058ms | 9/10 是 `maintain_current=true` |
| B-template | 10/10 | **10/10** | 137ms | 159ms | 模型只回 `{"template","focus"}` |
| C-choice | 10/10 | **10/10** | 106ms | 130ms | 模型只回 `{"choice":"C2"}` |
| D-score | 10/10 | **10/10** | 0.3ms | 0.4ms | 程序评分；歧义才问模型 |
| D0-score_only | 10/10 | **10/10** | 0.3ms | 0.3ms | 纯程序评分，绝不调模型 |

三条判断：

1. **C1 得到支持**：同一批态势下，缩小接口把"可执行计划率"从 0.1 提到 1.0，延迟从 ~2.5s（离线）/9.6s（真实局）降到 0.1~0.14s。
2. **D 没有超过 D0**：margin=8 下**仲裁 0 次**（D 与 D0 每个数字都相同）。按计划 §11「D0 与 D 相当，优先更简单者」→ 不给仲裁找存在感。
3. **C2 没有得到支持，且 C 的选择不可信**：见下节。

### 候选置换检查（防"总选第一项"）

`harvest-k0-01/permute/permutation.json`：每个局面 3 种排列（原序 / 种子 23 重排并改名 P1..Pn / 种子 37 重排改名）。

- **语义稳定性 7/10**。
- 不稳定的 3 个局面里，带语义 ID 时选 `C-ECO`（恰为第 1 项），换成不可读 `P1..P4` 后**两次都选 `P1`**（不同洗牌种子、`P1` 语义都是"基地防守"）。
- 结论：**2B 的"选择"主要跟位置走，没有证据显示它在比较内容**。C 得 10/10 的"合法率"来自程序兜底，不是模型判断力。

## 4. M4/M5：真实对局行为对照

证据：`comparison.json`（由 `scripts/analyze_runs.py` 从每局产物生成）。

| 局 | 方案 | seed | 请求/成功 | 战略 p50 / p95 | 采纳 | 保持 | 拒绝 | Accepted 命令(去重) | 收官己方实体 | 余额 | 里程碑 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| m4-a-s11 | A rules | 11 | 13/13 | 0.2ms / 1.2ms | 1 | 11 | 1 | 44 (44) | 15 | 550 | 5 |
| m4-a-s22 | A rules | 22 | 16/16 | 0.2ms / 1.2ms | 1 | 14 | 1 | 34 (32) | 18 | 100 | 4 |
| m4-c-s11 | C choice | 11 | 13/13 | 604ms / 5484ms | 8 | 3 | 2 | 42 (41) | 15 | 550 | 5 |
| m4-c-s22 | C choice | 22 | 14/14 | 596ms / 8803ms | 9 | 1 | 4 | 35 (34) | 21 | 150 | 5 |
| m4-d0-s11 | D0 | 11 | 15/15 | 0.3ms / 1.2ms | 9 | 5 | 1 | 36 (35) | 22 | 0 | 5 |
| m4-d0-s22 | D0 | 22 | 15/15 | 0.3ms / 1.2ms | 7 | 6 | 2 | 35 (34) | 23 | 100 | 6 |
| harvest-k0-01 | K0 plan | 0 | 10/6 | 9589ms / 10837ms | **0** | 3 | 7 | 31 (30) | 15 | 550 | 5 |

长局（D0，seed 33）：

- `m5-d0-long` 8 分钟：44 请求全成功，采纳 **30**、保持 9、拒绝 4；246 条命令 → **159 Accepted（132 去重后）**；收官 **101** 个己方实体、余额 **33045**、**6** 个里程碑。
- `m5-d0-long-rec` 6 分钟（含录像）：31 请求 → 采纳 16、40 个己方实体、余额 16200、6 个里程碑。

行为结论：

- **采纳率**：K0 0 < A 1 ≪ C 8~9 ≈ D0 7~9。C/D0 的局面代际拒绝只有 1~4 次（K0 是 7 次）。
- **发展**：两个 seed 上 D0 的收官实体数（22/23）都不低于 A（15/18）与 C（15/21）；seed 22 上 D0 里程碑最多（6 vs A 4 / C 5）。
- **不可行订单**：D0-11 的 `InsufficientResources` 拒绝为 **0**，A/C 同 seed 各 3~4 次——评分里带"经济瓶颈"项的直接效果。
- **合法性**：6 局全部拒绝原因只有 `NoValidSite` / `ConstructionInProgress` / `InsufficientResources`（游戏侧正常约束），**没有** `LedgerFull` / `IntentLedgerFull` / `EmptyUnitSet` 风暴 / 空单位夺权 / 旧局结果被采纳。

## 5. 计划到执行一致性：断在 task_id 上（本轮最重要的反面发现）

命令账本里**没有任何一条命令的 `task_id` 是战略计划的 `strat-*`**：全部是规则地板的 `rule-*` 或四列接口的执行者标签 `W1/F1/S1`。

- 静态链路是通的：`task_patch_bridge.build_decision_frame(..., strategic_tasks=_strategic_task_lines(state))`（唯一实现，无条件调用），即采纳的战略任务会作为**上下文行**进入战术层提示词；`nodes._commit_strategy_plan` 也把任务状态写进 `active_tasks`，回执按 `task_id` 更新进度。
- 但 `active_tasks` 里的 `strat-*` 永远不会被回执命中（没有命令以此 id 下发），所以"计划是否被遵从"**不能**用命令账本证明，只能看战术层提示词内容。
- 本轮**没有**捕获战术层提示词（`decisions/rounds/events/model.jsonl` 里都没有 `strategic_tasks` 字段），因此该链只有静态证据，**运行期未取证**。

⇒ 按计划 §证据纪律，`计划到实际执行一致性` 本轮判 **PARTIAL / 不可追踪到命令级**；"采纳了更多计划"不等于"计划被执行"。这是把 D0 判为 champion 时必须一起交付的限制条件。

## 6. 动态证据：实际看过的帧

录像器材：`tools/dev/record_playtest.py`（`printwindow`，只采指定 PID 的窗口客户区，窗口在屏外 `-4000,-4000`，未抢焦点、未系统注入输入、未录桌面）。**注意**：录像器需要 OpenCV，副官 venv 没有 → 必须用 `D:/software/anaconda3/python.exe`（首次失败见 checklist C-010）。

| 视频 | 时间码 | 打开的原帧 | 我看到的 |
|---|---|---|---|
| `m5-rec-try2/video/clip-01.mp4`（2min, D0, seed33） | 5.0s | `review/early/frame-0000025.jpg` | 指挥中心 + 在建建筑，HUD「岚·AI副官／副官运行中」，结果栏 `A 资金1880/余额9400` |
| 同上 | 85.0s | `review/late/frame-0000425.jpg` | 车厂附近 5 个单位、建造完成，结果栏 `A 资金110/余额550`；面板写「正在维持：采集×5、建造×4」 |
| `m5-d0-long-rec/video/clip-01.mp4`（6min, D0, seed33） | 140.0s | `review/mid/frame-0000700.jpg` | 基地 + 车厂 + 约 6 个坦克，`资金 550`，面板「正在维持：建造×5、采集×3」 |
| 同上 | 190.0s | `review/mid/frame-0000950.jpg` | 同布局；画面下方出现 1 个远离基地的移动单位（侦察/工程车） |
| 同上 | 265.0s | `review/late/frame-0001325.jpg` | **出现「战区补给·三选一」模态（剩余 15 秒）**，等玩家选；联机战局仍在推进，倒计时后自动选 |
| `m5-d0-long/screenshots/final.png`（8min, D0, seed33） | t=479s, 212FPS | 静态截图 | 基地周围**成片坦克（约 50 辆）**，`资金 33045`；面板「正在维持：采集」「本轮没有新命令（丢弃 16 个单位）」，状态「规划中（目标: 施压）」 |

**明确未看到的东西**：全部 12 局都是 `with_ai=False`，场上**没有敌人**。因此我看到的部队是"在基地周围集结"而不是"推进交战"；S03/S04/S06（已确认敌情的持续作战、基地受袭、路径失败恢复）本轮**没有可测样本**。这一点不能靠上述帧来"看起来还行"。

## 7. 门禁与测试

| 检查 | 命令 | rc | 结果 |
|---|---|---|---|
| 新增合同测试 | `python -m unittest -v adjutant_coordinator.tests.test_strategy_variants` | **0** | 11/11 OK（候选恒合法、越界回退规则、D0 不调模型、D 只在歧义调、置换不改语义） |
| 副官协调器全量单测 | `python -m unittest discover -s adjutant_coordinator/tests -p "test_*.py" -t adjutant_coordinator/tests` | 1 | Ran 1062，1 failure + 1 skipped；失败是 `test_campaign_mainline.InterruptStackTest.test_defense_branch_only_when_interrupt_active`，只 import `campaign/decision_map/rules_fallback/state`，这三个文件有 **2186 行他人未提交改动** → 判为他人 WIP，不属本轮（见 checklist C-011） |
| 定向 Godot 回归 | `python tools/run_targeted_godot_tests.py --godot <console> --ids adjutant-command-protocol,adjutant-observation,adjutant-rules-export` | **0** | 3/3 `passed=True rc=0`；工具输出的屏蔽模式为 `ObjectDB instances were leaked at exit`、`RID allocations of type .* were leaked at exit`、`resources still in use at exit`、`SCRIPT ERROR`（工具自身判 pass，我**未**独立核验这些模式的良性） |
| 每个新文件解析 | `python -m py_compile strategy_variants.py agent_runner.py run_match.py offline_replay.py` | 0 | — |
| 路径边界 | `python tools/check_workspace_target.py --mode develop --target <新文件>` | 0 | `decision: allow` |

**未做**：全量 Godot 128 项、独立会话复核、`tools/run_full_regression.ps1`。

## 8. 源码变化与回退入口

**落地并保留的改动（全部新增文件，未改任何既有文件的默认行为）**

- `source/adjutant_coordinator/graph/strategy_variants.py`（新增）：B/C/D/D0 四个 provider + 事实提取 + 候选生成 + 可解释评分 + 候选置换开关。**产品代码不 import 它**（只有本轮自己的测试 import）。
- `source/adjutant_coordinator/tests/test_strategy_variants.py`（新增）：11 项合同测试。

**尝试落地但被阻塞的改动：`blocked: workspace`**

`source/adjutant_coordinator/deploy/agent_runner.py` 上的写入会在约 3 秒内被还原回 `14:15:55 / 129925B` 版本（两次独立复现：`replace_in_file` 报成功，紧接着读取仍是旧内容）。因此**没有**把 `--strategy-mode template|choice|score|score_only` 接进产品命令面。

为了让实验照常完成，本轮把策略注入放在**自己的 runner 包装器**里（零共享源码改动）：
`agent/runs/20261013-strategy-run1/scripts/capture_runner.py`——monkeypatch `MeteredModel._invoke` 抓取战略上下文，并按 `AIRTS_STRATEGY_VARIANT` 把战略 provider 换成收缩接口。

**若之后能安全写入，落地补丁只需三处**（内容已在 `checklist.md`/本报告记录，未落盘）：

1. `--strategy-mode` 的 `choices` 加 `template/choice/score/score_only`；
2. `_build_models()` 里识别 variant 模式并调用 `_build_variant_strategy(settings, mode)`；
3. 新增模块级 `_build_variant_strategy()`：用 `settings.base_url_for("strategy")` / `model_for` / `timeout_for` 构造 `strategy_variants.LocalChat`，返回对应 provider。

**精确回退（本轮全部改动）**

```powershell
# 1) 默认行为没有变化：不传 --variant 时 runner 与基线逐字一致。
# 2) 删除本轮新增的两个源码/测试文件：
Remove-Item G:/AIRTS/AI_RTS/source/adjutant_coordinator/graph/strategy_variants.py
Remove-Item G:/AIRTS/AI_RTS/source/adjutant_coordinator/tests/test_strategy_variants.py
# 3) 证据目录（agent/runs 是临时目录，可整体删除）：
Remove-Item -Recurse G:/AIRTS/AI_RTS/agent/runs/20261013-strategy-run1
# 不改 build/adjutant_runtime、不动打包版、不动任何 venv/模型
```

## 9. 进程与清理

- 12 局全部由 `MatchGroup` 动态端口 + 实例登记启动，收尾按 **pid 进程树**：每局 `cleanup_ok=true`、`leftovers=[]`。
- 未按端口或映像名杀任何进程；未使用 `runner_ctl.py stop`；未结束任何非本轮 PID。
- 录像器、runner 子进程在 `finally` 中等待/精确终止；辅助控制台 `CREATE_NO_WINDOW`，游戏窗口屏外非激活。
- 一处**操作失误并已归位**：第一次 `run_match.py` 用了相对路径，把 runner 日志/状态/capture 写进了 `source/m0-k0-initial/`；已整体移回证据目录并删除 `source/` 下的空目录（`source` 现无残留）。

## 10. 未验证项（不得当成通过）

1. **模型侧战略没有一项晋级**：K0 未过门槛；B 只做了离线对照（没有真实对局）；C 的语义选择被置换检查证伪（0.7）。"2B 能把战略选对"本轮**未被证明**。
2. **没有敌情的对局**：12 局全部 `with_ai=False` → S03/S04/S06（确认敌情的持续作战、基地受袭紧急链、路径失败恢复）与"目标反转/最长停滞/战斗推进/防守撤离"指标**未测**。
3. **跨地图未取得**：`--map` 在服务端被接受但实际仍用 `PlainAndSimple`（`probe-map47`），`--seed` 生效。根因待查（`NetSession` 固定地图收敛点）。因此"未见地图"的泛化结论**没有**。
4. **性能对照未做**：帧 p95 / >100ms 计数 / 权威模拟速度 / 内存、录像开与关的配对测量都没有采集（`op=status` 未返回 perf 字段）。
5. **S07/S08 未做**：玩家接管夺回、超时/空/非法注入、暂停/退局重开、旧局结果拒绝（只在自然局观测到 `control_generation` 拒绝 15 次，不是受控注入）。
6. **正常生命周期未做**：全部开局走 DCS `op=start`、退局走 watchdog + pid 树；**正常菜单开局/退局/换图重开**与"UI-player"资格（点选/框选/右键/持续按键）没有证据。
7. **计划→执行一致性只有静态证据**（§5），战术层提示词未捕获。
8. **样本量小**：配对只有 2 个 seed；D0 的"更好"是趋势，不是统计结论。
9. **全量回归与独立复核未做**。
10. 定向 Godot 回归工具报的屏蔽模式（leak / SCRIPT ERROR）我未独立核验。

## 11. 结论与本地组合

**本轮交付的本地组合**

- 默认（建议）：**D0 —— 程序在当次真实上下文上生成 ≤4 个已验证可执行的 `StrategicPlan` 候选 + KEEP，用可解释评分直选；战略层不调用模型。** 依据：同一批 10 个真实冻结态势可执行率 1.0、p50 0.3ms；真实 2 seed 配对中收官实体数与里程碑不低于 A/C，且 `InsufficientResources` 更少；8 分钟长局 101 实体 / 余额 33045 / 6 里程碑。代价：**没有模型参与战略**。
- 回退：**A —— `--strategy-mode rules`**（程序主线计划 + 同一 Laya 执行层），已验证 2 局 + 离线 10/10，成本 0.2ms。
- 保留但不默认：**C（`{"choice":...}` 收缩接口）**——格式与延迟都稳（真实局 p50 0.6s、0 错误、采纳 8~9），但位置偏置未解，且相对 D0 没有行为收益。
- 拒绝：**K0（完整规划接口）**——可用计划率 0.1、真实局采纳 0、p50 9.6s、最长 15s 超时；**D（带仲裁）**——仲裁 0 次，等于 D0 加复杂度。
- **E 未进入**（条件不成立）；**T unavailable**（本机未授权其它模型）。

**产品状态**：`needs-review`。收缩接口未接进产品命令面（`blocked: workspace`），因此不能称为"产品完成"；本文交付的是**经过真实验证的组合 + 可复现证据 + 精确回退**。

## 12. 下一步（按价值排序）

1. 在可安全写入时落地 §8 的三处接线（约 15 行），把 `score_only` 变成可开关的 `--strategy-mode`。
2. 用 `with_ai=True`（或 `deploy/selfplay_match.py`）重跑配对，补齐 S03/S04/S06 与战斗指标。
3. 修 `NetSession` 固定地图收敛点，解锁跨图 held-out。
4. 给 C 加"每请求随机候选次序 + 不可读 ID"再测语义稳定性；若仍 <0.9，永久保留 D0。
5. 补性能配对测量与 UI-player 资格；补一次正常菜单退局/重开。
