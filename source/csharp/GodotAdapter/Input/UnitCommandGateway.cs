using AI_RTS.Application.Commands;
using AI_RTS.GodotAdapter.Composition;
using Godot;

namespace AI_RTS.GodotAdapter.Input;

/// <summary>为 GDScript 输入层提供稳定的 C# 单位命令入口和结果转换。</summary>
public partial class UnitCommandGateway : Node
{
    /// <summary>当前 Match 统一持有的命令运行时。</summary>
    private CommandRuntime _runtime = null!;

    /// <summary>定位所属 Match 的公共 CommandRuntime。</summary>
    public override void _Ready()
    {
        var match = FindAncestor("Match");
        _runtime = match.GetNode<CommandRuntime>("CommandRuntime");
    }

    /// <summary>接收 GDScript 单位节点并提交批量强制移动命令。</summary>
    public Godot.Collections.Dictionary ForceMoveUnits(
        Godot.Collections.Array<Node> unitNodes, Vector3 destination, Node issuerPlayer)
    {
        return ToGodot(_runtime.ForceMoveUnits(unitNodes, destination, issuerPlayer));
    }

    /// <summary>接收 GDScript 单位节点并提交停止移动命令。</summary>
    public Godot.Collections.Dictionary HaltMovement(
        Godot.Collections.Array<Node> unitNodes, Node issuerPlayer)
    {
        return ToGodot(_runtime.HaltMovement(unitNodes, issuerPlayer));
    }

    /// <summary>查询指定单位当前活动订单的状态名称，主要用于桥接期诊断。</summary>
    public string GetActiveOrderState(Node unitNode)
    {
        return _runtime.GetActiveOrderState(unitNode);
    }

    /// <summary>按字符串形式的 UnitOrderId 查询状态名称，主要用于桥接期诊断。</summary>
    public string GetOrderState(string orderId) => _runtime.GetOrderState(orderId);

    /// <summary>沿父节点查找指定名称的装配根，缺失时立即报告场景契约错误。</summary>
    private Node FindAncestor(string nodeName)
    {
        Node? current = this;
        while (current is not null && current.Name != nodeName)
        {
            current = current.GetParent();
        }
        return current ?? throw new InvalidOperationException(
            $"UnitCommandGateway requires an ancestor named {nodeName}.");
    }

    /// <summary>将强类型 CommandResult 转换为 GDScript 可读取的 Dictionary。</summary>
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
