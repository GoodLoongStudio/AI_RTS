using AI_RTS.Application.Input;
using AI_RTS.Domain.Input;
using Godot;

namespace AI_RTS.GodotAdapter.Input;

/// <summary>在 Match 生命周期内统一解析键盘组合、上下文和本地玩家覆盖。</summary>
public partial class InputBindingRuntime : Node
{
    /// <summary>玩家覆盖文件结构版本。</summary>
    public const int ControlsSchemaVersion = 2;

    /// <summary>玩家本地键位覆盖路径；不进入 Git 仓库。</summary>
    [Export(PropertyHint.File, "*.cfg")]
    public string ControlsPath { get; set; } = "user://controls.cfg";

    /// <summary>唯一动作按下且获得最高优先级时发布。</summary>
    [Signal]
    public delegate void ActionPressedEventHandler(string actionId);

    /// <summary>已分派动作对应物理键释放或上下文失效时发布。</summary>
    [Signal]
    public delegate void ActionReleasedEventHandler(string actionId);

    private readonly IReadOnlyList<InputBindingDefinition> _definitions =
        DefaultInputBindings.Create();
    private readonly HashSet<InputContextId> _activeContexts =
    [
        InputContextId.Global,
        InputContextId.Camera,
        InputContextId.Selection,
        InputContextId.UnitCommand
    ];
    private readonly Dictionary<long, InputActionId> _pressedKeys = new();
    private readonly HashSet<InputActionId> _pressedActions = [];
    private HashSet<InputContextId>? _contextsBeforeTextInput;
    private IInputBindingService _service = null!;

    /// <summary>装配默认绑定并原子加载 user://controls.cfg 覆盖。</summary>
    public override void _Ready()
    {
        _service = new InputBindingService(_definitions);
        LoadUserOverrides();
    }

    /// <summary>在其他 Legacy `_unhandled_input` 之前解析并消费已注册键盘动作。</summary>
    public override void _Input(InputEvent @event)
    {
        if (@event is not InputEventKey key || key.Echo)
        {
            return;
        }
        var keyIdentity = Identity(key);
        if (!key.Pressed)
        {
            Release(keyIdentity);
            return;
        }
        if (_pressedKeys.ContainsKey(keyIdentity) || !TryCreateChord(key, out var chord))
        {
            return;
        }
        var resolution = _service.Resolve(chord, _activeContexts);
        if (resolution.Status == InputResolutionStatus.Ambiguous)
        {
            GD.PushError($"输入冲突未分派：{InputChordParser.Format(chord)} -> " +
                string.Join(", ", resolution.Candidates.Select(item => item.Value)));
            GetViewport().SetInputAsHandled();
            return;
        }
        if (resolution.Status != InputResolutionStatus.Resolved || resolution.ActionId is null)
        {
            return;
        }
        _pressedKeys[keyIdentity] = resolution.ActionId.Value;
        _pressedActions.Add(resolution.ActionId.Value);
        EmitSignal(SignalName.ActionPressed, resolution.ActionId.Value.Value);
        GetViewport().SetInputAsHandled();
    }

    /// <summary>启停一个输入上下文；切换时释放全部按下动作，避免按键卡住。</summary>
    public void SetContextActive(string contextName, bool active)
    {
        if (!Enum.TryParse<InputContextId>(contextName, true, out var context))
        {
            GD.PushError($"未知输入上下文：{contextName}");
            return;
        }
        var targetContexts = _contextsBeforeTextInput ?? _activeContexts;
        var changed = active ? targetContexts.Add(context) : targetContexts.Remove(context);
        if (changed && _contextsBeforeTextInput is null)
        {
            ReleaseAll();
        }
    }

    /// <summary>进入文本输入模态，只保留文本上下文，避免字母被镜头、编组或命令系统消费。</summary>
    public void EnterTextInputMode()
    {
        if (_contextsBeforeTextInput is not null)
        {
            return;
        }
        _contextsBeforeTextInput = new HashSet<InputContextId>(_activeContexts);
        _activeContexts.Clear();
        _activeContexts.Add(InputContextId.MenuTextInput);
        ReleaseAll();
    }

    /// <summary>退出文本输入模态并恢复进入前的完整上下文快照。</summary>
    public void ExitTextInputMode()
    {
        if (_contextsBeforeTextInput is null)
        {
            return;
        }
        _activeContexts.Clear();
        _activeContexts.UnionWith(_contextsBeforeTextInput);
        _contextsBeforeTextInput = null;
        ReleaseAll();
    }

    /// <summary>查询动作是否由当前获得分派的物理键持续按下。</summary>
    public bool IsActionPressed(string actionId) =>
        _pressedActions.Contains(new InputActionId(actionId));

    /// <summary>查询指定输入上下文当前是否实际参与动作解析，供 UI 状态与自动测试核对。</summary>
    public bool IsContextActive(string contextName) =>
        Enum.TryParse<InputContextId>(contextName, true, out var context) &&
        _activeContexts.Contains(context);

