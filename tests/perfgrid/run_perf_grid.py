# -*- coding: utf-8 -*-
"""临时性能对照驱动（2026-09-26 索敌优化第一轮）。

交错安排三个版本（同一时间窗内轮转，减少时间漂移）：
  A = AIRTS_TARGETING=baseline   （旧全场组扫描 + 无错峰，基线）
  B = AIRTS_TARGETING=nostagger  （仅空间网格）
  C = （默认）                    （空间网格 + 索敌错峰）
每次运行唯一 run_id、独立 JSON；已存在的 run_id 跳过（可恢复分块）。
用法：python tests/perfgrid/run_perf_grid.py [max_runs] [scenario_filter]
"""
import json
import os
import subprocess
import sys
import time

GODOT = r"G:/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64_console.exe"
PROJ = "G:/AIRTS/AI_RTS"
OUT = "G:/AIRTS/tmp_logs/perf_grid_20260926"

# 主矩阵：G4 生成地图（用户 2026-09-26 指定：压力测试在 G4 地图上更准）。
# PlainAndSimple 场景（idle200 等）保留为机制对照，可后续补跑。
SCENARIOS = ["g4idle200", "g4idle400", "g4battle200", "g4move200"]
VERSIONS = {"A": "basestats", "B": "nostagger", "C": None}
REPS = 3


def run_one(run_id, scenario, version, warmup=20.0, sample=60.0):
    os.makedirs(OUT, exist_ok=True)
    log_path = os.path.join(OUT, run_id + ".out")
    env = dict(os.environ)
    env["AIRTS_TEST_BASE"] = "24609"
    if VERSIONS[version] is not None:
        env["AIRTS_TARGETING"] = VERSIONS[version]
    else:
        env.pop("AIRTS_TARGETING", None)
    cmd = [
        GODOT, "--path", PROJ, "res://tests/perfgrid/PerfGridRunner.tscn",
        "--resolution", "1920x1080", "--",
        "--scenario=%s" % scenario, "--warmup=%s" % warmup, "--sample=%s" % sample,
        "--out=%s" % OUT, "--label=%s" % run_id,
    ]
    with open(log_path, "w", encoding="utf-8", errors="replace") as log:
        start = time.time()
        proc = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT,
                              env=env, timeout=600, cwd=PROJ)
        elapsed = time.time() - start
    print("  %s exit=%s %.0fs" % (run_id, proc.returncode, elapsed), flush=True)
    result_path = os.path.join(OUT, run_id + ".json")
    if os.path.exists(result_path):
        with open(result_path, encoding="utf-8") as fh:
            return json.load(fh)
    print("  MISSING JSON %s (see %s)" % (run_id, log_path), flush=True)
    return None


def main():
    max_runs = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    scenario_filter = sys.argv[2] if len(sys.argv) > 2 else None
    stamp = time.strftime("%Y%m%d")
    ran = 0
    rows = []
    for scenario in SCENARIOS:
        if scenario_filter and scenario != scenario_filter:
            continue
        for rep in range(1, REPS + 1):
            for version in ["A", "B", "C"]:  # 交错：A→B→C ×3，减弱时间漂移
                run_id = "%s_%s_r%d_%s" % (scenario, version, rep, stamp)
                result_path = os.path.join(OUT, run_id + ".json")
                if os.path.exists(result_path):
                    print("[skip done] %s" % run_id, flush=True)
                    with open(result_path, encoding="utf-8") as fh:
                        result = json.load(fh)
                else:
                    if max_runs and ran >= max_runs:
                        print("[max-runs %d reached]" % max_runs, flush=True)
                        _dump(rows)
                        return
                    print("[%s] %s" % (version, run_id), flush=True)
                    result = run_one(run_id, scenario, version)
                    ran += 1
                if result:
                    rows.append({
                        "run_id": run_id, "scenario": scenario, "version": version,
                        "fps_avg": result["fps_avg"], "fps_1pct_low": result["fps_1pct_low"],
                        "p50": result["frame_ms_p50"], "p95": result["frame_ms_p95"],
                        "p99": result["frame_ms_p99"],
                        "render_cpu_avg": result["render_cpu_ms_avg"],
                        "render_gpu_avg": result["render_gpu_ms_avg"],
                        "queries": result["targeting_stats"].get("query_calls", 0),
                        "candidates": result["targeting_stats"].get("candidates_returned", 0),
                        "scan_us": result["targeting_stats"].get("scan_time_us", 0),
                        "maintain_us": result["targeting_stats"].get("index_maintain_us", 0),
                        "peak_scan_us": result["targeting_stats"].get("peak_frame_scan_us", 0),
                        "units_start": result["units_start"], "units_end": result["units_end"],
                    })
    _dump(rows)


def _dump(rows):
    with open(os.path.join(OUT, "summary_grid.json"), "w", encoding="utf-8") as fh:
        json.dump(rows, fh, indent=1, ensure_ascii=False)
    print("=== SUMMARY (%d rows) ===" % len(rows), flush=True)
    for row in rows:
        print(json.dumps(row, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
