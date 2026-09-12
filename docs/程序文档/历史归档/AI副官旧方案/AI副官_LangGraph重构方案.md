# [已废弃 / 仅供追溯] AI 副官 LangGraph 重构方案

> Deprecated，2026-09-12 归档。正文保留当时方案，不是当前指令；禁止据此恢复双模型、云端实时链路或阶段后停等。执行请读[当前入口](../../AI副官_当前执行入口.md)。

日期：2026-09-10
状态：待执行
适用范围：单局一个真人玩家；玩家可以随时打断副官；玩家拥有最高控制权。

## 1. 最终架构

```text
玩家
  ├─ 手动控制单位
  └─ 与 Hermes 对话

Hermes
  └─ 玩家画像、四重记忆、对局复盘、长期偏好

LangGraph
  └─ 每个对局一个副官状态图
      ├─ 战略计划
      ├─ 战术响应
      ├─ 玩家打断
      ├─ 计划调整
      ├─ 请求取消和恢复
      └─ 命令仲裁

PydanticAI
  └─ LangGraph 内的结构化模型节点

Godot
  ├─ Observation
  ├─ 玩家优先控制权
  ├─ 行为树/编队状态机
  └─ CommandRuntime 权威执行
```

职责边界：

- Hermes 负责长期记忆和玩家关系，不进入实时战场控制环。
- LangGraph 负责状态、事件、战略/战术调度、中断、恢复和仲裁。
- PydanticAI 负责模型调用与结构化输出，不直接执行游戏命令。
- Godot 行为树或现有编队状态机负责高频单位执行。
- `CommandRuntime` 是唯一权威命令执行入口。
- 玩家命令优先级高于所有 AI 意图。

## 2. API 和模型配置

首期只配置一个外部 OpenAI 兼容 Provider 和一套 API Key：

```text
LLM_BASE_URL
LLM_API_KEY
HERMES_MODEL
STRATEGY_MODEL
TACTICS_MODEL
```

战略、战术和 Hermes 可以先使用同一个模型。以后只调整模型名，不改变协议和运行架构。LangGraph、PydanticAI、Godot 本身不需要额外模型 API。

本地 FakeModel 和回放测试必须不需要 API Key。

## 3. Hermes 边界

Hermes 保留一个玩家长期会话，每局可以有一个对局会话，但只接收摘要：

- 开局配置和玩家偏好；
- 战略阶段变化；
- 重大敌情和基地受袭；
- 玩家接管部队；
- 关键任务完成或失败；
- 对局结束报告。

Hermes 不负责高频读取战场，不直接调用 `move`、`attack`、`build` 等游戏命令。

## 4. LangGraph 状态和流程

每个单真人对局创建一个图状态，至少包含：

```text
match_id
player_id
rules_version
server_tick
latest_snapshot_id
active_plan
plan_version
active_tasks
active_intents
ai_controlled_units
player_controlled_units
control_generation
pending_events
pending_requests
command_receipts
degraded_reason
```

建议流程：

```text
ingest_observation
    ↓
classify_event
    ↓
player_override_gate
    ├─ 玩家打断 → reconcile_plan
    ├─ 紧急事件 → tactical_agent
    ├─ 战略周期到期 → strategic_agent
    └─ 无需决策 → wait
    ↓
arbitrate_intent
    ↓
dispatch_to_godot
    ↓
observe_receipt
    ↓
persist_checkpoint
```

LangGraph 的 `interrupt` 用于暂停、保存和恢复图状态。它不能替代 HTTP 请求取消、Intent 过期检查和 Godot 最终校验。

## 5. 战略层

调用频率：开局立即调用，普通周期 30-60 秒，重大事件可以提前触发。

战略层只输出 `StrategicPlan`，内容包括阶段目标、任务优先级、资源预留、允许使用的单位范围、完成条件和中止条件。战略层不能直接输出单位命令。

计划必须带 `plan_id`、`plan_version`、`based_on_snapshot`、`valid_until_tick`。

战略模型失败时保留当前有效计划，不阻塞战术层和 Godot。

