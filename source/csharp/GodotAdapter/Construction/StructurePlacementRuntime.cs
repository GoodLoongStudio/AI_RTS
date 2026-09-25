using AI_RTS.Application.Construction;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Configuration;
using AI_RTS.Domain.Construction;
using AI_RTS.Domain.Economy;
using AI_RTS.GodotAdapter.Common;
using AI_RTS.GodotAdapter.Composition;
using AI_RTS.GodotAdapter.Configuration;
using AI_RTS.GodotAdapter.Economy;
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
        _definitions = new GodotStructurePlacementDefinitionRepository(_configuration.Catalog);
        _world = new GodotStructurePlacementWorldPort(GetParent());
        _service = new StructurePlacementService(
            _definitions,
            new AllowRegisteredStructurePlacementAuthorization(),
            _world,
            _economy.AccountService);
    }

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
        return ToGodot(_service.Evaluate(Query(playerId, definitionId, transform)));
    }

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
        var query = Query(playerId, definitionId, transform);
        var evaluation = _service.Evaluate(query);
        if (!evaluation.IsValid)
        {
            return ToGodot(evaluation);
        }

        var definition = construction.Placement;
        var world = _world.EvaluateDetailed(playerId, evaluation.Candidate, definition);
        if (world.Issues.Count != 0)
        {
            return ToGodot(_service.Evaluate(query));
        }

        var structure = prototype.Instantiate<Node3D>();
        var displacedIds = new Godot.Collections.Array<string>();
        foreach (var unit in world.FriendlyDisplacements.Keys)
        {
            displacedIds.Add(GodotStableIdentity.Unit(unit).Value.ToString("D"));
        }
        structure.SetMeta("ai_rts_displaced_unit_ids", displacedIds);
        var constructionCost = ToGodotCosts(definition.ConstructionCost);
        var paymentAccepted = definition.ConstructionCost.Count == 0 ||
            _economy.SubtractResources(
                player, constructionCost, "ConstructionCost", structure)["accepted"].AsBool();
        if (!paymentAccepted)
        {
            structure.Free();
            return ToGodot(_service.Evaluate(query));
        }

        try
        {
            GetParent().Call("_setup_and_spawn_unit", structure, transform, player, true);
            if (!_commands.RegisterConstructionSite(
                structure,
                player,
                definitionId,
                construction.RequiredWork,
                definition.ConstructionCost))
            {
                throw new InvalidOperationException("无法注册权威施工现场。");
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
    /// - hint 非空时直接以 hint 为锚点（调用方有政策偏好时用）。
    /// </summary>
    /// <returns>{"found": bool, "pos": Vector3（含地表高度）}；找不到 found=false。</returns>
    /// hint 传 Vector3.INF 表示"无锚点偏好"（GDScript 侧字面量即可，避免可空/可选参数
    /// 导致源码生成器不注册——实测 `has_method` 走反射能看到、GDScript 调用却报
    /// Nonexistent，两者表不一样）。
    public Godot.Collections.Dictionary FindAutoSpot(
        Node player,
        PackedScene prototype,
        string mode,
        Vector3 hint,
        float maxRadiusMeters)
    {
        var construction = EnsureDefinition(prototype);
        var definitionId = construction.DefinitionId;
        var playerId = GodotStableIdentity.Player(player);
        _world.RegisterPlayer(playerId, player);
        if (construction.Placement.Footprint is not CirclePlacementFootprint footprint)
        {
            return null;
        }

        var radius = MathF.Max(footprint.Radius, 0.5f);
        var hintPoint = hint.IsFinite() ? (Vector3?)hint : null;
        if (ResolveAutoAnchor(player, mode, hintPoint) is not Vector3 anchor)
        {
            GD.Print($"[AUTOSPOT] no anchor mode={mode} ownStructures={OwnStructures(player).Count()}");
            return AutoSpotResult(false, Vector3.Zero);
        }
        GD.Print($"[AUTOSPOT] mode={mode} anchor=({anchor.X:F1},{anchor.Z:F1}) radius={radius}");

        var limit = maxRadiusMeters > 0.01f
            ? maxRadiusMeters
            : (string.Equals(mode, "resource", StringComparison.Ordinal) ? 14f : 30f);
        // 资源模式（矿场/分基地）起始环略外扩：贴脸矿点放置时，工人站位会落进
        // 建筑避让圈与矿点之间的夹缝，被每帧推回 → 原地抖（2026-09-23 实测）。
        // 不能再大：远端矿点只有工人视野（5m+2m 补偿），环外扩太多会整体
        // 落在视野外（NotVisible）→ 一个点都搜不到。
        var firstRing = string.Equals(mode, "resource", StringComparison.Ordinal)
            ? radius + 2.0f
            : radius + 1.5f;
        var evaluations = 0;
        for (var ring = 0; ring < 16; ring++)
        {
            var distance = firstRing + ring * 2.0f;
            if (distance > limit)
            {
                break;
            }

            for (var step = 0; step < 16; step++)
            {
                // 黄金角螺旋：确定性，且相邻环采样点错开（不会每局都落在同一方位）。
                var angle = 2.399963229728653f * (ring * 16 + step);
                var spot = new Vector3(
                    anchor.X + MathF.Cos(angle) * distance,
                    0f,
                    anchor.Z + MathF.Sin(angle) * distance);
                if (++evaluations > 256)
                {
                    return AutoSpotResult(false, Vector3.Zero);
                }

                var evaluation = _service.Evaluate(Query(
                    playerId, definitionId, new Transform3D(Basis.Identity, spot)));
                // "缺钱"不是选址失败：落点合法，扣款失败由 Place 原样回报（诊断不丢类）。
                if (evaluation.IsValid || (evaluation.Issues.Count == 1 &&
                        evaluation.Issues[0] == StructurePlacementIssue.InsufficientResources))
                {
                    var found = SampleGroundHeight(spot);
                    GD.Print($"[AUTOSPOT] FOUND ({found.X:F1},{found.Y:F1},{found.Z:F1})");
                    return AutoSpotResult(true, found);
                }
            }
        }

        return AutoSpotResult(false, Vector3.Zero);
    }

    /// <summary>自动放置结果字面量（GDScript 侧只认 Dictionary）。</summary>
    private static Godot.Collections.Dictionary AutoSpotResult(bool found, Vector3 pos) =>
        new()
        {
            ["found"] = found,
            ["pos"] = pos,
        };

    /// <summary>按模式解析自动放置锚点；解析不到（没有己方建筑/没有矿点）返回 null。</summary>
    private Vector3? ResolveAutoAnchor(Node player, string mode, Vector3? hint)
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
                if (toNearestStructure < ExpansionMinBaseDistanceM)
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
    private static IEnumerable<Node3D> OwnStructures(Node player) =>
        player.GetTree().GetNodesInGroup("units")
            .OfType<Node3D>()
            .Where(unit => unit.GetParent() == player
                && unit.FindChild("MovementObstacle", false, false) != null);

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
}
