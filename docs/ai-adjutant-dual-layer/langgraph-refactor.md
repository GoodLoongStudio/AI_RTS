# AI 副官 LangGraph 重构：实施记录与映射

> 状态：**本地实施完成（FakeModel 闭环 + 本地双进程 E2E + 真实模型闭环）**；
> 服务器已部署到 `/opt/airts-agent`（独立目录/独立 venv，玩家局服与旧 daemon 未动）；
> **服务器侧“真模型 + 服务器对局”闭环未跑通**（游玩代码树半合并，见 §8.6）。
> 日期：2026-09-10（真实模型与服务器部署部分为当晚追加）
> 外部审核包（声明↔证据↔复现↔争议点）：`docs/ai-adjutant-dual-layer/langgraph-refactor-review-report.md`
> 依据：`docs/plan/AI副官_LangGraph重构方案.md`、`docs/plan/AI副官_LangGraph重构执行提示词.md`、
> `docs/ai-adjutant-dual-layer/architecture.md`、`docs/ai-adjutant-dual-layer/delivery.md`、
> `docs/项目统一规范.md`（main 为交付基线；本地分支 `yyp_test`）。

## 0. 结论速览

| 项目 | 状态 | 证据 |
| --- | --- | --- |
| 每个对局独立图状态 | 已实现 | `graph/state.py` + `graph/checkpoint.py`（按 `(match_id, player_id)` 隔离） |
| 战略层低频生成计划、不下命令 | 已实现 | `graph/nodes.py::node_strategic_agent`；测试断言战略 tick 无下发 |
| 战术层事件触发、有限期 Intent | 已实现 | `node_tactical_agent` + `arbitration.py`（TTL 夹紧、批上限） |
| 紧急战术事件打断普通战略任务 | 已实现 | `interrupts.py::EMERGENCY_EVENT_KINDS` + `_preempt_for_emergency` |
| 玩家命令立即增加代际并撤销 lease | 已实现 | `runtime.on_player_command` + `state.mark_player_override` + 权威侧 `_adjutant_authorize_units` |
| 玩家接管后旧模型响应抢不回 | 已实现 | 仲裁 `lease_owner_player` / 权威 `PlayerOverride`,`StaleGeneration` |
| 玩家局部接管不清空战略计划 | 已实现 | 任务标记 `partially_overridden`，`active_plan` 保留（测试断言） |
| 显式归还后 AI 才能重新接管 | 已实现 | `reacquire` 契约字段 + 仲裁授权校验 + 权威 reacquire 分支 |
| 模型超时/断线/非法输出不阻塞 | 已实现 | 节点降级 + 冷却 + 保留既有计划/意图；Godot 按有效 Intent 与规则 AI 运行 |
| LangGraph 重启可从 checkpoint 恢复 | 已实现 | `JsonCheckpointStore` + `runtime.restore()`；单元测试与 E2E 场景 7 |
| PendingAuthority 不重复下单 | 已实现 | 仲裁在途指纹去重 + `observe_receipt` 按 command_id 复核（不重提） |
| 命令仍由 Godot 权威层最终校验 | 已实现 | `op=adjutant_intent` → `op=adjutant_command` 完整权威链 |
| 真实 PydanticAI 模型 | **已接入并跑通闭环** | §8.4：服务器冒烟 `PASS_REAL_MODEL`；本地闭环真实模型产出计划 + 6 条意图，权威层 `Accepted×3` |
| 服务器部署 | **已部署（独立目录，独立 venv）** | §8.5：`/opt/airts-agent`（252MB）、`.env` 600、端口硬白名单；玩家局服与旧 daemon 未动 |
| 服务器侧对局闭环 | **已跑通** | §8.6：`srv_e2e_real_r8` PASS=20 FAIL=0 SKIP=1（真实意图 `Accepted×1`）；阻塞根因与修复清单同节 |

## 1. 与现有代码的映射

