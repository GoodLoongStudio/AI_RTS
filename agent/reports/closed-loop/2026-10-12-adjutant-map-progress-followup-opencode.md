# AI 副官规则 + 地图工作台总进度流程图：闭环报告（2026-10-12，needs-review）

- 任务提示词：`agent/prompts/2026-10-11-adjutant-map-progress-followup-deepseek.md`
- 计划：`agent/plans/2026-10-11-adjutant-map-progress-followup-plan.md`
- 接手交接：`agent/prompts/2026-10-12-opencode-coordination.md`（用户指示停止产品写入/编译/开局；
  本报告所有产品改动均为**其他会话在共享工作树落地**的已存在修复，本会话负责验证/证据/建议）
- 证据根：`agent/runs/20261011-adjutant-map-progress/`（分析）与
  `agent/runs/20261011-adjutant-repair-01/r12-current-tree/`（r12 真实 Match）
- 工程：`G:/AIRTS/AI_RTS`（rev-parse 核对；`check_workspace_target.py --mode develop` rc=0）
- **状态：needs-review**——Phase 1 首矿/经济未闭环（根因已定位、补丁已备、等分工实施），
  Phase 2 缺 5 FPS 视频，Phase 3 缺战损/机场场景；不得写“全部完成”。

## 1. 一句话结论

- **Phase 2（地图流程图）已闭环**：实现已在工作树，本会话完成烟测（rc=0/0 failures）、
  18 张状态截图实看、独立 8767 端口 4 条真实后端 job 记录。
- **Phase 3 代码侧已闭环**：盲区反例修复+回归、双计数修正、覆盖增益节流已在工作树且
  134 条相关单测 OK；真实 Match 口径统计已从 r12 日志提取。
- **Phase 1 r12 复现并定位**：0 矿场/余额死锁 50/满载矿车无交付 = 三处叠加
  （首矿 hint 超建造网络 → NoValidSite；ladder 首矿排 4 塔之后；资金类拒绝无按类冷却）。
- **Phase 2（建筑通行）只读核对完成**，视频与三态验证待窗口窗口。

## 2. 已交付与验证（按提示词门禁逐项）

### 2.1 地图工作台总进度流程图（Phase 4，完成）

- 实现：`source/main-menu/MapGeneration.gd` 的 `STAGE_ORDER`/`STAGE_TEXT`/`STAGE_STATUS_TEXT`/
  `STAGE_MARK`/`STAGE_TONE` + `_stage_display()`（唯一状态解释口径，中心流程图与右侧
  “地图检查”共用）+ `_render_flow()`/`_render_stages()`；`_flow_box` HFlow 窄窗口自动换行。
- 烟测：`tests/automated/MapProgressFlowSmokeTest.tscn` rc=0，
  marker `Map progress flow smoke test completed: 0 failure(s)`；
  覆盖 done/pass=false、quick preview(g2)、skip_engine_check、上游失败不伪装、
  重试覆盖、同源（中心 vs 右侧）、迟到响应丢弃、断连等 10 组用例（A~J）。
- 截图（`agent/runs/20261011-adjutant-map-progress/`，2026-10-12 11:15 新鲜生成，
  `--position 6000,6000` 屏外窗口不抢前台，err=0，逐个打开实看）：
  - `flow-running-mixed-{1920x1080,1280x720,1000x720}.png`：G1 完成/G2 当前青框/
    G3 失败红/后续"未运行：上游阶段失败"，总状态"第 2/5 阶段·第 3/5 次尝试·耗时 12s"；
  - `flow-all-done-*`：5 节点全 ✓ + engine 62.0s，"5/5 阶段完成·全部阶段已结束"；
  - `flow-done-pass-false-*`：G2 done+pass=false → "检查未通过/需检查"（琥珀，非绿）；
  - `flow-quick-preview-*`：G3/G4/engine"快速预览未运行"（灰），"G2 快速预览·2/2 阶段完成"；
  - `flow-skip-engine-in-game-*`：engine"跳过：游戏内生成路径"（灰 »），"4/5 阶段完成"；
  - `flow-stage-failed-1000x720.png`（窄窗口两行排布）：G2 ✕+错误详情条。
