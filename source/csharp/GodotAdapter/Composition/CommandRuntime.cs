using AI_RTS.Application.Commands;
using AI_RTS.Application.Commands.Units;
using AI_RTS.Application.Combat;
using AI_RTS.Application.Construction;
using AI_RTS.Application.Orders;
using AI_RTS.Application.Units;
using AI_RTS.Domain.Combat;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Construction;
using AI_RTS.Domain.Economy;
using AI_RTS.GodotAdapter.Navigation;
using AI_RTS.GodotAdapter.Combat;
using AI_RTS.GodotAdapter.Common;
using AI_RTS.GodotAdapter.Configuration;
using AI_RTS.GodotAdapter.Construction;
using AI_RTS.GodotAdapter.Economy;
using AI_RTS.GodotAdapter.Units;
using AI_RTS.Domain.Queries;
using Godot;

namespace AI_RTS.GodotAdapter.Composition;

/// <summary>在 Match 生命周期内统一持有单位注册表、订单存储和权威命令服务。</summary>
public partial class CommandRuntime : Node
{
    /// <summary>向 Godot 表现与集成层广播权威订单状态变化；可见性过滤不得在此信号中绕过。</summary>
    [Signal]
    public delegate void OrderStateChangedEventHandler(
        string orderId,
        string commandId,
        string unitId,
        string kind,
        string previousState,
        string currentState,
        string replacedByCommandId);

    /// <summary>维护本 Match 中 Godot Node 与稳定单位/玩家 ID 的映射。</summary>
    private readonly GodotUnitRegistry _units = new();

    /// <summary>维护非单位资源节点的稳定身份与可采集状态。</summary>
    private readonly GodotResourceNodeRegistry _resourceNodes = new();

    /// <summary>维护施工现场稳定 ID 与 Godot Node 的弱引用映射。</summary>
    private readonly GodotConstructionSiteRegistry _constructionSites = new();

    /// <summary>保存本 Match 中所有控制器共享的单位订单状态。</summary>
    private readonly InMemoryUnitOrderStore _orders = new();

    /// <summary>保存本 Match 中所有控制器共享的单位交战姿态与开火策略。</summary>
    private readonly InMemoryCombatPolicyStore _combatPolicies = new();

    /// <summary>记录已订阅单位退出事件的 ID，避免多个控制器重复连接。</summary>
    private readonly HashSet<UnitId> _deathTrackedUnits = new();

    /// <summary>等待系统驱逐完成后才启动的施工任务；任意新玩家订单都会使其失效。</summary>
    private readonly Dictionary<UnitId, PendingConstruction> _pendingConstruction = new();

    /// <summary>所有 Human、规则 AI 和未来外部 Adapter 共享的命令服务。</summary>
    private IUnitCommandService _commands = null!;

    /// <summary>当前 Match 的权威施工任务、整数进度与终态服务。</summary>
    private IConstructionService _construction = null!;

    /// <summary>提供初始完成建筑的权威施工定义。</summary>
    private BalanceConfigRuntime _balance = null!;

    /// <summary>当前 Match 的进程内稳定 ID。</summary>
    private MatchId _matchId;

    /// <summary>为当前 Match 创建唯一的命令服务及 Legacy 导航适配器。</summary>
    public override void _Ready()
    {
        var economy = GetParent().GetNode<EconomyRuntime>("EconomyRuntime");
        _balance = GetParent().GetNode<BalanceConfigRuntime>("BalanceConfigRuntime");
        _matchId = economy.MatchId;
        _orders.StateChanged += OnOrderStateChanged;
        _construction = new ConstructionService(
            _units,
            _orders,
            new LegacyConstructionWorkerPort(_units, _constructionSites),
            _constructionSites,
            economy.AccountService);
        _commands = new UnitCommandService(
            _units,
            new LegacyMovementPort(_units, _resourceNodes),
            new LegacyAttackPort(_units),
            _orders,
            _combatPolicies,
            new LegacyStopPort(_units),
            new LegacyWorkerTaskPort(_units, _resourceNodes),
            _resourceNodes,
            _construction);
    }

    /// <summary>每个物理 Tick 只推进一次权威施工工作量。</summary>
    public override void _PhysicsProcess(double delta)
    {
        _construction.Advance(checked((long)Engine.GetPhysicsFrames()));
    }

    /// <summary>代表指定玩家向一组 Godot 单位节点提交普通移动命令。</summary>
    public CommandResult MoveUnits(
        IEnumerable<Node> unitNodes,
        Vector3 destination,
        Node issuerPlayer)
    {
        var context = CreateContext(issuerPlayer);
        var unitIds = unitNodes.Select(_units.Register).ToArray();
        var result = _commands.Move(
            context,
            new MoveUnitsCommand(
                unitIds,
                new WorldPosition(destination.X, destination.Y, destination.Z)));
        TrackAcceptedOrders(result);
        return result;
    }

