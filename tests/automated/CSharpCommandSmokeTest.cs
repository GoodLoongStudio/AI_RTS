using AI_RTS.Application.Commands;
using AI_RTS.Application.Commands.Units;
using AI_RTS.Application.Orders;
using AI_RTS.Application.Units;
using AI_RTS.Domain.Common;
using Godot;

namespace AI_RTS.Tests.Automated;

public partial class CSharpCommandSmokeTest : Node
{
    private int _failures;

    public override void _Ready()
    {
        TestPartialAcceptanceAndIndependentOrders();
        TestFailedReplacementPreservesActiveOrder();
        TestHaltSuspendsWithoutReplacingOrder();

        GD.Print($"C# command smoke test completed: {_failures} failure(s)");
        GetTree().Quit(_failures == 0 ? 0 : 1);
    }

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
        var service = new UnitCommandService(repository, new FakeMovementPort(), orders);

        var result = service.Move(Context(owner), new MoveUnitsCommand(
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

    private void TestFailedReplacementPreservesActiveOrder()
    {
        var owner = NewPlayerId();
        var unit = NewUnitId();
        var repository = new FakeRepository(new UnitCommandSnapshot(unit, owner, true));
        var movement = new FakeMovementPort();
        var orders = new InMemoryUnitOrderStore();
        var service = new UnitCommandService(repository, movement, orders);

        service.Move(Context(owner), new MoveUnitsCommand([unit], new WorldPosition(1, 0, 1)));
        var original = orders.FindActive(unit);
        movement.FailMoves = true;
        var failed = service.Move(Context(owner), new MoveUnitsCommand([unit], new WorldPosition(2, 0, 2)));

        Check(failed.Status == CommandStatus.Rejected, "navigation rejection should reject replacement move");
        Check(orders.FindActive(unit)?.OrderId == original?.OrderId,
            "failed replacement must preserve the previous active order");
    }

    private void TestHaltSuspendsWithoutReplacingOrder()
    {
        var owner = NewPlayerId();
        var unit = NewUnitId();
        var repository = new FakeRepository(new UnitCommandSnapshot(unit, owner, true));
        var orders = new InMemoryUnitOrderStore();
        var service = new UnitCommandService(repository, new FakeMovementPort(), orders);

        service.Move(Context(owner), new MoveUnitsCommand([unit], new WorldPosition(1, 0, 1)));
        var original = orders.FindActive(unit);
        var halted = service.HaltMovement(Context(owner), new HaltMovementCommand([unit]));

        Check(halted.Status == CommandStatus.Accepted, "halt should be accepted");
        Check(halted.UnitResults.Single().OrderId == original?.OrderId,
            "halt should retain the existing order id");
        Check(orders.Find(original!.OrderId)?.State == UnitOrderState.Suspended,
            "halt should suspend rather than cancel the active order");
    }

    private void Check(bool condition, string message)
    {
        if (condition)
            return;
        _failures++;
        GD.PushError($"C# command smoke assertion failed: {message}");
    }

    private static CommandContext Context(PlayerId owner) => new(
        new CommandId(Guid.NewGuid()), new MatchId(Guid.NewGuid()), owner, 1);
    private static PlayerId NewPlayerId() => new(Guid.NewGuid());
    private static UnitId NewUnitId() => new(Guid.NewGuid());

    private sealed class FakeRepository(params UnitCommandSnapshot[] units) : IUnitCommandUnitRepository
    {
        private readonly Dictionary<UnitId, UnitCommandSnapshot> _units =
            units.ToDictionary(unit => unit.UnitId);

        public UnitCommandSnapshot? Find(UnitId unitId) =>
            _units.TryGetValue(unitId, out var unit) ? unit : null;
    }

    private sealed class FakeMovementPort : IUnitMovementPort
    {
        public bool FailMoves { get; set; }

        public MovementPortResult RequestMove(UnitId unitId, WorldPosition destination) =>
            FailMoves ? MovementPortResult.Failure(MovementPortError.NavigationUnavailable) :
                MovementPortResult.Success();

        public MovementPortResult RequestHalt(UnitId unitId) => MovementPortResult.Success();
    }
}
