# 副官协调器核心

对应 `docs/ai-adjutant-dual-layer/architecture.md` 的宿主协调器职责，
以及 `docs/ai-adjutant-dual-layer/langgraph-refactor.md` 的 LangGraph 单局副官图。

## 模块

### 第一阶段：协调器核心
- `protocol.py`：命令包/计划契约与校验（必填、身份、版本、过期、快照时效）。
- `state.py`：`PlanStore`（采纳代际，旧输出不能覆盖）、`TaskTracker`（任务状态机，
  与命令 Accepted 分离）、`ControlLease`（控制租约与玩家优先权）。
- `events.py`：有界事件总线，窗口内同键合并，断线恢复走新快照。
- `persistence.py`：按 `(match_id, player_id)` 目录隔离；独立临时文件（pid+uuid）
  + `os.replace` 原子写；`writer.lock` 单写入者（陈旧锁 pid 回收）。
- `coordinator.py`：`AdjutantCoordinator` 主循环（tick 驱动、请求代际、重试退避、
  逐条批次、资源预留约束）与 `FakeStrategyModel`/`FakeTacticsModel`（确定性协议测试专用）。
- `host.py` / `provider.py` / `transport.py` / `http_provider.py`：第二阶段宿主调度、
  Provider 抽象、通道抽象与 HTTP 适配（未接真实模型）。

### 第二阶段：LangGraph 副官图（`graph/`）
- `contracts.py`：`StrategicPlan` / `TacticalIntent` / `IntentBatch` / `PlayerControlEvent`
  的 pydantic 契约（目标只允许观测内实体与规则内场景；未知字段与未知目标键一律拒绝）。
- `state.py`：`AdjutantGraphState`（单局状态，含每单位控制代际、意图生命周期、
  在途请求、任务状态、降级原因）+ JSON 友好序列化。
- `checkpoint.py`：`MemoryCheckpointStore` / `JsonCheckpointStore`（按对局隔离、
  原子写、陈旧写拒绝、损坏文件不静默重建）/ `NullCheckpointStore`。
- `model_context.py`：模型上下文构造（不伪造、不补默认值；截断显式上报；
  目标引用校验只认观测/规则里的稳定 ID）。
- `interrupts.py`：事件分类与路由、玩家打断语义、紧急战术抢占。
- `arbitration.py`：意图仲裁（代际/计划版本/TTL/租约/引用/重复/在途去重/批上限）。
- `nodes.py`：图节点（ingest → classify → [reconcile|strategic|tactical|wait] →
  arbitrate → dispatch → observe → persist）与降级逻辑。
- `graph.py`：`LangGraphRunner`（真实 StateGraph + MemorySaver + interrupt/resume）
  与 `FallbackRunner`（未安装 langgraph 时的等价执行器，同一批节点函数）。
- `pydantic_agents.py`：`PydanticAIStrategyAgent` / `PydanticAITacticsAgent`
  与 `FakeStructuredModel`（确定性、无 API Key）。
- `runtime.py`：`AdjutantGraphRuntime` 兼容适配层（复用 `AdjutantCoordinator`
  的计划采纳/租约/预算/幂等回执，命令仍走 `Transport` → Godot 权威入口）。
- `replay.py`：JSONL 回放驱动（独立 run_id，输入/状态/意图/回执/汇总留痕并自校验）。

## 测试

```powershell
cd G:\AIRTS\AI_RTS\source\adjutant_coordinator
$env:PYTHONUTF8="1"
python -m unittest discover -s tests              # 221 项（含 80 项 LangGraph 图测试）
python -m compileall .
python e2e_dual_layer.py --run-id <run_id>        # 第一阶段双进程 E2E（独立测试配置）
python e2e_langgraph.py --run-id <run_id>         # LangGraph Intent 双进程 E2E（独立测试配置）
```

可选依赖（只在用真实 LangGraph / PydanticAI 时需要，缺省走内置执行器）：

```powershell
python -m venv G:\AIRTS\临时文件夹\airts_agent_venv
G:\AIRTS\临时文件夹\airts_agent_venv\Scripts\python -m pip install -r requirements-graph.txt
G:\AIRTS\临时文件夹\airts_agent_venv\Scripts\python -m unittest discover -s tests
```

JSONL 回放（FakeModel，无需 API Key）：

```powershell
python -m adjutant_coordinator.graph.replay `
  --fixture tests\fixtures\replay_base_attack.jsonl --run-id replay-001
```

## 服务器部署与真实模型（`deploy/`）

服务器（腾讯云 101.43.121.102）独立目录部署：`/opt/airts-agent/{app,.venv,state,logs,backups}`，
独立 venv，模型配置集中在 `/opt/airts-agent/.env`（mode 600，密钥不进日志、不进版本库）。

```bash
# 1) 安装（服务器本机执行或由本地驱动脚本触发）
bash /opt/airts-agent/app/adjutant_coordinator/deploy/install_server.sh --sync-hermes-env

# 2) 真实模型冒烟（战略/战术各一次，只读 op + 契约校验，不下发游戏命令）
cd /opt/airts-agent/app
.venv/bin/python -m adjutant_coordinator.deploy.model_smoke --authority-port 24572 \
    --out /opt/airts-agent/logs/smoke/smoke.json

# 3) 隔离测试局服 E2E（端口硬白名单 24569/24570/24572；玩家局服 24567/24571 一律拒绝）
.venv/bin/python -m adjutant_coordinator.deploy.server_e2e --run-id srv_e2e_001 \
    --provider fake --client-mode auto        # 假模型先验证链路
.venv/bin/python -m adjutant_coordinator.deploy.server_e2e --run-id srv_e2e_002 \
    --provider real --client-mode none --ttl 1500   # 真模型（服务器无客户端时用 none）
```

辅助脚本：

- `deploy/godot_tcp.py`：Godot 调试端点 TCP 客户端（端口硬白名单 + 测试客户端拉起 + 开局）。
- `deploy/env_file.py`：加载服务器 `.env`（只返回键名，不打印取值）。
- `deploy/llm_proxy.py`：**只绑定 127.0.0.1** 的 OpenAI 兼容代理（密钥留服务器）；
  本机经 SSH 取模型时用它 + `ssh_llm_bridge.py`（本地工具，不入库）。
- 本地 SSH 运维驱动（上传/安装/部署 Godot 补丁/E2E/拉日志）带凭证，放在
  `G:\AIRTS\临时文件夹\` 下的本地工具目录，不入版本库。

> 端口纪律：任何测试只碰 24569/24570/24572；玩家局服 UDP 24567 + TCP 24571 与
> Hermes 客户端 24568 一律禁止连接（`deploy/godot_tcp.py::FORBIDDEN_PORTS` 硬拒绝）。

## 游戏侧入口（权威校验在游戏内）

- `op=rules` / `op=tactical` / `op=strategic` / `op=adjutant_command` / `op=adjutant_batch`
- `op=adjutant_intent`：LangGraph 战术意图入口（意图登记幂等 + TTL + 控制代际/租约守卫，
  再复用 `op=adjutant_command` 的完整权威链；游戏侧不掌握战略计划版本）。
- `op=adjutant_leases`：只读查询租约代际与意图登记（验收/诊断）。
- 复核：`op=commands` + `command_id`（副官账本优先，兼容旧展示历史）
- 战术位置评分：`tactical_position.py` 提供可解释的候选点排序；没有游戏地形遮挡接口时
  `cover_score` 明确为 `null`，禁止把几何近似冒充真实掩体数据。宿主可注入 terrain/LOS provider。
- 端口约定：本地 E2E 固定 24569/24570/24572，不触碰线上局服。
