using AI_RTS.Domain.Common;

namespace AI_RTS.Application.Commands;

    /// <summary>提供一次命令执行所需的对局、发出者与模拟时刻信息。</summary>
public sealed record CommandContext(
    CommandId CommandId,
    MatchId MatchId,
    PlayerId IssuerPlayerId,
    long SimulationTick,
    long SimulationMilliseconds = 0);

/// <summary>表示批量命令在下达时的汇总接收状态。</summary>
public enum CommandStatus
{
    /// <summary>所有目标均已接受命令。</summary>
    Accepted,
    /// <summary>至少一个目标接受且至少一个目标拒绝命令。</summary>
    PartiallyAccepted,
    /// <summary>所有目标均被拒绝，或命令结构无效。</summary>
    Rejected
}

/// <summary>表示命令在权威执行层被拒绝的稳定原因。</summary>
public enum CommandErrorCode
{
    /// <summary>没有错误。</summary>
    None,
    /// <summary>命令没有包含任何单位。</summary>
    EmptyUnitSet,
    /// <summary>指定单位不存在或已经失效。</summary>
    UnitNotFound,
    /// <summary>命令发出者不拥有指定单位。</summary>
    UnitNotOwned,
    /// <summary>指定单位不具备移动能力。</summary>
    UnitCannotMove,
    /// <summary>指定单位尚未提供统一停止能力。</summary>
    UnitCannotStop,
    /// <summary>目标世界坐标包含非有限值。</summary>
    InvalidDestination,
    /// <summary>实体移动目标是执行单位自身，或目标种类不支持该命令。</summary>
    InvalidMovementTarget,
    /// <summary>当前无法向导航系统提交请求。</summary>
    NavigationUnavailable,
    /// <summary>单位所属玩家当前没有已完成的 CommandCenter 可供回防。</summary>
    CommandCenterNotFound,
    /// <summary>对局尚未开始或已经结束。</summary>
    MatchNotRunning,
    /// <summary>交战姿态值不属于当前版本支持的枚举项。</summary>
    InvalidEngagementStance,
    /// <summary>开火策略值不属于当前版本支持的枚举项。</summary>
    InvalidFirePolicy,
    /// <summary>攻击目标联合类型或地面坐标无效。</summary>
    InvalidAttackTarget,
    /// <summary>攻击者没有可用武器。</summary>
    UnitCannotAttack,
    /// <summary>实体攻击目标不存在或已经失效。</summary>
    TargetNotFound,
    /// <summary>受限命令来源当前未获准操作该目标，不泄漏目标是否存在。</summary>
    TargetUnavailable,
    /// <summary>实体存在，但不是当前规则下的伤害目标。</summary>
    TargetNotDamageable,
    /// <summary>攻击者武器不能攻击目标所在域。</summary>
    WeaponCannotTargetDomain,
    /// <summary>攻击者武器不支持向无实体地面位置强制开火。</summary>
    WeaponCannotForceFire,
    /// <summary>单位处于停火策略，普通攻击不能获得开火授权。</summary>
    FirePolicyPreventsAttack,
    /// <summary>迁移期攻击执行层暂时无法接收请求。</summary>
    AttackUnavailable,
    /// <summary>指定单位不具备采集能力。</summary>
    UnitCannotGather,
    /// <summary>采集命令引用的资源节点不存在或已经失效。</summary>
    ResourceTargetNotFound,
    /// <summary>指定资源节点已经耗尽。</summary>
    ResourceDepleted,
    /// <summary>迁移期 Worker 工作执行层无法接收请求。</summary>
    WorkUnavailable,
    /// <summary>指定单位不具备施工能力。</summary>
    WorkerCannotConstruct,
    /// <summary>施工现场不存在或已失效。</summary>
    ConstructionSiteNotFound,
    /// <summary>施工现场不属于命令发出者。</summary>
    ConstructionSiteNotOwned,
    /// <summary>施工现场已经完成。</summary>
    ConstructionAlreadyCompleted,
    /// <summary>施工执行层当前无法接收或暂停任务。</summary>
    ConstructionUnavailable,
    /// <summary>指定实体没有声明集结点能力。</summary>
    UnitCannotSetRallyPoint,
    /// <summary>集结目标不属于当前允许的友军或资源目标。</summary>
    RallyTargetNotAllowed,
    /// <summary>集结目标对命令发出者不可观察。</summary>
    RallyTargetNotObservable,
    /// <summary>集结点服务或表现适配器当前不可用。</summary>
    RallyPointUnavailable,

    /// <summary>技能定义不存在或当前 Catalog 不可用。</summary>
    SkillNotFound,

    /// <summary>技能存在，但当前不允许由玩家主动施放。</summary>
    SkillNotCastable,

    /// <summary>技能目标形状超出当前命令入口支持的范围。</summary>
    InvalidSkillTarget,

    /// <summary>目标阵营、自身限制或存活要求不满足技能配置。</summary>
    SkillTargetNotAllowed,

    /// <summary>目标超出技能配置的最大距离。</summary>
    SkillOutOfRange,

    /// <summary>技能仍在冷却中，不能再次正式生效。</summary>
    SkillOnCooldown,

    /// <summary>单位正在施放前等待，不能再开始一条技能。</summary>
    SkillBusy,

    /// <summary>玩家资源不足以支付技能消耗。</summary>
    InsufficientResources
}

/// <summary>记录批量命令中单个单位的接收结果和订单标识。</summary>
public sealed record UnitCommandResult(
    UnitId UnitId,
    bool Accepted,
    CommandErrorCode ErrorCode,
    UnitOrderId? OrderId = null);

/// <summary>记录一次批量命令的权威同步回执。</summary>
public sealed record CommandResult(
    CommandId CommandId,
    CommandStatus Status,
    IReadOnlyList<UnitCommandResult> UnitResults);
