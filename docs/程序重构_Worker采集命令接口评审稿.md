# Worker 采集命令接口评审稿

> 状态：2026-08-14 已评审，按第 12 节结论实施
>
> 对应工作项：`CMD-026B`、`ECO-002`
> 本稿只确定采集命令与任务生命周期；施工、建筑放置和完整资源账户迁移分别进入后续切片。

## 1. 当前实现与直接迁移风险

当前 Worker 右键矿石后直接创建 `CollectingResourcesSequentially`。一个 GDScript 组合 Action 同时承担：

- 前往资源点；
- 按计时器采集并修改矿石、Worker 携带量；
- 寻找最近 CommandCenter；
- 返回并直接修改 `Player.resource_a/resource_b`；
- 返回原资源点或在附近自动选择新资源点。

该实现没有公共命令回执、稳定采集订单、阶段查询或结束原因。现有统一 Stop 桥也只识别移动与攻击 Action；如果现在仅把 Worker 加入 Tank/Helicopter 的迁移白名单，Stop 会返回 `Accepted`，但采集组合 Action 仍可能继续移动或采集。这属于假回执，禁止作为过渡方案。

资源节点也不是 `Unit.gd`，当前 `GodotUnitRegistry` 不能安全把它当作普通 `UnitId` 查询。采集目标需要独立、明确的稳定身份。

## 2. 建议的首轮范围

首轮纵向样例只迁移“右键一个资源点并持续采集”的公共边界：

```csharp
namespace AI_RTS.Application.Commands.Units;

/// <summary>请求一组 Worker 以指定资源点为起始目标持续采集并自动送回。</summary>
public sealed record GatherResourcesCommand(
    IReadOnlyList<UnitId> WorkerIds,
    ResourceNodeId TargetResourceId);
```

```csharp
namespace AI_RTS.Domain.Common;

/// <summary>标识一个可被采集命令引用的资源节点。</summary>
/// <param name="Value">当前对局内唯一的 Guid 值。</param>
public readonly record struct ResourceNodeId(Guid Value);
```

命令表示持续任务，而不是“只拿一个资源”或“只完成一趟运输”。它保持当前 RTS 操作习惯：玩家右键一次后，Worker 持续执行采集—返程—交付循环，直到 Stop、替换命令、单位损失或没有可继续采集的资源。

首轮不把资源数量、玩家账户或采集速度全部搬入 Domain。它们可暂由 `IWorkerTaskPort` 适配现有场景实现，但 Application 必须拥有命令校验、订单身份与暂停状态；后续 `ECO-001`/`ECO-007` 可替换端口内部实现而不改变命令 DTO。

## 3. 能力与目标快照

建议为命令校验增加最小能力与资源查询，而不是根据 Godot 脚本文件名判断：

```csharp
public readonly record struct UnitCommandSnapshot(
    UnitId UnitId,
    PlayerId OwnerId,
    bool CanMove,
    bool CanGather,
    // 既有字段保持不变
);

public readonly record struct ResourceNodeSnapshot(
    ResourceNodeId ResourceNodeId,
    ResourceKind Kind,
    bool IsAvailable);

public interface IResourceNodeRepository
{
    ResourceNodeSnapshot? Find(ResourceNodeId resourceNodeId);
}
```

`ResourceKind` 进入强类型枚举，首版包含 A、B；不把场景脚本属性名 `resource_a/resource_b` 暴露到命令接口。

## 4. 执行端口

建议新增独立工作端口，不把采集伪装成移动：

```csharp
public interface IWorkerTaskPort
{
    /// <summary>开始或重新开始指定 Worker 的持续采集任务。</summary>
    WorkerTaskPortResult RequestGather(UnitId workerId, ResourceNodeId resourceNodeId);

    /// <summary>暂停当前可保留工作任务；没有工作任务时返回幂等成功。</summary>
    WorkerTaskPortResult RequestSuspend(UnitId workerId);
}
```

Godot Adapter 第一版仍可创建 Legacy 组合 Action，但必须增加明确的暂停入口。暂停不能把整个 Action 直接销毁：它要保留资源目标、当前阶段和 Worker 已携带资源，同时停止导航、采集计时器与交付状态推进。

## 5. 同步回执与错误码

`GatherResources` 按 Worker 独立校验，允许多选部分成功：

| 情况 | 单位结果 |
|---|---|
| Worker 属于发出者、具备采集能力、目标可用 | `Accepted` |
| 选中了 Tank/Helicopter 等非采集单位 | `UnitCannotGather` |
| Worker 不属于发出者 | `UnitNotOwned` |
| Worker 已死亡或失效 | `UnitNotFound` |
| 资源节点不存在 | `ResourceTargetNotFound` |
| 资源节点已经耗尽 | `ResourceDepleted` |
| Legacy 工作适配器无法接收 | `WorkUnavailable` |

整个批次仍使用 `Accepted / PartiallyAccepted / Rejected`，每个被接受的 Worker 获得独立 `UnitOrderId`。同步接受只表示采集任务已经合法建立，不表示已获得或交付资源。

## 6. 订单、Stop 与恢复

新增 `UnitOrderKind.Gather`。建议采用以下已评审 Stop 原则：

| 操作 | Gather 订单 | Worker 行为 |
|---|---|---|
| 统一 Stop | `Suspended` | 保留目标、阶段与携带资源；停止移动和采集；不自动恢复 |
| 再次右键同一或其他资源点 | 旧订单 `Cancelled`，新订单 `InProgress` | 以新命令恢复/替换任务，携带资源不丢失 |
| 普通 Move/ForceMove | 旧订单 `Cancelled` | 离开工作任务，携带资源保留 |
| Worker 死亡 | `UnitLost` | 由未来资源掉落规则决定携带资源去向，首轮不擅自设计 |

