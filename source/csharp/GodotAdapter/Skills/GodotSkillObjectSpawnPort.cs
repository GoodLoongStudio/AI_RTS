using AI_RTS.Application.Skills;
using AI_RTS.Domain.Common;
using AI_RTS.GodotAdapter.Configuration;
using AI_RTS.GodotAdapter.Units;
using Godot;

namespace AI_RTS.GodotAdapter.Skills;

/// <summary>按已有 PackedScene 走现有生成入口，不解释对象模板内部。</summary>
public sealed class GodotSkillObjectSpawnPort(
    GodotUnitRegistry units,
    GodotAssetManifest assets,
    Node matchSignals) : ISkillObjectSpawnPort
{
    /// <inheritdoc />
    public void SpawnObject(
        UnitTypeId templateId,
        WorldPosition position,
        float yawRadians,
        UnitId casterId)
    {
        var scene = assets.FindUnitScene(templateId);
        if (scene is null || !units.TryGetNode(casterId, out var caster))
        {
            return;
        }

        var instance = scene.Instantiate<Node3D>();
        var origin = new Vector3(position.X, position.Y, position.Z);
        var transform = new Transform3D(Basis.Identity.Rotated(Vector3.Up, yawRadians), origin);
        matchSignals.EmitSignal("setup_and_spawn_unit", instance, transform, caster.GetParent());
    }
}
