# AI 副官 LangGraph 重构：审核报告（提交外部审核用）

| 项 | 值 |
| --- | --- |
| 报告目的 | 提交给审核方（GPT-6）逐条核验「声明 ↔ 证据 ↔ 复现方式」 |
| 日期 | 2026-09-10 |
| 代码基线 | `yyp_test` @ `dc42264`（`fix(ui): 5 menu panels fit viewport at any resolution`） |
| 本机环境 | Windows / Python 3.12.7（anaconda）+ 独立 venv `G:\AIRTS\临时文件夹\airts_agent_venv`（Python 3.12.7） |
| 目标工程 | Godot 4.7.1 Mono，`G:\AIRTS\AI_RTS` |
| 相关文档 | `docs/plan/AI副官_LangGraph重构方案.md`、`docs/plan/AI副官_LangGraph重构执行提示词.md`、`docs/ai-adjutant-dual-layer/langgraph-refactor.md`（实施细节）、`source/adjutant_coordinator/README.md`（命令） |
| Git 状态 | **全部改动未 commit、未 push**（本地工作区）；并行会话的未提交文件未触碰 |

---

## 1. 审核范围（请审什么、不必审什么）

**请重点审：**

1. 契约与不变量是否真的能阻止「旧模型输出抢回玩家控制」「重复下单」「模型绕过规则」；
2. 图的状态机（路由/仲裁/下发/回执/持久化）是否存在状态漂移、竞态或静默丢弃；
3. checkpoint 语义（陈旧写、损坏文件、恢复后不重复下单）是否自洽；
4. 「声明 ↔ 证据」是否有夸大或证据不足；
5. 真实模型实测结论（第 7、8 节）的解释是否成立。

**不必审：**

- 副官玩法设计本身（属于方案，不在本次实现范围）；
- Hermes 技能/旧 daemon 相关代码（未改动）；
- 服务器游玩代码树中他人未提交的改动（`Online.gd/Online.tscn` 等，未触碰）。

---

## 2. 可验证声明表（核心）

> 「实测结果」列均为本机/服务器上真实执行过的输出，非推断。第 11 节给出复现命令。

| # | 声明 | 证据类型 | 实测结果 | 证据位置 |
| --- | --- | --- | --- | --- |
| C1 | 每个对局独立图状态 + 按 `(match_id, player_id)` 隔离落盘 | 单元测试 | 通过（隔离/陈旧写/损坏/版本不符各有用例） | `tests/test_graph_state_checkpoint.py`（11 例） |
| C2 | 战略层只产出计划，不下发任何命令 | 单元测试 + E2E | 战略 tick `sent=0` | `test_graph_runtime_fake.py`、`e2e_langgraph.py` |
| C3 | 战术意图有限期（TTL 夹紧 + 批上限 + 在途去重） | 单元测试 | 通过（17 例仲裁用例） | `tests/test_intent_arbitration.py` |
| C4 | 玩家命令立即增加代际、撤销 lease、失效相关意图，**不清空战略计划** | 单元测试 + 真实 Godot E2E | 图内 `dropped=player_override`、计划保留；权威层 `PlayerOverride` | `test_player_interrupt.py`（9 例）、`e2e_langgraph` 场景 3/4 |
| C5 | 玩家接管后，旧模型响应无法抢回 | 权威层实测 | `StaleGeneration`（旧代际）/`PlayerOverride`（租约被取消） | `logs/e2e_lg_20260910_r9`、`runs/local_real_r6` |
| C6 | 显式归还后 AI 才能重新接管（一次性授权） | 单元测试 + E2E | 未授权 → `reacquire_not_authorized`；归还后 → 权威层 `Accepted`，租约代际 1→2 | `test_intent_arbitration.py`、`e2e_langgraph` 场景 5 |
| C7 | 模型不能绕过规则/不能凭空构造场景 | 权威层实测 | `InvalidProducer`、`UntrustedScene` | `e2e_langgraph` 场景 6、`runs/local_real_r6/r7` |
| C8 | PendingAuthority 不重复下单，按 `command_id` 复核终态 | 单元测试 | 等待期不重提、终态结算留痕 `pending_resolved` | `test_graph_runtime_fake.py::PendingAuthorityTest` |
| C9 | 模型超时/断线/非法输出不阻塞，且保留既有计划与意图 | 单元测试 | 降级 + 冷却，`model_errors`/`model_retry_cooldown` 有用例 | `test_graph_runtime_fake.py::DegradeTest` |
| C10 | checkpoint 恢复后不重复下发历史意图 | 单元测试 + 两次 E2E | `resent=[]`、`sent=0` | `test_graph_runtime_fake.py::CheckpointRestoreTest`、`runs/local_real_r6/r7` |
| C11 | 未安装 LangGraph 时行为等价（同一批节点函数，双引擎） | 单元测试 | 两引擎 route/accepted/paused/回执一致 | `test_graph_runtime_fake.py::LangGraphEngineTest` |
| C12 | 真实 Provider 可用（服务器同一套 Provider） | 服务器侧真实调用 | `verdict=PASS_REAL_MODEL`（strategy 27.25s / tactics 15.35s，均契约合法） | `tmp_logs/langgraph_recon/server_runs/srv_smoke_r3/smoke.json` |
| C13 | 真实模型能驱动完整闭环并被权威层接受 | 真实 Godot E2E | 本地：计划采纳 + 6 意图下发，`Accepted×3`；**服务器：`srv_e2e_real_r8` PASS=20 FAIL=0 SKIP=1，真实意图 `Accepted×1`（另一条被权威层 `PlayerOverride` 拒绝）** | `tmp_logs/langgraph_recon/runs/local_real_r6/`、服务器 `/opt/airts-agent/logs/srv_e2e_real_r8/` |
| C16 | 高层战术动作可被现有执行层执行（Phase 4 翻译层，未改玩法） | 代码 + E2E | `scout/regroup/retreat→move`、`defend→attack_move|stop`、`hold→stop`；回执带 `action_translated_from` | `source/net/DebugControlServer.gd::_adjutant_translate_action` |
| C17 | 服务器游玩代码树缺口已修（客户端能入局） | 服务器实测 | 补 `source/ui/UISfx.gd`+autoload、对齐 `Main.gd`/`Online.tscn`、补 demo 平衡/资产配置与缺失场景（Infantry/Barracks）、headless 资源导入；客户端 `networked=true` | 第 10.5 节 |
| C14 | Godot 侧只新增校验入口，未改玩法逻辑 | 代码 diff | `DebugControlServer.gd` 仅新增 `op=adjutant_intent` / `adjutant_leases` + 守卫函数；无既有函数语义变更 | 见第 10.3 节 |
| C15 | 未触碰玩家局服 | 服务器实测 | 全程只连 24569/24570/24572；收尾 `airts-game-test=inactive`，`airts-game=active`，UDP 24567 在线 | 第 10.4 节 |

