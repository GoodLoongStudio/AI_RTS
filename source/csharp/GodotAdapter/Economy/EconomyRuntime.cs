using AI_RTS.Application.Economy;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Economy;
using AI_RTS.GodotAdapter.Common;
using Godot;

namespace AI_RTS.GodotAdapter.Economy;

/// <summary>在一个 Match 内持有唯一资源账户服务，并适配 Legacy Player 字典接口。</summary>
/// <remarks>红警式单资源：账户里只有“钱”（ResourceKind.A / resource_a）。</remarks>
public partial class EconomyRuntime : Node
{
    /// <summary>向 Godot 表现层广播一次已应用的权威余额变化。</summary>
    [Signal]
    public delegate void BalanceChangedEventHandler(
        string playerId,
        string transactionId,
        string reason,
        int resourceA,
        long version);

    private readonly InMemoryResourceAccountService _accounts = new();
    private readonly Dictionary<PlayerId, WeakReference<Node>> _players = new();
    private readonly MatchId _matchId = new(Guid.NewGuid());

    /// <summary>向同一 Godot Adapter 程序集中的权威业务 Runtime 提供共享账户服务。</summary>
    internal IResourceAccountService AccountService => _accounts;

    /// <summary>返回资源账户所属的当前对局身份。</summary>
    internal MatchId MatchId => _matchId;

    /// <summary>建立当前对局身份并订阅账户权威事件。</summary>
    public override void _Ready()
    {
        _accounts.BalanceChanged += OnBalanceChanged;
    }

    /// <summary>注册 Player Node，并把场景导出数值作为唯一一次初始余额导入。</summary>
    public string RegisterPlayer(Node player, int resourceA)
    {
        var playerId = GodotStableIdentity.Player(player);
        _players[playerId] = new WeakReference<Node>(player);
        if (_accounts.Find(playerId) is null)
        {
            var opened = _accounts.Open(new OpenResourceAccount(
                new ResourceTransactionId(Guid.NewGuid()),
                _matchId,
                playerId,
                [new ResourceAmount(ResourceKind.A, resourceA)],
                CurrentTick()));
            if (opened.Status != ResourceTransactionStatus.Applied)
            {
                GD.PushError($"无法建立玩家资源账户：{opened.Status}");
            }
        }
        else
        {
            PublishSnapshot(playerId, _accounts.Find(playerId)!);
        }
        return playerId.Value.ToString("D");
    }

    /// <summary>判断玩家是否拥有字典指定的全部资源；该结果只供预览，最终扣款仍需提交交易。</summary>
    public bool HasResources(Node player, Godot.Collections.Dictionary resources)
    {
        var playerId = GodotStableIdentity.Player(player);
        var costs = ReadAmounts(resources);
        var snapshot = _accounts.Find(playerId);
        if (costs is null || snapshot is null)
        {
            return false;
        }
        return costs.All(cost => snapshot.GetBalance(cost.Kind) >= cost.Amount);
    }

    /// <summary>把 Legacy 正数字典作为一笔收入交易原子应用。</summary>
    public Godot.Collections.Dictionary AddResources(
        Node player,
        Godot.Collections.Dictionary resources,
        string reason,
        Node? source = null) => ApplyLegacy(player, resources, reason, source, 1);

    /// <summary>把 Legacy 正数字典作为一笔支出交易原子应用。</summary>
    public Godot.Collections.Dictionary SubtractResources(
        Node player,
        Godot.Collections.Dictionary resources,
        string reason,
        Node? source = null) => ApplyLegacy(player, resources, reason, source, -1);

    /// <summary>返回指定玩家的当前权威余额与账户版本，主要供桥接期测试和诊断使用。</summary>
    public Godot.Collections.Dictionary GetSnapshot(Node player)
    {
        var snapshot = _accounts.Find(GodotStableIdentity.Player(player));
        return snapshot is null ? new Godot.Collections.Dictionary() : ToGodot(snapshot);
    }

