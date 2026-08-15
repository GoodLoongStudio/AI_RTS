using AI_RTS.Domain.Common;
using AI_RTS.Domain.Queries;

namespace AI_RTS.Application.Queries;

/// <summary>在当前无联盟 Demo 中把自己、中立和其他玩家解析为稳定关系。</summary>
public sealed class NoAlliancePlayerRelationResolver : IPlayerRelationResolver
{
    /// <inheritdoc />
    public ObserverRelation Resolve(PlayerId observerPlayerId, PlayerId? ownerPlayerId)
    {
        if (ownerPlayerId is null)
        {
            return ObserverRelation.Neutral;
        }
        return ownerPlayerId.Value == observerPlayerId ?
            ObserverRelation.Self : ObserverRelation.Enemy;
    }
}

/// <summary>实现会话授权、战争迷雾过滤、字段裁剪和稳定空结果语义。</summary>
public sealed class WorldQueryService : IWorldQueryService
{
    private readonly IWorldObservationRepository _repository;
    private readonly IPlayerRelationResolver _relations;
    private readonly IReadOnlyDictionary<QuerySessionId, QuerySessionGrant> _sessions;
    private readonly Dictionary<QuerySessionId, Dictionary<BattlefieldEntityId, RememberedEntity>>
        _lastKnownBySession = new();

    /// <summary>使用组合根预先签发的不可变授权建立查询服务。</summary>
    public WorldQueryService(
        IWorldObservationRepository repository,
        IEnumerable<QuerySessionGrant> grants,
        IPlayerRelationResolver? relations = null)
    {
        _repository = repository ?? throw new ArgumentNullException(nameof(repository));
        _relations = relations ?? new NoAlliancePlayerRelationResolver();
        var grantArray = grants?.ToArray() ?? throw new ArgumentNullException(nameof(grants));
        ValidateGrants(grantArray);
        _sessions = grantArray.ToDictionary(item => item.SessionId);
        foreach (var grant in grantArray.Where(item => !item.Omniscient))
        {
            _lastKnownBySession[grant.SessionId] = new Dictionary<BattlefieldEntityId, RememberedEntity>();
        }
    }

    /// <inheritdoc />
    public QueryResult<IReadOnlyList<EntityObservation>> GetOwnForces(
        QuerySessionId sessionId,
        ObservationField requestedFields)
    {
        if (!TryGetSession(sessionId, out var session))
        {
            return Rejected<IReadOnlyList<EntityObservation>>(QueryErrorCode.InvalidSession);
        }
        if (!FieldsAreValid(requestedFields))
        {
            return Rejected<IReadOnlyList<EntityObservation>>(QueryErrorCode.InvalidRequest);
        }

        var snapshot = _repository.Capture();
        var observations = snapshot.Entities
            .Where(entity => entity.OwnerPlayerId == session.ObserverPlayerId &&
                entity.EntityId.Kind != BattlefieldEntityKind.ResourceNode)
            .OrderBy(entity => entity.EntityId.Kind)
            .ThenBy(entity => entity.EntityId.Value)
            .Select(entity => Observe(
                entity,
                session,
                ObservationState.Owned,
                requestedFields,
                session.OwnFields,
                snapshot.Revision))
            .ToArray();
        return Accepted<IReadOnlyList<EntityObservation>>(observations, snapshot.Revision);
    }

    /// <inheritdoc />
    public QueryResult<IReadOnlyList<EntityObservation>> ScanCircle(
        QuerySessionId sessionId,
        CircleObservationRequest request)
    {
        if (!TryGetSession(sessionId, out var session))
        {
            return Rejected<IReadOnlyList<EntityObservation>>(QueryErrorCode.InvalidSession);
        }
        if (!CircleIsValid(request))
        {
            return Rejected<IReadOnlyList<EntityObservation>>(QueryErrorCode.InvalidRequest);
        }

        var snapshot = _repository.Capture();
        var radiusSquared = request.Radius * request.Radius;
        var currentEntities = snapshot.Entities
            .Where(entity => PlanarDistanceSquared(entity.Position, request.Center) <= radiusSquared)
            .Where(entity => IsObservable(entity, session))
            .OrderBy(entity => entity.EntityId.Kind)
            .ThenBy(entity => entity.EntityId.Value)
            .ToArray();
        if (!session.Omniscient)
        {
            UpdateLastKnown(sessionId, session, snapshot, request, currentEntities);
        }
        var observations = currentEntities.Select(entity =>
            {
                var owned = entity.OwnerPlayerId == session.ObserverPlayerId;
                return Observe(
                    entity,
                    session,
                    owned ? ObservationState.Owned : ObservationState.VisibleNow,
                    request.RequestedFields,
                    owned ? session.OwnFields : session.VisibleFields,
                    snapshot.Revision);
            })
            .Concat(LastKnownInCircle(
                sessionId,
                session,
                request,
                currentEntities.Select(item => item.EntityId).ToHashSet()))
            .OrderBy(entity => entity.EntityId.Kind)
            .ThenBy(entity => entity.EntityId.Value)
            .ToArray();
        return Accepted<IReadOnlyList<EntityObservation>>(observations, snapshot.Revision);
    }

