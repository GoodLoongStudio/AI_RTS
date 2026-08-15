using AI_RTS.Application.Production;
using AI_RTS.Domain.Production;
using AI_RTS.GodotAdapter.Common;
using Godot;

namespace AI_RTS.GodotAdapter.Production;

/// <summary>通过 Legacy 队列节点执行有界出生位置查询与单位生成。</summary>
public sealed class GodotProductionDeploymentPort(
    GodotProductionDefinitionRepository definitions,
    GodotProductionProducerRegistry producers) : IProductionDeploymentPort
{
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
        return new ProductionDeploymentResult(
            ProductionDeploymentStatus.Deployed,
            GodotStableIdentity.Unit(produced));
    }
}