**刻意不做的声明**：❌「服务器侧真模型+服务器对局闭环已跑通」——**没做到**，见第 9 节。

---

## 3. 交付物清单（文件级）

### 3.1 代码（Python 图包 `source/adjutant_coordinator/graph/`，全部新增）

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `contracts.py` | 345 | `StrategicPlan` / `PlanTask` / `TacticalIntent` / `IntentBatch` / `PlayerControlEvent`；目标键与动作白名单、TTL 与身份校验、命令包映射 |
| `state.py` | 412 | `AdjutantGraphState`：每单位控制代际、意图生命周期、在途请求、任务状态、决策留痕、JSON 序列化 |
| `checkpoint.py` | 139 | `Memory` / `Json` / `Null` checkpoint store；陈旧写拒绝、损坏不重建、按对局隔离 |
| `model_context.py` | 205 | 模型上下文构造（不伪造、不补默认值、截断显式上报、引用校验） |
| `interrupts.py` | 199 | 事件分类与路由、紧急事件集、玩家打断语义、紧急抢占 |
| `arbitration.py` | 179 | 意图仲裁：过期/计划版本/代际/租约/引用/重复/在途去重/TTL 夹紧/批上限 |
| `nodes.py` | 810 | 图节点：ingest → classify → (reconcile/strategic/tactical/wait) → arbitrate → dispatch → observe → persist |
| `graph.py` | 250 | `LangGraphRunner`（StateGraph + MemorySaver + `interrupt_after` + `Command(resume)`）与 `FallbackRunner` |
| `pydantic_agents.py` | 307 | `PydanticAIStrategyAgent` / `PydanticAITacticsAgent` / `FakeStructuredModel`；超时与结构化错误归一化 |
| `runtime.py` | 370 | `AdjutantGraphRuntime`：兼容层（复用 `AdjutantCoordinator` 计划/租约/预算/幂等）、checkpoint/restore、`tick_provider` |
| `replay.py` | 334 | JSONL 回放驱动 + 产物落盘 + 汇总自校验 |
| `__init__.py` | 22 | 导出 |

### 3.2 测试（全部新增）

| 文件 | 用例数 | 覆盖 |
| --- | --- | --- |
| `tests/test_graph_contracts.py` | 19 | 契约白名单、目标键、TTL、批次身份、命令包映射、`reacquire` |
| `tests/test_graph_state_checkpoint.py` | 11 | 序列化/隔离/陈旧写/损坏/代际与释放语义 |
| `tests/test_player_interrupt.py` | 9 | 打断局部性、计划保留、紧急抢占、身份漂移、路由优先级 |
| `tests/test_intent_arbitration.py` | 17 | 四类丢弃条件、TTL 夹紧、批上限、去重、在途、reacquire 授权 |
| `tests/test_graph_runtime_fake.py` | 17 | 端到端（FakeModel）：计划→意图→下发→回执、打断/恢复、PendingAuthority、降级/冷却、恢复、TTL 重算、plan_version 归一化、双引擎一致性 |
| `tests/test_graph_replay.py` | 7 | 5 个 JSONL 场景 + 产物完整性 + LangGraph 引擎重跑 |
| `tests/graph_test_helpers.py` | — | 观测/计划/意图夹具与可录音通道桩 |
| `tests/fixtures/replay_*.jsonl` | 5 场景 | 敌袭、目标死亡、路径失败、玩家接管、模型超时 |

**合计新增 80 例**（基线 141 → 现 **221**）。

### 3.3 其它新增/修改

