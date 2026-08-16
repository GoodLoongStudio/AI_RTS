using AI_RTS.Application.Commands;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Production;

namespace AI_RTS.Application.Production;

/// <summary>请求向一座生产建筑加入一种单位。</summary>
public sealed record EnqueueProductionCommand(
    UnitId ProducerId,
    ProductionDefinitionId DefinitionId);

/// <summary>请求取消一个稳定生产项目。</summary>
public sealed record CancelProductionItemCommand(ProductionItemId ItemId);

/// <summary>表示生产命令的稳定处理结果。</summary>
public enum ProductionCommandStatus
{
    /// <summary>命令已经完整应用。</summary>
    Accepted,
    /// <summary>生产建筑不存在或已经失效。</summary>
    ProducerNotFound,
    /// <summary>生产建筑不属于命令发出者。</summary>
    ProducerNotOwned,
    /// <summary>生产建筑尚未完成施工。</summary>
    ProducerNotConstructed,
    /// <summary>产品定义不存在或无效。</summary>
    DefinitionNotFound,
    /// <summary>该建筑不具备目标产品的生产能力。</summary>
    ProductNotAllowed,
    /// <summary>生产队列已经达到容量上限。</summary>
    QueueFull,
    /// <summary>玩家资源不足。</summary>
    InsufficientResources,
    /// <summary>生产项目不存在。</summary>
    ItemNotFound,
    /// <summary>生产项目已进入终态。</summary>
    ItemNotActive,
    /// <summary>账户或部署执行端暂时不可用。</summary>
    ExecutionUnavailable
}

/// <summary>返回生产命令状态及其项目快照。</summary>
public sealed record ProductionCommandResult(
    CommandId CommandId,
    ProductionCommandStatus Status,
    ProductionItemSnapshot? Item);

/// <summary>提供稳定生产定义查询。</summary>
public interface IProductionDefinitionRepository
{
    /// <summary>按稳定定义 ID 查询产品；不存在时返回 null。</summary>
    ProductionDefinition? Find(ProductionDefinitionId definitionId);
}

/// <summary>提供生产建筑的只读能力与状态快照。</summary>
public interface IProductionProducerRepository
{
    /// <summary>按稳定 UnitId 查询生产建筑；不存在时返回 null。</summary>
    ProductionProducerSnapshot? Find(UnitId producerId);
}

/// <summary>表示部署端一次尝试的结果。</summary>
public enum ProductionDeploymentStatus
{
    /// <summary>单位已生成并取得稳定 UnitId。</summary>
    Deployed,
    /// <summary>出口或合法空间暂时被阻挡，可以稍后重试。</summary>
    Blocked,
    /// <summary>部署端或定义映射不可用。</summary>
    Unavailable
}

/// <summary>返回部署状态及成功时的新单位 ID。</summary>
public readonly record struct ProductionDeploymentResult(
    ProductionDeploymentStatus Status,
    UnitId? ProducedUnitId = null);

/// <summary>隔离生产核心与 Godot 出生位置、节点生成及旧 Signal。</summary>
public interface IProductionDeploymentPort
{
    /// <summary>尝试部署一个已完成工作量的生产项目。</summary>
    ProductionDeploymentResult TryDeploy(ProductionItemSnapshot item);
}

/// <summary>表示项目已经完成扣款并进入队列。</summary>
public sealed record ProductionQueued(ProductionItemSnapshot Item, long SimulationTick);

/// <summary>表示项目首次成为队首并开始推进。</summary>
public sealed record ProductionStarted(ProductionItemSnapshot Item, long SimulationTick);

/// <summary>表示队首生产项目的整数工作量已经推进。</summary>
public sealed record ProductionProgressed(ProductionItemSnapshot Item, long SimulationTick);

/// <summary>表示项目工作量完成但尚未成功部署。</summary>
public sealed record ProductionAwaitingDeployment(
    ProductionItemSnapshot Item,
    long SimulationTick);

/// <summary>表示单位已经成功生成。</summary>
public sealed record UnitProductionCompleted(
    ProductionItemSnapshot Item,
    UnitId ProducedUnitId,
    long SimulationTick);

/// <summary>表示生产项目因主动取消或建筑失效进入终态。</summary>
public sealed record ProductionTerminated(ProductionItemSnapshot Item, long SimulationTick);

/// <summary>提供 Match 范围的生产队列、进度、退款与部署入口。</summary>
public interface IProductionService
{
    /// <summary>项目完成扣款并入队后发布。</summary>
    event Action<ProductionQueued>? Queued;

    /// <summary>项目首次取得生产线时发布。</summary>
    event Action<ProductionStarted>? Started;

    /// <summary>队首项目工作量变化后发布。</summary>
    event Action<ProductionProgressed>? Progressed;

    /// <summary>项目首次进入等待部署时发布。</summary>
    event Action<ProductionAwaitingDeployment>? AwaitingDeployment;

    /// <summary>单位成功生成后发布。</summary>
    event Action<UnitProductionCompleted>? Completed;

    /// <summary>项目主动取消或因生产建筑失效时发布。</summary>
    event Action<ProductionTerminated>? Terminated;

    /// <summary>提交一项生产并执行原子扣款。</summary>
    ProductionCommandResult Enqueue(
        CommandContext context,
        EnqueueProductionCommand command);

    /// <summary>由拥有者取消一项未完成生产并全额退款。</summary>
    ProductionCommandResult Cancel(
        CommandContext context,
        CancelProductionItemCommand command);

    /// <summary>取消指定生产建筑当前全部项目，并返回逐项结果。</summary>
    IReadOnlyList<ProductionCommandResult> CancelAll(
        CommandContext context,
        UnitId producerId);

    /// <summary>把生产建筑的全部非终态项目标记为 ProducerLost，不退款。</summary>
    void LoseProducer(UnitId producerId, long simulationTick);

    /// <summary>每个模拟 Tick 推进一次队首并尝试部署。</summary>
    void Advance(long simulationTick);

    /// <summary>查询稳定项目快照。</summary>
    ProductionItemSnapshot? Find(ProductionItemId itemId);

    /// <summary>按当前顺序查询生产建筑的非终态队列。</summary>
    IReadOnlyList<ProductionItemSnapshot> GetQueue(UnitId producerId);
}
