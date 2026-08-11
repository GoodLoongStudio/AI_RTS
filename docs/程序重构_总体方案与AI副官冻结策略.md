# 程序重构：总体方案与 AI 副官冻结策略

> 文档状态：重构方案草案，供团队评审
>
> 编写日期：2026-08-11
>
> 适用分支：`refactor/dev-20260811-008-repository`
>
> 前置文档：《程序重构_现有仓库结构与运行基线.md》《程序重构_手动功能验收清单.md》

## 1. 决策摘要

本次重构采用以下核心原则：

> 先把游戏做成架构可靠、操作完整、规则确定的传统 RTS，再把玩家、传统 AI 和大模型 AI 作为不同的“命令来源”接入同一套游戏接口。

AI 副官相关功能进入冻结状态。冻结不是立即删除已有演示，而是：

- 不继续扩展关键词、人格、对话、剧情表现或模型接入；
- 不允许 AI 副官直接形成第二套单位控制系统；
- 当前战役演示作为行为样本和产品验证材料保留；
- 只迁移其中能够服务所有操作者的命令、查询、校验、反馈和身份概念；
- 等 Human 和传统规则 AI 都通过统一接口稳定运行后，再重新评审大模型接入。

## 2. 为什么需要冻结

当前 `AICommandHUD` 同时承担 UI 创建、快捷键、编组、文本解析、预设问答、任务上下文、镜头跟随和单位动作修改。这会导致 AI 原型反向决定底层 RTS 架构。

此外，当前 Match 只要存在 Human 就会实例化 AICommandHUD，不限于战役。它还占用 `1/2/3`、`Q/W/E/R/D/F` 等输入，其中 `Q/E` 与传统镜头旋转冲突。这意味着 AI 原型已经侵入普通对局操作层，不适合作为后续功能扩展的基础。

如果现在直接接入大模型，会同时固化以下问题：

- 模型或 HUD 直接引用 Godot Node、节点组和场景路径；
- 玩家、规则 AI、大模型分别维护三套控制逻辑；
- 权限、战争迷雾、资源和目标校验不一致；
- 命令无法稳定回放、测试、存档或用于联机；
- 大模型输出的不确定性进入确定性的游戏模拟层。

因此，冻结 AI 副官是为了保护 RTS 核心边界，而不是放弃 AI 方向。

## 3. 冻结期间的功能分类

### 3.1 保留：作为产品需求或验证样本

以下内容有长期价值，应当保留其行为描述、测试样本或数据，但不代表保留当前实现方式：

1. **玩家自然语言表达战术意图的入口概念**：未来可重新启用。
2. **命令二次确认**：移动类命令需要确认位置，攻击命令需要确认合法目标。
3. **受限信息原则**：AI 不应把战争迷雾之外的信息当成事实。
4. **结构化反馈**：接受、拒绝、部分执行、等待目标、失败原因。
5. **任务上下文**：当前目标、已确认情报、风险和建议应当来自查询接口。
6. **英雄身份组件**：英雄仍是普通 RTS 单位，只附加战役身份，这是正确方向。
7. **回声撤离灰盒任务**：用于验证传统操作、目标推进和未来 Agent 接入。
8. **AICommandHUD 的交互稿价值**：界面布局和文字可以作为产品原型参考。

### 3.2 暂留：Legacy 演示，不再扩展

下列现有代码可在过渡期保留，以便重构前后演示对照：

- `source/match/hud/AICommandHUD.gd`；
- `source/campaign/CampaignController.gd` 中与 AI HUD 的适配调用；
- `CampaignMission.gd` 中的预设建议和风险文本；
- 当前关键词命令和预设问答；
- 当前英雄 F1 选择/镜头跟随表现。

暂留代码应满足以下约束：

- 标记为 Legacy/Prototype，不作为新系统依赖；
- 默认不出现在普通自定义对局；
- 如需保留战役演示，通过明确 Feature Flag 或 Legacy composition 入口启用；
- 除阻断运行的缺陷外，不继续增加功能；
- 新 C# 领域层不得反向引用这些脚本。

是否立即修改默认启用行为，应作为一个独立、小型 PR 评审，不与核心迁移混在同一提交中。

### 3.3 跟随本次重构：抽象为公共能力

这些能力不是“AI 专属”，必须进入统一 RTS 核心：

