using AI_RTS.Application.Units;
using AI_RTS.Domain.Common;
using AI_RTS.GodotAdapter.Economy;
using AI_RTS.GodotAdapter.Units;
using Godot;

namespace AI_RTS.GodotAdapter.Navigation;

/// <summary>把 C# 移动端口临时适配到现有 GDScript Moving Action。</summary>
public sealed class LegacyMovementPort(
    GodotUnitRegistry units,
    GodotResourceNodeRegistry resources) : IUnitMovementPort, IReturnToBaseMovementPort
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
    public MovementPortResult RequestApproachEntity(
        UnitId unitId,
        BattlefieldEntityId targetEntityId)
    {
        if (!units.TryGetNode(unitId, out var unit) ||
            !TryGetTarget(targetEntityId, out var target))
        {
            return MovementPortResult.Failure(MovementPortError.UnitUnavailable);
        }
        if (!unit.HasMethod("request_legacy_approach_entity"))
        {
            return MovementPortResult.Failure(MovementPortError.NavigationUnavailable);
        }

        return unit.Call("request_legacy_approach_entity", target).AsBool() ?
            MovementPortResult.Success() :
            MovementPortResult.Failure(MovementPortError.NavigationUnavailable);
    }

    /// <inheritdoc />
    public MovementPortResult RequestFollowEntity(UnitId unitId, UnitId targetId)
    {
        if (!units.TryGetNode(unitId, out var unit) ||
            !units.TryGetNode(targetId, out var target))
        {
            return MovementPortResult.Failure(MovementPortError.UnitUnavailable);
        }
        if (!unit.HasMethod("request_legacy_follow_entity"))
        {
            return MovementPortResult.Failure(MovementPortError.NavigationUnavailable);
        }

        return unit.Call("request_legacy_follow_entity", target).AsBool() ?
            MovementPortResult.Success() :
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
    public MovementPortResult RequestReturnToBase(UnitId unitId, UnitId commandCenterId)
    {
        if (!units.TryGetNode(unitId, out var unit) ||
            !units.TryGetNode(commandCenterId, out var commandCenter))
        {
            return MovementPortResult.Failure(MovementPortError.UnitUnavailable);
        }
        if (!unit.HasMethod("request_legacy_return_to_base"))
        {
            return MovementPortResult.Failure(MovementPortError.NavigationUnavailable);
        }

        var accepted = unit.Call("request_legacy_return_to_base", commandCenter).AsBool();
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

    /// <summary>按统一战场实体身份解析单位、建筑或资源节点。</summary>
    private bool TryGetTarget(BattlefieldEntityId targetEntityId, out Node target)
    {
        if (targetEntityId.Kind == BattlefieldEntityKind.ResourceNode)
        {
            return resources.TryGetNode(new ResourceNodeId(targetEntityId.Value), out target);
        }
        return units.TryGetNode(new UnitId(targetEntityId.Value), out target);
    }
}