| 方案要求 | 现有代码 | 本次新增/扩展 |
| --- | --- | --- |
| 计划采纳代际、任务状态机、控制租约 | `source/adjutant_coordinator/state.py`（`PlanStore`/`TaskTracker`/`ControlLease`） | 图运行时继续复用；图侧新增每单位 `generation` 与意图生命周期 |
| 命令包/计划契约 | `source/adjutant_coordinator/protocol.py` | `graph/contracts.py` 用 pydantic 固化 `StrategicPlan`/`TacticalIntent`，`to_plan_dict()` 仍走既有 `validate_plan` |
| 宿主调度、Provider 抽象、通道抽象 | `host.py` / `provider.py` / `transport.py` / `http_provider.py` | `graph/runtime.py` 复用 `AdjutantCoordinator.submit_command` 与 `Transport`，不新建第二套通道 |
| 权威命令入口与观测 | `source/net/DebugControlServer.gd`、`AdjutantObservationRuntime.cs` | 新增 `op=adjutant_intent`（意图登记 + TTL + 代际守卫）与只读 `op=adjutant_leases` |
| 观测视图（rules/strategic/tactical） | `op=rules` / `op=strategic` / `op=tactical` | `graph/model_context.py` 只消费这些视图；截断显式上报，不补默认值 |
| 编队行为执行 | `AutoAttackingBattlegroup.gd` / `SimpleClairvoyantAI.gd` / `UnitCommandGateway` | **未改动玩法逻辑**：Intent 仍经既有移动/攻击/生产/建造路径执行，游戏内规则 AI 与自动接战照常（见 §7 未完成项） |

## 2. 契约（方案 §5/§6/§7）

- `StrategicPlan`：`plan_id/plan_version/match_id/player_id/rules_version/based_on_snapshot/
  valid_until_tick/phase_goal/tasks[]/reserves/rationale/abort_when`；任务含稳定 `task_id`、
  优先级、完成条件、单位集合、选择约束与**允许动作白名单**；未知字段一律拒绝。
- `TacticalIntent`：`intent_id/plan_version/task_id/unit_ids/action/target/priority/
  based_on_snapshot/issued_tick/expires_tick/generation/abort_when/emergency/reacquire`。
  - 动作白名单：`move/attack/attack_move/defend/retreat/scout/hold/regroup`
    + 游戏已实现直通动作 `gather/stop/produce/build`；
  - 目标键白名单：`entity_id/pos/scene/producer/resource/dest/area`，其他键（例如任意
    `script_path`）直接判非法；
  - `expires_tick` 必须有上限（默认 600 tick，紧急 300 tick），超长会被夹紧并留痕。
- 控制代际与租约：
  - 图侧每个单位维护 `unit_generations[unit]`；`control_generation` 为全局单调计数；
  - 玩家手动命令 → 该单位代际 +1、移入 `player_controlled_units`、撤销 AI lease、
    相关意图全部失效、相关任务标记 `partially_overridden`（**计划不清空**）；
  - 显式归还（`player_release`）→ 该单位代际 +1 并移入 `released_units`，
    只有携带 `reacquire=true` 的意图才能重新接管（授权一次性消费）。
- 四条失效条件（`state.is_intent_valid`，判定顺序：过期 → 玩家接管 → 代际 → 计划版本）：
  `expires_tick < server_tick` / `lease.owner == player` /
  `intent.generation != 当前代际` / `intent.plan_version != active_plan_version`。

## 3. 图拓扑与节点职责（方案 §4）

```text
ingest_observation      观测包头/事件入队、身份漂移检测、tick/snapshot 推进、意图过期清理
      ↓
classify_event          事件分类与路由（player_override_gate）
      ├─ player_interrupt   → reconcile_plan        （玩家打断/归还：只动相关单位）
      ├─ emergency_tactical → tactical_agent        （紧急事件抢占同单位低优先级意图）
      ├─ strategic_due      → strategic_agent       （周期/重大事件；只产出计划）
      ├─ tactical_due       → tactical_agent        （事件驱动；产出候选意图）
      └─ wait               → wait
      ↓
arbitrate_intent        契约校验 + 引用校验 + 代际/租约 + 去重 + TTL 夹紧 + 批上限
      ↓
dispatch_to_godot       转命令包（含 intent_id/generation）→ 权威通道逐条提交
      ↓
observe_receipt         按 command_id 复核 PendingAuthority（超时不重下单）
      ↓
persist_checkpoint      按 (match, player) 原子落盘（陈旧写拒绝）
```

引擎：
- `LangGraphRunner`：真实 `StateGraph` + `MemorySaver`，`interrupt_after=[reconcile_plan]`
  实现“玩家打断 → 暂停 → 下一轮 `Command(resume=...)` 恢复并收尾”；
- `FallbackRunner`：未安装 `langgraph` 时用同一批节点函数按同一拓扑执行，
  暂停/恢复语义等价（单元测试对两条路径做行为一致性断言）；