    /// <summary>代表指定玩家命令单位靠近单位、建筑或资源实体。</summary>
    public CommandResult ApproachEntityUnits(
        IEnumerable<Node> unitNodes,
        Node targetNode,
        Node issuerPlayer)
    {
        var unitIds = unitNodes.Select(_units.Register).ToArray();
        var targetId = RegisterApproachTarget(targetNode);
        var result = _commands.ApproachEntity(
            CreateContext(issuerPlayer),
            new ApproachEntityCommand(unitIds, targetId));
        TrackAcceptedEntityMovement(result, "approach_ended", UnitOrderKind.ApproachEntity);
        return result;
    }

    /// <summary>代表指定玩家命令单位持续跟随一个单位或建筑。</summary>
    public CommandResult FollowEntityUnits(
        IEnumerable<Node> unitNodes,
        Node targetNode,
        Node issuerPlayer)
    {
        var unitIds = unitNodes.Select(_units.Register).ToArray();
        var targetId = _units.Register(targetNode);
        var result = _commands.FollowEntity(
            CreateContext(issuerPlayer),
            new FollowEntityCommand(unitIds, targetId));
        TrackAcceptedEntityMovement(result, "follow_ended", UnitOrderKind.FollowEntity);
        return result;
    }

    /// <summary>由固定身份 Adapter 按稳定单位 ID 提交普通移动命令。</summary>
    internal CommandResult MoveUnitsByStableIds(
        IReadOnlyList<UnitId> unitIds,
        Vector3 destination,
        Node issuerPlayer)
    {
        var result = _commands.Move(
            CreateContext(issuerPlayer),
            new MoveUnitsCommand(
                unitIds,
                new WorldPosition(destination.X, destination.Y, destination.Z)));
        TrackAcceptedOrders(result);
        return result;
    }

    /// <summary>代表指定玩家向一组 Godot 单位节点提交强制移动命令。</summary>
    public CommandResult ForceMoveUnits(
        IEnumerable<Node> unitNodes,
        Vector3 destination,
        Node issuerPlayer)
    {
        var context = CreateContext(issuerPlayer);
        var unitIds = unitNodes.Select(_units.Register).ToArray();
        var result = _commands.ForceMove(
            context,
            new ForceMoveUnitsCommand(
                unitIds,
                new WorldPosition(destination.X, destination.Y, destination.Z)));
        TrackAcceptedOrders(result);
        return result;
    }

    /// <summary>代表指定玩家向一组 Worker 提交持续采集任务。</summary>
    public CommandResult GatherResources(
        IEnumerable<Node> workerNodes,
        Node resourceNode,
        Node issuerPlayer)
    {
        var context = CreateContext(issuerPlayer);
        var workerIds = workerNodes.Select(_units.Register).ToArray();
        var resourceNodeId = _resourceNodes.Register(resourceNode);
        var result = _commands.GatherResources(
            context,
            new GatherResourcesCommand(workerIds, resourceNodeId));
        TrackAcceptedGatherOrders(result);
        return result;
    }

    /// <summary>由固定身份 Adapter 按 Worker 与资源节点稳定 ID 提交持续采集任务。</summary>
    internal CommandResult GatherResourcesByStableIds(
        IReadOnlyList<UnitId> workerIds,
        ResourceNodeId resourceNodeId,
        Node issuerPlayer)
    {
        var result = _commands.GatherResources(
            CreateContext(issuerPlayer),
            new GatherResourcesCommand(workerIds, resourceNodeId));
        TrackAcceptedGatherOrders(result);
        return result;
    }

    /// <summary>注册已经完成扣款和生成的施工现场，并绑定其销毁清理。</summary>
    internal bool RegisterConstructionSite(
        Node site,
        Node owner,
        StructureDefinitionId definitionId,
        int requiredWork,
        IReadOnlyList<ResourceAmount> costs)
    {
        var siteId = _constructionSites.Register(site);
        _units.Register(site);
        var registered = _construction.Register(new RegisterConstructionSite(
            siteId,
            _units.RegisterPlayer(owner),
            definitionId,
            requiredWork,
            costs));
        if (registered)
        {
            site.TreeExiting += () => _construction.Destroy(
                siteId, checked((long)Engine.GetPhysicsFrames()));
        }
        return registered;
    }

    /// <summary>代表控制器向一组 Worker 提交同一施工现场任务。</summary>
    public CommandResult ConstructUnits(
        IEnumerable<Node> workerNodes,
        Node site,
        Node issuerPlayer)
    {
        var workerIds = workerNodes.Select(_units.Register).ToArray();
        var result = _construction.Construct(
            CreateContext(issuerPlayer),
            new ConstructStructureCommand(workerIds, _constructionSites.Register(site)));
        TrackAcceptedPersistentOrders(result);
        return result;
    }

