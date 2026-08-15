using AI_RTS.Application.Queries;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Economy;
using AI_RTS.Domain.Queries;
using AI_RTS.GodotAdapter.Common;
using AI_RTS.GodotAdapter.Composition;
using AI_RTS.GodotAdapter.Economy;
using AI_RTS.GodotAdapter.AI;
using AI_RTS.GodotAdapter.Configuration;
using AI_RTS.GodotAdapter.Construction;
using AI_RTS.GodotAdapter.Production;
using Godot;

namespace AI_RTS.GodotAdapter.Queries;

/// <summary>在 Match 组合根中签发查询会话，并向 GDScript 暴露最小只读测试入口。</summary>
public partial class WorldQueryRuntime : Node
{
    private readonly Dictionary<PlayerId, QuerySessionId> _standardSessions = new();
    private readonly Dictionary<PlayerId, QuerySessionId> _debugSessions = new();
    private IWorldQueryService? _queries;

    /// <summary>由 Match 在玩家与权威经济账户建立后一次性签发标准和调试会话。</summary>
    public void Initialize(Node playersRoot, Node? humanPlayer)
    {
        if (_queries is not null)
        {
            throw new InvalidOperationException("WorldQueryRuntime 只能初始化一次。");
        }
        var grants = new List<QuerySessionGrant>();
        foreach (var player in playersRoot.GetChildren().OfType<Node>())
        {
            if (!player.IsInGroup("players"))
            {
                continue;
            }
            var playerId = GodotStableIdentity.Player(player);
            var standardSession = new QuerySessionId(Guid.NewGuid());
            _standardSessions[playerId] = standardSession;
            var human = player == humanPlayer;
            grants.Add(new QuerySessionGrant(
                standardSession,
                playerId,
                human ? QuerySourceKind.Human : QuerySourceKind.RuleAI,
                ObservationField.All,
                human ? ObservationField.All :
                    ObservationField.Position | ObservationField.Type | ObservationField.Relation,
                false));
            if (OS.IsDebugBuild())
            {
                var debugSession = new QuerySessionId(Guid.NewGuid());
                _debugSessions[playerId] = debugSession;
                grants.Add(new QuerySessionGrant(
                    debugSession,
                    playerId,
                    QuerySourceKind.OmniscientDebug,
                    ObservationField.All,
                    ObservationField.All,
                    true));
            }
        }
        var economy = GetParent().GetNode<EconomyRuntime>("EconomyRuntime");
        var commands = GetParent().GetNode<CommandRuntime>("CommandRuntime");
        var configuration = GetParent().GetNode<BalanceConfigRuntime>("BalanceConfigRuntime");
        var placement = GetParent().GetNode<StructurePlacementRuntime>("StructurePlacementRuntime");
        var production = GetParent().GetNode<ProductionRuntime>("ProductionRuntime");
        _queries = new WorldQueryService(
            new GodotWorldObservationRepository(
                GetParent(), economy.AccountService, commands, production),
            grants);
        BindRuleAiSessions(
            playersRoot, humanPlayer, commands, configuration, placement, production);
    }

    /// <summary>仅供当前自动/人工测试取得组合根已签发的标准会话；正式 Agent Gateway 不暴露此入口。</summary>
    public string GetStandardSessionForTests(Node player) =>
        FindSession(_standardSessions, GodotStableIdentity.Player(player));

    /// <summary>仅在调试构建返回全知测试会话；正式构建始终为空。</summary>
    public string GetDebugSessionForTests(Node player) =>
        FindSession(_debugSessions, GodotStableIdentity.Player(player));

    /// <summary>返回己方单位与建筑摘要，成功空集合也保留 entities 键。</summary>
    public Godot.Collections.Dictionary GetOwnForces(string sessionId, int requestedFields) =>
        ToGodot(Queries().GetOwnForces(Session(sessionId), Fields(requestedFields)));

    /// <summary>返回圆形范围内获准观察的实体，成功空集合也保留 entities 键。</summary>
    public Godot.Collections.Dictionary ScanCircle(
        string sessionId,
        Vector3 center,
        float radius,
        int requestedFields) =>
        ToGodot(Queries().ScanCircle(
            Session(sessionId),
            new CircleObservationRequest(
                new WorldPosition(center.X, center.Y, center.Z),
                radius,
                Fields(requestedFields))));

