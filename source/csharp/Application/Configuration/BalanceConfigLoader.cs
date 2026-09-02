using System.Collections.Frozen;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using AI_RTS.Domain.Battlefield;
using AI_RTS.Domain.Combat;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Configuration;
using AI_RTS.Domain.Construction;
using AI_RTS.Domain.Economy;
using AI_RTS.Domain.Production;
using AI_RTS.Domain.Skills;

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
        ValidateRequiredCollection(dto.Skills, "$.skills", errors);

        ValidateResources(dto.Resources ?? [], errors);
        var warheadIds = ValidateWarheads(dto.Warheads ?? [], errors);
        var weaponIds = ValidateWeapons(dto.Weapons ?? [], warheadIds, errors);
        var unitTypes = ValidateUnitTypes(dto.UnitTypes ?? [], weaponIds, errors);
        var productionIds = ValidateProductions(dto.Productions ?? [], unitTypes, errors);
        var constructionIds = ValidateConstructions(dto.Constructions ?? [], unitTypes, errors);
        ValidateSkills(dto.Skills ?? [], unitTypes.Keys, errors);
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
        ForEach(dto.Skills, "skills", (item, path) =>
        {
            AddUnknown(item.UnknownProperties, path, errors);
            ForEachNested(item.Effects, $"{path}.effects", (effect, effectPath) =>
                AddUnknown(effect.UnknownProperties, effectPath, errors));
            ForEachNested(item.Cost, $"{path}.cost", (cost, costPath) =>
                AddUnknown(cost.UnknownProperties, costPath, errors));
            if (item.Interrupt is not null)
            {
                AddUnknown(item.Interrupt.UnknownProperties, $"{path}.interrupt", errors);
            }
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
        RequireFinitePositive(movement.MaxTurnDegreesPerSecond, $"{path}.maxTurnDegreesPerSecond", errors);
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
        var productIds = new HashSet<string>(StringComparer.Ordinal);
        for (var index = 0; index < productions.Count; index++)
        {
            var item = productions[index];
            var path = $"$.productions[{index}]";
            AddStableId(item.Id, $"{path}.id", ids, errors);
            if (ValidateUnitReference(
                item.ProductUnitTypeId,
                $"{path}.productUnitTypeId",
                unitTypes,
                errors) && !productIds.Add(item.ProductUnitTypeId!))
            {
                Add(errors, BalanceConfigErrorCode.InvalidCapability,
                    $"{path}.productUnitTypeId",
                    "迁移期 PackedScene 入队入口要求每种产品只有一个生产定义。");
            }
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

    /// <summary>验证技能 ID、触发、目标、效果种类和冷却，并拒绝重复定义。</summary>
    private static void ValidateSkills(
        IReadOnlyList<SkillDefinitionDto> skills,
        IReadOnlyCollection<string> unitTypeIds,
        List<BalanceConfigError> errors)
    {
        var ids = new HashSet<string>(StringComparer.Ordinal);
        for (var index = 0; index < skills.Count; index++)
        {
            var item = skills[index];
            var path = $"$.skills[{index}]";
            AddStableId(item.Id, $"{path}.id", ids, errors);
            var triggerValid = TryParseSkillTrigger(item.Trigger, $"{path}.trigger", errors, out var trigger);
            var targetValid = TryParseSkillTarget(item.Target, $"{path}.target", errors, out var target);
            if (triggerValid)
            {
                ValidateSkillTriggerShape(item, trigger, targetValid ? target : null, path, unitTypeIds, errors);
            }
            RequireNonNegative(item.CooldownMilliseconds, $"{path}.cooldownMilliseconds", errors);
            if (item.CastDelayMilliseconds is not null)
            {
                RequireNonNegative(item.CastDelayMilliseconds, $"{path}.castDelayMilliseconds", errors);
            }
            ValidateSkillInterrupt(item.Interrupt, $"{path}.interrupt", errors);
            if (item.Relation is not null)
            {
                TryParseSkillRelation(item.Relation, $"{path}.relation", errors, out _);
            }
            if (item.RangeMeters is not null)
            {
                RequireFiniteNonNegative(item.RangeMeters, $"{path}.rangeMeters", errors);
            }
            if (item.Cost is not null)
            {
                ValidateCost(item.Cost, $"{path}.cost", errors);
            }
            if (item.Effects is null)
            {
                Add(errors, BalanceConfigErrorCode.MissingValue, $"{path}.effects",
                    "必须声明 effects；至少包含一条基础效果。");
                continue;
            }
            if (item.Effects.Count == 0)
            {
                Add(errors, BalanceConfigErrorCode.MissingValue, $"{path}.effects",
                    "技能必须至少声明一条基础效果。");
                continue;
            }
            for (var effectIndex = 0; effectIndex < item.Effects.Count; effectIndex++)
            {
                var effect = item.Effects[effectIndex];
                var effectPath = $"{path}.effects[{effectIndex}]";
                var kindValid = TryParseSkillEffectKind(
                    effect.Kind, $"{effectPath}.kind", errors, out var effectKind);
                if (effect.Amount is { } amount && !float.IsFinite(amount))
                {
                    Add(errors, BalanceConfigErrorCode.InvalidNumber, $"{effectPath}.amount",
                        "数值必须是有限数。");
                }
                if (effect.DelayMilliseconds is not null)
                {
                    RequireNonNegative(
                        effect.DelayMilliseconds, $"{effectPath}.delayMilliseconds", errors);
                }
                if (kindValid && effectKind == SkillEffectKind.IssueCommand)
                {
                    TryParseIssuedCommand(effect.Command, $"{effectPath}.command", errors, out _);
                }
                if (kindValid && effectKind == SkillEffectKind.EmitEvent && effect.EventKind is not null)
                {
                    TryParseEmittedEvent(effect.EventKind, $"{effectPath}.eventKind", errors, out _);
                }
                if (kindValid && effectKind == SkillEffectKind.CreateObject)
                {
                    if (RequireStableId(effect.TemplateId, $"{effectPath}.templateId", errors) &&
                        !unitTypeIds.Contains(effect.TemplateId!))
                    {
                        Add(errors, BalanceConfigErrorCode.MissingReference, $"{effectPath}.templateId",
                            $"对象模板 {effect.TemplateId} 不存在。");
                    }
                }
                if (kindValid && effectKind == SkillEffectKind.AddStatus)
                {
                    RequireStableId(effect.StatusId, $"{effectPath}.statusId", errors);
                    RequirePositive(effect.DurationMilliseconds, $"{effectPath}.durationMilliseconds", errors);
                    TryParseSkillAttribute(effect.Attribute, $"{effectPath}.attribute", errors, out _);
                    RequireFinitePositive(effect.Modifier, $"{effectPath}.modifier", errors);
                    if (effect.Stack is not null)
                    {
                        TryParseSkillStack(effect.Stack, $"{effectPath}.stack", errors, out _);
                    }
                }
                ValidateSkillEffectTiming(effect, effectIndex, effectPath, errors);
                ValidateSkillEffectPeriod(effect, effectPath, errors);
                if (effect.Condition is not null)
                {
                    TryParseSkillCondition(effect.Condition, $"{effectPath}.condition", errors, out _);
                }
            }
        }
    }

    /// <summary>校验中断阶段、原因；声明 interrupt 时至少要有一个阶段。</summary>
    private static void ValidateSkillInterrupt(
        SkillInterruptDefinitionDto? interrupt,
        string path,
        List<BalanceConfigError> errors)
    {
        if (interrupt is null)
        {
            return;
        }

        if (interrupt.Phases is null || interrupt.Phases.Count == 0)
        {
            Add(errors, BalanceConfigErrorCode.MissingValue, $"{path}.phases",
                "声明 interrupt 时必须至少有一个阶段。");
        }
        else
        {
            for (var index = 0; index < interrupt.Phases.Count; index++)
            {
                TryParseSkillInterruptPhase(
                    interrupt.Phases[index], $"{path}.phases[{index}]", errors, out _);
            }
        }

        if (interrupt.Causes is not null)
        {
            if (interrupt.Causes.Count == 0)
            {
                Add(errors, BalanceConfigErrorCode.MissingValue, $"{path}.causes",
                    "causes 若声明则不能为空。");
            }

            for (var index = 0; index < interrupt.Causes.Count; index++)
            {
                TryParseSkillInterruptCause(
                    interrupt.Causes[index], $"{path}.causes[{index}]", errors, out _);
            }
        }
    }

    /// <summary>按触发种类校验事件、条件和装配类型，并禁止主动入口字段混用。</summary>
    private static void ValidateSkillTriggerShape(
        SkillDefinitionDto item,
        SkillTriggerKind trigger,
        SkillTargetKind? target,
        string path,
        IReadOnlyCollection<string> unitTypeIds,
        List<BalanceConfigError> errors)
    {
        if (trigger != SkillTriggerKind.Active &&
            target is not null &&
            target != SkillTargetKind.Self)
        {
            Add(errors, BalanceConfigErrorCode.InvalidEnum, $"{path}.target",
                "被动、事件和条件触发本步只允许 target 为 self。");
        }

        if (item.EquippedUnitTypeIds is not null)
        {
            for (var index = 0; index < item.EquippedUnitTypeIds.Count; index++)
            {
                var typePath = $"{path}.equippedUnitTypeIds[{index}]";
                var typeId = item.EquippedUnitTypeIds[index];
                if (!RequireStableId(typeId, typePath, errors))
                {
                    continue;
                }

                if (!unitTypeIds.Contains(typeId))
                {
                    Add(errors, BalanceConfigErrorCode.MissingReference, typePath,
                        $"装备类型 {typeId} 不存在。");
                }
            }
        }

        switch (trigger)
        {
            case SkillTriggerKind.Active:
                if (item.Event is not null)
                {
                    Add(errors, BalanceConfigErrorCode.InvalidEnum, $"{path}.event",
                        "主动技能不得声明 event。");
                }
                if (item.ActivationCondition is not null &&
                    item.ActivationCondition != "always")
                {
                    Add(errors, BalanceConfigErrorCode.InvalidEnum, $"{path}.activationCondition",
                        "主动技能不得声明非 always 的装配条件。");
                }
                break;
            case SkillTriggerKind.Event:
                TryParseSkillTriggerEvent(item.Event, $"{path}.event", errors, out _);
                if (item.ActivationCondition is not null)
                {
                    TryParseSkillCondition(
                        item.ActivationCondition, $"{path}.activationCondition", errors, out _);
                }
                break;
            case SkillTriggerKind.Condition:
                if (item.Event is not null)
                {
                    Add(errors, BalanceConfigErrorCode.InvalidEnum, $"{path}.event",
                        "条件触发不得声明 event。");
                }
                if (!TryParseSkillCondition(
                    item.ActivationCondition, $"{path}.activationCondition", errors, out var condition) ||
                    condition == SkillEffectCondition.Always)
                {
                    if (item.ActivationCondition == "always")
                    {
                        Add(errors, BalanceConfigErrorCode.InvalidEnum, $"{path}.activationCondition",
                            "条件触发不能使用 always，应改用被动触发。");
                    }
                }
                break;
            case SkillTriggerKind.Passive:
                if (item.Event is not null)
                {
                    Add(errors, BalanceConfigErrorCode.InvalidEnum, $"{path}.event",
                        "被动技能不得声明 event。");
                }
                if (item.ActivationCondition is not null &&
                    item.ActivationCondition != "always")
                {
                    Add(errors, BalanceConfigErrorCode.InvalidEnum, $"{path}.activationCondition",
                        "被动技能的装配条件只能是 always。");
                }
                break;
        }
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
        var skills = dto.Skills!.Select(item =>
        {
            var target = ParseSkillTarget(item.Target!);
            return new SkillDefinition(
                new SkillDefinitionId(item.Id!),
                ParseSkillTrigger(item.Trigger!),
                target,
                item.Effects!
                    .Select(effect => MapSkillEffect(effect))
                    .ToArray(),
                item.CooldownMilliseconds!.Value,
                item.Relation is null ? DefaultSkillRelation(target) : ParseSkillRelation(item.Relation),
                item.RangeMeters,
                item.RequireAlive ?? target is SkillTargetKind.Unit or SkillTargetKind.Units,
                item.AllowSelf ?? target == SkillTargetKind.Self,
                item.Cost is null ? [] : MapCost(item.Cost),
                item.Event is null ? SkillTriggerEvent.None : ParseSkillTriggerEvent(item.Event),
                item.ActivationCondition is null ?
                    SkillEffectCondition.Always : ParseSkillCondition(item.ActivationCondition),
                item.EquippedUnitTypeIds is null ?
                    [] :
                    item.EquippedUnitTypeIds.Select(value => new UnitTypeId(value)).ToArray(),
                item.CastDelayMilliseconds ?? 0,
                item.Interrupt is null ? null : MapSkillInterrupt(item.Interrupt));
        });
        return new InMemoryGameBalanceCatalog(
            new BalanceConfigVersion(dto.SchemaVersion!.Value, dto.ContentVersion!, hash),
            units,
            weapons,
            warheads,
            productions,
            constructions,
            resources,
            skills);
    }

    private static UnitTypeDefinition MapUnitType(UnitTypeDefinitionDto item) => new(
        new UnitTypeId(item.Id!),
        item.MaxHp!.Value,
        item.SightRangeMeters!.Value,
        item.Movement is null ? null : new UnitMovementDefinition(
            ParseCombatDomain(item.Movement.Domain!),
            item.Movement.SpeedMetersPerSecond!.Value,
            item.Movement.MaxTurnDegreesPerSecond!.Value,
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
        Array.AsReadOnly(cost.Where(item => item.Amount > 0).Select(item => new ResourceAmount(
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

    /// <summary>把规范化触发名称转换为强类型技能触发。</summary>
    private static bool TryParseSkillTrigger(
        string? value,
        string path,
        List<BalanceConfigError> errors,
        out SkillTriggerKind kind)
    {
        var valid = value switch
        {
            "active" => (true, SkillTriggerKind.Active),
            "passive" => (true, SkillTriggerKind.Passive),
            "event" => (true, SkillTriggerKind.Event),
            "condition" => (true, SkillTriggerKind.Condition),
            _ => (false, default(SkillTriggerKind))
        };
        kind = valid.Item2;
        if (!valid.Item1)
        {
            Add(errors, string.IsNullOrWhiteSpace(value) ? BalanceConfigErrorCode.MissingValue :
                BalanceConfigErrorCode.InvalidEnum, path,
                "trigger 必须是 active、passive、event 或 condition。");
        }
        return valid.Item1;
    }

    /// <summary>把规范化目标名称转换为强类型技能目标形状。</summary>
    private static bool TryParseSkillTarget(
        string? value,
        string path,
        List<BalanceConfigError> errors,
        out SkillTargetKind kind)
    {
        var valid = value switch
        {
            "self" => (true, SkillTargetKind.Self),
            "unit" => (true, SkillTargetKind.Unit),
            "units" => (true, SkillTargetKind.Units),
            "ground" => (true, SkillTargetKind.Ground),
            "area" => (true, SkillTargetKind.Area),
            "direction" => (true, SkillTargetKind.Direction),
            "gameObject" => (true, SkillTargetKind.GameObject),
            _ => (false, default(SkillTargetKind))
        };
        kind = valid.Item2;
        if (!valid.Item1)
        {
            Add(errors, string.IsNullOrWhiteSpace(value) ? BalanceConfigErrorCode.MissingValue :
                BalanceConfigErrorCode.InvalidEnum, path,
                "target 必须是 self、unit、units、ground、area、direction 或 gameObject。");
        }
        return valid.Item1;
    }

    /// <summary>把规范化效果种类转换为策划文档固定的基础效果枚举。</summary>
    private static bool TryParseSkillEffectKind(
        string? value,
        string path,
        List<BalanceConfigError> errors,
        out SkillEffectKind kind)
    {
        var valid = value switch
        {
            "dealDamage" => (true, SkillEffectKind.DealDamage),
            "restoreHealth" => (true, SkillEffectKind.RestoreHealth),
            "modifyShield" => (true, SkillEffectKind.ModifyShield),
            "modifyAttribute" => (true, SkillEffectKind.ModifyAttribute),
            "modifyResource" => (true, SkillEffectKind.ModifyResource),
            "addStatus" => (true, SkillEffectKind.AddStatus),
            "removeStatus" => (true, SkillEffectKind.RemoveStatus),
            "displace" => (true, SkillEffectKind.Displace),
            "forceMove" => (true, SkillEffectKind.ForceMove),
            "createObject" => (true, SkillEffectKind.CreateObject),
            "removeObject" => (true, SkillEffectKind.RemoveObject),
            "issueCommand" => (true, SkillEffectKind.IssueCommand),
            "emitEvent" => (true, SkillEffectKind.EmitEvent),
            _ => (false, default(SkillEffectKind))
        };
        kind = valid.Item2;
        if (!valid.Item1)
        {
            Add(errors, string.IsNullOrWhiteSpace(value) ? BalanceConfigErrorCode.MissingValue :
                BalanceConfigErrorCode.InvalidEnum, path,
                "effects.kind 必须是策划文档列出的基础效果种类。");
        }
        return valid.Item1;
    }

    /// <summary>把规范化阵营关系转换为技能目标关系。</summary>
    private static bool TryParseSkillRelation(
        string? value,
        string path,
        List<BalanceConfigError> errors,
        out SkillTargetRelation relation)
    {
        var valid = value switch
        {
            "self" => (true, SkillTargetRelation.Self),
            "ally" => (true, SkillTargetRelation.Ally),
            "enemy" => (true, SkillTargetRelation.Enemy),
            "any" => (true, SkillTargetRelation.Any),
            _ => (false, default(SkillTargetRelation))
        };
        relation = valid.Item2;
        if (!valid.Item1)
        {
            Add(errors, string.IsNullOrWhiteSpace(value) ? BalanceConfigErrorCode.MissingValue :
                BalanceConfigErrorCode.InvalidEnum, path,
                "relation 必须是 self、ally、enemy 或 any。");
        }
        return valid.Item1;
    }

    /// <summary>把规范化属性名称转换为技能可改属性。</summary>
    private static bool TryParseSkillAttribute(
        string? value,
        string path,
        List<BalanceConfigError> errors,
        out SkillAttributeKind attribute)
    {
        if (value == "moveSpeed")
        {
            attribute = SkillAttributeKind.MoveSpeed;
            return true;
        }

        attribute = default;
        Add(errors, string.IsNullOrWhiteSpace(value) ? BalanceConfigErrorCode.MissingValue :
            BalanceConfigErrorCode.InvalidEnum, path, "attribute 必须是 moveSpeed。");
        return false;
    }

    /// <summary>把规范化叠加规则转换为强类型枚举。</summary>
    private static bool TryParseSkillStack(
        string? value,
        string path,
        List<BalanceConfigError> errors,
        out SkillStackRule stack)
    {
        var valid = value switch
        {
            "refresh" => (true, SkillStackRule.Refresh),
            "overwrite" => (true, SkillStackRule.Overwrite),
            "ignore" => (true, SkillStackRule.Ignore),
            _ => (false, default(SkillStackRule))
        };
        stack = valid.Item2;
        if (!valid.Item1)
        {
            Add(errors, string.IsNullOrWhiteSpace(value) ? BalanceConfigErrorCode.MissingValue :
                BalanceConfigErrorCode.InvalidEnum, path,
                "stack 必须是 refresh、overwrite 或 ignore。");
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

    private static SkillTriggerKind ParseSkillTrigger(string value) => value switch
    {
        "passive" => SkillTriggerKind.Passive,
        "event" => SkillTriggerKind.Event,
        "condition" => SkillTriggerKind.Condition,
        _ => SkillTriggerKind.Active
    };

    private static SkillTargetKind ParseSkillTarget(string value) => value switch
    {
        "unit" => SkillTargetKind.Unit,
        "units" => SkillTargetKind.Units,
        "ground" => SkillTargetKind.Ground,
        "area" => SkillTargetKind.Area,
        "direction" => SkillTargetKind.Direction,
        "gameObject" => SkillTargetKind.GameObject,
        _ => SkillTargetKind.Self
    };

    private static SkillEffectDefinition MapSkillEffect(SkillEffectDefinitionDto effect)
    {
        var kind = ParseSkillEffectKind(effect.Kind!);
        SkillStatusDefinition? status = null;
        if (kind == SkillEffectKind.AddStatus)
        {
            status = new SkillStatusDefinition(
                effect.StatusId!,
                effect.DurationMilliseconds!.Value,
                ParseSkillAttribute(effect.Attribute!),
                effect.Modifier!.Value,
                effect.Stack is null ? SkillStackRule.Refresh : ParseSkillStack(effect.Stack));
        }

        return new SkillEffectDefinition(
            kind,
            effect.Amount,
            effect.DelayMilliseconds ?? 0,
            status,
            effect.Timing is null ? SkillEffectTiming.AfterPrevious : ParseSkillTiming(effect.Timing),
            effect.PeriodMilliseconds ?? 0,
            effect.RepeatCount ?? 1,
            effect.Condition is null ? SkillEffectCondition.Always : ParseSkillCondition(effect.Condition),
            kind == SkillEffectKind.IssueCommand && effect.Command is not null ?
                ParseIssuedCommand(effect.Command) : null,
            kind == SkillEffectKind.EmitEvent ?
                (effect.EventKind is null ?
                    BattlefieldEventKind.SkillEmitted : ParseEmittedEvent(effect.EventKind)) :
                null,
            effect.EventImportant ?? false,
            kind == SkillEffectKind.CreateObject && effect.TemplateId is not null ?
                new UnitTypeId(effect.TemplateId) : null);
    }

    private static SkillEffectKind ParseSkillEffectKind(string value) => value switch
    {
        "restoreHealth" => SkillEffectKind.RestoreHealth,
        "modifyShield" => SkillEffectKind.ModifyShield,
        "modifyAttribute" => SkillEffectKind.ModifyAttribute,
        "modifyResource" => SkillEffectKind.ModifyResource,
        "addStatus" => SkillEffectKind.AddStatus,
        "removeStatus" => SkillEffectKind.RemoveStatus,
        "displace" => SkillEffectKind.Displace,
        "forceMove" => SkillEffectKind.ForceMove,
        "createObject" => SkillEffectKind.CreateObject,
        "removeObject" => SkillEffectKind.RemoveObject,
        "issueCommand" => SkillEffectKind.IssueCommand,
        "emitEvent" => SkillEffectKind.EmitEvent,
        _ => SkillEffectKind.DealDamage
    };

    private static SkillTargetRelation ParseSkillRelation(string value) => value switch
    {
        "self" => SkillTargetRelation.Self,
        "ally" => SkillTargetRelation.Ally,
        "any" => SkillTargetRelation.Any,
        _ => SkillTargetRelation.Enemy
    };

    private static SkillTargetRelation DefaultSkillRelation(SkillTargetKind target) => target switch
    {
        SkillTargetKind.Self => SkillTargetRelation.Self,
        SkillTargetKind.Ground => SkillTargetRelation.Any,
        _ => SkillTargetRelation.Enemy
    };

    /// <summary>校验同时与延迟互斥，首条不得声明 simultaneous。</summary>
    private static void ValidateSkillEffectTiming(
        SkillEffectDefinitionDto effect,
        int effectIndex,
        string effectPath,
        List<BalanceConfigError> errors)
    {
        var timingValid = true;
        var timing = SkillEffectTiming.AfterPrevious;
        if (effect.Timing is not null)
        {
            timingValid = TryParseSkillTiming(effect.Timing, $"{effectPath}.timing", errors, out timing);
        }

        if (timingValid && timing == SkillEffectTiming.Simultaneous && effectIndex == 0)
        {
            Add(errors, BalanceConfigErrorCode.InvalidEnum, $"{effectPath}.timing",
                "首条效果不能使用 simultaneous。");
        }

        if (timingValid && timing == SkillEffectTiming.Simultaneous &&
            effect.DelayMilliseconds is > 0)
        {
            Add(errors, BalanceConfigErrorCode.InvalidNumber, $"{effectPath}.delayMilliseconds",
                "simultaneous 不得与正延迟同时声明。");
        }
    }

    /// <summary>周期间隔与重复次数必须成对，且次数至少为 1。</summary>
    private static void ValidateSkillEffectPeriod(
        SkillEffectDefinitionDto effect,
        string effectPath,
        List<BalanceConfigError> errors)
    {
        var hasPeriod = effect.PeriodMilliseconds is not null;
        var hasRepeat = effect.RepeatCount is not null;
        if (hasPeriod)
        {
            RequirePositive(effect.PeriodMilliseconds, $"{effectPath}.periodMilliseconds", errors);
        }

        if (hasRepeat)
        {
            RequirePositive(effect.RepeatCount, $"{effectPath}.repeatCount", errors);
        }

        if (hasPeriod != hasRepeat)
        {
            Add(errors, BalanceConfigErrorCode.MissingValue,
                hasPeriod ? $"{effectPath}.repeatCount" : $"{effectPath}.periodMilliseconds",
                "periodMilliseconds 与 repeatCount 必须成对声明。");
        }

        if (hasPeriod && hasRepeat && effect.RepeatCount is 1)
        {
            Add(errors, BalanceConfigErrorCode.InvalidNumber, $"{effectPath}.repeatCount",
                "周期重复次数必须大于 1。");
        }
    }

    /// <summary>把规范化时间关系转换为强类型枚举。</summary>
    private static bool TryParseSkillTiming(
        string? value,
        string path,
        List<BalanceConfigError> errors,
        out SkillEffectTiming timing)
    {
        var valid = value switch
        {
            "afterPrevious" => (true, SkillEffectTiming.AfterPrevious),
            "simultaneous" => (true, SkillEffectTiming.Simultaneous),
            _ => (false, default(SkillEffectTiming))
        };
        timing = valid.Item2;
        if (!valid.Item1)
        {
            Add(errors, string.IsNullOrWhiteSpace(value) ? BalanceConfigErrorCode.MissingValue :
                BalanceConfigErrorCode.InvalidEnum, path,
                "timing 必须是 afterPrevious 或 simultaneous。");
        }
        return valid.Item1;
    }

    /// <summary>把规范化条件名称转换为强类型枚举。</summary>
    private static bool TryParseSkillCondition(
        string? value,
        string path,
        List<BalanceConfigError> errors,
        out SkillEffectCondition condition)
    {
        var valid = value switch
        {
            "always" => (true, SkillEffectCondition.Always),
            "targetAlive" => (true, SkillEffectCondition.TargetAlive),
            "targetWounded" => (true, SkillEffectCondition.TargetWounded),
            _ => (false, default(SkillEffectCondition))
        };
        condition = valid.Item2;
        if (!valid.Item1)
        {
            Add(errors, string.IsNullOrWhiteSpace(value) ? BalanceConfigErrorCode.MissingValue :
                BalanceConfigErrorCode.InvalidEnum, path,
                "condition 必须是 always、targetAlive 或 targetWounded。");
        }
        return valid.Item1;
    }

    private static SkillAttributeKind ParseSkillAttribute(string _) =>
        SkillAttributeKind.MoveSpeed;

    private static SkillStackRule ParseSkillStack(string value) => value switch
    {
        "overwrite" => SkillStackRule.Overwrite,
        "ignore" => SkillStackRule.Ignore,
        _ => SkillStackRule.Refresh
    };

    private static SkillEffectTiming ParseSkillTiming(string value) =>
        value == "simultaneous" ? SkillEffectTiming.Simultaneous : SkillEffectTiming.AfterPrevious;

    private static SkillEffectCondition ParseSkillCondition(string value) => value switch
    {
        "targetAlive" => SkillEffectCondition.TargetAlive,
        "targetWounded" => SkillEffectCondition.TargetWounded,
        _ => SkillEffectCondition.Always
    };

    private static bool TryParseSkillTriggerEvent(
        string? value,
        string path,
        List<BalanceConfigError> errors,
        out SkillTriggerEvent triggerEvent)
    {
        if (value == "unitDamaged")
        {
            triggerEvent = SkillTriggerEvent.UnitDamaged;
            return true;
        }

        triggerEvent = default;
        Add(errors, string.IsNullOrWhiteSpace(value) ? BalanceConfigErrorCode.MissingValue :
            BalanceConfigErrorCode.InvalidEnum, path, "event 必须是 unitDamaged。");
        return false;
    }

    private static SkillTriggerEvent ParseSkillTriggerEvent(string value) =>
        value == "unitDamaged" ? SkillTriggerEvent.UnitDamaged : SkillTriggerEvent.None;

    private static bool TryParseIssuedCommand(
        string? value,
        string path,
        List<BalanceConfigError> errors,
        out SkillIssuedCommandKind command)
    {
        var valid = value switch
        {
            "move" => (true, SkillIssuedCommandKind.Move),
            "attack" => (true, SkillIssuedCommandKind.Attack),
            _ => (false, default(SkillIssuedCommandKind))
        };
        command = valid.Item2;
        if (!valid.Item1)
        {
            Add(errors, string.IsNullOrWhiteSpace(value) ? BalanceConfigErrorCode.MissingValue :
                BalanceConfigErrorCode.InvalidEnum, path,
                "command 必须是 move 或 attack。");
        }
        return valid.Item1;
    }

    private static bool TryParseEmittedEvent(
        string? value,
        string path,
        List<BalanceConfigError> errors,
        out BattlefieldEventKind kind)
    {
        if (value == "skillEmitted")
        {
            kind = BattlefieldEventKind.SkillEmitted;
            return true;
        }

        kind = default;
        Add(errors, string.IsNullOrWhiteSpace(value) ? BalanceConfigErrorCode.MissingValue :
            BalanceConfigErrorCode.InvalidEnum, path, "eventKind 必须是 skillEmitted。");
        return false;
    }

    private static SkillIssuedCommandKind ParseIssuedCommand(string value) =>
        value == "attack" ? SkillIssuedCommandKind.Attack : SkillIssuedCommandKind.Move;

    private static BattlefieldEventKind ParseEmittedEvent(string _) =>
        BattlefieldEventKind.SkillEmitted;

    private static SkillInterruptDefinition MapSkillInterrupt(SkillInterruptDefinitionDto interrupt) =>
        new(
            (interrupt.Phases ?? [])
                .Select(ParseSkillInterruptPhase)
                .Distinct()
                .ToArray(),
            interrupt.Causes is null or { Count: 0 } ?
                [SkillInterruptCause.Stop] :
                interrupt.Causes.Select(ParseSkillInterruptCause).Distinct().ToArray(),
            interrupt.RefundCost ?? false,
            interrupt.KeepCooldown ?? true);

    private static bool TryParseSkillInterruptPhase(
        string? value,
        string path,
        List<BalanceConfigError> errors,
        out SkillInterruptPhase phase)
    {
        var valid = value switch
        {
            "beforeActivation" => (true, SkillInterruptPhase.BeforeActivation),
            "afterActivation" => (true, SkillInterruptPhase.AfterActivation),
            _ => (false, default(SkillInterruptPhase))
        };
        phase = valid.Item2;
        if (!valid.Item1)
        {
            Add(errors, string.IsNullOrWhiteSpace(value) ? BalanceConfigErrorCode.MissingValue :
                BalanceConfigErrorCode.InvalidEnum, path,
                "phases 必须是 beforeActivation 或 afterActivation。");
        }
        return valid.Item1;
    }

    private static bool TryParseSkillInterruptCause(
        string? value,
        string path,
        List<BalanceConfigError> errors,
        out SkillInterruptCause cause)
    {
        var valid = value switch
        {
            "stop" => (true, SkillInterruptCause.Stop),
            "death" => (true, SkillInterruptCause.Death),
            _ => (false, default(SkillInterruptCause))
        };
        cause = valid.Item2;
        if (!valid.Item1)
        {
            Add(errors, string.IsNullOrWhiteSpace(value) ? BalanceConfigErrorCode.MissingValue :
                BalanceConfigErrorCode.InvalidEnum, path,
                "causes 必须是 stop 或 death。");
        }
        return valid.Item1;
    }

    private static SkillInterruptPhase ParseSkillInterruptPhase(string value) =>
        value == "afterActivation" ?
            SkillInterruptPhase.AfterActivation : SkillInterruptPhase.BeforeActivation;

    private static SkillInterruptCause ParseSkillInterruptCause(string value) =>
        value == "death" ? SkillInterruptCause.Death : SkillInterruptCause.Stop;

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
    private readonly FrozenDictionary<SkillDefinitionId, SkillDefinition> _skills;

    /// <inheritdoc />
    public BalanceConfigVersion Version { get; }

    /// <inheritdoc />
    public IReadOnlyCollection<UnitTypeDefinition> UnitTypes => _unitTypes.Values;

    /// <inheritdoc />
    public IReadOnlyCollection<WeaponDefinition> Weapons => _weapons.Values;

    /// <inheritdoc />
    public IReadOnlyCollection<ProductionDefinition> Productions => _productions.Values;

    /// <inheritdoc />
    public IReadOnlyCollection<StructureConstructionDefinition> Constructions =>
        _constructions.Values;

    /// <inheritdoc />
    public IReadOnlyCollection<SkillDefinition> Skills => _skills.Values;

    /// <summary>冻结全部定义索引，之后不再接受注册或覆盖。</summary>
    public InMemoryGameBalanceCatalog(
        BalanceConfigVersion version,
        IEnumerable<UnitTypeDefinition> unitTypes,
        IEnumerable<WeaponDefinition> weapons,
        IEnumerable<WarheadDefinition> warheads,
        IEnumerable<ProductionDefinition> productions,
        IEnumerable<StructureConstructionDefinition> constructions,
        IEnumerable<ResourceDefinition> resources,
        IEnumerable<SkillDefinition> skills)
    {
        Version = version;
        _unitTypes = unitTypes.ToFrozenDictionary(item => item.Id);
        _weapons = weapons.ToFrozenDictionary(item => item.Id);
        _warheads = warheads.ToFrozenDictionary(item => item.Id);
        _productions = productions.ToFrozenDictionary(item => item.DefinitionId);
        _constructions = constructions.ToFrozenDictionary(item => item.DefinitionId);
        _resources = resources.ToFrozenDictionary(item => item.Kind);
        _skills = skills.ToFrozenDictionary(item => item.Id);
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

    /// <inheritdoc />
    public SkillDefinition? FindSkill(SkillDefinitionId skillId) =>
        _skills.GetValueOrDefault(skillId);
}
