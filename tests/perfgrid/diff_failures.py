# -*- coding: utf-8 -*-
"""差分失败项（2026-09-26）：把回归失败的测试在 AIRTS_TARGETING=baseline
（不创建网格节点 = 旧代码等价形态）下重跑，区分"既有失败"与"优化引入"。"""
import json
import os
import subprocess
import sys

GODOT = r"G:/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64_console.exe"
PROJ = "G:/AIRTS/AI_RTS"
LOGDIR = r"G:/AIRTS/tmp_logs/perf_grid_20260926/regression"


def main():
    cfg = json.load(open(os.path.join(PROJ, "config", "full_regression_suite.json"), encoding="utf-8"))
    by_id = {t["id"]: t for t in cfg["godot_tests"]}
    results = json.load(open(os.path.join(LOGDIR, "results.json"), encoding="utf-8"))
    failures = [r["id"] for r in results if r.get("result") == "fail"]
    print("failures to diff: %d" % len(failures), flush=True)
    inherited, introduced = [], []
    for tid in failures:
        scene = by_id[tid]["scene"]
        env = dict(os.environ)
        env["AIRTS_TEST_BASE"] = "24609"
        env["AIRTS_TARGETING"] = "baseline"
        log_path = os.path.join(LOGDIR, "diff_%s.out" % tid)
        try:
            with open(log_path, "w", encoding="utf-8", errors="replace") as log:
                subprocess.run([GODOT, "--path", PROJ, scene], stdout=log,
                               stderr=subprocess.STDOUT, env=env, timeout=150, cwd=PROJ)
            output = open(log_path, encoding="utf-8", errors="replace").read()
        except subprocess.TimeoutExpired:
            output = "TIMEOUT"
        marker = by_id[tid].get("expected_marker", "")
        ok_baseline = marker in output
        (inherited if not ok_baseline else introduced).append(tid)
        print("%-42s baseline_%s" % (tid, "PASS(=> 优化引入!)" if ok_baseline else "FAIL(既有)"), flush=True)
    print("=== 既有失败 %d | 优化引入 %d ===" % (len(inherited), len(introduced)), flush=True)
    if introduced:
        print("引入清单:", introduced, flush=True)
    json.dump({"inherited": inherited, "introduced": introduced},
              open(os.path.join(LOGDIR, "diff_summary.json"), "w", encoding="utf-8"), indent=1)


if __name__ == "__main__":
    main()
