using AI_RTS.Domain.Common;
using AI_RTS.Domain.Skills;

namespace AI_RTS.Application.Skills;

/// <summary>记录单位当前装配的非主动技能。</summary>
public interface ISkillLoadoutStore
{
    /// <summary>授予技能；重复授予保持幂等。</summary>
    void Grant(UnitId unitId, SkillDefinitionId skillId);

    /// <summary>移除该单位全部自动技能。</summary>
    void RevokeAll(UnitId unitId);

    /// <summary>枚举该单位已授予的技能。</summary>
    IReadOnlyCollection<SkillDefinitionId> SkillsOf(UnitId unitId);

    /// <summary>枚举全部装配对，供被动和条件评估。</summary>
    IReadOnlyCollection<(UnitId UnitId, SkillDefinitionId SkillId)> All();
}

/// <summary>进程内装配表，不跨对局持久化。</summary>
public sealed class InMemorySkillLoadoutStore : ISkillLoadoutStore
{
    private readonly Dictionary<Guid, HashSet<SkillDefinitionId>> _byUnit = new();

    /// <inheritdoc />
    public void Grant(UnitId unitId, SkillDefinitionId skillId)
    {
        if (!_byUnit.TryGetValue(unitId.Value, out var skills))
        {
            skills = [];
            _byUnit[unitId.Value] = skills;
        }

        skills.Add(skillId);
    }

    /// <inheritdoc />
    public void RevokeAll(UnitId unitId) => _byUnit.Remove(unitId.Value);

    /// <inheritdoc />
    public IReadOnlyCollection<SkillDefinitionId> SkillsOf(UnitId unitId) =>
        _byUnit.TryGetValue(unitId.Value, out var skills) ? skills.ToArray() : [];

    /// <inheritdoc />
    public IReadOnlyCollection<(UnitId UnitId, SkillDefinitionId SkillId)> All() =>
        _byUnit
            .SelectMany(pair => pair.Value.Select(skillId => (new UnitId(pair.Key), skillId)))
            .ToArray();
}