底层 `HaltMovement` 与玩家统一 Stop 继续区分：

- `HaltMovement` 只停止导航；Worker 已经贴近资源点并正在采集时不暂停采集；
- 玩家 HUD 的统一 Stop 暂停整个 Gather 任务，包括采集计时器；
- 第一版不增加独立 Resume 按钮；再次下达 Gather 产生新订单并恢复任务。未来如 UI/策划需要，可再增加 `ResumeWorkCommand`。

## 7. 资源耗尽与任务结束

评审决定首轮不自动寻找附近资源。自动换点可能让 Worker 未经玩家确认离开安全区并进入危险位置，其行为需要策划组结合警戒、护航和自动化程度继续评审。

确定规则如下：

1. 命令只绑定玩家明确点击的资源节点；
2. 资源耗尽且 Worker 有携带资源时，完成最后一次返程交付；
3. 资源耗尽且 Worker 没有携带资源时，直接结束任务并待机；
4. 最后一次交付完成后订单进入 `Completed`，Worker 待机；
5. 资源目标因剧情或其他非正常原因失效时，订单进入 `TargetLost`；是否允许返程交付由当时携带状态决定，但不得自动选择新矿。

因此为 `UnitOrderState` 增加通用终态 `Completed`。资源耗尽是正常完成，不使用 `TargetLost`。

## 8. 异步事件与反馈

建议内部事件至少包括：

- `GatherStarted`；
- `CargoChanged`；
- `ResourcesDelivered`；
- `GatherSuspended`；
- `GatherCompleted`；
- `GatherTargetLost`。

这些是权威内部事实，不代表所有控制者都能直接收到。Human 是否播放“资源已送达”、规则 AI 是否收到事件、未来大模型是否必须消耗观察点，仍由反馈与观察策略过滤。

## 9. 施工为何不并入本切片

施工还涉及建筑放置合法性、资源扣除原子性、蓝图身份、多 Worker 协作、取消退款和 `StructureConstructionCompleted` 事件。把它与 Gather 同时迁移会掩盖接口问题。因此建议顺序为：

1. `CMD-026B / ECO-002`：Gather 命令、Stop 暂停、再下令恢复、一次交付循环；
2. `ECO-001`：玩家资源账户与资源变更规则；
3. `ECO-003 / ECO-004`：建筑放置与 Construct 命令；
4. `ECO-005 / ECO-006`：生产队列与集结点。

## 10. 首轮验收建议

建立一个只包含 Human CommandCenter、两个 Worker、A/B 资源点的场景，自动与人工验证：

1. Worker 右键资源点获得 Gather 订单并开始移动；
2. Tank 与 Worker 混选时返回 `PartiallyAccepted`；
3. Worker 采到资源并完成一次交付，玩家账户增加且订单仍持续；
4. 去程、采集中、返程分别按 Stop，均进入 `Suspended` 且不自动恢复；
5. Stop 后携带资源、目标和阶段不丢失；
6. 再次右键资源点产生新订单并恢复；
7. 普通 Move 替换 Gather，但不清空携带资源；
8. 资源耗尽时不自动换点；完成最后一次交付后待机；
9. Worker 死亡进入 `UnitLost`；
10. 全部即时回执与异步事件可被测试记录，但不会默认暴露给未来大模型控制器。

## 11. 经济账户解耦约束

玩家经济不能建模为 Gather 的内部字段或只允许采集交付写入。后续 `ECO-001` 应提供独立资源账户边界，所有来源以统一交易/变更记录入账，例如：

| 来源 | 示例 |
|---|---|
| Worker 交付 | Worker 抵达有效交付点后，把携带资源计入玩家账户 |
| 任务奖励 | 完成战役目标后一次性奖励 |
| 被动生产 | 固定矿场、天然气井、油井按模拟时间产出 |
| 退款/补偿 | 取消建筑、生产或脚本补偿 |

建议资源变更至少保留 `PlayerId`、`ResourceKind`、数量、来源种类、来源实体/任务标识和模拟 Tick。Gather 只能在“交付完成”事件中申请一笔 `WorkerDelivery` 交易；不能直接拥有玩家余额。

本轮继续适配 Legacy `Player.resource_a/resource_b`，但必须把写入集中在交付端口，便于以后替换为通用资源账户服务。任务奖励与被动经济建筑本轮不实现。

## 12. 评审结论

2026-08-14 确认：

1. `GatherResourcesCommand` 表示持续的采集—返程—交付循环；只有交付完成后玩家资源增加；Worker 返程中死亡时，未交付载荷丢失；
2. 统一 Stop 暂停整个采集任务且不自动恢复；
3. 首版不增加 `ResumeWorkCommand`。玩家再次右键资源点会创建新 Gather 订单；自动开始挖矿、采集/建造工作优先级作为未来 Worker 能力策略待策划评审；
4. 资源耗尽后不自动寻找新资源；有载荷则完成最后一次交付，之后 Worker 待机。

## 13. 人工验收补充

2026-08-14 采集—返程—交付循环人工验收通过。验收发现：Worker 携带载荷并被 Stop 暂停后，当前需再次右键资源点才能建立新 Gather 并先返程交付，右键 CommandCenter/资源交付建筑不会直接触发交付。

该行为不在已评审的 `GatherResourcesCommand(ResourceNodeId)` 契约内，也可能与后续上下文右键分派发生冲突，因此本轮不修改接口或实现。后续以 `CMD-031` 单独评审 `ReturnCargoCommand`、交付目标类型、交付后的任务状态及与采集/建造意图的优先级。
