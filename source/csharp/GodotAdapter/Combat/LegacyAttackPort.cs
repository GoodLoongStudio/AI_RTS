using AI_RTS.Application.Units;
using AI_RTS.Domain.Common;
using AI_RTS.GodotAdapter.Units;

namespace AI_RTS.GodotAdapter.Combat;

/// <summary>把 C# 显式攻击端口临时适配到现有 GDScript ForceAttack Action。</summary>
public sealed class LegacyAttackPort(GodotUnitRegistry units) : IUnitAttackPort
{
    /// <inheritdoc />
    public AttackPortResult RequestEntityAttack(UnitId attackerId, UnitId targetId)
    {
        if (!units.TryGetNode(attackerId, out var attacker) ||
            !units.TryGetNode(targetId, out var target))
        {
            return AttackPortResult.Failure(AttackPortError.UnitUnavailable);
        }
        if (!attacker.HasMethod("request_legacy_attack"))
        {
            return AttackPortResult.Failure(AttackPortError.AttackUnavailable);
        }

        return attacker.Call("request_legacy_attack", target).AsBool() ?
            AttackPortResult.Success() : AttackPortResult.Failure(AttackPortError.AttackUnavailable);
    }

    /// <inheritdoc />
    public AttackPortResult RequestEntityForceAttack(UnitId attackerId, UnitId targetId)
    {
        if (!units.TryGetNode(attackerId, out var attacker) ||
            !units.TryGetNode(targetId, out var target))
        {
            return AttackPortResult.Failure(AttackPortError.UnitUnavailable);
        }
        if (!attacker.HasMethod("request_legacy_force_attack"))
        {
            return AttackPortResult.Failure(AttackPortError.AttackUnavailable);
        }

        return attacker.Call("request_legacy_force_attack", target).AsBool() ?
            AttackPortResult.Success() : AttackPortResult.Failure(AttackPortError.AttackUnavailable);
    }

    /// <inheritdoc />
    public AttackPortResult RequestCancelForceAttack(UnitId unitId)
    {
        if (!units.TryGetNode(unitId, out var unit))
        {
            return AttackPortResult.Failure(AttackPortError.UnitUnavailable);
        }
        if (!unit.HasMethod("request_legacy_cancel_force_attack"))
        {
            return AttackPortResult.Failure(AttackPortError.AttackUnavailable);
        }

        return unit.Call("request_legacy_cancel_force_attack").AsBool() ?
            AttackPortResult.Success() : AttackPortResult.Failure(AttackPortError.AttackUnavailable);
    }
}
