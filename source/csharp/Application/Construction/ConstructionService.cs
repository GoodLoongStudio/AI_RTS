using AI_RTS.Application.Commands;
using AI_RTS.Application.Economy;
using AI_RTS.Application.Orders;
using AI_RTS.Application.Units;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Construction;
using AI_RTS.Domain.Economy;

namespace AI_RTS.Application.Construction;

/// <summary>以内存现场和活动分配统一处理施工命令、整数进度、退款与终态清理。</summary>
public sealed class ConstructionService : IConstructionService
{
    private readonly IUnitCommandUnitRepository _units;
    private readonly IUnitOrderStore _orders;
    private readonly IConstructionWorkerPort _workers;
    private readonly IConstructionSitePort _sitePort;
    private readonly IResourceAccountService _accounts;
    private readonly Dictionary<UnitId, ConstructionSiteSnapshot> _sites = new();
    private readonly Dictionary<UnitId, Assignment> _assignments = new();
    private long _lastAdvancedTick = -1;

    /// <summary>建立共享订单与资源账户的 Match 级施工服务。</summary>
    public ConstructionService(
        IUnitCommandUnitRepository units,
        IUnitOrderStore orders,
        IConstructionWorkerPort workers,
        IConstructionSitePort sitePort,
        IResourceAccountService accounts)
    {
        _units = units;
        _orders = orders;
        _workers = workers;
        _sitePort = sitePort;
        _accounts = accounts;
        _orders.StateChanged += OnOrderStateChanged;
    }

    /// <inheritdoc />
    public event Action<ConstructionCompleted>? Completed;

    /// <inheritdoc />
    public event Action<ConstructionTerminated>? Terminated;

    /// <inheritdoc />
    public bool Register(RegisterConstructionSite request)
    {
        if (request.SiteId.Value == Guid.Empty || request.OwnerId.Value == Guid.Empty ||
            string.IsNullOrWhiteSpace(request.DefinitionId.Value) || request.RequiredWork <= 0 ||
            request.ConstructionCost is null || request.ConstructionCost.Count == 0 ||
            request.ConstructionCost.Any(cost =>
                !Enum.IsDefined(cost.Kind) || cost.Amount < 0) ||
            _sites.ContainsKey(request.SiteId))
        {
            return false;
        }

        var site = new ConstructionSiteSnapshot(
            request.SiteId,
            request.OwnerId,
            request.DefinitionId,
            request.RequiredWork,
            0,
            request.ConstructionCost.ToArray(),
            ConstructionSiteState.Active,
            1);
        if (!_sitePort.ApplyProgress(request.SiteId, 0, request.RequiredWork))
        {
            return false;
        }
        _sites.Add(request.SiteId, site);
        return true;
    }

    /// <inheritdoc />
    public ConstructionSiteSnapshot? Find(UnitId siteId) =>
        _sites.GetValueOrDefault(siteId);

    /// <inheritdoc />
    public CommandResult Construct(CommandContext context, ConstructStructureCommand command)
    {
        if (command.WorkerIds.Count == 0)
        {
            return Rejected(context.CommandId, command.WorkerIds, CommandErrorCode.EmptyUnitSet);
        }
        if (!_sites.TryGetValue(command.SiteId, out var site))
        {
            return Rejected(
                context.CommandId, command.WorkerIds, CommandErrorCode.ConstructionSiteNotFound);
        }

        var siteError = site.OwnerId != context.IssuerPlayerId ?
            CommandErrorCode.ConstructionSiteNotOwned : site.State switch
            {
                ConstructionSiteState.Completed => CommandErrorCode.ConstructionAlreadyCompleted,
                ConstructionSiteState.Active => CommandErrorCode.None,
                _ => CommandErrorCode.ConstructionUnavailable
            };
        if (siteError != CommandErrorCode.None)
        {
            return Rejected(context.CommandId, command.WorkerIds, siteError);
        }

        var results = new List<UnitCommandResult>();
        foreach (var workerId in command.WorkerIds.Distinct().OrderBy(id => id.Value))
        {
            var validation = ValidateWorker(context, workerId);
            if (validation != CommandErrorCode.None)
            {
                results.Add(new UnitCommandResult(workerId, false, validation));
                continue;
            }

            var active = _orders.FindActive(workerId);
            if (active?.Kind == UnitOrderKind.Construct &&
                active.State == UnitOrderState.Suspended &&
                _assignments.TryGetValue(workerId, out var suspended) &&
                suspended.SiteId == command.SiteId)
            {
                var resumed = _workers.RequestConstruct(workerId, command.SiteId);
                if (!resumed.Accepted)
                {
                    results.Add(new UnitCommandResult(
                        workerId, false, CommandErrorCode.ConstructionUnavailable));
                    continue;
                }
                _orders.Transition(active.OrderId, UnitOrderState.InProgress);
                results.Add(new UnitCommandResult(
                    workerId, true, CommandErrorCode.None, active.OrderId));
                continue;
            }

            if (active is not null)
            {
                _orders.Transition(active.OrderId, UnitOrderState.Cancelled, context.CommandId);
            }
            var portResult = _workers.RequestConstruct(workerId, command.SiteId);
            if (!portResult.Accepted)
            {
                results.Add(new UnitCommandResult(
                    workerId, false, CommandErrorCode.ConstructionUnavailable));
                continue;
            }

            var order = _orders.Create(context.CommandId, workerId, UnitOrderKind.Construct);
            _assignments[workerId] = new Assignment(command.SiteId, order.OrderId, 1);
            _orders.Transition(order.OrderId, UnitOrderState.InProgress);
            results.Add(new UnitCommandResult(workerId, true, CommandErrorCode.None, order.OrderId));
        }
        return Summarize(context.CommandId, results);
    }

