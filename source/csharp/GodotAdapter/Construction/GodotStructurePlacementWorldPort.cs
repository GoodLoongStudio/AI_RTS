using AI_RTS.Application.Construction;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Construction;
using AI_RTS.GodotAdapter.Common;
using Godot;

namespace AI_RTS.GodotAdapter.Construction;

/// <summary>保存一次 Godot 空间评估的问题以及仅限己方的安全驱逐计划。</summary>
internal sealed record GodotPlacementWorldAssessment(
    IReadOnlyList<StructurePlacementIssue> Issues,
    IReadOnlyDictionary<Node3D, Vector3> FriendlyDisplacements);

/// <summary>把当前 Godot 地图、视野、导航和单位占用转换为稳定放置问题。</summary>
internal sealed class GodotStructurePlacementWorldPort : IStructurePlacementWorldPort
{
    private const int TerrainDomain = 1;
    private const float SightCompensation = 2.0f;
    private const float DisplacementMargin = 0.35f;
    private const int PerimeterSamples = 16;
    private readonly Node _match;
    private readonly Dictionary<PlayerId, WeakReference<Node>> _players = new();

    /// <summary>建立只访问当前 Match SceneTree 的空间适配器。</summary>
    public GodotStructurePlacementWorldPort(Node match)
    {
        _match = match;
    }

    /// <summary>注册查询发出者的 Godot Player Node，供所有权和视野判断使用。</summary>
    public void RegisterPlayer(PlayerId playerId, Node player) =>
        _players[playerId] = new WeakReference<Node>(player);

    /// <inheritdoc />
    public IReadOnlyList<StructurePlacementIssue> Evaluate(
        MatchId matchId,
        PlayerId playerId,
        StructurePlacementCandidate candidate,
        StructurePlacementDefinition definition) =>
        EvaluateDetailed(playerId, candidate, definition).Issues;

    /// <summary>执行空间评估并为重叠己方移动单位计算确定性安全落点。</summary>
    public GodotPlacementWorldAssessment EvaluateDetailed(
        PlayerId playerId,
        StructurePlacementCandidate candidate,
        StructurePlacementDefinition definition)
    {
        var issues = new HashSet<StructurePlacementIssue>();
        if (!_players.TryGetValue(playerId, out var reference) ||
            !reference.TryGetTarget(out var player) || !GodotObject.IsInstanceValid(player) ||
            definition.Footprint is not CirclePlacementFootprint footprint ||
            definition.EnvironmentId.Value != "terrain.surface")
        {
            return new GodotPlacementWorldAssessment(
                [StructurePlacementIssue.ValidationUnavailable],
                new Dictionary<Node3D, Vector3>());
        }

        var center = ToVector3(candidate.Position);
        if (!InsideMap(center, footprint.Radius))
        {
            issues.Add(StructurePlacementIssue.OutOfBounds);
        }
        var fullyVisible = FullyVisible(player, center, footprint.Radius);
        if (!fullyVisible)
        {
            issues.Add(StructurePlacementIssue.NotVisible);
        }
        if (!Navigable(center, footprint.Radius))
        {
            issues.Add(StructurePlacementIssue.SurfaceNotBuildable);
        }

        var friendlyOverlaps = new List<Node3D>();
        if (fullyVisible)
        {
            foreach (var unit in Units())
            {
                if (!Overlaps(center, footprint.Radius, unit))
                {
                    continue;
                }

                var movement = unit.FindChild("Movement", false, false);
                if (movement is not null && Domain(unit) != TerrainDomain)
                {
                    continue;
                }
                if (movement is not null && unit.GetParent() == player)
                {
                    friendlyOverlaps.Add(unit);
                    continue;
                }
                issues.Add(StructurePlacementIssue.Occupied);
            }
            foreach (var resource in Resources())
            {
                if (Overlaps(center, footprint.Radius, resource))
                {
                    issues.Add(StructurePlacementIssue.Occupied);
                }
            }
        }

        Dictionary<Node3D, Vector3> displacements;
        var planned = fullyVisible ?
            PlanDisplacements(center, footprint.Radius, friendlyOverlaps) : null;
        if (fullyVisible && planned is null)
        {
            issues.Add(StructurePlacementIssue.FriendlyDisplacementUnavailable);
            displacements = new Dictionary<Node3D, Vector3>();
        }
        else
        {
            displacements = planned ?? new Dictionary<Node3D, Vector3>();
        }
        return new GodotPlacementWorldAssessment(issues.ToArray(), displacements);
    }

    /// <summary>检查完整圆形 footprint 是否处于矩形地图范围内。</summary>
    private bool InsideMap(Vector3 center, float radius)
    {
        var size = _match.GetNode<Node>("Map").Get("size").AsVector2();
        return center.X - radius >= 0.0f && center.Z - radius >= 0.0f &&
            center.X + radius <= size.X && center.Z + radius <= size.Y;
    }

    /// <summary>用中心和圆周采样保证 footprint 不延伸进战争迷雾。</summary>
    private bool FullyVisible(Node player, Vector3 center, float radius)
    {
        var revealers = Units().Where(unit => unit.GetParent() == player && Reveals(unit)).ToArray();
        foreach (var point in SampleCircle(center, radius))
        {
            if (!revealers.Any(unit =>
                PlanarDistance(point, unit.GlobalPosition) <= SightRange(unit) + SightCompensation))
            {
                return false;
            }
        }
        return true;
    }

