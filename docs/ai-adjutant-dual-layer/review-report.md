# 副官双层改造第一阶段 审查报告

日期：2026-09-07。实施：CodeBuddy（GLM-5.3-Flash）。状态：第一阶段交付，待负责人审查后安排第二阶段。

## 0. 独立复核记录（2026-09-07，审查方第一轮）

- 结论：**第一阶段交付基本可信**。协调器 26/26 通过；E2E 独立复跑 **21 PASS / 0 FAIL / 0 SKIP**。
- 复核方直接修复 `e2e_dual_layer.py` 在中文 Windows 默认编码下读取 `git log` 崩溃的问题
  （`subprocess.run(..., encoding="utf-8", errors="replace")`），本轮已确认该修复在工作区。
- 汇总格式统一：`summary.json` 原为顶层 `PASS/FAIL/SKIP` 字段；应用复核方建议改为
  顶层与 `counts` 子对象**双格式并存**（内容一致），后续汇总脚本统一读 `counts.*`。
  已在 `e2e_dual_layer.py` 落实（`python -m py_compile` 验证通过）；历史 run 目录证据保持原样不回改。
- 复核方建议的第二阶段前置范围（未实施，待安排）：真实 provider 接口、宿主调度/超时/重连/心跳、
  中文 UI 消费结构化回执、玩家"交还副官"授权开关、Hermes 完成前的离线假模型模拟测试。

## 1. 基线与工作位置

| 项 | 值 |
| --- | --- |
| 仓库 | `G:\AIRTS\AI_RTS`，分支 `yyp_test` |
| 基线提交 | `6bcf1a1fa9707a470184bcbe7ef62209b6e6ae91`（2026-09-07 00:30 +0800「大更新」） |
| 基线脏文件 | 地图生成 3 项（`35-0-rampfix` 改动、`49-1376088014-rampfix` 删除）+ 新增 fbx 资产 + `docs/ai-adjutant-dual-layer/` 文档目录 + 新增 `16/35/47` 地图目录 —— 全部为其他任务内容，**未触碰、未恢复、未清理** |
| 本轮新增修改 | 见 §2，全部为新增文件 + 三个既有文件的小补丁，未使用 worktree（改动集中且与热点冲突面小，见偏差 D8） |
| 规则版本 | Demo 对局 `demo-baseline-2026-08-12`；独立测试配置 `adjutant-e2e-2026-09-07`（含 content hash，运行时从 Catalog 导出） |

## 2. 实际修改文件

### 新增

| 文件 | 职责 |
| --- | --- |
| `source/csharp/GodotAdapter/Adjutant/AdjutantObservationRuntime.cs` | C# 规则导出器：从当前 Match 实际加载的 `IGameBalanceCatalog` 导出规则视图与公共包头（match_id/player_id/rules_version/snapshot_id/server_tick）。同 assembly 访问 internal `BalanceConfigRuntime.Catalog/Assets` 与 `EconomyRuntime.MatchId`，**零修改既有 C# 类型** |
| `source/match/units/Scout.tscn` | 独立测试配置专用的新增普通内容场景（复用 Drone.gd 通用单位脚本）；正式平衡数据不含 scout |
| `config/balance/adjutant-e2e.balance.v1.json` | 独立测试平衡配置：demo 全量副本 + 新增普通单位 `scout`（air/视野 12/无武器，成本 A×120，由 aircraft_factory 生产）+ tank 成本变更 500→555。**不改动用户正式平衡数据** |
| `config/godot/adjutant-e2e.assets.v1.json` | 配套受信任资产映射（scout→Scout.tscn） |
| `tests/automated/AdjutantRulesExportSmokeTest.gd/.tscn` | 规则导出冒烟（稳定 ID/能力/成本/生产关系/受信任映射/指纹/技能显式不可调用） |
| `tests/automated/AdjutantObservationSmokeTest.gd/.tscn` | 战术观测冒烟（包头/视野公平/冻结情报/确认死亡/截断续取/战略摘要，双玩家场景） |
| `tests/automated/AdjutantCommandProtocolSmokeTest.gd/.tscn` | 命令协议冒烟（身份/版本/过期/幂等/玩家优先权/动态生产关系/受信任场景/批次/账本背压） |
| `source/adjutant_coordinator/`（Python 协调器核心） | `protocol.py`（命令包/计划校验）、`state.py`（PlanStore 采纳代际/TaskTracker 状态机/ControlLease）、`events.py`（有界事件总线+合并）、`persistence.py`（按对局玩家隔离目录+独立临时文件原子写+单写入者锁）、`coordinator.py`（协调器+确定性假模型）、`tests/`（26 个 unittest） |
| `source/adjutant_coordinator/e2e_dual_layer.py` | 本地双进程 E2E（权威服+客户端，独立测试配置，独立 run_id 目录） |

