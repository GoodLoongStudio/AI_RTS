using AI_RTS.Application.Commands;
using AI_RTS.Application.Commands.Units;
using AI_RTS.Application.Combat;
using AI_RTS.Application.Orders;
using AI_RTS.Application.Units;
using AI_RTS.Domain.Combat;
using AI_RTS.Domain.Common;
using Godot;

namespace AI_RTS.Tests.Automated;

/// <summary>验证 C# 命令服务的部分成功、订单替换和暂停语义。</summary>
public partial class CSharpCommandSmokeTest : Node
{
    /// <summary>累计失败断言数量，并作为进程退出码来源。</summary>
    private int _failures;

    /// <summary>依次运行无 UI 命令测试，并用非零退出码报告失败。</summary>
    public override void _Ready()
    {
        TestPartialAcceptanceAndIndependentOrders();
        TestMoveAndForceMoveKeepDistinctIntent();
        TestGroundAttackMoveKeepsDistinctIntent();
        TestEntityAttackMoveAuthorization();
        TestFailedReplacementPreservesActiveOrder();
        TestHaltSuspendsWithoutReplacingOrder();
        TestCombatPoliciesAreIndependentAndOwnershipChecked();
        TestForceAttackAndSelectiveCancellation();
        TestOrdinaryAttackAuthorization();
        TestTacticalWithdrawCapabilityFallback();

        GD.Print($"C# command smoke test completed: {_failures} failure(s)");
        GetTree().Quit(_failures == 0 ? 0 : 1);
    }

    /// <summary>验证可移动、不可移动和失效单位在同一批命令中独立返回结果。</summary>
    private void TestPartialAcceptanceAndIndependentOrders()
    {
        var owner = NewPlayerId();
        var movable = NewUnitId();
        var immovable = NewUnitId();
        var missing = NewUnitId();
        var repository = new FakeRepository(
            new UnitCommandSnapshot(movable, owner, true),
            new UnitCommandSnapshot(immovable, owner, false));
        var orders = new InMemoryUnitOrderStore();
        var service = NewService(repository, new FakeMovementPort(), orders);

        var result = service.ForceMove(Context(owner), new ForceMoveUnitsCommand(
            [movable, immovable, missing], new WorldPosition(10, 0, 10)));

        Check(result.Status == CommandStatus.PartiallyAccepted, "batch should be partially accepted");
        Check(result.UnitResults.Single(item => item.UnitId == movable).OrderId is not null,
            "accepted unit should receive an independent order id");
        Check(result.UnitResults.Single(item => item.UnitId == immovable).ErrorCode == CommandErrorCode.UnitCannotMove,
            "immovable unit should be rejected independently");
        Check(result.UnitResults.Single(item => item.UnitId == missing).ErrorCode == CommandErrorCode.UnitNotFound,
            "missing unit should be rejected independently");
        Check(orders.FindActive(movable)?.State == UnitOrderState.InProgress,
            "accepted move order should become in progress");
    }

    /// <summary>验证普通移动和强制移动复用导航端口，但保留彼此独立的订单类型。</summary>
    private void TestMoveAndForceMoveKeepDistinctIntent()
    {
        var owner = NewPlayerId();
        var unit = NewUnitId();
        var repository = new FakeRepository(new UnitCommandSnapshot(unit, owner, true));
        var orders = new InMemoryUnitOrderStore();
        var service = NewService(repository, new FakeMovementPort(), orders);

        var move = service.Move(
            Context(owner),
            new MoveUnitsCommand([unit], new WorldPosition(1, 0, 1)));
        var moveOrder = orders.FindActive(unit);
        var forceMove = service.ForceMove(
            Context(owner),
            new ForceMoveUnitsCommand([unit], new WorldPosition(2, 0, 2)));

        Check(move.Status == CommandStatus.Accepted, "ordinary move should be accepted");
        Check(moveOrder?.Kind == UnitOrderKind.Move, "ordinary move should retain Move order kind");
        Check(forceMove.Status == CommandStatus.Accepted, "force move should be accepted");
        Check(orders.FindActive(unit)?.Kind == UnitOrderKind.ForceMove,
            "force move should retain ForceMove order kind");
        Check(moveOrder is not null && orders.Find(moveOrder.OrderId)?.State == UnitOrderState.Cancelled,
            "force move should replace the previous ordinary move order");
    }