    /// <summary>解析 Legacy 字典并提交一笔带明确来源的权威资源交易。</summary>
    private Godot.Collections.Dictionary ApplyLegacy(
        Node player,
        Godot.Collections.Dictionary resources,
        string reasonName,
        Node? source,
        int sign)
    {
        var amounts = ReadAmounts(resources);
        if (amounts is null || amounts.Length == 0)
        {
            return ToGodot(new ResourceTransactionResult(
                new ResourceTransactionId(Guid.Empty),
                ResourceTransactionStatus.InvalidTransaction,
                null));
        }

        if (!Enum.TryParse<ResourceChangeReason>(reasonName, out var reason) ||
            reason == ResourceChangeReason.InitialBalance)
        {
            return ToGodot(new ResourceTransactionResult(
                new ResourceTransactionId(Guid.Empty),
                ResourceTransactionStatus.InvalidTransaction,
                null));
        }

        var playerId = GodotStableIdentity.Player(player);
        Guid? sourceId = source is null ? null : GodotStableIdentity.Unit(source).Value;
        var result = _accounts.Apply(new ApplyResourceTransaction(
            new ResourceTransactionId(Guid.NewGuid()),
            _matchId,
            playerId,
            amounts.Select(amount => new ResourceDelta(
                amount.Kind,
                checked(amount.Amount * sign))).ToArray(),
            reason,
            sourceId,
            CurrentTick()));
        GD.Print($"[ECO] ApplyLegacy reason={reasonName} player={playerId.Value.ToString("D")[..8]} status={result.Status} a={result.Snapshot?.GetBalance(ResourceKind.A) ?? -1}");
        return ToGodot(result);
    }

    /// <summary>把 Legacy 正数字典转换为强类型数量集合。</summary>
    private static ResourceAmount[]? ReadAmounts(Godot.Collections.Dictionary resources)
    {
        var result = new List<ResourceAmount>();
        foreach (var keyValue in resources.Keys)
        {
            var name = keyValue.AsString();
            var kind = name switch
            {
                "resource_a" => ResourceKind.A,
                _ => (ResourceKind?)null
            };
            var value = resources[keyValue].AsInt32();
            if (kind is null || value < 0)
            {
                return null;
            }
            if (value > 0)
            {
                result.Add(new ResourceAmount(kind.Value, value));
            }
        }
        return result.ToArray();
    }

    /// <summary>把成功交易同步到 Player 兼容镜像并发布 Godot Signal。</summary>
    private void OnBalanceChanged(ResourceBalanceChanged change)
    {
        PublishSnapshot(change.PlayerId, change.Snapshot);
        EmitSignal(
            SignalName.BalanceChanged,
            change.PlayerId.Value.ToString("D"),
            change.TransactionId.Value.ToString("D"),
            change.Reason.ToString(),
            change.Snapshot.GetBalance(ResourceKind.A),
            change.Snapshot.Version);
    }

    /// <summary>将权威余额写入仍有效的 Player Legacy 只读镜像。</summary>
    private void PublishSnapshot(PlayerId playerId, ResourceAccountSnapshot snapshot)
    {
        if (!_players.TryGetValue(playerId, out var reference) ||
            !reference.TryGetTarget(out var player) || !GodotObject.IsInstanceValid(player))
        {
            GD.Print($"[ECO] PublishSnapshot player={playerId.Value.ToString("D")[..8]} MISSING(未注册或已失效)");
            return;
        }
        GD.Print($"[ECO] PublishSnapshot player={playerId.Value.ToString("D")[..8]} a={snapshot.GetBalance(ResourceKind.A)}");
        player.Call(
            "apply_authoritative_resource_snapshot",
            snapshot.GetBalance(ResourceKind.A),
            snapshot.Version);
    }

    /// <summary>把资源交易结果转换为 GDScript 可读取的稳定字段集合。</summary>
    private static Godot.Collections.Dictionary ToGodot(ResourceTransactionResult result)
    {
        var dictionary = new Godot.Collections.Dictionary
        {
            ["transaction_id"] = result.TransactionId.Value.ToString("D"),
            ["status"] = result.Status.ToString(),
            ["accepted"] = result.Status is ResourceTransactionStatus.Applied or
                ResourceTransactionStatus.AlreadyApplied
        };
        if (result.Snapshot is not null)
        {
            dictionary["resource_a"] = result.Snapshot.GetBalance(ResourceKind.A);
            dictionary["version"] = result.Snapshot.Version;
        }
        return dictionary;
    }

    /// <summary>把账户快照转换为 GDScript 可读取的稳定字段集合。</summary>
    private static Godot.Collections.Dictionary ToGodot(ResourceAccountSnapshot snapshot) => new()
    {
        ["player_id"] = snapshot.PlayerId.Value.ToString("D"),
        ["resource_a"] = snapshot.GetBalance(ResourceKind.A),
        ["version"] = snapshot.Version
    };

    /// <summary>读取当前物理模拟 Tick。</summary>
    private static long CurrentTick() => checked((long)Engine.GetPhysicsFrames());
}
