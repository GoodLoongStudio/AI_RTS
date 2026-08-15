using AI_RTS.Application.Commands;
using AI_RTS.Domain.Common;
using AI_RTS.GodotAdapter.Composition;
using Godot;

namespace AI_RTS.GodotAdapter.AI;

/// <summary>把传统规则 AI 绑定到固定玩家身份，并仅接受稳定实体 ID 命令参数。</summary>
public partial class RuleAiCommandGateway : Node
{
    private CommandRuntime _commands = null!;
    private WeakReference<Node> _issuer = null!;

    /// <summary>由 Match 组合根一次性绑定共享命令运行时和不可更换的发出者身份。</summary>
    internal void Configure(CommandRuntime commands, Node issuer)
    {
        if (_commands is not null)
        {
            throw new InvalidOperationException("RuleAiCommandGateway 只能配置一次。");
        }
        _commands = commands;
        _issuer = new WeakReference<Node>(issuer);
    }

    /// <summary>按稳定 Worker 与施工现场 ID 提交统一 Construct 命令。</summary>
    public Godot.Collections.Dictionary Construct(
        Godot.Collections.Array<string> workerIds,
        string constructionSiteId)
    {
        if (!_issuer.TryGetTarget(out var issuer) ||
            !GodotObject.IsInstanceValid(issuer) || !issuer.IsInsideTree())
        {
            return Rejected(CommandErrorCode.MatchNotRunning, []);
        }
        var parsedWorkers = workerIds
            .Select(value => Guid.TryParse(value, out var id) ?
                new UnitId(id) : new UnitId(Guid.Empty))
            .ToArray();
        var parsedSite = Guid.TryParse(constructionSiteId, out var siteId) ?
            new UnitId(siteId) : new UnitId(Guid.Empty);
        return ToGodot(_commands.ConstructUnitsByStableIds(
            parsedWorkers, parsedSite, issuer));
    }

    /// <summary>创建未进入权威命令服务时使用的稳定拒绝回执。</summary>
    private static Godot.Collections.Dictionary Rejected(
        CommandErrorCode error,
        IReadOnlyList<UnitId> unitIds) => ToGodot(new CommandResult(
            new CommandId(Guid.NewGuid()),
            CommandStatus.Rejected,
            unitIds.Select(id => new UnitCommandResult(id, false, error)).ToArray()));

    /// <summary>将强类型命令回执转换为 GDScript 可读取的稳定字段集合。</summary>
    private static Godot.Collections.Dictionary ToGodot(CommandResult result)
    {
        var unitResults = new Godot.Collections.Array<Godot.Collections.Dictionary>();
        foreach (var item in result.UnitResults)
        {
            unitResults.Add(new Godot.Collections.Dictionary
            {
                ["unit_id"] = item.UnitId.Value.ToString("D"),
                ["accepted"] = item.Accepted,
                ["error_code"] = item.ErrorCode.ToString(),
                ["order_id"] = item.OrderId?.Value.ToString("D") ?? string.Empty
            });
        }
        return new Godot.Collections.Dictionary
        {
            ["command_id"] = result.CommandId.Value.ToString("D"),
            ["status"] = result.Status.ToString(),
            ["unit_results"] = unitResults
        };
    }
}
