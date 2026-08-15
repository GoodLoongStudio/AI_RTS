using AI_RTS.Application.Commands;
using AI_RTS.Application.Commands.Units;
using AI_RTS.Application.Combat;
using AI_RTS.Application.Economy;
using AI_RTS.Application.Orders;
using AI_RTS.Application.Units;
using AI_RTS.Domain.Combat;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Economy;

namespace AI_RTS.Tests.Core;

/// <summary>提供不启动 Godot、不依赖第三方测试框架的核心命令测试入口。</summary>
internal static class Program
{
    /// <summary>执行全部纯 C# 测试，并通过进程退出码报告结果。</summary>
    private static int Main()
    {
        var failures = new UnitCommandServiceTests().Run();
        failures += new StructurePlacementServiceTests().Run();
        failures += new ConstructionServiceTests().Run();
        failures += new ProductionServiceTests().Run();
        failures += new RallyPointServiceTests().Run();
        failures += new BalanceConfigLoaderTests().Run();
        failures += new InputBindingServiceTests().Run();
        failures += new ControlGroupServiceTests().Run();
        failures += new WorldQueryServiceTests().Run();
        return failures == 0 ? 0 : 1;
    }
}

/// <summary>验证 Application 命令规则只依赖抽象端口和纯 C# 状态。</summary>
internal sealed class UnitCommandServiceTests
{
    private int _failures;
    private int _tests;

    /// <summary>执行当前核心命令回归集合。</summary>
    public int Run()
    {
        RunTest(nameof(PartialAcceptanceReturnsPerUnitResults), PartialAcceptanceReturnsPerUnitResults);
        RunTest(nameof(DuplicateUnitsAreExecutedOnce), DuplicateUnitsAreExecutedOnce);
        RunTest(nameof(InvalidDestinationDoesNotReachMovementPort), InvalidDestinationDoesNotReachMovementPort);
        RunTest(nameof(FailedReplacementPreservesActiveOrder), FailedReplacementPreservesActiveOrder);
        RunTest(nameof(HaltSuspendsMovementOrder), HaltSuspendsMovementOrder);
        RunTest(nameof(UnifiedStopAppliesOrderSpecificSemantics), UnifiedStopAppliesOrderSpecificSemantics);
        RunTest(nameof(GatherReturnsPerWorkerResults), GatherReturnsPerWorkerResults);
        RunTest(nameof(StopSuspendsGatherWithoutUsingGenericStop), StopSuspendsGatherWithoutUsingGenericStop);
        RunTest(nameof(CombatPoliciesAreIndependentAndOwnershipChecked), CombatPoliciesAreIndependentAndOwnershipChecked);
        RunTest(nameof(OrdinaryAttackRespectsHoldFire), OrdinaryAttackRespectsHoldFire);
        RunTest(nameof(ForceAttackOverridesHoldFire), ForceAttackOverridesHoldFire);
        RunTest(nameof(GroundForceAttackRequiresExplicitCapability), GroundForceAttackRequiresExplicitCapability);
        RunTest(nameof(AttackMoveKeepsMovingDuringHoldFire), AttackMoveKeepsMovingDuringHoldFire);
        RunTest(nameof(TacticalWithdrawFallsBackToOrdinaryMovement), TacticalWithdrawFallsBackToOrdinaryMovement);
        RunTest(nameof(EntityMovementKeepsDistinctOrderSemantics), EntityMovementKeepsDistinctOrderSemantics);
        RunTest(nameof(EntityMovementRejectsSelfAndMissingTargets), EntityMovementRejectsSelfAndMissingTargets);
        RunTest(nameof(StopSuspendsEntityMovementOrders), StopSuspendsEntityMovementOrders);
        RunTest(nameof(PortFailuresMapToStableErrors), PortFailuresMapToStableErrors);
        RunTest(nameof(OrderStorePublishesAuthoritativeStateChanges), OrderStorePublishesAuthoritativeStateChanges);
        RunTest(nameof(AcceptedOrdersPreserveOriginalTargets), AcceptedOrdersPreserveOriginalTargets);
        RunTest(nameof(AreaWarheadUsesImpactPointAndFootprints), AreaWarheadUsesImpactPointAndFootprints);
        RunTest(nameof(WarheadResultsAreStableUniqueAndRespectFriendlyFire), WarheadResultsAreStableUniqueAndRespectFriendlyFire);
        RunTest(nameof(ResourceTransactionAppliesMultipleKindsAtomically), ResourceTransactionAppliesMultipleKindsAtomically);
        RunTest(nameof(ResourceTransactionRejectsPartialPayment), ResourceTransactionRejectsPartialPayment);
        RunTest(nameof(ResourceTransactionReplayIsIdempotent), ResourceTransactionReplayIsIdempotent);
        RunTest(nameof(ResourceTransactionIdConflictIsRejected), ResourceTransactionIdConflictIsRejected);
        RunTest(nameof(ResourceTransactionRejectsInvalidAndOverflowingAmounts), ResourceTransactionRejectsInvalidAndOverflowingAmounts);
        RunTest(nameof(ResourceAccountSupportsAllIncomeReasons), ResourceAccountSupportsAllIncomeReasons);
        RunTest(nameof(ResourceAccountSnapshotCannotMutateStore), ResourceAccountSnapshotCannotMutateStore);

        Console.WriteLine($"AI_RTS.Core tests completed: {_tests} test(s), {_failures} failure(s).");
        return _failures == 0 ? 0 : 1;
    }

    /// <summary>验证同一批命令可以逐单位成功或失败，并产生稳定汇总状态。</summary>
    private void PartialAcceptanceReturnsPerUnitResults()
    {
        var owner = NewPlayerId();
        var movable = NewUnitId();
        var immovable = NewUnitId();
        var missing = NewUnitId();
        var repository = new FakeRepository(
            new UnitCommandSnapshot(movable, owner, true),
            new UnitCommandSnapshot(immovable, owner, false));
        var orders = new InMemoryUnitOrderStore();
        var service = NewService(repository, new FakeMovementPort(), new FakeAttackPort(), orders);

        var result = service.ForceMove(
            Context(owner),
            new ForceMoveUnitsCommand(
                [movable, immovable, missing],
                new WorldPosition(10, 0, 10)));

        Check(result.Status == CommandStatus.PartiallyAccepted, "批量结果应为 PartiallyAccepted");
        Check(result.UnitResults.Count == 3, "每个稳定单位 ID 应有一个结果");
        Check(ResultFor(result, movable).Accepted, "可移动单位应接受命令");
        Check(ResultFor(result, immovable).ErrorCode == CommandErrorCode.UnitCannotMove,
            "不可移动单位应独立返回 UnitCannotMove");
        Check(ResultFor(result, missing).ErrorCode == CommandErrorCode.UnitNotFound,
            "失效单位应独立返回 UnitNotFound");
        Check(orders.FindActive(movable)?.State == UnitOrderState.InProgress,
            "已接受单位应拥有 InProgress 订单");
    }

