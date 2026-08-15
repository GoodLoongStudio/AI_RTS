using AI_RTS.Application.Commands;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Rally;

namespace AI_RTS.Application.Rally;

/// <summary>管理每座生产者彼此独立的集结目标、权限、幂等版本和失效清理。</summary>
public sealed class RallyPointService(
    IRallyProducerRepository producers,
    IRallyTargetRepository targets,
    IRallyPositionValidator positions) : IRallyPointService
{
    private readonly Dictionary<UnitId, RallyPointSnapshot> _points = new();

    /// <inheritdoc />
    public event Action<RallyPointChanged>? Changed;

    /// <inheritdoc />
    public event Action<RallyPointCleared>? Cleared;

    /// <inheritdoc />
    public CommandResult SetPosition(CommandContext context, SetRallyPositionCommand command)
    {
        if (command.ProducerIds.Count == 0 || !Finite(command.Destination) ||
            !positions.IsInsideMap(command.Destination))
        {
            return RejectAll(
                context.CommandId,
                command.ProducerIds,
                command.ProducerIds.Count == 0 ?
                    CommandErrorCode.EmptyUnitSet : CommandErrorCode.InvalidDestination);
        }
        return Apply(context, command.ProducerIds, new RallyPositionTarget(command.Destination));
    }

    /// <inheritdoc />
    public CommandResult SetTarget(CommandContext context, SetRallyTargetCommand command)
    {
        if (command.ProducerIds.Count == 0)
        {
            return RejectAll(context.CommandId, command.ProducerIds, CommandErrorCode.EmptyUnitSet);
        }
        var targetError = ValidateTarget(context.IssuerPlayerId, command.Target);
        if (targetError != CommandErrorCode.None)
        {
            return RejectAll(context.CommandId, command.ProducerIds, targetError);
        }
        return Apply(context, command.ProducerIds, command.Target);
    }

    /// <inheritdoc />
    public CommandResult Clear(CommandContext context, ClearRallyPointCommand command)
    {
        if (command.ProducerIds.Count == 0)
        {
            return RejectAll(context.CommandId, command.ProducerIds, CommandErrorCode.EmptyUnitSet);
        }
        var results = new List<UnitCommandResult>();
        foreach (var producerId in StableDistinct(command.ProducerIds))
        {
            var error = ValidateProducer(context, producerId);
            if (error != CommandErrorCode.None)
            {
                results.Add(new UnitCommandResult(producerId, false, error));
                continue;
            }
            if (_points.Remove(producerId, out var previous))
            {
                Cleared?.Invoke(new RallyPointCleared(
                    previous, RallyPointClearReason.Explicit, context.SimulationTick));
            }
            results.Add(new UnitCommandResult(producerId, true, CommandErrorCode.None));
        }
        return Summarize(context.CommandId, results);
    }

    /// <inheritdoc />
    public void LoseTarget(RallyTarget target, long simulationTick)
    {
        foreach (var item in _points.Values.Where(item => item.Target == target).ToArray())
        {
            _points.Remove(item.ProducerId);
            Cleared?.Invoke(new RallyPointCleared(
                item, RallyPointClearReason.TargetLost, simulationTick));
        }
    }

    /// <inheritdoc />
    public void LoseProducer(UnitId producerId, long simulationTick)
    {
        if (_points.Remove(producerId, out var previous))
        {
            Cleared?.Invoke(new RallyPointCleared(
                previous, RallyPointClearReason.ProducerLost, simulationTick));
        }
    }

    /// <inheritdoc />
    public RallyPointSnapshot? Find(UnitId producerId) => _points.GetValueOrDefault(producerId);

    /// <summary>逐生产者校验并原子替换其独立目标。</summary>
    private CommandResult Apply(
        CommandContext context,
        IReadOnlyList<UnitId> producerIds,
        RallyTarget target)
    {
        var results = new List<UnitCommandResult>();
        foreach (var producerId in StableDistinct(producerIds))
        {
            var error = ValidateProducer(context, producerId);
            if (error == CommandErrorCode.None && target is RallyUnitTarget unitTarget &&
                unitTarget.TargetUnitId == producerId)
            {
                error = CommandErrorCode.RallyTargetNotAllowed;
            }
            if (error != CommandErrorCode.None)
            {
                results.Add(new UnitCommandResult(producerId, false, error));
                continue;
            }

            var previous = Find(producerId);
            if (previous?.Target != target)
            {
                var current = new RallyPointSnapshot(
                    producerId,
                    context.IssuerPlayerId,
                    target,
                    checked((previous?.Version ?? 0) + 1),
                    context.SimulationTick);
                _points[producerId] = current;
                Changed?.Invoke(new RallyPointChanged(current, previous, context.SimulationTick));
            }
            results.Add(new UnitCommandResult(producerId, true, CommandErrorCode.None));
        }
        return Summarize(context.CommandId, results);
    }

    /// <summary>校验实体或资源目标的存续、观察权限和同玩家限制。</summary>
    private CommandErrorCode ValidateTarget(PlayerId issuer, RallyTarget target)
    {
        if (target is RallyUnitTarget unitTarget)
        {
            var snapshot = targets.FindUnit(unitTarget.TargetUnitId, issuer);
            if (snapshot is null || !snapshot.Value.IsAlive)
            {
                return CommandErrorCode.TargetNotFound;
            }
            if (!snapshot.Value.IsObservable)
            {
                return CommandErrorCode.RallyTargetNotObservable;
            }
            return snapshot.Value.OwnerId == issuer ?
                CommandErrorCode.None : CommandErrorCode.RallyTargetNotAllowed;
        }
        if (target is RallyResourceTarget resourceTarget)
        {
            var snapshot = targets.FindResource(resourceTarget.TargetResourceId, issuer);
            if (snapshot is null || !snapshot.Value.IsAvailable)
            {
                return CommandErrorCode.ResourceTargetNotFound;
            }
            return snapshot.Value.IsObservable ?
                CommandErrorCode.None : CommandErrorCode.RallyTargetNotObservable;
        }
        return CommandErrorCode.InvalidDestination;
    }

    /// <summary>校验生产者存在、存活、已施工完成、归属正确且声明集结能力。</summary>
    private CommandErrorCode ValidateProducer(CommandContext context, UnitId producerId)
    {
        var producer = producers.Find(producerId);
        if (producer is null || !producer.Value.IsAlive)
        {
            return CommandErrorCode.UnitNotFound;
        }
        if (producer.Value.OwnerId != context.IssuerPlayerId)
        {
            return CommandErrorCode.UnitNotOwned;
        }
        return producer.Value.IsConstructed && producer.Value.CanSetRallyPoint ?
            CommandErrorCode.None : CommandErrorCode.UnitCannotSetRallyPoint;
    }

    /// <summary>按 UnitId 稳定排序并去除重复生产者。</summary>
    private static IEnumerable<UnitId> StableDistinct(IEnumerable<UnitId> ids) =>
        ids.Distinct().OrderBy(id => id.Value);

    /// <summary>汇总逐生产者接收结果。</summary>
    private static CommandResult Summarize(
        CommandId commandId,
        IReadOnlyList<UnitCommandResult> results)
    {
        var accepted = results.Count(result => result.Accepted);
        var status = accepted == 0 ? CommandStatus.Rejected :
            accepted == results.Count ? CommandStatus.Accepted : CommandStatus.PartiallyAccepted;
        return new CommandResult(commandId, status, results);
    }

    /// <summary>为结构性无效命令创建逐生产者拒绝结果。</summary>
    private static CommandResult RejectAll(
        CommandId commandId,
        IEnumerable<UnitId> producerIds,
        CommandErrorCode error) => Summarize(
            commandId,
            StableDistinct(producerIds)
                .Select(id => new UnitCommandResult(id, false, error))
                .ToArray());

    private static bool Finite(WorldPosition position) =>
        float.IsFinite(position.X) && float.IsFinite(position.Y) && float.IsFinite(position.Z);
}
