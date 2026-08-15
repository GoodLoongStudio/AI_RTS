using AI_RTS.Application.Match;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Match;
using AI_RTS.GodotAdapter.Common;
using Godot;

namespace AI_RTS.GodotAdapter.Match;

/// <summary>把 Godot 玩家及单位事实适配到可测试的 C# 对局胜负服务。</summary>
public partial class MatchOutcomeRuntime : Node
{
    /// <summary>首次进入终态时发布结构化结果，由 UI 适配器负责展示。</summary>
    [Signal]
    public delegate void MatchResolvedEventHandler(Godot.Collections.Dictionary resolution);

    private readonly HashSet<PlayerId> _registeredPlayers = [];
    private IMatchOutcomeService _service = null!;
    private Node _match = null!;
    private Node _matchSignals = null!;
    private MatchSideId? _localHumanSideId;
    private bool _configured;
    private bool _evaluationPending;
    private bool _terminalPublished;

    /// <summary>在 Match 完成玩家和初始单位装配后建立权威快照并开启判定。</summary>
    public void Initialize(Node playersContainer, Node? localHumanPlayer)
    {
        if (_configured)
        {
            throw new InvalidOperationException("MatchOutcomeRuntime 只能初始化一次。");
        }
        _configured = true;
        _match = GetParent();
        _service = new MatchOutcomeService(new LastSurvivingSideRule());

        foreach (var player in playersContainer.GetChildren().OfType<Node>())
        {
            if (player.IsInGroup("players"))
            {
                RegisterParticipant(player, player == localHumanPlayer);
            }
        }
        foreach (var unit in GetTree().GetNodesInGroup("units").OfType<Node>())
        {
            if (_match.IsAncestorOf(unit))
            {
                RegisterCombatant(unit);
            }
        }

        _matchSignals = GetNode("/root/MatchSignals");
        _matchSignals.Connect("unit_spawned", Callable.From<Node>(OnUnitSpawned));
        _matchSignals.Connect("unit_died", Callable.From<Node>(OnUnitDied));
        PublishIfTerminal(_service.StartMatch());
    }

    /// <summary>退出对局时解除全局事实订阅，避免旧 Runtime 接收下一局事件。</summary>
    public override void _ExitTree()
    {
        if (!_configured || !GodotObject.IsInstanceValid(_matchSignals))
        {
            return;
        }
        var spawned = Callable.From<Node>(OnUnitSpawned);
        var died = Callable.From<Node>(OnUnitDied);
        if (_matchSignals.IsConnected("unit_spawned", spawned))
        {
            _matchSignals.Disconnect("unit_spawned", spawned);
        }
        if (_matchSignals.IsConnected("unit_died", died))
        {
            _matchSignals.Disconnect("unit_died", died);
        }
    }

    /// <summary>返回供自动测试和诊断界面读取的稳定结果字段。</summary>
    public Godot.Collections.Dictionary InspectOutcome()
    {
        if (!_configured)
        {
            return new Godot.Collections.Dictionary
            {
                ["status"] = "RuntimeUnavailable",
                ["kind"] = MatchResolutionKind.InProgress.ToString(),
                ["winning_side_ids"] = new Godot.Collections.Array<string>(),
                ["surviving_side_ids"] = new Godot.Collections.Array<string>(),
                ["local_human_side_id"] = string.Empty,
                ["version"] = 0L
            };
        }
        return ToGodot(_service.GetSnapshot());
    }

    /// <summary>登记权威生成事实，并把同帧更新合并为一次胜负评估。</summary>
    private void OnUnitSpawned(Node unit)
    {
        if (!_match.IsAncestorOf(unit) || !unit.IsInGroup("units"))
        {
            return;
        }
        RegisterCombatant(unit);
        ScheduleEvaluation();
    }

    /// <summary>登记权威死亡事实；未知与重复死亡由 Application 服务幂等处理。</summary>
    private void OnUnitDied(Node unit)
    {
        if (!GodotObject.IsInstanceValid(unit) || !unit.HasMeta(GodotStableIdentity.UnitIdMeta))
        {
            return;
        }
        _service.RemoveCombatant(GodotStableIdentity.Unit(unit));
        ScheduleEvaluation();
    }

    /// <summary>将同一帧中的生成和死亡事实合并，支持真正的同时全灭平局。</summary>
    private void ScheduleEvaluation()
    {
        if (_evaluationPending || _terminalPublished)
        {
            return;
        }
        _evaluationPending = true;
        Callable.From(EvaluateAndPublish).CallDeferred();
    }

    /// <summary>执行合并后的唯一一次评估，并在首次终态时发布结果。</summary>
    private void EvaluateAndPublish()
    {
        _evaluationPending = false;
        if (!IsInsideTree() || _terminalPublished)
        {
            return;
        }
        PublishIfTerminal(_service.Evaluate());
    }

    /// <summary>将 Godot 玩家映射为默认独立 Side，并记录唯一的本机 Human。</summary>
    private void RegisterParticipant(Node player, bool isLocalHuman)
    {
        var playerId = GodotStableIdentity.Player(player);
        if (!_registeredPlayers.Add(playerId))
        {
            return;
        }
        var sideId = new MatchSideId(playerId.Value);
        _service.RegisterParticipant(new MatchParticipant(playerId, sideId, isLocalHuman));
        if (isLocalHuman)
        {
            _localHumanSideId = sideId;
        }
    }

    /// <summary>将当前 units group 实体显式登记为计入 Demo 歼灭规则的对象。</summary>
    private void RegisterCombatant(Node unit)
    {
        var owner = unit.GetParent();
        var ownerId = GodotStableIdentity.Player(owner);
        if (!_registeredPlayers.Contains(ownerId))
        {
            return;
        }
        _service.RegisterCombatant(new MatchCombatant(
            GodotStableIdentity.Unit(unit),
            ownerId,
            true));
    }

    /// <summary>确保终态只向 Godot 展示层发布一次。</summary>
    private void PublishIfTerminal(MatchResolution resolution)
    {
        if (_terminalPublished || resolution.Kind == MatchResolutionKind.InProgress)
        {
            return;
        }
        _terminalPublished = true;
        EmitSignal(SignalName.MatchResolved, ToGodot(resolution));
    }

    /// <summary>把领域快照转换为 GDScript 可稳定读取的显式字段。</summary>
    private Godot.Collections.Dictionary ToGodot(MatchResolution resolution) => new()
    {
        ["status"] = "Accepted",
        ["kind"] = resolution.Kind.ToString(),
        ["winning_side_ids"] = SideIds(resolution.WinningSideIds),
        ["surviving_side_ids"] = SideIds(resolution.SurvivingSideIds),
        ["local_human_side_id"] = _localHumanSideId?.Value.ToString("D") ?? string.Empty,
        ["version"] = resolution.Version
    };

    private static Godot.Collections.Array<string> SideIds(
        IReadOnlyList<MatchSideId> sideIds)
    {
        var result = new Godot.Collections.Array<string>();
        foreach (var sideId in sideIds)
        {
            result.Add(sideId.Value.ToString("D"));
        }
        return result;
    }
}
