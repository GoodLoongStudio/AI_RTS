# 服务器：Agent 网关 + 局服（yyp_test）Implementation Plan

## Overview

同一台腾讯云 Ubuntu（4 核 8G / 约 12 Mbps）跑两件事，代码一律签出 **`yyp_test`**：

1. **Agent 工具 / LLM 网关**：策划文档里的 RemoteLLMPolicy 与工具 Schema，不跑 Godot 编辑器。
2. **游戏权威进程（后上）**：2–4 人 Demo 的 Godot Linux dedicated；对局事实只在这里。

两者用 **本机回环上的版本化 DTO** 连接。大模型不碰场景树、不改血量、不读迷雾外真值。API Key 只在服务器环境变量，不进 Git。

## Current State Analysis

### 策划已冻结的约束（必须遵守）

来源：`策划文档_AI副官系统.md`、`AI副官_下一阶段开发训练与评测规格.md`、`AI副官_权限与情报规则_P0.md`、`程序重构_AI操作点与受限观察方案.md`。

| 要求 | 对部署的含义 |
|---|---|
| 游戏系统提供合法事实，LLM 只理解/判断/提议 | 网关不能写 Godot Node；只能调查询和 `CommandRuntime` |
| 迷雾外敌军真值不得给 AI | 网关只用 `QuerySourceKind.Agent` 会话，禁止 `OmniscientDebug` |
| Human / RuleAI / LLM 共用权威命令服务 | 联机后命令仍进现有 `UnitCommandService`，多一个 issuer |
| `RemoteLLMPolicy` 只做 Observation→工具 Schema→Intent | 独立进程，超时/失败降级 ScriptedPolicy |
| API Key 不进仓库、不进 Trace | systemd `EnvironmentFile`，Trace 只记 provider/model/prompt_version |
| 禁止 LLM 逐帧微操 | 网关按决策调度调用，不跟 60Hz |
| 进入正式 LLM 对局前要能 Headless + ScriptedPolicy | 服务器先能无头跑场景，再接真模型 |
| P0 战术托管：Move/Attack 等可自动，生产/科技禁止 | 工具表按权限矩阵裁剪 |
| 玩家手动优先于 AI | 局服取消冲突 Intent，网关不得覆盖 |

代码侧已有：`WorldQueryService`（`GetOwnForces` / `ScanCircle` / …）、`QuerySourceKind.Agent`、`IBudgetedWorldQueryService`（边界已留、未做扣费）。还没有：RemoteLLMPolicy、工具 Schema 运行时、决策调度、Episode Trace 落盘、联机层。

### 不要部署到这台公网机的东西

- Godot **编辑器** + `addons/godot_mcp` 公网监听。MCP 文档写明：远程访问必须单独安全评审并认证。编辑器还要显示/GPU，4 核 8G 会被吃光。
- Cursor 本机 MCP（9080）原样映射到 0.0.0.0。
- 把 LLM 推理模型装在这台 8G 上（`LocalModelPolicy` 是以后的事；P1 只用一个远程 Provider + Mock）。

### Git 现状

本机当前分支是 `yyp_test`，跟踪的是 `origin/yyp_map`（HEAD `8581a30`）。远端不一定已有 `yyp_test` 这个名字。服务器绑定该分支前需要：把 `yyp_test` **推到 origin**（或你们实际有写权限的 fork），服务器只 `fetch` + `checkout yyp_test`。

## Implementation Strategy

一台机器、一个仓库目录、三个 systemd 单元，CPU/内存用 cgroup 隔开，避免 Agent 把局服卡死。

```text
测试同学 Windows 客户端
        │ UDP（以后，游戏口）
        ▼
[airts-game]  Godot 4.7.1 Mono dedicated / headless     绑定 127.0.0.1 工具口 + 公网 UDP
        │ HTTP/JSON 或 Unix socket，仅 127.0.0.1
        │ ObservationEnvelope / ProposedIntent / Feedback（带 schema_version）
        ▼
[airts-agent]  RemoteLLMPolicy 网关
        │ HTTPS 出站
        ▼
远程大模型 Provider（一个即可）

[airts-sync]  定时 git fetch origin yyp_test && 校验后重启（人工或 webhook）
仓库路径：/opt/airts   分支：只允许 yyp_test
```

**工具表（Agent 允许调用的，对应已有查询 + 命令，不是 MCP）：**

- 观察：`GetOwnForces`、`GetOwnEconomy`、`ScanCircle`、`InspectOwnEntity`、`GetBattlefieldBounds`（字段按 Agent 会话裁剪）。
- 意图：与 P0 矩阵一致的 Move / Attack / AttackMove / Hold / Retreat / Stop / 姿态与开火；生产、科研、改任务目标不出现在工具里。
- 网关把 LLM tool call 变成 `ProposedIntent`，局服 Validator 再决定执行或拒绝；拒绝原因对模型走过滤后的 Feedback，原始 `UnitNotFound` 不回传以免探雾。

**联机时：** 每个真人玩家一个 `QuerySessionGrant(Source=Agent, Observer=该玩家)`。语音/文字从客户端发到局服，局服带上玩家 ID 转给网关。网关无玩家身份则拒绝。

