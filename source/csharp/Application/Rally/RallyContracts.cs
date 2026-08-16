using AI_RTS.Application.Commands;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Rally;

namespace AI_RTS.Application.Rally;

/// <summary>请求多座生产者设置相同位置集结目标。</summary>
public sealed record SetRallyPositionCommand(
    IReadOnlyList<UnitId> ProducerIds,
    WorldPosition Destination);

/// <summary>请求多座生产者设置相同实体或资源集结目标。</summary>
public sealed record SetRallyTargetCommand(
    IReadOnlyList<UnitId> ProducerIds,
    RallyTarget Target);

/// <summary>请求多座生产者清除自定义集结目标并回归默认出口。</summary>
public sealed record ClearRallyPointCommand(IReadOnlyList<UnitId> ProducerIds);

/// <summary>提供集结命令校验所需的生产者能力快照。</summary>
public readonly record struct RallyProducerSnapshot(
    UnitId ProducerId,
    PlayerId OwnerId,
    bool IsAlive,
    bool IsConstructed,
    bool CanSetRallyPoint);

/// <summary>提供友军实体集结目标的所有权和观察状态。</summary>
public readonly record struct RallyUnitTargetSnapshot(
    UnitId UnitId,
    PlayerId OwnerId,
    bool IsAlive,
    bool IsObservable);

/// <summary>提供资源集结目标的存续和观察状态。</summary>
public readonly record struct RallyResourceTargetSnapshot(
    ResourceNodeId ResourceNodeId,
    bool IsAvailable,
    bool IsObservable);

/// <summary>查询可设置集结点的生产者。</summary>
public interface IRallyProducerRepository
{
    /// <summary>按稳定身份查询生产者；不存在时返回 null。</summary>
    RallyProducerSnapshot? Find(UnitId producerId);
}

/// <summary>查询实体与资源集结目标，不向核心暴露 Godot Node。</summary>
public interface IRallyTargetRepository
{
    /// <summary>查询单位或建筑目标。</summary>
    RallyUnitTargetSnapshot? FindUnit(UnitId unitId, PlayerId observerId);

    /// <summary>查询资源节点目标。</summary>
    RallyResourceTargetSnapshot? FindResource(ResourceNodeId resourceNodeId, PlayerId observerId);
}

/// <summary>验证位置是否位于当前地图可用范围，不承担寻路可达性计算。</summary>
public interface IRallyPositionValidator
{
    /// <summary>返回有限坐标是否位于对局地图范围。</summary>
    bool IsInsideMap(WorldPosition position);
}

/// <summary>表示自定义集结目标已经建立或替换。</summary>
public sealed record RallyPointChanged(
    RallyPointSnapshot Current,
    RallyPointSnapshot? Previous,
    long SimulationTick);

/// <summary>表示自定义集结目标已经清除并回归默认出口。</summary>
public sealed record RallyPointCleared(
    RallyPointSnapshot Previous,
    RallyPointClearReason Reason,
    long SimulationTick);

/// <summary>提供集结点命令、查询和目标失效入口。</summary>
public interface IRallyPointService
{
    /// <summary>自定义目标变化时发布；幂等重复设置不发布。</summary>
    event Action<RallyPointChanged>? Changed;

    /// <summary>自定义目标清除时发布。</summary>
    event Action<RallyPointCleared>? Cleared;

    /// <summary>设置批量位置集结点。</summary>
    CommandResult SetPosition(CommandContext context, SetRallyPositionCommand command);

    /// <summary>设置批量实体或资源集结点。</summary>
    CommandResult SetTarget(CommandContext context, SetRallyTargetCommand command);

    /// <summary>显式清除批量集结点。</summary>
    CommandResult Clear(CommandContext context, ClearRallyPointCommand command);

    /// <summary>目标失效时清除所有引用它的自定义集结点。</summary>
    void LoseTarget(RallyTarget target, long simulationTick);

    /// <summary>生产者失效时清除其自定义集结点。</summary>
    void LoseProducer(UnitId producerId, long simulationTick);

    /// <summary>读取生产者当前自定义集结点；null 表示使用默认出口。</summary>
    RallyPointSnapshot? Find(UnitId producerId);
}
