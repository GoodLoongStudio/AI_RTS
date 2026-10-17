using AI_RTS.Application.Construction;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Configuration;
using AI_RTS.Domain.Construction;
using AI_RTS.Domain.Economy;
using AI_RTS.GodotAdapter.Common;
using AI_RTS.GodotAdapter.Composition;
using AI_RTS.GodotAdapter.Configuration;
using AI_RTS.GodotAdapter.Economy;
using AI_RTS.GodotAdapter.Queries;
using Godot;
using System.Linq;

namespace AI_RTS.GodotAdapter.Construction;

/// <summary>向 Human、规则 AI 和未来 Agent 暴露同一建筑放置评估与提交入口。</summary>
public partial class StructurePlacementRuntime : Node
{
    private GodotStructurePlacementDefinitionRepository _definitions = null!;
    private BalanceConfigRuntime _configuration = null!;
    private EconomyRuntime _economy = null!;
    private CommandRuntime _commands = null!;
    private GodotStructurePlacementWorldPort _world = null!;
    private StructurePlacementService _service = null!;

    /// <summary>连接当前 Match 的资源账户、命令运行时和空间查询端口。</summary>
    public override void _Ready()
    {
        _economy = GetParent().GetNode<EconomyRuntime>("EconomyRuntime");
        _commands = GetParent().GetNode<CommandRuntime>("CommandRuntime");
        _configuration = GetParent().GetNode<BalanceConfigRuntime>("BalanceConfigRuntime");
        if (!_configuration.IsHealthy() || _commands.GetMeta("initialization_blocked", false).AsBool())
        {
            SetMeta("initialization_blocked", true);
            GD.PrintErr("[StructurePlacementRuntime] 配置/命令运行时不健康，跳过建筑放置服务装配");
            return;
        }
        _definitions = new GodotStructurePlacementDefinitionRepository(_configuration.Catalog);
        _world = new GodotStructurePlacementWorldPort(GetParent());
        _service = new StructurePlacementService(
            _definitions,
            new AllowRegisteredStructurePlacementAuthorization(),
            new GodotConstructionStatePort(_commands.Construction),
            _world,
            _economy.AccountService);
        StructurePlacementService.Timing = QueryPerfCounters.Enabled;
    }

    /// <summary>GDScript 预检入口：该玩家当前是否已有在建工地（"一次只能建造一个"）。</summary>
    public bool HasActiveConstructionSite(Node player) =>
        _commands.Construction.HasActiveConstructionSite(GodotStableIdentity.Player(player));

    /// <summary>只读评估蓝图，不扣资源、不生成建筑且不改变单位任务。</summary>
    public Godot.Collections.Dictionary Evaluate(
        Node player,
        PackedScene prototype,
        Transform3D transform,
        Godot.Collections.Dictionary _legacyConstructionCost)
    {
        var definitionId = EnsureDefinition(prototype).DefinitionId;
        var playerId = GodotStableIdentity.Player(player);
        _world.RegisterPlayer(playerId, player);
        _world.RegisterCandidateFootprint(definitionId.Value, prototype);
        return ToGodot(_service.Evaluate(Query(playerId, definitionId, transform)));
    }

    /// <summary>Bounds for candidate centers, including the selected building's footprint.</summary>
    public Rect2 BuildAreaBounds(Node player, PackedScene prototype)
    {
        var definition = EnsureDefinition(prototype);
        using var size = GetParent().GetNode("Map").Get("size");
        var mapBounds = new Rect2(Vector2.Zero, size.AsVector2());
        if (definition.DefinitionId.Value == "command_center")
        {
            return mapBounds;
        }
        if (definition.Placement.Footprint is not CirclePlacementFootprint footprint)
        {
            return new Rect2();
        }
        Rect2? bounds = null;
        foreach (var node in GetTree().GetNodesInGroup("units"))
        {
            if (node is not Node3D unit || unit.GetParent() != player ||
                unit.FindChild("MovementObstacle", false, false) is null)
            {
                continue;
            }
            using var radius = unit.Get("radius");
            var reach = radius.AsSingle() + footprint.Radius +
                GodotStructurePlacementWorldPort.BuildRangeMeters;
            var center = new Vector2(unit.GlobalPosition.X, unit.GlobalPosition.Z);
            var next = new Rect2(center - Vector2.One * reach, Vector2.One * reach * 2);
            bounds = bounds?.Merge(next) ?? next;
        }
        return bounds?.Intersection(mapBounds) ?? new Rect2();
    }

    /// <summary>Returns the authoritative build-range discs used by the ground preview.</summary>
    public Godot.Collections.Array<Godot.Collections.Dictionary> BuildAreaCircles(
        Node player, PackedScene prototype)
    {
        var construction = EnsureDefinition(prototype);
        var footprintRadius = PreviewFootprintRadius(construction.Placement.Footprint);
        var result = new Godot.Collections.Array<Godot.Collections.Dictionary>();
        if (footprintRadius <= 0.0f)
        {
            return result;
        }

        foreach (var node in GetTree().GetNodesInGroup("units"))
        {
            if (node is not Node3D unit || unit.GetParent() != player)
            {
                continue;
            }

            var obstacle = unit.FindChild("MovementObstacle", false, false);
            if (obstacle is null)
            {
                continue;
            }

            using var radius = unit.Get("radius");
            var reach = radius.AsSingle() + footprintRadius +
                GodotStructurePlacementWorldPort.BuildRangeMeters;
            result.Add(new Godot.Collections.Dictionary
            {
                ["center"] = new Vector2(unit.GlobalPosition.X, unit.GlobalPosition.Z),
                ["radius"] = reach,
            });
        }
        return result;
    }

    private static float PreviewFootprintRadius(StructurePlacementFootprint footprint) =>
        footprint switch
        {
            CirclePlacementFootprint circle => circle.Radius,
            BoxPlacementFootprint box => MathF.Sqrt(
                box.HalfWidth * box.HalfWidth + box.HalfDepth * box.HalfDepth),
            ConvexPlacementFootprint polygon => polygon.Vertices.Count == 0
                ? 0.0f
                : polygon.Vertices.Max(vertex =>
                    MathF.Sqrt(vertex.X * vertex.X + vertex.Z * vertex.Z)),
            _ => 0.0f,
        };