    /// <summary>返回指定己方单位或建筑的稳定实体引用，主要供桥接测试使用。</summary>
    public Godot.Collections.Dictionary GetOwnEntityReferenceForTests(Node entity, Node owner)
    {
        if (entity.GetParent() != owner || !entity.IsInGroup("units"))
        {
            return new Godot.Collections.Dictionary();
        }
        var kind = entity.HasMethod("is_constructed") ?
            BattlefieldEntityKind.Structure : BattlefieldEntityKind.Unit;
        return new Godot.Collections.Dictionary
        {
            ["kind"] = kind.ToString(),
            ["id"] = GodotStableIdentity.Unit(entity).Value.ToString("D")
        };
    }

    /// <summary>按引用查询己方实体；非己方和未知引用返回相同公开错误。</summary>
    public Godot.Collections.Dictionary InspectOwnEntity(
        string sessionId,
        string kind,
        string entityId,
        int requestedFields)
    {
        if (!Enum.TryParse<BattlefieldEntityKind>(kind, true, out var parsedKind) ||
            !Guid.TryParse(entityId, out var parsedId))
        {
            return InvalidRequestDictionary();
        }
        return ToGodot(Queries().InspectOwnEntity(
            Session(sessionId),
            new BattlefieldEntityId(parsedKind, parsedId),
            Fields(requestedFields)));
    }

    /// <summary>返回会话观察者自己的准确资源账户。</summary>
    public Godot.Collections.Dictionary GetOwnEconomy(string sessionId) =>
        ToGodot(Queries().GetOwnEconomy(Session(sessionId)));

    private IWorldQueryService Queries() => _queries ??
        throw new InvalidOperationException("WorldQueryRuntime 尚未由 Match 初始化。");

    private static QuerySessionId Session(string value) => Guid.TryParse(value, out var id) ?
        new QuerySessionId(id) : new QuerySessionId(Guid.Empty);

    /// <summary>由对局组合根把每个传统规则 AI 绑定到其自身的标准权限会话。</summary>
    private void BindRuleAiSessions(
        Node playersRoot,
        Node? humanPlayer,
        CommandRuntime commands,
        BalanceConfigRuntime configuration,
        StructurePlacementRuntime placement,
        ProductionRuntime production)
    {
        foreach (var player in playersRoot.GetChildren().OfType<Node>())
        {
            if (player == humanPlayer || !player.IsInGroup("players") ||
                !player.HasMethod("setup_world_query"))
            {
                continue;
            }
            var playerId = GodotStableIdentity.Player(player);
            if (!_standardSessions.TryGetValue(playerId, out var session))
            {
                GD.PushError($"无法为传统规则 AI {player.Name} 绑定标准查询会话。");
                continue;
            }
            var commandGateway = new RuleAiCommandGateway
            {
                Name = "RuleAiCommandGateway"
            };
            commandGateway.Configure(
                commands, configuration, placement, production, player);
            player.AddChild(commandGateway);
            player.Call("setup_world_query", this, session.Value.ToString("D"));
        }
    }

    private static ObservationField Fields(int value) => (ObservationField)value;

    private static string FindSession(
        IReadOnlyDictionary<PlayerId, QuerySessionId> sessions,
        PlayerId playerId) =>
        sessions.TryGetValue(playerId, out var session) ? session.Value.ToString("D") : string.Empty;

    private static Godot.Collections.Dictionary ToGodot(
        QueryResult<IReadOnlyList<EntityObservation>> result)
    {
        var entities = new Godot.Collections.Array<Godot.Collections.Dictionary>();
        if (result.Value is not null)
        {
            foreach (var observation in result.Value)
            {
                entities.Add(ToGodot(observation));
            }
        }
        return Envelope(result.Status, result.ErrorCode, result.ObservationRevision, "entities", entities);
    }

    private static Godot.Collections.Dictionary ToGodot(QueryResult<EntityObservation> result) =>
        Envelope(
            result.Status,
            result.ErrorCode,
            result.ObservationRevision,
            "entity",
            result.Value is null ? default(Variant) : Variant.From(ToGodot(result.Value)));

    private static Godot.Collections.Dictionary ToGodot(
        QueryResult<ResourceAccountObservation> result)
    {
        var economy = new Godot.Collections.Dictionary();
        if (result.Value is not null)
        {
            economy["account_version"] = result.Value.AccountVersion;
            var balances = new Godot.Collections.Dictionary();
            foreach (var amount in result.Value.Balances)
            {
                balances[ResourceKey(amount.Kind)] = amount.Amount;
            }
            economy["balances"] = balances;
        }
        return Envelope(result.Status, result.ErrorCode, result.ObservationRevision, "economy", economy);
    }