- 单位稳定 ID、玩家/操作者 ID、目标 ID；
- 选择与控制组的应用层服务；
- Move、Attack、AttackMove、Stop、Hold、Patrol 等单位命令；
- Gather、ReturnCargo、Build、Repair 等经济命令；
- Produce、CancelProduction、SetRallyPoint 等生产命令；
- 命令合法性、权限、资源、视野和目标域校验；
- 命令执行结果与失败原因；
- 只读游戏快照和受权限约束的查询；
- 任务目标推进与游戏事件订阅；
- 输入映射、规则 AI 和未来 Agent 的适配器边界；
- 可记录、可回放、可测试的命令日志。

### 3.4 不迁移：未来由新架构替代

以下实现不值得逐行翻译成 C#：

- `_parse_command` 和 `_parse_ai_question` 的字符串关键词判断；
- `_mock_agent_busy` 与人为延时；
- 固定预设答复作为所谓模型推理；
- AICommandHUD 直接给 `unit.action` 赋值；
- 通过 `MatchSignals.terrain_targeted/unit_targeted` 模拟命令返回值；
- AI HUD 自己维护一套小队状态真相；
- 依赖节点组和 NodePath 向 Agent 暴露游戏对象；
- 将自然语言、UI、规则校验和执行写在同一个脚本中。

这些代码在统一接口具备替代能力后删除，而不是提前删除导致战役无法对照。

## 4. 重构后的目标架构

目标架构分为五层：

```text
┌────────────────────────────────────────────────────┐
│ Command Sources                                    │
│ Human Input | Rule AI | Replay | Future LLM Agent  │
└───────────────────────┬────────────────────────────┘
                        │ Intent / Command Request
┌───────────────────────▼────────────────────────────┐
│ Application                                        │
│ Command Dispatcher | Query Service | Mission Flow  │
└───────────────────────┬────────────────────────────┘
                        │ validated command
┌───────────────────────▼────────────────────────────┐
│ Domain (pure C# where practical)                   │
│ Rules | Economy | Combat | Production | Orders     │
└───────────────────────┬────────────────────────────┘
                        │ state changes / domain events
┌───────────────────────▼────────────────────────────┐
│ Godot Adapter                                      │
│ Nodes | Navigation | Physics | Animation | Audio   │
└───────────────────────┬────────────────────────────┘
                        │ presentation events
┌───────────────────────▼────────────────────────────┐
│ Presentation                                       │
│ HUD | Selection Feedback | Command Feedback        │
└────────────────────────────────────────────────────┘
```

外部基础设施横向接入 Application 端口，包括存档、数据库、日志、HTTP、大模型服务和 Python 进程/服务。领域层不依赖这些实现。

### 4.1 Domain：确定性的游戏规则

领域层优先使用纯 C# 类型，不依赖 `Node`、`SceneTree`、`PackedScene` 或 UI。主要包含：

- `UnitId`、`PlayerId`、`MatchId`、`EntityId` 等稳定标识；
- 单位属性、资源账户、生产队列、命令状态；
- 命令及校验规则；
- 领域事件和结构化错误；
- 可序列化的状态快照。

Godot 的位置类型可在边界转换，领域层可使用自己的不可变坐标值类型，避免业务逻辑绑定引擎对象生命周期。

### 4.2 Application：用例与调度

Application 层负责接收命令、加载操作者上下文、调用规则校验、安排执行顺序并返回结果。建议的核心端口如下：

```csharp
public interface IGameCommandDispatcher
{
    CommandResult Dispatch(CommandContext context, IGameCommand command);
}

public interface IGameQueryService
{
    PlayerSnapshot GetPlayerView(PlayerId viewer);
    UnitSnapshot? GetVisibleUnit(PlayerId viewer, UnitId unitId);
    IReadOnlyList<UnitSnapshot> GetControllableUnits(PlayerId playerId);
}
```

接口名称可以在实际编码前调整，关键要求是：命令有结果，查询受观察者权限限制，调用者不能直接修改状态。

### 4.3 Command Sources：统一入口，不统一决策方式

三类操作者共享命令接口，但不需要共享决策实现：

- Human Adapter 把鼠标、键盘和 HUD 操作转换为命令；
- Rule AI Adapter 根据状态机、行为树或效用系统产生命令；
- Future Agent Adapter 把大模型输出转换成候选意图，再生成命令。

所有来源必须带 `CommandContext`，至少包含操作者、所属玩家、权限、请求编号和时间/模拟 Tick。执行层不应仅凭调用对象的类型决定权限。

### 4.4 Query 与信息边界

