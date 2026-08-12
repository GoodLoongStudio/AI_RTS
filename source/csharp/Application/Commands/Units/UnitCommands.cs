using AI_RTS.Domain.Common;

namespace AI_RTS.Application.Commands.Units;

public sealed record MoveUnitsCommand(
    IReadOnlyList<UnitId> UnitIds,
    WorldPosition Destination);

public sealed record HaltMovementCommand(IReadOnlyList<UnitId> UnitIds);