    /// <summary>按最新视野、空间和余额复验，成功后创建施工现场并驱逐重叠友军。</summary>
    public Godot.Collections.Dictionary Place(
        Node player,
        PackedScene prototype,
        Transform3D transform,
        Godot.Collections.Dictionary _legacyConstructionCost)
    {
        var construction = EnsureDefinition(prototype);
        var definitionId = construction.DefinitionId;
        var playerId = GodotStableIdentity.Player(player);
        _world.RegisterPlayer(playerId, player);
        _world.RegisterCandidateFootprint(definitionId.Value, prototype);
        var query = Query(playerId, definitionId, transform);
        var evalStarted = QueryPerfCounters.Enabled ? System.Diagnostics.Stopwatch.GetTimestamp() : 0L;
        var evaluation = _service.Evaluate(query);
        if (QueryPerfCounters.Enabled)
        {
            QueryPerfCounters.AddPlacementPhase(
                "place_eval", System.Diagnostics.Stopwatch.GetTimestamp() - evalStarted);
        }
        if (!evaluation.IsValid)
        {
            return ToGodot(evaluation);
        }

        var definition = construction.Placement;
        var world = _world.TryConsumeFresh(playerId, evaluation.Candidate, definition);
        if (world is null)
        {
            world = _world.EvaluateDetailed(playerId, evaluation.Candidate, definition);
            if (QueryPerfCounters.Enabled)
            {
                QueryPerfCounters.AddPlacementPhase("place_requery", 1);
            }
        }
        else if (QueryPerfCounters.Enabled)
        {
            QueryPerfCounters.AddPlacementPhase("place_reuse", 1);
        }
        var blockingIssues = world.Issues
            .Where(issue => issue != StructurePlacementIssue.BlocksPassage)
            .ToArray();
        if (blockingIssues.Length != 0)
        {
            return ToGodot(_service.Evaluate(query));
        }

        var instanceStarted = QueryPerfCounters.Enabled ? System.Diagnostics.Stopwatch.GetTimestamp() : 0L;
        var structure = prototype.Instantiate<Node3D>();
        if (QueryPerfCounters.Enabled)
        {
            QueryPerfCounters.AddPlacementPhase(
                "place_instance", System.Diagnostics.Stopwatch.GetTimestamp() - instanceStarted);
        }
        var displacedIds = new Godot.Collections.Array<string>();
        foreach (var unit in world.FriendlyDisplacements.Keys)
        {
            displacedIds.Add(GodotStableIdentity.Unit(unit).Value.ToString("D"));
        }
        structure.SetMeta("ai_rts_displaced_unit_ids", displacedIds);
        var constructionCost = ToGodotCosts(definition.ConstructionCost);
        var payStarted = QueryPerfCounters.Enabled ? System.Diagnostics.Stopwatch.GetTimestamp() : 0L;
        var paymentAccepted = definition.ConstructionCost.Count == 0 ||
            _economy.SubtractResources(
                player, constructionCost, "ConstructionCost", structure)["accepted"].AsBool();
        if (QueryPerfCounters.Enabled)
        {
            QueryPerfCounters.AddPlacementPhase(
                "place_pay", System.Diagnostics.Stopwatch.GetTimestamp() - payStarted);
        }
        if (!paymentAccepted)
        {
            structure.Free();
            return ToGodot(_service.Evaluate(query));
        }

        try
        {
            // 【2026-09-30 验证席实测：人类放置的建筑被放大 3 倍】调用方（蓝图 ghost）带着
            // **Visual 缩放**（建筑 3.0），评估只用 origin+yaw 所以判定正常，但这里把原始
            // transform 直接交给出生路径 ⇒ 落地 root scale=3、视觉 9 倍、车厂碰撞半径 19.95m
            // （应 6.65）。出生只应接受『世界位置 + 旋转』，缩放必须在此时剔除 ——
            // 美术缩放保留在场景自己的 Visual 分支里（世界米制归一化契约）。
            var spawnTransform = new Transform3D(transform.Basis.Orthonormalized(), transform.Origin);
            var spawnStarted = QueryPerfCounters.Enabled ? System.Diagnostics.Stopwatch.GetTimestamp() : 0L;
            GetParent().Call("_setup_and_spawn_unit", structure, spawnTransform, player, true);
            if (QueryPerfCounters.Enabled)
            {
                QueryPerfCounters.AddPlacementPhase(
                    "place_spawn", System.Diagnostics.Stopwatch.GetTimestamp() - spawnStarted);
            }
            var registerStarted = QueryPerfCounters.Enabled ? System.Diagnostics.Stopwatch.GetTimestamp() : 0L;
            if (!_commands.RegisterConstructionSite(structure, player, construction))
            {
                if (QueryPerfCounters.Enabled)
                {
                    QueryPerfCounters.AddPlacementPhase(
                        "place_register", System.Diagnostics.Stopwatch.GetTimestamp() - registerStarted);
                }
                throw new InvalidOperationException("无法注册权威施工现场。");
            }
            if (QueryPerfCounters.Enabled)
            {
                QueryPerfCounters.AddPlacementPhase(
                    "place_register", System.Diagnostics.Stopwatch.GetTimestamp() - registerStarted);
            }
            // 同帧缓存失效（2026-09-23 修重叠建筑）：新建筑已入 "units" 组，
            // 必须让同帧的下一次放置评估看得到它，否则电脑玩家多个控制器同帧
            // 触发时会把第二座建筑叠放到同一位置。
            _world.InvalidateCaches();
        }
        catch
        {
            if (definition.ConstructionCost.Count != 0)
            {
                _economy.AddResources(player, constructionCost, "ConstructionRefund", structure);
            }
            structure.QueueFree();
            throw;
        }

        foreach (var displacement in world.FriendlyDisplacements)
        {
            if (!_commands.DisplaceUnitForConstruction(
                displacement.Key, displacement.Value, player))
            {
                GD.PushError($"无法驱逐建筑 footprint 内的友军：{displacement.Key.Name}");
            }
        }

        return new Godot.Collections.Dictionary
        {
            ["accepted"] = true,
            ["status"] = "Accepted",
            ["primary_issue"] = string.Empty,
            ["issues"] = new Godot.Collections.Array<string>(),
            ["structure"] = structure,
            ["displaced_unit_ids"] = displacedIds
        };
    }

