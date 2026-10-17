using System.Diagnostics;
using Godot;

namespace AI_RTS.GodotAdapter.Queries;

/// <summary>
/// 性能插桩计数器（2026-10-11 整晚对局优化阶段一，测量专用）。
/// 仅当环境变量 AIRTS_AI_PERF_STATS=1 时记录；默认零开销（Enabled=false 时直接返回）。
/// 全部调用发生在主线程（Godot 查询/命令/GDScript 控制器均主线程），不加锁。
/// </summary>
public static class QueryPerfCounters
{
    private static bool _enabled;
    private static bool _initialized;
    private static long _captureCalls;
    private static long _captureMisses;
    private static long _CaptureTicks;
    private static long _captureMaxTicks;
    private static long _captureEntities;
    private static readonly Dictionary<string, long[]> CapturePhases = new();
    private static long _placementCalls;
    private static long _placementTicks;
    private static long _placementMaxTicks;
    private static long _placementFound;
    private static long _evaluateOneCalls;
    private static long _evaluateOneTicks;
    private static long _evaluateOneMaxTicks;
    private static int _hitchPrints;

    private static readonly Dictionary<string, long[]> Queries = new();
    private static readonly Dictionary<string, long[]> Commands = new();
    private static readonly Dictionary<string, long[]> PlacementPhases = new();

    /// <summary>查询/命令/选址插桩总开关（运行期只读一次环境变量）。</summary>
    public static bool Enabled
    {
        get
        {
            if (!_initialized)
            {
                _enabled = OS.GetEnvironment("AIRTS_AI_PERF_STATS") == "1";
                _initialized = true;
            }
            return _enabled;
        }
    }

    /// <summary>记录一次 CaptureShared 调用（miss=true 表示真的重建了快照）。</summary>
    public static void AddCapture(long ticks, bool miss, long entities)
    {
        if (!Enabled)
        {
            return;
        }
        _captureCalls++;
        _CaptureTicks += ticks;
        _captureEntities += entities;
        if (ticks > _captureMaxTicks)
        {
            _captureMaxTicks = ticks;
        }
        if (miss)
        {
            _captureMisses++;
        }
    }

    /// <summary>记录一次快照重建的内部阶段。各阶段互斥，不能与 capture total 再相加。</summary>
    public static void AddCapturePhase(string phase, long ticks)
    {
        if (!Enabled)
        {
            return;
        }
        if (!CapturePhases.TryGetValue(phase, out var slot))
        {
            slot = new long[3];
            CapturePhases[phase] = slot;
        }
        slot[0]++;
        slot[1] += ticks;
        if (ticks > slot[2])
        {
            slot[2] = ticks;
        }
    }

    /// <summary>记录一次查询 API 调用（_api 如 GetOwnForces/ScanCircle；_fromRuleAi 标识来源会话）。</summary>
    public static void AddQuery(string api, long ticks, long entities, bool fromRuleAi)
    {
        if (!Enabled)
        {
            return;
        }
        if (!Queries.TryGetValue(api, out var slot))
        {
            slot = new long[5];
            Queries[api] = slot;
        }
        slot[0]++;
        slot[1] += ticks;
        slot[2] += entities;
        if (fromRuleAi)
        {
            slot[3]++;
            slot[4] += ticks;
        }
    }

    /// <summary>记录一次规则 AI 命令网关调用。</summary>
    public static void AddCommand(string kind, long ticks)
    {
        if (!Enabled)
        {
            return;
        }
        if (!Commands.TryGetValue(kind, out var slot))
        {
            slot = new long[2];
            Commands[kind] = slot;
        }
        slot[0]++;
        slot[1] += ticks;
    }

    /// <summary>记录一次 FindAutoSpot 选址探测。total 含其下各 phase，不能与 phase 相加。</summary>
    public static void AddPlacement(long ticks, bool found)
    {
        if (!Enabled)
        {
            return;
        }
        _placementCalls++;
        _placementTicks += ticks;
        if (ticks > _placementMaxTicks)
        {
            _placementMaxTicks = ticks;
        }
        if (found)
        {
            _placementFound++;
        }
        NoteHitch("placement", ticks);
    }

    /// <summary>
    /// 记录 FindAutoSpot 的一个内部阶段。阶段之间互斥；它们的和约等于 placement total，
    /// 但不能再与 placement total 相加。
    /// </summary>
    public static void AddPlacementPhase(string phase, long ticks)
    {
        if (!Enabled)
        {
            return;
        }
        if (!PlacementPhases.TryGetValue(phase, out var slot))
        {
            slot = new long[3];
            PlacementPhases[phase] = slot;
        }
        slot[0]++;
        slot[1] += ticks;
        if (ticks > slot[2])
        {
            slot[2] = ticks;
        }
    }

    /// <summary>记录单次 StructurePlacement.Evaluate。与 placement.evaluate 阶段重叠，不能相加。</summary>
    public static void NoteEvaluateOne(long ticks)
    {
        if (!Enabled)
        {
            return;
        }
        _evaluateOneCalls++;
        _evaluateOneTicks += ticks;
        if (ticks > _evaluateOneMaxTicks)
        {
            _evaluateOneMaxTicks = ticks;
        }
        NoteHitch("placement.evaluate_one", ticks);
    }

