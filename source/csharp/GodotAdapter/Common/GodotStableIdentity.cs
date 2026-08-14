using AI_RTS.Domain.Common;
using Godot;

namespace AI_RTS.GodotAdapter.Common;

/// <summary>为 Godot Node 提供命令与经济适配器共享的稳定身份。</summary>
public static class GodotStableIdentity
{
    /// <summary>单位节点保存稳定 ID 时使用的 Metadata 键。</summary>
    public const string UnitIdMeta = "ai_rts_unit_id";

    /// <summary>玩家节点保存稳定 ID 时使用的 Metadata 键。</summary>
    public const string PlayerIdMeta = "ai_rts_player_id";

    /// <summary>取得或创建单位节点的稳定 UnitId。</summary>
    public static UnitId Unit(Node unit) =>
        GetOrCreateId(unit, UnitIdMeta, value => new UnitId(value));

    /// <summary>取得或创建玩家节点的稳定 PlayerId。</summary>
    public static PlayerId Player(Node player) =>
        GetOrCreateId(player, PlayerIdMeta, value => new PlayerId(value));

    /// <summary>读取节点已有 Metadata ID；不存在时创建并保存新 Guid。</summary>
    private static TId GetOrCreateId<TId>(Node node, string metaKey, Func<Guid, TId> factory)
    {
        if (node.HasMeta(metaKey) && Guid.TryParse(node.GetMeta(metaKey).AsString(), out var existing))
        {
            return factory(existing);
        }

        var value = Guid.NewGuid();
        node.SetMeta(metaKey, value.ToString("D"));
        return factory(value);
    }
}