    /// <summary>把放置开始时捕获的 Worker 交给统一施工入口，并延后被驱逐者的任务。</summary>
    public void AssignBuilders(
        Godot.Collections.Array<Node> workers,
        Node structure,
        Node player,
        Godot.Collections.Array<string> displacedUnitIds)
    {
        _commands.AssignBuildersAfterPlacement(
            workers, structure, player, displacedUnitIds.ToHashSet());
    }

    /// <summary>
    /// 自动相邻放置（2026-09-23 用户口径"建筑自动相邻造"）：以己方基地或指定锚点为圆心，
    /// 由内到外逐环采样，返回第一个通过完整放置评估的落点；找不到返回 null（调用方按
    /// NoValidSite 拒绝，**绝不臆造坐标**）。
    ///
    /// 为什么放在权威端：落点可行性的事实（界内/视野/可建/占用）全在 Godot 侧，
    /// 副官不再需要自己算坐标 —— 它只发"建什么"，游戏负责"建哪"。这把副官侧整套
    /// 候选生成、拒绝分类账本、按类退避都降级成兜底（见 adjutant placement.py）。
    ///
    /// mode：
    /// - "base"：锚点 = 距己方现有建筑最近的点（默认贴着基地往外圈找）；
    /// - "resource"：锚点 = 距己方建筑最远的**已探明**矿点（分基地/矿场的扩张语义），
    ///   在其周围小半径内找合法落点；
    /// - "hint"：锚点 = hint 本身，**跳过全局邻接层**，只在 hint 周围 maxRadiusMeters
    ///   内环搜。给调用方自带战术候选生成器时用（防御塔的反扎堆选带：先按
    ///   "离已有塔远、在防御带内"挑方位，再让权威端在该方位附近解出合法邻接落点）；
    /// - hint 非空且 mode 不是 "hint"：锚点 = hint，但仍享受全局邻接层
    ///   （经济建筑"围着这个中心建"的语义）。
    /// </summary>
    /// <returns>{"found": bool, "pos": Vector3（含地表高度）, "reason": string}；
    /// 找不到 found=false；因全局性拒绝（施工中/未授权/校验不可用）提前终止时
    /// reason = 对应 issue 名 —— 调用方应按"等待"处理而不是"没地方建"。</returns>
    /// hint 传 Vector3.INF 表示"无锚点偏好"（GDScript 侧字面量即可，避免可空/可选参数
    /// 导致源码生成器不注册——实测 `has_method` 走反射能看到、GDScript 调用却报
    /// Nonexistent，两者表不一样）。
    /// <summary>建造范围（世界米）：供 HUD 画建造范围圈，与放置判据同源。</summary>
    public float BuildRangeMeters() => GodotStructurePlacementWorldPort.BuildRangeMeters;

    /// <summary>窄缝导航断开阈值（米）。与放置端口常量同源，供穿模通行证读取。</summary>
    public float StructureSealGapMeters() => GodotStructurePlacementWorldPort.StructureSealGapMeters;

    /// <summary>最宽地面单位不必穿模的表面间隙（米）。与放置端口常量同源。</summary>
    public float StructurePassGapMeters() => GodotStructurePlacementWorldPort.StructurePassGapMeters;

    public Godot.Collections.Dictionary FindAutoSpot(
        Node player,
        PackedScene prototype,
        string mode,
        Vector3 hint,
        float maxRadiusMeters)
    {
        var perfStarted = QueryPerfCounters.Enabled ? System.Diagnostics.Stopwatch.GetTimestamp() : 0L;
        var reply = FindAutoSpotInstrumented(player, prototype, mode, hint, maxRadiusMeters);
        if (QueryPerfCounters.Enabled)
        {
            var found = reply is Godot.Collections.Dictionary dictionary &&
                dictionary.GetValueOrDefault("found").AsBool();
            QueryPerfCounters.AddPlacement(
                System.Diagnostics.Stopwatch.GetTimestamp() - perfStarted, found);
        }
        return reply;
    }