    /// <summary>计算两个数字动作的 -1、0、1 轴值。</summary>
    public float GetAxis(string negativeActionId, string positiveActionId) =>
        (IsActionPressed(positiveActionId) ? 1.0f : 0.0f) -
        (IsActionPressed(negativeActionId) ? 1.0f : 0.0f);

    /// <summary>查询 Shift/Ctrl/Alt 当前物理状态，供追加选择等修饰语义使用。</summary>
    public bool IsModifierPressed(string modifierName) => modifierName.ToUpperInvariant() switch
    {
        "SHIFT" => Godot.Input.IsKeyPressed(Key.Shift),
        "CTRL" => Godot.Input.IsKeyPressed(Key.Ctrl),
        "ALT" => Godot.Input.IsKeyPressed(Key.Alt),
        _ => false
    };

    /// <summary>恢复官方默认绑定并覆盖保存本地 controls.cfg。</summary>
    public void RestoreDefaults()
    {
        _service.RestoreDefaults();
        SaveCurrentBindings();
        ReleaseAll();
    }

    /// <summary>返回动作当前键位文本；按钮/系统专用或未知动作返回空字符串。</summary>
    public string GetBinding(string actionId)
    {
        var chord = _service.FindChord(new InputActionId(actionId));
        return chord is null ? string.Empty : InputChordParser.Format(chord.Value);
    }

    private void LoadUserOverrides()
    {
        var config = new ConfigFile();
        var error = config.Load(ControlsPath);
        if (error == Error.FileNotFound)
        {
            SaveCurrentBindings();
            return;
        }
        if (error != Error.Ok ||
            config.GetValue("meta", "schema_version", 0).AsInt32() != ControlsSchemaVersion)
        {
            GD.PushWarning($"controls.cfg 无法加载或版本不受支持，已重写为当前默认键位：{error}");
            SaveCurrentBindings();
            return;
        }
        var overrides = new Dictionary<InputActionId, string>();
        foreach (var key in config.GetSectionKeys("bindings"))
        {
            overrides[new InputActionId(key)] = config.GetValue("bindings", key).AsString();
        }
        var result = _service.ApplyOverrides(overrides);
        if (!result.Applied)
        {
            GD.PushWarning("controls.cfg 整体拒绝，继续使用默认键位：\n" +
                string.Join("\n", result.Errors.Select(item => $"{item.Code}: {item.Message}")));
        }
    }

    private void SaveCurrentBindings()
    {
        var config = new ConfigFile();
        config.SetValue("meta", "schema_version", ControlsSchemaVersion);
        foreach (var definition in _definitions
            .Where(item => item.PlayerBindable)
            .OrderBy(item => item.ActionId.Value, StringComparer.Ordinal))
        {
            config.SetValue(
                "bindings",
                definition.ActionId.Value,
                GetBinding(definition.ActionId.Value));
        }
        var error = config.Save(ControlsPath);
        if (error != Error.Ok)
        {
            GD.PushWarning($"无法保存 {ControlsPath}：{error}");
        }
    }

    private void Release(long keyIdentity)
    {
        if (!_pressedKeys.Remove(keyIdentity, out var actionId))
        {
            return;
        }
        _pressedActions.Remove(actionId);
        EmitSignal(SignalName.ActionReleased, actionId.Value);
        GetViewport().SetInputAsHandled();
    }

    private void ReleaseAll()
    {
        foreach (var actionId in _pressedActions.OrderBy(item => item.Value, StringComparer.Ordinal))
        {
            EmitSignal(SignalName.ActionReleased, actionId.Value);
        }
        _pressedKeys.Clear();
        _pressedActions.Clear();
    }

    private static bool TryCreateChord(InputEventKey key, out InputChord chord)
    {
        chord = default;
        var modifierCount = (key.ShiftPressed ? 1 : 0) +
            (key.CtrlPressed ? 1 : 0) + (key.AltPressed ? 1 : 0) +
            (key.MetaPressed ? 1 : 0);
        if (modifierCount > 1 || key.MetaPressed)
        {
            return false;
        }
        var modifier = key.ShiftPressed ? InputModifier.Shift :
            key.CtrlPressed ? InputModifier.Ctrl :
            key.AltPressed ? InputModifier.Alt : InputModifier.None;
        var code = key.PhysicalKeycode == Key.None ? key.Keycode : key.PhysicalKeycode;
        var name = OS.GetKeycodeString(code).Trim().ToUpperInvariant();
        if (string.IsNullOrWhiteSpace(name) || name is "SHIFT" or "CTRL" or "ALT" or "META")
        {
            return false;
        }
        chord = new InputChord(name, modifier);
        return true;
    }

    private static long Identity(InputEventKey key)
    {
        var code = key.PhysicalKeycode == Key.None ? key.Keycode : key.PhysicalKeycode;
        return (long)code;
    }
}