写入命令和读取查询必须分离。查询返回的不是 Node，而是不可变快照或 DTO。

至少区分：

- 玩家完全拥有的信息；
- 当前视野内信息；
- 已探索但当前不可见的信息；
- 公共比赛信息；
- 调试/观战权限信息。

现有 `SimpleClairvoyantAI` 可以作为一种显式 `OmniscientDebugPolicy` 暂时保留，但不能让“传统 AI”默认等同于全知权限。

### 4.5 Command Result 与反馈

统一返回结果建议至少包含：

- `Accepted`：命令已接受并开始执行；
- `Completed`：即时命令已完成；
- `PartiallyAccepted`：多选单位中只有部分可执行；
- `Rejected`：权限、资源、目标、视野或状态不合法；
- `NeedsTarget`：命令还需要位置或目标确认；
- `Deferred`：进入生产队列或等待条件。

结果同时服务玩家 HUD、规则 AI 调整策略、未来大模型自我纠错、日志和测试，不能只用无返回值 Signal 表示。

## 5. 命令模型建议

第一阶段不追求一次定义全部命令，而是按传统 RTS 操作逐批建立。

### 5.1 单位控制

- `MoveUnitsCommand`
- `AttackUnitCommand`
- `AttackMoveCommand`
- `StopUnitsCommand`
- `HoldPositionCommand`
- `PatrolCommand`

### 5.2 经济与建造

- `GatherResourceCommand`
- `ReturnCargoCommand`
- `PlaceStructureCommand`
- `ConstructStructureCommand`
- `RepairUnitCommand`

建筑放置建议拆成“查询候选位置合法性”和“提交建造命令”，使玩家蓝图预览不产生游戏状态变更。

### 5.3 生产与集结

- `EnqueueProductionCommand`
- `CancelProductionCommand`
- `SetRallyPositionCommand`
- `SetRallyTargetCommand`

### 5.4 玩家本地状态

选择集和控制组不一定属于权威模拟状态，但必须有清晰的应用层接口：

- `ISelectionService`
- `IControlGroupService`

Human、战役英雄快捷键和未来语音/自然语言选择都应复用它们，AI 不需要伪造鼠标点击或输入动作。

## 6. 事件、信号与命令的分工

现有 `MatchSignals` 不应直接等同于未来 Command API。

- **Command**：请求系统做某件事，有明确操作者、顺序和返回结果；
- **Domain Event**：确定性状态已经发生变化，例如单位死亡、生产完成；
- **Godot Signal**：将领域事件适配给 HUD、声音、动画或场景节点；
- **Input Event**：鼠标键盘输入，只存在于 Human Adapter。

例如右键敌军的正确链路应是：

```text
Godot mouse event
  → HumanInputAdapter
  → AttackUnitCommand(playerId, selectedUnitIds, targetId)
  → permission/visibility/domain validation
  → command execution
  → CommandResult + UnitOrderChanged event
  → HUD/animation/audio adapters
```

规则 AI 和未来大模型从 `AttackUnitCommand` 开始，不经过鼠标事件。

## 7. AI 副官未来重新接入的边界

冻结解除后，大模型仍不直接调用 Godot 或领域对象。建议链路为：

```text
Player text/voice
  → IAgentConversationService
  → structured Intent Proposal
  → Intent Policy / permission check
  → one or more standard RTS Commands
  → IGameCommandDispatcher
  → structured results
  → natural-language explanation
```

建议预留但暂不实现：

```csharp
public interface IAgentIntentInterpreter
{
    Task<IntentProposal> InterpretAsync(
        AgentObservation observation,
        PlayerMessage message,
        CancellationToken cancellationToken);
}
```

`AgentObservation` 必须由 `IGameQueryService` 根据玩家权限构造。模型不得自行查询场景树、数据库表或隐藏单位。

未来模型接入至少满足以下解冻条件：

1. Human 已完全通过公共 Command API 操作核心 RTS 功能；
2. 至少一个传统规则 AI 已通过相同 API 完成经济和战斗闭环；
3. 命令有稳定 ID、结构化结果、日志和回放能力；
4. 查询接口能正确执行战争迷雾与权限过滤；
5. 自动化测试能可靠以非零退出码报告失败；
6. Mock Agent 可仅替换 `IAgentIntentInterpreter` 而不改游戏规则代码；
7. 外部调用具备超时、取消、重试、限流和安全降级策略。

## 8. 分阶段重构计划

