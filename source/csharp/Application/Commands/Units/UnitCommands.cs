using AI_RTS.Domain.Common;
using AI_RTS.Domain.Combat;

namespace AI_RTS.Application.Commands.Units;

/// <summary>请求一组单位强制移动到经过编队计算后的目标位置。</summary>
public sealed record ForceMoveUnitsCommand(
    IReadOnlyList<UnitId> UnitIds,
    WorldPosition Destination);

/// <summary>请求一组单位停止当前移动，并保留可暂停的上层任务。</summary>
public sealed record HaltMovementCommand(IReadOnlyList<UnitId> UnitIds);

/// <summary>请求一组单位切换持续交战姿态，不改变其独立开火策略。</summary>
public sealed record SetEngagementStanceCommand(
    IReadOnlyList<UnitId> UnitIds,
    EngagementStance Stance);

/// <summary>请求一组单位切换持续开火策略，不改变其独立交战姿态。</summary>
public sealed record SetFirePolicyCommand(
    IReadOnlyList<UnitId> UnitIds,
    FirePolicy Policy);
