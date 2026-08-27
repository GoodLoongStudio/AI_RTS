using AI_RTS.Domain.Battlefield;
using AI_RTS.Domain.Common;

namespace AI_RTS.Application.Battlefield;

/// <summary>记录并查询当前控制方可合法获知的重要战场事件。</summary>
public interface IBattlefieldEventLog
{
    /// <summary>追加一条事件；超过容量时丢弃最旧记录。</summary>
    BattlefieldEventRecord Record(
        BattlefieldEventKind kind,
        WorldPosition position,
        bool isImportant = true);

    /// <summary>返回最近一条重要事件；没有可跳转事件时为空。</summary>
    BattlefieldEventRecord? FindLatestImportant();

    /// <summary>当前已保存的事件数量。</summary>
    int Count { get; }
}

/// <summary>单局内存事件日志，只保存经过情报过滤后的玩家可知事件。</summary>
public sealed class BattlefieldEventLog : IBattlefieldEventLog
{
    /// <summary>单局最多保留的事件条数，避免长对局无限增长。</summary>
    public const int Capacity = 64;

    private readonly List<BattlefieldEventRecord> _events = [];
    private int _nextSequence = 1;

    /// <inheritdoc />
    public int Count => _events.Count;

    /// <inheritdoc />
    public BattlefieldEventRecord Record(
        BattlefieldEventKind kind,
        WorldPosition position,
        bool isImportant = true)
    {
        var record = new BattlefieldEventRecord(_nextSequence, kind, position, isImportant);
        _nextSequence++;
        _events.Add(record);
        if (_events.Count > Capacity)
        {
            _events.RemoveAt(0);
        }

        return record;
    }

    /// <inheritdoc />
    public BattlefieldEventRecord? FindLatestImportant()
    {
        for (var index = _events.Count - 1; index >= 0; index--)
        {
            if (_events[index].IsImportant)
            {
                return _events[index];
            }
        }

        return null;
    }
}