    /// <inheritdoc />
    public ConstructionWorkerPortResult RequestSuspend(UnitId workerId)
    {
        if (!_assignments.ContainsKey(workerId))
        {
            return ConstructionWorkerPortResult.Failure(
                ConstructionWorkerPortError.EntityUnavailable);
        }
        return _workers.RequestSuspend(workerId);
    }

    /// <inheritdoc />
    public void Advance(long simulationTick)
    {
        if (simulationTick <= _lastAdvancedTick)
        {
            return;
        }
        _lastAdvancedTick = simulationTick;

        var workBySite = new Dictionary<UnitId, int>();
        foreach (var item in _assignments.ToArray())
        {
            var active = _orders.FindActive(item.Key);
            if (active?.OrderId != item.Value.OrderId ||
                active.State != UnitOrderState.InProgress ||
                !_workers.IsContributing(item.Key, item.Value.SiteId))
            {
                continue;
            }
            workBySite[item.Value.SiteId] = checked(
                workBySite.GetValueOrDefault(item.Value.SiteId) + item.Value.BuildPowerPerTick);
        }

        foreach (var work in workBySite.OrderBy(item => item.Key.Value))
        {
            if (!_sites.TryGetValue(work.Key, out var site) ||
                site.State != ConstructionSiteState.Active)
            {
                continue;
            }
            var completed = Math.Min(site.RequiredWork, checked(site.CompletedWork + work.Value));
            if (!_sitePort.ApplyProgress(site.SiteId, completed, site.RequiredWork))
            {
                continue;
            }
            site = site with { CompletedWork = completed, Version = checked(site.Version + 1) };
            _sites[site.SiteId] = site;
            if (completed == site.RequiredWork)
            {
                Complete(site, simulationTick);
            }
        }
    }

    /// <inheritdoc />
    public ConstructionSiteCommandResult Cancel(
        CommandContext context,
        CancelConstructionCommand command)
    {
        if (!_sites.TryGetValue(command.SiteId, out var site))
        {
            return new ConstructionSiteCommandResult(
                ConstructionSiteCommandStatus.SiteNotFound, null);
        }
        if (site.OwnerId != context.IssuerPlayerId)
        {
            return new ConstructionSiteCommandResult(
                ConstructionSiteCommandStatus.SiteNotOwned, site);
        }
        if (site.State != ConstructionSiteState.Active)
        {
            return new ConstructionSiteCommandResult(
                ConstructionSiteCommandStatus.SiteNotActive, site);
        }

        var refund = _accounts.Apply(new ApplyResourceTransaction(
            new ResourceTransactionId(context.CommandId.Value),
            context.MatchId,
            context.IssuerPlayerId,
            site.ConstructionCost.Where(cost => cost.Amount > 0)
                .Select(cost => new ResourceDelta(cost.Kind, cost.Amount)).ToArray(),
            ResourceChangeReason.ConstructionRefund,
            site.SiteId.Value,
            context.SimulationTick));
        if (refund.Status is not ResourceTransactionStatus.Applied and
            not ResourceTransactionStatus.AlreadyApplied)
        {
            return new ConstructionSiteCommandResult(
                ConstructionSiteCommandStatus.ExecutionUnavailable, site);
        }
        if (!_sitePort.Cancel(site.SiteId))
        {
            return new ConstructionSiteCommandResult(
                ConstructionSiteCommandStatus.ExecutionUnavailable, site);
        }

        site = site with
        {
            State = ConstructionSiteState.Cancelled,
            Version = checked(site.Version + 1)
        };
        _sites[site.SiteId] = site;
        EndAssignments(site.SiteId, UnitOrderState.Cancelled, context.CommandId);
        Terminated?.Invoke(new ConstructionTerminated(
            site.SiteId, site.OwnerId, site.DefinitionId, site.State, context.SimulationTick));
        return new ConstructionSiteCommandResult(ConstructionSiteCommandStatus.Applied, site);
    }

