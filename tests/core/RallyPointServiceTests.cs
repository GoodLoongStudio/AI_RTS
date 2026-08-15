using AI_RTS.Application.Commands;
using AI_RTS.Application.Rally;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Rally;

namespace AI_RTS.Tests.Core;

/// <summary>验证集结点权限、强类型目标、幂等更新和失效回归默认出口。</summary>
internal sealed class RallyPointServiceTests
{
    private int _failures;
    private int _tests;

    /// <summary>执行 ECO-006 纯 C# 回归集合。</summary>
    public int Run()
    {
        RunTest(nameof(PositionSupportsPartialSuccessAndIndependentState),
            PositionSupportsPartialSuccessAndIndependentState);
        RunTest(nameof(TargetRulesRejectEnemyInvisibleAndSelf),
            TargetRulesRejectEnemyInvisibleAndSelf);
        RunTest(nameof(SameTargetIsIdempotentAndReplacementVersions),
            SameTargetIsIdempotentAndReplacementVersions);
        RunTest(nameof(TargetLossReturnsAllReferencesToDefaultExit),
            TargetLossReturnsAllReferencesToDefaultExit);
        RunTest(nameof(ClearAndProducerLossPublishStableReasons),
            ClearAndProducerLossPublishStableReasons);
        Console.WriteLine(
            $"Rally point tests completed: {_tests} test(s), {_failures} failure(s).");
        return _failures;
    }

    /// <summary>验证多建筑逐项回执以及每座生产者彼此独立的目标。</summary>
    private void PositionSupportsPartialSuccessAndIndependentState()
    {
        var fixture = CreateFixture();
        var otherOwner = new PlayerId(Guid.NewGuid());
        var foreign = new UnitId(Guid.NewGuid());
        fixture.Producers.Items[foreign] = new RallyProducerSnapshot(
            foreign, otherOwner, true, true, true);

        var result = fixture.Service.SetPosition(
            Context(fixture),
            new SetRallyPositionCommand(
                [fixture.FirstProducerId, fixture.SecondProducerId, foreign],
                new WorldPosition(9, 0, 12)));

        Check(result.Status == CommandStatus.PartiallyAccepted,
            "混合所有权的生产者应返回部分成功");
        Check(fixture.Service.Find(fixture.FirstProducerId)?.Target is RallyPositionTarget &&
            fixture.Service.Find(fixture.SecondProducerId)?.Target is RallyPositionTarget,
            "两座己方建筑应分别保存相同值的独立快照");
        Check(fixture.Service.Find(foreign) is null,
            "非己方建筑不得产生集结状态");
    }

    /// <summary>验证敌方、不可观察和 Producer 自身目标被稳定拒绝。</summary>
    private void TargetRulesRejectEnemyInvisibleAndSelf()
    {
        var fixture = CreateFixture();
        var enemy = new UnitId(Guid.NewGuid());
        fixture.Targets.Units[enemy] = new RallyUnitTargetSnapshot(
            enemy, new PlayerId(Guid.NewGuid()), true, true);
        var enemyResult = fixture.Service.SetTarget(
            Context(fixture),
            new SetRallyTargetCommand([fixture.FirstProducerId], new RallyUnitTarget(enemy)));
        Check(enemyResult.UnitResults[0].ErrorCode == CommandErrorCode.RallyTargetNotAllowed,
            "敌方实体不能作为首轮集结目标");

        var resource = new ResourceNodeId(Guid.NewGuid());
        fixture.Targets.Resources[resource] = new RallyResourceTargetSnapshot(resource, true, false);
        var hiddenResult = fixture.Service.SetTarget(
            Context(fixture),
            new SetRallyTargetCommand(
                [fixture.FirstProducerId], new RallyResourceTarget(resource)));
        Check(hiddenResult.UnitResults[0].ErrorCode == CommandErrorCode.RallyTargetNotObservable,
            "不可观察资源不得绕过观察边界");

        fixture.Targets.Units[fixture.FirstProducerId] = new RallyUnitTargetSnapshot(
            fixture.FirstProducerId, fixture.OwnerId, true, true);
        var selfResult = fixture.Service.SetTarget(
            Context(fixture),
            new SetRallyTargetCommand(
                [fixture.FirstProducerId], new RallyUnitTarget(fixture.FirstProducerId)));
        Check(selfResult.UnitResults[0].ErrorCode == CommandErrorCode.RallyTargetNotAllowed,
            "Producer 自身目标应要求使用显式 Clear");
    }

    /// <summary>验证相同目标不重复事件，替换目标只增加一次版本。</summary>
    private void SameTargetIsIdempotentAndReplacementVersions()
    {
        var fixture = CreateFixture();
        var changes = 0;
        fixture.Service.Changed += _ => changes++;
        var firstContext = Context(fixture);
        var target = new WorldPosition(5, 0, 6);

        fixture.Service.SetPosition(
            firstContext, new SetRallyPositionCommand([fixture.FirstProducerId], target));
        fixture.Service.SetPosition(
            firstContext, new SetRallyPositionCommand([fixture.FirstProducerId], target));
        fixture.Service.SetPosition(
            Context(fixture),
            new SetRallyPositionCommand([fixture.FirstProducerId], new WorldPosition(7, 0, 8)));

        Check(changes == 2, "幂等重复设置不应发布 Changed");
        Check(fixture.Service.Find(fixture.FirstProducerId)?.Version == 2,
            "真实替换应把版本从一增加到二");
    }

