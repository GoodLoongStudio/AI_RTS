# -*- coding: utf-8 -*-
"""联机双进程冒烟司机：自动清场→起服→等端口→起客户端→轮询结果→失败重试。

在私有副本工程（ai_rts_smoke）里跑，避开并行会话对主工程的工作树/进程争抢。
成功判据：冒烟客户端把 5 张 *_overview.png 无关——本脚本只认
临时文件夹\\联机冒烟\\smoke_client.log 末尾出现 SMOKE_OK。
"""
import os
import subprocess
import shutil
import time
from pathlib import Path

EXE = r"G:\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe"
PROJ = r"G:\AIRTS\临时文件夹\联机冒烟\ai_rts_smoke"
SMOKE_LOG = Path(r"G:\AIRTS\临时文件夹\联机冒烟\smoke_client.log")
PORT = 24599
ATTEMPTS = 8
CLIENT_TIMEOUT = 420


def kill_godot():
    subprocess.run(
        ["powershell", "-Command",
         "Get-Process | Where-Object { $_.ProcessName -like '*Godot*' } | "
         "Stop-Process -Force -ErrorAction SilentlyContinue"],
        capture_output=True)
    time.sleep(2)


def wait_port_free(timeout=20):
    end = time.time() + timeout
    while time.time() < end:
        out = subprocess.run(["netstat", "-ano"], capture_output=True, text=True).stdout
        if "24599" not in out:
            return True
        time.sleep(2)
    return False


def wait_port_bound(timeout=90):
    end = time.time() + timeout
    while time.time() < end:
        out = subprocess.run(["netstat", "-ano"], capture_output=True, text=True).stdout
        if "24599" in out:
            return True
        time.sleep(2)
    return False


def smoke_client_once() -> str:
    """跑一次冒烟客户端，返回 SMOKE_OK / SMOKE_FAIL:<原因> / SMOKE_TIMEOUT"""
    if SMOKE_LOG.exists():
        os.remove(SMOKE_LOG)
    proc = subprocess.Popen(
        [EXE, "--headless", "--path", PROJ,
         "res://source/main-menu/Online.tscn", "--",
         "--smokeclient", "--smokeport", str(PORT)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    end = time.time() + CLIENT_TIMEOUT
    while time.time() < end:
        time.sleep(5)
        if SMOKE_LOG.exists():
            text = SMOKE_LOG.read_text(encoding="utf-8", errors="ignore")
            if "SMOKE_OK" in text:
                proc.kill()
                return "SMOKE_OK"
            if "SMOKE_FAIL" in text:
                reason = [l for l in text.splitlines() if "SMOKE_FAIL" in l][-1]
                proc.kill()
                return "SMOKE_FAIL:" + reason.strip()
    proc.kill()
    return "SMOKE_TIMEOUT"


def main():
    for attempt in range(1, ATTEMPTS + 1):
        print(f"=== attempt {attempt}/{ATTEMPTS} ===", flush=True)
        kill_godot()
        if not wait_port_free():
            print("port still busy, retry", flush=True)
            continue
        server = subprocess.Popen(
            [EXE, "--headless", "--path", PROJ, "--", "--server", "--port", str(PORT)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if not wait_port_bound():
            print("server failed to bind, retry", flush=True)
            kill_godot()
            continue
        print("server bound, launching smoke client", flush=True)
        result = smoke_client_once()
        print(result, flush=True)
        kill_godot()
        if result == "SMOKE_OK":
            print("SMOKE_ACCEPTED — 双进程联机验收通过", flush=True)
            return 0
        time.sleep(10)
    print("ALL ATTEMPTS EXHAUSTED", flush=True)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
