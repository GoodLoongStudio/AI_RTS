using AI_RTS.Application.Commands;
using AI_RTS.Application.Economy;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Economy;
using AI_RTS.Domain.Production;

namespace AI_RTS.Application.Production;

/// <summary>以稳定项目和整数工作量统一管理生产、退款、建筑失效与部署。</summary>
public sealed class ProductionService : IProductionService
{
    private readonly IProductionDefinitionRepository _definitions;
    private readonly IProductionProducerRepository _producers;
    private readonly IProductionDeploymentPort _deployment;
    private readonly IResourceAccountService _accounts;
    private readonly Dictionary<ProductionItemId, ItemRuntime> _items = new();
    private readonly Dictionary<UnitId, List<ProductionItemId>> _queues = new();
    private long _lastAdvancedTick = -1;

    /// <summary>建立使用统一定义、生产建筑、部署和资源账户端口的 Match 级服务。</summary>
    public ProductionService(
        IProductionDefinitionRepository definitions,
        IProductionProducerRepository producers,
        IProductionDeploymentPort deployment,
        IResourceAccountService accounts)
    {
        _definitions = definitions;
        _producers = producers;
        _deployment = deployment;
        _accounts = accounts;
    }

    /// <inheritdoc />
    public event Action<ProductionQueued>? Queued;

    /// <inheritdoc />
    public event Action<ProductionStarted>? Started;

    /// <inheritdoc />
    public event Action<ProductionProgressed>? Progressed;

    /// <inheritdoc />
    public event Action<ProductionAwaitingDeployment>? AwaitingDeployment;

    /// <inheritdoc />
    public event Action<UnitProductionCompleted>? Completed;

    /// <inheritdoc />
    public event Action<ProductionTerminated>? Terminated;

    /// <inheritdoc />
    public ProductionCommandResult Enqueue(
        CommandContext context,
        EnqueueProductionCommand command)
    {
        var producer = _producers.Find(command.ProducerId);
        var validation = ValidateProducer(context, producer);
        if (validation != ProductionCommandStatus.Accepted)
        {
            return Result(context, validation);
        }
        var definition = _definitions.Find(command.DefinitionId);
        if (!ValidDefinition(definition))
        {
            return Result(context, ProductionCommandStatus.DefinitionNotFound);
        }
        if (!definition!.AllowedProducerDefinitions.Contains(producer!.DefinitionId))
        {
            return Result(context, ProductionCommandStatus.ProductNotAllowed);
        }

        var queue = Queue(command.ProducerId);
        if (queue.Count >= producer.QueueLimit)
        {
            return Result(context, ProductionCommandStatus.QueueFull);
        }

        var itemId = new ProductionItemId(Guid.NewGuid());
        if (definition.Cost.Count != 0)
        {
            var payment = _accounts.Apply(new ApplyResourceTransaction(
                new ResourceTransactionId(itemId.Value),
                context.MatchId,
                context.IssuerPlayerId,
                definition.Cost.Select(cost =>
                    new ResourceDelta(cost.Kind, -cost.Amount)).ToArray(),
                ResourceChangeReason.ProductionCost,
                itemId.Value,
                context.SimulationTick));
            if (payment.Status == ResourceTransactionStatus.InsufficientResources)
            {
                return Result(context, ProductionCommandStatus.InsufficientResources);
            }
            if (payment.Status != ResourceTransactionStatus.Applied)
            {
                return Result(context, ProductionCommandStatus.ExecutionUnavailable);
            }
        }

        var snapshot = new ProductionItemSnapshot(
            itemId,
            command.ProducerId,
            context.IssuerPlayerId,
            command.DefinitionId,
            definition.RequiredWork,
            0,
            definition.Cost.ToArray(),
            ProductionItemState.Queued,
            1);
        _items.Add(itemId, new ItemRuntime(snapshot, new ResourceTransactionId(Guid.NewGuid())));
        queue.Add(itemId);
        Queued?.Invoke(new ProductionQueued(snapshot, context.SimulationTick));
        if (queue.Count == 1)
        {
            snapshot = SetState(snapshot, ProductionItemState.Producing);
            Started?.Invoke(new ProductionStarted(snapshot, context.SimulationTick));
        }
        return Result(context, ProductionCommandStatus.Accepted, snapshot);
    }