    /// <summary>验证批量命令中的重复单位不会导致端口重复执行。</summary>
    private void DuplicateUnitsAreExecutedOnce()
    {
        var owner = NewPlayerId();
        var unit = NewUnitId();
        var movement = new FakeMovementPort();
        var service = NewService(
            new FakeRepository(new UnitCommandSnapshot(unit, owner, true)),
            movement);

        var result = service.Move(
            Context(owner),
            new MoveUnitsCommand([unit, unit], new WorldPosition(1, 0, 1)));

        Check(result.Status == CommandStatus.Accepted, "去重后的移动应被接受");
        Check(result.UnitResults.Count == 1, "重复单位只应产生一个结果");
        Check(movement.MoveRequests == 1, "重复单位只应调用一次移动端口");
    }

    /// <summary>验证非有限坐标在 Application 层被拒绝，不泄漏给导航实现。</summary>
    private void InvalidDestinationDoesNotReachMovementPort()
    {
        var owner = NewPlayerId();
        var unit = NewUnitId();
        var movement = new FakeMovementPort();
        var service = NewService(
            new FakeRepository(new UnitCommandSnapshot(unit, owner, true)),
            movement);

        var result = service.Move(
            Context(owner),
            new MoveUnitsCommand([unit], new WorldPosition(float.NaN, 0, 1)));

        Check(result.Status == CommandStatus.Rejected, "非有限坐标应被拒绝");
        Check(ResultFor(result, unit).ErrorCode == CommandErrorCode.InvalidDestination,
            "非有限坐标应返回 InvalidDestination");
        Check(movement.MoveRequests == 0, "无效坐标不应到达移动端口");
    }

    /// <summary>验证新端口请求失败时不会取消仍可执行的旧订单。</summary>
    private void FailedReplacementPreservesActiveOrder()
    {
        var owner = NewPlayerId();
        var unit = NewUnitId();
        var movement = new FakeMovementPort();
        var orders = new InMemoryUnitOrderStore();
        var service = NewService(
            new FakeRepository(new UnitCommandSnapshot(unit, owner, true)),
            movement,
            orders: orders);

        service.Move(Context(owner), new MoveUnitsCommand([unit], new WorldPosition(1, 0, 1)));
        var original = orders.FindActive(unit);
        movement.MovementError = MovementPortError.NavigationUnavailable;
        var replacement = service.ForceMove(
            Context(owner),
            new ForceMoveUnitsCommand([unit], new WorldPosition(2, 0, 2)));

        Check(replacement.Status == CommandStatus.Rejected, "导航拒绝应拒绝替换命令");
        Check(orders.FindActive(unit)?.OrderId == original?.OrderId,
            "端口拒绝后应保留旧活动订单");
    }

    /// <summary>验证停止移动会暂停而非删除当前移动订单。</summary>
    private void HaltSuspendsMovementOrder()
    {
        var owner = NewPlayerId();
        var unit = NewUnitId();
        var orders = new InMemoryUnitOrderStore();
        var service = NewService(
            new FakeRepository(new UnitCommandSnapshot(unit, owner, true)),
            new FakeMovementPort(),
            orders: orders);

        service.ForceMove(
            Context(owner),
            new ForceMoveUnitsCommand([unit], new WorldPosition(1, 0, 1)));
        var original = orders.FindActive(unit)!;
        var result = service.HaltMovement(Context(owner), new HaltMovementCommand([unit]));

        Check(result.Status == CommandStatus.Accepted, "停止移动应被接受");
        Check(ResultFor(result, unit).OrderId == original.OrderId, "停止移动应保留原订单 ID");
        Check(orders.Find(original.OrderId)?.State == UnitOrderState.Suspended,
            "停止移动应把订单转换为 Suspended");
    }

    /// <summary>验证统一 Stop 暂停移动、取消普通/强制攻击，但不会修改持续战斗策略。</summary>
    private void UnifiedStopAppliesOrderSpecificSemantics()
    {
        var owner = NewPlayerId();
        var enemyOwner = NewPlayerId();
        var mover = NewUnitId();
        var forceAttacker = NewUnitId();
        var ordinaryAttacker = NewUnitId();
        var target = NewUnitId();
        var domains = new HashSet<CombatDomain> { CombatDomain.Terrain };
        var repository = new FakeRepository(
            new UnitCommandSnapshot(mover, owner, true),
            new UnitCommandSnapshot(forceAttacker, owner, true, true, CombatDomain.Terrain, domains),
            new UnitCommandSnapshot(ordinaryAttacker, owner, true, true, CombatDomain.Terrain, domains),
            new UnitCommandSnapshot(target, enemyOwner, true, true));
        var orders = new InMemoryUnitOrderStore();
        var policies = new InMemoryCombatPolicyStore();
        var stop = new FakeStopPort();
        var service = NewService(repository, orders: orders, policies: policies, stop: stop);

        service.Move(Context(owner), new MoveUnitsCommand([mover], new WorldPosition(1, 0, 1)));
        service.ForceAttack(
            Context(owner),
            new ForceAttackCommand([forceAttacker], new EntityAttackTarget(target)));
        service.Attack(
            Context(owner),
            new AttackCommand([ordinaryAttacker], new EntityAttackTarget(target)));
        policies.SetFirePolicy(forceAttacker, FirePolicy.HoldFire);
        var moverOrder = orders.FindActive(mover)!;
        var forceOrder = orders.FindActive(forceAttacker)!;
        var ordinaryOrder = orders.FindActive(ordinaryAttacker)!;

        var result = service.Stop(
            Context(owner),
            new StopUnitsCommand([mover, forceAttacker, ordinaryAttacker]));

        Check(result.Status == CommandStatus.Accepted, "统一 Stop 应逐单位接受合法批次");
        Check(stop.Requests == 3, "每个去重单位应只收到一次原子 Stop 请求");
        Check(orders.Find(moverOrder.OrderId)?.State == UnitOrderState.Suspended,
            "移动订单应进入 Suspended 并保留任务身份");
        Check(orders.Find(forceOrder.OrderId)?.State == UnitOrderState.Cancelled,
            "显式 ForceAttack 应被统一 Stop 取消");
        Check(orders.Find(ordinaryOrder.OrderId)?.State == UnitOrderState.Cancelled,
            "玩家下达的普通 Attack 应被 Stop 命令取消");
        Check(ResultFor(result, ordinaryAttacker).OrderId == ordinaryOrder.OrderId,
            "普通 Attack 被取消时应回传受影响的订单 ID");
        Check(policies.Get(forceAttacker).FirePolicy == FirePolicy.HoldFire,
            "统一 Stop 不应修改持续停火策略");
    }

