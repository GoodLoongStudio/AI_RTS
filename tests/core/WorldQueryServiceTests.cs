using AI_RTS.Application.Queries;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Configuration;
using AI_RTS.Domain.Economy;
using AI_RTS.Domain.Production;
using AI_RTS.Domain.Queries;

namespace AI_RTS.Tests.Core;

/// <summary>验证公共查询的会话授权、战争迷雾、字段裁剪和显式空结果。</summary>
internal sealed class WorldQueryServiceTests
{
    private readonly PlayerId _observer = new(Guid.NewGuid());
    private readonly PlayerId _enemy = new(Guid.NewGuid());
    private readonly QuerySessionId _normalSession = new(Guid.NewGuid());
    private readonly QuerySessionId _debugSession = new(Guid.NewGuid());
    private readonly BattlefieldEntityId _ownedUnit =
        new(BattlefieldEntityKind.Unit, Guid.NewGuid());
    private readonly BattlefieldEntityId _visibleEnemy =
        new(BattlefieldEntityKind.Unit, Guid.NewGuid());
    private readonly BattlefieldEntityId _hiddenEnemy =
        new(BattlefieldEntityKind.Structure, Guid.NewGuid());
    private int _failures;
    private int _tests;

    /// <summary>执行全部纯 C# 查询权限测试。</summary>
    public int Run()
    {
        RunTest(nameof(OwnInformationIsAccurateWithoutVisibility), OwnInformationIsAccurateWithoutVisibility);
        RunTest(nameof(ValidEmptyScanIsExplicitSuccess), ValidEmptyScanIsExplicitSuccess);
        RunTest(nameof(NormalAndDebugSessionsHaveDifferentVisibility), NormalAndDebugSessionsHaveDifferentVisibility);
        RunTest(nameof(VisibleFieldPermissionsDoNotLeakHealth), VisibleFieldPermissionsDoNotLeakHealth);
        RunTest(nameof(EnemyAndUnknownDirectInspectionAreIndistinguishable), EnemyAndUnknownDirectInspectionAreIndistinguishable);
        RunTest(nameof(OwnEconomyIsExactAndVersioned), OwnEconomyIsExactAndVersioned);
        RunTest(nameof(OwnConstructionInformationIsAccurateAndPermissionScoped),
            OwnConstructionInformationIsAccurateAndPermissionScoped);
        RunTest(nameof(ProductionInformationIsOwnOnlyExceptForDebug),
            ProductionInformationIsOwnOnlyExceptForDebug);
        RunTest(nameof(OrderInformationIsOwnOnlyAndIdleIsExplicit),
            OrderInformationIsOwnOnlyAndIdleIsExplicit);
        RunTest(nameof(InvalidSessionDoesNotCaptureWorld), InvalidSessionDoesNotCaptureWorld);
        RunTest(nameof(InvalidAreaIsRejected), InvalidAreaIsRejected);
        RunTest(nameof(EnemyStructureBecomesLastKnownButMobileDoesNot), EnemyStructureBecomesLastKnownButMobileDoesNot);
        RunTest(nameof(ReobservedEmptyPositionClearsLastKnown), ReobservedEmptyPositionClearsLastKnown);
        RunTest(nameof(CommandTargetAuthorizationRequiresCurrentEnemyVisibility),
            CommandTargetAuthorizationRequiresCurrentEnemyVisibility);
        RunTest(nameof(BattlefieldBoundsArePublicAndSessionBound),
            BattlefieldBoundsArePublicAndSessionBound);

        Console.WriteLine($"World query tests completed: {_tests} test(s), {_failures} failure(s).");
        return _failures == 0 ? 0 : 1;
    }

    /// <summary>验证己方单位即使未列入可见集合，也返回准确位置与生命值。</summary>
    private void OwnInformationIsAccurateWithoutVisibility()
    {
        var service = NewService(out _);

        var result = service.InspectOwnEntity(
            _normalSession,
            _ownedUnit,
            ObservationField.Position | ObservationField.Health);

        Check(result.Status == QueryStatus.Accepted, "己方实体查询应成功");
        Check(result.Value?.State == ObservationState.Owned, "己方实体应标记为 Owned");
        Check(result.Value?.Position == new WorldPosition(1, 0, 1), "己方位置必须准确");
        Check(result.Value?.CurrentHealth == 7 && result.Value.MaximumHealth == 10,
            "己方生命值必须准确");
    }

