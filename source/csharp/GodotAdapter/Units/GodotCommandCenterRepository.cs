using AI_RTS.Application.Units;
using AI_RTS.Domain.Common;
using AI_RTS.GodotAdapter.Common;
using Godot;

namespace AI_RTS.GodotAdapter.Units;

/// <summary>
/// 从当前 Match 的权威 SceneTree 查询己方已完成 CommandCenter。
/// 施工中的蓝图、敌方基地和脱离 Match 的节点都不会进入候选集。
/// </summary>
public sealed class GodotCommandCenterRepository(
    Node match,
    GodotUnitRegistry units) : ICommandCenterRepository
{
    private const string CommandCenterTypeId = "command_center";

    /// <inheritdoc />
    public UnitCommandSnapshot? FindNearestCompletedCommandCenter(
        PlayerId owner,
        WorldPosition origin)
    {
        UnitCommandSnapshot? nearest = null;
        var nearestDistanceSquared = float.PositiveInfinity;
        foreach (var candidate in EnumerateCompletedCommandCenters(owner))
        {
            var dx = candidate.Position.X - origin.X;
            var dz = candidate.Position.Z - origin.Z;
            var distanceSquared = dx * dx + dz * dz;
            if (distanceSquared >= nearestDistanceSquared)
            {
                continue;
            }

            nearestDistanceSquared = distanceSquared;
            nearest = candidate;
        }
        return nearest;
    }

    /// <summary>为表现 Action 返回同一套权威筛选结果中的最近基地节点。</summary>
    public Node? FindNearestCompletedCommandCenterNode(Node unitNode)
    {
        if (unitNode.GetParent() is not Node ownerNode)
        {
            return null;
        }

        var owner = GodotStableIdentity.Player(ownerNode);
        var origin = unitNode is Node3D spatial ? spatial.GlobalPosition : Vector3.Zero;
        Node? nearestNode = null;
        var nearestDistanceSquared = float.PositiveInfinity;
        foreach (var candidate in EnumerateCompletedCommandCenterNodes(owner))
        {
            if (candidate is not Node3D spatialCandidate)
            {
                continue;
            }

            var offset = spatialCandidate.GlobalPosition - origin;
            var distanceSquared = offset.X * offset.X + offset.Z * offset.Z;
            if (distanceSquared >= nearestDistanceSquared)
            {
                continue;
            }

            nearestDistanceSquared = distanceSquared;
            nearestNode = candidate;
        }
        return nearestNode;
    }

    private IEnumerable<UnitCommandSnapshot> EnumerateCompletedCommandCenters(PlayerId owner)
    {
        foreach (var node in EnumerateCompletedCommandCenterNodes(owner))
        {
            var id = units.Register(node);
            if (units.Find(id) is { } snapshot && snapshot.IsAlive)
            {
                yield return snapshot;
            }
        }
    }

    private IEnumerable<Node> EnumerateCompletedCommandCenterNodes(PlayerId owner)
    {
        foreach (var candidate in match.GetTree().GetNodesInGroup("units").OfType<Node>())
        {
            if (!match.IsAncestorOf(candidate) || candidate.GetParent() is not Node ownerNode)
            {
                continue;
            }
            if (GodotStableIdentity.Player(ownerNode) != owner)
            {
                continue;
            }
            if (candidate.Get("unit_type_id").AsString() != CommandCenterTypeId)
            {
                continue;
            }
            if (!candidate.HasMethod("is_constructed") ||
                !candidate.Call("is_constructed").AsBool())
            {
                continue;
            }
            var hp = candidate.Get("hp");
            if (hp.VariantType != Variant.Type.Nil && hp.AsSingle() <= 0.0f)
            {
                continue;
            }
            if (candidate is Node3D)
            {
                yield return candidate;
            }
        }
    }
}