    /// <summary>验证地面移动攻击使用独立执行端口与订单类型。</summary>
    private void TestGroundAttackMoveKeepsDistinctIntent()
    {
        var owner = NewPlayerId();
        var unit = NewUnitId();
        var repository = new FakeRepository(new UnitCommandSnapshot(unit, owner, true, true));
        var movement = new FakeMovementPort();
        var orders = new InMemoryUnitOrderStore();
        var service = NewService(repository, movement, orders);

        var result = service.GroundAttackMove(
            Context(owner),
            new GroundAttackMoveCommand([unit], new WorldPosition(4, 0, 4)));

        Check(result.Status == CommandStatus.Accepted, "ground attack move should be accepted");
        Check(movement.GroundAttackMoveRequests == 1,
            "ground attack move should use its dedicated movement port");
        Check(orders.FindActive(unit)?.Kind == UnitOrderKind.GroundAttackMove,
            "ground attack move should retain its order kind");
    }

    /// <summary>验证实体移动攻击保留敌方最终目标、拒绝己方目标，并允许停火单位继续追踪。</summary>
    private void TestEntityAttackMoveAuthorization()
    {
        var owner = NewPlayerId();
        var enemyOwner = NewPlayerId();
        var unit = NewUnitId();
        var friendly = NewUnitId();
        var enemy = NewUnitId();
        var terrainDomains = new HashSet<CombatDomain> { CombatDomain.Terrain };
        var repository = new FakeRepository(
            new UnitCommandSnapshot(unit, owner, true, true, CombatDomain.Terrain, terrainDomains),
            new UnitCommandSnapshot(friendly, owner, true, true, CombatDomain.Terrain, terrainDomains),
            new UnitCommandSnapshot(enemy, enemyOwner, true, true, CombatDomain.Terrain, terrainDomains));
        var movement = new FakeMovementPort();
        var orders = new InMemoryUnitOrderStore();
        var policies = new InMemoryCombatPolicyStore();
        var service = new UnitCommandService(
            repository, movement, new FakeAttackPort(), orders, policies, new FakeStopPort());

        policies.SetFirePolicy(unit, FirePolicy.HoldFire);
        var accepted = service.EntityAttackMove(
            Context(owner), new EntityAttackMoveCommand([unit], new EntityAttackTarget(enemy)));
        var rejected = service.EntityAttackMove(
            Context(owner), new EntityAttackMoveCommand([unit], new EntityAttackTarget(friendly)));

        Check(accepted.Status == CommandStatus.Accepted,
            "hold-fire entity attack move should still be accepted as movement");
        Check(movement.EntityAttackMoveRequests == 1,
            "entity attack move should use its dedicated movement port");
        Check(orders.FindActive(unit)?.Kind == UnitOrderKind.EntityAttackMove,
            "entity attack move should retain its order kind");
        Check(rejected.Status == CommandStatus.Rejected &&
            rejected.UnitResults.Single().ErrorCode == CommandErrorCode.InvalidAttackTarget,
            "entity attack move should reject a friendly final target");
    }

    /// <summary>验证新导航请求失败时不会提前取消旧活动订单。</summary>
    private void TestFailedReplacementPreservesActiveOrder()
    {
        var owner = NewPlayerId();
        var unit = NewUnitId();
        var repository = new FakeRepository(new UnitCommandSnapshot(unit, owner, true));
        var movement = new FakeMovementPort();
        var orders = new InMemoryUnitOrderStore();
        var service = NewService(repository, movement, orders);

        service.ForceMove(Context(owner), new ForceMoveUnitsCommand([unit], new WorldPosition(1, 0, 1)));
        var original = orders.FindActive(unit);
        movement.FailMoves = true;
        var failed = service.ForceMove(Context(owner), new ForceMoveUnitsCommand([unit], new WorldPosition(2, 0, 2)));

        Check(failed.Status == CommandStatus.Rejected, "navigation rejection should reject replacement move");
        Check(orders.FindActive(unit)?.OrderId == original?.OrderId,
            "failed replacement must preserve the previous active order");
    }

    /// <summary>验证 Halt 保留订单 ID，并把活动订单转换为 Suspended。</summary>
    private void TestHaltSuspendsWithoutReplacingOrder()
    {
        var owner = NewPlayerId();
        var unit = NewUnitId();
        var repository = new FakeRepository(new UnitCommandSnapshot(unit, owner, true));
        var orders = new InMemoryUnitOrderStore();
        var service = NewService(repository, new FakeMovementPort(), orders);

        service.ForceMove(Context(owner), new ForceMoveUnitsCommand([unit], new WorldPosition(1, 0, 1)));
        var original = orders.FindActive(unit);
        var halted = service.HaltMovement(Context(owner), new HaltMovementCommand([unit]));

        Check(halted.Status == CommandStatus.Accepted, "halt should be accepted");
        Check(halted.UnitResults.Single().OrderId == original?.OrderId,
            "halt should retain the existing order id");
        Check(orders.Find(original!.OrderId)?.State == UnitOrderState.Suspended,
            "halt should suspend rather than cancel the active order");
    }

