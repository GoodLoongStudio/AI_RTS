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
    private readonly HashSet<MatchSideId> _registeredSides = [];
    private readonly HashSet<UnitId> _exitSubscriptions = [];
    private IMatchOutcomeService _service = null!;
    private Node _match = null!;
    private Node _matchSignals = null!;
    private MatchSideId? _localHumanSideId;
    private bool _configured;
    private bool _evaluationPending;
    private bool _terminalPublished;
    private bool _shuttingDown;
    private bool _soloPractice;

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
            // 联机大厅的空槽保留一个 NONE 占位 Player 以维持槽位索引，
            // 但它不是参战方；否则单人测试局会被错误判定为仅剩一方获胜。
            if (player.IsInGroup("players")
                && (!player.HasMeta("slot_kind") || player.GetMeta("slot_kind").AsInt32() != 0))
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

        // 单人练习房（参战方不足 2）：设计师要求「只有玩家主动退出才结束，
        // 不以胜利/失败为结束」。此时完全不启用歼灭判定——否则开局即被判胜利，
        // 既弹出结算 UI 又会触发专用服回收，对局彻底冻结。
        _soloPractice = _registeredSides.Count < 2;
        if (_soloPractice)
        {
            return;
        }

        _matchSignals.Connect("unit_spawned", Callable.From<Node>(OnUnitSpawned));
        PublishIfTerminal(_service.StartMatch());
    }

    /// <summary>退出对局时解除全局事实订阅，避免旧 Runtime 接收下一局事件。</summary>
    public override void _ExitTree()
    {
        _shuttingDown = true;
        if (!_configured || !GodotObject.IsInstanceValid(_matchSignals))
        {
            return;
        }
        var spawned = Callable.From<Node>(OnUnitSpawned);
        if (_matchSignals.IsConnected("unit_spawned", spawned))
        {
            _matchSignals.Disconnect("unit_spawned", spawned);
        }
    }

    /// <summary>战役目标完成时一次性锁定本机阵营胜利，不依赖歼灭规则。</summary>
    public bool DeclareCampaignVictory()
    {
        if (!_configured || _terminalPublished || _localHumanSideId is not { } localSide)
        {
            return false;
        }

        PublishIfTerminal(_service.ResolveExplicit(MatchResolutionKind.Won, [localSide]));
        return _terminalPublished;
    }

    /// <summary>战役失败目标完成时一次性锁定非本机阵营胜利，不依赖歼灭规则。</summary>
    public bool DeclareCampaignDefeat()
    {
        if (!_configured || _terminalPublished || _localHumanSideId is not { } localSide)
        {
            return false;
        }

        var winners = _registeredSides
            .Where(sideId => sideId != localSide)
            .OrderBy(sideId => sideId.Value)
            .ToArray();
        if (winners.Length == 0)
        {
            return false;
        }

        PublishIfTerminal(_service.ResolveExplicit(MatchResolutionKind.Won, winners));
        return _terminalPublished;
    }

    /// <summary>战役与 UI 共用的一次锁定查询；未初始化时视为尚未锁定。</summary>
    public bool IsOutcomeLocked()
    {
        return _configured && _service.GetSnapshot().Kind != MatchResolutionKind.InProgress;
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
                ["local_result"] = "InProgress",
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

    /// <summary>处理任何已登记实体退出，包括死亡、取消蓝图和系统移除。</summary>
    private void OnCombatantExited(UnitId unitId)
    {
        _exitSubscriptions.Remove(unitId);
        _service.RemoveCombatant(unitId);
        ScheduleEvaluation();
    }

    /// <summary>将同一帧中的生成和死亡事实合并，支持真正的同时全灭平局。</summary>
    private void ScheduleEvaluation()
    {
        if (_evaluationPending || _terminalPublished || _shuttingDown || _soloPractice)
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
        _registeredSides.Add(sideId);
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
        var unitId = GodotStableIdentity.Unit(unit);
        _service.RegisterCombatant(new MatchCombatant(
            unitId,
            ownerId,
            true));
        if (_exitSubscriptions.Add(unitId))
        {
            unit.TreeExited += () => OnCombatantExited(unitId);
        }
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
        ["local_result"] = MapLocalResult(resolution),
        ["version"] = resolution.Version
    };

    /// <summary>把权威终态映射为本机展示结果，供结算 UI 直接读取。</summary>
    private string MapLocalResult(MatchResolution resolution)
    {
        if (resolution.Kind == MatchResolutionKind.InProgress)
        {
            return "InProgress";
        }
        if (resolution.Kind == MatchResolutionKind.Draw || _localHumanSideId is not { } localSide)
        {
            return "Finish";
        }
        return resolution.WinningSideIds.Contains(localSide) ? "Victory" : "Defeat";
    }

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
