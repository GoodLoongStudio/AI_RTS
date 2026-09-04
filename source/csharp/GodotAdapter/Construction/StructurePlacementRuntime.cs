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
