using AI_RTS.Domain.Common;
using AI_RTS.Domain.Selection;

namespace AI_RTS.Application.Selection;

/// <summary>描述一次控制组替换是否已经应用。</summary>
public enum ControlGroupSaveStatus
{
    /// <summary>所有输入成员均有效，替换已经应用。</summary>
    Accepted,
    /// <summary>至少一个输入成员被过滤，替换仍以剩余集合应用。</summary>
    AcceptedWithFilteredMembers,
    /// <summary>调用上下文非法，存储没有发生变化。</summary>
    Rejected
}

/// <summary>描述一次控制组读取是否成功。</summary>
public enum ControlGroupRecallStatus
{
    /// <summary>读取成功；成员集合可以为空。</summary>
    Accepted,
    /// <summary>编号或调用上下文非法。</summary>
    Rejected
}

/// <summary>控制组成员过滤和请求拒绝使用的稳定原因。</summary>
public enum ControlGroupErrorCode
{
    /// <summary>没有错误。</summary>
    None,
    /// <summary>控制组编号不在 1～9 范围内。</summary>
    InvalidGroup,
    /// <summary>单位不存在或已经失效。</summary>
    UnitUnavailable,
    /// <summary>单位不属于请求玩家。</summary>
    UnitNotOwned,
    /// <summary>实体当前不具备本地选择能力。</summary>
    UnitNotSelectable
}

/// <summary>Application 层校验控制组成员所需的最小单位快照。</summary>
/// <param name="UnitId">单位或建筑的稳定身份。</param>
/// <param name="OwnerPlayerId">当前拥有者。</param>
/// <param name="Selectable">是否允许作为玩家本地 Selection 成员。</param>
public sealed record ControlGroupUnitSnapshot(
    UnitId UnitId,
    PlayerId OwnerPlayerId,
    bool Selectable);

/// <summary>隔离控制组服务与 Godot Node、SceneTree 和选择表现。</summary>
public interface IControlGroupUnitRepository
{
    /// <summary>返回当前有效的最小成员快照；未知或失效时为空。</summary>
    ControlGroupUnitSnapshot? Find(UnitId unitId);
}

/// <summary>描述保存输入中的单个稳定成员是否进入新集合。</summary>
/// <param name="UnitId">输入单位身份。</param>
/// <param name="Accepted">是否保存到控制组。</param>
/// <param name="ErrorCode">过滤原因；成功时为 None。</param>
public sealed record ControlGroupMemberResult(
    UnitId UnitId,
    bool Accepted,
    ControlGroupErrorCode ErrorCode);

/// <summary>返回控制组替换状态、实际存储集合和逐成员结果。</summary>
/// <param name="Status">替换状态。</param>
/// <param name="Group">目标控制组编号。</param>
/// <param name="StoredUnitIds">替换后按稳定 ID 排序的成员。</param>
/// <param name="MemberResults">去重后按稳定 ID 排序的逐成员结果。</param>
/// <param name="ErrorCode">请求级错误；替换已应用时为 None。</param>
public sealed record ControlGroupSaveResult(
    ControlGroupSaveStatus Status,
    ControlGroupNumber Group,
    IReadOnlyList<UnitId> StoredUnitIds,
    IReadOnlyList<ControlGroupMemberResult> MemberResults,
    ControlGroupErrorCode ErrorCode);

/// <summary>提供当前有效控制组成员和本次被剔除的失效身份。</summary>
/// <param name="Status">读取状态。</param>
/// <param name="Group">目标控制组编号。</param>
/// <param name="UnitIds">当前有效成员。</param>
/// <param name="PrunedUnitIds">本次读取永久剔除的失效成员。</param>
/// <param name="IsEmpty">成功读取后集合是否为空。</param>
/// <param name="ErrorCode">请求级错误；成功时为 None。</param>
public sealed record ControlGroupRecallResult(
    ControlGroupRecallStatus Status,
    ControlGroupNumber Group,
    IReadOnlyList<UnitId> UnitIds,
    IReadOnlyList<UnitId> PrunedUnitIds,
    bool IsEmpty,
    ControlGroupErrorCode ErrorCode);

/// <summary>提供不触发 Godot Selection 的控制组诊断快照。</summary>
/// <param name="Group">目标控制组编号。</param>
/// <param name="UnitIds">当前有效成员。</param>
/// <param name="IsEmpty">集合是否为空。</param>
/// <param name="ErrorCode">编号非法时的稳定错误。</param>
public sealed record ControlGroupSnapshot(
    ControlGroupNumber Group,
    IReadOnlyList<UnitId> UnitIds,
    bool IsEmpty,
    ControlGroupErrorCode ErrorCode);

/// <summary>维护一场对局内按玩家隔离的传统控制组成员。</summary>
public interface IControlGroupService
{
    /// <summary>用经过所有权和可选择性过滤的输入替换指定控制组。</summary>
    ControlGroupSaveResult Replace(
        PlayerId playerId,
        ControlGroupNumber group,
        IReadOnlyList<UnitId> selectedUnitIds);

    /// <summary>返回有效成员，并永久剔除失效、失去归属或不可选择成员。</summary>
    ControlGroupRecallResult Recall(PlayerId playerId, ControlGroupNumber group);

    /// <summary>返回当前诊断快照；不会触发任何 Godot Selection 表现。</summary>
    ControlGroupSnapshot Inspect(PlayerId playerId, ControlGroupNumber group);

    /// <summary>从全部玩家控制组中主动删除退出对局的单位身份。</summary>
    void RemoveUnit(UnitId unitId);
}
