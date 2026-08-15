using AI_RTS.Application.Economy;
using AI_RTS.Application.Queries;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Economy;
using AI_RTS.Domain.Queries;
using AI_RTS.GodotAdapter.Common;
using Godot;

namespace AI_RTS.GodotAdapter.Queries;

/// <summary>把当前 Match 的 Godot 场景和权威经济账户复制为不暴露 Node 的观察快照。</summary>
public sealed class GodotWorldObservationRepository : IWorldObservationRepository
{
    private const float SightCompensation = 2.0f;
    private readonly Node _matchRoot;
    private readonly IResourceAccountService _accounts;

    /// <summary>绑定单个 Match 根节点和该 Match 唯一资源账户服务。</summary>
    public GodotWorldObservationRepository(Node matchRoot, IResourceAccountService accounts)
    {
        _matchRoot = matchRoot;
        _accounts = accounts;
    }

    /// <inheritdoc />
    public WorldObservationSnapshot Capture()
    {
        var players = NodesInMatch("players");
        var playerIds = players.ToDictionary(player => player, GodotStableIdentity.Player);
        var units = NodesInMatch("units");
        var resources = NodesInMatch("resource_units");
        var revealers = players.ToDictionary(
            player => playerIds[player],
            player => units.Where(unit => unit.GetParent() == player && CanReveal(unit)).ToArray());
        var entities = units.Select(unit => SnapshotUnit(unit, playerIds, revealers))
            .Concat(resources.Select(resource => SnapshotResource(resource, revealers)))
            .OrderBy(entity => entity.EntityId.Kind)
            .ThenBy(entity => entity.EntityId.Value)
            .ToArray();
        var economies = playerIds.Values
            .Select(playerId => _accounts.Find(playerId))
            .Where(snapshot => snapshot is not null)
            .Select(snapshot => new WorldEconomySnapshot(
                snapshot!.PlayerId,
                new ResourceAccountObservation(
                    snapshot.Balances
                        .OrderBy(item => item.Key)
                        .Select(item => new ResourceAmount(item.Key, item.Value))
                        .ToArray(),
                    snapshot.Version)))
            .ToArray();
        return new WorldObservationSnapshot(
            checked((long)Engine.GetPhysicsFrames()),
            entities,
            economies);
    }

    private WorldEntitySnapshot SnapshotUnit(
        Node unit,
        IReadOnlyDictionary<Node, PlayerId> playerIds,
        IReadOnlyDictionary<PlayerId, Node[]> revealers)
    {
        var ownerNode = unit.GetParent();
        var owner = playerIds.GetValueOrDefault(ownerNode);
        var kind = unit.HasMethod("is_constructed") ?
            BattlefieldEntityKind.Structure : BattlefieldEntityKind.Unit;
        return new WorldEntitySnapshot(
            new BattlefieldEntityId(kind, GodotStableIdentity.Unit(unit).Value),
            owner.Value == Guid.Empty ? null : owner,
            Position(unit),
            UnitType(unit),
            NullableFloat(unit.Get("hp")),
            NullableFloat(unit.Get("hp_max")),
            VisiblePlayers(unit, owner.Value == Guid.Empty ? null : owner, revealers));
    }

    private WorldEntitySnapshot SnapshotResource(
        Node resource,
        IReadOnlyDictionary<PlayerId, Node[]> revealers) =>
        new(
            new BattlefieldEntityId(
                BattlefieldEntityKind.ResourceNode,
                GodotStableIdentity.ResourceNode(resource).Value),
            null,
            Position(resource),
            ResourceType(resource),
            null,
            null,
            VisiblePlayers(resource, null, revealers));

    private static IReadOnlySet<PlayerId> VisiblePlayers(
        Node entity,
        PlayerId? owner,
        IReadOnlyDictionary<PlayerId, Node[]> revealers)
    {
        var result = new HashSet<PlayerId>();
        if (owner is not null)
        {
            result.Add(owner.Value);
        }
        var entityPosition = Position(entity);
        foreach (var item in revealers)
        {
            if (item.Value.Any(revealer => IsInsideSight(revealer, entityPosition)))
            {
                result.Add(item.Key);
            }
        }
        return result;
    }

    private static bool IsInsideSight(Node revealer, WorldPosition target)
    {
        var sight = NullableFloat(revealer.Get("sight_range"));
        if (sight is null || sight <= 0)
        {
            return false;
        }
        var origin = Position(revealer);
        var x = origin.X - target.X;
        var z = origin.Z - target.Z;
        var range = sight.Value + SightCompensation;
        return x * x + z * z <= range * range;
    }

    private static bool CanReveal(Node unit)
    {
        var sight = NullableFloat(unit.Get("sight_range"));
        if (sight is null || sight <= 0)
        {
            return false;
        }
        return !unit.HasMethod("is_constructed") || unit.Call("is_constructed").AsBool();
    }

    private Node[] NodesInMatch(string group) => _matchRoot.GetTree().GetNodesInGroup(group)
        .OfType<Node>()
        .Where(node => node == _matchRoot || _matchRoot.IsAncestorOf(node))
        .ToArray();

    private static WorldPosition Position(Node node)
    {
        var position = ((Node3D)node).GlobalPosition;
        return new WorldPosition(position.X, position.Y, position.Z);
    }

    private static string UnitType(Node unit)
    {
        var type = unit.Get("unit_type_id").AsString();
        return string.IsNullOrWhiteSpace(type) ? unit.Name.ToString().ToLowerInvariant() : type;
    }

    private static string ResourceType(Node resource)
    {
        if (resource.Get("resource_a").VariantType != Variant.Type.Nil)
        {
            return "resource_a";
        }
        if (resource.Get("resource_b").VariantType != Variant.Type.Nil)
        {
            return "resource_b";
        }
        return "resource_unknown";
    }

    private static float? NullableFloat(Variant value) => value.VariantType == Variant.Type.Nil ?
        null : value.AsSingle();
}
