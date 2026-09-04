using AI_RTS.Application.Construction;
using AI_RTS.Application.Economy;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Construction;
using AI_RTS.Domain.Economy;

namespace AI_RTS.Tests.Core;

/// <summary>验证建筑放置评估不依赖 Godot，并保持稳定问题与只读语义。</summary>
internal sealed class StructurePlacementServiceTests
{
    private int _failures;
    private int _tests;

    /// <summary>执行建筑放置核心回归集合。</summary>
    public int Run()
    {
        RunTest(nameof(ValidCandidateNormalizesYaw), ValidCandidateNormalizesYaw);
        RunTest(nameof(EvaluationReturnsAllIssuesInStableOrder),
            EvaluationReturnsAllIssuesInStableOrder);
        RunTest(nameof(UnknownDefinitionStopsDependentQueries),
            UnknownDefinitionStopsDependentQueries);
        RunTest(nameof(InvalidTransformStopsDependentQueries),
            InvalidTransformStopsDependentQueries);
        RunTest(nameof(PreviewDoesNotMutateResourceAccount), PreviewDoesNotMutateResourceAccount);
        RunTest(nameof(AdapterFailureBecomesValidationUnavailable),
            AdapterFailureBecomesValidationUnavailable);

        Console.WriteLine(
            $"Structure placement tests completed: {_tests} test(s), {_failures} failure(s).");
        return _failures;
    }

    /// <summary>验证合法候选被接受，并把负角度规范化到 [0, 2π)。</summary>
    private void ValidCandidateNormalizesYaw()
    {
        var fixture = CreateFixture();
        var result = fixture.Service.Evaluate(Query(fixture, -MathF.PI / 2.0f));

        Check(result.IsValid, "合法且余额充足的候选应被接受");
        Check(result.PrimaryIssue is null && result.Issues.Count == 0,
            "合法候选不应返回问题");
        Check(MathF.Abs(result.Candidate.YawRadians - MathF.PI * 1.5f) < 0.0001f,
            "负角度应规范化到 [0, 2π)");
        Check(result.ObservedAccountVersion == 1, "Preview 应返回观察到的账户版本");
    }

    /// <summary>验证空间与资源问题能够同时返回，并遵循固定优先级。</summary>
    private void EvaluationReturnsAllIssuesInStableOrder()
    {
        var fixture = CreateFixture(resourceA: 1);
        fixture.Authorization.Allowed = false;
        fixture.World.Issues =
        [
            StructurePlacementIssue.Occupied,
            StructurePlacementIssue.NotVisible,
            StructurePlacementIssue.OutOfBounds,
            StructurePlacementIssue.Occupied
        ];

        var result = fixture.Service.Evaluate(Query(fixture, 0.0f));

        Check(!result.IsValid, "存在问题时候选应无效");
        Check(result.Issues.SequenceEqual(new[]
        {
            StructurePlacementIssue.NotAuthorized,
            StructurePlacementIssue.NotVisible,
            StructurePlacementIssue.OutOfBounds,
            StructurePlacementIssue.Occupied,
            StructurePlacementIssue.InsufficientResources
        }), "问题应去重并按稳定优先级返回");
        Check(result.PrimaryIssue == StructurePlacementIssue.NotAuthorized,
            "PrimaryIssue 应等于最高优先级问题");
    }

    /// <summary>验证未知定义不会继续查询权限、世界或余额。</summary>
    private void UnknownDefinitionStopsDependentQueries()
    {
        var fixture = CreateFixture();
        fixture.Definitions.Definition = null;

        var result = fixture.Service.Evaluate(Query(fixture, 0.0f));

        Check(result.Issues.SequenceEqual(new[] { StructurePlacementIssue.UnknownDefinition }),
            "未知定义应返回唯一稳定问题");
        Check(fixture.Authorization.Calls == 0 && fixture.World.Calls == 0,
            "未知定义不应触发依赖定义的端口");
    }

    /// <summary>验证非有限坐标不会进入任何外部端口。</summary>
    private void InvalidTransformStopsDependentQueries()
    {
        var fixture = CreateFixture();
        var query = Query(fixture, float.NaN) with
        {
            Candidate = Query(fixture, 0.0f).Candidate with
            {
                Position = new WorldPosition(float.PositiveInfinity, 0.0f, 1.0f)
            }
        };

        var result = fixture.Service.Evaluate(query);

        Check(result.PrimaryIssue == StructurePlacementIssue.InvalidTransform,
            "非有限变换应返回 InvalidTransform");
        Check(fixture.Definitions.Calls == 0 && fixture.World.Calls == 0,
            "非法变换不应进入定义或世界端口");
    }

    /// <summary>验证反复 Preview 不扣款、不增加账户版本且不改变世界端口状态。</summary>
    private void PreviewDoesNotMutateResourceAccount()
    {
        var fixture = CreateFixture();
        var before = fixture.Accounts.Find(fixture.PlayerId)!;

        fixture.Service.Evaluate(Query(fixture, 0.0f));
        fixture.Service.Evaluate(Query(fixture, MathF.PI));
        var after = fixture.Accounts.Find(fixture.PlayerId)!;

        Check(after.Version == before.Version, "Preview 不得增加账户版本");
        Check(after.GetBalance(ResourceKind.A) == before.GetBalance(ResourceKind.A),
            "Preview 不得扣除资源");
        Check(fixture.World.Calls == 2, "每个不同候选均应执行一次只读世界评估");
    }