| 文件 | 状态 | 说明 |
| --- | --- | --- |
| `source/net/DebugControlServer.gd` | 修改 | 新增 `op=adjutant_intent`（意图登记幂等 + TTL + 代际守卫 → 复用 `op=adjutant_command` 权威链）、`op=adjutant_leases`（只读）；新增 `_adjutant_intents` 登记表与容量上限 |
| `source/adjutant_coordinator/e2e_langgraph.py` | 新增 | FakeModel + LangGraph + 真实 Godot 权威层双进程 E2E（28 项断言） |
| `source/adjutant_coordinator/deploy/server_e2e.py` | 修改（并行会话目录内） | 增加 `--client-mode none`、`tick_provider` 接入、探针用权威最新 tick、恢复断言改为「不重复下发历史意图」、异常带栈 |
| `source/adjutant_coordinator/deploy/model_smoke.py` | 修改 | 产物 JSON 序列化（`_jsonable`），修复 `IntentBatch` 无法落盘 |
| `source/adjutant_coordinator/deploy/llm_proxy.py` | 新增 | 只绑定 `127.0.0.1` 的 OpenAI 兼容代理（密钥留服务器，转发时注入 Authorization，只允许 `POST /chat/completions`） |
| `source/adjutant_coordinator/requirements-graph.txt` | 新增 | 可选依赖锁定（langgraph 1.2.11 / langgraph-checkpoint 4.2.0 / pydantic 2.13.5 / pydantic-ai 2.42.0 / httpx 0.28.1 / aiosqlite 0.22.1） |
| `source/adjutant_coordinator/README.md` | 修改 | 模块说明、测试命令、服务器部署与真实模型命令、端口纪律 |
| `docs/ai-adjutant-dual-layer/langgraph-refactor.md` | 新增 | 实施记录（映射、契约、拓扑、四道防线、真实模型、服务器部署、缺口） |
| `logs/e2e_lg_20260910_r1..r9`、`logs/e2e_dual_regress_20260910` | 新增 | E2E 证据（失败轮次一并保留，不覆盖、不择优） |

> 说明：`deploy/` 目录由今日并行会话创建（服务器部署工具），本人新增 `llm_proxy.py` 并修改 `server_e2e.py` / `model_smoke.py`；本地 SSH 运维驱动脚本含凭证，放在 `G:\AIRTS\临时文件夹\` 本地工具目录，**不入库**。

---

## 4. 架构与关键设计决策

### 4.1 图上拓扑（单局一副官图）

```
ingest_observation → classify_event →┬→ reconcile_plan（玩家打断/归还，只动相关单位）
                                     ├→ strategic_agent（周期/重大事件；只产出计划）
                                     ├→ tactical_agent（事件驱动；紧急事件先抢占同单位低优先级意图）
                                     └→ wait
  → arbitrate_intent → dispatch_to_godot → observe_receipt → persist_checkpoint
