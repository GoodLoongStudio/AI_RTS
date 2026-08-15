using System.Collections.Frozen;
using System.Text.Json;
using System.Text.Json.Serialization;
using AI_RTS.Application.Configuration;
using AI_RTS.Domain.Combat;
using AI_RTS.Domain.Common;
using Godot;

namespace AI_RTS.GodotAdapter.Configuration;

/// <summary>表示 Godot 资源映射加载失败的稳定类别。</summary>
public enum GodotAssetManifestErrorCode
{
    /// <summary>JSON 语法、根对象或字段类型无效。</summary>
    InvalidJson,

    /// <summary>配置包含当前 schema 未声明的字段。</summary>
    UnknownProperty,

    /// <summary>schemaVersion 不是当前加载器支持的版本。</summary>
    UnsupportedSchemaVersion,

    /// <summary>必填字段为空或集合缺失。</summary>
    MissingValue,

    /// <summary>同一稳定 ID 或场景路径被重复声明。</summary>
    DuplicateValue,

    /// <summary>资源映射引用了平衡 Catalog 中不存在的定义。</summary>
    MissingBalanceReference,

    /// <summary>Godot 资源路径格式无效、资源不存在或不是 PackedScene。</summary>
    InvalidResource,

    /// <summary>Catalog 中的定义缺少运行所需的场景映射。</summary>
    MissingRequiredAsset
}

/// <summary>记录可定位的 Godot asset manifest 错误。</summary>
/// <param name="Code">稳定错误码。</param>
/// <param name="Path">JSONPath 风格错误位置。</param>
/// <param name="Message">面向开发者的中文诊断。</param>
public sealed record GodotAssetManifestError(
    GodotAssetManifestErrorCode Code,
    string Path,
    string Message);

/// <summary>返回全量 manifest 错误，且只在零错误时携带可用映射。</summary>
/// <param name="Manifest">成功时的不可变资源映射。</param>
/// <param name="Errors">按验证顺序排列的全部错误。</param>
public sealed record GodotAssetManifestLoadResult(
    GodotAssetManifest? Manifest,
    IReadOnlyList<GodotAssetManifestError> Errors)
{
    /// <summary>指示资源映射是否完整加载。</summary>
    public bool Succeeded => Manifest is not null && Errors.Count == 0;
}

/// <summary>保存稳定类型 ID 与 Godot PackedScene 之间的不可变映射。</summary>
public sealed class GodotAssetManifest
{
    private readonly FrozenDictionary<UnitTypeId, PackedScene> _unitScenes;
    private readonly FrozenDictionary<string, UnitTypeId> _unitTypesByScenePath;
    private readonly FrozenDictionary<UnitTypeId, PackedScene> _blueprintScenes;
    private readonly FrozenDictionary<WeaponDefinitionId, PackedScene> _projectileScenes;

    /// <summary>manifest 结构版本。</summary>
    public int SchemaVersion { get; }

    /// <summary>由项目维护的资源映射内容版本。</summary>
    public string ContentVersion { get; }

    /// <summary>冻结已经校验和加载的所有 PackedScene 映射。</summary>
    internal GodotAssetManifest(
        int schemaVersion,
        string contentVersion,
        IEnumerable<KeyValuePair<UnitTypeId, PackedScene>> unitScenes,
        IEnumerable<KeyValuePair<UnitTypeId, PackedScene>> blueprintScenes,
        IEnumerable<KeyValuePair<WeaponDefinitionId, PackedScene>> projectileScenes)
    {
        SchemaVersion = schemaVersion;
        ContentVersion = contentVersion;
        _unitScenes = unitScenes.ToFrozenDictionary();
        _unitTypesByScenePath = _unitScenes.ToFrozenDictionary(
            item => item.Value.ResourcePath,
            item => item.Key,
            StringComparer.Ordinal);
        _blueprintScenes = blueprintScenes.ToFrozenDictionary();
        _projectileScenes = projectileScenes.ToFrozenDictionary();
    }

    /// <summary>按稳定实体类型查询可生成场景。</summary>
    public PackedScene? FindUnitScene(UnitTypeId unitTypeId) =>
        _unitScenes.GetValueOrDefault(unitTypeId);

    /// <summary>按 PackedScene 资源路径反查稳定实体类型。</summary>
    public UnitTypeId? FindUnitType(PackedScene scene) =>
        FindUnitType(scene.ResourcePath);

