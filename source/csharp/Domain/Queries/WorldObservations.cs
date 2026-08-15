using AI_RTS.Domain.Common;
using AI_RTS.Domain.Configuration;
using AI_RTS.Domain.Economy;
using AI_RTS.Domain.Production;

namespace AI_RTS.Domain.Queries;

/// <summary>描述观察者对实体信息的当前知识状态。</summary>
public enum ObservationState
{
    /// <summary>实体属于观察者，基础信息始终准确。</summary>
    Owned,
    /// <summary>实体当前处于观察者有效视野中。</summary>
    VisibleNow,
    /// <summary>仅保留先前确认的信息；首个纵向样例暂不生成此状态。</summary>
    LastKnown
}

/// <summary>声明调用方请求或结果实际包含的实体字段。</summary>
[Flags]
public enum ObservationField
{
    /// <summary>没有额外可选字段。</summary>
    None = 0,
    /// <summary>实体的当前或最后确认位置。</summary>
    Position = 1 << 0,
    /// <summary>实体稳定类型键。</summary>
    Type = 1 << 1,
    /// <summary>实体与观察者之间的阵营关系。</summary>
    Relation = 1 << 2,
    /// <summary>实体当前与最大生命值。</summary>
    Health = 1 << 3,
    /// <summary>建筑施工状态、整数进度与当前活动建造者数量。</summary>
    Construction = 1 << 4,
    /// <summary>生产建筑的容量与当前非终态队列。</summary>
    Production = 1 << 5,
    /// <summary>单位当前仍可继续变化的权威活动订单。</summary>
    Order = 1 << 6,
    /// <summary>首版支持的全部可选字段。</summary>
    All = Position | Type | Relation | Health | Construction | Production | Order
}

/// <summary>描述观察接口公开的建筑施工阶段。</summary>
public enum ConstructionObservationState
{
    /// <summary>建筑仍需 Worker 提供施工工作量。</summary>
    UnderConstruction,

    /// <summary>建筑已经完成施工并可正常工作。</summary>
    Completed
}

/// <summary>返回建筑施工生命周期、整数工作量和当前活动建造者数量。</summary>
/// <param name="State">查询接口公开的施工阶段。</param>
/// <param name="CompletedWork">已经完成的非负整数工作量。</param>
/// <param name="RequiredWork">完成施工所需的正整数工作量。</param>
/// <param name="ActiveBuilderCount">当前持有进行中 Construct 订单的 Worker 数量。</param>
public sealed record ConstructionObservation(
    ConstructionObservationState State,
    int CompletedWork,
    int RequiredWork,
    int ActiveBuilderCount);

/// <summary>返回一个生产项目的稳定产品类型、状态和整数工作量。</summary>
/// <param name="ItemId">生产项目的稳定身份。</param>
/// <param name="ProductTypeId">最终部署单位的稳定类型。</param>
/// <param name="State">项目当前生命周期状态。</param>
/// <param name="CompletedWork">已经完成的非负整数工作量。</param>
/// <param name="RequiredWork">完成生产所需的正整数工作量。</param>
public sealed record ProductionItemObservation(
    ProductionItemId ItemId,
    UnitTypeId ProductTypeId,
    ProductionItemState State,
    int CompletedWork,
    int RequiredWork);

/// <summary>返回生产建筑的队列容量和按当前顺序排列的非终态项目。</summary>
/// <param name="QueueLimit">生产建筑允许的最大非终态项目数量。</param>
/// <param name="Items">按实际队列顺序排列；空队列返回显式空集合。</param>
public sealed record ProductionObservation(
    int QueueLimit,
    IReadOnlyList<ProductionItemObservation> Items);

/// <summary>区分观察接口公开的单位订单语义。</summary>
public enum OrderObservationKind
{
    /// <summary>普通位置移动。</summary>
    Move,
    /// <summary>强制位置移动。</summary>
    ForceMove,
    /// <summary>对地移动并攻击。</summary>
    GroundAttackMove,
    /// <summary>向实体目标移动并攻击。</summary>
    EntityAttackMove,
    /// <summary>优先撤离的战术撤退。</summary>
    TacticalWithdraw,
    /// <summary>普通实体攻击。</summary>
    Attack,
    /// <summary>显式强制攻击。</summary>
    ForceAttack,
    /// <summary>持续对地强制攻击。</summary>
    GroundForceAttack,
    /// <summary>持续采集、返程和交付。</summary>
    Gather,
    /// <summary>前往施工现场并持续施工。</summary>
    Construct
}

