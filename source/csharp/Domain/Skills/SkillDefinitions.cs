using AI_RTS.Domain.Battlefield;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Economy;

namespace AI_RTS.Domain.Skills;

/// <summary>描述技能何时开始执行。</summary>
public enum SkillTriggerKind
{
    /// <summary>由玩家或 AI 明确施放。</summary>
    Active,

    /// <summary>满足装配条件后持续生效，无需确认目标。</summary>
    Passive,

    /// <summary>由统一战场事件触发。</summary>
    Event,

    /// <summary>由配置条件成立时触发。</summary>
    Condition
}

/// <summary>事件触发技能监听的统一战场事件；本步只实现受伤。</summary>
public enum SkillTriggerEvent
{
    /// <summary>不监听事件。</summary>
    None,

    /// <summary>单位生命因伤害下降。</summary>
    UnitDamaged
}

/// <summary>描述技能作用对象的基础形状。</summary>
public enum SkillTargetKind
{
    /// <summary>施法者自身。</summary>
    Self,

    /// <summary>单个单位。</summary>
    Unit,

    /// <summary>多个单位。</summary>
    Units,

    /// <summary>地面坐标。</summary>
    Ground,

    /// <summary>区域。</summary>
    Area,

    /// <summary>方向。</summary>
    Direction,

    /// <summary>已有游戏对象。</summary>
    GameObject
}

/// <summary>技能目标允许的阵营关系。</summary>
public enum SkillTargetRelation
{
    /// <summary>仅施法者自身。</summary>
    Self,

    /// <summary>同一所有者的单位。</summary>
    Ally,

    /// <summary>其他所有者的单位。</summary>
    Enemy,

    /// <summary>不限制阵营。</summary>
    Any
}

/// <summary>策划文档固定的基础效果种类；本步只校验枚举，不执行。</summary>
public enum SkillEffectKind
{
    /// <summary>对目标产生伤害。</summary>
    DealDamage,

    /// <summary>恢复目标生命值。</summary>
    RestoreHealth,

    /// <summary>增加、减少或恢复护盾。</summary>
    ModifyShield,

    /// <summary>修改已有单位属性。</summary>
    ModifyAttribute,

    /// <summary>修改能量、弹药、充能等资源。</summary>
    ModifyResource,

    /// <summary>给目标增加一个状态。</summary>
    AddStatus,

    /// <summary>移除目标已有状态。</summary>
    RemoveStatus,

    /// <summary>改变对象位置。</summary>
    Displace,

    /// <summary>推、拉、击退等强制位移。</summary>
    ForceMove,

    /// <summary>按对象模板创建一个游戏对象。</summary>
    CreateObject,

    /// <summary>移除指定游戏对象。</summary>
    RemoveObject,

    /// <summary>让目标执行一个已有基础命令。</summary>
    IssueCommand,

    /// <summary>产生一个统一游戏事件。</summary>
    EmitEvent
}

/// <summary>状态可以修改的已有单位属性；本步只实现移动速度。</summary>
public enum SkillAttributeKind
{
    /// <summary>移动速度倍率，1 表示恢复基线。</summary>
    MoveSpeed
}

/// <summary>同一状态再次施加时的叠加规则。</summary>
public enum SkillStackRule
{
    /// <summary>保留当前修正，只刷新剩余持续时间。</summary>
    Refresh,

    /// <summary>用新修正覆盖并刷新持续时间。</summary>
    Overwrite,

    /// <summary>已有该状态时忽略新的施加。</summary>
    Ignore
}

/// <summary>效果相对上一条的时间关系；同时与延迟互斥。</summary>
public enum SkillEffectTiming
{
    /// <summary>相对上一条效果的首次触发时刻再等待延迟。</summary>
    AfterPrevious,

    /// <summary>与上一条效果在同一模拟毫秒执行。</summary>
    Simultaneous
}

/// <summary>单次效果执行前的最小跳过条件。</summary>
public enum SkillEffectCondition
{
    /// <summary>不检查，直接执行。</summary>
    Always,

    /// <summary>目标（自身或指定单位）必须存活。</summary>
    TargetAlive,

    /// <summary>目标必须存活且当前生命低于上限。</summary>
    TargetWounded
}

/// <summary>下达命令效果可映射的已有基础命令。</summary>
public enum SkillIssuedCommandKind
{
    /// <summary>普通移动到技能确认的地面或单位位置。</summary>
    Move,

    /// <summary>普通攻击技能确认的单位目标。</summary>
    Attack
}

