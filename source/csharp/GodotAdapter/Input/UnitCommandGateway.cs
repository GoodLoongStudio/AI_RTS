using AI_RTS.Application.Commands;
using AI_RTS.Application.Construction;
using AI_RTS.Domain.Combat;
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

    /// <summary>接收 GDScript 单位节点并提交批量普通移动命令。</summary>
    public Godot.Collections.Dictionary MoveUnits(
        Godot.Collections.Array<Node> unitNodes, Vector3 destination, Node issuerPlayer)
    {
        return ToGodot(_runtime.MoveUnits(unitNodes, destination, issuerPlayer));
    }

    /// <summary>接收 GDScript 单位与实体节点并提交靠近实体命令。</summary>
    public Godot.Collections.Dictionary ApproachEntityUnits(
        Godot.Collections.Array<Node> unitNodes,
        Node targetNode,
        Node issuerPlayer)
    {
        return ToGodot(_runtime.ApproachEntityUnits(unitNodes, targetNode, issuerPlayer));
    }

    /// <summary>接收 GDScript 单位与目标节点并提交持续跟随命令。</summary>
    public Godot.Collections.Dictionary FollowEntityUnits(
        Godot.Collections.Array<Node> unitNodes,
        Node targetNode,
        Node issuerPlayer)
    {
        return ToGodot(_runtime.FollowEntityUnits(unitNodes, targetNode, issuerPlayer));
    }

    /// <summary>接收 GDScript 单位节点并提交批量强制移动命令。</summary>
    public Godot.Collections.Dictionary ForceMoveUnits(
        Godot.Collections.Array<Node> unitNodes, Vector3 destination, Node issuerPlayer)
    {
        return ToGodot(_runtime.ForceMoveUnits(unitNodes, destination, issuerPlayer));
    }

    /// <summary>接收 GDScript Worker 与资源节点并提交持续采集任务。</summary>
    public Godot.Collections.Dictionary GatherResources(
        Godot.Collections.Array<Node> workerNodes,
        Node resourceNode,
        Node issuerPlayer)
    {
        return ToGodot(_runtime.GatherResources(workerNodes, resourceNode, issuerPlayer));
    }

    /// <summary>接收 Worker 与已注册施工现场并提交批量 Construct 命令。</summary>
    public Godot.Collections.Dictionary ConstructUnits(
        Godot.Collections.Array<Node> workerNodes,
        Node constructionSite,
        Node issuerPlayer)
    {
        return ToGodot(_runtime.ConstructUnits(workerNodes, constructionSite, issuerPlayer));
    }

    /// <summary>由现场拥有者主动取消未完成建筑并返回退款处理状态。</summary>
    public Godot.Collections.Dictionary CancelConstruction(
        Node constructionSite,
        Node issuerPlayer)
    {
        return ToGodot(_runtime.CancelConstruction(constructionSite, issuerPlayer));
    }

    /// <summary>接收 GDScript 单位节点并提交批量地面移动攻击命令。</summary>
    public Godot.Collections.Dictionary GroundAttackMoveUnits(
        Godot.Collections.Array<Node> unitNodes, Vector3 destination, Node issuerPlayer)
    {
        return ToGodot(_runtime.GroundAttackMoveUnits(unitNodes, destination, issuerPlayer));
    }

    /// <summary>接收 GDScript 单位节点并提交以敌方实体为最终目标的移动攻击命令。</summary>
    public Godot.Collections.Dictionary EntityAttackMoveUnits(
        Godot.Collections.Array<Node> unitNodes, Node targetNode, Node issuerPlayer)
    {
        return ToGodot(_runtime.EntityAttackMoveUnits(unitNodes, targetNode, issuerPlayer));
    }

    /// <summary>接收 GDScript 单位节点并提交批量战术撤退命令。</summary>
    public Godot.Collections.Dictionary TacticalWithdrawUnits(
        Godot.Collections.Array<Node> unitNodes, Vector3 destination, Node issuerPlayer)
    {
        return ToGodot(_runtime.TacticalWithdrawUnits(unitNodes, destination, issuerPlayer));
    }

    /// <summary>接收 GDScript 单位节点并提交停止移动命令。</summary>
    public Godot.Collections.Dictionary HaltMovement(
        Godot.Collections.Array<Node> unitNodes, Node issuerPlayer)
    {
        return ToGodot(_runtime.HaltMovement(unitNodes, issuerPlayer));
    }

    /// <summary>提交统一 Stop；每个单位只产生一个命令回执。</summary>
    public Godot.Collections.Dictionary StopUnits(
        Godot.Collections.Array<Node> unitNodes, Node issuerPlayer)
    {
        return ToGodot(_runtime.StopUnits(unitNodes, issuerPlayer));
    }

    /// <summary>按稳定字符串名称设置一组单位的持续交战姿态。</summary>
    public Godot.Collections.Dictionary SetEngagementStance(
        Godot.Collections.Array<Node> unitNodes, string stance, Node issuerPlayer)
    {
        if (!Enum.TryParse<EngagementStance>(stance, false, out var parsed))
        {
            throw new ArgumentException($"Unknown EngagementStance: {stance}", nameof(stance));
        }
        return ToGodot(_runtime.SetEngagementStance(unitNodes, parsed, issuerPlayer));
    }

    /// <summary>按稳定字符串名称设置一组单位的持续开火策略。</summary>
    public Godot.Collections.Dictionary SetFirePolicy(
        Godot.Collections.Array<Node> unitNodes, string policy, Node issuerPlayer)
    {
        if (!Enum.TryParse<FirePolicy>(policy, false, out var parsed))
        {
            throw new ArgumentException($"Unknown FirePolicy: {policy}", nameof(policy));
        }
        return ToGodot(_runtime.SetFirePolicy(unitNodes, parsed, issuerPlayer));
    }

    /// <summary>提交主动技能施放；单位目标技能可传入 targetNode。</summary>
    public Godot.Collections.Dictionary CastSkill(
        Godot.Collections.Array<Node> unitNodes,
        string skillId,
        Node issuerPlayer,
        Node? targetNode = null)
    {
        return ToGodot(_runtime.CastSkill(unitNodes, skillId, issuerPlayer, targetNode));
    }

    /// <summary>查询单位 HUD 技能槽及冷却剩余。</summary>
    public Godot.Collections.Array GetHudSlots(Node unitNode) => _runtime.GetHudSlots(unitNode);

    /// <summary>提交对地面坐标的主动技能施放。</summary>
    public Godot.Collections.Dictionary CastSkillGround(
        Godot.Collections.Array<Node> unitNodes,
        string skillId,
        Vector3 position,
        Node issuerPlayer)
    {
        return ToGodot(_runtime.CastSkillGround(unitNodes, skillId, position, issuerPlayer));
    }

    /// <summary>提交批量普通实体攻击；只接受敌方目标且不覆盖停火。</summary>
    public Godot.Collections.Dictionary AttackUnits(
        Godot.Collections.Array<Node> unitNodes, Node targetNode, Node issuerPlayer)
    {
        return ToGodot(_runtime.AttackUnits(unitNodes, targetNode, issuerPlayer));
    }

    /// <summary>提交批量实体强制攻击，允许显式己方或友军目标。</summary>
    public Godot.Collections.Dictionary ForceAttackUnits(
        Godot.Collections.Array<Node> unitNodes, Node targetNode, Node issuerPlayer)
    {
        return ToGodot(_runtime.ForceAttackUnits(unitNodes, targetNode, issuerPlayer));
    }

    /// <summary>提交批量持续地面强制攻击；不支持该能力的单位逐单位拒绝。</summary>
    public Godot.Collections.Dictionary ForceAttackGround(
        Godot.Collections.Array<Node> unitNodes, Vector3 position, Node issuerPlayer)
    {
        return ToGodot(_runtime.ForceAttackGround(unitNodes, position, issuerPlayer));
    }

    /// <summary>只取消显式 ForceAttack，不影响普通自动攻击。</summary>
    public Godot.Collections.Dictionary CancelForceAttack(
        Godot.Collections.Array<Node> unitNodes, Node issuerPlayer)
    {
        return ToGodot(_runtime.CancelForceAttack(unitNodes, issuerPlayer));
    }

    /// <summary>查询指定单位当前权威交战姿态名称。</summary>
    public string GetEngagementStance(Node unitNode) => _runtime.GetEngagementStance(unitNode);

    /// <summary>查询指定单位当前权威开火策略名称。</summary>
    public string GetFirePolicy(Node unitNode) => _runtime.GetFirePolicy(unitNode);

    /// <summary>查询指定单位当前警戒岗位点；尚未确定时返回 Vector3.INF。</summary>
    public Vector3 GetGuardAnchor(Node unitNode) => _runtime.GetGuardAnchor(unitNode);

    /// <summary>查询指定单位当前活动订单的状态名称，主要用于桥接期诊断。</summary>
    public string GetActiveOrderState(Node unitNode)
    {
        return _runtime.GetActiveOrderState(unitNode);
    }

    /// <summary>按字符串形式的 UnitOrderId 查询状态名称，主要用于桥接期诊断。</summary>
    public string GetOrderState(string orderId) => _runtime.GetOrderState(orderId);

    /// <summary>按订单 ID 查询完整权威快照，供迁移期 HUD 和测试按稳定字段读取。</summary>
    public Godot.Collections.Dictionary GetOrderSnapshot(string orderId) =>
        _runtime.GetOrderSnapshot(orderId);

    /// <summary>查询单位最近一次终态订单，供玩家与 AI 读取不可达等明确结果。</summary>
    public Godot.Collections.Dictionary GetLastTerminalOrder(Node unitNode) =>
        _runtime.GetLastTerminalOrder(unitNode);

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

    /// <summary>把单现场命令结果转换为 GDScript 可读取的稳定字段。</summary>
    private static Godot.Collections.Dictionary ToGodot(ConstructionSiteCommandResult result)
    {
        return new Godot.Collections.Dictionary
        {
            ["accepted"] = result.Status == ConstructionSiteCommandStatus.Applied,
            ["status"] = result.Status.ToString(),
            ["site_state"] = result.Snapshot?.State.ToString() ?? string.Empty
        };
    }
}
