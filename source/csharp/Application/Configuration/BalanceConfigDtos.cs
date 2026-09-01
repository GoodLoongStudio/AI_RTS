using System.Text.Json;
using System.Text.Json.Serialization;

namespace AI_RTS.Application.Configuration;

/// <summary>保存尚未经过业务校验的平衡配置根对象。</summary>
internal sealed class BalanceConfigDto
{
    /// <summary>配置结构版本。</summary>
    public int? SchemaVersion { get; set; }

    /// <summary>由项目维护的可读内容版本。</summary>
    public string? ContentVersion { get; set; }

    /// <summary>资源种类与采集周期。</summary>
    public List<ResourceDefinitionDto>? Resources { get; set; }

    /// <summary>弹头定义。</summary>
    public List<WarheadDefinitionDto>? Warheads { get; set; }

    /// <summary>武器定义。</summary>
    public List<WeaponDefinitionDto>? Weapons { get; set; }

    /// <summary>单位与建筑的基础数值和能力。</summary>
    public List<UnitTypeDefinitionDto>? UnitTypes { get; set; }

    /// <summary>产品成本、工作量和生产者资格。</summary>
    public List<ProductionDefinitionDto>? Productions { get; set; }

    /// <summary>建筑成本、工作量、环境和圆形占地。</summary>
    public List<ConstructionDefinitionDto>? Constructions { get; set; }

    /// <summary>技能定义；允许空数组。</summary>
    public List<SkillDefinitionDto>? Skills { get; set; }

    /// <summary>捕获当前 schema 未声明的根字段。</summary>
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? UnknownProperties { get; set; }
}

/// <summary>保存尚未校验的资源配置。</summary>
internal sealed class ResourceDefinitionDto
{
    /// <summary>资源枚举名称，例如 A 或 B。</summary>
    public string? Kind { get; set; }

    /// <summary>采集一个离散资源所需的整数毫秒数。</summary>
    public int? CollectionDurationMilliseconds { get; set; }

    /// <summary>捕获当前 schema 未声明的资源字段。</summary>
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? UnknownProperties { get; set; }
}

/// <summary>保存尚未校验的弹头配置。</summary>
internal sealed class WarheadDefinitionDto
{
    /// <summary>稳定 snake_case 弹头 ID。</summary>
    public string? Id { get; set; }

    /// <summary>命中选择模式名称。</summary>
    public string? ImpactSelectionMode { get; set; }

    /// <summary>爆点范围半径，单位为米。</summary>
    public float? RadiusMeters { get; set; }

    /// <summary>友军伤害倍率。</summary>
    public float? FriendlyFireDamageMultiplier { get; set; }

    /// <summary>捕获当前 schema 未声明的弹头字段。</summary>
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? UnknownProperties { get; set; }
}

/// <summary>保存尚未校验的武器配置。</summary>
internal sealed class WeaponDefinitionDto
{
    /// <summary>稳定 snake_case 武器 ID。</summary>
    public string? Id { get; set; }

    /// <summary>伤害交付方式名称。</summary>
    public string? DeliveryKind { get; set; }

    /// <summary>未应用弹头倍率前的基础伤害。</summary>
    public float? BaseDamage { get; set; }

    /// <summary>相邻两次合法开火之间的整数毫秒数。</summary>
    public int? CooldownMilliseconds { get; set; }

    /// <summary>最大攻击距离，单位为米。</summary>
    public float? RangeMeters { get; set; }

    /// <summary>允许攻击的空间名称集合。</summary>
    public List<string>? TargetDomains { get; set; }

    /// <summary>稳定弹头 ID 引用。</summary>
    public string? WarheadId { get; set; }

    /// <summary>捕获当前 schema 未声明的武器字段。</summary>
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? UnknownProperties { get; set; }
}

/// <summary>保存尚未校验的单位或建筑类型配置。</summary>
internal sealed class UnitTypeDefinitionDto
{
    /// <summary>稳定 snake_case 实体类型 ID。</summary>
    public string? Id { get; set; }

    /// <summary>最大生命值。</summary>
    public float? MaxHp { get; set; }

    /// <summary>视野半径，单位为米。</summary>
    public float? SightRangeMeters { get; set; }

    /// <summary>可选移动能力。</summary>
    public UnitMovementDefinitionDto? Movement { get; set; }

    /// <summary>装配的稳定武器 ID 列表。</summary>
    public List<string>? WeaponIds { get; set; }

    /// <summary>是否允许显式强制攻击地面坐标。</summary>
    public bool? CanForceFireGround { get; set; }

    /// <summary>可选采集能力。</summary>
    public GathererDefinitionDto? Gatherer { get; set; }