    /// <summary>验证姿态与开火策略正交保存，且不能修改其他玩家单位。</summary>
    private void TestCombatPoliciesAreIndependentAndOwnershipChecked()
    {
        var owner = NewPlayerId();
        var adversary = NewPlayerId();
        var ownedUnit = NewUnitId();
        var foreignUnit = NewUnitId();
        var repository = new FakeRepository(
            new UnitCommandSnapshot(ownedUnit, owner, true),
            new UnitCommandSnapshot(foreignUnit, adversary, true));
        var policies = new InMemoryCombatPolicyStore();
        var service = new UnitCommandService(
            repository,
            new FakeMovementPort(),
            new FakeAttackPort(),
            new InMemoryUnitOrderStore(),
            policies,
            new FakeStopPort());

        var stanceResult = service.SetEngagementStance(
            Context(owner),
            new SetEngagementStanceCommand(
                [ownedUnit, foreignUnit],
                EngagementStance.Guard));
        var fireResult = service.SetFirePolicy(
            Context(owner),
            new SetFirePolicyCommand([ownedUnit], FirePolicy.HoldFire));

        Check(stanceResult.Status == CommandStatus.PartiallyAccepted,
            "combat policy batch should enforce ownership per unit");
        Check(stanceResult.UnitResults.Single(item => item.UnitId == foreignUnit).ErrorCode ==
            CommandErrorCode.UnitNotOwned, "foreign combat policy update should be rejected");
        Check(fireResult.Status == CommandStatus.Accepted, "owned fire policy should be accepted");
        Check(policies.Get(ownedUnit) == new CombatPolicySnapshot(
            EngagementStance.Guard, FirePolicy.HoldFire, null),
            "stance and fire policy should be stored independently");
        Check(policies.Get(foreignUnit) == new CombatPolicySnapshot(
            EngagementStance.Aggressive, FirePolicy.FireAtWill, null),
            "rejected foreign unit should preserve default policy");
    }

    /// <summary>验证显式攻击可选择友军、创建分类订单，并可被选择性取消。</summary>
    private void TestForceAttackAndSelectiveCancellation()
    {
        var owner = NewPlayerId();
        var attacker = NewUnitId();
        var friendlyTarget = NewUnitId();
        var repository = new FakeRepository(
            new UnitCommandSnapshot(
                attacker,
                owner,
                true,
                true,
                CombatDomain.Terrain,
                new HashSet<CombatDomain> { CombatDomain.Terrain }),
            new UnitCommandSnapshot(friendlyTarget, owner, true));
        var orders = new InMemoryUnitOrderStore();
        var attack = new FakeAttackPort();
        var service = new UnitCommandService(
            repository,
            new FakeMovementPort(),
            attack,
            orders,
            new InMemoryCombatPolicyStore(),
            new FakeStopPort());

        var result = service.ForceAttack(
            Context(owner),
            new ForceAttackCommand([attacker], new EntityAttackTarget(friendlyTarget)));
        var order = orders.FindActive(attacker);

        Check(result.Status == CommandStatus.Accepted, "explicit friendly force attack should be accepted");
        Check(order?.Kind == UnitOrderKind.ForceAttack, "force attack order should retain its kind");
        var cancelled = service.CancelForceAttack(
            Context(owner),
            new CancelForceAttackCommand([attacker]));
        Check(cancelled.Status == CommandStatus.Accepted, "force attack cancellation should be accepted");
        Check(order is not null && orders.Find(order.OrderId)?.State == UnitOrderState.Cancelled,
            "selective cancellation should cancel active force attack order");
        Check(attack.CancelRequests == 1, "attack port should receive one cancellation request");

        var ground = service.ForceAttack(
            Context(owner),
            new ForceAttackCommand([attacker], new GroundAttackTarget(new WorldPosition(1, 0, 1))));
        Check(ground.UnitResults.Single().ErrorCode == CommandErrorCode.WeaponCannotForceFire,
            "ground force attack should return stable unsupported weapon error");
    }

