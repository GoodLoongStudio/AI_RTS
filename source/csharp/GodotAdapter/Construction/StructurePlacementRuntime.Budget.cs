using System.Diagnostics;
using System.Linq;
using AI_RTS.Application.Construction;
using AI_RTS.Domain.Construction;
using AI_RTS.GodotAdapter.Common;
using AI_RTS.GodotAdapter.Queries;
using Godot;

namespace AI_RTS.GodotAdapter.Construction;

public partial class StructurePlacementRuntime
{
    private const int SharedSliceBudgetUs = 1500;
    private const int SearchDeadlineUs = 5_000_000;
    private const int MaxSearchRestarts = 8;

    private static long _sliceFrame = -1;
    private static long _sliceRemaining;

    private readonly Dictionary<ulong, RuleSpotJob> _ruleSpotJobs = new();
    private readonly Dictionary<ulong, Dictionary<string, int>> _ruleSpotMisses = new();

    private sealed class RankCursor
    {
        public bool Snapshotted;
        /// <summary>0 尚未取单位，1 投影己方建筑，2 投影矿点，3 通道与近邻，4 已完成。</summary>
        public int GatherPhase;
        public int GatherIndex;
        public Node3D[]? SourceUnits;
        public Node3D[]? SourceResources;
        public List<(Vector3 Position, float Radius, string Type, bool Production, Vector3 Facing)>? GatherOwn;
        public List<Vector3>? GatherResourcePositions;
        public List<(Vector3 Start, Vector3 End)>? RouteList;
        public (Vector3 Position, float Radius, string Type, bool Production, Vector3 Facing)[] Own = [];
        public (Vector3 Position, float Radius, string Type, bool Production, Vector3 Facing)[] Ordered = [];
        public Vector3[] Resources = [];
        public (Vector3 Start, Vector3 End)[] Routes = [];
        public float[] Gaps = [];
        public List<(Vector3 Position, float Score)> Candidates = new();
        public HashSet<(int, int)> Keys = new();
        public int Attempts;
        public int GapIndex;
        public int OwnIndex;
        public int GapStep;
        public int Ring;
        public int Step;
    }

    private sealed class RuleSpotJob
    {
        public string Key = "";
        public int Generation;
        public int Restarts;
        public long StartedTicks;
        public bool Ready;
        public List<Vector3> Ranked = new();
        public RankCursor? Cursor;
        public int Index;
        public float Radius;
        public Vector3 Anchor;
        public float Limit;
        public string Mode = "";
        public Vector3? HeldSpot;
        public Dictionary<StructurePlacementIssue, int> IssueMix = new();
    }

    /// <summary>
    /// 规则 AI 用的可续选址。pending=true 表示本帧预算用完，不是无地可建。
    /// 所有规则 AI 共用每帧约 1.5ms。同步 FindAutoSpot 不走这里。
    /// </summary>
    public Godot.Collections.Dictionary FindAutoSpotBudgeted(
        Node player,
        PackedScene prototype,
        string mode,
        Vector3 hint,
        float maxRadiusMeters,
        int budgetUs)
    {
        var grant = GrantSlice(budgetUs);
        if (grant <= 0)
        {
            return PendingSpot();
        }
        var started = Stopwatch.GetTimestamp();
        var deadline = started + grant;
        var found = false;
        try
        {
            var reply = StepBudgeted(player, prototype, mode, hint, maxRadiusMeters, deadline);
            found = reply.GetValueOrDefault("found").AsBool();
            return reply;
        }
        finally
        {
            var elapsed = Stopwatch.GetTimestamp() - started;
            _sliceRemaining -= elapsed;
            if (_sliceRemaining < 0)
            {
                _sliceRemaining = 0;
            }
            if (QueryPerfCounters.Enabled)
            {
                QueryPerfCounters.AddPlacement(elapsed, found);
            }
        }
    }

    private static long GrantSlice(int requestedUs)
    {
        var frame = (long)Engine.GetProcessFrames();
        if (frame != _sliceFrame)
        {
            _sliceFrame = frame;
            _sliceRemaining = TicksFromUs(SharedSliceBudgetUs);
        }
        if (_sliceRemaining <= 0 || requestedUs <= 0)
        {
            return 0;
        }
        return Math.Min(_sliceRemaining, TicksFromUs(requestedUs));
    }

    private static long TicksFromUs(int microseconds) =>
        microseconds * Stopwatch.Frequency / 1_000_000L;

