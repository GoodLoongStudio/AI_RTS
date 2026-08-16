namespace AI_RTS.Domain.Input;

/// <summary>标识可由输入系统分派或由按钮/系统直接调用的稳定动作。</summary>
/// <param name="Value">跨配置版本保持稳定的动作键。</param>
public readonly record struct InputActionId(string Value);

/// <summary>区分同一物理按键在不同交互状态中的合法含义。</summary>
public enum InputContextId
{
    /// <summary>始终可用的全局操作。</summary>
    Global,
    /// <summary>镜头平移、旋转与缩放。</summary>
    Camera,
    /// <summary>选择单位及追加选择。</summary>
    Selection,
    /// <summary>传统单位命令及控制组。</summary>
    UnitCommand,
    /// <summary>建筑蓝图放置和旋转。</summary>
    BuildPlacement,
    /// <summary>菜单或文本框正在接收键盘输入。</summary>
    MenuTextInput,
    /// <summary>冻结期 Legacy AI 副官界面。</summary>
    LegacyAgent,
    /// <summary>仅开发和测试构建使用的诊断操作。</summary>
    Debug
}

/// <summary>首版允许与一个普通键组合的唯一功能修饰键。</summary>
public enum InputModifier
{
    /// <summary>没有功能修饰键。</summary>
    None,
    /// <summary>Shift 修饰键。</summary>
    Shift,
    /// <summary>Ctrl 修饰键。</summary>
    Ctrl,
    /// <summary>Alt 修饰键。</summary>
    Alt
}

/// <summary>表示规范化的“零或一个修饰键 + 一个普通键”键盘手势。</summary>
/// <param name="Key">规范化大写物理键名。</param>
/// <param name="Modifier">唯一功能修饰键。</param>
public readonly record struct InputChord(string Key, InputModifier Modifier)
{
    /// <summary>组合键比同一普通键的裸键具有更高匹配特异度。</summary>
    public int Specificity => Modifier == InputModifier.None ? 1 : 2;
}

/// <summary>声明稳定动作、上下文、默认键位与是否允许玩家直接绑定。</summary>
/// <param name="ActionId">稳定动作 ID。</param>
/// <param name="Context">动作生效的输入上下文。</param>
/// <param name="DefaultChord">默认键位；按钮/系统专用动作允许为空。</param>
/// <param name="PlayerBindable">是否允许从玩家配置覆盖键位。</param>
public sealed record InputBindingDefinition(
    InputActionId ActionId,
    InputContextId Context,
    InputChord? DefaultChord,
    bool PlayerBindable);

/// <summary>输入解析的稳定状态。</summary>
public enum InputResolutionStatus
{
    /// <summary>没有活动动作匹配该按键。</summary>
    None,
    /// <summary>唯一动作获得本次按键。</summary>
    Resolved,
    /// <summary>同优先级存在多个动作，系统拒绝猜测。</summary>
    Ambiguous
}

/// <summary>返回唯一动作或同优先级冲突动作集合。</summary>
/// <param name="Status">解析状态。</param>
/// <param name="ActionId">成功时的动作 ID。</param>
/// <param name="Candidates">歧义时按稳定 ID 排序的候选动作。</param>
public sealed record InputResolution(
    InputResolutionStatus Status,
    InputActionId? ActionId,
    IReadOnlyList<InputActionId> Candidates);

/// <summary>描述一个上下文内无法同时保留的重复键位。</summary>
/// <param name="Context">发生冲突的上下文。</param>
/// <param name="Chord">重复物理键位。</param>
/// <param name="ActionIds">冲突动作 ID。</param>
public sealed record InputBindingConflict(
    InputContextId Context,
    InputChord Chord,
    IReadOnlyList<InputActionId> ActionIds);
