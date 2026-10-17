using AI_RTS.Application.Construction;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Construction;
using AI_RTS.GodotAdapter.Common;
using AI_RTS.GodotAdapter.Queries;
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
    /// <summary>
    /// 相邻判定的边缘操作余量（世界米）：candidate 与己方建筑的圆心距允许到
    /// <c>candidate_radius + existing_radius + EdgeClearanceMeters</c>。
    /// 【2026-09-29 尺寸口径统一】旧值 6.0m 是"让玩家点得中绿环"的临时补丁，
    /// 它把相隔十几米的建筑也算成"相邻"，预览与权威判定失真（用户明确反对）。
    /// 0.75m 只是让两栋建筑"几乎贴一起但不重叠"的操作余量；真正的建造困难靠
    /// 出生点/避让圈/carve 的世界尺寸统一来解决，不靠放大相邻范围。
    /// </summary>
    /// <summary>相邻判定的操作余量（Autospot 的环步长也用它，见 StructurePlacementRuntime）。</summary>
    internal const float EdgeClearanceMeters = 0.75f;

    /// <summary>建造网络范围（世界米）：候选建筑边缘到己方建造源边缘的最大距离。</summary>
    /// <remarks>
    /// 【2026-10-01】48m 是把资源服务/自动选址半径误当成建造范围，导致白色区域覆盖
    /// 半张地图。RA3 的规则是由 Construction Yard/扩张节点提供 ground control，
    /// 不是给每栋建筑统一加一个超大半径；当前原型仍保留“己方建筑网络可接力”的玩法，
    /// 但把边缘范围收敛到 18m。候选圆心判定仍会额外加上候选与锚点的实际 footprint。
    /// </remarks>
    // 【2026-10-02 用户口径】建造圈缩到原来的 2/3：18 → 12（圈、放置判据、搜索采样同源 ✓）。
    // 【2026-10-06 用户质询：AI 副官的建造是否与玩家同一套规则】审计结论 ⇒ 恢复『同源』：