    private Godot.Collections.Dictionary FindAutoSpotInstrumented(
        Node player,
        PackedScene prototype,
        string mode,
        Vector3 hint,
        float maxRadiusMeters)
    {
        var perf = QueryPerfCounters.Enabled;
        var mark = perf ? System.Diagnostics.Stopwatch.GetTimestamp() : 0L;
        void Mark(string phase)
        {
            if (!perf)
            {
                return;
            }
            var now = System.Diagnostics.Stopwatch.GetTimestamp();
            QueryPerfCounters.AddPlacementPhase(phase, now - mark);
            mark = now;
        }

        var construction = EnsureDefinition(prototype);
        var definitionId = construction.DefinitionId;
        var playerId = GodotStableIdentity.Player(player);
        _world.RegisterPlayer(playerId, player);
        _world.RegisterCandidateFootprint(definitionId.Value, prototype);
        if (construction.Placement.Footprint is not CirclePlacementFootprint footprint)
        {
            Mark("precheck");
            return AutoSpotResult(false, Vector3.Zero, StructurePlacementIssue.ValidationUnavailable.ToString());
        }

        var radius = MathF.Max(footprint.Radius, 0.5f);
        var hintPoint = hint.IsFinite() ? (Vector3?)hint : null;
        if (ResolveAutoAnchor(player, mode, hintPoint, definitionId.Value) is not Vector3 anchor)
        {
            GD.Print($"[AUTOSPOT] no anchor mode={mode} ownStructures={OwnStructures(player).Count()}");
            Mark("resolve_anchor");
            return AutoSpotResult(false, Vector3.Zero);
        }
        Mark("resolve_anchor");
        GD.Print($"[AUTOSPOT] mode={mode} anchor=({anchor.X:F1},{anchor.Z:F1}) radius={radius}");

        var limit = maxRadiusMeters > 0.01f
            ? maxRadiusMeters
        // 【2026-09-30 用户口径「矿场要真的能采到矿」】资源模式的搜索上限必须覆盖
        // 『洞外 + 相邻己方建筑』这条环带：矿场的合法位置同时要求
        //   ① 距要服务的矿 >= carve 净空（footprint 9.8 + agent 2.8 + 0.75 ≈ 13.35m）
        //   ② 距己方建筑 <= 建造网络窗口（候选/锚点 footprint 之外再留 BuildRangeMeters）
        // 旧上限 14m 只够贴脸放置 ⇒ 锚点矿必然被自己的洞吞掉（AI 建矿场=白建）。
        // 放到 32m（≈ 矿场服务半径 30m）：远处样本被视野拒绝时会照常跳过，不是错误。
            : (string.Equals(mode, "resource", StringComparison.Ordinal) ? 32f : 30f);
        // 资源模式（矿场/分基地）起始环略外扩：贴脸矿点放置时，工人站位会落进
        // 建筑避让圈与矿点之间的夹缝，被每帧推回 → 原地抖（2026-09-23 实测）。
        // 不能再大：远端矿点只有工人视野（5m+2m 补偿），环外扩太多会整体
        // 落在视野外（NotVisible）→ 一个点都搜不到。
        // 【2026-09-30 用户口径「矿场要真的能采到矿」】资源模式的锚点 = 要服务的那颗矿点，
        // 而矿场自己的 carve 洞 = footprint + navmesh.agent_radius（9.8 + 2.8 = 12.6m）。
        // 旧实现起始环 = radius + 2.0 = 11.8m ⇒ **锚点矿必然落在自己的洞里**：工人只能站到
        // 洞边缘，到矿点还差约 6.1m > 采集贴合阈值 ⇒ AI 建的矿场永远采不到矿（经济不转）。
        // 修法：资源模式的最近落点必须让锚点矿留在 carve 洞之外（radius + agent + 0.75 余量）。
        // hint 模式：从锚点**本体**开始 0.75m 细环外扩 —— 调用方的候选方位可能
        // 落在合法带的任一侧（Occupied 侧 0.7m 内也有带），起始环大了会整片跳过。
        var agentRadius = _world.CachedAgentRadiusMeters;
        Mark("agent_radius");
        var carveClearance = radius + agentRadius
            + GodotStructurePlacementWorldPort.EdgeClearanceMeters;
        var firstRing = string.Equals(mode, "hint", StringComparison.Ordinal)
            ? GodotStructurePlacementWorldPort.EdgeClearanceMeters * 0.5f
            : string.Equals(mode, "resource", StringComparison.Ordinal)
                ? MathF.Max(radius + 2.0f, carveClearance)
                : radius + 1.5f;
        // 【2026-09-30 用户报 / AI 实测：贴基地的炮塔自动选址永远失败】
        // 环步长需要足够细，避免采样相位跳过可建地形；旧实现固定 2.0m 步长，
        // 在基地边缘的窄地形带上曾出现整圈 NotAdjacent。现在建造网络范围是
        // BuildRangeMeters，步长只负责搜索密度，不再把合法区间错误地当成 0.75m 窄带。
        var ringStep = MathF.Max(0.5f, MathF.Min(2.0f, GodotStructurePlacementWorldPort.EdgeClearanceMeters));
        // 每环角数按弧长自适应（目标弧距 1.2m，下限 12、上限 32），保证地形采样稳定。
        // 环数必须由 limit 推出：不能因为步长变小而把搜索半径截断在基地脚下。
        var maxRings = Math.Clamp((int)MathF.Ceiling((MathF.Min(limit, 48f) - firstRing) / ringStep) + 1, 1, 64);
        if (HasActiveConstructionSite(player))
        {
            Mark("anchor");
            return AutoSpotResult(false, Vector3.Zero, StructurePlacementIssue.ConstructionInProgress.ToString());
        }
        Mark("anchor");
        var evaluations = 0;
        // 【为什么要有这个计数】资源模式连续 6 次返回 `NoValidSite` 时，上层只有一句
        // "找不到合法落点"，而"锚点没探明 / 视野不够 / 地面被占 / 贴太近"四种断点的
        // 修法完全不同。没有 Issue 分布就只能靠读注释猜（本轮就是这么绕了一圈）。
        var issueMix = new Dictionary<StructurePlacementIssue, int>();
        var rankedStarted = perf ? System.Diagnostics.Stopwatch.GetTimestamp() : 0L;
        var ranked = BuildRankedCandidates(
            player, mode, definitionId.Value, anchor, radius, limit, carveClearance, firstRing, ringStep, maxRings);
        if (perf)
        {
            QueryPerfCounters.AddPlacementPhase(
                "ranked_build", System.Diagnostics.Stopwatch.GetTimestamp() - rankedStarted);
        }
        foreach (var candidate in ranked)
        {
            evaluations++;
            var evalStarted = perf ? System.Diagnostics.Stopwatch.GetTimestamp() : 0L;
            var evaluation = _service.Evaluate(Query(playerId, definitionId,
                new Transform3D(Basis.Identity, candidate.Position)));
            if (perf)
            {
                QueryPerfCounters.NoteEvaluateOne(System.Diagnostics.Stopwatch.GetTimestamp() - evalStarted);
            }
            if (evaluation.IsValid || (evaluation.Issues.Count == 1 &&
                evaluation.Issues[0] == StructurePlacementIssue.InsufficientResources))
            {
                Mark("evaluate");
                var found = SampleGroundHeight(candidate.Position);
                Mark("ground");
                GD.Print($"[AUTOSPOT] FOUND-SPREAD ({found.X:F1},{found.Y:F1},{found.Z:F1}) evaluations={evaluations}");
                return AutoSpotResult(true, found);
            }
            if (evaluation.Issues.Count == 1 && IsGlobalIssue(evaluation.Issues[0]))
            {
                Mark("evaluate");
                return AutoSpotResult(false, Vector3.Zero, evaluation.Issues[0].ToString());
            }
            foreach (var issue in evaluation.Issues)
                issueMix[issue] = issueMix.GetValueOrDefault(issue) + 1;
        }
        Mark("evaluate");
        LogAutoSpotFailure(player, mode, anchor, limit, evaluations, issueMix, "exhausted");
        Mark("failure_log");
        return AutoSpotResult(false, Vector3.Zero);
    }

