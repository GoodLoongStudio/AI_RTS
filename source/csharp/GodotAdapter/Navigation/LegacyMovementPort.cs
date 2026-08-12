using AI_RTS.Application.Units;
using AI_RTS.Domain.Common;
using AI_RTS.GodotAdapter.Units;
using Godot;

namespace AI_RTS.GodotAdapter.Navigation;

public sealed class LegacyMovementPort(GodotUnitRegistry units) : IUnitMovementPort
{
    public MovementPortResult RequestMove(UnitId unitId, WorldPosition destination)
    {
        if (!units.TryGetNode(unitId, out var unit))
            return MovementPortResult.Failure(MovementPortError.UnitUnavailable);
        if (!unit.HasMethod("request_legacy_move"))
            return MovementPortResult.Failure(MovementPortError.NavigationUnavailable);

        var accepted = unit.Call(
            "request_legacy_move", new Vector3(destination.X, destination.Y, destination.Z)).AsBool();
        return accepted ? MovementPortResult.Success() :
            MovementPortResult.Failure(MovementPortError.NavigationUnavailable);
    }

    public MovementPortResult RequestHalt(UnitId unitId)
    {
        if (!units.TryGetNode(unitId, out var unit))
            return MovementPortResult.Failure(MovementPortError.UnitUnavailable);
        if (!unit.HasMethod("request_legacy_halt_movement"))
            return MovementPortResult.Failure(MovementPortError.NavigationUnavailable);

        var accepted = unit.Call("request_legacy_halt_movement").AsBool();
        return accepted ? MovementPortResult.Success() :
            MovementPortResult.Failure(MovementPortError.NavigationUnavailable);
    }
}
