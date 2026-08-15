using AI_RTS.Application.Commands;
using AI_RTS.Application.Production;
using AI_RTS.Application.Queries;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Configuration;
using AI_RTS.GodotAdapter.Common;
using AI_RTS.GodotAdapter.Composition;
using AI_RTS.GodotAdapter.Configuration;
using AI_RTS.GodotAdapter.Construction;
using AI_RTS.GodotAdapter.Production;
using Godot;

namespace AI_RTS.GodotAdapter.AI;

/// <summary>把传统规则 AI 绑定到固定玩家身份，并仅接受稳定实体 ID 命令参数。</summary>
public partial class RuleAiCommandGateway : Node
{
    private CommandRuntime _commands = null!;
    private WeakReference<Node> _issuer = null!;
    private BalanceConfigRuntime _configuration = null!;
    private StructurePlacementRuntime _placement = null!;
    private ProductionRuntime _production = null!;
    private IVisibleEnemyTargetAuthorizer _targetAuthorizer = null!;
    private QuerySessionId _querySessionId;

    /// <summary>由 Match 组合根一次性绑定共享命令运行时和不可更换的发出者身份。</summary>
    internal void Configure(
        CommandRuntime commands,
        BalanceConfigRuntime configuration,
        StructurePlacementRuntime placement,
        ProductionRuntime production,
        IVisibleEnemyTargetAuthorizer targetAuthorizer,
        QuerySessionId querySessionId,
        Node issuer)
    {
        if (_commands is not null)
        {
            throw new InvalidOperationException("RuleAiCommandGateway 只能配置一次。");
        }
        _commands = commands;
        _configuration = configuration;
        _placement = placement;
        _production = production;
        _targetAuthorizer = targetAuthorizer;
        _querySessionId = querySessionId;
        _issuer = new WeakReference<Node>(issuer);
    }

    /// <summary>按稳定单位 ID 提交普通移动命令，目的地允许位于战争迷雾中。</summary>
    public Godot.Collections.Dictionary Move(
        Godot.Collections.Array<string> unitEntityIds,
        Vector3 destination)
    {
        if (!TryGetIssuer(out var issuer))
        {
            return Rejected(CommandErrorCode.MatchNotRunning, ParseUnits(unitEntityIds));
        }
        return ToGodot(_commands.MoveUnitsByStableIds(
            ParseUnits(unitEntityIds), destination, issuer));
    }

    /// <summary>按稳定实体引用提交普通攻击，并强制要求目标是会话当前可见的敌方。</summary>
    public Godot.Collections.Dictionary Attack(
        Godot.Collections.Array<string> unitEntityIds,
        string targetKind,
        string targetEntityId)
    {
        var units = ParseUnits(unitEntityIds);
        if (!TryGetIssuer(out var issuer))
        {
            return Rejected(CommandErrorCode.MatchNotRunning, units);
        }
        if (!Enum.TryParse<BattlefieldEntityKind>(targetKind, true, out var kind) ||
            kind == BattlefieldEntityKind.ResourceNode ||
            !Guid.TryParse(targetEntityId, out var parsedTargetId) ||
            !_targetAuthorizer.IsCurrentlyVisibleEnemy(
                _querySessionId,
                new BattlefieldEntityId(kind, parsedTargetId)))
        {
            return Rejected(CommandErrorCode.TargetUnavailable, units);
        }
        return ToGodot(_commands.AttackUnitsByStableIds(
            units, new UnitId(parsedTargetId), issuer));
    }

    /// <summary>按稳定 Worker 与施工现场 ID 提交统一 Construct 命令。</summary>
    public Godot.Collections.Dictionary Construct(
        Godot.Collections.Array<string> workerIds,
        string constructionSiteId)
    {
        if (!_issuer.TryGetTarget(out var issuer) ||
            !GodotObject.IsInstanceValid(issuer) || !issuer.IsInsideTree())
        {
            return Rejected(CommandErrorCode.MatchNotRunning, []);
        }
        var parsedWorkers = workerIds
            .Select(value => Guid.TryParse(value, out var id) ?
                new UnitId(id) : new UnitId(Guid.Empty))
            .ToArray();
        var parsedSite = Guid.TryParse(constructionSiteId, out var siteId) ?
            new UnitId(siteId) : new UnitId(Guid.Empty);
        return ToGodot(_commands.ConstructUnitsByStableIds(
            parsedWorkers, parsedSite, issuer));
    }

    /// <summary>按稳定建筑类型和世界变换提交统一放置命令，不向 AI 返回 Godot Node。</summary>
    public Godot.Collections.Dictionary PlaceStructure(string unitTypeId, Transform3D transform)
    {
        if (!_issuer.TryGetTarget(out var issuer) ||
            !GodotObject.IsInstanceValid(issuer) || !issuer.IsInsideTree())
        {
            return RejectedPlacement("MatchNotRunning");
        }
        var prototype = _configuration.Assets.FindUnitScene(new UnitTypeId(unitTypeId));
        if (prototype is null || _configuration.FindConstruction(prototype) is null)
        {
            return RejectedPlacement("UnknownDefinition");
        }
        return ToStablePlacement(_placement.Place(
            issuer,
            prototype,
            transform,
            new Godot.Collections.Dictionary()));
    }