    /// <summary>验证合法但没有实体的区域返回 Accepted 和非空空集合。</summary>
    private void ValidEmptyScanIsExplicitSuccess()
    {
        var service = NewService(out _);

        var result = service.ScanCircle(
            _normalSession,
            new CircleObservationRequest(new WorldPosition(100, 0, 100), 1, ObservationField.Type));

        Check(result.Status == QueryStatus.Accepted, "合法空区域应成功");
        Check(result.Value is not null && result.Value.Count == 0,
            "合法空区域必须显式返回空集合");
        Check(result.ErrorCode is null, "合法空区域不应携带错误码");
    }

    /// <summary>验证普通会话受视野约束而全知调试会话可以看到隐藏实体。</summary>
    private void NormalAndDebugSessionsHaveDifferentVisibility()
    {
        var service = NewService(out _);
        var request = new CircleObservationRequest(
            new WorldPosition(0, 0, 0),
            50,
            ObservationField.Type);

        var normal = service.ScanCircle(_normalSession, request);
        var debug = service.ScanCircle(_debugSession, request);

        Check(normal.Value!.All(item => item.EntityId != _hiddenEnemy),
            "普通会话不得看到视野外建筑");
        Check(debug.Value!.Any(item => item.EntityId == _hiddenEnemy),
            "全知调试会话应看到视野外建筑");
    }

    /// <summary>验证可见敌军即使被请求生命值，也只能返回会话获准字段。</summary>
    private void VisibleFieldPermissionsDoNotLeakHealth()
    {
        var service = NewService(out _);
        var result = service.ScanCircle(
            _normalSession,
            new CircleObservationRequest(
                new WorldPosition(4, 0, 4),
                2,
                ObservationField.Position | ObservationField.Type | ObservationField.Health));
        var enemy = result.Value!.Single(item => item.EntityId == _visibleEnemy);

        Check(!enemy.ReturnedFields.HasFlag(ObservationField.Health),
            "未授权敌军生命值字段不应出现在 ReturnedFields");
        Check(enemy.CurrentHealth is null && enemy.MaximumHealth is null,
            "未授权敌军生命值必须为空而非伪造零值");
        Check(enemy.Position == new WorldPosition(4, 0, 4), "已授权位置字段应准确返回");
    }

    /// <summary>验证直接查询敌军和随机未知 ID 返回相同公开错误。</summary>
    private void EnemyAndUnknownDirectInspectionAreIndistinguishable()
    {
        var service = NewService(out _);
        var enemy = service.InspectOwnEntity(
            _normalSession,
            _visibleEnemy,
            ObservationField.Type);
        var unknown = service.InspectOwnEntity(
            _normalSession,
            new BattlefieldEntityId(BattlefieldEntityKind.Unit, Guid.NewGuid()),
            ObservationField.Type);

        Check(enemy.Status == QueryStatus.Rejected && unknown.Status == QueryStatus.Rejected,
            "非己方直接查询均应拒绝");
        Check(enemy.ErrorCode == QueryErrorCode.OwnEntityUnavailable &&
            unknown.ErrorCode == QueryErrorCode.OwnEntityUnavailable,
            "敌军和未知 ID 不得通过错误码区分");
    }

    /// <summary>验证自己的资源余额与账户版本准确返回。</summary>
    private void OwnEconomyIsExactAndVersioned()
    {
        var service = NewService(out _);

        var result = service.GetOwnEconomy(_normalSession);

        Check(result.Status == QueryStatus.Accepted, "己方经济查询应成功");
        Check(result.Value?.AccountVersion == 5, "资源账户版本应准确返回");
        Check(result.Value?.Balances.Single(item => item.Kind == ResourceKind.A).Amount == 12,
            "资源 A 余额应准确返回");
    }

