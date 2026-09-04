using AI_RTS.Application.Units;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Economy;
using Godot;

namespace AI_RTS.GodotAdapter.Economy;

/// <summary>维护资源节点稳定身份，并把 Legacy GDScript 资源字段转换为只读快照。</summary>
public sealed class GodotResourceNodeRegistry : IResourceNodeRepository
{
    /// <summary>资源节点保存稳定 ID 时使用的 Metadata 键。</summary>
    private const string ResourceNodeIdMeta = "ai_rts_resource_node_id";

    /// <summary>使用弱引用保存运行时节点，避免注册表延长场景对象生命周期。</summary>
    private readonly Dictionary<ResourceNodeId, WeakReference<Node>> _nodes = new();

    /// <summary>注册一个资源节点并返回其当前对局稳定身份。</summary>
    public ResourceNodeId Register(Node resourceNode)
    {
        ResourceNodeId id;
        if (resourceNode.HasMeta(ResourceNodeIdMeta) &&
            Guid.TryParse(resourceNode.GetMeta(ResourceNodeIdMeta).AsString(), out var existing))
        {
            id = new ResourceNodeId(existing);
        }
        else
        {
            id = new ResourceNodeId(Guid.NewGuid());
            resourceNode.SetMeta(ResourceNodeIdMeta, id.Value.ToString("D"));
        }

        _nodes[id] = new WeakReference<Node>(resourceNode);
        return id;
    }

    /// <inheritdoc />
    public ResourceNodeSnapshot? Find(ResourceNodeId resourceNodeId)
    {
        if (!TryGetNode(resourceNodeId, out var node))
        {
            return null;
        }

        var resourceA = node.Get("resource_a");
        if (resourceA.VariantType != Variant.Type.Nil)
        {
            return new ResourceNodeSnapshot(
                resourceNodeId,
                ResourceKind.A,
                resourceA.AsInt32() > 0);
        }

        return null;
    }

    /// <summary>取得仍有效且位于 SceneTree 中的资源节点。</summary>
    public bool TryGetNode(ResourceNodeId resourceNodeId, out Node resourceNode)
    {
        resourceNode = null!;
        if (!_nodes.TryGetValue(resourceNodeId, out var reference) ||
            !reference.TryGetTarget(out var candidate))
        {
            return false;
        }
        if (!GodotObject.IsInstanceValid(candidate) || !candidate.IsInsideTree())
        {
            return false;
        }

        resourceNode = candidate;
        return true;
    }
}