    /// <summary>可选施工能力。</summary>
    public ConstructorDefinitionDto? Constructor { get; set; }

    /// <summary>可选生产队列能力。</summary>
    public ProducerDefinitionDto? Producer { get; set; }

    /// <summary>捕获当前 schema 未声明的实体字段。</summary>
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? UnknownProperties { get; set; }
}

/// <summary>保存尚未校验的移动能力配置。</summary>
internal sealed class UnitMovementDefinitionDto
{
    /// <summary>移动空间名称。</summary>
    public string? Domain { get; set; }

    /// <summary>正常移动速度，单位为米/秒。</summary>
    public float? SpeedMetersPerSecond { get; set; }

    /// <summary>是否支持沿实时路径倒车。</summary>
    public bool? CanReverse { get; set; }

    /// <summary>倒车速度相对正常速度的倍率。</summary>
    public float? ReverseSpeedMultiplier { get; set; }

    /// <summary>是否允许普通移动期间开火。</summary>
    public bool? CanFireWhileMoving { get; set; }

    /// <summary>移动射击相对车头方向的总射界角度。</summary>
    public float? MovingWeaponArcDegrees { get; set; }

    /// <summary>捕获当前 schema 未声明的移动字段。</summary>
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? UnknownProperties { get; set; }
}

/// <summary>保存尚未校验的采集能力配置。</summary>
internal sealed class GathererDefinitionDto
{
    /// <summary>可携带的离散资源总量。</summary>
    public int? CarryCapacity { get; set; }

    /// <summary>捕获当前 schema 未声明的采集字段。</summary>
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? UnknownProperties { get; set; }
}

/// <summary>保存尚未校验的施工能力配置。</summary>
internal sealed class ConstructorDefinitionDto
{
    /// <summary>每个有效施工 Tick 贡献的工作量。</summary>
    public int? WorkPerTick { get; set; }

    /// <summary>捕获当前 schema 未声明的施工能力字段。</summary>
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? UnknownProperties { get; set; }
}

/// <summary>保存尚未校验的生产队列能力配置。</summary>
internal sealed class ProducerDefinitionDto
{
    /// <summary>单个实体的活动生产项目上限。</summary>
    public int? QueueLimit { get; set; }

    /// <summary>捕获当前 schema 未声明的生产能力字段。</summary>
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? UnknownProperties { get; set; }
}

/// <summary>保存尚未校验的资源成本项。</summary>
internal sealed class ResourceAmountDto
{
    /// <summary>资源枚举名称。</summary>
    public string? Kind { get; set; }

    /// <summary>非负整数数量。</summary>
    public int? Amount { get; set; }

    /// <summary>捕获当前 schema 未声明的成本字段。</summary>
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? UnknownProperties { get; set; }
}

/// <summary>保存尚未校验的生产定义。</summary>
internal sealed class ProductionDefinitionDto
{
    /// <summary>稳定 snake_case 生产定义 ID。</summary>
    public string? Id { get; set; }

    /// <summary>成功部署后生成的稳定实体类型 ID。</summary>
    public string? ProductUnitTypeId { get; set; }

    /// <summary>完成生产所需的正整数工作量。</summary>
    public int? RequiredWork { get; set; }

    /// <summary>入队时一次性支付的成本。</summary>
    public List<ResourceAmountDto>? Cost { get; set; }

    /// <summary>允许执行该定义的建筑类型 ID。</summary>
    public List<string>? AllowedProducerUnitTypeIds { get; set; }

    /// <summary>捕获当前 schema 未声明的生产字段。</summary>
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? UnknownProperties { get; set; }
}

/// <summary>保存尚未校验的建筑施工和放置定义。</summary>
internal sealed class ConstructionDefinitionDto
{
    /// <summary>稳定 snake_case 建筑定义 ID。</summary>
    public string? Id { get; set; }

    /// <summary>施工完成后对应的稳定实体类型 ID。</summary>
    public string? UnitTypeId { get; set; }

    /// <summary>完成施工所需的正整数工作量。</summary>
    public int? RequiredWork { get; set; }

    /// <summary>放置时一次性支付的成本。</summary>
    public List<ResourceAmountDto>? Cost { get; set; }

    /// <summary>要求的可建造环境稳定键。</summary>
    public string? EnvironmentId { get; set; }

    /// <summary>当前 Demo 使用的圆形占地半径，单位为米。</summary>
    public float? FootprintRadiusMeters { get; set; }

    /// <summary>捕获当前 schema 未声明的建筑字段。</summary>
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? UnknownProperties { get; set; }
}