    /// <summary>验证己方施工详情准确返回，未授权敌方不会泄漏施工进度。</summary>
    private void OwnConstructionInformationIsAccurateAndPermissionScoped()
    {
        var service = NewService(out var repository);
        var ownStructure = new BattlefieldEntityId(BattlefieldEntityKind.Structure, Guid.NewGuid());
        repository.Snapshot = repository.Snapshot with
        {
            Entities = repository.Snapshot.Entities.Append(new WorldEntitySnapshot(
                ownStructure,
                _observer,
                new WorldPosition(2, 0, 2),
                "vehicle_factory",
                4,
                16,
                true,
                new HashSet<PlayerId>(),
                new ConstructionObservation(
                    ConstructionObservationState.UnderConstruction, 50, 200, 1))).ToArray()
        };

        var own = service.InspectOwnEntity(
            _normalSession, ownStructure, ObservationField.Construction);
        var enemy = service.ScanCircle(
            _normalSession,
            new CircleObservationRequest(
                new WorldPosition(4, 0, 4), 2, ObservationField.Construction));

        Check(own.Value?.Construction ==
            new ConstructionObservation(
                ConstructionObservationState.UnderConstruction, 50, 200, 1),
            "己方施工工作量与活动建造者数量应准确返回");
        Check(enemy.Value!.Single(item => item.EntityId == _visibleEnemy).Construction is null,
            "未授权敌军不得通过施工字段泄漏进度");
    }

    /// <summary>验证生产空队列显式返回，普通会话即使获授字段也不能读取敌方队列。</summary>
    private void ProductionInformationIsOwnOnlyExceptForDebug()
    {
        var service = NewService(out var repository);
        var ownProducer = new BattlefieldEntityId(BattlefieldEntityKind.Structure, Guid.NewGuid());
        var enemyProducer = new BattlefieldEntityId(BattlefieldEntityKind.Structure, Guid.NewGuid());
        var emptyProduction = new ProductionObservation(5, []);
        var enemyProduction = new ProductionObservation(5,
        [
            new ProductionItemObservation(
                new ProductionItemId(Guid.NewGuid()),
                new UnitTypeId("tank"),
                ProductionItemState.Producing,
                10,
                100)
        ]);
        repository.Snapshot = repository.Snapshot with
        {
            Entities = repository.Snapshot.Entities.Concat(
            [
                new WorldEntitySnapshot(
                    ownProducer, _observer, new WorldPosition(2, 0, 2),
                    "command_center", 20, 20, true, new HashSet<PlayerId>(),
                    Production: emptyProduction),
                new WorldEntitySnapshot(
                    enemyProducer, _enemy, new WorldPosition(3, 0, 3),
                    "vehicle_factory", 16, 16, true,
                    new HashSet<PlayerId> { _observer }, Production: enemyProduction)
            ]).ToArray()
        };
        var own = service.InspectOwnEntity(
            _normalSession, ownProducer, ObservationField.Production);
        var productionGrantedSession = new QuerySessionId(Guid.NewGuid());
        var ordinaryService = new WorldQueryService(
            repository,
            [
                new QuerySessionGrant(
                    productionGrantedSession,
                    _observer,
                    QuerySourceKind.Agent,
                    ObservationField.All,
                    ObservationField.Production,
                    false)
            ]);
        var normal = ordinaryService.ScanCircle(
            productionGrantedSession,
            new CircleObservationRequest(
                new WorldPosition(3, 0, 3), 1, ObservationField.Production));
        var debug = service.ScanCircle(
            _debugSession,
            new CircleObservationRequest(
                new WorldPosition(3, 0, 3), 1, ObservationField.Production));

        Check(own.Value?.Production is { QueueLimit: 5 } &&
            own.Value.Production.Items.Count == 0,
            "己方空生产队列应显式返回容量和空 Items");
        Check(normal.Value!.Single(item => item.EntityId == enemyProducer).Production is null,
            "普通会话不得读取当前可见敌方生产队列");
        Check(debug.Value!.Single(item => item.EntityId == enemyProducer).Production == enemyProduction,
            "全知调试会话应能读取敌方生产队列用于诊断");
    }

