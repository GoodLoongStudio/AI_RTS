using AI_RTS.Application.Configuration;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Combat;
using AI_RTS.Domain.Configuration;
using AI_RTS.Domain.Construction;
using AI_RTS.Domain.Economy;
using AI_RTS.Domain.Production;
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
        // 修复联机/进局黑屏：C# 异常从 _EnterTree 抛到 Godot 会中断节点初始化，
        // 导致 Assets/Catalog 永远保持 null，随后每个 C# 调用都在 GDScript 侧
        // 触发 NullReferenceException 级联（WorkerMenu._ready → Loading 卡死 → 黑屏）。
        // 这里吞掉异常并降级：打印完整堆栈后让对局以「配置降级」方式继续启动，
        // 各查询方法的 null 防御会返回空结果而不是再次级联崩溃。
        try
        {
            var balance = new BalanceConfigLoader().Load(
                ReadText(BalanceConfigPath),
                DemoBalanceRequirements.Create());
            if (!balance.Succeeded)
            {
                Fail("平衡配置加载失败", balance.Errors.Select(item =>
                    $"{item.Code} {item.Path}: {item.Message}"));
                return;
            }
            Catalog = balance.Catalog!;

            var assets = new GodotAssetManifestLoader().Load(
                ReadText(AssetManifestPath),
                Catalog);
            if (!assets.Succeeded)
            {
                Fail("Godot asset manifest 加载失败", assets.Errors.Select(item =>
                    $"{item.Code} {item.Path}: {item.Message}"));
                return;
            }
            Assets = assets.Manifest!;
        }
        catch (System.Exception ex)
        {
            GD.PrintErr($"[BalanceConfigRuntime] 初始化异常，配置降级继续启动：{ex}");
            GD.PushError($"[BalanceConfigRuntime] 初始化异常，配置降级继续启动：{ex.Message}");
        }
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

    /// <summary>返回 HUD 可消费的单位只读显示快照；数值仍以 Catalog 为权威来源。</summary>
    public Godot.Collections.Dictionary GetUnitDisplaySnapshot(PackedScene scene)
    {
        // 防御：配置降级时返回最小快照（含 GDScript 会读取的键），避免 throw 中断
        // GDScript 调用栈造成 HUD 初始化级联失败（修复进局黑屏）。
        if (Catalog is null || Assets is null || scene is null)
        {
            return new Godot.Collections.Dictionary
            {
                ["unit_type_id"] = string.Empty,
                ["hp_max"] = 0.0f,
                ["sight_range"] = 0.0f
            };
        }
        var unitTypeId = Assets.FindUnitType(scene);
        var unit = unitTypeId is null ? null : Catalog.FindUnitType(unitTypeId.Value);
        if (unit is null)
        {
            GD.PushWarning(
                $"[BalanceConfigRuntime] 场景缺少单位映射（配置降级）：{scene.ResourcePath}");
            return new Godot.Collections.Dictionary
            {
                ["unit_type_id"] = string.Empty,
                ["hp_max"] = 0.0f,
                ["sight_range"] = 0.0f
            };
        }
        var result = new Godot.Collections.Dictionary
        {
            ["unit_type_id"] = unit.Id.Value,
            ["hp_max"] = unit.MaxHp,
            ["sight_range"] = unit.SightRangeMeters
        };
        if (unit.WeaponIds.Count > 1)
        {
            throw new InvalidOperationException(
                $"实体 {unit.Id.Value} 配置了多件武器；当前 HUD 尚未定义多武器展示规则。");
        }
        if (unit.WeaponIds.Count == 1)
        {
            var weapon = Catalog.FindWeapon(unit.WeaponIds[0]) ??
                throw new InvalidOperationException($"主武器 {unit.WeaponIds[0].Value} 不存在。");
            result["attack_damage"] = weapon.BaseDamage;
            result["attack_interval"] = weapon.CooldownMilliseconds / 1000.0;
            result["attack_range"] = weapon.RangeMeters;
        }
        return result;
    }

    /// <summary>按产品场景返回包含 resource_a/resource_b 的生产成本副本。</summary>
    public Godot.Collections.Dictionary GetProductionCost(PackedScene scene)
    {
        var definition = FindProduction(scene) ??
            throw new InvalidOperationException($"场景 {scene.ResourcePath} 没有生产定义。");
        return ToLegacyCosts(definition.Cost);
    }

    /// <summary>按建筑场景返回包含 resource_a/resource_b 的施工成本副本。</summary>
    public Godot.Collections.Dictionary GetConstructionCost(PackedScene scene)
    {
        // 防御：配置降级时返回空成本，而不是抛异常中断 GDScript 调用栈（修复黑屏级联）。
        if (Catalog is null || Assets is null || scene is null)
        {
            return new Godot.Collections.Dictionary();
        }
        var definition = FindConstruction(scene);
        return definition is null ?
            new Godot.Collections.Dictionary() :
            ToLegacyCosts(definition.Placement.ConstructionCost);
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
        // 防御：配置降级或场景缺失时返回空，避免 NullReferenceException 级联（修复黑屏）。
        if (Catalog is null || Assets is null || scene is null)
        {
            return null;
        }
        var unitTypeId = Assets.FindUnitType(scene);
        return unitTypeId is null ? null :
            Catalog.FindConstruction(new StructureDefinitionId(unitTypeId.Value.Value));
    }

    /// <summary>按运行时建筑的稳定 UnitTypeId 查询施工定义；非建筑返回空。</summary>
    internal StructureConstructionDefinition? FindConstruction(Node structure)
    {
        var unitTypeId = structure.Get("unit_type_id").AsString();
        return string.IsNullOrWhiteSpace(unitTypeId) ? null :
            Catalog.FindConstruction(new StructureDefinitionId(unitTypeId));
    }

    /// <summary>按产品场景查询唯一生产定义。</summary>
    internal ProductionDefinition? FindProduction(PackedScene scene)
    {
        var unitTypeId = Assets.FindUnitType(scene);
        return unitTypeId is null ? null : Catalog.Productions.SingleOrDefault(
            item => item.ProductTypeId == unitTypeId.Value);
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
        movement.Set("max_turn_speed_deg_per_sec", definition.Movement.MaxTurnDegreesPerSecond);
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

    /// <summary>把强类型成本转换成 Legacy HUD/规则 AI 使用的完整双资源字典副本。</summary>
    private static Godot.Collections.Dictionary ToLegacyCosts(
        IEnumerable<ResourceAmount> costs)
    {
        var result = new Godot.Collections.Dictionary
        {
            ["resource_a"] = 0,
            ["resource_b"] = 0
        };
        foreach (var cost in costs)
        {
            result[cost.Kind == ResourceKind.A ? "resource_a" : "resource_b"] = cost.Amount;
        }
        return result;
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
        GD.PrintErr(message);  // 同时写 stderr：Godot logger 未必转发到进程 stderr，便于离线诊断
        throw new InvalidOperationException(message);
    }
}