    /// <summary>验证 Gather 只接受自有 Worker，并为每个接受者创建独立持续订单。</summary>
    private void GatherReturnsPerWorkerResults()
    {
        var owner = NewPlayerId();
        var worker = NewUnitId();
        var tank = NewUnitId();
        var resourceId = NewResourceNodeId();
        var orders = new InMemoryUnitOrderStore();
        var work = new FakeWorkerTaskPort();
        var service = NewService(
            new FakeRepository(
                new UnitCommandSnapshot(worker, owner, true, CanGather: true),
                new UnitCommandSnapshot(tank, owner, true)),
            orders: orders,
            workerTasks: work,
            resources: new FakeResourceRepository(
                new ResourceNodeSnapshot(resourceId, ResourceKind.A, true)));

        var result = service.GatherResources(
            Context(owner),
            new GatherResourcesCommand([worker, tank], resourceId));

        Check(result.Status == CommandStatus.PartiallyAccepted,
            "Worker 与非采集单位混选应返回 PartiallyAccepted");
        Check(ResultFor(result, worker).Accepted, "具备采集能力的 Worker 应接受 Gather");
        Check(ResultFor(result, tank).ErrorCode == CommandErrorCode.UnitCannotGather,
            "非采集单位应返回 UnitCannotGather");
        Check(orders.FindActive(worker)?.Kind == UnitOrderKind.Gather,
            "已接受 Worker 应获得 Gather 订单");
        Check(orders.FindActive(worker)?.Target is UnitOrderEntityTarget
            {
                EntityId.Kind: BattlefieldEntityKind.ResourceNode,
                EntityId.Value: var targetId,
                TypeId: "resource_a"
            } && targetId == resourceId.Value,
            "Gather 订单应保留下令时的资源稳定 ID 与类型，不依赖实时 Node");
        Check(work.GatherRequests == 1, "只有合法 Worker 应到达工作任务端口");
    }

    /// <summary>验证统一 Stop 通过工作端口暂停 Gather，且不调用通用 Stop 端口。</summary>
    private void StopSuspendsGatherWithoutUsingGenericStop()
    {
        var owner = NewPlayerId();
        var worker = NewUnitId();
        var resourceId = NewResourceNodeId();
        var orders = new InMemoryUnitOrderStore();
        var work = new FakeWorkerTaskPort();
        var stop = new FakeStopPort();
        var service = NewService(
            new FakeRepository(new UnitCommandSnapshot(worker, owner, true, CanGather: true)),
            orders: orders,
            stop: stop,
            workerTasks: work,
            resources: new FakeResourceRepository(
                new ResourceNodeSnapshot(resourceId, ResourceKind.B, true)));

        var gather = service.GatherResources(
            Context(owner),
            new GatherResourcesCommand([worker], resourceId));
        var orderId = ResultFor(gather, worker).OrderId!.Value;
        var stopped = service.Stop(Context(owner), new StopUnitsCommand([worker]));

        Check(stopped.Status == CommandStatus.Accepted, "Gather 期间统一 Stop 应被接受");
        Check(work.SuspendRequests == 1, "Gather Stop 应调用工作暂停端口一次");
        Check(stop.Requests == 0, "Gather Stop 不应误用通用移动/攻击停止端口");
        Check(orders.Find(orderId)?.State == UnitOrderState.Suspended,
            "Gather Stop 应保留订单并转为 Suspended");
    }

    /// <summary>验证姿态与开火策略独立保存，并逐单位检查所有权。</summary>
    private void CombatPoliciesAreIndependentAndOwnershipChecked()
    {
        var owner = NewPlayerId();
        var adversary = NewPlayerId();
        var owned = NewUnitId();
        var foreign = NewUnitId();
        var policies = new InMemoryCombatPolicyStore();
        var service = NewService(
            new FakeRepository(
                new UnitCommandSnapshot(owned, owner, true),
                new UnitCommandSnapshot(foreign, adversary, true)),
            policies: policies);

        var stance = service.SetEngagementStance(
            Context(owner),
            new SetEngagementStanceCommand([owned, foreign], EngagementStance.Guard));
        var fire = service.SetFirePolicy(
            Context(owner),
            new SetFirePolicyCommand([owned], FirePolicy.HoldFire));

        Check(stance.Status == CommandStatus.PartiallyAccepted, "跨所有权批量策略应部分接受");
        Check(ResultFor(stance, foreign).ErrorCode == CommandErrorCode.UnitNotOwned,
            "其他玩家单位应返回 UnitNotOwned");
        Check(fire.Status == CommandStatus.Accepted, "己方开火策略应被接受");
        Check(policies.Get(owned) == new CombatPolicySnapshot(
                EngagementStance.Guard,
                FirePolicy.HoldFire,
                null),
            "姿态与开火策略应正交保存");
    }

    /// <summary>验证普通攻击受停火约束，且不会调用攻击端口。</summary>
    private void OrdinaryAttackRespectsHoldFire()
    {
        var owner = NewPlayerId();
        var enemyOwner = NewPlayerId();
        var attacker = NewUnitId();
        var target = NewUnitId();
        var policies = new InMemoryCombatPolicyStore();
        var attack = new FakeAttackPort();
        var service = NewService(
            CombatRepository(owner, enemyOwner, attacker, target),
            attack: attack,
            policies: policies);
        policies.SetFirePolicy(attacker, FirePolicy.HoldFire);

        var result = service.Attack(
            Context(owner),
            new AttackCommand([attacker], new EntityAttackTarget(target)));

        Check(ResultFor(result, attacker).ErrorCode == CommandErrorCode.FirePolicyPreventsAttack,
            "停火单位的普通攻击应被拒绝");
        Check(attack.OrdinaryRequests == 0, "停火拒绝不应到达攻击端口");
    }

    /// <summary>验证移动和实体攻击订单保存公开查询所需的原始目标意图。</summary>
    private void AcceptedOrdersPreserveOriginalTargets()
    {
        var owner = NewPlayerId();
        var enemyOwner = NewPlayerId();
        var attacker = NewUnitId();
        var target = NewUnitId();
        var destination = new WorldPosition(3, 0, 4);
        var domains = new HashSet<CombatDomain> { CombatDomain.Terrain };
        var orders = new InMemoryUnitOrderStore();
        var service = NewService(
            new FakeRepository(
                new UnitCommandSnapshot(
                    attacker,
                    owner,
                    true,
                    true,
                    CombatDomain.Terrain,
                    domains),
                new UnitCommandSnapshot(
                    target,
                    enemyOwner,
                    false,
                    EntityKind: BattlefieldEntityKind.Structure,
                    TypeId: "command_center")),
            orders: orders);

        service.Move(Context(owner), new MoveUnitsCommand([attacker], destination));
        Check(orders.FindActive(attacker)?.Target == new UnitOrderPositionTarget(destination),
            "移动订单应保存下令时的世界位置");

        service.Attack(Context(owner), new AttackCommand([attacker], new EntityAttackTarget(target)));
        Check(orders.FindActive(attacker)?.Target == new UnitOrderEntityTarget(
                new BattlefieldEntityId(BattlefieldEntityKind.Structure, target.Value),
                "command_center"),
            "实体攻击订单应保存稳定实体种类、ID 与类型");
    }