    /// <summary>验证己方活动订单准确、空闲显式为空，误授权也不能泄漏敌方订单。</summary>
    private void OrderInformationIsOwnOnlyAndIdleIsExplicit()
    {
        var service = NewService(out var repository);
        var idleUnit = new BattlefieldEntityId(BattlefieldEntityKind.Unit, Guid.NewGuid());
        var resource = new BattlefieldEntityId(BattlefieldEntityKind.ResourceNode, Guid.NewGuid());
        var ownOrder = new OrderObservation(
            new UnitOrderId(Guid.NewGuid()),
            OrderObservationKind.Gather,
            OrderObservationState.InProgress,
            new OrderTargetObservation(resource, null, "resource_a"));
        var enemyOrder = new OrderObservation(
            new UnitOrderId(Guid.NewGuid()),
            OrderObservationKind.Attack,
            OrderObservationState.InProgress,
            null);
        repository.Snapshot = repository.Snapshot with
        {
            Entities = repository.Snapshot.Entities
                .Select(entity => entity.EntityId == _ownedUnit ?
                    entity with { Order = ownOrder } :
                    entity.EntityId == _visibleEnemy ?
                        entity with { Order = enemyOrder } : entity)
                .Append(Entity(
                    idleUnit,
                    _observer,
                    new WorldPosition(2, 0, 1),
                    "worker",
                    5,
                    5,
                    new HashSet<PlayerId>()))
                .ToArray()
        };
        var own = service.InspectOwnEntity(
            _normalSession, _ownedUnit, ObservationField.Order);
        var idle = service.InspectOwnEntity(
            _normalSession, idleUnit, ObservationField.Order);
        var orderGrantedSession = new QuerySessionId(Guid.NewGuid());
        var ordinaryService = new WorldQueryService(
            repository,
            [
                new QuerySessionGrant(
                    orderGrantedSession,
                    _observer,
                    QuerySourceKind.RuleAI,
                    ObservationField.All,
                    ObservationField.Order,
                    false)
            ]);
        var enemy = ordinaryService.ScanCircle(
            orderGrantedSession,
            new CircleObservationRequest(
                new WorldPosition(4, 0, 4), 1, ObservationField.Order));
        var debug = service.ScanCircle(
            _debugSession,
            new CircleObservationRequest(
                new WorldPosition(4, 0, 4), 1, ObservationField.Order));

        Check(own.Value?.Order == ownOrder,
            "己方活动 Gather 订单及目标意图应准确返回");
        Check(idle.Status == QueryStatus.Accepted && idle.Value?.Order is null,
            "己方空闲单位应成功返回且 Order 显式为空");
        Check(enemy.Value!.Single(item => item.EntityId == _visibleEnemy).Order is null,
            "普通会话即使误授 Order 字段也不得读取敌方活动订单");
        Check(debug.Value!.Single(item => item.EntityId == _visibleEnemy).Order == enemyOrder,
            "全知调试会话应能读取敌方订单用于诊断");
    }

    /// <summary>验证随机会话不能触发世界读取或选择其他观察者。</summary>
    private void InvalidSessionDoesNotCaptureWorld()
    {
        var service = NewService(out var repository);

        var result = service.GetOwnForces(
            new QuerySessionId(Guid.NewGuid()),
            ObservationField.All);

        Check(result.ErrorCode == QueryErrorCode.InvalidSession, "未知会话应被拒绝");
        Check(repository.CaptureCalls == 0, "未知会话不应到达权威世界仓库");
    }

    /// <summary>验证非有限坐标和非正半径在读取世界前被拒绝。</summary>
    private void InvalidAreaIsRejected()
    {
        var service = NewService(out var repository);

        var result = service.ScanCircle(
            _normalSession,
            new CircleObservationRequest(new WorldPosition(float.NaN, 0, 0), 0, ObservationField.All));

        Check(result.ErrorCode == QueryErrorCode.InvalidRequest, "非法范围应返回 InvalidRequest");
        Check(repository.CaptureCalls == 0, "非法范围不应读取世界");
    }

