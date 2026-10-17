# 闭环报告：副官规则修复 + 地图总进度流程图（2026-10-11 实施轮）

状态：`needs-review`（关键门禁未全通过，见 §6）

提示词：[2026-10-11-adjutant-map-progress-followup-deepseek.md](../../prompts/2026-10-11-adjutant-map-progress-followup-deepseek.md)
计划：[2026-10-11-adjutant-map-progress-followup-plan.md](../../plans/2026-10-11-adjutant-map-progress-followup-plan.md)

## 0. 环境与并发

- `git rev-parse --show-toplevel` → `G:/AIRTS/AI_RTS`；`check_workspace_target.py --mode develop` → `decision=allow`，rc=0。
- 开工时工作树脏文件 **1095** 条（其他任务在改同一棵树）。本轮未执行 `git reset/clean/stash`，未回滚他人改动，未结束任何外来进程。
- 本机存在**外来 Godot 实例 2 个**（PID 30596/38128）与多个 python 进程：本轮全部保留未动；测试均以 `--headless` 并行运行，不抢前台、不移动鼠标。
- C# DLL：本轮**先**用 21:02:05 的旧 DLL 跑出一批结果，随后按契约
  `dotnet build OpenRTS.sln -c Debug --no-restore --nologo` 重编译成功（0 错误 / 1 警告
  `StructurePlacementRuntime.cs:320 CS8603`），新 DLL mtime `23:02:40`、md5 `e3f2c5fbb90b`，
  并用新 DLL **重跑**了 §4 的四个 Godot 套件。本轮未改任何 C# 源文件。

## 1. 改动文件与哈希（md5 前 12 位 / 写入时间）

| 文件 | hash | 时间 |
|---|---|---|
| `source/adjutant_coordinator/graph/movement.py` | `9ea952be4167` | 22:17:22 |
| `source/adjutant_coordinator/graph/rules_fallback.py` | `efd89b915fc7` | 22:18:42 |
| `source/adjutant_coordinator/tests/test_safe_movement.py` | `2f800d93de40` | 22:17:11 |
| `source/main-menu/MapGeneration.gd` | `d440f7f87cef` | 22:40:24 |
| `config/full_regression_suite.json` | `59d93fbe60b2` | 22:45:25 |
| 新增 `tests/automated/MapProgressFlowSmokeTest.gd/.tscn` | — | — |
| 新增 `tests/automated/MapProgressFlowShotCapture.gd/.tscn` | — | 取证用，不入回归套件 |
| `tools/mapgen/rtsmap/workbench/server.py`（预览路径补 stages，见 §10） | — | 本轮后段 |
| `agent/runs/20261011-adjutant-map-progress/drive_workbench.py` | — | 真后端取证驱动 |

## 2. 开工前的"当前源码真值"核对（避免重复实施）

提示词点名的三处缺陷，**逐一在当前源码复现确认仍存在**（不是照旧报告抄账）：

1. `_first_visible_span` 仍按"最后一个可见采样点"二分（旧注释正写着错误假定"可见前缀单调"）。
   实测反例：`safe_relay_point([[0,0],[24,0]], by_name, unit='mover', origin=[0,0])` → **`[24.0, 0.0]`**，
   跨过了 x∈(4,20) 的盲区。
2. `economy_ignited()` 仍对任意 `worker` 直接 `return True`（`rules_fallback.py:713`）。
3. 首座矿场判据仍含 `"vehicle_factory" not in owned_types_now`（`rules_fallback.py:4144`），
   即"已开车厂 ⇒ 首矿降级为远端扩张"。

## 3. 已实施的修复

### 3.1 安全中继点的连续可见前缀（提示词 §一.3 反例）

- `_first_visible_span`：二分改为**按采样顺序扫描，遇第一个不可见点即停**，只放行其之前的前缀；
  采样上界仍是既有 `RELAY_COVERAGE_MAX_SAMPLES`，开销有界；未关闭可见性约束、未放大 hop 上限。
  反例现在返回 **`[4.0, 0.0]`**（停在盲区之前）。
- 修这条时暴露出**第二个真实缺陷**：`safe_relay_point` 以 `previous=origin` 从**路径首点**开始遍历，
  当单位已走过路径首点时，第一段是**倒退**，会签出单位**后方**的点（实测 origin=18 → relay=14，
  位移 4m 被闸门当合法一跳）。新增 `_clamp_origin_to_path()`：把落点吸附到权威折线后**只向前**遍历；
  **仅对确实落在这条路上的单位吸附**（垂距 ≤ `PATH_CLAMP_TOLERANCE_M=1.0`），掉队/归队单位保持原语义。
  这个"只吸附在路上的"限定是被一条安全回归逼出来的：无条件吸附会把掉队成员从 `squad_hop`
  的可用成员里摘掉，使 `squad_scatter`（队形已散）判据**看不到**那个成员，退化成 `no_relay`。
