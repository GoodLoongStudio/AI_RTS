using AI_RTS.Domain.Common;
using AI_RTS.Domain.Combat;

namespace AI_RTS.Application.Commands.Units;

/// <summary>请求一组单位普通移动到经过编队计算后的目标位置。</summary>
public sealed record MoveUnitsCommand(
    IReadOnlyList<UnitId> UnitIds,
    WorldPosition Destination);

/// <summary>请求一组单位强制移动到经过编队计算后的目标位置。</summary>
public sealed record ForceMoveUnitsCommand(
    IReadOnlyList<UnitId> UnitIds,
    WorldPosition Destination);

/// <summary>请求一组单位向地面目标推进，并按持续交战姿态处理途中敌人。</summary>
public sealed record GroundAttackMoveCommand(
    IReadOnlyList<UnitId> UnitIds,
    WorldPosition Destination);

/// <summary>请求一组单位以指定敌方实体为最终目标推进，并按持续交战姿态处理途中敌人。</summary>
public sealed record EntityAttackMoveCommand(
    IReadOnlyList<UnitId> UnitIds,
    EntityAttackTarget Target);

/// <summary>请求一组单位向指定位置战术撤退；无倒车能力的可移动单位退化为强制移动。</summary>
public sealed record TacticalWithdrawCommand(
    IReadOnlyList<UnitId> UnitIds,
    WorldPosition Destination);

/// <summary>请求一组单位停止当前移动，并保留可暂停的上层任务。</summary>
public sealed record HaltMovementCommand(IReadOnlyList<UnitId> UnitIds);

/// <summary>请求一组单位执行统一停止：暂停可保留任务，并取消显式 ForceAttack。</summary>
public sealed record StopUnitsCommand(IReadOnlyList<UnitId> UnitIds);

/// <summary>请求一组单位切换持续交战姿态，不改变其独立开火策略。</summary>
public sealed record SetEngagementStanceCommand(
    IReadOnlyList<UnitId> UnitIds,
    EngagementStance Stance);

/// <summary>请求一组单位切换持续开火策略，不改变其独立交战姿态。</summary>
public sealed record SetFirePolicyCommand(
    IReadOnlyList<UnitId> UnitIds,
    FirePolicy Policy);

/// <summary>表示 ForceAttack 可接受的实体或地面目标联合类型。</summary>
public abstract record AttackTarget;

/// <summary>引用一个进程内稳定单位身份作为持续强制攻击目标。</summary>
public sealed record EntityAttackTarget(UnitId TargetUnitId) : AttackTarget;

/// <summary>引用一个纯世界坐标；当前纵向样例会稳定返回武器不支持。</summary>
public sealed record GroundAttackTarget(WorldPosition Position) : AttackTarget;

/// <summary>请求一组单位普通攻击同一敌方实体；命令受持续停火策略约束。</summary>
public sealed record AttackCommand(
    IReadOnlyList<UnitId> UnitIds,
    EntityAttackTarget Target);

/// <summary>请求一组单位持续强制攻击同一目标，并获得订单级临时开火授权。</summary>
public sealed record ForceAttackCommand(
    IReadOnlyList<UnitId> UnitIds,
    AttackTarget Target);

/// <summary>取消一组单位当前显式 ForceAttack，不影响普通自动攻击。</summary>
public sealed record CancelForceAttackCommand(IReadOnlyList<UnitId> UnitIds);
