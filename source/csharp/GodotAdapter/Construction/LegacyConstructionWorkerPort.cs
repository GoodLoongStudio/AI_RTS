using AI_RTS.Application.Construction;
using AI_RTS.Domain.Common;
using AI_RTS.GodotAdapter.Units;
using Godot;

namespace AI_RTS.GodotAdapter.Construction;

/// <summary>把权威 Construct 任务适配到现有 Worker 的移动、到位和火花表现。</summary>
public sealed class LegacyConstructionWorkerPort(
    GodotUnitRegistry units,
    GodotConstructionSiteRegistry sites) : IConstructionWorkerPort
{
    /// <inheritdoc />
    public ConstructionWorkerPortResult RequestConstruct(UnitId workerId, UnitId siteId)
    {
        if (!units.TryGetNode(workerId, out var worker) || !sites.TryGetNode(siteId, out var site))
        {
            return ConstructionWorkerPortResult.Failure(
                ConstructionWorkerPortError.EntityUnavailable);
        }
        return Call(worker, "request_legacy_construct", site);
    }

    /// <inheritdoc />
    public ConstructionWorkerPortResult RequestSuspend(UnitId workerId)
    {
        if (!units.TryGetNode(workerId, out var worker))
        {
            return ConstructionWorkerPortResult.Failure(
                ConstructionWorkerPortError.EntityUnavailable);
        }
        return Call(worker, "request_legacy_suspend_construction");
    }

    /// <inheritdoc />
    public bool IsContributing(UnitId workerId, UnitId siteId)
    {
        return units.TryGetNode(workerId, out var worker) &&
            sites.TryGetNode(siteId, out var site) &&
            worker.HasMethod("is_legacy_contributing_to_construction") &&
            worker.Call("is_legacy_contributing_to_construction", site).AsBool();
    }

    /// <inheritdoc />
    public void Clear(UnitId workerId)
    {
        if (units.TryGetNode(workerId, out var worker) &&
            worker.HasMethod("request_legacy_clear_construction"))
        {
            worker.Call("request_legacy_clear_construction");
        }
    }

    /// <summary>调用 Worker 的布尔迁移桥并转换为稳定端口结果。</summary>
    private static ConstructionWorkerPortResult Call(
        Node worker,
        StringName method,
        params Variant[] arguments)
    {
        if (!worker.HasMethod(method) || !worker.Call(method, arguments).AsBool())
        {
            return ConstructionWorkerPortResult.Failure(
                ConstructionWorkerPortError.ExecutionUnavailable);
        }
        return ConstructionWorkerPortResult.Success();
    }
}