    /// <summary>按实例保留的 PackedScene 资源路径反查稳定实体类型。</summary>
    public UnitTypeId? FindUnitType(string scenePath) =>
        _unitTypesByScenePath.TryGetValue(scenePath, out var unitTypeId) ?
            unitTypeId : null;

    /// <summary>按稳定建筑类型查询放置预览场景。</summary>
    public PackedScene? FindBlueprintScene(UnitTypeId unitTypeId) =>
        _blueprintScenes.GetValueOrDefault(unitTypeId);

    /// <summary>按稳定武器 ID 查询投射物表现场景。</summary>
    public PackedScene? FindProjectileScene(WeaponDefinitionId weaponId) =>
        _projectileScenes.GetValueOrDefault(weaponId);
}

/// <summary>严格校验 Godot 资源映射并在成功时预加载 PackedScene。</summary>
public sealed class GodotAssetManifestLoader
{
    /// <summary>当前支持的资源映射结构版本。</summary>
    public const int SupportedSchemaVersion = 1;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = false,
        AllowTrailingCommas = false,
        ReadCommentHandling = JsonCommentHandling.Disallow
    };

    /// <summary>解析映射、检查 Catalog 引用和 Godot 资源类型，并拒绝部分结果。</summary>
    public GodotAssetManifestLoadResult Load(string json, IGameBalanceCatalog catalog)
    {
        if (string.IsNullOrWhiteSpace(json))
        {
            return Failed(GodotAssetManifestErrorCode.InvalidJson, "$", "manifest 不能为空。");
        }

        GodotAssetManifestDto? dto;
        try
        {
            dto = JsonSerializer.Deserialize<GodotAssetManifestDto>(json, JsonOptions);
        }
        catch (JsonException exception)
        {
            return Failed(
                GodotAssetManifestErrorCode.InvalidJson,
                string.IsNullOrWhiteSpace(exception.Path) ? "$" : exception.Path,
                $"manifest JSON 无法解析：{exception.Message}");
        }

        if (dto is null)
        {
            return Failed(GodotAssetManifestErrorCode.InvalidJson, "$", "manifest 根对象不能为 null。");
        }

        var errors = Validate(dto, catalog);
        if (errors.Count != 0)
        {
            return new GodotAssetManifestLoadResult(null, errors.AsReadOnly());
        }

        var unitScenes = dto.UnitAssets!.Select(item =>
            KeyValuePair.Create(
                new UnitTypeId(item.UnitTypeId!),
                ResourceLoader.Load<PackedScene>(item.ScenePath!)));
        var blueprints = dto.UnitAssets!
            .Where(item => !string.IsNullOrWhiteSpace(item.BlueprintScenePath))
            .Select(item => KeyValuePair.Create(
                new UnitTypeId(item.UnitTypeId!),
                ResourceLoader.Load<PackedScene>(item.BlueprintScenePath!)));
        var projectiles = dto.WeaponAssets!
            .Where(item => !string.IsNullOrWhiteSpace(item.ProjectileScenePath))
            .Select(item => KeyValuePair.Create(
                new WeaponDefinitionId(item.WeaponId!),
                ResourceLoader.Load<PackedScene>(item.ProjectileScenePath!)));
        return new GodotAssetManifestLoadResult(
            new GodotAssetManifest(
                dto.SchemaVersion!.Value,
                dto.ContentVersion!,
                unitScenes,
                blueprints,
                projectiles),
            Array.Empty<GodotAssetManifestError>());
    }

    /// <summary>验证字段、唯一性、Catalog 引用、完整性和 PackedScene 资源。</summary>
    private static List<GodotAssetManifestError> Validate(
        GodotAssetManifestDto dto,
        IGameBalanceCatalog catalog)
    {
        var errors = new List<GodotAssetManifestError>();
        AddUnknown(dto.UnknownProperties, "$", errors);
        if (dto.SchemaVersion is null)
        {
            Add(errors, GodotAssetManifestErrorCode.MissingValue, "$.schemaVersion",
                "必须声明 schemaVersion。");
        }
        else if (dto.SchemaVersion != SupportedSchemaVersion)
        {
            Add(errors, GodotAssetManifestErrorCode.UnsupportedSchemaVersion, "$.schemaVersion",
                $"仅支持 schemaVersion={SupportedSchemaVersion}。");
        }
        if (string.IsNullOrWhiteSpace(dto.ContentVersion))
        {
            Add(errors, GodotAssetManifestErrorCode.MissingValue, "$.contentVersion",
                "必须声明 contentVersion。");
        }
        if (dto.UnitAssets is null)
        {
            Add(errors, GodotAssetManifestErrorCode.MissingValue, "$.unitAssets",
                "必须声明 unitAssets。");
        }
        if (dto.WeaponAssets is null)
        {
            Add(errors, GodotAssetManifestErrorCode.MissingValue, "$.weaponAssets",
                "必须声明 weaponAssets。");
        }

        var unitIds = new HashSet<UnitTypeId>();
        var unitScenePaths = new HashSet<string>(StringComparer.Ordinal);
        var blueprintIds = new HashSet<UnitTypeId>();
        foreach (var pair in (dto.UnitAssets ?? []).Select((item, index) => (item, index)))
        {
            var item = pair.item;
            var path = $"$.unitAssets[{pair.index}]";
            AddUnknown(item.UnknownProperties, path, errors);
            var unitTypeId = new UnitTypeId(item.UnitTypeId ?? string.Empty);
            if (string.IsNullOrWhiteSpace(item.UnitTypeId))
            {
                Add(errors, GodotAssetManifestErrorCode.MissingValue, $"{path}.unitTypeId",
                    "必须声明 unitTypeId。");
            }
            else
            {
                if (!unitIds.Add(unitTypeId))
                {
                    Add(errors, GodotAssetManifestErrorCode.DuplicateValue,
                        $"{path}.unitTypeId", $"实体资源 {item.UnitTypeId} 重复声明。");
                }
                if (catalog.FindUnitType(unitTypeId) is null)
                {
                    Add(errors, GodotAssetManifestErrorCode.MissingBalanceReference,
                        $"{path}.unitTypeId", $"Catalog 中不存在 {item.UnitTypeId}。");
                }
            }
            ValidateScene(item.ScenePath, $"{path}.scenePath", errors);
            if (!string.IsNullOrWhiteSpace(item.ScenePath) &&
                !unitScenePaths.Add(item.ScenePath))
            {
                Add(errors, GodotAssetManifestErrorCode.DuplicateValue, $"{path}.scenePath",
                    $"单位场景路径 {item.ScenePath} 不能映射到多个类型。");
            }
            if (!string.IsNullOrWhiteSpace(item.BlueprintScenePath))
            {
                ValidateScene(item.BlueprintScenePath, $"{path}.blueprintScenePath", errors);
                blueprintIds.Add(unitTypeId);
            }
        }

        var weaponIds = new HashSet<WeaponDefinitionId>();
        foreach (var pair in (dto.WeaponAssets ?? []).Select((item, index) => (item, index)))
        {
            var item = pair.item;
            var path = $"$.weaponAssets[{pair.index}]";
            AddUnknown(item.UnknownProperties, path, errors);
            var weaponId = new WeaponDefinitionId(item.WeaponId ?? string.Empty);
            if (string.IsNullOrWhiteSpace(item.WeaponId))
            {
                Add(errors, GodotAssetManifestErrorCode.MissingValue, $"{path}.weaponId",
                    "必须声明 weaponId。");
            }
            else
            {
                if (!weaponIds.Add(weaponId))
                {
                    Add(errors, GodotAssetManifestErrorCode.DuplicateValue,
                        $"{path}.weaponId", $"武器资源 {item.WeaponId} 重复声明。");
                }
                if (catalog.FindWeapon(weaponId) is null)
                {
                    Add(errors, GodotAssetManifestErrorCode.MissingBalanceReference,
                        $"{path}.weaponId", $"Catalog 中不存在武器 {item.WeaponId}。");
                }
            }
            ValidateScene(item.ProjectileScenePath, $"{path}.projectileScenePath", errors);
        }

        foreach (var unit in catalog.UnitTypes.OrderBy(item => item.Id.Value))
        {
            if (!unitIds.Contains(unit.Id))
            {
                Add(errors, GodotAssetManifestErrorCode.MissingRequiredAsset, "$.unitAssets",
                    $"实体类型 {unit.Id.Value} 缺少 unit scene 映射。");
            }
        }
        foreach (var construction in catalog.Constructions.OrderBy(item => item.DefinitionId.Value))
        {
            if (!blueprintIds.Contains(construction.UnitTypeId))
            {
                Add(errors, GodotAssetManifestErrorCode.MissingRequiredAsset, "$.unitAssets",
                    $"建筑 {construction.UnitTypeId.Value} 缺少 blueprint scene 映射。");
            }
        }
        foreach (var weapon in catalog.Weapons
            .Where(item => item.DeliveryKind == WeaponDeliveryKind.Projectile)
            .OrderBy(item => item.Id.Value))
        {
            if (!weaponIds.Contains(weapon.Id))
            {
                Add(errors, GodotAssetManifestErrorCode.MissingRequiredAsset, "$.weaponAssets",
                    $"投射物武器 {weapon.Id.Value} 缺少 projectile scene 映射。");
            }
        }
        return errors;
    }

    /// <summary>要求路径位于 res:// 且存在可加载的 PackedScene。</summary>
    private static void ValidateScene(
        string? resourcePath,
        string path,
        List<GodotAssetManifestError> errors)
    {
        if (string.IsNullOrWhiteSpace(resourcePath))
        {
            Add(errors, GodotAssetManifestErrorCode.MissingValue, path, "必须声明资源路径。");
            return;
        }
        if (!resourcePath.StartsWith("res://", StringComparison.Ordinal) ||
            !resourcePath.EndsWith(".tscn", StringComparison.OrdinalIgnoreCase) ||
            !ResourceLoader.Exists(resourcePath, "PackedScene"))
        {
            Add(errors, GodotAssetManifestErrorCode.InvalidResource, path,
                $"{resourcePath} 不是存在的 res:// PackedScene。");
        }
    }

    private static void AddUnknown(
        IReadOnlyDictionary<string, JsonElement>? unknown,
        string path,
        List<GodotAssetManifestError> errors)
    {
        if (unknown is null)
        {
            return;
        }
        foreach (var name in unknown.Keys.Order(StringComparer.Ordinal))
        {
            Add(errors, GodotAssetManifestErrorCode.UnknownProperty, $"{path}.{name}",
                $"字段 {name} 不属于当前 manifest schema。");
        }
    }

    private static GodotAssetManifestLoadResult Failed(
        GodotAssetManifestErrorCode code,
        string path,
        string message) => new(
            null,
            Array.AsReadOnly([new GodotAssetManifestError(code, path, message)]));

    private static void Add(
        ICollection<GodotAssetManifestError> errors,
        GodotAssetManifestErrorCode code,
        string path,
        string message) => errors.Add(new GodotAssetManifestError(code, path, message));
}

