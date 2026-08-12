namespace AI_RTS.Domain.Common;

public readonly record struct MatchId(Guid Value);
public readonly record struct PlayerId(Guid Value);
public readonly record struct UnitId(Guid Value);
public readonly record struct CommandId(Guid Value);
public readonly record struct UnitOrderId(Guid Value);
