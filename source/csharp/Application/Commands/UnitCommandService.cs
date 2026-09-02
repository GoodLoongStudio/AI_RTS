using AI_RTS.Application.Battlefield;
using AI_RTS.Application.Commands.Units;
using AI_RTS.Application.Combat;
using AI_RTS.Application.Configuration;
using AI_RTS.Application.Construction;
using AI_RTS.Application.Orders;
using AI_RTS.Application.Economy;
using AI_RTS.Application.Skills;
using AI_RTS.Application.Units;
using AI_RTS.Domain.Battlefield;
using AI_RTS.Domain.Combat;
using AI_RTS.Domain.Common;
using AI_RTS.Domain.Economy;
using AI_RTS.Domain.Skills;

namespace AI_RTS.Application.Commands;

/// <summary>提供经过权限与能力校验的单位命令入口。</summary>
public interface IUnitCommandService
{
    /// <summary>提交批量普通移动命令，并返回每个单位的接收结果。</summary>
    CommandResult Move(CommandContext context, MoveUnitsCommand command);

    /// <summary>提交批量靠近实体命令，并在真正邻接后完成。</summary>
    CommandResult ApproachEntity(CommandContext context, ApproachEntityCommand command);

    /// <summary>提交批量持续跟随命令，并保持目标稳定身份。</summary>
    CommandResult FollowEntity(CommandContext context, FollowEntityCommand command);

    /// <summary>提交批量强制移动命令，并返回每个单位的接收结果。</summary>
    CommandResult ForceMove(CommandContext context, ForceMoveUnitsCommand command);

    /// <summary>提交批量地面移动攻击命令，并返回逐单位接收结果。</summary>
    CommandResult GroundAttackMove(CommandContext context, GroundAttackMoveCommand command);

    /// <summary>提交以敌方实体为最终目标的移动攻击命令，并返回逐单位接收结果。</summary>
    CommandResult EntityAttackMove(CommandContext context, EntityAttackMoveCommand command);

    /// <summary>提交批量战术撤退命令，并按单位能力选择倒车或普通移动执行。</summary>
    CommandResult TacticalWithdraw(CommandContext context, TacticalWithdrawCommand command);

    /// <summary>停止单位当前移动，并将已有活动订单转为暂停。</summary>
    CommandResult HaltMovement(CommandContext context, HaltMovementCommand command);

    /// <summary>提交批量统一停止命令，并返回每个单位独立的接收结果。</summary>
    CommandResult Stop(CommandContext context, StopUnitsCommand command);

    /// <summary>设置单位持续交战姿态，不改变开火策略。</summary>
    CommandResult SetEngagementStance(CommandContext context, SetEngagementStanceCommand command);

    /// <summary>设置单位持续开火策略，不改变交战姿态。</summary>
    CommandResult SetFirePolicy(CommandContext context, SetFirePolicyCommand command);

    /// <summary>提交批量普通实体攻击；停火或非敌方目标按单位稳定拒绝。</summary>
    CommandResult Attack(CommandContext context, AttackCommand command);

    /// <summary>提交批量显式强制攻击，并返回每个攻击者的接收结果。</summary>
    CommandResult ForceAttack(CommandContext context, ForceAttackCommand command);

    /// <summary>只取消当前显式 ForceAttack，不影响普通自动攻击。</summary>
    CommandResult CancelForceAttack(CommandContext context, CancelForceAttackCommand command);

    /// <summary>提交持续采集任务，并返回每个 Worker 的独立接收结果。</summary>
    CommandResult GatherResources(CommandContext context, GatherResourcesCommand command);

    /// <summary>提交主动技能施放；接受后按时间规则调度已支持的效果，不替换现有订单。</summary>
    CommandResult CastSkill(CommandContext context, CastSkillCommand command);

    /// <summary>按模拟毫秒推进已排队的延迟效果；时刻不变则后续段不发生。</summary>
    void AdvanceSkillEffects(long simulationMilliseconds);

    /// <summary>按单位类型把目录中声明装配的技能挂到该单位（含 HUD 主动槽）。</summary>
    void EquipAutomaticSkills(UnitId unitId);

    /// <summary>返回该单位已装配的主动技能槽及当前冷却剩余。</summary>
    IReadOnlyList<SkillHudSlot> GetHudSlots(UnitId unitId, long simulationMilliseconds);

    /// <summary>测试或脚本显式授予一条非主动技能。</summary>
    void GrantSkill(UnitId unitId, SkillDefinitionId skillId);

    /// <summary>单位离开战场时移除其自动技能装配。</summary>
    void RevokeAutomaticSkills(UnitId unitId);

    /// <summary>单位受伤后尝试触发已装配的事件技能。</summary>
    void NotifyUnitDamaged(MatchId match, UnitId unitId, long simulationMilliseconds);

    /// <summary>评估已装配的被动和条件技能；时刻不变则冷却中的不会再生效。</summary>
    void EvaluateAutomaticSkills(MatchId match, long simulationMilliseconds);

    /// <summary>按配置取消施放前等待或尚未执行的效果；已生效结果不回滚。</summary>
    void InterruptSkills(
        MatchId match,
        UnitId unitId,
        SkillInterruptCause cause,
        long simulationMilliseconds);
}

