using AI_RTS.Application.Commands.Units;
using AI_RTS.Application.Combat;
using AI_RTS.Application.Orders;
using AI_RTS.Application.Units;
using AI_RTS.Domain.Combat;
using AI_RTS.Domain.Common;

namespace AI_RTS.Application.Commands;

/// <summary>提供经过权限与能力校验的单位命令入口。</summary>
public interface IUnitCommandService
{
    /// <summary>提交批量普通移动命令，并返回每个单位的接收结果。</summary>
    CommandResult Move(CommandContext context, MoveUnitsCommand command);

    /// <summary>提交批量强制移动命令，并返回每个单位的接收结果。</summary>
    CommandResult ForceMove(CommandContext context, ForceMoveUnitsCommand command);

    /// <summary>提交批量地面移动攻击命令，并返回逐单位接收结果。</summary>
    CommandResult GroundAttackMove(CommandContext context, GroundAttackMoveCommand command);

    /// <summary>提交以敌方实体为最终目标的移动攻击命令，并返回逐单位接收结果。</summary>
    CommandResult EntityAttackMove(CommandContext context, EntityAttackMoveCommand command);

    /// <summary>提交批量战术撤退命令，并按单位能力选择倒车或普通移动执行。</summary>
    CommandResult TacticalWithdraw(CommandContext context, TacticalWithdrawCommand command);

    /// <summary>停止单位当前移动，并将已有活动订单转为暂停。</summary>
    CommandResult HaltMovement(CommandContext context, HaltMovementCommand command);

    /// <summary>提交批量统一停止命令，并返回每个单位独立的接收结果。</summary>
    CommandResult Stop(CommandContext context, StopUnitsCommand command);

    /// <summary>设置单位持续交战姿态，不改变开火策略。</summary>
    CommandResult SetEngagementStance(CommandContext context, SetEngagementStanceCommand command);

    /// <summary>设置单位持续开火策略，不改变交战姿态。</summary>
    CommandResult SetFirePolicy(CommandContext context, SetFirePolicyCommand command);

    /// <summary>提交批量普通实体攻击；停火或非敌方目标按单位稳定拒绝。</summary>
    CommandResult Attack(CommandContext context, AttackCommand command);

    /// <summary>提交批量显式强制攻击，并返回每个攻击者的接收结果。</summary>
    CommandResult ForceAttack(CommandContext context, ForceAttackCommand command);

    /// <summary>只取消当前显式 ForceAttack，不影响普通自动攻击。</summary>
    CommandResult CancelForceAttack(CommandContext context, CancelForceAttackCommand command);

    /// <summary>提交持续采集任务，并返回每个 Worker 的独立接收结果。</summary>
    CommandResult GatherResources(CommandContext context, GatherResourcesCommand command);
}

