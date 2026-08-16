using AI_RTS.Domain.Common;
using AI_RTS.Domain.Economy;

namespace AI_RTS.Domain.Construction;

/// <summary>标识建筑要求的可建造环境，例如地表、海面或天然气喷口。</summary>
/// <param name="Value">由项目配置维护的稳定环境键。</param>
public readonly record struct PlacementEnvironmentId(string Value);

/// <summary>表示建筑占地使用的二维局部坐标。</summary>
/// <param name="X">局部 X 坐标。</param>
/// <param name="Z">局部 Z 坐标。</param>
public readonly record struct PlanarPoint(float X, float Z);

/// <summary>表示不依赖引擎碰撞类型的建筑占地形状。</summary>
public abstract record StructurePlacementFootprint;

/// <summary>表示不受朝向影响的圆形占地。</summary>
/// <param name="Radius">占地半径，必须为有限正数。</param>
public sealed record CirclePlacementFootprint(float Radius) : StructurePlacementFootprint;

/// <summary>表示会随建筑朝向旋转的矩形占地。</summary>
/// <param name="HalfWidth">局部 X 方向半宽，必须为有限正数。</param>
/// <param name="HalfDepth">局部 Z 方向半深，必须为有限正数。</param>
public sealed record BoxPlacementFootprint(float HalfWidth, float HalfDepth) :
    StructurePlacementFootprint;

/// <summary>表示以建筑原点为局部坐标的凸多边形占地。</summary>
/// <param name="Vertices">按轮廓顺序排列且数量不少于三个的顶点。</param>
public sealed record ConvexPlacementFootprint(IReadOnlyList<PlanarPoint> Vertices) :
    StructurePlacementFootprint;

/// <summary>保存一个建筑定义参与放置判断的权威规则数据。</summary>
/// <param name="DefinitionId">稳定建筑定义 ID。</param>
/// <param name="Footprint">完整建筑占地。</param>
/// <param name="EnvironmentId">需要满足的可建造环境。</param>
/// <param name="ConstructionCost">创建施工现场时需要支付的完整成本。</param>
public sealed record StructurePlacementDefinition(
    StructureDefinitionId DefinitionId,
    StructurePlacementFootprint Footprint,
    PlacementEnvironmentId EnvironmentId,
    IReadOnlyList<ResourceAmount> ConstructionCost);

/// <summary>描述一次不含引擎对象的建筑放置候选。</summary>
/// <param name="DefinitionId">目标建筑定义。</param>
/// <param name="Position">候选世界坐标。</param>
/// <param name="YawRadians">绕世界 Y 轴的朝向弧度。</param>
public sealed record StructurePlacementCandidate(
    StructureDefinitionId DefinitionId,
    WorldPosition Position,
    float YawRadians);

/// <summary>表示施工现场不可逆的权威生命周期状态。</summary>
public enum ConstructionSiteState
{
    /// <summary>现场有效，等待或正在接受 Worker 工作量。</summary>
    Active,

    /// <summary>工作量达到要求，建筑正式可用。</summary>
    Completed,

    /// <summary>拥有者主动取消，退款最多执行一次。</summary>
    Cancelled,

    /// <summary>施工中被伤害或规则效果摧毁，不退款。</summary>
    Destroyed
}

/// <summary>记录施工现场的整数工作量、成本和权威版本。</summary>
/// <param name="SiteId">施工现场复用的稳定建筑 UnitId。</param>
/// <param name="OwnerId">现场拥有者。</param>
/// <param name="DefinitionId">现场对应的建筑定义。</param>
/// <param name="RequiredWork">完成施工所需的正整数工作量。</param>
/// <param name="CompletedWork">已经完成的工作量。</param>
/// <param name="ConstructionCost">主动取消时使用的原始完整成本。</param>
/// <param name="State">当前不可逆生命周期状态。</param>
/// <param name="Version">每次权威变化后递增的版本。</param>
public sealed record ConstructionSiteSnapshot(
    UnitId SiteId,
    PlayerId OwnerId,
    StructureDefinitionId DefinitionId,
    int RequiredWork,
    int CompletedWork,
    IReadOnlyList<ResourceAmount> ConstructionCost,
    ConstructionSiteState State,
    long Version);
