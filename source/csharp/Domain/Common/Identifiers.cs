namespace AI_RTS.Domain.Common;

/// <summary>标识一场对局。</summary>
/// <param name="Value">进程内唯一的 Guid 值。</param>
public readonly record struct MatchId(Guid Value);

/// <summary>标识拥有单位与资源的玩家。</summary>
/// <param name="Value">进程内唯一的 Guid 值。</param>
public readonly record struct PlayerId(Guid Value);

/// <summary>标识一个可被命令或查询引用的单位。</summary>
/// <param name="Value">进程内唯一的 Guid 值。</param>
public readonly record struct UnitId(Guid Value);

/// <summary>标识一次批量命令调用。</summary>
/// <param name="Value">进程内唯一的 Guid 值。</param>
public readonly record struct CommandId(Guid Value);

/// <summary>标识一个单位独立执行的订单。</summary>
/// <param name="Value">进程内唯一的 Guid 值。</param>
public readonly record struct UnitOrderId(Guid Value);
