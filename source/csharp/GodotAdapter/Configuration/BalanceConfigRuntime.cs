using AI_RTS.Application.Configuration;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Combat;
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

    /// <summary>把不可变单位类型和主武器快照写入 Legacy Unit 表现节点。</summary>
    public void ConfigureUnit(Node unit)
    {
        var definition = FindUnitType(unit) ??
            throw new InvalidOperationException(
                $"场景 {unit.SceneFilePath} 没有受信任的单位类型定义。");
        unit.Set("unit_type_id", definition.Id.Value);
        unit.Set("hp_max", definition.MaxHp);
        unit.Set("hp", definition.MaxHp);
        unit.Set("sight_range", definition.SightRangeMeters);
        unit.Set("can_reverse", definition.Movement?.CanReverse ?? false);
        unit.Set("can_fire_while_moving", definition.Movement?.CanFireWhileMoving ?? false);
        unit.Set("can_force_fire_ground", definition.CanForceFireGround);
        unit.Set("moving_weapon_arc_degrees",
            definition.Movement?.MovingWeaponArcDegrees ?? 0.0f);
        unit.Set("resources_max", definition.Gatherer?.CarryCapacity ?? 0);
        unit.Set("construction_work_per_tick", definition.Constructor?.WorkPerTick ?? 0);
        ConfigureMovement(unit, definition);
        ConfigurePrimaryWeapon(unit, definition);
    }

    /// <summary>按 PackedScene 查询已经验证的建筑施工定义。</summary>
    internal StructureConstructionDefinition? FindConstruction(PackedScene scene)
    {
        var unitTypeId = Assets.FindUnitType(scene);
        return unitTypeId is null ? null :
            Catalog.FindConstruction(new StructureDefinitionId(unitTypeId.Value.Value));
    }

    /// <summary>按运行时单位查询已经完整校验的实体类型定义。</summary>
    internal UnitTypeDefinition? FindUnitType(Node unit)
    {
        var unitTypeId = Assets.FindUnitType(unit.SceneFilePath);
        return unitTypeId is null ? null : Catalog.FindUnitType(unitTypeId.Value);
    }

    /// <summary>要求场景的 Movement trait 与配置能力一致，并注入速度和移动空间。</summary>
    private static void ConfigureMovement(Node unit, UnitTypeDefinition definition)
    {
        var movement = unit.FindChild("Movement", false, false);
        if (definition.Movement is null)
        {
            if (movement is not null)
            {
                throw new InvalidOperationException(
                    $"实体 {definition.Id.Value} 有 Movement 节点但配置未声明移动能力。");
            }
            return;
        }
        if (movement is null)
        {
            throw new InvalidOperationException(
                $"实体 {definition.Id.Value} 声明移动能力但场景缺少 Movement 节点。");
        }
        movement.Set("domain", definition.Movement.Domain == CombatDomain.Air ? 0 : 1);
        movement.Set("speed", definition.Movement.SpeedMetersPerSecond);
        movement.Set("reverse_speed_multiplier", definition.Movement.ReverseSpeedMultiplier);
    }

    /// <summary>把当前 Legacy 单武器执行器所需属性绑定到 Catalog 第一主武器。</summary>
    private void ConfigurePrimaryWeapon(Node unit, UnitTypeDefinition definition)
    {
        if (definition.WeaponIds.Count > 1)
        {
            throw new InvalidOperationException(
                $"实体 {definition.Id.Value} 配置了多件武器；当前执行器只支持一件主武器。");
        }
        if (definition.WeaponIds.Count == 0)
        {
            unit.Set("weapon_definition_id", string.Empty);
            unit.Set("attack_damage", default(Variant));
            unit.Set("attack_interval", default(Variant));
            unit.Set("attack_range", default(Variant));
            unit.Set("attack_domains", new Godot.Collections.Array());
            return;
        }

        var weaponId = definition.WeaponIds[0];
        var weapon = Catalog.FindWeapon(weaponId) ??
            throw new InvalidOperationException($"主武器 {weaponId.Value} 不存在。");
        unit.Set("weapon_definition_id", weapon.Id.Value);
        unit.Set("attack_damage", weapon.BaseDamage);
        unit.Set("attack_interval", weapon.CooldownMilliseconds / 1000.0);
        unit.Set("attack_range", weapon.RangeMeters);
        var domains = new Godot.Collections.Array();
        foreach (var domain in weapon.TargetDomains.Order())
        {
            domains.Add(domain == CombatDomain.Air ? 0 : 1);
        }
        unit.Set("attack_domains", domains);
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
