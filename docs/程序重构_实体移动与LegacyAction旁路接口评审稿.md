# 程序重构：实体移动与 Legacy Action 旁路接口评审稿

> 对应进度：`CMD-026C`、`ARCH-015`
>
> 本轮迁移旧项目已经存在的 Drone 普通控制、右键实体靠近/跟随和生产集结分派，不新增护航、巡逻、编队或目标优先级机制。

## 1. 审计结论

`UnitActionsController.gd` 仍存在 8 处由 Human 输入调用方直接赋值 `Unit.action` 的路径：

| 旧路径 | 当前原因 | 处理建议 |
|---|---|---|
| 地面普通 Move 回退 | `_is_migrated_command_unit` 只硬编码 Tank、Helicopter、Worker，Drone 被排除 | 删除回退，所有候选统一提交公共 Move，由 C# 逐单位校验能力 |
| 空中点击实体位置 Move 回退 | 同上 | 删除回退，Drone 也走公共 Move |
| Gather 回退 | Worker 已迁移，当前基本属于不可达兼容路径 | 删除回退 |
| Attack 回退 | 当前攻击单位已迁移，但未来新单位可能再次绕过 | 删除回退 |
| Construct 回退 | Worker 已迁移，当前基本属于不可达兼容路径 | 删除回退 |
| Following | 公共命令尚无持续跟随语义 | 新增 `FollowEntityCommand` |
| MovingToUnit | 公共命令尚无靠近实体语义 | 新增 `ApproachEntityCommand` |
| 第二处普通 Move 回退 | 空中实体点击分派中的同类兼容路径 | 删除回退 |

规则 AI 的 Drone 巡逻已经使用稳定 ID 和公共 Move；当前不一致只发生在玩家控制 Drone 时。继续维护类型白名单会使每种新单位都必须修改 Human Controller，也会让未来单位在遗漏时静默退回直接 Action。

生产集结点还有两处同类旁路：

- 非 Worker 出厂后靠近资源时，`RallyPointRuntime` 直接调用 `request_legacy_move_to_unit`；
- 出厂单位跟随己方移动目标时，直接调用 `request_legacy_follow`。

两者应改用同一公共命令，以便产生可查询、可停止、可替换的权威订单。

## 2. 允许保留的 Legacy 边界

本轮不把 Godot 导航 Action 翻译成 C#。以下写入属于迁移期允许清单：

- `Unit.gd` 的 `request_legacy_*` 方法：只允许由 GodotAdapter 端口调用；
- `LegacyMovementPort`、`LegacyAttackPort`、Worker/Construction 端口：把已通过 Application 校验的命令转换为表现执行；
- `MovingToUnit.gd`、`Following.gd` 及其他 Action 内部的子 Action：属于执行器内部状态；
- Tank、Helicopter、Turret 初始化自主索敌 Action：属于当前单位执行端的待机表现；
- 建筑放置时的友军驱逐：属于 `CommandRuntime` 内部系统动作，需在 Legacy 允许清单中单独登记，不开放给 Human/AI 调用方。

以下位置不再允许直接写入或直接调用 `request_legacy_*`：

- Human 输入控制器和 HUD；
- 规则 AI、战役任务和未来大模型 Adapter；
- Rally、生产等上层系统分派器。

## 3. 新增命令语义

### 3.1 ApproachEntity

```csharp
public sealed record ApproachEntityCommand(
    IReadOnlyList<UnitId> UnitIds,
    BattlefieldEntityId TargetEntityId);
```

- 含义：移动至目标 footprint 邻接位置；不持续保持编队或护航关系；
- 目标移动时执行端可以更新路径，直到真正邻接；
- 邻接后订单进入 `Arrived`；
- 目标先失效时进入 `TargetLost`；
- 新命令替换时进入 `Cancelled`；
- Stop/Halt 后进入 `Suspended`，停止移动且不自动恢复；
- 不附带攻击、采集、施工或集结语义。

### 3.2 FollowEntity

