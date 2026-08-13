using AI_RTS.Application.Units;
using AI_RTS.Domain.Common;
using AI_RTS.GodotAdapter.Units;
using Godot;

namespace AI_RTS.GodotAdapter.Navigation;

/// <summary>把 C# 移动端口临时适配到现有 GDScript Moving Action。</summary>
public sealed class LegacyMovementPort(GodotUnitRegistry units) : IUnitMovementPort
{
    /// <inheritdoc />
    public MovementPortResult RequestMove(UnitId unitId, WorldPosition destination)
    {
        if (!units.TryGetNode(unitId, out var unit))
        {
            return MovementPortResult.Failure(MovementPortError.UnitUnavailable);
        }
        if (!unit.HasMethod("request_legacy_move"))
        {
            return MovementPortResult.Failure(MovementPortError.NavigationUnavailable);
        }

        var accepted = unit.Call(
            "request_legacy_move", new Vector3(destination.X, destination.Y, destination.Z)).AsBool();
        return accepted ? MovementPortResult.Success() :
            MovementPortResult.Failure(MovementPortError.NavigationUnavailable);
    }

    /// <inheritdoc />
    public MovementPortResult RequestGroundAttackMove(UnitId unitId, WorldPosition destination)
    {
        if (!units.TryGetNode(unitId, out var unit))
        {
            return MovementPortResult.Failure(MovementPortError.UnitUnavailable);
        }
        if (!unit.HasMethod("request_legacy_ground_attack_move"))
        {
            return MovementPortResult.Failure(MovementPortError.NavigationUnavailable);
        }

        var accepted = unit.Call(
            "request_legacy_ground_attack_move",
            new Vector3(destination.X, destination.Y, destination.Z)).AsBool();
        return accepted ? MovementPortResult.Success() :
            MovementPortResult.Failure(MovementPortError.NavigationUnavailable);
    }

    /// <inheritdoc />
    public MovementPortResult RequestEntityAttackMove(UnitId unitId, UnitId targetId)
    {
        if (!units.TryGetNode(unitId, out var unit) || !units.TryGetNode(targetId, out var target))
        {
            return MovementPortResult.Failure(MovementPortError.UnitUnavailable);
        }
        if (!unit.HasMethod("request_legacy_entity_attack_move"))
        {
            return MovementPortResult.Failure(MovementPortError.NavigationUnavailable);
        }

        var accepted = unit.Call("request_legacy_entity_attack_move", target).AsBool();
        return accepted ? MovementPortResult.Success() :
            MovementPortResult.Failure(MovementPortError.NavigationUnavailable);
    }

    /// <inheritdoc />
    public MovementPortResult RequestTacticalWithdraw(UnitId unitId, WorldPosition destination)
    {
        if (!units.TryGetNode(unitId, out var unit))
        {
            return MovementPortResult.Failure(MovementPortError.UnitUnavailable);
        }
        if (!unit.HasMethod("request_legacy_tactical_withdraw"))
        {
            return MovementPortResult.Failure(MovementPortError.NavigationUnavailable);
        }

        var accepted = unit.Call(
            "request_legacy_tactical_withdraw",
            new Vector3(destination.X, destination.Y, destination.Z)).AsBool();
        return accepted ? MovementPortResult.Success() :
            MovementPortResult.Failure(MovementPortError.NavigationUnavailable);
    }

    /// <inheritdoc />
    public MovementPortResult RequestHalt(UnitId unitId)
    {
        if (!units.TryGetNode(unitId, out var unit))
        {
            return MovementPortResult.Failure(MovementPortError.UnitUnavailable);
        }
        if (!unit.HasMethod("request_legacy_halt_movement"))
        {
            return MovementPortResult.Failure(MovementPortError.NavigationUnavailable);
        }

        var accepted = unit.Call("request_legacy_halt_movement").AsBool();
        return accepted ? MovementPortResult.Success() :
            MovementPortResult.Failure(MovementPortError.NavigationUnavailable);
    }
}
