using AI_RTS.Domain.Common;

namespace AI_RTS.Domain.Combat;

/// <summary>区分攻击从开火到命中的权威交付方式。</summary>
public enum WeaponDeliveryKind
{
    /// <summary>即时命中，不创建逐发飞行实体，例如步兵子弹。</summary>
    Hitscan,

    /// <summary>拥有独立飞行生命周期的炮弹或导弹。</summary>
    Projectile,

    /// <summary>沿射线路径结算、可配置穿透与阻挡的光束。</summary>
    Beam,

    /// <summary>部署在固定位置并等待引信触发的攻击实体，例如地雷。</summary>
    Deployable
}

/// <summary>控制 Beam 如何与指定目标之前的单位发生交互。</summary>
public enum BeamPathInteractionMode
{
    /// <summary>忽略路径单位并直接命中指定目标。</summary>
    IgnorePathUnits,

    /// <summary>由路径上的第一个合法对象阻挡光束。</summary>
    BlockOnFirst,

    /// <summary>按目标消耗穿透预算，预算耗尽后终止。</summary>
    PenetrateWithBudget
}

/// <summary>区分弹头只结算指定目标还是查询实际爆点范围。</summary>
public enum ImpactSelectionMode
{
    /// <summary>只对仍有效的指定目标结算，用于当前无 AoE 武器。</summary>
    IntendedTargetOnly,

    /// <summary>按实际爆点和 footprint 查询全部范围目标。</summary>
    Area
}

/// <summary>保存一次攻击在发射瞬间冻结的权威数据。</summary>
public sealed record AttackLaunchSnapshot(
    AttackInstanceId AttackId,
    UnitId SourceUnitId,
    PlayerId SourcePlayerId,
    WeaponDeliveryKind DeliveryKind,
    WorldPosition Origin,
    WorldPosition InitialAimPoint,
    UnitId? IntendedTargetUnitId,
    float BaseDamage,
    float WarheadRadius,
    float FriendlyFireDamageMultiplier,
    ImpactSelectionMode ImpactSelectionMode);

/// <summary>提供爆点结算所需的最小可伤害对象快照。</summary>
public readonly record struct ImpactCandidateSnapshot(
    UnitId UnitId,
    PlayerId OwnerId,
    WorldPosition Position,
    float FootprintRadius,
    bool IsDamageable);

/// <summary>记录一次爆点对单个对象产生的最终伤害。</summary>
public readonly record struct DamageApplication(UnitId UnitId, float Damage);