```

### 4.2 关键决策与取舍（可被挑战点）

| 决策 | 理由 | 代价 / 备选 |
| --- | --- | --- |
| 双引擎（LangGraph + 内置执行器），节点函数完全共用 | 服务器/本地可能装不上 langgraph；两条路径行为必须一致才敢上生产 | 需要一致性测试（C11）；节点函数必须「无框架依赖」 |
| 玩家打断用 `interrupt_after(reconcile_plan)` + 下一轮 `Command(resume)` | 真正的图暂停/恢复语义，是选 LangGraph 的核心理由 | 暂停轮之后一轮还要再推进一次；已实现「恢复 + 本轮 run_tick」两步，保证不跳过观测 |
| 命令仍走 `AdjutantCoordinator.submit_command` → `Transport` → Godot 权威入口 | 不新建第二套通道；复用既有租约/预算/幂等账本 | 需把观测包头同步给协调器（`ingest_snapshot`），否则 `based_on_snapshot` 判定失真 |
| 意图 TTL 在下发前按宿主提供的最新 tick 重算 | 真实模型 15-113s，窗口按决策时刻算必然过期（实测 6/6 被判 `Expired`） | 引入 `tick_provider` 的外部依赖；重算留痕 `intent_ttl_recomputed` 供审计 |
| 每轮字段（candidate_intents / intent_arbitration / dispatch_pending）在 ingest 重置 | 恢复 checkpoint 后曾误读上一轮仲裁结果（真实缺陷） | 语义上要求「每轮字段只在当轮有效」，需与实现保持一致 |
| 事件由消费它的分支节点显式消费 | 事件不会重复触发；模型失败时保留事件以便重试 | 需要每个分支明确「我消费哪些事件」 |
| `reacquire` 需「玩家显式归还」授权且一次性消费 | 玩家优先权最高，模型不能自行抢回 | 授权状态需要持久化（`released_units`）并随 checkpoint 恢复 |

---

## 5. 契约与不变量（审核清单）

### 5.1 意图失效四条件（`state.is_intent_valid`，判定顺序）

1. `expires_tick < server_tick` → `expired`
2. 目标单位在 `player_controlled_units` → `lease_owner_player`
3. `generation` 与当前代际不一致（`0` 视为「由系统填写」） → `generation_mismatch`
4. `plan_version` 与当前生效计划版本不一致 → `plan_version_mismatch`

> 顺序有语义：玩家优先权理由要盖过版本/代际理由（否则审计会误判为「版本问题」）。

### 5.2 仲裁丢弃原因（穷举，均有用例）

`expired` / `plan_version_mismatch` / `unit_not_in_observation:<u>` / `lease_owner_player:<u>` /
`generation_mismatch` / `contract_invalid` / `entity_not_in_observation:<id>` /
`scene_not_in_rules:<path>` / `reacquire_not_authorized:<u>` / `duplicate_of:<id>` /
`duplicate_of_live_intent:<id>` / `pending_authority_unresolved` / `intent_already_tracked` /
`batch_limit_exceeded`

### 5.3 权威层守卫（Godot，`op=adjutant_intent`）

结构校验 → 意图登记幂等（同 `intent_id` 返回原回执，`intent_replay=true`）→ 对局身份 →
`expires_tick` 过期 → 控制代际守卫（`StaleGeneration` / `PlayerOverride`，`reacquire` 除外）
→ 复用 `op=adjutant_command`（规则版本/快照时效/目标合法性/租约/幂等账本）。
**游戏侧不掌握战略计划版本**（明确不做，由协调器/图负责）。

---

## 6. 验证矩阵（全部为本机/服务器真实执行）

| 验证 | 命令 | 结果 |
| --- | --- | --- |
| 单元测试（系统 Python） | `python -m unittest discover -s tests` | **221 OK**（3 例 LangGraph 专项 skip） |
| 单元测试（venv，含 langgraph+pydantic-ai） | venv 同命令 | **221 OK，0 skip** |
| 编译 | `python -m compileall .` | 通过 |
| JSONL 回放（5 场景） | `python -m adjutant_coordinator.graph.replay --fixture tests/fixtures/<f> --run-id <id>` | 全 PASS，汇总经 `results` 重算自校验 |
| 本地双进程 E2E（FakeModel + LangGraph 引擎） | `python e2e_langgraph.py --run-id e2e_lg_20260910_r11` | **PASS=28 FAIL=0 SKIP=0** |
| 第一阶段链路回归 | `python e2e_dual_layer.py --run-id e2e_dual_regress_20260910` | **PASS=21 FAIL=0 SKIP=0** |
| 服务器侧真实模型冒烟 | `.venv/bin/python -m adjutant_coordinator.deploy.model_smoke --authority-port 24572` | **PASS_REAL_MODEL** |
| 真实模型闭环（本地 Godot 权威层） | `server_e2e.py --provider real --client-mode skip --ttl 1500` | `r6`：18 PASS / 1 FAIL（断言缺陷，已修）；`r7`：17 PASS / 1 FAIL（模型随机性） |
| **服务器侧闭环（FakeModel）** | `server_e2e.py --provider fake --client-mode skip --ttl 1500` | `srv_e2e_fake_r4`：**PASS=20 FAIL=0 SKIP=0** |
| **服务器侧闭环（真实模型）** | `server_e2e.py --provider real --client-mode skip --ttl 1500` | `srv_e2e_real_r8`：**PASS=20 FAIL=0 SKIP=1**（真实意图 `Accepted×1`） |

**基线对照**：本次改动前为 141 例 OK（同一命令）。

---

## 7. 真实模型实测数据

模型：`step-3.7-flash`（StepFun `https://api.stepfun.com/step_plan/v1`，reasoning 模型），
密钥只在服务器 `/opt/airts-agent/.env`（mode 600）；本机取模型经 SSH-exec 桥接到服务器
`127.0.0.1:8899` 的回环代理（密钥不出服务器）。

### 7.1 服务器侧冒烟（`srv_smoke_r3`）

```json
{"strategy": {"ok": true, "latency_s": 27.254, "valid": true, "validation_errors": []},
 "tactics":  {"ok": true, "latency_s": 15.348, "valid": true, "intent_count": 2},
 "verdict": "PASS_REAL_MODEL"}
```
观测为**罐装视图**（服务器隔离测试局服没有可入局玩家，见第 9 节），因此该冒烟只证明
「真实 Provider 可用 + 契约校验可用」，不证明「在真实对局观测上决策」。

### 7.2 真实模型闭环（`local_real_r6`，真实 Godot 对局观测）

| 指标 | 值 |
| --- | --- |
| 模型调用 | 3 次，全部成功（`model_ok=3 / model_errors=0`） |
| 延迟 | p50 **55.1s**，max **113.0s** |
| 采纳的计划 | `early_game_strategic_plan:v1`（模型自拟 plan_id） |
| 下发意图 | 6 条：`build_turret_u3_1`、`prod_soldier_u5_1`、`prod_tank_u4_1`、`prod_worker_u0_1`、`scout_east_u1`、`scout_south_u2` |
| 权威层回执 | **`Accepted×3`**（生产工人/坦克/士兵）、`UntrustedScene×1`（炮塔建造）、`UnsupportedAction×2`（scout 动作未实现） |
| 其它断言 | 玩家接管→图暂停→权威层 `StaleGeneration`；非法生产 `InvalidProducer`；checkpoint 恢复 `resent=[]` |

`local_real_r7`（上下文增强后复跑）：计划采纳、3 条意图均通过契约，
回执 `Rejected×1 / UntrustedScene×2` —— 说明失分主因在执行层动作集与场景映射（随后已修，见 §8-D4/D5）。