    /// <summary>验证普通攻击拒绝己方与停火单位，并为合法敌方目标建立独立订单。</summary>
    private void TestOrdinaryAttackAuthorization()
    {
        var owner = NewPlayerId();
        var adversary = NewPlayerId();
        var attacker = NewUnitId();
        var friendly = NewUnitId();
        var enemy = NewUnitId();
        var repository = new FakeRepository(
            new UnitCommandSnapshot(
                attacker,
                owner,
                true,
                true,
                CombatDomain.Terrain,
                new HashSet<CombatDomain> { CombatDomain.Terrain }),
            new UnitCommandSnapshot(friendly, owner, true),
            new UnitCommandSnapshot(enemy, adversary, true));
        var policies = new InMemoryCombatPolicyStore();
        var attack = new FakeAttackPort();
        var orders = new InMemoryUnitOrderStore();
        var service = new UnitCommandService(
            repository, new FakeMovementPort(), attack, orders, policies, new FakeStopPort());

        var friendlyResult = service.Attack(
            Context(owner),
            new AttackCommand([attacker], new EntityAttackTarget(friendly)));
        policies.SetFirePolicy(attacker, FirePolicy.HoldFire);
        var holdFireResult = service.Attack(
            Context(owner),
            new AttackCommand([attacker], new EntityAttackTarget(enemy)));
        policies.SetFirePolicy(attacker, FirePolicy.FireAtWill);
        var accepted = service.Attack(
            Context(owner),
            new AttackCommand([attacker], new EntityAttackTarget(enemy)));

        Check(friendlyResult.UnitResults.Single().ErrorCode == CommandErrorCode.InvalidAttackTarget,
            "ordinary attack should reject friendly target");
        Check(holdFireResult.UnitResults.Single().ErrorCode ==
            CommandErrorCode.FirePolicyPreventsAttack,
            "ordinary attack should reject HoldFire attacker");
        Check(accepted.Status == CommandStatus.Accepted,
            "ordinary enemy attack should be accepted under FireAtWill");
        Check(orders.FindActive(attacker)?.Kind == UnitOrderKind.Attack,
            "ordinary attack should retain Attack order kind");
        Check(attack.OrdinaryAttackRequests == 1,
            "only authorized ordinary attack should reach attack port");
    }

    /// <summary>验证倒车单位使用撤退端口，而普通可移动单位自动退化为移动且仍创建撤退订单。</summary>
    private void TestTacticalWithdrawCapabilityFallback()
    {
        var owner = NewPlayerId();
        var reversing = NewUnitId();
        var forwardOnly = NewUnitId();
        var repository = new FakeRepository(
            new UnitCommandSnapshot(reversing, owner, true, CanReverse: true),
            new UnitCommandSnapshot(forwardOnly, owner, true));
        var movement = new FakeMovementPort();
        var orders = new InMemoryUnitOrderStore();
        var service = NewService(repository, movement, orders);

        var result = service.TacticalWithdraw(
            Context(owner),
            new TacticalWithdrawCommand(
                [reversing, forwardOnly],
                new WorldPosition(8, 0, 8)));

        Check(result.Status == CommandStatus.Accepted, "movable withdraw batch should be accepted");
        Check(movement.WithdrawRequests == 1, "reverse-capable unit should use withdrawal port");
        Check(movement.MoveRequests == 1, "forward-only unit should degrade to ordinary movement port");
        Check(orders.FindActive(reversing)?.Kind == UnitOrderKind.TacticalWithdraw,
            "reversing unit should retain tactical withdraw order kind");
        Check(orders.FindActive(forwardOnly)?.Kind == UnitOrderKind.TacticalWithdraw,
            "fallback unit should retain player tactical intent in order kind");
    }

    /// <summary>累计失败断言并向 Godot 错误日志报告原因。</summary>
    private void Check(bool condition, string message)
    {
        if (condition)
        {
            return;
        }
        _failures++;
        GD.PushError($"C# command smoke assertion failed: {message}");
    }

    private static CommandContext Context(PlayerId owner) => new(
        new CommandId(Guid.NewGuid()), new MatchId(Guid.NewGuid()), owner, 1);
    private static PlayerId NewPlayerId() => new(Guid.NewGuid());
    private static UnitId NewUnitId() => new(Guid.NewGuid());

    private static UnitCommandService NewService(
        IUnitCommandUnitRepository repository,
        IUnitMovementPort movement,
        IUnitOrderStore orders) =>
        new(
            repository,
            movement,
            new FakeAttackPort(),
            orders,
            new InMemoryCombatPolicyStore(),
            new FakeStopPort());