    /// <summary>验证适配器异常不会逃逸或被误判为合法。</summary>
    private void AdapterFailureBecomesValidationUnavailable()
    {
        var fixture = CreateFixture();
        fixture.World.Throw = true;

        var result = fixture.Service.Evaluate(Query(fixture, 0.0f));

        Check(!result.IsValid, "世界适配器失败时不得接受候选");
        Check(result.PrimaryIssue == StructurePlacementIssue.ValidationUnavailable,
            "适配器失败应映射为 ValidationUnavailable");
    }

    /// <summary>建立带默认合法定义和资源账户的测试夹具。</summary>
    private static Fixture CreateFixture(int resourceA = 10)
    {
        var player = new PlayerId(Guid.NewGuid());
        var match = new MatchId(Guid.NewGuid());
        var definitionId = new StructureDefinitionId("command_center");
        var definition = new StructurePlacementDefinition(
            definitionId,
            new CirclePlacementFootprint(2.0f),
            new PlacementEnvironmentId("terrain.surface"),
            [new ResourceAmount(ResourceKind.A, 4)]);
        var definitions = new FakeDefinitions(definition);
        var authorization = new FakeAuthorization();
        var world = new FakeWorld();
        var accounts = new InMemoryResourceAccountService();
        accounts.Open(new OpenResourceAccount(
            new ResourceTransactionId(Guid.NewGuid()),
            match,
            player,
            [new ResourceAmount(ResourceKind.A, resourceA)],
            1));
        var service = new StructurePlacementService(
            definitions, authorization, world, accounts);
        return new Fixture(
            player, match, definitionId, definitions, authorization, world, accounts, service);
    }

    /// <summary>建立使用测试夹具身份的评估请求。</summary>
    private static EvaluateStructurePlacementQuery Query(Fixture fixture, float yaw) => new(
        fixture.MatchId,
        fixture.PlayerId,
        new StructurePlacementCandidate(
            fixture.DefinitionId,
            new WorldPosition(10.0f, 0.0f, 10.0f),
            yaw));

    /// <summary>执行单项测试并把未捕获异常转换为失败。</summary>
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

    /// <summary>累计失败并输出可定位的中文断言信息。</summary>
    private void Check(bool condition, string message)
    {
        if (condition)
        {
            return;
        }
        _failures++;
        Console.Error.WriteLine($"[FAIL] {message}");
    }

    /// <summary>集中保存单项测试使用的端口和稳定身份。</summary>
    private sealed record Fixture(
        PlayerId PlayerId,
        MatchId MatchId,
        StructureDefinitionId DefinitionId,
        FakeDefinitions Definitions,
        FakeAuthorization Authorization,
        FakeWorld World,
        InMemoryResourceAccountService Accounts,
        StructurePlacementService Service);

    /// <summary>提供可观察调用次数的内存建筑定义仓库。</summary>
    private sealed class FakeDefinitions(StructurePlacementDefinition? definition) :
        IStructurePlacementDefinitionRepository
    {
        /// <summary>当前返回的定义。</summary>
        public StructurePlacementDefinition? Definition { get; set; } = definition;

        /// <summary>累计查询次数。</summary>
        public int Calls { get; private set; }

        /// <inheritdoc />
        public StructurePlacementDefinition? Find(StructureDefinitionId definitionId)
        {
            Calls++;
            return Definition?.DefinitionId == definitionId ? Definition : null;
        }
    }

    /// <summary>提供可切换授权结果的测试端口。</summary>
    private sealed class FakeAuthorization : IStructurePlacementAuthorizationPort
    {
        /// <summary>后续查询是否允许。</summary>
        public bool Allowed { get; set; } = true;

        /// <summary>累计查询次数。</summary>
        public int Calls { get; private set; }

        /// <inheritdoc />
        public bool CanPlace(
            MatchId matchId,
            PlayerId playerId,
            StructureDefinitionId definitionId)
        {
            Calls++;
            return Allowed;
        }
    }

    /// <summary>返回注入问题或异常的测试世界端口。</summary>
    private sealed class FakeWorld : IStructurePlacementWorldPort
    {
        /// <summary>后续评估返回的问题。</summary>
        public IReadOnlyList<StructurePlacementIssue> Issues { get; set; } = [];

        /// <summary>是否在评估时模拟引擎适配失败。</summary>
        public bool Throw { get; set; }

        /// <summary>累计评估次数。</summary>
        public int Calls { get; private set; }

        /// <inheritdoc />
        public IReadOnlyList<StructurePlacementIssue> Evaluate(
            MatchId matchId,
            PlayerId playerId,
            StructurePlacementCandidate candidate,
            StructurePlacementDefinition definition)
        {
            Calls++;
            if (Throw)
            {
                throw new InvalidOperationException("simulated world adapter failure");
            }
            return Issues;
        }
    }
}