    /// <summary>验证只有曾被范围观察的敌方建筑在失去视野后成为 LastKnown。</summary>
    private void EnemyStructureBecomesLastKnownButMobileDoesNot()
    {
        var service = NewService(out var repository);
        RevealHiddenStructure(repository);
        var request = new CircleObservationRequest(
            new WorldPosition(6, 0, 6),
            5,
            ObservationField.All);
        service.ScanCircle(_normalSession, request);
        repository.Snapshot = repository.Snapshot with
        {
            Revision = 43,
            Entities = repository.Snapshot.Entities.Select(entity => entity with
            {
                VisibleToPlayers = new HashSet<PlayerId>()
            }).ToArray(),
            VisibilityRegions = []
        };

        var result = service.ScanCircle(_normalSession, request);

        var memory = result.Value!.Single(item => item.EntityId == _hiddenEnemy);
        Check(memory.State == ObservationState.LastKnown, "失去视野的敌方建筑应成为 LastKnown");
        Check(memory.ObservedRevision == 42 && result.ObservationRevision == 43,
            "残影应区分最后观察版本和本次查询版本");
        Check(result.Value!.All(item => item.EntityId != _visibleEnemy),
            "可移动敌军失去视野后不应保留残影");
    }

    /// <summary>验证重新获得最后位置视野且建筑不存在时自动清除残影。</summary>
    private void ReobservedEmptyPositionClearsLastKnown()
    {
        var service = NewService(out var repository);
        RevealHiddenStructure(repository);
        var request = new CircleObservationRequest(
            new WorldPosition(8, 0, 8),
            2,
            ObservationField.All);
        service.ScanCircle(_normalSession, request);
        repository.Snapshot = repository.Snapshot with
        {
            Revision = 43,
            Entities = repository.Snapshot.Entities
                .Where(entity => entity.EntityId != _hiddenEnemy)
                .ToArray(),
            VisibilityRegions =
            [
                new VisibilityRegionSnapshot(
                    _observer,
                    new WorldPosition(8, 0, 8),
                    3)
            ]
        };

        var result = service.ScanCircle(_normalSession, request);
        repository.Snapshot = repository.Snapshot with
        {
            Revision = 44,
            VisibilityRegions = []
        };
        var afterVisionLostAgain = service.ScanCircle(_normalSession, request);

        Check(result.Value is not null && result.Value.Count == 0,
            "重新侦察确认建筑不存在时应返回显式空集合");
        Check(afterVisionLostAgain.Value is not null && afterVisionLostAgain.Value.Count == 0,
            "已清除残影不能在再次失去视野后复活");
    }

    /// <summary>验证命令授权只接受当前可见敌方，并让隐藏、己方、未知与非法会话不可区分。</summary>
    private void CommandTargetAuthorizationRequiresCurrentEnemyVisibility()
    {
        var service = NewService(out var repository);
        var unknown = new BattlefieldEntityId(BattlefieldEntityKind.Unit, Guid.NewGuid());

        Check(service.IsCurrentlyVisibleEnemy(_normalSession, _visibleEnemy),
            "普通会话应获准攻击当前可见敌方");
        Check(!service.IsCurrentlyVisibleEnemy(_normalSession, _hiddenEnemy),
            "普通会话不得获准攻击隐藏敌方");
        Check(!service.IsCurrentlyVisibleEnemy(_normalSession, _ownedUnit),
            "己方实体不得通过敌方目标授权");
        Check(!service.IsCurrentlyVisibleEnemy(_normalSession, unknown),
            "未知 ID 不得通过目标授权");
        Check(!service.IsCurrentlyVisibleEnemy(new QuerySessionId(Guid.NewGuid()), _visibleEnemy),
            "未知会话不得触发目标授权");
        Check(service.IsCurrentlyVisibleEnemy(_debugSession, _hiddenEnemy),
            "全知调试会话可获准操作隐藏敌方以支持诊断");

        repository.Snapshot = repository.Snapshot with
        {
            Entities = repository.Snapshot.Entities.Select(entity =>
                entity.EntityId == _visibleEnemy ? entity with
                {
                    VisibleToPlayers = new HashSet<PlayerId>()
                } : entity).ToArray()
        };
        Check(!service.IsCurrentlyVisibleEnemy(_normalSession, _visibleEnemy),
            "敌方离开视野后，先前可见 ID 必须立即失去命令授权");
    }

