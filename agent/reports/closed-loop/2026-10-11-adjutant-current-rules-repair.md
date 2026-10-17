# AI 副官当前规则修复报告（2026-10-11）

- 任务提示词：`agent/prompts/2026-10-11-adjutant-current-rules-repair-deepseek.md`（含 B1 无人机增补）
- 诊断基线（只读）：`agent/reports/closed-loop/2026-10-11-adjutant-current-rules-diagnosis.md`（本报告不覆盖它）
- run-id：`20261011-adjutant-repair-01`；证据根：`agent/runs/20261011-adjutant-repair-01/`
- 工程：`G:/AIRTS/AI_RTS`；commit `9a2e6d4` + 本任务未提交补丁（保留共享工作区他人改动，未 reset/clean）
- **状态：needs-review（部分门禁未过，详见 §5）**——不宣称"全部完成"

## 1. 一句话结论

- **A 阶段核心链打通**：车厂→兵营→矿场（真实完工赠车）→**首笔交付+多趟收入**（R4：28 次/11200 矿；R5：31 次），R1 基线为"两兵营/两车厂/零矿场/零交付"。
- **B1 无人机链打通**：经济点火后**机场插队建成**（R5 t=32s）→**机场生产第二架无人机**（`rule-produce-recon-Unit_4-4518` accepted）→**两架在明显分离的两个方向**（(174.7,219.9) vs (39.2,38.8)）。
- **B2（主力跳长）经试改后回滚**：改动触发 4 条安全断言边界变化，重审需独立一轮（C-026），本轮保持既有安全口径。
- A2 余项（贴建布局/出口连通/赠车失败恢复/施工后阻塞）与 C 阶段部分项未完成/未验证。

## 2. 三阶段试玩结果（用户验收口径）

### 阶段 A（经济 / 出兵 / 通行）
| 验收点 | 结果 | 证据 |
|---|---|---|
| 正常开局经济优先（非两兵营） | ✅ | R2/R3/R4/R5：车厂（t≈16s）→ 兵营 → 矿场（48s 内） |
| 矿场真实完工赠车 | ✅ | `[REFINERY] Unit_8 完工赠送矿车 Unit_11`（R2）等 |
| **首笔交付 + 多趟往返收入** | ✅ | R4：交付 28 次/11200 矿、余额 3100→5550；R3 对照=0；R5：31 次 |
| 一座基础兵营+车厂出兵 | ✅ | soldier/tank/helicopter 均出现（R4/R5） |
| 经济未满足时不出现第二兵营 | ✅ | R4 t=180s 仅 1 座 |
| 后期确有需求能建第二座 | ⬜ 未测（需长局） | — |
| 步兵/坦克/矿车"离开再返回"全链 | ⬜ 部分（矿车往返✅；步兵坦克回程未专项） | — |
| 建造布局不堵通道（贴建倾向） | ⬜ 未修（C-023/C-024） | — |
| 施工前/中/完工分段录像回看 | ⬜ 未做（本轮以状态/日志为主） | — |

### 阶段 B（侦察 / 目的地）
| 验收点 | 结果 | 证据 |
|---|---|---|
| 经济稳定后主动建必要机场 | ✅ | R5 t=32s `aircraft_factory` 出现（建造前置生效） |
| 机场排队→生产额外无人机 | ✅ | `rule-produce-recon-Unit_4-4518` accepted（receipt） |
| 两架分两个方向 | ✅（初步） | drone 位置 (174.7,219.9) / (39.2,38.8) 分离；**覆盖增益未量化**（⬜） |
| 损失能补 / 队列不重复 / 机场被毁恢复 | ⬜ 未测（本轮无战损） | — |
| 侦察预算与经济启动预算统一仲裁 | ✅ 结构核验（侦察补充在作战 reserve 闸门之前 return；大地图第二架以"经济点火"为前置） | 代码 + R5 |
| scoutconfirm 抽兵审计 | ⚠️ 观测到 `rule-fill-scoutconfirm` 高频滚动（多单位轮换），是否在无人机覆盖后停止未证实 | 日志警告 6 条；记 C-025 |
| 主力持续推进（跳长 13-14m） | ⚠️ 未改（B2 试改已回滚，见 §4） | C-026 |