    /// <inheritdoc />
    public ConstructionSiteCommandResult Destroy(UnitId siteId, long simulationTick)
    {
        if (!_sites.TryGetValue(siteId, out var site))
        {
            return new ConstructionSiteCommandResult(
                ConstructionSiteCommandStatus.SiteNotFound, null);
        }
        if (site.State != ConstructionSiteState.Active)
        {
            return new ConstructionSiteCommandResult(
                ConstructionSiteCommandStatus.SiteNotActive, site);
        }
        site = site with
        {
            State = ConstructionSiteState.Destroyed,
            Version = checked(site.Version + 1)
        };
        _sites[site.SiteId] = site;
        EndAssignments(site.SiteId, UnitOrderState.TargetLost);
        Terminated?.Invoke(new ConstructionTerminated(
            site.SiteId, site.OwnerId, site.DefinitionId, site.State, simulationTick));
        return new ConstructionSiteCommandResult(ConstructionSiteCommandStatus.Applied, site);
    }

    /// <summary>完成现场、清理全部关联分配并只发布一次完成事件。</summary>
    private void Complete(ConstructionSiteSnapshot site, long simulationTick)
    {
        if (!_sitePort.Complete(site.SiteId))
        {
            return;
        }
        site = site with
        {
            State = ConstructionSiteState.Completed,
            Version = checked(site.Version + 1)
        };
        _sites[site.SiteId] = site;
        EndAssignments(site.SiteId, UnitOrderState.Completed);
        Completed?.Invoke(new ConstructionCompleted(
            site.SiteId, site.OwnerId, site.DefinitionId, simulationTick));
    }

    /// <summary>结束目标现场的全部活动或暂停 Construct 订单。</summary>
    private void EndAssignments(
        UnitId siteId,
        UnitOrderState state,
        CommandId? replacedBy = null)
    {
        foreach (var item in _assignments.Where(item => item.Value.SiteId == siteId).ToArray())
        {
            _orders.Transition(item.Value.OrderId, state, replacedBy);
        }
    }

    /// <summary>验证 Worker 存在、归属正确且具备施工能力。</summary>
    private CommandErrorCode ValidateWorker(CommandContext context, UnitId workerId)
    {
        var worker = _units.Find(workerId);
        if (worker is null)
        {
            return CommandErrorCode.UnitNotFound;
        }
        if (worker.Value.OwnerId != context.IssuerPlayerId)
        {
            return CommandErrorCode.UnitNotOwned;
        }
        return worker.Value.CanConstruct ?
            CommandErrorCode.None : CommandErrorCode.WorkerCannotConstruct;
    }

    /// <summary>在 Construct 订单进入终态时立即删除活动索引和 Legacy 执行引用。</summary>
    private void OnOrderStateChanged(UnitOrderStateChanged change)
    {
        if (change.Current.Kind != UnitOrderKind.Construct ||
            change.Current.State is not (UnitOrderState.Completed or UnitOrderState.TargetLost or
                UnitOrderState.Cancelled or UnitOrderState.UnitLost or UnitOrderState.Unreachable) ||
            !_assignments.TryGetValue(change.Current.UnitId, out var assignment) ||
            assignment.OrderId != change.Current.OrderId)
        {
            return;
        }
        _assignments.Remove(change.Current.UnitId);
        _workers.Clear(change.Current.UnitId);
    }

    /// <summary>创建所有目标均拒绝的稳定批量结果。</summary>
    private static CommandResult Rejected(
        CommandId commandId,
        IReadOnlyList<UnitId> unitIds,
        CommandErrorCode error) => new(
            commandId,
            CommandStatus.Rejected,
            unitIds.Distinct().OrderBy(id => id.Value)
                .Select(id => new UnitCommandResult(id, false, error)).ToArray());

    /// <summary>根据逐 Worker 结果计算 Accepted、PartiallyAccepted 或 Rejected。</summary>
    private static CommandResult Summarize(
        CommandId commandId,
        IReadOnlyList<UnitCommandResult> results)
    {
        var accepted = results.Count(result => result.Accepted);
        var status = accepted == 0 ? CommandStatus.Rejected :
            accepted == results.Count ? CommandStatus.Accepted : CommandStatus.PartiallyAccepted;
        return new CommandResult(commandId, status, results);
    }

    /// <summary>保存 Worker 当前现场、订单和每 Tick 建造能力。</summary>
    private sealed record Assignment(
        UnitId SiteId,
        UnitOrderId OrderId,
        int BuildPowerPerTick);
}