- 真实后端（独立 8767，只清理自己的服务）：`workbench-mine-g2.json`（G1/G2 done）、
  `workbench-mine-full.json`（G1-G3 done、G3 pass=false → g4/engine upstream_failed skip）、
  `workbench-mine-full-l8t608.json`（G1→G4 done → engine error，见 §5 归因）。

### 2.2 副官规则（Phase 1/3）

已存在且验证的修复（工作树，本会话未重做、未回滚）：

| 项 | 状态 | 证据 |
|---|---|---|
| 盲区反例 `_first_visible_span` | ✅ 修复 | 复现 `safe_relay_point([[0,0],[24,0]],...)→[4.0,0.0]` 不跨盲区；`test_safe_movement.py:502/568` 两条回归（含"不砍短真正连续链"区分断言） |
| 无人机计数双计 | ✅ 修复 | `recon_produce_intent` = live + `pending_production`(max 合并)；r12 实录 recon_coverage 节流、scout_share=0 |
| economy 口径分开 | ✅ 已有 | `economy_ignited`=矿场+矿车；`income_observed`=delivered_count>0；`economy_under_construction` 三态函数在位 |
| 首矿 first_economy | ✅ 已有 | `first_economy = "ore_refinery" not in owned_types`（不再被 vehicle_factory 降级） |
| 第二产能限制 | ✅ 已有 | barracks/vehicle_factory 第二座需 `economy_ignited` |
| RELAY_MAX_HOP_M=24 | ✅ 加载 | `test_safe_movement.py:488` 断言；r12 movement：unsafe_dispatches=0 |

r12 真实 Match（model=off，真实 Match 新进程+runner attach，73 采样）真实数值：

- 经济死锁链：余额 11200→450→50；ore_refinery `NoValidSite×2`（hint 距基地 79m，
  `AUTOSPOT evaluations=0`）；ladder 建序 VF→barracks→AF→anti_air_turret 后钱尽；
  worker Unit_8 carried=[400,0] 从 t≈158s 保持到局终（无矿场=无交付目标）；
  `InsufficientResources` 下 command_center 重发 7 次（tick 1656…5613）。
- movement（tick 快照）：planned 661 / allowed 284 / squad_advances 284 /
  scout_confirmed 295 / unsafe_dispatches 0 / replan avg 22.88ms max 3063ms /
  fallback 377（protected_unit 300、relay_too_close 64）；
  arrival 194（p50 0.90m、no_route 90）；movement_gate 462 全 blocked=[]。
- 命令目标距离（近似口径）：attack_move p50 104.5m、gather p50 **142.3m**、
  scout p50 66.6m、move p50 85.6m（口径限制见分析文档 §3.1）。
- 无人机覆盖：per-unit max new_cells Unit_1=20/Unit_15=4；t=70.8s 起 2 架在视野内
  （fog 采样不可见≠阵亡）。
- 退出码：game_rc=1 / runner_rc=1 = **驱动侧 terminate**（探针 `_finish` 只 quit 0/2/3、
  1083 tick 无 tick_error 佐证）；**非 Godot/runner 崩溃**。

单测基线：`venv python -m unittest discover -s adjutant_coordinator/tests`
1030 tests / failures=3（behavior_tree respond_radius 为他人 WIP、arrival/state_channels
为历史既有），无本任务新增红。

### 2.3 建筑通行（Phase 2）只读核对（p2-t1 完成）

权威数值归档（`analysis-phase2-clearance-audit.md`）：nav agent 2.8m /
worker 物理 1.36m / 通道净空 5.6m（StructurePassGapMeters）/ 建造网络 12m /
矿场服务 46m / 采集余量 2.0m / 站位吸附 4.0m / 扩张最小距 30m / 外推 6m；
量化证明 1.2m 邻接贴合≠可通行（缝 1.2m 时 worker 物理净空为负）。

## 3. 未验证项（如实列出）