//   - 玩家侧代码注释（StructurePlacementHandler.gd:254）明确要求：**半径与放置判据同源**；
//   - 我一度把『圈』拆成 12、『判据/窗口』留 18 ⇒ 圈会**骗人**（显示 12 却能放到 18）且破坏同源；
//   - 且该窗口同时被玩家判定、AI 的 FindAutoSpot 环形采样、以及世界端口视野/邻接判定使用；
//   - 18 → 12 的收窄曾导致 AI 只能贴建筑放 + 矿场落点全被判非法（不造矿场）。
// ⇒ 结论：**只保留一个来源**，圈 = 判据 = 窗口 = BuildRangeMeters。
// 【用户口径 2026-10-07】可建造半径按用户要求缩小为原来的 2/3（18 → 12）✓
// 注意：该常量同时是「放置判定/搜索网络窗口」⇒ 收窄会让 AI 只能贴建筑放 ✓（此前实测过 ✓）
internal const float BuildRangeMeters = 12f;
    /// <summary>
    /// 建筑窄缝阈值（碰撞表面间隙，世界米）。放置不再用这段拒绝。
    /// Seal：间隙小于该值时导航面在缝里断开。
    /// Pass：最大地面单位要缝 ≥ 2×2.75 + 0.1 才不必穿模。
    /// 小于 Pass 且单位过不去时，由 Movement 单车穿模通过。
    /// </summary>
    internal const float StructureSealGapMeters = 2.4f;
    internal const float StructurePassGapMeters = 5.6f;
    private const float DisplacementMargin = 0.35f;
    /// <summary>
    /// 驱逐余量的下限：必须大于被驱逐单位的到位容差（<c>target_desired_distance</c>，
    /// 坦克 0.5 / 工人 0.31 / 步兵 0.35），否则单位在距目标一个容差内停下时
    /// 会永久留在建筑 footprint 内（2026-09-28 实测：坦克插进炮塔 12 cm）。
    /// </summary>
    private const float MinDisplacementMargin = 0.65f;

    /// <summary>
    /// 圆形规划半径与地面 hull 之间的各向异性余量（米）。
    /// 验收口径是 hull-to-hull（2026-10-01 用户定），而这里能拿到的只有圆形 `radius`。
    /// 【2026-10-12 实测 `_HullVsRadiusProbe`】hull 沿"指向对方"方向的半程：坦克 1.184/1.749、
    /// 炮塔 1.314、车厂 3.970；圆形口径：坦克 radius 1.84、炮塔 footprint 约 2.0、车厂约 3.0。
    /// 即**沿轴 hull 与圆半径同量级、互有胜负**（车厂沿轴 hull 3.97 明显大于其圆半径），
    /// 留 0.5m 覆盖这个差并保留一点安全带宽。
    /// 注意不要改成"所有方向的最大半程"：实测炮塔 4.137 / 车厂 5.010，是沿轴值的 2~3 倍，
    /// 用它算余量会把单位推到几十米外，驱逐落点直接找不到。
    /// </summary>
    private const float HullSlackMeters = 0.5f;
    private const int PerimeterSamples = 16;
    /// <summary>导航连续性判定：采样点与 navmesh 的平面距离容差（米）。</summary>
    private const float NavigableToleranceMeters = 0.05f;
    /// <summary>
    /// 导航连续性采样环半径占 footprint 半径的比例：探**圆心 + 半半径环**（SampleCircle
    /// 自带圆心）。职责分离的关键——整环会把大型建筑自己 carve 的缝隙判成地形不可建
    /// （基地 carve 9.8m &gt; footprint 7.0m），而脚印内是否被占由 Overlaps 用完整
    /// footprint 把关。水面/悬崖仍由 WaterBlocked 与半环各自负责。
    /// </summary>
    private const float TerrainProbeRadiusScale = 0.5f;
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
        StructurePlacementDefinition definition)
    {
        var started = QueryPerfCounters.Enabled
            ? System.Diagnostics.Stopwatch.GetTimestamp() : 0L;
        var assessment = EvaluateDetailed(playerId, candidate, definition);
        RememberFresh(playerId, candidate, definition, assessment);
        if (QueryPerfCounters.Enabled)
        {
            QueryPerfCounters.AddPlacementPhase(
                "eval_world", System.Diagnostics.Stopwatch.GetTimestamp() - started);
        }
        return assessment.Issues;
    }

    /// <summary>
    /// 提交路径刚通过 <see cref="Evaluate"/> 做过同一次空间评估。
    /// 玩家、定义、规范化候选和世界代际都没变时，直接交出那份驱逐计划，不再扫第二遍。
    /// </summary>
    internal GodotPlacementWorldAssessment? TryConsumeFresh(
        PlayerId playerId,
        StructurePlacementCandidate candidate,
        StructurePlacementDefinition definition)
    {
        var fresh = _freshAssessment;
        _freshAssessment = null;
        if (fresh is null || _freshGeneration != MutationCount)
        {
            return null;
        }
        if (_freshPlayer != playerId ||
            _freshDefinition != definition.DefinitionId.Value)
        {
            return null;
        }
        var position = candidate.Position;
        if (_freshX != position.X || _freshY != position.Y || _freshZ != position.Z ||
            _freshYaw != candidate.YawRadians)
        {
            return null;
        }
        return fresh;
    }

    private void RememberFresh(
        PlayerId playerId,
        StructurePlacementCandidate candidate,
        StructurePlacementDefinition definition,
        GodotPlacementWorldAssessment assessment)
    {
        var position = candidate.Position;
        _freshAssessment = assessment;
        _freshPlayer = playerId;
        _freshDefinition = definition.DefinitionId.Value;
        _freshX = position.X;
        _freshY = position.Y;
        _freshZ = position.Z;
        _freshYaw = candidate.YawRadians;
        _freshGeneration = MutationCount;
    }

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
        var perf = QueryPerfCounters.Enabled;
        var bodyStarted = perf ? System.Diagnostics.Stopwatch.GetTimestamp() : 0L;
        var part = bodyStarted;
        void Part(string name)
        {
            if (!perf)
            {
                return;
            }
            var now = System.Diagnostics.Stopwatch.GetTimestamp();
            QueryPerfCounters.AddPlacementPhase(name, now - part);
            part = now;
        }
        if (!InsideMap(center, footprint.Radius))
        {
            issues.Add(StructurePlacementIssue.OutOfBounds);
        }
        // 建造不受战争迷雾限制，但普通建筑必须接入己方建筑网络；
        // 指挥中心是唯一可远程部署的扩张锚点。
        if (!IsRemoteAnchor(candidate) && !AdjacentToOwnStructure(player, center, footprint.Radius))
        {
            issues.Add(StructurePlacementIssue.NotAdjacent);
        }
        Part("eval_adjacent");
        // 【2026-09-29 用户口径】建造不校验视野：位置合法（地形可建、不与单位/
        // 资源/建筑重叠）即可，未探索区域也允许远距离放置——远距离的代价是
        // 施工慢，而不是要求先开图。地形合法性仍由 Navigable/WaterBlocked 按整环把关。
        if (!Navigable(center, footprint.Radius) || WaterBlocked(center, footprint.Radius))
        {
            issues.Add(StructurePlacementIssue.SurfaceNotBuildable);
        }
        Part("eval_surface");

        var friendlyOverlaps = new List<Node3D>();
        foreach (var unit in Units())
        {
            if (!Overlaps(center, footprint.Radius, unit))
            {
                continue;
            }

            var movement = unit.FindChild("Movement", false, false);
            if (movement != null && Domain(unit) != TerrainDomain)
            {
                continue;
            }
            // 【2026-09-29 用户实报"车厂和基地重叠落地"】只有**机动单位**才可驱逐：
            // 己方建筑（带 MovementObstacle、无 Movement）必须硬拒 —— 它不会执行驱逐
            // （没有 Movement），旧实现把建筑当成 Occupied 是正确语义，我一度放开成
            // "己方一律尝试驱逐"，结果建筑进驱逐计划、计划成功即放行 → 两个建筑重叠。
            if (movement != null && unit.GetParent() == player)
            {
                friendlyOverlaps.Add(unit);
                continue;
            }
            issues.Add(StructurePlacementIssue.Occupied);
        }
        Part("eval_units");
        foreach (var resource in Resources())
        {
            if (Overlaps(center, footprint.Radius, resource))
            {
                issues.Add(StructurePlacementIssue.Occupied);
            }
        }
        Part("eval_resources");
        // 窄缝允许建造（表面空隙落在贴紧与可通行之间也不再拒绝）。
        // 过不去的地面单位由 Movement 的单车穿模通行证通过，不在这里加 BlocksPassage。

        Dictionary<Node3D, Vector3> displacements;
        var planned = PlanDisplacements(center, footprint.Radius, friendlyOverlaps);
        Part("eval_displace");
        if (planned is null)
        {
            issues.Add(StructurePlacementIssue.FriendlyDisplacementUnavailable);
            displacements = new Dictionary<Node3D, Vector3>();
        }
        else
        {
            displacements = planned;
        }
        if (perf)
        {
            QueryPerfCounters.AddPlacementPhase(
                "eval_body", System.Diagnostics.Stopwatch.GetTimestamp() - bodyStarted);
        }
        return new GodotPlacementWorldAssessment(issues.ToArray(), displacements);
    }

    /// <summary>普通建筑与任意己方建筑边缘相邻即可落位。</summary>
    private bool AdjacentToOwnStructure(Node player, Vector3 center, float radius)
    {
        var structures = Units()
            .Where(unit => unit.GetParent() == player &&
                unit.FindChild("MovementObstacle", false, false) is not null)
            .ToArray();
        return structures.Any(unit =>
            PlanarDistance(center, unit.GlobalPosition) <= radius + Radius(unit) + BuildRangeMeters);
    }

    private static bool IsRemoteAnchor(StructurePlacementCandidate candidate) =>
        string.Equals(candidate.DefinitionId.Value, "command_center", StringComparison.Ordinal);

    /// <summary>检查完整圆形 footprint 是否处于矩形地图范围内。</summary>
    private bool InsideMap(Vector3 center, float radius)
    {
        using var size = _match.GetNode<Node>("Map").Get("size");
        var mapSize = size.AsVector2();
        return center.X - radius >= 0.0f && center.Z - radius >= 0.0f &&
            center.X + radius <= mapSize.X && center.Z + radius <= mapSize.Y;
    }

    /// <summary>生成地图把水面当逻辑禁行区，不建 200+ 块水面碰撞。</summary>
    private bool WaterBlocked(Vector3 center, float radius)
    {
        var map = _match.GetNodeOrNull("Map");
        if (map == null || !map.HasMeta("water_occupancy"))
        {
            return false;
        }
        using var occupancyVariant = map.GetMeta("water_occupancy");
        if (occupancyVariant.AsGodotObject() is not Node occupancy ||
            !occupancy.HasMethod("is_water_blocked"))
        {
            return false;
        }
        foreach (var point in SampleCircle(center, radius))
        {
            if (CachedOccupancy(occupancy, "is_water_blocked", point, _waterPointCache))
            {
                return true;
            }
        }
        return false;
    }

    /// <summary>检查采样点均落在当前地表导航区域内。</summary>
    private bool Navigable(Vector3 center, float radius)
    {
        // 256+ 生成图跳过 navmesh；台地顶用高度/坡度判定，不能再拿空导航当不可造。
        if (UsesLogicSurface())
        {
            return SurfaceBuildable(center, radius);
        }
        var navigation = _match.GetNode<Node>("Navigation");
        using var mapRid = navigation.Call("get_navigation_map_rid_by_domain", TerrainDomain);
        var rid = mapRid.AsRid();
        // 【2026-09-29 用户实报"近了不能造、稍远能造、再远又不能造"（同心圆绿环）】
        // 导航烘焙会给每个障碍（建筑/矿点）挖洞，洞边界 = 障碍碰撞体 `vertices` 的世界
        // XZ 包围盒 + `agent_radius`(2.8m，09-27 尺寸统一时随单位半径一起放大)。旧实现把洞当成
        // "地形不平"：矿点 0.2m 碰撞 → 3.0m 洞、基地 1.4m → 4.2m 洞，绿环被这些 carve 岛
        // 啃得只剩几道细缝（实测 976 个候选仅 8.7% 可建）。
        // 修正：采样点若落在某障碍的 carve 洞内，视为"被该障碍遮挡"（由 Occupied 判定用
        // footprint 统一把关放不放得下），只有真正落在所有障碍外的不可导航点
        // 才算地形不可建（悬崖/水面仍由 WaterBlocked 负责）。
        var carveZones = CarveZones().ToArray();
        // 【2026-09-29 尺寸口径统一】导航**连续性**只验证"圆心 + 半半径环"：
        // 整环（半径外沿 16 点）验证会把大型建筑自己挖的 carve 缝隙算成地形不可建
        // （基地 carve 9.8m > 自身 footprint 7.0m，整环必然踩缝 → "Irregular terrain"）。
        // 圆心+半环足以判定"这块地平不平、连不连得上路网"；至于脚印范围内是否被
        // 既有障碍 carve 占着，由 <see cref="Overlaps"/> / <see cref="Occupied"/>
        // 用完整 footprint 把关（职责分离，与任务要求一致）。
        foreach (var point in SampleCircle(center, radius * TerrainProbeRadiusScale))
        {
            var closest = NavigationServer3D.MapGetClosestPoint(rid, point);
            if (PlanarDistance(point, closest) > NavigableToleranceMeters && !InsideAnyCarveZone(point, carveZones))
            {
                return false;
            }
        }
        return true;
    }

    /// <summary>导航 agent_radius（读 navmesh 本体，不复制常量：烘焙侧 assert 保证它与单位半径匹配）。
    /// 【2026-09-30】抽成 static 供自动选址复用：carve 洞 = footprint 包围网格 + agent_radius，
    /// 两处各写一份常量必然漂移。</summary>
    internal static float AgentRadiusMetersOf(Node? matchNode)
    {
        var region = matchNode?.GetNodeOrNull("Navigation/Terrain/NavigationRegion3D");
        if (region == null && matchNode != null)
        {
            region = matchNode.GetTree()?.Root.FindChild("NavigationRegion3D", true, false);
        }
        if (region == null)
        {
            return 2.8f;
        }
        using var mesh = region.Get("navigation_mesh");
        if (mesh.Obj is GodotObject meshObject)
        {
            using var agentRadius = meshObject.Get("agent_radius");
            return agentRadius.AsSingle();
        }
        return 2.8f;
    }

    private float AgentRadiusMeters => CachedAgentRadiusMeters;

    private float _cachedAgentRadius = -1f;

    /// <summary>导航 agent 半径在一局里不变。缓存后避免每次选址从场景根 FindChild。</summary>
    internal float CachedAgentRadiusMeters
    {
        get
        {
            if (_cachedAgentRadius < 0f)
            {
                _cachedAgentRadius = AgentRadiusMetersOf(_match);
            }
            return _cachedAgentRadius;
        }
    }

    internal int MutationCount { get; private set; }

    private GodotPlacementWorldAssessment? _freshAssessment;
    private PlayerId _freshPlayer;
    private string _freshDefinition = "";
    private float _freshX;
    private float _freshY;
    private float _freshZ;
    private float _freshYaw;
    private int _freshGeneration = -1;

    /// <summary>
    /// 障碍 carve 洞：MovementObstacle.vertices 的世界 XZ 包围盒外扩 agent_radius。
    /// 不再把长方形/旋转碰撞体压成圆半径，否则导航连续性和实际 carve 网格不一致。
    /// 【2026-09-29 用户实报"矿场还是放不下"】必须同时覆盖 `units` 与 `resource_units`
    /// 两个组：地图预置矿点在场景里写死 `groups=["resource_units"]`，**不在** `units` 组，
    /// 只扫 units 会把基地旁边几簇矿的 carve 洞（0.2 + 2.8 ≈ 3.05m）全部漏掉，
    /// 于是判定报"地形不平"——正是玩家看到的红字。
    /// </summary>
    private IEnumerable<Rect2> CarveZones()
    {
        var agentRadius = AgentRadiusMeters;
        var obstacles = Units()
            .Concat(Resources())
            .Where(node => node.FindChild("MovementObstacle", false, false) is not null)
            .Distinct();
        foreach (var node in obstacles)
        {
            if (node.FindChild("MovementObstacle", false, false) is not Node3D obstacle)
            {
                continue;
            }
            yield return CarveBoundsOf(obstacle, agentRadius);
        }
    }

    /// <summary>
    /// 单个障碍的导航挖洞包围盒：vertices 的世界空间 XZ AABB + agent_radius。
    /// NavigationObstacle3D 用 vertices 进行 navmesh carve；这里仅用于判断
    /// "closest point 距离过大" 是否是该障碍自己的洞，不能把它误报成地形不可建。
    /// </summary>
    /// <remarks>
    /// 【2026-09-29 收尾崩溃】<c>Get("vertices")</c> 的 Variant 持有原生
    /// <c>PackedVector3Array</c>（引用计数对象）：不 Dispose 就把释放推给 GC finalizer，
    /// 而放置评估每帧要查几十个障碍 × 几十个候选点，退出时 native interop 已拆除 →
    /// <c>godot_variant_destroy</c> 访问违例（0xC0000005，实测 refinery-free-miner 必崩）。
    /// 跨 GDScript 边界读属性一律 `using` 掉 Variant。
    /// </remarks>
    private static Rect2 CarveBoundsOf(Node3D obstacle, float agentRadius)
    {
        using var vertices = obstacle.Get("vertices");
        Rect2? bounds = null;
        if (vertices.VariantType == Variant.Type.PackedVector3Array)
        {
            foreach (var vertex in vertices.AsVector3Array())
            {
                var worldVertex = obstacle.GlobalTransform * vertex;
                var point = new Vector2(worldVertex.X, worldVertex.Z);
                var pointBounds = new Rect2(point, Vector2.Zero);
                bounds = bounds is null ? pointBounds : bounds.Value.Merge(pointBounds);
            }
        }

        if (bounds is not null && bounds.Value.Size.X > 0.0f && bounds.Value.Size.Y > 0.0f)
        {
            var expansion = Vector2.One * (agentRadius + 0.05f);
            return new Rect2(bounds.Value.Position - expansion, bounds.Value.Size + expansion * 2.0f);
        }

        using var footprint = obstacle.Get("radius");
        var fallbackRadius = footprint.VariantType == Variant.Type.Nil
            ? 0.0f
            : footprint.AsSingle();
        var center = new Vector2(obstacle.GlobalPosition.X, obstacle.GlobalPosition.Z);
        var fallbackExtent = fallbackRadius + CarveMarginOf(obstacle) + agentRadius + 0.05f;
        return new Rect2(center - Vector2.One * fallbackExtent, Vector2.One * fallbackExtent * 2.0f);
    }

    /// <summary>MovementObstacle 的 carve 外扩（只对参与烘焙的障碍生效；vertices 分支已包含它）。</summary>
    internal static float CarveMarginOf(Node obstacle)
    {
        if (!obstacle.HasMethod("effective_carve_margin"))
        {
            return 0.0f;
        }
        using var margin = obstacle.Call("effective_carve_margin");
        return margin.AsSingle();
    }

    /// <summary>单位的到位容差（Movement.target_desired_distance；读不到按车辆级 0.5 兜底）。</summary>
    /// <summary>
    /// 单位"自认为到达"的半径——必须与移动层的判据**同一个口径**。
    /// 【2026-10-12 建筑卡单位】原来只读 `target_desired_distance`（实测坦克 0.15m），
    /// 但 `Movement.gd:844` 判到达用的是 `max(movement.radius, 0.35)`
    /// （实测坦克运行时 radius=1.84，**不是** tscn 里的 1.288）。
    /// 两者差 1.69m：规划层按 0.15 留 margin，把落点算到离建筑 3.87m，
    /// 单位却在离目标 1.60m 处就"到达"（`_terminal_events`: reason=Arrived），
    /// 最终停在离建筑 2.27m —— 仍压在 hull 要求的 3.43m 里面。
    /// 这就是 `StructurePlacementSmokeTest`「被覆盖的友军应移动到建筑 footprint 外」
    /// 和 `SpawnPointRegression` B2 的真因。
    /// </summary>
    private static float ArriveToleranceOf(Node3D unit)
    {
        var movement = unit.FindChild("Movement", false, false);
        if (movement != null)
        {
            var tolerance = 0.0f;
            using (var value = movement.Get("target_desired_distance"))
            {
                if (value.VariantType != Variant.Type.Nil && value.AsSingle() > 0.0f)
                {
                    tolerance = value.AsSingle();
                }
            }
            // 移动层真正的到达判据：半径本身（下限 0.35）；两者取大，绝不小于它。
            using (var radiusValue = movement.Get("radius"))
            {
                if (radiusValue.VariantType != Variant.Type.Nil)
                {
                    tolerance = MathF.Max(tolerance, MathF.Max(radiusValue.AsSingle(), 0.35f));
                }
            }
            if (tolerance > 0.0f)
            {
                return tolerance;
            }
        }
        return 0.5f;
    }

    /// <summary>平面点是否落在任一 carve 包围盒内（含 0.05m 判定容差）。</summary>
    private static bool InsideAnyCarveZone(Vector3 point, Rect2[] zones)
    {
        var point2 = new Vector2(point.X, point.Z);
        foreach (var zone in zones)
        {
            if (zone.HasPoint(point2))
            {
                return true;
            }
        }
        return false;
    }

    /// <summary>256+ 生成图跳过导航烘焙，用高度/坡度代替 navmesh。</summary>
    private bool UsesLogicSurface()
    {
        var map = _match.GetNodeOrNull("Map");
        if (map == null)
        {
            return false;
        }
        var size = map.Get("size");
        using (size)
        {
            if (size.VariantType != Variant.Type.Vector2)
            {
                return false;
            }
            var mapSize = size.AsVector2();
            return mapSize.X >= 256.0f || mapSize.Y >= 256.0f;
        }
    }

    /// <summary>台地顶和平地可造，水面与陡坡不可造。</summary>
    private bool SurfaceBuildable(Vector3 center, float radius)
    {
        var map = _match.GetNodeOrNull("Map");
        if (map == null || !map.HasMeta("water_occupancy"))
        {
            return true;
        }
        using var occupancyVariant = map.GetMeta("water_occupancy");
        if (occupancyVariant.AsGodotObject() is not Node occupancy ||
            !occupancy.HasMethod("is_surface_buildable"))
        {
            return true;
        }
        foreach (var point in SampleCircle(center, radius))
        {
            if (!CachedOccupancy(occupancy, "is_surface_buildable", point, _surfacePointCache))
            {
                return false;
            }
        }
        return true;
    }

    /// <summary>
    /// 把地表/水面采样提前写入缓存，并在截止时间处停下。
    /// 1 = 整圈可通过，0 = 已发现不可建，-1 = 预算用完但还没查完。
    /// </summary>
    internal int WarmFootprint(Vector3 center, float radius, long deadlineTicks)
    {
        var map = _match.GetNodeOrNull("Map");
        if (map == null || !map.HasMeta("water_occupancy"))
        {
            return 1;
        }
        using var occupancyVariant = map.GetMeta("water_occupancy");
        if (occupancyVariant.AsGodotObject() is not Node occupancy)
        {
            return 1;
        }
        if (occupancy.HasMethod("is_surface_buildable"))
        {
            foreach (var point in SampleCircle(center, radius))
            {
                if (System.Diagnostics.Stopwatch.GetTimestamp() >= deadlineTicks)
                {
                    return -1;
                }
                if (!CachedOccupancy(occupancy, "is_surface_buildable", point, _surfacePointCache))
                {
                    return 0;
                }
            }
        }
        if (occupancy.HasMethod("is_water_blocked"))
        {
            foreach (var point in SampleCircle(center, radius))
            {
                if (System.Diagnostics.Stopwatch.GetTimestamp() >= deadlineTicks)
                {
                    return -1;
                }
                if (CachedOccupancy(occupancy, "is_water_blocked", point, _waterPointCache))
                {
                    return 0;
                }
            }
        }
        return 1;
    }

    private bool CachedOccupancy(Node occupancy, string method, Vector3 point, Dictionary<long, bool> cache)
    {
        var key = SampleKey(point) ^ ((long)method.Length << 48);
        if (cache.TryGetValue(key, out var cached))
        {
            return cached;
        }
        using var result = occupancy.Call(method, point);
        var value = result.AsBool();
        if (cache.Count > 8192)
        {
            cache.Clear();
        }
        cache[key] = value;
        return value;
    }

    private static long SampleKey(Vector3 point)
    {
        var x = (int)MathF.Round(point.X * 10f);
        var z = (int)MathF.Round(point.Z * 10f);
        return ((long)x << 32) | (uint)z;
    }

    /// <summary>为每个重叠友军寻找建筑外围互不重叠的导航落点。</summary>
    private Dictionary<Node3D, Vector3>? PlanDisplacements(
        Vector3 center,
        float structureRadius,
        IReadOnlyList<Node3D> overlapping)
    {
        var result = new Dictionary<Node3D, Vector3>();
        var displaced = overlapping.ToHashSet();
        var blockers = DisplacementBlockers(displaced);
        var resources = Resources().ToArray();
        foreach (var unit in overlapping.OrderBy(unit => GodotStableIdentity.Unit(unit).Value))
        {
            var unitRadius = Radius(unit);
            var initial = (unit.GlobalPosition - center) * new Vector3(1.0f, 0.0f, 1.0f);
            if (initial.LengthSquared() < 0.0001f)
            {
                initial = Vector3.Right;
            }
            initial = initial.Normalized();

            // 余量 = max(常量, 该单位到位容差 + 圆/壳各向异性余量)。
            // 单位会在距目标"一个到位容差"内停下（口径见 `ArriveToleranceOf`，
            // 2026-10-12 已修正为与移动层判据同源），余量必须吃掉它；
            // 另外规划用的是**圆形半径**，而验收用的是**地面 hull**
            // （`hull-to-hull`，炮塔圆 1.38 但沿轴 hull ≈1.64），
            // 所以还要再留出 HullSlack，否则会差最后几厘米而仍然压在楼里
            // （实测：只留 0.15 时停在 3.40m，hull 要求 >3.43m）。
            var tolerance = ArriveToleranceOf(unit);
            var margin = MathF.Max(DisplacementMargin, tolerance + HullSlackMeters);
            margin = MathF.Max(margin, MinDisplacementMargin);
            Vector3? selected = null;
            for (var ring = 0; ring < 4 && selected is null; ring++)
            {
                var distance = structureRadius + unitRadius + margin + ring *
                    (unitRadius * 2.0f + margin);
                for (var index = 0; index < PerimeterSamples; index++)
                {
                    var alternating = index == 0 ? 0 : ((index + 1) / 2) * (index % 2 == 0 ? -1 : 1);
                    var direction = initial.Rotated(Vector3.Up,
                        alternating * MathF.Tau / PerimeterSamples);
                    var candidate = center + direction * distance;
                    candidate.Y = unit.GlobalPosition.Y;
                    // 【2026-09-29 任务硬性要求】落点必须离开建筑 **半径和 + 到位容差 +
                    // 安全余量**：单位走到目标后会在距目标一个到位容差内停下，distance 里
                    // 已含 margin（= max(0.35, 到位容差+0.15)），这里再显式复核一遍
                    // "实际间距 > 半径和 + 到位容差"，双保险防止单位卡在建筑 footprint 内
                    // （2026-09-28 实测：坦克停在距炮塔 4.08m 而要求 4.20m，差 12cm）。
                    var finalGap = PlanarDistance(candidate, center) - structureRadius - unitRadius;
                    var acceptable = finalGap > tolerance &&
                        SafeDisplacement(candidate, unitRadius, blockers, resources, result.Values);
                    if (acceptable)
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
    /// <summary>
    /// 驱逐检测要挡路的单位：正在被这场驱逐挪走的不算，空域单位也不算。
    /// 同一场评估里每个采样点都用这份名单，避免每个采样点再走一遍 FindChild。
    /// </summary>
    private Node3D[] DisplacementBlockers(IReadOnlySet<Node3D> displaced)
    {
        var blockers = new List<Node3D>();
        foreach (var unit in Units())
        {
            if (displaced.Contains(unit))
            {
                continue;
            }
            var movement = unit.FindChild("Movement", false, false);
            if (movement != null && Domain(unit) != TerrainDomain)
            {
                continue;
            }
            blockers.Add(unit);
        }
        return blockers.ToArray();
    }

    private bool SafeDisplacement(
        Vector3 candidate,
        float radius,
        Node3D[] blockers,
        Node3D[] resources,
        IEnumerable<Vector3> reserved)
    {
        if (!InsideMap(candidate, radius) || !Navigable(candidate, radius) ||
            WaterBlocked(candidate, radius))
        {
            return false;
        }
        if (reserved.Any(point => PlanarDistance(point, candidate) <= radius * 2.0f))
        {
            return false;
        }
        foreach (var unit in blockers)
        {
            if (!GodotObject.IsInstanceValid(unit))
            {
                continue;
            }
            if (Overlaps(candidate, radius, unit))
            {
                return false;
            }
        }
        foreach (var resource in resources)
        {
            if (!GodotObject.IsInstanceValid(resource))
            {
                continue;
            }
            if (Overlaps(candidate, radius, resource))
            {
                return false;
            }
        }
        return true;
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
        using var constructed = unit.Call("is_constructed");
        return constructed.AsBool();
    }

    /// <summary>读取单位或资源的圆形权威半径。</summary>
    /// <summary>单位的占地半径（世界米）：优先逻辑半径，其次碰撞体，供自动选址复用。</summary>
    internal static float RadiusOf(Node3D node) => Radius(node);

    private static float Radius(Node3D node)
    {
        using var value = node.Get("radius");
        return value.AsSingle();
    }

    /// <summary>读取单位视野；未配置时返回零。</summary>
    private static float SightRange(Node3D unit)
    {
        using var value = unit.Get("sight_range");
        return value.VariantType == Variant.Type.Nil ? 0.0f : value.AsSingle();
    }

    /// <summary>读取 Legacy Navigation.Domain 整数值。</summary>
    private static int Domain(Node3D unit)
    {
        using var value = unit.Get("movement_domain");
        return value.AsInt32();
    }

    /// <summary>
    /// 判断候选 footprint 是否与实际 CollisionShape3D 的世界包围网格相交。
    ///
    /// 旧实现只比较两个逻辑半径，导致长方形/旋转后的碰撞体仍按圆形处理，
    /// 也让调试画面里的红色圆柱看起来像是实际碰撞体。候选建筑定义目前仍以
    /// 半径表达，因此候选侧使用等边包围盒；已有单位/建筑/资源侧读取真实形状。
    /// </summary>
    private bool Overlaps(Vector3 center, float radius, Node3D other)
    {
        var candidate = new Rect2(
            new Vector2(center.X - radius, center.Z - radius),
            Vector2.One * radius * 2.0f);
        var occupied = CollisionBounds(other);
        return candidate.Position.X <= occupied.End.X &&
            candidate.End.X >= occupied.Position.X &&
            candidate.Position.Y <= occupied.End.Y &&
            candidate.End.Y >= occupied.Position.Y;
    }

    private readonly Dictionary<string, Vector2[]> _candidateFootprints = new(StringComparer.Ordinal);

    /// <summary>缓存候选建筑在自身局部坐标下的碰撞足迹，供旋转后的间隙计算。</summary>
    internal void RegisterCandidateFootprint(string definitionId, PackedScene prototype)
    {
        if (string.IsNullOrEmpty(definitionId) || prototype == null ||
            _candidateFootprints.ContainsKey(definitionId))
        {
            return;
        }

        var instance = prototype.Instantiate<Node3D>();
        try
        {
            _candidateFootprints[definitionId] = LocalCollisionFootprint(instance);
        }
        finally
        {
            instance.Free();
        }
    }

    /// <summary>
    /// 表面间隙是否落在 (Seal, Pass)。放置评估已不再调用，窄缝允许建造。
    /// 几何留在这里，和 StructureSealGapMeters / StructurePassGapMeters 放在一起。
    /// </summary>
    private bool LeavesBlockingGap(StructurePlacementCandidate candidate, Vector3 center, float radius)
    {
        var footprint = CandidateFootprint(candidate, center, radius);
        foreach (var unit in Units())
        {
            if (PlanarDistance(center, unit.GlobalPosition) >
                (radius + Radius(unit)) * 1.5f + StructurePassGapMeters)
            {
                continue;
            }
            if (unit.FindChild("MovementObstacle", false, false) is not Node obstacle)
            {
                continue;
            }
            using var affects = obstacle.Get("affect_navigation_mesh");
            if (!affects.AsBool())
            {
                continue;
            }
            var gap = ConvexGap(footprint, RectCorners(CollisionBounds(unit)));
            if (gap > StructureSealGapMeters && gap < StructurePassGapMeters)
            {
                return true;
            }
        }
        return false;
    }

    private Vector2[] CandidateFootprint(StructurePlacementCandidate candidate, Vector3 center, float radius)
    {
        if (_candidateFootprints.TryGetValue(candidate.DefinitionId.Value, out var local) && local.Length >= 3)
        {
            var basis = new Basis(Vector3.Up, candidate.YawRadians);
            var world = new Vector2[local.Length];
            for (var i = 0; i < local.Length; i++)
            {
                var rotated = basis * new Vector3(local[i].X, 0.0f, local[i].Y);
                world[i] = new Vector2(center.X + rotated.X, center.Z + rotated.Z);
            }
            return world;
        }

        return RectCorners(new Rect2(
            new Vector2(center.X - radius, center.Z - radius),
            Vector2.One * radius * 2.0f));
    }

    private static Vector2[] LocalCollisionFootprint(Node3D root)
    {
        var minX = float.PositiveInfinity;
        var minZ = float.PositiveInfinity;
        var maxX = float.NegativeInfinity;
        var maxZ = float.NegativeInfinity;
        var any = false;
        foreach (var descendant in Descendants(root))
        {
            if (descendant is not CollisionShape3D shapeNode || shapeNode.Shape is null ||
                ShapeBounds(shapeNode.Shape) is not (Vector3 Min, Vector3 Max) local)
            {
                continue;
            }

            var relative = RelativeTo(root, shapeNode);
            foreach (var corner in BoundsCorners(local.Min, local.Max))
            {
                var point = relative * corner;
                any = true;
                minX = MathF.Min(minX, point.X);
                minZ = MathF.Min(minZ, point.Z);
                maxX = MathF.Max(maxX, point.X);
                maxZ = MathF.Max(maxZ, point.Z);
            }
        }

        if (!any || maxX - minX < 0.01f || maxZ - minZ < 0.01f)
        {
            return Array.Empty<Vector2>();
        }

        return
        [
            new Vector2(minX, minZ),
            new Vector2(maxX, minZ),
            new Vector2(maxX, maxZ),
            new Vector2(minX, maxZ),
        ];
    }

    private static Transform3D RelativeTo(Node3D root, Node3D node)
    {
        var transform = Transform3D.Identity;
        for (Node? current = node; current != null && current != root; current = current.GetParent())
        {
            if (current is Node3D spatial)
            {
                transform = spatial.Transform * transform;
            }
        }
        return transform;
    }

    private static Vector2[] RectCorners(Rect2 rect) =>
    [
        rect.Position,
        new Vector2(rect.End.X, rect.Position.Y),
        rect.End,
        new Vector2(rect.Position.X, rect.End.Y),
    ];

    private static float ConvexGap(Vector2[] left, Vector2[] right)
    {
        if (left.Length < 3 || right.Length < 3)
        {
            return float.MaxValue;
        }
        if (PolygonsOverlap(left, right))
        {
            return 0.0f;
        }

        var best = float.MaxValue;
        AccumulateEdgeDistance(left, right, ref best);
        AccumulateEdgeDistance(right, left, ref best);
        return best;
    }

    private static void AccumulateEdgeDistance(Vector2[] edges, Vector2[] points, ref float best)
    {
        for (var i = 0; i < edges.Length; i++)
        {
            var start = edges[i];
            var end = edges[(i + 1) % edges.Length];
            foreach (var point in points)
            {
                best = MathF.Min(best, PointSegmentDistance(point, start, end));
            }
        }
    }

    private static float PointSegmentDistance(Vector2 point, Vector2 start, Vector2 end)
    {
        var edge = end - start;
        var lengthSquared = edge.LengthSquared();
        if (lengthSquared < 1.0e-8f)
        {
            return point.DistanceTo(start);
        }
        var t = Math.Clamp((point - start).Dot(edge) / lengthSquared, 0.0f, 1.0f);
        return point.DistanceTo(start + edge * t);
    }

    private static bool PolygonsOverlap(Vector2[] left, Vector2[] right) =>
        !HasSeparatingAxis(left, right, left) && !HasSeparatingAxis(left, right, right);

    private static bool HasSeparatingAxis(Vector2[] left, Vector2[] right, Vector2[] edgeSource)
    {
        for (var i = 0; i < edgeSource.Length; i++)
        {
            var start = edgeSource[i];
            var end = edgeSource[(i + 1) % edgeSource.Length];
            var axis = new Vector2(-(end.Y - start.Y), end.X - start.X);
            var length = axis.Length();
            if (length < 1.0e-6f)
            {
                continue;
            }
            axis /= length;
            Project(left, axis, out var leftMin, out var leftMax);
            Project(right, axis, out var rightMin, out var rightMax);
            if (leftMax < rightMin || rightMax < leftMin)
            {
                return true;
            }
        }
        return false;
    }

    private static void Project(Vector2[] points, Vector2 axis, out float min, out float max)
    {
        min = float.PositiveInfinity;
        max = float.NegativeInfinity;
        foreach (var point in points)
        {
            var value = point.Dot(axis);
            min = MathF.Min(min, value);
            max = MathF.Max(max, value);
        }
    }

    private static float RectGap(Rect2 a, Rect2 b)
    {
        var dx = MathF.Max(0.0f, MathF.Max(a.Position.X - b.End.X, b.Position.X - a.End.X));
        var dz = MathF.Max(0.0f, MathF.Max(a.Position.Y - b.End.Y, b.Position.Y - a.End.Y));
        return MathF.Sqrt(dx * dx + dz * dz);
    }

    private readonly Dictionary<ulong, Rect2> _collisionBoundsCache = new();
    private long _collisionBoundsFrame = long.MinValue;

    /// <summary>读取节点下全部碰撞形状的世界 XZ 包围盒；没有形状时退回逻辑半径。</summary>
    private Rect2 CollisionBounds(Node3D node)
    {
        var frame = checked((long)Engine.GetPhysicsFrames());
        if (frame != _collisionBoundsFrame)
        {
            _collisionBoundsCache.Clear();
            _collisionBoundsFrame = frame;
        }
        var id = node.GetInstanceId();
        if (_collisionBoundsCache.TryGetValue(id, out var cached))
        {
            return cached;
        }
        var computed = ComputeCollisionBounds(node);
        _collisionBoundsCache[id] = computed;
        return computed;
    }

    /// <summary>
    /// 碰撞盒只取决于形状和全局变换。用引擎一次取出 CollisionShape3D，
    /// 避免为每个单位把整棵可视子树逐个跨回 C#。
    /// </summary>
    private static Rect2 ComputeCollisionBounds(Node3D node)
    {
        Rect2? result = null;
        foreach (var descendant in node.FindChildren("*", "CollisionShape3D", true, false))
        {
            if (descendant is not CollisionShape3D shapeNode || shapeNode.Shape is null)
            {
                continue;
            }

            if (ShapeBounds(shapeNode.Shape) is not (Vector3 Min, Vector3 Max) local)
            {
                continue;
            }

            foreach (var corner in BoundsCorners(local.Min, local.Max))
            {
                var world = shapeNode.GlobalTransform * corner;
                var point = new Vector2(world.X, world.Z);
                var next = new Rect2(point, Vector2.Zero);
                result = result is null ? next : result.Value.Merge(next);
            }
        }

        if (result is not null && result.Value.Size.X > 0.0f && result.Value.Size.Y > 0.0f)
        {
            return result.Value;
        }

        var fallback = Radius(node);
        return new Rect2(
            new Vector2(node.GlobalPosition.X - fallback, node.GlobalPosition.Z - fallback),
            Vector2.One * fallback * 2.0f);
    }

    private static IEnumerable<Node> Descendants(Node node)
    {
        foreach (var child in node.GetChildren())
        {
            yield return child;
            foreach (var descendant in Descendants(child))
            {
                yield return descendant;
            }
        }
    }

    private static (Vector3 Min, Vector3 Max)? ShapeBounds(Shape3D shape) => shape switch
    {
        CylinderShape3D cylinder => (
            new Vector3(-cylinder.Radius, -cylinder.Height * 0.5f, -cylinder.Radius),
            new Vector3(cylinder.Radius, cylinder.Height * 0.5f, cylinder.Radius)),
        SphereShape3D sphere => (
            Vector3.One * -sphere.Radius,
            Vector3.One * sphere.Radius),
        BoxShape3D box => (
            box.Size * -0.5f,
            box.Size * 0.5f),
        CapsuleShape3D capsule => (
            new Vector3(-capsule.Radius, -capsule.Height * 0.5f, -capsule.Radius),
            new Vector3(capsule.Radius, capsule.Height * 0.5f, capsule.Radius)),
        _ => null,
    };

    private static IEnumerable<Vector3> BoundsCorners(Vector3 min, Vector3 max)
    {
        yield return new Vector3(min.X, min.Y, min.Z);
        yield return new Vector3(max.X, min.Y, min.Z);
        yield return new Vector3(min.X, max.Y, min.Z);
        yield return new Vector3(max.X, max.Y, min.Z);
        yield return new Vector3(min.X, min.Y, max.Z);
        yield return new Vector3(max.X, min.Y, max.Z);
        yield return new Vector3(min.X, max.Y, max.Z);
        yield return new Vector3(max.X, max.Y, max.Z);
    }

    /// <summary>计算忽略高度的世界距离。</summary>
    private static float PlanarDistance(Vector3 left, Vector3 right) =>
        new Vector2(left.X - right.X, left.Z - right.Z).Length();

    /// <summary>把纯 C# 世界坐标转换为 Godot Vector3。</summary>
    private static Vector3 ToVector3(WorldPosition position) =>
        new(position.X, position.Y, position.Z);

    /// <summary>
    /// 枚举当前仍有效的玩家单位和建筑。
    /// 【性能·勿回退，用户 2026-09-15 批准】按物理帧缓存：一次放置评估会扫场 5~10 次
    /// （自己 + 视野揭示者 + 每个候选落点的占用检查），而每次 `GetNodesInGroup` 都要分配一个新数组；
    /// 一个 AI 每拍最多探 8 个候选落点，一局 3 个电脑时这是纯浪费。
    /// 同一物理帧内单位集合不变（`queue_free` 在帧末执行），仍过滤已释放对象兜底。
    /// </summary>
    private IEnumerable<Node3D> Units()
    {
        var frame = checked((long)Engine.GetPhysicsFrames());
        if (_unitsThisFrame is null || frame != _unitsFrame)
        {
            _unitsThisFrame = _match.GetTree().GetNodesInGroup("units").OfType<Node3D>().ToArray();
            _unitsFrame = frame;
        }
        return _unitsThisFrame.Where(GodotObject.IsInstanceValid);
    }

    /// <summary>
    /// 立即使本帧缓存失效（2026-09-23 修"电脑玩家造重叠建筑"）。
    ///
    /// 根因：`Units()` 按物理帧缓存"units"组快照。同一物理帧内**先**放置的建筑
    /// 落地入组后，缓存不会刷新 —— **后**一次放置的占用检查看不到它，两个建筑
    /// 落在同一位置也被判合法（实测：电脑玩家的经济/生产/防御三个控制器都是
    /// ~0.5s 定时器，同帧触发时必然复现）。
    /// 放置成功/失败后都应调用：让同帧的下一次评估看到最新世界。
    /// </summary>
    public void InvalidateCaches()
    {
        _unitsThisFrame = null;
        _unitsFrame = long.MinValue;
        _resourcesThisFrame = null;
        _resourcesFrame = long.MinValue;
        _collisionBoundsCache.Clear();
        _collisionBoundsFrame = long.MinValue;
        MutationCount++;
    }

    /// <summary>本帧单位组快照。放置成功后 <see cref="InvalidateCaches"/> 会清掉。</summary>
    internal IEnumerable<Node3D> CachedUnits() => Units();

    /// <summary>本帧资源组快照。放置成功后 <see cref="InvalidateCaches"/> 会清掉。</summary>
    internal IEnumerable<Node3D> CachedResources() => Resources();

    /// <summary>枚举当前仍有效的资源节点（按物理帧缓存，口径同 `Units()`）。</summary>
    private IEnumerable<Node3D> Resources()
    {
        var frame = checked((long)Engine.GetPhysicsFrames());
        if (_resourcesThisFrame is null || frame != _resourcesFrame)
        {
            _resourcesThisFrame = _match.GetTree().GetNodesInGroup("resource_units")
                .OfType<Node3D>().ToArray();
            _resourcesFrame = frame;
        }
        return _resourcesThisFrame.Where(GodotObject.IsInstanceValid);
    }

    private Node3D[]? _unitsThisFrame;
    private long _unitsFrame = -1;
    private readonly Dictionary<long, bool> _surfacePointCache = new();
    private readonly Dictionary<long, bool> _waterPointCache = new();
    private Node3D[]? _resourcesThisFrame;
    private long _resourcesFrame = -1;
}
