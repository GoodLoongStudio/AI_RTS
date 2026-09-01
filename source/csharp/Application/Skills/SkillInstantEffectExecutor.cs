using AI_RTS.Application.Combat;
using AI_RTS.Application.Configuration;
using AI_RTS.Application.Units;
using AI_RTS.Domain.Battlefield;
using AI_RTS.Domain.Combat;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Skills;

namespace AI_RTS.Application.Skills;

/// <summary>在技能命令被接受后立即执行当前已支持的即时效果。</summary>
public sealed class SkillInstantEffectExecutor(
    IUnitCommandUnitRepository units,
    IWarheadDamageResolver warheads,
    IUnitDamagePort? damage = null,
    IGameBalanceCatalog? catalog = null,
    ISkillStatusService? statuses = null,
    ISkillWorldActionPort? worldActions = null,
    ISkillObjectSpawnPort? objectSpawn = null)
{
    /// <summary>与 Demo 直接命中弹头一致的默认友伤来源。</summary>
    public static WarheadDefinitionId DefaultWarheadId { get; } = new("direct_full_damage");

    /// <summary>立即执行当前已支持的单条效果。</summary>
    public void Apply(
        UnitId casterId,
        SkillDefinition skill,
        UnitId? targetUnitId,
        WorldPosition? targetPosition,
        SkillEffectDefinition effect,
        long simulationMilliseconds)
    {
        if (!SkillEffectConditions.IsSatisfied(
            units, skill, casterId, targetUnitId, effect.Condition))
        {
            return;
        }

        if (effect.Kind == SkillEffectKind.EmitEvent)
        {
            ApplyEmitEvent(casterId, targetPosition, effect);
            return;
        }

        if (effect.Kind == SkillEffectKind.IssueCommand)
        {
            ApplyIssueCommand(casterId, targetUnitId, targetPosition, effect);
            return;
        }

        if (effect.Kind == SkillEffectKind.AddStatus)
        {
            ApplyStatus(casterId, skill, targetUnitId, effect, simulationMilliseconds);
            return;
        }

        if (effect.Kind == SkillEffectKind.CreateObject)
        {
            ApplyCreateObject(casterId, skill, targetUnitId, targetPosition, effect);
            return;
        }

        if (effect.Amount is not { } amount || !float.IsFinite(amount) || amount <= 0.0f)
        {
            return;
        }

        if (effect.Kind == SkillEffectKind.RestoreHealth)
        {
            ApplyRestore(casterId, skill, targetUnitId, amount);
            return;
        }

        if (effect.Kind != SkillEffectKind.DealDamage || damage is null)
        {
            return;
        }

        var victimId = skill.Target == SkillTargetKind.Self ? casterId : targetUnitId;
        if (victimId is null)
        {
            return;
        }

        var caster = units.Find(casterId);
        var victim = units.Find(victimId.Value);
        if (caster is null || victim is null)
        {
            return;
        }

        var origin = new WorldPosition(0, 0, 0);
        var launch = new AttackLaunchSnapshot(
            new AttackInstanceId(Guid.NewGuid()),
            casterId,
            caster.Value.OwnerId,
            WeaponDeliveryKind.Hitscan,
            origin,
            origin,
            victimId.Value,
            amount,
            0.0f,
            FriendlyFireMultiplier(),
            ImpactSelectionMode.IntendedTargetOnly);
        var candidates = new[]
        {
            new ImpactCandidateSnapshot(
                victim.Value.UnitId,
                victim.Value.OwnerId,
                origin,
                0.0f,
                victim.Value.IsDamageable)
        };
        foreach (var application in warheads.Resolve(launch, origin, candidates))
        {
            damage.ApplyDamage(application.UnitId, application.Damage);
        }
    }

    private void ApplyStatus(
        UnitId casterId,
        SkillDefinition skill,
        UnitId? targetUnitId,
        SkillEffectDefinition effect,
        long simulationMilliseconds)
    {
        if (effect.Status is null || statuses is null)
        {
            return;
        }

        var targetId = skill.Target == SkillTargetKind.Self ? casterId : targetUnitId;
        if (targetId is null)
        {
            return;
        }

        var target = units.Find(targetId.Value);
        if (target is null || !target.Value.IsAlive)
        {
            return;
        }

        statuses.Apply(targetId.Value, effect.Status, simulationMilliseconds);
    }

    private void ApplyEmitEvent(
        UnitId casterId,
        WorldPosition? targetPosition,
        SkillEffectDefinition effect)
    {
        var kind = effect.EmittedEvent ?? BattlefieldEventKind.SkillEmitted;
        var position = targetPosition ?? units.Find(casterId)?.Position ?? default;
        worldActions?.EmitBattlefieldEvent(kind, position, effect.EmittedEventImportant);
    }

    private void ApplyCreateObject(
        UnitId casterId,
        SkillDefinition skill,
        UnitId? targetUnitId,
        WorldPosition? targetPosition,
        SkillEffectDefinition effect)
    {
        if (objectSpawn is null || effect.ObjectTemplateId is null)
        {
            return;
        }

        var caster = units.Find(casterId);
        if (caster is null)
        {
            return;
        }

        var position = targetPosition;
        if (skill.Target == SkillTargetKind.Self || position is null)
        {
            position = targetUnitId is { } id ? units.Find(id)?.Position : caster.Value.Position;
        }

        if (position is not { } point ||
            !float.IsFinite(point.X) ||
            !float.IsFinite(point.Y) ||
            !float.IsFinite(point.Z))
        {
            return;
        }

        var origin = caster.Value.Position;
        var dx = point.X - origin.X;
        var dz = point.Z - origin.Z;
        var yaw = dx * dx + dz * dz > 0.0001f ? MathF.Atan2(dx, dz) : 0.0f;
        objectSpawn.SpawnObject(effect.ObjectTemplateId.Value, point, yaw, casterId);
    }

    private void ApplyIssueCommand(
        UnitId casterId,
        UnitId? targetUnitId,
        WorldPosition? targetPosition,
        SkillEffectDefinition effect)
    {
        if (worldActions is null || effect.IssuedCommand is null)
        {
            return;
        }

        if (effect.IssuedCommand == SkillIssuedCommandKind.Move)
        {
            var destination = targetPosition ??
                (targetUnitId is { } id ? units.Find(id)?.Position : null);
            if (destination is { } point &&
                float.IsFinite(point.X) &&
                float.IsFinite(point.Y) &&
                float.IsFinite(point.Z))
            {
                worldActions.IssueMove(casterId, point);
            }

            return;
        }

        if (effect.IssuedCommand == SkillIssuedCommandKind.Attack && targetUnitId is { } target)
        {
            worldActions.IssueAttack(casterId, target);
        }
    }

    private void ApplyRestore(
        UnitId casterId,
        SkillDefinition skill,
        UnitId? targetUnitId,
        float amount)
    {
        var targetId = skill.Target == SkillTargetKind.Self ? casterId : targetUnitId;
        if (targetId is null)
        {
            return;
        }

        var target = units.Find(targetId.Value);
        if (target is null || !target.Value.IsAlive || !target.Value.IsDamageable)
        {
            return;
        }

        var missing = target.Value.MaximumHealth > 0.0f ?
            Math.Max(0.0f, target.Value.MaximumHealth - target.Value.CurrentHealth) :
            amount;
        var heal = Math.Min(amount, missing);
        if (heal > 0.0f)
        {
            damage?.RestoreHealth(target.Value.UnitId, heal);
        }
    }

    private float FriendlyFireMultiplier() =>
        catalog?.FindWarhead(DefaultWarheadId)?.FriendlyFireDamageMultiplier ?? 1.0f;
}