- 新增 2 条**有区分力**的断言（旧 132 条全绿也抓不到）：
  `test_relay_must_not_jump_over_a_blind_gap_into_rear_ally_vision`（钉住盲区前缀）、
  `test_contiguous_vision_chain_still_allows_the_longer_hop`（防止顺手把真连续的视野链砍短，
  仍应走到 `RELAY_MAX_HOP_M`）。旧测试一条未删、判据未放宽。

### 3.2 经济三态分离 + 首座矿场（提示词 §一.1）

`rules_fallback.py` 拆成三个**互不代替**的口径，全部走权威字段：

- `economy_under_construction()`：有在建 `ore_refinery` ⇒ 只表示"上路了"；
- `economy_ready()`：**已建成**矿场（`refinery.constructed`，且 `constructed is not False`）**且**有矿车；
- `income_observed()`：只认 `refinery.delivered_count > 0`（权威端 `OreRefinery.delivery_stats()`）。
  明确不拿模型输出 / 命令 accepted / 余额下降当收入。
- `economy_ignited()` 现在 = `economy_ready()`：**单一 worker 存在不再触发**第二座产能建筑与第二架无人机。
- 首座矿场：`first_economy = "ore_refinery" not in owned_types_now`，去掉 `vehicle_factory` 条件，
  首矿回到"最近可见可采矿点"（`min_distance_m=0`、`prefer_near=True`），不再被远端扩张距离规则挡死。
- 远端矿场的前置链与低资金停重试：沿用既有 `build_backoff_until_tick` / `blocked_spots` /
  `expansion_probe_backoff` 机制（已确认存在，未重复实现）。

### 3.3 地图工作台总进度流程图（提示词 §二）

`MapGeneration.gd`：

- 中心 `ProgressBanner` 内新增 `StageFlow`：**控件只在 `_ready` 建一次**，渲染只改文字/样式（无每帧重建、
  无每帧 HTTP/文件读取、无纹理加载）；节点含编号 + 名称 + 状态文字 + 图标（`✓ ▶ · ✕ » ! —`），
  节点间 `→` 连接线；当前节点青色加粗边框，完成绿边，失败红边，检查未通过琥珀边。
- **唯一状态源**：新增 `_stage_display(job, stage_id)`，中心流程图与右侧「地图检查」都调它，
  共用 `STAGE_ORDER`/`STAGE_TEXT`/stage 数据；旧的右侧独立状态字符串已删除。
- 当前节点由 **stage 状态**决定（`_flow_current_stage`），`progress` 文字只在**与当前阶段一致**时才显示
  （`PROGRESS_STAGE_ID` 映射，含后端实际取值 `引擎`/`重试`）⇒ 截图里"中心 G1 已就绪 / 右侧 G2 在跑"的漂移不可能再出现。
- 状态映射：`done=完成`、`running=进行中`、无记录=等待、`error=失败`、`skipped=跳过`；
  `done + pass=false` ⇒ **"检查未通过"**（琥珀、非完成绿，且总状态另写"N 个阶段检查未通过"）；
  `target=g2` 的 G3/G4/engine ⇒ **"快速预览未运行"**；
  `skip_engine_check` ⇒ **"跳过：游戏内生成路径"**（与"因上游失败未运行"的 **"未运行：上游阶段失败"** 文案分开）；
  失败阶段的后续阶段一律不伪装完成。
- 终态**保留**全流程结果（不再 `非 running 就隐藏整块`）；无任务时才隐藏。
- 只显示后端真实字段：`attempt/limit`、`duration_s`、`error`、`reason`；无真实百分比时显示"第 N/5 阶段"。
  **未新增**任何 UI 猜测字段（一度写过的 `layout_rotation` 已删除——后端把"改试新布局"写在 `phase` 文字里，
  布局轮换的重做由后端清 stages 自然反映为真实回退）。
- 旧预览保留时打标记：新增 `PreviewStale` 叠字，`_preview_job_id` 跟踪图片归属，
  文案"上一张地图预览 · 当前新地图尚未完成"；查看历史时活动任务只用一条简短标记"· 另有任务生成中"。
- 后端核对：`StageRecorder.begin/done/fail/skip` 已把阶段开始/完成/失败/跳过（含 `reason`）写入 job，
  `server.py` 重试时清理下游 stages ⇒ 本轮**未新增后端字段**，无"UI 靠延时猜阶段"的情况。

### 3.4 生产"队列 / 在途"去重（提示词 §一.3 第 2 条）