**和 2–4 人 Demo 的关系：** 局服可以晚于网关。第一期 Agent 可以对 **单机 headless / 战役切片** 调工具（满足策划「先 Scripted + Headless」）。多人 UDP 就绪后，同一网关接到权威 Match，不用换工具 Schema。

## Implementation Steps

1. ⏳ **Git 钉死 yyp_test**：origin 上出现 `yyp_test`；服务器 deploy key 只读该仓；`git checkout --force yyp_test`；禁止在服务器上改文件当正式源。
2. ⏳ **目录与密钥**：`/opt/airts`、`/etc/airts/agent.env`（Provider endpoint、模型 ID、timeout、prompt_version）；防火墙默认拒绝，只出站 443 + 入站 22 / 以后 UDP。
3. ⏳ **工具合同落地（先 Mock）**：把现有 `IWorldQueryService` + `UnitCommandService` 封成带 `tool_schema_version` 的 JSON；`MockPolicy` 与 `ScriptedPolicy` 能在 headless 场景走完「观察→意图→校验→Trace」。不接真 LLM 也算 Agent 工具部署成功。
4. ⏳ **RemoteLLMPolicy**：一个 Provider；异步、超时、解析失败 → 确定性 fallback；Trace 记 token/延迟，不记 Key、不记隐藏真值。
5. ⏳ **局服进程**：Linux `dedicated_server` 导出；对网关只绑 `127.0.0.1`；对玩家以后绑 UDP。cgroup：局服预留约 3 核 / 5G，网关 1 核 / 1–1.5G。
6. ⏳ **联机接上**：2–4 人 Match 里按玩家签发 Agent 会话；HUD 文字进同一条链（语音识别可仍在客户端，只把文本上传）。
7. ❌ 公网 Godot MCP、在 8G 上跑本地大模型、多 Provider、像素控制。

## Timeline

| 阶段 | 服务器上看见什么 | 依赖 |
|---|---|---|
| G0 | `/opt/airts` 在 `yyp_test`，能 `git pull` | 远端分支 + 部署密钥 |
| G1 | Mock 工具 + headless 一局 Trace | 不必联机、不必真 LLM |
| G2 | 真 Provider，战役/切片里副官能问能下已有命令 | G1 + Key |
| G3 | 无头局服 + 2–4 人 UDP | `联机Demo-2到4人-plan.md` |
| G4 | 每人一个副官会话 | G2 + G3 |

## Risk Assessment

| 风险 | 缓解 |
|---|---|
| Agent 阻塞 tick | 网关异步；局服绝不 `await` LLM |
| 工具把迷雾打穿 | 只签发 Agent 会话；评测真值另一通道，不进 Policy |
| `yyp_test` 与 origin 脱节 | 服务器拒绝手改；只快进该分支 |
| 4G 内存被 .NET + Godot + Python 挤爆 | 先 G1 量 RSS；局服与网关分 cgroup |
| MCP 暴露公网 | 不装编辑器、不端口转发 9080 |
| API 费用 | 事件驱动调用，禁止每帧；超时降级规则 AI |
| 无 GitHub 写权限推不出 `yyp_test` | 用有权限的远端，或管理员建 `yyp_test` |

## Success Criteria

- 服务器 `git rev-parse --abbrev-ref HEAD` 恒为 `yyp_test`。
- 不接 LLM 时，headless + Mock/Scripted 能对 `IWorldQueryService` 走完一局并写出 Trace（策划 P0 门槛中与部署相关的部分）。
- 接 LLM 后，模型只能通过工具表观察/提议；非法 Intent 被 Validator 挡住且游戏不崩。
- 游戏进程与网关可独立重启；Key 不在仓库。
- 未把编辑器 MCP 绑到公网 IP。

## Progress Tracking

- ✅ SSH 可达（Ubuntu 22.04.5，4 核 / 7.6G / 178G 盘）
- ✅ 轻量 Hermes Agent v0.20.6 已装（中国镜像 `res1.hermesagent.org.cn`，无浏览器/无捆绑 skills）；路径 `/home/ubuntu/.local/bin/hermes`
- ⏳ 远端 `yyp_test` + 服务器只读签出
- ⏳ Mock 工具合同 + headless Trace
- ⏳ RemoteLLMPolicy 单 Provider
- ⏳ 局服 dedicated + 本机 DTO
- ⏳ 2–4 人与每玩家 Agent 会话
- ❌ 公网 MCP / 本地大模型

## Related Files

- `docs/策划文档/策划文档_AI副官系统.md`
- `docs/策划文档/AI副官_下一阶段开发训练与评测规格.md`
- `docs/策划文档/AI副官_权限与情报规则_P0.md`
- `docs/程序文档/程序重构_AI操作点与受限观察方案.md`
- `docs/程序文档/程序协作_Godot_MCP集成.md`
- `source/csharp/Application/Queries/WorldQueryContracts.cs`（`QuerySourceKind.Agent`）
- `docs/plan/联机Demo-2到4人-plan.md`
- `docs/plan/腾讯云内测部署-plan.md`