/// <summary>区分观察接口公开的活动订单阶段。</summary>
public enum OrderObservationState
{
    /// <summary>订单已通过校验。</summary>
    Accepted,
    /// <summary>单位正在执行订单。</summary>
    InProgress,
    /// <summary>订单被保留且不会自动恢复。</summary>
    Suspended
}

/// <summary>记录下令时已确认的目标意图；不表示目标的实时状态。</summary>
/// <param name="EntityId">稳定实体目标；位置订单或无目标订单为空。</param>
/// <param name="Position">纯位置目标；实体订单或无目标订单为空。</param>
/// <param name="TypeId">下令时已知的目标稳定类型；未知时为空。</param>
public sealed record OrderTargetObservation(
    BattlefieldEntityId? EntityId,
    WorldPosition? Position,
    string? TypeId);

/// <summary>返回单位当前仍可继续变化的权威活动订单。</summary>
/// <param name="OrderId">订单稳定身份。</param>
/// <param name="Kind">订单语义。</param>
/// <param name="State">当前非终态阶段。</param>
/// <param name="Target">原始目标意图；没有目标时为空。</param>
public sealed record OrderObservation(
    UnitOrderId OrderId,
    OrderObservationKind Kind,
    OrderObservationState State,
    OrderTargetObservation? Target);

/// <summary>描述实体与查询观察者之间的关系。</summary>
public enum ObserverRelation
{
    /// <summary>实体属于查询观察者。</summary>
    Self,
    /// <summary>实体属于不可直接操作的盟友。</summary>
    Ally,
    /// <summary>实体属于敌对玩家。</summary>
    Enemy,
    /// <summary>实体不属于任何玩家。</summary>
    Neutral,
    /// <summary>当前规则无法确认阵营关系。</summary>
    Unknown
}

/// <summary>返回不包含 Godot Node 或可变内部状态的实体观察快照。</summary>
/// <param name="EntityId">统一稳定实体引用。</param>
/// <param name="State">该结果的知识状态。</param>
/// <param name="ReturnedFields">本次实际获准返回的可选字段。</param>
/// <param name="ObservedRevision">这些字段最后被该会话实际观察时的版本。</param>
/// <param name="Position">位置字段；未返回时为空。</param>
/// <param name="TypeId">稳定实体类型键；未返回时为空。</param>
/// <param name="Relation">阵营关系；未返回时为空。</param>
/// <param name="CurrentHealth">当前生命值；未返回时为空。</param>
/// <param name="MaximumHealth">最大生命值；未返回时为空。</param>
/// <param name="Construction">施工字段；非建筑、未请求或未获授权时为空。</param>
/// <param name="Production">生产字段；非生产建筑、未请求或未获授权时为空。</param>
/// <param name="Order">活动订单；空闲、未请求或未获授权时为空。</param>
public sealed record EntityObservation(
    BattlefieldEntityId EntityId,
    ObservationState State,
    ObservationField ReturnedFields,
    long ObservedRevision,
    WorldPosition? Position,
    string? TypeId,
    ObserverRelation? Relation,
    float? CurrentHealth,
    float? MaximumHealth,
    ConstructionObservation? Construction = null,
    ProductionObservation? Production = null,
    OrderObservation? Order = null);

/// <summary>描述一次圆形范围观察请求。</summary>
/// <param name="Center">范围中心。</param>
/// <param name="Radius">严格大于零的世界半径。</param>
/// <param name="RequestedFields">希望返回的可选字段。</param>
public sealed record CircleObservationRequest(
    WorldPosition Center,
    float Radius,
    ObservationField RequestedFields);

/// <summary>返回观察者自己的准确资源账户快照。</summary>
/// <param name="Balances">按资源种类稳定排序的整数余额。</param>
/// <param name="AccountVersion">权威资源账户版本。</param>
public sealed record ResourceAccountObservation(
    IReadOnlyList<ResourceAmount> Balances,
    long AccountVersion);
