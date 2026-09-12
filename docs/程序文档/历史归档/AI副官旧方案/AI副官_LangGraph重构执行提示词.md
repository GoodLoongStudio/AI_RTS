# [已废弃 / 禁止执行] DeepSeek V4.1 Flash 执行提示词：AI 副官 LangGraph 重构

> Deprecated，2026-09-12 归档。下文是历史指令，不能作为当前任务要求。执行请读[当前入口](../../AI副官_当前执行入口.md)。

你负责在 `G:\AIRTS\AI_RTS` 完成 AI 副官架构重构。请先阅读并遵守：

- `docs/项目统一规范.md`
- `docs/ai-adjutant-dual-layer/architecture.md`
- `docs/ai-adjutant-dual-layer/delivery.md`
- `docs/plan/AI副官_LangGraph重构方案.md`
- 根目录 `skill.md` 和 `服务器信息.md`

目标是把当前纯 Hermes 实时控制链改造成：

```text
Hermes = 玩家画像、长期记忆、对局复盘
LangGraph = 单局副官状态、战略/战术编排、中断、恢复、仲裁
PydanticAI = LangGraph 内的结构化模型节点
Godot = 观测、玩家优先控制、行为执行、权威命令校验
```

当前只考虑单局一个真人玩家。玩家可以随时打断副官，玩家命令永远优先。不要扩展多人副官权限模型，除非现有代码已经要求这样做。

## 执行要求

先做代码和文档审计，再实施。不要根据方案文件臆造不存在的接口；要映射到现有 `source/adjutant_coordinator`、`CommandRuntime`、`WorldQueryService`、`AdjutantObservationRuntime`、`DebugControlServer` 和 `AutoAttackingBattlegroup`。

保留现有权威执行链和测试。模型只能输出结构化 `StrategicPlan` 或 `TacticalIntent`，不能直接修改 Godot 节点，不能绕过 `CommandRuntime`，不能创建第二套平衡、资源或生产数据。

允许你自主决定：

- LangGraph 图节点如何拆分；
- checkpoint 的具体实现；
- PydanticAI Agent 的装配方式；
- 与现有协调器的兼容适配层；
- 行为树和现有编队状态机的组合方式；
- 必要的 DTO 命名，只要语义和兼容性清楚；
- 测试夹具和回放工具的具体格式。

不要擅自改变：

- 玩家最高控制权；
- Intent 的计划版本、快照版本、控制代际和过期语义；
- Godot 权威命令入口；
- 迷雾和玩家视野约束；
- 本地测试端口隔离；
- 不把 Hermes 放回实时高频控制环。

## 必须实现的行为

1. 每个对局有独立 LangGraph 状态。
2. 战略层低频生成计划，不直接下单位命令。
3. 战术层由事件触发，生成有限期 Intent。
4. 紧急战术事件可以打断普通战略任务。
5. 玩家命令立即增加控制代际并撤销相关 AI lease。
6. 玩家接管的单位不会被旧模型响应抢回。
7. 玩家局部接管不会清空整个战略计划。
8. 玩家显式归还单位后，AI 才能重新接管。
9. 模型超时、断线、非法输出时，Godot 不阻塞并有规则 AI fallback。
10. LangGraph 重启后可以从 checkpoint 恢复。
11. `PendingAuthority` 不会导致重复下单。
12. 所有命令仍由 Godot 权威层做最终校验。

## API 约束

第一版只需要一个 OpenAI 兼容 Provider 和一套 API Key。战略模型、战术模型和 Hermes 可以使用同一个 Provider，模型名可配置。LangGraph 和 PydanticAI 不应被设计成需要额外外部 API 的服务。

必须提供 FakeModel 或等价测试实现，使本地协议、图状态、玩家打断、Intent 过期、恢复和降级测试不需要 API Key。

PydanticAI 是 LangGraph 的模型节点实现，不是第二个总调度器。若现有依赖或环境不适合立即安装，请先保留清晰的 Provider 抽象和 FakeModel，再记录真实依赖安装步骤，不要伪造已接入。

## 实施顺序

建议顺序如下，但可以根据代码事实调整：

1. 记录工作区基线和现有测试结果。
2. 固化 `StrategicPlan`、`TacticalIntent`、`generation`、lease 和 TTL 契约。
3. 完成玩家打断和显式归还测试。
4. 用 FakeModel 建立 LangGraph 图和 checkpoint。
5. 用 JSONL 回放验证敌袭、目标死亡、路径失败、玩家接管和模型超时。
6. 接入本地 Godot 双进程隔离 E2E。
7. 把 Intent 接入 Godot 编队行为执行层。
8. 再接真实 PydanticAI Provider。
9. 最后接 Hermes 的记忆摘要和复盘，不让 Hermes 直接控制单位。

## 测试要求

至少运行并报告：

```powershell
cd G:\AIRTS\AI_RTS\source\adjutant_coordinator
python -m unittest discover -s tests
python -m compileall .
```

根据改动范围运行相关 Godot headless 测试和本地双进程 E2E。每次测试使用独立 `run_id`，保存输入、状态、Intent、回执和结果。不要连接公网正式局服，不要停用或重启服务器上的现有 Hermes、Godot 或 daemon，不要修改服务器配置，除非用户另行明确授权。

当前工作区可能有其他未提交修改。不要 reset、checkout、clean、stash 或覆盖与本任务无关的改动。编辑共享文件前先复读当前内容，补丁保持小而可回退。

## 输出要求

完成后提供：

- 修改文件清单；
- 架构与现有代码的映射；
- 运行过的命令和结果；
- 未完成部分和原因；
- 真实模型是否接入的准确说明；
- 玩家打断测试证据；
- LangGraph checkpoint 恢复测试证据；
- 本地 E2E 是否通过；
- 后续需要人工决定的事项。

不要把 FakeModel 测试称为真实模型闭环，不要把静态检查称为运行验收，不要宣称服务器已经部署，除非确实有对应证据。
