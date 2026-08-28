using AI_RTS.Application.Units;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Skills;

namespace AI_RTS.Application.Skills;

/// <summary>在单位上施加、刷新和到期移除状态。</summary>
public interface ISkillStatusService
{
    /// <summary>按叠加规则施加或更新状态，并立即应用属性修正。</summary>
    void Apply(UnitId targetId, SkillStatusDefinition status, long simulationMilliseconds);

    /// <summary>移除已到期状态并恢复对应属性。</summary>
    void Advance(long simulationMilliseconds);
}

/// <summary>每个单位每种状态最多一条；到期后恢复移速基线。</summary>
public sealed class SkillStatusService(IUnitMoveSpeedPort? moveSpeed = null) : ISkillStatusService
{
    private readonly Dictionary<(Guid Unit, string Status), ActiveStatus> _active = new();

    /// <inheritdoc />
    public void Apply(UnitId targetId, SkillStatusDefinition status, long simulationMilliseconds)
    {
        var key = (targetId.Value, status.Id);
        var expiresAt = checked(simulationMilliseconds + status.DurationMilliseconds);
        if (_active.TryGetValue(key, out var current))
        {
            switch (current.Stack)
            {
                case SkillStackRule.Ignore:
                    return;
                case SkillStackRule.Refresh:
                    _active[key] = current with { ExpiresAtMilliseconds = expiresAt };
                    return;
                case SkillStackRule.Overwrite:
                    ApplyModifier(targetId, status);
                    _active[key] = new ActiveStatus(
                        targetId, status, expiresAt, status.Stack);
                    return;
            }
        }

        ApplyModifier(targetId, status);
        _active[key] = new ActiveStatus(targetId, status, expiresAt, status.Stack);
    }

    /// <inheritdoc />
    public void Advance(long simulationMilliseconds)
    {
        var expired = _active.Values
            .Where(item => item.ExpiresAtMilliseconds <= simulationMilliseconds)
            .ToArray();
        foreach (var item in expired)
        {
            _active.Remove((item.TargetId.Value, item.Status.Id));
            if (item.Status.Attribute == SkillAttributeKind.MoveSpeed)
            {
                moveSpeed?.ClearMoveSpeedModifier(item.TargetId);
            }
        }
    }

    private void ApplyModifier(UnitId targetId, SkillStatusDefinition status)
    {
        if (status.Attribute == SkillAttributeKind.MoveSpeed)
        {
            moveSpeed?.ApplyMoveSpeedMultiplier(targetId, status.Modifier);
        }
    }

    private sealed record ActiveStatus(
        UnitId TargetId,
        SkillStatusDefinition Status,
        long ExpiresAtMilliseconds,
        SkillStackRule Stack);
}
