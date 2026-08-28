using AI_RTS.Domain.Common;

namespace AI_RTS.Domain.Economy;

/// <summary>表示一种资源的非负绝对数量。</summary>
/// <param name="Kind">资源种类。</param>
/// <param name="Amount">资源数量。</param>
public readonly record struct ResourceAmount(ResourceKind Kind, int Amount);

/// <summary>表示一种资源的有符号变化量；正数入账，负数扣款。</summary>
/// <param name="Kind">资源种类。</param>
/// <param name="Amount">变化数量；普通交易中不得为零。</param>
public readonly record struct ResourceDelta(ResourceKind Kind, int Amount);

/// <summary>表示某个玩家资源账户的只读权威快照。</summary>
/// <param name="PlayerId">账户所属玩家。</param>
/// <param name="Balances">按资源种类保存的余额集合。</param>
/// <param name="Version">每次成功交易后递增的账户版本。</param>
public sealed record ResourceAccountSnapshot(
    PlayerId PlayerId,
    IReadOnlyDictionary<ResourceKind, int> Balances,
    long Version)
{
    /// <summary>读取指定种类的余额；快照未显式包含该种类时返回零。</summary>
    public int GetBalance(ResourceKind kind) => Balances.GetValueOrDefault(kind);
}

/// <summary>说明资源变化发生的业务原因。</summary>
public enum ResourceChangeReason
{
    /// <summary>建立账户时导入初始资源。</summary>
    InitialBalance,

    /// <summary>Worker 抵达有效交付点后交付载荷。</summary>
    WorkerDelivery,

    /// <summary>开始放置或建造建筑时支付成本。</summary>
    ConstructionCost,

    /// <summary>取消建筑时退还资源。</summary>
    ConstructionRefund,

    /// <summary>单位进入生产队列时支付成本。</summary>
    ProductionCost,

    /// <summary>主动技能正式生效时支付消耗。</summary>
    SkillCost,

    /// <summary>中断已生效技能时按配置退还消耗。</summary>
    SkillRefund,

    /// <summary>取消生产时退还资源。</summary>
    ProductionRefund,

    /// <summary>战役或任务目标完成后的奖励。</summary>
    MissionReward,

    /// <summary>资源建筑按模拟时间产生的收入。</summary>
    PassiveIncome,

    /// <summary>关卡脚本、调试工具或兼容代码产生的明确调整。</summary>
    ScriptedAdjustment
}
