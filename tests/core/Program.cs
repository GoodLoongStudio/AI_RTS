using AI_RTS.Application.Battlefield;
using AI_RTS.Application.Commands;
using AI_RTS.Application.Commands.Units;
using AI_RTS.Application.Combat;
using AI_RTS.Application.Configuration;
using AI_RTS.Application.Economy;
using AI_RTS.Application.Orders;
using AI_RTS.Application.Skills;
using AI_RTS.Application.Units;
using AI_RTS.Domain.Battlefield;
using AI_RTS.Domain.Combat;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Configuration;
using AI_RTS.Domain.Construction;
using AI_RTS.Domain.Economy;
using AI_RTS.Domain.Production;
using AI_RTS.Domain.Skills;

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
        failures += new MatchOutcomeServiceTests().Run();
        failures += new BattlefieldEventLogTests().Run();
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
        RunTest(nameof(ReturnToBaseSelectsNearestCompletedCommandCenter),
            ReturnToBaseSelectsNearestCompletedCommandCenter);
        RunTest(nameof(ReturnToBaseRejectsWithoutCommandCenter),
            ReturnToBaseRejectsWithoutCommandCenter);
        RunTest(nameof(StopSuspendsReturnToBaseOrder), StopSuspendsReturnToBaseOrder);
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
        RunTest(nameof(CastSkillAcceptsOwnedUnitOnSelfActiveSkill),
            CastSkillAcceptsOwnedUnitOnSelfActiveSkill);
        RunTest(nameof(CastSkillRejectsMissingPassiveAndNonSelfSkills),
            CastSkillRejectsMissingPassiveAndNonSelfSkills);
        RunTest(nameof(CastSkillChecksOwnershipWithoutReplacingOrders),
            CastSkillChecksOwnershipWithoutReplacingOrders);
        RunTest(nameof(CastSkillDealDamageHitsSelfThroughWarheadResolver),
            CastSkillDealDamageHitsSelfThroughWarheadResolver);
        RunTest(nameof(CastSkillDealDamageHitsSpecifiedUnitAndSkipsUndamageable),
            CastSkillDealDamageHitsSpecifiedUnitAndSkipsUndamageable);
        RunTest(nameof(CastSkillRejectsFriendOutOfRangeAndDeadTargets),
            CastSkillRejectsFriendOutOfRangeAndDeadTargets);
        RunTest(nameof(CastSkillRecordsInRangeGroundTarget),
            CastSkillRecordsInRangeGroundTarget);
        RunTest(nameof(CastSkillPaysCostThenStartsCooldownOnSimulationClock),
            CastSkillPaysCostThenStartsCooldownOnSimulationClock);
        RunTest(nameof(CastSkillRejectsInsufficientResourcesWithoutStartingCooldown),
            CastSkillRejectsInsufficientResourcesWithoutStartingCooldown);
        RunTest(nameof(CastSkillSecondEffectWaitsForSimulationDelay),
            CastSkillSecondEffectWaitsForSimulationDelay);
        RunTest(nameof(CastSkillRestoreHealthClampsToMaximum),
            CastSkillRestoreHealthClampsToMaximum);
        RunTest(nameof(CastSkillStatusAppliesAndExpiresMoveSpeed),
            CastSkillStatusAppliesAndExpiresMoveSpeed);
        RunTest(nameof(CastSkillStatusStackRulesRefreshOverwriteIgnore),
            CastSkillStatusStackRulesRefreshOverwriteIgnore);
        RunTest(nameof(CastSkillStatusIgnoresDeadTarget),
            CastSkillStatusIgnoresDeadTarget);
        RunTest(nameof(CastSkillSimultaneousDamageAndHeal),
            CastSkillSimultaneousDamageAndHeal);
        RunTest(nameof(CastSkillPeriodicTicksUseSimulationClock),
            CastSkillPeriodicTicksUseSimulationClock);
        RunTest(nameof(CastSkillConditionSkipsWhenNotWounded),
            CastSkillConditionSkipsWhenNotWounded);
        RunTest(nameof(CastSkillSequentialAfterSimultaneousKeepsDelay),
            CastSkillSequentialAfterSimultaneousKeepsDelay);
        RunTest(nameof(AutomaticEventSkillHealsOnDamageWithoutPlayerCast),
            AutomaticEventSkillHealsOnDamageWithoutPlayerCast);
        RunTest(nameof(AutomaticConditionAndPassiveSkillsEvaluateOnClock),
            AutomaticConditionAndPassiveSkillsEvaluateOnClock);
        RunTest(nameof(CastSkillStopDuringWindupCancelsLaterEffects),
            CastSkillStopDuringWindupCancelsLaterEffects);
        RunTest(nameof(CastSkillStopAfterActivationKeepsAppliedAndHonorsRefund),
            CastSkillStopAfterActivationKeepsAppliedAndHonorsRefund);
        RunTest(nameof(CastSkillWithoutInterruptKeepsDelayedEffectsAfterStop),
            CastSkillWithoutInterruptKeepsDelayedEffectsAfterStop);
        RunTest(nameof(CastSkillEmitEventWritesBattlefieldLog),
            CastSkillEmitEventWritesBattlefieldLog);
        RunTest(nameof(CastSkillIssueCommandUsesExistingMoveAndAttack),
            CastSkillIssueCommandUsesExistingMoveAndAttack);
        RunTest(nameof(CastSkillCreateObjectUsesExistingTemplate),
            CastSkillCreateObjectUsesExistingTemplate);
        RunTest(nameof(HudSlotsShowEquippedActiveSkillsAndCooldown),
            HudSlotsShowEquippedActiveSkillsAndCooldown);

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

    /// <summary>验证回基地姿态由权威仓储选择平面距离最近的己方已完成基地。</summary>
    private void ReturnToBaseSelectsNearestCompletedCommandCenter()
    {
        var owner = NewPlayerId();
        var unit = NewUnitId();
        var nearBase = NewUnitId();
        var farBase = NewUnitId();
        var movement = new FakeMovementPort();
        var orders = new InMemoryUnitOrderStore();
        var policies = new InMemoryCombatPolicyStore();
        var centers = new FakeCommandCenterRepository(
            new UnitCommandSnapshot(
                farBase,
                owner,
                false,
                EntityKind: BattlefieldEntityKind.Structure,
                TypeId: "command_center",
                Position: new WorldPosition(12, 0, 0)),
            new UnitCommandSnapshot(
                nearBase,
                owner,
                false,
                EntityKind: BattlefieldEntityKind.Structure,
                TypeId: "command_center",
                Position: new WorldPosition(3, 0, 4)));
        var service = NewService(
            new FakeRepository(new UnitCommandSnapshot(
                unit,
                owner,
                true,
                Position: new WorldPosition(0, 0, 0))),
            movement,
            orders: orders,
            policies: policies,
            commandCenters: centers);

        var result = service.SetEngagementStance(
            Context(owner),
            new SetEngagementStanceCommand([unit], EngagementStance.ReturnToBase));

        Check(result.Status == CommandStatus.Accepted, "有己方已完成基地时回基地姿态应被接受");
        Check(ResultFor(result, unit).Accepted, "可移动单位应接受回基地命令");
        Check(movement.ReturnToBaseRequests == 1, "回基地只应提交一次语义移动请求");
        Check(movement.LastCommandCenterId == nearBase, "回基地应选择平面距离最近的基地");
        Check(policies.Get(unit).EngagementStance == EngagementStance.ReturnToBase,
            "接受回基地后应保存 ReturnToBase 姿态");
        var order = orders.FindActive(unit);
        Check(order?.Kind == UnitOrderKind.ReturnToBase,
            "接受回基地后应创建 ReturnToBase 活动订单");
        Check(order?.Target is UnitOrderEntityTarget target &&
            target.EntityId.Kind == BattlefieldEntityKind.Structure &&
            target.EntityId.Value == nearBase.Value,
            "回基地订单应保留最近 CommandCenter 的稳定实体身份");
    }

    /// <summary>验证没有己方已完成基地时回基地命令拒绝且不替换现有订单。</summary>
    private void ReturnToBaseRejectsWithoutCommandCenter()
    {
        var owner = NewPlayerId();
        var unit = NewUnitId();
        var movement = new FakeMovementPort();
        var orders = new InMemoryUnitOrderStore();
        var policies = new InMemoryCombatPolicyStore();
        var service = NewService(
            new FakeRepository(new UnitCommandSnapshot(unit, owner, true)),
            movement,
            orders: orders,
            policies: policies,
            commandCenters: new FakeCommandCenterRepository());

        var result = service.SetEngagementStance(
            Context(owner),
            new SetEngagementStanceCommand([unit], EngagementStance.ReturnToBase));

        Check(result.Status == CommandStatus.Rejected, "没有己方基地时回基地姿态应拒绝");
        Check(ResultFor(result, unit).ErrorCode == CommandErrorCode.CommandCenterNotFound,
            "没有己方基地时应返回 CommandCenterNotFound");
        Check(movement.ReturnToBaseRequests == 0, "没有基地时不得调用回基地移动端口");
        Check(policies.Get(unit).EngagementStance == EngagementStance.Aggressive,
            "回基地拒绝不得篡改原有交战姿态");
        Check(orders.FindActive(unit) is null, "回基地拒绝不得创建活动订单");
    }

    /// <summary>验证统一 Stop 会暂停回基地订单，而不是把停止当作普通取消。</summary>
    private void StopSuspendsReturnToBaseOrder()
    {
        var owner = NewPlayerId();
        var unit = NewUnitId();
        var baseId = NewUnitId();
        var orders = new InMemoryUnitOrderStore();
        var service = NewService(
            new FakeRepository(new UnitCommandSnapshot(unit, owner, true)),
            new FakeMovementPort(),
            orders: orders,
            commandCenters: new FakeCommandCenterRepository(
                new UnitCommandSnapshot(
                    baseId,
                    owner,
                    false,
                    EntityKind: BattlefieldEntityKind.Structure,
                    TypeId: "command_center",
                    Position: new WorldPosition(5, 0, 0))));

        var returnResult = service.SetEngagementStance(
            Context(owner),
            new SetEngagementStanceCommand([unit], EngagementStance.ReturnToBase));
        var orderId = ResultFor(returnResult, unit).OrderId!.Value;
        var stopResult = service.Stop(Context(owner), new StopUnitsCommand([unit]));

        Check(stopResult.Status == CommandStatus.Accepted, "停止回基地单位应被接受");
        Check(orders.Find(orderId)?.State == UnitOrderState.Suspended,
            "统一 Stop 应暂停 ReturnToBase 订单并保留身份");
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
            ResourceChangeReason.SkillRefund,
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

    /// <summary>验证己方单位对自身主动技能返回 Accepted，且不创建订单。</summary>
    private void CastSkillAcceptsOwnedUnitOnSelfActiveSkill()
    {
        var owner = NewPlayerId();
        var unit = NewUnitId();
        var orders = new InMemoryUnitOrderStore();
        var service = NewService(
            new FakeRepository(new UnitCommandSnapshot(unit, owner, true)),
            orders: orders,
            catalog: SkillCatalog(SelfPulse()));

        var result = service.CastSkill(
            Context(owner),
            new CastSkillCommand([unit, unit], new SkillDefinitionId("demo_self_pulse")));

        Check(result.Status == CommandStatus.Accepted, "己方单位对自身主动技能应被接受");
        Check(result.UnitResults.Count == 1, "重复单位只应产生一个施放回执");
        Check(ResultFor(result, unit).Accepted && ResultFor(result, unit).OrderId is null,
            "本步施放成功只回执，不创建订单");
        Check(orders.FindActive(unit) is null, "施放入口不得留下活动技能订单");
    }

    /// <summary>验证缺失技能、被动技能和非自身目标在命令层整批拒绝。</summary>
    private void CastSkillRejectsMissingPassiveAndNonSelfSkills()
    {
        var owner = NewPlayerId();
        var unit = NewUnitId();
        var repository = new FakeRepository(new UnitCommandSnapshot(unit, owner, true));
        var missing = NewService(repository, catalog: SkillCatalog(SelfPulse()));
        var passive = NewService(
            repository,
            catalog: SkillCatalog(new SkillDefinition(
                new SkillDefinitionId("demo_passive"),
                SkillTriggerKind.Passive,
                SkillTargetKind.Self,
                [new SkillEffectDefinition(SkillEffectKind.DealDamage, 1.0f)],
                0)));
        var aimed = NewService(
            repository,
            catalog: SkillCatalog(new SkillDefinition(
                new SkillDefinitionId("demo_unit_pulse"),
                SkillTriggerKind.Active,
                SkillTargetKind.Unit,
                [new SkillEffectDefinition(SkillEffectKind.DealDamage, 1.0f)],
                0)));

        Check(ResultFor(missing.CastSkill(
                Context(owner),
                new CastSkillCommand([unit], new SkillDefinitionId("missing_skill"))), unit)
            .ErrorCode == CommandErrorCode.SkillNotFound,
            "不存在的技能应返回 SkillNotFound");
        Check(ResultFor(passive.CastSkill(
                Context(owner),
                new CastSkillCommand([unit], new SkillDefinitionId("demo_passive"))), unit)
            .ErrorCode == CommandErrorCode.SkillNotCastable,
            "被动技能不能从主动入口施放");
        Check(ResultFor(aimed.CastSkill(
                Context(owner),
                new CastSkillCommand([unit], new SkillDefinitionId("demo_unit_pulse"))), unit)
            .ErrorCode == CommandErrorCode.InvalidSkillTarget,
            "本步只接受自身目标技能");
        Check(NewService(repository).CastSkill(
                Context(owner),
                new CastSkillCommand([unit], new SkillDefinitionId("demo_self_pulse")))
            .Status == CommandStatus.Rejected,
            "没有 Catalog 时不得施放");
    }

    /// <summary>验证跨所有权部分接受，且成功施放不替换已有移动订单。</summary>
    private void CastSkillChecksOwnershipWithoutReplacingOrders()
    {
        var owner = NewPlayerId();
        var adversary = NewPlayerId();
        var owned = NewUnitId();
        var foreign = NewUnitId();
        var missing = NewUnitId();
        var orders = new InMemoryUnitOrderStore();
        var service = NewService(
            new FakeRepository(
                new UnitCommandSnapshot(owned, owner, true),
                new UnitCommandSnapshot(foreign, adversary, true)),
            orders: orders,
            catalog: SkillCatalog(SelfPulse()));

        service.Move(Context(owner), new MoveUnitsCommand([owned], new WorldPosition(1, 0, 1)));
        var moveOrder = orders.FindActive(owned);
        var result = service.CastSkill(
            Context(owner),
            new CastSkillCommand([owned, foreign, missing], new SkillDefinitionId("demo_self_pulse")));

        Check(result.Status == CommandStatus.PartiallyAccepted, "混选应部分接受技能施放");
        Check(ResultFor(result, owned).Accepted, "己方单位应接受自身施放");
        Check(ResultFor(result, foreign).ErrorCode == CommandErrorCode.UnitNotOwned,
            "他方单位应返回 UnitNotOwned");
        Check(ResultFor(result, missing).ErrorCode == CommandErrorCode.UnitNotFound,
            "失效单位应返回 UnitNotFound");
        Check(orders.FindActive(owned)?.OrderId == moveOrder?.OrderId,
            "技能入口本步不得替换已有订单");
    }

    /// <summary>验证自身伤害走弹头解析，并对友伤倍率生效。</summary>
    private void CastSkillDealDamageHitsSelfThroughWarheadResolver()
    {
        var owner = NewPlayerId();
        var unit = NewUnitId();
        var damage = new FakeDamagePort();
        var catalog = new FakeSkillCatalog(
            [SelfPulse()],
            new WarheadDefinition(
                new WarheadDefinitionId("direct_full_damage"),
                ImpactSelectionMode.IntendedTargetOnly,
                0.0f,
                0.5f));
        var service = NewService(
            new FakeRepository(new UnitCommandSnapshot(unit, owner, true)),
            catalog: catalog,
            damage: damage);

        var result = service.CastSkill(
            Context(owner),
            new CastSkillCommand([unit], new SkillDefinitionId("demo_self_pulse")));

        Check(result.Status == CommandStatus.Accepted, "自身伤害技能应被接受");
        Check(damage.Applications.Count == 1 &&
            damage.Applications[0].UnitId == unit &&
            damage.Applications[0].Damage == 0.5f,
            "自身伤害应等于基础伤害乘以友伤倍率");
    }

    /// <summary>验证指定单位受伤，不可伤害目标不产生伤害记录。</summary>
    private void CastSkillDealDamageHitsSpecifiedUnitAndSkipsUndamageable()
    {
        var owner = NewPlayerId();
        var enemyOwner = NewPlayerId();
        var caster = NewUnitId();
        var enemy = NewUnitId();
        var invulnerable = NewUnitId();
        var missing = NewUnitId();
        var pulse = new SkillDefinition(
            new SkillDefinitionId("demo_unit_pulse"),
            SkillTriggerKind.Active,
            SkillTargetKind.Unit,
            [new SkillEffectDefinition(SkillEffectKind.DealDamage, 2.0f)],
            0);
        var damage = new FakeDamagePort();
        var repository = new FakeRepository(
            new UnitCommandSnapshot(caster, owner, true),
            new UnitCommandSnapshot(enemy, enemyOwner, true),
            new UnitCommandSnapshot(invulnerable, enemyOwner, true, IsDamageable: false));
        var service = NewService(repository, catalog: SkillCatalog(pulse), damage: damage);

        var hit = service.CastSkill(
            Context(owner),
            new CastSkillCommand([caster], pulse.Id, enemy));
        var skipped = service.CastSkill(
            Context(owner),
            new CastSkillCommand([caster], pulse.Id, invulnerable));
        var absent = service.CastSkill(
            Context(owner),
            new CastSkillCommand([caster], pulse.Id, missing));

        Check(hit.Status == CommandStatus.Accepted, "指定存活单位应接受即时伤害");
        Check(skipped.Status == CommandStatus.Accepted, "不可伤害目标仍应接受命令");
        Check(absent.Status == CommandStatus.Rejected &&
            ResultFor(absent, caster).ErrorCode == CommandErrorCode.TargetNotFound,
            "指定目标不存在时应整批拒绝");
        Check(damage.Applications.Count == 1 &&
            damage.Applications[0].UnitId == enemy &&
            damage.Applications[0].Damage == 2.0f,
            "只有可伤害指定单位应扣 HP");
    }

    /// <summary>验证友军、超距和死亡目标按技能规则拒绝。</summary>
    private void CastSkillRejectsFriendOutOfRangeAndDeadTargets()
    {
        var owner = NewPlayerId();
        var enemyOwner = NewPlayerId();
        var caster = NewUnitId();
        var ally = NewUnitId();
        var farEnemy = NewUnitId();
        var nearEnemy = NewUnitId();
        var deadEnemy = NewUnitId();
        var pulse = new SkillDefinition(
            new SkillDefinitionId("demo_unit_pulse"),
            SkillTriggerKind.Active,
            SkillTargetKind.Unit,
            [new SkillEffectDefinition(SkillEffectKind.DealDamage, 2.0f)],
            0,
            SkillTargetRelation.Enemy,
            5.0f);
        var damage = new FakeDamagePort();
        var service = NewService(
            new FakeRepository(
                new UnitCommandSnapshot(caster, owner, true, Position: new WorldPosition(0, 0, 0)),
                new UnitCommandSnapshot(ally, owner, true, Position: new WorldPosition(1, 0, 0)),
                new UnitCommandSnapshot(
                    farEnemy, enemyOwner, true, Position: new WorldPosition(10, 0, 0)),
                new UnitCommandSnapshot(
                    nearEnemy, enemyOwner, true, Position: new WorldPosition(3, 0, 0)),
                new UnitCommandSnapshot(
                    deadEnemy,
                    enemyOwner,
                    true,
                    Position: new WorldPosition(1, 0, 0),
                    IsAlive: false)),
            catalog: SkillCatalog(pulse),
            damage: damage);

        Check(ResultFor(service.CastSkill(
                Context(owner), new CastSkillCommand([caster], pulse.Id, ally)), caster)
            .ErrorCode == CommandErrorCode.SkillTargetNotAllowed,
            "友军单位应被阵营规则拒绝");
        Check(ResultFor(service.CastSkill(
                Context(owner), new CastSkillCommand([caster], pulse.Id, farEnemy)), caster)
            .ErrorCode == CommandErrorCode.SkillOutOfRange,
            "超距敌军应被拒绝");
        Check(ResultFor(service.CastSkill(
                Context(owner), new CastSkillCommand([caster], pulse.Id, deadEnemy)), caster)
            .ErrorCode == CommandErrorCode.TargetNotFound,
            "死亡目标应视为不可选");
        var hit = service.CastSkill(
            Context(owner), new CastSkillCommand([caster], pulse.Id, nearEnemy));
        Check(hit.Status == CommandStatus.Accepted, "距离内敌军应接受");
        Check(damage.Applications.Single().UnitId == nearEnemy, "只有合法敌军应受伤");
    }

    /// <summary>验证地面技能在距离内记下坐标，超距或非法坐标被拒绝。</summary>
    private void CastSkillRecordsInRangeGroundTarget()
    {
        var owner = NewPlayerId();
        var caster = NewUnitId();
        var mark = new SkillDefinition(
            new SkillDefinitionId("demo_ground_mark"),
            SkillTriggerKind.Active,
            SkillTargetKind.Ground,
            [new SkillEffectDefinition(SkillEffectKind.EmitEvent, null)],
            0,
            SkillTargetRelation.Any,
            8.0f,
            false);
        var journal = new InMemorySkillCastJournal();
        var service = NewService(
            new FakeRepository(
                new UnitCommandSnapshot(caster, owner, true, Position: new WorldPosition(0, 0, 0))),
            catalog: SkillCatalog(mark),
            skillCasts: journal);
        var destination = new WorldPosition(4, 0, 2);

        var accepted = service.CastSkill(
            Context(owner),
            new CastSkillCommand([caster], mark.Id, TargetPosition: destination));
        var far = service.CastSkill(
            Context(owner),
            new CastSkillCommand([caster], mark.Id, TargetPosition: new WorldPosition(20, 0, 0)));
        var invalid = service.CastSkill(
            Context(owner),
            new CastSkillCommand([caster], mark.Id, TargetPosition: new WorldPosition(float.NaN, 0, 0)));

        Check(accepted.Status == CommandStatus.Accepted, "距离内地面目标应接受");
        Check(journal.Records.Count == 1 &&
            journal.Records[0].TargetPosition == destination &&
            journal.Records[0].TargetUnitId is null,
            "地面技能应记下确认坐标");
        Check(ResultFor(far, caster).ErrorCode == CommandErrorCode.SkillOutOfRange,
            "超距地面目标应被拒绝");
        Check(invalid.Status == CommandStatus.Rejected &&
            ResultFor(invalid, caster).ErrorCode == CommandErrorCode.InvalidDestination,
            "非有限地面坐标应被拒绝");
    }

    /// <summary>验证正式生效时扣费并按模拟毫秒进入冷却；时刻不前进则冷却不结束。</summary>
    private void CastSkillPaysCostThenStartsCooldownOnSimulationClock()
    {
        var owner = NewPlayerId();
        var match = new MatchId(Guid.NewGuid());
        var unit = NewUnitId();
        var accounts = OpenAccount(owner, match, 2, 0);
        var cooldowns = new InMemorySkillCooldownStore();
        var skill = new SkillDefinition(
            new SkillDefinitionId("paid_pulse"),
            SkillTriggerKind.Active,
            SkillTargetKind.Self,
            [new SkillEffectDefinition(SkillEffectKind.DealDamage, 1.0f)],
            3000) with
        {
            Cost = [new ResourceAmount(ResourceKind.A, 1)]
        };
        var service = NewService(
            new FakeRepository(new UnitCommandSnapshot(unit, owner, true)),
            catalog: SkillCatalog(skill),
            accounts: accounts,
            cooldowns: cooldowns);

        var first = service.CastSkill(Context(owner, match, 0), new CastSkillCommand([unit], skill.Id));
        Check(first.Status == CommandStatus.Accepted, "首次生效应扣费并开始冷却");
        Check(accounts.Find(owner)?.GetBalance(ResourceKind.A) == 1,
            $"首次生效应扣除 1 个 A；实际 {accounts.Find(owner)?.GetBalance(ResourceKind.A)}");

        var paused = service.CastSkill(Context(owner, match, 0), new CastSkillCommand([unit], skill.Id));
        Check(ResultFor(paused, unit).ErrorCode == CommandErrorCode.SkillOnCooldown,
            $"模拟时刻不前进时冷却不得结束；实际 {ResultFor(paused, unit).ErrorCode}");
        var almost = service.CastSkill(
            Context(owner, match, 2999), new CastSkillCommand([unit], skill.Id));
        Check(ResultFor(almost, unit).ErrorCode == CommandErrorCode.SkillOnCooldown,
            "冷却结束前不得再次生效");
        Check(accounts.Find(owner)?.GetBalance(ResourceKind.A) == 1,
            "冷却拒绝不得再次扣费");

        var ready = service.CastSkill(
            Context(owner, match, 3000), new CastSkillCommand([unit], skill.Id));
        Check(ready.Status == CommandStatus.Accepted, "冷却结束后应再次接受");
        Check(accounts.Find(owner)?.GetBalance(ResourceKind.A) == 0, "第二次生效应再扣 1 个 A");
    }

    /// <summary>验证资源不足时整笔拒绝，且不会进入冷却。</summary>
    private void CastSkillRejectsInsufficientResourcesWithoutStartingCooldown()
    {
        var owner = NewPlayerId();
        var match = new MatchId(Guid.NewGuid());
        var unit = NewUnitId();
        var accounts = OpenAccount(owner, match, 0, 0);
        var cooldowns = new InMemorySkillCooldownStore();
        var skill = new SkillDefinition(
            new SkillDefinitionId("paid_pulse"),
            SkillTriggerKind.Active,
            SkillTargetKind.Self,
            [new SkillEffectDefinition(SkillEffectKind.DealDamage, 1.0f)],
            3000) with
        {
            Cost = [new ResourceAmount(ResourceKind.A, 1)]
        };
        var service = NewService(
            new FakeRepository(new UnitCommandSnapshot(unit, owner, true)),
            catalog: SkillCatalog(skill),
            accounts: accounts,
            cooldowns: cooldowns);

        var rejected = service.CastSkill(
            Context(owner, match, 0), new CastSkillCommand([unit], skill.Id));
        accounts.Apply(new ApplyResourceTransaction(
            NewResourceTransactionId(),
            match,
            owner,
            [new ResourceDelta(ResourceKind.A, 1)],
            ResourceChangeReason.ScriptedAdjustment,
            null,
            1));
        var funded = service.CastSkill(
            Context(owner, match, 0), new CastSkillCommand([unit], skill.Id));

        Check(ResultFor(rejected, unit).ErrorCode == CommandErrorCode.InsufficientResources,
            "余额不足应拒绝技能生效");
        Check(funded.Status == CommandStatus.Accepted,
            "未成功生效时不得留下冷却");
        Check(accounts.Find(owner)?.GetBalance(ResourceKind.A) == 0,
            "补足资源后的首次生效应扣费");
    }

    /// <summary>验证第二段效果在延迟到达后才发生，模拟时刻不变则不触发。</summary>
    private void CastSkillSecondEffectWaitsForSimulationDelay()
    {
        var owner = NewPlayerId();
        var unit = NewUnitId();
        var damage = new FakeDamagePort();
        var skill = new SkillDefinition(
            new SkillDefinitionId("demo_delayed_pulse"),
            SkillTriggerKind.Active,
            SkillTargetKind.Self,
            [
                new SkillEffectDefinition(SkillEffectKind.DealDamage, 1.0f),
                new SkillEffectDefinition(SkillEffectKind.DealDamage, 1.0f, 1000)
            ],
            0);
        var service = NewService(
            new FakeRepository(new UnitCommandSnapshot(unit, owner, true)),
            catalog: SkillCatalog(skill),
            damage: damage);

        var cast = service.CastSkill(Context(owner, new MatchId(Guid.NewGuid()), 0),
            new CastSkillCommand([unit], skill.Id));
        Check(cast.Status == CommandStatus.Accepted, "延迟序列技能应被接受");
        Check(damage.Applications.Count == 1 && damage.Applications[0].Damage == 1.0f,
            "第一段应在正式生效时立即结算");

        service.AdvanceSkillEffects(0);
        service.AdvanceSkillEffects(999);
        Check(damage.Applications.Count == 1, "模拟时刻未到延迟终点时第二段不得发生");

        service.AdvanceSkillEffects(1000);
        Check(damage.Applications.Count == 2 && damage.Applications[1].Damage == 1.0f,
            "延迟到达后应结算第二段");
    }

    /// <summary>验证治疗只作用于存活受伤单位，且恢复量不超过缺失生命。</summary>
    private void CastSkillRestoreHealthClampsToMaximum()
    {
        var owner = NewPlayerId();
        var wounded = NewUnitId();
        var full = NewUnitId();
        var dead = NewUnitId();
        var heal = new SkillDefinition(
            new SkillDefinitionId("demo_self_heal"),
            SkillTriggerKind.Active,
            SkillTargetKind.Self,
            [new SkillEffectDefinition(SkillEffectKind.RestoreHealth, 3.0f)],
            0);
        var damage = new FakeDamagePort();
        var woundedService = NewService(
            new FakeRepository(new UnitCommandSnapshot(
                wounded, owner, true, CurrentHealth: 4.0f, MaximumHealth: 10.0f)),
            catalog: SkillCatalog(heal),
            damage: damage);
        var fullService = NewService(
            new FakeRepository(new UnitCommandSnapshot(
                full, owner, true, CurrentHealth: 10.0f, MaximumHealth: 10.0f)),
            catalog: SkillCatalog(heal),
            damage: damage);
        var deadService = NewService(
            new FakeRepository(new UnitCommandSnapshot(
                dead, owner, true, IsAlive: false, CurrentHealth: 0.0f, MaximumHealth: 10.0f)),
            catalog: SkillCatalog(heal),
            damage: damage);

        Check(woundedService.CastSkill(
                Context(owner), new CastSkillCommand([wounded], heal.Id)).Status ==
            CommandStatus.Accepted,
            "受伤单位的治疗应被接受");
        Check(fullService.CastSkill(
                Context(owner), new CastSkillCommand([full], heal.Id)).Status ==
            CommandStatus.Accepted,
            "满血单位的治疗命令仍应接受");
        Check(deadService.CastSkill(
                Context(owner), new CastSkillCommand([dead], heal.Id)).Status ==
            CommandStatus.Accepted,
            "死亡单位的治疗命令仍应接受但不应回血");
        Check(damage.Restores.Count == 1 &&
            damage.Restores[0].UnitId == wounded &&
            damage.Restores[0].Amount == 3.0f,
            "只有受伤存活单位应恢复，且不超过缺失生命");

        var overflow = new FakeDamagePort();
        var overflowHeal = new SkillDefinition(
            new SkillDefinitionId("big_heal"),
            SkillTriggerKind.Active,
            SkillTargetKind.Self,
            [new SkillEffectDefinition(SkillEffectKind.RestoreHealth, 20.0f)],
            0);
        NewService(
            new FakeRepository(new UnitCommandSnapshot(
                wounded, owner, true, CurrentHealth: 8.0f, MaximumHealth: 10.0f)),
            catalog: SkillCatalog(overflowHeal),
            damage: overflow).CastSkill(
            Context(owner), new CastSkillCommand([wounded], overflowHeal.Id));
        Check(overflow.Restores.Single().Amount == 2.0f, "过量治疗应被钳制到生命上限");
    }

    /// <summary>验证移速状态立即生效，未到期保持，到期后恢复基线。</summary>
    private void CastSkillStatusAppliesAndExpiresMoveSpeed()
    {
        var owner = NewPlayerId();
        var unit = NewUnitId();
        var speed = new FakeMoveSpeedPort();
        var service = NewService(
            new FakeRepository(new UnitCommandSnapshot(unit, owner, true, IsAlive: true)),
            catalog: SkillCatalog(SelfSlow()),
            moveSpeed: speed);

        Check(service.CastSkill(Context(owner), new CastSkillCommand([unit], SelfSlow().Id)).Status ==
            CommandStatus.Accepted,
            "自身减速应被接受");
        Check(speed.MultiplierOf(unit) == 0.5f, "施加后移速应为基线的一半");

        service.AdvanceSkillEffects(2999);
        Check(speed.MultiplierOf(unit) == 0.5f && speed.Clears.Count == 0,
            "未到期前不应恢复移速");

        service.AdvanceSkillEffects(3000);
        Check(speed.Clears.Contains(unit) && speed.MultiplierOf(unit) == 1.0f,
            "到期后应清除移速修正");
    }

    /// <summary>验证 refresh 只延时、overwrite 换修正、ignore 忽略再施加。</summary>
    private void CastSkillStatusStackRulesRefreshOverwriteIgnore()
    {
        var owner = NewPlayerId();
        var unit = NewUnitId();
        var refreshSpeed = new FakeMoveSpeedPort();
        var refresh = SelfSlow(SkillStackRule.Refresh, 0.5f, 1000);
        var refreshService = NewService(
            new FakeRepository(new UnitCommandSnapshot(unit, owner, true, IsAlive: true)),
            catalog: SkillCatalog(refresh),
            moveSpeed: refreshSpeed);
        refreshService.CastSkill(Context(owner, new MatchId(Guid.NewGuid()), 0),
            new CastSkillCommand([unit], refresh.Id));
        refreshService.CastSkill(Context(owner, new MatchId(Guid.NewGuid()), 500),
            new CastSkillCommand([unit], refresh.Id));
        refreshService.AdvanceSkillEffects(1000);
        Check(refreshSpeed.MultiplierOf(unit) == 0.5f && refreshSpeed.Clears.Count == 0,
            "refresh 应把到期从 1000 延到 1500");
        refreshService.AdvanceSkillEffects(1500);
        Check(refreshSpeed.Clears.Contains(unit), "refresh 后应在新到期时刻清除");

        var overwriteSpeed = new FakeMoveSpeedPort();
        var first = SelfSlow(SkillStackRule.Overwrite, 0.5f, 1000, "ow_slow");
        var second = new SkillDefinition(
            new SkillDefinitionId("demo_self_slow_hard"),
            SkillTriggerKind.Active,
            SkillTargetKind.Self,
            [new SkillEffectDefinition(
                SkillEffectKind.AddStatus,
                null,
                0,
                new SkillStatusDefinition(
                    "ow_slow", 1000, SkillAttributeKind.MoveSpeed, 0.25f, SkillStackRule.Overwrite))],
            0);
        var overwriteService = NewService(
            new FakeRepository(new UnitCommandSnapshot(unit, owner, true, IsAlive: true)),
            catalog: SkillCatalog(first, second),
            moveSpeed: overwriteSpeed);
        overwriteService.CastSkill(Context(owner), new CastSkillCommand([unit], first.Id));
        overwriteService.CastSkill(Context(owner), new CastSkillCommand([unit], second.Id));
        Check(overwriteSpeed.MultiplierOf(unit) == 0.25f, "overwrite 应用新的移速倍率");

        var ignoreSpeed = new FakeMoveSpeedPort();
        var ignore = SelfSlow(SkillStackRule.Ignore, 0.5f, 1000, "ig_slow");
        var ignoreHarder = new SkillDefinition(
            new SkillDefinitionId("demo_self_slow_ignored"),
            SkillTriggerKind.Active,
            SkillTargetKind.Self,
            [new SkillEffectDefinition(
                SkillEffectKind.AddStatus,
                null,
                0,
                new SkillStatusDefinition(
                    "ig_slow", 1000, SkillAttributeKind.MoveSpeed, 0.25f, SkillStackRule.Ignore))],
            0);
        var ignoreService = NewService(
            new FakeRepository(new UnitCommandSnapshot(unit, owner, true, IsAlive: true)),
            catalog: SkillCatalog(ignore, ignoreHarder),
            moveSpeed: ignoreSpeed);
        ignoreService.CastSkill(Context(owner, new MatchId(Guid.NewGuid()), 0),
            new CastSkillCommand([unit], ignore.Id));
        ignoreService.CastSkill(Context(owner, new MatchId(Guid.NewGuid()), 500),
            new CastSkillCommand([unit], ignoreHarder.Id));
        Check(ignoreSpeed.MultiplierOf(unit) == 0.5f, "ignore 不应改已有修正");
        ignoreService.AdvanceSkillEffects(1000);
        Check(ignoreSpeed.Clears.Contains(unit), "ignore 第二次施加后仍按首次到期");
    }

    /// <summary>验证死亡单位不施加移速状态。</summary>
    private void CastSkillStatusIgnoresDeadTarget()
    {
        var owner = NewPlayerId();
        var unit = NewUnitId();
        var speed = new FakeMoveSpeedPort();
        var service = NewService(
            new FakeRepository(new UnitCommandSnapshot(
                unit, owner, true, IsAlive: false)),
            catalog: SkillCatalog(SelfSlow()),
            moveSpeed: speed);

        Check(service.CastSkill(Context(owner), new CastSkillCommand([unit], SelfSlow().Id)).Status ==
            CommandStatus.Accepted,
            "对死亡单位的自身状态命令仍应接受");
        Check(speed.Applications.Count == 0, "死亡单位不应施加移速状态");
    }

    /// <summary>验证同时组合在同一模拟毫秒结算伤害和治疗。</summary>
    private void CastSkillSimultaneousDamageAndHeal()
    {
        var owner = NewPlayerId();
        var unit = NewUnitId();
        var damage = new FakeDamagePort();
        var skill = new SkillDefinition(
            new SkillDefinitionId("demo_self_burst"),
            SkillTriggerKind.Active,
            SkillTargetKind.Self,
            [
                new SkillEffectDefinition(SkillEffectKind.DealDamage, 1.0f),
                new SkillEffectDefinition(
                    SkillEffectKind.RestoreHealth,
                    1.0f,
                    0,
                    null,
                    SkillEffectTiming.Simultaneous)
            ],
            0);
        var service = NewService(
            new FakeRepository(new UnitCommandSnapshot(
                unit, owner, true, CurrentHealth: 5.0f, MaximumHealth: 10.0f)),
            catalog: SkillCatalog(skill),
            damage: damage);

        Check(service.CastSkill(Context(owner), new CastSkillCommand([unit], skill.Id)).Status ==
            CommandStatus.Accepted,
            "同时伤害加治疗应被接受");
        Check(damage.Applications.Count == 1 && damage.Restores.Count == 1,
            "正式生效时应同时结算一段伤害和一段治疗");
        service.AdvanceSkillEffects(1000);
        Check(damage.Applications.Count == 1 && damage.Restores.Count == 1,
            "同时组合不应再产生后续段");
    }

    /// <summary>验证周期伤害按模拟毫秒跳字，时刻不变则不再跳。</summary>
    private void CastSkillPeriodicTicksUseSimulationClock()
    {
        var owner = NewPlayerId();
        var unit = NewUnitId();
        var damage = new FakeDamagePort();
        var skill = new SkillDefinition(
            new SkillDefinitionId("demo_self_ticks"),
            SkillTriggerKind.Active,
            SkillTargetKind.Self,
            [
                new SkillEffectDefinition(
                    SkillEffectKind.DealDamage,
                    1.0f,
                    0,
                    null,
                    SkillEffectTiming.AfterPrevious,
                    1000,
                    3)
            ],
            0);
        var service = NewService(
            new FakeRepository(new UnitCommandSnapshot(unit, owner, true)),
            catalog: SkillCatalog(skill),
            damage: damage);

        service.CastSkill(Context(owner, new MatchId(Guid.NewGuid()), 0),
            new CastSkillCommand([unit], skill.Id));
        Check(damage.Applications.Count == 1, "周期首次应在正式生效时结算");
        service.AdvanceSkillEffects(0);
        service.AdvanceSkillEffects(999);
        Check(damage.Applications.Count == 1, "周期间隔未到时不得跳第二次");
        service.AdvanceSkillEffects(1000);
        Check(damage.Applications.Count == 2, "第一周期到达后应跳第二次");
        service.AdvanceSkillEffects(2000);
        Check(damage.Applications.Count == 3 && damage.Applications.TrueForAll(item => item.Damage == 1.0f),
            "三跳结束后不得继续");
        service.AdvanceSkillEffects(3000);
        Check(damage.Applications.Count == 3, "超过重复次数后不得再跳");
    }

    /// <summary>验证条件不满足时跳过效果，命令仍接受。</summary>
    private void CastSkillConditionSkipsWhenNotWounded()
    {
        var owner = NewPlayerId();
        var wounded = NewUnitId();
        var full = NewUnitId();
        var dead = NewUnitId();
        var skill = new SkillDefinition(
            new SkillDefinitionId("demo_self_heal_if_wounded"),
            SkillTriggerKind.Active,
            SkillTargetKind.Self,
            [
                new SkillEffectDefinition(
                    SkillEffectKind.RestoreHealth,
                    3.0f,
                    Condition: SkillEffectCondition.TargetWounded)
            ],
            0);
        var damage = new FakeDamagePort();
        var woundedService = NewService(
            new FakeRepository(new UnitCommandSnapshot(
                wounded, owner, true, CurrentHealth: 4.0f, MaximumHealth: 10.0f)),
            catalog: SkillCatalog(skill),
            damage: damage);
        var fullService = NewService(
            new FakeRepository(new UnitCommandSnapshot(
                full, owner, true, CurrentHealth: 10.0f, MaximumHealth: 10.0f)),
            catalog: SkillCatalog(skill),
            damage: damage);
        var deadService = NewService(
            new FakeRepository(new UnitCommandSnapshot(
                dead, owner, true, IsAlive: false, CurrentHealth: 0.0f, MaximumHealth: 10.0f)),
            catalog: SkillCatalog(skill),
            damage: damage);

        Check(woundedService.CastSkill(
                Context(owner), new CastSkillCommand([wounded], skill.Id)).Status ==
            CommandStatus.Accepted,
            "受伤单位的条件治疗应被接受");
        Check(fullService.CastSkill(
                Context(owner), new CastSkillCommand([full], skill.Id)).Status ==
            CommandStatus.Accepted,
            "满血时条件不满足仍应接受命令");
        Check(deadService.CastSkill(
                Context(owner), new CastSkillCommand([dead], skill.Id)).Status ==
            CommandStatus.Accepted,
            "死亡时条件不满足仍应接受命令");
        Check(damage.Restores.Count == 1 &&
            damage.Restores[0].UnitId == wounded &&
            damage.Restores[0].Amount == 3.0f,
            "只有受伤存活单位应恢复生命");
    }

    /// <summary>验证同时段之后的顺序延迟仍从上一条首次时刻起算。</summary>
    private void CastSkillSequentialAfterSimultaneousKeepsDelay()
    {
        var owner = NewPlayerId();
        var unit = NewUnitId();
        var damage = new FakeDamagePort();
        var skill = new SkillDefinition(
            new SkillDefinitionId("burst_then_pulse"),
            SkillTriggerKind.Active,
            SkillTargetKind.Self,
            [
                new SkillEffectDefinition(SkillEffectKind.DealDamage, 1.0f),
                new SkillEffectDefinition(
                    SkillEffectKind.RestoreHealth,
                    1.0f,
                    0,
                    null,
                    SkillEffectTiming.Simultaneous),
                new SkillEffectDefinition(SkillEffectKind.DealDamage, 2.0f, 500)
            ],
            0);
        var service = NewService(
            new FakeRepository(new UnitCommandSnapshot(
                unit, owner, true, CurrentHealth: 5.0f, MaximumHealth: 10.0f)),
            catalog: SkillCatalog(skill),
            damage: damage);

        service.CastSkill(Context(owner, new MatchId(Guid.NewGuid()), 0),
            new CastSkillCommand([unit], skill.Id));
        Check(damage.Applications.Count == 1 && damage.Restores.Count == 1,
            "同时段应立刻结算");
        service.AdvanceSkillEffects(499);
        Check(damage.Applications.Count == 1, "后续顺序段在延迟前不得发生");
        service.AdvanceSkillEffects(500);
        Check(damage.Applications.Count == 2 && damage.Applications[1].Damage == 2.0f,
            "后续顺序段应从同时段的时刻再等延迟");
    }

    /// <summary>验证事件技能不能主动点放，受伤后自动治疗，冷却按模拟时钟。</summary>
    private void AutomaticEventSkillHealsOnDamageWithoutPlayerCast()
    {
        var owner = NewPlayerId();
        var match = new MatchId(Guid.NewGuid());
        var tank = NewUnitId();
        var other = NewUnitId();
        var skill = new SkillDefinition(
            new SkillDefinitionId("demo_on_damage_heal"),
            SkillTriggerKind.Event,
            SkillTargetKind.Self,
            [new SkillEffectDefinition(SkillEffectKind.RestoreHealth, 1.0f)],
            2000,
            EquippedUnitTypeIds: [new UnitTypeId("tank")],
            TriggerEvent: SkillTriggerEvent.UnitDamaged);
        var damage = new FakeDamagePort();
        var granted = NewService(
            new FakeRepository(new UnitCommandSnapshot(
                tank, owner, true, CurrentHealth: 4.0f, MaximumHealth: 10.0f)),
            catalog: SkillCatalog(skill),
            damage: damage,
            cooldowns: new InMemorySkillCooldownStore());
        Check(granted.CastSkill(Context(owner, match, 0), new CastSkillCommand([tank], skill.Id))
            .UnitResults[0].ErrorCode == CommandErrorCode.SkillNotCastable,
            "事件技能不得从主动入口施放");
        granted.GrantSkill(tank, skill.Id);
        granted.NotifyUnitDamaged(match, tank, 0);
        granted.NotifyUnitDamaged(match, tank, 0);
        Check(damage.Restores.Count == 1 && damage.Restores[0].Amount == 1.0f,
            "受伤应自动治疗一次，冷却中不得再触发");
        granted.NotifyUnitDamaged(match, tank, 2000);
        Check(damage.Restores.Count == 2, "冷却结束后再次受伤应再治疗");

        var equipped = NewService(
            new FakeRepository(
                new UnitCommandSnapshot(
                    tank, owner, true, TypeId: "tank", CurrentHealth: 4.0f, MaximumHealth: 10.0f),
                new UnitCommandSnapshot(
                    other, owner, true, TypeId: "helicopter", CurrentHealth: 4.0f, MaximumHealth: 10.0f)),
            catalog: SkillCatalog(skill),
            damage: damage,
            cooldowns: new InMemorySkillCooldownStore());
        equipped.EquipAutomaticSkills(tank);
        equipped.EquipAutomaticSkills(other);
        equipped.NotifyUnitDamaged(match, tank, 0);
        equipped.NotifyUnitDamaged(match, other, 0);
        Check(damage.Restores.Count == 3 && damage.Restores[2].UnitId == tank,
            "只有装配了该技能的坦克类型应自动治疗");
    }

    /// <summary>验证条件触发看受伤状态，被动装配后自动上状态。</summary>
    private void AutomaticConditionAndPassiveSkillsEvaluateOnClock()
    {
        var owner = NewPlayerId();
        var match = new MatchId(Guid.NewGuid());
        var wounded = NewUnitId();
        var full = NewUnitId();
        var regen = new SkillDefinition(
            new SkillDefinitionId("demo_wounded_regen"),
            SkillTriggerKind.Condition,
            SkillTargetKind.Self,
            [new SkillEffectDefinition(SkillEffectKind.RestoreHealth, 1.0f)],
            3000,
            ActivationCondition: SkillEffectCondition.TargetWounded);
        var healPort = new FakeDamagePort();
        var woundedService = NewService(
            new FakeRepository(new UnitCommandSnapshot(
                wounded, owner, true, CurrentHealth: 5.0f, MaximumHealth: 10.0f)),
            catalog: SkillCatalog(regen),
            damage: healPort,
            cooldowns: new InMemorySkillCooldownStore());
        var fullService = NewService(
            new FakeRepository(new UnitCommandSnapshot(
                full, owner, true, CurrentHealth: 10.0f, MaximumHealth: 10.0f)),
            catalog: SkillCatalog(regen),
            damage: healPort,
            cooldowns: new InMemorySkillCooldownStore());
        woundedService.GrantSkill(wounded, regen.Id);
        fullService.GrantSkill(full, regen.Id);
        woundedService.EvaluateAutomaticSkills(match, 0);
        woundedService.EvaluateAutomaticSkills(match, 0);
        fullService.EvaluateAutomaticSkills(match, 0);
        Check(healPort.Restores.Count == 1 && healPort.Restores[0].UnitId == wounded,
            "只有受伤且已授予的单位应条件回春");
        woundedService.EvaluateAutomaticSkills(match, 3000);
        Check(healPort.Restores.Count == 2, "冷却结束后受伤条件仍成立应再治疗");

        var mover = NewUnitId();
        var slow = new SkillDefinition(
            new SkillDefinitionId("demo_passive_slow"),
            SkillTriggerKind.Passive,
            SkillTargetKind.Self,
            [new SkillEffectDefinition(
                SkillEffectKind.AddStatus,
                null,
                0,
                new SkillStatusDefinition(
                    "demo_passive_slow",
                    1500,
                    SkillAttributeKind.MoveSpeed,
                    0.75f,
                    SkillStackRule.Refresh))],
            1000);
        var speed = new FakeMoveSpeedPort();
        var passive = NewService(
            new FakeRepository(new UnitCommandSnapshot(mover, owner, true, IsAlive: true)),
            catalog: SkillCatalog(slow),
            moveSpeed: speed);
        Check(passive.CastSkill(Context(owner, match, 0), new CastSkillCommand([mover], slow.Id))
            .UnitResults[0].ErrorCode == CommandErrorCode.SkillNotCastable,
            "被动技能不得从主动入口施放");
        passive.GrantSkill(mover, slow.Id);
        passive.EvaluateAutomaticSkills(match, 0);
        Check(speed.MultiplierOf(mover) == 0.75f, "被动装配后应立即改移速");
    }

    /// <summary>验证施放前被停止则不扣费、不进冷却、后续效果不发生。</summary>
    private void CastSkillStopDuringWindupCancelsLaterEffects()
    {
        var owner = NewPlayerId();
        var match = new MatchId(Guid.NewGuid());
        var unit = NewUnitId();
        var damage = new FakeDamagePort();
        var accounts = OpenAccount(owner, match, 1, 0);
        var cooldowns = new InMemorySkillCooldownStore();
        var skill = WindupPulse(refund: false, keepCooldown: true);
        var service = NewService(
            new FakeRepository(new UnitCommandSnapshot(unit, owner, true)),
            catalog: SkillCatalog(skill),
            damage: damage,
            accounts: accounts,
            cooldowns: cooldowns);

        Check(service.CastSkill(Context(owner, match, 0), new CastSkillCommand([unit], skill.Id)).Status ==
            CommandStatus.Accepted,
            "引导技能应先被接受");
        Check(accounts.Find(owner)?.GetBalance(ResourceKind.A) == 1, "施放前等待不得扣费");
        Check(service.CastSkill(Context(owner, match, 0), new CastSkillCommand([unit], skill.Id))
            .UnitResults[0].ErrorCode == CommandErrorCode.SkillBusy,
            "引导中不得再开始一条技能");

        service.Stop(Context(owner, match, 500), new StopUnitsCommand([unit]));
        service.AdvanceSkillEffects(2000);
        Check(damage.Applications.Count == 0, "施放前停止后不得结算任何效果");
        Check(accounts.Find(owner)?.GetBalance(ResourceKind.A) == 1, "施放前停止不得扣费");
        Check(cooldowns.IsReady(unit, skill.Id, 500), "施放前停止不得进入冷却");
    }

    /// <summary>验证正式生效后中断不回滚已结算效果，并按配置退费清冷却。</summary>
    private void CastSkillStopAfterActivationKeepsAppliedAndHonorsRefund()
    {
        var owner = NewPlayerId();
        var match = new MatchId(Guid.NewGuid());
        var unit = NewUnitId();
        var damage = new FakeDamagePort();
        var accounts = OpenAccount(owner, match, 1, 0);
        var cooldowns = new InMemorySkillCooldownStore();
        var skill = WindupPulse(refund: true, keepCooldown: false);
        var service = NewService(
            new FakeRepository(new UnitCommandSnapshot(unit, owner, true)),
            catalog: SkillCatalog(skill),
            damage: damage,
            accounts: accounts,
            cooldowns: cooldowns);

        service.CastSkill(Context(owner, match, 0), new CastSkillCommand([unit], skill.Id));
        service.AdvanceSkillEffects(1000);
        Check(damage.Applications.Count == 1 && accounts.Find(owner)?.GetBalance(ResourceKind.A) == 0,
            "正式生效时应扣费并结算第一段");
        Check(!cooldowns.IsReady(unit, skill.Id, 1000), "正式生效应进入冷却");

        service.Stop(Context(owner, match, 1500), new StopUnitsCommand([unit]));
        service.AdvanceSkillEffects(2000);
        Check(damage.Applications.Count == 1, "中断不得回滚已生效伤害，也不得再结算后续段");
        Check(accounts.Find(owner)?.GetBalance(ResourceKind.A) == 1, "配置退费时应退还消耗");
        Check(cooldowns.IsReady(unit, skill.Id, 1500), "配置不留冷却时应立即就绪");
    }

    /// <summary>验证未声明中断的技能在停止后仍会打出延迟段。</summary>
    private void CastSkillWithoutInterruptKeepsDelayedEffectsAfterStop()
    {
        var owner = NewPlayerId();
        var unit = NewUnitId();
        var damage = new FakeDamagePort();
        var skill = new SkillDefinition(
            new SkillDefinitionId("demo_delayed_pulse"),
            SkillTriggerKind.Active,
            SkillTargetKind.Self,
            [
                new SkillEffectDefinition(SkillEffectKind.DealDamage, 1.0f),
                new SkillEffectDefinition(SkillEffectKind.DealDamage, 1.0f, 1000)
            ],
            0);
        var service = NewService(
            new FakeRepository(new UnitCommandSnapshot(unit, owner, true)),
            catalog: SkillCatalog(skill),
            damage: damage);

        service.CastSkill(Context(owner, new MatchId(Guid.NewGuid()), 0),
            new CastSkillCommand([unit], skill.Id));
        service.Stop(Context(owner), new StopUnitsCommand([unit]));
        service.AdvanceSkillEffects(1000);
        Check(damage.Applications.Count == 2, "未配置中断时停止不得取消延迟段");
    }

    /// <summary>验证触发事件写入统一战场日志，不另建事件体系。</summary>
    private void CastSkillEmitEventWritesBattlefieldLog()
    {
        var owner = NewPlayerId();
        var caster = NewUnitId();
        var events = new BattlefieldEventLog();
        var mark = new SkillDefinition(
            new SkillDefinitionId("demo_ground_mark"),
            SkillTriggerKind.Active,
            SkillTargetKind.Ground,
            [new SkillEffectDefinition(
                SkillEffectKind.EmitEvent,
                null,
                EmittedEvent: BattlefieldEventKind.SkillEmitted)],
            0,
            SkillTargetRelation.Any,
            8.0f,
            false);
        var service = NewService(
            new FakeRepository(
                new UnitCommandSnapshot(caster, owner, true, Position: new WorldPosition(0, 0, 0))),
            catalog: SkillCatalog(mark),
            battlefieldEvents: events);
        var destination = new WorldPosition(4, 0, 2);

        Check(service.CastSkill(
                Context(owner),
                new CastSkillCommand([caster], mark.Id, TargetPosition: destination)).Status ==
            CommandStatus.Accepted,
            "地面标记应被接受");
        Check(events.Count == 1 &&
            events.FindLatestImportant() is null,
            "技能事件默认不应抢 Space 跳转");
    }

    /// <summary>验证下达命令走已有 Move/Attack，不新建命令种类。</summary>
    private void CastSkillIssueCommandUsesExistingMoveAndAttack()
    {
        var owner = NewPlayerId();
        var enemyOwner = NewPlayerId();
        var caster = NewUnitId();
        var enemy = NewUnitId();
        var movement = new FakeMovementPort();
        var attack = new FakeAttackPort();
        var dash = new SkillDefinition(
            new SkillDefinitionId("demo_issue_move"),
            SkillTriggerKind.Active,
            SkillTargetKind.Ground,
            [new SkillEffectDefinition(
                SkillEffectKind.IssueCommand,
                null,
                IssuedCommand: SkillIssuedCommandKind.Move)],
            0,
            SkillTargetRelation.Any,
            8.0f,
            false);
        var strike = new SkillDefinition(
            new SkillDefinitionId("demo_issue_attack"),
            SkillTriggerKind.Active,
            SkillTargetKind.Unit,
            [new SkillEffectDefinition(
                SkillEffectKind.IssueCommand,
                null,
                IssuedCommand: SkillIssuedCommandKind.Attack)],
            0,
            SkillTargetRelation.Enemy,
            5.0f);
        var moveService = NewService(
            new FakeRepository(
                new UnitCommandSnapshot(caster, owner, true, Position: new WorldPosition(0, 0, 0))),
            movement,
            catalog: SkillCatalog(dash));
        var destination = new WorldPosition(3, 0, 1);
        Check(moveService.CastSkill(
                Context(owner),
                new CastSkillCommand([caster], dash.Id, TargetPosition: destination)).Status ==
            CommandStatus.Accepted,
            "下达移动应被接受");
        Check(movement.MoveRequests == 1 && movement.LastDestination == destination,
            "下达移动应调用已有 Move 入口");

        var domains = new HashSet<CombatDomain> { CombatDomain.Terrain };
        var attackService = NewService(
            new FakeRepository(
                new UnitCommandSnapshot(
                    caster,
                    owner,
                    true,
                    true,
                    CombatDomain.Terrain,
                    domains,
                    Position: new WorldPosition(0, 0, 0)),
                new UnitCommandSnapshot(
                    enemy,
                    enemyOwner,
                    true,
                    true,
                    Position: new WorldPosition(2, 0, 0))),
            attack: attack,
            catalog: SkillCatalog(strike));
        Check(attackService.CastSkill(
                Context(owner),
                new CastSkillCommand([caster], strike.Id, enemy)).Status ==
            CommandStatus.Accepted,
            "下达攻击应被接受");
        Check(attack.OrdinaryRequests == 1, "下达攻击应调用已有 Attack 入口");
    }

    /// <summary>验证创建对象只提交模板、位置、方向和施法者。</summary>
    private void CastSkillCreateObjectUsesExistingTemplate()
    {
        var owner = NewPlayerId();
        var caster = NewUnitId();
        var spawned = new FakeObjectSpawnPort();
        var summon = new SkillDefinition(
            new SkillDefinitionId("demo_spawn_drone"),
            SkillTriggerKind.Active,
            SkillTargetKind.Ground,
            [new SkillEffectDefinition(
                SkillEffectKind.CreateObject,
                null,
                ObjectTemplateId: new UnitTypeId("drone"))],
            0,
            SkillTargetRelation.Any,
            8.0f,
            false);
        var service = NewService(
            new FakeRepository(
                new UnitCommandSnapshot(caster, owner, true, Position: new WorldPosition(0, 0, 0))),
            catalog: SkillCatalog(summon),
            objectSpawn: spawned);
        var destination = new WorldPosition(3, 0, 1);

        Check(service.CastSkill(
                Context(owner),
                new CastSkillCommand([caster], summon.Id, TargetPosition: destination)).Status ==
            CommandStatus.Accepted,
            "创建对象应被接受");
        Check(spawned.Requests.Count == 1, "创建对象应调用一次生成入口");
        Check(spawned.Requests[0].TemplateId == new UnitTypeId("drone") &&
            spawned.Requests[0].Position == destination &&
            spawned.Requests[0].CasterId == caster,
            "技能层只应提交模板、位置和施法者");
        Check(Math.Abs(spawned.Requests[0].YawRadians - MathF.Atan2(3.0f, 1.0f)) < 0.0001f,
            "方向应由施法者指向落点");
    }

    /// <summary>验证坦克装配的主动技能出现在 HUD 槽，冷却按模拟时钟剩余。</summary>
    private void HudSlotsShowEquippedActiveSkillsAndCooldown()
    {
        var owner = NewPlayerId();
        var tank = NewUnitId();
        var other = NewUnitId();
        var heal = new SkillDefinition(
            new SkillDefinitionId("demo_self_heal"),
            SkillTriggerKind.Active,
            SkillTargetKind.Self,
            [new SkillEffectDefinition(SkillEffectKind.RestoreHealth, 3.0f)],
            2000,
            EquippedUnitTypeIds: [new UnitTypeId("tank")]);
        var pulse = new SkillDefinition(
            new SkillDefinitionId("demo_unit_pulse"),
            SkillTriggerKind.Active,
            SkillTargetKind.Unit,
            [new SkillEffectDefinition(SkillEffectKind.DealDamage, 2.0f)],
            3000,
            SkillTargetRelation.Enemy,
            5.0f,
            EquippedUnitTypeIds: [new UnitTypeId("tank")]);
        var passive = new SkillDefinition(
            new SkillDefinitionId("demo_on_damage_heal"),
            SkillTriggerKind.Event,
            SkillTargetKind.Self,
            [new SkillEffectDefinition(SkillEffectKind.RestoreHealth, 1.0f)],
            2000,
            EquippedUnitTypeIds: [new UnitTypeId("tank")],
            TriggerEvent: SkillTriggerEvent.UnitDamaged);
        var service = NewService(
            new FakeRepository(
                new UnitCommandSnapshot(
                    tank,
                    owner,
                    true,
                    TypeId: "tank",
                    CurrentHealth: 4.0f,
                    MaximumHealth: 10.0f),
                new UnitCommandSnapshot(other, owner, true, TypeId: "helicopter")),
            catalog: SkillCatalog(heal, pulse, passive),
            damage: new FakeDamagePort(),
            cooldowns: new InMemorySkillCooldownStore());
        service.EquipAutomaticSkills(tank);
        service.EquipAutomaticSkills(other);
        var empty = service.GetHudSlots(other, 0);
        Check(empty.Count == 0, "未装配主动技能的单位不应出 HUD 槽");
        var ready = service.GetHudSlots(tank, 0);
        Check(ready.Count == 2 &&
            ready[0].SkillId.Value == "demo_self_heal" &&
            ready[0].IsReady &&
            ready[1].SkillId.Value == "demo_unit_pulse",
            "坦克 HUD 应只列出已装配的主动技能");
        Check(service.CastSkill(Context(owner, new MatchId(Guid.NewGuid()), 0),
                new CastSkillCommand([tank], heal.Id)).Status == CommandStatus.Accepted,
            "治疗应从 HUD 对应技能施放");
        var cooling = service.GetHudSlots(tank, 500);
        Check(cooling[0].CooldownRemainingMilliseconds == 1500 && !cooling[0].IsReady,
            "冷却中槽位应显示剩余模拟毫秒");
        Check(service.GetHudSlots(tank, 2000)[0].IsReady, "冷却结束后槽位应重新就绪");
    }

    private static SkillDefinition WindupPulse(bool refund, bool keepCooldown) => new(
        new SkillDefinitionId("demo_windup_pulse"),
        SkillTriggerKind.Active,
        SkillTargetKind.Self,
        [
            new SkillEffectDefinition(SkillEffectKind.DealDamage, 1.0f),
            new SkillEffectDefinition(SkillEffectKind.DealDamage, 1.0f, 1000)
        ],
        3000,
        Cost: [new ResourceAmount(ResourceKind.A, 1)],
        CastDelayMilliseconds: 1000,
        Interrupt: new SkillInterruptDefinition(
            [SkillInterruptPhase.BeforeActivation, SkillInterruptPhase.AfterActivation],
            [SkillInterruptCause.Stop],
            refund,
            keepCooldown));

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

    private static CommandContext Context(PlayerId owner) => Context(owner, new MatchId(Guid.NewGuid()), 0);

    private static CommandContext Context(PlayerId owner, MatchId match, long simulationMilliseconds) =>
        new(new CommandId(Guid.NewGuid()), match, owner, 1, simulationMilliseconds);

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

    private static SkillDefinition SelfSlow(
        SkillStackRule stack = SkillStackRule.Refresh,
        float modifier = 0.5f,
        int durationMilliseconds = 3000,
        string statusId = "demo_slow") => new(
        new SkillDefinitionId("demo_self_slow"),
        SkillTriggerKind.Active,
        SkillTargetKind.Self,
        [new SkillEffectDefinition(
            SkillEffectKind.AddStatus,
            null,
            0,
            new SkillStatusDefinition(
                statusId,
                durationMilliseconds,
                SkillAttributeKind.MoveSpeed,
                modifier,
                stack))],
        0);

    private static SkillDefinition SelfPulse() => new(
        new SkillDefinitionId("demo_self_pulse"),
        SkillTriggerKind.Active,
        SkillTargetKind.Self,
        [new SkillEffectDefinition(SkillEffectKind.DealDamage, 1.0f)],
        3000);

    private static IGameBalanceCatalog SkillCatalog(params SkillDefinition[] skills) =>
        new FakeSkillCatalog(skills);

    private static UnitCommandService NewService(
        IUnitCommandUnitRepository repository,
        IUnitMovementPort? movement = null,
        IUnitAttackPort? attack = null,
        IUnitOrderStore? orders = null,
        ICombatPolicyStore? policies = null,
        IUnitStopPort? stop = null,
        IWorkerTaskPort? workerTasks = null,
        IResourceNodeRepository? resources = null,
        IGameBalanceCatalog? catalog = null,
        IUnitDamagePort? damage = null,
        ISkillCastJournal? skillCasts = null,
        IResourceAccountService? accounts = null,
        ISkillCooldownStore? cooldowns = null,
        IUnitMoveSpeedPort? moveSpeed = null,
        IBattlefieldEventLog? battlefieldEvents = null,
        ISkillObjectSpawnPort? objectSpawn = null,
        ICommandCenterRepository? commandCenters = null) => new(
            repository,
            movement ?? new FakeMovementPort(),
            attack ?? new FakeAttackPort(),
            orders ?? new InMemoryUnitOrderStore(),
            policies ?? new InMemoryCombatPolicyStore(),
            stop ?? new FakeStopPort(),
            workerTasks,
            resources,
            catalog: catalog,
            damage: damage,
            skillCasts: skillCasts,
            accounts: accounts,
            cooldowns: cooldowns,
            moveSpeed: moveSpeed,
            battlefieldEvents: battlefieldEvents,
            objectSpawn: objectSpawn,
            commandCenters: commandCenters);

    /// <summary>记录技能创建对象时提交的模板、位姿和施法者。</summary>
    private sealed class FakeObjectSpawnPort : ISkillObjectSpawnPort
    {
        public List<SpawnRequest> Requests { get; } = [];

        public void SpawnObject(
            UnitTypeId templateId,
            WorldPosition position,
            float yawRadians,
            UnitId casterId) =>
            Requests.Add(new SpawnRequest(templateId, position, yawRadians, casterId));

        public readonly record struct SpawnRequest(
            UnitTypeId TemplateId,
            WorldPosition Position,
            float YawRadians,
            UnitId CasterId);
    }

    /// <summary>记录技能伤害端口收到的最终伤害。</summary>
    private sealed class FakeDamagePort : IUnitDamagePort
    {
        public List<DamageApplication> Applications { get; } = [];

        public void ApplyDamage(UnitId unitId, float damage) =>
            Applications.Add(new DamageApplication(unitId, damage));

        public List<(UnitId UnitId, float Amount)> Restores { get; } = [];

        public void RestoreHealth(UnitId unitId, float amount) => Restores.Add((unitId, amount));
    }

    /// <summary>记录技能移速端口收到的倍率和清除。</summary>
    private sealed class FakeMoveSpeedPort : IUnitMoveSpeedPort
    {
        public List<(UnitId UnitId, float Multiplier)> Applications { get; } = [];

        public List<UnitId> Clears { get; } = [];

        public Dictionary<UnitId, float> Multipliers { get; } = [];

        public float MultiplierOf(UnitId unitId) =>
            Multipliers.TryGetValue(unitId, out var value) ? value : 1.0f;

        public void ApplyMoveSpeedMultiplier(UnitId unitId, float multiplier)
        {
            Applications.Add((unitId, multiplier));
            Multipliers[unitId] = multiplier;
        }

        public void ClearMoveSpeedModifier(UnitId unitId)
        {
            Clears.Add(unitId);
            Multipliers[unitId] = 1.0f;
        }
    }

    /// <summary>只提供技能查询的测试 Catalog，其他定义一律视为不存在。</summary>
    private sealed class FakeSkillCatalog(
        SkillDefinition[] skills,
        WarheadDefinition? warhead = null) : IGameBalanceCatalog
    {
        private readonly Dictionary<SkillDefinitionId, SkillDefinition> _skills =
            skills.ToDictionary(item => item.Id);

        public BalanceConfigVersion Version { get; } = new(1, "test-skills", "0");

        public IReadOnlyCollection<UnitTypeDefinition> UnitTypes => [];

        public IReadOnlyCollection<WeaponDefinition> Weapons => [];

        public IReadOnlyCollection<ProductionDefinition> Productions => [];

        public IReadOnlyCollection<StructureConstructionDefinition> Constructions => [];

        public IReadOnlyCollection<SkillDefinition> Skills => _skills.Values;

        public UnitTypeDefinition? FindUnitType(UnitTypeId unitTypeId) => null;

        public WeaponDefinition? FindWeapon(WeaponDefinitionId weaponId) => null;

        public WarheadDefinition? FindWarhead(WarheadDefinitionId warheadId) =>
            warhead is not null && warhead.Id.Equals(warheadId) ? warhead : null;

        public ProductionDefinition? FindProduction(ProductionDefinitionId definitionId) => null;

        public StructureConstructionDefinition? FindConstruction(StructureDefinitionId definitionId) =>
            null;

        public ResourceDefinition? FindResource(ResourceKind kind) => null;

        public SkillDefinition? FindSkill(SkillDefinitionId skillId) =>
            _skills.GetValueOrDefault(skillId);
    }

    /// <summary>提供纯内存单位快照，不依赖 Godot ObjectDB。</summary>
    private sealed class FakeRepository(params UnitCommandSnapshot[] units) : IUnitCommandUnitRepository
    {
        private readonly Dictionary<UnitId, UnitCommandSnapshot> _units =
            units.ToDictionary(unit => unit.UnitId);

        /// <inheritdoc />
        public UnitCommandSnapshot? Find(UnitId unitId) =>
            _units.TryGetValue(unitId, out var unit) ? unit : null;
    }

    /// <summary>提供最近己方已完成 CommandCenter 的纯内存查询。</summary>
    private sealed class FakeCommandCenterRepository(params UnitCommandSnapshot[] commandCenters) :
        ICommandCenterRepository
    {
        private readonly UnitCommandSnapshot[] _commandCenters = commandCenters;

        public UnitCommandSnapshot? FindNearestCompletedCommandCenter(
            PlayerId owner,
            WorldPosition origin)
        {
            UnitCommandSnapshot? nearest = null;
            var nearestDistanceSquared = float.PositiveInfinity;
            foreach (var commandCenter in _commandCenters)
            {
                if (commandCenter.OwnerId != owner || !commandCenter.IsAlive ||
                    commandCenter.TypeId != "command_center")
                {
                    continue;
                }

                var dx = commandCenter.Position.X - origin.X;
                var dz = commandCenter.Position.Z - origin.Z;
                var distanceSquared = dx * dx + dz * dz;
                if (distanceSquared >= nearestDistanceSquared)
                {
                    continue;
                }

                nearestDistanceSquared = distanceSquared;
                nearest = commandCenter;
            }
            return nearest;
        }
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
    private sealed class FakeMovementPort : IUnitMovementPort, IReturnToBaseMovementPort
    {
        /// <summary>非 None 时，所有移动请求返回该错误。</summary>
        public MovementPortError MovementError { get; set; }

        /// <summary>普通移动请求次数。</summary>
        public int MoveRequests { get; private set; }

        /// <summary>最近一次普通移动目标。</summary>
        public WorldPosition LastDestination { get; private set; }

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

        /// <summary>回基地请求次数。</summary>
        public int ReturnToBaseRequests { get; private set; }

        /// <summary>最近一次回基地请求的基地稳定 ID。</summary>
        public UnitId LastCommandCenterId { get; private set; }

        /// <inheritdoc />
        public MovementPortResult RequestMove(UnitId unitId, WorldPosition destination)
        {
            MoveRequests++;
            LastDestination = destination;
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
        public MovementPortResult RequestReturnToBase(UnitId unitId, UnitId commandCenterId)
        {
            ReturnToBaseRequests++;
            LastCommandCenterId = commandCenterId;
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