/// <summary>保存尚未校验的技能定义。</summary>
internal sealed class SkillDefinitionDto
{
    /// <summary>稳定 snake_case 技能 ID。</summary>
    public string? Id { get; set; }

    /// <summary>触发规则名称。</summary>
    public string? Trigger { get; set; }

    /// <summary>目标规则基础形状名称。</summary>
    public string? Target { get; set; }

    /// <summary>基础效果序列。</summary>
    public List<SkillEffectDefinitionDto>? Effects { get; set; }

    /// <summary>再次使用前的整数毫秒数。</summary>
    public int? CooldownMilliseconds { get; set; }

    /// <summary>单位目标允许的阵营关系名称。</summary>
    public string? Relation { get; set; }

    /// <summary>最大作用距离；缺省表示不限制。</summary>
    public float? RangeMeters { get; set; }

    /// <summary>单位目标是否必须存活；缺省对单位目标为 true。</summary>
    public bool? RequireAlive { get; set; }

    /// <summary>是否允许选中施法者自己；缺省对自身技能为 true。</summary>
    public bool? AllowSelf { get; set; }

    /// <summary>正式生效时支付的资源；缺省或空数组表示无消耗。</summary>
    public List<ResourceAmountDto>? Cost { get; set; }

    /// <summary>事件触发时监听的战场事件名称。</summary>
    public string? Event { get; set; }

    /// <summary>条件触发时必须成立的条件名称。</summary>
    public string? ActivationCondition { get; set; }

    /// <summary>自动装配到这些稳定单位类型 ID。</summary>
    public List<string>? EquippedUnitTypeIds { get; set; }

    /// <summary>正式生效前的等待毫秒。</summary>
    public int? CastDelayMilliseconds { get; set; }

    /// <summary>中断规则；缺省表示停止或死亡不取消后续效果。</summary>
    public SkillInterruptDefinitionDto? Interrupt { get; set; }

    /// <summary>捕获当前 schema 未声明的技能字段。</summary>
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? UnknownProperties { get; set; }
}

/// <summary>保存尚未校验的技能中断规则。</summary>
internal sealed class SkillInterruptDefinitionDto
{
    /// <summary>允许中断的阶段名称。</summary>
    public List<string>? Phases { get; set; }

    /// <summary>会触发中断的情况名称。</summary>
    public List<string>? Causes { get; set; }

    /// <summary>正式生效后中断是否退还消耗。</summary>
    public bool? RefundCost { get; set; }

    /// <summary>正式生效后中断是否保留冷却。</summary>
    public bool? KeepCooldown { get; set; }

    /// <summary>捕获当前 schema 未声明的中断字段。</summary>
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? UnknownProperties { get; set; }
}

/// <summary>保存尚未校验的技能效果项。</summary>
internal sealed class SkillEffectDefinitionDto
{
    /// <summary>基础效果种类名称。</summary>
    public string? Kind { get; set; }

    /// <summary>可选数值；本步不解释语义。</summary>
    public float? Amount { get; set; }

    /// <summary>相对上一条效果的等待毫秒。</summary>
    public int? DelayMilliseconds { get; set; }

    /// <summary>添加状态时的稳定状态 ID。</summary>
    public string? StatusId { get; set; }

    /// <summary>状态持续时间。</summary>
    public int? DurationMilliseconds { get; set; }

    /// <summary>被修改的属性名称。</summary>
    public string? Attribute { get; set; }

    /// <summary>属性修正；移速为相对基线的正倍率。</summary>
    public float? Modifier { get; set; }

    /// <summary>再次施加时的叠加规则名称。</summary>
    public string? Stack { get; set; }

    /// <summary>与上一条效果的时间关系名称。</summary>
    public string? Timing { get; set; }

    /// <summary>周期间隔毫秒；与 repeatCount 成对出现。</summary>
    public int? PeriodMilliseconds { get; set; }

    /// <summary>包含首次在内的重复次数。</summary>
    public int? RepeatCount { get; set; }

    /// <summary>不满足则跳过该次执行的条件名称。</summary>
    public string? Condition { get; set; }

    /// <summary>下达命令时映射的已有命令名称。</summary>
    public string? Command { get; set; }

    /// <summary>触发事件时的战场事件种类名称。</summary>
    public string? EventKind { get; set; }

    /// <summary>该事件是否可作为 Space 跳转目标。</summary>
    public bool? EventImportant { get; set; }

    /// <summary>创建对象时使用的已有单位类型模板 ID。</summary>
    public string? TemplateId { get; set; }

    /// <summary>捕获当前 schema 未声明的效果字段。</summary>
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? UnknownProperties { get; set; }
}
