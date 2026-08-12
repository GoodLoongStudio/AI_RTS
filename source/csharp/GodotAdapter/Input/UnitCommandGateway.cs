using AI_RTS.Application.Commands;
using AI_RTS.Application.Commands.Units;
using AI_RTS.Application.Orders;
using AI_RTS.Domain.Common;
using AI_RTS.GodotAdapter.Navigation;
using AI_RTS.GodotAdapter.Units;
using Godot;

namespace AI_RTS.GodotAdapter.Input;

/// <summary>为 GDScript 输入层提供稳定的 C# 单位命令入口和结果转换。</summary>
public partial class UnitCommandGateway : Node
{
    /// <summary>维护 Godot Node 与稳定单位/玩家 ID 的映射。</summary>
    private readonly GodotUnitRegistry _units = new();
    /// <summary>保存当前对局中的单位订单状态。</summary>
    private readonly InMemoryUnitOrderStore _orders = new();
    /// <summary>记录已订阅单位退出事件的 ID，避免重复连接。</summary>
    private readonly HashSet<UnitId> _deathTrackedUnits = new();
    /// <summary>当前 Gateway 使用的权威命令服务。</summary>
    private IUnitCommandService _commands = null!;

    /// <summary>当前运行对局的进程内稳定 ID。</summary>
    private MatchId _matchId;

    /// <summary>创建当前对局使用的命令服务及 Godot 导航适配器。</summary>
    public override void _Ready()
    {
        _matchId = new MatchId(Guid.NewGuid());
        _commands = new UnitCommandService(_units, new LegacyMovementPort(_units), _orders);
    }

    /// <summary>接收 GDScript 单位节点并提交批量移动命令。</summary>
    public Godot.Collections.Dictionary MoveUnits(
        Godot.Collections.Array<Node> unitNodes, Vector3 destination, Node issuerPlayer)
    {
        var context = CreateContext(issuerPlayer);
        var ids = unitNodes.Select(_units.Register).ToArray();
        var result = _commands.Move(context,
            new MoveUnitsCommand(ids, new WorldPosition(destination.X, destination.Y, destination.Z)));
        TrackAcceptedOrders(result);
        return ToGodot(result);
    }

    /// <summary>接收 GDScript 单位节点并提交停止移动命令。</summary>
    public Godot.Collections.Dictionary HaltMovement(
        Godot.Collections.Array<Node> unitNodes, Node issuerPlayer)
    {
        var context = CreateContext(issuerPlayer);
        var ids = unitNodes.Select(_units.Register).ToArray();
        var result = _commands.HaltMovement(context, new HaltMovementCommand(ids));
        return ToGodot(result);
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
                movement.Connect("movement_finished", Callable.From(() => CompleteIfActive(item.UnitId, orderId)),
                    (uint)ConnectFlags.OneShot);
            }
            if (_deathTrackedUnits.Add(item.UnitId))
            {
                unit.TreeExiting += () => LoseActiveOrder(item.UnitId);
            }
        }
    }

    /// <summary>仅在订单仍处于执行中时，将移动完成事件转换为 Arrived。</summary>
    private void CompleteIfActive(UnitId unitId, UnitOrderId orderId)
    {
        var active = _orders.FindActive(unitId);
        if (active?.OrderId == orderId && active.State == UnitOrderState.InProgress)
        {
            _orders.Transition(orderId, UnitOrderState.Arrived);
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

    /// <summary>将强类型 CommandResult 转换为 GDScript 可读取的 Dictionary。</summary>
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
}
