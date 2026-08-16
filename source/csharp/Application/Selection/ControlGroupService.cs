using AI_RTS.Domain.Common;
using AI_RTS.Domain.Selection;

namespace AI_RTS.Application.Selection;

/// <summary>以内存稳定 ID 集合实现单局传统控制组，不依赖 Godot SceneTree。</summary>
public sealed class ControlGroupService(IControlGroupUnitRepository units) : IControlGroupService
{
    private readonly Dictionary<(PlayerId PlayerId, ControlGroupNumber Group), List<UnitId>>
        _groups = new();

    /// <inheritdoc />
    public ControlGroupSaveResult Replace(
        PlayerId playerId,
        ControlGroupNumber group,
        IReadOnlyList<UnitId> selectedUnitIds)
    {
        ArgumentNullException.ThrowIfNull(selectedUnitIds);
        if (!group.IsValid)
        {
            return new ControlGroupSaveResult(
                ControlGroupSaveStatus.Rejected,
                group,
                [],
                [],
                ControlGroupErrorCode.InvalidGroup);
        }

        var results = new List<ControlGroupMemberResult>();
        var accepted = new List<UnitId>();
        foreach (var unitId in selectedUnitIds.Distinct().OrderBy(item => item.Value))
        {
            var error = Validate(playerId, unitId);
            var isAccepted = error == ControlGroupErrorCode.None;
            results.Add(new ControlGroupMemberResult(unitId, isAccepted, error));
            if (isAccepted)
            {
                accepted.Add(unitId);
            }
        }

        _groups[(playerId, group)] = accepted;
        return new ControlGroupSaveResult(
            results.Any(item => !item.Accepted) ?
                ControlGroupSaveStatus.AcceptedWithFilteredMembers :
                ControlGroupSaveStatus.Accepted,
            group,
            accepted.AsReadOnly(),
            results.AsReadOnly(),
            ControlGroupErrorCode.None);
    }

    /// <inheritdoc />
    public ControlGroupRecallResult Recall(PlayerId playerId, ControlGroupNumber group)
    {
        if (!group.IsValid)
        {
            return new ControlGroupRecallResult(
                ControlGroupRecallStatus.Rejected,
                group,
                [],
                [],
                true,
                ControlGroupErrorCode.InvalidGroup);
        }

        var key = (playerId, group);
        if (!_groups.TryGetValue(key, out var stored))
        {
            return AcceptedRecall(group, [], []);
        }

        var valid = new List<UnitId>();
        var pruned = new List<UnitId>();
        foreach (var unitId in stored)
        {
            if (Validate(playerId, unitId) == ControlGroupErrorCode.None)
            {
                valid.Add(unitId);
            }
            else
            {
                pruned.Add(unitId);
            }
        }
        _groups[key] = valid;
        return AcceptedRecall(group, valid, pruned);
    }

    /// <inheritdoc />
    public ControlGroupSnapshot Inspect(PlayerId playerId, ControlGroupNumber group)
    {
        var result = Recall(playerId, group);
        return new ControlGroupSnapshot(
            group,
            result.UnitIds,
            result.IsEmpty,
            result.ErrorCode);
    }

    /// <inheritdoc />
    public void RemoveUnit(UnitId unitId)
    {
        foreach (var members in _groups.Values)
        {
            members.Remove(unitId);
        }
    }

    /// <summary>验证成员仍存在、属于请求玩家且可选择。</summary>
    private ControlGroupErrorCode Validate(PlayerId playerId, UnitId unitId)
    {
        var snapshot = units.Find(unitId);
        if (snapshot is null)
        {
            return ControlGroupErrorCode.UnitUnavailable;
        }
        if (snapshot.OwnerPlayerId != playerId)
        {
            return ControlGroupErrorCode.UnitNotOwned;
        }
        return snapshot.Selectable ?
            ControlGroupErrorCode.None : ControlGroupErrorCode.UnitNotSelectable;
    }

    /// <summary>创建显式成功空集合也包含所有稳定键的 Recall 结果。</summary>
    private static ControlGroupRecallResult AcceptedRecall(
        ControlGroupNumber group,
        IReadOnlyList<UnitId> valid,
        IReadOnlyList<UnitId> pruned) => new(
            ControlGroupRecallStatus.Accepted,
            group,
            valid.ToArray(),
            pruned.OrderBy(item => item.Value).ToArray(),
            valid.Count == 0,
            ControlGroupErrorCode.None);
}
