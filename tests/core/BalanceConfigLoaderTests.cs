using AI_RTS.Application.Configuration;
using AI_RTS.Domain.Combat;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Economy;
using AI_RTS.Domain.Production;

namespace AI_RTS.Tests.Core;

/// <summary>验证版本化 JSON 只能在完整通过校验后生成不可变数值 Catalog。</summary>
internal sealed class BalanceConfigLoaderTests
{
    private int _failures;
    private int _tests;
    private readonly BalanceConfigLoader _loader = new();

    /// <summary>执行强类型配置加载和失败语义回归集合。</summary>
    public int Run()
    {
        RunTest(nameof(DemoBaselineBuildsExpectedCatalog), DemoBaselineBuildsExpectedCatalog);
        RunTest(nameof(IdenticalContentProducesStableHash), IdenticalContentProducesStableHash);
        RunTest(nameof(UnknownPropertyRejectsWholeCatalog), UnknownPropertyRejectsWholeCatalog);
        RunTest(nameof(UnsupportedSchemaRejectsWholeCatalog), UnsupportedSchemaRejectsWholeCatalog);
        RunTest(nameof(DuplicateIdRejectsWholeCatalog), DuplicateIdRejectsWholeCatalog);
        RunTest(nameof(InvalidNumberAndEnumAreReportedTogether), InvalidNumberAndEnumAreReportedTogether);
        RunTest(nameof(MissingReferenceAndDuplicateCostAreRejected),
            MissingReferenceAndDuplicateCostAreRejected);
        RunTest(nameof(DuplicateProductDefinitionIsRejected),
            DuplicateProductDefinitionIsRejected);
        RunTest(nameof(ProfileRequirementsReportMissingDefinitions),
            ProfileRequirementsReportMissingDefinitions);
        RunTest(nameof(InvalidJsonNeverCreatesCatalog), InvalidJsonNeverCreatesCatalog);

        Console.WriteLine(
            $"Balance config tests completed: {_tests} test(s), {_failures} failure(s).");
        return _failures == 0 ? 0 : 1;
    }

    /// <summary>验证 Demo 文件完整映射基线单位、武器、资源、生产和施工数值。</summary>
    private void DemoBaselineBuildsExpectedCatalog()
    {
        var result = _loader.Load(BaselineJson(), DemoBalanceRequirements.Create());

        Check(result.Succeeded, Errors(result));
        Check(result.Catalog is not null, "成功结果必须包含 Catalog");
        var catalog = result.Catalog!;
        Check(catalog.Version.SchemaVersion == 1, "基线 schemaVersion 应为 1");
        Check(catalog.Version.ContentVersion == "demo-baseline-2026-08-12",
            "基线 contentVersion 应保持快照日期");
        Check(catalog.Version.ContentHash.Length == 64, "SHA-256 内容摘要应为 64 位十六进制");

        var tank = catalog.FindUnitType(new UnitTypeId("tank"));
        Check(tank is not null, "Catalog 应包含 Tank");
        Check(tank?.MaxHp == 10.0f && tank.SightRangeMeters == 8.0f,
            "Tank HP 与视野应匹配迁移基线");
        Check(tank?.Movement?.Domain == CombatDomain.Terrain &&
            tank.Movement.SpeedMetersPerSecond == 2.75f &&
            tank.Movement.CanReverse && tank.Movement.CanFireWhileMoving &&
            tank.Movement.MovingWeaponArcDegrees == 120.0f,
            "Tank 移动、倒车和移动射界应匹配当前场景");
        Check(tank?.CanForceFireGround == true, "Tank 应保留对地强制攻击能力");

        var cannon = catalog.FindWeapon(new WeaponDefinitionId("tank_cannon"));
        Check(cannon?.BaseDamage == 2.0f && cannon.CooldownMilliseconds == 750 &&
            cannon.RangeMeters == 5.0f,
            "Tank 主武器应使用整数毫秒并匹配攻击基线");
        Check(cannon?.TargetDomains.SetEquals([CombatDomain.Terrain]) == true,
            "Tank 主武器只应攻击 Terrain");
        Check(catalog.FindWarhead(new WarheadDefinitionId("direct_full_damage"))?
            .FriendlyFireDamageMultiplier == 0.0f,
            "演示直接命中弹头默认禁止友伤");

        var tankProduction = catalog.FindProduction(new ProductionDefinitionId("tank"));
        Check(tankProduction?.ProductTypeId == new UnitTypeId("tank") &&
            tankProduction.RequiredWork == 360,
            "Tank 生产定义应显式引用产品类型并保持 360 工作量");
        Check(tankProduction?.Cost.OrderBy(item => item.Kind).SequenceEqual(
            [new ResourceAmount(ResourceKind.A, 3), new ResourceAmount(ResourceKind.B, 1)]) == true,
            "Tank 生产成本应匹配迁移基线");

        var commandCenter = catalog.FindConstruction(new StructureDefinitionId("command_center"));
        Check(commandCenter?.RequiredWork == 200,
            "CommandCenter 施工应保持迁移期 200 工作量");
        Check(catalog.FindResource(ResourceKind.B)?.CollectionDurationMilliseconds == 2000,
            "Resource B 采集时间应映射为 2000 整数毫秒");
    }