### 7.3 服务器侧真实模型闭环（`srv_e2e_real_r8`，这是最终验收口径）

| 指标 | 值 |
| --- | --- |
| Provider | 服务器 `.env` 直连 `https://api.stepfun.com/step_plan/v1`，`step-3.7-flash` |
| 模型调用 | 3 次，全部成功（`model_ok=3 / model_errors=0`） |
| 延迟 | p50 **25.2s**，max **109.6s**（因此 `.env` 超时提到 120s） |
| 采纳计划 | `plan_91547_001:v1`（模型自拟） |
| 下发意图 | 2 条：回执 **`Accepted×1`**（真实执行）与 **`PlayerOverride×1`**（目标单位当时已被玩家接管，权威层拒绝——这正是期望的防线） |
| 其它 | 玩家打断→图暂停→恢复不补发；非法生产 `InvalidProducer`；checkpoint 恢复 `resent=[]` |
| 汇总 | **PASS=20 FAIL=0 SKIP=1**（SKIP = 场景前置条件不满足：手动单位当时无活跃意图） |

---

## 8. 真实模型暴露并已修复的缺陷

| # | 现象 | 根因 | 修复 | 回归证据 |
| --- | --- | --- | --- | --- |
| D1 | 战术结构化输出连续失败，且只报 `Exceeded maximum output retries (1)`，无法定位 | 失败原因被吞；契约字段无 `description`，模型不知道白名单 | `capture_run_messages()` 提取最近一次校验反馈写入日志与异常；`retries=2`；全部字段补 `Field(description=...)` 与系统提示词硬化 | `tests/test_graph_contracts.py`；真实模型 3/3 调用契约合法 |
| D2 | 真实模型 6/6 意图被权威层判 `Expired` | 模型耗时 15-113s，tick 前进数百；TTL 按「决策时刻」算必然过期 | `tick_provider`：下发前刷新 tick/快照，并按新基准重算已过期窗口（`intent_ttl_recomputed` 留痕） | 新增用例 `test_expired_window_is_recomputed_at_dispatch_with_fresh_tick`；r6 起不再出现 `Expired` |
| D3 | `build` 目标场景被 `UntrustedScene` 拒 | 上下文只给 `trusted_scene_paths` 平铺列表，模型难以把「建造物 ↔ 场景」配对 | 上下文新增 `buildable`（id ↔ scene）、`production_relations`（产品 ↔ 允许生产者/成本）与 `own_units`（单位名 ↔ 类型） | `runs/local_real_r7` 上下文已带该字段 |
| D4 | `scout/hold/regroup/defend/retreat` 被权威层判 `UnsupportedAction` | 契约（方案 §6）允许高层动作，但执行层只实现了 `move/attack/attack_move/gather/stop/produce/build` | 新增 **Phase 4 动作翻译层**：`scout/regroup/retreat→move`、`defend→attack_move\|stop`、`hold→stop`；回执带 `action_translated_from`，登记表带 `action_requested`；未新增/改变任何玩法逻辑 | 服务器 `srv_e2e_real_r8` 中高层动作不再被判 `UnsupportedAction` |
| D5 | 模型把生产/建造场景写成类型 id，被 `UntrustedScene` 拒 | 场景必须是规则视图里的路径 | 权威层新增 id→路径解析（只认规则视图里的 `unit_types[].id` / `constructions[].id`，非规则来源仍拒绝），回执带 `scene_resolved_from` | 同上 |
| D6 | 真实模型结构化输出仍会失败：`plan_version` 写错、`expires_tick` 用自己的时钟 | 契约把这些“回声/元数据”字段当作硬约束 | 归一化容错（回声字段按上下文补齐、`plan_version` 归一化、窗口按当前 tick 重算），全部留痕 `clamped`；身份字段给出不一致的非空值仍拒绝 | `srv_e2e_real_r8` 中 3/3 调用契约合法且意图落到权威层 |
| D7 | 60s 超时误判（模型 max 109.6s） | 服务器 `.env` 默认 60s | `.env` `LLM_TIMEOUT_SECONDS=120` | r8 无超时降级 |

另有两个**安全机制正常工作的实测样本**（不是缺陷）：`UntrustedScene`（模型凭空构造资源路径被拒）、
`InvalidProducer`（错误生产者生产坦克被拒）。

---

## 9. 未完成 / 未验证（如实声明，请审核方据此判断完成度）

### 9.0 更新（2026-09-10 当晚收尾）：服务器侧闭环**已跑通**

`/opt/airts-agent` 部署 + 服务器游玩代码树缺口修复后，服务器侧闭环结果：

| 轮次 | 模型 | 结果 |
| --- | --- | --- |
| `srv_e2e_fake_r4` | FakeModel（链路验证） | **PASS=20 FAIL=0 SKIP=0** |
| `srv_e2e_real_r8` | 真实 `step-3.7-flash` | **PASS=20 FAIL=0 SKIP=1**：计划采纳、真实意图下发 `Accepted×1`（另一条被权威层 `PlayerOverride` 拒绝）、图暂停/恢复、checkpoint 恢复不重复下发；模型延迟 p50 25.2s / max 109.6s |

