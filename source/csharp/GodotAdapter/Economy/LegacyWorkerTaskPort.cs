using AI_RTS.Application.Units;
using AI_RTS.Domain.Common;
using AI_RTS.GodotAdapter.Units;

namespace AI_RTS.GodotAdapter.Economy;

/// <summary>把公共 Worker 任务端口适配到现有 GDScript 采集组合 Action。</summary>
/// <param name="units">提供 Worker 稳定身份到运行时节点的映射。</param>
/// <param name="resources">提供资源节点稳定身份到运行时节点的映射。</param>
public sealed class LegacyWorkerTaskPort(
    GodotUnitRegistry units,
    GodotResourceNodeRegistry resources) : IWorkerTaskPort
{
    /// <inheritdoc />
    public WorkerTaskPortResult RequestGather(UnitId workerId, ResourceNodeId resourceNodeId)
    {
        if (!units.TryGetNode(workerId, out var worker))
        {
            return WorkerTaskPortResult.Failure(WorkerTaskPortError.UnitUnavailable);
        }
        if (!resources.TryGetNode(resourceNodeId, out var resourceNode))
        {
            return WorkerTaskPortResult.Failure(WorkerTaskPortError.TargetUnavailable);
        }
        if (!worker.HasMethod("request_legacy_gather"))
        {
            return WorkerTaskPortResult.Failure(WorkerTaskPortError.WorkUnavailable);
        }

        return worker.Call("request_legacy_gather", resourceNode).AsBool() ?
            WorkerTaskPortResult.Success() :
            WorkerTaskPortResult.Failure(WorkerTaskPortError.WorkUnavailable);
    }

    /// <inheritdoc />
    public WorkerTaskPortResult RequestSuspend(UnitId workerId)
    {
        if (!units.TryGetNode(workerId, out var worker))
        {
            return WorkerTaskPortResult.Failure(WorkerTaskPortError.UnitUnavailable);
        }
        if (!worker.HasMethod("request_legacy_suspend_work"))
        {
            return WorkerTaskPortResult.Failure(WorkerTaskPortError.WorkUnavailable);
        }

        return worker.Call("request_legacy_suspend_work").AsBool() ?
            WorkerTaskPortResult.Success() :
            WorkerTaskPortResult.Failure(WorkerTaskPortError.WorkUnavailable);
    }
}
