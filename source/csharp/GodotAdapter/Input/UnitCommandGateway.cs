using AI_RTS.Application.Commands;
using AI_RTS.Application.Commands.Units;
using AI_RTS.Application.Orders;
using AI_RTS.Domain.Common;
using AI_RTS.GodotAdapter.Navigation;
using AI_RTS.GodotAdapter.Units;
using Godot;

namespace AI_RTS.GodotAdapter.Input;

public partial class UnitCommandGateway : Node
{
    private readonly GodotUnitRegistry _units = new();
    private readonly InMemoryUnitOrderStore _orders = new();
    private readonly HashSet<UnitId> _deathTrackedUnits = new();
    private IUnitCommandService _commands = null!;
    private MatchId _matchId;

    public override void _Ready()
    {
        _matchId = new MatchId(Guid.NewGuid());
        _commands = new UnitCommandService(_units, new LegacyMovementPort(_units), _orders);
    }

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

    public Godot.Collections.Dictionary HaltMovement(
        Godot.Collections.Array<Node> unitNodes, Node issuerPlayer)
    {
        var context = CreateContext(issuerPlayer);
        var ids = unitNodes.Select(_units.Register).ToArray();
        var result = _commands.HaltMovement(context, new HaltMovementCommand(ids));
        return ToGodot(result);
    }

    public string GetActiveOrderState(Node unitNode)
    {
        var unitId = _units.Register(unitNode);
        return _orders.FindActive(unitId)?.State.ToString() ?? string.Empty;
    }

    public string GetOrderState(string orderId) =>
        Guid.TryParse(orderId, out var value) ?
            _orders.Find(new UnitOrderId(value))?.State.ToString() ?? string.Empty : string.Empty;

    private CommandContext CreateContext(Node issuerPlayer) => new(
        new CommandId(Guid.NewGuid()),
        _matchId,
        _units.RegisterPlayer(issuerPlayer),
        checked((long)Engine.GetPhysicsFrames()));

    private void TrackAcceptedOrders(CommandResult result)
    {
        foreach (var item in result.UnitResults)
        {
            if (!item.Accepted || item.OrderId is not { } orderId || !_units.TryGetNode(item.UnitId, out var unit))
                continue;

            var movement = unit.FindChild("Movement", false, false);
            if (movement is not null)
            {
                movement.Connect("movement_finished", Callable.From(() => CompleteIfActive(item.UnitId, orderId)),
                    (uint)ConnectFlags.OneShot);
            }
            if (_deathTrackedUnits.Add(item.UnitId))
                unit.TreeExiting += () => LoseActiveOrder(item.UnitId);
        }
    }

    private void CompleteIfActive(UnitId unitId, UnitOrderId orderId)
    {
        var active = _orders.FindActive(unitId);
        if (active?.OrderId == orderId && active.State == UnitOrderState.InProgress)
            _orders.Transition(orderId, UnitOrderState.Arrived);
    }

    private void LoseActiveOrder(UnitId unitId)
    {
        if (_orders.FindActive(unitId) is { } active)
            _orders.Transition(active.OrderId, UnitOrderState.UnitLost);
        _deathTrackedUnits.Remove(unitId);
    }

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
