using AI_RTS.Application.Commands;
using AI_RTS.Application.Commands.Units;
using AI_RTS.Application.Combat;
using AI_RTS.Application.Orders;
using AI_RTS.Application.Units;
using AI_RTS.Domain.Combat;
using AI_RTS.Domain.Common;

namespace AI_RTS.Tests.Core;

/// <summary>提供不启动 Godot、不依赖第三方测试框架的核心命令测试入口。</summary>
internal static class Program
{
    /// <summary>执行全部纯 C# 测试，并通过进程退出码报告结果。</summary>
    private static int Main()
    {
        var suite = new UnitCommandServiceTests();
        return suite.Run();
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
        RunTest(nameof(CombatPoliciesAreIndependentAndOwnershipChecked), CombatPoliciesAreIndependentAndOwnershipChecked);
        RunTest(nameof(OrdinaryAttackRespectsHoldFire), OrdinaryAttackRespectsHoldFire);
        RunTest(nameof(ForceAttackOverridesHoldFire), ForceAttackOverridesHoldFire);
        RunTest(nameof(AttackMoveKeepsMovingDuringHoldFire), AttackMoveKeepsMovingDuringHoldFire);
        RunTest(nameof(TacticalWithdrawFallsBackToOrdinaryMovement), TacticalWithdrawFallsBackToOrdinaryMovement);
        RunTest(nameof(PortFailuresMapToStableErrors), PortFailuresMapToStableErrors);
        RunTest(nameof(OrderStorePublishesAuthoritativeStateChanges), OrderStorePublishesAuthoritativeStateChanges);

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
        ICombatPolicyStore? policies = null) => new(
            repository,
            movement ?? new FakeMovementPort(),
            attack ?? new FakeAttackPort(),
            orders ?? new InMemoryUnitOrderStore(),
            policies ?? new InMemoryCombatPolicyStore());

    /// <summary>提供纯内存单位快照，不依赖 Godot ObjectDB。</summary>
    private sealed class FakeRepository(params UnitCommandSnapshot[] units) : IUnitCommandUnitRepository
    {
        private readonly Dictionary<UnitId, UnitCommandSnapshot> _units =
            units.ToDictionary(unit => unit.UnitId);

        /// <inheritdoc />
        public UnitCommandSnapshot? Find(UnitId unitId) =>
            _units.TryGetValue(unitId, out var unit) ? unit : null;
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

        /// <summary>倒车撤退请求次数。</summary>
        public int WithdrawRequests { get; private set; }

        /// <inheritdoc />
        public MovementPortResult RequestMove(UnitId unitId, WorldPosition destination)
        {
            MoveRequests++;
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
        public AttackPortResult RequestCancelForceAttack(UnitId unitId) => Result();

        private AttackPortResult Result() => Error == AttackPortError.None
            ? AttackPortResult.Success()
            : AttackPortResult.Failure(Error);
    }
}
