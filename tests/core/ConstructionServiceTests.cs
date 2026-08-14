using AI_RTS.Application.Commands;
using AI_RTS.Application.Construction;
using AI_RTS.Application.Economy;
using AI_RTS.Application.Orders;
using AI_RTS.Application.Units;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Construction;
using AI_RTS.Domain.Economy;

namespace AI_RTS.Tests.Core;

/// <summary>验证施工任务、整数进度、退款与 Worker 终态清理均不依赖 Godot。</summary>
internal sealed class ConstructionServiceTests
{
    private int _failures;
    private int _tests;

    /// <summary>执行 ECO-004 施工核心回归集合。</summary>
    public int Run()
    {
        RunTest(nameof(MultipleWorkersCompleteOnce), MultipleWorkersCompleteOnce);
        RunTest(nameof(SuspendedWorkerResumesSameOrder), SuspendedWorkerResumesSameOrder);
        RunTest(nameof(ExitedWorkerLeavesNoAssignmentAfterOthersComplete),
            ExitedWorkerLeavesNoAssignmentAfterOthersComplete);
        RunTest(nameof(CancelRefundsButDestructionDoesNot), CancelRefundsButDestructionDoesNot);
        Console.WriteLine(
            $"Construction service tests completed: {_tests} test(s), {_failures} failure(s).");
        return _failures;
    }

    /// <summary>验证多个 Worker 线性叠加工作量，完成事件与现场完成调用均只发生一次。</summary>
    private void MultipleWorkersCompleteOnce()
    {
        var fixture = CreateFixture(requiredWork: 2);
        fixture.Service.Construct(
            Context(fixture), new ConstructStructureCommand(fixture.Workers, fixture.SiteId));
        var completedEvents = 0;
        fixture.Service.Completed += _ => completedEvents++;

        fixture.Service.Advance(1);
        fixture.Service.Advance(1);
        fixture.Service.Advance(2);

        Check(fixture.Service.Find(fixture.SiteId)?.State == ConstructionSiteState.Completed,
            "两个 Worker 应在一个 Tick 内完成 RequiredWork=2 的现场");
        Check(fixture.Sites.CompleteCalls == 1 && completedEvents == 1,
            "完成端口与完成事件都必须恰好发布一次");
        Check(fixture.WorkersPort.ClearCalls == 2,
            "完成现场后必须清理全部 Worker 的执行引用");
    }

    /// <summary>验证暂停后再次指定同一现场会恢复原订单，不创建重复施工身份。</summary>
    private void SuspendedWorkerResumesSameOrder()
    {
        var fixture = CreateFixture(requiredWork: 10);
        var first = fixture.Service.Construct(
            Context(fixture), new ConstructStructureCommand([fixture.Workers[0]], fixture.SiteId));
        var orderId = first.UnitResults.Single().OrderId!.Value;
        fixture.Service.RequestSuspend(fixture.Workers[0]);
        fixture.Orders.Transition(orderId, UnitOrderState.Suspended);

        var resumed = fixture.Service.Construct(
            Context(fixture), new ConstructStructureCommand([fixture.Workers[0]], fixture.SiteId));

        Check(resumed.UnitResults.Single().OrderId == orderId,
            "继续同一现场应复用暂停中的 Construct 订单 ID");
        Check(fixture.Orders.Find(orderId)?.State == UnitOrderState.InProgress,
            "恢复后的 Construct 订单应重新进入 InProgress");
    }

    /// <summary>验证旧 Worker 中途退出后立即清理，其他 Worker 完工也不会留下残余关联。</summary>
    private void ExitedWorkerLeavesNoAssignmentAfterOthersComplete()
    {
        var fixture = CreateFixture(requiredWork: 2);
        var started = fixture.Service.Construct(
            Context(fixture), new ConstructStructureCommand(fixture.Workers, fixture.SiteId));
        var exitedWorker = fixture.Workers[0];
        var exitedOrder = started.UnitResults.Single(item => item.UnitId == exitedWorker).OrderId!.Value;
        fixture.Orders.Transition(exitedOrder, UnitOrderState.Cancelled);

        fixture.Service.Advance(1);
        fixture.Service.Advance(2);

        Check(fixture.Service.Find(fixture.SiteId)?.State == ConstructionSiteState.Completed,
            "剩余 Worker 应能够独立完成建筑");
        Check(fixture.WorkersPort.ClearCalls == 2 && fixture.WorkersPort.ActiveCount == 0,
            "退出者与完工者的 Legacy 现场引用都应被删除");
        Check(!fixture.Service.RequestSuspend(exitedWorker).Accepted,
            "已经退出并清理的 Worker 不应再存在可暂停的残留分配");
    }

    /// <summary>验证主动取消全额退款且幂等，而被摧毁现场不产生退款。</summary>
    private void CancelRefundsButDestructionDoesNot()
    {
        var cancelled = CreateFixture(requiredWork: 10);
        var cancelContext = Context(cancelled);
        var first = cancelled.Service.Cancel(
            cancelContext, new CancelConstructionCommand(cancelled.SiteId));
        var replay = cancelled.Service.Cancel(
            cancelContext, new CancelConstructionCommand(cancelled.SiteId));

        Check(first.Status == ConstructionSiteCommandStatus.Applied &&
            replay.Status == ConstructionSiteCommandStatus.SiteNotActive,
            "主动取消只应成功一次");
        Check(cancelled.Accounts.Find(cancelled.OwnerId)!.GetBalance(ResourceKind.A) == 10,
            "主动取消应把已预扣的 4 点资源全额退回");

        var destroyed = CreateFixture(requiredWork: 10);
        destroyed.Service.Destroy(destroyed.SiteId, 2);
        Check(destroyed.Accounts.Find(destroyed.OwnerId)!.GetBalance(ResourceKind.A) == 6,
            "被摧毁的未完成建筑不得退款");
    }

