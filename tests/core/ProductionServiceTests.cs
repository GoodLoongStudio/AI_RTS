using AI_RTS.Application.Commands;
using AI_RTS.Application.Economy;
using AI_RTS.Application.Production;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Construction;
using AI_RTS.Domain.Economy;
using AI_RTS.Domain.Production;

namespace AI_RTS.Tests.Core;

/// <summary>验证稳定生产队列、整数推进、部署阻塞和退款规则。</summary>
internal sealed class ProductionServiceTests
{
    private int _failures;
    private int _tests;

    /// <summary>执行 ECO-005 纯 C# 回归集合。</summary>
    public int Run()
    {
        RunTest(nameof(EnqueueValidatesCapabilityResourcesAndCapacity),
            EnqueueValidatesCapabilityResourcesAndCapacity);
        RunTest(nameof(OnlyFrontAdvancesAndDuplicateTickIsIgnored),
            OnlyFrontAdvancesAndDuplicateTickIsIgnored);
        RunTest(nameof(BlockedDeploymentStopsQueueUntilSuccessful),
            BlockedDeploymentStopsQueueUntilSuccessful);
        RunTest(nameof(CancelRefundsOnceAndPromotesNextItem),
            CancelRefundsOnceAndPromotesNextItem);
        RunTest(nameof(ProducerLossTerminatesAllWithoutRefund),
            ProducerLossTerminatesAllWithoutRefund);
        RunTest(nameof(FreeDefinitionSkipsEmptyPaymentAndRefund),
            FreeDefinitionSkipsEmptyPaymentAndRefund);
        Console.WriteLine(
            $"Production service tests completed: {_tests} test(s), {_failures} failure(s).");
        return _failures;
    }

    /// <summary>验证生产资格、余额和统一容量均由 Application 强制执行。</summary>
    private void EnqueueValidatesCapabilityResourcesAndCapacity()
    {
        var fixture = CreateFixture(queueCapacity: 2, balance: 4);
        var first = fixture.Service.Enqueue(Context(fixture), Command(fixture));
        var second = fixture.Service.Enqueue(Context(fixture), Command(fixture));
        var full = fixture.Service.Enqueue(Context(fixture), Command(fixture));

        Check(first.Status == ProductionCommandStatus.Accepted && first.Item is not null,
            "合法产品应返回稳定 ProductionItemId");
        Check(second.Status == ProductionCommandStatus.Accepted,
            "第二项应在统一容量内入队");
        Check(full.Status == ProductionCommandStatus.QueueFull,
            "达到容量后不得继续扣款或入队");
        Check(fixture.Accounts.Find(fixture.OwnerId)!.GetBalance(ResourceKind.A) == 0,
            "两项生产应各原子扣除 2 点资源");

        fixture.Definitions.Definition = fixture.Definitions.Definition! with
        {
            AllowedProducerDefinitions = new HashSet<StructureDefinitionId>
            {
                new("aircraft_factory")
            }
        };
        var disallowedFixture = CreateFixture();
        disallowedFixture.Definitions.Definition = fixture.Definitions.Definition;
        var disallowed = disallowedFixture.Service.Enqueue(
            Context(disallowedFixture), Command(disallowedFixture));
        Check(disallowed.Status == ProductionCommandStatus.ProductNotAllowed,
            "不兼容建筑不得仅依赖 UI 自律生产目标单位");
    }

    /// <summary>验证只有队首推进，同一模拟 Tick 重入不会重复增加工作量。</summary>
    private void OnlyFrontAdvancesAndDuplicateTickIsIgnored()
    {
        var fixture = CreateFixture(requiredWork: 3);
        var first = fixture.Service.Enqueue(Context(fixture), Command(fixture)).Item!;
        var second = fixture.Service.Enqueue(Context(fixture), Command(fixture)).Item!;

        fixture.Service.Advance(1);
        fixture.Service.Advance(1);

        Check(fixture.Service.Find(first.ItemId)!.CompletedWork == 1,
            "同一 Tick 只能推进一次队首工作量");
        Check(fixture.Service.Find(second.ItemId)!.CompletedWork == 0 &&
            fixture.Service.Find(second.ItemId)!.State == ProductionItemState.Queued,
            "非队首项目不得消耗工作量");
    }