    /// <summary>
    /// 与同步 FindAutoSpot 相同的候选生成和评分次序。返回已按分数降序截断的列表。
    /// </summary>
    private List<(Vector3 Position, float Score)> BuildRankedCandidates(
        Node player,
        string mode,
        string definitionId,
        Vector3 anchor,
        float radius,
        float limit,
        float carveClearance,
        float firstRing,
        float ringStep,
        int maxRings)
    {
        var cursor = new RankCursor();
        AppendRanked(
            cursor, player, mode, definitionId, anchor, radius, limit,
            carveClearance, firstRing, ringStep, maxRings, long.MaxValue);
        return cursor.Candidates.OrderByDescending(item => item.Score).Take(256).ToList();
    }

    /// <summary>
    /// 分批记下己方建筑、矿点、矿场通道和 16 座最近建筑。
    /// 预算用完返回 false，游标留在下一栋还没读的节点；全部记完才标记 Snapshotted。
    /// 同步选址的 deadline 是 long.MaxValue，仍一次做完。排序只在记完之后发生。
    /// </summary>
    private bool EnsureRankSnapshot(
        RankCursor cursor, Node player, string mode, Vector3 anchor, long deadline)
    {
        bool Expired() => System.Diagnostics.Stopwatch.GetTimestamp() >= deadline;
        if (cursor.GatherPhase == 0)
        {
            cursor.SourceUnits = _world.CachedUnits().ToArray();
            cursor.GatherOwn = new();
            cursor.GatherIndex = 0;
            cursor.GatherPhase = 1;
            if (Expired())
            {
                return false;
            }
        }

        if (cursor.GatherPhase == 1)
        {
            var source = cursor.SourceUnits ?? [];
            var own = cursor.GatherOwn ??= new();
            for (; cursor.GatherIndex < source.Length; cursor.GatherIndex++)
            {
                if (Expired())
                {
                    return false;
                }
                var node = source[cursor.GatherIndex];
                if (!GodotObject.IsInstanceValid(node) || node.GetParent() != player ||
                    !node.HasMeta("placement_anchor_structure"))
                {
                    continue;
                }
                using var type = node.Get("unit_type_id");
                var production = node.FindChild("ProductionQueue", false, false) != null;
                var facing = node.GlobalTransform.Basis.Z;
                facing.Y = 0;
                own.Add((node.GlobalPosition, GodotStructurePlacementWorldPort.RadiusOf(node),
                    type.AsString(), production,
                    facing.LengthSquared() > 0.001f ? facing.Normalized() : Vector3.Back));
            }
            cursor.Own = own.ToArray();
            cursor.SourceUnits = null;
            cursor.GatherOwn = null;
            cursor.GatherIndex = 0;
            cursor.GatherPhase = 2;
            if (Expired())
            {
                return false;
            }
        }

        if (cursor.GatherPhase == 2)
        {
            cursor.SourceResources ??= _world.CachedResources().ToArray();
            var positions = cursor.GatherResourcePositions ??= new();
            var resources = cursor.SourceResources;
            for (; cursor.GatherIndex < resources.Length; cursor.GatherIndex++)
            {
                if (Expired())
                {
                    return false;
                }
                var resource = resources[cursor.GatherIndex];
                if (!GodotObject.IsInstanceValid(resource) || IsDepleted(resource))
                {
                    continue;
                }
                positions.Add(resource.GlobalPosition);
            }
            cursor.Resources = positions.ToArray();
            cursor.SourceResources = null;
            cursor.GatherResourcePositions = null;
            cursor.GatherIndex = 0;
            cursor.GatherPhase = 3;
            if (Expired())
            {
                return false;
            }
        }

        if (cursor.GatherPhase == 3)
        {
            var routes = cursor.RouteList ??= new();
            for (; cursor.GatherIndex < cursor.Own.Length; cursor.GatherIndex++)
            {
                if (Expired())
                {
                    return false;
                }
                var own = cursor.Own[cursor.GatherIndex];
                if (own.Type != "ore_refinery")
                {
                    continue;
                }
                AppendTwoNearestRoutes(routes, own.Position, cursor.Resources);
            }
            if (Expired())
            {
                return false;
            }
            var passage = GodotStructurePlacementWorldPort.StructurePassGapMeters;
            cursor.Routes = routes.ToArray();
            cursor.RouteList = null;
            cursor.Gaps = [passage + 2f, passage + 0.2f, 10f];
            cursor.Ordered = NearestOwned(cursor.Own, anchor, 16);
            if (mode == "hint")
            {
                cursor.GapIndex = cursor.Gaps.Length;
            }
            cursor.GatherIndex = 0;
            cursor.GatherPhase = 4;
            cursor.Snapshotted = true;
        }

        return cursor.Snapshotted;
    }

    /// <summary>
    /// 保留距矿场最近的两颗矿。距离相等时下标更小的在前，与稳定 OrderBy().Take(2) 相同。
    /// </summary>
    private static void AppendTwoNearestRoutes(
        List<(Vector3 Start, Vector3 End)> routes, Vector3 origin, Vector3[] resources)
    {
        var nearest = -1;
        var second = -1;
        var nearestDistance = 0f;
        var secondDistance = 0f;
        for (var index = 0; index < resources.Length; index++)
        {
            var distance = PlanarDistance(resources[index], origin);
            if (nearest < 0 || distance < nearestDistance)
            {
                second = nearest;
                secondDistance = nearestDistance;
                nearest = index;
                nearestDistance = distance;
            }
            else if (second < 0 || distance < secondDistance)
            {
                second = index;
                secondDistance = distance;
            }
        }
        if (nearest >= 0)
        {
            routes.Add((origin, resources[nearest]));
        }
        if (second >= 0)
        {
            routes.Add((origin, resources[second]));
        }
    }

