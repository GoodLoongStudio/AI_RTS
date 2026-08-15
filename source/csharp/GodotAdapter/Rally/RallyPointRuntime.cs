using AI_RTS.Application.Commands;
using AI_RTS.Application.Rally;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Rally;
using AI_RTS.GodotAdapter.Common;
using AI_RTS.GodotAdapter.Composition;
using AI_RTS.GodotAdapter.Production;
using Godot;

namespace AI_RTS.GodotAdapter.Rally;

/// <summary>装配权威 Rally 服务、Godot 视图和生产完成后的事件驱动出厂任务。</summary>
public partial class RallyPointRuntime : Node
{
    private readonly HashSet<UnitId> _trackedProducers = new();
    private readonly HashSet<UnitId> _trackedUnitTargets = new();
    private readonly HashSet<ResourceNodeId> _trackedResourceTargets = new();
    private CommandRuntime _commands = null!;
    private ProductionRuntime _production = null!;
    private GodotRallyRepository _repository = null!;
    private IRallyPointService _service = null!;

    /// <summary>连接命令运行时、生产完成事件和 Rally 视图事件。</summary>
    public override void _Ready()
    {
        _commands = GetParent().GetNode<CommandRuntime>("CommandRuntime");
        _production = GetParent().GetNode<ProductionRuntime>("ProductionRuntime");
        _repository = new GodotRallyRepository(GetParent(), _commands);
        _service = new RallyPointService(_repository, _repository, _repository);
        _service.Changed += OnChanged;
        _service.Cleared += OnCleared;
        _production.UnitDeployed += OnUnitDeployed;
    }

    /// <summary>注册一座带 RallyPoint 视图的生产者及其失效清理。</summary>
    public string RegisterProducer(Node producer, Node view)
    {
        var producerId = _repository.RegisterProducer(producer, view);
        if (_trackedProducers.Add(producerId))
        {
            producer.TreeExiting += () => _service.LoseProducer(producerId, CurrentTick());
        }
        return producerId.Value.ToString("D");
    }

    /// <summary>为多座生产者设置同一地面集结位置。</summary>
    public Godot.Collections.Dictionary SetPosition(
        Godot.Collections.Array<Node> producers,
        Vector3 destination,
        Node issuerPlayer)
    {
        var ids = producers.Select(_repository.RegisterProducerFromExisting).ToArray();
        return ToGodot(_service.SetPosition(
            Context(issuerPlayer),
            new SetRallyPositionCommand(
                ids, new WorldPosition(destination.X, destination.Y, destination.Z))));
    }

    /// <summary>为多座生产者设置友军实体或资源节点目标。</summary>
    public Godot.Collections.Dictionary SetTarget(
        Godot.Collections.Array<Node> producers,
        Node target,
        Node issuerPlayer)
    {
        var ids = producers.Select(_repository.RegisterProducerFromExisting).ToArray();
        RallyTarget rallyTarget;
        if (IsResource(target))
        {
            var resourceId = _repository.RegisterResourceTarget(target);
            TrackResourceTarget(resourceId, target);
            rallyTarget = new RallyResourceTarget(resourceId);
        }
        else
        {
            var unitId = _repository.RegisterUnitTarget(target);
            TrackUnitTarget(unitId, target);
            rallyTarget = new RallyUnitTarget(unitId);
        }
        return ToGodot(_service.SetTarget(
            Context(issuerPlayer), new SetRallyTargetCommand(ids, rallyTarget)));
    }

    /// <summary>显式清除多座生产者的自定义集结点并回归默认门口。</summary>
    public Godot.Collections.Dictionary Clear(
        Godot.Collections.Array<Node> producers,
        Node issuerPlayer)
    {
        var ids = producers.Select(_repository.RegisterProducerFromExisting).ToArray();
        return ToGodot(_service.Clear(
            Context(issuerPlayer), new ClearRallyPointCommand(ids)));
    }

    /// <summary>查询迁移期测试和 HUD 使用的当前自定义 Rally 快照。</summary>
    public Godot.Collections.Dictionary GetSnapshot(Node producer)
    {
        var producerId = GodotStableIdentity.Unit(producer);
        if (_service.Find(producerId) is not { } point)
        {
            return new Godot.Collections.Dictionary();
        }
        var result = new Godot.Collections.Dictionary
        {
            ["producer_id"] = point.ProducerId.Value.ToString("D"),
            ["version"] = point.Version,
            ["updated_at_tick"] = point.UpdatedAtTick
        };
        switch (point.Target)
        {
            case RallyPositionTarget position:
                result["kind"] = "Position";
                result["position"] = new Vector3(
                    position.Position.X, position.Position.Y, position.Position.Z);
                break;
            case RallyUnitTarget unit:
                result["kind"] = "Unit";
                result["target_id"] = unit.TargetUnitId.Value.ToString("D");
                break;
            case RallyResourceTarget resource:
                result["kind"] = "Resource";
                result["target_id"] = resource.TargetResourceId.Value.ToString("D");
                break;
        }
        return result;
    }

