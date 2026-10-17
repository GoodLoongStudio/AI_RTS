# RA3 共用调度移植：S0 + 第一候选（相位错开）阶段报告

- 日期：2026-10-11（20:32–21:1x）
- run-id：`2026-10-11-ra3-shared-nav`；证据目录：`agent/runs/2026-10-11-ra3-shared-nav/`
- 任务提示词：`agent/prompts/2026-10-11-ra3-shared-ai-navigation-deepseek.md`；关联计划：`agent/plans/2026-10-11-ra3-shared-ai-navigation-plan.md`
- 状态：**needs-review**（S0 完成；S1 第一候选 `rejected-with-evidence` 已精确撤回；下一步候选方向已修正）

## 1. S0 交付（全部落盘）

| 交付物 | 路径 | 说明 |
|---|---|---|
| 数值合同 | `agent/runs/2026-10-11-ra3-shared-nav/acceptance-contract.md` | 编辑前锁定：L1–L5 负载档、四道门禁、5% 工程门禁、行为/响应合同、候选专项判据、基线旧 BUG（B-01..B-04） |
| 基线/champion | 同目录 `baseline.md` + `baseline-hashes.txt` | champion = 当前工作树（HEAD `9a2e6d4` 不可独立编译）；14 文件 + DLL hash；三种命令来源入口（电脑/副官/真人共用 CommandRuntime，缺持久编组/到期/路径队列） |
| 热点排序 | `baseline.md` §4 | H1 移动/RVO（他人 2270 行进行中，不碰）；H2 AI 查询桥接（电脑会话阶段一/二，不抢）；**H3 AI 决策同帧集中（无归属 ⇒ 本轮候选）**；H4 副官路径提示（进行中，不碰） |
| 保护项 | `baseline.md` §5 | Movement/副官 Python/16:19 批次语义/权限边界/画质碰撞物理——不可回退不可触碰 |

基线数值引用既有实测（不重复测量）：RVO handoff（1000 单位 1577ms p50）、stage1（AI 拍 88% 在 C# 桥接层；1AI AI≈2.5% 单核、3AI≈8.6%）、multithreaded plan（400 单位 champion 6.893 FPS，两刀已退回）、adjutant 计划（diagnosis-and-handoff）。

## 2. 第一候选：AI 决策相位错开（S1 到期调度）——**rejected-with-evidence**

**假设**：3AI × 5 Controller 的 15 个 0.5s 决策 Timer 同相位 ⇒ 每拍集中尖峰；按 (player_rank × controller_index) 确定性错开后尾帧改善、语义不变。

**实施**（7 文件，最小改动 + `AIRTS_AI_PHASE_STAGGER=0` 回退开关）：见 `round-01/patch.md`。

**验证与结果**（详见 `round-01/verification.md`）：

| 维度 | 结果 |
|---|---|
| 静态/单元 | 6/7 文件 check-only rc=0（SimpleClairvoyantAI 的 rc=1 为 check-only 无法解析 autoload，以未改动文件对照归因）；纯函数探针 **17/17 PASS** |
| 运行时机制 | 3AI 真实 Match：15 相位 0…14/15 各不同、period=1.00s、**phase-end 帧两轮逐帧一致**（确定性） |
| **受控计数（决定性）** | GetOwnForces **2663/2654（ON）vs 585/583（OFF）＝×4.5**；capture.misses **2664/2654 vs 209/203＝×12.7**（2/2 稳定复现） |
| 帧时间 | p99 ON 33.3/22.1 vs OFF 28.4/29.5——ON 组内波动覆盖组间差，**无可归因收益** |
| 行为 | 单位 58–69、0 错误、命令链正常 |

**机理**：`CaptureShared` 帧快照 + `own_forces_scan`/`battlefield_scan` 按物理帧缓存 ⇒ **同帧 5 个 Controller 共享一次查询**是本架构的效率来源；相位错开把决策拆到 5 个不同帧，直接拆散了该共享（OFF 侧 3.1 次/秒 = 15÷5 共享；ON 侧 14 次/秒 = 每拍每 Controller 各一次），**回退 stage1 收益的大半**（对照 stage1 champion 538/535 次）。

