using AI_RTS.Application.Configuration;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Configuration;
using AI_RTS.Domain.Construction;
using AI_RTS.Domain.Economy;
using Godot;

namespace AI_RTS.GodotAdapter.Configuration;

/// <summary>在 Match 进入 SceneTree 时加载唯一平衡 Catalog 和 Godot 资源映射。</summary>
public partial class BalanceConfigRuntime : Node
{
    /// <summary>仓库内权威 Demo 平衡 JSON 路径。</summary>
    [Export(PropertyHint.File, "*.json")]
    public string BalanceConfigPath { get; set; } =
        "res://config/balance/demo.balance.v1.json";

    /// <summary>仓库内权威 Godot asset manifest 路径。</summary>
    [Export(PropertyHint.File, "*.json")]
    public string AssetManifestPath { get; set; } =
        "res://config/godot/demo.assets.v1.json";

    /// <summary>向同一 Match 的 C# Adapter 提供不可变平衡 Catalog。</summary>
    internal IGameBalanceCatalog Catalog { get; private set; } = null!;

    /// <summary>向同一 Match 的 C# Adapter 提供不可变 PackedScene 映射。</summary>
    internal GodotAssetManifest Assets { get; private set; } = null!;

    /// <summary>在其他 Match 子节点初始化前完成配置加载；错误配置直接阻止对局启动。</summary>
    public override void _EnterTree()
    {
        var balance = new BalanceConfigLoader().Load(
            ReadText(BalanceConfigPath),
            DemoBalanceRequirements.Create());
        if (!balance.Succeeded)
        {
            Fail("平衡配置加载失败", balance.Errors.Select(item =>
                $"{item.Code} {item.Path}: {item.Message}"));
        }
        Catalog = balance.Catalog!;

        var assets = new GodotAssetManifestLoader().Load(
            ReadText(AssetManifestPath),
            Catalog);
        if (!assets.Succeeded)
        {
            Fail("Godot asset manifest 加载失败", assets.Errors.Select(item =>
                $"{item.Code} {item.Path}: {item.Message}"));
        }
        Assets = assets.Manifest!;
    }

    /// <summary>按单位或建筑场景查询稳定 UnitTypeId；未知场景返回空字符串。</summary>
    public string GetUnitTypeId(PackedScene scene) =>
        Assets.FindUnitType(scene)?.Value ?? string.Empty;

    /// <summary>按建筑原型查询蓝图场景路径；未知或非建筑类型返回空字符串。</summary>
    public string GetBlueprintScenePath(PackedScene scene)
    {
        var unitTypeId = Assets.FindUnitType(scene);
        return unitTypeId is null ? string.Empty :
            Assets.FindBlueprintScene(unitTypeId.Value)?.ResourcePath ?? string.Empty;
    }

    /// <summary>把 Legacy resource_a/resource_b 名称映射为 Catalog 采集秒数。</summary>
    public double GetCollectionDurationSeconds(string legacyResourceName)
    {
        var kind = legacyResourceName switch
        {
            "resource_a" => ResourceKind.A,
            "resource_b" => ResourceKind.B,
            _ => (ResourceKind?)null
        };
        if (kind is null || Catalog.FindResource(kind.Value) is not { } definition)
        {
            GD.PushError($"未知资源采集配置：{legacyResourceName}");
            return 0.0;
        }
        return definition.CollectionDurationMilliseconds / 1000.0;
    }

    /// <summary>按 PackedScene 查询已经验证的建筑施工定义。</summary>
    internal StructureConstructionDefinition? FindConstruction(PackedScene scene)
    {
        var unitTypeId = Assets.FindUnitType(scene);
        return unitTypeId is null ? null :
            Catalog.FindConstruction(new StructureDefinitionId(unitTypeId.Value.Value));
    }

    /// <summary>读取 res:// JSON；缺失或空文件交给上层严格 Loader 报告。</summary>
    private static string ReadText(string resourcePath)
    {
        if (!Godot.FileAccess.FileExists(resourcePath))
        {
            return string.Empty;
        }
        return Godot.FileAccess.GetFileAsString(resourcePath);
    }

    /// <summary>输出全部配置错误并以异常阻止 Match 使用部分数据继续启动。</summary>
    private static void Fail(string title, IEnumerable<string> errors)
    {
        var message = $"{title}：{System.Environment.NewLine}" +
            string.Join(System.Environment.NewLine, errors);
        GD.PushError(message);
        throw new InvalidOperationException(message);
    }
}
