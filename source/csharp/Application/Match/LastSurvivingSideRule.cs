using AI_RTS.Domain.Common;
using AI_RTS.Domain.Match;

namespace AI_RTS.Application.Match;

/// <summary>实现当前 Demo“最后仍有计分实体的阵营获胜”的歼灭规则。</summary>
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