    /// <inheritdoc />
    public QueryResult<EntityObservation> InspectOwnEntity(
        QuerySessionId sessionId,
        BattlefieldEntityId entityId,
        ObservationField requestedFields)
    {
        if (!TryGetSession(sessionId, out var session))
        {
            return Rejected<EntityObservation>(QueryErrorCode.InvalidSession);
        }
        if (!FieldsAreValid(requestedFields) || entityId.Value == Guid.Empty ||
            entityId.Kind == BattlefieldEntityKind.ResourceNode)
        {
            return Rejected<EntityObservation>(QueryErrorCode.InvalidRequest);
        }

        var snapshot = _repository.Capture();
        var entity = snapshot.Entities.FirstOrDefault(item => item.EntityId == entityId);
        if (entity is null || entity.OwnerPlayerId != session.ObserverPlayerId)
        {
            return Rejected<EntityObservation>(
                QueryErrorCode.OwnEntityUnavailable,
                snapshot.Revision);
        }
        return Accepted(
            Observe(
                entity,
                session,
                ObservationState.Owned,
                requestedFields,
                session.OwnFields,
                snapshot.Revision),
            snapshot.Revision);
    }

    /// <inheritdoc />
    public QueryResult<ResourceAccountObservation> GetOwnEconomy(QuerySessionId sessionId)
    {
        if (!TryGetSession(sessionId, out var session))
        {
            return Rejected<ResourceAccountObservation>(QueryErrorCode.InvalidSession);
        }

        var snapshot = _repository.Capture();
        var economy = snapshot.Economies.FirstOrDefault(
            item => item.PlayerId == session.ObserverPlayerId);
        return economy is null ?
            Rejected<ResourceAccountObservation>(
                QueryErrorCode.EconomyUnavailable,
                snapshot.Revision) :
            Accepted(economy.Observation, snapshot.Revision);
    }

    private EntityObservation Observe(
        WorldEntitySnapshot entity,
        QuerySessionGrant session,
        ObservationState state,
        ObservationField requestedFields,
        ObservationField allowedFields,
        long observedRevision)
    {
        var returned = requestedFields & allowedFields & ObservationField.All;
        if (state != ObservationState.Owned && !session.Omniscient)
        {
            returned &= ~(ObservationField.Production | ObservationField.Order);
        }
        return new EntityObservation(
            entity.EntityId,
            state,
            returned,
            observedRevision,
            returned.HasFlag(ObservationField.Position) ? entity.Position : null,
            returned.HasFlag(ObservationField.Type) ? entity.TypeId : null,
            returned.HasFlag(ObservationField.Relation) ?
                _relations.Resolve(session.ObserverPlayerId, entity.OwnerPlayerId) : null,
            returned.HasFlag(ObservationField.Health) ? entity.CurrentHealth : null,
            returned.HasFlag(ObservationField.Health) ? entity.MaximumHealth : null,
            returned.HasFlag(ObservationField.Construction) ? entity.Construction : null,
            returned.HasFlag(ObservationField.Production) ? entity.Production : null,
            returned.HasFlag(ObservationField.Order) ? entity.Order : null);
    }