    /// <summary>验证出口受阻时保持 AwaitingDeployment 并阻塞后续项目。</summary>
    private void BlockedDeploymentStopsQueueUntilSuccessful()
    {
        var fixture = CreateFixture(requiredWork: 1);
        fixture.Deployment.Status = ProductionDeploymentStatus.Blocked;
        var first = fixture.Service.Enqueue(Context(fixture), Command(fixture)).Item!;
        var second = fixture.Service.Enqueue(Context(fixture), Command(fixture)).Item!;
        var awaitingEvents = 0;
        var completedEvents = 0;
        fixture.Service.AwaitingDeployment += _ => awaitingEvents++;
        fixture.Service.Completed += _ => completedEvents++;

        fixture.Service.Advance(1);
        fixture.Service.Advance(2);

        Check(fixture.Service.Find(first.ItemId)!.State == ProductionItemState.AwaitingDeployment,
            "受阻项目应保持 AwaitingDeployment");
        Check(fixture.Service.Find(second.ItemId)!.State == ProductionItemState.Queued,
            "等待部署项目必须阻塞后续队列");
        Check(awaitingEvents == 1 && completedEvents == 0,
            "等待部署事件只应在首次进入状态时发布");

        fixture.Deployment.Status = ProductionDeploymentStatus.Deployed;
        fixture.Service.Advance(3);
        fixture.Service.Advance(3);

        Check(fixture.Service.Find(first.ItemId)!.State == ProductionItemState.Completed,
            "解除阻挡后项目应部署完成");
        Check(fixture.Service.Find(second.ItemId)!.State == ProductionItemState.Producing,
            "下一项应在完成后取得生产线但不在同 Tick 偷跑进度");
        Check(fixture.Deployment.SuccessfulDeployments == 1 && completedEvents == 1,
            "重复 Tick 不得重复生成或发布完成事件");
    }

    /// <summary>验证取消任意未完成项目全额退款，取消队首后下一项立即取得生产线。</summary>
    private void CancelRefundsOnceAndPromotesNextItem()
    {
        var fixture = CreateFixture();
        var first = fixture.Service.Enqueue(Context(fixture), Command(fixture)).Item!;
        var second = fixture.Service.Enqueue(Context(fixture), Command(fixture)).Item!;
        var cancelContext = Context(fixture);

        var cancelled = fixture.Service.Cancel(
            cancelContext, new CancelProductionItemCommand(first.ItemId));
        var replay = fixture.Service.Cancel(
            cancelContext, new CancelProductionItemCommand(first.ItemId));

        Check(cancelled.Status == ProductionCommandStatus.Accepted &&
            replay.Status == ProductionCommandStatus.ItemNotActive,
            "同一生产项目只能成功取消一次");
        Check(fixture.Accounts.Find(fixture.OwnerId)!.GetBalance(ResourceKind.A) == 18,
            "两项扣款后取消一项应只退回一份完整成本");
        Check(fixture.Service.Find(second.ItemId)!.State == ProductionItemState.Producing,
            "取消队首后下一项应立即成为 Producing");
    }

    /// <summary>验证生产建筑失效会终止全部项目且不产生退款。</summary>
    private void ProducerLossTerminatesAllWithoutRefund()
    {
        var fixture = CreateFixture();
        var first = fixture.Service.Enqueue(Context(fixture), Command(fixture)).Item!;
        var second = fixture.Service.Enqueue(Context(fixture), Command(fixture)).Item!;
        var terminated = 0;
        fixture.Service.Terminated += _ => terminated++;

        fixture.Service.LoseProducer(fixture.ProducerId, 5);

        Check(fixture.Service.Find(first.ItemId)!.State == ProductionItemState.ProducerLost &&
            fixture.Service.Find(second.ItemId)!.State == ProductionItemState.ProducerLost,
            "建筑失效后全部未完成项目应进入 ProducerLost");
        Check(fixture.Accounts.Find(fixture.OwnerId)!.GetBalance(ResourceKind.A) == 16,
            "ProducerLost 不得退还已支付生产成本");
        Check(fixture.Service.GetQueue(fixture.ProducerId).Count == 0 && terminated == 2,
            "建筑失效后活动队列应清空并逐项发布终止事件");
    }