    private static void NoteHitch(string bucket, long ticks)
    {
        var microseconds = TicksToMicroseconds(ticks);
        if (microseconds < 100_000.0 || _hitchPrints >= 32)
        {
            return;
        }
        _hitchPrints++;
        GD.Print($"[AI-PERF] hitch bucket={bucket} us={microseconds:F0}");
    }

    private static double TicksToMicroseconds(long ticks) =>
        ticks * 1000000.0 / Stopwatch.Frequency;

    private static double TicksToMicroseconds(long ticks, long calls) =>
        calls == 0 ? 0.0 : TicksToMicroseconds(ticks) / calls;

    /// <summary>导出当前累计值（微秒/次数），供探针写入 JSON。</summary>
    public static Godot.Collections.Dictionary Dump()
    {
        var queries = new Godot.Collections.Dictionary();
        foreach (var pair in Queries)
        {
            queries[pair.Key] = new Godot.Collections.Dictionary
            {
                ["calls"] = pair.Value[0],
                ["total_us"] = Mathf.Round(TicksToMicroseconds(pair.Value[1])),
                ["per_call_us"] = Mathf.Round(TicksToMicroseconds(pair.Value[1], pair.Value[0])),
                ["entities"] = pair.Value[2],
                ["rule_ai_calls"] = pair.Value[3],
                ["rule_ai_total_us"] = Mathf.Round(TicksToMicroseconds(pair.Value[4])),
            };
        }
        var commands = new Godot.Collections.Dictionary();
        foreach (var pair in Commands)
        {
            commands[pair.Key] = new Godot.Collections.Dictionary
            {
                ["calls"] = pair.Value[0],
                ["total_us"] = Mathf.Round(TicksToMicroseconds(pair.Value[1])),
                ["per_call_us"] = Mathf.Round(TicksToMicroseconds(pair.Value[1], pair.Value[0])),
            };
        }
        return new Godot.Collections.Dictionary
        {
            ["enabled"] = Enabled,
            ["capture"] = new Godot.Collections.Dictionary
            {
                ["calls"] = _captureCalls,
                ["misses"] = _captureMisses,
                ["capture_total_us"] = Mathf.Round(TicksToMicroseconds(_CaptureTicks)),
                ["capture_max_us"] = Mathf.Round(TicksToMicroseconds(_captureMaxTicks)),
                ["capture_entities"] = _captureEntities,
                ["phases"] = DumpNamedPhases(CapturePhases),
            },
            ["queries"] = queries,
            ["commands"] = commands,
            ["placement"] = new Godot.Collections.Dictionary
            {
                ["calls"] = _placementCalls,
                ["found"] = _placementFound,
                ["total_us"] = Mathf.Round(TicksToMicroseconds(_placementTicks)),
                ["per_call_us"] = Mathf.Round(TicksToMicroseconds(_placementTicks, _placementCalls)),
                ["max_us"] = Mathf.Round(TicksToMicroseconds(_placementMaxTicks)),
                ["inclusive"] = "phases are children of placement; evaluate_one is inside the evaluate phase",
                ["phases"] = DumpPhases(),
                ["evaluate_one"] = new Godot.Collections.Dictionary
                {
                    ["calls"] = _evaluateOneCalls,
                    ["total_us"] = Mathf.Round(TicksToMicroseconds(_evaluateOneTicks)),
                    ["per_call_us"] = Mathf.Round(TicksToMicroseconds(_evaluateOneTicks, _evaluateOneCalls)),
                    ["max_us"] = Mathf.Round(TicksToMicroseconds(_evaluateOneMaxTicks)),
                },
            },
        };
    }

    private static Godot.Collections.Dictionary DumpPhases() => DumpNamedPhases(PlacementPhases);

    private static Godot.Collections.Dictionary DumpNamedPhases(Dictionary<string, long[]> source)
    {
        var phases = new Godot.Collections.Dictionary();
        foreach (var pair in source)
        {
            phases[pair.Key] = new Godot.Collections.Dictionary
            {
                ["calls"] = pair.Value[0],
                ["total_us"] = Mathf.Round(TicksToMicroseconds(pair.Value[1])),
                ["per_call_us"] = Mathf.Round(TicksToMicroseconds(pair.Value[1], pair.Value[0])),
                ["max_us"] = Mathf.Round(TicksToMicroseconds(pair.Value[2])),
            };
        }
        return phases;
    }

    /// <summary>清零（探针分段统计用）。</summary>
    public static void Reset()
    {
        _captureCalls = 0;
        _captureMisses = 0;
        _CaptureTicks = 0;
        _captureMaxTicks = 0;
        _captureEntities = 0;
        _placementCalls = 0;
        _placementTicks = 0;
        _placementMaxTicks = 0;
        _placementFound = 0;
        _evaluateOneCalls = 0;
        _evaluateOneTicks = 0;
        _evaluateOneMaxTicks = 0;
        _hitchPrints = 0;
        Queries.Clear();
        Commands.Clear();
        PlacementPhases.Clear();
        CapturePhases.Clear();
    }
}
