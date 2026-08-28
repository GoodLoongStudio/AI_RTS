using AI_RTS.Domain.Battlefield;
using AI_RTS.Domain.Common;

namespace AI_RTS.Application.Skills;

/// <summary>技能效果复用已有移动、攻击和战场事件入口，不另建命令体系。</summary>
public interface ISkillWorldActionPort
{
    /// <summary>让施法者执行已有普通移动。</summary>
    void IssueMove(UnitId unitId, WorldPosition destination);

    /// <summary>让施法者执行已有普通实体攻击。</summary>
    void IssueAttack(UnitId attackerId, UnitId targetId);

    /// <summary>把技能信号写入统一战场事件日志。</summary>
    void EmitBattlefieldEvent(BattlefieldEventKind kind, WorldPosition position, bool isImportant);
}

/// <summary>技能创建对象时只提交模板、位姿和施法者，不解释模板内部。</summary>
public interface ISkillObjectSpawnPort
{
    /// <summary>按已有对象模板在场上生成一个实例。</summary>
    void SpawnObject(
        UnitTypeId templateId,
        WorldPosition position,
        float yawRadians,
        UnitId casterId);
}