    /// <summary>提供测试使用的内存单位查询仓储。</summary>
    private sealed class FakeRepository(params UnitCommandSnapshot[] units) : IUnitCommandUnitRepository
    {
        private readonly Dictionary<UnitId, UnitCommandSnapshot> _units =
            units.ToDictionary(unit => unit.UnitId);

        /// <inheritdoc />
        public UnitCommandSnapshot? Find(UnitId unitId) =>
            _units.TryGetValue(unitId, out var unit) ? unit : null;
    }

    /// <summary>提供可控制成功或失败的测试移动端口。</summary>
    private sealed class FakeMovementPort : IUnitMovementPort
    {
        /// <summary>为 true 时拒绝后续所有移动请求。</summary>
        public bool FailMoves { get; set; }

        /// <summary>累计普通移动端口调用次数。</summary>
        public int MoveRequests { get; private set; }

        /// <summary>累计倒车撤退端口调用次数。</summary>
        public int WithdrawRequests { get; private set; }

        /// <summary>累计地面移动攻击端口调用次数。</summary>
        public int GroundAttackMoveRequests { get; private set; }

        /// <summary>累计实体移动攻击端口调用次数。</summary>
        public int EntityAttackMoveRequests { get; private set; }

        /// <inheritdoc />
        public MovementPortResult RequestMove(UnitId unitId, WorldPosition destination)
        {
            MoveRequests++;
            return FailMoves ? MovementPortResult.Failure(MovementPortError.NavigationUnavailable) :
                MovementPortResult.Success();
        }

        /// <inheritdoc />
        public MovementPortResult RequestApproachEntity(
            UnitId unitId,
            BattlefieldEntityId targetEntityId) => FailMoves ?
            MovementPortResult.Failure(MovementPortError.NavigationUnavailable) :
            MovementPortResult.Success();

        /// <inheritdoc />
        public MovementPortResult RequestFollowEntity(UnitId unitId, UnitId targetId) =>
            FailMoves ?
                MovementPortResult.Failure(MovementPortError.NavigationUnavailable) :
                MovementPortResult.Success();

        /// <inheritdoc />
        public MovementPortResult RequestTacticalWithdraw(UnitId unitId, WorldPosition destination)
        {
            WithdrawRequests++;
            return FailMoves ? MovementPortResult.Failure(MovementPortError.NavigationUnavailable) :
                MovementPortResult.Success();
        }

        /// <inheritdoc />
        public MovementPortResult RequestGroundAttackMove(UnitId unitId, WorldPosition destination)
        {
            GroundAttackMoveRequests++;
            return FailMoves ? MovementPortResult.Failure(MovementPortError.NavigationUnavailable) :
                MovementPortResult.Success();
        }

        /// <inheritdoc />
        public MovementPortResult RequestEntityAttackMove(UnitId unitId, UnitId targetId)
        {
            EntityAttackMoveRequests++;
            return FailMoves ? MovementPortResult.Failure(MovementPortError.NavigationUnavailable) :
                MovementPortResult.Success();
        }

        /// <inheritdoc />
        public MovementPortResult RequestHalt(UnitId unitId) => MovementPortResult.Success();
    }

    /// <summary>记录测试中的显式攻击与取消请求。</summary>
    private sealed class FakeAttackPort : IUnitAttackPort
    {
        /// <summary>累计收到的取消请求数。</summary>
        public int CancelRequests { get; private set; }

        /// <summary>累计收到的普通实体攻击请求数。</summary>
        public int OrdinaryAttackRequests { get; private set; }

        /// <inheritdoc />
        public AttackPortResult RequestEntityAttack(UnitId attackerId, UnitId targetId)
        {
            OrdinaryAttackRequests++;
            return AttackPortResult.Success();
        }

        /// <inheritdoc />
        public AttackPortResult RequestEntityForceAttack(UnitId attackerId, UnitId targetId) =>
            AttackPortResult.Success();

        /// <inheritdoc />
        public AttackPortResult RequestGroundForceAttack(UnitId attackerId, WorldPosition position) =>
            AttackPortResult.Success();

        /// <inheritdoc />
        public AttackPortResult RequestCancelForceAttack(UnitId unitId)
        {
            CancelRequests++;
            return AttackPortResult.Success();
        }
    }

    /// <summary>为 Godot 内 C# 冒烟测试提供始终接受的统一 Stop 端口。</summary>
    private sealed class FakeStopPort : IUnitStopPort
    {
        /// <inheritdoc />
        public StopPortResult RequestStop(UnitId unitId) => StopPortResult.Success();
    }
}