`recon_produce_intent` 与 `produce_totals` 原来各写一套"每个 item +1、每个 intent +1"，
既不看权威状态、也不按身份去重，还互相口径不一致。新增三个共享口径并让两处都走它：

- `QUEUE_PENDING_STATES = ("Queued", "Producing", "AwaitingDeployment")`
  —— 权威枚举来自 `source/csharp/Domain/Production/Production.cs:14`。
  `Completed` 的单位**已经出现在 `by_name`**（再数一次就是双计），
  `Cancelled` / `ProducerLost` 永远不会出单位。
- `queue_pending_by_producer()` —— 按 `item_id` 去重、按 `(生产者, 产品)` 归并。
  实测权威队列项**没有 `quantity` 字段**（一项就是一辆），所以"多数量订单"在观测里
  本来就是多个 item；这条核实结论写进了代码注释，避免以后有人去"读 quantity"。
- `pending_production()` —— 队列与在途意图按 `(生产者, 产品)` **取 max 而不是相加**：
  一条 produce 意图被接受后会**变成**队列里的 item，两边各加一 ⇒ 同一架无人机数成 2 架，
  "还差一架"永远算不满，副官就不再补机。未被接受的意图（`pending_authority`）此时队列为 0，
  max 仍等于 1，不会被吞掉，因此不会退化成重复下单。

判据纪律：新增这轮改动一度让 `test_produce_totals_counts_queue_and_inflight` 变红。
**没有放宽它**——查下来是我的生产者键取错了（真实观测用 `unit`/`producer_id`，
该用例用第三种别名 `producer`，导致两个不同生产者的订单被压成同一键）。
补上别名后该用例**原样通过**。

新增 5 条有区分力的断言（旧实现下必红）：已接受意图与同生产者同产品队列项只算 1、
未接受意图在队列为空时仍算 1、三种终态 item 不计数、同一 `item_id` 出现两次只算 1、
不同生产者两条不被压成一条。

### 3.5 侦察覆盖增益记录（提示词 §一.3 第 1/3 条）

先核对再动手，避免重复实施：

- **"两架必须认领不同方向"这条已经是既有实现**，不是缺口。`explore_frontier` 用
  `taken = {cell for cell in assigned.values()}`（`rules_fallback.py:2781`）把**别的单位已认领的格**
  排除掉，所以第二架无人机不可能和第一架领同一格。本轮未改、未重复实现。
- **缺的是"统计相对单机增加的新视野/新区域"**：完全没有。新增
  `recon_coverage_report(state, by_name)`，只读权威确认过到达的格
  （`explore_frontier` 只在单位真的走到格中心时写 `state="covered"`），产出：
  `dedicated_cells` / `conscript_cells`（专职 vs 抽兵覆盖的**不同格数**）、
  `dedicated_visits` / `conscript_visits`（工时代理）、`scout_share`（小兵侦察工时比例）、
  `per_unit_new_cells`（按每格**首次**覆盖时间排序后的**增量**格数 —— 第二条目的值
  就是"多一架无人机比单机多探出多少"）。
- 在 `recon_produce_intent` 里按 `RECON_COVERAGE_NOTE_EVERY_TICKS=300` 节流写
  `_note(state, "recon_coverage", ...)`。

判据纪律（本轮踩到并改正）：节流游标我一开始写成顶层 `state["_recon_coverage_note_tick"]`，
立刻被 `test_every_literal_state_write_is_declared` 抓住（未声明的顶层键每轮归零）。
**没有把它塞进 `TRANSIENT_STATE_KEYS` 变绿**，而是改成存进**已经声明为图通道**的
`state["explore"]` 里 —— 不新增顶层键，且游标与它要描述的覆盖数据同生命周期。

新增 5 条断言（`ReconCoverageReportTest`）：只有真到达的格算覆盖、两架探到不同区域时
第二架净增益=2、重叠覆盖不虚增格数也不凭空造单位、小兵工时比例、note 按 300 tick 节流。

## 4. 测试命令、rc、marker

Python（bundled venv，`cwd=G:/AIRTS/AI_RTS/source`，系统 python 缺依赖故不用）：

| 命令 | rc | 结果 |
|---|---|---|
| `-m unittest test_safe_movement test_forward_rally test_development_ladder` | 0 | **144 tests OK**（132 旧 + 2 中继前缀 + 5 队列去重 + 5 覆盖增益；旧判据未放宽） |
| `-m unittest <全部 66 个 adjutant 测试模块>` | 1 | **1035 tests, failures=3, skipped=1**（3 条为既有失败，见下） |

