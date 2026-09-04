namespace AI_RTS.Domain.Economy;

/// <summary>区分玩家经济系统支持的强类型资源。</summary>
/// <remarks>红警式单资源：当前 Demo 只有“钱”（A 类），历史 B 类资源已移除。</remarks>
public enum ResourceKind
{
    /// <summary>唯一资源：钱。</summary>
    A
}