### 阶段 C（整局 / 异常 / 性能）
| 验收点 | 结果 | 证据 |
|---|---|---|
| 退局重开无残留 | ✅（R5→R6：资金/单位重置、match_id 不同） | R6（见 §3.5） |
| 模型降级档（timeout）仍按规则推进 | ✅（R6 `--model timeout`：经济/侦察链正常） | R6 |
| 玩家接管立即生效 | ✅（R6：点选副官单位 → 日志出现 release/override） | R6 |
| 性能门槛（新增工作有预算） | ✅ | R5 runner fast_scan：fps p50/p95 = 298/398；观测采样 p50/p95/max = 1/1/43ms；decisions 19629/8min |
| 资金不足/矿场损失/回执重放/同 tick 多建造 | ⬜ 未系统覆盖 | — |
| HUD 混示审计 / 后台日志字段 | ⬜ 未做 | — |

## 3. 修复明细（根因 → 改动 → 基线→新数值）

### 3.1 A1 开局经济语义错位（已确认问题组）
- **根因**：阶梯/里程碑/候选/提示四处未跟上新玩法（矿场完工赠矿车、车厂产矿车、矿车向矿场交付）。
- **改动**（5 文件）：
  - `graph/campaign.py`：M01 改"经济点火"，`build_order=("vehicle_factory","ore_refinery")`；`context_view` 加 `economy` 字段。
  - `graph/rules_fallback.py`：`pick_expansion_spot` 支持首矿近点（`min_distance_m=0+prefer_near`）；新增 `_building_cost_a`；`worker_bootstrap_reserve` 扩展"经济种子"（无经济建筑且无矿车时预留 min(车厂+1矿车, 矿场)）。
  - `graph/task_patch_prompt.py`：`KEY_BUILDINGS` 含矿场；扩建候选含矿场。
  - `graph/pydantic_agents.py`：战略提示改为当前经济口径。
- **基线→新数值**：唯一接受建造（R1）= 2 兵营+2 车厂+0 矿场 → **R2 起 = 车厂→兵营→矿场、矿场完工**。

### 3.2 C-013 交付死循环（本轮最关键）
- **根因（R3 取证）**：`满载回城 → [REFINERY]指派采矿 → action 重启 → 再满载`。**两个打断源**都对满载返程无豁免：副官"补采轨"（`rule-fill-gather`）与矿场 claim（`_assign`/`_supervise_assigned`）。
- **改动**：
  - `rules_fallback.py` 补采轨：`carried>0` 的矿车跳过（R3）。
  - `source/match/units/OreRefinery.gd`：新增 `_worker_is_laden`；`_claim_tick` 候选跳过满载；`_supervise_assigned` 对满载留册不 move/不释放/不重启（本轮）。
- **基线→新数值**：交付 0（R3）→ **28 次/11200 矿（R4）**；打断日志高频→0；余额只降→波动上行（+2450/36s）。

### 3.3 B1 无人机主动产/补/分工（新提示词）
- **根因缺口**：`RECON_MIN_PROBES=1` 固定最低；**没有机场时不建机场**（`recon_produce_intent` 无空闲机场→None）；建造顺序里机场被产能竞争挤掉。
- **改动**（`rules_fallback.py`）：
  - 新增 `RECON_BIG_MAP_EDGE_M=400`、`RECON_DESIRED_MAX=2`、`_live_probes`、`economy_ignited`、`recon_desired_count`（大地图+经济点火→2，容错缺参→1）。
  - `recon_produce_intent` 阈值改用 `recon_desired_count`。
  - 建造阶梯加"侦察产能前置"：有缺口且无机场（含在建）→ 机场插到本轮建造最前。
- **基线→新数值**：R4（改前）无机厂无第二架 → **R5：t=32s 机场建成、第二架 accepted、两方向分离**。
- **未完成**：覆盖增益量化、战损补齐、机场被毁恢复、scoutconfirm 抽兵审计（C-025/C-027）。