    /// <summary>代表已绑定身份的 Adapter 按稳定 ID 提交施工命令。</summary>
    internal CommandResult ConstructUnitsByStableIds(
        IReadOnlyList<UnitId> workerIds,
        UnitId siteId,
        Node issuerPlayer)
    {
        foreach (var workerId in workerIds.Distinct())
        {
            _units.TryResolveInMatch(workerId, GetParent(), out _);
        }
        var result = _construction.Construct(
            CreateContext(issuerPlayer),
            new ConstructStructureCommand(workerIds, siteId));
        TrackAcceptedPersistentOrders(result);
        return result;
    }

    /// <summary>返回建筑可公开给查询层的施工阶段、工作量与活动建造者数量。</summary>
    internal ConstructionObservation? ObserveConstruction(Node structure)
    {
        if (!structure.HasMethod("is_constructed") ||
            _balance.FindConstruction(structure) is not { } definition)
        {
            return null;
        }
        var siteId = GodotStableIdentity.Unit(structure);
        if (_construction.Find(siteId) is { } site)
        {
            return new ConstructionObservation(
                site.State == ConstructionSiteState.Completed ?
                    ConstructionObservationState.Completed :
                    ConstructionObservationState.UnderConstruction,
                site.CompletedWork,
                site.RequiredWork,
                _construction.GetActiveBuilderCount(siteId));
        }
        var completed = structure.Call("is_constructed").AsBool();
        return new ConstructionObservation(
            completed ? ConstructionObservationState.Completed :
                ConstructionObservationState.UnderConstruction,
            completed ? definition.RequiredWork : 0,
            definition.RequiredWork,
            0);
    }

    /// <summary>让放置开始时捕获的 Worker 施工；被驱逐者到位后才开始，期间新命令可取消等待。</summary>
    public void AssignBuildersAfterPlacement(
        IEnumerable<Node> workerNodes,
        Node site,
        Node issuerPlayer,
        IReadOnlySet<string> displacedUnitIds)
    {
        var immediate = new List<Node>();
        foreach (var worker in workerNodes.Distinct())
        {
            var workerId = _units.Register(worker);
            if (!displacedUnitIds.Contains(workerId.Value.ToString("D")))
            {
                immediate.Add(worker);
                continue;
            }

            _pendingConstruction[workerId] = new PendingConstruction(
                new WeakReference<Node>(site), new WeakReference<Node>(issuerPlayer));
            var movement = worker.FindChild("Movement", false, false);
            if (movement is null)
            {
                _pendingConstruction.Remove(workerId);
                continue;
            }
            movement.Connect(
                "movement_finished",
                Callable.From(() => StartPendingConstruction(workerId)),
                (uint)ConnectFlags.OneShot);
        }
        if (immediate.Count > 0)
        {
            ConstructUnits(immediate, site, issuerPlayer);
        }
    }

    /// <summary>由拥有者主动取消未完成现场；成功时执行一次全额退款。</summary>
    public ConstructionSiteCommandResult CancelConstruction(Node site, Node issuerPlayer)
    {
        return _construction.Cancel(
            CreateContext(issuerPlayer),
            new CancelConstructionCommand(_constructionSites.Register(site)));
    }

    /// <summary>代表指定玩家向一组单位提交地面移动攻击，并跟踪订单完成状态。</summary>
    public CommandResult GroundAttackMoveUnits(
        IEnumerable<Node> unitNodes,
        Vector3 destination,
        Node issuerPlayer)
    {
        var context = CreateContext(issuerPlayer);
        var unitIds = unitNodes.Select(_units.Register).ToArray();
        var result = _commands.GroundAttackMove(
            context,
            new GroundAttackMoveCommand(
                unitIds,
                new WorldPosition(destination.X, destination.Y, destination.Z)));
        TrackAcceptedOrders(result);
        return result;
    }

    /// <summary>代表指定玩家提交以敌方实体为最终目标的移动攻击，并跟踪目标失效状态。</summary>
    public CommandResult EntityAttackMoveUnits(
        IEnumerable<Node> unitNodes,
        Node targetNode,
        Node issuerPlayer)
    {
        var context = CreateContext(issuerPlayer);
        var unitIds = unitNodes.Select(_units.Register).ToArray();
        var targetId = _units.Register(targetNode);
        var result = _commands.EntityAttackMove(
            context,
            new EntityAttackMoveCommand(unitIds, new EntityAttackTarget(targetId)));
        TrackAcceptedAttacks(result, "entity_attack_move_ended", UnitOrderKind.EntityAttackMove);
        return result;
    }

    /// <summary>代表指定玩家向一组单位提交战术撤退，并跟踪到达与损失状态。</summary>
    public CommandResult TacticalWithdrawUnits(
        IEnumerable<Node> unitNodes,
        Vector3 destination,
        Node issuerPlayer)
    {
        var context = CreateContext(issuerPlayer);
        var unitIds = unitNodes.Select(_units.Register).ToArray();
        var result = _commands.TacticalWithdraw(
            context,
            new TacticalWithdrawCommand(
                unitIds,
                new WorldPosition(destination.X, destination.Y, destination.Z)));
        TrackAcceptedOrders(result);
        return result;
    }

