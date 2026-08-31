using AI_RTS.Domain.Combat;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Construction;
using AI_RTS.Domain.Economy;

namespace AI_RTS.Domain.Configuration;

/// <summary>描述一份已加载平衡数据的格式版本、内容版本和内容指纹。</summary>
/// <param name="SchemaVersion">配置结构版本；当前仅支持 1。</param>
/// <param name="ContentVersion">由项目维护的可读内容版本。</param>
/// <param name="ContentHash">原始 UTF-8 JSON 内容的 SHA-256 十六进制摘要。</param>
public sealed record BalanceConfigVersion(
    int SchemaVersion,
    string ContentVersion,
    string ContentHash);

/// <summary>描述移动能力的领域无关数值。</summary>
/// <param name="Domain">单位使用的移动空间。</param>
/// <param name="SpeedMetersPerSecond">正常移动速度，单位为米/秒。</param>
/// <param name="CanReverse">是否支持沿实时路径倒车。</param>
/// <param name="ReverseSpeedMultiplier">倒车速度相对正常速度的倍率。</param>
/// <param name="CanFireWhileMoving">是否允许普通移动期间开火。</param>
/// <param name="MovingWeaponArcDegrees">移动射击相对车头方向的总射界角度。</param>
public sealed record UnitMovementDefinition(
    CombatDomain Domain,
    float SpeedMetersPerSecond,
    bool CanReverse,
    float ReverseSpeedMultiplier,
    bool CanFireWhileMoving,
    float MovingWeaponArcDegrees);

/// <summary>描述 Worker 的采集载荷能力。</summary>
/// <param name="CarryCapacity">可携带的离散资源总量。</param>
public sealed record GathererDefinition(int CarryCapacity);

/// <summary>描述单位每个有效施工 Tick 可以贡献的工作量。</summary>
/// <param name="WorkPerTick">每个施工 Tick 贡献的正整数工作量。</param>
public sealed record ConstructorDefinition(int WorkPerTick);

/// <summary>描述单位拥有的独立生产队列容量。</summary>
/// <param name="QueueLimit">该单位实例最多容纳的活动生产项目数。</param>
public sealed record ProducerDefinition(int QueueLimit);

/// <summary>描述一种单位或建筑的不可变基础数值与能力组合。</summary>
/// <param name="Id">稳定战场实体类型 ID。</param>
/// <param name="MaxHp">最大生命值。</param>
/// <param name="SightRangeMeters">视野半径，单位为米。</param>
/// <param name="Movement">移动能力；null 表示不能移动。</param>
/// <param name="WeaponIds">该类型装配的稳定武器定义列表。</param>
/// <param name="CanForceFireGround">是否允许显式强制攻击地面坐标。</param>
/// <param name="Gatherer">采集能力；null 表示不能采集。</param>
/// <param name="Constructor">施工能力；null 表示不能施工。</param>
/// <param name="Producer">生产能力；null 表示没有生产队列。</param>
public sealed record UnitTypeDefinition(
    UnitTypeId Id,
    float MaxHp,
    float SightRangeMeters,
    UnitMovementDefinition? Movement,
    IReadOnlyList<WeaponDefinitionId> WeaponIds,
    bool CanForceFireGround,
    GathererDefinition? Gatherer,
    ConstructorDefinition? Constructor,
    ProducerDefinition? Producer);

/// <summary>描述一次命中如何选择受影响对象及计算友军伤害。</summary>
/// <param name="Id">稳定弹头定义 ID。</param>
/// <param name="ImpactSelectionMode">只命中指定目标或按实际爆点查询范围。</param>
/// <param name="RadiusMeters">范围结算半径，单位为米；直接命中允许为零。</param>
/// <param name="FriendlyFireDamageMultiplier">对友军应用的伤害倍率，当前 Demo 默认为 0（关闭友伤）。</param>
public sealed record WarheadDefinition(
    WarheadDefinitionId Id,
    ImpactSelectionMode ImpactSelectionMode,
    float RadiusMeters,
    float FriendlyFireDamageMultiplier);

/// <summary>描述一件武器在发射瞬间需要冻结的不可变数值。</summary>
/// <param name="Id">稳定武器定义 ID。</param>
/// <param name="DeliveryKind">伤害交付方式。</param>
/// <param name="BaseDamage">未应用弹头倍率前的基础伤害。</param>
/// <param name="CooldownMilliseconds">相邻两次合法开火之间的整数毫秒数。</param>
/// <param name="RangeMeters">最大攻击距离，单位为米。</param>
/// <param name="TargetDomains">该武器允许攻击的空间集合。</param>
/// <param name="WarheadId">命中时使用的弹头定义。</param>
public sealed record WeaponDefinition(
    WeaponDefinitionId Id,
    WeaponDeliveryKind DeliveryKind,
    float BaseDamage,
    int CooldownMilliseconds,
    float RangeMeters,
    IReadOnlySet<CombatDomain> TargetDomains,
    WarheadDefinitionId WarheadId);

/// <summary>描述一种资源的采集周期配置。</summary>
/// <param name="Kind">稳定资源枚举。</param>
/// <param name="CollectionDurationMilliseconds">采集一个离散资源所需的整数毫秒数。</param>
public sealed record ResourceDefinition(
    ResourceKind Kind,
    int CollectionDurationMilliseconds);

/// <summary>组合建筑放置定义与施工所需的整数工作量。</summary>
/// <param name="DefinitionId">稳定建筑定义 ID。</param>
/// <param name="UnitTypeId">施工完成后对应的战场实体类型。</param>
/// <param name="RequiredWork">完成施工所需的正整数工作量。</param>
/// <param name="Placement">占地、环境与成本定义。</param>
public sealed record StructureConstructionDefinition(
    StructureDefinitionId DefinitionId,
    UnitTypeId UnitTypeId,
    int RequiredWork,
    StructurePlacementDefinition Placement);
