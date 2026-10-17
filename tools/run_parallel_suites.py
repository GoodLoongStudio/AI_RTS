# -*- coding: utf-8 -*-
"""并行定向 Godot 回归（2026-09-30 提速 C）。

与 run_targeted_godot_tests.py 完全同判据（同一份 full_regression_suite.json 的
expected_marker + forbidden_output_patterns），只是把"顺序 for"换成线程池并发：

- 端口**预先**分配（避免 free_port 竞争）：所有 {free_port} 占位符在启动前一次性算好。
- 环境隔离：AIRTS_INSTANCE_DIR 清空（登记节点完全惰性）+ AIRTS_INSTANCE_STRICT_DCS=0
  （抢不到调试端口的实例**不要**按严格模式自退，否则并行时会互相踢掉）。
- 时序敏感套件走"串行车道"（默认 local-avoidance / navigation-stability /
  movement-recovery / movement-scale）：它们测的是帧时序与拥堵，CPU 争抢会污染结论。

用法：
    python tools/run_parallel_suites.py --godot <exe> --ids a,b,c --jobs 6
    python tools/run_parallel_suites.py --godot <exe> --ids all --jobs 6
"""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import socket
import subprocess
import sys
import time

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SUITE = os.path.join(REPO, "config", "full_regression_suite.json")
QUIT_AFTER = "200000"
SERIAL_DEFAULT = "local-avoidance,navigation-stability,movement-recovery,movement-scale"


def reserve_ports(count: int) -> list[int]:
    """一次性预留 count 个端口（保持 socket 打开到最后才关，避免被别的进程抢走）。"""
    socks, ports = [], []
    for _ in range(count):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        socks.append(s)
        ports.append(int(s.getsockname()[1]))
    return socks, ports


def run_one(godot: str, test: dict, patterns, ports: list[int], out_dir: str) -> dict:
    test_id = test["id"]
    cmd = [godot, "--headless", "--path", REPO, "--quit-after", QUIT_AFTER, test["scene"]]
    for extra in test.get("extra_args") or []:
        text = str(extra)
        if "{free_port}" in text:
            text = text.replace("{free_port}", str(ports.pop() if ports else 0))
        cmd.append(text)
    env = dict(os.environ)
    env["AIRTS_INSTANCE_DIR"] = ""          # 登记节点惰性：不写登记、不启用严格退场
    env["AIRTS_INSTANCE_STRICT_DCS"] = "0"  # 并行时端口必被占，禁止自退
    started = time.time()
    try:
        proc = subprocess.run(cmd, cwd=REPO, env=env,
                              timeout=int(test.get("timeout_seconds", 120)) + 240,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        output, code = proc.stdout.decode("utf-8", "replace"), proc.returncode
    except subprocess.TimeoutExpired as exc:
        output = (exc.stdout or b"").decode("utf-8", "replace") + "\n(timeout)"
        code = -9
    marker = test.get("expected_marker", "")
    hits = sorted({p.pattern for p in patterns if p.search(output)})
    log_path = os.path.join(out_dir, "%s.log" % test_id)
    with open(log_path, "w", encoding="utf-8") as handle:
        handle.write(output)
    return {"id": test_id, "passed": bool(marker) and marker in output and code == 0,
            "returncode": code, "marker_found": marker in output,
            "forbidden_hits": hits, "seconds": round(time.time() - started, 1),
            "log": log_path}


def main() -> int:
    parser = argparse.ArgumentParser(description="并行定向 Godot 回归")
    parser.add_argument("--godot", required=True)
    parser.add_argument("--ids", required=True, help="逗号分隔；all = 全部套件")
    parser.add_argument("--jobs", type=int, default=6, help="并行度（默认 6）")
    parser.add_argument("--serial", default=SERIAL_DEFAULT, help="走串行车道的套件 id")
    parser.add_argument("--out", default=os.path.join(REPO, "build", "targeted_regression"))
    parser.add_argument("--no-recheck", action="store_true", help="失败者不单独复核")
    args = parser.parse_args()

    with open(SUITE, encoding="utf-8") as handle:
        suite = json.load(handle)
    patterns = [re.compile(item) for item in suite.get("forbidden_output_patterns", [])]
    by_id = {item.get("id"): item for item in suite.get("godot_tests", [])}
    wanted = list(by_id) if args.ids.strip() == "all" else [x.strip() for x in args.ids.split(",") if x.strip()]
    missing = [x for x in wanted if x not in by_id]
    if missing:
        print("[parallel] 套件里没有这些 id：%s" % ",".join(missing), flush=True)
        return 2
    os.makedirs(args.out, exist_ok=True)

    serial_ids = {x.strip() for x in args.serial.split(",") if x.strip()}
    parallel = [by_id[x] for x in wanted if x not in serial_ids]
    serial = [by_id[x] for x in wanted if x in serial_ids]

    total_started = time.time()
    print("[parallel] 并行 %d 个（jobs=%d） + 串行 %d 个：%s" % (
        len(parallel), args.jobs, len(serial), ",".join(x["id"] for x in serial)), flush=True)

    socks, ports = reserve_ports(8)
    rows: list[dict] = []
    try:
        if parallel:
            with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
                futures = {pool.submit(run_one, args.godot, t, patterns, ports, args.out): t for t in parallel}
                for fut in concurrent.futures.as_completed(futures):
                    row = fut.result()
                    rows.append(row)
                    print("[parallel]   %-32s passed=%-5s rc=%-4s %5.1fs 噪声=%s" % (
                        row["id"], row["passed"], row["returncode"], row["seconds"],
                        ",".join(row["forbidden_hits"]) or "-"), flush=True)
        for test in serial:
            row = run_one(args.godot, test, patterns, ports, args.out)
            rows.append(row)
            print("[parallel]   %-32s passed=%-5s rc=%-4s %5.1fs 噪声=%s（串行道）" % (
                row["id"], row["passed"], row["returncode"], row["seconds"],
                ",".join(row["forbidden_hits"]) or "-"), flush=True)
    finally:
        for s in socks:
            s.close()

    ok = [r for r in rows if r["passed"]]
    bad = [r for r in rows if not r["passed"]]
    print("\n[parallel] %d/%d 通过，总耗时 %.1fs（顺序跑同批约需 %.0fs）" % (
        len(ok), len(rows), time.time() - total_started, sum(r["seconds"] for r in rows)), flush=True)
    # 失败者**单独**重跑一次：并行争抢（CPU/端口）可能造成假红，必须与真回归区分开。
    if bad and not args.no_recheck:
        print("[parallel] 失败者串行复核：%s" % ",".join(r["id"] for r in bad), flush=True)
        for row in list(bad):
            again = run_one(args.godot, by_id[row["id"]], patterns, ports, args.out)
            row["recheck_passed"] = again["passed"]
            print("[parallel]   复核 %-30s 单独跑 passed=%s" % (row["id"], again["passed"]), flush=True)
        ok = [r for r in rows if r["passed"] or r.get("recheck_passed")]
        bad = [r for r in rows if not (r["passed"] or r.get("recheck_passed"))]
        print("[parallel] 复核后：通过 %d/%d，真失败 %s" % (
            len(ok), len(rows), ",".join(r["id"] for r in bad) or "无"), flush=True)
    if bad:
        print("[parallel] 失败：%s" % ",".join(r["id"] for r in bad), flush=True)
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