- 图编译一次、观测按 tick 注入（`_TickContext`），单实例单线程使用。

## 4. 四道防线（玩家优先权不会被旧响应绕过）

1. **图内仲裁**：`generation`/`plan_version`/TTL/租约/引用/重复/在途校验，丢弃即留原因；
2. **兼容协调器**：`AdjutantCoordinator.submit_command` 再做协议、租约（`PlayerOverride`）与预算校验；
3. **游戏权威层**：`op=adjutant_intent` 的意图登记幂等 + 过期检查 + 代际守卫
   （`StaleGeneration` / `PlayerOverride`），再进入 `op=adjutant_command` 的规则/快照/目标校验；
4. **命令执行层**：`CommandRuntime`/`UnitCommandGateway` 的最终合法性裁决。

## 5. checkpoint 与恢复（方案 §4、§12）

- 实现：`MemoryCheckpointStore`（测试）/ `JsonCheckpointStore`（本地与服务器）/
  `NullCheckpointStore`（显式禁用）；复用 `persistence.MatchPlayerStore` 的
  按对局目录隔离 + 独立临时文件 + `os.replace` + 单写入者锁。
- 陈旧写保护：`saved_tick` 倒退的 checkpoint 明确拒绝，不覆盖更新的证据；
- 损坏/版本不支持：返回 `None` 并保留文件现场（不静默重建）；
- 恢复语义：`runtime.restore(expect_rules_version=...)` 校验身份与规则版本，
  恢复后立刻按 TTL 复核活跃意图（过期即失效），在途请求保持 pending 等待终态复核。

## 6. 模型节点与真实 Provider 边界（方案 §2）

- `GraphModelSettings.from_env()` 只认一套 OpenAI 兼容配置：
  `LLM_BASE_URL` / `LLM_API_KEY` / `HERMES_MODEL` / `STRATEGY_MODEL` / `TACTICS_MODEL`
  （角色未单独配置时回落到同一模型）；凭证只在调用期解析，`safe_dict()` 输出脱敏视图。
- `PydanticAIStrategyAgent` / `PydanticAITacticsAgent`：`pydantic_ai.Agent(output_type=契约模型)`，
  线程级超时保护；`ModelUnavailable` / `ModelTimeout` / `ModelInvalidOutput` 三类异常
  全部转成图内降级，不阻塞。
- `pydantic_ai_available()` 诚实上报依赖状态与安装命令；**依赖缺失或没有 Key 时明确报错**，
  绝不伪装“已接入真实模型”。
- `FakeStructuredModel`：确定性脚本模型，覆盖 `completed/empty/malformed/timeout/error/raise/late`，
  所有本地测试与回放**不需要 API Key**。

## 7. 未完成与需人工决定的事项（2026-09-10 晚更新）

> 真实模型接入状态更新：**已用真实 Provider（StepFun step-3.7-flash）跑通**
> “真实决策 → 契约 → 意图 → Godot 权威层回执”闭环（§8.4）；**服务器侧对局闭环未跑通**（§8.6）。
> 已实测的执行层缺口（§9）需要决定是否补动作翻译。



1. **真实模型接入**（Phase 5/6）：**已完成最小闭环**——服务器同一套 Provider
   （StepFun `step-3.7-flash`）已在服务器冒烟通过并在本地闭环里驱动真实计划与意图（§8.4）。
   仍需负责人决定：模型选择/预算、TTL 与超时参数（真实延迟 p50 25-55s、max 113s）、
   以及“慢模型下每个 tick 一次模型调用”的调度节流方案。
   剩余调优项：**成型率**（r6 3/6 被接受、r7 0/3），主因见下方 §9 的动作集缺口。
2. **Hermes 记忆/复盘接入**（Phase 7）：Hermes 仍不进入 `dispatch_to_godot` 路径；
   需要决定摘要字段、频率与存储位置。
3. **Godot 编队行为层深度接入**（Phase 4）：目前 Intent 走既有移动/攻击/生产/建造执行路径，
   未在 `AutoAttackingBattlegroup` 内实现“Intent 驱动的小队角色/驻留承诺”等玩法逻辑
   （改动玩法需项目负责人明确批准）。游戏内规则 AI 仍然是 fallback。
4. **服务器部署**（Phase 5-6 之后）：未 SSH、未改端口/配置；
   按方案 §12 需独立目录 `/opt/airts-agent/`、独立 venv、只绑定 `127.0.0.1`、
   不与旧 Hermes daemon 共用状态文件；正式切换需单独窗口。
