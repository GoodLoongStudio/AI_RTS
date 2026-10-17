using AI_RTS.Application.Economy;
using AI_RTS.Application.Queries;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Economy;
using AI_RTS.Domain.Queries;
using AI_RTS.GodotAdapter.Common;
using AI_RTS.GodotAdapter.Composition;
using AI_RTS.GodotAdapter.Production;
using Godot;
using System.Diagnostics;

namespace AI_RTS.GodotAdapter.Queries;

/// <summary>把当前 Match 的 Godot 场景和权威经济账户复制为不暴露 Node 的观察快照。</summary>
public sealed class GodotWorldObservationRepository : IWorldObservationRepository
{
    private const float SightCompensation = 2.0f;
    private readonly Node _matchRoot;
    private readonly IResourceAccountService _accounts;
    private readonly CommandRuntime _commands;
    private readonly ProductionRuntime _production;

    /// <summary>同一物理帧内共享的快照（见 CaptureShared）。</summary>
    private WorldObservationSnapshot? _sharedSnapshot;
    private long _sharedSnapshotFrame = -1;

    /// <summary>绑定单个 Match 根节点和该 Match 唯一资源账户服务。</summary>
    public GodotWorldObservationRepository(
        Node matchRoot,
        IResourceAccountService accounts,
        CommandRuntime commands,
        ProductionRuntime production)
    {
        _matchRoot = matchRoot;
        _accounts = accounts;
        _commands = commands;
        _production = production;
    }

    private bool _notedFirstCapture;

    /// <inheritdoc />
    public WorldObservationSnapshot Capture()
    {
        var perf = QueryPerfCounters.Enabled;
        var mark = perf ? Stopwatch.GetTimestamp() : 0L;
        void Part(string name)
        {
            if (!perf)
            {
                return;
            }
            var now = Stopwatch.GetTimestamp();
            QueryPerfCounters.AddCapturePhase(name, now - mark);
            mark = now;
        }

        var players = NodesInMatch("players");
        var playerIds = players.ToDictionary(player => player, GodotStableIdentity.Player);
        var units = NodesInMatch("units");
        var resources = NodesInMatch("resource_units");
        Part("capture_nodes");
        var revealers = SampleRevealers(players, playerIds, units);
        Part("capture_reveal");
        var entities = units.Select(unit => SnapshotUnit(unit, playerIds, revealers))
            .Concat(resources.Select(resource => SnapshotResource(resource, revealers)))
            .OrderBy(entity => entity.EntityId.Kind)
            .ThenBy(entity => entity.EntityId.Value)
            .ToArray();
        Part("capture_entities");
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
        Part("capture_economy");
        var visibilityRegions = revealers
            .Select(revealer => new VisibilityRegionSnapshot(
                revealer.Player,
                new WorldPosition(revealer.X, revealer.Y, revealer.Z),
                revealer.SightWithCompensation))
            .ToArray();
        var bounds = CaptureBattlefieldBounds();
        Part("capture_rest");
        return new WorldObservationSnapshot(
            checked((long)Engine.GetPhysicsFrames()),
            entities,
            economies,
            visibilityRegions,
            bounds);
    }

    /// <inheritdoc />
    public WorldObservationSnapshot CaptureShared()
    {
        // 【性能·勿回退：3 个电脑玩家也要流畅】Capture 是"全场单位 × 每个玩家的揭示者"的全量重建，
        // 而 AI 每个决策拍会连续发起十几次查询（各 Controller 的 GetOwnForces、每个编组的全图
        // ScanCircle、每个空闲工人的资源扫描、每次资源交付再查一次经济）—— 过去每次查询都重建一次，
        // 是主机主线程最大的热点（3 个 AI 约 ×3，且 AI 把单位数再抬高一层）。
        // 单位迁移、结算与命令生效都发生在物理帧边界，所以同一物理帧内共享不会让任何观察变旧；
        // 唯一折衷：同一帧内"命令已扣款、结算要到下一帧才反映"的变化看不到，AI 至多少算一拍。
        var frame = checked((long)Engine.GetPhysicsFrames());
        if (_sharedSnapshot is not null && frame == _sharedSnapshotFrame)
        {
            QueryPerfCounters.AddCapture(0L, false, 0L);
            return _sharedSnapshot;
        }

        var started = QueryPerfCounters.Enabled ? Stopwatch.GetTimestamp() : 0L;
        _sharedSnapshot = Capture();
        _sharedSnapshotFrame = frame;
        if (QueryPerfCounters.Enabled)
        {
            var elapsed = Stopwatch.GetTimestamp() - started;
            QueryPerfCounters.AddCapture(elapsed, true, _sharedSnapshot.Entities.Count);
            if (!_notedFirstCapture)
            {
                _notedFirstCapture = true;
                QueryPerfCounters.AddCapturePhase("capture_first", elapsed);
            }
        }
        return _sharedSnapshot;
    }