    /// <summary>验证相同原始内容重复加载得到相同内容指纹。</summary>
    private void IdenticalContentProducesStableHash()
    {
        var json = BaselineJson();
        var first = _loader.Load(json, DemoBalanceRequirements.Create());
        var second = _loader.Load(json, DemoBalanceRequirements.Create());

        Check(first.Succeeded && second.Succeeded, "相同基线应可重复加载");
        Check(first.Catalog?.Version.ContentHash == second.Catalog?.Version.ContentHash,
            "相同 UTF-8 内容必须产生稳定摘要");
    }

    /// <summary>验证拼写错误字段返回稳定路径，且不产生部分 Catalog。</summary>
    private void UnknownPropertyRejectsWholeCatalog()
    {
        var json = BaselineJson().Replace(
            "\"schemaVersion\": 1,",
            "\"schemaVersion\": 1,\n  \"schemaVersoin\": 1,",
            StringComparison.Ordinal);
        var result = _loader.Load(json);

        CheckError(result, BalanceConfigErrorCode.UnknownProperty, "$.schemaVersoin");
        Check(result.Catalog is null, "未知字段存在时不得创建部分 Catalog");
    }

    /// <summary>验证不支持的 schema 版本在映射前被拒绝。</summary>
    private void UnsupportedSchemaRejectsWholeCatalog()
    {
        var json = BaselineJson().Replace(
            "\"schemaVersion\": 1",
            "\"schemaVersion\": 2",
            StringComparison.Ordinal);
        var result = _loader.Load(json);

        CheckError(result, BalanceConfigErrorCode.UnsupportedSchemaVersion, "$.schemaVersion");
        Check(result.Catalog is null, "未知 schema 不得创建 Catalog");
    }

    /// <summary>验证重复稳定 ID 不能被后一个定义静默覆盖。</summary>
    private void DuplicateIdRejectsWholeCatalog()
    {
        const string duplicate = """
            {
              "id": "tank",
              "maxHp": 1.0,
              "sightRangeMeters": 1.0,
              "weaponIds": [],
              "canForceFireGround": false
            },
            """;
        var json = BaselineJson().Replace(
            "\"unitTypes\": [",
            $"\"unitTypes\": [{duplicate}",
            StringComparison.Ordinal);
        var result = _loader.Load(json);

        CheckError(result, BalanceConfigErrorCode.DuplicateId, "$.unitTypes[4].id");
        Check(result.Catalog is null, "重复定义不得产生以最后值覆盖的 Catalog");
    }

    /// <summary>验证加载器一次返回可以独立发现的非法数值与非法枚举。</summary>
    private void InvalidNumberAndEnumAreReportedTogether()
    {
        var json = BaselineJson()
            .Replace(
                "\"speedMetersPerSecond\": 2.75",
                "\"speedMetersPerSecond\": -2.75",
                StringComparison.Ordinal)
            .Replace(
                "\"deliveryKind\": \"projectile\"",
                "\"deliveryKind\": \"telepathy\"",
                StringComparison.Ordinal);
        var result = _loader.Load(json);

        Check(result.Errors.Any(item => item.Code == BalanceConfigErrorCode.InvalidNumber),
            "负移动速度应返回 InvalidNumber");
        Check(result.Errors.Any(item => item.Code == BalanceConfigErrorCode.InvalidEnum),
            "未知交付方式应返回 InvalidEnum");
        Check(result.Catalog is null, "多项错误存在时不得创建 Catalog");
    }