/// <summary>协调单位校验、导航端口调用与订单状态更新。</summary>
public sealed class UnitCommandService(
    IUnitCommandUnitRepository units,
    IUnitMovementPort movement,
    IUnitAttackPort attack,
    IUnitOrderStore orders,
    ICombatPolicyStore combatPolicies,
    IUnitStopPort stop,
    IWorkerTaskPort? workerTasks = null,
    IResourceNodeRepository? resourceNodes = null) : IUnitCommandService
{
    /// <inheritdoc />
    public CommandResult Move(CommandContext context, MoveUnitsCommand command)
    {
        if (command.UnitIds.Count == 0 || !IsFinite(command.Destination))
        {
            return Rejected(context.CommandId, command.UnitIds,
                command.UnitIds.Count == 0 ? CommandErrorCode.EmptyUnitSet : CommandErrorCode.InvalidDestination);
        }

        return ExecuteMove(context, command.UnitIds, UnitOrderKind.Move, unitId =>
            movement.RequestMove(unitId, command.Destination));
    }

    /// <inheritdoc />
    public CommandResult ForceMove(CommandContext context, ForceMoveUnitsCommand command)
    {
        if (command.UnitIds.Count == 0 || !IsFinite(command.Destination))
        {
            return Rejected(context.CommandId, command.UnitIds,
                command.UnitIds.Count == 0 ? CommandErrorCode.EmptyUnitSet : CommandErrorCode.InvalidDestination);
        }

        return ExecuteMove(context, command.UnitIds, UnitOrderKind.ForceMove, unitId =>
            movement.RequestMove(unitId, command.Destination));
    }

    /// <inheritdoc />
    public CommandResult GroundAttackMove(CommandContext context, GroundAttackMoveCommand command)
    {
        if (command.UnitIds.Count == 0 || !IsFinite(command.Destination))
        {
            return Rejected(context.CommandId, command.UnitIds,
                command.UnitIds.Count == 0 ? CommandErrorCode.EmptyUnitSet : CommandErrorCode.InvalidDestination);
        }

        return ExecuteMove(context, command.UnitIds, UnitOrderKind.GroundAttackMove, unitId =>
            movement.RequestGroundAttackMove(unitId, command.Destination));
    }

    /// <inheritdoc />
    public CommandResult EntityAttackMove(CommandContext context, EntityAttackMoveCommand command)
    {
        if (command.UnitIds.Count == 0)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.EmptyUnitSet);
        }

        var target = units.Find(command.Target.TargetUnitId);
        if (target is null)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.TargetNotFound);
        }
        if (!target.Value.IsDamageable)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.TargetNotDamageable);
        }

        var results = new List<UnitCommandResult>();
        foreach (var unitId in StableDistinct(command.UnitIds))
        {
            var validation = ValidateAttackMove(context, unitId, target.Value);
            if (validation != CommandErrorCode.None)
            {
                results.Add(new UnitCommandResult(unitId, false, validation));
                continue;
            }

            var portResult = movement.RequestEntityAttackMove(unitId, command.Target.TargetUnitId);
            if (!portResult.Accepted)
            {
                results.Add(new UnitCommandResult(unitId, false, Map(portResult.Error)));
                continue;
            }

            var order = orders.Create(context.CommandId, unitId, UnitOrderKind.EntityAttackMove);
            orders.Transition(order.OrderId, UnitOrderState.InProgress);
            results.Add(new UnitCommandResult(unitId, true, CommandErrorCode.None, order.OrderId));
        }
        return Summarize(context.CommandId, results);
    }

    /// <inheritdoc />
    public CommandResult TacticalWithdraw(CommandContext context, TacticalWithdrawCommand command)
    {
        if (command.UnitIds.Count == 0 || !IsFinite(command.Destination))
        {
            return Rejected(context.CommandId, command.UnitIds,
                command.UnitIds.Count == 0 ? CommandErrorCode.EmptyUnitSet : CommandErrorCode.InvalidDestination);
        }

        return ExecuteMove(
            context,
            command.UnitIds,
            UnitOrderKind.TacticalWithdraw,
            unitId => units.Find(unitId)!.Value.CanReverse ?
                movement.RequestTacticalWithdraw(unitId, command.Destination) :
                movement.RequestMove(unitId, command.Destination));
    }

    /// <inheritdoc />
    public CommandResult HaltMovement(CommandContext context, HaltMovementCommand command)
    {
        if (command.UnitIds.Count == 0)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.EmptyUnitSet);
        }

        var results = new List<UnitCommandResult>();
        foreach (var unitId in StableDistinct(command.UnitIds))
        {
            var validation = Validate(context, unitId);
            if (validation != CommandErrorCode.None)
            {
                results.Add(new UnitCommandResult(unitId, false, validation));
                continue;
            }

            var portResult = movement.RequestHalt(unitId);
            if (!portResult.Accepted)
            {
                results.Add(new UnitCommandResult(unitId, false, Map(portResult.Error)));
                continue;
            }

            var active = orders.FindActive(unitId);
            if (active?.Kind is UnitOrderKind.Move or UnitOrderKind.ForceMove or
                UnitOrderKind.GroundAttackMove or UnitOrderKind.EntityAttackMove or
                UnitOrderKind.TacticalWithdraw)
            {
                orders.Transition(active.OrderId, UnitOrderState.Suspended);
            }
            results.Add(new UnitCommandResult(
                unitId,
                true,
                CommandErrorCode.None,
                active?.Kind is UnitOrderKind.Move or UnitOrderKind.ForceMove or
                    UnitOrderKind.GroundAttackMove or UnitOrderKind.EntityAttackMove or
                    UnitOrderKind.TacticalWithdraw ?
                    active.OrderId : null));
        }
        return Summarize(context.CommandId, results);
    }

    /// <inheritdoc />
    public CommandResult GatherResources(
        CommandContext context,
        GatherResourcesCommand command)
    {
        if (command.WorkerIds.Count == 0)
        {
            return Rejected(
                context.CommandId,
                command.WorkerIds,
                CommandErrorCode.EmptyUnitSet);
        }

        var resource = resourceNodes?.Find(command.TargetResourceId);
        if (resource is null)
        {
            return Rejected(
                context.CommandId,
                command.WorkerIds,
                CommandErrorCode.ResourceTargetNotFound);
        }
        if (!resource.Value.IsAvailable)
        {
            return Rejected(
                context.CommandId,
                command.WorkerIds,
                CommandErrorCode.ResourceDepleted);
        }

        var results = new List<UnitCommandResult>();
        foreach (var workerId in StableDistinct(command.WorkerIds))
        {
            var ownership = ValidateOwnership(context, workerId);
            if (ownership != CommandErrorCode.None)
            {
                results.Add(new UnitCommandResult(workerId, false, ownership));
                continue;
            }

            var worker = units.Find(workerId)!.Value;
            if (!worker.CanGather)
            {
                results.Add(new UnitCommandResult(
                    workerId,
                    false,
                    CommandErrorCode.UnitCannotGather));
                continue;
            }

            var portResult = workerTasks?.RequestGather(workerId, command.TargetResourceId);
            if (portResult is null || !portResult.Value.Accepted)
            {
                results.Add(new UnitCommandResult(
                    workerId,
                    false,
                    portResult is null ?
                        CommandErrorCode.WorkUnavailable : Map(portResult.Value.Error)));
                continue;
            }

            var order = orders.Create(context.CommandId, workerId, UnitOrderKind.Gather);
            orders.Transition(order.OrderId, UnitOrderState.InProgress);
            results.Add(new UnitCommandResult(
                workerId,
                true,
                CommandErrorCode.None,
                order.OrderId));
        }

        return Summarize(context.CommandId, results);
    }

    /// <inheritdoc />
    public CommandResult Stop(CommandContext context, StopUnitsCommand command)
    {
        if (command.UnitIds.Count == 0)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.EmptyUnitSet);
        }

        var results = new List<UnitCommandResult>();
        foreach (var unitId in StableDistinct(command.UnitIds))
        {
            var validation = ValidateOwnership(context, unitId);
            if (validation != CommandErrorCode.None)
            {
                results.Add(new UnitCommandResult(unitId, false, validation));
                continue;
            }

            var active = orders.FindActive(unitId);
            if (active?.Kind == UnitOrderKind.Gather)
            {
                var workResult = workerTasks?.RequestSuspend(unitId);
                if (workResult is null || !workResult.Value.Accepted)
                {
                    results.Add(new UnitCommandResult(
                        unitId,
                        false,
                        workResult is null ?
                            CommandErrorCode.WorkUnavailable : Map(workResult.Value.Error)));
                    continue;
                }
            }
            else
            {
                var portResult = stop.RequestStop(unitId);
                if (!portResult.Accepted)
                {
                    results.Add(new UnitCommandResult(unitId, false, Map(portResult.Error)));
                    continue;
                }
            }

            var affectedOrderId = TransitionStoppedOrder(context, active);
            results.Add(new UnitCommandResult(
                unitId,
                true,
                CommandErrorCode.None,
                affectedOrderId));
        }

        return Summarize(context.CommandId, results);
    }

    /// <summary>按照订单种类应用统一停止状态；攻击订单取消，持续战斗策略保持不变。</summary>
    private UnitOrderId? TransitionStoppedOrder(
        CommandContext context,
        UnitOrderSnapshot? active)
    {
        if (active?.Kind is UnitOrderKind.Move or UnitOrderKind.ForceMove or
            UnitOrderKind.GroundAttackMove or UnitOrderKind.EntityAttackMove or
            UnitOrderKind.TacticalWithdraw or UnitOrderKind.Gather)
        {
            orders.Transition(active.OrderId, UnitOrderState.Suspended);
            return active.OrderId;
        }
        if (active?.Kind is UnitOrderKind.Attack or UnitOrderKind.ForceAttack or
            UnitOrderKind.GroundForceAttack)
        {
            orders.Transition(active.OrderId, UnitOrderState.Cancelled, context.CommandId);
            return active.OrderId;
        }

        return null;
    }

    /// <inheritdoc />
    public CommandResult SetEngagementStance(
        CommandContext context,
        SetEngagementStanceCommand command)
    {
        if (command.UnitIds.Count == 0 || !Enum.IsDefined(command.Stance))
        {
            return Rejected(
                context.CommandId,
                command.UnitIds,
                command.UnitIds.Count == 0 ?
                    CommandErrorCode.EmptyUnitSet : CommandErrorCode.InvalidEngagementStance);
        }

        return SetCombatPolicy(
            context,
            command.UnitIds,
            unitId => combatPolicies.SetEngagementStance(unitId, command.Stance));
    }

    /// <inheritdoc />
    public CommandResult SetFirePolicy(CommandContext context, SetFirePolicyCommand command)
    {
        if (command.UnitIds.Count == 0 || !Enum.IsDefined(command.Policy))
        {
            return Rejected(
                context.CommandId,
                command.UnitIds,
                command.UnitIds.Count == 0 ?
                    CommandErrorCode.EmptyUnitSet : CommandErrorCode.InvalidFirePolicy);
        }

        return SetCombatPolicy(
            context,
            command.UnitIds,
            unitId => combatPolicies.SetFirePolicy(unitId, command.Policy));
    }

    /// <inheritdoc />
    public CommandResult Attack(CommandContext context, AttackCommand command)
    {
        if (command.UnitIds.Count == 0)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.EmptyUnitSet);
        }

        var target = units.Find(command.Target.TargetUnitId);
        if (target is null)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.TargetNotFound);
        }
        if (!target.Value.IsDamageable)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.TargetNotDamageable);
        }

        var results = new List<UnitCommandResult>();
        foreach (var unitId in StableDistinct(command.UnitIds))
        {
            var validation = ValidateAttack(context, unitId, target.Value, false);
            if (validation != CommandErrorCode.None)
            {
                results.Add(new UnitCommandResult(unitId, false, validation));
                continue;
            }

            var portResult = attack.RequestEntityAttack(unitId, command.Target.TargetUnitId);
            if (!portResult.Accepted)
            {
                results.Add(new UnitCommandResult(unitId, false, Map(portResult.Error)));
                continue;
            }

            var order = orders.Create(context.CommandId, unitId, UnitOrderKind.Attack);
            orders.Transition(order.OrderId, UnitOrderState.InProgress);
            results.Add(new UnitCommandResult(unitId, true, CommandErrorCode.None, order.OrderId));
        }
        return Summarize(context.CommandId, results);
    }

    /// <inheritdoc />
    public CommandResult ForceAttack(CommandContext context, ForceAttackCommand command)
    {
        if (command.UnitIds.Count == 0)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.EmptyUnitSet);
        }
        if (command.Target is GroundAttackTarget groundTarget)
        {
            if (!IsFinite(groundTarget.Position))
            {
                return Rejected(
                    context.CommandId,
                    command.UnitIds,
                    CommandErrorCode.InvalidAttackTarget);
            }

            return ExecuteGroundForceAttack(context, command.UnitIds, groundTarget.Position);
        }
        if (command.Target is not EntityAttackTarget entityTarget)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.InvalidAttackTarget);
        }

        var target = units.Find(entityTarget.TargetUnitId);
        if (target is null)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.TargetNotFound);
        }
        if (!target.Value.IsDamageable)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.TargetNotDamageable);
        }

        var results = new List<UnitCommandResult>();
        foreach (var unitId in StableDistinct(command.UnitIds))
        {
            var validation = ValidateAttack(context, unitId, target.Value, true);
            if (validation != CommandErrorCode.None)
            {
                results.Add(new UnitCommandResult(unitId, false, validation));
                continue;
            }

            var portResult = attack.RequestEntityForceAttack(unitId, entityTarget.TargetUnitId);
            if (!portResult.Accepted)
            {
                results.Add(new UnitCommandResult(unitId, false, Map(portResult.Error)));
                continue;
            }

            var order = orders.Create(context.CommandId, unitId, UnitOrderKind.ForceAttack);
            orders.Transition(order.OrderId, UnitOrderState.InProgress);
            results.Add(new UnitCommandResult(unitId, true, CommandErrorCode.None, order.OrderId));
        }
        return Summarize(context.CommandId, results);
    }

    /// <inheritdoc />
    public CommandResult CancelForceAttack(
        CommandContext context,
        CancelForceAttackCommand command)
    {
        if (command.UnitIds.Count == 0)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.EmptyUnitSet);
        }

        var results = new List<UnitCommandResult>();
        foreach (var unitId in StableDistinct(command.UnitIds))
        {
            var validation = ValidateOwnership(context, unitId);
            if (validation != CommandErrorCode.None)
            {
                results.Add(new UnitCommandResult(unitId, false, validation));
                continue;
            }

            var portResult = attack.RequestCancelForceAttack(unitId);
            if (!portResult.Accepted)
            {
                results.Add(new UnitCommandResult(unitId, false, Map(portResult.Error)));
                continue;
            }

            var active = orders.FindActive(unitId);
            if (active?.Kind is UnitOrderKind.ForceAttack or UnitOrderKind.GroundForceAttack)
            {
                orders.Transition(active.OrderId, UnitOrderState.Cancelled, context.CommandId);
            }
            results.Add(new UnitCommandResult(
                unitId,
                true,
                CommandErrorCode.None,
                active?.Kind is UnitOrderKind.ForceAttack or UnitOrderKind.GroundForceAttack ?
                    active.OrderId : null));
        }
        return Summarize(context.CommandId, results);
    }

    /// <summary>逐单位校验地面强制开火能力并创建持续地面攻击订单。</summary>
    private CommandResult ExecuteGroundForceAttack(
        CommandContext context,
        IReadOnlyList<UnitId> unitIds,
        WorldPosition position)
    {
        var results = new List<UnitCommandResult>();
        foreach (var unitId in StableDistinct(unitIds))
        {
            var ownership = ValidateOwnership(context, unitId);
            if (ownership != CommandErrorCode.None)
            {
                results.Add(new UnitCommandResult(unitId, false, ownership));
                continue;
            }

            var attacker = units.Find(unitId)!.Value;
            if (!attacker.CanAttack)
            {
                results.Add(new UnitCommandResult(
                    unitId,
                    false,
                    CommandErrorCode.UnitCannotAttack));
                continue;
            }
            if (!attacker.CanForceFireGround)
            {
                results.Add(new UnitCommandResult(
                    unitId,
                    false,
                    CommandErrorCode.WeaponCannotForceFire));
                continue;
            }

            var portResult = attack.RequestGroundForceAttack(unitId, position);
            if (!portResult.Accepted)
            {
                results.Add(new UnitCommandResult(unitId, false, Map(portResult.Error)));
                continue;
            }

            var order = orders.Create(context.CommandId, unitId, UnitOrderKind.GroundForceAttack);
            orders.Transition(order.OrderId, UnitOrderState.InProgress);
            results.Add(new UnitCommandResult(
                unitId,
                true,
                CommandErrorCode.None,
                order.OrderId));
        }

        return Summarize(context.CommandId, results);
    }

    /// <summary>逐单位校验所有权并修改彼此独立的持续战斗策略。</summary>
    private CommandResult SetCombatPolicy(
        CommandContext context,
        IReadOnlyList<UnitId> unitIds,
        Action<UnitId> update)
    {
        var results = new List<UnitCommandResult>();
        foreach (var unitId in StableDistinct(unitIds))
        {
            var validation = ValidateOwnership(context, unitId);
            if (validation != CommandErrorCode.None)
            {
                results.Add(new UnitCommandResult(unitId, false, validation));
                continue;
            }

            update(unitId);
            results.Add(new UnitCommandResult(unitId, true, CommandErrorCode.None));
        }
        return Summarize(context.CommandId, results);
    }

    /// <summary>逐单位校验并执行可独立接受的批量移动请求。</summary>
    private CommandResult ExecuteMove(
        CommandContext context,
        IReadOnlyList<UnitId> unitIds,
        UnitOrderKind orderKind,
        Func<UnitId, MovementPortResult> execute)
    {
        var results = new List<UnitCommandResult>();
        foreach (var unitId in StableDistinct(unitIds))
        {
            var validation = Validate(context, unitId);
            if (validation != CommandErrorCode.None)
            {
                results.Add(new UnitCommandResult(unitId, false, validation));
                continue;
            }

            var portResult = execute(unitId);
            if (!portResult.Accepted)
            {
                results.Add(new UnitCommandResult(unitId, false, Map(portResult.Error)));
                continue;
            }
            var order = orders.Create(context.CommandId, unitId, orderKind);
            orders.Transition(order.OrderId, UnitOrderState.InProgress);
            results.Add(new UnitCommandResult(unitId, true, CommandErrorCode.None, order.OrderId));
        }
        return Summarize(context.CommandId, results);
    }

    /// <summary>校验单位是否存在、属于命令发出者且具备移动能力。</summary>
    private CommandErrorCode Validate(CommandContext context, UnitId unitId)
    {
        var ownership = ValidateOwnership(context, unitId);
        if (ownership != CommandErrorCode.None)
        {
            return ownership;
        }

        return units.Find(unitId)!.Value.CanMove ?
            CommandErrorCode.None : CommandErrorCode.UnitCannotMove;
    }

    /// <summary>校验单位是否存在并属于命令发出者，不附加移动或攻击能力要求。</summary>
    private CommandErrorCode ValidateOwnership(CommandContext context, UnitId unitId)
    {
        var unit = units.Find(unitId);
        if (unit is null)
        {
            return CommandErrorCode.UnitNotFound;
        }
        return unit.Value.OwnerId == context.IssuerPlayerId ?
            CommandErrorCode.None : CommandErrorCode.UnitNotOwned;
    }

    /// <summary>校验实体攻击的所有权、敌我关系、停火策略、武器能力和目标域。</summary>
    private CommandErrorCode ValidateAttack(
        CommandContext context,
        UnitId unitId,
        UnitCommandSnapshot target,
        bool isForceAttack)
    {
        var ownership = ValidateOwnership(context, unitId);
        if (ownership != CommandErrorCode.None)
        {
            return ownership;
        }

        var attacker = units.Find(unitId)!.Value;
        if (!isForceAttack && attacker.OwnerId == target.OwnerId)
        {
            return CommandErrorCode.InvalidAttackTarget;
        }
        if (!isForceAttack && combatPolicies.Get(unitId).FirePolicy == FirePolicy.HoldFire)
        {
            return CommandErrorCode.FirePolicyPreventsAttack;
        }
        if (!attacker.CanAttack)
        {
            return CommandErrorCode.UnitCannotAttack;
        }
        return attacker.AttackDomains?.Contains(target.Domain) == true ?
            CommandErrorCode.None : CommandErrorCode.WeaponCannotTargetDomain;
    }

    /// <summary>校验实体移动攻击的所有权、移动与攻击能力、敌我关系及目标域；停火仅抑制开火，不拒绝推进。</summary>
    private CommandErrorCode ValidateAttackMove(
        CommandContext context,
        UnitId unitId,
        UnitCommandSnapshot target)
    {
        var ownership = ValidateOwnership(context, unitId);
        if (ownership != CommandErrorCode.None)
        {
            return ownership;
        }

        var attacker = units.Find(unitId)!.Value;
        if (attacker.OwnerId == target.OwnerId)
        {
            return CommandErrorCode.InvalidAttackTarget;
        }
        if (!attacker.CanMove)
        {
            return CommandErrorCode.UnitCannotMove;
        }
        if (!attacker.CanAttack)
        {
            return CommandErrorCode.UnitCannotAttack;
        }
        return attacker.AttackDomains?.Contains(target.Domain) == true ?
            CommandErrorCode.None : CommandErrorCode.WeaponCannotTargetDomain;
    }

    private static IReadOnlyList<UnitId> StableDistinct(IEnumerable<UnitId> ids) =>
        ids.Distinct().OrderBy(id => id.Value).ToArray();

    private static bool IsFinite(WorldPosition value) =>
        float.IsFinite(value.X) && float.IsFinite(value.Y) && float.IsFinite(value.Z);

    private static CommandErrorCode Map(MovementPortError error) => error switch
    {
        MovementPortError.NavigationUnavailable => CommandErrorCode.NavigationUnavailable,
        _ => CommandErrorCode.UnitNotFound
    };

    private static CommandErrorCode Map(AttackPortError error) => error switch
    {
        AttackPortError.AttackUnavailable => CommandErrorCode.AttackUnavailable,
        _ => CommandErrorCode.UnitNotFound
    };

    /// <summary>把统一停止端口错误转换为不泄漏执行层细节的稳定命令错误。</summary>
    private static CommandErrorCode Map(StopPortError error) => error switch
    {
        StopPortError.UnitUnavailable => CommandErrorCode.UnitNotFound,
        StopPortError.StopUnavailable => CommandErrorCode.UnitCannotStop,
        _ => CommandErrorCode.UnitCannotStop
    };

    /// <summary>把 Worker 工作端口错误转换为稳定命令错误。</summary>
    private static CommandErrorCode Map(WorkerTaskPortError error) => error switch
    {
        WorkerTaskPortError.UnitUnavailable => CommandErrorCode.UnitNotFound,
        WorkerTaskPortError.TargetUnavailable => CommandErrorCode.ResourceTargetNotFound,
        _ => CommandErrorCode.WorkUnavailable
    };

    private static CommandResult Rejected(
        CommandId commandId, IReadOnlyList<UnitId> unitIds, CommandErrorCode error) =>
        new(commandId, CommandStatus.Rejected,
            StableDistinct(unitIds).Select(id => new UnitCommandResult(id, false, error)).ToArray());

    /// <summary>根据逐单位结果计算批量命令的 Accepted、PartiallyAccepted 或 Rejected 状态。</summary>
    private static CommandResult Summarize(CommandId commandId, IReadOnlyList<UnitCommandResult> results)
    {
        var accepted = results.Count(result => result.Accepted);
        var status = accepted == 0 ? CommandStatus.Rejected :
            accepted == results.Count ? CommandStatus.Accepted : CommandStatus.PartiallyAccepted;
        return new CommandResult(commandId, status, results);
    }
}
