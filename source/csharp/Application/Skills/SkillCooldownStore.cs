using AI_RTS.Domain.Common;
using AI_RTS.Domain.Skills;

namespace AI_RTS.Application.Skills;

/// <summary>按单位与技能记录冷却结束的模拟毫秒。</summary>
public interface ISkillCooldownStore
{
    /// <summary>当前模拟时刻该单位是否可以再次让该技能正式生效。</summary>
    bool IsReady(UnitId unitId, SkillDefinitionId skillId, long simulationMilliseconds);

    /// <summary>距离冷却结束的剩余模拟毫秒；已就绪则为 0。</summary>
    int RemainingMilliseconds(UnitId unitId, SkillDefinitionId skillId, long simulationMilliseconds);

    /// <summary>在正式生效时开始冷却；持续为零时不写入。</summary>
    void Start(
        UnitId unitId,
        SkillDefinitionId skillId,
        long simulationMilliseconds,
        int cooldownMilliseconds);

    /// <summary>清除该单位该技能的冷却，使其立即可再次正式生效。</summary>
    void Clear(UnitId unitId, SkillDefinitionId skillId);
}

/// <summary>用模拟毫秒保存冷却，暂停期间只要时刻不前进就不会结束。</summary>
public sealed class InMemorySkillCooldownStore : ISkillCooldownStore
{
    private readonly Dictionary<(Guid Unit, string Skill), long> _readyAt = new();

    /// <inheritdoc />
    public bool IsReady(UnitId unitId, SkillDefinitionId skillId, long simulationMilliseconds)
    {
        return RemainingMilliseconds(unitId, skillId, simulationMilliseconds) == 0;
    }

    /// <inheritdoc />
    public int RemainingMilliseconds(
        UnitId unitId,
        SkillDefinitionId skillId,
        long simulationMilliseconds)
    {
        if (!_readyAt.TryGetValue((unitId.Value, skillId.Value), out var readyAt) ||
            simulationMilliseconds >= readyAt)
        {
            return 0;
        }

        return checked((int)(readyAt - simulationMilliseconds));
    }

    /// <inheritdoc />
    public void Start(
        UnitId unitId,
        SkillDefinitionId skillId,
        long simulationMilliseconds,
        int cooldownMilliseconds)
    {
        if (cooldownMilliseconds <= 0)
        {
            return;
        }

        _readyAt[(unitId.Value, skillId.Value)] = checked(simulationMilliseconds + cooldownMilliseconds);
    }

    /// <inheritdoc />
    public void Clear(UnitId unitId, SkillDefinitionId skillId) =>
        _readyAt.Remove((unitId.Value, skillId.Value));
}