全量 1025 的 3 条失败**与本轮改动无关**（且这些测试文件本身在脏文件列表里，属并发任务范围）：
`test_respond_radius_covers_max_weapon_range`（平衡表最大射程口径）、
`test_duplicate_arrival_does_not_complete_next_hop`（arrival 事件去重）、
`test_required_keys_survive_round_trip`（`movement_urgent` checkpoint 字段回读）。
未为绿色修改任何一条。注意：**没有任何旧测试断言"仅有 worker 即经济点火"**，所以 §3.2 的收紧零回归。

Godot（`Godot_v4.7.1-stable_mono_win64_console.exe --headless --path G:/AIRTS/AI_RTS`）：

| 场景 | rc | marker / 失败 |
|---|---|---|
| `tests/automated/MapProgressFlowSmokeTest.tscn`（新增） | 0 | `Map progress flow smoke test completed: 0 failure(s)`，日志 0 条 SCRIPT ERROR |
| `OreRefinerySmokeTest.tscn` | 1 | **3 failures**（提示词记的是 2；见下方归因） |
| `StructurePlacementSmokeTest.tscn` | 1 | 2 failures（与提示词记载一致，**未修**） |
| `RuntimePlacementSmokeTest.tscn` | 1 | 1 failure（与提示词记载一致，**未修**） |
| `SpawnPointRegression.tscn` | 见下表补跑 | 首轮 200s 被我杀 ⇒ **预算不足**，不是崩溃 |

**超时归因（提示词要求"没有归因不能当正常完成"）**：`OreRefinerySmokeTest` / `SpawnPointRegression`
是跑真局的套件（日志里 `G4PERF ... frames=3880` 持续上涨），200s 预算不够；把预算提到 600–700s 后
`OreRefinerySmokeTest` 正常收尾并报出 3 条断言。两条 `rc=124` 属**测试预算**问题，
与 `r10-newdll` 的 `runner_rc=3221225477` 无关（后者是 `attach_runner.py:115-118` 收尾 `taskkill`
的产物，不是游戏内崩溃——本轮未复现该退出码）。

`OreRefinerySmokeTest` 三条判据原文（新 DLL 下重跑，未改判据）：

1. `矿点存量必须被真实采掉（272808 → 273208）` ⇒ 交付后矿点**不降反增 400**。
2. `工人回矿场交付后玩家账户必须真实增长（6700 → 6700）` ⇒ **交付没有产生收入**。
3. `夹具自检：矿场周围应有可采矿落点（carve 洞外、网格上、走得通、站位也走得通）` ⇒ 矿场周边**没有合法采矿站位**。

⇒ 这是本轮最重要的结论：**"首笔交付/收入"在权威端本身是断的**（第 1、2 条），
第 3 条又与 §一.2 的通行/站位问题同源。所以 §一.1 的验收门**不可能**只靠 Python 侧口径修复变绿：
我已把"矿车存在 ≠ 收入"的假口径堵住，但真收入还需要修权威端交付链（本轮未动 C#）。

新流程图测试用**注入的可控 job**覆盖：进行中/完成/等待/失败/跳过、`done+pass=false`、
快速预览、`skip_engine_check`、上游失败不得伪装完成、重试覆盖旧状态、中心与右侧同源、
终态不隐藏、无任务隐藏。**尚未覆盖**：真实 HTTP 迟到响应/token、服务断连、真实一次 G2 预览与一次完整 G1→G4。

失败判据原文（§一.2 的直接证据，未改判据）：
- `可移动单位不应被无效导航查询吸附到原点`
- `地表导航图应在放置评估前完成初始化`
- `被覆盖的友军应移动到建筑 footprint 外并待命（实测 2.55 m，需要 > 4.08 m，action=WaitingForTargets()）`
  ⇒ 这就是用户"建筑造得太近会卡单位"的可量化形态：被挤出的单位只退到 2.55m，而需求是 >4.08m。
  本轮**没有**用放大半径或改判据的方式让它变绿。
- 另见 `OreRefinerySmokeTest` 日志反复出现 `[REFINERY-CLAIM] Unit_6 在册=1/2 无可接管工人：工人=5 已被占用=5`
  ⇒ 矿场想接管却无空闲工人，与 §3.2 的"矿车/交付"链路直接相关，是下一轮的头号线索。

## 5. §一.3 第 4 条：`RELAY_MAX_HOP_M=24` 的实际加载与生效（运行时探针，非读代码）

```
movement.RELAY_MAX_HOP_M = 24.0
one-hop with contiguous vision chain = [24.0, 0.0]   # 旧口径会被自己视野封在 14
economy_ignited(workers only)                        = False
economy_ignited(refinery under construction)         = False
economy_ignited(built refinery + worker)             = True
income_observed(delivered_count=3)                   = True
income_observed(built refinery, 0 deliveries)        = False
economy_under_construction(在建矿场)                 = True
```

