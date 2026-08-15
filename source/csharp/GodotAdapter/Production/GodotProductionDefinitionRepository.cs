using AI_RTS.Application.Production;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Construction;
using AI_RTS.Domain.Economy;
using AI_RTS.Domain.Production;
using Godot;

namespace AI_RTS.GodotAdapter.Production;

/// <summary>维护稳定产品定义与 PackedScene 的迁移期映射。</summary>
public sealed class GodotProductionDefinitionRepository : IProductionDefinitionRepository
{
    private sealed record KnownDefinition(
        int RequiredWork,
        ResourceAmount[] Cost,
        string[] AllowedProducers);

    private static readonly Dictionary<string, KnownDefinition> KnownDefinitions = new()
    {
        ["res://source/match/units/Worker.tscn"] = new(
            180,
            [new ResourceAmount(ResourceKind.A, 2)],
            ["command_center"]),
        ["res://source/match/units/Tank.tscn"] = new(
            360,
            [new ResourceAmount(ResourceKind.A, 3), new ResourceAmount(ResourceKind.B, 1)],
            ["vehicle_factory"]),
        ["res://source/match/units/Helicopter.tscn"] = new(
            360,
            [new ResourceAmount(ResourceKind.A, 1), new ResourceAmount(ResourceKind.B, 3)],
            ["aircraft_factory"]),
        ["res://source/match/units/Drone.tscn"] = new(
            180,
            [new ResourceAmount(ResourceKind.A, 2)],
            ["aircraft_factory"])
    };

    private readonly Dictionary<ProductionDefinitionId, ProductionDefinition> _definitions = new();
    private readonly Dictionary<ProductionDefinitionId, PackedScene> _scenes = new();

    /// <summary>按受信任目录注册产品定义，调用方不能覆盖成本、工期或生产资格。</summary>
    public ProductionDefinitionId? Register(PackedScene scene)
    {
        if (!KnownDefinitions.TryGetValue(scene.ResourcePath, out var known))
        {
            return null;
        }
        var definitionId = new ProductionDefinitionId(StableName(scene.ResourcePath));
        var definition = new ProductionDefinition(
            definitionId,
            known.RequiredWork,
            known.Cost,
            known.AllowedProducers.Select(value => new StructureDefinitionId(value)).ToHashSet());
        if (_definitions.TryGetValue(definitionId, out var existing) &&
            !Equivalent(existing, definition))
        {
            return null;
        }
        _definitions[definitionId] = definition;
        _scenes[definitionId] = scene;
        return definitionId;
    }

    /// <summary>按值比较重复注册的定义，避免集合引用差异造成假冲突。</summary>
    private static bool Equivalent(
        ProductionDefinition left,
        ProductionDefinition right)
    {
        return left.DefinitionId == right.DefinitionId &&
            left.RequiredWork == right.RequiredWork &&
            left.Cost.OrderBy(item => item.Kind).SequenceEqual(
                right.Cost.OrderBy(item => item.Kind)) &&
            left.AllowedProducerDefinitions.SetEquals(right.AllowedProducerDefinitions);
    }

    /// <inheritdoc />
    public ProductionDefinition? Find(ProductionDefinitionId definitionId) =>
        _definitions.GetValueOrDefault(definitionId);

    /// <summary>查询用于部署的产品 PackedScene。</summary>
    public PackedScene? FindScene(ProductionDefinitionId definitionId) =>
        _scenes.GetValueOrDefault(definitionId);

    /// <summary>从场景文件名生成不暴露目录结构的稳定 snake_case 名称。</summary>
    private static string StableName(string resourcePath)
    {
        var fileName = resourcePath[(resourcePath.LastIndexOf('/') + 1)..];
        var withoutExtension = fileName[..fileName.LastIndexOf('.')];
        return string.Concat(withoutExtension.Select((character, index) =>
            char.IsUpper(character) && index > 0 ?
                $"_{char.ToLowerInvariant(character)}" :
                char.ToLowerInvariant(character).ToString()));
    }
}