    /// <summary>代表指定玩家向一组 Godot 单位节点提交停止移动命令。</summary>
    public CommandResult HaltMovement(IEnumerable<Node> unitNodes, Node issuerPlayer)
    {
        var context = CreateContext(issuerPlayer);
        var nodes = unitNodes.ToArray();
        var unitIds = nodes.Select(_units.Register).ToArray();
        var result = _commands.HaltMovement(context, new HaltMovementCommand(unitIds));
        UpdateGuardAnchorsForAccepted(result);
        return result;
    }

    /// <summary>由固定身份 Adapter 按稳定单位 ID 暂停当前可停止任务。</summary>
    internal CommandResult HaltMovementByStableIds(
        IReadOnlyList<UnitId> unitIds,
        Node issuerPlayer)
    {
        var result = _commands.HaltMovement(
            CreateContext(issuerPlayer),
            new HaltMovementCommand(unitIds));
        UpdateGuardAnchorsForAccepted(result);
        return result;
    }

    /// <summary>代表指定玩家向一组单位提交单一、可逐单位回执的统一停止命令。</summary>
    public CommandResult StopUnits(IEnumerable<Node> unitNodes, Node issuerPlayer)
    {
        var context = CreateContext(issuerPlayer);
        var unitIds = unitNodes.Select(_units.Register).ToArray();
        foreach (var unitId in unitIds)
        {
            _pendingConstruction.Remove(unitId);
        }
        return _commands.Stop(context, new StopUnitsCommand(unitIds));
    }

    /// <summary>代表指定玩家设置一组 Godot 单位的持续交战姿态。</summary>
    public CommandResult SetEngagementStance(
        IEnumerable<Node> unitNodes,
        EngagementStance stance,
        Node issuerPlayer)
    {
        var context = CreateContext(issuerPlayer);
        var nodes = unitNodes.ToArray();
        var result = _commands.SetEngagementStance(
            context,
            new SetEngagementStanceCommand(nodes.Select(_units.Register).ToArray(), stance));
        foreach (var item in result.UnitResults.Where(item => item.Accepted))
        {
            if (stance != EngagementStance.Guard)
            {
                _combatPolicies.SetGuardAnchor(item.UnitId, null);
                continue;
            }

            var active = _orders.FindActive(item.UnitId);
            if (active?.State == UnitOrderState.InProgress)
            {
                _combatPolicies.SetGuardAnchor(item.UnitId, null);
            }
            else if (_units.TryGetNode(item.UnitId, out var unit))
            {
                _combatPolicies.SetGuardAnchor(item.UnitId, ToWorldPosition(unit));
            }
        }
        RefreshLegacyCombatPolicies(result);
        return result;
    }

    /// <summary>代表指定玩家设置一组 Godot 单位的持续开火策略。</summary>
    public CommandResult SetFirePolicy(
        IEnumerable<Node> unitNodes,
        FirePolicy policy,
        Node issuerPlayer)
    {
        var context = CreateContext(issuerPlayer);
        var unitIds = unitNodes.Select(_units.Register).ToArray();
        var result = _commands.SetFirePolicy(context, new SetFirePolicyCommand(unitIds, policy));
        RefreshLegacyCombatPolicies(result);
        return result;
    }

    /// <summary>代表指定玩家向一组单位提交普通敌方实体攻击。</summary>
    public CommandResult AttackUnits(
        IEnumerable<Node> unitNodes,
        Node targetNode,
        Node issuerPlayer)
    {
        var context = CreateContext(issuerPlayer);
        var unitIds = unitNodes.Select(_units.Register).ToArray();
        var targetId = _units.Register(targetNode);
        var result = _commands.Attack(
            context,
            new AttackCommand(unitIds, new EntityAttackTarget(targetId)));
        TrackAcceptedAttacks(result, "ordinary_attack_ended", UnitOrderKind.Attack);
        return result;
    }

    /// <summary>由固定身份 Adapter 按稳定单位与目标 ID 提交普通实体攻击。</summary>
    internal CommandResult AttackUnitsByStableIds(
        IReadOnlyList<UnitId> unitIds,
        UnitId targetId,
        Node issuerPlayer)
    {
        var result = _commands.Attack(
            CreateContext(issuerPlayer),
            new AttackCommand(unitIds, new EntityAttackTarget(targetId)));
        TrackAcceptedAttacks(result, "ordinary_attack_ended", UnitOrderKind.Attack);
        return result;
    }

    /// <summary>代表指定玩家向一组 Godot 单位提交持续实体强制攻击。</summary>
    public CommandResult ForceAttackUnits(
        IEnumerable<Node> unitNodes,
        Node targetNode,
        Node issuerPlayer)
    {
        var context = CreateContext(issuerPlayer);
        var unitIds = unitNodes.Select(_units.Register).ToArray();
        var targetId = _units.Register(targetNode);
        var result = _commands.ForceAttack(
            context,
            new ForceAttackCommand(unitIds, new EntityAttackTarget(targetId)));
        TrackAcceptedAttacks(result, "explicit_force_attack_ended", UnitOrderKind.ForceAttack);
        return result;
    }

