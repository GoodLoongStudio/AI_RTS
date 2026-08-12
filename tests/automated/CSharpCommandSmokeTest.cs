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
        TestFailedReplacementPreservesActiveOrder();
        TestHaltSuspendsWithoutReplacingOrder();
        TestCombatPoliciesAreIndependentAndOwnershipChecked();
        TestForceAttackAndSelectiveCancellation();

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
            policies);

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
            new InMemoryCombatPolicyStore());

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
        new(repository, movement, new FakeAttackPort(), orders, new InMemoryCombatPolicyStore());

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

        /// <inheritdoc />
        public MovementPortResult RequestMove(UnitId unitId, WorldPosition destination) =>
            FailMoves ? MovementPortResult.Failure(MovementPortError.NavigationUnavailable) :
                MovementPortResult.Success();

        /// <inheritdoc />
        public MovementPortResult RequestHalt(UnitId unitId) => MovementPortResult.Success();
    }

    /// <summary>记录测试中的显式攻击与取消请求。</summary>
    private sealed class FakeAttackPort : IUnitAttackPort
    {
        /// <summary>累计收到的取消请求数。</summary>
        public int CancelRequests { get; private set; }

        /// <inheritdoc />
        public AttackPortResult RequestEntityForceAttack(UnitId attackerId, UnitId targetId) =>
            AttackPortResult.Success();

        /// <inheritdoc />
        public AttackPortResult RequestCancelForceAttack(UnitId unitId)
        {
            CancelRequests++;
            return AttackPortResult.Success();
        }
    }
}