    /// <summary>验证显式强制攻击可以临时覆盖停火而不修改持续策略。</summary>
    private void ForceAttackOverridesHoldFire()
    {
        var owner = NewPlayerId();
        var targetOwner = NewPlayerId();
        var attacker = NewUnitId();
        var target = NewUnitId();
        var policies = new InMemoryCombatPolicyStore();
        var attack = new FakeAttackPort();
        var service = NewService(
            CombatRepository(owner, targetOwner, attacker, target),
            attack: attack,
            policies: policies);
        policies.SetFirePolicy(attacker, FirePolicy.HoldFire);

        var result = service.ForceAttack(
            Context(owner),
            new ForceAttackCommand([attacker], new EntityAttackTarget(target)));

        Check(result.Status == CommandStatus.Accepted, "ForceAttack 应临时覆盖停火");
        Check(attack.ForceRequests == 1, "合法 ForceAttack 应调用强制攻击端口");
        Check(policies.Get(attacker).FirePolicy == FirePolicy.HoldFire,
            "临时授权不应修改持续停火策略");
    }

    /// <summary>验证地面强制攻击逐单位检查显式武器能力，并保持持续停火策略。</summary>
    private void GroundForceAttackRequiresExplicitCapability()
    {
        var owner = NewPlayerId();
        var capable = NewUnitId();
        var unsupported = NewUnitId();
        var attack = new FakeAttackPort();
        var policies = new InMemoryCombatPolicyStore();
        var repository = new FakeRepository(
            new UnitCommandSnapshot(
                capable,
                owner,
                true,
                true,
                CanForceFireGround: true),
            new UnitCommandSnapshot(
                unsupported,
                owner,
                true,
                true));
        var orders = new InMemoryUnitOrderStore();
        var service = NewService(repository, attack: attack, orders: orders, policies: policies);
        policies.SetFirePolicy(capable, FirePolicy.HoldFire);

        var result = service.ForceAttack(
            Context(owner),
            new ForceAttackCommand(
                [capable, unsupported],
                new GroundAttackTarget(new WorldPosition(2, 0, 2))));

        Check(result.Status == CommandStatus.PartiallyAccepted,
            "混合地面强制开火能力应部分接受");
        Check(ResultFor(result, capable).Accepted, "支持地面炮击的单位应接受");
        Check(ResultFor(result, unsupported).ErrorCode == CommandErrorCode.WeaponCannotForceFire,
            "不支持地面炮击的单位应稳定拒绝");
        Check(attack.GroundForceRequests == 1, "只有支持能力的单位应调用地面攻击端口");
        Check(orders.FindActive(capable)?.Kind == UnitOrderKind.GroundForceAttack,
            "地面炮击应保留独立订单类型");
        Check(policies.Get(capable).FirePolicy == FirePolicy.HoldFire,
            "临时地面开火授权不应修改持续停火策略");
    }

    /// <summary>验证停火只禁止射击，不阻止实体 AttackMove 的移动意图。</summary>
    private void AttackMoveKeepsMovingDuringHoldFire()
    {
        var owner = NewPlayerId();
        var enemyOwner = NewPlayerId();
        var attacker = NewUnitId();
        var target = NewUnitId();
        var policies = new InMemoryCombatPolicyStore();
        var movement = new FakeMovementPort();
        var service = NewService(
            CombatRepository(owner, enemyOwner, attacker, target),
            movement,
            policies: policies);
        policies.SetFirePolicy(attacker, FirePolicy.HoldFire);

        var result = service.EntityAttackMove(
            Context(owner),
            new EntityAttackMoveCommand([attacker], new EntityAttackTarget(target)));

        Check(result.Status == CommandStatus.Accepted, "停火时实体 AttackMove 仍应推进");
        Check(movement.EntityAttackMoveRequests == 1, "AttackMove 应到达专用移动端口");
    }

    /// <summary>验证没有倒车能力的单位退化为普通移动，但保留撤退订单意图。</summary>
    private void TacticalWithdrawFallsBackToOrdinaryMovement()
    {
        var owner = NewPlayerId();
        var reversing = NewUnitId();
        var forwardOnly = NewUnitId();
        var movement = new FakeMovementPort();
        var orders = new InMemoryUnitOrderStore();
        var service = NewService(
            new FakeRepository(
                new UnitCommandSnapshot(reversing, owner, true, CanReverse: true),
                new UnitCommandSnapshot(forwardOnly, owner, true)),
            movement,
            orders: orders);

        var result = service.TacticalWithdraw(
            Context(owner),
            new TacticalWithdrawCommand(
                [reversing, forwardOnly],
                new WorldPosition(8, 0, 8)));

        Check(result.Status == CommandStatus.Accepted, "两种单位的撤退命令都应被接受");
        Check(movement.WithdrawRequests == 1, "倒车单位应调用撤退端口");
        Check(movement.MoveRequests == 1, "无倒车能力单位应退化为普通移动");
        Check(orders.FindActive(forwardOnly)?.Kind == UnitOrderKind.TacticalWithdraw,
            "退化执行仍应保留玩家的撤退意图");
    }

    /// <summary>验证靠近资源与持续跟随使用不同订单种类，并保留稳定实体目标。</summary>
    private void EntityMovementKeepsDistinctOrderSemantics()
    {
        var owner = NewPlayerId();
        var unit = NewUnitId();
        var target = NewUnitId();
        var resource = NewResourceNodeId();
        var movement = new FakeMovementPort();
        var orders = new InMemoryUnitOrderStore();
        var service = NewService(
            new FakeRepository(
                new UnitCommandSnapshot(unit, owner, true),
                new UnitCommandSnapshot(target, owner, true)),
            movement,
            orders: orders,
            resources: new FakeResourceRepository(
                new ResourceNodeSnapshot(resource, ResourceKind.A, true)));

        var approach = service.ApproachEntity(
            Context(owner),
            new ApproachEntityCommand(
                [unit],
                new BattlefieldEntityId(BattlefieldEntityKind.ResourceNode, resource.Value)));
        var approachOrder = orders.Find(ResultFor(approach, unit).OrderId!.Value);
        var follow = service.FollowEntity(
            Context(owner),
            new FollowEntityCommand([unit], target));
        var followOrder = orders.Find(ResultFor(follow, unit).OrderId!.Value);

        Check(approach.Status == CommandStatus.Accepted && movement.ApproachRequests == 1,
            "资源实体 Approach 应到达专用移动端口");
        Check(approachOrder?.Kind == UnitOrderKind.ApproachEntity &&
            approachOrder.Target is UnitOrderEntityTarget
            {
                EntityId.Kind: BattlefieldEntityKind.ResourceNode
            }, "Approach 应保存资源实体身份");
        Check(follow.Status == CommandStatus.Accepted && movement.FollowRequests == 1,
            "单位 Follow 应到达专用移动端口");
        Check(followOrder?.Kind == UnitOrderKind.FollowEntity &&
            followOrder.Target is UnitOrderEntityTarget entity &&
            entity.EntityId.Value == target.Value,
            "Follow 应保留目标单位身份并使用独立订单种类");
        Check(approachOrder is not null &&
            orders.Find(approachOrder.OrderId)?.State == UnitOrderState.Cancelled,
            "后续 Follow 应按统一替换规则取消旧 Approach");
    }