    /// <summary>
    /// 取距锚点最近的若干座己方建筑。距离相等时保留更早出现的一座，与稳定 OrderBy().Take 相同。
    /// </summary>
    private static (Vector3 Position, float Radius, string Type, bool Production, Vector3 Facing)[] NearestOwned(
        (Vector3 Position, float Radius, string Type, bool Production, Vector3 Facing)[] own,
        Vector3 anchor, int take)
    {
        if (take <= 0 || own.Length == 0)
        {
            return [];
        }
        var chosen = new List<int>(Math.Min(take, own.Length));
        for (var index = 0; index < own.Length; index++)
        {
            var distance = PlanarDistance(own[index].Position, anchor);
            var insertAt = chosen.Count;
            for (var other = 0; other < chosen.Count; other++)
            {
                if (distance < PlanarDistance(own[chosen[other]].Position, anchor))
                {
                    insertAt = other;
                    break;
                }
            }
            if (insertAt >= take)
            {
                continue;
            }
            chosen.Insert(insertAt, index);
            if (chosen.Count > take)
            {
                chosen.RemoveAt(chosen.Count - 1);
            }
        }
        var ordered = new (Vector3 Position, float Radius, string Type, bool Production, Vector3 Facing)[chosen.Count];
        for (var index = 0; index < chosen.Count; index++)
        {
            ordered[index] = own[chosen[index]];
        }
        return ordered;
    }

    /// <summary>
    /// 继续生成候选。返回 false 表示本帧预算用完，游标已保存，下次从同一点继续。
    /// 全部生成完才返回 true。同步调用传入 long.MaxValue，一次跑完。
    /// </summary>
    private bool AppendRanked(
        RankCursor cursor,
        Node player,
        string mode,
        string definitionId,
        Vector3 anchor,
        float radius,
        float limit,
        float carveClearance,
        float firstRing,
        float ringStep,
        int maxRings,
        long deadline)
    {
        if (!cursor.Snapshotted)
        {
            var gatherStarted = QueryPerfCounters.Enabled ? System.Diagnostics.Stopwatch.GetTimestamp() : 0L;
            var gathered = EnsureRankSnapshot(cursor, player, mode, anchor, deadline);
            if (QueryPerfCounters.Enabled)
            {
                QueryPerfCounters.AddPlacementPhase(
                    "ranked_gather", System.Diagnostics.Stopwatch.GetTimestamp() - gatherStarted);
            }
            if (!gathered || System.Diagnostics.Stopwatch.GetTimestamp() >= deadline)
            {
                return false;
            }
        }

        var ownStructures = cursor.Own;
        var resources = cursor.Resources;
        var miningRoutes = cursor.Routes;
        var passage = GodotStructurePlacementWorldPort.StructurePassGapMeters;
        var localMode = mode is "hint" or "resource";
        var loopsStarted = QueryPerfCounters.Enabled ? System.Diagnostics.Stopwatch.GetTimestamp() : 0L;
        bool Expired() => System.Diagnostics.Stopwatch.GetTimestamp() >= deadline;
        bool BlocksRefineryApproach(Vector3 spot)
        {
            if (definitionId != "ore_refinery" || resources.Length == 0)
            {
                return false;
            }
            var nearest = -1;
            var second = -1;
            var nearestDistance = 0f;
            var secondDistance = 0f;
            for (var index = 0; index < resources.Length; index++)
            {
                var distance = PlanarDistance(resources[index], spot);
                if (nearest < 0 || distance < nearestDistance)
                {
                    second = nearest;
                    secondDistance = nearestDistance;
                    nearest = index;
                    nearestDistance = distance;
                }
                else if (second < 0 || distance < secondDistance)
                {
                    second = index;
                    secondDistance = distance;
                }
            }
            var gap = passage * 0.5f;
            bool CorridorClear(Vector3 resource)
            {
                foreach (var own in ownStructures)
                {
                    if (DistanceToSegment(own.Position, spot, resource) < own.Radius + gap)
                    {
                        return false;
                    }
                }
                return true;
            }
            if (CorridorClear(resources[nearest]))
            {
                return false;
            }
            return second < 0 || !CorridorClear(resources[second]);
        }

        void Add(Vector3 spot)
        {
            if (++cursor.Attempts > 1536 || cursor.Candidates.Count >= 768 ||
                !cursor.Keys.Add(((int)MathF.Round(spot.X * 10), (int)MathF.Round(spot.Z * 10))))
                return;
            var anchorDistance = PlanarDistance(spot, anchor);
            if (localMode && anchorDistance > limit) return;
            if (mode == "resource" && anchorDistance < carveClearance) return;
            if (resources.Any(resource => PlanarDistance(spot, resource) < radius + passage)) return;
            if (definitionId != "command_center" && !ownStructures.Any(own =>
                PlanarDistance(spot, own.Position) <= radius + own.Radius +
                    GodotStructurePlacementWorldPort.BuildRangeMeters)) return;
            if (definitionId == "ore_refinery" && mode == "resource" && !resources.Any(resource =>
                PlanarDistance(spot, resource) >= carveClearance &&
                PlanarDistance(resource, anchor) <= limit)) return;
            var clearance = ownStructures.Length == 0 ? passage + 2 : ownStructures.Min(own =>
                PlanarDistance(spot, own.Position) - own.Radius - radius);
            if (clearance < passage + 0.1f) return;
            if (definitionId == "command_center" && mode == "resource" && ownStructures.Any(own =>
                own.Type == "command_center" && PlanarDistance(spot, own.Position) < 30f)) return;
            foreach (var own in ownStructures)
            {
                if (own.Production)
                {
                    if (DistanceToSegment(spot,
                        own.Position, own.Position + own.Facing * (own.Radius + passage * 2))
                        < radius + passage * 0.5f) return;
                }
            }
            if (miningRoutes.Any(route => DistanceToSegment(spot, route.Start, route.End)
                < radius + passage * 0.5f)) return;
            if (BlocksRefineryApproach(spot)) return;
            var score = MathF.Min(clearance, passage + 3f) * 4 - anchorDistance * 0.35f;
            if (mode == "resource") score -= anchorDistance * 0.5f;
            cursor.Candidates.Add((spot, score));
        }

        while (cursor.GapIndex < cursor.Gaps.Length)
        {
            while (cursor.OwnIndex < cursor.Ordered.Length)
            {
                var own = cursor.Ordered[cursor.OwnIndex];
                var target = own.Radius + radius + cursor.Gaps[cursor.GapIndex];
                while (cursor.GapStep < 16)
                {
                    if (Expired())
                    {
                        NoteRankedLoops(loopsStarted);
                        return false;
                    }
                    if (cursor.Attempts >= 1536 || cursor.Candidates.Count >= 768)
                    {
                        cursor.GapStep = 16;
                        break;
                    }
                    var angle = MathF.Tau * cursor.GapStep / 16;
                    Add(new Vector3(own.Position.X + MathF.Cos(angle) * target, 0,
                        own.Position.Z + MathF.Sin(angle) * target));
                    cursor.GapStep++;
                }
                cursor.GapStep = 0;
                cursor.OwnIndex++;
            }
            cursor.OwnIndex = 0;
            cursor.GapIndex++;
        }

        while (cursor.Ring < maxRings)
        {
            var distance = firstRing + cursor.Ring * ringStep;
            if (distance > limit || cursor.Attempts >= 1536 || cursor.Candidates.Count >= 768)
            {
                cursor.Ring = maxRings;
                break;
            }
            while (cursor.Step < 16)
            {
                if (Expired())
                {
                    NoteRankedLoops(loopsStarted);
                    return false;
                }
                if (cursor.Attempts >= 1536 || cursor.Candidates.Count >= 768)
                {
                    cursor.Step = 16;
                    break;
                }
                var angle = 2.399963229728653f * (cursor.Ring * 16 + cursor.Step);
                Add(new Vector3(anchor.X + MathF.Cos(angle) * distance, 0,
                    anchor.Z + MathF.Sin(angle) * distance));
                cursor.Step++;
            }
            cursor.Step = 0;
            cursor.Ring++;
        }

        NoteRankedLoops(loopsStarted);
        return true;
    }

