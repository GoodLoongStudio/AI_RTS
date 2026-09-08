using AI_RTS.Domain.Combat;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Configuration;
using AI_RTS.Domain.Construction;
using AI_RTS.Domain.Economy;
using AI_RTS.Domain.Production;
using AI_RTS.GodotAdapter.Configuration;
using AI_RTS.GodotAdapter.Economy;
using Godot;

namespace AI_RTS.GodotAdapter.Adjutant;

/// <summary>
/// 副官双层改造第一阶段：从当前 Match 实际加载的 Catalog 导出规则视图与观测包头。
/// 只读导出，不建立第二套平衡数据；数值全部来自 IGameBalanceCatalog，
/// 场景路径只由受信任 asset manifest 解析，模型不得构造任意资源路径。
/// 本节点由 DebugControlServer（autoload）动态挂载，不进 Match.tscn，避免共享场景冲突。
/// </summary>
public partial class AdjutantObservationRuntime : Node
{
    /// <summary>对局内自增快照序号；新对局由 GDScript 侧重置归属。</summary>
    private long _snapshotCounter;

    /// <summary>当前权威模拟 tick：与 ProductionRuntime.CurrentTick 同源（物理帧，60Hz）。</summary>
    public long CurrentServerTick() => checked((long)Engine.GetPhysicsFrames());

    /// <summary>分配新的观测快照序号。</summary>
    public long NextSnapshotId() => ++_snapshotCounter;

    /// <summary>
    /// 当前对局稳定标识。取统一经济运行时的 MatchId（对局生命周期内不可变）；
    /// 运行时缺失或配置降级时返回空字符串，由调用方显式拒绝命令而不是伪造身份。
    /// </summary>
    public string ResolveMatchId(Node match)
    {
        if (match is null)
        {
            return string.Empty;
        }
        var economy = match.GetNodeOrNull<EconomyRuntime>("EconomyRuntime");
        return economy is null ? string.Empty : economy.MatchId.Value.ToString("D");
    }

    /// <summary>
    /// 当前对局规则版本键（content hash）；用于命令包 rules_version 匹配校验。
    /// Catalog 约定对局生命周期内不可变，因此本键在对局内恒定。
    /// </summary>
    public string ResolveRulesVersion(Node match)
    {
        var runtime = FindConfigRuntime(match);
        return runtime is null ? string.Empty : runtime.Catalog.Version.ContentHash;
    }

    /// <summary>
    /// 构建公共观测包头：schema_version / match_id / player_id / rules_version /
    /// snapshot_id / server_tick。身份由服务端（权威进程）确定，不接受客户端自报。
    /// </summary>
    public Godot.Collections.Dictionary BuildHeader(Node match, Node player)
    {
        return new Godot.Collections.Dictionary
        {
            ["schema_version"] = 1,
            ["match_id"] = ResolveMatchId(match),
            ["player_id"] = player is null ? string.Empty : player.Name.ToString(),
            ["rules_version"] = ResolveRulesVersion(match),
            ["snapshot_id"] = NextSnapshotId(),
            ["server_tick"] = CurrentServerTick(),
        };
    }

