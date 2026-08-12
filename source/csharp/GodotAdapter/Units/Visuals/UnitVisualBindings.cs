using Godot;

namespace AI_RTS.GodotAdapter.Units.Visuals;

public partial class UnitVisualBindings : Node
{
    [Export] public NodePath VisualRootPath { get; set; } = new();
    [Export] public NodePath CollisionRootPath { get; set; } = new();
    [Export] public NodePath SelectionAnchorPath { get; set; } = new();
    [Export] public NodePath HealthBarAnchorPath { get; set; } = new();
    [Export] public NodePath GroundFootprintPath { get; set; } = new();
    [Export] public NodePath PrimaryMuzzlePath { get; set; } = new();
    [Export] public NodePath OptionalAnimationRootPath { get; set; } = new();

    public Node3D? VisualRoot { get; private set; }
    public Node3D? CollisionRoot { get; private set; }
    public Marker3D? SelectionAnchor { get; private set; }
    public Marker3D? HealthBarAnchor { get; private set; }
    public Marker3D? GroundFootprint { get; private set; }
    public Marker3D? PrimaryMuzzle { get; private set; }
    public Node3D? OptionalAnimationRoot { get; private set; }

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

    private void ValidateBinding(Node? node, string binding)
    {
        if (node is null)
            GD.PushError($"UnitVisualBindings missing {binding} at {GetPath()}");
    }
}