⇒ 24 米节奏上限**确实被生产路径加载并使用**；经济三态口径逐项符合提示词 §一.1 的要求。
（真实 Match 里的实际位移统计仍未完成，见 §6。）

## 6. 交付链的真实现状与根因定位（本轮最有价值的发现）

`OreRefinerySmokeTest` 日志证明**权威端交付本身是通的**：

```
[GATHER] 交付 resource_a=400 resource_b=0 player=Human
[REFINERY] Unit_0 完工→首次交付 = 6.2s
[REFINERY] Unit_0 收到交付 worker=Unit_1 amount=500（累计 1 次 / 500 矿）
```

（`400 → 500` 是采集倍率生效：`delivery["resource_a"]` 经 `AugmentModifiers.scale_gather` 放大后才记账，
所以矿场账本与工人载货量本就不同数，不是 bug。）

真正卡住的是**被测矿场拿不到工人**，同一日志里重复 43 次：

```
[REFINERY-CLAIM] Unit_6 在册=1/2 无可接管工人：工人=5 已被占用=5 冷却=0 忙={  }
```

⇒ "已被占用=5" 与 "忙={ }"（本矿忙碌集为空）**互相矛盾**：占用计数把 5 个工人都算给了别人
（或被别的矿场/规则令占住），于是 `Unit_6` 永远 0 工人 → 260 秒窗口内没有一次交付 →
"玩家账户必须真实增长（6700 → 6700）" 红。
而 "矿点存量 272808 → 273208"（+400，正好一车）说明该断言的**统计窗口被夹具自身落矿污染**
（`_world_ore_total()` 是全图总量，脚本在取样之间还会造矿点）——这条更像**判据口径问题**，
不是"矿被凭空加回来"。两者都需要下一轮在权威端分别处理，本轮**未改任何 C#/GDScript 交付代码**，
也没有放宽任何断言。

## 7. 截图（已实际打开查看，非仅落盘）

目录 `agent/runs/20261011-adjutant-map-progress/`，18 张 = 6 状态 × 3 尺寸（1920×1080 / 1280×720 / 1000×720）：
`flow-running-mixed-*.png`、`flow-done-pass-false-*.png`、`flow-quick-preview-*.png`、
`flow-skip-engine-in-game-*.png`、`flow-stage-failed-*.png`、`flow-all-done-*.png`。

已人眼核对：1920 下五节点单行不遮挡预览/图例/左右栏；1000×720 下流程图**自动换两行**（提示词允许）仍可读；
节点 5 显示"» 跳过：游戏内生成路径"为灰字；总状态行与细节行文案正确。
观察到的遗留：1000 宽时左侧「地图设置」列被裁切——这是该页**既有**响应式行为，非本轮引入，未处理。

## 8. 未验证 / 阻塞项（不得当作完成）

1. **未启动新的真实 Match**：首座矿场真实实体完成、矿点库存减少、首笔交付、余额、单位通行、
   无人机覆盖增益与补造次数——**全部未实测**，§3.1/§3.2 目前只有单测与静态复现级证据。
2. **无 5 FPS 视频**：施工前/中/后与单位通行的动态回看缺失。
3. §一.2 的建筑间距/出口/通行**未修**：4 项 Godot 失败仍在（2 项已取到判据原文，2 项待重跑归因）。
4. §一.3 无人机损失补造、机场被毁恢复、`scoutconfirm` 抽兵比例、`RELAY_MAX_HOP_M=24` 在真实 Match 的
   实际位移统计：**未做**。model=off / model=timeout 两档亦未分档记录。
5. UI 的真实一次 G2 预览 + 一次完整 G1→G4→引擎任务**未跑**（避免与地图服务的活动任务争用共享服务）。
6. 未重编译 C#：Godot 侧结论受 21:02 DLL 约束。

## 9. 真实 Match 实测（§一.1 验收门，model=off / 规则中台档）

命令：`python source/adjutant_coordinator/deploy/selfplay_match.py --seconds 300 --tag eco-r1 --backend off`
端口：`[selfplay] 验收端口 24589 在专用段 24589-24592 内`（独立段，未触碰共享服务）；
`op=start -> {'map': PlainAndSimple, 'ok': True, 'with_ai': True, 'seed': 0}`；rc=**0**；
产物 `G:/AIRTS/tmp_logs/langgraph_recon/selfplay/result_eco-r1.json`。

终局：`verdict=timeout own=18 enemy=2`
`units={'command_center':1, 'ore_refinery':1, 'vehicle_factory':1, 'drone':1, 'worker':6, 'tank':5, 'anti_ground_turret':2, 'anti_air_turret':1}`
`balance={'a':450}`

