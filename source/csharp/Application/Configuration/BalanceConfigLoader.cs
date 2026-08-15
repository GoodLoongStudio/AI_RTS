using System.Collections.Frozen;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using AI_RTS.Domain.Combat;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Configuration;
using AI_RTS.Domain.Construction;
using AI_RTS.Domain.Economy;
using AI_RTS.Domain.Production;

namespace AI_RTS.Application.Configuration;

/// <summary>把版本化 JSON 严格校验并映射为不可变游戏数值 Catalog。</summary>
public sealed class BalanceConfigLoader
{
    /// <summary>当前加载器唯一支持的配置结构版本。</summary>
    public const int SupportedSchemaVersion = 1;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = false,
        AllowTrailingCommas = false,
        ReadCommentHandling = JsonCommentHandling.Disallow
    };

    /// <summary>解析并完整校验 JSON；任一错误都会阻止 Catalog 创建。</summary>
    public BalanceConfigLoadResult Load(
        string json,
        BalanceConfigRequirements? requirements = null)
    {
        if (string.IsNullOrWhiteSpace(json))
        {
            return Failed(new BalanceConfigError(
                BalanceConfigErrorCode.InvalidJson,
                "$",
                "配置内容不能为空。"));
        }

        BalanceConfigDto? dto;
        try
        {
            dto = JsonSerializer.Deserialize<BalanceConfigDto>(json, JsonOptions);
        }
        catch (JsonException exception)
        {
            return Failed(new BalanceConfigError(
                BalanceConfigErrorCode.InvalidJson,
                string.IsNullOrWhiteSpace(exception.Path) ? "$" : exception.Path,
                $"JSON 无法解析：{exception.Message}"));
        }
        catch (NotSupportedException exception)
        {
            return Failed(new BalanceConfigError(
                BalanceConfigErrorCode.InvalidJson,
                "$",
                $"JSON 类型不受支持：{exception.Message}"));
        }

        if (dto is null)
        {
            return Failed(new BalanceConfigError(
                BalanceConfigErrorCode.InvalidJson,
                "$",
                "JSON 根对象不能为 null。"));
        }

        var errors = Validate(dto, requirements ?? BalanceConfigRequirements.Empty);
        if (errors.Count != 0)
        {
            return new BalanceConfigLoadResult(null, errors.AsReadOnly());
        }

        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(json)))
            .ToLowerInvariant();
        return new BalanceConfigLoadResult(BuildCatalog(dto, hash), Array.Empty<BalanceConfigError>());
    }

    /// <summary>验证所有 DTO，并尽量一次返回全部相互独立的问题。</summary>
    private static List<BalanceConfigError> Validate(
        BalanceConfigDto dto,
        BalanceConfigRequirements requirements)
    {
        var errors = new List<BalanceConfigError>();
        CollectUnknownProperties(dto, errors);

        if (dto.SchemaVersion is null)
        {
            Add(errors, BalanceConfigErrorCode.MissingValue, "$.schemaVersion",
                "必须声明 schemaVersion。");
        }
        else if (dto.SchemaVersion != SupportedSchemaVersion)
        {
            Add(errors, BalanceConfigErrorCode.UnsupportedSchemaVersion, "$.schemaVersion",
                $"仅支持 schemaVersion={SupportedSchemaVersion}。");
        }
        if (string.IsNullOrWhiteSpace(dto.ContentVersion))
        {
            Add(errors, BalanceConfigErrorCode.MissingValue, "$.contentVersion",
                "必须声明非空 contentVersion。");
        }

        ValidateRequiredCollection(dto.Resources, "$.resources", errors);
        ValidateRequiredCollection(dto.Warheads, "$.warheads", errors);
        ValidateRequiredCollection(dto.Weapons, "$.weapons", errors);
        ValidateRequiredCollection(dto.UnitTypes, "$.unitTypes", errors);
        ValidateRequiredCollection(dto.Productions, "$.productions", errors);
        ValidateRequiredCollection(dto.Constructions, "$.constructions", errors);

        ValidateResources(dto.Resources ?? [], errors);
        var warheadIds = ValidateWarheads(dto.Warheads ?? [], errors);
        var weaponIds = ValidateWeapons(dto.Weapons ?? [], warheadIds, errors);
        var unitTypes = ValidateUnitTypes(dto.UnitTypes ?? [], weaponIds, errors);
        var productionIds = ValidateProductions(dto.Productions ?? [], unitTypes, errors);
        var constructionIds = ValidateConstructions(dto.Constructions ?? [], unitTypes, errors);
        ValidateRequirements(
            requirements,
            unitTypes.Keys,
            productionIds,
            constructionIds,
            ParsedResourceKinds(dto.Resources ?? []),
            errors);
        return errors;
    }

    /// <summary>要求顶层集合显式存在，同时允许调用方使用空数组。</summary>
    private static void ValidateRequiredCollection<T>(
        IReadOnlyCollection<T>? collection,
        string path,
        List<BalanceConfigError> errors)
    {
        if (collection is null)
        {
            Add(errors, BalanceConfigErrorCode.MissingValue, path, "必须声明该集合。允许使用空数组。");
        }
    }

    /// <summary>把所有层级的扩展字段转换为稳定 UnknownProperty 错误。</summary>
    private static void CollectUnknownProperties(
        BalanceConfigDto dto,
        List<BalanceConfigError> errors)
    {
        AddUnknown(dto.UnknownProperties, "$", errors);
        ForEach(dto.Resources, "resources", (item, path) =>
            AddUnknown(item.UnknownProperties, path, errors));
        ForEach(dto.Warheads, "warheads", (item, path) =>
            AddUnknown(item.UnknownProperties, path, errors));
        ForEach(dto.Weapons, "weapons", (item, path) =>
            AddUnknown(item.UnknownProperties, path, errors));
        ForEach(dto.UnitTypes, "unitTypes", (item, path) =>
        {
            AddUnknown(item.UnknownProperties, path, errors);
            if (item.Movement is not null)
            {
                AddUnknown(item.Movement.UnknownProperties, $"{path}.movement", errors);
            }
            if (item.Gatherer is not null)
            {
                AddUnknown(item.Gatherer.UnknownProperties, $"{path}.gatherer", errors);
            }
            if (item.Constructor is not null)
            {
                AddUnknown(item.Constructor.UnknownProperties, $"{path}.constructor", errors);
            }
            if (item.Producer is not null)
            {
                AddUnknown(item.Producer.UnknownProperties, $"{path}.producer", errors);
            }
        });
        ForEach(dto.Productions, "productions", (item, path) =>
        {
            AddUnknown(item.UnknownProperties, path, errors);
            ForEachNested(item.Cost, $"{path}.cost", (cost, costPath) =>
                AddUnknown(cost.UnknownProperties, costPath, errors));
        });
        ForEach(dto.Constructions, "constructions", (item, path) =>
        {
            AddUnknown(item.UnknownProperties, path, errors);
            ForEachNested(item.Cost, $"{path}.cost", (cost, costPath) =>
                AddUnknown(cost.UnknownProperties, costPath, errors));
        });
    }

    /// <summary>验证资源枚举唯一且采集周期为正整数毫秒。</summary>
    private static void ValidateResources(
        IReadOnlyList<ResourceDefinitionDto> resources,
        List<BalanceConfigError> errors)
    {
        var kinds = new HashSet<ResourceKind>();
        for (var index = 0; index < resources.Count; index++)
        {
            var path = $"$.resources[{index}]";
            if (TryParseResourceKind(resources[index].Kind, $"{path}.kind", errors, out var kind) &&
                !kinds.Add(kind))
            {
                Add(errors, BalanceConfigErrorCode.DuplicateId, $"{path}.kind",
                    $"资源 {kind} 重复定义。");
            }
            RequirePositive(resources[index].CollectionDurationMilliseconds,
                $"{path}.collectionDurationMilliseconds", errors);
        }
    }

    /// <summary>验证弹头 ID、选择模式、范围和友伤倍率并返回有效 ID。</summary>
    private static HashSet<string> ValidateWarheads(
        IReadOnlyList<WarheadDefinitionDto> warheads,
        List<BalanceConfigError> errors)
    {
        var ids = new HashSet<string>(StringComparer.Ordinal);
        for (var index = 0; index < warheads.Count; index++)
        {
            var item = warheads[index];
            var path = $"$.warheads[{index}]";
            AddStableId(item.Id, $"{path}.id", ids, errors);
            var selectionValid = TryParseImpactSelection(
                item.ImpactSelectionMode, $"{path}.impactSelectionMode", errors, out var selection);
            RequireFiniteNonNegative(item.RadiusMeters, $"{path}.radiusMeters", errors);
            RequireFiniteNonNegative(item.FriendlyFireDamageMultiplier,
                $"{path}.friendlyFireDamageMultiplier", errors);
            if (selectionValid && selection == ImpactSelectionMode.IntendedTargetOnly &&
                item.RadiusMeters is > 0.0f)
            {
                Add(errors, BalanceConfigErrorCode.InvalidCapability, $"{path}.radiusMeters",
                    "IntendedTargetOnly 弹头的范围半径必须为零。");
            }
        }
        return ids;
    }

    /// <summary>验证武器数值、攻击域和弹头引用并返回有效 ID。</summary>
    private static HashSet<string> ValidateWeapons(
        IReadOnlyList<WeaponDefinitionDto> weapons,
        IReadOnlySet<string> warheadIds,
        List<BalanceConfigError> errors)
    {
        var ids = new HashSet<string>(StringComparer.Ordinal);
        for (var index = 0; index < weapons.Count; index++)
        {
            var item = weapons[index];
            var path = $"$.weapons[{index}]";
            AddStableId(item.Id, $"{path}.id", ids, errors);
            TryParseDelivery(item.DeliveryKind, $"{path}.deliveryKind", errors, out _);
            RequireFinitePositive(item.BaseDamage, $"{path}.baseDamage", errors);
            RequirePositive(item.CooldownMilliseconds, $"{path}.cooldownMilliseconds", errors);
            RequireFinitePositive(item.RangeMeters, $"{path}.rangeMeters", errors);

            if (item.TargetDomains is null || item.TargetDomains.Count == 0)
            {
                Add(errors, BalanceConfigErrorCode.MissingValue, $"{path}.targetDomains",
                    "武器必须至少声明一个攻击域。");
            }
            else
            {
                var domains = new HashSet<CombatDomain>();
                for (var domainIndex = 0; domainIndex < item.TargetDomains.Count; domainIndex++)
                {
                    var domainPath = $"{path}.targetDomains[{domainIndex}]";
                    if (TryParseCombatDomain(
                        item.TargetDomains[domainIndex], domainPath, errors, out var domain) &&
                        !domains.Add(domain))
                    {
                        Add(errors, BalanceConfigErrorCode.DuplicateId, domainPath,
                            $"攻击域 {domain} 重复声明。");
                    }
                }
            }

            if (RequireStableId(item.WarheadId, $"{path}.warheadId", errors) &&
                !warheadIds.Contains(item.WarheadId!))
            {
                Add(errors, BalanceConfigErrorCode.MissingReference, $"{path}.warheadId",
                    $"弹头 {item.WarheadId} 不存在。");
            }
        }
        return ids;
    }

    /// <summary>验证单位基础数值与可选能力并返回首个有效 ID 索引。</summary>
    private static Dictionary<string, UnitTypeDefinitionDto> ValidateUnitTypes(
        IReadOnlyList<UnitTypeDefinitionDto> unitTypes,
        IReadOnlySet<string> weaponIds,
        List<BalanceConfigError> errors)
    {
        var definitions = new Dictionary<string, UnitTypeDefinitionDto>(StringComparer.Ordinal);
        for (var index = 0; index < unitTypes.Count; index++)
        {
            var item = unitTypes[index];
            var path = $"$.unitTypes[{index}]";
            if (RequireStableId(item.Id, $"{path}.id", errors))
            {
                if (!definitions.TryAdd(item.Id!, item))
                {
                    Add(errors, BalanceConfigErrorCode.DuplicateId, $"{path}.id",
                        $"实体类型 {item.Id} 重复定义。");
                }
            }
            RequireFinitePositive(item.MaxHp, $"{path}.maxHp", errors);
            RequireFiniteNonNegative(item.SightRangeMeters, $"{path}.sightRangeMeters", errors);
            ValidateMovement(item, path, errors);
            ValidateWeaponReferences(item.WeaponIds, path, weaponIds, errors);
            RequireBoolean(item.CanForceFireGround, $"{path}.canForceFireGround", errors);
            if (item.CanForceFireGround == true &&
                (item.WeaponIds is null || item.WeaponIds.Count == 0))
            {
                Add(errors, BalanceConfigErrorCode.InvalidCapability,
                    $"{path}.canForceFireGround",
                    "允许强制攻击地面的实体必须装配至少一件武器。");
            }
            if (item.Gatherer is not null)
            {
                RequirePositive(item.Gatherer.CarryCapacity, $"{path}.gatherer.carryCapacity", errors);
            }
            if (item.Constructor is not null)
            {
                RequirePositive(item.Constructor.WorkPerTick, $"{path}.constructor.workPerTick", errors);
            }
            if (item.Producer is not null)
            {
                RequirePositive(item.Producer.QueueLimit, $"{path}.producer.queueLimit", errors);
            }
        }
        return definitions;
    }

    /// <summary>验证移动数值以及移动射击能力之间的一致性。</summary>
    private static void ValidateMovement(
        UnitTypeDefinitionDto unit,
        string unitPath,
        List<BalanceConfigError> errors)
    {
        if (unit.Movement is null)
        {
            return;
        }
        var movement = unit.Movement;
        var path = $"{unitPath}.movement";
        TryParseCombatDomain(movement.Domain, $"{path}.domain", errors, out _);
        RequireFinitePositive(movement.SpeedMetersPerSecond, $"{path}.speedMetersPerSecond", errors);
        RequireBoolean(movement.CanReverse, $"{path}.canReverse", errors);
        RequireFiniteInRange(
            movement.ReverseSpeedMultiplier, 0.0f, 1.0f, false,
            $"{path}.reverseSpeedMultiplier", errors);
        RequireBoolean(movement.CanFireWhileMoving, $"{path}.canFireWhileMoving", errors);
        RequireFiniteInRange(
            movement.MovingWeaponArcDegrees, 0.0f, 360.0f, true,
            $"{path}.movingWeaponArcDegrees", errors);

        if (movement.CanFireWhileMoving == true)
        {
            if (movement.MovingWeaponArcDegrees is not > 0.0f)
            {
                Add(errors, BalanceConfigErrorCode.InvalidCapability,
                    $"{path}.movingWeaponArcDegrees",
                    "允许移动射击时必须提供大于零的射界。");
            }
            if (unit.WeaponIds is null || unit.WeaponIds.Count == 0)
            {
                Add(errors, BalanceConfigErrorCode.InvalidCapability, $"{unitPath}.weaponIds",
                    "允许移动射击的实体必须装配至少一件武器。");
            }
        }
        else if (movement.CanFireWhileMoving == false && movement.MovingWeaponArcDegrees is > 0.0f)
        {
            Add(errors, BalanceConfigErrorCode.InvalidCapability,
                $"{path}.movingWeaponArcDegrees",
                "禁止移动射击时射界必须为零。");
        }
    }

    /// <summary>验证单位武器列表显式存在、无重复且全部指向已知定义。</summary>
    private static void ValidateWeaponReferences(
        IReadOnlyList<string>? references,
        string unitPath,
        IReadOnlySet<string> weaponIds,
        List<BalanceConfigError> errors)
    {
        if (references is null)
        {
            Add(errors, BalanceConfigErrorCode.MissingValue, $"{unitPath}.weaponIds",
                "必须声明 weaponIds；无武器时使用空数组。");
            return;
        }
        var unique = new HashSet<string>(StringComparer.Ordinal);
        for (var index = 0; index < references.Count; index++)
        {
            var path = $"{unitPath}.weaponIds[{index}]";
            var value = references[index];
            if (!RequireStableId(value, path, errors))
            {
                continue;
            }
            if (!unique.Add(value))
            {
                Add(errors, BalanceConfigErrorCode.DuplicateId, path, $"武器 {value} 重复装配。");
            }
            if (!weaponIds.Contains(value))
            {
                Add(errors, BalanceConfigErrorCode.MissingReference, path, $"武器 {value} 不存在。");
            }
        }
    }

    /// <summary>验证生产成本、产品和生产者能力引用并返回有效 ID。</summary>
    private static HashSet<string> ValidateProductions(
        IReadOnlyList<ProductionDefinitionDto> productions,
        IReadOnlyDictionary<string, UnitTypeDefinitionDto> unitTypes,
        List<BalanceConfigError> errors)
    {
        var ids = new HashSet<string>(StringComparer.Ordinal);
        for (var index = 0; index < productions.Count; index++)
        {
            var item = productions[index];
            var path = $"$.productions[{index}]";
            AddStableId(item.Id, $"{path}.id", ids, errors);
            ValidateUnitReference(item.ProductUnitTypeId, $"{path}.productUnitTypeId", unitTypes, errors);
            RequirePositive(item.RequiredWork, $"{path}.requiredWork", errors);
            ValidateCost(item.Cost, $"{path}.cost", errors);
            if (item.AllowedProducerUnitTypeIds is null ||
                item.AllowedProducerUnitTypeIds.Count == 0)
            {
                Add(errors, BalanceConfigErrorCode.MissingValue,
                    $"{path}.allowedProducerUnitTypeIds",
                    "生产定义必须至少声明一个生产者。");
                continue;
            }

            var producers = new HashSet<string>(StringComparer.Ordinal);
            for (var producerIndex = 0;
                producerIndex < item.AllowedProducerUnitTypeIds.Count;
                producerIndex++)
            {
                var producerId = item.AllowedProducerUnitTypeIds[producerIndex];
                var producerPath = $"{path}.allowedProducerUnitTypeIds[{producerIndex}]";
                if (!ValidateUnitReference(producerId, producerPath, unitTypes, errors))
                {
                    continue;
                }
                if (!producers.Add(producerId))
                {
                    Add(errors, BalanceConfigErrorCode.DuplicateId, producerPath,
                        $"生产者 {producerId} 重复声明。");
                }
                if (unitTypes[producerId].Producer is null)
                {
                    Add(errors, BalanceConfigErrorCode.InvalidCapability, producerPath,
                        $"实体类型 {producerId} 没有 Producer 能力。");
                }
            }
        }
        return ids;
    }

    /// <summary>验证建筑施工工作量、放置环境、占地和实体引用。</summary>
    private static HashSet<string> ValidateConstructions(
        IReadOnlyList<ConstructionDefinitionDto> constructions,
        IReadOnlyDictionary<string, UnitTypeDefinitionDto> unitTypes,
        List<BalanceConfigError> errors)
    {
        var ids = new HashSet<string>(StringComparer.Ordinal);
        for (var index = 0; index < constructions.Count; index++)
        {
            var item = constructions[index];
            var path = $"$.constructions[{index}]";
            AddStableId(item.Id, $"{path}.id", ids, errors);
            ValidateUnitReference(item.UnitTypeId, $"{path}.unitTypeId", unitTypes, errors);
            RequirePositive(item.RequiredWork, $"{path}.requiredWork", errors);
            ValidateCost(item.Cost, $"{path}.cost", errors);
            if (string.IsNullOrWhiteSpace(item.EnvironmentId))
            {
                Add(errors, BalanceConfigErrorCode.MissingValue, $"{path}.environmentId",
                    "必须声明可建造环境 ID。");
            }
            RequireFinitePositive(item.FootprintRadiusMeters,
                $"{path}.footprintRadiusMeters", errors);
        }
        return ids;
    }

    /// <summary>验证成本集合允许为空，但不允许缺失、负数或重复资源。</summary>
    private static void ValidateCost(
        IReadOnlyList<ResourceAmountDto>? cost,
        string path,
        List<BalanceConfigError> errors)
    {
        if (cost is null)
        {
            Add(errors, BalanceConfigErrorCode.MissingValue, path,
                "必须声明 cost；免费项目使用空数组。");
            return;
        }
        var kinds = new HashSet<ResourceKind>();
        for (var index = 0; index < cost.Count; index++)
        {
            var itemPath = $"{path}[{index}]";
            if (TryParseResourceKind(cost[index].Kind, $"{itemPath}.kind", errors, out var kind) &&
                !kinds.Add(kind))
            {
                Add(errors, BalanceConfigErrorCode.DuplicateResourceCost, $"{itemPath}.kind",
                    $"成本重复声明资源 {kind}。");
            }
            RequireNonNegative(cost[index].Amount, $"{itemPath}.amount", errors);
        }
    }

    /// <summary>检查 Match 组合根要求的定义是否全部存在。</summary>
    private static void ValidateRequirements(
        BalanceConfigRequirements requirements,
        IEnumerable<string> unitTypeIds,
        IReadOnlySet<string> productionIds,
        IReadOnlySet<string> constructionIds,
        IReadOnlySet<ResourceKind> resourceKinds,
        List<BalanceConfigError> errors)
    {
        var units = unitTypeIds.ToHashSet(StringComparer.Ordinal);
        foreach (var required in requirements.UnitTypeIds.OrderBy(item => item.Value))
        {
            if (!units.Contains(required.Value))
            {
                Add(errors, BalanceConfigErrorCode.MissingRequiredDefinition, "$.unitTypes",
                    $"当前配置档案缺少实体类型 {required.Value}。");
            }
        }
        foreach (var required in requirements.ProductionDefinitionIds.OrderBy(item => item.Value))
        {
            if (!productionIds.Contains(required.Value))
            {
                Add(errors, BalanceConfigErrorCode.MissingRequiredDefinition, "$.productions",
                    $"当前配置档案缺少生产定义 {required.Value}。");
            }
        }
        foreach (var required in requirements.StructureDefinitionIds.OrderBy(item => item.Value))
        {
            if (!constructionIds.Contains(required.Value))
            {
                Add(errors, BalanceConfigErrorCode.MissingRequiredDefinition, "$.constructions",
                    $"当前配置档案缺少建筑定义 {required.Value}。");
            }
        }
        foreach (var required in requirements.ResourceKinds.OrderBy(item => item))
        {
            if (!resourceKinds.Contains(required))
            {
                Add(errors, BalanceConfigErrorCode.MissingRequiredDefinition, "$.resources",
                    $"当前配置档案缺少资源 {required}。");
            }
        }
    }

    /// <summary>在零错误前提下把 DTO 映射为只读领域定义和冻结索引。</summary>
    private static IGameBalanceCatalog BuildCatalog(BalanceConfigDto dto, string hash)
    {
        var resources = dto.Resources!.Select(item => new ResourceDefinition(
            ParseResourceKind(item.Kind!),
            item.CollectionDurationMilliseconds!.Value));
        var warheads = dto.Warheads!.Select(item => new WarheadDefinition(
            new WarheadDefinitionId(item.Id!),
            ParseImpactSelection(item.ImpactSelectionMode!),
            item.RadiusMeters!.Value,
            item.FriendlyFireDamageMultiplier!.Value));
        var weapons = dto.Weapons!.Select(item => new WeaponDefinition(
            new WeaponDefinitionId(item.Id!),
            ParseDelivery(item.DeliveryKind!),
            item.BaseDamage!.Value,
            item.CooldownMilliseconds!.Value,
            item.RangeMeters!.Value,
            item.TargetDomains!.Select(ParseCombatDomain).ToFrozenSet(),
            new WarheadDefinitionId(item.WarheadId!)));
        var units = dto.UnitTypes!.Select(MapUnitType);
        var productions = dto.Productions!.Select(item => new ProductionDefinition(
            new ProductionDefinitionId(item.Id!),
            item.RequiredWork!.Value,
            MapCost(item.Cost!),
            item.AllowedProducerUnitTypeIds!
                .Select(value => new StructureDefinitionId(value))
                .ToFrozenSet(),
            new UnitTypeId(item.ProductUnitTypeId!)));
        var constructions = dto.Constructions!.Select(item =>
        {
            var definitionId = new StructureDefinitionId(item.Id!);
            var placement = new StructurePlacementDefinition(
                definitionId,
                new CirclePlacementFootprint(item.FootprintRadiusMeters!.Value),
                new PlacementEnvironmentId(item.EnvironmentId!),
                MapCost(item.Cost!));
            return new StructureConstructionDefinition(
                definitionId,
                new UnitTypeId(item.UnitTypeId!),
                item.RequiredWork!.Value,
                placement);
        });
        return new InMemoryGameBalanceCatalog(
            new BalanceConfigVersion(dto.SchemaVersion!.Value, dto.ContentVersion!, hash),
            units,
            weapons,
            warheads,
            productions,
            constructions,
            resources);
    }

    private static UnitTypeDefinition MapUnitType(UnitTypeDefinitionDto item) => new(
        new UnitTypeId(item.Id!),
        item.MaxHp!.Value,
        item.SightRangeMeters!.Value,
        item.Movement is null ? null : new UnitMovementDefinition(
            ParseCombatDomain(item.Movement.Domain!),
            item.Movement.SpeedMetersPerSecond!.Value,
            item.Movement.CanReverse!.Value,
            item.Movement.ReverseSpeedMultiplier!.Value,
            item.Movement.CanFireWhileMoving!.Value,
            item.Movement.MovingWeaponArcDegrees!.Value),
        Array.AsReadOnly(item.WeaponIds!.Select(value => new WeaponDefinitionId(value)).ToArray()),
        item.CanForceFireGround!.Value,
        item.Gatherer is null ? null : new GathererDefinition(item.Gatherer.CarryCapacity!.Value),
        item.Constructor is null ? null : new ConstructorDefinition(item.Constructor.WorkPerTick!.Value),
        item.Producer is null ? null : new ProducerDefinition(item.Producer.QueueLimit!.Value));

    private static IReadOnlyList<ResourceAmount> MapCost(IEnumerable<ResourceAmountDto> cost) =>
        Array.AsReadOnly(cost.Select(item => new ResourceAmount(
            ParseResourceKind(item.Kind!),
            item.Amount!.Value)).ToArray());

    private static BalanceConfigLoadResult Failed(BalanceConfigError error) =>
        new(null, Array.AsReadOnly([error]));

    /// <summary>把扩展数据按字段名称稳定排序后转换为未知字段错误。</summary>
    private static void AddUnknown(
        IReadOnlyDictionary<string, JsonElement>? unknown,
        string path,
        List<BalanceConfigError> errors)
    {
        if (unknown is null)
        {
            return;
        }
        foreach (var name in unknown.Keys.Order(StringComparer.Ordinal))
        {
            Add(errors, BalanceConfigErrorCode.UnknownProperty, $"{path}.{name}",
                $"字段 {name} 不属于当前 schema。");
        }
    }

    /// <summary>验证稳定 ID 格式并阻止同一作用域内的重复定义。</summary>
    private static void AddStableId(
        string? value,
        string path,
        ISet<string> ids,
        List<BalanceConfigError> errors)
    {
        if (!RequireStableId(value, path, errors))
        {
            return;
        }
        if (!ids.Add(value!))
        {
            Add(errors, BalanceConfigErrorCode.DuplicateId, path, $"稳定 ID {value} 重复定义。");
        }
    }

    /// <summary>验证字符串是合法稳定 ID 且引用已存在的实体类型。</summary>
    private static bool ValidateUnitReference(
        string? value,
        string path,
        IReadOnlyDictionary<string, UnitTypeDefinitionDto> unitTypes,
        List<BalanceConfigError> errors)
    {
        if (!RequireStableId(value, path, errors))
        {
            return false;
        }
        if (!unitTypes.ContainsKey(value!))
        {
            Add(errors, BalanceConfigErrorCode.MissingReference, path,
                $"实体类型 {value} 不存在。");
            return false;
        }
        return true;
    }

    /// <summary>要求 ID 非空并符合项目 snake_case 约束。</summary>
    private static bool RequireStableId(
        string? value,
        string path,
        List<BalanceConfigError> errors)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            Add(errors, BalanceConfigErrorCode.MissingValue, path, "必须声明稳定 ID。");
            return false;
        }
        if (!IsSnakeCaseId(value))
        {
            Add(errors, BalanceConfigErrorCode.InvalidId, path,
                "稳定 ID 必须以小写字母开头，且只包含小写字母、数字和下划线。");
            return false;
        }
        return true;
    }

    /// <summary>检查 ID 只包含小写字母、数字和下划线，且以字母开头。</summary>
    private static bool IsSnakeCaseId(string value)
    {
        if (value.Length == 0 || value[0] is < 'a' or > 'z')
        {
            return false;
        }
        foreach (var character in value)
        {
            if (character is >= 'a' and <= 'z' ||
                character is >= '0' and <= '9' || character == '_')
            {
                continue;
            }
            return false;
        }
        return true;
    }

    /// <summary>要求浮点数显式存在、有限且大于零。</summary>
    private static void RequireFinitePositive(
        float? value,
        string path,
        List<BalanceConfigError> errors)
    {
        if (value is null)
        {
            Add(errors, BalanceConfigErrorCode.MissingValue, path, "必须声明该数值。");
        }
        else if (!float.IsFinite(value.Value) || value <= 0.0f)
        {
            Add(errors, BalanceConfigErrorCode.InvalidNumber, path, "数值必须是有限正数。");
        }
    }

    /// <summary>要求浮点数显式存在、有限且不小于零。</summary>
    private static void RequireFiniteNonNegative(
        float? value,
        string path,
        List<BalanceConfigError> errors)
    {
        if (value is null)
        {
            Add(errors, BalanceConfigErrorCode.MissingValue, path, "必须声明该数值。");
        }
        else if (!float.IsFinite(value.Value) || value < 0.0f)
        {
            Add(errors, BalanceConfigErrorCode.InvalidNumber, path, "数值必须有限且不能为负数。");
        }
    }

    /// <summary>要求浮点数位于指定有限区间，并允许控制是否包含下界。</summary>
    private static void RequireFiniteInRange(
        float? value,
        float minimum,
        float maximum,
        bool includeMinimum,
        string path,
        List<BalanceConfigError> errors)
    {
        if (value is null)
        {
            Add(errors, BalanceConfigErrorCode.MissingValue, path, "必须声明该数值。");
            return;
        }
        var belowMinimum = includeMinimum ? value < minimum : value <= minimum;
        if (!float.IsFinite(value.Value) || belowMinimum || value > maximum)
        {
            var lowerSymbol = includeMinimum ? "[" : "(";
            Add(errors, BalanceConfigErrorCode.InvalidNumber, path,
                $"数值必须位于 {lowerSymbol}{minimum}, {maximum}]。");
        }
    }

    /// <summary>要求整数显式存在且大于零。</summary>
    private static void RequirePositive(
        int? value,
        string path,
        List<BalanceConfigError> errors)
    {
        if (value is null)
        {
            Add(errors, BalanceConfigErrorCode.MissingValue, path, "必须声明该整数。");
        }
        else if (value <= 0)
        {
            Add(errors, BalanceConfigErrorCode.InvalidNumber, path, "整数必须大于零。");
        }
    }

    /// <summary>要求整数显式存在且不小于零。</summary>
    private static void RequireNonNegative(
        int? value,
        string path,
        List<BalanceConfigError> errors)
    {
        if (value is null)
        {
            Add(errors, BalanceConfigErrorCode.MissingValue, path, "必须声明该整数。");
        }
        else if (value < 0)
        {
            Add(errors, BalanceConfigErrorCode.InvalidNumber, path, "整数不能为负数。");
        }
    }

    /// <summary>要求布尔配置显式声明，禁止依赖语言默认值。</summary>
    private static void RequireBoolean(
        bool? value,
        string path,
        List<BalanceConfigError> errors)
    {
        if (value is null)
        {
            Add(errors, BalanceConfigErrorCode.MissingValue, path, "必须显式声明布尔值。");
        }
    }

    /// <summary>把严格区分大小写的资源名称转换为强类型枚举。</summary>
    private static bool TryParseResourceKind(
        string? value,
        string path,
        List<BalanceConfigError> errors,
        out ResourceKind kind)
    {
        if (value == "A")
        {
            kind = ResourceKind.A;
            return true;
        }
        if (value == "B")
        {
            kind = ResourceKind.B;
            return true;
        }
        kind = default;
        Add(errors, string.IsNullOrWhiteSpace(value) ? BalanceConfigErrorCode.MissingValue :
            BalanceConfigErrorCode.InvalidEnum, path, "资源类型必须是 A 或 B。");
        return false;
    }

    /// <summary>把规范化空间名称转换为强类型攻击与移动域。</summary>
    private static bool TryParseCombatDomain(
        string? value,
        string path,
        List<BalanceConfigError> errors,
        out CombatDomain domain)
    {
        if (value == "terrain")
        {
            domain = CombatDomain.Terrain;
            return true;
        }
        if (value == "air")
        {
            domain = CombatDomain.Air;
            return true;
        }
        domain = default;
        Add(errors, string.IsNullOrWhiteSpace(value) ? BalanceConfigErrorCode.MissingValue :
            BalanceConfigErrorCode.InvalidEnum, path, "空间必须是 terrain 或 air。");
        return false;
    }

    /// <summary>把规范化交付方式名称转换为强类型武器交付方式。</summary>
    private static bool TryParseDelivery(
        string? value,
        string path,
        List<BalanceConfigError> errors,
        out WeaponDeliveryKind kind)
    {
        var valid = value switch
        {
            "hitscan" => (true, WeaponDeliveryKind.Hitscan),
            "projectile" => (true, WeaponDeliveryKind.Projectile),
            "beam" => (true, WeaponDeliveryKind.Beam),
            "deployable" => (true, WeaponDeliveryKind.Deployable),
            _ => (false, default(WeaponDeliveryKind))
        };
        kind = valid.Item2;
        if (!valid.Item1)
        {
            Add(errors, string.IsNullOrWhiteSpace(value) ? BalanceConfigErrorCode.MissingValue :
                BalanceConfigErrorCode.InvalidEnum, path,
                "deliveryKind 必须是 hitscan、projectile、beam 或 deployable。");
        }
        return valid.Item1;
    }

    /// <summary>把规范化命中选择名称转换为强类型弹头模式。</summary>
    private static bool TryParseImpactSelection(
        string? value,
        string path,
        List<BalanceConfigError> errors,
        out ImpactSelectionMode mode)
    {
        var valid = value switch
        {
            "intendedTargetOnly" => (true, ImpactSelectionMode.IntendedTargetOnly),
            "area" => (true, ImpactSelectionMode.Area),
            _ => (false, default(ImpactSelectionMode))
        };
        mode = valid.Item2;
        if (!valid.Item1)
        {
            Add(errors, string.IsNullOrWhiteSpace(value) ? BalanceConfigErrorCode.MissingValue :
                BalanceConfigErrorCode.InvalidEnum, path,
                "impactSelectionMode 必须是 intendedTargetOnly 或 area。");
        }
        return valid.Item1;
    }

    private static HashSet<ResourceKind> ParsedResourceKinds(
        IEnumerable<ResourceDefinitionDto> resources) => resources
        .Where(item => item.Kind is "A" or "B")
        .Select(item => ParseResourceKind(item.Kind!))
        .ToHashSet();

    private static ResourceKind ParseResourceKind(string value) => value == "A" ?
        ResourceKind.A : ResourceKind.B;

    private static CombatDomain ParseCombatDomain(string value) => value == "terrain" ?
        CombatDomain.Terrain : CombatDomain.Air;

    private static WeaponDeliveryKind ParseDelivery(string value) => value switch
    {
        "hitscan" => WeaponDeliveryKind.Hitscan,
        "projectile" => WeaponDeliveryKind.Projectile,
        "beam" => WeaponDeliveryKind.Beam,
        _ => WeaponDeliveryKind.Deployable
    };

    private static ImpactSelectionMode ParseImpactSelection(string value) =>
        value == "area" ? ImpactSelectionMode.Area : ImpactSelectionMode.IntendedTargetOnly;

    private static void Add(
        ICollection<BalanceConfigError> errors,
        BalanceConfigErrorCode code,
        string path,
        string message) => errors.Add(new BalanceConfigError(code, path, message));

    private static void ForEach<T>(
        IReadOnlyList<T>? items,
        string propertyName,
        Action<T, string> action)
    {
        if (items is null)
        {
            return;
        }
        for (var index = 0; index < items.Count; index++)
        {
            action(items[index], $"$.{propertyName}[{index}]");
        }
    }

    private static void ForEachNested<T>(
        IReadOnlyList<T>? items,
        string path,
        Action<T, string> action)
    {
        if (items is null)
        {
            return;
        }
        for (var index = 0; index < items.Count; index++)
        {
            action(items[index], $"{path}[{index}]");
        }
    }
}