### 阶段 0：冻结与基线

- 评审并确认本文；
- 将 AICommandHUD 标记为 Legacy Prototype；
- 普通自定义对局默认不创建 AICommandHUD；
- 战役通过显式开关保留现有演示；
- 修复测试假阳性，使失败必定返回非零；
- 保留重构前手动验收证据。

### 阶段 1：C# 工程骨架与测试

- 建立 C# solution/project、命名空间和程序集边界；
- 建立纯 C# 单元测试与 Godot 集成测试入口；
- 引入稳定实体 ID、命令上下文、结果和错误码；
- 建立 composition root，避免新代码继续增加 Autoload。

### 阶段 2：最小单位命令纵切

- 迁移选择、Move、Stop、Attack；
- Human 适配器调用公共接口；
- Godot Navigation/Action 暂由适配器驱动；
- 用 `TestOneUnit` 和战斗场景回归。

### 阶段 3：经济、建造和生产

- 迁移资源账户、采集、建筑合法性、施工、生产队列和集结点；
- 将数值从场景路径 Dictionary 迁移为强类型配置；
- 建立配置加载、版本和校验。

### 阶段 4：传统规则 AI

- 为规则 AI 提供受权限约束的查询；
- 将 Economy/Defense/Offense 等控制器改为公共命令来源；
- 明确并测试普通 AI 与全知调试 AI 的权限差异；
- 完成人机对局闭环。

### 阶段 5：战役与任务系统

- 将 Mission Dictionary 迁移为强类型任务定义；
- 任务系统监听领域事件和查询快照，不直接检查 HUD 状态；
- 英雄快捷操作迁移到 Selection/Camera 服务；
- Legacy AI HUD 只作为可替换表现层存在。

### 阶段 6：Agent 重新接入评审

- 按解冻条件评审；
- 先实现确定性的 Mock `IAgentIntentInterpreter`；
- 再接入外部大模型服务；
- Python、数据库等通过 Infrastructure 接口接入，不进入 Domain。

## 9. 兼容迁移策略

大规模重构期间，新旧系统需要短期共存。建议采用“纵向切片替换”，而非按文件类型一次重写全部脚本。

每个切片应包含：

1. 新的 C# 接口和领域行为；
2. Godot 场景适配器；
3. Human 调用路径；
4. 如适用，规则 AI 调用路径；
5. 自动化测试；
6. 对应手动验收项；
7. 旧实现删除或明确的临时桥接层。

桥接层只允许依赖方向为：

```text
Legacy GDScript / Godot Node → C# Application API
```

禁止新领域代码反向依赖 Legacy GDScript。Feature Flag 只决定装配哪套适配器，不允许两套系统同时修改同一份状态。

## 10. 团队协作与分支建议

为避免多人重构冲突：

- 先合并接口/骨架 PR，再由不同程序员认领独立命令纵切；
- 单位数值、场景重命名、资源移动与逻辑迁移分开提交；
- 公共接口变更必须更新接口文档和受影响调用者列表；
- 不在功能 PR 中顺手格式化全部 GDScript 或重存大量场景；
- 每个 PR 明确修改的场景、节点名、节点组、输入动作和 Signal；
- 合并前同步最新 main，并运行与切片对应的自动及手动验收；
- Legacy 删除必须证明所有调用者已经迁移，不能凭“看起来没用”删除。

## 11. 本次方案的非目标

本方案当前不决定：

- 大模型供应商、具体模型或计费方案；
- AI 副官人格、剧情文本和美术表现；
- Python 使用进程、HTTP 服务还是其他 IPC；
- 最终数据库产品；
- 联机协议和确定性同步的完整实现。

这些选择应在公共命令、查询和状态边界稳定后分别形成 ADR。现在过早选择会让外部技术反向污染 RTS 核心。

## 12. 验收标准

本方案阶段性成功不以“GDScript 数量归零”衡量，而以以下结果衡量：

- Human 与规则 AI 对相同操作调用相同 Command API；
- 任何调用者都不能绕过权限和规则直接修改领域状态；
- 核心命令可在无 UI、尽量无 Godot 场景的测试中执行；
- 命令失败有稳定错误码和可显示原因；
- 战争迷雾对玩家、规则 AI 和未来 Agent 使用同一信息边界；
- 传统 RTS 功能达到或超过重构前手动验收基线；
- AI 副官的重新接入只新增 Adapter/Infrastructure，不修改核心 RTS 规则。
