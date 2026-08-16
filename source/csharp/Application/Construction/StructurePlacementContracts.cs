using AI_RTS.Domain.Common;
using AI_RTS.Domain.Construction;

namespace AI_RTS.Application.Construction;

/// <summary>表示建筑放置候选存在的稳定问题。</summary>
public enum StructurePlacementIssue
{
    /// <summary>建筑定义不存在或当前版本不支持。</summary>
    UnknownDefinition,

    /// <summary>位置或旋转包含非法数值。</summary>
    InvalidTransform,

    /// <summary>发出者当前没有放置该建筑的权限。</summary>
    NotAuthorized,

    /// <summary>完整 footprint 未处于当前玩家的有效视野内。</summary>
    NotVisible,

    /// <summary>完整 footprint 超出地图或规则允许的区域。</summary>
    OutOfBounds,

    /// <summary>地形、坡度、水域或特定环境不满足建筑定义。</summary>
    SurfaceNotBuildable,

    /// <summary>footprint 与敌军、建筑、施工现场、资源或其他权威阻挡物相交。</summary>
    Occupied,

    /// <summary>重叠友军移动单位无法全部分配安全驱逐落点。</summary>
    FriendlyDisplacementUnavailable,

    /// <summary>玩家当前不能支付完整建造成本。</summary>
    InsufficientResources,

    /// <summary>定义、空间或账户适配器暂时无法完成评估。</summary>
    ValidationUnavailable
}

/// <summary>请求只读评估一个建筑放置候选。</summary>
/// <param name="MatchId">候选所属对局。</param>
/// <param name="PlayerId">请求放置的玩家。</param>
/// <param name="Candidate">待评估的建筑、位置和朝向。</param>
public sealed record EvaluateStructurePlacementQuery(
    MatchId MatchId,
    PlayerId PlayerId,
    StructurePlacementCandidate Candidate);

/// <summary>返回一次只读放置评估及稳定主问题。</summary>
/// <param name="Candidate">经过合法角度规范化的候选；非法变换保留原值。</param>
/// <param name="IsValid">当前快照下是否允许提交。</param>
/// <param name="PrimaryIssue">供 UI 使用的最高优先级问题。</param>
/// <param name="Issues">去重并按固定优先级排序的全部安全问题。</param>
/// <param name="ObservedAccountVersion">评估时读取的账户版本；账户不可用时为空。</param>
public sealed record StructurePlacementEvaluation(
    StructurePlacementCandidate Candidate,
    bool IsValid,
    StructurePlacementIssue? PrimaryIssue,
    IReadOnlyList<StructurePlacementIssue> Issues,
    long? ObservedAccountVersion);

/// <summary>提供建筑定义、成本和 footprint 的稳定查询。</summary>
public interface IStructurePlacementDefinitionRepository
{
    /// <summary>按稳定 ID 查询建筑定义；不存在时返回 null。</summary>
    StructurePlacementDefinition? Find(StructureDefinitionId definitionId);
}

/// <summary>查询玩家当前是否有权放置指定建筑定义。</summary>
public interface IStructurePlacementAuthorizationPort
{
    /// <summary>返回指定玩家在当前对局能否使用该建筑定义。</summary>
    bool CanPlace(MatchId matchId, PlayerId playerId, StructureDefinitionId definitionId);
}

/// <summary>查询当前 Godot 世界对候选 footprint 的权威空间判断。</summary>
public interface IStructurePlacementWorldPort
{
    /// <summary>返回不含实体身份的空间问题集合。</summary>
    IReadOnlyList<StructurePlacementIssue> Evaluate(
        MatchId matchId,
        PlayerId playerId,
        StructurePlacementCandidate candidate,
        StructurePlacementDefinition definition);
}

/// <summary>提供建筑放置只读评估入口。</summary>
public interface IStructurePlacementService
{
    /// <summary>评估候选但不扣款、不创建现场且不锁定位置。</summary>
    StructurePlacementEvaluation Evaluate(EvaluateStructurePlacementQuery query);
}
