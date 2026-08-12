using AI_RTS.Domain.Common;

namespace AI_RTS.Application.Commands;

/// <summary>提供一次命令执行所需的对局、发出者与模拟时刻信息。</summary>
public sealed record CommandContext(
    CommandId CommandId,
    MatchId MatchId,
    PlayerId IssuerPlayerId,
    long SimulationTick);

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
    /// <summary>目标世界坐标包含非有限值。</summary>
    InvalidDestination,
    /// <summary>当前无法向导航系统提交请求。</summary>
    NavigationUnavailable,
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
    /// <summary>实体存在，但不是当前规则下的伤害目标。</summary>
    TargetNotDamageable,
    /// <summary>攻击者武器不能攻击目标所在域。</summary>
    WeaponCannotTargetDomain,
    /// <summary>攻击者武器不支持向无实体地面位置强制开火。</summary>
    WeaponCannotForceFire,
    /// <summary>单位处于停火策略，普通攻击不能获得开火授权。</summary>
    FirePolicyPreventsAttack,
    /// <summary>迁移期攻击执行层暂时无法接收请求。</summary>
    AttackUnavailable
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
