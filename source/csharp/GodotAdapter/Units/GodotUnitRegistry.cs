using AI_RTS.Application.Units;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Combat;
using Godot;

namespace AI_RTS.GodotAdapter.Units;

/// <summary>维护稳定 UnitId、PlayerId 与 Godot 运行时 Node 之间的临时映射。</summary>
public sealed class GodotUnitRegistry : IUnitCommandUnitRepository
{
    /// <summary>单位节点保存稳定 ID 时使用的 Metadata 键。</summary>
    private const string UnitIdMeta = "ai_rts_unit_id";

    /// <summary>玩家节点保存稳定 ID 时使用的 Metadata 键。</summary>
    private const string PlayerIdMeta = "ai_rts_player_id";

    /// <summary>使用弱引用保存单位节点，避免注册表延长 Node 生命周期。</summary>
    private readonly Dictionary<UnitId, WeakReference<Node>> _nodes = new();

    /// <summary>注册单位节点，并返回其进程内稳定 UnitId。</summary>
    public UnitId Register(Node unit)
    {
        var id = GetOrCreateId<UnitId>(unit, UnitIdMeta, value => new UnitId(value));
        _nodes[id] = new WeakReference<Node>(unit);
        return id;
    }

    /// <summary>注册玩家节点，并返回其进程内稳定 PlayerId。</summary>
    public PlayerId RegisterPlayer(Node player) =>
        GetOrCreateId<PlayerId>(player, PlayerIdMeta, value => new PlayerId(value));

    /// <inheritdoc />
    public UnitCommandSnapshot? Find(UnitId unitId)
    {
        if (!TryGetNode(unitId, out var unit))
        {
            return null;
        }

        var player = unit.GetParent();
        var ownerId = RegisterPlayer(player);
        var movement = unit.FindChild("Movement", false, false);
        var attackDomains = ReadAttackDomains(unit);
        var hp = unit.Get("hp");
        return new UnitCommandSnapshot(
            unitId,
            ownerId,
            movement is not null,
            unit.Get("attack_range").VariantType != Variant.Type.Nil,
            ReadDomain(unit.Get("movement_domain").AsInt32()),
            attackDomains,
            hp.VariantType != Variant.Type.Nil,
            unit.Get("can_reverse").AsBool(),
            unit.Get("can_force_fire_ground").AsBool(),
            unit.HasMethod("request_legacy_gather"));
    }

    /// <summary>尝试取得仍有效且位于 SceneTree 中的单位节点。</summary>
    public bool TryGetNode(UnitId unitId, out Node unit)
    {
        unit = null!;
        if (!_nodes.TryGetValue(unitId, out var reference) || !reference.TryGetTarget(out var candidate))
        {
            return false;
        }
        if (!GodotObject.IsInstanceValid(candidate) || !candidate.IsInsideTree())
        {
            return false;
        }
        unit = candidate;
        return true;
    }

    /// <summary>读取节点已有 Metadata ID；不存在时创建并保存新 Guid。</summary>
    private static TId GetOrCreateId<TId>(Node node, string metaKey, Func<Guid, TId> factory)
    {
        if (node.HasMeta(metaKey) && Guid.TryParse(node.GetMeta(metaKey).AsString(), out var existing))
        {
            return factory(existing);
        }

        var value = Guid.NewGuid();
        node.SetMeta(metaKey, value.ToString("D"));
        return factory(value);
    }

    /// <summary>读取 Legacy attack_domains 数组并转换为不依赖 Godot 常量的领域集合。</summary>
    private static IReadOnlySet<CombatDomain> ReadAttackDomains(Node unit)
    {
        var result = new HashSet<CombatDomain>();
        foreach (var value in unit.Get("attack_domains").AsGodotArray())
        {
            result.Add(ReadDomain(value.AsInt32()));
        }
        return result;
    }

    /// <summary>把现有 Navigation.Domain 的整数约定映射到 C# CombatDomain。</summary>
    private static CombatDomain ReadDomain(int value) =>
        value == 0 ? CombatDomain.Air : CombatDomain.Terrain;
}