### 修改（小补丁）

| 文件 | 改动 | 说明 |
| --- | --- | --- |
| `source/net/DebugControlServer.gd` | 新增 5 个 op（`rules`/`tactical`/`strategic`/`adjutant_command`/`adjutant_batch`）+ 幂等账本/控制租约/敌情情报 + `_ready` 动态挂载 C# 观测节点 + `_query_commands` 优先查副官账本 + 手动 op 成功路径调用 `notify_player_override` | 副官协议核心入口；`_command_log` 展示历史（64 条）与副官幂等账本（256 条，满时显式 `LedgerFull` 背压）**分离** |
| `source/csharp/GodotAdapter/Configuration/BalanceConfigRuntime.cs` | `_EnterTree` 前解析 `--balance-config=`/`--assets-manifest=` 用户参数 | 未传参时行为完全不变；供独立测试配置（E2E）使用 |
| `source/match/players/human/UnitActionsController.gd` | `_emit_command_feedback` 成功路径调用 `_release_adjutant_leases()`（+新私有函数） | 真实玩家 UI 手动命令 → 立即取消副官控制租约（玩家优先权） |
| `source/net/DebugControlServer.gd` `_op_build` | 直执行条件 `is_server` → `is_server or not is_networked`；NetSync 检查移至转发分支 | 单机（未联网）对局的 build 原先必然 `NoNetSync` 失败；现直执行。联机行为不变（偏差 D7） |

## 3. 协议映射与兼容行为

| 设计契约 | 实际映射 |
| --- | --- |
| 规则来源唯一（当前对局 Catalog） | C# 从 `BalanceConfigRuntime.Catalog` 导出；`op=rules` 按 match_id 缓存（Catalog 对局内不可变） |
| 公共包头 | `AdjutantObservationRuntime.BuildHeader`：schema_version=1、match_id（EconomyRuntime.MatchId）、player_id（服务端解析）、rules_version（Catalog content hash）、snapshot_id（对局内自增）、server_tick（`Engine.GetPhysicsFrames()`，与 `ProductionRuntime.CurrentTick` 同源） |
| 战略/战术/规则三视图 | `op=strategic`（资源/产能/敌情 last_seen/地图边界/可用能力与生产关系）、`op=tactical`（实体级快照，支持 center/radius/limit/offset）、`op=rules` |
| 视野公平 | 敌方实体只回 as_player 自己存活单位的 sight_range 判定结果（复用 `_unit_scouted`，不碰全局组）；失去视野 → `unit_enemy_frozen`（冻结 last_seen，不更新真实状态）；世界移除 → `unit_enemy_dead`（confirmed_dead 独立事件）；**未提供 full_vision** |
| 截断与续取 | `truncated` + `next_offset` 显式；分页合并覆盖全量（冒烟测试验证） |
| 命令协议 | `op=adjutant_command`：必填 command_id/request_id/match_id/player_id/rules_version/plan_version/task_id/based_on_snapshot/issued_tick/expires_tick/action/params；验证链 = 结构 → 幂等 → 对局身份 → 玩家授权（human）→ 规则版本 → 快照时效 → 过期 → 受信任场景 → 动态生产关系 → 控制租约 → 权威执行 |
| 幂等作用域 | `(match_id, player_id, command_id)`；同 ID 同参数重放返回原回执 + `idempotent_replay=true`；同 ID 异参数 → `DuplicateConflict`；账本满 → `LedgerFull`（显式背压）。`op=commands` 复核优先查账本 |
| 玩家优先权 | 副官接受命令时登记租约；玩家手动命令（真实 UI 路径经 `UnitActionsController` 钩子、旧 op 路径经 `notify_player_override`）立即失效；再动被拒 `PlayerOverride`；重新接管需请求显式 `reacquire=true`（记录授权与命令关联）。协调器侧（Python `ControlLease`）同步拦截，双层防御 |
| 逐条批次 | `op=adjutant_batch` 逐条提交逐条回执，明确非原子；前一条扣资源后后一条按剩余重新校验（权威入口天然逐条结算） |
| 回执三态 | 传输接收（TCP 行）/权威接受（`accepted`+`status`）/任务完成（协调器 TaskTracker：pending/running/completed/failed/cancelled/unknown）；`PendingAuthority` 不落终态、任务不转 failed，等待 `op=commands` 复核 |
| 资源预留 | 协调器 `_reserve_budget`/`_spent`：预留是副官花费约束而非第二余额；已接受实际支出累计计入，`est_cost` 超预留 → `BudgetExceeded` 拦截 |
| 模型请求代际 | `ModelRequest`（role/request_id/deadline）；超时标 `timed_out`；`deliver_late_result` 对迟到返回按代际丢弃（`stale`），不抢回控制 |
| 持久化隔离 | `MatchPlayerStore`：`root/<match_id>/<player_id>/` 目录隔离；独立临时文件（pid+uuid）+ `os.replace` + Windows 重试；`writer.lock` 单写入者（陈旧锁 pid 活性回收） |

