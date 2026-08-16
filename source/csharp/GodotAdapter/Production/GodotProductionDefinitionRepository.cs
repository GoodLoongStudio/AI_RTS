using AI_RTS.Application.Configuration;
using AI_RTS.Application.Production;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Production;
using AI_RTS.GodotAdapter.Configuration;
using Godot;

namespace AI_RTS.GodotAdapter.Production;

/// <summary>把不可变生产 Catalog 与 Godot 产品 PackedScene 映射组合为生产端口。</summary>
public sealed class GodotProductionDefinitionRepository : IProductionDefinitionRepository
{
    private readonly IGameBalanceCatalog _catalog;
    private readonly GodotAssetManifest _assets;
    private readonly IReadOnlyDictionary<UnitTypeId, ProductionDefinitionId> _products;

    /// <summary>建立每种产品到唯一生产定义的只读索引。</summary>
    public GodotProductionDefinitionRepository(
        IGameBalanceCatalog catalog,
        GodotAssetManifest assets)
    {
        _catalog = catalog;
        _assets = assets;
        _products = catalog.Productions.ToDictionary(
            item => item.ProductTypeId,
            item => item.DefinitionId);
    }

    /// <summary>按受信任 manifest 中的产品场景解析稳定生产定义。</summary>
    public ProductionDefinitionId? Resolve(PackedScene scene)
    {
        var unitTypeId = _assets.FindUnitType(scene);
        return unitTypeId is null ? null : Resolve(unitTypeId.Value);
    }

    /// <summary>按稳定产品类型解析唯一生产定义。</summary>
    public ProductionDefinitionId? Resolve(UnitTypeId productTypeId) =>
        _products.TryGetValue(productTypeId, out var definitionId) ? definitionId : null;

    /// <inheritdoc />
    public ProductionDefinition? Find(ProductionDefinitionId definitionId) =>
        _catalog.FindProduction(definitionId);

    /// <summary>查询生产定义部署时使用的受信任 PackedScene。</summary>
    public PackedScene? FindScene(ProductionDefinitionId definitionId)
    {
        var definition = _catalog.FindProduction(definitionId);
        return definition is null ? null : _assets.FindUnitScene(definition.ProductTypeId);
    }
}
