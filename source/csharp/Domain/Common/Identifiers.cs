namespace AI_RTS.Domain.Common;

/// <summary>标识一场对局。</summary>
/// <param name="Value">进程内唯一的 Guid 值。</param>
public readonly record struct MatchId(Guid Value);

/// <summary>标识拥有单位与资源的玩家。</summary>
/// <param name="Value">进程内唯一的 Guid 值。</param>
public readonly record struct PlayerId(Guid Value);

/// <summary>标识一个可被命令或查询引用的单位。</summary>
/// <param name="Value">进程内唯一的 Guid 值。</param>
public readonly record struct UnitId(Guid Value);

/// <summary>标识一种跨对局稳定的战场实体类型，包含移动单位和建筑。</summary>
/// <param name="Value">项目配置内唯一的 snake_case 类型键。</param>
public readonly record struct UnitTypeId(string Value);

/// <summary>标识一个可被采集命令引用的资源节点。</summary>
/// <param name="Value">当前对局内唯一的 Guid 值。</param>
public readonly record struct ResourceNodeId(Guid Value);

/// <summary>标识一笔资源交易，用于幂等处理和审计。</summary>
/// <param name="Value">当前对局内唯一的 Guid 值。</param>
public readonly record struct ResourceTransactionId(Guid Value);

/// <summary>标识一次批量命令调用。</summary>
/// <param name="Value">进程内唯一的 Guid 值。</param>
public readonly record struct CommandId(Guid Value);

/// <summary>标识一个单位独立执行的订单。</summary>
/// <param name="Value">进程内唯一的 Guid 值。</param>
public readonly record struct UnitOrderId(Guid Value);

/// <summary>标识一次已经离开发射者、拥有独立生命周期的攻击实例。</summary>
/// <param name="Value">进程内唯一的 Guid 值。</param>
public readonly record struct AttackInstanceId(Guid Value);

/// <summary>标识一个不依赖 Godot 场景路径的建筑定义。</summary>
/// <param name="Value">项目内稳定且非空的定义键。</param>
public readonly record struct StructureDefinitionId(string Value);

/// <summary>标识一个可被单位装配引用的稳定武器定义。</summary>
/// <param name="Value">项目配置内唯一的 snake_case 武器键。</param>
public readonly record struct WeaponDefinitionId(string Value);

/// <summary>标识一个决定命中范围与友伤倍率的稳定弹头定义。</summary>
/// <param name="Value">项目配置内唯一的 snake_case 弹头键。</param>
public readonly record struct WarheadDefinitionId(string Value);
