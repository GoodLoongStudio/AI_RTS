using AI_RTS.Application.Construction;
using AI_RTS.Domain.Common;

namespace AI_RTS.GodotAdapter.Construction;

/// <summary>以本局权威施工服务判断一个玩家是否仍有活动中的工地。</summary>
public sealed class GodotStructurePlacementConstructionStatePort : IStructurePlacementConstructionStatePort
{
    private readonly IConstructionService _construction;
    private readonly MatchId _matchId;

    public GodotStructurePlacementConstructionStatePort(
        IConstructionService construction,
        MatchId matchId)
    {
        _construction = construction;
        _matchId = matchId;
    }

    public bool HasActiveConstructionSite(MatchId matchId, PlayerId playerId)
    {
        // 此端口仅服务当前 Match；不允许跨局绕过单工地限制。
        return matchId != _matchId || _construction.HasActiveConstructionSite(playerId);
    }
}
