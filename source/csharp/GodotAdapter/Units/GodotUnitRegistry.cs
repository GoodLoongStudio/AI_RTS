using AI_RTS.Application.Units;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Combat;
using AI_RTS.GodotAdapter.Common;
using Godot;

namespace AI_RTS.GodotAdapter.Units;

/// <summary>维护稳定 UnitId、PlayerId 与 Godot 运行时 Node 之间的临时映射。</summary>
public sealed class GodotUnitRegistry : IUnitCommandUnitRepository
{
    /// <summary>使用弱引用保存单位节点，避免注册表延长 Node 生命周期。</summary>
    private readonly Dictionary<UnitId, WeakReference<Node>> _nodes = new();

    /// <summary>注册单位节点，并返回其进程内稳定 UnitId。</summary>
    public UnitId Register(Node unit)
    {
        var id = GodotStableIdentity.Unit(unit);
        _nodes[id] = new WeakReference<Node>(unit);
        return id;
    }

    /// <summary>注册玩家节点，并返回其进程内稳定 PlayerId。</summary>
    public PlayerId RegisterPlayer(Node player) => GodotStableIdentity.Player(player);

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
            unit.HasMethod("request_legacy_gather"),
            unit.HasMethod("request_legacy_construct") &&
                unit.Get("construction_work_per_tick").AsInt32() > 0,
            unit.Get("construction_work_per_tick").AsInt32());
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

    /// <summary>在指定 Match 的单位组中按稳定 ID 查找并注册仍有效的实体。</summary>
    public bool TryResolveInMatch(UnitId unitId, Node matchRoot, out Node unit)
    {
        if (TryGetNode(unitId, out unit))
        {
            return true;
        }
        foreach (var candidate in matchRoot.GetTree().GetNodesInGroup("units").OfType<Node>())
        {
            if (!matchRoot.IsAncestorOf(candidate) || GodotStableIdentity.Unit(candidate) != unitId)
            {
                continue;
            }
            Register(candidate);
            unit = candidate;
            return true;
        }
        unit = null!;
        return false;
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