    private static void NoteRankedLoops(long loopsStarted)
    {
        if (!QueryPerfCounters.Enabled)
        {
            return;
        }
        QueryPerfCounters.AddPlacementPhase(
            "ranked_loops", System.Diagnostics.Stopwatch.GetTimestamp() - loopsStarted);
    }


    private static float DistanceToSegment(Vector3 point, Vector3 start, Vector3 end)
    {
        point.Y = start.Y = end.Y = 0;
        var segment = end - start;
        var t = segment.LengthSquared() < 0.001f ? 0 :
            Math.Clamp((point - start).Dot(segment) / segment.LengthSquared(), 0, 1);
        return (point - (start + segment * t)).Length();
    }

    /// <summary>自动选址失败的断点分布（只打印，不改变任何判定）。</summary>
    private void LogAutoSpotFailure(
        Node player, string mode, Vector3 anchor, float limit, int evaluations,
        Dictionary<StructurePlacementIssue, int> issueMix, string why)
    {
        var mix = issueMix.Count == 0
            ? "none"
            : string.Join(", ", issueMix.OrderByDescending(pair => pair.Value)
                .Select(pair => $"{pair.Key}×{pair.Value}"));
        GD.Print($"[AUTOSPOT] FAIL mode={mode} anchor=({anchor.X:F1},{anchor.Z:F1}) " +
                 $"limit={limit:F1} evaluations={evaluations} stop={why} issues={mix}");
    }

    /// <summary>自动放置结果字面量（GDScript 侧只认 Dictionary）。
    /// reason：提前终止原因（全局性拒绝的 issue 名，如 ConstructionInProgress），
    /// 找到落点或"搜完确实没有"时为空串 —— 调用方据此区分"没地方建"与"现在不能建"。</summary>
    private static Godot.Collections.Dictionary AutoSpotResult(bool found, Vector3 pos, string reason = "") =>
        new()
        {
            ["found"] = found,
            ["pos"] = pos,
            ["reason"] = reason,
        };

    /// <summary>
    /// 全局性放置拒绝：与候选坐标无关，第一个候选命中就等于全部候选命中，
    /// 继续环采样只是烧预算（实测施工期间 257 次评估 256 次 ConstructionInProgress）。
    /// NotAuthorized/ValidationUnavailable 同理（按 玩家×建筑定义 / 系统状态 判定）。
    /// </summary>
    private static bool IsGlobalIssue(StructurePlacementIssue issue) =>
        issue is StructurePlacementIssue.ConstructionInProgress
            or StructurePlacementIssue.NotAuthorized
            or StructurePlacementIssue.ValidationUnavailable;

    /// <summary>按模式解析自动放置锚点；解析不到（没有己方建筑/没有矿点）返回 null。</summary>
    private Vector3? ResolveAutoAnchor(Node player, string mode, Vector3? hint, string definitionId)
    {
        if (hint is Vector3 explicitAnchor && explicitAnchor.IsFinite())
        {
            return explicitAnchor;
        }

        var ownStructures = OwnStructures(player).ToArray();
        if (string.Equals(mode, "resource", StringComparison.Ordinal))
        {
            // 扩张语义：距己方任意建筑 >= ExpansionMinBaseDistanceM 的**最近**矿点
            // （先占最近的新矿，不一路飞到地图角落开两线作战）。
            var resources = GetTree()
                .GetNodesInGroup("resource_units")
                .OfType<Node3D>()
                .Where(resource => !IsDepleted(resource))
                .ToArray();
            if (resources.Length == 0)
            {
                return null;
            }

            var home = ownStructures.FirstOrDefault()?.GlobalPosition ??
                FallbackAnchor(player);
            Vector3? best = null;
            var bestScore = float.MaxValue;
            foreach (var resource in resources)
            {
                var toNearestStructure = ownStructures.Length == 0
                    ? 0f
                    : ownStructures.Min(structure =>
                        PlanarDistance(structure.GlobalPosition, resource.GlobalPosition));
                if (definitionId == "command_center" && toNearestStructure < ExpansionMinBaseDistanceM)
                {
                    continue; // 已有建筑在服的矿点不算"新矿"
                }

                var score = PlanarDistance(home, resource.GlobalPosition);
                if (score < bestScore)
                {
                    bestScore = score;
                    best = resource.GlobalPosition;
                }
            }

            if (definitionId == "command_center") return best;
            return best ?? resources
                .OrderBy(resource => PlanarDistance(home, resource.GlobalPosition))
                .First().GlobalPosition;
        }

        // base 模式：贴最近的一座己方建筑；没有建筑时退回任意己方单位（开局 CC 一定在）。
        if (ownStructures.Length > 0)
        {
            var first = ownStructures[0].GlobalPosition;
            return ownStructures
                .OrderBy(structure => PlanarDistance(first, structure.GlobalPosition))
                .First().GlobalPosition;
        }

        var anyOwn = GetTree().GetNodesInGroup("units")
            .OfType<Node3D>()
            .FirstOrDefault(unit => unit.GetParent() == player);
        return anyOwn?.GlobalPosition ?? FallbackAnchor(player);
    }

