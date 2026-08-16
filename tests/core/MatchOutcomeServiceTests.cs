using AI_RTS.Application.Match;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Match;

namespace AI_RTS.Tests.Core;

/// <summary>验证歼灭规则、初始化门闩、批量评估和一次性终态。</summary>
internal sealed class MatchOutcomeServiceTests
{
    private int _failures;
    private int _tests;

    /// <summary>执行全部对局胜负纯 C# 回归并返回失败数。</summary>
    public int Run()
    {
        RunTest(nameof(DoesNotResolveBeforeStart), DoesNotResolveBeforeStart);
        RunTest(nameof(TwoLivingSidesRemainInProgress), TwoLivingSidesRemainInProgress);
        RunTest(nameof(LastLivingSideWins), LastLivingSideWins);
        RunTest(nameof(AllOwnedCombatantsMustBeRemoved), AllOwnedCombatantsMustBeRemoved);
        RunTest(nameof(PlayersCanShareOneSide), PlayersCanShareOneSide);
        RunTest(nameof(BatchedAnnihilationDraws), BatchedAnnihilationDraws);
        RunTest(nameof(NonCountingEntitiesDoNotKeepSideAlive), NonCountingEntitiesDoNotKeepSideAlive);
        RunTest(nameof(DuplicateFactsAreIdempotent), DuplicateFactsAreIdempotent);
        RunTest(nameof(TerminalResolutionIsImmutable), TerminalResolutionIsImmutable);
        RunTest(nameof(SnapshotVersionAndSidesAreStable), SnapshotVersionAndSidesAreStable);
        RunTest(nameof(SingleSideDebugMatchDoesNotAutoFinish), SingleSideDebugMatchDoesNotAutoFinish);

        Console.WriteLine(
            $"Match outcome tests completed: {_tests} test(s), {_failures} failure(s).");
        return _failures;
    }

    /// <summary>验证初始玩家和单位分批登记期间不会提前产生终局。</summary>
    private void DoesNotResolveBeforeStart()
    {
        var fixture = TwoSides();
        fixture.Service.RemoveCombatant(fixture.SecondUnit);

        Check(fixture.Service.GetSnapshot().Kind == MatchResolutionKind.InProgress,
            "StartMatch 前不得判定胜负");
        Check(fixture.Service.GetSnapshot().Version == 0,
            "StartMatch 前不得推进评估版本");
    }

    /// <summary>验证双方均有计分实体时保持进行中。</summary>
    private void TwoLivingSidesRemainInProgress()
    {
        var fixture = TwoSides();
        var result = fixture.Service.StartMatch();

        Check(result.Kind == MatchResolutionKind.InProgress,
            "两个存活阵营应继续对局");
        Check(result.SurvivingSideIds.Count == 2,
            "快照应包含两个存活阵营");
    }

    /// <summary>验证一方最后一个计分实体退出后另一方获胜。</summary>
    private void LastLivingSideWins()
    {
        var fixture = TwoSides();
        fixture.Service.StartMatch();
        fixture.Service.RemoveCombatant(fixture.SecondUnit);

        var result = fixture.Service.Evaluate();

        Check(result.Kind == MatchResolutionKind.Won,
            "最后存活阵营应进入 Won");
        Check(result.WinningSideIds.SequenceEqual([fixture.FirstSide]),
            "胜方应为仍有实体的第一阵营");
    }

    /// <summary>验证同一玩家的多个计分实体全部退出后才会淘汰。</summary>
    private void AllOwnedCombatantsMustBeRemoved()
    {
        var fixture = TwoSides();
        var extra = Unit(3);
        fixture.Service.RegisterCombatant(new MatchCombatant(extra, fixture.SecondPlayer, true));
        fixture.Service.StartMatch();
        fixture.Service.RemoveCombatant(fixture.SecondUnit);

        Check(fixture.Service.Evaluate().Kind == MatchResolutionKind.InProgress,
            "玩家仍有第二个计分实体时不得淘汰");
        fixture.Service.RemoveCombatant(extra);
        Check(fixture.Service.Evaluate().Kind == MatchResolutionKind.Won,
            "最后一个计分实体退出后才应结束");
    }

    /// <summary>验证多个玩家共享 Side 时任一队友存活即可维持阵营。</summary>
    private void PlayersCanShareOneSide()
    {
        var service = NewService();
        var sharedSide = Side(1);
        var allyOne = Player(1);
        var allyTwo = Player(2);
        var enemy = Player(3);
        service.RegisterParticipant(new MatchParticipant(allyOne, sharedSide, true));
        service.RegisterParticipant(new MatchParticipant(allyTwo, sharedSide, false));
        service.RegisterParticipant(new MatchParticipant(enemy, Side(2), false));
        service.RegisterCombatant(new MatchCombatant(Unit(1), allyTwo, true));
        service.RegisterCombatant(new MatchCombatant(Unit(2), enemy, true));

        Check(service.StartMatch().Kind == MatchResolutionKind.InProgress,
            "无单位的队友不应让共享阵营出局");
    }

    /// <summary>验证同一批事实全部应用后再评估可以得到平局。</summary>
    private void BatchedAnnihilationDraws()
    {
        var fixture = TwoSides();
        fixture.Service.StartMatch();
        fixture.Service.RemoveCombatant(fixture.FirstUnit);
        fixture.Service.RemoveCombatant(fixture.SecondUnit);

        var result = fixture.Service.Evaluate();

        Check(result.Kind == MatchResolutionKind.Draw,
            "同批次全灭应判为 Draw");
        Check(result.WinningSideIds.Count == 0 && result.SurvivingSideIds.Count == 0,
            "平局不得包含伪胜方或存活方");
    }