**处置**：`rejected-with-evidence`，7 文件**精确撤回**（逐文件 SHA-256 前缀与改动前相同，`REVERT_EXACT`）。代码零残留，champion 保持 16:19 批次树。

**保留结论（方向修正）**：
1. **RA3 式"错开相位"不能移植到"每帧重建共享快照"的架构上**——RA3 的 Manager 持有持久数据副本/增量更新，而 AIRTS 的帧快照要求"同帧集中"才有效率。该结论是对研究文档 P0/P1 建议的**本地化修正**（研究文档未覆盖此交互）。
2. 后续候选应**扩大同帧共享**（同帧同参数查询去重、三来源共享），而不是拆散决策相位；与 stage1 `own_forces_scan` 同型同合同。

## 3. 边界与并行状态（S0 记录）

- 本轮只写 7 个 AI 文件（已撤回）+ 本 run/报告/计划；**未触碰** Movement.gd（+2270 行进行中）、`source/adjutant_coordinator/**`（19:2x 仍在写）、C# 与 config。
- 机器并行：另一会话 full-serial 回归 124/124（20:43 完成）前后执行；本候选 4 次 run 窗口内系统负载 43–72%（含用户后台），**帧时间数据标注非独占环境**（受控计数不受影响）。
- 收尾时机器仍被其他会话占用：`20261010-background-playtest-01` 的后台联机对局（Godot 38140，端口 24772/24773）与 `20261011-adjutant-repair-01` 的副官 r10 attach 实验（Python 59668 等）活跃运行中。
- 无人为中断用户操作；全部辅助进程隐藏、探针/驱动各自清理（`ai_perf_run.py` pid 树清理）。

## 4. 门禁状态

| 门禁 | 状态 |
|---|---|
| 静态/解析 | ✓（6/7 + autoload 对照归因；探针 17/17） |
| 无头真实 Match（新进程） | ✓ 4 次（ON×2 / OFF×2），rc=0、marker 齐、errors 空、产物新鲜 |
| 受影响正反 + 旧链路 | ✓ 相位正例/确定性/回退开关；行为与命令链正常 |
| 相关回归 | **blocked（非拒绝）**：共享机器上存在其他会话的活跃联机对局与副官实验（background-playtest-01 + adjutant-repair-01 r10，21:03 起持续占用 CPU 72%），按"不并行跑回归"纪律不执行；替代证据：撤回为 `REVERT_EXACT`（7 文件 SHA-256 == 改动前，树状态与 stage1 已验证 champion 逐字节一致）。待机器空闲补跑 rule-ai-* + world-query-runtime（列为 needs-review 项） |
| 同场景 A/B ≥3 组 | 2 对（受控计数 2/2 复现；帧时间噪声大不做结论） |
| 长时/线程/联机 | 不适用（候选未晋级，无新后端） |

## 5. 下一步（不请求批准，按计划继续）

1. 等机器空闲补跑 champion 体检（rule-ai-* 7 项 + world-query-runtime；`rule-ai-economy-query`/`rule-ai-expansion` 为 B-01 预存红，同场景对照归因）。启动前先确认 `background-playtest-01` 对局实例与 `adjutant-repair-01` 实验均已退出（`Get-CimInstance Win32_Process` 查 CommandLine，禁止按进程名误杀）。
2. 候选 2（方向已修正）：**同帧共享扩大化**——审计 3 个来源在同一物理帧的同参数查询（ScanCircle 3574 次/局是本轮最大单项查询），按 stage1 `own_forces_scan` 同合同做"同帧同参去重"，须先证明参数可对齐（不同中心/半径不得强并）。
3. S1 其余项（持久编组/任务反馈）在候选 2 后按计划推进；与电脑会话的阶段二（FindAutoSpot/需求统计）保持不重叠。

## 6. 证据索引

- S0：`agent/runs/2026-10-11-ra3-shared-nav/{acceptance-contract.md, baseline.md, baseline-hashes.txt}`
- 候选 1：`round-01/{patch.md, verification.md}`；运行日志 `cand/*`、`base/*`（4×JSON + out/err/driver 日志）；探针 `probe_phase_fraction.gd` + `probe-phase*.log`；解析校验 `parse-check*.log`、`ctrl-check*`（对照）
- 撤回验证：`REVERT_EXACT`（7 文件 hash 逐一命中基线）
