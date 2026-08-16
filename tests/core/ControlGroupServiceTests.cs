using AI_RTS.Application.Selection;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Selection;

namespace AI_RTS.Tests.Core;

/// <summary>验证传统控制组只保存稳定身份，并按评审契约过滤和清理成员。</summary>
internal sealed class ControlGroupServiceTests
{
    private int _failures;
    private int _tests;

    /// <summary>执行全部控制组纯 C# 回归并返回失败数。</summary>
    public int Run()
    {
        RunTest(nameof(ReplaceDeduplicatesAndSorts), ReplaceDeduplicatesAndSorts);
        RunTest(nameof(EmptyReplaceClearsAndEmptyRecallSucceeds),
            EmptyReplaceClearsAndEmptyRecallSucceeds);
        RunTest(nameof(InvalidMembersAreFilteredAndCanClear),
            InvalidMembersAreFilteredAndCanClear);
        RunTest(nameof(RecallPrunesChangedMembers), RecallPrunesChangedMembers);
        RunTest(nameof(RemoveUnitCleansEveryGroup), RemoveUnitCleansEveryGroup);
        RunTest(nameof(PlayersAndGroupsAreIndependent), PlayersAndGroupsAreIndependent);
        RunTest(nameof(InvalidGroupDoesNotMutateStorage), InvalidGroupDoesNotMutateStorage);

        Console.WriteLine(
            $"Control group tests completed: {_tests} test(s), {_failures} failure(s).");
        return _failures;
    }

    /// <summary>验证同组输入去重并按稳定 UnitId 排序，同一成员可重复出现在不同组。</summary>
    private void ReplaceDeduplicatesAndSorts()
    {
        var player = NewPlayer();
        var first = Unit(1);
        var second = Unit(2);
        var repository = new FakeRepository(
            new ControlGroupUnitSnapshot(first, player, true),
            new ControlGroupUnitSnapshot(second, player, true));
        var service = new ControlGroupService(repository);

        var result = service.Replace(player, Group(1), [second, first, second]);
        service.Replace(player, Group(2), [first]);

        Check(result.Status == ControlGroupSaveStatus.Accepted,
            "全部有效成员应返回 Accepted");
        Check(result.StoredUnitIds.SequenceEqual([first, second]),
            "成员应去重并按稳定 ID 排序");
        Check(service.Recall(player, Group(2)).UnitIds.SequenceEqual([first]),
            "同一成员应允许同时属于多个控制组");
    }

    /// <summary>验证显式空保存清组，读取空组仍返回带显式空值的成功结果。</summary>
    private void EmptyReplaceClearsAndEmptyRecallSucceeds()
    {
        var player = NewPlayer();
        var unit = Unit(1);
        var service = new ControlGroupService(new FakeRepository(
            new ControlGroupUnitSnapshot(unit, player, true)));
        service.Replace(player, Group(1), [unit]);

        var save = service.Replace(player, Group(1), []);
        var recall = service.Recall(player, Group(1));

        Check(save.Status == ControlGroupSaveStatus.Accepted && save.StoredUnitIds.Count == 0,
            "空输入应成功清空控制组");
        Check(recall.Status == ControlGroupRecallStatus.Accepted && recall.IsEmpty,
            "读取空控制组应显式成功且 IsEmpty=true");
    }

    /// <summary>验证混合输入只保存有效成员，全部无效输入会以空集合覆盖原组。</summary>
    private void InvalidMembersAreFilteredAndCanClear()
    {
        var player = NewPlayer();
        var enemy = NewPlayer();
        var valid = Unit(1);
        var enemyUnit = Unit(2);
        var unselectable = Unit(3);
        var missing = Unit(4);
        var repository = new FakeRepository(
            new ControlGroupUnitSnapshot(valid, player, true),
            new ControlGroupUnitSnapshot(enemyUnit, enemy, true),
            new ControlGroupUnitSnapshot(unselectable, player, false));
        var service = new ControlGroupService(repository);

        var mixed = service.Replace(
            player, Group(1), [valid, enemyUnit, unselectable, missing]);
        var cleared = service.Replace(player, Group(1), [enemyUnit, missing]);

        Check(mixed.Status == ControlGroupSaveStatus.AcceptedWithFilteredMembers,
            "混合输入应返回 AcceptedWithFilteredMembers");
        Check(mixed.StoredUnitIds.SequenceEqual([valid]),
            "混合输入只应存储有效成员");
        Check(ResultFor(mixed, enemyUnit).ErrorCode == ControlGroupErrorCode.UnitNotOwned,
            "敌方成员应返回 UnitNotOwned");
        Check(ResultFor(mixed, unselectable).ErrorCode == ControlGroupErrorCode.UnitNotSelectable,
            "不可选择成员应返回 UnitNotSelectable");
        Check(ResultFor(mixed, missing).ErrorCode == ControlGroupErrorCode.UnitUnavailable,
            "未知成员应返回 UnitUnavailable");
        Check(cleared.Status == ControlGroupSaveStatus.AcceptedWithFilteredMembers &&
            cleared.StoredUnitIds.Count == 0,
            "全部无效输入应以过滤后的空集合清空原组");
    }

