using Godot;

namespace AI_RTS.Tests.Automated;

/// <summary>在 Godot 无头测试退出前显式完成托管 Variant 终结器，避免原生运行时先行卸载。</summary>
public partial class ManagedGcTestHook : RefCounted
{
    /// <summary>回收已失去引用的托管包装并等待终结器完成；只允许测试退出阶段调用。</summary>
    public void CollectPendingFinalizers()
    {
        GC.Collect();
        GC.WaitForPendingFinalizers();
        GC.Collect();
    }
}
