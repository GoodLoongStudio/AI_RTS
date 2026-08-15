using AI_RTS.Application.Queries;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Economy;
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
        RunTest(nameof(InvalidSessionDoesNotCaptureWorld), InvalidSessionDoesNotCaptureWorld);
        RunTest(nameof(InvalidAreaIsRejected), InvalidAreaIsRejected);

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
                    [new ResourceAmount(ResourceKind.A, 12), new ResourceAmount(ResourceKind.B, 3)],
                    5))]));
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
        new(id, owner, position, type, hp, hpMax, visibleTo);

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

        public WorldObservationSnapshot Capture()
        {
            CaptureCalls++;
            return snapshot;
        }
    }
}