    /// <summary>验证 Recall 会惰性剔除死亡、转属或变为不可选择的成员。</summary>
    private void RecallPrunesChangedMembers()
    {
        var player = NewPlayer();
        var enemy = NewPlayer();
        var alive = Unit(1);
        var dead = Unit(2);
        var transferred = Unit(3);
        var repository = new FakeRepository(
            new ControlGroupUnitSnapshot(alive, player, true),
            new ControlGroupUnitSnapshot(dead, player, true),
            new ControlGroupUnitSnapshot(transferred, player, true));
        var service = new ControlGroupService(repository);
        service.Replace(player, Group(1), [alive, dead, transferred]);
        repository.Remove(dead);
        repository.Set(new ControlGroupUnitSnapshot(transferred, enemy, true));

        var recall = service.Recall(player, Group(1));
        var secondRecall = service.Recall(player, Group(1));

        Check(recall.UnitIds.SequenceEqual([alive]), "Recall 只应返回仍有效己方成员");
        Check(recall.PrunedUnitIds.SequenceEqual([dead, transferred]),
            "Recall 应稳定返回本次剔除的失效成员");
        Check(secondRecall.PrunedUnitIds.Count == 0,
            "失效成员一经剔除不应在后续 Recall 重复报告");
    }

    /// <summary>验证主动单位退出会从全部玩家和全部编号中清理身份。</summary>
    private void RemoveUnitCleansEveryGroup()
    {
        var player = NewPlayer();
        var unit = Unit(1);
        var service = new ControlGroupService(new FakeRepository(
            new ControlGroupUnitSnapshot(unit, player, true)));
        service.Replace(player, Group(1), [unit]);
        service.Replace(player, Group(9), [unit]);

        service.RemoveUnit(unit);

        Check(service.Recall(player, Group(1)).IsEmpty,
            "主动清理应删除第一控制组成员");
        Check(service.Recall(player, Group(9)).IsEmpty,
            "主动清理应删除所有其他控制组成员");
    }

    /// <summary>验证相同数字编号在不同玩家之间隔离，不同编号也独立覆盖。</summary>
    private void PlayersAndGroupsAreIndependent()
    {
        var firstPlayer = NewPlayer();
        var secondPlayer = NewPlayer();
        var first = Unit(1);
        var second = Unit(2);
        var repository = new FakeRepository(
            new ControlGroupUnitSnapshot(first, firstPlayer, true),
            new ControlGroupUnitSnapshot(second, secondPlayer, true));
        var service = new ControlGroupService(repository);
        service.Replace(firstPlayer, Group(1), [first]);
        service.Replace(secondPlayer, Group(1), [second]);
        service.Replace(firstPlayer, Group(2), [first]);

        Check(service.Recall(firstPlayer, Group(1)).UnitIds.SequenceEqual([first]),
            "第一玩家同编号不应读取第二玩家成员");
        Check(service.Recall(secondPlayer, Group(1)).UnitIds.SequenceEqual([second]),
            "第二玩家同编号应保持独立集合");
        Check(service.Recall(firstPlayer, Group(2)).UnitIds.SequenceEqual([first]),
            "同一玩家不同编号应保持独立集合");
    }

    /// <summary>验证非法编号稳定拒绝，不能修改任何合法控制组。</summary>
    private void InvalidGroupDoesNotMutateStorage()
    {
        var player = NewPlayer();
        var unit = Unit(1);
        var service = new ControlGroupService(new FakeRepository(
            new ControlGroupUnitSnapshot(unit, player, true)));
        service.Replace(player, Group(1), [unit]);

        var save = service.Replace(player, Group(0), []);
        var recall = service.Recall(player, Group(10));

        Check(save.Status == ControlGroupSaveStatus.Rejected &&
            save.ErrorCode == ControlGroupErrorCode.InvalidGroup,
            "非法保存编号应稳定拒绝");
        Check(recall.Status == ControlGroupRecallStatus.Rejected &&
            recall.ErrorCode == ControlGroupErrorCode.InvalidGroup,
            "非法访问编号应稳定拒绝");
        Check(service.Recall(player, Group(1)).UnitIds.SequenceEqual([unit]),
            "非法请求不应修改合法控制组");
    }

    /// <summary>执行单项测试并把未捕获异常转换为失败。</summary>
    private void RunTest(string name, Action test)
    {
        _tests++;
        var failuresBefore = _failures;
        try
        {
            test();
        }
        catch (Exception exception)
        {
            _failures++;
            Console.Error.WriteLine($"[FAIL] {name}: unexpected {exception}");
        }
        if (_failures == failuresBefore)
        {
            Console.WriteLine($"[PASS] {name}");
        }
    }

    /// <summary>累计一个带明确原因的测试失败。</summary>
    private void Check(bool condition, string message)
    {
        if (condition)
        {
            return;
        }
        _failures++;
        Console.Error.WriteLine($"[FAIL] {message}");
    }

    private static ControlGroupMemberResult ResultFor(
        ControlGroupSaveResult result,
        UnitId unitId) => result.MemberResults.Single(item => item.UnitId == unitId);

    private static PlayerId NewPlayer() => new(Guid.NewGuid());

    private static UnitId Unit(int value) => new(new Guid(value, 0, 0, new byte[8]));

    private static ControlGroupNumber Group(int value) => new(value);

    /// <summary>提供可变的纯内存成员快照，模拟死亡、转属和可选择性变化。</summary>
    private sealed class FakeRepository(params ControlGroupUnitSnapshot[] snapshots) :
        IControlGroupUnitRepository
    {
        private readonly Dictionary<UnitId, ControlGroupUnitSnapshot> _snapshots =
            snapshots.ToDictionary(item => item.UnitId);

        /// <inheritdoc />
        public ControlGroupUnitSnapshot? Find(UnitId unitId) =>
            _snapshots.TryGetValue(unitId, out var snapshot) ? snapshot : null;

        /// <summary>增加或替换一个测试快照。</summary>
        public void Set(ControlGroupUnitSnapshot snapshot)
        {
            _snapshots[snapshot.UnitId] = snapshot;
        }

        /// <summary>模拟单位失效并移除测试快照。</summary>
        public void Remove(UnitId unitId)
        {
            _snapshots.Remove(unitId);
        }
    }
}
