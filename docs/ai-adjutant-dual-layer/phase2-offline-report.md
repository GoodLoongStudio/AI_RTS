# 副官双层改造 第二阶段离线准备 报告

日期：2026-09-07。实施：CodeBuddy（GLM-5.3-Flash）。
范围：真实模型接入前的离线宿主框架（provider 接口、宿主调度、transport 抽象、结构化日志、测试）。
**真实模型 API、Hermes、DGX 均未接入；线上服务未修改；无 git commit/push。**

## 1. 基线

- 仓库 `G:\AIRTS\AI_RTS`，分支 `yyp_test`，基线提交同第一阶段（`6bcf1a1`）。
- 第一阶段交付与其复核结论（review-report.md §0）未被推翻；本阶段全部为**增量新增**，
  对第一阶段代码仅两处最小改动（见 §2）。
- 基线脏文件（地图生成/资产/文档目录）继续保留未触碰。

## 2. 实际修改文件

### 新增（`source/adjutant_coordinator/`）

| 文件 | 职责 |
| --- | --- |
| `provider.py` | `ModelCallContext`（request_id/role/身份/观测/计划版本/issued/deadline/预算/取消钩子）、`ModelOutcome`（completed/rejected/timeout/error/cancelled + payload + reason + retryable + available_at_tick 迟到语义 + `validate()` 自检）、`StrategyProvider`/`TacticsProvider` 抽象、`LegacyModelAdapter`（第一阶段裸模型接口 → Provider） |
| `fakes.py` | `ScriptedStrategyProvider`/`ScriptedTacticsProvider`：确定性脚本，支持 completed/timeout/error/empty/malformed/late/raise 七种行为与取消钩子；`make_valid_plan` 测试辅助 |
| `transport.py` | `Transport` 抽象（send_command/heartbeat/close/describe）、`LoopbackTransport`（handler 注入）、`FakeTransport`（ok/disconnect/empty/invalid_json/unknown_state 脚本 + 心跳失败预算）、`ResilientTransport`（断线→unsent 留证→重连→**身份指纹校验（match_id/player_id/rules_version）→漂移保持断开**；close 幂等） |
| `structured_log.py` | `StructuredLogger`：12 个标准字段逐条齐全（event/status/reason/server_tick/match_id/player_id/request_id/plan_version/task_id/command_id/rules_version/snapshot_id）；身份字段只能经 `update_identity` 修改（事件级参数不可伪造对局身份）；`MemorySink`/`JsonlFileSink`（UTF-8） |
| `host.py` | `HostScheduler` 宿主调度器（见 §3） |
| `tests/test_provider.py` / `tests/test_transport.py` / `tests/test_host.py` / `tests/test_structured_log.py` | 新增 51 项测试 |
| `verify_summary.py` | summary.json 独立校验器（UTF-8 强制；顶层与 counts 均须与 results 重算一致；未知结果类型/计数不符即失败） |

### 修改

| 文件 | 改动 | 兼容性 |
| --- | --- | --- |
| `coordinator.py` | ① `transport` 参数归一化（裸 Callable 或 Transport 对象均可）；② 抽出公共 API `adopt_plan()`/`submit_commands_batch()`（`_call_strategy` 复用前者） | 26 项第一阶段测试零改动全过；`op=*` 游戏侧协议未动 |
| `e2e_dual_layer.py` | 写完 summary 后自校验（`verify_summary`：results 重算 vs 顶层 vs counts，不一致抛错即本轮失败）；保留顶层 PASS/FAIL/SKIP 为主字段，counts 仅为兼容派生字段；UTF-8 读取保持 | E2E 21 项场景与判定完全不变 |

## 3. 接口说明

### Provider（模型注入点）
```python
outcome = provider.propose(ModelCallContext(
    request_id, role, match_id, player_id, rules_version, plan_version,
    snapshot_id, server_tick, issued_tick, deadline_tick,
    budget, observation, is_cancelled))
# -> ModelOutcome(status ∈ completed/rejected/timeout/error/cancelled,
#                 payload, reason, retryable, available_at_tick)
```
- 契约：propose 快速返回（不做长阻塞 IO）；真实 provider 的网络/凭证/模型名全部在
  宿主装配层，**协调器核心零依赖**。
