using System.Collections.Frozen;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Configuration;
using AI_RTS.Domain.Construction;
using AI_RTS.Domain.Economy;
using AI_RTS.Domain.Production;

namespace AI_RTS.Application.Configuration;

/// <summary>提供已经完整校验且在 Match 生命周期内不可变的数值定义。</summary>
public interface IGameBalanceCatalog
{
    /// <summary>读取配置格式、内容版本和内容指纹。</summary>
    BalanceConfigVersion Version { get; }

    /// <summary>枚举当前配置中的全部单位和建筑定义。</summary>
    IReadOnlyCollection<UnitTypeDefinition> UnitTypes { get; }

    /// <summary>枚举当前配置中的全部武器定义。</summary>
    IReadOnlyCollection<WeaponDefinition> Weapons { get; }

    /// <summary>枚举当前配置中的全部生产定义。</summary>
    IReadOnlyCollection<ProductionDefinition> Productions { get; }

    /// <summary>枚举当前配置中的全部建筑施工定义。</summary>
    IReadOnlyCollection<StructureConstructionDefinition> Constructions { get; }

    /// <summary>按稳定类型 ID 查询单位或建筑定义。</summary>
    UnitTypeDefinition? FindUnitType(UnitTypeId unitTypeId);

    /// <summary>按稳定 ID 查询武器定义。</summary>
    WeaponDefinition? FindWeapon(WeaponDefinitionId weaponId);

    /// <summary>按稳定 ID 查询弹头定义。</summary>
    WarheadDefinition? FindWarhead(WarheadDefinitionId warheadId);

    /// <summary>按稳定 ID 查询生产定义。</summary>
    ProductionDefinition? FindProduction(ProductionDefinitionId definitionId);

    /// <summary>按稳定 ID 查询建筑施工与放置定义。</summary>
    StructureConstructionDefinition? FindConstruction(StructureDefinitionId definitionId);

    /// <summary>按强类型资源种类查询采集定义。</summary>
    ResourceDefinition? FindResource(ResourceKind kind);
}

/// <summary>表示配置加载或校验失败的稳定类别。</summary>
public enum BalanceConfigErrorCode
{
    /// <summary>JSON 语法、根类型或基础字段类型无效。</summary>
    InvalidJson,

    /// <summary>JSON 含当前 schema 未声明的字段。</summary>
    UnknownProperty,

    /// <summary>schemaVersion 不是当前加载器支持的版本。</summary>
    UnsupportedSchemaVersion,

    /// <summary>必填字段或集合缺失。</summary>
    MissingValue,

    /// <summary>稳定 ID 为空或不符合 snake_case 约束。</summary>
    InvalidId,

    /// <summary>同一作用域内出现重复稳定 ID。</summary>
    DuplicateId,

    /// <summary>数值非有限、为负、为零非法或超出约定范围。</summary>
    InvalidNumber,

    /// <summary>字符串不能映射为受支持的强类型枚举。</summary>
    InvalidEnum,

    /// <summary>同一成本中重复声明一种资源。</summary>
    DuplicateResourceCost,

    /// <summary>配置引用了不存在的单位、武器、弹头或生产者。</summary>
    MissingReference,

    /// <summary>能力字段组合互相矛盾。</summary>
    InvalidCapability,

    /// <summary>当前配置档案缺少组合根明确要求的定义。</summary>
    MissingRequiredDefinition
}

/// <summary>描述一个可稳定定位的配置错误。</summary>
/// <param name="Code">供程序和测试判断的稳定错误码。</param>
/// <param name="Path">使用 JSONPath 风格表达的错误位置。</param>
/// <param name="Message">面向开发者的中文诊断信息。</param>
public sealed record BalanceConfigError(
    BalanceConfigErrorCode Code,
    string Path,
    string Message);

/// <summary>返回全量配置错误，且仅在零错误时携带可用 Catalog。</summary>
/// <param name="Catalog">成功时的不可变 Catalog；失败时为 null。</param>
/// <param name="Errors">按验证顺序保存的全部已发现错误。</param>
public sealed record BalanceConfigLoadResult(
    IGameBalanceCatalog? Catalog,
    IReadOnlyList<BalanceConfigError> Errors)
{
    /// <summary>指示配置是否完整加载且没有任何错误。</summary>
    public bool Succeeded => Catalog is not null && Errors.Count == 0;
}

/// <summary>声明一个 Match 配置档案必须包含的稳定定义集合。</summary>
/// <param name="UnitTypeIds">必须存在的单位和建筑类型。</param>
/// <param name="ProductionDefinitionIds">必须存在的生产定义。</param>
/// <param name="StructureDefinitionIds">必须存在的建筑施工定义。</param>
/// <param name="ResourceKinds">必须存在的资源定义。</param>
public sealed record BalanceConfigRequirements(
    IReadOnlySet<UnitTypeId> UnitTypeIds,
    IReadOnlySet<ProductionDefinitionId> ProductionDefinitionIds,
    IReadOnlySet<StructureDefinitionId> StructureDefinitionIds,
    IReadOnlySet<ResourceKind> ResourceKinds)
{
    /// <summary>创建不额外要求具体内容定义的通用配置约束。</summary>
    public static BalanceConfigRequirements Empty { get; } = new(
        Array.Empty<UnitTypeId>().ToFrozenSet(),
        Array.Empty<ProductionDefinitionId>().ToFrozenSet(),
        Array.Empty<StructureDefinitionId>().ToFrozenSet(),
        Array.Empty<ResourceKind>().ToFrozenSet());
}

/// <summary>提供当前 Demo 组合根要求的稳定定义清单。</summary>
public static class DemoBalanceRequirements
{
    /// <summary>构造当前九种实体、四种产品、五种建筑和两种资源的要求。</summary>
    public static BalanceConfigRequirements Create() => new(
        new UnitTypeId[]
        {
            new("drone"),
            new("worker"),
            new("helicopter"),
            new("tank"),
            new("command_center"),
            new("vehicle_factory"),
            new("aircraft_factory"),
            new("anti_ground_turret"),
            new("anti_air_turret")
        }.ToFrozenSet(),
        new ProductionDefinitionId[]
        {
            new("worker"),
            new("drone"),
            new("tank"),
            new("helicopter")
        }.ToFrozenSet(),
        new StructureDefinitionId[]
        {
            new("command_center"),
            new("vehicle_factory"),
            new("aircraft_factory"),
            new("anti_ground_turret"),
            new("anti_air_turret")
        }.ToFrozenSet(),
        new[] { ResourceKind.A, ResourceKind.B }.ToFrozenSet());
}
