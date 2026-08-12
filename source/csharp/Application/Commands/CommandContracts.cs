using AI_RTS.Domain.Common;

namespace AI_RTS.Application.Commands;

public sealed record CommandContext(
    CommandId CommandId,
    MatchId MatchId,
    PlayerId IssuerPlayerId,
    long SimulationTick);

public enum CommandStatus
{
    Accepted,
    PartiallyAccepted,
    Rejected
}

public enum CommandErrorCode
{
    None,
    EmptyUnitSet,
    UnitNotFound,
    UnitNotOwned,
    UnitCannotMove,
    InvalidDestination,
    NavigationUnavailable,
    MatchNotRunning
}

public sealed record UnitCommandResult(
    UnitId UnitId,
    bool Accepted,
    CommandErrorCode ErrorCode,
    UnitOrderId? OrderId = null);

public sealed record CommandResult(
    CommandId CommandId,
    CommandStatus Status,
    IReadOnlyList<UnitCommandResult> UnitResults);