/// <summary>效果序列中的一条基础效果定义。</summary>
/// <param name="Kind">固定效果种类。</param>
/// <param name="Amount">可选数值；本步仅保存，不解释语义。</param>
/// <param name="DelayMilliseconds">相对上一条效果首次触发的等待毫秒；首条相对正式生效时刻。</param>
/// <param name="Status">添加状态时的持续属性修正。</param>
/// <param name="Timing">与上一条的时间关系。</param>
/// <param name="PeriodMilliseconds">周期间隔；0 表示不周期重复。</param>
/// <param name="RepeatCount">包含首次在内的执行次数。</param>
/// <param name="Condition">不满足则跳过该次执行。</param>
public sealed record SkillEffectDefinition(
    SkillEffectKind Kind,
    float? Amount,
    int DelayMilliseconds = 0,
    SkillStatusDefinition? Status = null,
    SkillEffectTiming Timing = SkillEffectTiming.AfterPrevious,
    int PeriodMilliseconds = 0,
    int RepeatCount = 1,
    SkillEffectCondition Condition = SkillEffectCondition.Always,
    SkillIssuedCommandKind? IssuedCommand = null,
    BattlefieldEventKind? EmittedEvent = null,
    bool EmittedEventImportant = false,
    UnitTypeId? ObjectTemplateId = null);

/// <summary>添加状态效果携带的持续属性修正。</summary>
/// <param name="Id">稳定状态 ID，用于刷新或覆盖同一状态。</param>
/// <param name="DurationMilliseconds">状态持续时间。</param>
/// <param name="Attribute">被修改的属性。</param>
/// <param name="Modifier">属性修正；移速为相对基线的正倍率。</param>
/// <param name="Stack">再次施加时的叠加规则。</param>
public sealed record SkillStatusDefinition(
    string Id,
    int DurationMilliseconds,
    SkillAttributeKind Attribute,
    float Modifier,
    SkillStackRule Stack);

/// <summary>一份已校验的不可变技能定义。</summary>
/// <param name="Id">稳定技能 ID。</param>
/// <param name="Trigger">触发规则。</param>
/// <param name="Target">目标规则基础形状。</param>
/// <param name="Effects">至少一条基础效果，当前按配置顺序保存。</param>
/// <param name="CooldownMilliseconds">再次使用前的整数毫秒数，允许为零。</param>
/// <param name="Relation">单位目标允许的阵营关系。</param>
/// <param name="RangeMeters">最大作用距离；null 表示不限制距离。</param>
/// <param name="RequireAlive">单位目标是否必须存活。</param>
/// <param name="AllowSelf">单位目标是否允许选中施法者自己。</param>
    /// <param name="Cost">正式生效时一次性支付的资源；空表示无消耗。</param>
    /// <param name="TriggerEvent">事件触发时监听的战场事件。</param>
    /// <param name="ActivationCondition">条件触发时必须成立的装配条件。</param>
    /// <param name="EquippedUnitTypeIds">自动装配到这些单位类型；空表示只靠运行时授予。</param>
    /// <param name="CastDelayMilliseconds">正式生效前的等待；期间可按中断规则取消。</param>
    /// <param name="Interrupt">中断规则；null 表示停止或死亡不取消后续效果。</param>
public sealed record SkillDefinition(
    SkillDefinitionId Id,
    SkillTriggerKind Trigger,
    SkillTargetKind Target,
    IReadOnlyList<SkillEffectDefinition> Effects,
    int CooldownMilliseconds,
    SkillTargetRelation Relation = SkillTargetRelation.Enemy,
    float? RangeMeters = null,
    bool RequireAlive = true,
    bool AllowSelf = false,
    IReadOnlyList<ResourceAmount>? Cost = null,
    SkillTriggerEvent TriggerEvent = SkillTriggerEvent.None,
    SkillEffectCondition ActivationCondition = SkillEffectCondition.Always,
    IReadOnlyList<UnitTypeId>? EquippedUnitTypeIds = null,
    int CastDelayMilliseconds = 0,
    SkillInterruptDefinition? Interrupt = null);

/// <summary>技能允许被中断的阶段。</summary>
public enum SkillInterruptPhase
{
    /// <summary>正式生效前的施放等待。</summary>
    BeforeActivation,

    /// <summary>正式生效后、尚未执行的效果段。</summary>
    AfterActivation
}

/// <summary>可以触发技能中断的情况。</summary>
public enum SkillInterruptCause
{
    /// <summary>玩家或 AI 下达统一停止。</summary>
    Stop,

    /// <summary>施法者死亡。</summary>
    Death
}

/// <summary>一份技能的中断配置。</summary>
/// <param name="Phases">允许中断的阶段。</param>
/// <param name="Causes">会触发中断的情况。</param>
/// <param name="RefundCost">正式生效后中断时是否退还消耗。</param>
/// <param name="KeepCooldown">正式生效后中断时是否保留冷却。</param>
public sealed record SkillInterruptDefinition(
    IReadOnlyList<SkillInterruptPhase> Phases,
    IReadOnlyList<SkillInterruptCause> Causes,
    bool RefundCost,
    bool KeepCooldown);