    /// <summary>提交持续地面强制攻击，并只跟踪执行单位损失。</summary>
    public CommandResult ForceAttackGround(
        IEnumerable<Node> unitNodes,
        Vector3 position,
        Node issuerPlayer)
    {
        var context = CreateContext(issuerPlayer);
        var unitIds = unitNodes.Select(_units.Register).ToArray();
        var result = _commands.ForceAttack(
            context,
            new ForceAttackCommand(
                unitIds,
                new GroundAttackTarget(new WorldPosition(position.X, position.Y, position.Z))));
        TrackAcceptedPersistentOrders(result);
        return result;
    }

    /// <summary>只取消指定单位的显式 ForceAttack，不影响普通自动攻击。</summary>
    public CommandResult CancelForceAttack(IEnumerable<Node> unitNodes, Node issuerPlayer)
    {
        var context = CreateContext(issuerPlayer);
        var unitIds = unitNodes.Select(_units.Register).ToArray();
        return _commands.CancelForceAttack(context, new CancelForceAttackCommand(unitIds));
    }

    /// <summary>结束单位现有订单并执行建筑放置产生的系统驱逐；完成后单位待命。</summary>
    public bool DisplaceUnitForConstruction(Node unitNode, Vector3 destination, Node ownerPlayer)
    {
        var unitId = _units.Register(unitNode);
        if (_units.Find(unitId) is not { } snapshot ||
            snapshot.OwnerId != _units.RegisterPlayer(ownerPlayer) ||
            !snapshot.CanMove || !Finite(destination))
        {
            return false;
        }

        if (_orders.FindActive(unitId) is { } active)
        {
            _orders.Transition(active.OrderId, UnitOrderState.Cancelled);
        }
        return unitNode.HasMethod("request_legacy_move") &&
            unitNode.Call("request_legacy_move", destination).AsBool();
    }

    /// <summary>查询指定 Godot 单位当前权威交战姿态名称。</summary>
    public string GetEngagementStance(Node unitNode) =>
        _combatPolicies.Get(_units.Register(unitNode)).EngagementStance.ToString();

    /// <summary>查询指定 Godot 单位当前权威开火策略名称。</summary>
    public string GetFirePolicy(Node unitNode) =>
        _combatPolicies.Get(_units.Register(unitNode)).FirePolicy.ToString();

    /// <summary>把生产者当前姿态与开火策略复制给新出厂单位，再由 Rally 分派初始任务。</summary>
    internal bool InheritCombatPolicy(Node producer, Node producedUnit, Node ownerPlayer)
    {
        var producerId = _units.Register(producer);
        var policy = _combatPolicies.Get(producerId);
        var stanceResult = SetEngagementStance(
            [producedUnit], policy.EngagementStance, ownerPlayer);
        var fireResult = SetFirePolicy([producedUnit], policy.FirePolicy, ownerPlayer);
        return stanceResult.Status == CommandStatus.Accepted &&
            fireResult.Status == CommandStatus.Accepted;
    }

    /// <summary>为 Rally Adapter 注册单位或建筑并返回稳定身份。</summary>
    internal UnitId RegisterRuntimeUnit(Node unit) => _units.Register(unit);

    /// <summary>为 Rally Adapter 注册资源节点并返回稳定身份。</summary>
    internal ResourceNodeId RegisterRuntimeResource(Node resource) =>
        _resourceNodes.Register(resource);

    /// <summary>把 Godot 实体注册为靠近命令使用的统一稳定目标。</summary>
    private BattlefieldEntityId RegisterApproachTarget(Node target)
    {
        if (target.IsInGroup("resource_units"))
        {
            return new BattlefieldEntityId(
                BattlefieldEntityKind.ResourceNode,
                _resourceNodes.Register(target).Value);
        }

        var unitId = _units.Register(target);
        var kind = _units.Find(unitId)?.EntityKind ?? BattlefieldEntityKind.Unit;
        return new BattlefieldEntityId(kind, unitId.Value);
    }

    /// <summary>返回查询层可公开的活动订单与原始目标意图；空闲单位返回空。</summary>
    internal OrderObservation? ObserveActiveOrder(Node unit)
    {
        var unitId = _units.Register(unit);
        if (_orders.FindActive(unitId) is not { } order)
        {
            return null;
        }
        return new OrderObservation(
            order.OrderId,
            MapOrderKind(order.Kind),
            MapOrderState(order.State),
            order.Target switch
            {
                UnitOrderEntityTarget entity => new OrderTargetObservation(
                    entity.EntityId, null, entity.TypeId),
                UnitOrderPositionTarget position => new OrderTargetObservation(
                    null, position.Position, null),
                _ => null
            });
    }

    /// <summary>查询 Rally Adapter 所需的单位能力和所有权。</summary>
    internal UnitCommandSnapshot? FindRuntimeUnit(UnitId unitId) => _units.Find(unitId);