    /// <summary>验证显式空成本可以生产和取消，且不会提交非法空交易。</summary>
    private void FreeDefinitionSkipsEmptyPaymentAndRefund()
    {
        var fixture = CreateFixture(balance: 0);
        fixture.Definitions.Definition = fixture.Definitions.Definition! with
        {
            Cost = Array.Empty<ResourceAmount>()
        };

        var queued = fixture.Service.Enqueue(Context(fixture), Command(fixture));
        var cancelled = fixture.Service.Cancel(
            Context(fixture),
            new CancelProductionItemCommand(queued.Item!.ItemId));

        Check(queued.Status == ProductionCommandStatus.Accepted,
            "显式空成本生产定义应允许入队");
        Check(cancelled.Status == ProductionCommandStatus.Accepted,
            "空成本项目应允许取消且无需退款交易");
        Check(fixture.Accounts.Find(fixture.OwnerId)!.GetBalance(ResourceKind.A) == 0,
            "免费项目不得改变资源余额");
    }

    /// <summary>建立拥有合法生产定义、建筑和资源账户的测试夹具。</summary>
    private static Fixture CreateFixture(
        int requiredWork = 2,
        int queueCapacity = 5,
        int balance = 20)
    {
        var owner = new PlayerId(Guid.NewGuid());
        var match = new MatchId(Guid.NewGuid());
        var producerId = new UnitId(Guid.NewGuid());
        var producerDefinition = new StructureDefinitionId("vehicle_factory");
        var productDefinition = new ProductionDefinitionId("tank");
        var definition = new ProductionDefinition(
            productDefinition,
            requiredWork,
            [new ResourceAmount(ResourceKind.A, 2)],
            new HashSet<StructureDefinitionId> { producerDefinition });
        var definitions = new FakeDefinitions(definition);
        var producers = new FakeProducers(new ProductionProducerSnapshot(
            producerId, owner, producerDefinition, true, true, queueCapacity));
        var deployment = new FakeDeployment();
        var accounts = new InMemoryResourceAccountService();
        accounts.Open(new OpenResourceAccount(
            new ResourceTransactionId(Guid.NewGuid()),
            match,
            owner,
            [new ResourceAmount(ResourceKind.A, balance)],
            0));
        var service = new ProductionService(definitions, producers, deployment, accounts);
        return new Fixture(
            owner,
            match,
            producerId,
            productDefinition,
            definitions,
            deployment,
            accounts,
            service);
    }

    /// <summary>创建当前夹具的入队命令。</summary>
    private static EnqueueProductionCommand Command(Fixture fixture) =>
        new(fixture.ProducerId, fixture.ProductDefinitionId);

    /// <summary>创建当前夹具的命令上下文。</summary>
    private static CommandContext Context(Fixture fixture) => new(
        new CommandId(Guid.NewGuid()), fixture.MatchId, fixture.OwnerId, 1);

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
        UnitId ProducerId,
        ProductionDefinitionId ProductDefinitionId,
        FakeDefinitions Definitions,
        FakeDeployment Deployment,
        InMemoryResourceAccountService Accounts,
        ProductionService Service);

    /// <summary>提供可替换的纯内存产品定义。</summary>
    private sealed class FakeDefinitions(ProductionDefinition definition) :
        IProductionDefinitionRepository
    {
        /// <summary>当前测试使用的产品定义。</summary>
        public ProductionDefinition? Definition { get; set; } = definition;

        /// <inheritdoc />
        public ProductionDefinition? Find(ProductionDefinitionId definitionId) =>
            Definition?.DefinitionId == definitionId ? Definition : null;
    }

    /// <summary>提供纯内存生产建筑快照。</summary>
    private sealed class FakeProducers(params ProductionProducerSnapshot[] producers) :
        IProductionProducerRepository
    {
        private readonly Dictionary<UnitId, ProductionProducerSnapshot> _producers =
            producers.ToDictionary(item => item.ProducerId);

        /// <inheritdoc />
        public ProductionProducerSnapshot? Find(UnitId producerId) =>
            _producers.GetValueOrDefault(producerId);
    }

    /// <summary>允许测试控制部署受阻或成功，并统计实际生成次数。</summary>
    private sealed class FakeDeployment : IProductionDeploymentPort
    {
        /// <summary>后续部署请求应返回的状态。</summary>
        public ProductionDeploymentStatus Status { get; set; } =
            ProductionDeploymentStatus.Deployed;

        /// <summary>成功部署的累计次数。</summary>
        public int SuccessfulDeployments { get; private set; }

        /// <inheritdoc />
        public ProductionDeploymentResult TryDeploy(ProductionItemSnapshot item)
        {
            if (Status != ProductionDeploymentStatus.Deployed)
            {
                return new ProductionDeploymentResult(Status);
            }
            SuccessfulDeployments++;
            return new ProductionDeploymentResult(
                Status, new UnitId(Guid.NewGuid()));
        }
    }
}
