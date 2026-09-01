using AI_RTS.Domain.Combat;
using AI_RTS.Domain.Common;

namespace AI_RTS.Application.Combat;

/// <summary>根据不可变发射快照和实际爆点计算确定性的受伤对象集合。</summary>
public interface IWarheadDamageResolver
{
    /// <summary>返回按稳定 UnitId 排序且每个对象最多出现一次的伤害结果。</summary>
    IReadOnlyList<DamageApplication> Resolve(
        AttackLaunchSnapshot launch,
        WorldPosition impactPoint,
        IEnumerable<ImpactCandidateSnapshot> candidates);
}

/// <summary>实现当前无距离衰减的点命中与范围弹头规则。</summary>
public sealed class WarheadDamageResolver : IWarheadDamageResolver
{
    /// <inheritdoc />
    public IReadOnlyList<DamageApplication> Resolve(
        AttackLaunchSnapshot launch,
        WorldPosition impactPoint,
        IEnumerable<ImpactCandidateSnapshot> candidates)
    {
        if (!IsValid(launch) || !IsFinite(impactPoint))
        {
            return [];
        }

        var results = new List<DamageApplication>();
        foreach (var candidate in candidates
            .Where(item => item.IsDamageable)
            .GroupBy(item => item.UnitId)
            .Select(group => group.First())
            .OrderBy(item => item.UnitId.Value))
        {
            // Direct entity attacks must never damage the attacker's own side.
            // ForceAttack may still be accepted as an order, but a stale or
            // misrouted target reference must not turn it into self-damage.
            if (launch.ImpactSelectionMode == ImpactSelectionMode.IntendedTargetOnly &&
                candidate.OwnerId == launch.SourcePlayerId)
            {
                continue;
            }

            if (!CanHit(launch, impactPoint, candidate))
            {
                continue;
            }

            var multiplier = candidate.OwnerId == launch.SourcePlayerId ?
                launch.FriendlyFireDamageMultiplier : 1.0f;
            var damage = launch.BaseDamage * multiplier;
            if (damage > 0.0f && float.IsFinite(damage))
            {
                results.Add(new DamageApplication(candidate.UnitId, damage));
            }
        }

        return results;
    }

    /// <summary>判断候选对象是否符合指定目标或实际爆点范围规则。</summary>
    private static bool CanHit(
        AttackLaunchSnapshot launch,
        WorldPosition impactPoint,
        ImpactCandidateSnapshot candidate)
    {
        if (launch.ImpactSelectionMode == ImpactSelectionMode.IntendedTargetOnly)
        {
            return launch.IntendedTargetUnitId == candidate.UnitId;
        }

        var dx = candidate.Position.X - impactPoint.X;
        var dz = candidate.Position.Z - impactPoint.Z;
        var combinedRadius = launch.WarheadRadius + Math.Max(0.0f, candidate.FootprintRadius);
        return dx * dx + dz * dz <= combinedRadius * combinedRadius;
    }

    /// <summary>校验发射快照中的数值，拒绝 NaN、无穷值和负半径。</summary>
    private static bool IsValid(AttackLaunchSnapshot launch) =>
        launch.BaseDamage >= 0.0f &&
        float.IsFinite(launch.BaseDamage) &&
        launch.WarheadRadius >= 0.0f &&
        float.IsFinite(launch.WarheadRadius) &&
        launch.FriendlyFireDamageMultiplier >= 0.0f &&
        float.IsFinite(launch.FriendlyFireDamageMultiplier) &&
        IsFinite(launch.Origin) &&
        IsFinite(launch.InitialAimPoint);

    /// <summary>判断世界坐标的每个分量是否都是有限值。</summary>
    private static bool IsFinite(WorldPosition position) =>
        float.IsFinite(position.X) &&
        float.IsFinite(position.Y) &&
        float.IsFinite(position.Z);
}