    /// <summary>创建已经预扣建筑成本并注册现场的纯 C# 测试夹具。</summary>
    private static Fixture CreateFixture(int requiredWork)
    {
        var owner = new PlayerId(Guid.NewGuid());
        var match = new MatchId(Guid.NewGuid());
        var site = new UnitId(Guid.NewGuid());
        UnitId[] workers = [new(Guid.NewGuid()), new(Guid.NewGuid())];
        var repository = new FakeRepository(workers.Select(worker =>
            new UnitCommandSnapshot(worker, owner, true, CanConstruct: true)).ToArray());
        var orders = new InMemoryUnitOrderStore();
        var workerPort = new FakeWorkerPort();
        var sitePort = new FakeSitePort();
        var accounts = new InMemoryResourceAccountService();
        accounts.Open(new OpenResourceAccount(
            new ResourceTransactionId(Guid.NewGuid()),
            match,
            owner,
            [new ResourceAmount(ResourceKind.A, 6)],
            0));
        var service = new ConstructionService(
            repository, orders, workerPort, sitePort, accounts);
        var registered = service.Register(new RegisterConstructionSite(
            site,
            owner,
            new StructureDefinitionId("test_structure"),
            requiredWork,
            [new ResourceAmount(ResourceKind.A, 4)]));
        if (!registered)
        {
            throw new InvalidOperationException("测试施工现场注册失败。");
        }
        return new Fixture(
            owner, match, site, workers, orders, workerPort, sitePort, accounts, service);
    }

    /// <summary>创建使用测试夹具身份的命令上下文。</summary>
    private static CommandContext Context(Fixture fixture) => new(
        new CommandId(Guid.NewGuid()), fixture.MatchId, fixture.OwnerId, 1);

    /// <summary>执行单项测试并把未捕获异常转换为失败。</summary>
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

    /// <summary>记录断言失败并继续运行剩余回归项。</summary>
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
        UnitId SiteId,
        UnitId[] Workers,
        InMemoryUnitOrderStore Orders,
        FakeWorkerPort WorkersPort,
        FakeSitePort Sites,
        InMemoryResourceAccountService Accounts,
        ConstructionService Service);

    /// <summary>提供具备施工能力的纯内存 Worker 快照。</summary>
    private sealed class FakeRepository(params UnitCommandSnapshot[] units) :
        IUnitCommandUnitRepository
    {
        private readonly Dictionary<UnitId, UnitCommandSnapshot> _units =
            units.ToDictionary(item => item.UnitId);

        /// <inheritdoc />
        public UnitCommandSnapshot? Find(UnitId unitId) => _units.GetValueOrDefault(unitId);
    }

    /// <summary>记录 Worker 当前现场引用、暂停状态和终态清理次数。</summary>
    private sealed class FakeWorkerPort : IConstructionWorkerPort
    {
        private readonly Dictionary<UnitId, (UnitId SiteId, bool Contributing)> _active = new();

        /// <summary>当前仍持有现场引用的 Worker 数量。</summary>
        public int ActiveCount => _active.Count;

        /// <summary>累计执行终态清理的次数。</summary>
        public int ClearCalls { get; private set; }

        /// <inheritdoc />
        public ConstructionWorkerPortResult RequestConstruct(UnitId workerId, UnitId siteId)
        {
            _active[workerId] = (siteId, true);
            return ConstructionWorkerPortResult.Success();
        }

        /// <inheritdoc />
        public ConstructionWorkerPortResult RequestSuspend(UnitId workerId)
        {
            if (!_active.TryGetValue(workerId, out var state))
            {
                return ConstructionWorkerPortResult.Failure(
                    ConstructionWorkerPortError.EntityUnavailable);
            }
            _active[workerId] = (state.SiteId, false);
            return ConstructionWorkerPortResult.Success();
        }

        /// <inheritdoc />
        public bool IsContributing(UnitId workerId, UnitId siteId) =>
            _active.TryGetValue(workerId, out var state) &&
            state.SiteId == siteId && state.Contributing;

        /// <inheritdoc />
        public void Clear(UnitId workerId)
        {
            if (_active.Remove(workerId))
            {
                ClearCalls++;
            }
        }
    }

    /// <summary>记录施工现场进度、完成与取消调用。</summary>
    private sealed class FakeSitePort : IConstructionSitePort
    {
        /// <summary>累计完成调用次数。</summary>
        public int CompleteCalls { get; private set; }

        /// <inheritdoc />
        public bool ApplyProgress(UnitId siteId, int completedWork, int requiredWork) => true;

        /// <inheritdoc />
        public bool Complete(UnitId siteId)
        {
            CompleteCalls++;
            return true;
        }

        /// <inheritdoc />
        public bool Cancel(UnitId siteId) => true;
    }
}