    /// <summary>查询 Rally Adapter 所需的资源状态。</summary>
    internal ResourceNodeSnapshot? FindRuntimeResource(ResourceNodeId resourceNodeId) =>
        _resourceNodes.Find(resourceNodeId);

    /// <summary>解析 Rally Adapter 保存的单位弱引用。</summary>
    internal bool TryGetRuntimeUnit(UnitId unitId, out Node unit) =>
        _units.TryGetNode(unitId, out unit);

    /// <summary>解析 Rally Adapter 保存的资源节点弱引用。</summary>
    internal bool TryGetRuntimeResource(ResourceNodeId resourceNodeId, out Node resource) =>
        _resourceNodes.TryGetNode(resourceNodeId, out resource);

    /// <summary>返回当前 Match 的稳定身份。</summary>
    internal MatchId RuntimeMatchId => _matchId;

    /// <summary>查询警戒岗位点；尚未确定时返回正无穷坐标供 GDScript 明确识别。</summary>
    public Vector3 GetGuardAnchor(Node unitNode)
    {
        var anchor = _combatPolicies.Get(_units.Register(unitNode)).GuardAnchor;
        return anchor is { } value ?
            new Vector3(value.X, value.Y, value.Z) : Vector3.Inf;
    }

    /// <summary>查询指定单位当前活动订单的状态名称，主要用于桥接期诊断。</summary>
    public string GetActiveOrderState(Node unitNode)
    {
        var unitId = _units.Register(unitNode);
        return _orders.FindActive(unitId)?.State.ToString() ?? string.Empty;
    }

    /// <summary>按字符串形式的 UnitOrderId 查询状态名称，主要用于桥接期诊断。</summary>
    public string GetOrderState(string orderId) =>
        Guid.TryParse(orderId, out var value) ?
            _orders.Find(new UnitOrderId(value))?.State.ToString() ?? string.Empty : string.Empty;

    /// <summary>按订单 ID 查询完整权威快照；无效或不存在时返回空 Dictionary。</summary>
    public Godot.Collections.Dictionary GetOrderSnapshot(string orderId)
    {
        if (!Guid.TryParse(orderId, out var value) ||
            _orders.Find(new UnitOrderId(value)) is not { } order)
        {
            return new Godot.Collections.Dictionary();
        }

        return ToGodot(order);
    }

    private CommandContext CreateContext(Node issuerPlayer) => new(
        new CommandId(Guid.NewGuid()),
        _matchId,
        _units.RegisterPlayer(issuerPlayer),
        checked((long)Engine.GetPhysicsFrames()));

    /// <summary>将纯 C# 权威订单事件转换为 Match 唯一的 Godot Signal。</summary>
    private void OnOrderStateChanged(UnitOrderStateChanged change)
    {
        if (change.Previous is null && change.Current.Kind != UnitOrderKind.Construct)
        {
            _pendingConstruction.Remove(change.Current.UnitId);
        }
        EmitSignal(
            SignalName.OrderStateChanged,
            change.Current.OrderId.Value.ToString("D"),
            change.Current.CommandId.Value.ToString("D"),
            change.Current.UnitId.Value.ToString("D"),
            change.Current.Kind.ToString(),
            change.Previous?.State.ToString() ?? string.Empty,
            change.Current.State.ToString(),
            change.Current.ReplacedByCommandId?.Value.ToString("D") ?? string.Empty);
    }

    /// <summary>仅在驱逐等待仍有效且现场、玩家、Worker 均存活时提交 Construct。</summary>
    private void StartPendingConstruction(UnitId workerId)
    {
        if (!_pendingConstruction.Remove(workerId, out var pending) ||
            !_units.TryGetNode(workerId, out var worker) ||
            !pending.Site.TryGetTarget(out var site) ||
            !pending.Issuer.TryGetTarget(out var issuer) ||
            !GodotObject.IsInstanceValid(site) || !site.IsInsideTree() ||
            !GodotObject.IsInstanceValid(issuer) || !issuer.IsInsideTree())
        {
            return;
        }
        ConstructUnits([worker], site, issuer);
    }

    /// <summary>将强类型订单快照转换为 GDScript 可读取的稳定字段集合。</summary>
    private static Godot.Collections.Dictionary ToGodot(UnitOrderSnapshot order) => new()
    {
        ["order_id"] = order.OrderId.Value.ToString("D"),
        ["command_id"] = order.CommandId.Value.ToString("D"),
        ["unit_id"] = order.UnitId.Value.ToString("D"),
        ["kind"] = order.Kind.ToString(),
        ["state"] = order.State.ToString(),
        ["replaced_by_command_id"] = order.ReplacedByCommandId?.Value.ToString("D") ?? string.Empty
    };

