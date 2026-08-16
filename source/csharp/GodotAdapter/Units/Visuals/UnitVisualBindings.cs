using Godot;

namespace AI_RTS.GodotAdapter.Units.Visuals;

/// <summary>将单位场景中的视觉、碰撞和语义挂点公开为稳定视觉契约。</summary>
public partial class UnitVisualBindings : Node
{
    /// <summary>单位可替换视觉模型根节点路径。</summary>
    [Export] public NodePath VisualRootPath { get; set; } = new();
    /// <summary>单位碰撞根节点路径。</summary>
    [Export] public NodePath CollisionRootPath { get; set; } = new();
    /// <summary>选择提示的语义锚点路径。</summary>
    [Export] public NodePath SelectionAnchorPath { get; set; } = new();
    /// <summary>血条的语义锚点路径。</summary>
    [Export] public NodePath HealthBarAnchorPath { get; set; } = new();
    /// <summary>单位地面占位中心的语义锚点路径。</summary>
    [Export] public NodePath GroundFootprintPath { get; set; } = new();
    /// <summary>主武器炮口的语义锚点路径。</summary>
    [Export] public NodePath PrimaryMuzzlePath { get; set; } = new();
    /// <summary>可选动画根节点路径。</summary>
    [Export] public NodePath OptionalAnimationRootPath { get; set; } = new();

    /// <summary>解析后的可替换视觉模型根节点。</summary>
    public Node3D? VisualRoot { get; private set; }
    /// <summary>解析后的碰撞根节点。</summary>
    public Node3D? CollisionRoot { get; private set; }
    /// <summary>解析后的选择提示锚点。</summary>
    public Marker3D? SelectionAnchor { get; private set; }
    /// <summary>解析后的血条锚点。</summary>
    public Marker3D? HealthBarAnchor { get; private set; }
    /// <summary>解析后的地面占位中心锚点。</summary>
    public Marker3D? GroundFootprint { get; private set; }
    /// <summary>解析后的主武器炮口锚点。</summary>
    public Marker3D? PrimaryMuzzle { get; private set; }
    /// <summary>解析后的可选动画根节点。</summary>
    public Node3D? OptionalAnimationRoot { get; private set; }

    /// <summary>解析场景绑定并报告缺失的必需挂点。</summary>
    public override void _Ready()
    {
        VisualRoot = Resolve<Node3D>(VisualRootPath);
        CollisionRoot = Resolve<Node3D>(CollisionRootPath);
        SelectionAnchor = Resolve<Marker3D>(SelectionAnchorPath);
        HealthBarAnchor = Resolve<Marker3D>(HealthBarAnchorPath);
        GroundFootprint = Resolve<Marker3D>(GroundFootprintPath);
        PrimaryMuzzle = Resolve<Marker3D>(PrimaryMuzzlePath);
        OptionalAnimationRoot = Resolve<Node3D>(OptionalAnimationRootPath);

        ValidateBinding(VisualRoot, nameof(VisualRoot));
        ValidateBinding(CollisionRoot, nameof(CollisionRoot));
        ValidateBinding(SelectionAnchor, nameof(SelectionAnchor));
        ValidateBinding(HealthBarAnchor, nameof(HealthBarAnchor));
        ValidateBinding(GroundFootprint, nameof(GroundFootprint));
        ValidateBinding(PrimaryMuzzle, nameof(PrimaryMuzzle));
    }

    private T? Resolve<T>(NodePath path) where T : Node =>
        path.IsEmpty ? null : GetNodeOrNull<T>(path);

    /// <summary>报告缺失的必需视觉绑定，并保留场景路径用于定位。</summary>
    private void ValidateBinding(Node? node, string binding)
    {
        if (node is null)
        {
            GD.PushError($"UnitVisualBindings missing {binding} at {GetPath()}");
        }
    }
}