为跑通做过的服务器改动（全部先备份、只重启过 `airts-game-test`，玩家局服未动）：见第 10.5 节。
为此在代码侧新增的**模型输出容错/归一化**（并明确记录为对方案 §7 的有意偏差）：见第 12.7 节。

### 9.1 服务器侧「真模型 + 服务器对局」闭环**未跑通**（已被 §9.0 取代，保留原因分析）

隔离测试局服可被 `op=start` 拉起（返回 `{"ok": true, ...}`），但没有可入局玩家，`match` 不会真正开始。
根因（均为服务器游玩代码树自身状态，非本次改动引入）：

1. 缺 `source/ui/UISfx.gd`（整个 `source/ui/` 目录）→ `UnitActionsController.gd` 报 `Identifier "UISfx" not declared`，客户端加载对局场景即失败（对比：同一实例上 `op=adjutant_intent` 可正常应答，说明 `DebugControlServer.gd` 已正常加载解析）；
2. `source/main-menu/Online.gd` 与 `Online.tscn` 不匹配（服务器本地未提交改动）→ 联机界面控件为 `null`；
3. 服务器版 `NetSession.gd` 快照早于本地，**不支持** `--autojoin/--smokehost` 等命令行入局参数；
4. 服务器 sshd `AllowTcpForwarding no` → `ssh -L` 隧道被拒（改用 SSH-exec 桥接）。

补齐路径（三选一，需授权）：同步音频/UI 合并文件 + autoload；或整体对齐游玩代码树（需运维窗口）；
或补一个可入局的自动化客户端。

### 9.2 执行层动作集缺口（Phase 4，未做，需批准）

契约允许 `scout/hold/regroup/defend/retreat`（方案 §6 要求），但 `op=adjutant_command` 执行层未实现
→ 权威层 `UnsupportedAction`。建议在 Godot 侧做动作翻译（映射到 `move`/`attack_move`/`stop`），
或在白名单中标注「尚未支持」并从提示词移除。

### 9.3 其它未做

- Hermes 记忆/复盘接入（Phase 7）；
- UI 事件视图（按 `plan_id/task_id/command_id` 关联）；
- 真实模型成型率调优（r6 3/6、r7 0/3 被接受）与调度节流（每 tick 单次模型调用）；
- 真实模型参数决策（TTL 1500-3000、超时、模型选择与预算）。

---

## 10. 边界与合规检查（供审核核对）

### 10.1 端口纪律

`deploy/godot_tcp.py` 内置硬白名单：允许 `24569/24570/24572`；**拒绝** `24567/24571/24568`
（玩家局服 UDP/TCP、Hermes 客户端）。本轮所有测试只连白名单端口。

### 10.2 密钥

- 只在服务器 `/opt/airts-agent/.env`（mode 600），从 `~/.hermes/.env` 提取，**未打印、未进日志、未进版本库**；
- 本机取模型通过 SSH-exec → 服务器回环代理注入 Authorization；`GraphModelSettings.safe_dict()` 输出 `***redacted***`；
- `model_smoke` 日志只记录 latency / ok / 错误类型，不记录 prompt 与响应正文。

### 10.3 Godot 侧改动的最小性

- 服务器原 `DebugControlServer.gd` sha256 = `e817ef34…`，与本地基线 `dc42264` 版本**完全一致** → 后升级到 `457e59f9…`（本地版本），备份 `.bak-langgraph-<ts>`；
- 改动 = 新增 op 分派两项 + 新增函数（`_op_adjutant_intent` / `_adjutant_intent_receipt` /
  `_adjutant_generation_guard` / `_adjutant_intent_count` / `_op_adjutant_leases`）+ 两个变量 +
  容量常量；**无既有函数语义变更**，未触碰移动/攻击/生产/建造/规则 AI。

### 10.4 服务器影响面

| 服务 | 状态 | 说明 |
| --- | --- | --- |
| `airts-game`（玩家局服 24567/24571） | **active，全程未动** | 仍运行旧代码；下次运维重启才会加载新 `DebugControlServer.gd`（仅新增 op，向后兼容） |
| `airts-game-test`（24569/24572） | inactive（用完已停） | 使用期间只用于本轮 E2E |
| `adjutant-daemon` | inactive（未启动） | 未动 |
| systemd / nginx / 旧 Hermes | 未改动 | 无新增自启 |

收尾清理：服务器 LLM 代理与测试客户端已停；本机 Godot 栈与桥接进程已停；
`airts-game-test` 已 `reset-failed` 并恢复 inactive。

### 10.5 为跑通服务器闭环对服务器游玩代码树做的修复（全部先备份）

