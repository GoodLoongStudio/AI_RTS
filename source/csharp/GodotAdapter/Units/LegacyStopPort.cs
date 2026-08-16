using AI_RTS.Application.Units;
using AI_RTS.Domain.Common;

namespace AI_RTS.GodotAdapter.Units;

/// <summary>把统一 Stop 意图适配到迁移期 Godot Unit Action，避免上层拆成多条命令。</summary>
public sealed class LegacyStopPort(GodotUnitRegistry units) : IUnitStopPort
{
    /// <inheritdoc />
    public StopPortResult RequestStop(UnitId unitId)
    {
        if (!units.TryGetNode(unitId, out var unit))
        {
            return StopPortResult.Failure(StopPortError.UnitUnavailable);
        }
        if (!unit.HasMethod("request_legacy_stop"))
        {
            return StopPortResult.Failure(StopPortError.StopUnavailable);
        }

        return unit.Call("request_legacy_stop").AsBool() ?
            StopPortResult.Success() :
            StopPortResult.Failure(StopPortError.StopUnavailable);
    }
}
