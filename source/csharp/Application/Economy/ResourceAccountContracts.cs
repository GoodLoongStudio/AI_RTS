using AI_RTS.Domain.Common;
using AI_RTS.Domain.Economy;

namespace AI_RTS.Application.Economy;

/// <summary>请求建立玩家资源账户并导入一次初始余额。</summary>
public sealed record OpenResourceAccount(
    ResourceTransactionId TransactionId,
    MatchId MatchId,
    PlayerId PlayerId,
    IReadOnlyList<ResourceAmount> InitialBalances,
    long SimulationTick);

/// <summary>请求以一笔原子交易改变指定玩家的资源余额。</summary>
public sealed record ApplyResourceTransaction(
    ResourceTransactionId TransactionId,
    MatchId MatchId,
    PlayerId PlayerId,
    IReadOnlyList<ResourceDelta> Deltas,
    ResourceChangeReason Reason,
    Guid? SourceId,
    long SimulationTick);

/// <summary>表示资源交易的权威处理状态。</summary>
public enum ResourceTransactionStatus
{
    /// <summary>交易已完整应用。</summary>
    Applied,

    /// <summary>相同交易已经应用，本次没有再次修改余额。</summary>
    AlreadyApplied,

    /// <summary>账户不存在。</summary>
    AccountNotFound,

    /// <summary>同一玩家的账户已经建立。</summary>
    AccountAlreadyExists,

    /// <summary>交易结构、数量或来源不合法。</summary>
    InvalidTransaction,

    /// <summary>至少一种资源不足，整笔交易没有应用。</summary>
    InsufficientResources,

    /// <summary>交易会造成数值溢出，整笔交易没有应用。</summary>
    Overflow,

    /// <summary>相同 TransactionId 被用于不同内容。</summary>
    TransactionConflict
}

/// <summary>记录资源交易结果及处理后的权威账户快照。</summary>
public sealed record ResourceTransactionResult(
    ResourceTransactionId TransactionId,
    ResourceTransactionStatus Status,
    ResourceAccountSnapshot? Snapshot);

/// <summary>记录一笔成功交易造成的权威余额变化。</summary>
public sealed record ResourceBalanceChanged(
    ResourceTransactionId TransactionId,
    MatchId MatchId,
    PlayerId PlayerId,
    ResourceChangeReason Reason,
    Guid? SourceId,
    long SimulationTick,
    IReadOnlyList<ResourceDelta> Deltas,
    ResourceAccountSnapshot Snapshot);

/// <summary>提供 Match 范围内统一的资源账户查询与交易入口。</summary>
public interface IResourceAccountService
{
    /// <summary>成功交易后发布一次权威余额变化。</summary>
    event Action<ResourceBalanceChanged>? BalanceChanged;

    /// <summary>建立玩家账户并原子导入初始余额。</summary>
    ResourceTransactionResult Open(OpenResourceAccount request);

    /// <summary>查询玩家当前资源快照；账户不存在时返回 null。</summary>
    ResourceAccountSnapshot? Find(PlayerId playerId);

    /// <summary>原子校验并应用一笔资源交易。</summary>
    ResourceTransactionResult Apply(ApplyResourceTransaction transaction);
}
