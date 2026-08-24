using AI_RTS.Application.Battlefield;
using AI_RTS.Domain.Battlefield;
using AI_RTS.Domain.Common;
using Godot;

namespace AI_RTS.GodotAdapter.Battlefield;

/// <summary>把己方受损、阵亡、可见敌亡和完工等合法事件写入权威日志，供 Space 跳转。</summary>
public partial class BattlefieldEventRuntime : Node
{
    /// <summary>与旁白相同的受击提示间隔，避免每次掉血都覆盖最近跳转点。</summary>
    public const int UnderAttackThrottleMsec = 10_000;

    private IBattlefieldEventLog _log = new BattlefieldEventLog();
    private Node? _humanPlayer;
    private Node? _signals;
    private Callable _onDamaged;
    private Callable _onDied;
    private Callable _onConstructed;
    private ulong _lastUnderAttackMsec;

    /// <summary>由 Match 绑定本地 Human；无 Human 的对局不记录镜头跳转事件。</summary>
    public void Initialize(Node? humanPlayer)
    {
        _humanPlayer = humanPlayer;
        _signals = GetNode<Node>("/root/MatchSignals");
        _onDamaged = Callable.From<Node>(OnUnitDamaged);
        _onDied = Callable.From<Node>(OnUnitDied);
        _onConstructed = Callable.From<Node>(OnConstructionFinished);
        _signals.Connect("unit_damaged", _onDamaged);
        _signals.Connect("unit_died", _onDied);
        _signals.Connect("unit_construction_finished", _onConstructed);
    }

    /// <inheritdoc />
    public override void _ExitTree()
    {
        if (_signals is null || !GodotObject.IsInstanceValid(_signals))
        {
            return;
        }

        _signals.Disconnect("unit_damaged", _onDamaged);
        _signals.Disconnect("unit_died", _onDied);
        _signals.Disconnect("unit_construction_finished", _onConstructed);
    }

    /// <summary>测试或关卡脚本写入一条可跳转事件，并返回其序号。</summary>
    public int RecordImportant(string kindName, Vector3 position)
    {
        if (!Enum.TryParse<BattlefieldEventKind>(kindName, out var kind))
        {
            throw new ArgumentException($"未知战场事件种类：{kindName}。", nameof(kindName));
        }

        return _log.Record(kind, ToWorld(position)).Sequence;
    }

    /// <summary>返回最近重要事件的世界坐标；没有事件时返回空字典。</summary>
    public Godot.Collections.Dictionary TryGetLatestImportantFocus()
    {
        var latest = _log.FindLatestImportant();
        if (latest is null)
        {
            return [];
        }

        return new Godot.Collections.Dictionary
        {
            ["sequence"] = latest.Sequence,
            ["kind"] = latest.Kind.ToString(),
            ["position"] = new Vector3(latest.Position.X, latest.Position.Y, latest.Position.Z)
        };
    }

    /// <summary>当前日志条数，供自动测试核对。</summary>
    public int GetEventCount() => _log.Count;

    private void OnUnitDamaged(Node unit)
    {
        if (!IsOwnedByHuman(unit))
        {
            return;
        }

        var now = Time.GetTicksMsec();
        if (_lastUnderAttackMsec != 0 &&
            now - _lastUnderAttackMsec < (ulong)UnderAttackThrottleMsec)
        {
            return;
        }

        _lastUnderAttackMsec = now;
        _log.Record(BattlefieldEventKind.OwnUnitUnderAttack, PositionOf(unit));
    }

    private void OnUnitDied(Node unit)
    {
        var position = PositionOf(unit);
        if (IsOwnedByHuman(unit))
        {
            _log.Record(BattlefieldEventKind.OwnUnitLost, position);
            return;
        }

        if (unit.IsInGroup("adversary_units") && IsCurrentlyVisible(unit))
        {
            _log.Record(BattlefieldEventKind.VisibleHostileLost, position);
        }
    }

    private void OnConstructionFinished(Node unit)
    {
        if (!IsOwnedByHuman(unit))
        {
            return;
        }

        _log.Record(BattlefieldEventKind.OwnConstructionFinished, PositionOf(unit));
    }

    private bool IsOwnedByHuman(Node unit)
    {
        if (_humanPlayer is null || !GodotObject.IsInstanceValid(_humanPlayer))
        {
            return false;
        }

        if (unit.IsInGroup("controlled_units") || unit.GetParent() == _humanPlayer)
        {
            return true;
        }

        var owner = unit.Get("player");
        return owner.VariantType == Variant.Type.Object && owner.AsGodotObject() == _humanPlayer;
    }

    private static bool IsCurrentlyVisible(Node unit) =>
        unit is Node3D node3D && node3D.IsVisibleInTree();

    private static WorldPosition PositionOf(Node unit)
    {
        if (unit is Node3D node3D && node3D.IsInsideTree())
        {
            return ToWorld(node3D.GlobalPosition);
        }

        if (unit is Node3D detached)
        {
            return ToWorld(detached.GlobalPosition);
        }

        return new WorldPosition(0, 0, 0);
    }

    private static WorldPosition ToWorld(Vector3 position) =>
        new(position.X, position.Y, position.Z);
}
