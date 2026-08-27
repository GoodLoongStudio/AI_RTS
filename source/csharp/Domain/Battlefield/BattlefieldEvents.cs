using AI_RTS.Domain.Common;

namespace AI_RTS.Domain.Battlefield;

/// <summary>玩家可合法获知、并允许镜头跳转的重要战场事件种类。</summary>
public enum BattlefieldEventKind
{
    /// <summary>己方单位或建筑正在受到攻击。</summary>
    OwnUnitUnderAttack,

    /// <summary>己方单位或建筑已经失效。</summary>
    OwnUnitLost,

    /// <summary>当前可见的敌方单位被摧毁。</summary>
    VisibleHostileLost,

    /// <summary>己方建筑完成施工。</summary>
    OwnConstructionFinished
}

/// <summary>一条已过滤情报边界的战场事件快照。</summary>
/// <param name="Sequence">单局内递增序号，越大越新。</param>
/// <param name="Kind">事件种类。</param>
/// <param name="Position">事件发生时的世界位置。</param>
/// <param name="IsImportant">是否允许作为 Space 跳转目标。</param>
public sealed record BattlefieldEventRecord(
    int Sequence,
    BattlefieldEventKind Kind,
    WorldPosition Position,
    bool IsImportant);
