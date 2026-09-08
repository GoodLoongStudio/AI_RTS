# 副官双层改造 第三阶段第一轮：真实 Provider 适配层与离线模型沙盒 报告

日期：2026-09-07。实施：CodeBuddy（GLM-5.3-Flash）。
**真实模型 API 未实际调用；Hermes 未接入；DGX 未接入；线上服务未修改；无 git commit/push。**

## 1. 基线与范围

- 仓库 `G:\AIRTS\AI_RTS`，分支 `yyp_test`，基线延续（`6bcf1a1` 及第一阶段/第二阶段增量）。
- 本轮只做：真实 Provider 适配接口、API 请求/响应归一化、凭证环境变量读取与脱敏、
  Fake/HTTP 配置切换、固定战况快照离线沙盒、对应测试。
- 第一阶段命令协议、玩家优先权、正式平衡数据、现有地图/单位/建筑改动：**零修改**
  （游戏侧 GDScript/C# 本轮零改动，E2E 场景不变）。

## 2. 实际修改文件（均在 `source/adjutant_coordinator/`）

### 新增

| 文件 | 职责 |
| --- | --- |
| `redaction.py` | 脱敏工具：敏感键识别（api_key/secret/token/authorization/password/credential/bearer，大小写不敏感）、`redact_mapping`/`redact_headers`/`redact_text`（已知凭证串替换）、固定掩码 `***redacted***` |
| `config.py` | `ProviderSettings`：mode(fake/http)/endpoint/model/**api_key_env（环境变量名，非凭证值）**/timeout；`from_env()`（`AI_ADJUTANT_<ROLE>_<MODE|ENDPOINT|MODEL|API_KEY_ENV|TIMEOUT>`，非法 mode 回落 fake）；`resolve_api_key()`（调用期读环境变量）；`safe_dict()`（凭证值掩码，api_key_env 为变量名保留）；`create_strategy_provider`/`create_tactics_provider` 工厂（fake 注入 / http 构建，HTTP 依赖延迟导入） |
| `http_provider.py` | `HttpModelProvider`（请求构造、响应归一化）、`HttpClient` 协议（注入点）、`UrllibHttpClient`（标准库实现，**仅宿主显式装配；沙盒与测试不使用**）、`HttpResponse` |
| `sandbox.py` | `ModelSandbox`：固定战况快照（离线示例数据）+ Provider 输出 → 协议校验 → PlanStore 代际演练；`FIXED_SNAPSHOT`/`SANDBOX_BUDGET`；`run_fake_sandbox` 入口 + CLI（`python -m adjutant_coordinator.sandbox --rounds N`，**无任何联网选项**） |
| `tests/test_config.py` / `tests/test_http_provider.py` / `tests/test_sandbox.py` | 新增 36 项测试 |

### 修改

无既有文件修改（第二阶段及更早文件全部保持原样；`e2e_dual_layer.py` 本轮未改）。

## 3. Provider 接口与归一化行为

### 请求构造
`ModelCallContext` → POST JSON：`{role, model, request_id, match_id, player_id,
rules_version, plan_version, snapshot_id, issued_tick, deadline_tick, budget, observation}`。
头：`Authorization: Bearer <凭证>` + `Content-Type: application/json`（落日志前强制脱敏）。

### 归一化矩阵（全部返回结构化 `ModelOutcome`，不炸调用方）
| 场景 | 结果 |
| --- | --- |
| 请求前已取消 | `cancelled`（不发起请求） |
| 响应后已取消 | `cancelled`（迟到完成不抢回控制） |
| 凭证缺失（环境变量无值） | `error` "api key missing"，`retryable=false`（防重试风暴），不发请求 |
| 客户端抛 TimeoutError | `timeout` |
| 客户端其他异常（连接重置等） | `error` retryable=true |
| HTTP ≥400 | `error` "http <code>"，响应体截断+脱敏后落日志 |
| 空响应体 | `error` "empty response body" |
| 非法 JSON | `error` "invalid json: …" |
| JSON 根非对象 | `error` "response root is not an object" |
| `{"error": "…"}` | `rejected`（api error） |
| 未知 `status` 字段 | `rejected`（unknown response status，不猜测语义） |
| strategy 缺 `plan` 对象（非空响应） | `error` "missing 'plan' object" |
| tactics 缺 `commands` 列表（非空响应） | `error` "missing 'commands' list" |
| `{}`（纯空对象） | `completed` + payload=None（空响应业务路径） |
| `{"plan": {...}}` / `{"commands": [...]}` | `completed`（payload 交给协议层校验） |

迟到语义沿用第二阶段：`available_at_tick > deadline` → stale 丢弃（HTTP 同步调用不产生
available_at；该字段供异步 provider 与假模型使用，沙盒/host 已覆盖）。

## 4. 配置方式（服务端）

