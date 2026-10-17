#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""副官共存探针（2026-10-11 阶段一，共存复测专用）。

流程：headless 专用服 + headless 客户端（e2e_dual_layer 同款启动）→
尝试把最多 3 个槽位转为规则 AI（controller op；失败则 1AI 回退）→
start 开局 → 挂接 agent_runner（--authority-port=服务器 DCS，--allow-other-port，
provider=real，model=on）→ 双侧采样（游戏 frame/实体 + runner 日志尾部）→
到时收尾。所有权：本驱动 Popen 的进程树，finally 统一清理。
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
sys.path.insert(0, str(HERE))

from match_instance import allocate_ports, kill_tree, tcp_call  # noqa: E402

GODOT = (r"G:/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/"
         r"Godot_v4.7.1-stable_mono_win64_console.exe")
RUNNER = str(PROJECT / "source/adjutant_coordinator/deploy/agent_runner.py")
# 副官 runner 必须用登记的副官 venv（含 pydantic_ai/Laya 依赖）：
# 2026-10-11 实测 anaconda python 启动报 "pydantic_ai 不可用" setup_failed。
RUNNER_PY = r"G:/AIRTS/临时文件夹/airts_agent_venv/Scripts/python.exe"
CREATE_NO_WINDOW = 0x08000000


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True)
    parser.add_argument("--run-id", default="coexist")
    parser.add_argument("--minutes", type=float, default=8.0)
    parser.add_argument("--deadline-s", type=float, default=0.0)
    args = parser.parse_args()

    output = Path(args.out).resolve()
    output.mkdir(parents=True, exist_ok=True)
    ports = allocate_ports()
    server_port, server_dbg = ports["game"], ports["server_dcs"]
    client_dbg = ports["client_dcs"]
    deadline_s = args.deadline_s or (args.minutes * 60 + 420)

    env = dict(os.environ)
    env["AIRTS_AI_PERF_STATS"] = "1"  # 游戏侧插桩：frame 分布 + AI/查询桶
    server_log = open(output / "server.log", "wb")
    client_log = open(output / "client.log", "wb")
    runner_log = open(output / "runner.log", "wb")

    server = subprocess.Popen(
        [GODOT, "--headless", "--path", ".", "--",
         "--server", "--port", str(server_port), "--debugport", str(server_dbg)],
        cwd=str(PROJECT), env=env, stdout=server_log, stderr=subprocess.STDOUT,
        creationflags=CREATE_NO_WINDOW)
    client = subprocess.Popen(
        [GODOT, "--headless", "--path", ".", "--",
         "--debugport", str(client_dbg), "--autojoin", "--autojoin-lobby",
         "--smokehost", "127.0.0.1", "--smokeport", str(server_port)],
        cwd=str(PROJECT), env=env, stdout=client_log, stderr=subprocess.STDOUT,
        creationflags=CREATE_NO_WINDOW)
    runner = None
    print("server pid=%d dcs=%d client pid=%d dcs=%d" % (
        server.pid, server_dbg, client.pid, client_dbg), flush=True)
    samples = open(output / "coexist_samples.jsonl", "w", encoding="utf-8")
    started = time.time()
    runner_started = False
    ai_slots_set = False
    match_started = False
    try:
        # 等两个调试口就绪。
        deadline = started + 120
        while time.time() < deadline:
            try:
                tcp_call(server_dbg, {"op": "status", "lite": True}, timeout=3.0)
                tcp_call(client_dbg, {"op": "status", "lite": True}, timeout=3.0)
                break
            except Exception:
                time.sleep(2.0)
        else:
            raise RuntimeError("调试口 120s 未就绪")
        # 槽位 AI 化（尽力而为；失败走 1AI 回退）。
        for slot in (1, 2):
            try:
                reply = tcp_call(server_dbg, {"op": "controller", "rule_ai_slot": slot},
                                 timeout=5.0)
                print("controller slot=%d -> %s" % (slot, str(reply)[:120]), flush=True)
            except Exception as exc:
                print("controller slot=%d failed: %s" % (slot, exc), flush=True)
        ai_slots_set = True
        time.sleep(1.0)
        # 安全闸门（e2e_dual_layer 同款）：等客户端真正联网后才 start。
        networked = False
        for _ in range(30):
            time.sleep(2)
            try:
                status = tcp_call(client_dbg, {"op": "status", "lite": True}, timeout=4.0)
                if status.get("networked") is True:
                    networked = True
                    break
            except Exception:
                pass
        print("client networked=%s" % networked, flush=True)
        reply = tcp_call(client_dbg, {"op": "start", "with_ai": True}, timeout=15.0)
        print("start -> %s" % str(reply)[:160], flush=True)
        match_started = bool(reply.get("ok"))
        # 等服务器 match=True。
        for _ in range(40):
            time.sleep(2)
            try:
                status = tcp_call(server_dbg, {"op": "status", "lite": True}, timeout=4.0)
                if status.get("match") is True:
                    print("server match ready", flush=True)
                    break
            except Exception:
                pass
        # 挂接副官 runner（真实模型档位）。
        runner_cmd = [RUNNER_PY, RUNNER,
                      "--authority-port", str(server_dbg), "--allow-other-port",
                      "--provider", "real", "--model", "on",
                      "--log-dir", str(output / "runner_logs"),
                      "--state-dir", str(output / "runner_state"),
                      "--pidfile", str(output / "runner.pidfile"),
                      "--ttl", str(int(args.minutes * 60 + 120))]
        # 本轮测试进程的运行时环境（不改 .env.local/持久配置）：开发配置口径
        # AIRTS_S1_BACKEND=laya、AIRTS_LAYA_DEVICE 留空=自动 cuda→mps→cpu（计划 §4.1）。
        runner_env = dict(env)
        runner_env.setdefault("AIRTS_S1_BACKEND", "laya")
        runner_env.setdefault("AIRTS_LAYA_DEVICE", "")
        runner = subprocess.Popen(runner_cmd, cwd=str(PROJECT), env=runner_env,
                                  stdout=runner_log, stderr=subprocess.STDOUT,
                                  creationflags=CREATE_NO_WINDOW)
        runner_started = True
        print("runner pid=%d" % runner.pid, flush=True)

        # 双侧采样循环。
        next_sample = 0.0
        while time.time() - started < args.minutes * 60:
            now = time.time()
            if now >= next_sample:
                next_sample = now + 2.0
                row = {"wall_s": round(now - started, 1)}
                for name, port, pid in (("server", server_dbg, server.pid),
                                        ("client", client_dbg, client.pid)):
                    try:
                        row[name] = tcp_call(port, {"op": "status", "lite": True}, timeout=4.0)
                    except Exception as exc:
                        row[name] = {"error": str(exc)}
                samples.write(json.dumps(row, ensure_ascii=False) + "\n")
                samples.flush()
            if server.poll() is not None or client.poll() is not None:
                print("game process exited early", flush=True)
                break
            time.sleep(0.5)
        print("coexist window done at %.0fs" % (time.time() - started), flush=True)
        return 0
    finally:
        samples.close()
        server_log.close()
        client_log.close()
        runner_log.close()
        for proc in (runner, client, server):
            if proc is not None and proc.poll() is None:
                kill_tree(proc.pid)
        print("cleanup done (runner_started=%s ai_slots_set=%s match_started=%s)" % (
            runner_started, ai_slots_set, match_started), flush=True)


if __name__ == "__main__":
    sys.exit(main())
