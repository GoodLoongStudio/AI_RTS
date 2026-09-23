# -*- coding: utf-8 -*-
"""无敌人 G4 生成图 × AI 副官 卡住复现驱动。

流程：
  1. headless 起对局场景（NoEnemyAdjutantRepro.tscn，单人无敌人，DCS 开在 --debugport）
  2. 起副官 runner（三层全本地：规则 + Laya/2B）连该端口，正常发展
  3. 进程内监控打印 [REPRO]/[STUCK]/[TRACE]
  4. 到时收尾，汇总卡住单位清单

用法：
  python dev/repro_g4_stuck.py --map 49 --seconds 600
  python dev/repro_g4_stuck.py --map 49 --seconds 600 --backend off
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
# 本脚本位于 <repo>/AI_RTS/dev/：向上找含 AI_RTS 与 godot_mono_471 的仓库根。
REPO = HERE
for _ in range(5):
    if (os.path.isdir(os.path.join(REPO, "AI_RTS"))
            and os.path.isdir(os.path.join(REPO, "godot_mono_471"))):
        break
    REPO = os.path.dirname(REPO)
AIRTS = os.path.join(REPO, "AI_RTS")
GODOT = os.path.join(REPO, "godot_mono_471", "Godot_v4.7.1-stable_mono_win64",
                     "Godot_v4.7.1-stable_mono_win64_console.exe")
VENV_PY = os.path.join(REPO, "临时文件夹", "airts_agent_venv", "Scripts", "python.exe")
SRC = os.path.join(AIRTS, "source")
ENV_FILE = os.path.join(SRC, "adjutant_coordinator", ".env.local")
OUT = os.path.join(REPO, "tmp_logs", "g4_stuck_repro")
SCENE = "res://tests/automated/NoEnemyAdjutantRepro.tscn"

PORT = int(os.environ.get("AIRTS_REPRO_PORT", "24591"))


def log(*a):
    print(" ".join(str(x) for x in a), flush=True)


def tcp_listening(port: int) -> bool:
    out = subprocess.run(["netstat", "-an", "-p", "TCP"], capture_output=True)
    text = (out.stdout or b"").decode("utf-8", errors="replace")
    return ("127.0.0.1:%d" % port) in text and "LISTENING" in text


def kill_game():
    # 只杀挂着本复现场景的 Godot（并行多局时不能按镜像名全杀）。
    ps = ("Get-CimInstance Win32_Process | Where-Object { $_.Name -like 'Godot*' -and "
          "$_.CommandLine -match 'NoEnemyAdjutantRepro' } | "
          "ForEach-Object { $_.ProcessId }")
    try:
        raw = subprocess.run(["powershell", "-NoProfile", "-Command", ps],
                             capture_output=True, timeout=30).stdout
        for pid in (raw or b"").decode("utf-8", errors="replace").split():
            subprocess.run(["taskkill", "/F", "/T", "/PID", pid.strip()], capture_output=True)
    except Exception as exc:  # noqa: BLE001
        log("kill_game err:", exc)
    time.sleep(2)


def kill_runner():
    ps = ("Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'python.exe' -and "
          "$_.CommandLine -match 'agent_runner' -and $_.CommandLine -match '--authority-port %d' } | "
          "ForEach-Object { $_.ProcessId }" % PORT)
    try:
        raw = subprocess.run(["powershell", "-NoProfile", "-Command", ps],
                             capture_output=True, timeout=30).stdout
        for pid in (raw or b"").decode("utf-8", errors="replace").split():
            subprocess.run(["taskkill", "/F", "/T", "/PID", pid.strip()], capture_output=True)
    except Exception as exc:  # noqa: BLE001
        log("kill_runner err:", exc)
    time.sleep(2)


def start_runner(state_dir: str, backend: str, tactics_interval: int):
    hud = os.path.join(state_dir, "hud")
    os.makedirs(hud, exist_ok=True)
    pidfile = os.path.join(hud, "agent_runner.pid")
    if os.path.exists(pidfile):
        os.remove(pidfile)
    args = [VENV_PY, "-m", "adjutant_coordinator.deploy.agent_runner",
            "--authority-port", str(PORT), "--provider", "real", "--engine", "langgraph",
            "--allow-other-port", "--player", "Player_0",
            "--interface", "four-col", "--scheduling", "async",
            "--env-file", ENV_FILE, "--state-dir", state_dir,
            "--log-dir", hud, "--pidfile", pidfile, "--max-batch", "24",
            "--strategy-mode", "plan", "--model", "on",
            "--tactics-interval", str(tactics_interval),
            "--event-interval", "10"]
    env = dict(os.environ)
    env["AIRTS_S1_BACKEND"] = backend
    env["AIRTS_RUNNER_HUD"] = hud
    out = open(os.path.join(state_dir, "runner.out"), "w", encoding="utf-8", errors="replace")
    proc = subprocess.Popen(args, cwd=SRC, stdout=out, stderr=subprocess.STDOUT,
                            env=env, creationflags=subprocess.CREATE_NO_WINDOW)
    log("[driver] runner pid=%d backend=%s" % (proc.pid, backend))
    return proc


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--map", default="49")
    parser.add_argument("--seconds", type=int, default=600)
    parser.add_argument("--backend", default=os.environ.get("AIRTS_S1_BACKEND", "laya"),
                        choices=("laya", "model", "off"))
    parser.add_argument("--tactics-interval", type=int, default=15)
    parser.add_argument("--tag", default="")
    parser.add_argument("--port", type=int, default=None)
    parser.add_argument("--no-runner", action="store_true",
                        help="只起对局不起副官（直接命令压测用）")
    args = parser.parse_args()

    global PORT
    if args.port:
        PORT = args.port

    tag = args.tag or ("g4stuck_%s_%d" % (args.map, int(time.time())))
    state_dir = os.path.join(OUT, tag)
    os.makedirs(state_dir, exist_ok=True)
    game_log = open(os.path.join(state_dir, "game.out"), "w", encoding="utf-8", errors="replace")

    kill_game()
    kill_runner()

    spawn = [GODOT, "--headless", "--path", AIRTS, SCENE, "--", "--debugport", str(PORT),
             args.map, "--seconds=%d" % args.seconds]
    log("[driver] spawn game:", " ".join(spawn))
    game = subprocess.Popen(spawn, stdout=game_log, stderr=subprocess.STDOUT,
                            creationflags=subprocess.CREATE_NO_WINDOW)

    ok = False
    for _ in range(90):
        time.sleep(2)
        if tcp_listening(PORT):
            ok = True
            break
        if game.poll() is not None:
            break
    if not ok:
        log("[driver] DCS 未就绪（game alive=%s）" % (game.poll() is None))
        kill_game()
        return 2
    log("[driver] DCS ready on %d" % PORT)

    if args.no_runner:
        log("[driver] no-runner mode: 只监控，命令由外部脚本下发")
    else:
        start_runner(state_dir, args.backend, args.tactics_interval)

        # 等 runner 写出第一份心跳（jsonl）说明挂上了对局。
        hud = os.path.join(state_dir, "hud")
        attached = False
        for i in range(60):
            time.sleep(3)
            if os.path.isdir(hud) and any(f.endswith(".jsonl") for f in os.listdir(hud)):
                attached = True
                break
            if game.poll() is not None:
                log("[driver] game exited early")
                break
        log("[driver] runner attached=%s" % attached)
        if not attached:
            runner_out = os.path.join(state_dir, "runner.out")
            if os.path.exists(runner_out):
                with open(runner_out, "r", encoding="utf-8", errors="replace") as f:
                    for line in f.read().strip().split("\n")[-25:]:
                        log("  runner.out:", line[:200])

    # 监控对局日志。
    deadline = time.time() + args.seconds + 120
    seen_stuck = 0
    last_size = -1
    last_growth = time.time()
    froze = False
    while time.time() < deadline:
        if game.poll() is not None:
            log("[driver] game exited (code=%s)" % game.returncode)
            break
        time.sleep(10)
        try:
            size = os.path.getsize(os.path.join(state_dir, "game.out"))
        except OSError:
            size = -1
        if size != last_size:
            last_size = size
            last_growth = time.time()
        elif time.time() - last_growth > 150 and not froze:
            # 日志 150s 没长但进程活着：模拟冻结/挂死。取一份 perf 快照留证。
            froze = True
            log("[driver] !! game log silent for %.0fs while process alive — probing perf"
                % (time.time() - last_growth))
            try:
                import json
                import socket
                with socket.create_connection(("127.0.0.1", PORT), timeout=20) as sock:
                    sock.sendall((json.dumps({"op": "perf"}) + "\n").encode())
                    buf = b""
                    while time.time() - last_growth < 40:
                        chunk = sock.recv(262144)
                        if not chunk:
                            break
                        buf += chunk
                        if buf.endswith(b"\n"):
                            break
                start = buf.find(b"{")
                end = buf.find(b"\n", start)
                perf = json.loads(buf[start:end].decode("utf-8", "replace"))
                log("[driver] perf: fps=%s physics_ms=%s process_ms=%s units=%s nodes=%s"
                    % (perf.get("fps"), perf.get("physics_ms"), perf.get("process_ms"),
                       perf.get("units"), perf.get("nodes")))
                with open(os.path.join(state_dir, "freeze_perf.json"), "w",
                          encoding="utf-8") as f:
                    json.dump(perf, f, ensure_ascii=False, indent=1)
            except Exception as exc:  # noqa: BLE001
                log("[driver] perf probe failed:", exc)
        try:
            with open(os.path.join(state_dir, "game.out"), "r", encoding="utf-8",
                      errors="replace") as f:
                text = f.read()
            seen_stuck = text.count("[STUCK]")
        except OSError:
            pass

    kill_runner()
    kill_game()
    game_log.close()

    log("[driver] done. stuck_events=%d log=%s" % (seen_stuck, game_log.name))
    return 0


if __name__ == "__main__":
    sys.exit(main())