## 4. 与设计的偏差

| # | 偏差 | 理由 |
| --- | --- | --- |
| D1 | `display_name` 暂等于稳定 ID | 当前工程无单位本地化/展示名资源（已核查 Ra3Sidebar 等无映射）；字段已预留，接本地化时须与 Catalog 类型 ID 关联 |
| D2 | 技能全部标 `adjutant_callable=false` | 第一阶段命令协议动作集未含 `cast_skill`；观测也未暴露技能槽。命令执行与观测均不支持时不声明可由副官调用（按 architecture.md §2） |
| D3 | 观测（tactical/strategic）允许任意存在玩家视角（含 AI），命令仅允许 human 玩家 | 观测是只读且按该玩家视野过滤（不泄露）；副官语义 = 指挥真人玩家部队（沿用现有 as_player 约定）。AI 玩家视角便于 E2E 观测验证 |
| D4 | 玩家"显式交回控制权"以协议字段 `reacquire=true` 记录（含命令关联与 tick），真实玩家授权 UI 归第二阶段 | 第一阶段无中文 UI 交付；授权事实已显式化、可审计，符合"不能下一次轮询立刻抢回"的纪律 |
| D5 | 旧 `op=status` 的 `full_vision` 参数原样保留 | 兼容现有 lite 采样器与 round_runner 判定纪律；新战术快照不提供 full_vision |
| D6 | 协调器为 Python（`source/adjutant_coordinator/`），通过 transport 注入与游戏解耦 | 架构指明"宿主程序调度模型"；第二阶段接真实模型 API 时仅替换 StrategyModel/TacticsModel 实现 |
| D7 | `_op_build` 单机直执行（行为变化） | 单机对局没有转发目标，原实现必然 `NoNetSync`；副官单机验证依赖此路径。联机（networked）路径完全不变 |
| D8 | 未使用独立 worktree | 改动 = 新增文件 ×20 + 3 个既有文件小补丁；热点冲突面最大的是 DebugControlServer.gd（本就是副官热点）。基线脏文件全部保留未触碰。如审查方要求可平移到 worktree（文件清单见 §2） |
| D9 | `EconomyRuntime.MatchId` 为 internal | 通过同 assembly 新增 C# 类访问（public API 不变），未放宽既有可见性 |

## 5. 测试证据

### 5.1 GDScript 冒烟（真实引擎，headless 单进程）

| 测试 | 命令 | 结果 | 证据 |
| --- | --- | --- | --- |
| 规则导出 | `Godot --headless --path G:\AIRTS\AI_RTS res://tests/automated/AdjutantRulesExportSmokeTest.tscn` | **PASS（0 failure），exit 0** | `G:\AIRTS\tmp_logs\final_rules.log` |
| 战术观测（双玩家） | `... res://tests/automated/AdjutantObservationSmokeTest.tscn -- --debugport 24681` | **PASS（0 failure），exit 0** | `G:\AIRTS\tmp_logs\final_obs.log/.err.log` |
| 命令协议 | `... res://tests/automated/AdjutantCommandProtocolSmokeTest.tscn -- --debugport 24682` | **PASS（0 failure），exit 0** | `G:\AIRTS\tmp_logs\final_cmd.log/.err.log` |

### 5.2 协调器确定性测试（Python unittest，假模型 + 注入时钟）

命令：`cd G:\AIRTS\AI_RTS\source\adjutant_coordinator && python -m unittest discover -s tests`
结果：**26/26 PASS，0 FAIL，0 SKIP**（计划采纳代际/版本倒退拒绝、逐条批次、PendingAuthority 不失败任务、玩家接管+reacquire、迟到返回丢弃、事件合并与有界背压、竞争订单不超预留、持久化并发/隔离/陈旧锁回收/损坏容错）。

### 5.3 真实双进程 E2E（本地权威服 + 客户端，独立测试配置）

命令：`cd G:\AIRTS\AI_RTS\source\adjutant_coordinator && python e2e_dual_layer.py --run-id e2e_run5`
结果：**PASS=21 FAIL=0 SKIP=0**（汇总 `logs/e2e_run5/summary.json`；进程日志 `server.log`/`client.log`）。

