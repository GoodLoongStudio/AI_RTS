using AI_RTS.Domain.Common;
using AI_RTS.Domain.Queries;

namespace AI_RTS.Application.Queries;

/// <summary>区分由组合根授予查询会话的可信来源。</summary>
public enum QuerySourceKind
{
    /// <summary>本地玩家界面或输入适配器。</summary>
    Human,
    /// <summary>传统确定性规则 AI。</summary>
    RuleAI,
    /// <summary>未来受操作点和网关约束的大模型 Agent。</summary>
    Agent,
    /// <summary>测试和诊断使用的全知来源。</summary>
    OmniscientDebug
}

/// <summary>描述查询是否被可靠执行。</summary>
public enum QueryStatus
{
    /// <summary>查询成功；集合值可以为空但不能缺失。</summary>
    Accepted,
    /// <summary>查询因会话、参数或权限问题被拒绝。</summary>
    Rejected
}

/// <summary>查询失败的稳定公开错误码。</summary>
public enum QueryErrorCode
{
    /// <summary>查询会话不存在或已失效。</summary>
    InvalidSession,
    /// <summary>范围或字段参数非法。</summary>
    InvalidRequest,
    /// <summary>己方实体不存在、已失效或并不属于观察者。</summary>
    OwnEntityUnavailable,
    /// <summary>观察者没有可用的资源账户。</summary>
    EconomyUnavailable
}

/// <summary>返回显式状态、不可变值和观察版本；成功空集合仍携带非空集合值。</summary>
/// <param name="Status">查询状态。</param>
/// <param name="Value">成功值；拒绝时为空。</param>
/// <param name="ErrorCode">拒绝原因；成功时为空。</param>
/// <param name="ObservationRevision">结果使用的统一观察快照版本。</param>
public sealed record QueryResult<T>(
    QueryStatus Status,
    T? Value,
    QueryErrorCode? ErrorCode,
    long ObservationRevision);

/// <summary>由可信组合根创建并绑定观察者与字段权限的不可变会话授权。</summary>
/// <param name="SessionId">随机且不可由普通调用方选择的会话 ID。</param>
/// <param name="ObserverPlayerId">会话唯一观察者。</param>
/// <param name="Source">可信来源类型。</param>
/// <param name="OwnFields">查询己方实体时允许返回的字段。</param>
/// <param name="VisibleFields">查询当前可见非己方实体时允许返回的字段。</param>
/// <param name="Omniscient">是否忽略视野；仅调试授权允许为真。</param>
public sealed record QuerySessionGrant(
    QuerySessionId SessionId,
    PlayerId ObserverPlayerId,
    QuerySourceKind Source,
    ObservationField OwnFields,
    ObservationField VisibleFields,
    bool Omniscient);

/// <summary>查询服务读取的单帧权威实体数据。</summary>
/// <param name="EntityId">统一稳定实体引用。</param>
/// <param name="OwnerPlayerId">拥有者；中立实体为空。</param>
/// <param name="Position">准确世界位置。</param>
/// <param name="TypeId">稳定类型键。</param>
/// <param name="CurrentHealth">当前生命值；无生命语义时为空。</param>
/// <param name="MaximumHealth">最大生命值；无生命语义时为空。</param>
/// <param name="RetainsLastKnownWhenHidden">失去视野后是否允许该实体留下观察记忆。</param>
/// <param name="VisibleToPlayers">当前能够观察该实体的玩家集合。</param>
public sealed record WorldEntitySnapshot(
    BattlefieldEntityId EntityId,
    PlayerId? OwnerPlayerId,
    WorldPosition Position,
    string TypeId,
    float? CurrentHealth,
    float? MaximumHealth,
    bool RetainsLastKnownWhenHidden,
    IReadOnlySet<PlayerId> VisibleToPlayers);

/// <summary>查询服务读取的单帧资源账户数据。</summary>
/// <param name="PlayerId">账户所有者。</param>
/// <param name="Observation">准确资源快照。</param>
public sealed record WorldEconomySnapshot(
    PlayerId PlayerId,
    ResourceAccountObservation Observation);

/// <summary>描述某观察者当前真实可见的一块圆形区域。</summary>
/// <param name="PlayerId">拥有该视野的玩家。</param>
/// <param name="Center">视野圆心。</param>
/// <param name="Radius">包含现有视野补偿后的正半径。</param>
public sealed record VisibilityRegionSnapshot(
    PlayerId PlayerId,
    WorldPosition Center,
    float Radius);

/// <summary>把同一观察版本的实体与经济数据封装为不可变读取批次。</summary>
/// <param name="Revision">单调递增的观察版本。</param>
/// <param name="Entities">按稳定实体 ID 排序前的实体集合。</param>
/// <param name="Economies">玩家资源账户集合。</param>
/// <param name="VisibilityRegions">用于确认最后已知位置是否被重新侦察的当前视野区域。</param>
public sealed record WorldObservationSnapshot(
    long Revision,
    IReadOnlyList<WorldEntitySnapshot> Entities,
    IReadOnlyList<WorldEconomySnapshot> Economies,
    IReadOnlyList<VisibilityRegionSnapshot> VisibilityRegions);

/// <summary>由 Adapter 在一次读取中捕获权威世界快照。</summary>
public interface IWorldObservationRepository
{
    /// <summary>捕获一个内部版本一致且不暴露场景 Node 的快照。</summary>
    WorldObservationSnapshot Capture();
}

/// <summary>解析玩家之间的关系；当前 Demo 默认除自己外均为敌对。</summary>
public interface IPlayerRelationResolver
{
    /// <summary>返回观察者与可空实体拥有者之间的关系。</summary>
    ObserverRelation Resolve(PlayerId observerPlayerId, PlayerId? ownerPlayerId);
}

/// <summary>供玩家、规则 AI、测试和未来 Agent 共享的受权限只读查询边界。</summary>
public interface IWorldQueryService
{
    /// <summary>查询观察者全部己方单位与建筑的准确快照。</summary>
    QueryResult<IReadOnlyList<EntityObservation>> GetOwnForces(
        QuerySessionId sessionId,
        ObservationField requestedFields);

    /// <summary>查询指定圆形范围内当前获准观察的实体。</summary>
    QueryResult<IReadOnlyList<EntityObservation>> ScanCircle(
        QuerySessionId sessionId,
        CircleObservationRequest request);

    /// <summary>只允许按稳定 ID 查询观察者自己的实体。</summary>
    QueryResult<EntityObservation> InspectOwnEntity(
        QuerySessionId sessionId,
        BattlefieldEntityId entityId,
        ObservationField requestedFields);

    /// <summary>查询观察者自己的准确资源账户。</summary>
    QueryResult<ResourceAccountObservation> GetOwnEconomy(QuerySessionId sessionId);
}

/// <summary>未来只向大模型 Gateway 暴露的强制操作点查询边界。</summary>
/// <remarks>实现必须在调用底层查询前原子扣费；当前重构只固定隔离边界。</remarks>
public interface IBudgetedWorldQueryService : IWorldQueryService
{
}