    private void UpdateLastKnown(
        QuerySessionId sessionId,
        QuerySessionGrant session,
        WorldObservationSnapshot snapshot,
        CircleObservationRequest request,
        IReadOnlyList<WorldEntitySnapshot> currentEntities)
    {
        var memories = _lastKnownBySession[sessionId];
        var currentIds = currentEntities.Select(item => item.EntityId).ToHashSet();
        var staleIds = memories.Values
            .Where(memory => IsInsideCircle(memory.Entity.Position, request))
            .Where(memory => IsPositionVisible(
                snapshot,
                session.ObserverPlayerId,
                memory.Entity.Position))
            .Where(memory => !currentIds.Contains(memory.Entity.EntityId))
            .Select(memory => memory.Entity.EntityId)
            .ToArray();
        foreach (var staleId in staleIds)
        {
            memories.Remove(staleId);
        }

        foreach (var entity in currentEntities.Where(entity =>
            entity.RetainsLastKnownWhenHidden &&
            entity.OwnerPlayerId != session.ObserverPlayerId &&
            entity.VisibleToPlayers.Contains(session.ObserverPlayerId) &&
            _relations.Resolve(session.ObserverPlayerId, entity.OwnerPlayerId) ==
                ObserverRelation.Enemy))
        {
            memories[entity.EntityId] = new RememberedEntity(entity, snapshot.Revision);
        }
    }

    private IEnumerable<EntityObservation> LastKnownInCircle(
        QuerySessionId sessionId,
        QuerySessionGrant session,
        CircleObservationRequest request,
        IReadOnlySet<BattlefieldEntityId> currentIds)
    {
        if (!_lastKnownBySession.TryGetValue(sessionId, out var memories))
        {
            return [];
        }
        return memories.Values
            .Where(memory => !currentIds.Contains(memory.Entity.EntityId) &&
                IsInsideCircle(memory.Entity.Position, request))
            .Select(memory => Observe(
                memory.Entity,
                session,
                ObservationState.LastKnown,
                request.RequestedFields,
                session.VisibleFields,
                memory.ObservedRevision))
            .ToArray();
    }

    private static bool IsPositionVisible(
        WorldObservationSnapshot snapshot,
        PlayerId playerId,
        WorldPosition position) => snapshot.VisibilityRegions.Any(region =>
            region.PlayerId == playerId &&
            PlanarDistanceSquared(region.Center, position) <= region.Radius * region.Radius);

    private static bool IsInsideCircle(
        WorldPosition position,
        CircleObservationRequest request) =>
        PlanarDistanceSquared(position, request.Center) <= request.Radius * request.Radius;

    private static bool IsObservable(
        WorldEntitySnapshot entity,
        QuerySessionGrant session) =>
        entity.OwnerPlayerId == session.ObserverPlayerId || session.Omniscient ||
        entity.VisibleToPlayers.Contains(session.ObserverPlayerId);

    private bool TryGetSession(QuerySessionId sessionId, out QuerySessionGrant session) =>
        _sessions.TryGetValue(sessionId, out session!);

    private static bool CircleIsValid(CircleObservationRequest request) =>
        request is not null && float.IsFinite(request.Center.X) && float.IsFinite(request.Center.Y) &&
        float.IsFinite(request.Center.Z) && float.IsFinite(request.Radius) &&
        request.Radius > 0 && FieldsAreValid(request.RequestedFields);

    private static bool FieldsAreValid(ObservationField fields) =>
        (fields & ~ObservationField.All) == 0;

    private static float PlanarDistanceSquared(WorldPosition left, WorldPosition right)
    {
        var x = left.X - right.X;
        var z = left.Z - right.Z;
        return x * x + z * z;
    }

    private static QueryResult<T> Accepted<T>(T value, long revision) =>
        new(QueryStatus.Accepted, value, null, revision);

    private static QueryResult<T> Rejected<T>(
        QueryErrorCode errorCode,
        long revision = 0) =>
        new(QueryStatus.Rejected, default, errorCode, revision);

    private static void ValidateGrants(IReadOnlyList<QuerySessionGrant> grants)
    {
        if (grants.Any(grant => grant.SessionId.Value == Guid.Empty ||
            grant.ObserverPlayerId.Value == Guid.Empty ||
            !FieldsAreValid(grant.OwnFields) || !FieldsAreValid(grant.VisibleFields)))
        {
            throw new ArgumentException("查询会话必须包含有效身份和字段权限。", nameof(grants));
        }
        if (grants.Select(grant => grant.SessionId).Distinct().Count() != grants.Count)
        {
            throw new ArgumentException("查询会话 ID 必须唯一。", nameof(grants));
        }
        if (grants.Any(grant => grant.Omniscient &&
            grant.Source != QuerySourceKind.OmniscientDebug))
        {
            throw new ArgumentException("只有 OmniscientDebug 来源可以获得全知权限。", nameof(grants));
        }
    }

    private sealed record RememberedEntity(
        WorldEntitySnapshot Entity,
        long ObservedRevision);
}