    /// <summary>验证悬空弹头引用和重复资源成本均被完整报告。</summary>
    private void MissingReferenceAndDuplicateCostAreRejected()
    {
        var json = BaselineJson()
            .Replace(
                "\"warheadId\": \"direct_full_damage\"",
                "\"warheadId\": \"missing_warhead\"",
                StringComparison.Ordinal)
            .Replace(
                "{ \"kind\": \"A\", \"amount\": 3 },",
                "{ \"kind\": \"A\", \"amount\": 3 },\n        " +
                "{ \"kind\": \"A\", \"amount\": 1 },",
                StringComparison.Ordinal);
        var result = _loader.Load(json);

        Check(result.Errors.Any(item => item.Code == BalanceConfigErrorCode.MissingReference),
            "不存在的弹头应返回 MissingReference");
        Check(result.Errors.Any(item => item.Code == BalanceConfigErrorCode.DuplicateResourceCost),
            "同一成本内重复资源应返回 DuplicateResourceCost");
        Check(result.Catalog is null, "引用和成本错误不得创建 Catalog");
    }

    /// <summary>验证迁移期同一产品不能对应多个依赖 PackedScene 反查的生产定义。</summary>
    private void DuplicateProductDefinitionIsRejected()
    {
        const string duplicate = """
            {
              "id": "tank_alternate",
              "productUnitTypeId": "tank",
              "requiredWork": 360,
              "cost": [],
              "allowedProducerUnitTypeIds": ["vehicle_factory"]
            },
            """;
        var json = BaselineJson().Replace(
            "\"productions\": [",
            $"\"productions\": [{duplicate}",
            StringComparison.Ordinal);
        var result = _loader.Load(json);

        CheckError(result, BalanceConfigErrorCode.InvalidCapability,
            "$.productions[3].productUnitTypeId");
        Check(result.Catalog is null, "产品生产定义不唯一时不得创建 Catalog");
    }

    /// <summary>验证 Match 组合根可以在通用 schema 校验之外声明必需定义。</summary>
    private void ProfileRequirementsReportMissingDefinitions()
    {
        var requirements = new BalanceConfigRequirements(
            new HashSet<UnitTypeId>([new("missing_unit")]),
            new HashSet<ProductionDefinitionId>(),
            new HashSet<StructureDefinitionId>(),
            new HashSet<ResourceKind>());
        var result = _loader.Load(BaselineJson(), requirements);

        CheckError(result, BalanceConfigErrorCode.MissingRequiredDefinition, "$.unitTypes");
        Check(result.Catalog is null, "缺少组合根必需定义时不得创建 Catalog");
    }

    /// <summary>验证语法错误只返回失败结果，不向调用方抛出解析异常。</summary>
    private void InvalidJsonNeverCreatesCatalog()
    {
        var result = _loader.Load("{ this is not json }");

        CheckError(result, BalanceConfigErrorCode.InvalidJson, null);
        Check(result.Catalog is null, "无效 JSON 不得创建 Catalog");
    }

    /// <summary>从仓库定位并读取本次迁移的 Demo 基线 JSON。</summary>
    private static string BaselineJson()
    {
        var directory = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (directory is not null)
        {
            var path = Path.Combine(
                directory.FullName, "config", "balance", "demo.balance.v1.json");
            if (File.Exists(path))
            {
                return File.ReadAllText(path);
            }
            directory = directory.Parent;
        }
        throw new FileNotFoundException("无法定位 config/balance/demo.balance.v1.json。");
    }

    private void CheckError(
        BalanceConfigLoadResult result,
        BalanceConfigErrorCode code,
        string? path)
    {
        Check(result.Errors.Any(item => item.Code == code &&
            (path is null || item.Path == path)),
            $"应返回 {code}{(path is null ? string.Empty : $" at {path}")}；实际：{Errors(result)}");
    }

    private void RunTest(string name, Action test)
    {
        _tests++;
        var failuresBefore = _failures;
        try
        {
            test();
        }
        catch (Exception exception)
        {
            _failures++;
            Console.Error.WriteLine($"[FAIL] {name}: unexpected {exception}");
        }
        if (_failures == failuresBefore)
        {
            Console.WriteLine($"[PASS] {name}");
        }
    }

    private void Check(bool condition, string message)
    {
        if (condition)
        {
            return;
        }
        _failures++;
        Console.Error.WriteLine($"[FAIL] {message}");
    }

    private static string Errors(BalanceConfigLoadResult result) => string.Join(
        "; ",
        result.Errors.Select(item => $"{item.Code} {item.Path}: {item.Message}"));
}