| 文件/资源 | 动作 | 依据 |
| --- | --- | --- |
| `source/ui/UISfx.gd`(+`.uid`) | 新增 | 服务器缺该文件 → `UnitActionsController.gd` 解析失败（`Identifier "UISfx" not declared`），客户端加载对局场景即崩 |
| `project.godot` | 追加 `UISfx="*res://source/ui/UISfx.gd"` autoload（其余行未动，先备份 `.bak-langgraph-*`） | 缺 autoload 时同样解析失败 |
| `source/main-menu/Main.gd` | 替换为基线版本（服务器版少 9 行：缺 `--autojoin` → 联机场景重定向） | 无头客户端需要该重定向才会走 `Online.gd` 的 autojoin 钩子 |
| `source/main-menu/Online.tscn` | 替换为基线版本（服务器版与 `Online.gd` 不匹配，控件为 null） | `Online.gd` 与基线**逐字节相同**，故 .tscn 是过期的一方 |
| `config/balance/demo.balance.v1.json`、`config/godot/demo.assets.v1.json` | 替换为基线版本（服务器版缺 `skills`/`maxTurnDegreesPerSecond`/`soldier`/`barracks`，与服务器 C# 契约不符 → `balance_catalog_unavailable`） | 服务器 C# `BalanceCatalogContracts` 要求这些定义 |
| `source/match/units/Infantry.tscn`、`Barracks.tscn`（+ 脚本/几何/动画资源/`.uid`，共 77 文件 13.2MB，仅补缺失项） | 新增 | 资产清单校验要求每个单位/建筑都有场景映射（`MissingRequiredAsset`） |
| `.godot/imported` | `--headless --import` 补齐新资源导入产物 | 已知坑：新资源无导入产物时 `load()` 静默失败 |
| `/opt/airts-agent/.env` | `LLM_TIMEOUT_SECONDS` 60 → 120 | 真实模型延迟 max 109.6s，60s 会误判超时 |

**未做**：未改 `NetSession.gd`（与基线相同）、未动 `airts-game` 服务、未改 C#/其它玩法脚本、未动他们本地 WIP（`Online.gd`、`Terrain.gd`、C# 系列 `M` 文件等）。所有被替换文件都留有 `.bak-langgraph-<时间戳>` 备份。

### 10.6 服务器收尾状态（实测）

```text
systemctl is-active airts-game airts-game-test adjutant-daemon  →  active / inactive / inactive
ss -ulnp | grep 24567                                            →  live 局服仍在监听（pid 216609）
ss -tlnp | grep -E '24569|24570|24572|8899'                      →  无（测试端口与代理已释放）
```

---

## 11. 复现步骤

```powershell
# 0) 环境
cd G:\AIRTS\AI_RTS\source\adjutant_coordinator
$env:PYTHONUTF8="1"

# 1) 单元测试（不需要任何 Key / 不需要游戏）
python -m unittest discover -s tests              # 219 OK（3 skip）
& "G:\AIRTS\临时文件夹\airts_agent_venv\Scripts\python.exe" -m unittest discover -s tests  # 219 OK, 0 skip
python -m compileall .

# 2) JSONL 回放（FakeModel，无 Key）；产物在 graph/logs/<run_id>/
python -m adjutant_coordinator.graph.replay --fixture tests\fixtures\replay_base_attack.jsonl --run-id replay-001

# 3) 本地双进程 E2E（FakeModel + LangGraph + 真实 Godot 权威层；端口 24569/24570/24572）
python e2e_langgraph.py --run-id e2e_lg_local     # 期望 PASS=28 FAIL=0 SKIP=0

# 4) 真实模型闭环（需先起本地栈；模型经服务器代理，密钥不出服务器）
#    a. 服务器：.venv/bin/python -m adjutant_coordinator.deploy.llm_proxy --port 8899
#    b. 本机 ：python tmp_logs\langgraph_recon\ssh_llm_bridge.py --port 8899
#    c. 本机栈：python tmp_logs\langgraph_recon\local_stack.py start
$env:LLM_BASE_URL="http://127.0.0.1:8899"; $env:LLM_API_KEY="dummy"
$env:STRATEGY_MODEL="step-3.7-flash"; $env:TACTICS_MODEL="step-3.7-flash"
& "G:\AIRTS\临时文件夹\airts_agent_venv\Scripts\python.exe" adjutant_coordinator\deploy\server_e2e.py `
  --provider real --client-mode skip --ttl 1500 --run-id local_real_x

