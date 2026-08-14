using AI_RTS.Domain.Common;

namespace AI_RTS.Application.Orders;

/// <summary>区分一次性单位订单的执行语义，供停止、取消和状态跟踪精确判断。</summary>
public enum UnitOrderKind
{
    /// <summary>要求单位优先到达指定位置的普通移动订单。</summary>
    Move,

    /// <summary>要求单位优先到达指定位置的强制移动订单。</summary>
    ForceMove,

    /// <summary>允许按交战姿态暂停推进并清除途中敌人的地面移动攻击订单。</summary>
    GroundAttackMove,

    /// <summary>保留敌方实体最终目标身份、允许途中接敌并在清敌后继续追踪的移动攻击订单。</summary>
    EntityAttackMove,

    /// <summary>沿导航路径倒车，或由不具备倒车能力的单位退化执行普通移动。</summary>
    TacticalWithdraw,

    /// <summary>受持续开火策略约束、只允许敌方实体目标的普通攻击订单。</summary>
    Attack,

    /// <summary>带订单级临时开火授权的显式实体强制攻击。</summary>
    ForceAttack,

    /// <summary>持续攻击纯地面坐标，不依赖实体目标身份。</summary>
    GroundForceAttack,

    /// <summary>持续执行采集、返程与交付循环的 Worker 工作订单。</summary>
    Gather,

    /// <summary>前往己方施工现场并在到位后持续贡献工作量。</summary>
    Construct
}

/// <summary>表示单个单位订单在生命周期中的权威状态。</summary>
public enum UnitOrderState
{
    /// <summary>订单已通过校验并被接收。</summary>
    Accepted,
    /// <summary>单位正在执行订单。</summary>
    InProgress,
    /// <summary>订单被保留，但不会自动继续执行。</summary>
    Suspended,
    /// <summary>单位已经到达目标位置。</summary>
    Arrived,
    /// <summary>持续任务按规则正常完成。</summary>
    Completed,
    /// <summary>重新寻路后仍无法抵达目标。</summary>
    Unreachable,
    /// <summary>依赖的实体目标已经消失。</summary>
    TargetLost,
    /// <summary>订单被新命令或明确取消操作终止。</summary>
    Cancelled,
    /// <summary>执行订单的单位已经损失。</summary>
    UnitLost
}

/// <summary>记录一个单位订单的身份、来源命令和当前状态。</summary>
public sealed record UnitOrderSnapshot(
    UnitOrderId OrderId,
    CommandId CommandId,
    UnitId UnitId,
    UnitOrderKind Kind,
    UnitOrderState State,
    CommandId? ReplacedByCommandId = null);

/// <summary>记录一次权威订单状态变化，供表现层、任务系统和受权限约束的观察适配器消费。</summary>
public sealed record UnitOrderStateChanged(
    UnitOrderSnapshot? Previous,
    UnitOrderSnapshot Current);

/// <summary>管理单位订单的创建、查询与状态转换。</summary>
public interface IUnitOrderStore
{
    /// <summary>在订单成功创建或状态实际发生变化后发布权威状态事件。</summary>
    event Action<UnitOrderStateChanged>? StateChanged;

    /// <summary>为单位创建新订单，并取消其旧活动订单。</summary>
    UnitOrderSnapshot Create(CommandId commandId, UnitId unitId, UnitOrderKind kind);

    /// <summary>查询单位当前仍可继续变化的活动订单。</summary>
    UnitOrderSnapshot? FindActive(UnitId unitId);

    /// <summary>按订单 ID 查询快照。</summary>
    UnitOrderSnapshot? Find(UnitOrderId orderId);

    /// <summary>将订单转换到指定状态。</summary>
    void Transition(UnitOrderId orderId, UnitOrderState state, CommandId? replacedBy = null);
}

/// <summary>在当前对局进程中保存单位订单，不承担存档持久化。</summary>
public sealed class InMemoryUnitOrderStore : IUnitOrderStore
{
    /// <inheritdoc />
    public event Action<UnitOrderStateChanged>? StateChanged;

    /// <summary>按订单 ID 保存全部订单快照。</summary>
    private readonly Dictionary<UnitOrderId, UnitOrderSnapshot> _orders = new();

    /// <summary>保存每个单位当前活动订单的索引。</summary>
    private readonly Dictionary<UnitId, UnitOrderId> _activeByUnit = new();

    /// <inheritdoc />
    public UnitOrderSnapshot Create(CommandId commandId, UnitId unitId, UnitOrderKind kind)
    {
        if (FindActive(unitId) is { } previous)
        {
            Transition(previous.OrderId, UnitOrderState.Cancelled, commandId);
        }

        var order = new UnitOrderSnapshot(
            new UnitOrderId(Guid.NewGuid()), commandId, unitId, kind, UnitOrderState.Accepted);
        _orders.Add(order.OrderId, order);
        _activeByUnit[unitId] = order.OrderId;
        StateChanged?.Invoke(new UnitOrderStateChanged(null, order));
        return order;
    }

    /// <inheritdoc />
    public UnitOrderSnapshot? FindActive(UnitId unitId) =>
        _activeByUnit.TryGetValue(unitId, out var id) ? Find(id) : null;

    /// <inheritdoc />
    public UnitOrderSnapshot? Find(UnitOrderId orderId) =>
        _orders.TryGetValue(orderId, out var order) ? order : null;

    /// <inheritdoc />
    public void Transition(UnitOrderId orderId, UnitOrderState state, CommandId? replacedBy = null)
    {
        if (!_orders.TryGetValue(orderId, out var current))
        {
            return;
        }

        var updated = current with { State = state, ReplacedByCommandId = replacedBy };
        if (updated == current)
        {
            return;
        }

        _orders[orderId] = updated;
        if (IsTerminal(state) &&
            _activeByUnit.TryGetValue(current.UnitId, out var active) &&
            active == orderId)
        {
            _activeByUnit.Remove(current.UnitId);
        }
        StateChanged?.Invoke(new UnitOrderStateChanged(current, updated));
    }

    private static bool IsTerminal(UnitOrderState state) => state is
        UnitOrderState.Arrived or UnitOrderState.Completed or UnitOrderState.Unreachable or
        UnitOrderState.TargetLost or UnitOrderState.Cancelled or UnitOrderState.UnitLost;
}