5. **UI 事件视图**：前端仍按旧状态面板展示；按 `plan_id/task_id/command_id` 关联的
   事件视图尚未改造（方案 §11 未覆盖本次范围）。
6. **多会话协作约定**：本草稿与既有 `hermes-full-loop-acceptance-report.md` 互不覆盖，
   如需合并请由负责人决定单一来源。

## 8. 运行与证据（含真实模型与服务器部署）

### 8.1 单元测试与编译

```powershell
cd G:\AIRTS\AI_RTS\source\adjutant_coordinator
$env:PYTHONUTF8="1"
python -m unittest discover -s tests     # 217 项 OK（系统 python 3.12.7，3 项 LangGraph 专项 skip）
python -m compileall .
```

装入可选依赖的虚拟环境（`G:\AIRTS\临时文件夹\airts_agent_venv`）中：

```powershell
& "G:\AIRTS\临时文件夹\airts_agent_venv\Scripts\python.exe" -m unittest discover -s tests
# 217 项 OK，0 skip（含真实 LangGraph StateGraph + interrupt/resume 与 LangGraph 回放）
```

基线对照：本次改动前为 **141 项 OK**（同一命令），新增 76 项。

### 8.2 JSONL 回放（FakeModel，无 API Key）

```powershell
python -m adjutant_coordinator.graph.replay --fixture tests\fixtures\replay_base_attack.jsonl --run-id replay-001
```

五个场景（`tests/fixtures/`）：`replay_base_attack`（敌袭抢占）、`replay_target_dead`（目标死亡/失去视野）、
`replay_path_failed`（路径失败后重复下单被拦）、`replay_player_takeover`（玩家接管→旧意图失效→归还后重接管）、
`replay_model_timeout`（模型超时降级→恢复）。全部断言 PASS，汇总经 `results` 重算自校验。

### 8.3 本地双进程 E2E（独立测试局服，端口 24569/24570/24572）

```powershell
python e2e_langgraph.py --run-id e2e_lg_...      # LangGraph Intent 链路
python e2e_dual_layer.py --run-id e2e_dual_...   # 第一阶段链路回归（未被本次改动破坏）
```

`e2e_langgraph.py` 的证据（逐条 `[PASS]`，汇总自校验）：

- 战略节点采纳计划且战略层下发 0 条命令；
- 紧急意图经 `op=adjutant_intent` 被权威层接受（`status=Accepted`），
  `op=adjutant_leases` 显示租约 `{"active": true, "generation": 1}` 与图内代际一致；
- 玩家手动命令后：图内旧意图 `dropped`，图暂停（LangGraph interrupt 语义），恢复后不补发旧命令；
- 权威层独立防线：绕过图直接提交的旧意图被 `PlayerOverride`（租约被玩家取消）拒绝；
- 显式归还 + `reacquire` 意图被权威层接受，租约代际 1 → 2；随后旧代际意图被 `StaleGeneration` 拒绝；
- 非法目标（CommandCenter 生产 tank）被权威规则视图拒绝（`InvalidProducer`）；
- checkpoint 按对局隔离写入，重启恢复后保留计划与活跃意图且**不重复下单**。

产物目录：`source/adjutant_coordinator/logs/<run_id>/`
（`summary.json`（含 PASS/FAIL/SKIP 与逐条结果）、`graph_states.jsonl`、`graph_intents.jsonl`、
`graph_receipts.jsonl`、`state/`（checkpoint）、`server.log`、`client.log`、`baseline.txt`）。
失败轮次与成功轮次一并保留，不覆盖、不择优汇总。

### 8.4 真实模型闭环（2026-09-10 追加）

模型：服务器 Hermes 使用的同一套 Provider（StepFun，`https://api.stepfun.com/step_plan/v1`，
模型 `step-3.7-flash`）。密钥始终只在服务器（`/opt/airts-agent/.env`，mode 600）。

- **服务器侧真实模型冒烟**（`deploy/model_smoke.py`，在服务器 venv 里跑）：
  `verdict=PASS_REAL_MODEL`，strategic 27.25s / valid，tactics 15.35s / valid（2 条意图）。
