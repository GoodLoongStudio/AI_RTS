using AI_RTS.Application.Selection;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Selection;
using AI_RTS.GodotAdapter.Common;
using AI_RTS.GodotAdapter.Composition;
using AI_RTS.GodotAdapter.Input;
using Godot;

namespace AI_RTS.GodotAdapter.Selection;

/// <summary>把本地控制组按键和 Godot Selection 表现适配到稳定 ID C# 服务。</summary>
public partial class ControlGroupRuntime : Node
{
    private readonly HashSet<UnitId> _exitSubscriptions = [];
    private CommandRuntime _commands = null!;
    private InputBindingRuntime _input = null!;
    private IControlGroupService _service = null!;
    private Node _match = null!;
    private Node _localPlayer = null!;
    private PlayerId _localPlayerId;
    private bool _configured;

    /// <summary>由 Match 组合根绑定唯一 Human；无本地 Human 的对局不启用控制组。</summary>
    public void Configure(Node? localPlayer)
    {
        if (_configured)
        {
            throw new InvalidOperationException("ControlGroupRuntime 只能配置一次。");
        }
        _configured = true;
        if (localPlayer is null)
        {
            return;
        }

        _localPlayer = localPlayer;
        _localPlayerId = GodotStableIdentity.Player(localPlayer);
        _match = FindParent("Match");
        _commands = _match.GetNode<CommandRuntime>("CommandRuntime");
        _input = _match.GetNode<InputBindingRuntime>("InputBindingRuntime");
        _service = new ControlGroupService(new GodotControlGroupUnitRepository(_commands));
        _input.ActionPressed += OnActionPressed;
    }

    /// <summary>退出场景时解除输入订阅，避免重开对局后旧 Runtime 继续接收动作。</summary>
    public override void _ExitTree()
    {
        if (_configured && _localPlayer is not null &&
            GodotObject.IsInstanceValid(_input))
        {
            _input.ActionPressed -= OnActionPressed;
        }
    }

    /// <summary>用当前 Selection 替换指定控制组，并返回稳定字段结果。</summary>
    public Godot.Collections.Dictionary SaveControlGroup(int groupNumber)
    {
        if (!TryGetService(out var rejected))
        {
            return rejected;
        }

        var selected = GetTree().GetNodesInGroup("selected_units")
            .OfType<Node>()
            .Where(node => _match.IsAncestorOf(node))
            .ToArray();
        var unitIds = new List<UnitId>();
        foreach (var unit in selected)
        {
            var unitId = _commands.RegisterRuntimeUnit(unit);
            unitIds.Add(unitId);
            SubscribeToExit(unit, unitId);
        }
        return ToGodot(_service.Replace(
            _localPlayerId,
            new ControlGroupNumber(groupNumber),
            unitIds));
    }

    /// <summary>召回指定控制组；成功空组也会清空当前 Selection。</summary>
    public Godot.Collections.Dictionary RecallControlGroup(int groupNumber)
    {
        if (!TryGetService(out var rejected))
        {
            return rejected;
        }

        var result = _service.Recall(
            _localPlayerId,
            new ControlGroupNumber(groupNumber));
        if (result.Status == ControlGroupRecallStatus.Accepted)
        {
            ReplaceSelection(result.UnitIds);
        }
        return ToGodot(result);
    }

    /// <summary>返回指定控制组的稳定 ID 快照，不改变 Selection。</summary>
    public Godot.Collections.Dictionary InspectControlGroup(int groupNumber)
    {
        if (!TryGetService(out var rejected))
        {
            return rejected;
        }
        return ToGodot(_service.Inspect(
            _localPlayerId,
            new ControlGroupNumber(groupNumber)));
    }

    /// <summary>解析集中输入服务发布的控制组动作，不读取物理键。</summary>
    private void OnActionPressed(string actionId)
    {
        const string savePrefix = "group.set_";
        const string recallPrefix = "group.access_";
        if (actionId.StartsWith(savePrefix, StringComparison.Ordinal) &&
            int.TryParse(actionId[savePrefix.Length..], out var saveGroup))
        {
            SaveControlGroup(saveGroup);
            return;
        }
        if (actionId.StartsWith(recallPrefix, StringComparison.Ordinal) &&
            int.TryParse(actionId[recallPrefix.Length..], out var recallGroup))
        {
            RecallControlGroup(recallGroup);
        }
    }

