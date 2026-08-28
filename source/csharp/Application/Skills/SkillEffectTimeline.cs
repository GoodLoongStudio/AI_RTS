using AI_RTS.Domain.Common;
using AI_RTS.Domain.Skills;

namespace AI_RTS.Application.Skills;

/// <summary>按模拟毫秒调度顺序效果；时刻不前进则延迟不结束。</summary>
public interface ISkillEffectTimeline
{
    /// <summary>从正式生效时刻起，按效果间隔排队或立即执行。</summary>
    void Schedule(
        UnitId casterId,
        SkillDefinition skill,
        UnitId? targetUnitId,
        WorldPosition? targetPosition,
        long simulationMilliseconds);

    /// <summary>执行所有到期效果。paused 时只要传入同一时刻就不会触发后续段。</summary>
    void Advance(long simulationMilliseconds);

    /// <summary>取消该单位尚未执行且匹配条件的效果，不回滚已结算段。</summary>
    IReadOnlyCollection<SkillDefinition> CancelPending(
        UnitId casterId,
        Func<SkillDefinition, bool> match);
}

/// <summary>用模拟毫秒保存待执行技能效果。</summary>
public sealed class SkillEffectTimeline(SkillInstantEffectExecutor executor) : ISkillEffectTimeline
{
    private readonly List<ScheduledSkillEffect> _pending = [];

    /// <inheritdoc />
    public void Schedule(
        UnitId casterId,
        SkillDefinition skill,
        UnitId? targetUnitId,
        WorldPosition? targetPosition,
        long simulationMilliseconds)
    {
        var cursor = simulationMilliseconds;
        var previousAt = simulationMilliseconds;
        var isFirst = true;
        foreach (var effect in skill.Effects)
        {
            long at;
            if (!isFirst && effect.Timing == SkillEffectTiming.Simultaneous)
            {
                at = previousAt;
            }
            else
            {
                at = checked(cursor + Math.Max(0, effect.DelayMilliseconds));
            }

            var repeats = Math.Max(1, effect.RepeatCount);
            var period = repeats > 1 ? Math.Max(0, effect.PeriodMilliseconds) : 0;
            if (repeats > 1 && period <= 0)
            {
                repeats = 1;
            }

            for (var index = 0; index < repeats; index++)
            {
                var tickAt = checked(at + (index * period));
                if (tickAt <= simulationMilliseconds)
                {
                    executor.Apply(
                        casterId, skill, targetUnitId, targetPosition, effect, simulationMilliseconds);
                    continue;
                }

                _pending.Add(new ScheduledSkillEffect(
                    tickAt, casterId, skill, targetUnitId, targetPosition, effect));
            }

            previousAt = at;
            cursor = at;
            isFirst = false;
        }
    }

    /// <inheritdoc />
    public void Advance(long simulationMilliseconds)
    {
        var due = _pending
            .Where(item => item.ReadyAtMilliseconds <= simulationMilliseconds)
            .OrderBy(item => item.ReadyAtMilliseconds)
            .ToArray();
        foreach (var item in due)
        {
            _pending.Remove(item);
            executor.Apply(
                item.CasterId,
                item.Skill,
                item.TargetUnitId,
                item.TargetPosition,
                item.Effect,
                simulationMilliseconds);
        }
    }

    /// <inheritdoc />
    public IReadOnlyCollection<SkillDefinition> CancelPending(
        UnitId casterId,
        Func<SkillDefinition, bool> match)
    {
        var cancelled = _pending
            .Where(item => item.CasterId == casterId && match(item.Skill))
            .ToArray();
        foreach (var item in cancelled)
        {
            _pending.Remove(item);
        }

        return cancelled.Select(item => item.Skill).Distinct().ToArray();
    }

    private sealed record ScheduledSkillEffect(
        long ReadyAtMilliseconds,
        UnitId CasterId,
        SkillDefinition Skill,
        UnitId? TargetUnitId,
        WorldPosition? TargetPosition,
        SkillEffectDefinition Effect);
}
