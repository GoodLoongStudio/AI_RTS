using AI_RTS.Domain.Combat;
using AI_RTS.Domain.Common;

namespace AI_RTS.Application.Combat;

/// <summary>保存单位彼此独立的交战姿态与开火策略。</summary>
public readonly record struct CombatPolicySnapshot(
    EngagementStance EngagementStance,
    FirePolicy FirePolicy);

/// <summary>提供对局生命周期内单位战斗策略的权威读写入口。</summary>
public interface ICombatPolicyStore
{
    /// <summary>读取单位策略；尚未显式设置时返回兼容 Legacy 行为的默认值。</summary>
    CombatPolicySnapshot Get(UnitId unitId);

    /// <summary>只修改交战姿态，保留独立的开火策略。</summary>
    void SetEngagementStance(UnitId unitId, EngagementStance stance);

    /// <summary>只修改开火策略，保留独立的交战姿态。</summary>
    void SetFirePolicy(UnitId unitId, FirePolicy policy);
}

/// <summary>在当前 Match 进程中保存战斗策略，不承担存档持久化。</summary>
public sealed class InMemoryCombatPolicyStore : ICombatPolicyStore
{
    /// <summary>默认值保持现有单位主动索敌和追击的运行表现。</summary>
    private static readonly CombatPolicySnapshot DefaultPolicy = new(
        EngagementStance.Aggressive,
        FirePolicy.FireAtWill);

    /// <summary>仅保存已显式修改过的单位策略。</summary>
    private readonly Dictionary<UnitId, CombatPolicySnapshot> _policies = new();

    /// <inheritdoc />
    public CombatPolicySnapshot Get(UnitId unitId) =>
        _policies.TryGetValue(unitId, out var policy) ? policy : DefaultPolicy;

    /// <inheritdoc />
    public void SetEngagementStance(UnitId unitId, EngagementStance stance)
    {
        _policies[unitId] = Get(unitId) with { EngagementStance = stance };
    }

    /// <inheritdoc />
    public void SetFirePolicy(UnitId unitId, FirePolicy policy)
    {
        _policies[unitId] = Get(unitId) with { FirePolicy = policy };
    }
}
