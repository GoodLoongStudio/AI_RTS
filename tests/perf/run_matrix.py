# -*- coding: utf-8 -*-
"""临时性能测试矩阵驱动（2026-09-25 性能诊断专用，用完即删）。

串行执行 godot 渲染运行；每个运行同步采样整机 GPU 利用率（nvidia-smi，2s 粒度），
用于识别背景负载（本机有 LoL 等无关进程时数据会被污染，报告中如实标注）。
"""
import json
import os
import subprocess
import sys
import time

GODOT = r"G:/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64_console.exe"
PROJ = "G:/AIRTS/AI_RTS"
OUT = "G:/AIRTS/tmp_logs/perf_20260925"

# 场景 → (scene key, 重复次数, expected 单位数)
SCENARIOS = {"A": ("small", 1, 7), "B": ("battle", 3, 88), "C": ("large", 1, 29)}
# 标签 → (mode, scale)
CONFIGS = [
    ("native", "bilinear", 1.00),
    ("bil067", "bilinear", 0.67),
    ("fsr067", "fsr2", 0.67),
    ("bil050", "bilinear", 0.50),
    ("fsr050", "fsr2", 0.50),
]


def run_one(tag, scenario_key, expected, mode, scale, warmup=20.0, sample=60.0):
    label = "%s_%s" % (scenario_key, tag)
    os.makedirs(OUT, exist_ok=True)
    log_path = os.path.join(OUT, label + ".out")
    gpu_path = os.path.join(OUT, "gpu_%s.csv" % label)
    with open(log_path, "w", encoding="utf-8", errors="replace") as log:
        gpu = subprocess.Popen(
            ["nvidia-smi",
             "--query-gpu=timestamp,utilization.gpu,memory.used,power.draw",
             "--format=csv,noheader,nounits", "-l", "2"],
            stdout=open(gpu_path, "w", encoding="utf-8"),
            stderr=subprocess.STDOUT)
        try:
            cmd = [
                GODOT, "--path", PROJ, "res://tests/perf/PerfRunner.tscn",
                "--resolution", "1920x1080",
                "--",
                "--scenario=%s" % scenario_key,
                "--mode=%s" % mode,
                "--scale=%s" % scale,
                "--warmup=%s" % warmup,
                "--sample=%s" % sample,
                "--out=%s" % OUT,
                "--label=%s" % label,
                "--msaa=2",
                "--expected=%d" % expected,
            ]
            env = dict(os.environ)
            env["AIRTS_TEST_BASE"] = "24609"  # 端口隔离，不干扰用户的 Demo 构建
            start = time.time()
            proc = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT,
                                  env=env, timeout=900, cwd=PROJ)
            elapsed = time.time() - start
        finally:
            gpu.terminate()
    print("  exit=%s elapsed=%.0fs" % (proc.returncode, elapsed), flush=True)
    result_path = os.path.join(OUT, label + ".json")
    if os.path.exists(result_path):
        with open(result_path, encoding="utf-8") as fh:
            return json.load(fh)
    print("  MISSING JSON for %s, see %s" % (label, log_path), flush=True)
    return None


def main():
    only = sys.argv[1] if len(sys.argv) > 1 else None  # 可传场景 A/B/C 只跑该场景
    max_runs = int(sys.argv[2]) if len(sys.argv) > 2 else 0  # 单次调用的运行数上限（可恢复分块）
    summary = []
    ran = 0
    for scenario_name, (scenario_key, repeats, expected) in SCENARIOS.items():
        if only and scenario_name != only:
            continue
        for rep in range(1, repeats + 1):
            for tag, mode, scale in CONFIGS:
                run_tag = "%s_r%d" % (tag, rep)
                result_path = os.path.join(OUT, "%s_%s.json" % (scenario_key, run_tag))
                if os.path.exists(result_path):  # 可恢复：跳过已完成运行
                    with open(result_path, encoding="utf-8") as fh:
                        result = json.load(fh)
                    print("[skip done] %s_%s" % (scenario_key, run_tag), flush=True)
                else:
                    if max_runs and ran >= max_runs:
                        print("[max-runs %d reached, stop]" % max_runs, flush=True)
                        with open(os.path.join(OUT, "summary.json"), "w", encoding="utf-8") as fh:
                            json.dump(summary, fh, indent=1)
                        return
                    print("[%s %s] scale=%.2f mode=%s" % (scenario_name, run_tag, scale, mode), flush=True)
                    result = run_one(run_tag, scenario_key, expected, mode, scale)
                    ran += 1
                if result:
                    summary.append({
                        "scenario": scenario_name, "tag": run_tag,
                        "fps_avg": result["fps_avg"], "fps_1pct_low": result["fps_1pct_low"],
                        "frame_ms_p95": result["frame_ms_p95"],
                        "cpu_process_ms_avg": result["cpu_process_ms_avg"],
                        "draw_calls_avg": result["draw_calls_avg"],
                        "units_min": result["units_min"], "units_max": result["units_max"],
                    })
    with open(os.path.join(OUT, "summary.json"), "w", encoding="utf-8") as fh:
        json.dump(summary, fh, indent=1)
    print("=== SUMMARY ===", flush=True)
    for row in summary:
        print(json.dumps(row), flush=True)


if __name__ == "__main__":
    main()
