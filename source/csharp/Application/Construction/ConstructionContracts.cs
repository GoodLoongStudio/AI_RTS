using AI_RTS.Application.Commands;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Construction;
using AI_RTS.Domain.Economy;

namespace AI_RTS.Application.Construction;

/// <summary>请求一组 Worker 前往并持续施工同一现场。</summary>
/// <param name="WorkerIds">逐个校验、去重并建立独立订单的 Worker。</param>
/// <param name="SiteId">目标施工现场的稳定建筑 UnitId。</param>
public sealed record ConstructStructureCommand(
    IReadOnlyList<UnitId> WorkerIds,
    UnitId SiteId);

/// <summary>请求拥有者主动取消一个仍为 Active 的施工现场。</summary>
/// <param name="SiteId">需要取消并退款的现场。</param>
public sealed record CancelConstructionCommand(UnitId SiteId);

/// <summary>请求把 ECO-003 已创建并扣款的建筑注册为施工现场。</summary>
public sealed record RegisterConstructionSite(
    UnitId SiteId,
    PlayerId OwnerId,
    StructureDefinitionId DefinitionId,
    int RequiredWork,
    IReadOnlyList<ResourceAmount> ConstructionCost);

/// <summary>表示单现场命令的稳定处理状态。</summary>
public enum ConstructionSiteCommandStatus
{
    /// <summary>命令已经完整应用。</summary>
    Applied,
    /// <summary>现场不存在。</summary>
    SiteNotFound,
    /// <summary>命令发出者不拥有现场。</summary>
    SiteNotOwned,
    /// <summary>现场已经进入 Completed、Cancelled 或 Destroyed。</summary>
    SiteNotActive,
    /// <summary>退款或 Godot 现场执行端拒绝了操作。</summary>
    ExecutionUnavailable
}

/// <summary>返回单现场命令状态及处理后的快照。</summary>
public sealed record ConstructionSiteCommandResult(
    ConstructionSiteCommandStatus Status,
    ConstructionSiteSnapshot? Snapshot);

/// <summary>表示施工 Worker Adapter 的稳定失败原因。</summary>
public enum ConstructionWorkerPortError
{
    /// <summary>没有错误。</summary>
    None,
    /// <summary>Worker 或现场对应的运行时对象已经失效。</summary>
    EntityUnavailable,
    /// <summary>Worker 无法移动或进入施工表现。</summary>
    ExecutionUnavailable
}

/// <summary>表示 Worker 施工端口是否接受请求。</summary>
public readonly record struct ConstructionWorkerPortResult(
    bool Accepted,
    ConstructionWorkerPortError Error)
{
    /// <summary>创建成功端口结果。</summary>
    public static ConstructionWorkerPortResult Success() =>
        new(true, ConstructionWorkerPortError.None);

    /// <summary>创建失败端口结果。</summary>
    public static ConstructionWorkerPortResult Failure(ConstructionWorkerPortError error) =>
        new(false, error);
}

/// <summary>隔离施工服务与 Worker 导航、到位和火花表现。</summary>
public interface IConstructionWorkerPort
{
    /// <summary>要求 Worker 开始或继续前往指定现场施工。</summary>
    ConstructionWorkerPortResult RequestConstruct(UnitId workerId, UnitId siteId);

    /// <summary>暂停完整施工任务并停止移动/贡献。</summary>
    ConstructionWorkerPortResult RequestSuspend(UnitId workerId);

    /// <summary>查询 Worker 当前是否到位且能够贡献工作量。</summary>
    bool IsContributing(UnitId workerId, UnitId siteId);

    /// <summary>清除 Worker 的 Legacy 施工执行与表现，不保留 Node 引用。</summary>
    void Clear(UnitId workerId);
}

/// <summary>隔离施工服务与建筑 HP、材质和节点生命周期。</summary>
public interface IConstructionSitePort
{
    /// <summary>把新的整数工作量镜像到建筑进度并解锁非伤害 HP。</summary>
    bool ApplyProgress(UnitId siteId, int completedWork, int requiredWork);

    /// <summary>把建筑切换为已完成可用状态。</summary>
    bool Complete(UnitId siteId);

    /// <summary>删除被拥有者主动取消的现场。</summary>
    bool Cancel(UnitId siteId);
}

/// <summary>允许统一 Stop 暂停当前 Construct 订单。</summary>
public interface IConstructionTaskCoordinator
{
    /// <summary>暂停 Worker 的施工执行；成功后由命令服务转换订单状态。</summary>
    ConstructionWorkerPortResult RequestSuspend(UnitId workerId);
}

/// <summary>表示一个现场已经完成的权威异步事件。</summary>
public sealed record ConstructionCompleted(
    UnitId SiteId,
    PlayerId OwnerId,
    StructureDefinitionId DefinitionId,
    long SimulationTick);

/// <summary>表示现场因主动取消或被摧毁而终止。</summary>
public sealed record ConstructionTerminated(
    UnitId SiteId,
    PlayerId OwnerId,
    StructureDefinitionId DefinitionId,
    ConstructionSiteState State,
    long SimulationTick);

/// <summary>提供统一施工任务、进度和现场终态入口。</summary>
public interface IConstructionService : IConstructionTaskCoordinator
{
    /// <summary>现场完成后发布一次权威事件。</summary>
    event Action<ConstructionCompleted>? Completed;

    /// <summary>现场取消或摧毁后发布一次权威事件。</summary>
    event Action<ConstructionTerminated>? Terminated;

    /// <summary>注册 Place 已成功创建和扣款的现场。</summary>
    bool Register(RegisterConstructionSite request);

    /// <summary>查询现场当前快照。</summary>
    ConstructionSiteSnapshot? Find(UnitId siteId);

    /// <summary>提交批量 Worker 施工命令。</summary>
    CommandResult Construct(CommandContext context, ConstructStructureCommand command);

    /// <summary>推进指定模拟 Tick；同一 Tick 重复调用不重复增加工作量。</summary>
    void Advance(long simulationTick);

    /// <summary>拥有者主动取消现场并执行一次全额退款。</summary>
    ConstructionSiteCommandResult Cancel(
        CommandContext context,
        CancelConstructionCommand command);

    /// <summary>把仍为 Active 的现场标记为被摧毁，不退款。</summary>
    ConstructionSiteCommandResult Destroy(UnitId siteId, long simulationTick);
}