    /// <inheritdoc />
    public ProductionCommandResult Cancel(
        CommandContext context,
        CancelProductionItemCommand command)
    {
        if (!_items.TryGetValue(command.ItemId, out var runtime))
        {
            return Result(context, ProductionCommandStatus.ItemNotFound);
        }
        var item = runtime.Snapshot;
        if (item.OwnerId != context.IssuerPlayerId)
        {
            return Result(context, ProductionCommandStatus.ProducerNotOwned, item);
        }
        if (IsTerminal(item.State))
        {
            return Result(context, ProductionCommandStatus.ItemNotActive, item);
        }

        if (item.PaidCost.Count != 0)
        {
            var refund = _accounts.Apply(new ApplyResourceTransaction(
                runtime.RefundTransactionId,
                context.MatchId,
                context.IssuerPlayerId,
                item.PaidCost.Select(cost =>
                    new ResourceDelta(cost.Kind, cost.Amount)).ToArray(),
                ResourceChangeReason.ProductionRefund,
                item.ItemId.Value,
                context.SimulationTick));
            if (refund.Status is not ResourceTransactionStatus.Applied and
                not ResourceTransactionStatus.AlreadyApplied)
            {
                return Result(context, ProductionCommandStatus.ExecutionUnavailable, item);
            }
        }

        var wasFront = RemoveFromQueue(item.ProducerId, item.ItemId);
        item = SetState(item, ProductionItemState.Cancelled);
        Terminated?.Invoke(new ProductionTerminated(item, context.SimulationTick));
        if (wasFront)
        {
            PromoteFront(item.ProducerId, context.SimulationTick);
        }
        return Result(context, ProductionCommandStatus.Accepted, item);
    }

    /// <inheritdoc />
    public IReadOnlyList<ProductionCommandResult> CancelAll(
        CommandContext context,
        UnitId producerId)
    {
        var producer = _producers.Find(producerId);
        var validation = ValidateProducer(context, producer, requireConstructed: false);
        if (validation != ProductionCommandStatus.Accepted)
        {
            return [Result(context, validation)];
        }
        return GetQueue(producerId)
            .Select(item => Cancel(context, new CancelProductionItemCommand(item.ItemId)))
            .ToArray();
    }

    /// <inheritdoc />
    public void LoseProducer(UnitId producerId, long simulationTick)
    {
        if (!_queues.Remove(producerId, out var queue))
        {
            return;
        }
        foreach (var itemId in queue)
        {
            var item = _items[itemId].Snapshot;
            if (IsTerminal(item.State))
            {
                continue;
            }
            item = SetState(item, ProductionItemState.ProducerLost);
            Terminated?.Invoke(new ProductionTerminated(item, simulationTick));
        }
    }

    /// <inheritdoc />
    public void Advance(long simulationTick)
    {
        if (simulationTick <= _lastAdvancedTick)
        {
            return;
        }
        _lastAdvancedTick = simulationTick;

        foreach (var producerId in _queues.Keys.OrderBy(id => id.Value).ToArray())
        {
            if (!_queues.TryGetValue(producerId, out var queue) || queue.Count == 0)
            {
                continue;
            }
            var item = _items[queue[0]].Snapshot;
            if (item.State == ProductionItemState.Producing)
            {
                var completedWork = Math.Min(
                    item.RequiredWork, checked(item.CompletedWork + 1));
                item = Update(item with
                {
                    CompletedWork = completedWork,
                    Version = checked(item.Version + 1)
                });
                Progressed?.Invoke(new ProductionProgressed(item, simulationTick));
                if (completedWork == item.RequiredWork)
                {
                    item = SetState(item, ProductionItemState.AwaitingDeployment);
                    AwaitingDeployment?.Invoke(new ProductionAwaitingDeployment(
                        item, simulationTick));
                }
            }
            if (item.State == ProductionItemState.AwaitingDeployment)
            {
                TryComplete(item, simulationTick);
            }
        }
    }

    /// <inheritdoc />
    public ProductionItemSnapshot? Find(ProductionItemId itemId) =>
        _items.TryGetValue(itemId, out var runtime) ? runtime.Snapshot : null;

    /// <inheritdoc />
    public IReadOnlyList<ProductionItemSnapshot> GetQueue(UnitId producerId)
    {
        return _queues.TryGetValue(producerId, out var queue) ?
            queue.Select(itemId => _items[itemId].Snapshot).ToArray() :
            Array.Empty<ProductionItemSnapshot>();
    }