关键场景证据（全部真实 TCP → 权威进程）：
- 独立测试配置的新对局中规则视图发现新增内容 `scout` 与 tank 成本 555（正式平衡数据未改）；
- `command_center` 生产 tank 被动态生产关系拒绝（`InvalidProducer`）；
- 副官 build → 服务器直执行 `Accepted` → 战术快照出现 `constructed=true` 的 vehicle_factory（**真实世界状态变化**）；
- vehicle_factory 生产 tank `Accepted`（成本 555 从当前账本扣）；
- 同 command_id 重放：原回执 + `idempotent_replay`，生产队列仍 1 个订单（**不重复扣费**）；
- 玩家手动命令后副官被 `PlayerOverride` 拒绝；`reacquire` 授权后恢复。

### 5.4 既有测试基线对照

| 段 | 本轮 | 基线（2026-09-06 记录） |
| --- | --- | --- |
| `tests/core` AI_RTS.Core 段 | 59 测试 17 失败 | 17 失败（09-04 遗留，与副官链路无关） |
| Balance config 段 | **17/17 PASS** | 0 失败 |
| 其余段（placement/construction/production/rally/input/control-group/world-query/outcome/event） | 全部 0 失败 | 0 失败 |

C# 构建零警告零错误（`dotnet build OpenRTS.csproj`）。

### 5.5 调试过程记录（首次失败与修复）

首次失败均保留在 `G:\AIRTS\tmp_logs\adj_*`：规则导出 1 失败（测试索引字段名）→ 修复后过；观测测试超时 3 轮（parse error ×2、queue_free 后访问已释放对象、测试逻辑反转）→ 修复后过；协议测试 9→4→2→1→0 失败（测试 helper 未提交命令、params 引用污染破坏幂等指纹、`_adjutant_check_scene` 字段名不匹配、match_id 校验缺失、build 单机路径、账本复核链）；E2E run1→run5：put_utf8_string 长度前缀、单位装载时序、硬编码 Player_1（空槽占位）触发鉴权拒绝、建造点不可建、复核链路。未使用无限重试掩盖失败。

## 6. 验证状态分类

- **真实引擎验证（headless 真实对局/双进程）**：规则导出内容与指纹、包头、视野冻结/死亡确认、截断续取、身份/版本/过期/幂等/背压、玩家优先权（含真实 UI 钩子路径的单机等价）、动态生产关系、**真实建造链与生产链的世界状态变化**、同 ID 不重复扣费。
- **仅确定性假模型测试（非模型实战）**：协调器的计划采纳、任务状态机、事件合并、请求代际/迟到丢弃、重试退避、资源预留约束、假模型脚本化协议。**假模型只验证协议，不构成双模型闭环。**
- **未验证（如实声明）**：真实双模型接入、中文 UI、Hermes 线上集成、DGX、亚秒级微操；`LedgerFull` 的多会话并发竞争（单写者模型下由锁保证，未做双客户端并发压测）；跨对局长时间运行的账本内存增长（有界 256，但未跑 24h 老化）。

## 7. 第二阶段接入点与剩余工作

1. **模型接入**：实现 `adjutant_coordinator.coordinator.StrategyModel/TacticsModel` 的真实 provider（配置 provider/model/timeout/预算，凭证仅服务端）；宿主进程装配 `AdjutantCoordinator` + `MatchPlayerStore`，transport 走 TCP `adjutant_command`/`adjutant_batch`。
2. **Hermes 边界**：核实服务器 Hermes 版本与扩展机制后决定调度宿主位置；先不改线上配置。
3. **中文 UI**：`AICommandHUD`/`AdjutantButton` 改为消费 plan_id/task_id/command_id 关联的结构化回执（账本 receipt 已带 task_id/plan_version）。
4. **玩家授权 UI**：把 `reacquire=true` 的协议授权升级为玩家侧"交还副官"开关。
5. **旧接口兼容**：`op=status/lite`、`op=move/gather/build/produce/attack`、`op=commands` 均保持兼容；Hermes 现行 rts_ctl 链路未受破坏（E2E 用同链路）。
6. **内容协作约定**：稳定 ID 不随显示名变更；新增能力需在规则视图暴露并写明命令支持情况；删除/重命名 ID 属不兼容变更（当前导出按 Catalog 全量，自动跟随）。

## 8. 未解决问题

- 独立测试配置通过 `--balance-config` 用户参数加载：该机制对服务器/客户端进程均生效，但**生产环境不应传该参数**（默认路径不变，风险低，建议审查确认）。
- `_adjutant_ledger` 为进程内存账本：对局重启即清空（幂等作用域限定在 (match,player) 内，语义正确），但跨重连的复核依赖对局进程存活。
- Python 协调器未接入自动重连/心跳（第二阶段宿主职责）。