- **Phase 1 未闭环**：补丁 A/B/C 未实施（等分工）；首矿 accepted+constructed、
  矿点库存减少、`refinery.delivered_count>0` 首笔交付、低资金无重复提交——均无证据。
- **Phase 2 视频与三态**：5 FPS 视频未录（等窗口窗口）；施工中态 carve/净空、
  步兵/坦克/矿车三段往返未实测。
- **Phase 3 战损场景**：无人机损失补造、机场被毁恢复、高防空区换线未测；
  单 hop 直方未聚合；model=timeout 档未在本会话实测（历史 R6 有经济/侦察链正常记录）。
- **地图完整任务**：G1→G4→引擎全 pass 未取得（engine error，见 §5）。
- 正常小模型（real provider）未实测 → 按提示词写“未验证”，不宣称已接好。

## 4. candidate/champion

- champion = 当前工作树（本会话验证过的部分：流程图/盲区/双计数/口径统计）。
- candidate（未晋升）= 补丁 A/B/C 方案（`analysis-phase1-fix-patches.md`），
  未在真实 Match 验证，连续未提升轮数=0（尚未开始测试轮）。
- 无“为测试改绿”操作；三个历史失败（behavior_tree/arrival/state_channels）保持原样
  并标注归属。

## 5. 崩溃/超时归因

- r12 game_rc=1/runner_rc=1：驱动侧 terminate（非崩溃），见 §2.2。
- 地图 engine error：Godot 截图进程 signal 11；**复现规律=用 Python 启动必崩、
  pwsh/cmd 启动稳定成功**（rc=3221225477 + `Failed to open 'user://logs/...'`）；
  历史 job（layout25/36/61）同症状 → 判为**历史复现的已知环境现象**，
  未归因为本轮产品改动导致；mapspec 产物本身正常生成。
- 无未归因崩溃；无大量 DCS timeout 被忽略（r12 采样 73/73 有效，DCS 34 端口相关噪声
  已在探针修复后消失）。

### 5.1 历史 Godot 失败归因台账（2026-10-12 22:10 滚动，含实施方 22:00 C# 修复）

提示词 §2 列的 4 个失败（合计 8 条）：

| 测试 | 历史 | 归因/状态 |
|---|---|---|
| RuntimePlacementSmokeTest | 1 | **已修（夹具）**：预览 Tank y=0 vs 实测 y=0.6 → ground_height_at 推导（Cursor `r25-fixtures/final.json`=3/3） |
| StructurePlacementSmokeTest | 2 | **实施方归因：1 条环境竞态**（放置时地图还在前台初始化、初始无不可建表面，未复现）+ 1 条与 spawn point 卡死同族；**实施方 22:00 已修后者（2→1）**：`ArriveToleranceOf()` movement 同源取到达容差、`HullSlackMeters` 0.15f→0.5f（movement.radius=1.84 vs Tank.tscn 覆盖 1.288 不同源=旧漂移根因；C# `a5586600a111`、DLL `bcb35b140850` 21:57） |
| SpawnPointRegression | 3 | **实施方归因：B2 出生点族不同（缺一次旋转）+ `infm` 空指针** |
| OreRefinerySmokeTest | 2 | **实施方归因指向夹具“范围内应有矿”断言链**（边界矿/等待 15s/4 辆矿车）——与 Phase 1 经济链同域，夹具/产品归因未分离，补丁 A 后重跑判定 |

附带：HistoricalUnitCommandHud 与 AdjutantHudStatusDiscovery 各 1 条已由 Cursor 夹具修复（r25 3/3）。
工具链事实：5 FPS 视频当前被 cv2 依赖阻塞（实施方 venv 未装 cv2，`record_playtest.py` 无法播放验证）——
p2-t3 执行前须先解决。台账全文：`analysis/analysis-phase2-smoke-test-map.md` §5。

## 7. 验收时点的工作树/DLL 哈希（sha256 前 12 位，2026-10-12 17:37）