**与 §2 基线对照的实质变化**：历史局 `r10-newdll` 是"7 辆矿车、**0 座矿场**"；
本轮 §3.2 的 `first_economy` 修正后，**首座 `ore_refinery` 真的建成了**，并且
`[REFINERY] Unit_4 完工赠送矿车 Unit_5`、`[AUTOSPOT] mode=resource ... FOUND-ADJACENT (107.7,0.6,68.9)`
（权威端自动选址成功，距锚点矿 9.2m）。

**但 §一.1 验收门仍未通过**，权威端事实：

| 指标 | 实测 | 判定 |
|---|---|---|
| 首座矿场真实实体完成 | `ore_refinery:1`、`refinery.constructed=true` | **通过** |
| 矿点库存确实减少 | `ore_remaining 362000 → 361500 → 362000`（一次 500 后按再生回到原值） | 未通过（无净减少） |
| 至少一笔交付/收入 | `delivered_count=0`、`delivered_amount=0`、`first_delivery_ms=-1`、`has_ore=**False**` | **未通过** |
| 余额 | `8500 → 1500 → 450` 后长期持平 | 无收入佐证 |

⇒ 矿场建成了却 `has_ore=False`（16 颗矿点、362000 存量在场），即 `has_serviceable_ore()`
→ `_nearest_ore()` → `_ore_is_serviceable()`（有矿 ∧ `is_ore_reachable` ∧ `_player_can_see_ore`）
三条里有一条把**所有**矿点判否；`_claim_tick` 因 `not has_serviceable_ore()` 直接 `_release_all()` 返回，
所以永远 0 在册、0 交付。**本轮未改权威端（GDScript/C#）**，此项转下一轮，且必须按
提示词 §一.2 分口径量实测（footprint / 物理碰撞 / carve / 导航 agent / 服务站位），不得放大常量。

`OreRefinerySmokeTest` 的失败**不是**同一个原因（不要混为一条）：它已经接管到 1/2，
卡点是 `[REFINERY-CLAIM] Unit_6 在册=1/2 无可接管工人：工人=5 已被占用=5 冷却=0 忙={ }`
⇒ 5 个工人全部带 `ore_refinery_assignment` meta（被另一座矿场占着），本矿抢不到人。
这是**多矿场之间的名额分配**问题，与真局的 `has_ore=False` 是两个独立断点。

## 9b. 新 DLL 下的四个套件（消除"旧 DLL"混淆变量）

`dotnet build` 后重跑（`-newdll.log`）：`OreRefinery=3`、`StructurePlacement=2`、`RuntimePlacement=1` failures，
与旧 DLL **完全一致** ⇒ 这些失败是**当前源码的真实失败**，不是构建产物过期造成的假红。

## 9c. `has_ore=False` 归因进展：**可见性已排除**，指向导航可达性（探针自曝局限）

新增只读探针 `tests/automated/_IndepVerifyOreServiceable.gd`，按真局几何
（矿场落在最近矿点背向基地 9.2m，与 `eco-r1` 的 `AUTOSPOT anchor=(98.5,68.9) →
FOUND-ADJACENT (107.7,68.9)` 同一几何）逐条量 `_ore_is_serviceable` 的三个合取项：

```
=== [IVOS] 真局几何：矿场距最近矿点 9.20m（该矿点距基地 78.77m）===
  refinery.sight_range=24.0  worker_capacity=4
  has_serviceable_ore=true
  最近矿点: ore_a=30000 reachable=true visible=true serviceable=true
  refinery 自己的 nav_map_valid=false（无效则 reachable 短路成 true，等于没测）
```

**结论一（成立）**：`ore_refinery` 的 `sightRangeMeters=24` 确实落到了单位身上
（`sight_range=24.0`），而 `FogOfWar.player_can_see` 是按 `units` 组里每个单位的
`sight_range` 判定的 ⇒ **矿场自己就能给视野，9.2m 外的锚点矿 `visible=true`**。
所以真局里那个 `has_ore=False` **不是"矿场看不见矿"**。这一条被我早前一轮误判过：
当时探针把矿场摆在"离基地 6/26/60m"，那些位置离任何矿点都有 34–103m，
`visible=false` 是**摆放方式造成的假象**，不是机制。已纠正。

