using AI_RTS.Application.Construction;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Construction;

namespace AI_RTS.GodotAdapter.Construction;

/// <summary>在 Match 生命周期内保存由 Godot 配置注册的建筑放置定义。</summary>
internal sealed class GodotStructurePlacementDefinitionRepository :
    IStructurePlacementDefinitionRepository
{
    private readonly Dictionary<StructureDefinitionId, StructurePlacementDefinition> _definitions =
        new();

    /// <summary>注册或更新一个已经过 Godot Adapter 解析的建筑定义。</summary>
    public void Register(StructurePlacementDefinition definition) =>
        _definitions[definition.DefinitionId] = definition;

    /// <inheritdoc />
    public StructurePlacementDefinition? Find(StructureDefinitionId definitionId) =>
        _definitions.GetValueOrDefault(definitionId);
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
