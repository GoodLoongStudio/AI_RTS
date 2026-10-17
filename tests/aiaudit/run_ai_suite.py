# -*- coding: utf-8 -*-
"""定向回归驱动（2026-09-28）：只跑 副官(adjutant) + 电脑玩家(traditional-ai) 两组用例。
逐个运行 godot headless，抓取结论行与 SCRIPT ERROR，写 JSON 汇总。
用法: python tests/aiaudit/run_ai_suite.py [id1,id2,...]
"""
import json
import os
import re
import socket
import subprocess
import sys
import time
from collections import deque

#: 日志窗口：头部留够上下文，尾部必须留住结论行（`completed: N failure(s)`）。
HEAD_LINES = 8000
TAIL_LINES = 4000

GODOT = r"G:/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64_console.exe"
PROJ = "G:/AIRTS/AI_RTS"
CFG = json.load(open(os.path.join(PROJ, "config", "full_regression_suite.json"), encoding="utf-8"))
BY_ID = {t["id"]: t for t in CFG["godot_tests"]}
OUTDIR = os.environ.get("AIRTS_AIAUDIT_OUT") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "out")
CATEGORIES = ("traditional-ai", "adjutant")


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def main():
    os.makedirs(OUTDIR, exist_ok=True)
    only = sys.argv[1].split(",") if len(sys.argv) > 1 else None
    targets = []
    for t in CFG["godot_tests"]:
        if only:
            if t["id"] not in only:
                continue
        elif t.get("category") not in CATEGORIES:
            continue
        targets.append(t)
    results = []
    for t in targets:
        tid, scene, marker = t["id"], t["scene"], t["expected_marker"]
        args = [a.replace("{free_port}", str(free_port())) for a in t.get("extra_args") or []]
        env = dict(os.environ)
        env["AIRTS_TEST_BASE"] = "24800"
        env["PYTHONIOENCODING"] = "utf-8"
        cmd = [GODOT, "--headless", "--path", PROJ, "--quit-after", "200000", scene] + args
        log_path = os.path.join(OUTDIR, tid + ".out")
        start = time.time()
        rc = None
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    env=env, text=True, encoding="utf-8", errors="replace")
            # 逐行去重 + 头部/尾部双窗口：结论行打在**最后**，只留头部会把
            # "completed: N failure(s)" 截掉 → 判成假红（实测 movement-scale）。
            head, tail = [], deque(maxlen=TAIL_LINES)
            with open(log_path, "w", encoding="utf-8", errors="replace") as log:
                prev, repeat, seen = None, 0, 0
                deadline = start + t.get("timeout_seconds", 120) + 60
                for line in proc.stdout:
                    if time.time() > deadline:
                        proc.kill()
                        rc = "timeout"
                        break
                    if line == prev:
                        repeat += 1
                        continue
                    if prev is not None and repeat:
                        note = "    ... [last line repeated %d more times]\n" % repeat
                        if len(head) < HEAD_LINES:
                            head.append(note)
                        else:
                            tail.append(note)
                    repeat, prev = 0, line
                    seen += 1
                    if len(head) < HEAD_LINES:
                        head.append(line)
                    else:
                        tail.append(line)
                if prev is not None and repeat:
                    tail.append("    ... [last line repeated %d more times]\n")
                skipped = max(0, seen - HEAD_LINES)
                log.writelines(head)
                if skipped:
                    log.write("[... 中间 %d 行已省略 ...]\n" % skipped)
                    log.writelines(tail)
                if rc is None:
                    proc.wait()
                    rc = proc.returncode
        except subprocess.TimeoutExpired:
            rc = "timeout"
        text = open(log_path, encoding="utf-8", errors="replace").read() if os.path.exists(log_path) else ""
        fails = re.findall(r"assertion failed:\s*(.*)$", text, re.M)
        parse_err = re.findall(r"(Parse Error:.*|Failed to load script.*|Cannot [^\n]{0,160}|System\.\w+Exception[^\n]{0,80}|Invalid access to property or key [^\n]{0,120}|Trying to assign value[^\n]{0,120})", text)
        res = {
            "id": tid,
            "category": t.get("category"),
            "scene": scene,
            "returncode": rc,
            "seconds": round(time.time() - start, 1),
            "marker_ok": marker in text,
            "marker": marker,
            "conclusion": [m for m in re.findall(r"(\d+) failure\(s\)", text)],
            "fail_lines": fails[:40],
            "errors": sorted(set(parse_err))[:30],
            "log_lines": len(text.splitlines()),
        }
        results.append(res)
        print("[%s] rc=%s marker_ok=%s fails=%d secs=%.1f" % (
            tid, rc, res["marker_ok"], len(fails), res["seconds"]), flush=True)
        with open(os.path.join(OUTDIR, "summary.json"), "w", encoding="utf-8") as f:
            json.dump(results, f, ensure_ascii=False, indent=2)
    print("DONE %d tests, %d red" % (len(results), sum(1 for r in results if not r["marker_ok"])), flush=True)


if __name__ == "__main__":
    main()
