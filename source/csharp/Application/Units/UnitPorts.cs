using AI_RTS.Domain.Common;

namespace AI_RTS.Application.Units;

public readonly record struct UnitCommandSnapshot(UnitId UnitId, PlayerId OwnerId, bool CanMove);

public interface IUnitCommandUnitRepository
{
    UnitCommandSnapshot? Find(UnitId unitId);
}

public enum MovementPortError
{
    None,
    UnitUnavailable,
    NavigationUnavailable
}

public readonly record struct MovementPortResult(bool Accepted, MovementPortError Error)
{
    public static MovementPortResult Success() => new(true, MovementPortError.None);
    public static MovementPortResult Failure(MovementPortError error) => new(false, error);
}

public interface IUnitMovementPort
{
    MovementPortResult RequestMove(UnitId unitId, WorldPosition destination);
    MovementPortResult RequestHalt(UnitId unitId);
}