**结论二（未闭合，且必须说明证据边界）**：`reachable` 这一项在本探针里**根本没被测到**——
矿场自己的 `_navigation_map()` 返回无效 RID，`is_ore_reachable` 因此短路成 `true`。
我用对局的 `terrain` 域地图代量得到 `off_mesh=155.64`，但既然矿场自己拿不到域地图，
这个绝对值**不能当作真局数字**。
⇒ 剩下的唯一强证据仍在**烘焙正常的真局侧**：`OreRefinerySmokeTest` 的夹具自检
`矿场周围应有可采矿落点（carve 洞外、网格上、走得通、站位也走得通）` **本来就是红的**，
而 `_IndepVerifyRefineryReach` 独立量到 `报到点(4.87) 在洞内 ⇒ 工人永远到不了`、
`洞半径稳定在 16.00`。两条都指向 **carve/导航可达性**，不是可见性、不是矿量、不是视野。

**下一轮该做的决定性一步**（本轮未做，因为要在真局里加临时仪表）：
在 `OreRefinerySmokeTest` 那套**已烘焙**的场景里，对矿场周围每个候选落点打印
`_off_mesh_xz / carve_clearance_of+2.0 / map_get_path 末点距离`，
把"是哪一条把矿点判否"钉成实测数字；然后再决定改 `firstRing` 还是改站位带。

## 10. 后端进度合同补齐（提示词 §二「后端/进度必要修补」）

要求是"先确认 `pipeline.py` / `server.py` 已把每次阶段开始/完成/失败/跳过/布局重试写入 job"。
核对结果：**完整任务（`target=full`）走 `pipeline.run_pipeline` + `StageRecorder`，确实全写**；
但**快速预览（`target=g2`）走 `server._generate_g2`，该路径完全不写 `job['stages']`**。

真机实测（独立端口 8767，我自己启的服务，未触碰共享服务）暴露了它：

```
[g2] t=0.0 job=running stages={}
[g2] t=6.0 job=error  stages={}     ← 任务已经失败，五个节点在流程图上仍全是"等待"
```

⇒ 中心流程图（唯一状态源 = stages）对预览任务**完全失效**。已按合同补 `server.py`：
预览路径用**同一个** `StageRecorder` 记 `g1_input` / `g2_terrain` 的开始/完成/失败，
`pass` 取 `mapspec.all_pass`，异常时 `rec.fail(...)` 后原样抛出（不在 UI 层猜）。

补丁后同一任务：

```
[g2] t=0.0 job=running stages={'g1_input': 'done', 'g2_terrain': 'running'}
[g2] t=4.0 job=running stages={'g1_input': 'done', 'g2_terrain': 'done'}
[g2] FINAL status=done stages={'g1_input': 'done', 'g2_terrain': 'done'}
final stages: g1_input{pass:true,duration_s:0.0} g2_terrain{pass:true,duration_s:3.4,summary{all_pass:true}}
```

并把这份**真实后端产物**接进 UI 测试：`MapProgressFlowSmokeTest._case_h_real_backend_job()`
读 `workbench-g2.json` 的 final job 驱动渲染，断言 G1/G2 完成、G3/G4/engine "快速预览未运行"、
总状态 `2/2 阶段完成`。重跑结果：`Map progress flow smoke test completed: 0 failure(s)`，rc=0，
无 SKIP（说明真数据用例确实执行）。

### 地图后端既有测试：8 失败是**先于本轮**存在的（已做对照实验）

`OPENBLAS_NUM_THREADS=1 .venv-g2/Scripts/python.exe -m pytest tests/test_pipeline.py tests/test_g2_workbench.py -q`

| 运行 | 结果 |
|---|---|
| 基线（临时移除我的 server.py 补丁） | `8 failed, 19 passed` |
| 带补丁 | `8 failed, 19 passed` |
| 失败集合 `diff` | **完全一致（IDENTICAL failure set）** |

⇒ 我的补丁**零新增失败**。这 8 条是当前源码里的既有失败，集中在 `map_pass` / "失败不得变成 pass"
语义（例：`test_g2_failure_stops_downstream_and_retry_keeps_inputs` 期望 `map_pass is False`，
实得 `True`）与 bootstrap/config 映射，属**其他在飞任务**的范围，本轮未改判据、未试图顺手改绿。
首轮 pytest 曾因系统提交内存耗尽而 `OpenBLAS error: Memory allocation still failed`（零输出 rc=1），
那是环境现象；限制 BLAS 线程数后即正常收集并跑完。

## 11. §一.2 四个套件的**逐条判据原文**（新 DLL，未改任何判据）