    /// <summary>验证实体移动拒绝自目标与失效目标，且不会调用执行端。</summary>
    private void EntityMovementRejectsSelfAndMissingTargets()
    {
        var owner = NewPlayerId();
        var unit = NewUnitId();
        var missing = NewUnitId();
        var movement = new FakeMovementPort();
        var service = NewService(
            new FakeRepository(new UnitCommandSnapshot(unit, owner, true)),
            movement);

        var self = service.FollowEntity(
            Context(owner),
            new FollowEntityCommand([unit], unit));
        var absent = service.FollowEntity(
            Context(owner),
            new FollowEntityCommand([unit], missing));

        Check(ResultFor(self, unit).ErrorCode == CommandErrorCode.InvalidMovementTarget,
            "单位不得持续跟随自身");
        Check(ResultFor(absent, unit).ErrorCode == CommandErrorCode.TargetNotFound,
            "失效实体目标应稳定返回 TargetNotFound");
        Check(movement.FollowRequests == 0,
            "非法实体目标不得到达移动执行端");
    }

    /// <summary>验证统一 Stop 会暂停 Approach 与 Follow，且不创建自动恢复。</summary>
    private void StopSuspendsEntityMovementOrders()
    {
        var owner = NewPlayerId();
        var approachUnit = NewUnitId();
        var followUnit = NewUnitId();
        var target = NewUnitId();
        var orders = new InMemoryUnitOrderStore();
        var service = NewService(
            new FakeRepository(
                new UnitCommandSnapshot(approachUnit, owner, true),
                new UnitCommandSnapshot(followUnit, owner, true),
                new UnitCommandSnapshot(target, owner, true)),
            orders: orders);
        var approach = service.ApproachEntity(
            Context(owner),
            new ApproachEntityCommand(
                [approachUnit],
                new BattlefieldEntityId(BattlefieldEntityKind.Unit, target.Value)));
        var follow = service.FollowEntity(
            Context(owner),
            new FollowEntityCommand([followUnit], target));

        var stopped = service.Stop(
            Context(owner),
            new StopUnitsCommand([approachUnit, followUnit]));

        Check(stopped.Status == CommandStatus.Accepted,
            "Stop 应接受两个实体移动订单");
        Check(orders.Find(ResultFor(approach, approachUnit).OrderId!.Value)?.State ==
            UnitOrderState.Suspended,
            "Approach 被 Stop 后应暂停");
        Check(orders.Find(ResultFor(follow, followUnit).OrderId!.Value)?.State ==
            UnitOrderState.Suspended,
            "Follow 被 Stop 后应暂停");
    }

    /// <summary>验证引擎适配失败会映射为稳定的 Application 错误码。</summary>
    private void PortFailuresMapToStableErrors()
    {
        var owner = NewPlayerId();
        var enemyOwner = NewPlayerId();
        var attacker = NewUnitId();
        var target = NewUnitId();
        var movement = new FakeMovementPort
        {
            MovementError = MovementPortError.UnitUnavailable
        };
        var attack = new FakeAttackPort
        {
            Error = AttackPortError.AttackUnavailable
        };
        var repository = CombatRepository(owner, enemyOwner, attacker, target);
        var service = NewService(repository, movement, attack);

        var move = service.Move(
            Context(owner),
            new MoveUnitsCommand([attacker], new WorldPosition(1, 0, 1)));
        var fire = service.Attack(
            Context(owner),
            new AttackCommand([attacker], new EntityAttackTarget(target)));

        Check(ResultFor(move, attacker).ErrorCode == CommandErrorCode.UnitNotFound,
            "移动端口 UnitUnavailable 应映射为 UnitNotFound");
        Check(ResultFor(fire, attacker).ErrorCode == CommandErrorCode.AttackUnavailable,
            "攻击端口失败应映射为 AttackUnavailable");
    }

    /// <summary>验证订单存储发布创建与实际状态变化，并抑制重复状态伪事件。</summary>
    private void OrderStorePublishesAuthoritativeStateChanges()
    {
        var store = new InMemoryUnitOrderStore();
        var changes = new List<UnitOrderStateChanged>();
        store.StateChanged += changes.Add;
        var order = store.Create(
            new CommandId(Guid.NewGuid()),
            NewUnitId(),
            UnitOrderKind.Move);

        store.Transition(order.OrderId, UnitOrderState.InProgress);
        store.Transition(order.OrderId, UnitOrderState.InProgress);
        store.Transition(order.OrderId, UnitOrderState.Suspended);
        store.Transition(order.OrderId, UnitOrderState.Cancelled);

        Check(changes.Count == 4, "创建和三次实际状态变化应产生四个事件");
        Check(changes[0].Previous is null && changes[0].Current.State == UnitOrderState.Accepted,
            "创建事件应没有 Previous，并携带 Accepted 快照");
        Check(changes[1].Previous?.State == UnitOrderState.Accepted &&
            changes[1].Current.State == UnitOrderState.InProgress,
            "执行事件应记录 Accepted 到 InProgress");
        Check(changes[2].Previous?.State == UnitOrderState.InProgress &&
            changes[2].Current.State == UnitOrderState.Suspended,
            "暂停事件应记录 InProgress 到 Suspended");
        Check(changes[3].Previous?.State == UnitOrderState.Suspended &&
            changes[3].Current.State == UnitOrderState.Cancelled,
            "取消事件应记录 Suspended 到 Cancelled");
    }

