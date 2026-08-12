using AI_RTS.Domain.Common;

namespace AI_RTS.Application.Commands.Units;

/// <summary>请求一组单位分别移动到经过编队计算后的目标位置。</summary>
public sealed record MoveUnitsCommand(
    IReadOnlyList<UnitId> UnitIds,
    WorldPosition Destination);

/// <summary>请求一组单位停止当前移动，并保留可暂停的上层任务。</summary>
public sealed record HaltMovementCommand(IReadOnlyList<UnitId> UnitIds);
