using AI_RTS.Application.Battlefield;
using AI_RTS.Domain.Battlefield;
using AI_RTS.Domain.Common;

namespace AI_RTS.Tests.Core;

/// <summary>验证战场事件日志只把最新重要事件作为 Space 跳转目标。</summary>
internal sealed class BattlefieldEventLogTests
{
    private int _failures;
    private int _tests;

    /// <summary>执行全部纯 C# 战场事件测试。</summary>
    public int Run()
    {
        RunTest(nameof(LatestImportantWins), LatestImportantWins);
        RunTest(nameof(UnimportantEventsAreSkipped), UnimportantEventsAreSkipped);
        RunTest(nameof(CapacityDropsOldest), CapacityDropsOldest);
        Console.WriteLine($"Battlefield event tests completed: {_tests} test(s), {_failures} failure(s).");
        return _failures == 0 ? 0 : 1;
    }

    /// <summary>验证后写入的重要事件覆盖先前跳转目标。</summary>
    private void LatestImportantWins()
    {
        var log = new BattlefieldEventLog();
        log.Record(BattlefieldEventKind.OwnUnitUnderAttack, new WorldPosition(1, 0, 1));
        var latest = log.Record(BattlefieldEventKind.OwnUnitLost, new WorldPosition(8, 0, 4));
        var found = log.FindLatestImportant();
        Check(found is not null && found.Sequence == latest.Sequence, "Space 应跳到最新重要事件");
        Check(found!.Position.X == 8, "最新事件应保留其世界坐标");
    }

    /// <summary>验证非重要事件不会成为跳转目标。</summary>
    private void UnimportantEventsAreSkipped()
    {
        var log = new BattlefieldEventLog();
        var important = log.Record(BattlefieldEventKind.VisibleHostileLost, new WorldPosition(3, 0, 2));
        log.Record(BattlefieldEventKind.OwnConstructionFinished, new WorldPosition(9, 0, 9), false);
        var found = log.FindLatestImportant();
        Check(found is not null && found.Sequence == important.Sequence, "非重要事件不得覆盖跳转目标");
    }

    /// <summary>验证超出容量时丢掉最旧记录，但仍能找到剩余的最新重要事件。</summary>
    private void CapacityDropsOldest()
    {
        var log = new BattlefieldEventLog();
        for (var index = 0; index < BattlefieldEventLog.Capacity + 3; index++)
        {
            log.Record(
                BattlefieldEventKind.OwnUnitUnderAttack,
                new WorldPosition(index, 0, 0));
        }

        Check(log.Count == BattlefieldEventLog.Capacity, "日志应限制在固定容量内");
        var found = log.FindLatestImportant();
        Check(found is not null && found.Position.X == BattlefieldEventLog.Capacity + 2, "容量淘汰后仍应跳到最新事件");
    }

    private void RunTest(string name, Action test)
    {
        _tests++;
        try
        {
            test();
            Console.WriteLine($"PASS {name}");
        }
        catch (Exception exception)
        {
            _failures++;
            Console.Error.WriteLine($"FAIL {name}: {exception.Message}");
        }
    }

    private static void Check(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }
}