    /// <summary>验证范围弹头以实际爆点查询，并允许 footprint 边缘进入范围的非指定目标受伤。</summary>
    private void AreaWarheadUsesImpactPointAndFootprints()
    {
        var sourcePlayer = NewPlayerId();
        var enemyPlayer = NewPlayerId();
        var intended = NewUnitId();
        var nearby = NewUnitId();
        var outside = NewUnitId();
        var launch = LaunchSnapshot(
            sourcePlayer,
            intended,
            radius: 1.0f,
            selectionMode: ImpactSelectionMode.Area);
        var resolver = new WarheadDamageResolver();

        var damage = resolver.Resolve(
            launch,
            new WorldPosition(5, 0, 5),
            [
                new ImpactCandidateSnapshot(
                    intended, enemyPlayer, new WorldPosition(20, 0, 20), 0.5f, true),
                new ImpactCandidateSnapshot(
                    nearby, enemyPlayer, new WorldPosition(6.4f, 0, 5), 0.5f, true),
                new ImpactCandidateSnapshot(
                    outside, enemyPlayer, new WorldPosition(6.6f, 0, 5), 0.5f, true)
            ]);

        Check(damage.Count == 1 && damage[0].UnitId == nearby,
            "范围弹头应命中 footprint 与爆炸范围相交的非指定目标");
    }

    /// <summary>验证弹头按稳定 ID 去重排序，并对友军应用发射快照中的伤害倍率。</summary>
    private void WarheadResultsAreStableUniqueAndRespectFriendlyFire()
    {
        var sourcePlayer = NewPlayerId();
        var enemyPlayer = NewPlayerId();
        var friendly = NewUnitId();
        var enemy = NewUnitId();
        var launch = LaunchSnapshot(
            sourcePlayer,
            null,
            radius: 3.0f,
            selectionMode: ImpactSelectionMode.Area,
            friendlyFireMultiplier: 0.5f);
        var resolver = new WarheadDamageResolver();
        var friendlyCandidate = new ImpactCandidateSnapshot(
            friendly, sourcePlayer, new WorldPosition(0, 0, 0), 0.5f, true);

        var damage = resolver.Resolve(
            launch,
            new WorldPosition(0, 0, 0),
            [
                new ImpactCandidateSnapshot(
                    enemy, enemyPlayer, new WorldPosition(1, 0, 0), 0.5f, true),
                friendlyCandidate,
                friendlyCandidate
            ]);

        Check(damage.Count == 2, "同一爆炸对每个稳定 UnitId 最多结算一次");
        Check(damage.SequenceEqual(damage.OrderBy(item => item.UnitId.Value)),
            "爆点伤害结果应按稳定 UnitId 排序");
        Check(damage.Single(item => item.UnitId == friendly).Damage == 5.0f,
            "友军应应用发射快照中的友伤倍率");
        Check(damage.Single(item => item.UnitId == enemy).Damage == 10.0f,
            "敌军应承受完整基础伤害");
    }

    /// <summary>验证一笔 A/B 交易只增加一次版本并完整应用。</summary>
    private void ResourceTransactionAppliesMultipleKindsAtomically()
    {
        var player = NewPlayerId();
        var match = new MatchId(Guid.NewGuid());
        var service = OpenAccount(player, match, 10, 8);

        var result = service.Apply(new ApplyResourceTransaction(
            NewResourceTransactionId(),
            match,
            player,
            [new ResourceDelta(ResourceKind.A, -4), new ResourceDelta(ResourceKind.B, -3)],
            ResourceChangeReason.ConstructionCost,
            null,
            2));

        Check(result.Status == ResourceTransactionStatus.Applied, "余额足够时多资源交易应成功");
        Check(result.Snapshot?.GetBalance(ResourceKind.A) == 6, "A 应按交易扣除");
        Check(result.Snapshot?.GetBalance(ResourceKind.B) == 5, "B 应按交易扣除");
        Check(result.Snapshot?.Version == 2, "多资源交易只应增加一次账户版本");
    }

    /// <summary>验证任一资源不足时整笔交易失败且其他资源不被部分扣除。</summary>
    private void ResourceTransactionRejectsPartialPayment()
    {
        var player = NewPlayerId();
        var match = new MatchId(Guid.NewGuid());
        var service = OpenAccount(player, match, 10, 1);

        var result = service.Apply(new ApplyResourceTransaction(
            NewResourceTransactionId(),
            match,
            player,
            [new ResourceDelta(ResourceKind.A, -4), new ResourceDelta(ResourceKind.B, -2)],
            ResourceChangeReason.ProductionCost,
            null,
            2));

        Check(result.Status == ResourceTransactionStatus.InsufficientResources,
            "任一资源不足时应返回 InsufficientResources");
        Check(service.Find(player)?.GetBalance(ResourceKind.A) == 10,
            "失败交易不得部分扣除充足的 A");
        Check(service.Find(player)?.GetBalance(ResourceKind.B) == 1,
            "失败交易不得改变不足的 B");
    }

    /// <summary>验证成功交易重放不会重复入账或重复发布事件。</summary>
    private void ResourceTransactionReplayIsIdempotent()
    {
        var player = NewPlayerId();
        var match = new MatchId(Guid.NewGuid());
        var service = OpenAccount(player, match, 0, 0);
        var changes = 0;
        service.BalanceChanged += _ => changes++;
        var transaction = new ApplyResourceTransaction(
            NewResourceTransactionId(),
            match,
            player,
            [new ResourceDelta(ResourceKind.A, 5)],
            ResourceChangeReason.WorkerDelivery,
            NewUnitId().Value,
            2);

        var first = service.Apply(transaction);
        var replay = service.Apply(transaction);

        Check(first.Status == ResourceTransactionStatus.Applied, "首次交付应成功");
        Check(replay.Status == ResourceTransactionStatus.AlreadyApplied, "重放应返回 AlreadyApplied");
        Check(service.Find(player)?.GetBalance(ResourceKind.A) == 5, "重放不得重复入账");
        Check(changes == 1, "重放不得重复发布余额变化事件");
    }

    /// <summary>验证同一交易 ID 不能用于不同交易内容。</summary>
    private void ResourceTransactionIdConflictIsRejected()
    {
        var player = NewPlayerId();
        var match = new MatchId(Guid.NewGuid());
        var service = OpenAccount(player, match, 0, 0);
        var id = NewResourceTransactionId();
        service.Apply(new ApplyResourceTransaction(
            id,
            match,
            player,
            [new ResourceDelta(ResourceKind.A, 2)],
            ResourceChangeReason.MissionReward,
            null,
            2));

        var conflict = service.Apply(new ApplyResourceTransaction(
            id,
            match,
            player,
            [new ResourceDelta(ResourceKind.A, 3)],
            ResourceChangeReason.MissionReward,
            null,
            2));

        Check(conflict.Status == ResourceTransactionStatus.TransactionConflict,
            "相同 ID 的不同内容应返回 TransactionConflict");
        Check(service.Find(player)?.GetBalance(ResourceKind.A) == 2,
            "冲突交易不得修改余额");
    }

