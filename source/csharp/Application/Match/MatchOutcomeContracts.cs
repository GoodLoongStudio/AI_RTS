using AI_RTS.Domain.Common;
using AI_RTS.Domain.Match;

namespace AI_RTS.Application.Match;

/// <summary>描述一条胜负规则的无版本计算结果。</summary>
/// <param name="Kind">规则计算出的阶段。</param>
/// <param name="WinningSideIds">获胜阵营侧。</param>
/// <param name="SurvivingSideIds">仍存活的阵营侧。</param>
public sealed record MatchRuleEvaluation(
    MatchResolutionKind Kind,
    IReadOnlyList<MatchSideId> WinningSideIds,
    IReadOnlyList<MatchSideId> SurvivingSideIds);

/// <summary>隔离具体地图玩法与对局参与者生命周期。</summary>
public interface IMatchOutcomeRule
{
    /// <summary>根据不可变参与者和实体快照计算当前结果。</summary>
    MatchRuleEvaluation Evaluate(
        IReadOnlyCollection<MatchParticipant> participants,
        IReadOnlyCollection<MatchCombatant> combatants);
}

/// <summary>维护单场对局参与者、计分实体及一次性终局状态。</summary>
public interface IMatchOutcomeService
{
    /// <summary>幂等登记一个参与者；相同身份的冲突数据会被拒绝。</summary>
    void RegisterParticipant(MatchParticipant participant);

    /// <summary>幂等登记一个战场实体；必须引用已登记玩家。</summary>
    void RegisterCombatant(MatchCombatant combatant);

    /// <summary>移除一个实体；未知或已经移除的身份不产生副作用。</summary>
    void RemoveCombatant(UnitId unitId);

    /// <summary>打开初始化门闩，并评估完整的初始对局快照。</summary>
    MatchResolution StartMatch();

    /// <summary>在批量事实更新后评估一次；终态不会被后续事实改写。</summary>
    MatchResolution Evaluate();

    /// <summary>由玩法一次性锁定终局；已进入终态后忽略。</summary>
    MatchResolution ResolveExplicit(
        MatchResolutionKind kind,
        IReadOnlyList<MatchSideId> winningSideIds);

    /// <summary>返回最近一次权威结果，不触发重新计算。</summary>
    MatchResolution GetSnapshot();
}
