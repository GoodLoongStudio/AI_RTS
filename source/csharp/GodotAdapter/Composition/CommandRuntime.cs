using AI_RTS.Application.Commands;
using AI_RTS.Application.Commands.Units;
using AI_RTS.Application.Combat;
using AI_RTS.Application.Orders;
using AI_RTS.Domain.Combat;
using AI_RTS.Domain.Common;
using AI_RTS.GodotAdapter.Navigation;
using AI_RTS.GodotAdapter.Combat;
using AI_RTS.GodotAdapter.Units;
using Godot;

namespace AI_RTS.GodotAdapter.Composition;

/// <summary>在 Match 生命周期内统一持有单位注册表、订单存储和权威命令服务。</summary>
public partial class CommandRuntime : Node
{
    /// <summary>维护本 Match 中 Godot Node 与稳定单位/玩家 ID 的映射。</summary>
    private readonly GodotUnitRegistry _units = new();

    /// <summary>保存本 Match 中所有控制器共享的单位订单状态。</summary>
    private readonly InMemoryUnitOrderStore _orders = new();

    /// <summary>保存本 Match 中所有控制器共享的单位交战姿态与开火策略。</summary>
    private readonly InMemoryCombatPolicyStore _combatPolicies = new();

    /// <summary>记录已订阅单位退出事件的 ID，避免多个控制器重复连接。</summary>
    private readonly HashSet<UnitId> _deathTrackedUnits = new();

    /// <summary>所有 Human、规则 AI 和未来外部 Adapter 共享的命令服务。</summary>
    private IUnitCommandService _commands = null!;

    /// <summary>当前 Match 的进程内稳定 ID。</summary>
    private MatchId _matchId;

    /// <summary>为当前 Match 创建唯一的命令服务及 Legacy 导航适配器。</summary>
    public override void _Ready()
    {
        _matchId = new MatchId(Guid.NewGuid());
        _commands = new UnitCommandService(
            _units,
            new LegacyMovementPort(_units),
            new LegacyAttackPort(_units),
            _orders,
            _combatPolicies);
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
        TrackAcceptedForceAttacks(result);
        return result;
    }

    /// <summary>提交地面强制攻击；当前武器能力会返回稳定拒绝。</summary>
    public CommandResult ForceAttackGround(
        IEnumerable<Node> unitNodes,
        Vector3 position,
        Node issuerPlayer)
    {
        var context = CreateContext(issuerPlayer);
        var unitIds = unitNodes.Select(_units.Register).ToArray();
        return _commands.ForceAttack(
            context,
            new ForceAttackCommand(
                unitIds,
                new GroundAttackTarget(new WorldPosition(position.X, position.Y, position.Z))));
    }

    /// <summary>只取消指定单位的显式 ForceAttack，不影响普通自动攻击。</summary>
    public CommandResult CancelForceAttack(IEnumerable<Node> unitNodes, Node issuerPlayer)
    {
        var context = CreateContext(issuerPlayer);
        var unitIds = unitNodes.Select(_units.Register).ToArray();
        return _commands.CancelForceAttack(context, new CancelForceAttackCommand(unitIds));
    }

    /// <summary>查询指定 Godot 单位当前权威交战姿态名称。</summary>
    public string GetEngagementStance(Node unitNode) =>
        _combatPolicies.Get(_units.Register(unitNode)).EngagementStance.ToString();

    /// <summary>查询指定 Godot 单位当前权威开火策略名称。</summary>
    public string GetFirePolicy(Node unitNode) =>
        _combatPolicies.Get(_units.Register(unitNode)).FirePolicy.ToString();

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

    private CommandContext CreateContext(Node issuerPlayer) => new(
        new CommandId(Guid.NewGuid()),
        _matchId,
        _units.RegisterPlayer(issuerPlayer),
        checked((long)Engine.GetPhysicsFrames()));

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

    /// <summary>把 Legacy 显式攻击目标失效事件转换为订单 TargetLost 状态。</summary>
    private void TrackAcceptedForceAttacks(CommandResult result)
    {
        foreach (var item in result.UnitResults)
        {
            if (!item.Accepted || item.OrderId is not { } orderId ||
                !_units.TryGetNode(item.UnitId, out var unit))
            {
                continue;
            }

            unit.Connect(
                "explicit_force_attack_ended",
                Callable.From<string>(reason => EndForceAttackIfActive(item.UnitId, orderId, reason)),
                (uint)ConnectFlags.OneShot);
            if (_deathTrackedUnits.Add(item.UnitId))
            {
                unit.TreeExiting += () => LoseActiveOrder(item.UnitId);
            }
        }
    }

    /// <summary>仅在回调仍属于当前 ForceAttack 时转换目标失效状态。</summary>
    private void EndForceAttackIfActive(UnitId unitId, UnitOrderId orderId, string reason)
    {
        var active = _orders.FindActive(unitId);
        if (active?.OrderId == orderId && active.Kind == UnitOrderKind.ForceAttack)
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
}
