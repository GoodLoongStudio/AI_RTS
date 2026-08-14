using AI_RTS.Application.Combat;
using AI_RTS.Domain.Combat;
using AI_RTS.Domain.Common;
using AI_RTS.GodotAdapter.Units;
using Godot;

namespace AI_RTS.GodotAdapter.Combat;

/// <summary>在 Match 生命周期内持有独立投射物、发射快照与一次性命中结算。</summary>
public partial class ProjectileRuntime : Node
{
    /// <summary>按攻击实例 ID 保存仍在飞行的权威快照和制导目标弱引用。</summary>
    private readonly Dictionary<AttackInstanceId, ActiveProjectile> _active = new();

    /// <summary>复用稳定单位 ID 注册和 Godot Node 弱引用查询。</summary>
    private readonly GodotUnitRegistry _units = new();

    /// <summary>执行不依赖 Godot Node 的弹头范围与友伤计算。</summary>
    private readonly IWarheadDamageResolver _warheads = new WarheadDamageResolver();

    /// <summary>承载所有独立投射物视觉的 Match 级节点。</summary>
    private Node3D _projectiles = null!;

    /// <summary>定位同级 Projectiles 容器。</summary>
    public override void _Ready()
    {
        _projectiles = GetParent().GetNode<Node3D>("Projectiles");
    }

    /// <summary>发射指向实体目标的投射物，并在发射瞬间冻结伤害与来源数据。</summary>
    public string LaunchEntity(
        Node sourceNode,
        Node targetNode,
        string projectileScenePath,
        float warheadRadius = 0.0f,
        bool areaDamage = false)
    {
        var source = RequireSpatial(sourceNode, nameof(sourceNode));
        var target = RequireSpatial(targetNode, nameof(targetNode));
        var sourceId = _units.Register(sourceNode);
        var targetId = _units.Register(targetNode);
        var snapshot = CreateSnapshot(
            source,
            sourceId,
            target.GlobalPosition,
            targetId,
            warheadRadius,
            areaDamage ? ImpactSelectionMode.Area : ImpactSelectionMode.IntendedTargetOnly);

        return Spawn(snapshot, projectileScenePath, source, target);
    }

    /// <summary>发射指向纯世界落点的投射物，并使用实际爆点执行范围查询。</summary>
    public string LaunchGround(
        Node sourceNode,
        Vector3 targetPosition,
        string projectileScenePath,
        float warheadRadius = 0.0f)
    {
        var source = RequireSpatial(sourceNode, nameof(sourceNode));
        var sourceId = _units.Register(sourceNode);
        var snapshot = CreateSnapshot(
            source,
            sourceId,
            targetPosition,
            null,
            warheadRadius,
            ImpactSelectionMode.Area);

        return Spawn(snapshot, projectileScenePath, source, null);
    }

    /// <summary>返回制导目标的最新有效位置；目标失效后保持最后已知位置。</summary>
    public Vector3 GetAimPoint(string attackId)
    {
        if (!TryGetActive(attackId, out var state))
        {
            return Vector3.Inf;
        }
        if (state.Target is not null &&
            state.Target.TryGetTarget(out var target) &&
            GodotObject.IsInstanceValid(target) &&
            target.IsInsideTree())
        {
            state.LastAimPoint = target.GlobalPosition;
        }

        return state.LastAimPoint;
    }

    /// <summary>在实际爆点对当前可伤害对象执行一次结算；重复调用不会再次造成伤害。</summary>
    public int ResolveImpact(string attackId, Vector3 impactPoint)
    {
        if (!Guid.TryParse(attackId, out var value))
        {
            return 0;
        }

        var id = new AttackInstanceId(value);
        if (!_active.Remove(id, out var state))
        {
            return 0;
        }

        var candidates = new List<ImpactCandidateSnapshot>();
        foreach (var node in GetTree().GetNodesInGroup("units").OfType<Node>())
        {
            if (!GodotObject.IsInstanceValid(node) || !node.IsInsideTree())
            {
                continue;
            }

            var hp = node.Get("hp");
            if (hp.VariantType == Variant.Type.Nil || node is not Node3D spatial)
            {
                continue;
            }

            var radiusValue = node.Get("radius");
            var radius = radiusValue.VariantType == Variant.Type.Nil ? 0.0f : radiusValue.AsSingle();
            candidates.Add(new ImpactCandidateSnapshot(
                _units.Register(node),
                _units.RegisterPlayer(node.GetParent()),
                ToWorld(spatial.GlobalPosition),
                radius,
                true));
        }

        var applications = _warheads.Resolve(state.Snapshot, ToWorld(impactPoint), candidates);
        foreach (var application in applications)
        {
            if (!_units.TryGetNode(application.UnitId, out var target))
            {
                continue;
            }

            target.Set("hp", target.Get("hp").AsSingle() - application.Damage);
        }

        return applications.Count;
    }

