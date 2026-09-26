# -*- coding: utf-8 -*-
"""临时回归驱动（2026-09-26）：tools/run_full_regression.ps1 在本机 PowerShell 5.1
下解析失败（共享脚本既有问题，不改动它），改为直接按
config/full_regression_suite.json 逐个运行 godot_tests，断言 expected_marker。
支持断点续跑：每个测试通过后在 tests/perfgrid/.regress_state/ 留标记。
用法：python tests/perfgrid/run_regression.py [max_tests] [category_filter]
"""
import json
import os
import socket
import subprocess
import sys
import time

GODOT = r"G:/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64_console.exe"
PROJ = "G:/AIRTS/AI_RTS"
STATE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".regress_state")
LOGDIR = r"G:/AIRTS/tmp_logs/perf_grid_20260926/regression"


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def main():
    max_tests = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    category = sys.argv[2] if len(sys.argv) > 2 else None
    cfg = json.load(open(os.path.join(PROJ, "config", "full_regression_suite.json"), encoding="utf-8"))
    excluded = set(cfg.get("excluded_scenes", []))
    os.makedirs(STATE, exist_ok=True)
    os.makedirs(LOGDIR, exist_ok=True)
    passed = failed = skipped = 0
    ran = 0
    results = []
    for test in cfg.get("godot_tests", []):
        tid = test["id"]
        scene = test["scene"]
        if scene in excluded:
            skipped += 1
            continue
        if category and test.get("category") != category:
            continue
        marker_file = os.path.join(STATE, tid + ".pass")
        if os.path.exists(marker_file):
            skipped += 1
            results.append({"id": tid, "result": "skipped_done"})
            continue
        if max_tests and ran >= max_tests:
            print("[max-tests %d reached]" % max_tests, flush=True)
            break
        args = [a.replace("{free_port}", str(free_port())) for a in test.get("extra_args", [])]
        env = dict(os.environ)
        env["AIRTS_TEST_BASE"] = "24609"
        cmd = [GODOT, "--path", PROJ, scene] + args
        log_path = os.path.join(LOGDIR, tid + ".out")
        start = time.time()
        try:
            with open(log_path, "w", encoding="utf-8", errors="replace") as log:
                proc = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT,
                                      env=env, timeout=test.get("timeout_seconds", 120),
                                      cwd=PROJ)
            output = open(log_path, encoding="utf-8", errors="replace").read()
            ok = test.get("expected_marker", "") in output and proc.returncode == 0
        except subprocess.TimeoutExpired:
            ok = False
            output = "TIMEOUT"
        elapsed = time.time() - start
        ran += 1
        if ok:
            passed += 1
            open(marker_file, "w").write("ok")
        else:
            failed += 1
        print("%-42s %s (%.0fs)" % (tid, "PASS" if ok else "FAIL", elapsed), flush=True)
        results.append({"id": tid, "result": "pass" if ok else "fail", "seconds": round(elapsed, 1)})
    with open(os.path.join(LOGDIR, "results.json"), "w", encoding="utf-8") as fh:
        json.dump(results, fh, indent=1)
    print("=== regression: pass=%d fail=%d skip=%d ===" % (passed, failed, skipped), flush=True)


if __name__ == "__main__":
    main()
