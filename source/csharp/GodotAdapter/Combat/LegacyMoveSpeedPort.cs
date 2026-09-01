using AI_RTS.Application.Units;
using AI_RTS.Domain.Common;
using AI_RTS.GodotAdapter.Units;
using Godot;

namespace AI_RTS.GodotAdapter.Combat;

/// <summary>用元数据保存基线移速，再按技能倍率改 Movement.speed。</summary>
public sealed class LegacyMoveSpeedPort(GodotUnitRegistry units) : IUnitMoveSpeedPort
{
    private const string BaseSpeedMeta = "skill_base_move_speed";

    /// <inheritdoc />
    public void ApplyMoveSpeedMultiplier(UnitId unitId, float multiplier)
    {
        if (!TryGetMovement(unitId, out var unit, out var movement) ||
            !float.IsFinite(multiplier) ||
            multiplier <= 0.0f)
        {
            return;
        }

        if (!unit.HasMeta(BaseSpeedMeta))
        {
            unit.SetMeta(BaseSpeedMeta, movement.Get("speed"));
        }

        movement.Set("speed", unit.GetMeta(BaseSpeedMeta).AsSingle() * multiplier);
    }

    /// <inheritdoc />
    public void ClearMoveSpeedModifier(UnitId unitId)
    {
        ApplyMoveSpeedMultiplier(unitId, 1.0f);
    }

    private bool TryGetMovement(UnitId unitId, out Node unit, out Node movement)
    {
        movement = null!;
        if (!units.TryGetNode(unitId, out unit))
        {
            return false;
        }

        var child = unit.FindChild("Movement", false, false);
        if (child is null)
        {
            return false;
        }

        movement = child;
        return true;
    }
}
