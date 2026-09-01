using AI_RTS.Application.Commands;
using AI_RTS.Application.Units;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Skills;

namespace AI_RTS.Application.Skills;

/// <summary>按技能配置检查单位或地面目标是否合法。</summary>
public static class SkillTargeting
{
    /// <summary>校验单个施法者对已存在单位目标的阵营、存活和距离。</summary>
    public static CommandErrorCode ValidateUnitTarget(
        SkillDefinition skill,
        UnitCommandSnapshot caster,
        UnitCommandSnapshot target)
    {
        if (skill.RequireAlive && !target.IsAlive)
        {
            return CommandErrorCode.TargetNotFound;
        }
        if (!skill.AllowSelf && target.UnitId == caster.UnitId)
        {
            return CommandErrorCode.SkillTargetNotAllowed;
        }
        if (!MatchesRelation(skill.Relation, caster, target))
        {
            return CommandErrorCode.SkillTargetNotAllowed;
        }
        return IsWithinRange(skill.RangeMeters, caster.Position, target.Position) ?
            CommandErrorCode.None : CommandErrorCode.SkillOutOfRange;
    }

    /// <summary>校验地面坐标是否有限且位于施法距离内。</summary>
    public static CommandErrorCode ValidateGroundTarget(
        SkillDefinition skill,
        UnitCommandSnapshot caster,
        WorldPosition? position)
    {
        if (position is null || !IsFinite(position.Value))
        {
            return CommandErrorCode.InvalidDestination;
        }
        return IsWithinRange(skill.RangeMeters, caster.Position, position.Value) ?
            CommandErrorCode.None : CommandErrorCode.SkillOutOfRange;
    }

    private static bool MatchesRelation(
        SkillTargetRelation relation,
        UnitCommandSnapshot caster,
        UnitCommandSnapshot target) => relation switch
    {
        SkillTargetRelation.Self => target.UnitId == caster.UnitId,
        SkillTargetRelation.Ally => target.OwnerId == caster.OwnerId,
        SkillTargetRelation.Enemy => target.OwnerId != caster.OwnerId,
        SkillTargetRelation.Any => true,
        _ => false
    };

    private static bool IsWithinRange(
        float? rangeMeters,
        WorldPosition origin,
        WorldPosition destination)
    {
        if (rangeMeters is null)
        {
            return true;
        }

        var dx = destination.X - origin.X;
        var dz = destination.Z - origin.Z;
        return dx * dx + dz * dz <= rangeMeters.Value * rangeMeters.Value;
    }

    private static bool IsFinite(WorldPosition value) =>
        float.IsFinite(value.X) && float.IsFinite(value.Y) && float.IsFinite(value.Z);
}