### 3.4 B2 主力跳长（口径重审后落地并达标）
- 方案：`hop_limit` 从 `min(14, 自己视野)` 改为"上限 24（`RELAY_MAX_HOP_M`）+ 逐点连续可见前缀裁剪（允许借友军视野链）"，自我覆盖仍封顶**自己真实视野**。
- 4 条旧断言**逐条分类**（均为旧口径边界，安全语义未破坏）：
  - `hop_per_unit`：b 段是"旧上限 14"断言 → 按新上限 24 更新；a 段（soldier 4m）本就通过。
  - `sparse_route`：tank 视野 16 → 14→16，断言更新为 `min(16, 上限)`。
  - `past_path_start`：新口径下"前向一小步（4m）"合理 → 断言改为"允许前向步 + **补强**'已过起点 30m（>24）必须拦'"。
  - `zero_displacement`：旧构造在新口径下已是合法前向步 → 构造改为**真·零位移**（单位已走过路径首点且首点不可见）。
  - 安全侧对照用例未红：`test_blind_gap_is_not_crossed`（盲区不跨）✓、`test_zero_displacement_relay_is_rejected`（真零位移）✓。
- **真机复验（R7，`d1b4c71f`，runner model=off）**：推进意图直线距离 **median 13.20m → 16.97m（+28.6%，n=96）**，p90 19.84 / max 21.51（≤24 有界）；scout 组 45.80（侦察不设此限）✓。
- 测试：`test_safe_movement + test_forward_rally + test_development_ladder` 132 条 OK；全量 1023 条仍只有 3 条既有失败。

### 3.6 A2 赠车失败恢复（有界重试）
- 根因：出生点查找失败时仅重置 `_free_miner_granted=false`，唯一重发路径是 `constructed` 信号（不会再发）→ 永久不赠。
- 改动（`OreRefinery.gd`）：失败计次 + 4s 节流 + 8 次上限；重试挂在 2s 心跳（`_claim_tick`）；测试/脚本"以完工态放置"路径从不尝试故不受扰动；权威唯一（重试仍在同一权威函数）。
- 验证：`RefineryFreeMinerSmokeTest` **0 failures**（两座矿场各赠一辆）。

### 3.5 C 阶段（R6 压缩执行）
- **重开残留** ✅：R5（`144ef688`，30+ 单位）→ R6（`357e2ef9`）：资金重置 10000、仅 base+drone，无任何残留；两局 DCS/端口/登记独立。
- **降级档（`--model timeout`）** ✅：规则中台照常推进：车厂 t≈16s → **机场 t≈32s（侦察产能前置同样生效）** → 坦克/直升机/矿场；与 model=off 档行为一致。
- **玩家接管**：点选链 ✅（两次点选 → `status.selected=true`，单位/建筑各一）；副官 override/release 机制在场（runner 日志 357 条相关行）但"选中瞬间撤租约"的精确事件**未逐条核对**（⚠️ 部分验证）。
- 记录：R6 runner 为 `--provider real --model timeout`（真实模型超时降级路径），authority=25033。

### 3.7 A2 自动放置与审计项（本轮续）
- **C-023 锚点口径统一**（`StructurePlacementRuntime.cs`）：build 循环旧实现遍历 `player.GetChildren()`（含移动单位）→ 改为与 `OwnStructures(player)` 同口径（`MovementObstacle` 且无 `Movement` trait，双保险）；先以场景实测证明"单位带 Movement/无 MovementObstacle、建筑反之"。
- **C-023 邻接净隙**：`EdgeClearance×0.5=0.375m` → `max(0.375, 1.2m)`（依据：worker 碰撞半径 1.36、nav agent 2.8，网络窗口 ~21.8 内）；R8 采样最小中心距 8.37=基地 4.98+矿场 3.02+0.375（旧口径）→ 新 DLL 后同组合应为 +0.825。
- **C-023b（实锤修复）**：resource 模式邻接层会先于环形命中"任意己方建筑"的贴建候选，把矿场拉到基地旁（R8：锚点矿 (155,141)→落点 (96,61)，284m）。修复：resource 邻接候选仅接受"距锚点矿 ≤32m"的己方建筑。**R10（新 DLL）验证：resource 落点 (81.8,172.5) 距锚点矿 (86.9,167.8) ≈6.8m；角落矿同理 6.8m**。
- **C-025 scoutconfirm 审计**：专职侦察在编齐备（`_live_probes ≥ recon_desired_count`）时不再抽战斗单位做双保险；专职缺口期保持 D13 轮转（R5 实测抽兵 2 次均为专职不足/在编 1<2 期；R9 同）。
- **C-024 阶段 desired count**：barracks/vehicle_factory 第二座需 `economy_ignited`（矿场/矿车存在）后开启；R9 实录"第二座车厂在矿车出现后落成"。
- **证伪记录**：**Godot 运行时不会自动编译 C#**（`.godot/mono/temp/bin/Debug/OpenRTS.dll` mtime=02:22 未随改动更新；`--quit` 启动不触发构建）——R8/R9 全部跑在旧 DLL 上；**显式 `dotnet build OpenRTS.sln -c Debug`（18.8s、0 errors）后 R10 才验证到放置修复**。placement 测试在新旧 DLL 下失败集合一致（StructurePlacement 2 / RuntimePlacement 1 均为既有红；SameFrame 0）。
- **C-033（新暴露，open）**：远端矿场在"建造网络"约束下建不成（R10：矿场 FOUND 贴矿 6.8m 但未落地；7 台矿车满载持货、余额 150 耗尽）——属"分矿需前哨/网络扩展"层，改动面大，留待独立一轮。

