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
        RunTest(nameof(OfficialUnitHotkeysResolve), OfficialUnitHotkeysResolve);
        RunTest(nameof(TabTogglesAiHud), TabTogglesAiHud);
        RunTest(nameof(F10OpensMenuAndEscapeCancels), F10OpensMenuAndEscapeCancels);
        RunTest(nameof(SpaceFocusesLatestBattlefieldEvent), SpaceFocusesLatestBattlefieldEvent);

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
                InputContextId.LegacyAgent))) == "camera.rotate_clockwise",
            "旧 AI Q 键取消后，Q 应回到镜头旋转");
        Check(Action(service.Resolve(Parse("R"), Contexts(
                InputContextId.LegacyAgent,
                InputContextId.UnitCommand,
                InputContextId.BuildPlacement))) == "build.rotate",
            "建造放置时 R 应旋转蓝图，不触发攻击移动");
        Check(Action(service.Resolve(Parse("R"), Contexts(
                InputContextId.LegacyAgent,
                InputContextId.UnitCommand))) == "unit.attack_move",
            "AI HUD 打开时 R 仍应是正式攻击移动");
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
            [Id("unit.halt")] = "Alt+M"
        });

        Check(!result.Applied, "按钮专用动作的玩家覆盖应被拒绝");
        Check(service.FindChord(Id("unit.halt")) is null,
            "按钮专用动作应始终没有玩家键位");
    }

    /// <summary>验证官方 RTS 单位快捷键已从按钮专用改为默认键位。</summary>
    private void OfficialUnitHotkeysResolve()
    {
        var service = NewService();
        var contexts = Contexts(InputContextId.UnitCommand);

        Check(Action(service.Resolve(Parse("R"), contexts)) == "unit.attack_move",
            "R 应解析为攻击移动");
        Check(Action(service.Resolve(Parse("F"), contexts)) == "unit.stop",
            "F 应解析为完整停止");
        Check(Action(service.Resolve(Parse("G"), contexts)) == "unit.stance_hold_ground",
            "G 应解析为固守");
        Check(Action(service.Resolve(Parse("C"), contexts)) == "unit.force_move",
            "C 应解析为强制移动");
        Check(Action(service.Resolve(Parse("X"), contexts)) == "unit.force_attack",
            "X 应解析为强制攻击");
        Check(Action(service.Resolve(Parse("Z"), contexts)) == "unit.tactical_withdraw",
            "Z 应解析为战术撤退");
        Check(Action(service.Resolve(Parse("T"), contexts)) == "unit.stance_aggressive",
            "T 应解析为侵略");
        Check(Action(service.Resolve(Parse("Y"), contexts)) == "unit.stance_guard",
            "Y 应解析为警戒");
        Check(Action(service.Resolve(Parse("H"), contexts)) == "unit.toggle_hold_fire",
            "H 应解析为停火切换");
        Check(Action(service.Resolve(Parse("B"), contexts)) == "unit.clear_rally",
            "B 应解析为清除集结");
        Check(service.FindChord(Id("legacy.command_move")) is null,
            "旧 AI 移动快捷键不应再占用默认键位");
        Check(service.FindChord(Id("legacy.command_stop")) is null,
            "旧 AI 停止快捷键不应再占用 F");
    }

    /// <summary>验证 Tab 在普通对局上下文中切换 AI 副官 HUD，文本输入时不抢键。</summary>
    private void TabTogglesAiHud()
    {
        var service = NewService();

        Check(Action(service.Resolve(Parse("TAB"), Contexts(
                InputContextId.Global,
                InputContextId.UnitCommand))) == "global.toggle_ai_hud",
            "Tab 应解析为切换 AI 副官 HUD");
        Check(Action(service.Resolve(Parse("TAB"), Contexts(InputContextId.MenuTextInput))) == null,
            "文字输入焦点下 Tab 不应切换 HUD");
    }

    /// <summary>验证 F10 打开暂停菜单，Esc 只取消/返回，不再打开菜单。</summary>
    private void F10OpensMenuAndEscapeCancels()
    {
        var service = NewService();
        var playContexts = Contexts(InputContextId.Global, InputContextId.UnitCommand);

        Check(Action(service.Resolve(Parse("F10"), playContexts)) == "global.toggle_menu",
            "F10 应解析为打开暂停菜单");
        Check(Action(service.Resolve(Parse("ESCAPE"), playContexts)) == "global.cancel",
            "对局中 Esc 应解析为取消/返回");
        Check(Action(service.Resolve(Parse("ESCAPE"), Contexts(InputContextId.MenuTextInput))) ==
                "text.cancel",
            "文字输入焦点下 Esc 应只取消文本焦点");
        Check(Action(service.Resolve(Parse("ESCAPE"), playContexts)) != "global.toggle_menu",
            "Esc 不得再打开暂停菜单");
    }

    /// <summary>验证 Space 在镜头上下文中跳转最近重要战场事件。</summary>
    private void SpaceFocusesLatestBattlefieldEvent()
    {
        var service = NewService();
        Check(
            Action(service.Resolve(Parse("SPACE"), Contexts(InputContextId.Camera))) ==
                "camera.focus_latest_event",
            "Space 应解析为跳转最近战场事件");
        Check(
            Action(service.Resolve(Parse("SPACE"), Contexts(InputContextId.MenuTextInput))) == null,
            "文字输入焦点下 Space 不应跳转镜头");
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
