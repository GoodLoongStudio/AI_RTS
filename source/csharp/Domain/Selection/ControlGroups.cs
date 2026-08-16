namespace AI_RTS.Domain.Selection;

/// <summary>标识玩家在一场对局内使用的传统控制组编号。</summary>
/// <param name="Value">首版允许的数字编号，范围为 1～9。</param>
public readonly record struct ControlGroupNumber(int Value)
{
    /// <summary>返回编号是否属于首版支持的 1～9 范围。</summary>
    public bool IsValid => Value is >= 1 and <= 9;
}
