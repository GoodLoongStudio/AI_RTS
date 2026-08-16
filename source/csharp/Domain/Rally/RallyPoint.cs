using AI_RTS.Domain.Common;

namespace AI_RTS.Domain.Rally;

/// <summary>表示生产者出厂后可使用的强类型集结目标。</summary>
public abstract record RallyTarget;

/// <summary>表示一个不要求设置时即可达的世界位置集结目标。</summary>
public sealed record RallyPositionTarget(WorldPosition Position) : RallyTarget;

/// <summary>表示一个同玩家单位或建筑集结目标。</summary>
public sealed record RallyUnitTarget(UnitId TargetUnitId) : RallyTarget;

/// <summary>表示一个资源节点集结目标。</summary>
public sealed record RallyResourceTarget(ResourceNodeId TargetResourceId) : RallyTarget;

/// <summary>保存单座生产者当前自定义集结目标及稳定版本。</summary>
public sealed record RallyPointSnapshot(
    UnitId ProducerId,
    PlayerId OwnerId,
    RallyTarget Target,
    long Version,
    long UpdatedAtTick);

/// <summary>表示清除自定义集结点的权威原因。</summary>
public enum RallyPointClearReason
{
    /// <summary>拥有者显式清除。</summary>
    Explicit,
    /// <summary>实体或资源目标已经失效。</summary>
    TargetLost,
    /// <summary>生产者已经失效。</summary>
    ProducerLost
}