    /// <summary>把已接受订单连接到 Godot 移动完成和单位退出事件。</summary>
    private void TrackAcceptedOrders(CommandResult result)
    {
        foreach (var item in result.UnitResults)
        {
            if (!item.Accepted || item.OrderId is not { } orderId || !_units.TryGetNode(item.UnitId, out var unit))
            {
                continue;
            }

            var movement = unit.FindChild("Movement", false, false);
            if (movement is not null)
            {
                movement.Connect(
                    "movement_finished",
                    Callable.From(() => CompleteIfActive(item.UnitId, orderId)),
                    (uint)ConnectFlags.OneShot);
            }
            if (_deathTrackedUnits.Add(item.UnitId))
            {
                unit.TreeExiting += () => LoseActiveOrder(item.UnitId);
            }
        }
    }

    /// <summary>只跟踪持续订单的执行单位损失，不把内部接近移动误判为订单完成。</summary>
    private void TrackAcceptedPersistentOrders(CommandResult result)
    {
        foreach (var item in result.UnitResults)
        {
            if (!item.Accepted || item.OrderId is null || !_units.TryGetNode(item.UnitId, out var unit))
            {
                continue;
            }

            if (_deathTrackedUnits.Add(item.UnitId))
            {
                unit.TreeExiting += () => LoseActiveOrder(item.UnitId);
            }
        }
    }

    /// <summary>跟踪 Legacy Worker 采集任务的正常完成、目标失效与单位损失。</summary>
    private void TrackAcceptedGatherOrders(CommandResult result)
    {
        foreach (var item in result.UnitResults)
        {
            if (!item.Accepted || item.OrderId is not { } orderId ||
                !_units.TryGetNode(item.UnitId, out var worker))
            {
                continue;
            }

            worker.Connect(
                "gather_task_ended",
                Callable.From<string>(reason => EndGatherIfActive(item.UnitId, orderId, reason)),
                (uint)ConnectFlags.OneShot);
            if (_deathTrackedUnits.Add(item.UnitId))
            {
                worker.TreeExiting += () => LoseActiveOrder(item.UnitId);
            }
        }
    }

    /// <summary>跟踪 Approach/Follow 的明确完成或目标失效信号，避免中间寻路结束造成假完成。</summary>
    private void TrackAcceptedEntityMovement(
        CommandResult result,
        string signalName,
        UnitOrderKind expectedKind)
    {
        foreach (var item in result.UnitResults)
        {
            if (!item.Accepted || item.OrderId is not { } orderId ||
                !_units.TryGetNode(item.UnitId, out var unit))
            {
                continue;
            }

            unit.Connect(
                signalName,
                Callable.From<string>(reason => EndEntityMovementIfActive(
                    item.UnitId,
                    orderId,
                    expectedKind,
                    reason)),
                (uint)ConnectFlags.OneShot);
            if (_deathTrackedUnits.Add(item.UnitId))
            {
                unit.TreeExiting += () => LoseActiveOrder(item.UnitId);
            }
        }
    }

    /// <summary>仅在回调仍属于对应实体移动订单时转换其明确终态。</summary>
    private void EndEntityMovementIfActive(
        UnitId unitId,
        UnitOrderId orderId,
        UnitOrderKind expectedKind,
        string reason)
    {
        var active = _orders.FindActive(unitId);
        if (active?.OrderId != orderId || active.Kind != expectedKind)
        {
            return;
        }

        var state = reason switch
        {
            "Arrived" => UnitOrderState.Arrived,
            "TargetLost" => UnitOrderState.TargetLost,
            _ => UnitOrderState.Cancelled
        };
        _orders.Transition(orderId, state);
        if (state == UnitOrderState.Arrived)
        {
            UpdateGuardAnchor(unitId);
        }
    }

    /// <summary>仅在回调仍属于指定 Gather 订单时转换任务终态。</summary>
    private void EndGatherIfActive(UnitId unitId, UnitOrderId orderId, string reason)
    {
        var active = _orders.FindActive(unitId);
        if (active?.OrderId != orderId || active.Kind != UnitOrderKind.Gather)
        {
            return;
        }

        var state = reason switch
        {
            "Completed" => UnitOrderState.Completed,
            "TargetLost" => UnitOrderState.TargetLost,
            _ => UnitOrderState.Cancelled
        };
        _orders.Transition(orderId, state);
    }

    /// <summary>把 Legacy 实体攻击目标失效事件转换为对应类型的订单状态。</summary>
    private void TrackAcceptedAttacks(
        CommandResult result,
        string signalName,
        UnitOrderKind expectedKind)
    {
        foreach (var item in result.UnitResults)
        {
            if (!item.Accepted || item.OrderId is not { } orderId ||
                !_units.TryGetNode(item.UnitId, out var unit))
            {
                continue;
            }

            unit.Connect(
                signalName,
                Callable.From<string>(reason => EndAttackIfActive(
                    item.UnitId, orderId, expectedKind, reason)),
                (uint)ConnectFlags.OneShot);
            if (_deathTrackedUnits.Add(item.UnitId))
            {
                unit.TreeExiting += () => LoseActiveOrder(item.UnitId);
            }
        }
    }

