using AI_RTS.Domain.Common;

namespace AI_RTS.Application.Orders;

public enum UnitOrderState
{
    Accepted,
    InProgress,
    Suspended,
    Arrived,
    Unreachable,
    TargetLost,
    Cancelled,
    UnitLost
}

public sealed record UnitOrderSnapshot(
    UnitOrderId OrderId,
    CommandId CommandId,
    UnitId UnitId,
    UnitOrderState State,
    CommandId? ReplacedByCommandId = null);

public interface IUnitOrderStore
{
    UnitOrderSnapshot Create(CommandId commandId, UnitId unitId);
    UnitOrderSnapshot? FindActive(UnitId unitId);
    UnitOrderSnapshot? Find(UnitOrderId orderId);
    void Transition(UnitOrderId orderId, UnitOrderState state, CommandId? replacedBy = null);
}

public sealed class InMemoryUnitOrderStore : IUnitOrderStore
{
    private readonly Dictionary<UnitOrderId, UnitOrderSnapshot> _orders = new();
    private readonly Dictionary<UnitId, UnitOrderId> _activeByUnit = new();

    public UnitOrderSnapshot Create(CommandId commandId, UnitId unitId)
    {
        if (FindActive(unitId) is { } previous)
            Transition(previous.OrderId, UnitOrderState.Cancelled, commandId);

        var order = new UnitOrderSnapshot(
            new UnitOrderId(Guid.NewGuid()), commandId, unitId, UnitOrderState.Accepted);
        _orders.Add(order.OrderId, order);
        _activeByUnit[unitId] = order.OrderId;
        return order;
    }

    public UnitOrderSnapshot? FindActive(UnitId unitId) =>
        _activeByUnit.TryGetValue(unitId, out var id) ? Find(id) : null;

    public UnitOrderSnapshot? Find(UnitOrderId orderId) =>
        _orders.TryGetValue(orderId, out var order) ? order : null;

    public void Transition(UnitOrderId orderId, UnitOrderState state, CommandId? replacedBy = null)
    {
        if (!_orders.TryGetValue(orderId, out var current))
            return;

        _orders[orderId] = current with { State = state, ReplacedByCommandId = replacedBy };
        if (IsTerminal(state) && _activeByUnit.TryGetValue(current.UnitId, out var active) && active == orderId)
            _activeByUnit.Remove(current.UnitId);
    }

    private static bool IsTerminal(UnitOrderState state) => state is
        UnitOrderState.Arrived or UnitOrderState.Unreachable or UnitOrderState.TargetLost or
        UnitOrderState.Cancelled or UnitOrderState.UnitLost;
}
