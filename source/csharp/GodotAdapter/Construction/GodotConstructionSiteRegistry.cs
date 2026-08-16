using AI_RTS.Application.Construction;
using AI_RTS.Domain.Common;
using AI_RTS.GodotAdapter.Common;
using Godot;

namespace AI_RTS.GodotAdapter.Construction;

/// <summary>以弱引用维护施工现场节点，并把权威整数进度映射到 Legacy 建筑表现。</summary>
public sealed class GodotConstructionSiteRegistry : IConstructionSitePort
{
    private readonly Dictionary<UnitId, WeakReference<Node>> _sites = new();

    /// <summary>注册施工现场并返回其 Match 内稳定 ID。</summary>
    public UnitId Register(Node site)
    {
        var id = GodotStableIdentity.Unit(site);
        _sites[id] = new WeakReference<Node>(site);
        return id;
    }

    /// <summary>尝试取得仍然有效且位于 SceneTree 中的现场节点。</summary>
    public bool TryGetNode(UnitId siteId, out Node site)
    {
        site = null!;
        if (!_sites.TryGetValue(siteId, out var reference) ||
            !reference.TryGetTarget(out var candidate) ||
            !GodotObject.IsInstanceValid(candidate) || !candidate.IsInsideTree())
        {
            return false;
        }
        site = candidate;
        return true;
    }

    /// <inheritdoc />
    public bool ApplyProgress(UnitId siteId, int completedWork, int requiredWork) =>
        CallBoolean(siteId, "apply_authoritative_construction_work", completedWork, requiredWork);

    /// <inheritdoc />
    public bool Complete(UnitId siteId) =>
        CallBoolean(siteId, "complete_authoritative_construction");

    /// <inheritdoc />
    public bool Cancel(UnitId siteId) =>
        CallBoolean(siteId, "cancel_authoritative_construction");

    /// <summary>调用现场的迁移桥并统一解释布尔返回值。</summary>
    private bool CallBoolean(UnitId siteId, StringName method, params Variant[] arguments)
    {
        if (!TryGetNode(siteId, out var site) || !site.HasMethod(method))
        {
            return false;
        }
        return site.Call(method, arguments).AsBool();
    }
}
