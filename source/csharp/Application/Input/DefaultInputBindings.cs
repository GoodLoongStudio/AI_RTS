using AI_RTS.Domain.Input;

namespace AI_RTS.Application.Input;

/// <summary>保存 Demo 官方默认键位和按钮/系统专用动作清单。</summary>
public static class DefaultInputBindings
{
    /// <summary>创建新的只读定义集合，供 Match 输入组合根与纯 C# 测试共同使用。</summary>
    public static IReadOnlyList<InputBindingDefinition> Create()
    {
        var result = new List<InputBindingDefinition>
        {
            Bind("global.toggle_menu", InputContextId.Global, "F10"),
            Bind("global.cancel", InputContextId.Global, "ESCAPE"),
            Bind("global.toggle_ai_hud", InputContextId.Global, "TAB"),
            Bind("text.cancel", InputContextId.MenuTextInput, "ESCAPE"),
            Bind("camera.move_up", InputContextId.Camera, "W"),
            Bind("camera.move_down", InputContextId.Camera, "S"),
            Bind("camera.move_left", InputContextId.Camera, "A"),
            Bind("camera.move_right", InputContextId.Camera, "D"),
            Bind("camera.rotate_clockwise", InputContextId.Camera, "Q"),
            Bind("camera.rotate_counterclockwise", InputContextId.Camera, "E"),
            Bind("camera.focus_latest_event", InputContextId.Camera, "SPACE"),
            Bind("build.rotate", InputContextId.BuildPlacement, "R"),
            Bind("legacy.hero_focus", InputContextId.LegacyAgent, "F1"),
            Bind("legacy.chat_focus", InputContextId.LegacyAgent, "ENTER"),
            Bind("legacy.squad_1", InputContextId.LegacyAgent, "1"),
            Bind("legacy.squad_2", InputContextId.LegacyAgent, "2"),
            Bind("legacy.squad_3", InputContextId.LegacyAgent, "3"),
            Bind("legacy.command_move", InputContextId.LegacyAgent, "U"),
            Bind("legacy.command_attack", InputContextId.LegacyAgent, "I"),
            Bind("legacy.command_defend", InputContextId.LegacyAgent, "O"),
            Bind("legacy.command_scout", InputContextId.LegacyAgent, "P"),
            Bind("legacy.command_retreat", InputContextId.LegacyAgent, "J"),
            Bind("legacy.command_stop", InputContextId.LegacyAgent, "K"),
            Bind("unit.attack_move", InputContextId.UnitCommand, "R"),
            Bind("unit.stop", InputContextId.UnitCommand, "F"),
            Bind("unit.stance_hold_ground", InputContextId.UnitCommand, "G"),
            Bind("unit.force_move", InputContextId.UnitCommand, "C"),
            Bind("unit.force_attack", InputContextId.UnitCommand, "X"),
            Bind("unit.tactical_withdraw", InputContextId.UnitCommand, "Z"),
            Bind("unit.stance_aggressive", InputContextId.UnitCommand, "T"),
            Bind("unit.stance_guard", InputContextId.UnitCommand, "Y"),
            Bind("unit.stance_return_to_base", InputContextId.UnitCommand, "V"),
            Bind("unit.toggle_hold_fire", InputContextId.UnitCommand, "H"),
            Bind("unit.clear_rally", InputContextId.UnitCommand, "B"),
            ButtonOnly("unit.halt")
        };
        for (var index = 1; index <= 9; index++)
        {
            result.Add(Bind($"group.access_{index}", InputContextId.UnitCommand, index.ToString()));
            result.Add(Bind(
                $"group.set_{index}", InputContextId.UnitCommand, $"Ctrl+{index}"));
        }
        return result.AsReadOnly();
    }

    private static InputBindingDefinition Bind(
        string actionId,
        InputContextId context,
        string chordText)
    {
        if (!InputChordParser.TryParse(chordText, out var chord))
        {
            throw new InvalidOperationException($"无效官方默认键位：{actionId}={chordText}。");
        }
        return new InputBindingDefinition(new InputActionId(actionId), context, chord, true);
    }

    private static InputBindingDefinition ButtonOnly(
        string actionId,
        InputContextId context = InputContextId.UnitCommand) => new(
        new InputActionId(actionId), context, null, false);
}
