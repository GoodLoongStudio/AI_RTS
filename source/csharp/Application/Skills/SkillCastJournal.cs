using AI_RTS.Domain.Common;
using AI_RTS.Domain.Skills;

namespace AI_RTS.Application.Skills;

/// <summary>记录一次已被命令层接受的技能目标确认结果。</summary>
public sealed record SkillCastRecord(
    CommandId CommandId,
    UnitId CasterId,
    SkillDefinitionId SkillId,
    UnitId? TargetUnitId,
    WorldPosition? TargetPosition);

/// <summary>保存本局已接受的技能目标，供后续效果读取地面或单位落点。</summary>
public interface ISkillCastJournal
{
    /// <summary>按接受顺序保存的施放记录。</summary>
    IReadOnlyList<SkillCastRecord> Records { get; }

    /// <summary>追加一条已接受施放的目标记录。</summary>
    void Record(SkillCastRecord record);
}

/// <summary>在当前对局进程中保存技能目标确认结果。</summary>
public sealed class InMemorySkillCastJournal : ISkillCastJournal
{
    private readonly List<SkillCastRecord> _records = [];

    /// <inheritdoc />
    public IReadOnlyList<SkillCastRecord> Records => _records;

    /// <inheritdoc />
    public void Record(SkillCastRecord record) => _records.Add(record);
}