```csharp
public sealed record FollowEntityCommand(
    IReadOnlyList<UnitId> UnitIds,
    UnitId TargetUnitId);
```

- 含义：持续追踪目标并保持 Legacy 邻接距离；
- 目标仍存在时不会因为一次靠近而进入 `Arrived`，订单保持 `InProgress`；
- 目标失效时进入 `TargetLost`；
- 新命令替换时进入 `Cancelled`；
- Stop/Halt 后进入 `Suspended`，不自动恢复；
- 首版不附带护航自动攻击、队形保持、最大跟随距离或目标切换。

`ApproachEntity` 与 `FollowEntity` 必须分开。前者是有完成点的一次移动，后者是持续关系；若复用同一订单种类，查询、Stop、任务事件和未来 AI 都无法区分。

## 4. 公共契约变化

建议扩展：

```csharp
public interface IUnitCommandService
{
    CommandResult ApproachEntity(
        CommandContext context,
        ApproachEntityCommand command);

    CommandResult FollowEntity(
        CommandContext context,
        FollowEntityCommand command);
}

public interface IUnitMovementPort
{
    MovementPortResult RequestApproachEntity(UnitId unitId, UnitId targetId);
    MovementPortResult RequestFollowEntity(UnitId unitId, UnitId targetId);
}
```

`UnitOrderKind` 增加 `ApproachEntity` 与 `FollowEntity`，目标统一保存为 `UnitOrderEntityTarget`。目标 ID 必须属于当前 Match，执行单位必须存在、属于发出者且具备移动能力；目标不能是执行单位自身。

命令服务不根据 Tank、Drone 等具体类型判断能力。Godot 注册快照中的 `CanMove` 和执行端口结果负责能力校验，混合选择继续返回逐单位结果与 `PartiallyAccepted`。

## 5. 权限与可见性边界

公共 Application 服务本身属于可信对局执行层，不应直接暴露给大模型：

- Human Gateway 只把当前可点击到的 Godot 实体转换为目标；
- 规则 AI 和未来大模型只能通过绑定身份的受限 Adapter 提交稳定 ID；
- 受限 Adapter 必须使用当前 QuerySession/观察结果授权非己方目标，不能因为猜中 UnitId 就绕过战争迷雾；
- 目标不可见、未知和不存在对受限 AI 统一返回 `TargetUnavailable`，避免用错误差异探测隐藏信息；
- 己方目标保持准确可用，不受战争迷雾限制。

本轮 Human 迁移和 Rally 系统分派不增加新的大模型入口；只预留上述授权位置。

## 6. 右键上下文保持

本轮保持现有判定顺序：

1. Worker 对资源优先 Gather；
2. 可攻击单位右键合法敌方优先普通 Attack；
3. Worker 对己方施工现场优先 Construct；
4. 对己方或敌方单位且可 Follow 时使用 FollowEntity；
5. 其他可移动地面单位使用 ApproachEntity；
6. 没有更高优先级实体交互的空中单位继续把点击解释为普通位置 Move；
7. 生产建筑按 Rally 服务处理目标。

该顺序只记录迁移基线，不代表正式版本的最终操作设计。未来快捷键、移动要塞、伪装或新型右键行为仍需单独评审。

## 7. Stop 与生命周期

当前 `request_legacy_stop` 未清除 `MovingToUnit` 和 `Following`，这会造成 Drone 或其他单位持续前进。迁移时应补齐：

- Stop 和 Halt 都会停止 Approach/Follow 的实际移动；
- 权威订单转为 `Suspended`，保留原目标供查询，但首版没有 Resume；
- 新命令会替换并取消该暂停订单；
- Approach 的完成必须由明确的 Action 终态信号驱动，不能把一次中间路径的 `movement_finished` 误判为已经邻接；
- Follow 不监听普通移动完成作为终态，只监听目标失效、单位损失、Stop 和命令替换。

## 8. 实施切片

