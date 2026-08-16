using AI_RTS.Application.Production;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Production;
using AI_RTS.GodotAdapter.Common;
using Godot;

namespace AI_RTS.GodotAdapter.Production;

/// <summary>通过 Legacy 队列节点执行有界出生位置查询与单位生成。</summary>
public sealed class GodotProductionDeploymentPort(
    GodotProductionDefinitionRepository definitions,
    GodotProductionProducerRegistry producers) : IProductionDeploymentPort
{
    private readonly Dictionary<UnitId, WeakReference<Node>> _producedUnits = new();

    /// <inheritdoc />
    public ProductionDeploymentResult TryDeploy(ProductionItemSnapshot item)
    {
        var scene = definitions.FindScene(item.DefinitionId);
        if (scene is null || !producers.TryGetQueueNode(item.ProducerId, out var queueNode) ||
            !queueNode.HasMethod("try_deploy_authoritative"))
        {
            return new ProductionDeploymentResult(ProductionDeploymentStatus.Unavailable);
        }
        var produced = queueNode.Call("try_deploy_authoritative", scene).AsGodotObject() as Node;
        if (produced is null || !GodotObject.IsInstanceValid(produced))
        {
            return new ProductionDeploymentResult(ProductionDeploymentStatus.Blocked);
        }
        var producedUnitId = GodotStableIdentity.Unit(produced);
        _producedUnits[producedUnitId] = new WeakReference<Node>(produced);
        return new ProductionDeploymentResult(
            ProductionDeploymentStatus.Deployed,
            producedUnitId);
    }

    /// <summary>解析刚完成部署的单位，供事件驱动的出厂初始化使用。</summary>
    public bool TryGetProducedUnit(UnitId unitId, out Node unit)
    {
        unit = null!;
        if (!_producedUnits.TryGetValue(unitId, out var reference) ||
            !reference.TryGetTarget(out var candidate) ||
            !GodotObject.IsInstanceValid(candidate) || !candidate.IsInsideTree())
        {
            return false;
        }
        unit = candidate;
        return true;
    }
}
