using AI_RTS.Application.Selection;
using AI_RTS.Domain.Common;
using AI_RTS.GodotAdapter.Composition;

namespace AI_RTS.GodotAdapter.Selection;

/// <summary>把共享单位注册表转换为不暴露 Godot Node 的控制组成员快照。</summary>
public sealed class GodotControlGroupUnitRepository(CommandRuntime commands) :
    IControlGroupUnitRepository
{
    /// <inheritdoc />
    public ControlGroupUnitSnapshot? Find(UnitId unitId)
    {
        var snapshot = commands.FindRuntimeUnit(unitId);
        if (snapshot is null || !commands.TryGetRuntimeUnit(unitId, out var unit))
        {
            return null;
        }
        return new ControlGroupUnitSnapshot(
            unitId,
            snapshot.Value.OwnerId,
            unit.FindChild("Selection", false, false) is not null);
    }
}