| hash | mtime | 文件 |
|---|---|---|
| 03165518BD8D | 10-12 17:19 | `source/adjutant_coordinator/graph/rules_fallback.py` |
| 4819604BE610 | 10-11 22:17 | `source/adjutant_coordinator/graph/movement.py`（盲区修复版） |
| 1AD4E14B3246 | 10-12 17:37 | `source/adjutant_coordinator/graph/campaign.py` |
| FA49AB6686FA | 10-11 22:40 | `source/main-menu/MapGeneration.gd`（流程图版） |
| 2A624CA03FD3 | 10-12 17:09 | `source/csharp/GodotAdapter/Construction/StructurePlacementRuntime.cs` |
| DB034CADB87F | 10-12 17:11 | `.godot/mono/temp/bin/Debug/OpenRTS.dll`（Godot 启动时自动编译产物） |
| 80B69DE5BCC4 | 10-12 15:49 | `tools/ai_perf_probe_runner.gd`（本会话的 `_attach_match` 修复） |
| A5586600A111 | 10-12 ~22:00（实施方） | `source/csharp/GodotAdapter/Construction/GodotStructurePlacementWorldPort.cs`（ArriveToleranceOf 同源/HullSlack 0.5f） |
| BCB35B140850 | 10-12 21:57 | `.godot/mono/temp/bin/Debug/OpenRTS.dll`（实施方 C# 修复后的新 DLL） |

注：Codex 会话在 17:09-17:37 持续写入上述文件（共享工作树未 reset/clean）；
本会话未写入任何产品源码；r12 的 Python 侧证据基于 17:19 前版本，
补丁建议已按 17:19 版本重新核对仍成立。

## 8. 测试命令与 rc 汇总

| 范围 | 命令 | rc/marker |
|---|---|---|
| 流程图烟测 | `Godot_console --headless --path . res://tests/automated/MapProgressFlowSmokeTest.tscn` | rc=0；marker `...completed: 0 failure(s)` |
| 定向回归 | `python tools/run_targeted_godot_tests.py --ids map-progress-flow` | passed=True |
| 副官单测 | `venv python -m unittest discover -s adjutant_coordinator/tests` | 1030 tests；failures=3（既有/他人 WIP，无新增） |
| 流程图截图 | `Godot_console --position 6000,6000 res://tests/automated/MapProgressFlowShotCapture.tscn` | 18/18 err=0 并实看 |
| 真实 Match | `python agent/runs/20261011-adjutant-repair-01/run_r12_mine.py 6` | 73 采样有效；game_rc=1/runner_rc=1=驱动 terminate |
| 地图后端 | `python .../drive_workbench_mine.py {g2,full,...}`（8767） | mine-g2 done；mine-full G1-G3 done+g4/engine skip；l8t608 G1→G4 done+engine error |

## 9. 下一轮必须解决

1. 实施补丁 A（首矿建造网络过滤）→ 新 Match 验收清单（§analysis 文档末）；
2. 补丁 B（资金类按类型冷却）；
3. 补丁 C（首矿 ladder 优先级）；
4. 5 FPS 视频（施工前→中→完工→通行）并按 SKILL 回看记录秒数；
5. 无人机/机场战损与两个出生点、退局重开；model=timeout 档；
6. 闭环后把本报告状态从 needs-review 推进到最终结论。

（本节为原 §6 内容，因哈希表插入调整编号；门禁未过之前，最终状态保持 needs-review。）

## 10. 基线差异标注（2026-10-12 19:43 后）

- 本报告副官单测基线“1030 tests/failures=3”是 **17:xx 本会话实跑**的快照；
- 用户 19:43 把建筑/副官任务转交 Cursor（`agent/prompts/2026-10-12-cursor-takeover-building-adjutant-and-performance.md`），
  其轮次引用 `r23-python-complete/result.json` = 1045 tests/1044 pass/1 skip/rc=0（范围更新、含实施方新增用例）；
  **以实施方 r23 为最新基线**，两者不冲突；
- 我的 Phase 1 证据链（r12 根因、补丁 A/B/C、验收判据）已移交实施方：
  `agent/runs/20261011-adjutant-map-progress/handoff-to-codex.md` §7/§9/§10。

