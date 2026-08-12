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
    /// <summary>提交批量强制移动命令，并返回每个单位的接收结果。</summary>
    CommandResult ForceMove(CommandContext context, ForceMoveUnitsCommand command);

    /// <summary>停止单位当前移动，并将已有活动订单转为暂停。</summary>
    CommandResult HaltMovement(CommandContext context, HaltMovementCommand command);

    /// <summary>设置单位持续交战姿态，不改变开火策略。</summary>
    CommandResult SetEngagementStance(CommandContext context, SetEngagementStanceCommand command);

    /// <summary>设置单位持续开火策略，不改变交战姿态。</summary>
    CommandResult SetFirePolicy(CommandContext context, SetFirePolicyCommand command);
}

/// <summary>协调单位校验、导航端口调用与订单状态更新。</summary>
public sealed class UnitCommandService(
    IUnitCommandUnitRepository units,
    IUnitMovementPort movement,
    IUnitOrderStore orders,
    ICombatPolicyStore combatPolicies) : IUnitCommandService
{
    /// <inheritdoc />
    public CommandResult ForceMove(CommandContext context, ForceMoveUnitsCommand command)
    {
        if (command.UnitIds.Count == 0 || !IsFinite(command.Destination))
        {
            return Rejected(context.CommandId, command.UnitIds,
                command.UnitIds.Count == 0 ? CommandErrorCode.EmptyUnitSet : CommandErrorCode.InvalidDestination);
        }

        return Execute(context, command.UnitIds, unitId =>
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
            if (active is not null)
            {
                orders.Transition(active.OrderId, UnitOrderState.Suspended);
            }
            results.Add(new UnitCommandResult(unitId, true, CommandErrorCode.None, active?.OrderId));
        }
        return Summarize(context.CommandId, results);
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
    private CommandResult Execute(
        CommandContext context,
        IReadOnlyList<UnitId> unitIds,
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
            var order = orders.Create(context.CommandId, unitId);
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

    private static IReadOnlyList<UnitId> StableDistinct(IEnumerable<UnitId> ids) =>
        ids.Distinct().OrderBy(id => id.Value).ToArray();

    private static bool IsFinite(WorldPosition value) =>
        float.IsFinite(value.X) && float.IsFinite(value.Y) && float.IsFinite(value.Z);

    private static CommandErrorCode Map(MovementPortError error) => error switch
    {
        MovementPortError.NavigationUnavailable => CommandErrorCode.NavigationUnavailable,
        _ => CommandErrorCode.UnitNotFound
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