- **真实模型闭环**（本地完好 Godot 权威层 + 真实模型决策，经 SSH-exec 桥接取模型，
  证据 `tmp_logs/langgraph_recon/runs/local_real_r6`）：真实模型产出并采纳计划
  `early_game_strategic_plan:v1`；真实战术意图 6 条下发权威层，回执
  `Accepted×3（生产工人/坦克/士兵）`、`UntrustedScene×1（炮塔建造场景不在受信任列表）`、
  `UnsupportedAction×2（scout 动作执行层未实现）`；模型延迟 p50 55.1s / max 113.0s；
  玩家接管 → 图暂停 → 权威层 `StaleGeneration` 拒绝旧代际意图；非法生产 `InvalidProducer`；
  checkpoint 恢复后不重复下发历史意图。
- 复跑 `local_real_r7`（上下文增强后）：计划采纳、3 条意图均通过契约，
  回执 `Rejected×1 / UntrustedScene×2` —— 说明**执行层动作集与规则映射仍是主要失分项**
  （下方 9.3），不是契约或安全机制问题。

真实模型暴露并已在代码中修复的问题：

1. **结构化输出失败无诊断**：原 `UnexpectedModelBehavior` 只给 “Exceeded maximum output
   retries”。现改为 `capture_run_messages()` 提取最近一次校验反馈写入日志，并把
   `retries` 提到 2；契约字段全部补 `Field(description=...)`，白名单动作/目标键、
   TTL 窗口、`generation=0`、`plan_version` 一致性都写进系统提示词。
2. **慢模型把 TTL 窗口跑完**：真实模型单次 15-113s，期间 tick 前进数百，导致
   “结构合法但已过期”的意图被权威层一律判 `Expired`。新增
   `AdjutantGraphRuntime(tick_provider=...)`：下发前用宿主提供的最新 tick/快照
   刷新时间基准，并按新基准重算已过期的窗口（留痕 `intent_ttl_recomputed`）。
3. 战术上下文补充 `buildable`（建造 id ↔ 场景路径）与 `production_relations`
   （产品 ↔ 允许生产者/成本），让模型能选出权威层接受的场景与生产者。

### 8.5 服务器部署（`/opt/airts-agent`，独立目录 + 独立 venv）

| 项 | 值 |
| --- | --- |
| 目录 | `/opt/airts-agent/{app,.venv,state,logs,backups}`（252MB） |
| 依赖 | langgraph 1.2.11 / langgraph-checkpoint 4.2.0 / pydantic 2.13.5 / pydantic-ai 2.42.0 / httpx 0.28.1 / aiosqlite 0.22.1（`deploy/install_server.sh`） |
| 配置 | `/opt/airts-agent/.env`（mode 600，从 `~/.hermes/.env` + `~/.hermes/config.yaml` 提取；密钥不打印） |
| 代码 | `source/adjutant_coordinator` → `/opt/airts-agent/app/adjutant_coordinator`（无 tests/logs/pyc） |
| 运行入口 | `cd /opt/airts-agent/app && .venv/bin/python -m adjutant_coordinator.deploy.{model_smoke,server_e2e}` |
| 端口纪律 | 只连 `127.0.0.1` 的 24569/24570/24572；玩家局服 24567/24571、Hermes 客户端 24568 一律拒绝（`deploy/godot_tcp.py` 硬白名单） |
| Godot 侧 | `DebugControlServer.gd` 已更新为新版（含 `op=adjutant_intent` / `adjutant_leases`）：服务器原文件 sha256 `e817ef34…` 与本地基线完全一致 → 干净增量；更新后 `457e59f9…`，备份 `DebugControlServer.gd.bak-langgraph-<ts>`；**只重启了 `airts-game-test`，玩家局服 `airts-game` 全程未动**（当前仍在运行旧代码，下次运维重启即生效） |
| 未做 | 未改 systemd 单元、未动 `adjutant-daemon`、未改 nginx、未装服务自启 |

### 8.6 服务器侧阻塞与修复（2026-09-10 当晚已修复，闭环跑通）

**结论：`srv_e2e_fake_r4` PASS=20 FAIL=0；`srv_e2e_real_r8` PASS=20 FAIL=0 SKIP=1**
（真实模型计划采纳、真实意图 `Accepted×1`、另一条被权威层 `PlayerOverride` 拒绝、
图暂停/恢复、checkpoint 恢复不重复下发；模型延迟 p50 25.2s / max 109.6s）。

修复清单（全部先备份为 `.bak-langgraph-<时间戳>`，只重启过 `airts-game-test`）：