1. 新增两个命令 DTO、订单种类、服务方法、端口方法和纯 C# 测试；
2. 扩展 LegacyMovementPort 与 `Unit.gd` 桥接信号，建立正确终态；
3. 扩展 CommandRuntime、UnitCommandGateway 和稳定结果转换；
4. 删除 Human Controller 的 `_is_migrated_command_unit` 和全部直接 Action 回退；
5. 将 RallyPointRuntime 的实体靠近/跟随改走公共命令；
6. 将战斗策略过滤从具体类名改为现有能力特征，避免新单位再次修改硬编码白名单；
7. 增加 Drone 玩家控制、Approach、Follow、Stop、目标失效和 Rally 出厂任务自动测试；
8. 回归 Tank、Helicopter、Worker、生产集结与规则 AI Drone 巡逻。

## 9. 建议评审结论

建议本轮确认：

1. 接受 `ApproachEntity` 与 `FollowEntity` 分为两个公共命令；
2. Approach 到达邻接位置后完成，Follow 在目标存在时持续进行；
3. 两者被 Stop/Halt 后均暂停且不自动恢复，新命令可替换；
4. 目标失效统一进入 `TargetLost`；
5. 保持当前右键上下文优先级，仅迁移不重新设计；
6. 删除 Human Controller 的具体单位类型白名单与所有直接 Action 回退；
7. Rally 出厂靠近/跟随也改走相同公共命令；
8. Legacy Action 只保留为 GodotAdapter 执行端，导航实现本身留给后续导航专项；
9. 受限 AI 对非己方实体必须经过观察授权，未知、不可见与不存在统一拒绝。

2026-08-15 项目负责人确认接受以上九项，可以进入实现。

## 10. 实现与自动验证记录

2026-08-15 已完成代码纵向切片，当前等待人工验收：

- `ApproachEntity` 使用 `BattlefieldEntityId`，支持单位、建筑和资源节点；这是为了覆盖已评审的非 Worker 资源集结行为，避免把中立资源错误注册为玩家单位；
- `FollowEntity` 只接受单位或建筑稳定 ID，与一次性 Approach 保持独立订单种类；
- 两类订单已贯通 `IUnitCommandService`、`IUnitMovementPort`、`CommandRuntime`、`UnitCommandGateway` 和查询观察枚举；
- Approach 只在真正邻接后进入 `Arrived`；Follow 不把中间移动完成视为终态；目标退出进入 `TargetLost`；
- Stop/Halt 会停止两类实际 Action，并将活动订单保留为 `Suspended`，不会自动恢复；
- Human Controller 已删除 Tank/Helicopter/Worker 类型白名单及全部直接 Action 回退；
- Rally 的非 Worker 资源靠近和友军实体跟随已改用相同公共命令；
- 战斗策略筛选改用现有攻击/生产能力特征，不再依赖具体单位类名；
- 审计时发现所有 Unit 因继承通用桥接方法而被误判为可采集；现已要求 `resources_max > 0`，Drone 不再错误进入 Gather；
- 核心测试新增 3 项，全套 90 项通过；AirEntityMove、RallyPoint、WorkerGather、RuleAiIntelligence、TraditionalUnitCommandHud、MultiUnitCommand、ProductionQueue、CSharpCommand 与 WorldQueryRuntime 共 9 个 Godot 回归均为 0 失败；
- 无头退出继续报告已登记的导航 RID/ObjectDB 泄漏；`TestAllUnits.tscn` 的现有 UID 警告及用户修改未纳入本项变更。

## 11. 人工验收记录

2026-08-15 项目负责人完成五项关键人工测试，全部通过：

- Drone 的实体 Approach 行为符合预期；
- Drone 的持续 Follow 行为符合预期；
- Stop/Halt 能暂停实体移动任务，且不会自动恢复；
- 目标失效能够结束任务并反馈 `TargetLost`；
- 生产集结的实体靠近/跟随链路无回归。

据此，`CMD-026C` 完成人工验收；`CMD-026` 按当前 Demo 已存在的 Tank、Helicopter、Worker、Drone 与施工单位类型收口。旧仓库中不存在的步兵等新增单位不作为本次重构的迁移门槛，后续应通过相同公共命令契约接入。