    /// <summary>尝试部署队首；受阻时保留状态，成功时只完成一次并启动下一项。</summary>
    private void TryComplete(ProductionItemSnapshot item, long simulationTick)
    {
        var deployment = _deployment.TryDeploy(item);
        if (deployment.Status != ProductionDeploymentStatus.Deployed ||
            deployment.ProducedUnitId is not { } producedUnitId)
        {
            return;
        }
        item = Update(item with
        {
            State = ProductionItemState.Completed,
            ProducedUnitId = producedUnitId,
            Version = checked(item.Version + 1)
        });
        RemoveFromQueue(item.ProducerId, item.ItemId);
        Completed?.Invoke(new UnitProductionCompleted(item, producedUnitId, simulationTick));
        PromoteFront(item.ProducerId, simulationTick);
    }

    /// <summary>把新的队首从 Queued 转换为 Producing，但不在同一 Tick 额外推进。</summary>
    private void PromoteFront(UnitId producerId, long simulationTick)
    {
        if (!_queues.TryGetValue(producerId, out var queue) || queue.Count == 0)
        {
            return;
        }
        var item = _items[queue[0]].Snapshot;
        if (item.State != ProductionItemState.Queued)
        {
            return;
        }
        item = SetState(item, ProductionItemState.Producing);
        Started?.Invoke(new ProductionStarted(item, simulationTick));
    }

    /// <summary>移除项目并返回它此前是否位于队首。</summary>
    private bool RemoveFromQueue(UnitId producerId, ProductionItemId itemId)
    {
        if (!_queues.TryGetValue(producerId, out var queue))
        {
            return false;
        }
        var wasFront = queue.Count > 0 && queue[0] == itemId;
        queue.Remove(itemId);
        if (queue.Count == 0)
        {
            _queues.Remove(producerId);
        }
        return wasFront;
    }

    /// <summary>更新项目快照并保留退款交易身份。</summary>
    private ProductionItemSnapshot Update(ProductionItemSnapshot snapshot)
    {
        var runtime = _items[snapshot.ItemId];
        _items[snapshot.ItemId] = runtime with { Snapshot = snapshot };
        return snapshot;
    }

    /// <summary>转换项目状态并增加版本。</summary>
    private ProductionItemSnapshot SetState(
        ProductionItemSnapshot snapshot,
        ProductionItemState state) => Update(snapshot with
        {
            State = state,
            Version = checked(snapshot.Version + 1)
        });

    /// <summary>返回或创建指定生产建筑的顺序队列。</summary>
    private List<ProductionItemId> Queue(UnitId producerId)
    {
        if (!_queues.TryGetValue(producerId, out var queue))
        {
            queue = new List<ProductionItemId>();
            _queues.Add(producerId, queue);
        }
        return queue;
    }

    /// <summary>验证产品定义数值、成本和生产资格集合。</summary>
    private static bool ValidDefinition(ProductionDefinition? definition)
    {
        return definition is not null &&
            !string.IsNullOrWhiteSpace(definition.DefinitionId.Value) &&
            definition.RequiredWork > 0 &&
            definition.Cost.All(cost =>
                Enum.IsDefined(cost.Kind) && cost.Amount > 0) &&
            definition.Cost.Select(cost => cost.Kind).Distinct().Count() == definition.Cost.Count &&
            definition.AllowedProducerDefinitions.Count > 0;
    }

    /// <summary>验证生产建筑存在、存活、归属正确并已完成施工。</summary>
    private static ProductionCommandStatus ValidateProducer(
        CommandContext context,
        ProductionProducerSnapshot? producer,
        bool requireConstructed = true)
    {
        if (producer is null || !producer.IsAlive)
        {
            return ProductionCommandStatus.ProducerNotFound;
        }
        if (producer.OwnerId != context.IssuerPlayerId)
        {
            return ProductionCommandStatus.ProducerNotOwned;
        }
        if (producer.QueueLimit <= 0)
        {
            return ProductionCommandStatus.ExecutionUnavailable;
        }
        return requireConstructed && !producer.IsConstructed ?
            ProductionCommandStatus.ProducerNotConstructed : ProductionCommandStatus.Accepted;
    }

    /// <summary>判断项目是否已经不可再次取消或推进。</summary>
    private static bool IsTerminal(ProductionItemState state) => state is
        ProductionItemState.Completed or ProductionItemState.Cancelled or
        ProductionItemState.ProducerLost;

    /// <summary>创建稳定生产命令结果。</summary>
    private static ProductionCommandResult Result(
        CommandContext context,
        ProductionCommandStatus status,
        ProductionItemSnapshot? item = null) => new(context.CommandId, status, item);

    /// <summary>保存项目快照及预先生成的幂等退款交易 ID。</summary>
    private sealed record ItemRuntime(
        ProductionItemSnapshot Snapshot,
        ResourceTransactionId RefundTransactionId);
}
