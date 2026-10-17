#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AI 对局性能探针精简驱动（2026-10-11 阶段一，测量专用）。

复刻 2026-10-11 12:30-12:50 本机验证成功的最小调用模式：
直接 Popen console exe（cwd=项目根、最小环境变量、CREATE_NO_WINDOW），
不启用实例登记/DCS/桥接口。带看门狗与按 pid 树清理；探针自身把 JSON
写到 --perf-out，结束时驱动核验 JSON 新鲜度并打印摘要。

背景：ai_perf_probe.py 走 Instance 注册环境时出现 5 次"仅版本头、CPU
爬行"的卡死（登记/租约/调试口单项二分均未复现，怀疑 USB 外接盘 I/O
停顿 + 注册路径组合），故本驱动完全绕开该路径。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
sys.path.insert(0, str(HERE))

from match_instance import kill_tree  # noqa: E402

CONSOLE_EXE = r"G:/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64_console.exe"
PROBE_SCENE = "res://tools/ai_perf_probe.tscn"
ERROR_RE = re.compile(r"SCRIPT ERROR:|Parse Error:|^ERROR:", re.MULTILINE)
MARKER_RE = re.compile(r"AI_PERF_PROBE completed reason=(\S+) frames=(\d+)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--ai-count", type=int, default=1)
    parser.add_argument("--frames", type=int, default=5400)
    parser.add_argument("--warmup-frames", type=int, default=600)
    parser.add_argument("--difficulty", type=int, default=1)
    parser.add_argument("--extra-units", type=int, default=0)
    parser.add_argument("--deadline-s", type=float, default=900.0,
                        help="总墙钟看门狗（含 USB 盘慢启动余量）")
    parser.add_argument("--no-perf-stats", action="store_true")
    args = parser.parse_args()

    output = Path(args.out).resolve()
    output.mkdir(parents=True, exist_ok=True)
    result_json = output / ("ai_perf_%s.json" % args.run_id)
    out_log = output / ("%s.out.log" % args.run_id)
    err_log = output / ("%s.err.log" % args.run_id)

    argv = [CONSOLE_EXE, "--headless", "--path", ".",
            PROBE_SCENE, "--",
            "--perf-out=" + result_json.as_posix(),
            "--ai-count=%d" % args.ai_count,
            "--frames=%d" % args.frames,
            "--warmup-frames=%d" % args.warmup_frames,
            "--difficulty=%d" % args.difficulty,
            "--extra-units=%d" % args.extra_units,
            "--watchdog-s=%.0f" % (args.deadline_s - 120.0),
            "--run-id=" + args.run_id]
    env = dict(os.environ)
    env["AIRTS_AI_PERF_STATS"] = "0" if args.no_perf_stats else "1"

    started = time.time()
    out_f = open(out_log, "w", encoding="utf-8", errors="replace")
    err_f = open(err_log, "w", encoding="utf-8", errors="replace")
    proc = None
    try:
        proc = subprocess.Popen(argv, cwd=str(PROJECT), env=env,
                                stdout=out_f, stderr=err_f,
                                creationflags=subprocess.CREATE_NO_WINDOW)
        print("launched pid=%d run-id=%s" % (proc.pid, args.run_id), flush=True)
        deadline = time.monotonic() + args.deadline_s
        while proc.poll() is None:
            if time.monotonic() >= deadline:
                kill_tree(proc.pid)
                raise TimeoutError("run %s 超过看门狗 %.0fs（已按 pid 树清理）"
                                   % (args.run_id, args.deadline_s))
            time.sleep(2.0)
        rc = proc.returncode
        out_text = out_log.read_text(encoding="utf-8", errors="replace") if out_log.exists() else ""
        err_text = err_log.read_text(encoding="utf-8", errors="replace") if err_log.exists() else ""
        logs = out_text + err_text
        marker = MARKER_RE.search(logs)
        # 只统计完成标记之前的错误；标记之后的 ERROR 是无头退出 teardown 噪音
        # （RID 泄漏、!is_inside_tree 等，direct-test 冒烟已确认与测量无关）。
        pre_marker_logs = logs[:marker.start()] if marker else logs
        errors = ERROR_RE.findall(pre_marker_logs)
        fresh = result_json.exists() and result_json.stat().st_mtime >= started
        if rc != 0 or not marker or not fresh:
            raise RuntimeError("run %s 失败: rc=%s marker=%s fresh_json=%s"
                               % (args.run_id, rc, bool(marker), fresh))
        data = json.loads(result_json.read_text(encoding="utf-8"))
        summary = {
            "run_id": data.get("run_id"),
            "ai_count": data.get("ai_count"),
            "difficulty": data.get("difficulty"),
            "extra_units": data.get("extra_units_per_player"),
            "sampled_frames": data.get("sampled_frames"),
            "wall_s": round(data.get("wall_s", 0.0), 1),
            "sim_s": data.get("sim_s"),
            "units_final": data.get("units_final"),
            "frame_ms": {k: round(v, 2) for k, v in data.get("frame_ms", {}).items()},
            "errors_excl_teardown": errors[:5],
            "json": str(result_json),
        }
        print(json.dumps(summary, ensure_ascii=False, indent=1), flush=True)
        return 0
    finally:
        out_f.close()
        err_f.close()
        if proc is not None and proc.poll() is None:
            kill_tree(proc.pid)


if __name__ == "__main__":
    sys.exit(main())
