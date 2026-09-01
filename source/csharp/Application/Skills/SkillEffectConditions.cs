using AI_RTS.Application.Units;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Skills;

namespace AI_RTS.Application.Skills;

/// <summary>按配置条件决定是否执行当前这一跳效果。</summary>
public static class SkillEffectConditions
{
    /// <summary>条件不满足时跳过效果，不改变命令接受结果。</summary>
    public static bool IsSatisfied(
        IUnitCommandUnitRepository units,
        SkillDefinition skill,
        UnitId casterId,
        UnitId? targetUnitId,
        SkillEffectCondition condition)
    {
        if (condition == SkillEffectCondition.Always)
        {
            return true;
        }

        var resolvedId = skill.Target == SkillTargetKind.Self ? casterId : targetUnitId;
        if (resolvedId is null)
        {
            return false;
        }

        var target = units.Find(resolvedId.Value);
        if (target is null)
        {
            return false;
        }

        return condition switch
        {
            SkillEffectCondition.TargetAlive => target.Value.IsAlive,
            SkillEffectCondition.TargetWounded => target.Value.IsAlive &&
                target.Value.MaximumHealth > 0.0f &&
                target.Value.CurrentHealth < target.Value.MaximumHealth,
            _ => true
        };
    }
}