    /// <summary>生产完成后先继承 Producer 策略，再按最新 Rally 快照分派任务。</summary>
    private void OnUnitDeployed(Node produced, Node producer)
    {
        var owner = producer.GetParent();
        _commands.InheritCombatPolicy(producer, produced, owner);
        var producerId = GodotStableIdentity.Unit(producer);
        if (_service.Find(producerId) is not { } point)
        {
            return;
        }
        switch (point.Target)
        {
            case RallyPositionTarget position:
                _commands.MoveUnits(
                    [produced],
                    new Vector3(position.Position.X, position.Position.Y, position.Position.Z),
                    owner);
                break;
            case RallyResourceTarget resource:
                DispatchResource(produced, owner, resource.TargetResourceId);
                break;
            case RallyUnitTarget unit:
                DispatchUnit(produced, owner, unit.TargetUnitId);
                break;
        }
    }

    /// <summary>Worker 对资源开始 Gather，其他单位仅靠近资源实体。</summary>
    private void DispatchResource(Node produced, Node owner, ResourceNodeId resourceId)
    {
        if (!_repository.TryGetResource(resourceId, out var resource))
        {
            return;
        }
        var producedId = _commands.RegisterRuntimeUnit(produced);
        if (_commands.FindRuntimeUnit(producedId)?.CanGather == true)
        {
            _commands.GatherResources([produced], resource, owner);
        }
        else
        {
            _commands.ApproachEntityUnits([produced], resource, owner);
        }
    }

    /// <summary>对同玩家单位或建筑提交公共持续跟随命令。</summary>
    private void DispatchUnit(Node produced, Node owner, UnitId targetId)
    {
        if (_repository.TryGetUnit(targetId, out var target))
        {
            _commands.FollowEntityUnits([produced], target, owner);
        }
    }

    /// <summary>权威目标变化后只更新对应 RallyPoint 表现。</summary>
    private void OnChanged(RallyPointChanged change)
    {
        if (!_repository.TryGetView(change.Current.ProducerId, out var view))
        {
            return;
        }
        switch (change.Current.Target)
        {
            case RallyPositionTarget position:
                view.Call(
                    "apply_authoritative_position",
                    new Vector3(position.Position.X, position.Position.Y, position.Position.Z));
                break;
            case RallyUnitTarget unit when
                _repository.TryGetUnit(unit.TargetUnitId, out var unitTarget):
                view.Call("apply_authoritative_target", unitTarget);
                break;
            case RallyResourceTarget resource when
                _repository.TryGetResource(resource.TargetResourceId, out var resourceTarget):
                view.Call("apply_authoritative_target", resourceTarget);
                break;
        }
    }

    /// <summary>清除自定义目标时把视图复位到建筑门口默认状态。</summary>
    private void OnCleared(RallyPointCleared change)
    {
        if (_repository.TryGetView(change.Previous.ProducerId, out var view))
        {
            view.Call("apply_authoritative_default");
        }
    }

    /// <summary>订阅单位或建筑目标退出并只清理一次引用。</summary>
    private void TrackUnitTarget(UnitId targetId, Node target)
    {
        if (_trackedUnitTargets.Add(targetId))
        {
            target.TreeExiting += () =>
                _service.LoseTarget(new RallyUnitTarget(targetId), CurrentTick());
        }
    }

    /// <summary>订阅资源目标退出并只清理一次引用。</summary>
    private void TrackResourceTarget(ResourceNodeId targetId, Node target)
    {
        if (_trackedResourceTargets.Add(targetId))
        {
            target.TreeExiting += () =>
                _service.LoseTarget(new RallyResourceTarget(targetId), CurrentTick());
        }
    }

    /// <summary>按稳定场景组判断目标是否为 Legacy 资源节点。</summary>
    private static bool IsResource(Node target) =>
        target.IsInGroup("resource_units");

    /// <summary>创建 Rally 命令上下文。</summary>
    private CommandContext Context(Node issuerPlayer) => new(
        new CommandId(Guid.NewGuid()),
        _commands.RuntimeMatchId,
        GodotStableIdentity.Player(issuerPlayer),
        CurrentTick());

    /// <summary>把公共命令结果转换为 GDScript 可读取回执。</summary>
    private static Godot.Collections.Dictionary ToGodot(CommandResult result)
    {
        var items = new Godot.Collections.Array<Godot.Collections.Dictionary>();
        foreach (var item in result.UnitResults)
        {
            items.Add(new Godot.Collections.Dictionary
            {
                ["unit_id"] = item.UnitId.Value.ToString("D"),
                ["accepted"] = item.Accepted,
                ["error"] = item.ErrorCode.ToString()
            });
        }
        return new Godot.Collections.Dictionary
        {
            ["command_id"] = result.CommandId.Value.ToString("D"),
            ["status"] = result.Status.ToString(),
            ["unit_results"] = items
        };
    }

    private static long CurrentTick() => checked((long)Engine.GetPhysicsFrames());
}
