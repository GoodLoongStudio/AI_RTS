using AI_RTS.Domain.Common;
using AI_RTS.Domain.Combat;

namespace AI_RTS.Application.Units;

/// <summary>提供命令校验所需的最小单位只读信息。</summary>
public readonly record struct UnitCommandSnapshot(
    UnitId UnitId,
    PlayerId OwnerId,
    bool CanMove,
    bool CanAttack = false,
    CombatDomain Domain = CombatDomain.Terrain,
    IReadOnlySet<CombatDomain>? AttackDomains = null,
    bool IsDamageable = true,
    bool CanReverse = false,
    bool CanForceFireGround = false);

/// <summary>为命令服务提供不依赖 Godot Node 的单位查询。</summary>
public interface IUnitCommandUnitRepository
{
    /// <summary>按稳定 ID 查询命令校验快照。</summary>
    UnitCommandSnapshot? Find(UnitId unitId);
}

/// <summary>表示移动端口调用失败的稳定原因。</summary>
public enum MovementPortError
{
    /// <summary>没有错误。</summary>
    None,
    /// <summary>单位对应的运行时对象已经不可用。</summary>
    UnitUnavailable,
    /// <summary>单位缺少导航能力或导航服务尚不可用。</summary>
    NavigationUnavailable
}

/// <summary>表示导航适配端口是否接受一次请求。</summary>
public readonly record struct MovementPortResult(bool Accepted, MovementPortError Error)
{
    /// <summary>创建成功的移动端口结果。</summary>
    public static MovementPortResult Success() => new(true, MovementPortError.None);

    /// <summary>使用指定错误原因创建失败的移动端口结果。</summary>
    public static MovementPortResult Failure(MovementPortError error) => new(false, error);
}

/// <summary>隔离 Application 命令逻辑与具体导航引擎。</summary>
public interface IUnitMovementPort
{
    /// <summary>向单位提交移动到世界坐标的请求。</summary>
    MovementPortResult RequestMove(UnitId unitId, WorldPosition destination);

    /// <summary>请求单位向地面位置移动并按权威交战策略处理中途敌人。</summary>
    MovementPortResult RequestGroundAttackMove(UnitId unitId, WorldPosition destination);

    /// <summary>请求单位追踪敌方实体推进，并按权威交战策略处理途中敌人。</summary>
    MovementPortResult RequestEntityAttackMove(UnitId unitId, UnitId targetId);

    /// <summary>请求单位沿导航路径倒车撤退；车体朝向由实时路径切线决定。</summary>
    MovementPortResult RequestTacticalWithdraw(UnitId unitId, WorldPosition destination);

    /// <summary>请求单位停止当前位移。</summary>
    MovementPortResult RequestHalt(UnitId unitId);
}

/// <summary>表示统一停止执行端拒绝请求的稳定原因。</summary>
public enum StopPortError
{
    /// <summary>没有错误。</summary>
    None,

    /// <summary>单位对应的运行时对象已经不可用。</summary>
    UnitUnavailable,

    /// <summary>单位执行端尚未提供统一停止能力。</summary>
    StopUnavailable
}

/// <summary>表示统一停止执行端是否接受一次请求。</summary>
public readonly record struct StopPortResult(bool Accepted, StopPortError Error)
{
    /// <summary>创建成功的统一停止结果。</summary>
    public static StopPortResult Success() => new(true, StopPortError.None);

    /// <summary>使用指定错误原因创建失败的统一停止结果。</summary>
    public static StopPortResult Failure(StopPortError error) => new(false, error);
}

/// <summary>隔离 Application 的统一 Stop 语义与单位内部任务实现。</summary>
public interface IUnitStopPort
{
    /// <summary>暂停可保留任务并取消显式强制攻击；普通攻击与持续战斗策略保持不变。</summary>
    StopPortResult RequestStop(UnitId unitId);
}

/// <summary>表示显式攻击端口拒绝请求的稳定原因。</summary>
public enum AttackPortError
{
    /// <summary>没有错误。</summary>
    None,

    /// <summary>攻击者或目标对应的运行时对象已经不可用。</summary>
    UnitUnavailable,

    /// <summary>迁移期攻击执行层暂时无法接收请求。</summary>
    AttackUnavailable
}

/// <summary>表示显式攻击适配端口是否接受一次请求。</summary>
public readonly record struct AttackPortResult(bool Accepted, AttackPortError Error)
{
    /// <summary>创建成功的攻击端口结果。</summary>
    public static AttackPortResult Success() => new(true, AttackPortError.None);

    /// <summary>使用指定错误原因创建失败的攻击端口结果。</summary>
    public static AttackPortResult Failure(AttackPortError error) => new(false, error);
}

/// <summary>隔离 Application ForceAttack 逻辑与 Legacy Godot Action。</summary>
public interface IUnitAttackPort
{
    /// <summary>请求攻击者普通攻击指定敌方实体。</summary>
    AttackPortResult RequestEntityAttack(UnitId attackerId, UnitId targetId);

    /// <summary>请求攻击者持续强制攻击指定实体目标。</summary>
    AttackPortResult RequestEntityForceAttack(UnitId attackerId, UnitId targetId);

    /// <summary>请求攻击者持续强制攻击纯地面坐标。</summary>
    AttackPortResult RequestGroundForceAttack(UnitId attackerId, WorldPosition position);

    /// <summary>取消单位当前显式 ForceAttack；没有显式攻击时作为幂等无操作接受。</summary>
    AttackPortResult RequestCancelForceAttack(UnitId unitId);
}