    private Godot.Collections.Dictionary StepBudgeted(
        Node player,
        PackedScene prototype,
        string mode,
        Vector3 hint,
        float maxRadiusMeters,
        long deadline)
    {
        var stepStarted = QueryPerfCounters.Enabled ? Stopwatch.GetTimestamp() : 0L;
        if (!GodotObject.IsInstanceValid(player))
        {
            return AutoSpotResult(false, Vector3.Zero, StructurePlacementIssue.ValidationUnavailable.ToString());
        }
        var construction = EnsureDefinition(prototype);
        var definitionId = construction.DefinitionId;
        var playerId = GodotStableIdentity.Player(player);
        _world.RegisterPlayer(playerId, player);
        _world.RegisterCandidateFootprint(definitionId.Value, prototype);
        if (Stopwatch.GetTimestamp() >= deadline)
        {
            return PendingSpot();
        }
        if (construction.Placement.Footprint is not CirclePlacementFootprint footprint)
        {
            return AutoSpotResult(false, Vector3.Zero, StructurePlacementIssue.ValidationUnavailable.ToString());
        }
        var radius = MathF.Max(footprint.Radius, 0.5f);
        var hintPoint = hint.IsFinite() ? (Vector3?)hint : null;
        var anchorStarted = QueryPerfCounters.Enabled ? Stopwatch.GetTimestamp() : 0L;
        if (ResolveAutoAnchor(player, mode, hintPoint, definitionId.Value) is not Vector3 anchor)
        {
            return AutoSpotResult(false, Vector3.Zero);
        }
        if (QueryPerfCounters.Enabled)
        {
            QueryPerfCounters.AddPlacementPhase(
                "slice_anchor", Stopwatch.GetTimestamp() - anchorStarted);
        }
        if (HasActiveConstructionSite(player))
        {
            return AutoSpotResult(false, Vector3.Zero, StructurePlacementIssue.ConstructionInProgress.ToString());
        }

        var limit = maxRadiusMeters > 0.01f
            ? maxRadiusMeters
            : (string.Equals(mode, "resource", StringComparison.Ordinal) ? 32f : 30f);
        var agentRadius = _world.CachedAgentRadiusMeters;
        var carveClearance = radius + agentRadius + GodotStructurePlacementWorldPort.EdgeClearanceMeters;
        var firstRing = string.Equals(mode, "hint", StringComparison.Ordinal)
            ? GodotStructurePlacementWorldPort.EdgeClearanceMeters * 0.5f
            : string.Equals(mode, "resource", StringComparison.Ordinal)
                ? MathF.Max(radius + 2.0f, carveClearance)
                : radius + 1.5f;
        var ringStep = MathF.Max(0.5f, MathF.Min(2.0f, GodotStructurePlacementWorldPort.EdgeClearanceMeters));
        var maxRings = Math.Clamp((int)MathF.Ceiling((MathF.Min(limit, 48f) - firstRing) / ringStep) + 1, 1, 64);
        var id = player.GetInstanceId();
        var key = $"{definitionId.Value}|{mode}|{anchor.X:F1}|{anchor.Z:F1}|{limit:F1}";
        var generation = _world.MutationCount;
        if (_ruleSpotMisses.TryGetValue(id, out var misses) &&
            misses.TryGetValue(key, out var missGeneration) && missGeneration == generation)
        {
            return AutoSpotResult(false, Vector3.Zero);
        }

        if (!_ruleSpotJobs.TryGetValue(id, out var job) || job.Key != key)
        {
            job = new RuleSpotJob
            {
                Key = key,
                Generation = generation,
                StartedTicks = Stopwatch.GetTimestamp(),
                Radius = radius,
                Anchor = anchor,
                Limit = limit,
                Mode = mode,
            };
            _ruleSpotJobs[id] = job;
        }
        if (job.Generation != generation)
        {
            job.Restarts++;
            job.Generation = generation;
            job.Ready = false;
            job.Ranked.Clear();
            job.Cursor = null;
            job.HeldSpot = null;
            job.Index = 0;
            job.IssueMix.Clear();
            if (job.Restarts > MaxSearchRestarts)
            {
                _ruleSpotJobs.Remove(id);
                return AutoSpotResult(false, Vector3.Zero, "SearchRestartLimit");
            }
        }
        if (Stopwatch.GetTimestamp() - job.StartedTicks > TicksFromUs(SearchDeadlineUs))
        {
            _ruleSpotJobs.Remove(id);
            return AutoSpotResult(false, Vector3.Zero, "SearchExpired");
        }
        if (job.HeldSpot is Vector3 held)
        {
            _ruleSpotJobs.Remove(id);
            GD.Print($"[AUTOSPOT] FOUND-SLICE ({held.X:F1},{held.Y:F1},{held.Z:F1}) index={job.Index}");
            return AutoSpotResult(true, held);
        }
        if (!job.Ready)
        {
            var rankedStarted = QueryPerfCounters.Enabled ? Stopwatch.GetTimestamp() : 0L;
            job.Cursor ??= new RankCursor();
            var rankedDone = AppendRanked(
                job.Cursor, player, mode, definitionId.Value, anchor, radius, limit,
                carveClearance, firstRing, ringStep, maxRings, deadline);
            if (QueryPerfCounters.Enabled)
            {
                QueryPerfCounters.AddPlacementPhase(
                    "ranked_build", Stopwatch.GetTimestamp() - rankedStarted);
            }
            if (!rankedDone)
            {
                if (QueryPerfCounters.Enabled)
                {
                    QueryPerfCounters.AddPlacementPhase(
                        "slice_setup", Stopwatch.GetTimestamp() - stepStarted);
                }
                return PendingSpot();
            }
            job.Ranked = job.Cursor.Candidates
                .OrderByDescending(item => item.Score)
                .Take(256)
                .Select(item => item.Position)
                .ToList();
            job.Ready = true;
            job.Index = 0;
            if (Stopwatch.GetTimestamp() >= deadline)
            {
                if (QueryPerfCounters.Enabled)
                {
                    QueryPerfCounters.AddPlacementPhase(
                        "slice_setup", Stopwatch.GetTimestamp() - stepStarted);
                }
                return PendingSpot();
            }
        }
        if (QueryPerfCounters.Enabled)
        {
            QueryPerfCounters.AddPlacementPhase("slice_setup", Stopwatch.GetTimestamp() - stepStarted);
        }

        while (job.Index < job.Ranked.Count)
        {
            if (Stopwatch.GetTimestamp() >= deadline)
            {
                return PendingSpot();
            }
            var spot = job.Ranked[job.Index];
            var warmStarted = QueryPerfCounters.Enabled ? Stopwatch.GetTimestamp() : 0L;
            var warm = _world.WarmFootprint(spot, job.Radius, deadline);
            if (QueryPerfCounters.Enabled)
            {
                QueryPerfCounters.AddPlacementPhase("warm", Stopwatch.GetTimestamp() - warmStarted);
            }
            if (warm < 0)
            {
                return PendingSpot();
            }
            if (warm == 0 && job.Index > 0)
            {
                job.IssueMix[StructurePlacementIssue.SurfaceNotBuildable] =
                    job.IssueMix.GetValueOrDefault(StructurePlacementIssue.SurfaceNotBuildable) + 1;
                job.Index++;
                continue;
            }
            if (Stopwatch.GetTimestamp() >= deadline)
            {
                return PendingSpot();
            }
            var queryStarted = QueryPerfCounters.Enabled ? Stopwatch.GetTimestamp() : 0L;
            var query = Query(playerId, definitionId, new Transform3D(Basis.Identity, spot));
            if (QueryPerfCounters.Enabled)
            {
                QueryPerfCounters.AddPlacementPhase(
                    "eval_query", Stopwatch.GetTimestamp() - queryStarted);
            }
            var evalStarted = QueryPerfCounters.Enabled ? Stopwatch.GetTimestamp() : 0L;
            var evaluation = _service.Evaluate(query);
            if (QueryPerfCounters.Enabled)
            {
                var evalTicks = Stopwatch.GetTimestamp() - evalStarted;
                QueryPerfCounters.NoteEvaluateOne(evalTicks);
                QueryPerfCounters.AddPlacementPhase(
                    "eval_prep", StructurePlacementService.LastPrepTicks);
                QueryPerfCounters.AddPlacementPhase(
                    "eval_account", StructurePlacementService.LastAccountTicks);
                QueryPerfCounters.AddPlacementPhase(
                    "eval_result", StructurePlacementService.LastResultTicks);
                if (evalTicks >= TicksFromUs(8000))
                {
                    long Us(long ticks) => ticks * 1_000_000L / Stopwatch.Frequency;
                    GD.Print(
                        $"[EVAL] us={Us(evalTicks)} prep={Us(StructurePlacementService.LastPrepTicks)} " +
                        $"world={Us(StructurePlacementService.LastWorldTicks)} " +
                        $"account={Us(StructurePlacementService.LastAccountTicks)} " +
                        $"result={Us(StructurePlacementService.LastResultTicks)} def={definitionId.Value}");
                }
            }
            if (evaluation.IsValid || (evaluation.Issues.Count == 1 &&
                evaluation.Issues[0] == StructurePlacementIssue.InsufficientResources))
            {
                job.HeldSpot = SampleGroundHeight(spot);
                return PendingSpot();
            }
            if (evaluation.Issues.Count == 1 && IsGlobalIssue(evaluation.Issues[0]))
            {
                _ruleSpotJobs.Remove(id);
                return AutoSpotResult(false, Vector3.Zero, evaluation.Issues[0].ToString());
            }
            foreach (var issue in evaluation.Issues)
            {
                job.IssueMix[issue] = job.IssueMix.GetValueOrDefault(issue) + 1;
            }
            job.Index++;
        }

        LogAutoSpotFailure(player, mode, job.Anchor, job.Limit, job.Index, job.IssueMix, "exhausted");
        _ruleSpotJobs.Remove(id);
        _ruleSpotMisses.TryAdd(id, new Dictionary<string, int>());
        _ruleSpotMisses[id][key] = generation;
        return AutoSpotResult(false, Vector3.Zero);
    }

    private static Godot.Collections.Dictionary PendingSpot() => new()
    {
        ["found"] = false,
        ["pos"] = Vector3.Zero,
        ["reason"] = "",
        ["pending"] = true,
    };
}
