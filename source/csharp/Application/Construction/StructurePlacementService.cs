using AI_RTS.Application.Economy;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Construction;
using AI_RTS.Domain.Economy;

namespace AI_RTS.Application.Construction;

/// <summary>组合定义、权限、空间和资源账户，生成不修改状态的建筑放置评估。</summary>
public sealed class StructurePlacementService : IStructurePlacementService
{
    private static readonly StructurePlacementIssue[] IssuePriority =
    [
        StructurePlacementIssue.UnknownDefinition,
        StructurePlacementIssue.InvalidTransform,
        StructurePlacementIssue.NotAuthorized,
        StructurePlacementIssue.ValidationUnavailable,
        StructurePlacementIssue.NotVisible,
        StructurePlacementIssue.OutOfBounds,
        StructurePlacementIssue.SurfaceNotBuildable,
        StructurePlacementIssue.Occupied,
        StructurePlacementIssue.FriendlyDisplacementUnavailable,
        StructurePlacementIssue.InsufficientResources
    ];

    private readonly IStructurePlacementDefinitionRepository _definitions;
    private readonly IStructurePlacementAuthorizationPort _authorization;
    private readonly IStructurePlacementWorldPort _world;
    private readonly IResourceAccountService _accounts;

    /// <summary>建立只依赖抽象端口的建筑放置评估服务。</summary>
    public StructurePlacementService(
        IStructurePlacementDefinitionRepository definitions,
        IStructurePlacementAuthorizationPort authorization,
        IStructurePlacementWorldPort world,
        IResourceAccountService accounts)
    {
        _definitions = definitions;
        _authorization = authorization;
        _world = world;
        _accounts = accounts;
    }

    /// <inheritdoc />
    public StructurePlacementEvaluation Evaluate(EvaluateStructurePlacementQuery query)
    {
        var issues = new HashSet<StructurePlacementIssue>();
        var candidate = query.Candidate;
        if (!ValidDefinitionId(candidate.DefinitionId))
        {
            issues.Add(StructurePlacementIssue.UnknownDefinition);
            return Result(candidate, issues, null);
        }
        if (query.MatchId.Value == Guid.Empty || query.PlayerId.Value == Guid.Empty)
        {
            issues.Add(StructurePlacementIssue.ValidationUnavailable);
            return Result(candidate, issues, null);
        }
        if (!ValidTransform(candidate))
        {
            issues.Add(StructurePlacementIssue.InvalidTransform);
            return Result(candidate, issues, null);
        }

        candidate = candidate with { YawRadians = NormalizeYaw(candidate.YawRadians) };
        StructurePlacementDefinition? definition;
        try
        {
            definition = _definitions.Find(candidate.DefinitionId);
        }
        catch
        {
            issues.Add(StructurePlacementIssue.ValidationUnavailable);
            return Result(candidate, issues, null);
        }

        if (definition is null)
        {
            issues.Add(StructurePlacementIssue.UnknownDefinition);
            return Result(candidate, issues, null);
        }
        if (!ValidDefinition(definition))
        {
            issues.Add(StructurePlacementIssue.ValidationUnavailable);
            return Result(candidate, issues, null);
        }

        try
        {
            if (!_authorization.CanPlace(query.MatchId, query.PlayerId, candidate.DefinitionId))
            {
                issues.Add(StructurePlacementIssue.NotAuthorized);
            }
        }
        catch
        {
            issues.Add(StructurePlacementIssue.ValidationUnavailable);
        }

        try
        {
            foreach (var issue in _world.Evaluate(
                query.MatchId, query.PlayerId, candidate, definition))
            {
                if (IsWorldIssue(issue))
                {
                    issues.Add(issue);
                }
                else
                {
                    issues.Add(StructurePlacementIssue.ValidationUnavailable);
                }
            }
        }
        catch
        {
            issues.Add(StructurePlacementIssue.ValidationUnavailable);
        }

        long? accountVersion = null;
        try
        {
            var snapshot = _accounts.Find(query.PlayerId);
            if (snapshot is null)
            {
                issues.Add(StructurePlacementIssue.ValidationUnavailable);
            }
            else
            {
                accountVersion = snapshot.Version;
                if (definition.ConstructionCost.Any(
                    cost => snapshot.GetBalance(cost.Kind) < cost.Amount))
                {
                    issues.Add(StructurePlacementIssue.InsufficientResources);
                }
            }
        }
        catch
        {
            issues.Add(StructurePlacementIssue.ValidationUnavailable);
        }

        return Result(candidate, issues, accountVersion);
    }

