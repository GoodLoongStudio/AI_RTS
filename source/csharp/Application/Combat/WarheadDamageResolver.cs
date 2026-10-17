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
    /// <summary>非制导直击弹的额外命中容差（米），叠加在"弹头半径 + 目标碰撞半径"之上。</summary>
    internal const float DirectHitToleranceMeters = 2.0f;

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
            // 【2026-10-12 用户要求】子弹不得误伤友军：直击原本就跳过自己人，现在 area 溅射
            // 同样只在**显式 ForceAttack**（AllowsFriendlyDamage）时才对自己人结算。
            // 友伤倍率仍留在 balance 里，只服务"玩家主动下令打自己单位"这一条路径。
            if (candidate.OwnerId == launch.SourcePlayerId && !launch.AllowsFriendlyDamage)
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
            if (launch.IntendedTargetUnitId != candidate.UnitId)
            {
                return false;
            }

            // 制导武器（当前只有防空炮）在命中时仍以目标当前位置结算。
            // 其它实体弹体的落点已在发射时冻结，目标移动出爆点后必须脱靶。
            if (launch.TracksTarget)
            {
                return true;
            }

            var targetDx = candidate.Position.X - impactPoint.X;
            var targetDz = candidate.Position.Z - impactPoint.Z;
            // 直击容差额外计入目标命中窗（2026-10-12 用户要求扩大命中判定范围）：
            // schema 规定 IntendedTargetOnly 弹头的 radiusMeters 必须为零
            // （BalanceConfigLoader.cs:275 会整表拒绝非零值），所以这条余量只能落在命中判定权威里。
            // 只放宽"冻结落点后目标仍在窗内"的判定，不会把直击弹变成溅射。
            var targetRadius = launch.WarheadRadius + Math.Max(0.0f, candidate.FootprintRadius) +
                DirectHitToleranceMeters;
            return targetDx * targetDx + targetDz * targetDz <= targetRadius * targetRadius;
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
