using System.Collections.ObjectModel;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Economy;

namespace AI_RTS.Application.Economy;

/// <summary>在单个 Match 内以内存方式保存玩家资源账户并原子处理交易。</summary>
public sealed class InMemoryResourceAccountService : IResourceAccountService
{
    private readonly Dictionary<PlayerId, AccountState> _accounts = new();
    private readonly Dictionary<ResourceTransactionId, AppliedTransaction> _applied = new();

    /// <inheritdoc />
    public event Action<ResourceBalanceChanged>? BalanceChanged;

    /// <inheritdoc />
    public ResourceTransactionResult Open(OpenResourceAccount request)
    {
        var canonical = CanonicalizeInitialBalances(request.InitialBalances);
        if (canonical is null || request.TransactionId.Value == Guid.Empty ||
            request.MatchId.Value == Guid.Empty || request.PlayerId.Value == Guid.Empty)
        {
            return Result(request.TransactionId, ResourceTransactionStatus.InvalidTransaction);
        }

        var fingerprint = TransactionFingerprint.ForOpen(request, canonical);
        if (TryReplay(request.TransactionId, fingerprint, out var replay))
        {
            return replay;
        }

        if (_accounts.ContainsKey(request.PlayerId))
        {
            return Result(request.TransactionId, ResourceTransactionStatus.AccountAlreadyExists);
        }

        var balances = Enum.GetValues<ResourceKind>().ToDictionary(kind => kind, _ => 0);
        foreach (var amount in canonical)
        {
            balances[amount.Kind] = amount.Amount;
        }

        var account = new AccountState(balances, 1);
        _accounts.Add(request.PlayerId, account);
        var snapshot = Snapshot(request.PlayerId, account);
        var result = new ResourceTransactionResult(
            request.TransactionId,
            ResourceTransactionStatus.Applied,
            snapshot);
        _applied.Add(request.TransactionId, new AppliedTransaction(fingerprint, snapshot));
        BalanceChanged?.Invoke(new ResourceBalanceChanged(
            request.TransactionId,
            request.MatchId,
            request.PlayerId,
            ResourceChangeReason.InitialBalance,
            null,
            request.SimulationTick,
            canonical.Select(amount => new ResourceDelta(amount.Kind, amount.Amount)).ToArray(),
            snapshot));
        return result;
    }

    /// <inheritdoc />
    public ResourceAccountSnapshot? Find(PlayerId playerId) =>
        _accounts.TryGetValue(playerId, out var account) ? Snapshot(playerId, account) : null;

    /// <inheritdoc />
    public ResourceTransactionResult Apply(ApplyResourceTransaction transaction)
    {
        var canonical = CanonicalizeDeltas(transaction.Deltas);
        if (canonical is null || transaction.TransactionId.Value == Guid.Empty ||
            transaction.MatchId.Value == Guid.Empty || transaction.PlayerId.Value == Guid.Empty ||
            !Enum.IsDefined(transaction.Reason) ||
            transaction.Reason == ResourceChangeReason.InitialBalance ||
            transaction.SourceId == Guid.Empty || !DeltasMatchReason(canonical, transaction.Reason))
        {
            return Result(transaction.TransactionId, ResourceTransactionStatus.InvalidTransaction);
        }

        var fingerprint = TransactionFingerprint.ForApply(transaction, canonical);
        if (TryReplay(transaction.TransactionId, fingerprint, out var replay))
        {
            return replay;
        }

        if (!_accounts.TryGetValue(transaction.PlayerId, out var account))
        {
            return Result(transaction.TransactionId, ResourceTransactionStatus.AccountNotFound);
        }

        var next = new Dictionary<ResourceKind, int>(account.Balances);
        try
        {
            foreach (var delta in canonical)
            {
                var balance = checked(next.GetValueOrDefault(delta.Kind) + delta.Amount);
                if (balance < 0)
                {
                    return Result(
                        transaction.TransactionId,
                        ResourceTransactionStatus.InsufficientResources,
                        Snapshot(transaction.PlayerId, account));
                }
                next[delta.Kind] = balance;
            }
        }
        catch (OverflowException)
        {
            return Result(
                transaction.TransactionId,
                ResourceTransactionStatus.Overflow,
                Snapshot(transaction.PlayerId, account));
        }

        account.Balances = next;
        account.Version = checked(account.Version + 1);
        var snapshot = Snapshot(transaction.PlayerId, account);
        var result = new ResourceTransactionResult(
            transaction.TransactionId,
            ResourceTransactionStatus.Applied,
            snapshot);
        _applied.Add(transaction.TransactionId, new AppliedTransaction(fingerprint, snapshot));
        BalanceChanged?.Invoke(new ResourceBalanceChanged(
            transaction.TransactionId,
            transaction.MatchId,
            transaction.PlayerId,
            transaction.Reason,
            transaction.SourceId,
            transaction.SimulationTick,
            canonical,
            snapshot));
        return result;
    }

