using AI_RTS.Domain.Common;
using AI_RTS.Domain.Match;

namespace AI_RTS.Application.Match;

/// <summary>以内存稳定身份维护对局胜负状态，不依赖 Godot SceneTree。</summary>
public sealed class MatchOutcomeService(IMatchOutcomeRule rule) : IMatchOutcomeService
{
    private readonly Dictionary<PlayerId, MatchParticipant> _participants = [];
    private readonly Dictionary<UnitId, MatchCombatant> _combatants = [];
    private MatchResolution _resolution = new(MatchResolutionKind.InProgress, [], [], 0);
    private bool _started;
    private bool _dirty = true;

    /// <inheritdoc />
    public void RegisterParticipant(MatchParticipant participant)
    {
        Validate(participant);
        if (_resolution.Kind != MatchResolutionKind.InProgress)
        {
            return;
        }
        if (_participants.TryGetValue(participant.PlayerId, out var existing))
        {
            if (existing != participant)
            {
                throw new InvalidOperationException("同一 PlayerId 不能登记冲突的对局参与者。");
            }
            return;
        }
        _participants.Add(participant.PlayerId, participant);
        _dirty = true;
    }

    /// <inheritdoc />
    public void RegisterCombatant(MatchCombatant combatant)
    {
        Validate(combatant);
        if (_resolution.Kind != MatchResolutionKind.InProgress)
        {
            return;
        }
        if (!_participants.ContainsKey(combatant.OwnerPlayerId))
        {
            throw new ArgumentException("战场实体必须引用已登记玩家。", nameof(combatant));
        }
        if (_combatants.TryGetValue(combatant.UnitId, out var existing))
        {
            if (existing != combatant)
            {
                throw new InvalidOperationException("同一 UnitId 不能登记冲突的战场实体。");
            }
            return;
        }
        _combatants.Add(combatant.UnitId, combatant);
        _dirty = true;
    }

    /// <inheritdoc />
    public void RemoveCombatant(UnitId unitId)
    {
        if (_resolution.Kind != MatchResolutionKind.InProgress)
        {
            return;
        }
        if (_combatants.Remove(unitId))
        {
            _dirty = true;
        }
    }

    /// <inheritdoc />
    public MatchResolution StartMatch()
    {
        _started = true;
        _dirty = true;
        return Evaluate();
    }

    /// <inheritdoc />
    public MatchResolution Evaluate()
    {
        if (!_started || !_dirty || _resolution.Kind != MatchResolutionKind.InProgress)
        {
            return _resolution;
        }

        var evaluation = rule.Evaluate(
            _participants.Values.ToArray(),
            _combatants.Values.ToArray());
        _resolution = new MatchResolution(
            evaluation.Kind,
            evaluation.WinningSideIds.ToArray(),
            evaluation.SurvivingSideIds.ToArray(),
            checked(_resolution.Version + 1));
        _dirty = false;
        return _resolution;
    }

    /// <inheritdoc />
    public MatchResolution ResolveExplicit(
        MatchResolutionKind kind,
        IReadOnlyList<MatchSideId> winningSideIds)
    {
        ArgumentNullException.ThrowIfNull(winningSideIds);
        if (kind == MatchResolutionKind.InProgress)
        {
            throw new ArgumentException("显式终局不能写成进行中。", nameof(kind));
        }
        if (kind == MatchResolutionKind.Won && winningSideIds.Count == 0)
        {
            throw new ArgumentException("Won 必须指定至少一个胜方。", nameof(winningSideIds));
        }
        if (kind == MatchResolutionKind.Draw && winningSideIds.Count != 0)
        {
            throw new ArgumentException("Draw 不得指定胜方。", nameof(winningSideIds));
        }
        if (!_started || _resolution.Kind != MatchResolutionKind.InProgress)
        {
            return _resolution;
        }

        _resolution = new MatchResolution(
            kind,
            winningSideIds.ToArray(),
            CurrentSurvivingSides(),
            checked(_resolution.Version + 1));
        _dirty = false;
        return _resolution;
    }

    /// <inheritdoc />
    public MatchResolution GetSnapshot() => _resolution;

    /// <summary>按当前计分实体汇总仍存活阵营，不改写显式终局。</summary>
    private IReadOnlyList<MatchSideId> CurrentSurvivingSides()
    {
        var sidesByPlayer = _participants.Values.ToDictionary(item => item.PlayerId, item => item.SideId);
        return _combatants.Values
            .Where(item => item.CountsForElimination && sidesByPlayer.ContainsKey(item.OwnerPlayerId))
            .Select(item => sidesByPlayer[item.OwnerPlayerId])
            .Distinct()
            .OrderBy(item => item.Value)
            .ToArray();
    }

    /// <summary>拒绝无法形成稳定身份或阵营归属的参与者。</summary>
    private static void Validate(MatchParticipant participant)
    {
        if (participant.PlayerId.Value == Guid.Empty || participant.SideId.Value == Guid.Empty)
        {
            throw new ArgumentException("参与者 PlayerId 与 SideId 不能为空。", nameof(participant));
        }
    }

    /// <summary>拒绝缺少稳定身份或所有者的战场实体。</summary>
    private static void Validate(MatchCombatant combatant)
    {
        if (combatant.UnitId.Value == Guid.Empty || combatant.OwnerPlayerId.Value == Guid.Empty)
        {
            throw new ArgumentException("战场实体 UnitId 与 OwnerPlayerId 不能为空。", nameof(combatant));
        }
    }
}
