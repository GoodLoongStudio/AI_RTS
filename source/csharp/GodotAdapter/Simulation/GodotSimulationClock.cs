using Godot;

namespace AI_RTS.GodotAdapter.Simulation;

/// <summary>读取 Match 上只在未暂停时推进的模拟毫秒。</summary>
public sealed class GodotSimulationClock(Node clock)
{
    /// <summary>返回当前模拟毫秒；暂停期间保持不变。</summary>
    public long GetMilliseconds() => clock.Call("get_msec").AsInt64();
}