/// <summary>保存尚未经过业务校验的 Godot 资源映射根对象。</summary>
internal sealed class GodotAssetManifestDto
{
    /// <summary>资源映射结构版本。</summary>
    public int? SchemaVersion { get; set; }

    /// <summary>由项目维护的可读内容版本。</summary>
    public string? ContentVersion { get; set; }

    /// <summary>实体类型与场景资源映射。</summary>
    public List<UnitAssetDto>? UnitAssets { get; set; }

    /// <summary>武器与投射物表现资源映射。</summary>
    public List<WeaponAssetDto>? WeaponAssets { get; set; }

    /// <summary>捕获当前 schema 未声明的根字段。</summary>
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? UnknownProperties { get; set; }
}

/// <summary>保存尚未校验的实体场景映射。</summary>
internal sealed class UnitAssetDto
{
    /// <summary>稳定实体类型 ID。</summary>
    public string? UnitTypeId { get; set; }

    /// <summary>可生成单位或建筑 PackedScene 路径。</summary>
    public string? ScenePath { get; set; }

    /// <summary>建筑放置预览 PackedScene 路径；非建筑允许省略。</summary>
    public string? BlueprintScenePath { get; set; }

    /// <summary>捕获当前 schema 未声明的实体资源字段。</summary>
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? UnknownProperties { get; set; }
}

/// <summary>保存尚未校验的武器表现资源映射。</summary>
internal sealed class WeaponAssetDto
{
    /// <summary>稳定武器定义 ID。</summary>
    public string? WeaponId { get; set; }

    /// <summary>投射物 PackedScene 路径。</summary>
    public string? ProjectileScenePath { get; set; }

    /// <summary>捕获当前 schema 未声明的武器资源字段。</summary>
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? UnknownProperties { get; set; }
}
