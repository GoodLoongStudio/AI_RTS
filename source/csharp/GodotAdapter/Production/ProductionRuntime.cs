using AI_RTS.Application.Commands;
using AI_RTS.Application.Production;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Production;
using AI_RTS.GodotAdapter.Common;
using AI_RTS.GodotAdapter.Configuration;
using AI_RTS.GodotAdapter.Economy;
using Godot;

namespace AI_RTS.GodotAdapter.Production;

/// <summary>在 Match 生命周期内装配权威生产服务并兼容现有 GDScript 队列和 Signal。</summary>
public partial class ProductionRuntime : Node
{
    private GodotProductionDefinitionRepository _definitions = null!;
    private GodotProductionProducerRegistry _producers = null!;
    private readonly HashSet<UnitId> _trackedProducers = new();
    private GodotProductionDeploymentPort _deployment = null!;
    private IProductionService _service = null!;
    private MatchId _matchId;

    /// <summary>单位成功部署后通知独立的出厂策略与 Rally 初始化器。</summary>
    public event Action<Node, Node>? UnitDeployed;

    /// <summary>连接统一经济账户、生产定义、建筑注册表与部署端口。</summary>
    public override void _Ready()
    {
        var economy = GetParent().GetNode<EconomyRuntime>("EconomyRuntime");
        var configuration = GetParent().GetNode<BalanceConfigRuntime>("BalanceConfigRuntime");
        _matchId = economy.MatchId;
        _definitions = new GodotProductionDefinitionRepository(
            configuration.Catalog,
            configuration.Assets);
        _producers = new GodotProductionProducerRegistry(configuration.Catalog);
        _deployment = new GodotProductionDeploymentPort(_definitions, _producers);
        _service = new ProductionService(
            _definitions,
            _producers,
            _deployment,
            economy.AccountService);
        _service.Queued += OnQueued;
        _service.Started += OnStarted;
        _service.Progressed += change => NotifyChanged(change.Item);
        _service.AwaitingDeployment += change => NotifyChanged(change.Item);
        _service.Completed += OnCompleted;
        _service.Terminated += change => NotifyRemoved(change.Item);
    }

    /// <summary>每个物理 Tick 只推进一次生产线。</summary>
    public override void _PhysicsProcess(double delta)
    {
        _service.Advance(CurrentTick());
    }

    /// <summary>由 Legacy ProductionQueue 节点注册所属建筑和稳定定义。</summary>
    public string RegisterProducer(
        Node producer,
        Node queueNode,
        string producerDefinitionId)
    {
        var producerId = _producers.Register(
            producer, queueNode, StableName(producerDefinitionId));
        if (_trackedProducers.Add(producerId))
        {
            producer.TreeExiting += () =>
                _service.LoseProducer(producerId, CurrentTick());
        }
        return producerId.Value.ToString("D");
    }

    /// <summary>提交统一生产入队命令；公开入口不允许绕过队列容量。</summary>
    public Godot.Collections.Dictionary Enqueue(
        Node producer,
        PackedScene product,
        Node issuerPlayer)
    {
        var producerId = GodotStableIdentity.Unit(producer);
        var definitionId = _definitions.Resolve(product);
        if (definitionId is null)
        {
            return ToGodot(new ProductionCommandResult(
                new CommandId(Guid.NewGuid()),
                ProductionCommandStatus.DefinitionNotFound,
                null));
        }
        return ToGodot(_service.Enqueue(
            Context(issuerPlayer),
            new EnqueueProductionCommand(producerId, definitionId.Value)));
    }

    /// <summary>由拥有者按稳定 ItemId 取消单项并全额退款。</summary>
    public Godot.Collections.Dictionary Cancel(string itemId, Node issuerPlayer)
    {
        if (!Guid.TryParse(itemId, out var value))
        {
            return ToGodot(new ProductionCommandResult(
                new CommandId(Guid.NewGuid()),
                ProductionCommandStatus.ItemNotFound,
                null));
        }
        return ToGodot(_service.Cancel(
            Context(issuerPlayer),
            new CancelProductionItemCommand(new ProductionItemId(value))));
    }

    /// <summary>取消建筑当前队列快照中的全部项目并返回逐项结果。</summary>
    public Godot.Collections.Array<Godot.Collections.Dictionary> CancelAll(
        Node producer,
        Node issuerPlayer)
    {
        var results = new Godot.Collections.Array<Godot.Collections.Dictionary>();
        foreach (var result in _service.CancelAll(
            Context(issuerPlayer), GodotStableIdentity.Unit(producer)))
        {
            results.Add(ToGodot(result));
        }
        return results;
    }