    /// <summary>用服务返回的有效成员替换 Godot Selection；空集合会保持取消选择。</summary>
    private void ReplaceSelection(IReadOnlyList<UnitId> unitIds)
    {
        var signals = GetNode("/root/MatchSignals");
        signals.EmitSignal("deselect_all_units");
        foreach (var unitId in unitIds)
        {
            if (!_commands.TryGetRuntimeUnit(unitId, out var unit) ||
                unit.GetParent() != _localPlayer)
            {
                continue;
            }
            unit.FindChild("Selection", false, false)?.Call("select");
        }
    }

    /// <summary>为保存过的成员建立一次退出订阅，主动清理全部控制组。</summary>
    private void SubscribeToExit(Node unit, UnitId unitId)
    {
        if (!_exitSubscriptions.Add(unitId))
        {
            return;
        }
        unit.TreeExited += () => OnUnitExited(unitId);
    }

    /// <summary>处理 Godot 单位退出并从全部控制组删除其稳定身份。</summary>
    private void OnUnitExited(UnitId unitId)
    {
        _exitSubscriptions.Remove(unitId);
        _service.RemoveUnit(unitId);
    }

    /// <summary>确认 Runtime 已绑定本地玩家；失败时创建可诊断拒绝信封。</summary>
    private bool TryGetService(out Godot.Collections.Dictionary rejected)
    {
        if (_service is not null)
        {
            rejected = [];
            return true;
        }
        rejected = new Godot.Collections.Dictionary
        {
            ["status"] = "Rejected",
            ["error_code"] = "RuntimeUnavailable",
            ["unit_ids"] = new Godot.Collections.Array<string>()
        };
        return false;
    }

    /// <summary>把保存结果转换为 GDScript 和自动测试可读取的稳定字段。</summary>
    private static Godot.Collections.Dictionary ToGodot(ControlGroupSaveResult result)
    {
        var members = new Godot.Collections.Array<Godot.Collections.Dictionary>();
        foreach (var member in result.MemberResults)
        {
            members.Add(new Godot.Collections.Dictionary
            {
                ["unit_id"] = member.UnitId.Value.ToString("D"),
                ["accepted"] = member.Accepted,
                ["error_code"] = member.ErrorCode.ToString()
            });
        }
        return new Godot.Collections.Dictionary
        {
            ["status"] = result.Status.ToString(),
            ["group"] = result.Group.Value,
            ["unit_ids"] = UnitIds(result.StoredUnitIds),
            ["member_results"] = members,
            ["error_code"] = result.ErrorCode.ToString()
        };
    }

    /// <summary>把召回结果转换为包含显式空标志和剔除集合的稳定字段。</summary>
    private static Godot.Collections.Dictionary ToGodot(ControlGroupRecallResult result) => new()
    {
        ["status"] = result.Status.ToString(),
        ["group"] = result.Group.Value,
        ["unit_ids"] = UnitIds(result.UnitIds),
        ["pruned_unit_ids"] = UnitIds(result.PrunedUnitIds),
        ["is_empty"] = result.IsEmpty,
        ["error_code"] = result.ErrorCode.ToString()
    };

    /// <summary>把只读诊断快照转换为稳定字段。</summary>
    private static Godot.Collections.Dictionary ToGodot(ControlGroupSnapshot snapshot) => new()
    {
        ["status"] = snapshot.ErrorCode == ControlGroupErrorCode.None ? "Accepted" : "Rejected",
        ["group"] = snapshot.Group.Value,
        ["unit_ids"] = UnitIds(snapshot.UnitIds),
        ["is_empty"] = snapshot.IsEmpty,
        ["error_code"] = snapshot.ErrorCode.ToString()
    };

    private static Godot.Collections.Array<string> UnitIds(IReadOnlyList<UnitId> unitIds)
    {
        var result = new Godot.Collections.Array<string>();
        foreach (var unitId in unitIds)
        {
            result.Add(unitId.Value.ToString("D"));
        }
        return result;
    }
}
