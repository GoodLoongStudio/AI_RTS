using AI_RTS.Application.Construction;
using AI_RTS.Domain.Common;
using AI_RTS.GodotAdapter.Units;
using System;

namespace AI_RTS.GodotAdapter.Construction;

/// <summary>按玩家已完工主基地数量提供施工进度倍率。</summary>
public sealed class GodotConstructionRatePort : IConstructionRatePort
{
    private readonly GodotCommandCenterRepository _commandCenters;
    private readonly double _bonusPerExtraCommandCenter;

    public GodotConstructionRatePort(
        GodotCommandCenterRepository commandCenters,
        double bonusPerExtraCommandCenter)
    {
        _commandCenters = commandCenters ?? throw new ArgumentNullException(nameof(commandCenters));
        _bonusPerExtraCommandCenter = Math.Max(0.0, bonusPerExtraCommandCenter);
    }

    public double ConstructionRateFor(PlayerId ownerId)
    {
        var extraCompletedCenters = Math.Max(
            0, _commandCenters.CountCompletedCommandCenters(ownerId) - 1);
        return 1.0 + extraCompletedCenters * _bonusPerExtraCommandCenter;
    }
}