    /// <summary>在视觉异常退出且尚未命中时释放运行时快照。</summary>
    public void Forget(string attackId)
    {
        if (Guid.TryParse(attackId, out var value))
        {
            _active.Remove(new AttackInstanceId(value));
        }
    }

    /// <summary>创建不依赖发射单位后续生命状态的攻击快照。</summary>
    private AttackLaunchSnapshot CreateSnapshot(
        Node3D source,
        UnitId sourceId,
        Vector3 aimPoint,
        UnitId? targetId,
        float warheadRadius,
        ImpactSelectionMode selectionMode)
    {
        var sourcePlayer = _units.RegisterPlayer(source.GetParent());
        return new AttackLaunchSnapshot(
            new AttackInstanceId(Guid.NewGuid()),
            sourceId,
            sourcePlayer,
            WeaponDeliveryKind.Projectile,
            ToWorld(GetLaunchTransform(source).Origin),
            ToWorld(aimPoint),
            targetId,
            source.Get("attack_damage").AsSingle(),
            Math.Max(0.0f, warheadRadius),
            1.0f,
            selectionMode);
    }

    /// <summary>实例化投射物并在进入 SceneTree 前注入全部表现快照。</summary>
    private string Spawn(
        AttackLaunchSnapshot snapshot,
        string projectileScenePath,
        Node3D source,
        Node3D? target)
    {
        var scene = GD.Load<PackedScene>(projectileScenePath) ??
            throw new InvalidOperationException($"Projectile scene not found: {projectileScenePath}");
        var projectile = scene.Instantiate<Node3D>();
        var launchTransform = GetLaunchTransform(source);
        var state = new ActiveProjectile(
            snapshot,
            target is null ? null : new WeakReference<Node3D>(target),
            ToVector(snapshot.InitialAimPoint));
        _active.Add(snapshot.AttackId, state);

        var id = snapshot.AttackId.Value.ToString("D");
        projectile.Set("attack_id", id);
        projectile.Set("projectile_runtime", this);
        projectile.Set("launch_transform", launchTransform);
        projectile.Set("visible_snapshot", source.Visible);
        projectile.TreeExited += () => Forget(id);
        _projectiles.AddChild(projectile);
        return id;
    }

    /// <summary>读取炮口的世界变换；没有显式炮口时使用单位自身变换。</summary>
    private static Transform3D GetLaunchTransform(Node3D source) =>
        source.FindChild("ProjectileOrigin", true, false) is Node3D origin ?
            origin.GlobalTransform : source.GlobalTransform;

    /// <summary>要求传入对象是可提供世界坐标的 3D 节点。</summary>
    private static Node3D RequireSpatial(Node node, string parameterName) =>
        node as Node3D ?? throw new ArgumentException(
            "Projectile source and target must be Node3D.", parameterName);

    /// <summary>解析攻击实例 ID，并尝试取得仍未结算的活动快照。</summary>
    private bool TryGetActive(string attackId, out ActiveProjectile state)
    {
        state = null!;
        return Guid.TryParse(attackId, out var value) &&
            _active.TryGetValue(new AttackInstanceId(value), out state!);
    }

    private static WorldPosition ToWorld(Vector3 value) => new(value.X, value.Y, value.Z);

    private static Vector3 ToVector(WorldPosition value) => new(value.X, value.Y, value.Z);

    /// <summary>保存飞行期间唯一允许变化的最后瞄准点与目标弱引用。</summary>
    private sealed class ActiveProjectile(
        AttackLaunchSnapshot snapshot,
        WeakReference<Node3D>? target,
        Vector3 lastAimPoint)
    {
        /// <summary>发射时冻结的权威攻击数据。</summary>
        public AttackLaunchSnapshot Snapshot { get; } = snapshot;

        /// <summary>仅用于制导刷新且不会延长目标生命周期的弱引用。</summary>
        public WeakReference<Node3D>? Target { get; } = target;

        /// <summary>目标失效后继续使用的最后有效瞄准点。</summary>
        public Vector3 LastAimPoint { get; set; } = lastAimPoint;
    }
}