/// <summary>协调单位校验、导航端口调用与订单状态更新。</summary>
public sealed class UnitCommandService(
    IUnitCommandUnitRepository units,
    IUnitMovementPort movement,
    IUnitAttackPort attack,
    IUnitOrderStore orders,
    ICombatPolicyStore combatPolicies,
    IUnitStopPort stop,
    IWorkerTaskPort? workerTasks = null,
    IResourceNodeRepository? resourceNodes = null,
    IConstructionTaskCoordinator? constructionTasks = null,
    IGameBalanceCatalog? catalog = null,
    IUnitDamagePort? damage = null,
    IWarheadDamageResolver? warheads = null,
    ISkillCastJournal? skillCasts = null,
    IResourceAccountService? accounts = null,
    ISkillCooldownStore? cooldowns = null,
    IUnitMoveSpeedPort? moveSpeed = null,
    IBattlefieldEventLog? battlefieldEvents = null,
    ISkillObjectSpawnPort? objectSpawn = null,
    ICommandCenterRepository? commandCenters = null) : IUnitCommandService, ISkillWorldActionPort
{
    private readonly IGameBalanceCatalog? _catalog = catalog;
    private readonly IResourceAccountService? _accounts = accounts;
    private readonly ISkillCooldownStore? _cooldowns = cooldowns;
    private readonly IBattlefieldEventLog? _battlefieldEvents = battlefieldEvents;
    private readonly ISkillObjectSpawnPort? _objectSpawn = objectSpawn;
    private readonly ICommandCenterRepository? _commandCenters = commandCenters;
    private readonly ISkillLoadoutStore _loadout = new InMemorySkillLoadoutStore();
    private readonly List<PendingSkillActivation> _pendingActivations = [];
    private MatchId _lastMatchId;
    private SkillRuntime? _skillRuntime;
    /// <inheritdoc />
    public CommandResult Move(CommandContext context, MoveUnitsCommand command)
    {
        if (command.UnitIds.Count == 0 || !IsFinite(command.Destination))
        {
            return Rejected(context.CommandId, command.UnitIds,
                command.UnitIds.Count == 0 ? CommandErrorCode.EmptyUnitSet : CommandErrorCode.InvalidDestination);
        }

        var formation = ComputeFormationDestinations(command.UnitIds, command.Destination);
        return ExecuteMove(
            context,
            command.UnitIds,
            UnitOrderKind.Move,
            unitId => new UnitOrderPositionTarget(formation[unitId]),
            unitId => movement.RequestMove(unitId, formation[unitId]));
    }

    /// <inheritdoc />
    public CommandResult ApproachEntity(
        CommandContext context,
        ApproachEntityCommand command)
    {
        if (command.UnitIds.Count == 0)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.EmptyUnitSet);
        }

        var target = FindApproachTarget(command.TargetEntityId);
        if (target is null)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.TargetNotFound);
        }

        return ExecuteEntityMovement(
            context,
            command.UnitIds,
            UnitOrderKind.ApproachEntity,
            target,
            unitId => movement.RequestApproachEntity(unitId, command.TargetEntityId));
    }

    /// <inheritdoc />
    public CommandResult FollowEntity(CommandContext context, FollowEntityCommand command)
    {
        if (command.UnitIds.Count == 0)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.EmptyUnitSet);
        }

        var target = units.Find(command.TargetUnitId);
        if (target is null)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.TargetNotFound);
        }

        return ExecuteEntityMovement(
            context,
            command.UnitIds,
            UnitOrderKind.FollowEntity,
            EntityOrderTarget(target.Value),
            unitId => movement.RequestFollowEntity(unitId, command.TargetUnitId));
    }

    /// <inheritdoc />
    public CommandResult ForceMove(CommandContext context, ForceMoveUnitsCommand command)
    {
        if (command.UnitIds.Count == 0 || !IsFinite(command.Destination))
        {
            return Rejected(context.CommandId, command.UnitIds,
                command.UnitIds.Count == 0 ? CommandErrorCode.EmptyUnitSet : CommandErrorCode.InvalidDestination);
        }

        return ExecuteMove(
            context,
            command.UnitIds,
            UnitOrderKind.ForceMove,
            new UnitOrderPositionTarget(command.Destination),
            unitId => movement.RequestMove(unitId, command.Destination));
    }

    /// <inheritdoc />
    public CommandResult GroundAttackMove(CommandContext context, GroundAttackMoveCommand command)
    {
        if (command.UnitIds.Count == 0 || !IsFinite(command.Destination))
        {
            return Rejected(context.CommandId, command.UnitIds,
                command.UnitIds.Count == 0 ? CommandErrorCode.EmptyUnitSet : CommandErrorCode.InvalidDestination);
        }

        return ExecuteMove(
            context,
            command.UnitIds,
            UnitOrderKind.GroundAttackMove,
            new UnitOrderPositionTarget(command.Destination),
            unitId => movement.RequestGroundAttackMove(unitId, command.Destination));
    }

    /// <inheritdoc />
    public CommandResult EntityAttackMove(CommandContext context, EntityAttackMoveCommand command)
    {
        if (command.UnitIds.Count == 0)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.EmptyUnitSet);
        }

        var target = units.Find(command.Target.TargetUnitId);
        if (target is null)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.TargetNotFound);
        }
        if (!target.Value.IsDamageable)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.TargetNotDamageable);
        }

        var results = new List<UnitCommandResult>();
        foreach (var unitId in StableDistinct(command.UnitIds))
        {
            var validation = ValidateAttackMove(context, unitId, target.Value);
            if (validation != CommandErrorCode.None)
            {
                results.Add(new UnitCommandResult(unitId, false, validation));
                continue;
            }

            var portResult = movement.RequestEntityAttackMove(unitId, command.Target.TargetUnitId);
            if (!portResult.Accepted)
            {
                results.Add(new UnitCommandResult(unitId, false, Map(portResult.Error)));
                continue;
            }

            var order = orders.Create(
                context.CommandId,
                unitId,
                UnitOrderKind.EntityAttackMove,
                EntityOrderTarget(target.Value));
            orders.Transition(order.OrderId, UnitOrderState.InProgress);
            results.Add(new UnitCommandResult(unitId, true, CommandErrorCode.None, order.OrderId));
        }
        return Summarize(context.CommandId, results);
    }

    /// <inheritdoc />
    public CommandResult TacticalWithdraw(CommandContext context, TacticalWithdrawCommand command)
    {
        if (command.UnitIds.Count == 0 || !IsFinite(command.Destination))
        {
            return Rejected(context.CommandId, command.UnitIds,
                command.UnitIds.Count == 0 ? CommandErrorCode.EmptyUnitSet : CommandErrorCode.InvalidDestination);
        }

        return ExecuteMove(
            context,
            command.UnitIds,
            UnitOrderKind.TacticalWithdraw,
            new UnitOrderPositionTarget(command.Destination),
            unitId => units.Find(unitId)!.Value.CanReverse ?
                movement.RequestTacticalWithdraw(unitId, command.Destination) :
                movement.RequestMove(unitId, command.Destination));
    }

    /// <inheritdoc />
    public CommandResult HaltMovement(CommandContext context, HaltMovementCommand command)
    {
        if (command.UnitIds.Count == 0)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.EmptyUnitSet);
        }

        var results = new List<UnitCommandResult>();
        foreach (var unitId in StableDistinct(command.UnitIds))
        {
            var validation = Validate(context, unitId);
            if (validation != CommandErrorCode.None)
            {
                results.Add(new UnitCommandResult(unitId, false, validation));
                continue;
            }

            var portResult = movement.RequestHalt(unitId);
            if (!portResult.Accepted)
            {
                results.Add(new UnitCommandResult(unitId, false, Map(portResult.Error)));
                continue;
            }

            var active = orders.FindActive(unitId);
            if (active?.Kind is UnitOrderKind.Move or UnitOrderKind.ApproachEntity or
                UnitOrderKind.FollowEntity or UnitOrderKind.ForceMove or
                UnitOrderKind.GroundAttackMove or UnitOrderKind.EntityAttackMove or
                UnitOrderKind.TacticalWithdraw or UnitOrderKind.ReturnToBase)
            {
                orders.Transition(active.OrderId, UnitOrderState.Suspended);
            }
            results.Add(new UnitCommandResult(
                unitId,
                true,
                CommandErrorCode.None,
                active?.Kind is UnitOrderKind.Move or UnitOrderKind.ApproachEntity or
                    UnitOrderKind.FollowEntity or UnitOrderKind.ForceMove or
                    UnitOrderKind.GroundAttackMove or UnitOrderKind.EntityAttackMove or
                    UnitOrderKind.TacticalWithdraw or UnitOrderKind.ReturnToBase ?
                    active.OrderId : null));
        }
        return Summarize(context.CommandId, results);
    }

    /// <inheritdoc />
    public CommandResult GatherResources(
        CommandContext context,
        GatherResourcesCommand command)
    {
        if (command.WorkerIds.Count == 0)
        {
            return Rejected(
                context.CommandId,
                command.WorkerIds,
                CommandErrorCode.EmptyUnitSet);
        }

        var resource = resourceNodes?.Find(command.TargetResourceId);
        if (resource is null)
        {
            return Rejected(
                context.CommandId,
                command.WorkerIds,
                CommandErrorCode.ResourceTargetNotFound);
        }
        if (!resource.Value.IsAvailable)
        {
            return Rejected(
                context.CommandId,
                command.WorkerIds,
                CommandErrorCode.ResourceDepleted);
        }

        var results = new List<UnitCommandResult>();
        foreach (var workerId in StableDistinct(command.WorkerIds))
        {
            var ownership = ValidateOwnership(context, workerId);
            if (ownership != CommandErrorCode.None)
            {
                results.Add(new UnitCommandResult(workerId, false, ownership));
                continue;
            }

            var worker = units.Find(workerId)!.Value;
            if (!worker.CanGather)
            {
                results.Add(new UnitCommandResult(
                    workerId,
                    false,
                    CommandErrorCode.UnitCannotGather));
                continue;
            }

            var portResult = workerTasks?.RequestGather(workerId, command.TargetResourceId);
            if (portResult is null || !portResult.Value.Accepted)
            {
                results.Add(new UnitCommandResult(
                    workerId,
                    false,
                    portResult is null ?
                        CommandErrorCode.WorkUnavailable : Map(portResult.Value.Error)));
                continue;
            }

            var order = orders.Create(
                context.CommandId,
                workerId,
                UnitOrderKind.Gather,
                new UnitOrderEntityTarget(
                    new BattlefieldEntityId(
                        BattlefieldEntityKind.ResourceNode,
                        resource.Value.ResourceNodeId.Value),
                    ResourceTypeId(resource.Value.Kind)));
            orders.Transition(order.OrderId, UnitOrderState.InProgress);
            results.Add(new UnitCommandResult(
                workerId,
                true,
                CommandErrorCode.None,
                order.OrderId));
        }

        return Summarize(context.CommandId, results);
    }

    /// <inheritdoc />
    public CommandResult CastSkill(CommandContext context, CastSkillCommand command)
    {
        _lastMatchId = context.MatchId;
        if (command.UnitIds.Count == 0)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.EmptyUnitSet);
        }

        var skill = _catalog?.FindSkill(command.SkillId);
        if (skill is null)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.SkillNotFound);
        }
        if (skill.Trigger != SkillTriggerKind.Active)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.SkillNotCastable);
        }
        if (skill.Target is not SkillTargetKind.Self and not SkillTargetKind.Unit
            and not SkillTargetKind.Ground)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.InvalidSkillTarget);
        }
        if (skill.Target == SkillTargetKind.Unit)
        {
            if (command.TargetUnitId is null)
            {
                return Rejected(
                    context.CommandId, command.UnitIds, CommandErrorCode.InvalidSkillTarget);
            }
            if (units.Find(command.TargetUnitId.Value) is null)
            {
                return Rejected(
                    context.CommandId, command.UnitIds, CommandErrorCode.TargetNotFound);
            }
        }
        if (skill.Target == SkillTargetKind.Ground &&
            (command.TargetPosition is null || !IsFinite(command.TargetPosition.Value)))
        {
            return Rejected(
                context.CommandId, command.UnitIds, CommandErrorCode.InvalidDestination);
        }

        var results = new List<UnitCommandResult>();
        foreach (var unitId in StableDistinct(command.UnitIds))
        {
            var ownership = ValidateOwnership(context, unitId);
            if (ownership != CommandErrorCode.None)
            {
                results.Add(new UnitCommandResult(unitId, false, ownership));
                continue;
            }

            var targeting = ValidateSkillTarget(skill, unitId, command);
            if (targeting != CommandErrorCode.None)
            {
                results.Add(new UnitCommandResult(unitId, false, targeting));
                continue;
            }

            var begin = BeginSkill(
                context,
                unitId,
                skill,
                command.TargetUnitId,
                command.TargetPosition);
            results.Add(new UnitCommandResult(unitId, begin == CommandErrorCode.None, begin));
        }
        return Summarize(context.CommandId, results);
    }

    /// <inheritdoc />
    public void AdvanceSkillEffects(long simulationMilliseconds)
    {
        ActivateDueSkills(simulationMilliseconds);
        Skill.Timeline.Advance(simulationMilliseconds);
        Skill.Statuses.Advance(simulationMilliseconds);
    }

    /// <inheritdoc />
    public void EquipAutomaticSkills(UnitId unitId)
    {
        var snapshot = units.Find(unitId);
        if (snapshot is null || string.IsNullOrWhiteSpace(snapshot.Value.TypeId) || _catalog is null)
        {
            return;
        }

        var typeId = new UnitTypeId(snapshot.Value.TypeId);
        foreach (var skill in _catalog.Skills)
        {
            if ((skill.EquippedUnitTypeIds ?? []).Any(item => item.Equals(typeId)))
            {
                _loadout.Grant(unitId, skill.Id);
            }
        }
    }

    /// <inheritdoc />
    public IReadOnlyList<SkillHudSlot> GetHudSlots(UnitId unitId, long simulationMilliseconds)
    {
        if (_catalog is null)
        {
            return [];
        }

        return _loadout.SkillsOf(unitId)
            .Select(skillId => _catalog.FindSkill(skillId))
            .OfType<SkillDefinition>()
            .Where(skill => skill.Trigger == SkillTriggerKind.Active)
            .OrderBy(skill => skill.Id.Value, StringComparer.Ordinal)
            .Select(skill =>
            {
                var remaining = _cooldowns?.RemainingMilliseconds(
                    unitId, skill.Id, simulationMilliseconds) ?? 0;
                return new SkillHudSlot(skill.Id, skill.Target, remaining, remaining == 0);
            })
            .ToArray();
    }

    /// <inheritdoc />
    public void GrantSkill(UnitId unitId, SkillDefinitionId skillId)
    {
        var skill = _catalog?.FindSkill(skillId);
        if (skill is null || skill.Trigger == SkillTriggerKind.Active)
        {
            return;
        }

        _loadout.Grant(unitId, skillId);
    }

    /// <inheritdoc />
    public void RevokeAutomaticSkills(UnitId unitId) => _loadout.RevokeAll(unitId);

    /// <inheritdoc />
    public void NotifyUnitDamaged(MatchId match, UnitId unitId, long simulationMilliseconds)
    {
        _lastMatchId = match;
        foreach (var skillId in _loadout.SkillsOf(unitId))
        {
            var skill = _catalog?.FindSkill(skillId);
            if (skill is null ||
                skill.Trigger != SkillTriggerKind.Event ||
                skill.TriggerEvent != SkillTriggerEvent.UnitDamaged)
            {
                continue;
            }

            TryActivateAutomatic(match, unitId, skill, simulationMilliseconds);
        }
    }

    /// <inheritdoc />
    public void EvaluateAutomaticSkills(MatchId match, long simulationMilliseconds)
    {
        _lastMatchId = match;
        foreach (var (unitId, skillId) in _loadout.All())
        {
            var skill = _catalog?.FindSkill(skillId);
            if (skill is null)
            {
                continue;
            }

            if (skill.Trigger == SkillTriggerKind.Passive)
            {
                TryActivateAutomatic(match, unitId, skill, simulationMilliseconds);
                continue;
            }

            if (skill.Trigger == SkillTriggerKind.Condition &&
                SkillEffectConditions.IsSatisfied(
                    units, skill, unitId, null, skill.ActivationCondition))
            {
                TryActivateAutomatic(match, unitId, skill, simulationMilliseconds);
            }
        }
    }

    /// <summary>不经玩家确认，复用目标、消耗、冷却和效果时间线。</summary>
    private void TryActivateAutomatic(
        MatchId match,
        UnitId unitId,
        SkillDefinition skill,
        long simulationMilliseconds)
    {
        var snapshot = units.Find(unitId);
        if (snapshot is null)
        {
            return;
        }

        var context = new CommandContext(
            new CommandId(Guid.NewGuid()),
            match,
            snapshot.Value.OwnerId,
            0,
            simulationMilliseconds);
        if (skill.ActivationCondition != SkillEffectCondition.Always &&
            !SkillEffectConditions.IsSatisfied(
                units, skill, unitId, null, skill.ActivationCondition))
        {
            return;
        }

        var command = new CastSkillCommand([unitId], skill.Id);
        if (ValidateSkillTarget(skill, unitId, command) != CommandErrorCode.None)
        {
            return;
        }

        if (_cooldowns is not null &&
            !_cooldowns.IsReady(unitId, skill.Id, simulationMilliseconds))
        {
            return;
        }

        BeginSkill(context, unitId, skill, null, null);
    }

    /// <summary>按技能配置校验自身、单位或地面目标。</summary>
    private CommandErrorCode ValidateSkillTarget(
        SkillDefinition skill,
        UnitId casterId,
        CastSkillCommand command)
    {
        var caster = units.Find(casterId);
        if (caster is null)
        {
            return CommandErrorCode.UnitNotFound;
        }
        if (skill.Target == SkillTargetKind.Self)
        {
            return CommandErrorCode.None;
        }
        if (skill.Target == SkillTargetKind.Ground)
        {
            return SkillTargeting.ValidateGroundTarget(skill, caster.Value, command.TargetPosition);
        }

        var target = units.Find(command.TargetUnitId!.Value);
        return target is null ?
            CommandErrorCode.TargetNotFound :
            SkillTargeting.ValidateUnitTarget(skill, caster.Value, target.Value);
    }

    /// <inheritdoc />
    public void InterruptSkills(
        MatchId match,
        UnitId unitId,
        SkillInterruptCause cause,
        long simulationMilliseconds)
    {
        _lastMatchId = match;
        _pendingActivations.RemoveAll(item =>
            item.CasterId == unitId &&
            AllowsInterrupt(item.Skill, SkillInterruptPhase.BeforeActivation, cause));

        var cancelled = Skill.Timeline.CancelPending(
            unitId,
            skill => AllowsInterrupt(skill, SkillInterruptPhase.AfterActivation, cause));
        foreach (var skill in cancelled)
        {
            if (skill.Interrupt?.RefundCost == true)
            {
                TryRefundSkillCost(match, unitId, skill);
            }

            if (skill.Interrupt?.KeepCooldown == false)
            {
                _cooldowns?.Clear(unitId, skill.Id);
            }
        }
    }

    /// <summary>校验冷却与预扣，再进入施放前等待或立即正式生效。</summary>
    private CommandErrorCode BeginSkill(
        CommandContext context,
        UnitId unitId,
        SkillDefinition skill,
        UnitId? targetUnitId,
        WorldPosition? targetPosition)
    {
        if (_pendingActivations.Any(item => item.CasterId == unitId))
        {
            return CommandErrorCode.SkillBusy;
        }

        if (_cooldowns is not null &&
            !_cooldowns.IsReady(unitId, skill.Id, context.SimulationMilliseconds))
        {
            return CommandErrorCode.SkillOnCooldown;
        }

        if (!CanAffordSkill(context.IssuerPlayerId, skill))
        {
            return CommandErrorCode.InsufficientResources;
        }

        if (skill.CastDelayMilliseconds > 0)
        {
            _pendingActivations.Add(new PendingSkillActivation(
                unitId,
                skill,
                targetUnitId,
                targetPosition,
                checked(context.SimulationMilliseconds + skill.CastDelayMilliseconds),
                context.MatchId,
                context.IssuerPlayerId,
                context.CommandId));
            return CommandErrorCode.None;
        }

        return ActivateSkill(context, unitId, skill, targetUnitId, targetPosition);
    }

    /// <summary>把已到期的施放前等待转为正式生效。</summary>
    private void ActivateDueSkills(long simulationMilliseconds)
    {
        var due = _pendingActivations
            .Where(item => item.ActivateAtMilliseconds <= simulationMilliseconds)
            .OrderBy(item => item.ActivateAtMilliseconds)
            .ToArray();
        foreach (var item in due)
        {
            _pendingActivations.Remove(item);
            var context = new CommandContext(
                item.CommandId,
                item.MatchId,
                item.OwnerId,
                0,
                simulationMilliseconds);
            ActivateSkill(context, item.CasterId, item.Skill, item.TargetUnitId, item.TargetPosition);
        }
    }

    /// <summary>正式生效：扣费、开冷却、调度效果。已生效结果之后中断不回滚。</summary>
    private CommandErrorCode ActivateSkill(
        CommandContext context,
        UnitId unitId,
        SkillDefinition skill,
        UnitId? targetUnitId,
        WorldPosition? targetPosition)
    {
        var payment = TryPaySkillCost(context, unitId, skill);
        if (payment != CommandErrorCode.None)
        {
            return payment;
        }

        _cooldowns?.Start(
            unitId, skill.Id, context.SimulationMilliseconds, skill.CooldownMilliseconds);
        Skill.Timeline.Schedule(
            unitId, skill, targetUnitId, targetPosition, context.SimulationMilliseconds);
        skillCasts?.Record(new SkillCastRecord(
            context.CommandId,
            unitId,
            skill.Id,
            skill.Target == SkillTargetKind.Self ? unitId : targetUnitId,
            targetPosition));
        return CommandErrorCode.None;
    }

    private static bool AllowsInterrupt(
        SkillDefinition skill,
        SkillInterruptPhase phase,
        SkillInterruptCause cause) =>
        skill.Interrupt is { } interrupt &&
        interrupt.Phases.Contains(phase) &&
        interrupt.Causes.Contains(cause);

    private bool CanAffordSkill(PlayerId playerId, SkillDefinition skill)
    {
        var cost = skill.Cost ?? [];
        if (cost.Count == 0)
        {
            return true;
        }

        var account = _accounts?.Find(playerId);
        return account is not null &&
            cost.All(item => account.GetBalance(item.Kind) >= item.Amount);
    }

    private void TryRefundSkillCost(
        MatchId match,
        UnitId casterId,
        SkillDefinition skill)
    {
        var cost = skill.Cost ?? [];
        if (cost.Count == 0 || _accounts is null)
        {
            return;
        }

        var owner = units.Find(casterId)?.OwnerId;
        if (owner is null)
        {
            return;
        }

        _accounts.Apply(new ApplyResourceTransaction(
            new ResourceTransactionId(Guid.NewGuid()),
            match,
            owner.Value,
            cost.Select(item => new ResourceDelta(item.Kind, item.Amount)).ToArray(),
            ResourceChangeReason.SkillRefund,
            casterId.Value,
            0));
    }

    /// <summary>在正式生效时扣除配置消耗；失败不开始冷却、不执行效果。</summary>
    private CommandErrorCode TryPaySkillCost(
        CommandContext context,
        UnitId casterId,
        SkillDefinition skill)
    {
        var cost = skill.Cost ?? [];
        if (cost.Count == 0)
        {
            return CommandErrorCode.None;
        }
        if (_accounts is null)
        {
            return CommandErrorCode.InsufficientResources;
        }

        var payment = _accounts.Apply(new ApplyResourceTransaction(
            new ResourceTransactionId(Guid.NewGuid()),
            context.MatchId,
            context.IssuerPlayerId,
            cost.Select(item => new ResourceDelta(item.Kind, -item.Amount)).ToArray(),
            ResourceChangeReason.SkillCost,
            casterId.Value,
            context.SimulationTick));
        return payment.Status is ResourceTransactionStatus.Applied
            or ResourceTransactionStatus.AlreadyApplied ?
            CommandErrorCode.None : CommandErrorCode.InsufficientResources;
    }

    /// <summary>把强类型资源种类转换为公共观察使用的稳定类型键。</summary>
    private static string ResourceTypeId(ResourceKind kind) => kind switch
    {
        ResourceKind.A => "resource_a",
        ResourceKind.B => "resource_b",
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, "未知资源种类。")
    };

    /// <inheritdoc />
    public CommandResult Stop(CommandContext context, StopUnitsCommand command)
    {
        if (command.UnitIds.Count == 0)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.EmptyUnitSet);
        }

        var results = new List<UnitCommandResult>();
        foreach (var unitId in StableDistinct(command.UnitIds))
        {
            var validation = ValidateOwnership(context, unitId);
            if (validation != CommandErrorCode.None)
            {
                results.Add(new UnitCommandResult(unitId, false, validation));
                continue;
            }

            InterruptSkills(
                context.MatchId, unitId, SkillInterruptCause.Stop, context.SimulationMilliseconds);

            var active = orders.FindActive(unitId);
            if (active?.Kind == UnitOrderKind.Gather)
            {
                var workResult = workerTasks?.RequestSuspend(unitId);
                if (workResult is null || !workResult.Value.Accepted)
                {
                    results.Add(new UnitCommandResult(
                        unitId,
                        false,
                        workResult is null ?
                            CommandErrorCode.WorkUnavailable : Map(workResult.Value.Error)));
                    continue;
                }
            }
            else if (active?.Kind == UnitOrderKind.Construct)
            {
                var constructionResult = constructionTasks?.RequestSuspend(unitId);
                if (constructionResult is null || !constructionResult.Value.Accepted)
                {
                    results.Add(new UnitCommandResult(
                        unitId,
                        false,
                        constructionResult is null ?
                            CommandErrorCode.ConstructionUnavailable :
                            Map(constructionResult.Value.Error)));
                    continue;
                }
            }
            else
            {
                var portResult = stop.RequestStop(unitId);
                if (!portResult.Accepted)
                {
                    results.Add(new UnitCommandResult(unitId, false, Map(portResult.Error)));
                    continue;
                }
            }

            var affectedOrderId = TransitionStoppedOrder(context, active);
            results.Add(new UnitCommandResult(
                unitId,
                true,
                CommandErrorCode.None,
                affectedOrderId));
        }

        return Summarize(context.CommandId, results);
    }

    /// <summary>按照订单种类应用统一停止状态；攻击订单取消，持续战斗策略保持不变。</summary>
    private UnitOrderId? TransitionStoppedOrder(
        CommandContext context,
        UnitOrderSnapshot? active)
    {
        if (active?.Kind is UnitOrderKind.Move or UnitOrderKind.ApproachEntity or
            UnitOrderKind.FollowEntity or UnitOrderKind.ForceMove or
            UnitOrderKind.GroundAttackMove or UnitOrderKind.EntityAttackMove or
            UnitOrderKind.TacticalWithdraw or UnitOrderKind.ReturnToBase or UnitOrderKind.Gather or
            UnitOrderKind.Construct)
        {
            orders.Transition(active.OrderId, UnitOrderState.Suspended);
            return active.OrderId;
        }
        if (active?.Kind is UnitOrderKind.Attack or UnitOrderKind.ForceAttack or
            UnitOrderKind.GroundForceAttack)
        {
            orders.Transition(active.OrderId, UnitOrderState.Cancelled, context.CommandId);
            return active.OrderId;
        }

        return null;
    }

    /// <inheritdoc />
    public CommandResult SetEngagementStance(
        CommandContext context,
        SetEngagementStanceCommand command)
    {
        if (command.UnitIds.Count == 0 || !Enum.IsDefined(command.Stance))
        {
            return Rejected(
                context.CommandId,
                command.UnitIds,
                command.UnitIds.Count == 0 ?
                    CommandErrorCode.EmptyUnitSet : CommandErrorCode.InvalidEngagementStance);
        }

        return command.Stance == EngagementStance.ReturnToBase ?
            SetReturnToBaseStance(context, command) :
            SetRegularEngagementStance(context, command);
    }

    /// <summary>设置普通战斗姿态，并在离开基地回防姿态时取消其活动回防订单。</summary>
    private CommandResult SetRegularEngagementStance(
        CommandContext context,
        SetEngagementStanceCommand command)
    {
        var results = new List<UnitCommandResult>();
        foreach (var unitId in StableDistinct(command.UnitIds))
        {
            var validation = ValidateOwnership(context, unitId);
            if (validation != CommandErrorCode.None)
            {
                results.Add(new UnitCommandResult(unitId, false, validation));
                continue;
            }

            if (orders.FindActive(unitId) is { Kind: UnitOrderKind.ReturnToBase } active)
            {
                // Transition first so a synchronous legacy movement callback cannot
                // incorrectly report the superseded ReturnToBase order as Arrived.
                orders.Transition(active.OrderId, UnitOrderState.Cancelled, context.CommandId);
                movement.RequestHalt(unitId);
            }

            combatPolicies.SetEngagementStance(unitId, command.Stance);
            results.Add(new UnitCommandResult(unitId, true, CommandErrorCode.None));
        }
        return Summarize(context.CommandId, results);
    }

    /// <summary>
    /// 设置基地回防姿态：权威选择最近己方已完成 CommandCenter，
    /// 再提交全速回防请求并建立可观察的持续订单。
    /// </summary>
    private CommandResult SetReturnToBaseStance(
        CommandContext context,
        SetEngagementStanceCommand command)
    {
        var results = new List<UnitCommandResult>();
        foreach (var unitId in StableDistinct(command.UnitIds))
        {
            var validation = Validate(context, unitId);
            if (validation != CommandErrorCode.None)
            {
                results.Add(new UnitCommandResult(unitId, false, validation));
                continue;
            }

            var unit = units.Find(unitId)!.Value;
            var commandCenter = _commandCenters?.FindNearestCompletedCommandCenter(
                unit.OwnerId,
                unit.Position);
            if (commandCenter is not { } baseSnapshot)
            {
                results.Add(new UnitCommandResult(
                    unitId,
                    false,
                    CommandErrorCode.CommandCenterNotFound));
                continue;
            }

            var portResult = movement is IReturnToBaseMovementPort returnPort ?
                returnPort.RequestReturnToBase(unitId, baseSnapshot.UnitId) :
                // Keep old test/adapters source-compatible during the migration;
                // the concrete Godot adapter implements the semantic port above.
                movement.RequestMove(unitId, baseSnapshot.Position);
            if (!portResult.Accepted)
            {
                results.Add(new UnitCommandResult(unitId, false, Map(portResult.Error)));
                continue;
            }

            combatPolicies.SetEngagementStance(unitId, EngagementStance.ReturnToBase);
            var target = new UnitOrderEntityTarget(
                new BattlefieldEntityId(
                    baseSnapshot.EntityKind,
                    baseSnapshot.UnitId.Value),
                baseSnapshot.TypeId);
            var order = orders.Create(
                context.CommandId,
                unitId,
                UnitOrderKind.ReturnToBase,
                target);
            orders.Transition(order.OrderId, UnitOrderState.InProgress);
            results.Add(new UnitCommandResult(
                unitId,
                true,
                CommandErrorCode.None,
                order.OrderId));
        }
        return Summarize(context.CommandId, results);
    }

    /// <inheritdoc />
    public CommandResult SetFirePolicy(CommandContext context, SetFirePolicyCommand command)
    {
        if (command.UnitIds.Count == 0 || !Enum.IsDefined(command.Policy))
        {
            return Rejected(
                context.CommandId,
                command.UnitIds,
                command.UnitIds.Count == 0 ?
                    CommandErrorCode.EmptyUnitSet : CommandErrorCode.InvalidFirePolicy);
        }

        return SetCombatPolicy(
            context,
            command.UnitIds,
            unitId => combatPolicies.SetFirePolicy(unitId, command.Policy));
    }

    /// <inheritdoc />
    public CommandResult Attack(CommandContext context, AttackCommand command)
    {
        if (command.UnitIds.Count == 0)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.EmptyUnitSet);
        }

        var target = units.Find(command.Target.TargetUnitId);
        if (target is null)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.TargetNotFound);
        }
        if (!target.Value.IsDamageable)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.TargetNotDamageable);
        }

        var results = new List<UnitCommandResult>();
        foreach (var unitId in StableDistinct(command.UnitIds))
        {
            var validation = ValidateAttack(context, unitId, target.Value, false);
            if (validation != CommandErrorCode.None)
            {
                results.Add(new UnitCommandResult(unitId, false, validation));
                continue;
            }

            var portResult = attack.RequestEntityAttack(unitId, command.Target.TargetUnitId);
            if (!portResult.Accepted)
            {
                results.Add(new UnitCommandResult(unitId, false, Map(portResult.Error)));
                continue;
            }

            var order = orders.Create(
                context.CommandId,
                unitId,
                UnitOrderKind.Attack,
                EntityOrderTarget(target.Value));
            orders.Transition(order.OrderId, UnitOrderState.InProgress);
            results.Add(new UnitCommandResult(unitId, true, CommandErrorCode.None, order.OrderId));
        }
        return Summarize(context.CommandId, results);
    }

    /// <inheritdoc />
    public CommandResult ForceAttack(CommandContext context, ForceAttackCommand command)
    {
        if (command.UnitIds.Count == 0)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.EmptyUnitSet);
        }
        if (command.Target is GroundAttackTarget groundTarget)
        {
            if (!IsFinite(groundTarget.Position))
            {
                return Rejected(
                    context.CommandId,
                    command.UnitIds,
                    CommandErrorCode.InvalidAttackTarget);
            }

            return ExecuteGroundForceAttack(context, command.UnitIds, groundTarget.Position);
        }
        if (command.Target is not EntityAttackTarget entityTarget)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.InvalidAttackTarget);
        }

        var target = units.Find(entityTarget.TargetUnitId);
        if (target is null)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.TargetNotFound);
        }
        if (!target.Value.IsDamageable)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.TargetNotDamageable);
        }

        var results = new List<UnitCommandResult>();
        foreach (var unitId in StableDistinct(command.UnitIds))
        {
            var validation = ValidateAttack(context, unitId, target.Value, true);
            if (validation != CommandErrorCode.None)
            {
                results.Add(new UnitCommandResult(unitId, false, validation));
                continue;
            }

            var portResult = attack.RequestEntityForceAttack(unitId, entityTarget.TargetUnitId);
            if (!portResult.Accepted)
            {
                results.Add(new UnitCommandResult(unitId, false, Map(portResult.Error)));
                continue;
            }

            var order = orders.Create(
                context.CommandId,
                unitId,
                UnitOrderKind.ForceAttack,
                EntityOrderTarget(target.Value));
            orders.Transition(order.OrderId, UnitOrderState.InProgress);
            results.Add(new UnitCommandResult(unitId, true, CommandErrorCode.None, order.OrderId));
        }
        return Summarize(context.CommandId, results);
    }

    /// <inheritdoc />
    public CommandResult CancelForceAttack(
        CommandContext context,
        CancelForceAttackCommand command)
    {
        if (command.UnitIds.Count == 0)
        {
            return Rejected(context.CommandId, command.UnitIds, CommandErrorCode.EmptyUnitSet);
        }

        var results = new List<UnitCommandResult>();
        foreach (var unitId in StableDistinct(command.UnitIds))
        {
            var validation = ValidateOwnership(context, unitId);
            if (validation != CommandErrorCode.None)
            {
                results.Add(new UnitCommandResult(unitId, false, validation));
                continue;
            }

            var portResult = attack.RequestCancelForceAttack(unitId);
            if (!portResult.Accepted)
            {
                results.Add(new UnitCommandResult(unitId, false, Map(portResult.Error)));
                continue;
            }

            var active = orders.FindActive(unitId);
            if (active?.Kind is UnitOrderKind.ForceAttack or UnitOrderKind.GroundForceAttack)
            {
                orders.Transition(active.OrderId, UnitOrderState.Cancelled, context.CommandId);
            }
            results.Add(new UnitCommandResult(
                unitId,
                true,
                CommandErrorCode.None,
                active?.Kind is UnitOrderKind.ForceAttack or UnitOrderKind.GroundForceAttack ?
                    active.OrderId : null));
        }
        return Summarize(context.CommandId, results);
    }

    /// <summary>逐单位校验地面强制开火能力并创建持续地面攻击订单。</summary>
    private CommandResult ExecuteGroundForceAttack(
        CommandContext context,
        IReadOnlyList<UnitId> unitIds,
        WorldPosition position)
    {
        var results = new List<UnitCommandResult>();
        foreach (var unitId in StableDistinct(unitIds))
        {
            var ownership = ValidateOwnership(context, unitId);
            if (ownership != CommandErrorCode.None)
            {
                results.Add(new UnitCommandResult(unitId, false, ownership));
                continue;
            }

            var attacker = units.Find(unitId)!.Value;
            if (!attacker.CanAttack)
            {
                results.Add(new UnitCommandResult(
                    unitId,
                    false,
                    CommandErrorCode.UnitCannotAttack));
                continue;
            }
            if (!attacker.CanForceFireGround)
            {
                results.Add(new UnitCommandResult(
                    unitId,
                    false,
                    CommandErrorCode.WeaponCannotForceFire));
                continue;
            }

            var portResult = attack.RequestGroundForceAttack(unitId, position);
            if (!portResult.Accepted)
            {
                results.Add(new UnitCommandResult(unitId, false, Map(portResult.Error)));
                continue;
            }

            var order = orders.Create(
                context.CommandId,
                unitId,
                UnitOrderKind.GroundForceAttack,
                new UnitOrderPositionTarget(position));
            orders.Transition(order.OrderId, UnitOrderState.InProgress);
            results.Add(new UnitCommandResult(
                unitId,
                true,
                CommandErrorCode.None,
                order.OrderId));
        }

        return Summarize(context.CommandId, results);
    }

    /// <summary>逐单位校验所有权并修改彼此独立的持续战斗策略。</summary>
    private CommandResult SetCombatPolicy(
        CommandContext context,
        IReadOnlyList<UnitId> unitIds,
        Action<UnitId> update)
    {
        var results = new List<UnitCommandResult>();
        foreach (var unitId in StableDistinct(unitIds))
        {
            var validation = ValidateOwnership(context, unitId);
            if (validation != CommandErrorCode.None)
            {
                results.Add(new UnitCommandResult(unitId, false, validation));
                continue;
            }

            update(unitId);
            results.Add(new UnitCommandResult(unitId, true, CommandErrorCode.None));
        }
        return Summarize(context.CommandId, results);
    }

    /// <summary>逐单位校验并执行可独立接受的批量移动请求。</summary>
    private CommandResult ExecuteMove(
        CommandContext context,
        IReadOnlyList<UnitId> unitIds,
        UnitOrderKind orderKind,
        UnitOrderTarget target,
        Func<UnitId, MovementPortResult> execute) =>
        ExecuteMove(context, unitIds, orderKind, _ => target, execute);

    private CommandResult ExecuteMove(
        CommandContext context,
        IReadOnlyList<UnitId> unitIds,
        UnitOrderKind orderKind,
        Func<UnitId, UnitOrderTarget> targetFactory,
        Func<UnitId, MovementPortResult> execute)
    {
        var results = new List<UnitCommandResult>();
        foreach (var unitId in StableDistinct(unitIds))
        {
            var validation = Validate(context, unitId);
            if (validation != CommandErrorCode.None)
            {
                results.Add(new UnitCommandResult(unitId, false, validation));
                continue;
            }

            var portResult = execute(unitId);
            if (!portResult.Accepted)
            {
                results.Add(new UnitCommandResult(unitId, false, Map(portResult.Error)));
                continue;
            }
            var order = orders.Create(context.CommandId, unitId, orderKind, targetFactory(unitId));
            orders.Transition(order.OrderId, UnitOrderState.InProgress);
            results.Add(new UnitCommandResult(unitId, true, CommandErrorCode.None, order.OrderId));
        }
        return Summarize(context.CommandId, results);
    }

    /// <summary>同一批移动命令共用一个目标点时的阵位间距（米）；大于最大单位直径，保证环间可通行。</summary>
    private const float FormationSpacingMeters = 2.0f;

    /// <summary>
    /// 把一批单位共用的移动目标点散布成同心六边形环形阵位，避免大部队（人类或 AI 波次）挤向同一点。
    /// 首单位占据目标点本身，其余按环展开；基准角取编队质心指向目标的方向，让阵列迎着前进方向展开。
    /// </summary>
    private Dictionary<UnitId, WorldPosition> ComputeFormationDestinations(
        IReadOnlyList<UnitId> unitIds, WorldPosition destination)
    {
        var destinations = new Dictionary<UnitId, WorldPosition>();
        var distinctUnits = StableDistinct(unitIds).ToList();
        if (distinctUnits.Count <= 1)
        {
            foreach (var unitId in distinctUnits)
            {
                destinations[unitId] = destination;
            }
            return destinations;
        }

        var baseAngle = ComputeFormationBaseAngle(distinctUnits, destination);
        for (var index = 0; index < distinctUnits.Count; index++)
        {
            destinations[distinctUnits[index]] = GetFormationSlotPosition(destination, index, baseAngle);
        }
        return destinations;
    }

    /// <summary>编队质心指向目标点的平面角；单位查询失败或距离过近则退回 0。</summary>
    private float ComputeFormationBaseAngle(IReadOnlyList<UnitId> unitIds, WorldPosition destination)
    {
        var sumX = 0.0f;
        var sumZ = 0.0f;
        var count = 0;
        foreach (var unitId in unitIds)
        {
            if (units.Find(unitId) is not { } snapshot)
            {
                continue;
            }
            sumX += snapshot.Position.X;
            sumZ += snapshot.Position.Z;
            count++;
        }
        if (count == 0)
        {
            return 0.0f;
        }

        var dx = destination.X - sumX / count;
        var dz = destination.Z - sumZ / count;
        if (dx * dx + dz * dz < 1e-4f)
        {
            return 0.0f;
        }
        return MathF.Atan2(dz, dx);
    }

    /// <summary>第 slotIndex 个阵位：0 号在目标点，之后按 1环6席、2环12席……展开，隔环错开半格。</summary>
    private static WorldPosition GetFormationSlotPosition(WorldPosition destination, int slotIndex, float baseAngle)
    {
        if (slotIndex == 0)
        {
            return destination;
        }

        var remaining = slotIndex - 1;
        var ring = 1;
        while (remaining >= ring * 6)
        {
            remaining -= ring * 6;
            ring++;
        }
        var slotsInRing = ring * 6;
        var radius = ring * FormationSpacingMeters;
        var slotAngle = baseAngle
            + remaining * (MathF.PI * 2f / slotsInRing)
            + (ring - 1) * (MathF.PI / 6f);
        return new WorldPosition(
            destination.X + MathF.Cos(slotAngle) * radius,
            destination.Y,
            destination.Z + MathF.Sin(slotAngle) * radius);
    }

    /// <summary>逐单位校验实体移动能力与自目标，并创建保留实体身份的订单。</summary>
    private CommandResult ExecuteEntityMovement(
        CommandContext context,
        IReadOnlyList<UnitId> unitIds,
        UnitOrderKind orderKind,
        UnitOrderEntityTarget target,
        Func<UnitId, MovementPortResult> execute)
    {
        var results = new List<UnitCommandResult>();
        foreach (var unitId in StableDistinct(unitIds))
        {
            var validation = Validate(context, unitId);
            if (validation == CommandErrorCode.None &&
                target.EntityId.Kind is BattlefieldEntityKind.Unit or BattlefieldEntityKind.Structure &&
                target.EntityId.Value == unitId.Value)
            {
                validation = CommandErrorCode.InvalidMovementTarget;
            }
            if (validation != CommandErrorCode.None)
            {
                results.Add(new UnitCommandResult(unitId, false, validation));
                continue;
            }

            var portResult = execute(unitId);
            if (!portResult.Accepted)
            {
                results.Add(new UnitCommandResult(unitId, false, Map(portResult.Error)));
                continue;
            }

            var order = orders.Create(context.CommandId, unitId, orderKind, target);
            orders.Transition(order.OrderId, UnitOrderState.InProgress);
            results.Add(new UnitCommandResult(
                unitId,
                true,
                CommandErrorCode.None,
                order.OrderId));
        }
        return Summarize(context.CommandId, results);
    }

    /// <summary>解析靠近命令允许的单位、建筑或资源目标，并保留稳定类型。</summary>
    private UnitOrderEntityTarget? FindApproachTarget(BattlefieldEntityId targetEntityId)
    {
        if (targetEntityId.Kind == BattlefieldEntityKind.ResourceNode)
        {
            var resource = resourceNodes?.Find(new ResourceNodeId(targetEntityId.Value));
            return resource is null ? null : new UnitOrderEntityTarget(
                targetEntityId,
                ResourceTypeId(resource.Value.Kind));
        }

        var target = units.Find(new UnitId(targetEntityId.Value));
        if (target is null || target.Value.EntityKind != targetEntityId.Kind)
        {
            return null;
        }
        return EntityOrderTarget(target.Value);
    }

    /// <summary>校验单位是否存在、属于命令发出者且具备移动能力。</summary>
    private CommandErrorCode Validate(CommandContext context, UnitId unitId)
    {
        var ownership = ValidateOwnership(context, unitId);
        if (ownership != CommandErrorCode.None)
        {
            return ownership;
        }

        return units.Find(unitId)!.Value.CanMove ?
            CommandErrorCode.None : CommandErrorCode.UnitCannotMove;
    }

    /// <summary>校验单位是否存在并属于命令发出者，不附加移动或攻击能力要求。</summary>
    private CommandErrorCode ValidateOwnership(CommandContext context, UnitId unitId)
    {
        var unit = units.Find(unitId);
        if (unit is null)
        {
            return CommandErrorCode.UnitNotFound;
        }
        return unit.Value.OwnerId == context.IssuerPlayerId ?
            CommandErrorCode.None : CommandErrorCode.UnitNotOwned;
    }

    /// <summary>校验实体攻击的所有权、敌我关系、停火策略、武器能力和目标域。</summary>
    private CommandErrorCode ValidateAttack(
        CommandContext context,
        UnitId unitId,
        UnitCommandSnapshot target,
        bool isForceAttack)
    {
        var ownership = ValidateOwnership(context, unitId);
        if (ownership != CommandErrorCode.None)
        {
            return ownership;
        }

        var attacker = units.Find(unitId)!.Value;
        if (!isForceAttack && attacker.OwnerId == target.OwnerId)
        {
            return CommandErrorCode.InvalidAttackTarget;
        }
        if (!isForceAttack && combatPolicies.Get(unitId).FirePolicy == FirePolicy.HoldFire)
        {
            return CommandErrorCode.FirePolicyPreventsAttack;
        }
        if (!attacker.CanAttack)
        {
            return CommandErrorCode.UnitCannotAttack;
        }
        return attacker.AttackDomains?.Contains(target.Domain) == true ?
            CommandErrorCode.None : CommandErrorCode.WeaponCannotTargetDomain;
    }

    /// <summary>校验实体移动攻击的所有权、移动与攻击能力、敌我关系及目标域；停火仅抑制开火，不拒绝推进。</summary>
    private CommandErrorCode ValidateAttackMove(
        CommandContext context,
        UnitId unitId,
        UnitCommandSnapshot target)
    {
        var ownership = ValidateOwnership(context, unitId);
        if (ownership != CommandErrorCode.None)
        {
            return ownership;
        }

        var attacker = units.Find(unitId)!.Value;
        if (attacker.OwnerId == target.OwnerId)
        {
            return CommandErrorCode.InvalidAttackTarget;
        }
        if (!attacker.CanMove)
        {
            return CommandErrorCode.UnitCannotMove;
        }
        if (!attacker.CanAttack)
        {
            return CommandErrorCode.UnitCannotAttack;
        }
        return attacker.AttackDomains?.Contains(target.Domain) == true ?
            CommandErrorCode.None : CommandErrorCode.WeaponCannotTargetDomain;
    }

    private static IReadOnlyList<UnitId> StableDistinct(IEnumerable<UnitId> ids) =>
        ids.Distinct().OrderBy(id => id.Value).ToArray();

    /// <summary>把命令仓库中的目标快照转换为不依赖运行时对象的订单目标意图。</summary>
    private static UnitOrderEntityTarget EntityOrderTarget(UnitCommandSnapshot target) => new(
        new BattlefieldEntityId(target.EntityKind, target.UnitId.Value),
        target.TypeId);

    private static bool IsFinite(WorldPosition value) =>
        float.IsFinite(value.X) && float.IsFinite(value.Y) && float.IsFinite(value.Z);

    private static CommandErrorCode Map(MovementPortError error) => error switch
    {
        MovementPortError.NavigationUnavailable => CommandErrorCode.NavigationUnavailable,
        _ => CommandErrorCode.UnitNotFound
    };

    private static CommandErrorCode Map(AttackPortError error) => error switch
    {
        AttackPortError.AttackUnavailable => CommandErrorCode.AttackUnavailable,
        _ => CommandErrorCode.UnitNotFound
    };

    /// <summary>把统一停止端口错误转换为不泄漏执行层细节的稳定命令错误。</summary>
    private static CommandErrorCode Map(StopPortError error) => error switch
    {
        StopPortError.UnitUnavailable => CommandErrorCode.UnitNotFound,
        StopPortError.StopUnavailable => CommandErrorCode.UnitCannotStop,
        _ => CommandErrorCode.UnitCannotStop
    };

    /// <summary>把 Worker 工作端口错误转换为稳定命令错误。</summary>
    private static CommandErrorCode Map(WorkerTaskPortError error) => error switch
    {
        WorkerTaskPortError.UnitUnavailable => CommandErrorCode.UnitNotFound,
        WorkerTaskPortError.TargetUnavailable => CommandErrorCode.ResourceTargetNotFound,
        _ => CommandErrorCode.WorkUnavailable
    };

    /// <summary>把施工执行端口错误转换为稳定命令错误。</summary>
    private static CommandErrorCode Map(ConstructionWorkerPortError error) => error switch
    {
        ConstructionWorkerPortError.EntityUnavailable => CommandErrorCode.UnitNotFound,
        _ => CommandErrorCode.ConstructionUnavailable
    };

    private static CommandResult Rejected(
        CommandId commandId, IReadOnlyList<UnitId> unitIds, CommandErrorCode error) =>
        new(commandId, CommandStatus.Rejected,
            StableDistinct(unitIds).Select(id => new UnitCommandResult(id, false, error)).ToArray());

    /// <summary>根据逐单位结果计算批量命令的 Accepted、PartiallyAccepted 或 Rejected 状态。</summary>
    private static CommandResult Summarize(CommandId commandId, IReadOnlyList<UnitCommandResult> results)
    {
        var accepted = results.Count(result => result.Accepted);
        var status = accepted == 0 ? CommandStatus.Rejected :
            accepted == results.Count ? CommandStatus.Accepted : CommandStatus.PartiallyAccepted;
        return new CommandResult(commandId, status, results);
    }

    private SkillRuntime Skill => _skillRuntime ??= CreateSkillRuntime(
        units, _catalog, damage, warheads, moveSpeed, this, _objectSpawn);

    /// <inheritdoc />
    void ISkillWorldActionPort.IssueMove(UnitId unitId, WorldPosition destination)
    {
        var snapshot = units.Find(unitId);
        if (snapshot is null)
        {
            return;
        }

        Move(
            new CommandContext(
                new CommandId(Guid.NewGuid()),
                _lastMatchId,
                snapshot.Value.OwnerId,
                0),
            new MoveUnitsCommand([unitId], destination));
    }

    /// <inheritdoc />
    void ISkillWorldActionPort.IssueAttack(UnitId attackerId, UnitId targetId)
    {
        var snapshot = units.Find(attackerId);
        if (snapshot is null)
        {
            return;
        }

        Attack(
            new CommandContext(
                new CommandId(Guid.NewGuid()),
                _lastMatchId,
                snapshot.Value.OwnerId,
                0),
            new AttackCommand([attackerId], new EntityAttackTarget(targetId)));
    }

    /// <inheritdoc />
    void ISkillWorldActionPort.EmitBattlefieldEvent(
        BattlefieldEventKind kind,
        WorldPosition position,
        bool isImportant) =>
        _battlefieldEvents?.Record(kind, position, isImportant);

    private static SkillRuntime CreateSkillRuntime(
        IUnitCommandUnitRepository units,
        IGameBalanceCatalog? catalog,
        IUnitDamagePort? damage,
        IWarheadDamageResolver? warheads,
        IUnitMoveSpeedPort? moveSpeed,
        ISkillWorldActionPort worldActions,
        ISkillObjectSpawnPort? objectSpawn)
    {
        var statuses = new SkillStatusService(moveSpeed);
        return new SkillRuntime(
            statuses,
            new SkillEffectTimeline(
                new SkillInstantEffectExecutor(
                    units,
                    warheads ?? new WarheadDamageResolver(),
                    damage,
                    catalog,
                    statuses,
                    worldActions,
                    objectSpawn)));
    }

    private sealed record SkillRuntime(
        ISkillStatusService Statuses,
        ISkillEffectTimeline Timeline);

    private sealed record PendingSkillActivation(
        UnitId CasterId,
        SkillDefinition Skill,
        UnitId? TargetUnitId,
        WorldPosition? TargetPosition,
        long ActivateAtMilliseconds,
        MatchId MatchId,
        PlayerId OwnerId,
        CommandId CommandId);
}
