using AI_RTS.Application.Units;
using AI_RTS.Domain.Common;
using AI_RTS.GodotAdapter.Units;
using Godot;

namespace AI_RTS.GodotAdapter.Combat;

/// <summary>把已解析伤害写入现有单位 hp，死亡继续走 GDScript 的 hp 归零逻辑。</summary>
public sealed class LegacyDamagePort(GodotUnitRegistry units) : IUnitDamagePort
{
    /// <inheritdoc />
    public void ApplyDamage(UnitId unitId, float damage)
    {
        if (!units.TryGetNode(unitId, out var unit))
        {
            return;
        }

        var hp = unit.Get("hp");
        if (hp.VariantType == Variant.Type.Nil)
        {
            return;
        }

        unit.Set("hp", hp.AsSingle() - damage);
    }

    /// <inheritdoc />
    public void RestoreHealth(UnitId unitId, float amount)
    {
        if (!units.TryGetNode(unitId, out var unit) || amount <= 0.0f || !float.IsFinite(amount))
        {
            return;
        }

        var hp = unit.Get("hp");
        if (hp.VariantType == Variant.Type.Nil)
        {
            return;
        }

        var current = hp.AsSingle();
        var max = unit.Get("hp_max");
        var ceiling = max.VariantType == Variant.Type.Nil ? current + amount : max.AsSingle();
        unit.Set("hp", Math.Min(ceiling, current + amount));
    }
}
