using AI_RTS.Application.Rally;
using AI_RTS.Domain.Common;
using AI_RTS.GodotAdapter.Common;
using AI_RTS.GodotAdapter.Composition;
using Godot;

namespace AI_RTS.GodotAdapter.Rally;

/// <summary>把 Godot 生产者、目标节点和地图尺寸适配为纯 C# Rally 查询端口。</summary>
public sealed class GodotRallyRepository(Node match, CommandRuntime commands) :
    IRallyProducerRepository,
    IRallyTargetRepository,
    IRallyPositionValidator
{
    private readonly Dictionary<UnitId, ProducerEntry> _producers = new();

    /// <summary>注册声明 RallyPoint 视图的生产者。</summary>
    public UnitId RegisterProducer(Node producer, Node view)
    {
        var producerId = commands.RegisterRuntimeUnit(producer);
        _producers[producerId] = new ProducerEntry(
            new WeakReference<Node>(producer), new WeakReference<Node>(view));
        return producerId;
    }

    /// <summary>从已完成场景装配的生产者解析其 RallyPoint 视图并确保注册。</summary>
    public UnitId RegisterProducerFromExisting(Node producer)
    {
        var producerId = commands.RegisterRuntimeUnit(producer);
        if (_producers.ContainsKey(producerId))
        {
            return producerId;
        }
        var view = producer.FindChild("RallyPoint", false, false);
        if (view is null)
        {
            return producerId;
        }
        return RegisterProducer(producer, view);
    }

    /// <summary>注册可被同玩家集结命令引用的单位或建筑。</summary>
    public UnitId RegisterUnitTarget(Node target) => commands.RegisterRuntimeUnit(target);

    /// <summary>注册可被集结命令引用的资源节点。</summary>
    public ResourceNodeId RegisterResourceTarget(Node target) =>
        commands.RegisterRuntimeResource(target);

    /// <inheritdoc />
    public RallyProducerSnapshot? Find(UnitId producerId)
    {
        if (!TryGetProducer(producerId, out var producer) ||
            commands.FindRuntimeUnit(producerId) is not { } unit)
        {
            return null;
        }
        var constructed = producer.HasMethod("is_constructed") &&
            producer.Call("is_constructed").AsBool();
        return new RallyProducerSnapshot(
            producerId, unit.OwnerId, true, constructed, true);
    }

    /// <inheritdoc />
    public RallyUnitTargetSnapshot? FindUnit(UnitId unitId, PlayerId observerId)
    {
        if (commands.FindRuntimeUnit(unitId) is not { } unit)
        {
            return null;
        }
        return new RallyUnitTargetSnapshot(
            unitId,
            unit.OwnerId,
            true,
            unit.OwnerId == observerId);
    }

    /// <inheritdoc />
    public RallyResourceTargetSnapshot? FindResource(
        ResourceNodeId resourceNodeId,
        PlayerId observerId)
    {
        var resource = commands.FindRuntimeResource(resourceNodeId);
        return resource is null ? null : new RallyResourceTargetSnapshot(
            resourceNodeId, resource.Value.IsAvailable, true);
    }

    /// <inheritdoc />
    public bool IsInsideMap(WorldPosition position)
    {
        var map = match.GetNode<Node>("Map");
        var size = map.Get("size").AsVector2();
        return position.X >= 0 && position.Z >= 0 &&
            position.X <= size.X && position.Z <= size.Y;
    }

    /// <summary>解析仍处于 SceneTree 的生产者。</summary>
    public bool TryGetProducer(UnitId producerId, out Node producer)
    {
        producer = null!;
        return _producers.TryGetValue(producerId, out var entry) &&
            TryGet(entry.Producer, out producer);
    }

    /// <summary>解析生产者对应的 RallyPoint 视图节点。</summary>
    public bool TryGetView(UnitId producerId, out Node view)
    {
        view = null!;
        return _producers.TryGetValue(producerId, out var entry) &&
            TryGet(entry.View, out view);
    }

    /// <summary>解析单位或建筑目标。</summary>
    public bool TryGetUnit(UnitId unitId, out Node unit) =>
        commands.TryGetRuntimeUnit(unitId, out unit);

    /// <summary>解析资源目标。</summary>
    public bool TryGetResource(ResourceNodeId resourceNodeId, out Node resource) =>
        commands.TryGetRuntimeResource(resourceNodeId, out resource);

    /// <summary>验证弱引用节点仍有效且位于当前 SceneTree。</summary>
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

    /// <summary>保存生产者和纯表现 RallyPoint 节点的弱引用。</summary>
    private sealed record ProducerEntry(
        WeakReference<Node> Producer,
        WeakReference<Node> View);
}