    /// <summary>把强类型资源映射为 Godot 与外置配置共同使用的稳定字段名。</summary>
    private static string ResourceKey(ResourceKind kind) => kind switch
    {
        ResourceKind.A => "resource_a",
        ResourceKind.B => "resource_b",
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, "未知资源类型。")
    };

    private static Godot.Collections.Dictionary ToGodot(EntityObservation observation) => new()
    {
        ["kind"] = observation.EntityId.Kind.ToString(),
        ["id"] = observation.EntityId.Value.ToString("D"),
        ["state"] = observation.State.ToString(),
        ["returned_fields"] = (int)observation.ReturnedFields,
        ["observed_revision"] = observation.ObservedRevision,
        ["position"] = observation.Position is null ? default(Variant) :
            Variant.From(new Vector3(
                observation.Position.Value.X,
                observation.Position.Value.Y,
                observation.Position.Value.Z)),
        ["type_id"] = observation.TypeId ?? string.Empty,
        ["relation"] = observation.Relation?.ToString() ?? string.Empty,
        ["current_health"] = observation.CurrentHealth is null ? default(Variant) :
            Variant.From(observation.CurrentHealth.Value),
        ["maximum_health"] = observation.MaximumHealth is null ? default(Variant) :
            Variant.From(observation.MaximumHealth.Value),
        ["construction"] = observation.Construction is null ? default(Variant) :
            Variant.From(ToGodot(observation.Construction)),
        ["production"] = observation.Production is null ? default(Variant) :
            Variant.From(ToGodot(observation.Production)),
        ["order"] = observation.Order is null ? default(Variant) :
            Variant.From(ToGodot(observation.Order))
    };

    /// <summary>把强类型施工观察转换为不暴露内部对象的稳定字段集合。</summary>
    private static Godot.Collections.Dictionary ToGodot(ConstructionObservation observation) => new()
    {
        ["state"] = observation.State.ToString(),
        ["completed_work"] = observation.CompletedWork,
        ["required_work"] = observation.RequiredWork,
        ["active_builder_count"] = observation.ActiveBuilderCount
    };

    /// <summary>把生产观察转换为显式容量和稳定顺序项目集合。</summary>
    private static Godot.Collections.Dictionary ToGodot(ProductionObservation observation)
    {
        var items = new Godot.Collections.Array<Godot.Collections.Dictionary>();
        foreach (var item in observation.Items)
        {
            items.Add(new Godot.Collections.Dictionary
            {
                ["item_id"] = item.ItemId.Value.ToString("D"),
                ["product_type_id"] = item.ProductTypeId.Value,
                ["state"] = item.State.ToString(),
                ["completed_work"] = item.CompletedWork,
                ["required_work"] = item.RequiredWork
            });
        }
        return new Godot.Collections.Dictionary
        {
            ["queue_limit"] = observation.QueueLimit,
            ["items"] = items
        };
    }

    /// <summary>把己方活动订单转换为稳定 ID、非终态阶段和原始目标意图。</summary>
    private static Godot.Collections.Dictionary ToGodot(OrderObservation observation) => new()
    {
        ["order_id"] = observation.OrderId.Value.ToString("D"),
        ["kind"] = observation.Kind.ToString(),
        ["state"] = observation.State.ToString(),
        ["target"] = observation.Target is null ? default(Variant) :
            Variant.From(ToGodot(observation.Target))
    };

    /// <summary>把订单目标转换为互斥的实体或位置字段；缺失字段显式为空。</summary>
    private static Godot.Collections.Dictionary ToGodot(OrderTargetObservation target) => new()
    {
        ["entity_kind"] = target.EntityId?.Kind.ToString() ?? string.Empty,
        ["entity_id"] = target.EntityId?.Value.ToString("D") ?? string.Empty,
        ["position"] = target.Position is null ? default(Variant) :
            Variant.From(new Vector3(
                target.Position.Value.X,
                target.Position.Value.Y,
                target.Position.Value.Z)),
        ["type_id"] = target.TypeId ?? string.Empty
    };

    private static Godot.Collections.Dictionary Envelope(
        QueryStatus status,
        QueryErrorCode? error,
        long revision,
        string valueKey,
        Variant value) => new()
    {
        ["status"] = status.ToString(),
        ["error"] = error?.ToString() ?? string.Empty,
        ["observation_revision"] = revision,
        [valueKey] = value
    };

    private static Godot.Collections.Dictionary InvalidRequestDictionary() => new()
    {
        ["status"] = QueryStatus.Rejected.ToString(),
        ["error"] = QueryErrorCode.InvalidRequest.ToString(),
        ["observation_revision"] = 0,
        ["entity"] = default(Variant)
    };
}
