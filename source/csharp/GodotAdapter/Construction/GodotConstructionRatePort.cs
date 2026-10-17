using AI_RTS.Application.Construction;
using AI_RTS.Domain.Common;
using AI_RTS.GodotAdapter.Units;

namespace AI_RTS.GodotAdapter.Construction;

/// <summary>
/// 施工速率端口："每多一座已完工主基地，建筑施工速度 +50%"（2026-09-29 用户规则）。
/// 按工地所有者实时统计已完工且存活的主基地数量；1 座及以下恒为 1.0（无修正）。
/// 比例来自 balance 的 sameTypeBonusPerExtraBuilding（0 = 规则整体关闭）。
/// </summary>
public sealed class GodotConstructionRatePort(
    GodotCommandCenterRepository commandCenters,
    float bonusPerExtraBuilding) : IConstructionRatePort
{
    private readonly GodotCommandCenterRepository _commandCenters = commandCenters;
    private readonly float _bonusPerExtraBuilding = bonusPerExtraBuilding;

    /// <inheritdoc />
    public double ConstructionRateFor(PlayerId ownerId)
    {
        if (_bonusPerExtraBuilding <= 0.0f)
        {
            return 1.0;
        }
        // 第一座主基地是"基建本身"，不加成；从第二座起线性叠加（2 座 → ×1.5）。
        var completed = _commandCenters.CountCompletedCommandCenters(ownerId);
        return completed <= 1 ? 1.0 : 1.0 + _bonusPerExtraBuilding * (completed - 1);
    }
}
