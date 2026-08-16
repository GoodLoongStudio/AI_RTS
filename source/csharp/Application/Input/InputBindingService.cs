using AI_RTS.Domain.Input;

namespace AI_RTS.Application.Input;

/// <summary>输入配置覆盖失败的稳定类别。</summary>
public enum InputBindingErrorCode
{
    /// <summary>动作 ID 不存在。</summary>
    UnknownAction,
    /// <summary>动作只能由按钮或系统调用，不能绑定玩家按键。</summary>
    ActionNotBindable,
    /// <summary>键位文本不是首版支持的零/单修饰键格式。</summary>
    InvalidChord,
    /// <summary>覆盖后同一上下文出现重复键位。</summary>
    BindingConflict
}
/// <summary>记录可定位的输入配置错误。</summary>
/// <param name="Code">稳定错误码。</param>
/// <param name="ActionId">相关动作 ID；整体冲突允许为空。</param>
/// <param name="Message">面向开发者的中文诊断。</param>
public sealed record InputBindingError(
    InputBindingErrorCode Code,
    InputActionId? ActionId,
    string Message);

/// <summary>返回覆盖是否完整应用；存在任一错误时保持旧快照。</summary>
/// <param name="Applied">是否应用全部覆盖。</param>
/// <param name="Errors">稳定错误集合。</param>
public sealed record InputBindingUpdateResult(
    bool Applied,
    IReadOnlyList<InputBindingError> Errors);

/// <summary>提供输入解析、配置覆盖、恢复默认和冲突查询。</summary>
public interface IInputBindingService
{
    /// <summary>按动作 ID 查询当前有效键位；按钮专用动作返回 null。</summary>
    InputChord? FindChord(InputActionId actionId);

    /// <summary>在活动上下文中解析一次精确按键；最多返回一个动作。</summary>
    InputResolution Resolve(InputChord chord, IReadOnlySet<InputContextId> activeContexts);

    /// <summary>原子应用玩家覆盖；非法或冲突配置不会部分生效。</summary>
    InputBindingUpdateResult ApplyOverrides(IReadOnlyDictionary<InputActionId, string> overrides);

    /// <summary>恢复仓库默认绑定。</summary>
    void RestoreDefaults();

    /// <summary>返回当前快照内全部同上下文冲突。</summary>
    IReadOnlyList<InputBindingConflict> FindConflicts();
}

/// <summary>实现精确组合键优先、上下文隔离和原子玩家覆盖。</summary>
public sealed class InputBindingService : IInputBindingService
{
    private readonly IReadOnlyDictionary<InputActionId, InputBindingDefinition> _definitions;
    private Dictionary<InputActionId, InputChord?> _bindings;

    /// <summary>验证动作 ID 唯一并建立默认不可歧义快照。</summary>
    public InputBindingService(IEnumerable<InputBindingDefinition> definitions)
    {
        var definitionArray = definitions.ToArray();
        if (definitionArray.Any(item => string.IsNullOrWhiteSpace(item.ActionId.Value)) ||
            definitionArray.Select(item => item.ActionId).Distinct().Count() != definitionArray.Length)
        {
            throw new ArgumentException("输入动作 ID 必须非空且唯一。", nameof(definitions));
        }
        if (definitionArray.Any(item => !item.PlayerBindable && item.DefaultChord is not null))
        {
            throw new ArgumentException("按钮/系统专用动作不能声明玩家默认键位。", nameof(definitions));
        }
        _definitions = definitionArray.ToDictionary(item => item.ActionId);
        _bindings = DefaultSnapshot();
        if (FindConflicts().Count != 0)
        {
            throw new ArgumentException("默认输入配置存在同上下文冲突。", nameof(definitions));
        }
    }

    /// <inheritdoc />
    public InputChord? FindChord(InputActionId actionId) =>
        _bindings.GetValueOrDefault(actionId);

    /// <inheritdoc />
    public InputResolution Resolve(
        InputChord chord,
        IReadOnlySet<InputContextId> activeContexts)
    {
        var candidates = _definitions.Values
            .Where(item => activeContexts.Contains(item.Context) &&
                _bindings.GetValueOrDefault(item.ActionId) == chord)
            .OrderByDescending(item => ContextPriority(item.Context))
            .ThenByDescending(_ => chord.Specificity)
            .ThenBy(item => item.ActionId.Value, StringComparer.Ordinal)
            .ToArray();
        if (candidates.Length == 0)
        {
            return new InputResolution(InputResolutionStatus.None, null, []);
        }
        var priority = ContextPriority(candidates[0].Context);
        var winners = candidates.Where(item => ContextPriority(item.Context) == priority).ToArray();
        if (winners.Length != 1)
        {
            return new InputResolution(
                InputResolutionStatus.Ambiguous,
                null,
                winners.Select(item => item.ActionId).ToArray());
        }
        return new InputResolution(InputResolutionStatus.Resolved, winners[0].ActionId, []);
    }