    /// <summary>读取 Map 公开尺寸并转换为不暴露 Node 的轴对齐战场边界。</summary>
    private BattlefieldBounds? CaptureBattlefieldBounds()
    {
        var map = _matchRoot.FindChild("Map", false, false);
        if (map is null)
        {
            return null;
        }
        var size = map.Get("size").AsVector2();
        if (!float.IsFinite(size.X) || !float.IsFinite(size.Y) ||
            size.X <= 0 || size.Y <= 0)
        {
            return null;
        }
        return new BattlefieldBounds(0, size.X, 0, size.Y);
    }

    /// <summary>一次快照里揭示者的位置和视野。避免每个观察对象再读一遍 Godot 属性。</summary>
    private readonly record struct RevealerSample(
        PlayerId Player, float X, float Y, float Z, float SightWithCompensation, float RangeSquared);

    private static RevealerSample[] SampleRevealers(
        Node[] players,
        IReadOnlyDictionary<Node, PlayerId> playerIds,
        Node[] units)
    {
        var samples = new List<RevealerSample>();
        foreach (var player in players)
        {
            var playerId = playerIds[player];
            foreach (var unit in units)
            {
                if (unit.GetParent() != player || !TryReadSight(unit, out var sight))
                {
                    continue;
                }
                if (unit.HasMethod("is_constructed") && !unit.Call("is_constructed").AsBool())
                {
                    continue;
                }
                var origin = Position(unit);
                var range = sight + SightCompensation;
                samples.Add(new RevealerSample(
                    playerId, origin.X, origin.Y, origin.Z, range, range * range));
            }
        }
        return samples.ToArray();
    }

    private int _slowUnitPrints;

    private WorldEntitySnapshot SnapshotUnit(
        Node unit,
        IReadOnlyDictionary<Node, PlayerId> playerIds,
        RevealerSample[] revealers)
    {
        var perf = QueryPerfCounters.Enabled;
        var mark = perf ? Stopwatch.GetTimestamp() : 0L;
        void Part(string name)
        {
            if (!perf)
            {
                return;
            }
            var now = Stopwatch.GetTimestamp();
            var ticks = now - mark;
            QueryPerfCounters.AddCapturePhase(name, ticks);
            var microseconds = ticks * 1000000.0 / Stopwatch.Frequency;
            if (microseconds >= 8000 && _slowUnitPrints < 6)
            {
                _slowUnitPrints++;
                GD.Print($"[CAP] {name} us={microseconds:F0} unit={unit.Name}");
            }
            mark = now;
        }

        var ownerNode = unit.GetParent();
        var owner = playerIds.GetValueOrDefault(ownerNode);
        var unitId = _commands.RegisterRuntimeUnit(unit);
        var kind = unit.HasMethod("is_constructed") ?
            BattlefieldEntityKind.Structure : BattlefieldEntityKind.Unit;
        Part("capture_u_id");
        var position = Position(unit);
        var unitType = UnitType(unit);
        var hp = NullableFloat(unit.Get("hp"));
        var hpMax = NullableFloat(unit.Get("hp_max"));
        Part("capture_u_props");
        var visible = VisiblePlayers(position, owner.Value == Guid.Empty ? null : owner, revealers);
        Part("capture_u_vis");
        var construction = _commands.ObserveConstruction(unit);
        Part("capture_u_build");
        var production = _production.ObserveProduction(unit);
        Part("capture_u_prod");
        var order = _commands.ObserveActiveOrder(unit);
        Part("capture_u_order");
        return new WorldEntitySnapshot(
            new BattlefieldEntityId(kind, unitId.Value),
            owner.Value == Guid.Empty ? null : owner,
            position,
            unitType,
            hp,
            hpMax,
            kind == BattlefieldEntityKind.Structure,
            visible,
            construction,
            production,
            order);
    }

    private WorldEntitySnapshot SnapshotResource(
        Node resource,
        RevealerSample[] revealers)
    {
        var resourceId = _commands.RegisterRuntimeResource(resource);
        var position = Position(resource);
        return new WorldEntitySnapshot(
            new BattlefieldEntityId(
                BattlefieldEntityKind.ResourceNode,
                resourceId.Value),
            null,
            position,
            ResourceType(resource),
            null,
            null,
            false,
            VisiblePlayers(position, null, revealers));
    }

    private static IReadOnlySet<PlayerId> VisiblePlayers(
        WorldPosition entityPosition,
        PlayerId? owner,
        RevealerSample[] revealers)
    {
        var result = new HashSet<PlayerId>();
        if (owner is not null)
        {
            result.Add(owner.Value);
        }
        foreach (var revealer in revealers)
        {
            if (result.Contains(revealer.Player))
            {
                continue;
            }
            var x = revealer.X - entityPosition.X;
            var z = revealer.Z - entityPosition.Z;
            if (x * x + z * z <= revealer.RangeSquared)
            {
                result.Add(revealer.Player);
            }
        }
        return result;
    }

    private static bool TryReadSight(Node unit, out float sight)
    {
        var value = NullableFloat(unit.Get("sight_range"));
        if (value is null || value <= 0)
        {
            sight = 0;
            return false;
        }
        sight = value.Value;
        return true;
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