    /// <summary>验证空、零、重复资源和整数溢出交易均被拒绝。</summary>
    private void ResourceTransactionRejectsInvalidAndOverflowingAmounts()
    {
        var player = NewPlayerId();
        var match = new MatchId(Guid.NewGuid());
        var service = OpenAccount(player, match, int.MaxValue, 0);
        var empty = service.Apply(new ApplyResourceTransaction(
            NewResourceTransactionId(), match, player, [],
            ResourceChangeReason.ScriptedAdjustment, null, 2));
        var zero = service.Apply(new ApplyResourceTransaction(
            NewResourceTransactionId(), match, player,
            [new ResourceDelta(ResourceKind.A, 0)],
            ResourceChangeReason.ScriptedAdjustment, null, 3));
        var duplicate = service.Apply(new ApplyResourceTransaction(
            NewResourceTransactionId(), match, player,
            [new ResourceDelta(ResourceKind.B, 1), new ResourceDelta(ResourceKind.B, 1)],
            ResourceChangeReason.ScriptedAdjustment, null, 4));
        var wrongDirection = service.Apply(new ApplyResourceTransaction(
            NewResourceTransactionId(), match, player,
            [new ResourceDelta(ResourceKind.B, 1)],
            ResourceChangeReason.ConstructionCost, null, 4));
        var overflow = service.Apply(new ApplyResourceTransaction(
            NewResourceTransactionId(), match, player,
            [new ResourceDelta(ResourceKind.A, 1)],
            ResourceChangeReason.ScriptedAdjustment, null, 5));

        Check(empty.Status == ResourceTransactionStatus.InvalidTransaction, "空交易应被拒绝");
        Check(zero.Status == ResourceTransactionStatus.InvalidTransaction, "零变化应被拒绝");
        Check(duplicate.Status == ResourceTransactionStatus.InvalidTransaction, "重复资源应被拒绝");
        Check(wrongDirection.Status == ResourceTransactionStatus.InvalidTransaction,
            "成本交易使用正数时应被拒绝");
        Check(overflow.Status == ResourceTransactionStatus.Overflow, "整数溢出应被拒绝");
        Check(service.Find(player)?.GetBalance(ResourceKind.A) == int.MaxValue,
            "无效交易不得改变账户");
    }

    /// <summary>验证不同收入来源共享相同账户交易入口。</summary>
    private void ResourceAccountSupportsAllIncomeReasons()
    {
        var player = NewPlayerId();
        var match = new MatchId(Guid.NewGuid());
        var service = OpenAccount(player, match, 0, 0);
        var reasons = new[]
        {
            ResourceChangeReason.WorkerDelivery,
            ResourceChangeReason.ConstructionRefund,
            ResourceChangeReason.ProductionRefund,
            ResourceChangeReason.MissionReward,
            ResourceChangeReason.PassiveIncome,
            ResourceChangeReason.ScriptedAdjustment
        };

        foreach (var reason in reasons)
        {
            var result = service.Apply(new ApplyResourceTransaction(
                NewResourceTransactionId(), match, player,
                [new ResourceDelta(ResourceKind.B, 1)], reason, null, 2));
            Check(result.Status == ResourceTransactionStatus.Applied,
                $"{reason} 应能使用统一账户入口");
        }

        Check(service.Find(player)?.GetBalance(ResourceKind.B) == reasons.Length,
            "所有已接受收入应进入同一账户");
    }

    /// <summary>验证外部快照不能反向修改账户内部字典。</summary>
    private void ResourceAccountSnapshotCannotMutateStore()
    {
        var player = NewPlayerId();
        var service = OpenAccount(player, new MatchId(Guid.NewGuid()), 3, 4);
        var snapshot = service.Find(player)!;
        var mutationRejected = false;
        try
        {
            ((IDictionary<ResourceKind, int>)snapshot.Balances)[ResourceKind.A] = 99;
        }
        catch (NotSupportedException)
        {
            mutationRejected = true;
        }

        Check(mutationRejected, "快照余额集合应拒绝外部修改");
        Check(service.Find(player)?.GetBalance(ResourceKind.A) == 3,
            "修改快照不得影响账户内部余额");
    }

    /// <summary>建立测试账户并确认初始余额导入成功。</summary>
    private static InMemoryResourceAccountService OpenAccount(
        PlayerId player,
        MatchId match,
        int resourceA,
        int resourceB)
    {
        var service = new InMemoryResourceAccountService();
        var result = service.Open(new OpenResourceAccount(
            NewResourceTransactionId(),
            match,
            player,
            [new ResourceAmount(ResourceKind.A, resourceA), new ResourceAmount(ResourceKind.B, resourceB)],
            1));
        if (result.Status != ResourceTransactionStatus.Applied)
        {
            throw new InvalidOperationException($"测试账户初始化失败：{result.Status}");
        }
        return service;
    }

    /// <summary>创建纯规则测试使用的不可变发射快照。</summary>
    private static AttackLaunchSnapshot LaunchSnapshot(
        PlayerId sourcePlayer,
        UnitId? intendedTarget,
        float radius,
        ImpactSelectionMode selectionMode,
        float friendlyFireMultiplier = 1.0f) => new(
            new AttackInstanceId(Guid.NewGuid()),
            NewUnitId(),
            sourcePlayer,
            WeaponDeliveryKind.Projectile,
            new WorldPosition(0, 0, 0),
            new WorldPosition(5, 0, 5),
            intendedTarget,
            10.0f,
            radius,
            friendlyFireMultiplier,
            selectionMode);

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

    private void Check(bool condition, string message)
    {
        if (condition)
        {
            return;
        }

        _failures++;
        Console.Error.WriteLine($"[FAIL] {message}");
    }

    private static UnitCommandResult ResultFor(CommandResult result, UnitId unitId) =>
        result.UnitResults.Single(item => item.UnitId == unitId);

    private static CommandContext Context(PlayerId owner) => new(
        new CommandId(Guid.NewGuid()),
        new MatchId(Guid.NewGuid()),
        owner,
        1);

    private static PlayerId NewPlayerId() => new(Guid.NewGuid());

    private static UnitId NewUnitId() => new(Guid.NewGuid());

    private static ResourceNodeId NewResourceNodeId() => new(Guid.NewGuid());

    private static ResourceTransactionId NewResourceTransactionId() => new(Guid.NewGuid());

    private static FakeRepository CombatRepository(
        PlayerId owner,
        PlayerId targetOwner,
        UnitId attacker,
        UnitId target)
    {
        var domains = new HashSet<CombatDomain> { CombatDomain.Terrain };
        return new FakeRepository(
            new UnitCommandSnapshot(
                attacker,
                owner,
                true,
                true,
                CombatDomain.Terrain,
                domains),
            new UnitCommandSnapshot(target, targetOwner, true, true));
    }