    /// <summary>规范化初始余额并拒绝重复资源、负数和未知枚举。</summary>
    private static ResourceAmount[]? CanonicalizeInitialBalances(
        IReadOnlyList<ResourceAmount>? balances)
    {
        if (balances is null)
        {
            return null;
        }

        var kinds = new HashSet<ResourceKind>();
        foreach (var amount in balances)
        {
            if (!Enum.IsDefined(amount.Kind) || amount.Amount < 0 || !kinds.Add(amount.Kind))
            {
                return null;
            }
        }
        return balances.OrderBy(amount => amount.Kind).ToArray();
    }

    /// <summary>规范化普通交易并拒绝空交易、重复资源、零变化和未知枚举。</summary>
    private static ResourceDelta[]? CanonicalizeDeltas(IReadOnlyList<ResourceDelta>? deltas)
    {
        if (deltas is null || deltas.Count == 0)
        {
            return null;
        }

        var kinds = new HashSet<ResourceKind>();
        foreach (var delta in deltas)
        {
            if (!Enum.IsDefined(delta.Kind) || delta.Amount == 0 || !kinds.Add(delta.Kind))
            {
                return null;
            }
        }
        return deltas.OrderBy(delta => delta.Kind).ToArray();
    }

    /// <summary>校验业务原因与资源变化方向一致，防止成本意外变成收入。</summary>
    private static bool DeltasMatchReason(
        IReadOnlyList<ResourceDelta> deltas,
        ResourceChangeReason reason) => reason switch
        {
            ResourceChangeReason.ConstructionCost or ResourceChangeReason.ProductionCost =>
                deltas.All(delta => delta.Amount < 0),
            ResourceChangeReason.ScriptedAdjustment => true,
            _ => deltas.All(delta => delta.Amount > 0)
        };

    /// <summary>处理已成功交易的幂等重放，并识别相同 ID 的内容冲突。</summary>
    private bool TryReplay(
        ResourceTransactionId transactionId,
        TransactionFingerprint fingerprint,
        out ResourceTransactionResult result)
    {
        if (!_applied.TryGetValue(transactionId, out var applied))
        {
            result = null!;
            return false;
        }

        result = new ResourceTransactionResult(
            transactionId,
            applied.Fingerprint == fingerprint ?
                ResourceTransactionStatus.AlreadyApplied :
                ResourceTransactionStatus.TransactionConflict,
            applied.Snapshot);
        return true;
    }

    /// <summary>创建不含账户快照的失败结果。</summary>
    private static ResourceTransactionResult Result(
        ResourceTransactionId transactionId,
        ResourceTransactionStatus status,
        ResourceAccountSnapshot? snapshot = null) => new(transactionId, status, snapshot);

    /// <summary>复制账户数据，避免调用者修改内部余额。</summary>
    private static ResourceAccountSnapshot Snapshot(PlayerId playerId, AccountState account) => new(
        playerId,
        new ReadOnlyDictionary<ResourceKind, int>(
            new Dictionary<ResourceKind, int>(account.Balances)),
        account.Version);

    /// <summary>保存单个玩家账户的可变内部状态。</summary>
    private sealed class AccountState(Dictionary<ResourceKind, int> balances, long version)
    {
        /// <summary>当前各资源余额。</summary>
        public Dictionary<ResourceKind, int> Balances { get; set; } = balances;

        /// <summary>当前账户版本。</summary>
        public long Version { get; set; } = version;
    }

    /// <summary>保存已成功交易的规范内容和首次应用后的快照。</summary>
    private sealed record AppliedTransaction(
        TransactionFingerprint Fingerprint,
        ResourceAccountSnapshot Snapshot);

    /// <summary>提供与集合引用无关的交易内容比较。</summary>
    private sealed record TransactionFingerprint(
        string Operation,
        MatchId MatchId,
        PlayerId PlayerId,
        ResourceChangeReason Reason,
        Guid? SourceId,
        long SimulationTick,
        string Amounts)
    {
        /// <summary>为开户请求创建稳定指纹。</summary>
        public static TransactionFingerprint ForOpen(
            OpenResourceAccount request,
            IReadOnlyList<ResourceAmount> balances) => new(
                "Open",
                request.MatchId,
                request.PlayerId,
                ResourceChangeReason.InitialBalance,
                null,
                request.SimulationTick,
                string.Join(';', balances.Select(value => $"{(int)value.Kind}:{value.Amount}")));

        /// <summary>为普通交易创建稳定指纹。</summary>
        public static TransactionFingerprint ForApply(
            ApplyResourceTransaction request,
            IReadOnlyList<ResourceDelta> deltas) => new(
                "Apply",
                request.MatchId,
                request.PlayerId,
                request.Reason,
                request.SourceId,
                request.SimulationTick,
                string.Join(';', deltas.Select(value => $"{(int)value.Kind}:{value.Amount}")));
    }
}