    /// <summary>仅在回调仍属于指定实体攻击订单时转换目标失效状态。</summary>
    private void EndAttackIfActive(
        UnitId unitId,
        UnitOrderId orderId,
        UnitOrderKind expectedKind,
        string reason)
    {
        var active = _orders.FindActive(unitId);
        if (active?.OrderId == orderId && active.Kind == expectedKind)
        {
            _orders.Transition(
                orderId,
                reason == "TargetLost" ? UnitOrderState.TargetLost : UnitOrderState.Cancelled);
        }
    }

    /// <summary>仅在订单仍处于执行中时，将移动完成事件转换为 Arrived。</summary>
    private void CompleteIfActive(UnitId unitId, UnitOrderId orderId)
    {
        var active = _orders.FindActive(unitId);
        if (active?.OrderId == orderId && active.State == UnitOrderState.InProgress)
        {
            _orders.Transition(orderId, UnitOrderState.Arrived);
            UpdateGuardAnchor(unitId);
        }
    }

    /// <summary>在单位退出 SceneTree 时，将其当前活动订单转换为 UnitLost。</summary>
    private void LoseActiveOrder(UnitId unitId)
    {
        if (_orders.FindActive(unitId) is { } active)
        {
            _orders.Transition(active.OrderId, UnitOrderState.UnitLost);
        }
        _deathTrackedUnits.Remove(unitId);
    }

    /// <summary>把应用层订单语义映射为不反向依赖 Application 的查询枚举。</summary>
    private static OrderObservationKind MapOrderKind(UnitOrderKind kind) => kind switch
    {
        UnitOrderKind.Move => OrderObservationKind.Move,
        UnitOrderKind.ApproachEntity => OrderObservationKind.ApproachEntity,
        UnitOrderKind.FollowEntity => OrderObservationKind.FollowEntity,
        UnitOrderKind.ForceMove => OrderObservationKind.ForceMove,
        UnitOrderKind.GroundAttackMove => OrderObservationKind.GroundAttackMove,
        UnitOrderKind.EntityAttackMove => OrderObservationKind.EntityAttackMove,
        UnitOrderKind.TacticalWithdraw => OrderObservationKind.TacticalWithdraw,
        UnitOrderKind.Attack => OrderObservationKind.Attack,
        UnitOrderKind.ForceAttack => OrderObservationKind.ForceAttack,
        UnitOrderKind.GroundForceAttack => OrderObservationKind.GroundForceAttack,
        UnitOrderKind.Gather => OrderObservationKind.Gather,
        UnitOrderKind.Construct => OrderObservationKind.Construct,
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, "未知订单类型。")
    };

    /// <summary>活动索引只允许三种非终态，将其映射为查询枚举。</summary>
    private static OrderObservationState MapOrderState(UnitOrderState state) => state switch
    {
        UnitOrderState.Accepted => OrderObservationState.Accepted,
        UnitOrderState.InProgress => OrderObservationState.InProgress,
        UnitOrderState.Suspended => OrderObservationState.Suspended,
        _ => throw new InvalidOperationException($"终态订单 {state} 不应保留在活动索引中。")
    };

    /// <summary>把已接受停止命令后单位的实际位置记录为新警戒岗位点。</summary>
    private void UpdateGuardAnchorsForAccepted(CommandResult result)
    {
        foreach (var item in result.UnitResults.Where(item => item.Accepted))
        {
            UpdateGuardAnchor(item.UnitId);
        }
    }

    /// <summary>通知迁移期 Legacy 自动战斗 Action 立即重新读取权威策略。</summary>
    private void RefreshLegacyCombatPolicies(CommandResult result)
    {
        foreach (var item in result.UnitResults.Where(item => item.Accepted))
        {
            if (_units.TryGetNode(item.UnitId, out var unit) &&
                unit.HasMethod("request_legacy_refresh_combat_policy"))
            {
                unit.Call("request_legacy_refresh_combat_policy");
            }
        }
    }

    /// <summary>仅为 Guard 姿态单位更新岗位点，避免其他姿态保存无意义位置。</summary>
    private void UpdateGuardAnchor(UnitId unitId)
    {
        if (_combatPolicies.Get(unitId).EngagementStance == EngagementStance.Guard &&
            _units.TryGetNode(unitId, out var unit))
        {
            _combatPolicies.SetGuardAnchor(unitId, ToWorldPosition(unit));
        }
    }

    /// <summary>把 Godot 单位节点的当前位置转换为不依赖引擎的世界坐标。</summary>
    private static WorldPosition ToWorldPosition(Node unit)
    {
        var position = ((Node3D)unit).GlobalPosition;
        return new WorldPosition(position.X, position.Y, position.Z);
    }

    /// <summary>验证 Godot 世界坐标不含 NaN 或 Infinity。</summary>
    private static bool Finite(Vector3 value) =>
        float.IsFinite(value.X) && float.IsFinite(value.Y) && float.IsFinite(value.Z);

    /// <summary>弱引用保存一次驱逐后的待施工意图，避免延长 Node 生命周期。</summary>
    private sealed record PendingConstruction(
        WeakReference<Node> Site,
        WeakReference<Node> Issuer);
}