    /// <summary>查询建筑当前非终态队列，供迁移期诊断与测试读取。</summary>
    public Godot.Collections.Array<Godot.Collections.Dictionary> GetQueue(Node producer)
    {
        var result = new Godot.Collections.Array<Godot.Collections.Dictionary>();
        foreach (var item in _service.GetQueue(GodotStableIdentity.Unit(producer)))
        {
            result.Add(ToGodot(item));
        }
        return result;
    }

    /// <summary>把入队事件同步到对应 Legacy 队列视图。</summary>
    private void OnQueued(ProductionQueued change)
    {
        if (_producers.TryGetQueueNode(change.Item.ProducerId, out var queue) &&
            _definitions.FindScene(change.Item.DefinitionId) is { } scene)
        {
            queue.Call("on_authoritative_item_queued", ToGodot(change.Item), scene);
        }
    }

    /// <summary>项目真正取得生产线后刷新 HUD，并兼容发布 Legacy 开始事件。</summary>
    private void OnStarted(ProductionStarted change)
    {
        if (_producers.TryGetQueueNode(change.Item.ProducerId, out var queue))
        {
            queue.Call("on_authoritative_item_started", ToGodot(change.Item));
        }
    }

    /// <summary>把进度或状态变化同步到对应 Legacy 队列视图。</summary>
    private void NotifyChanged(ProductionItemSnapshot item)
    {
        if (_producers.TryGetQueueNode(item.ProducerId, out var queue))
        {
            queue.Call("on_authoritative_item_changed", ToGodot(item));
        }
    }

    /// <summary>完成部署后移除 Legacy 队列视图，并携带新单位 ID。</summary>
    private void OnCompleted(UnitProductionCompleted change)
    {
        if (_deployment.TryGetProducedUnit(change.ProducedUnitId, out var produced) &&
            _producers.TryGetProducer(change.Item.ProducerId, out var producer))
        {
            UnitDeployed?.Invoke(produced, producer);
        }
        NotifyRemoved(change.Item);
    }

    /// <summary>把终态项目从 Legacy 队列视图中删除。</summary>
    private void NotifyRemoved(ProductionItemSnapshot item)
    {
        if (_producers.TryGetQueueNode(item.ProducerId, out var queue))
        {
            queue.Call("on_authoritative_item_removed", ToGodot(item));
        }
    }

    /// <summary>创建统一经济 Match 身份下的生产命令上下文。</summary>
    private CommandContext Context(Node issuerPlayer) => new(
        new CommandId(Guid.NewGuid()),
        _matchId,
        GodotStableIdentity.Player(issuerPlayer),
        CurrentTick());

    /// <summary>把稳定生产结果转换为 GDScript 可读取字段。</summary>
    private static Godot.Collections.Dictionary ToGodot(ProductionCommandResult result)
    {
        var dictionary = new Godot.Collections.Dictionary
        {
            ["accepted"] = result.Status == ProductionCommandStatus.Accepted,
            ["status"] = result.Status.ToString(),
            ["command_id"] = result.CommandId.Value.ToString("D")
        };
        if (result.Item is not null)
        {
            dictionary["item"] = ToGodot(result.Item);
        }
        return dictionary;
    }

    /// <summary>把生产项目快照转换为 HUD 和测试使用的稳定字段。</summary>
    private static Godot.Collections.Dictionary ToGodot(ProductionItemSnapshot item) => new()
    {
        ["item_id"] = item.ItemId.Value.ToString("D"),
        ["producer_id"] = item.ProducerId.Value.ToString("D"),
        ["definition_id"] = item.DefinitionId.Value,
        ["required_work"] = item.RequiredWork,
        ["completed_work"] = item.CompletedWork,
        ["state"] = item.State.ToString(),
        ["version"] = item.Version,
        ["produced_unit_id"] = item.ProducedUnitId?.Value.ToString("D") ?? string.Empty
    };

    /// <summary>把脚本路径或自由大小写名称规范为 snake_case 稳定建筑定义。</summary>
    private static string StableName(string source)
    {
        var fileName = source.Contains('/') ? source[(source.LastIndexOf('/') + 1)..] : source;
        var withoutExtension = fileName.Contains('.') ? fileName[..fileName.LastIndexOf('.')] : fileName;
        return string.Concat(withoutExtension.Select((character, index) =>
            char.IsUpper(character) && index > 0 ?
                $"_{char.ToLowerInvariant(character)}" :
                char.ToLowerInvariant(character).ToString()));
    }

    private static long CurrentTick() => checked((long)Engine.GetPhysicsFrames());
}