    /// <summary>验证目标失效会清除所有引用，null 明确表示回归默认门口。</summary>
    private void TargetLossReturnsAllReferencesToDefaultExit()
    {
        var fixture = CreateFixture();
        var friendly = new UnitId(Guid.NewGuid());
        fixture.Targets.Units[friendly] = new RallyUnitTargetSnapshot(
            friendly, fixture.OwnerId, true, true);
        var target = new RallyUnitTarget(friendly);
        fixture.Service.SetTarget(
            Context(fixture),
            new SetRallyTargetCommand(
                [fixture.FirstProducerId, fixture.SecondProducerId], target));
        var reasons = new List<RallyPointClearReason>();
        fixture.Service.Cleared += change => reasons.Add(change.Reason);

        fixture.Service.LoseTarget(target, 20);

        Check(fixture.Service.Find(fixture.FirstProducerId) is null &&
            fixture.Service.Find(fixture.SecondProducerId) is null,
            "目标失效后所有生产者都应回归默认出口");
        Check(reasons.Count == 2 && reasons.All(reason => reason == RallyPointClearReason.TargetLost),
            "每个被清理的生产者应发布一次 TargetLost");
    }

    /// <summary>验证显式清除幂等，生产者失效使用不同清除原因。</summary>
    private void ClearAndProducerLossPublishStableReasons()
    {
        var fixture = CreateFixture();
        fixture.Service.SetPosition(
            Context(fixture),
            new SetRallyPositionCommand(
                [fixture.FirstProducerId, fixture.SecondProducerId], new WorldPosition(3, 0, 4)));
        var reasons = new List<RallyPointClearReason>();
        fixture.Service.Cleared += change => reasons.Add(change.Reason);

        fixture.Service.Clear(
            Context(fixture), new ClearRallyPointCommand([fixture.FirstProducerId]));
        fixture.Service.Clear(
            Context(fixture), new ClearRallyPointCommand([fixture.FirstProducerId]));
        fixture.Service.LoseProducer(fixture.SecondProducerId, 30);

        Check(reasons.SequenceEqual(
            [RallyPointClearReason.Explicit, RallyPointClearReason.ProducerLost]),
            "重复 Clear 不发布事件，ProducerLost 使用独立原因");
    }

    /// <summary>建立两座己方生产建筑和可控目标仓库。</summary>
    private static Fixture CreateFixture()
    {
        var owner = new PlayerId(Guid.NewGuid());
        var match = new MatchId(Guid.NewGuid());
        var first = new UnitId(Guid.NewGuid());
        var second = new UnitId(Guid.NewGuid());
        var producers = new FakeProducers();
        producers.Items[first] = new RallyProducerSnapshot(first, owner, true, true, true);
        producers.Items[second] = new RallyProducerSnapshot(second, owner, true, true, true);
        var targets = new FakeTargets();
        var service = new RallyPointService(producers, targets, new FakePositions());
        return new Fixture(owner, match, first, second, producers, targets, service);
    }

    /// <summary>创建新的命令上下文。</summary>
    private static CommandContext Context(Fixture fixture) => new(
        new CommandId(Guid.NewGuid()), fixture.MatchId, fixture.OwnerId, 10);

    /// <summary>执行单项测试并把异常转换为失败。</summary>
    private void RunTest(string name, Action test)
    {
        _tests++;
        var before = _failures;
        try
        {
            test();
        }
        catch (Exception exception)
        {
            _failures++;
            Console.Error.WriteLine($"[FAIL] {name}: unexpected {exception}");
        }
        if (_failures == before)
        {
            Console.WriteLine($"[PASS] {name}");
        }
    }

    /// <summary>记录断言失败并继续运行其余回归。</summary>
    private void Check(bool condition, string message)
    {
        if (!condition)
        {
            _failures++;
            Console.Error.WriteLine($"[FAIL] {message}");
        }
    }

    private sealed record Fixture(
        PlayerId OwnerId,
        MatchId MatchId,
        UnitId FirstProducerId,
        UnitId SecondProducerId,
        FakeProducers Producers,
        FakeTargets Targets,
        RallyPointService Service);

    /// <summary>提供测试生产者能力快照。</summary>
    private sealed class FakeProducers : IRallyProducerRepository
    {
        /// <summary>按稳定身份保存生产者。</summary>
        public Dictionary<UnitId, RallyProducerSnapshot> Items { get; } = new();

        /// <inheritdoc />
        public RallyProducerSnapshot? Find(UnitId producerId) =>
            Items.GetValueOrDefault(producerId);
    }

    /// <summary>提供测试实体与资源目标快照。</summary>
    private sealed class FakeTargets : IRallyTargetRepository
    {
        /// <summary>单位和建筑目标。</summary>
        public Dictionary<UnitId, RallyUnitTargetSnapshot> Units { get; } = new();

        /// <summary>资源节点目标。</summary>
        public Dictionary<ResourceNodeId, RallyResourceTargetSnapshot> Resources { get; } = new();

        /// <inheritdoc />
        public RallyUnitTargetSnapshot? FindUnit(UnitId unitId, PlayerId observerId) =>
            Units.GetValueOrDefault(unitId);

        /// <inheritdoc />
        public RallyResourceTargetSnapshot? FindResource(
            ResourceNodeId resourceNodeId,
            PlayerId observerId) => Resources.GetValueOrDefault(resourceNodeId);
    }

    /// <summary>只接受当前测试地图正坐标范围。</summary>
    private sealed class FakePositions : IRallyPositionValidator
    {
        /// <inheritdoc />
        public bool IsInsideMap(WorldPosition position) =>
            position.X >= 0 && position.X <= 100 && position.Z >= 0 && position.Z <= 100;
    }
}