## 4. 测试命令与 rc

| 范围 | 命令 | rc / 结果 |
|---|---|---|
| 静态解析 | venv `python -m py_compile`（campaign/rules_fallback/task_patch_prompt/pydantic_agents/movement） | 0 |
| 相关单测 | `unittest test_worker_bootstrap_reserve test_campaign_mainline test_development_ladder`（119） | OK |
| 相关单测 | `unittest test_development_ladder test_explore_frontier test_campaign_mainline`（142） | OK |
| B2 回滚后 | `unittest test_safe_movement test_forward_rally`（88） | OK |
| 全量副官单测 | `discover -s adjutant_coordinator/tests`（1023） | failures=3（既有：credential/arrival/state_channels）+skipped=1，**无新增红** |
| 矿场/交付 Godot 测试 | `WorkerDeliveryRefineryOnlyTest / OreRefinerySmokeTest / RefineryFreeMinerSmokeTest`（headless） | 运行完成（FreeMiner rc=0；其余输出含 RID 泄漏噪音，判定行未逐条留档 ⚠️） |

## 5. 未验证项 / 未证实风险 / 共享工作区风险

- ⬜ A2：贴建布局（0.375m 邻接带）、采集站台/返矿通道、赠车失败恢复（`constructed` 单路径）、施工后障碍/nav 版本、出生点→集合点→基地外→返回全链、分段录像。
- ⬜ B1 余项：覆盖增益量化、战损补充、机场恢复、scoutconfirm 审计（C-025）。
- ⬜ B2：跳长调整（C-026，含 4 条断言清单）。
- ⬜ C 余项：资金不足/矿场损失恢复、回执重放、同 tick 多建造、HUD 混示、后台字段审计、四出生点/组合地图矩阵、独立复核（REV 未做）。
- ⚠️ 测量工具：DCS 在副官高频请求下偶发拒连（C-012）；R1~R6 的 tick/墙钟关系受窗口后台化影响（C-011）。
- ⚠️ 共享工作区：本任务补丁与他人未提交改动共存（未 reset/clean）；`test_client_credential_source` 等 3 条失败为他人 WIP，未动。

## 6. 环境 / 进程 / 证据

- 每轮均为**独立新启动真实 Match**（菜单开局 1 人 + 3 空位；非 headless 夹具）：R1 `201f4c3f` / R2 `3c79de3e` / R3 `77979bf5` / R4 `3fcc795f` / R5 `144ef688`（R6 见 r6 run 目录）。
- runner：`adjutant_coordinator.deploy.agent_runner`，`--provider real --engine langgraph --model off`（R6 为 `timeout`），authority=各局 DCS 端口，HUD/state 全独立。
- 证据路径：`agent/runs/20261011-adjutant-repair-01/{baseline-r2,r2-fixed,r3-delivery,r4-delivery,r5-recon,r6-*}/`（runner.out、sample-*.json、hud、meta）；`round-01/{direction,exploration,patch,verification}.md`）。
- cleanup：R1~R5 游戏/runner/drive/录制器进程按时按 PID 清理并核对无残留；**用户对局进程未受影响**；未按端口/映像名批量杀进程。
- 模拟速度/命令数：各局 receipts 数百至千条（R3 644 / R5 见 runner 日志）；产出数见 §3 基线→新数值。