    private static UnitCommandService NewService(
        IUnitCommandUnitRepository repository,
        IUnitMovementPort? movement = null,
        IUnitAttackPort? attack = null,
        IUnitOrderStore? orders = null,
        ICombatPolicyStore? policies = null,
        IUnitStopPort? stop = null,
        IWorkerTaskPort? workerTasks = null,
        IResourceNodeRepository? resources = null) => new(
            repository,
            movement ?? new FakeMovementPort(),
            attack ?? new FakeAttackPort(),
            orders ?? new InMemoryUnitOrderStore(),
            policies ?? new InMemoryCombatPolicyStore(),
            stop ?? new FakeStopPort(),
            workerTasks,
            resources);

    /// <summary>提供纯内存单位快照，不依赖 Godot ObjectDB。</summary>
    private sealed class FakeRepository(params UnitCommandSnapshot[] units) : IUnitCommandUnitRepository
    {
        private readonly Dictionary<UnitId, UnitCommandSnapshot> _units =
            units.ToDictionary(unit => unit.UnitId);

        /// <inheritdoc />
        public UnitCommandSnapshot? Find(UnitId unitId) =>
            _units.TryGetValue(unitId, out var unit) ? unit : null;
    }

    /// <summary>提供纯内存资源节点快照。</summary>
    private sealed class FakeResourceRepository(params ResourceNodeSnapshot[] resources) :
        IResourceNodeRepository
    {
        private readonly Dictionary<ResourceNodeId, ResourceNodeSnapshot> _resources =
            resources.ToDictionary(resource => resource.ResourceNodeId);

        /// <inheritdoc />
        public ResourceNodeSnapshot? Find(ResourceNodeId resourceNodeId) =>
            _resources.TryGetValue(resourceNodeId, out var resource) ? resource : null;
    }

    /// <summary>记录纯 C# 测试中的 Worker 采集与暂停请求。</summary>
    private sealed class FakeWorkerTaskPort : IWorkerTaskPort
    {
        /// <summary>累计收到的采集请求数。</summary>
        public int GatherRequests { get; private set; }

        /// <summary>累计收到的暂停请求数。</summary>
        public int SuspendRequests { get; private set; }

        /// <inheritdoc />
        public WorkerTaskPortResult RequestGather(UnitId workerId, ResourceNodeId resourceNodeId)
        {
            GatherRequests++;
            return WorkerTaskPortResult.Success();
        }

        /// <inheritdoc />
        public WorkerTaskPortResult RequestSuspend(UnitId workerId)
        {
            SuspendRequests++;
            return WorkerTaskPortResult.Success();
        }
    }

    /// <summary>记录纯 C# 测试中的移动意图，并允许注入失败。</summary>
    private sealed class FakeMovementPort : IUnitMovementPort
    {
        /// <summary>非 None 时，所有移动请求返回该错误。</summary>
        public MovementPortError MovementError { get; set; }

        /// <summary>普通移动请求次数。</summary>
        public int MoveRequests { get; private set; }

        /// <summary>地面移动攻击请求次数。</summary>
        public int GroundAttackMoveRequests { get; private set; }

        /// <summary>实体移动攻击请求次数。</summary>
        public int EntityAttackMoveRequests { get; private set; }

        /// <summary>靠近实体请求次数。</summary>
        public int ApproachRequests { get; private set; }

        /// <summary>持续跟随实体请求次数。</summary>
        public int FollowRequests { get; private set; }

        /// <summary>倒车撤退请求次数。</summary>
        public int WithdrawRequests { get; private set; }

        /// <inheritdoc />
        public MovementPortResult RequestMove(UnitId unitId, WorldPosition destination)
        {
            MoveRequests++;
            return Result();
        }

        /// <inheritdoc />
        public MovementPortResult RequestApproachEntity(
            UnitId unitId,
            BattlefieldEntityId targetEntityId)
        {
            ApproachRequests++;
            return Result();
        }

        /// <inheritdoc />
        public MovementPortResult RequestFollowEntity(UnitId unitId, UnitId targetId)
        {
            FollowRequests++;
            return Result();
        }

        /// <inheritdoc />
        public MovementPortResult RequestGroundAttackMove(UnitId unitId, WorldPosition destination)
        {
            GroundAttackMoveRequests++;
            return Result();
        }

        /// <inheritdoc />
        public MovementPortResult RequestEntityAttackMove(UnitId unitId, UnitId targetId)
        {
            EntityAttackMoveRequests++;
            return Result();
        }

        /// <inheritdoc />
        public MovementPortResult RequestTacticalWithdraw(UnitId unitId, WorldPosition destination)
        {
            WithdrawRequests++;
            return Result();
        }

        /// <inheritdoc />
        public MovementPortResult RequestHalt(UnitId unitId) => Result();

        private MovementPortResult Result() => MovementError == MovementPortError.None
            ? MovementPortResult.Success()
            : MovementPortResult.Failure(MovementError);
    }

    /// <summary>记录纯 C# 测试中的攻击意图，并允许注入失败。</summary>
    private sealed class FakeAttackPort : IUnitAttackPort
    {
        /// <summary>非 None 时，所有攻击请求返回该错误。</summary>
        public AttackPortError Error { get; set; }

        /// <summary>普通攻击请求次数。</summary>
        public int OrdinaryRequests { get; private set; }

        /// <summary>强制攻击请求次数。</summary>
        public int ForceRequests { get; private set; }

        /// <summary>地面强制攻击请求次数。</summary>
        public int GroundForceRequests { get; private set; }

        /// <inheritdoc />
        public AttackPortResult RequestEntityAttack(UnitId attackerId, UnitId targetId)
        {
            OrdinaryRequests++;
            return Result();
        }

        /// <inheritdoc />
        public AttackPortResult RequestEntityForceAttack(UnitId attackerId, UnitId targetId)
        {
            ForceRequests++;
            return Result();
        }

        /// <inheritdoc />
        public AttackPortResult RequestGroundForceAttack(UnitId attackerId, WorldPosition position)
        {
            GroundForceRequests++;
            return Result();
        }

        /// <inheritdoc />
        public AttackPortResult RequestCancelForceAttack(UnitId unitId) => Result();

        private AttackPortResult Result() => Error == AttackPortError.None
            ? AttackPortResult.Success()
            : AttackPortResult.Failure(Error);
    }

    /// <summary>记录纯 C# 测试中的原子 Stop 请求，并允许注入拒绝原因。</summary>
    private sealed class FakeStopPort : IUnitStopPort
    {
        /// <summary>非 None 时，后续统一停止请求均返回该错误。</summary>
        public StopPortError Error { get; set; }

        /// <summary>累计收到的统一停止请求数。</summary>
        public int Requests { get; private set; }

        /// <inheritdoc />
        public StopPortResult RequestStop(UnitId unitId)
        {
            Requests++;
            return Error == StopPortError.None ?
                StopPortResult.Success() : StopPortResult.Failure(Error);
        }
    }
}