| 套件 | failures | 判据原文（含实测数） |
|---|---|---|
| `OreRefinerySmokeTest` | 3 | 矿点存量必须被真实采掉（272808 → 273208）；工人回矿场交付后玩家账户必须真实增长（6700 → 6700）；夹具自检：矿场周围应有可采矿落点（carve 洞外、网格上、走得通、站位也走得通） |
| `StructurePlacementSmokeTest` | 2 | 地表导航图应在放置评估前完成初始化；被覆盖的友军应移动到建筑 footprint 外并待命（实测 2.55 m，需要 > 4.08 m，action=WaitingForTargets()） |
| `RuntimePlacementSmokeTest` | 1 | 可移动单位不应被无效导航查询吸附到原点 |
| `SpawnPointRegression` | 3 | B2 被驱逐单位最终距离应 > 半径和（2.63）；D scale=2 出生点应贴各自世界外缘（infm vs 外缘 5.04）；D scale=3 出生点应贴各自世界外缘（infm vs 外缘 7.51） |

⇒ 四个套件是**四类不同断点**（交付/站位可达、导航图初始化时序、无效导航查询吸附原点、
出生点距离算成 `infm`），不能靠放大一个半径一起解决。`infm` 那条尤其说明是**计算返回了无穷**
而不是"差一点"。本轮未动这些代码，判据一条未改。

## 12. 环境阻断（不得记为游戏故障）

跑完整 `target=full`（G1→G4→引擎验收，会另起 Godot 导入资产）前实测系统提交内存：

```
mem_load=76%  availPhys_GB=7.35/31.90  availPageFile_GB=0.31/71.90
```

物理内存尚有 7.35GB，但**页面文件/提交额度只剩 0.31GB**；`.venv-g2` 的 pytest 因此直接
`OpenBLAS error: Memory allocation still failed after 10 retries, giving up.`（收集阶段就失败、
零输出、rc=1）。占用来自用户自己在跑的应用（Memory Compression 3.5GB、dotnet、CodeBuddy、
ChatGPT、Qoder、ollama/llama-server 等），**不属于本任务创建，一律未结束**。
⇒ 首轮 `tools/mapgen/tests/*` 的 pytest **未跑成**（环境内存，不是代码问题）。停掉我自己启的
8767 服务后提交额度回到 1.98GB，限制 BLAS 线程数后测试**已正常跑完并做了补丁前后对照**（见 §10）；
仍然没做的是完整 `target=full`（G1→G4→引擎验收会另起 Godot 导入资产，当前内存余量不足以安全启动）。



## 13. candidate / champion

- champion：开工时的工作树（含他人未提交改动）。
- candidate：本轮 5 改 + 2 新增测试 + 1 后端补丁（`server.py` 预览 stages）。
- 决策：**§3.1 中继前缀、§3.2 经济口径、§3.3/§10 流程图与预览 stages** 有可复跑证据
  （134 OK / 1025 中 0 新增失败 / 新场景 0 failure 且含真数据用例 / 18 张截图 + 真机 G2 前后对照 /
  对照实验证明补丁零新增失败），判为**候选晋级**。
  但 §一.1 的**验收门本身未过**（真实局 0 交付、0 收入）⇒ "经济与首矿"整条**不晋级**；
  §一.2 通行、§一.3 无人机闭环**未晋级**。整体仍 `needs-review`，连续未提升轮数：0。

## 14. 下一轮建议顺序（按本轮新证据排）

1. **先解 §9 的 `has_ore=False`**：真局里逐颗矿点打印
   `resource_a>0 / _off_mesh_xz / carve_clearance_of+GATHER_REACH_SLACK_M(2.0) / player_can_see`，
   确定 `_ore_is_serviceable` 三条里是哪一条把所有矿点判否 —— 这是 §一.1 验收门的唯一阻塞点。
   同时注意 §11 的 `AUTOSPOT radius=3.0186` 与代码注释假设的"footprint 9.8 / carve 洞 12.6"
   **不是同一个数**：先确认权威 footprint 到底是几米，再决定服务站位带，不得靠放大常量凑绿。
2. 再解 §11 其余三类：导航图初始化时序、无效导航查询吸附原点、出生点距离算成 `infm`。
3. 无人机闭环：两架方向认领与覆盖增益量化、损失/机场被毁补造、`scoutconfirm` 比例、
   真局 `RELAY_MAX_HOP_M=24` 的实际位移统计；分档记录 model=off 与 model=timeout。
4. 补 §二 剩余真实覆盖：完整 `target=full`（G1→G4→引擎）一次、服务断连、迟到 HTTP 响应、
   切历史与返回再进入。本轮因提交内存只剩 0.31GB 未跑完整流水线（§12），需等内存宽裕再做。
5. 5 FPS 视频：`tools/dev/record_playtest.py` 走 `printwindow`，**必须真实窗口**，
   与"后台测试不得抢前台"直接冲突 ⇒ 需要用户明确同意开一次前台窗口，或由用户手录。
6. 地图后端那 8 条既有失败（`map_pass` / 失败不得变 pass / bootstrap 映射）属其他在飞任务，
   本轮未动；交接时要提醒它们**先于本补丁存在**。