## 6. 战术层

战术层由事件触发，不按模型频率固定轮询。事件包括基地受袭、发现敌军、编队减员、目标死亡、路径失败、生产队列空闲、任务完成、任务无进展、玩家接管和玩家归还单位。

战术层输出短期 `TacticalIntent`，至少包含：

```text
intent_id
plan_version
task_id
unit_ids
action
target
priority
based_on_snapshot
issued_tick
expires_tick
generation
abort_when
```

允许的高层动作：`move`、`attack`、`attack_move`、`defend`、`retreat`、`scout`、`hold`、`regroup`。

模型只能引用当前 Observation 中存在的稳定实体 ID 和规则 ID，不能构造任意场景路径或绕过视野规则。

## 7. 玩家打断和控制权

玩家优先级：

```text
玩家命令 > 紧急 AI 任务 > 普通 AI 任务 > 默认行为
```

每个单位或编队维护 AI lease 和控制代际 `generation`。玩家下令后，权威层必须增加代际、撤销相关 AI lease、使相关 Intent 失效、标记原任务并通知 LangGraph。

旧模型响应在以下任一条件成立时必须丢弃：

```text
intent.generation != current_generation
intent.plan_version != active_plan_version
intent.expires_tick < server_tick
lease.owner == player
```

玩家接管后，AI 默认不能自动抢回。只有 `player_release_units`、`player_release_group` 或明确启用的自动归还规则才能重新交给 AI。

玩家局部打断只影响相关单位，不能清空整个战略计划。其他未被玩家接管的单位继续执行 AI 任务。

任务状态区分：`running`、`partially_overridden`、`waiting_for_player`、`reassigned`、`completed`、`failed`、`cancelled`、`expired`。

## 8. Godot 执行层

优先复用当前 `CommandRuntime`、`UnitCommandGateway`、`WorldQueryService`、`AdjutantObservationRuntime`、`AutoAttackingBattlegroup` 以及现有移动、攻击、采集和撤退逻辑，不重写整个 Rule AI。

执行链：

```text
TacticalIntent
→ Godot IntentValidator
→ generation/lease/TTL 检查
→ 编队行为树或状态机
→ UnitCommandGateway
→ CommandRuntime
→ ExecutionReceipt
```

行为执行在 Godot 内部以 10-30Hz 或现有物理循环运行，不能等待 Python 或模型返回。模型不可用时继续执行有效 Intent；Intent 过期后进入规则 AI 或安全默认行为。

## 9. 当前仓库改造边界

保留并扩展：

```text
source/adjutant_coordinator/protocol.py
source/adjutant_coordinator/coordinator.py
source/adjutant_coordinator/host.py
source/adjutant_coordinator/events.py
source/adjutant_coordinator/state.py
source/adjutant_coordinator/persistence.py
source/adjutant_coordinator/transport.py
```

建议新增：

```text
source/adjutant_coordinator/graph/
  state.py
  graph.py
  nodes.py
  interrupts.py
  arbitration.py
  checkpoint.py
  model_context.py
  pydantic_agents.py
```

Godot 侧优先检查和扩展：

```text
source/csharp/GodotAdapter/Adjutant/AdjutantObservationRuntime.cs
source/csharp/GodotAdapter/Composition/CommandRuntime.cs
source/net/DebugControlServer.gd
source/match/players/simple-clairvoyant-ai/AutoAttackingBattlegroup.gd
source/match/players/simple-clairvoyant-ai/SimpleClairvoyantAI.gd
```

不得建立副官专属的第二套资源、兵种、生产和平衡数据。继续从当前对局 Catalog 和权威 Observation 获取事实。

## 10. 分阶段实施

### Phase 0：依赖和基线

建立独立 Python 虚拟环境，锁定 `langgraph`、`pydantic-ai`、`pydantic`、`httpx`、`aiosqlite`。保留 FakeModel，确认现有 Python 测试和编译基线通过。

### Phase 1：Intent 和玩家控制权