    /// <summary>验证稳定建筑定义键不为空白。</summary>
    private static bool ValidDefinitionId(StructureDefinitionId definitionId) =>
        !string.IsNullOrWhiteSpace(definitionId.Value);

    /// <summary>验证候选坐标与角度均为有限值。</summary>
    private static bool ValidTransform(StructurePlacementCandidate candidate) =>
        float.IsFinite(candidate.Position.X) && float.IsFinite(candidate.Position.Y) &&
        float.IsFinite(candidate.Position.Z) && float.IsFinite(candidate.YawRadians);

    /// <summary>验证定义成本、环境和 footprint 没有把配置错误伪装成合法结果。</summary>
    private static bool ValidDefinition(StructurePlacementDefinition definition)
    {
        if (!ValidDefinitionId(definition.DefinitionId) ||
            string.IsNullOrWhiteSpace(definition.EnvironmentId.Value) ||
            definition.ConstructionCost is null || definition.ConstructionCost.Count == 0 ||
            definition.ConstructionCost.Any(cost =>
                !Enum.IsDefined(cost.Kind) || cost.Amount < 0) ||
            definition.ConstructionCost.Select(cost => cost.Kind).Distinct().Count() !=
                definition.ConstructionCost.Count)
        {
            return false;
        }

        return definition.Footprint switch
        {
            CirclePlacementFootprint circle =>
                float.IsFinite(circle.Radius) && circle.Radius > 0.0f,
            BoxPlacementFootprint box =>
                float.IsFinite(box.HalfWidth) && box.HalfWidth > 0.0f &&
                float.IsFinite(box.HalfDepth) && box.HalfDepth > 0.0f,
            ConvexPlacementFootprint polygon =>
                polygon.Vertices is { Count: >= 3 } && polygon.Vertices.All(vertex =>
                    float.IsFinite(vertex.X) && float.IsFinite(vertex.Z)),
            _ => false
        };
    }

    /// <summary>把任意有限角度规范化到半开区间 [0, 2π)。</summary>
    private static float NormalizeYaw(float yaw)
    {
        var normalized = yaw % MathF.Tau;
        return normalized < 0.0f ? normalized + MathF.Tau : normalized;
    }

    /// <summary>限制世界端口只能返回其职责范围内的问题。</summary>
    private static bool IsWorldIssue(StructurePlacementIssue issue) => issue is
        StructurePlacementIssue.NotVisible or StructurePlacementIssue.OutOfBounds or
        StructurePlacementIssue.SurfaceNotBuildable or StructurePlacementIssue.Occupied or
        StructurePlacementIssue.FriendlyDisplacementUnavailable or
        StructurePlacementIssue.ValidationUnavailable;

    /// <summary>按固定优先级创建不可变评估结果。</summary>
    private static StructurePlacementEvaluation Result(
        StructurePlacementCandidate candidate,
        IReadOnlySet<StructurePlacementIssue> issues,
        long? accountVersion)
    {
        var ordered = IssuePriority.Where(issues.Contains).ToArray();
        return new StructurePlacementEvaluation(
            candidate,
            ordered.Length == 0,
            ordered.Length == 0 ? null : ordered[0],
            ordered,
            accountVersion);
    }
}
