using AI_RTS.Domain.Common;

namespace AI_RTS.Domain.Match;

/// <summary>描述参与当前对局胜负判定的玩家。</summary>
/// <param name="PlayerId">玩家稳定身份。</param>
/// <param name="SideId">玩家所属的胜负阵营侧。</param>
/// <param name="IsLocalHuman">是否为本机 Human，仅用于结果展示映射。</param>
public sealed record MatchParticipant(
    PlayerId PlayerId,
    MatchSideId SideId,
    bool IsLocalHuman);

/// <summary>描述一个可能影响歼灭胜负的战场实体。</summary>
/// <param name="UnitId">单位或建筑的稳定身份。</param>
/// <param name="OwnerPlayerId">实体当前所属玩家。</param>
/// <param name="CountsForElimination">是否计入所属阵营的存活判定。</param>
public sealed record MatchCombatant(
    UnitId UnitId,
    PlayerId OwnerPlayerId,
    bool CountsForElimination);

/// <summary>描述对局胜负规则的权威阶段。</summary>
public enum MatchResolutionKind
{
    /// <summary>当前仍不满足终局条件。</summary>
    InProgress,
    /// <summary>一个阵营侧已经获胜。</summary>
    Won,
    /// <summary>所有阵营侧在同一次评估中均已失去计分实体。</summary>
    Draw
}

/// <summary>提供不依赖 Godot 的对局胜负快照。</summary>
/// <param name="Kind">当前结果阶段。</param>
/// <param name="WinningSideIds">终局胜方；进行中或平局时为空。</param>
/// <param name="SurvivingSideIds">本次评估仍有计分实体的阵营侧。</param>
/// <param name="Version">只增不减的评估版本。</param>
public sealed record MatchResolution(
    MatchResolutionKind Kind,
    IReadOnlyList<MatchSideId> WinningSideIds,
    IReadOnlyList<MatchSideId> SurvivingSideIds,
    long Version);
