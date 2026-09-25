using AI_RTS.Application.Configuration;
using AI_RTS.Application.Production;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Construction;
using AI_RTS.Domain.Production;
using AI_RTS.GodotAdapter.Common;
using Godot;

namespace AI_RTS.GodotAdapter.Production;

/// <summary>以弱引用维护生产建筑及其 Legacy 队列表现节点。</summary>
public sealed class GodotProductionProducerRegistry : IProductionProducerRepository
{
    private readonly IGameBalanceCatalog _catalog;
    private readonly Dictionary<UnitId, Entry> _entries = new();

    /// <summary>建立使用 Match 不可变单位能力定义的生产建筑注册表。</summary>
    public GodotProductionProducerRegistry(IGameBalanceCatalog catalog)
    {
        _catalog = catalog;
    }

    /// <summary>注册生产建筑、定义名与队列表现节点。</summary>
    public UnitId Register(Node producer, Node queueNode, string producerDefinitionId)
    {
        var producerId = GodotStableIdentity.Unit(producer);
        var unitTypeId = new UnitTypeId(producerDefinitionId);
        var producerDefinition = _catalog.FindUnitType(unitTypeId)?.Producer ??
            throw new InvalidOperationException(
                $"实体类型 {producerDefinitionId} 没有 Producer 配置。");
        _entries[producerId] = new Entry(
            new WeakReference<Node>(producer),
            new WeakReference<Node>(queueNode),
            new StructureDefinitionId(producerDefinitionId),
            producerDefinition.QueueLimit);
        return producerId;
    }

    /// <inheritdoc />
    public ProductionProducerSnapshot? Find(UnitId producerId)
    {
        if (!TryGetProducer(producerId, out var producer) ||
            !_entries.TryGetValue(producerId, out var entry))
        {
            return null;
        }
        var constructed = producer.HasMethod("is_constructed") &&
            producer.Call("is_constructed").AsBool();
        return new ProductionProducerSnapshot(
            producerId,
            GodotStableIdentity.Player(producer.GetParent()),
            entry.DefinitionId,
            true,
            constructed,
            entry.QueueLimit,
            WorkPerTickOf(producer));
    }

    /// <summary>读取生产建筑的每 Tick 工作量；未配置或非法值一律回退 1.0（默认速度）。</summary>
    /// <remarks>
    /// 成长系统的「生产调度」会在单位出生时把倍率写进 Godot 属性
    /// `production_work_per_tick`；这里**实时**读取，所以改属性立刻生效。
    /// </remarks>
    private static float WorkPerTickOf(Node producer)
    {
        var value = producer.Get("production_work_per_tick");
        if (value.VariantType == Variant.Type.Nil)
        {
            return 1.0f;
        }
        var rate = value.AsSingle();
        return float.IsFinite(rate) && rate > 0.0f ? rate : 1.0f;
    }

    /// <summary>尝试取得仍位于 SceneTree 的生产建筑。</summary>
    public bool TryGetProducer(UnitId producerId, out Node producer)
    {
        producer = null!;
        return _entries.TryGetValue(producerId, out var entry) &&
            TryGet(entry.Producer, out producer);
    }

    /// <summary>尝试取得仍位于 SceneTree 的 Legacy 队列表现节点。</summary>
    public bool TryGetQueueNode(UnitId producerId, out Node queueNode)
    {
        queueNode = null!;
        return _entries.TryGetValue(producerId, out var entry) &&
            TryGet(entry.QueueNode, out queueNode);
    }

    /// <summary>解引用并验证 Godot Node。</summary>
    private static bool TryGet(WeakReference<Node> reference, out Node node)
    {
        node = null!;
        if (!reference.TryGetTarget(out var candidate) ||
            !GodotObject.IsInstanceValid(candidate) || !candidate.IsInsideTree())
        {
            return false;
        }
        node = candidate;
        return true;
    }

    /// <summary>保存生产建筑、队列表现和稳定建筑定义。</summary>
    private sealed record Entry(
        WeakReference<Node> Producer,
        WeakReference<Node> QueueNode,
        StructureDefinitionId DefinitionId,
        int QueueLimit);
}