- 迟到语义：`available_at_tick > deadline_tick` → 结果按 stale 丢弃；
  `available_at_tick > server_tick` → 挂起等待（不阻塞另一角色）；
  `available_at_tick < issued_tick`（时间倒流）→ 无效丢弃留证。

### HostScheduler（宿主调度器）
- `run_tick(server_tick, observation)` → `ok` / `degraded` / `fatal`。
- 战略：周期（`strategy_interval_ticks`）或重大事件（`observation.major_event` ∈
  配置集合且当前计划已过期）触发；战术：事件驱动（EventBus 有界合并）+ 最小间隔。
- 战略/战术各自独立挂起槽位：**战略结果未就绪不阻塞战术命令提交**（测试覆盖）。
- 超时：provider 返回 timeout 或挂起结果 settle 时已过 deadline → 标记 degraded、
  记录 timed_out 原因、**保留当前有效计划**（不重复下单；游戏内自动接战等防守行为照常）。
- 心跳：`heartbeat_interval_ticks` 周期探测；连续失败达阈值 → 断线处理 → 重连 →
  **identity_provider 重新读状态并校验 match_id/player_id/rules_version**；
  一致 → `ingest_header` 恢复并刷新日志身份；漂移 → 保持断开 + `reconnect_rejected` 留证。
- 异常：provider 异常转结构化 error（限次降级）；调度器内部意外异常 → `fatal` 状态 +
  结构化日志后**重抛**，绝不静默吞错。

### Transport（连接生命周期）
- `LoopbackTransport`：注入 handler（真实 TCP 客户端在装配层实现，本阶段不接网）。
- `FakeTransport`：断线/空响应/非法 JSON/未知状态/心跳失败脚本化。
- `ResilientTransport`：发送失败 → unsent_log 留证（**待诊断信息不丢**）→ 重连试探 →
  身份指纹校验；断开状态下再发只留证不发出；close 幂等。
- 双层身份防线：transport 层指纹校验（第一道）+ Host 层 identity_provider 终审。

### 结构化日志
- 每条战略请求、战术请求、计划采纳、命令提交回执、超时、迟到、重连、心跳失败、
  异常均落 12 标准字段 JSONL；对接持久层时用 `JsonlFileSink`（UTF-8）。
- 不记录凭证、模型名称或隐藏推理。

## 4. 测试结果

### 4.1 单元/确定性测试
命令：`cd G:\AIRTS\AI_RTS\source\adjutant_coordinator && python -m unittest discover -s tests`
结果：**Ran 77 tests, OK（0 FAIL, 0 SKIP）**
- 第一阶段既有 26 项：全部继续通过（零改动）。
- 新增 51 项：
  - `test_provider`（13）：上下文/结果结构、validate、迟到判定、Legacy 适配（dict/None/异常/字段透传）、假模型七种行为+取消+脚本耗尽。
  - `test_transport`（10）：环回往返/关闭拒绝、断线/空响应/非法结构/未知状态/心跳预算、断线留证、身份漂移阻断重连、探测失败保持断开、断开期间留证不外发、心跳计数、close 幂等。
  - `test_host`（14）：provider 注入与上下文、**并行不阻塞**、版本递增+旧计划拒绝、迟到 stale 丢弃、**超时保留当前计划+degraded**、挂起结果过 deadline 丢弃、时间倒流丢弃、心跳失败触发重连（身份校验）、身份漂移拒绝、**断线不丢计划/任务**、空响应/非法 JSON/未知状态不崩、provider 异常结构化、调度器崩溃 fatal+重抛、畸形计划拒绝。
  - `test_structured_log`（7）：标准字段齐全、缺省值、身份不可伪造、扩展字段不覆盖、JSONL UTF-8 往返、NullLogger、sink 过滤。