```powershell
# 服务端环境变量示例（凭证值只存在于环境变量 AI_ADJUTANT_API_KEY）：
AI_ADJUTANT_STRATEGY_MODE=http
AI_ADJUTANT_STRATEGY_ENDPOINT=https://<服务端网关>/v1/plan
AI_ADJUTANT_STRATEGY_MODEL=<模型名>
AI_ADJUTANT_STRATEGY_API_KEY_ENV=AI_ADJUTANT_API_KEY
AI_ADJUTANT_STRATEGY_TIMEOUT=8
AI_ADJUTANT_TACTICS_MODE=fake          # 两角色可独立切换
```
- 默认 `mode=fake`：未配置即离线，不存在"误连真实 API"路径。
- 切换真实 Provider 只改环境变量；协调器核心、协议、游戏侧零改动。
- 沙盒 CLI 只有 Fake 模式：`python -m adjutant_coordinator.sandbox --rounds N`。

## 5. 沙盒说明

- 固定战况快照（`FIXED_SNAPSHOT`）：离线示例数据（CC+2 worker+资源点+空敌情），
  结构对齐游戏侧 `op=tactical` 输出子集；不代表任何真实对局。
- 每轮：构造上下文（预算/观测/取消钩子）→ 战略输出 → `validate_plan` → PlanStore
  代际采纳（倒退拒绝留证）→ 战术输出 → 逐条 `validate_command_envelope`
  （非法命令计数+原因留证）。**无 transport、无网络、不发送任何游戏命令**。
- summary 明确标注 `api_key: ***redacted***`、`network: "none"`、`game_commands_sent: 0`。

## 6. 测试命令与真实结果

| 命令 | 结果 |
| --- | --- |
| `python -m unittest discover -s tests` | **Ran 113 tests, OK**（既有 77 项全部保持通过；新增 36 项：config 7、http_provider 20、sandbox 9） |
| 新增覆盖 → 需求 10 项对照 | 正常响应✓（plan/commands）、超时✓、取消✓（前/后两次检查）、空响应✓（空体+空对象）、非法 JSON✓、未知状态✓、HTTP/API 错误✓（400/500/error 字段/凭证缺失）、迟到✓（沙盒 stale）、计划版本倒退✓（沙盒 rejected）、非法命令✓（错 match/过期/非对象）、凭证脱敏✓（日志/安全视图/头） |
| `python -m py_compile`（全部 18 个 py 文件） | OK |
| `git diff --check` | 干净（exit 0） |
| `dotnet build OpenRTS.csproj` | 0 错误 |
| `python e2e_dual_layer.py --run-id e2e_p3_run1` + `verify_summary.py` | PASS=21 FAIL=0 SKIP=0，自校验与独立校验器均通过 |
| 沙盒 CLI | `python -m adjutant_coordinator.sandbox --rounds 2` → 2 轮计划采纳，无网络无命令 |

调试期失败（已修复并保留过程，最终轮无失败/FLAKY）：`__import__` 动态取类写法错误（改正常导入）、
`make_context` 缺 role 参数、`safe_dict` 误把 `api_key_env`（变量名）当凭证脱敏（回填修正）。

## 7. 边界声明（逐项如实回答）

| 问题 | 答案 |
| --- | --- |
| 真实模型是否实际调用？ | **否**。`UrllibHttpClient` 代码存在但仅由宿主显式装配；本轮全部测试与沙盒使用脚本假客户端，无任何真实网络请求 |
| Hermes 是否接入？ | **否**（rts_ctl 链路未动） |
| DGX 是否接入？ | **否** |
| 线上服务是否修改？ | **否** |
| 凭证是否出现在日志或文件中？ | **否**（三重防线：环境变量只在调用期读取；headers/配置落日志前经 redact；日志测试断言密钥字符串不出现。`safe_dict` 诊断视图凭证为掩码） |
| 是否发送真实游戏命令？ | **否**（沙盒无 transport；E2E 是第二阶段既有场景的回归，命令走本地隔离端口 24569/24570/24572 的测试对局） |
| 正式平衡数据/协议/玩家优先权是否修改？ | **否**（游戏侧 GDScript/C# 零改动） |

## 8. 下一轮接入只读 Hermes 前仍需完成

1. **只读 Hermes 勘察**：核实服务器 Hermes 版本、会话机制与可复用扩展点（只读查询，不写配置）。
2. **真实网关客户端**：把 `UrllibHttpClient`/服务端网关装配为 `HttpClient`，endpoint 指向
   服务端网关（凭证不经过客户端进程）。
3. **端到端装配**：`HostScheduler + HttpModelProvider + ResilientTransport + MatchPlayerStore`
   组装为长驻宿主进程，加降级白名单（degraded 期间允许的防守类命令）与费用统计上报。
4. **提示词/观测契约**：observation → 模型输入的字节级格式与输出 JSON schema 固化
   （当前 provider 期望 `{"plan":{}}`/`{"commands":[]}` 形态，需与实际模型输出对齐）。
5. **回退开关**：`mode=fake|http` 环境变量已是开关雏形，需补"运行中降级到 Fake"的运行态切换验证。
6. **对照评估准备**：固定快照/固定种子回归集扩充，按 delivery.md 记录 P50/P95 与调用量。
