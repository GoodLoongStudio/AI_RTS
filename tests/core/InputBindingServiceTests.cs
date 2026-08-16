using AI_RTS.Application.Input;
using AI_RTS.Domain.Input;

namespace AI_RTS.Tests.Core;

/// <summary>验证集中式输入的组合键优先级、上下文隔离和配置原子性。</summary>
internal sealed class InputBindingServiceTests
{
    private int _failures;
    private int _tests;

    /// <summary>执行全部纯 C# 输入规则测试。</summary>
    public int Run()
    {
        RunTest(nameof(ModifierChordSuppressesBareKey), ModifierChordSuppressesBareKey);
        RunTest(nameof(HigherPriorityContextWins), HigherPriorityContextWins);
        RunTest(nameof(FirstDemoRejectsMultipleModifiers), FirstDemoRejectsMultipleModifiers);
        RunTest(nameof(InvalidOverrideIsAtomic), InvalidOverrideIsAtomic);
        RunTest(nameof(SameContextConflictIsRejected), SameContextConflictIsRejected);
        RunTest(nameof(ButtonOnlyActionCannotBeBound), ButtonOnlyActionCannotBeBound);

        Console.WriteLine($"Input binding tests completed: {_tests} test(s), {_failures} failure(s).");
        return _failures == 0 ? 0 : 1;
    }

    /// <summary>验证 Ctrl+数字只触发编组保存，不会同时触发单数字访问。</summary>
    private void ModifierChordSuppressesBareKey()
    {
        var service = NewService();
        var contexts = Contexts(InputContextId.UnitCommand);

        Check(Action(service.Resolve(Parse("Ctrl+1"), contexts)) == "group.set_1",
            "Ctrl+1 应仅解析为编组保存");
        Check(Action(service.Resolve(Parse("1"), contexts)) == "group.access_1",
            "单独 1 应解析为编组访问");
    }

    /// <summary>验证同一物理键在多个活动上下文中只交给优先级最高者。</summary>
    private void HigherPriorityContextWins()
    {
        var service = NewService();

        Check(Action(service.Resolve(Parse("Q"), Contexts(
                InputContextId.Camera,
                InputContextId.LegacyAgent))) == "legacy.command_move",
            "LegacyAgent 打开时 Q 应屏蔽镜头旋转");
        Check(Action(service.Resolve(Parse("R"), Contexts(
                InputContextId.LegacyAgent,
                InputContextId.BuildPlacement))) == "build.rotate",
            "建造放置时 R 应屏蔽 Legacy 侦察命令");
    }

    /// <summary>验证首版允许 Alt+字母，但拒绝两个以上修饰键。</summary>
    private void FirstDemoRejectsMultipleModifiers()
    {
        Check(InputChordParser.TryParse("Alt+X", out _), "Alt+X 应属于首版支持格式");
        Check(!InputChordParser.TryParse("Ctrl+Shift+X", out _),
            "Ctrl+Shift+X 应等待后续优先级方案");
    }

    /// <summary>验证任一非法项都会使整批覆盖失败且旧绑定保持不变。</summary>
    private void InvalidOverrideIsAtomic()
    {
        var service = NewService();
        var result = service.ApplyOverrides(new Dictionary<InputActionId, string>
        {
            [Id("camera.move_up")] = "Alt+I",
            [Id("camera.move_down")] = "Ctrl+Shift+K"
        });

        Check(!result.Applied, "含非法组合键的覆盖批次应整体拒绝");
        Check(service.FindChord(Id("camera.move_up")) == Parse("W"),
            "整体拒绝后合法项也不应部分生效");
    }

    /// <summary>验证同一上下文中的重复绑定会被拒绝。</summary>
    private void SameContextConflictIsRejected()
    {
        var service = NewService();
        var result = service.ApplyOverrides(new Dictionary<InputActionId, string>
        {
            [Id("camera.move_up")] = "S"
        });

        Check(!result.Applied, "同一 Camera 上下文的重复 S 应被拒绝");
        Check(result.Errors.Any(item => item.Code == InputBindingErrorCode.BindingConflict),
            "重复绑定应返回稳定的 BindingConflict 错误");
    }

    /// <summary>验证内部或按钮专用动作不能从本地配置获得玩家按键。</summary>
    private void ButtonOnlyActionCannotBeBound()
    {
        var service = NewService();
        var result = service.ApplyOverrides(new Dictionary<InputActionId, string>
        {
            [Id("unit.force_move")] = "Alt+M"
        });

        Check(!result.Applied, "按钮专用动作的玩家覆盖应被拒绝");
        Check(service.FindChord(Id("unit.force_move")) is null,
            "按钮专用动作应始终没有玩家键位");
    }

    private static InputBindingService NewService() =>
        new(DefaultInputBindings.Create());

    private static InputActionId Id(string value) => new(value);

    private static HashSet<InputContextId> Contexts(params InputContextId[] contexts) =>
        contexts.ToHashSet();

    private static InputChord Parse(string value)
    {
        if (!InputChordParser.TryParse(value, out var chord))
        {
            throw new InvalidOperationException($"测试键位无法解析：{value}");
        }
        return chord;
    }

    private static string? Action(InputResolution resolution) => resolution.ActionId?.Value;

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