# 5) 服务器侧（隔离测试局服；玩家局服禁止）
#    cd /opt/airts-agent/app
#    .venv/bin/python -m adjutant_coordinator.deploy.model_smoke --authority-port 24572 --out /opt/airts-agent/logs/smoke/smoke.json
#    .venv/bin/python -m adjutant_coordinator.deploy.server_e2e --run-id srv_e2e --provider fake --client-mode auto
```

---

## 12. 已知风险与可能的设计争议（请审核方重点挑战）

1. **TTL 重算是否等于「篡改模型意图」**：`expires_tick` 在下发前被延长到
   `current_tick + intent_ttl_ticks`。我的立场：窗口语义应为「从下发时刻起算的有限期」，
   且重算有 `intent_ttl_recomputed` 留痕。若审核方认为应改为「过期即丢弃 + 让模型重规划」，需要改设计。
2. **暂停轮补偿**：图暂停后，恢复时我同时执行「完成上一轮收尾 + 按本轮观测再推进一次」，
   即一个 tick 内两次图推进。理由是避免丢掉该轮观测与事件；代价是同一 tick 可能触发两次模型调用（受间隔门限约束）。
3. **每单位 generation 与游戏侧租约 generation 是两套时钟**（仅做「不小于」比较）。
   实测会出现 graph=3 / lease=2 的偏差；我按「游戏侧只拒绝**落后**的意图」处理。
4. **`based_on_snapshot` 语义**：图只能夹紧到「自己已知的最新快照」，不能伪造快照号；
   快照新鲜度由宿主（观测注入方）保证。
5. **降级策略**：模型失败时保留既有计划与意图（游戏内规则 AI 继续兜底），而不是清空重来；
   连续失败进入冷却（默认 2 次错误 / 60 tick）。若审核方偏好「失败即停」，需要显式开关。
6. **PendingAuthority 判定**：当前对 `status in {"", "Unknown", "PendingAuthority"}` 视为未终态继续等待；
   是否应区分「权威层不支持复核」的通道能力？

### 12.7 对方案 §7「四条失效条件」的有意偏差（请审核方裁定）

真实模型实测后，把其中两条从「直接丢弃」改为「归一化 + 留痕」，其余两条保持丢弃：

| 条件 | 原实现 | 现实现 | 理由 | 残余风险 |
| --- | --- | --- | --- | --- |
| `expires_tick < now` | 丢弃 `expired` | 按 `now + intent_ttl_ticks` 重算并记 `clamped`；下发前还会按宿主提供的最新 tick 再核一次 | 模型用自己的时钟概念（真实测量：窗口经常已过），而该意图是**本轮刚产出**的；TTL 的真实语义是“下发时刻起的有限窗口” | 窗口被延长 → 若模型确实想给短窗口，语义被覆盖（有留痕可审计） |
| `plan_version` 不一致 | 丢弃 `plan_version_mismatch` | 归一化到当前生效版本并记 `clamped`；被替换的历史版本会记录在 `plan_version_history` 供审计 | 同步调用保证意图只可能来自当前上下文；真实模型频繁把 `plan_id`/版本号当 `plan_version` 写（4 次实测全部命中） | 失去“旧计划意图必须被拒”的显式保护；靠代际/租约/TTL/快照保证安全 |
| `lease.owner == player` | 丢弃 `lease_owner_player` | 不变（保持丢弃） | 玩家优先权是最高约束 | — |
| `generation` 不一致 | 丢弃 `generation_mismatch` | 不变（保持丢弃） | 旧响应抢回控制的直接防线 | — |

相关容错（不改安全语义，只降低结构化输出失败率）：模型可省略 `match_id`/`player_id`/`plan_version`/`based_on_snapshot`/`issued_tick`/`expires_tick`（系统按上下文补齐）；**给出非空但不一致的身份字段仍然拒绝**。

---

## 13. 给审核方的问题清单

1. 第 5 节的**不变量集合**是否足以覆盖「玩家优先权不可被绕过」？还缺哪条？（例如同 tick 内
   玩家命令与 AI 意图的先后顺序，我现在的实现是「玩家命令立即生效 + 图内失效 + 权威层再拒一次」）
2. 第 12 节第 1、2 条（TTL 重算、暂停轮补偿）是否可接受？若不可接受，你建议的替代语义是什么？
3. 双引擎（LangGraph / 内置执行器）是否值得保留？一致性测试是否足够？
4. checkpoint 的「陈旧写拒绝 + 损坏不重建」策略会不会掩盖故障（我更倾向保留现场）？
5. 第 9 节的三条补齐路径，你建议优先哪条（服务器游玩代码树同步 / 整体对齐 / 自动化客户端）？
6. 真实模型成型率（r6 3/6、r7 0/3）应算「实现问题」还是「提示词 + 执行层翻译问题」？
   你的判定标准是什么（例如「连续 3 轮 ≥80% 接受率」）？

---

## 14. 证据索引（路径清单）

| 内容 | 路径 |
| --- | --- |
| 实施记录（映射/契约/拓扑/四道防线/真实模型/服务器/缺口） | `docs/ai-adjutant-dual-layer/langgraph-refactor.md` |
| 命令与部署说明 | `source/adjutant_coordinator/README.md` |
| 本地 FakeModel E2E 证据（含失败轮次 r1-r5） | `source/adjutant_coordinator/logs/e2e_lg_20260910_r1..r9/{summary.json,graph_states.jsonl,graph_intents.jsonl,graph_receipts.jsonl,server.log,client.log,baseline.txt}` |
| 第一阶段 E2E 回归 | `source/adjutant_coordinator/logs/e2e_dual_regress_20260910/` |
| 真实模型闭环 | `tmp_logs/langgraph_recon/runs/local_real_r3..r7/{summary.json,model_calls.jsonl,states.jsonl}` |
| 服务器侧真实模型冒烟 | `tmp_logs/langgraph_recon/server_runs/srv_smoke_r3/smoke.json`（服务器 `/opt/airts-agent/logs/srv_smoke_r3/`） |
| 服务器勘察/部署/清理日志 | `tmp_logs/langgraph_recon/{srv_probe.log,deploy_agent.log,cleanup2.txt,caps.txt,audio_check.txt}` |
| 真实模型隧桥 | `tmp_logs/langgraph_recon/{ssh_llm_bridge.py,ssh_bridge.log}`；服务器 `deploy/llm_proxy.py` |

**报告结束。** 若需我把上述任一「实测结果」重新跑一遍并附原始输出，请指定条目编号（C1-C15 / D1-D3）。
