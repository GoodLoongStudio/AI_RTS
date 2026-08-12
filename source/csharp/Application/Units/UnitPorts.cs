using AI_RTS.Domain.Common;

namespace AI_RTS.Application.Units;

/// <summary>提供命令校验所需的最小单位只读信息。</summary>
public readonly record struct UnitCommandSnapshot(UnitId UnitId, PlayerId OwnerId, bool CanMove);

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

    /// <summary>请求单位停止当前位移。</summary>
    MovementPortResult RequestHalt(UnitId unitId);
}
