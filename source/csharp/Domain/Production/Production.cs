using AI_RTS.Domain.Common;
using AI_RTS.Domain.Construction;
using AI_RTS.Domain.Economy;

namespace AI_RTS.Domain.Production;

/// <summary>标识一种可进入生产队列的单位定义。</summary>
public readonly record struct ProductionDefinitionId(string Value);

/// <summary>标识一条生产队列中的稳定项目。</summary>
public readonly record struct ProductionItemId(Guid Value);

/// <summary>表示生产项目从入队到终止的权威状态。</summary>
public enum ProductionItemState
{
    /// <summary>已扣款并排队，尚未取得生产线。</summary>
    Queued,

    /// <summary>位于队首并正在推进工作量。</summary>
    Producing,

    /// <summary>生产工作量已完成，正在等待合法部署位置。</summary>
    AwaitingDeployment,

    /// <summary>单位已经成功生成。</summary>
    Completed,

    /// <summary>拥有者主动取消并执行退款。</summary>
    Cancelled,

    /// <summary>生产建筑失效，项目终止且不退款。</summary>
    ProducerLost
}

/// <summary>描述不依赖引擎对象的生产成本、工时与生产建筑资格。</summary>
/// <param name="DefinitionId">稳定生产定义 ID。</param>
/// <param name="RequiredWork">完成生产所需的正整数工作量。</param>
/// <param name="Cost">入队时一次性支付的非负资源成本。</param>
/// <param name="AllowedProducerDefinitions">允许执行该生产定义的建筑类型。</param>
/// <param name="ProductTypeId">成功部署后生成的稳定战场实体类型。</param>
public sealed record ProductionDefinition(
    ProductionDefinitionId DefinitionId,
    int RequiredWork,
    IReadOnlyList<ResourceAmount> Cost,
    IReadOnlySet<StructureDefinitionId> AllowedProducerDefinitions,
    UnitTypeId ProductTypeId = default);

/// <summary>保存单个生产项目的稳定身份、进度、支付和生命周期。</summary>
public sealed record ProductionItemSnapshot(
    ProductionItemId ItemId,
    UnitId ProducerId,
    PlayerId OwnerId,
    ProductionDefinitionId DefinitionId,
    int RequiredWork,
    int CompletedWork,
    IReadOnlyList<ResourceAmount> PaidCost,
    ProductionItemState State,
    long Version,
    UnitId? ProducedUnitId = null);

/// <summary>描述生产建筑在当前 Match 中的能力与可运行状态。</summary>
/// <param name="ProducerId">生产建筑的对局内稳定身份。</param>
/// <param name="OwnerId">当前拥有者。</param>
/// <param name="DefinitionId">稳定建筑类型。</param>
/// <param name="IsAlive">是否仍可被生产服务引用。</param>
/// <param name="IsConstructed">是否已经完成施工。</param>
/// <param name="QueueLimit">该建筑实例允许的活动生产项目上限。</param>
public sealed record ProductionProducerSnapshot(
    UnitId ProducerId,
    PlayerId OwnerId,
    StructureDefinitionId DefinitionId,
    bool IsAlive,
    bool IsConstructed,
    int QueueLimit = 5);