/// <summary>使用冻结字典保存已经完整校验的 Match 数值定义。</summary>
internal sealed class InMemoryGameBalanceCatalog : IGameBalanceCatalog
{
    private readonly FrozenDictionary<UnitTypeId, UnitTypeDefinition> _unitTypes;
    private readonly FrozenDictionary<WeaponDefinitionId, WeaponDefinition> _weapons;
    private readonly FrozenDictionary<WarheadDefinitionId, WarheadDefinition> _warheads;
    private readonly FrozenDictionary<ProductionDefinitionId, ProductionDefinition> _productions;
    private readonly FrozenDictionary<StructureDefinitionId, StructureConstructionDefinition>
        _constructions;
    private readonly FrozenDictionary<ResourceKind, ResourceDefinition> _resources;

    /// <inheritdoc />
    public BalanceConfigVersion Version { get; }

    /// <summary>冻结全部定义索引，之后不再接受注册或覆盖。</summary>
    public InMemoryGameBalanceCatalog(
        BalanceConfigVersion version,
        IEnumerable<UnitTypeDefinition> unitTypes,
        IEnumerable<WeaponDefinition> weapons,
        IEnumerable<WarheadDefinition> warheads,
        IEnumerable<ProductionDefinition> productions,
        IEnumerable<StructureConstructionDefinition> constructions,
        IEnumerable<ResourceDefinition> resources)
    {
        Version = version;
        _unitTypes = unitTypes.ToFrozenDictionary(item => item.Id);
        _weapons = weapons.ToFrozenDictionary(item => item.Id);
        _warheads = warheads.ToFrozenDictionary(item => item.Id);
        _productions = productions.ToFrozenDictionary(item => item.DefinitionId);
        _constructions = constructions.ToFrozenDictionary(item => item.DefinitionId);
        _resources = resources.ToFrozenDictionary(item => item.Kind);
    }

    /// <inheritdoc />
    public UnitTypeDefinition? FindUnitType(UnitTypeId unitTypeId) =>
        _unitTypes.GetValueOrDefault(unitTypeId);

    /// <inheritdoc />
    public WeaponDefinition? FindWeapon(WeaponDefinitionId weaponId) =>
        _weapons.GetValueOrDefault(weaponId);

    /// <inheritdoc />
    public WarheadDefinition? FindWarhead(WarheadDefinitionId warheadId) =>
        _warheads.GetValueOrDefault(warheadId);

    /// <inheritdoc />
    public ProductionDefinition? FindProduction(ProductionDefinitionId definitionId) =>
        _productions.GetValueOrDefault(definitionId);

    /// <inheritdoc />
    public StructureConstructionDefinition? FindConstruction(StructureDefinitionId definitionId) =>
        _constructions.GetValueOrDefault(definitionId);

    /// <inheritdoc />
    public ResourceDefinition? FindResource(ResourceKind kind) =>
        _resources.GetValueOrDefault(kind);
}
