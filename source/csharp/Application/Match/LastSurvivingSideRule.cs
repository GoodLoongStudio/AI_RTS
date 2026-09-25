using AI_RTS.Domain.Common;
using AI_RTS.Domain.Match;

namespace AI_RTS.Application.Match;

/// <summary>实现当前 Demo“最后仍有计分实体的阵营获胜”的歼灭规则。</summary>
/// <remarks>
/// “计分实体”由适配层标记（<see cref="GodotAdapter.Match.MatchOutcomeRuntime.RegisterCombatant"/>）：
/// 2026-09-21 起仅**可建造建筑**计入，因此“失去全部建造建筑”即被淘汰；
/// 本规则本身不认识建筑与单位的区别，只按 <see cref="MatchCombatant.CountsForElimination"/> 汇总。
/// </remarks>
public sealed class LastSurvivingSideRule : IMatchOutcomeRule
{
    /// <inheritdoc />
    public MatchRuleEvaluation Evaluate(
        IReadOnlyCollection<MatchParticipant> participants,
        IReadOnlyCollection<MatchCombatant> combatants)
    {
        var participantSides = participants
            .Select(item => item.SideId)
            .Distinct()
            .OrderBy(item => item.Value)
            .ToArray();
        if (participantSides.Length < 2)
        {
            return new MatchRuleEvaluation(
                MatchResolutionKind.InProgress,
                [],
                AliveSides(participants, combatants));
        }

        var surviving = AliveSides(participants, combatants);
        if (surviving.Count == 0)
        {
            return new MatchRuleEvaluation(MatchResolutionKind.Draw, [], surviving);
        }
        if (surviving.Count == 1)
        {
            return new MatchRuleEvaluation(MatchResolutionKind.Won, surviving, surviving);
        }
        return new MatchRuleEvaluation(MatchResolutionKind.InProgress, [], surviving);
    }

    /// <summary>按参与者归属汇总仍有计分实体的阵营侧。</summary>
    private static IReadOnlyList<MatchSideId> AliveSides(
        IReadOnlyCollection<MatchParticipant> participants,
        IReadOnlyCollection<MatchCombatant> combatants)
    {
        var sidesByPlayer = participants.ToDictionary(item => item.PlayerId, item => item.SideId);
        return combatants
            .Where(item => item.CountsForElimination && sidesByPlayer.ContainsKey(item.OwnerPlayerId))
            .Select(item => sidesByPlayer[item.OwnerPlayerId])
            .Distinct()
            .OrderBy(item => item.Value)
            .ToArray();
    }
}
