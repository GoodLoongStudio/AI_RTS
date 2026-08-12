using AI_RTS.Application.Commands.Units;
using AI_RTS.Application.Orders;
using AI_RTS.Application.Units;
using AI_RTS.Domain.Common;

namespace AI_RTS.Application.Commands;

public interface IUnitCommandService
{
    CommandResult Move(CommandContext context, MoveUnitsCommand command);
    CommandResult HaltMovement(CommandContext context, HaltMovementCommand command);
}

public sealed class UnitCommandService(
    IUnitCommandUnitRepository units,
    IUnitMovementPort movement,
    IUnitOrderStore orders) : IUnitCommandService
{
    public CommandResult Move(CommandContext context, MoveUnitsCommand command)
    {
        if (command.UnitIds.Count == 0 || !IsFinite(command.Destination))
            return Rejected(context.CommandId, command.UnitIds,
                command.UnitIds.Count == 0 ? CommandErrorCode.EmptyUnitSet : CommandErrorCode.InvalidDestination);

        return Execute(context, command.UnitIds, unitId =>
            movement.RequestMove(unitId, command.Destination));
    }

    public CommandResult HaltMovement(CommandContext context, HaltMovementCommand command)
    {
        if (command.UnitIds.Count == 0)
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.EmptyUnitSet);

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
                orders.Transition(active.OrderId, UnitOrderState.Suspended);
            results.Add(new UnitCommandResult(unitId, true, CommandErrorCode.None, active?.OrderId));
        }
        return Summarize(context.CommandId, results);
    }

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

    private CommandErrorCode Validate(CommandContext context, UnitId unitId)
    {
        var unit = units.Find(unitId);
        if (unit is null)
            return CommandErrorCode.UnitNotFound;
        if (unit.Value.OwnerId != context.IssuerPlayerId)
            return CommandErrorCode.UnitNotOwned;
        return unit.Value.CanMove ? CommandErrorCode.None : CommandErrorCode.UnitCannotMove;
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

    private static CommandResult Summarize(CommandId commandId, IReadOnlyList<UnitCommandResult> results)
    {
        var accepted = results.Count(result => result.Accepted);
        var status = accepted == 0 ? CommandStatus.Rejected :
            accepted == results.Count ? CommandStatus.Accepted : CommandStatus.PartiallyAccepted;
        return new CommandResult(commandId, status, results);
    }
}