    /// <summary>检查采样点均落在当前地表导航区域内。</summary>
    private bool Navigable(Vector3 center, float radius)
    {
        var navigation = _match.GetNode<Node>("Navigation");
        var mapRid = navigation.Call("get_navigation_map_rid_by_domain", TerrainDomain).AsRid();
        foreach (var point in SampleCircle(center, radius))
        {
            var closest = NavigationServer3D.MapGetClosestPoint(mapRid, point);
            if (PlanarDistance(point, closest) > 0.05f)
            {
                return false;
            }
        }
        return true;
    }

    /// <summary>为每个重叠友军寻找建筑外围互不重叠的导航落点。</summary>
    private Dictionary<Node3D, Vector3>? PlanDisplacements(
        Vector3 center,
        float structureRadius,
        IReadOnlyList<Node3D> overlapping)
    {
        var result = new Dictionary<Node3D, Vector3>();
        var displaced = overlapping.ToHashSet();
        foreach (var unit in overlapping.OrderBy(unit => GodotStableIdentity.Unit(unit).Value))
        {
            var unitRadius = Radius(unit);
            var initial = (unit.GlobalPosition - center) * new Vector3(1.0f, 0.0f, 1.0f);
            if (initial.LengthSquared() < 0.0001f)
            {
                initial = Vector3.Right;
            }
            initial = initial.Normalized();

            Vector3? selected = null;
            for (var ring = 0; ring < 4 && selected is null; ring++)
            {
                var distance = structureRadius + unitRadius + DisplacementMargin + ring *
                    (unitRadius * 2.0f + DisplacementMargin);
                for (var index = 0; index < PerimeterSamples; index++)
                {
                    var alternating = index == 0 ? 0 : ((index + 1) / 2) * (index % 2 == 0 ? -1 : 1);
                    var direction = initial.Rotated(Vector3.Up,
                        alternating * MathF.Tau / PerimeterSamples);
                    var candidate = center + direction * distance;
                    candidate.Y = unit.GlobalPosition.Y;
                    if (SafeDisplacement(candidate, unitRadius, unit, displaced, result.Values))
                    {
                        selected = candidate;
                        break;
                    }
                }
            }
            if (selected is null)
            {
                return null;
            }
            result.Add(unit, selected.Value);
        }
        return result;
    }

    /// <summary>验证驱逐落点在地图和导航内，且不与权威阻挡及已保留落点重叠。</summary>
    private bool SafeDisplacement(
        Vector3 candidate,
        float radius,
        Node3D movingUnit,
        IReadOnlySet<Node3D> displaced,
        IEnumerable<Vector3> reserved)
    {
        if (!InsideMap(candidate, radius) || !Navigable(candidate, radius))
        {
            return false;
        }
        if (reserved.Any(point => PlanarDistance(point, candidate) <= radius * 2.0f))
        {
            return false;
        }
        foreach (var unit in Units())
        {
            if (unit == movingUnit || displaced.Contains(unit) ||
                unit.FindChild("Movement", false, false) is not null && Domain(unit) != TerrainDomain)
            {
                continue;
            }
            if (Overlaps(candidate, radius, unit))
            {
                return false;
            }
        }
        return !Resources().Any(resource => Overlaps(candidate, radius, resource));
    }

    /// <summary>返回中心与圆周上的固定采样点。</summary>
    private static IEnumerable<Vector3> SampleCircle(Vector3 center, float radius)
    {
        yield return center;
        for (var index = 0; index < PerimeterSamples; index++)
        {
            var angle = index * MathF.Tau / PerimeterSamples;
            yield return center + new Vector3(MathF.Cos(angle) * radius, 0.0f,
                MathF.Sin(angle) * radius);
        }
    }

    /// <summary>判断己方单位是否能为建筑放置提供当前视野。</summary>
    private static bool Reveals(Node3D unit)
    {
        if (SightRange(unit) <= 0.0f)
        {
            return false;
        }
        return !unit.HasMethod("is_constructed") || unit.Call("is_constructed").AsBool();
    }

    /// <summary>读取单位或资源的圆形权威半径。</summary>
    private static float Radius(Node3D node) => node.Get("radius").AsSingle();

    /// <summary>读取单位视野；未配置时返回零。</summary>
    private static float SightRange(Node3D unit)
    {
        var value = unit.Get("sight_range");
        return value.VariantType == Variant.Type.Nil ? 0.0f : value.AsSingle();
    }

    /// <summary>读取 Legacy Navigation.Domain 整数值。</summary>
    private static int Domain(Node3D unit) => unit.Get("movement_domain").AsInt32();

    /// <summary>判断两个圆形 footprint 是否相交。</summary>
    private static bool Overlaps(Vector3 center, float radius, Node3D other) =>
        PlanarDistance(center, other.GlobalPosition) <= radius + Radius(other);

    /// <summary>计算忽略高度的世界距离。</summary>
    private static float PlanarDistance(Vector3 left, Vector3 right) =>
        new Vector2(left.X - right.X, left.Z - right.Z).Length();

    /// <summary>把纯 C# 世界坐标转换为 Godot Vector3。</summary>
    private static Vector3 ToVector3(WorldPosition position) =>
        new(position.X, position.Y, position.Z);

    /// <summary>枚举当前仍有效的玩家单位和建筑。</summary>
    private IEnumerable<Node3D> Units() =>
        _match.GetTree().GetNodesInGroup("units").OfType<Node3D>();

    /// <summary>枚举当前仍有效的资源节点。</summary>
    private IEnumerable<Node3D> Resources() =>
        _match.GetTree().GetNodesInGroup("resource_units").OfType<Node3D>();
}