    /// <summary>
    /// 从当前 Match 实际使用的 Catalog 导出规则视图。Catalog 在对局生命周期内不可变，
    /// 重复调用返回等价内容；缺失语义显式标记 null/unsupported，不伪造默认值。
    /// </summary>
    public Godot.Collections.Dictionary ExportRules(Node match)
    {
        var runtime = FindConfigRuntime(match);
        if (runtime is null || runtime.Catalog is null || runtime.Assets is null)
        {
            return new Godot.Collections.Dictionary
            {
                ["error"] = "balance_catalog_unavailable",
                ["reason"] = "当前对局没有可用的平衡 Catalog（配置降级），拒绝导出规则视图。",
            };
        }
        var catalog = runtime.Catalog;
        var assets = runtime.Assets;

        var constructionsByUnit = catalog.Constructions.ToDictionary(
            item => item.UnitTypeId, item => item);
        var unitTypes = new Godot.Collections.Array();
        foreach (var unit in catalog.UnitTypes.OrderBy(item => item.Id.Value, StringComparer.Ordinal))
        {
            var weapons = new Godot.Collections.Array();
            foreach (var weaponId in unit.WeaponIds)
            {
                var weapon = catalog.FindWeapon(weaponId);
                if (weapon is null)
                {
                    continue;
                }
                var domains = new Godot.Collections.Array();
                foreach (var domain in weapon.TargetDomains)
                {
                    domains.Add(ToDomainName(domain));
                }
                weapons.Add(new Godot.Collections.Dictionary
                {
                    ["id"] = weapon.Id.Value,
                    ["damage"] = weapon.BaseDamage,
                    ["cooldown_ms"] = weapon.CooldownMilliseconds,
                    ["range"] = weapon.RangeMeters,
                    ["target_domains"] = domains,
                });
            }

            var capabilities = new Godot.Collections.Dictionary
            {
                ["move"] = unit.Movement is not null,
                ["attack"] = unit.WeaponIds.Count > 0,
                ["gather"] = unit.Gatherer is not null,
                ["construct"] = unit.Constructor is not null,
                ["produce"] = unit.Producer is not null,
                ["force_fire_ground"] = unit.CanForceFireGround,
            };

            var entry = new Godot.Collections.Dictionary
            {
                ["id"] = unit.Id.Value,
                // 当前工程没有单位本地化/展示名资源：display_name 暂等于稳定 ID，
                // 后续接入本地化时必须保持与 Catalog 类型 ID 关联（偏差记录见审查报告）。
                ["display_name"] = unit.Id.Value,
                ["max_hp"] = unit.MaxHp,
                ["sight_range"] = unit.SightRangeMeters,
                ["movement"] = unit.Movement is null ? new Godot.Collections.Dictionary() :
                    MovementToGodot(unit.Movement),
                ["weapons"] = weapons,
                ["capabilities"] = capabilities,
                ["gatherer_carry_capacity"] =
                    unit.Gatherer is null ? Variant.From(0) : Variant.From(unit.Gatherer.CarryCapacity),
                ["constructor_work_per_tick"] =
                    unit.Constructor is null ? Variant.From(0) : Variant.From(unit.Constructor.WorkPerTick),
                ["producer_queue_limit"] =
                    unit.Producer is null ? Variant.From(0) : Variant.From(unit.Producer.QueueLimit),
                ["scene_path"] = assets.FindUnitScene(unit.Id)?.ResourcePath ?? string.Empty,
                ["is_structure"] = constructionsByUnit.ContainsKey(unit.Id),
            };
            if (constructionsByUnit.TryGetValue(unit.Id, out var construction))
            {
                entry["construction_id"] = construction.DefinitionId.Value;
            }
            unitTypes.Add(entry);
        }

        var productions = new Godot.Collections.Array();
        foreach (var production in catalog.Productions.OrderBy(item => item.DefinitionId.Value, StringComparer.Ordinal))
        {
            var producers = new Godot.Collections.Array();
            foreach (var producer in production.AllowedProducerDefinitions)
            {
                producers.Add(producer.Value);
            }
            productions.Add(new Godot.Collections.Dictionary
            {
                ["id"] = production.DefinitionId.Value,
                ["product_type_id"] = production.ProductTypeId.Value,
                ["required_work"] = production.RequiredWork,
                ["cost"] = CostsToGodot(production.Cost),
                ["allowed_producer_type_ids"] = producers,
            });
        }

        var constructions = new Godot.Collections.Array();
        foreach (var construction in catalog.Constructions.OrderBy(item => item.DefinitionId.Value, StringComparer.Ordinal))
        {
            var footprintRadius = construction.Placement.Footprint is CirclePlacementFootprint circle
                ? circle.Radius : 0.0f;
            constructions.Add(new Godot.Collections.Dictionary
            {
                ["id"] = construction.DefinitionId.Value,
                ["unit_type_id"] = construction.UnitTypeId.Value,
                ["required_work"] = construction.RequiredWork,
                ["cost"] = CostsToGodot(construction.Placement.ConstructionCost),
                ["footprint_radius_meters"] = footprintRadius,
                ["blueprint_scene_path"] =
                    assets.FindBlueprintScene(construction.UnitTypeId)?.ResourcePath ?? string.Empty,
            });
        }

        var resources = new Godot.Collections.Array();
        foreach (var kind in new[] { ResourceKind.A, ResourceKind.B })
        {
            var definition = catalog.FindResource(kind);
            if (definition is null)
            {
                continue;
            }
            resources.Add(new Godot.Collections.Dictionary
            {
                ["kind"] = definition.Kind.ToString(),
                ["collection_duration_ms"] = definition.CollectionDurationMilliseconds,
            });
        }

        var skills = new Godot.Collections.Array();
        foreach (var skill in catalog.Skills.OrderBy(item => item.Id.Value, StringComparer.Ordinal))
        {
            // 第一阶段命令协议未实现技能动作（cast_skill 不在 adjutant_command 动作集），
            // 因此全部技能对副官标为不可调用：命令执行与观测均不支持时不声明可由副官使用。
            skills.Add(new Godot.Collections.Dictionary
            {
                ["id"] = skill.Id.Value,
                ["trigger"] = skill.Trigger.ToString(),
                ["target"] = skill.Target.ToString(),
                ["cooldown_ms"] = skill.CooldownMilliseconds,
                ["adjutant_callable"] = false,
            });
        }

        return new Godot.Collections.Dictionary
        {
            ["schema_version"] = 1,
            ["rules_version"] = new Godot.Collections.Dictionary
            {
                ["schema_version"] = catalog.Version.SchemaVersion,
                ["content_version"] = catalog.Version.ContentVersion,
                ["content_hash"] = catalog.Version.ContentHash,
            },
            ["balance_config_path"] = runtime.BalanceConfigPath,
            ["asset_manifest_content_version"] = assets.ContentVersion,
            ["unit_types"] = unitTypes,
            ["productions"] = productions,
            ["constructions"] = constructions,
            ["resources"] = resources,
            ["skills"] = skills,
        };
    }

