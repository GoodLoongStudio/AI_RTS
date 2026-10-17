# -*- coding: utf-8 -*-
"""定向 Godot 冒烟回归：只跑指定的那几条，但**照全套的判据判**。

为什么不用 `tools/run_full_regression.ps1`：本轮开工期间它处于**另一路会话的在飞改动**中，
直接 `-File` 调用报 `ParserError: UnexpectedToken`（ps1 自身当前解析不过）。
不代改别人的文件，但也不能因此没有非退化证据，所以这里用同一份
`config/full_regression_suite.json` 的 `expected_marker` **和** `forbidden_output_patterns`
两条口径自己跑：

- `passed` = 期望 marker 出现 **且** 返回码 0；
- `log_clean` = 没有任何 forbidden pattern 命中（SCRIPT ERROR / Parse Error /
  ObjectDB 泄漏 / 断言失败等）。

两个结论**分开报**：只看 marker 判绿正是阶段 0 记过的假阳性来源
（"日志里 SCRIPT ERROR 刷屏也可能判 PASS"）。本轮就真撞到了这种噪声：
`Navmesh 'agent_radius' must match established constant` 之类来自并行会话
正在回退的单位半径改动，不属于本任务，但必须显式记在报告里而不是被"PASS"吞掉。

用法：
    python tools/run_targeted_godot_tests.py --godot <exe> --ids automatic-construction,ore-refinery
"""
from __future__ import annotations

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import time

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SUITE = os.path.join(REPO, "config", "full_regression_suite.json")
# 帧预算而不是秒：headless 约 58 帧/秒，给足到 ~55 分钟上限，
# 否则整局夹具会被帧预算截断，看起来像"卡死"（实测踩过）。
QUIT_AFTER = "200000"


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def main() -> int:
    parser = argparse.ArgumentParser(description="定向 Godot 冒烟回归")
    parser.add_argument("--godot", required=True)
    parser.add_argument("--ids", required=True, help="逗号分隔的套件 id")
    parser.add_argument("--out", default=os.path.join(REPO, "build", "targeted_regression"))
    args = parser.parse_args()

    wanted = [item.strip() for item in args.ids.split(",") if item.strip()]
    with open(SUITE, encoding="utf-8") as handle:
        suite = json.load(handle)
    patterns = [re.compile(item) for item in suite.get("forbidden_output_patterns", [])]
    by_id = {item.get("id"): item for item in suite.get("godot_tests", [])}
    missing = [item for item in wanted if item not in by_id]
    if missing:
        print("[targeted] 套件里没有这些 id：%s" % ",".join(missing), flush=True)
        return 2
    os.makedirs(args.out, exist_ok=True)

    rows = []
    for test_id in wanted:
        test = by_id[test_id]
        cmd = [args.godot, "--headless", "--path", REPO, "--quit-after", QUIT_AFTER,
               test["scene"]]
        for extra in test.get("extra_args") or []:
            cmd.append(str(extra).replace("{free_port}", str(free_port())))
        started = time.time()
        print("[targeted] 跑 %s (%s)" % (test_id, test["scene"].split("/")[-1]), flush=True)
        try:
            proc = subprocess.run(cmd, cwd=REPO, timeout=int(test.get("timeout_seconds", 120)) + 240,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            output = proc.stdout.decode("utf-8", "replace")
            code = proc.returncode
        except subprocess.TimeoutExpired:
            output, code = "(timeout)", -9
        marker = test.get("expected_marker", "")
        hits = sorted({pattern.pattern for pattern in patterns if pattern.search(output)})
        log_path = os.path.join(args.out, "%s.log" % test_id)
        with open(log_path, "w", encoding="utf-8") as handle:
            handle.write(output)
        rows.append({"id": test_id, "passed": bool(marker) and marker in output and code == 0,
                     "returncode": code, "marker": marker, "marker_found": marker in output,
                     "forbidden_hits": hits, "seconds": round(time.time() - started, 1),
                     "log": log_path})
        print("[targeted]   %s passed=%s rc=%s 噪声=%s" % (
            test_id, rows[-1]["passed"], code, hits or "无"), flush=True)

    payload = {"rows": rows, "at": time.strftime("%Y-%m-%d %H:%M:%S")}
    with open(os.path.join(args.out, "summary.json"), "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=1)
    lines = ["# 定向非退化回归（§7 完成标准第 8 条）", "",
             "| id | passed | 日志干净 | 返回码 | 秒 | forbidden 命中 |", "|---|---|---|---|---|---|"]
    for row in rows:
        lines.append("| %s | %s | %s | %s | %s | %s |" % (
            row["id"], "是" if row["passed"] else "**否**",
            "是" if not row["forbidden_hits"] else "**否**",
            row["returncode"], row["seconds"],
            "、".join(row["forbidden_hits"]) or "无"))
    with open(os.path.join(args.out, "summary.md"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    failed = [row["id"] for row in rows if not row["passed"]]
    print("[targeted] %d/%d 通过%s" % (len(rows) - len(failed), len(rows),
                                       ("；失败：" + ",".join(failed)) if failed else ""),
          flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
