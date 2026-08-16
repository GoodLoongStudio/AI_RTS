using AI_RTS.Application.Configuration;
using AI_RTS.Application.Construction;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Construction;

namespace AI_RTS.GodotAdapter.Construction;

/// <summary>从 Match 不可变 Catalog 查询建筑放置定义。</summary>
internal sealed class GodotStructurePlacementDefinitionRepository :
    IStructurePlacementDefinitionRepository
{
    private readonly IGameBalanceCatalog _catalog;

    /// <summary>建立只读 Catalog 适配器，不接受运行时覆盖。</summary>
    public GodotStructurePlacementDefinitionRepository(IGameBalanceCatalog catalog)
    {
        _catalog = catalog;
    }

    /// <inheritdoc />
    public StructurePlacementDefinition? Find(StructureDefinitionId definitionId) =>
        _catalog.FindConstruction(definitionId)?.Placement;
}

/// <summary>迁移期允许所有已注册定义；科技树权限以后替换此端口。</summary>
internal sealed class AllowRegisteredStructurePlacementAuthorization :
    IStructurePlacementAuthorizationPort
{
    /// <inheritdoc />
    public bool CanPlace(
        MatchId matchId,
        PlayerId playerId,
        StructureDefinitionId definitionId) => true;
}