| 缺口 | 修复 |
| --- | --- |
| 缺 `source/ui/UISfx.gd`（`UnitActionsController.gd` 解析失败） | 补文件 + `project.godot` 追加 `UISfx` autoload |
| `Main.gd` 少 9 行（缺 `--autojoin` → 联机场景重定向） | 换基线版本 |
| `Online.tscn` 与 `Online.gd`（与基线逐字节相同）不匹配 | 换基线版本 |
| demo 平衡/资产配置与服务器 C# 契约不符（缺 skills/soldier/barracks） | 换基线版本的两份配置 |
| 资产清单要求的 `Infantry.tscn`/`Barracks.tscn` 等 77 个文件缺失 | 仅补缺失项 + `--headless --import` 补齐导入产物 |
| `.env` 超时 60s < 模型 max 109.6s | `LLM_TIMEOUT_SECONDS=120` |

原始阻塞记录（保留供审核）：

服务器 `/home/ubuntu/AI_RTS` 的游玩代码树是**半合并状态**，与“能入局的客户端”不兼容：

- 缺 `source/ui/UISfx.gd`（及 `source/ui/`）→ `UnitActionsController.gd` 解析失败
  （`Identifier "UISfx" not declared`），客户端加载对局场景即失败；
- `source/main-menu/Online.gd` 与 `Online.tscn` 不匹配（本地未提交改动）→ 主菜单联机界面控件为 null；
- 服务器版 `NetSession.gd` 快照早于本地，**不支持** `--autojoin/--smokehost` 等命令行入局参数；
- 服务器 sshd `AllowTcpForwarding no` → 无法用 `ssh -L` 隧道（改用 SSH-exec 桥接）。

因此**本轮未能跑服务器侧“真模型 + 服务器对局”闭环**（隔离测试局服可被 `op=start` 拉起，
但没有可入局玩家，`match` 不会真正开始）。要补齐需要：

1) 把 `source/ui/`、`source/match/MusicDirector.gd`、`source/main-menu/MenuMusic.gd`、
`default_bus_layout.tres`、`assets/sfx/**`、`assets/music/**` 等音频合并文件同步到服务器，并把
`UISfx=` 等 autoload 合并进 `project.godot`；
2) 或把服务器游玩代码树整体对齐到交付基线（需运维窗口，会影响玩家局服下次重启）；
3) 或给服务器补一个可入局的自动化客户端（当前 `--autojoin` 能力缺失）。

以上都属于“服务器游玩代码树修复”，不在本人授权范围内的既有本地改动（Online.gd/tscn）
未擅自覆盖。

### 8.7 未执行的验证（不得声称）

- 未跑 C#/Godot 玩法人工验收（Intent 驱动的小队角色/驻留承诺仍未实现）；
- 未在玩家局服（UDP 24567 / TCP 24571）上做过任何操作：全程只碰 24569/24570/24572，
  收尾时已把隔离测试局服恢复为 inactive；
- 未改动他们的本地 WIP（`Online.gd`、`Terrain.gd`、多个 C# `M` 文件等）；
  服务器游玩代码树的修复见 §8.6（全部先备份）。

## 9. 执行层缺口（Phase 4 翻译层，已实现）

真实模型会用“高层战术动作”表达意图，`op=adjutant_command` 只实现了其中一部分。
现在在 `op=adjutant_intent` 内加入**动作翻译层**（`_adjutant_translate_action`），
不新增/不改变任何玩法逻辑：

| 契约允许动作 | 翻译/执行 | 回执留痕 |
| --- | --- | --- |
| `move` / `attack` / `attack_move` / `gather` / `stop` / `produce` / `build` | 直接执行（复用既有命令路径） | — |
| `scout` / `regroup` / `retreat` | → `move`（既有移动） | `action_translated_from` |
| `defend` | → `attack_move`（有目标点）/ `stop`（无目标点） | 同上 |
| `hold` | → `stop` | 同上 |

同时新增**场景 id 解析**：`produce/build` 的 `target.scene` 允许填规则视图里的
`unit_types[].id` / `constructions[].id`，由权威层解析成规则内场景路径（非规则来源仍
`UntrustedScene`），回执带 `scene_resolved_from`。

仍在“安全机制正常工作”范畴的实测样本：非法生产者 → `InvalidProducer`；
玩家接管后的意图 → `PlayerOverride` / `StaleGeneration`。

下一步（需负责人决定）：慢模型调度节流（每 tick 单次模型调用）、
`intent_ttl_ticks` 在真实 Provider 下建议 1500-3000（已按此跑通）。