    /// <summary>查找当前 Match 的平衡运行时；缺失时返回 null 由调用方降级。</summary>
    private static BalanceConfigRuntime? FindConfigRuntime(Node match)
    {
        if (match is null || !match.IsInsideTree())
        {
            return null;
        }
        return match.GetNodeOrNull<BalanceConfigRuntime>("BalanceConfigRuntime");
    }

    /// <summary>把不可变移动定义转换为 GDScript 可读取字段。</summary>
    private static Godot.Collections.Dictionary MovementToGodot(UnitMovementDefinition movement)
    {
        return new Godot.Collections.Dictionary
        {
            ["domain"] = ToDomainName(movement.Domain),
            ["speed"] = movement.SpeedMetersPerSecond,
            ["max_turn_deg_per_sec"] = movement.MaxTurnDegreesPerSecond,
            ["can_reverse"] = movement.CanReverse,
            ["can_fire_while_moving"] = movement.CanFireWhileMoving,
        };
    }

    /// <summary>把强类型成本列表转换为稳定 kind/amount 字段。</summary>
    private static Godot.Collections.Array CostsToGodot(IReadOnlyList<ResourceAmount> costs)
    {
        var result = new Godot.Collections.Array();
        foreach (var cost in costs)
        {
            result.Add(new Godot.Collections.Dictionary
            {
                ["kind"] = cost.Kind.ToString(),
                ["amount"] = cost.Amount,
            });
        }
        return result;
    }

    /// <summary>把战斗域枚举转换为协议字符串；未知域显式 unsupported。</summary>
    private static string ToDomainName(CombatDomain domain) => domain switch
    {
        CombatDomain.Air => "air",
        CombatDomain.Terrain => "terrain",
        _ => "unsupported",
    };
}