    /// <inheritdoc />
    public InputBindingUpdateResult ApplyOverrides(
        IReadOnlyDictionary<InputActionId, string> overrides)
    {
        var errors = new List<InputBindingError>();
        var candidate = new Dictionary<InputActionId, InputChord?>(_bindings);
        foreach (var item in overrides.OrderBy(item => item.Key.Value, StringComparer.Ordinal))
        {
            if (!_definitions.TryGetValue(item.Key, out var definition))
            {
                errors.Add(new InputBindingError(
                    InputBindingErrorCode.UnknownAction,
                    item.Key,
                    $"未知输入动作：{item.Key.Value}。"));
                continue;
            }
            if (!definition.PlayerBindable)
            {
                errors.Add(new InputBindingError(
                    InputBindingErrorCode.ActionNotBindable,
                    item.Key,
                    $"动作 {item.Key.Value} 只能由按钮或系统调用。"));
                continue;
            }
            if (!InputChordParser.TryParse(item.Value, out var chord))
            {
                errors.Add(new InputBindingError(
                    InputBindingErrorCode.InvalidChord,
                    item.Key,
                    $"键位 {item.Value} 不是受支持的单键或单修饰组合键。"));
                continue;
            }
            candidate[item.Key] = chord;
        }
        if (errors.Count != 0)
        {
            return new InputBindingUpdateResult(false, errors.AsReadOnly());
        }

        var old = _bindings;
        _bindings = candidate;
        var conflicts = FindConflicts();
        if (conflicts.Count != 0)
        {
            _bindings = old;
            return new InputBindingUpdateResult(
                false,
                conflicts.Select(item => new InputBindingError(
                    InputBindingErrorCode.BindingConflict,
                    null,
                    $"上下文 {item.Context} 的 {InputChordParser.Format(item.Chord)} 被多个动作占用。"))
                    .ToArray());
        }
        return new InputBindingUpdateResult(true, []);
    }

    /// <inheritdoc />
    public void RestoreDefaults() => _bindings = DefaultSnapshot();

    /// <inheritdoc />
    public IReadOnlyList<InputBindingConflict> FindConflicts() => _definitions.Values
        .Where(item => _bindings.GetValueOrDefault(item.ActionId) is not null)
        .GroupBy(item => (item.Context, Chord: _bindings[item.ActionId]!.Value))
        .Where(group => group.Count() > 1)
        .OrderBy(group => group.Key.Context)
        .ThenBy(group => InputChordParser.Format(group.Key.Chord), StringComparer.Ordinal)
        .Select(group => new InputBindingConflict(
            group.Key.Context,
            group.Key.Chord,
            group.Select(item => item.ActionId)
                .OrderBy(item => item.Value, StringComparer.Ordinal).ToArray()))
        .ToArray();

    private Dictionary<InputActionId, InputChord?> DefaultSnapshot() =>
        _definitions.Values.ToDictionary(item => item.ActionId, item => item.DefaultChord);

    private static int ContextPriority(InputContextId context) => context switch
    {
        InputContextId.MenuTextInput => 700,
        InputContextId.BuildPlacement => 600,
        InputContextId.LegacyAgent => 500,
        InputContextId.UnitCommand => 400,
        InputContextId.Selection => 300,
        InputContextId.Camera => 200,
        InputContextId.Global => 100,
        InputContextId.Debug => 50,
        _ => 0
    };
}

/// <summary>解析和格式化首版键盘组合键文本。</summary>
public static class InputChordParser
{
    private static readonly HashSet<string> ModifierNames =
        new(["SHIFT", "CTRL", "ALT"], StringComparer.Ordinal);

    /// <summary>只接受普通键或一个 Shift/Ctrl/Alt 加普通键。</summary>
    public static bool TryParse(string text, out InputChord chord)
    {
        chord = default;
        if (string.IsNullOrWhiteSpace(text))
        {
            return false;
        }
        var parts = text.Split('+', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length is < 1 or > 2)
        {
            return false;
        }
        var modifier = InputModifier.None;
        var key = parts[^1].ToUpperInvariant();
        if (parts.Length == 2 && !Enum.TryParse<InputModifier>(parts[0], true, out modifier))
        {
            return false;
        }
        if (modifier == InputModifier.None && parts.Length == 2 ||
            ModifierNames.Contains(key) || key.Any(char.IsWhiteSpace))
        {
            return false;
        }
        chord = new InputChord(key, modifier);
        return true;
    }

    /// <summary>生成可写入 controls.cfg 的稳定文本。</summary>
    public static string Format(InputChord chord) => chord.Modifier == InputModifier.None ?
        chord.Key : $"{chord.Modifier}+{chord.Key}";
}
