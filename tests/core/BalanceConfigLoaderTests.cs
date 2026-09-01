using AI_RTS.Application.Configuration;
using AI_RTS.Domain.Battlefield;
using AI_RTS.Domain.Combat;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Economy;
using AI_RTS.Domain.Production;
using AI_RTS.Domain.Skills;

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
        RunTest(nameof(DemoSkillIsAvailableFromCatalog), DemoSkillIsAvailableFromCatalog);
        RunTest(nameof(MissingSkillsCollectionRejectsWholeCatalog),
            MissingSkillsCollectionRejectsWholeCatalog);
        RunTest(nameof(SkillInvalidIdRejectsWholeCatalog), SkillInvalidIdRejectsWholeCatalog);
        RunTest(nameof(SkillUnknownEffectKindRejectsWholeCatalog),
            SkillUnknownEffectKindRejectsWholeCatalog);
        RunTest(nameof(SkillUnknownObjectTemplateRejectsWholeCatalog),
            SkillUnknownObjectTemplateRejectsWholeCatalog);
        RunTest(nameof(SkillDuplicateIdRejectsWholeCatalog), SkillDuplicateIdRejectsWholeCatalog);
        RunTest(nameof(SkillInvalidCombinationRejectsWholeCatalog),
            SkillInvalidCombinationRejectsWholeCatalog);

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

        var pulse = catalog.FindSkill(new SkillDefinitionId("demo_self_pulse"));
        Check(pulse is not null, "Catalog 应包含 demo_self_pulse");
        Check(pulse?.Trigger == SkillTriggerKind.Active && pulse.Target == SkillTargetKind.Self,
            "演示技能应为对自身的主动技能");
        Check(pulse?.Effects.Count == 1 &&
            pulse.Effects[0].Kind == SkillEffectKind.DealDamage &&
            pulse.Effects[0].Amount == 1.0f,
            "演示技能应包含一条即时伤害效果");
        Check(pulse?.CooldownMilliseconds == 3000, "演示技能冷却应为 3000 毫秒");
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

    /// <summary>验证基线技能定义能从 Catalog 按稳定 ID 读出。</summary>
    private void DemoSkillIsAvailableFromCatalog()
    {
        var result = _loader.Load(BaselineJson(), DemoBalanceRequirements.Create());
        Check(result.Succeeded, Errors(result));
        var skill = result.Catalog!.FindSkill(new SkillDefinitionId("demo_self_pulse"));
        Check(skill is not null, "FindSkill 应返回演示技能");
        Check(result.Catalog.Skills.Count == 16, "基线应包含十六条演示技能");
        Check(result.Catalog.FindSkill(new SkillDefinitionId("demo_self_heal"))?
            .Effects[0].Kind == SkillEffectKind.RestoreHealth &&
            result.Catalog.FindSkill(new SkillDefinitionId("demo_self_heal"))?
                .EquippedUnitTypeIds is [{ Value: "tank" }],
            "治疗演示技能应配置恢复生命并挂到坦克 HUD");
        Check(result.Catalog.FindSkill(new SkillDefinitionId("demo_unit_pulse"))?
            .EquippedUnitTypeIds is [{ Value: "tank" }],
            "单位脉冲应挂到坦克 HUD");
        var slow = result.Catalog.FindSkill(new SkillDefinitionId("demo_self_slow"))?.Effects[0];
        Check(slow?.Kind == SkillEffectKind.AddStatus &&
            slow.Status?.Id == "demo_slow" &&
            slow.Status.DurationMilliseconds == 3000 &&
            slow.Status.Attribute == SkillAttributeKind.MoveSpeed &&
            slow.Status.Modifier == 0.5f &&
            slow.Status.Stack == SkillStackRule.Refresh,
            "减速演示技能应配置移速状态");
        var burst = result.Catalog.FindSkill(new SkillDefinitionId("demo_self_burst"));
        Check(burst?.Effects.Count == 2 &&
            burst.Effects[1].Timing == SkillEffectTiming.Simultaneous &&
            burst.Effects[1].Kind == SkillEffectKind.RestoreHealth,
            "同时演示技能第二段应与第一段同时恢复生命");
        var ticks = result.Catalog.FindSkill(new SkillDefinitionId("demo_self_ticks"))?.Effects[0];
        Check(ticks?.PeriodMilliseconds == 1000 && ticks.RepeatCount == 3,
            "周期演示技能应配置三次伤害跳");
        Check(result.Catalog.FindSkill(new SkillDefinitionId("demo_self_heal_if_wounded"))?
            .Effects[0].Condition == SkillEffectCondition.TargetWounded,
            "条件演示技能应仅在受伤时治疗");
        var onDamage = result.Catalog.FindSkill(new SkillDefinitionId("demo_on_damage_heal"));
        Check(onDamage?.Trigger == SkillTriggerKind.Event &&
            onDamage.TriggerEvent == SkillTriggerEvent.UnitDamaged &&
            onDamage.EquippedUnitTypeIds is [{ Value: "tank" }],
            "受伤治疗应是装配到坦克的事件技能");
        Check(result.Catalog.FindSkill(new SkillDefinitionId("demo_wounded_regen"))?
            .ActivationCondition == SkillEffectCondition.TargetWounded,
            "条件回春应在受伤时自动评估");
        Check(result.Catalog.FindSkill(new SkillDefinitionId("demo_passive_slow"))?
            .Trigger == SkillTriggerKind.Passive,
            "被动减速应能从 Catalog 读出");
        var windup = result.Catalog.FindSkill(new SkillDefinitionId("demo_windup_pulse"));
        Check(windup?.CastDelayMilliseconds == 1000 &&
            windup.Interrupt?.Phases.Contains(SkillInterruptPhase.BeforeActivation) == true &&
            windup.Interrupt.Causes.Contains(SkillInterruptCause.Stop),
            "引导演示技能应配置施放前等待和停止中断");
        Check(result.Catalog.FindSkill(new SkillDefinitionId("demo_delayed_pulse"))?
            .Effects[1].DelayMilliseconds == 2000,
            "延迟演示技能第二段应在 2000 毫秒后触发");
        var unitPulse = result.Catalog.FindSkill(new SkillDefinitionId("demo_unit_pulse"));
        Check(unitPulse?.Relation == SkillTargetRelation.Enemy &&
            unitPulse.RangeMeters == 5.0f &&
            unitPulse.RequireAlive &&
            !unitPulse.AllowSelf,
            "单位演示技能应带敌方、距离和存活约束");
        Check(unitPulse?.Cost is [{ Kind: ResourceKind.A, Amount: 1 }],
            "单位演示技能应在生效时消耗 1 个 A");
        Check(result.Catalog.FindSkill(new SkillDefinitionId("demo_ground_mark"))?.Effects[0]
            .EmittedEvent == BattlefieldEventKind.SkillEmitted,
            "地面标记应写入统一技能事件");
        Check(result.Catalog.FindSkill(new SkillDefinitionId("demo_issue_move"))?.Effects[0]
            .IssuedCommand == SkillIssuedCommandKind.Move,
            "下达移动应映射到已有 Move");
        Check(result.Catalog.FindSkill(new SkillDefinitionId("demo_issue_attack"))?.Effects[0]
            .IssuedCommand == SkillIssuedCommandKind.Attack,
            "下达攻击应映射到已有 Attack");
        Check(result.Catalog.FindSkill(new SkillDefinitionId("demo_spawn_drone"))?.Effects[0]
            .ObjectTemplateId == new UnitTypeId("drone"),
            "创建对象应引用已有 drone 模板");
    }

    /// <summary>验证未知对象模板整表拒绝。</summary>
    private void SkillUnknownObjectTemplateRejectsWholeCatalog()
    {
        var json = BaselineJson().Replace(
            "\"templateId\": \"drone\"",
            "\"templateId\": \"ghost_trap\"",
            StringComparison.Ordinal);
        var result = _loader.Load(json);

        CheckError(result, BalanceConfigErrorCode.MissingReference,
            "$.skills[15].effects[0].templateId");
        Check(result.Catalog is null, "未知对象模板不得创建 Catalog");
    }

    /// <summary>验证顶层 skills 集合必须显式声明，不允许缺省。</summary>
    private void MissingSkillsCollectionRejectsWholeCatalog()
    {
        var json = BaselineJson();
        var skillsIndex = json.LastIndexOf("  \"skills\":", StringComparison.Ordinal);
        json = json[..skillsIndex].TrimEnd().TrimEnd(',') + "\n}\n";
        var result = _loader.Load(json);

        CheckError(result, BalanceConfigErrorCode.MissingValue, "$.skills");
        Check(result.Catalog is null, "缺少 skills 集合时不得创建 Catalog");
    }

    /// <summary>验证非法技能 ID 整表拒绝，不产生部分 Catalog。</summary>
    private void SkillInvalidIdRejectsWholeCatalog()
    {
        var json = BaselineJson().Replace(
            "\"id\": \"demo_self_pulse\"",
            "\"id\": \"DemoSelfPulse\"",
            StringComparison.Ordinal);
        var result = _loader.Load(json);

        CheckError(result, BalanceConfigErrorCode.InvalidId, "$.skills[0].id");
        Check(result.Catalog is null, "非法技能 ID 不得创建 Catalog");
    }

    /// <summary>验证未知效果种类整表拒绝。</summary>
    private void SkillUnknownEffectKindRejectsWholeCatalog()
    {
        var json = BaselineJson().Replace(
            "\"kind\": \"dealDamage\"",
            "\"kind\": \"explodeEverything\"",
            StringComparison.Ordinal);
        var result = _loader.Load(json);

        CheckError(result, BalanceConfigErrorCode.InvalidEnum, "$.skills[0].effects[0].kind");
        Check(result.Catalog is null, "未知效果种类不得创建 Catalog");
    }

    /// <summary>验证重复技能 ID 不能被后一个定义覆盖。</summary>
    private void SkillDuplicateIdRejectsWholeCatalog()
    {
        const string duplicate = """
            {
              "id": "demo_self_pulse",
              "trigger": "active",
              "target": "self",
              "effects": [
                { "kind": "restoreHealth", "amount": 1.0 }
              ],
              "cooldownMilliseconds": 1000
            },
            """;
        var json = BaselineJson().Replace(
            "\"skills\": [",
            $"\"skills\": [{duplicate}",
            StringComparison.Ordinal);
        var result = _loader.Load(json);

        CheckError(result, BalanceConfigErrorCode.DuplicateId, "$.skills[1].id");
        Check(result.Catalog is null, "重复技能 ID 不得创建 Catalog");
    }

    /// <summary>验证周期与次数不成对、未知条件会整表拒绝。</summary>
    private void SkillInvalidCombinationRejectsWholeCatalog()
    {
        var periodOnly = BaselineJson().Replace(
            """{ "kind": "dealDamage", "amount": 1.0 }""",
            """{ "kind": "dealDamage", "amount": 1.0, "periodMilliseconds": 500 }""",
            StringComparison.Ordinal);
        var periodResult = _loader.Load(periodOnly);
        CheckError(periodResult, BalanceConfigErrorCode.MissingValue,
            "$.skills[0].effects[0].repeatCount");
        Check(periodResult.Catalog is null, "缺少 repeatCount 不得创建 Catalog");

        var badCondition = BaselineJson().Replace(
            """{ "kind": "restoreHealth", "amount": 3.0 }""",
            """{ "kind": "restoreHealth", "amount": 3.0, "condition": "hpBelowHalf" }""",
            StringComparison.Ordinal);
        var conditionResult = _loader.Load(badCondition);
        CheckError(conditionResult, BalanceConfigErrorCode.InvalidEnum,
            "$.skills[4].effects[0].condition");
        Check(conditionResult.Catalog is null, "未知条件不得创建 Catalog");

        var delayedSimultaneous = BaselineJson().Replace(
            """{ "kind": "restoreHealth", "amount": 1.0, "timing": "simultaneous" }""",
            """{ "kind": "restoreHealth", "amount": 1.0, "timing": "simultaneous", "delayMilliseconds": 200 }""",
            StringComparison.Ordinal);
        var timingResult = _loader.Load(delayedSimultaneous);
        CheckError(timingResult, BalanceConfigErrorCode.InvalidNumber,
            "$.skills[6].effects[1].delayMilliseconds");
        Check(timingResult.Catalog is null, "同时与正延迟混用不得创建 Catalog");

        var eventWithoutKind = BaselineJson().Replace(
            """
                  "trigger": "event",
                  "event": "unitDamaged",
            """,
            """
                  "trigger": "event",
            """,
            StringComparison.Ordinal);
        var eventResult = _loader.Load(eventWithoutKind);
        CheckError(eventResult, BalanceConfigErrorCode.MissingValue, "$.skills[9].event");
        Check(eventResult.Catalog is null, "事件技能缺少 event 不得创建 Catalog");

        var emptyInterrupt = BaselineJson().Replace(
            """
                  "id": "demo_self_pulse",
                  "trigger": "active",
                  "target": "self",
            """,
            """
                  "id": "demo_self_pulse",
                  "trigger": "active",
                  "target": "self",
                  "interrupt": { "phases": [] },
            """,
            StringComparison.Ordinal);
        var interruptResult = _loader.Load(emptyInterrupt);
        CheckError(interruptResult, BalanceConfigErrorCode.MissingValue,
            "$.skills[0].interrupt.phases");
        Check(interruptResult.Catalog is null, "空中断阶段不得创建 Catalog");

        var badCommand = BaselineJson().Replace(
            """{ "kind": "issueCommand", "command": "move" }""",
            """{ "kind": "issueCommand", "command": "dance" }""",
            StringComparison.Ordinal);
        var commandResult = _loader.Load(badCommand);
        CheckError(commandResult, BalanceConfigErrorCode.InvalidEnum,
            "$.skills[13].effects[0].command");
        Check(commandResult.Catalog is null, "未知下达命令不得创建 Catalog");
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