    /// <summary>己方玩家名下的建筑（带 MovementObstacle 的 units 组成员）。</summary>
    private IEnumerable<Node3D> OwnStructures(Node player) =>
        _world.CachedUnits().Where(unit => unit.GetParent() == player &&
            unit.HasMeta("placement_anchor_structure"));

    /// <summary>没有己方建筑时的兜底锚点（玩家节点原点附近）。</summary>
    private static Vector3 FallbackAnchor(Node player) =>
        player is Node3D player3D ? player3D.GlobalPosition : Vector3.Zero;

    /// <summary>矿点是否已采空（resource_a/b 均为 0 视为枯竭）。</summary>
    private static bool IsDepleted(Node3D resource)
    {
        var a = resource.Get("resource_a");
        var b = resource.Get("resource_b");
        return (a.VariantType != Variant.Type.Nil && a.AsInt32() <= 0)
            && (b.VariantType != Variant.Type.Nil && b.AsInt32() <= 0);
    }

    /// <summary>平面（XZ）距离，与放置评估的判据同口径。</summary>
    private static float PlanarDistance(Vector3 a, Vector3 b) =>
        new Vector2(a.X, a.Z).DistanceTo(new Vector2(b.X, b.Z));

    /// <summary>取候选点的真实地表高度（生成图高度场/普通图射线），失败退回 0。</summary>
    private Vector3 SampleGroundHeight(Vector3 spot)
    {
        var match = GetParent();
        if (match != null && match.HasMethod("_sample_generated_height"))
        {
            var sampled = match.Call("_sample_generated_height", spot);
            if (sampled.VariantType == Variant.Type.Float || sampled.VariantType == Variant.Type.Int)
            {
                return new Vector3(spot.X, sampled.AsSingle(), spot.Z);
            }
        }

        return new Vector3(spot.X, 0f, spot.Z);
    }

    /// <summary>“新矿点”判定：距己方任意建筑至少这么远（贴着基地的矿不算扩张目标）。</summary>
    private const float ExpansionMinBaseDistanceM = 18.0f;

    /// <summary>按受信任 asset manifest 查询已经完整校验的施工定义。</summary>
    private StructureConstructionDefinition EnsureDefinition(PackedScene prototype)
    {
        return _configuration.FindConstruction(prototype) ??
            throw new InvalidOperationException(
                $"场景 {prototype.ResourcePath} 没有受信任的施工定义。");
    }

    /// <summary>建立使用当前 Match、玩家和 Godot Transform 的只读查询。</summary>
    private EvaluateStructurePlacementQuery Query(
        PlayerId playerId,
        StructureDefinitionId definitionId,
        Transform3D transform)
    {
        var position = transform.Origin;
        return new EvaluateStructurePlacementQuery(
            _economy.MatchId,
            playerId,
            new StructurePlacementCandidate(
                definitionId,
                new WorldPosition(position.X, position.Y, position.Z),
                transform.Basis.GetEuler().Y));
    }

    /// <summary>把强类型成本转换为迁移期经济 Gateway 接受的只读字典副本。</summary>
    private static Godot.Collections.Dictionary ToGodotCosts(
        IEnumerable<ResourceAmount> costs)
    {
        var result = new Godot.Collections.Dictionary();
        foreach (var cost in costs)
        {
            var key = cost.Kind switch
            {
                ResourceKind.A => "resource_a",
                ResourceKind.B => "resource_b",
                _ => throw new InvalidOperationException($"未知建筑资源类型：{cost.Kind}")
            };
            result[key] = cost.Amount;
        }
        return result;
    }

    /// <summary>把稳定评估转换为 GDScript 可读取的字段集合。</summary>
    private static Godot.Collections.Dictionary ToGodot(StructurePlacementEvaluation evaluation)
    {
        var issues = new Godot.Collections.Array<string>();
        foreach (var issue in evaluation.Issues)
        {
            issues.Add(issue.ToString());
        }
        return new Godot.Collections.Dictionary
        {
            ["accepted"] = evaluation.IsValid,
            ["status"] = evaluation.IsValid ? "Accepted" : "Rejected",
            ["primary_issue"] = evaluation.PrimaryIssue?.ToString() ?? string.Empty,
            ["issues"] = issues,
            ["account_version"] = evaluation.ObservedAccountVersion ?? -1
        };
    }

    /// <summary>
    /// 把权威施工服务的"该玩家是否已有在建工地"包装成放置评估端口。
    /// 内存内单 Match：MatchId 只用于满足接口签名，不参与判定。
    /// </summary>
    private sealed class GodotConstructionStatePort(
        IConstructionService construction) : IStructurePlacementConstructionStatePort
    {
        public bool HasActiveConstructionSite(MatchId matchId, PlayerId playerId)
        {
            var started = QueryPerfCounters.Enabled
                ? System.Diagnostics.Stopwatch.GetTimestamp() : 0L;
            var active = construction.HasActiveConstructionSite(playerId);
            if (QueryPerfCounters.Enabled)
            {
                QueryPerfCounters.AddPlacementPhase(
                    "eval_site", System.Diagnostics.Stopwatch.GetTimestamp() - started);
            }
            return active;
        }
    }
}