    /// <summary>按稳定生产建筑 ID 和产品类型提交统一生产入队命令。</summary>
    public Godot.Collections.Dictionary EnqueueProduction(
        string producerEntityId,
        string productTypeId)
    {
        if (!_issuer.TryGetTarget(out var issuer) ||
            !GodotObject.IsInstanceValid(issuer) || !issuer.IsInsideTree())
        {
            return ToGodot(new ProductionCommandResult(
                new CommandId(Guid.NewGuid()),
                ProductionCommandStatus.ExecutionUnavailable,
                null));
        }
        var producerId = Guid.TryParse(producerEntityId, out var parsedProducerId) ?
            new UnitId(parsedProducerId) : new UnitId(Guid.Empty);
        return ToGodot(_production.EnqueueByStableIds(
            producerId,
            new UnitTypeId(productTypeId),
            issuer));
    }

    /// <summary>按稳定 Worker 与资源节点 ID 提交统一 Gather 命令。</summary>
    public Godot.Collections.Dictionary Gather(
        Godot.Collections.Array<string> workerEntityIds,
        string resourceEntityId)
    {
        if (!_issuer.TryGetTarget(out var issuer) ||
            !GodotObject.IsInstanceValid(issuer) || !issuer.IsInsideTree())
        {
            return Rejected(CommandErrorCode.MatchNotRunning, []);
        }
        var workers = workerEntityIds
            .Select(value => Guid.TryParse(value, out var id) ?
                new UnitId(id) : new UnitId(Guid.Empty))
            .ToArray();
        var resourceId = Guid.TryParse(resourceEntityId, out var parsedResourceId) ?
            new ResourceNodeId(parsedResourceId) : new ResourceNodeId(Guid.Empty);
        return ToGodot(_commands.GatherResourcesByStableIds(
            workers, resourceId, issuer));
    }

    /// <summary>创建未进入权威命令服务时使用的稳定拒绝回执。</summary>
    private static Godot.Collections.Dictionary Rejected(
        CommandErrorCode error,
        IReadOnlyList<UnitId> unitIds) => ToGodot(new CommandResult(
            new CommandId(Guid.NewGuid()),
            CommandStatus.Rejected,
            unitIds.Select(id => new UnitCommandResult(id, false, error)).ToArray()));

    /// <summary>解析批量稳定单位 ID；非法值保留为空 ID，由应用层产生逐单位拒绝。</summary>
    private static IReadOnlyList<UnitId> ParseUnits(
        Godot.Collections.Array<string> unitEntityIds) => unitEntityIds
        .Select(value => Guid.TryParse(value, out var id) ?
            new UnitId(id) : new UnitId(Guid.Empty))
        .ToArray();

    /// <summary>确认固定发出者仍属于当前运行中的场景树。</summary>
    private bool TryGetIssuer(out Node issuer)
    {
        if (_issuer.TryGetTarget(out var target) &&
            GodotObject.IsInstanceValid(target) && target.IsInsideTree())
        {
            issuer = target;
            return true;
        }
        issuer = null!;
        return false;
    }

    /// <summary>将强类型命令回执转换为 GDScript 可读取的稳定字段集合。</summary>
    private static Godot.Collections.Dictionary ToGodot(CommandResult result)
    {
        var unitResults = new Godot.Collections.Array<Godot.Collections.Dictionary>();
        foreach (var item in result.UnitResults)
        {
            unitResults.Add(new Godot.Collections.Dictionary
            {
                ["unit_id"] = item.UnitId.Value.ToString("D"),
                ["accepted"] = item.Accepted,
                ["error_code"] = item.ErrorCode.ToString(),
                ["order_id"] = item.OrderId?.Value.ToString("D") ?? string.Empty
            });
        }
        return new Godot.Collections.Dictionary
        {
            ["command_id"] = result.CommandId.Value.ToString("D"),
            ["status"] = result.Status.ToString(),
            ["unit_results"] = unitResults
        };
    }

    /// <summary>删除 Legacy 放置结果中的 Node，只保留稳定现场 ID 和公开问题。</summary>
    private static Godot.Collections.Dictionary ToStablePlacement(
        Godot.Collections.Dictionary result)
    {
        var accepted = result.GetValueOrDefault("accepted").AsBool();
        var structure = accepted ? result.GetValueOrDefault("structure").AsGodotObject() as Node : null;
        return new Godot.Collections.Dictionary
        {
            ["accepted"] = accepted,
            ["status"] = result.GetValueOrDefault("status").AsString(),
            ["primary_issue"] = result.GetValueOrDefault("primary_issue").AsString(),
            ["issues"] = result.GetValueOrDefault("issues"),
            ["construction_site_id"] = structure is null ? string.Empty :
                GodotStableIdentity.Unit(structure).Value.ToString("D")
        };
    }

    /// <summary>创建未到达放置服务时使用的稳定拒绝回执。</summary>
    private static Godot.Collections.Dictionary RejectedPlacement(string issue) => new()
    {
        ["accepted"] = false,
        ["status"] = "Rejected",
        ["primary_issue"] = issue,
        ["issues"] = new Godot.Collections.Array<string> { issue },
        ["construction_site_id"] = string.Empty
    };

    /// <summary>把生产命令回执转换为不暴露内部对象的稳定字段集合。</summary>
    private static Godot.Collections.Dictionary ToGodot(ProductionCommandResult result)
    {
        var dictionary = new Godot.Collections.Dictionary
        {
            ["accepted"] = result.Status == ProductionCommandStatus.Accepted,
            ["status"] = result.Status.ToString(),
            ["command_id"] = result.CommandId.Value.ToString("D")
        };
        if (result.Item is not null)
        {
            dictionary["item_id"] = result.Item.ItemId.Value.ToString("D");
            dictionary["producer_id"] = result.Item.ProducerId.Value.ToString("D");
            dictionary["state"] = result.Item.State.ToString();
        }
        return dictionary;
    }
}