实现 `generation`、lease、`PlayerOverride`、Intent TTL 和显式玩家归还。先完成单元测试和 Godot headless 测试，不接真实模型。

### Phase 2：LangGraph 假模型闭环

使用内存 checkpoint 和固定 JSONL 回放，验证战略计划、战术打断、玩家接管、计划局部调整、Intent 过期、模型超时降级和 checkpoint 恢复。

### Phase 3：本地 Godot 双进程

LangGraph 通过现有 `rules`、`tactical`、`strategic`、`adjutant_command`、`commands` 协议接入本地隔离对局，复用 `e2e_dual_layer.py`。

### Phase 4：Godot 行为执行

将 Intent 接入 `AutoAttackingBattlegroup` 和现有单位行为，实现移动、攻击、attack-move、防守、撤退、待命和重组。保留规则 AI 作为 fallback。

### Phase 5：真实战术模型

先只接战术模型。初始 TTL、超时和批量上限配置化，记录延迟、接受率、过期率、重复命令率、玩家打断率和服务器帧耗时。

### Phase 6：真实战略模型

战略模型只更新计划；战术模型读取计划。验证战略超时不阻塞战术，新计划不会覆盖玩家控制单位。

### Phase 7：Hermes

接入玩家画像、偏好配置、重大事件摘要和对局复盘。Hermes 不进入 `dispatch_to_godot` 路径。

## 11. 测试和验收

本地测试优先使用 FakeModel、JSONL 回放和 Godot headless，不需要 API Key。

必须覆盖：

- 玩家打断单个单位和整个编队；
- 玩家停止后 AI 不恢复旧任务；
- 玩家未接管单位继续由 AI 管理；
- 显式归还后 AI 才能重新接管；
- 旧模型响应不能覆盖玩家命令；
- 目标死亡、失去视野、路径失败后的恢复；
- LangGraph checkpoint 恢复；
- 模型超时和 Provider 断线降级；
- 重复命令不重复扣费或生产；
- `PendingAuthority` 不导致重复下单；
- 战略和战术不互相覆盖；
- Godot 不等待模型。

现有协调器测试必须保持通过。每次运行使用独立 `run_id`，保留输入、图状态、Intent、回执、快照和汇总。

## 12. 服务器部署边界

服务器是 4 核 8G 单机，已有 Godot 局服 UDP 24567、Hermes Gateway、Dashboard 9119/nginx 80 和旧副官 daemon 24580。

LangGraph 必须部署到独立目录和独立虚拟环境：

```text
/opt/airts-agent/
  .venv/
  app/
  state/
  logs/
```

要求：只绑定 `127.0.0.1`，只连接本机 Godot 权威端口，不连接 UDP，不和旧 Hermes daemon 共用状态文件，checkpoint 按对局隔离，API Key 只放环境变量，日志不得写入 Key、完整 Prompt 或隐藏推理。

部署顺序：本地 FakeModel 回放 → 本地 Godot 双进程 → 服务器独立目录 MockModel → 服务器真实 Provider → 独立测试局 → 正式局服灰度。

不得直接替换当前线上 Hermes daemon。服务器代码版本、现有 Hermes 会话和端口状态必须先核实，正式切换安排单独窗口。

## 13. 最终验收标准

1. 玩家始终拥有最高控制权。
2. 玩家可以随时打断 AI。
3. 玩家接管的单位不会被旧 Intent 抢回。
4. 玩家未接管的单位仍可由 AI 管理。
5. 局部打断不会清空整个战略计划。
6. LangGraph 可以处理中断、恢复和 checkpoint。
7. PydanticAI 只负责结构化模型节点。
8. Hermes 不进入实时战场控制环。
9. 行为树不等待模型。
10. `CommandRuntime` 仍是唯一权威执行者。
11. 模型失败、断线、超时和非法输出都有降级路径。
12. Intent 有计划版本、快照版本、控制代际和过期时间。
13. 本地 FakeModel、回放和 headless 可以完成完整验证。
14. 真实运行只需一套 Provider 配置。
15. 服务端可以回退到规则 AI 或旧副官链路。