### 4.2 E2E（真实双进程）
命令：`python e2e_dual_layer.py --run-id e2e_p2_run1`
结果：**PASS=21 FAIL=0 SKIP=0，exit 0；summary 自校验通过**（`logs/e2e_p2_run1/summary.json`）。
独立校验器：`python verify_summary.py logs/e2e_run5/summary.json` → PASS（历史顶层格式兼容）。

### 4.3 其他验证
| 项 | 命令 | 结果 |
| --- | --- | --- |
| py_compile | `python -m py_compile` 全部 13 个 py 文件 | OK |
| git diff --check | `git diff --check` | 干净（exit 0） |
| C# 构建 | `dotnet build OpenRTS.csproj` | 0 错误 |
| Godot 解析/运行检查 | headless 跑 `AdjutantCommandProtocolSmokeTest.tscn` | 0 failure，exit 0（GDScript 侧本轮零改动） |

### 4.4 失败/超时/重试记录（调试期，均已修复并保留过程）
- 首轮 8 FAIL+1 ERROR：coordinator 把 Transport 对象当裸 Callable（归一化修复）；测试心跳间隔配置错误；`late` 脚本缺 payload 被 validate 拒绝（空响应语义修正：validate 放行 completed+None）；tactics 脚本 schema 不符；structured_log 身份字段可被事件参数伪造（改为仅 update_identity 可改）。
- 语义缺陷发现并修复：结果到达时间早于请求发出（时间倒流）原实现会立即生效 → 新增无效丢弃。
- 本轮最终测试**无 FLAKY、无重试通过**；E2E 的 build 多位置尝试是不同 command_id 的独立命令尝试（非同 ID 重试），summary 的 `retries` 语义预留为空。

## 5. 边界声明

- **真实模型 API：未接入**（无任何网络客户端、凭证、模型名进入代码）。
- **Hermes：未接入**，现有 rts_ctl 链路未改动。
- **DGX：未接入**。
- **线上服务：未修改**；本地 E2E 仅使用 24569/24570/24572 隔离端口。
- 正式平衡数据未改；玩家手动优先权与第一阶段命令协议未变（游戏侧 GDScript/C# 本轮零改动）。
- 假模型/假通道只用于协议与调度测试，**不构成真实模型闭环**。

## 6. 与第一阶段兼容性

| 检查 | 结果 |
| --- | --- |
| 第一阶段 26 项协调器测试 | 26/26 通过（零改动） |
| E2E 21 项场景 | 21/21 通过 |
| 游戏 op=rules/tactical/strategic/adjutant_command/adjutant_batch 及旧 op | 未改动，E2E 同链路验证 |
| 第一阶段 `FakeStrategyModel/FakeTacticsModel` 裸接口 | 经 `LegacyModelAdapter` 继续可用 |
| coordinator `transport` 参数 | 同时接受裸 Callable 与 Transport 对象 |

## 7. 接入真实 provider 前仍需完成（下一步）

1. **真实 provider 实现**：按 `StrategyProvider/TacticsProvider` 契约包装所选 API
   （凭证仅服务端配置；超时/重试/输出上限在 provider 内实现；`available_at_tick` 对应真实异步完成时刻）。
2. **真实 transport**：实现 `Transport`（TCP 客户端连调试端点）+ `identity_provider`
   （拉取 rules/status 包头），交给 `ResilientTransport` 包装。
3. **宿主进程装配**：把 `HostScheduler + AdjutantCoordinator + MatchPlayerStore +
   StructuredLogger(JsonlFileSink)` 装配为长驻进程；对局结束/换局的生命周期清理。
4. **降级策略细化**：degraded 期间是否允许防守类命令白名单（当前实现=不发任何新命令）。
5. **费用/预算接线**：`ModelCallContext.budget` 与 provider 侧 token/费用统计的对接与上报。
6. **中文 UI 与玩家授权开关**：消费结构化日志/回执字段（字段已按 UI 需要预留）。
7. **压测与回归**：固定版本连续回归（敌袭→回防 P50/P95、状态年龄、重复/过期命令计数），
   按 delivery.md 纪律执行。