    /// <summary>验证纯表现或其他非计分对象不会维持阵营存活。</summary>
    private void NonCountingEntitiesDoNotKeepSideAlive()
    {
        var fixture = TwoSides();
        fixture.Service.RegisterCombatant(
            new MatchCombatant(Unit(3), fixture.SecondPlayer, false));
        fixture.Service.StartMatch();
        fixture.Service.RemoveCombatant(fixture.SecondUnit);

        Check(fixture.Service.Evaluate().WinningSideIds.SequenceEqual([fixture.FirstSide]),
            "非计分实体不得阻止所属阵营淘汰");
    }

    /// <summary>验证重复登记、重复移除与未知身份移除均无副作用。</summary>
    private void DuplicateFactsAreIdempotent()
    {
        var fixture = TwoSides();
        fixture.Service.RegisterParticipant(
            new MatchParticipant(fixture.FirstPlayer, fixture.FirstSide, true));
        fixture.Service.RegisterCombatant(
            new MatchCombatant(fixture.FirstUnit, fixture.FirstPlayer, true));
        var started = fixture.Service.StartMatch();
        fixture.Service.RemoveCombatant(Unit(99));

        Check(fixture.Service.Evaluate().Version == started.Version,
            "未知移除不得创建新评估版本");
        fixture.Service.RemoveCombatant(fixture.SecondUnit);
        fixture.Service.RemoveCombatant(fixture.SecondUnit);
        Check(fixture.Service.Evaluate().Kind == MatchResolutionKind.Won,
            "重复移除不得破坏正确终局");
    }

    /// <summary>验证终局后的生成和死亡事实不能复活或改写结果。</summary>
    private void TerminalResolutionIsImmutable()
    {
        var fixture = TwoSides();
        fixture.Service.StartMatch();
        fixture.Service.RemoveCombatant(fixture.SecondUnit);
        var terminal = fixture.Service.Evaluate();
        fixture.Service.RegisterCombatant(
            new MatchCombatant(Unit(8), fixture.SecondPlayer, true));
        fixture.Service.RemoveCombatant(fixture.FirstUnit);

        Check(fixture.Service.Evaluate() == terminal,
            "终态必须保持一次性且不可逆");
    }

    /// <summary>验证版本递增且 Side 集合按稳定 Guid 排序。</summary>
    private void SnapshotVersionAndSidesAreStable()
    {
        var fixture = TwoSides(reverseRegistration: true);
        var initial = fixture.Service.StartMatch();
        fixture.Service.RemoveCombatant(fixture.SecondUnit);
        var terminal = fixture.Service.Evaluate();

        Check(initial.Version == 1 && terminal.Version == 2,
            "有效评估应产生只增不减版本");
        Check(initial.SurvivingSideIds.SequenceEqual([fixture.FirstSide, fixture.SecondSide]),
            "存活阵营应按稳定 Guid 排序而非注册顺序");
        Check(fixture.Service.GetSnapshot() == terminal,
            "GetSnapshot 应返回最近权威结果");
    }

    /// <summary>验证仅一方参与的开发测试场景不会在初始化时自动暂停。</summary>
    private void SingleSideDebugMatchDoesNotAutoFinish()
    {
        var service = NewService();
        var player = Player(1);
        service.RegisterParticipant(new MatchParticipant(player, Side(1), true));
        service.RegisterCombatant(new MatchCombatant(Unit(1), player, true));

        Check(service.StartMatch().Kind == MatchResolutionKind.InProgress,
            "单阵营开发场景不应自动结束");
    }

    /// <summary>创建两名玩家各自拥有一个计分实体的标准样例。</summary>
    private static Fixture TwoSides(bool reverseRegistration = false)
    {
        var service = NewService();
        var firstPlayer = Player(1);
        var secondPlayer = Player(2);
        var firstSide = Side(1);
        var secondSide = Side(2);
        var firstUnit = Unit(1);
        var secondUnit = Unit(2);
        var participants = new[]
        {
            new MatchParticipant(firstPlayer, firstSide, true),
            new MatchParticipant(secondPlayer, secondSide, false)
        };
        foreach (var participant in reverseRegistration ? participants.Reverse() : participants)
        {
            service.RegisterParticipant(participant);
        }
        service.RegisterCombatant(new MatchCombatant(firstUnit, firstPlayer, true));
        service.RegisterCombatant(new MatchCombatant(secondUnit, secondPlayer, true));
        return new Fixture(
            service, firstPlayer, secondPlayer, firstSide, secondSide, firstUnit, secondUnit);
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

    private static MatchOutcomeService NewService() => new(new LastSurvivingSideRule());

    private static PlayerId Player(int value) => new(GuidFor(value));

    private static MatchSideId Side(int value) => new(GuidFor(value + 100));

    private static UnitId Unit(int value) => new(GuidFor(value + 200));

    private static Guid GuidFor(int value) => new(value, 0, 0, new byte[8]);

    /// <summary>集中保存标准两方样例的稳定身份。</summary>
    private sealed record Fixture(
        MatchOutcomeService Service,
        PlayerId FirstPlayer,
        PlayerId SecondPlayer,
        MatchSideId FirstSide,
        MatchSideId SecondSide,
        UnitId FirstUnit,
        UnitId SecondUnit);
}
