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
    private readonly Dictionary<UnitId, Entry> _entries = new();

    /// <summary>注册生产建筑、定义名与队列表现节点。</summary>
    public UnitId Register(Node producer, Node queueNode, string producerDefinitionId)
    {
        var producerId = GodotStableIdentity.Unit(producer);
        _entries[producerId] = new Entry(
            new WeakReference<Node>(producer),
            new WeakReference<Node>(queueNode),
            new StructureDefinitionId(producerDefinitionId));
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
            constructed);
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
        StructureDefinitionId DefinitionId);
}
