using AI_RTS.Application.Units;
using AI_RTS.Domain.Common;
using Godot;

namespace AI_RTS.GodotAdapter.Units;

public sealed class GodotUnitRegistry : IUnitCommandUnitRepository
{
    private const string UnitIdMeta = "ai_rts_unit_id";
    private const string PlayerIdMeta = "ai_rts_player_id";
    private readonly Dictionary<UnitId, WeakReference<Node>> _nodes = new();

    public UnitId Register(Node unit)
    {
        var id = GetOrCreateId<UnitId>(unit, UnitIdMeta, value => new UnitId(value));
        _nodes[id] = new WeakReference<Node>(unit);
        return id;
    }

    public PlayerId RegisterPlayer(Node player) =>
        GetOrCreateId<PlayerId>(player, PlayerIdMeta, value => new PlayerId(value));

    public UnitCommandSnapshot? Find(UnitId unitId)
    {
        if (!TryGetNode(unitId, out var unit))
            return null;

        var player = unit.GetParent();
        var ownerId = RegisterPlayer(player);
        var movement = unit.FindChild("Movement", false, false);
        return new UnitCommandSnapshot(unitId, ownerId, movement is not null);
    }

    public bool TryGetNode(UnitId unitId, out Node unit)
    {
        unit = null!;
        if (!_nodes.TryGetValue(unitId, out var reference) || !reference.TryGetTarget(out var candidate))
            return false;
        if (!GodotObject.IsInstanceValid(candidate) || !candidate.IsInsideTree())
            return false;
        unit = candidate;
        return true;
    }

    private static TId GetOrCreateId<TId>(Node node, string metaKey, Func<Guid, TId> factory)
    {
        if (node.HasMeta(metaKey) && Guid.TryParse(node.GetMeta(metaKey).AsString(), out var existing))
            return factory(existing);

        var value = Guid.NewGuid();
        node.SetMeta(metaKey, value.ToString("D"));
        return factory(value);
    }
}