    /// <summary>验证地图边界对普通和调试会话一致公开，并在地图未就绪时明确拒绝。</summary>
    private void BattlefieldBoundsArePublicAndSessionBound()
    {
        var service = NewService(out var repository);

        var normal = service.GetBattlefieldBounds(_normalSession);
        var debug = service.GetBattlefieldBounds(_debugSession);

        Check(normal.Status == QueryStatus.Accepted &&
            normal.Value == new BattlefieldBounds(0, 50, 0, 50),
            "普通会话应取得准确公开地图边界");
        Check(debug.Value == normal.Value,
            "地图边界不应因普通或全知调试权限而变化");

        var capturesBeforeInvalidSession = repository.CaptureCalls;
        var invalid = service.GetBattlefieldBounds(new QuerySessionId(Guid.NewGuid()));
        Check(invalid.Status == QueryStatus.Rejected &&
            invalid.ErrorCode == QueryErrorCode.InvalidSession,
            "未知会话不得读取公开地图边界");
        Check(repository.CaptureCalls == capturesBeforeInvalidSession,
            "未知边界查询会话不应到达权威世界仓库");

        repository.Snapshot = repository.Snapshot with { Bounds = null };
        var unavailable = service.GetBattlefieldBounds(_normalSession);
        Check(unavailable.Status == QueryStatus.Rejected &&
            unavailable.ErrorCode == QueryErrorCode.BattlefieldUnavailable,
            "地图未就绪时应明确返回 BattlefieldUnavailable");
    }

    private void RevealHiddenStructure(FakeWorldRepository repository)
    {
        repository.Snapshot = repository.Snapshot with
        {
            Entities = repository.Snapshot.Entities.Select(entity =>
                entity.EntityId == _hiddenEnemy ? entity with
                {
                    VisibleToPlayers = new HashSet<PlayerId> { _observer }
                } : entity).ToArray()
        };
    }

    private WorldQueryService NewService(out FakeWorldRepository repository)
    {
        repository = new FakeWorldRepository(new WorldObservationSnapshot(
            42,
            [
                Entity(_ownedUnit, _observer, new WorldPosition(1, 0, 1), "tank", 7, 10, new HashSet<PlayerId>()),
                Entity(_visibleEnemy, _enemy, new WorldPosition(4, 0, 4), "tank", 6, 10, new HashSet<PlayerId> { _observer }),
                Entity(_hiddenEnemy, _enemy, new WorldPosition(8, 0, 8), "command_center", 20, 20, new HashSet<PlayerId>())
            ],
            [new WorldEconomySnapshot(
                _observer,
                new ResourceAccountObservation(
                    [new ResourceAmount(ResourceKind.A, 12)],
                    5))],
            [],
            new BattlefieldBounds(0, 50, 0, 50)));
        return new WorldQueryService(
            repository,
            [
                new QuerySessionGrant(
                    _normalSession,
                    _observer,
                    QuerySourceKind.Agent,
                    ObservationField.All,
                    ObservationField.Position | ObservationField.Type | ObservationField.Relation,
                    false),
                new QuerySessionGrant(
                    _debugSession,
                    _observer,
                    QuerySourceKind.OmniscientDebug,
                    ObservationField.All,
                    ObservationField.All,
                    true)
            ]);
    }

    private static WorldEntitySnapshot Entity(
        BattlefieldEntityId id,
        PlayerId owner,
        WorldPosition position,
        string type,
        float hp,
        float hpMax,
        IReadOnlySet<PlayerId> visibleTo) =>
        new(
            id,
            owner,
            position,
            type,
            hp,
            hpMax,
            id.Kind == BattlefieldEntityKind.Structure,
            visibleTo);

    private void RunTest(string name, Action test)
    {
        _tests++;
        try
        {
            test();
            Console.WriteLine($"PASS {name}");
        }
        catch (Exception exception)
        {
            _failures++;
            Console.Error.WriteLine($"FAIL {name}: {exception.Message}");
        }
    }

    private static void Check(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }

    private sealed class FakeWorldRepository(WorldObservationSnapshot snapshot) :
        IWorldObservationRepository
    {
        public int CaptureCalls { get; private set; }

        public WorldObservationSnapshot Snapshot { get; set; } = snapshot;

        public WorldObservationSnapshot Capture()
        {
            CaptureCalls++;
            return Snapshot;
        }
    }
}
