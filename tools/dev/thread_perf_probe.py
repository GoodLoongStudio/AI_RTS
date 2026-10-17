#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Hidden-console thread/capacity probe. Kills only the process tree it starts."""
from __future__ import annotations

import argparse
import ctypes
import json
import os
import sys
import threading
import time
from ctypes import wintypes
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from match_instance import Instance, allocate_ports, godot_exe  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
OVERRIDE = ROOT / "override.cfg"
TH32CS_SNAPTHREAD = 0x00000004
THREAD_QUERY_LIMITED_INFORMATION = 0x0800


class FILETIME(ctypes.Structure):
    _fields_ = [("lo", wintypes.DWORD), ("hi", wintypes.DWORD)]


class THREADENTRY32(ctypes.Structure):
    _fields_ = [
        ("dwSize", wintypes.DWORD),
        ("cntUsage", wintypes.DWORD),
        ("th32ThreadID", wintypes.DWORD),
        ("th32OwnerProcessID", wintypes.DWORD),
        ("tpBasePri", ctypes.c_long),
        ("tpDeltaPri", ctypes.c_long),
        ("dwFlags", wintypes.DWORD),
    ]


kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)


def filetime_seconds(value: FILETIME) -> float:
    ticks = (int(value.hi) << 32) | int(value.lo)
    return ticks / 10_000_000.0


def thread_ids(process_id: int) -> list[int]:
    snapshot = kernel32.CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0)
    if snapshot == ctypes.c_void_p(-1).value or snapshot == -1:
        return []
    entry = THREADENTRY32()
    entry.dwSize = ctypes.sizeof(THREADENTRY32)
    found = []
    ok = kernel32.Thread32First(snapshot, ctypes.byref(entry))
    while ok:
        if int(entry.th32OwnerProcessID) == process_id:
            found.append(int(entry.th32ThreadID))
        ok = kernel32.Thread32Next(snapshot, ctypes.byref(entry))
    kernel32.CloseHandle(snapshot)
    return found


def thread_cpu(thread_id: int) -> float | None:
    handle = kernel32.OpenThread(THREAD_QUERY_LIMITED_INFORMATION, False, thread_id)
    if not handle:
        return None
    created, exited, kernel, user = FILETIME(), FILETIME(), FILETIME(), FILETIME()
    ok = kernel32.GetThreadTimes(
        handle, ctypes.byref(created), ctypes.byref(exited),
        ctypes.byref(kernel), ctypes.byref(user))
    kernel32.CloseHandle(handle)
    if not ok:
        return None
    return filetime_seconds(kernel) + filetime_seconds(user)


def snapshot(process_id: int) -> dict[int, float]:
    out = {}
    for thread_id in thread_ids(process_id):
        cpu = thread_cpu(thread_id)
        if cpu is not None:
            out[thread_id] = cpu
    return out


def process_ids_named_godot() -> list[int]:
    import subprocess
    out = subprocess.check_output(
        ["powershell", "-NoProfile", "-Command",
         "Get-Process | Where-Object { $_.ProcessName -like '*godot*' -or $_.ProcessName -like '*Godot*' } | Select-Object -ExpandProperty Id"],
        text=True, encoding="utf-8", errors="replace")
    return [int(line) for line in out.split() if line.strip().isdigit()]


def write_override(mode: str) -> None:
    if OVERRIDE.exists():
        raise RuntimeError("override.cfg already exists; refusing to replace it")
    if mode == "default":
        return
    if mode == "off":
        multiple, high = "false", "true"
    elif mode == "highpri-off":
        multiple, high = "true", "false"
    else:
        raise RuntimeError("unknown thread mode " + mode)
    OVERRIDE.write_text(
        "\n".join([
            "; temporary thread A/B for one probe process; deleted when that process exits",
            "[navigation]",
            "avoidance/thread_model/avoidance_use_multiple_threads=" + multiple,
            "avoidance/thread_model/avoidance_use_high_priority_threads=" + high,
            "",
        ]),
        encoding="utf-8",
    )


def remove_override() -> None:
    try:
        OVERRIDE.unlink()
    except FileNotFoundError:
        pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True)
    parser.add_argument("--count", type=int, default=100)
    parser.add_argument("--mode", choices=("spread", "dense"), default="spread")
    parser.add_argument("--seconds", type=float, default=12.0)
    parser.add_argument("--unlock", choices=("0", "1"), default="1")
    parser.add_argument("--diag", choices=("0", "1"), default="1")
    parser.add_argument("--threads", choices=("default", "off", "highpri-off"), default="default")
    parser.add_argument("--timeout", type=float, default=170.0)
    parser.add_argument("--exp", default="", help="Diagnostic-only probe experiment tag.")
    parser.add_argument("--allow-parallel", action="store_true")
    args = parser.parse_args()
    output = Path(args.out).resolve()
    output.mkdir(parents=True, exist_ok=True)
    others = process_ids_named_godot()
    (output / "preexisting-godot.json").write_text(
        json.dumps(others), encoding="utf-8")
    if others and not args.allow_parallel:
        print("REFUSING: other Godot processes are running:", others)
        return 4
    project_godot = (ROOT / "project.godot").read_bytes()
    write_override(args.threads)
    ports = allocate_ports()
    instance_dir = output / "instances"
    instance_dir.mkdir(parents=True, exist_ok=True)

    class Probe(Instance):
        def argv(self):
            return [
                godot_exe(), "--path", str(ROOT), "--audio-driver", "Dummy",
                "--position", "80,80", "--resolution", "1280x720",
                "res://tests/automated/_ThreadPerfProbe.tscn", "--",
                "--debugport", str(self.ports["client_dcs"]),
            ]

    env = {
        "AIRTS_TPERF_COUNT": str(args.count),
        "AIRTS_TPERF_MODE": args.mode,
        "AIRTS_TPERF_SECONDS": str(args.seconds),
        "AIRTS_TPERF_UNLOCK": args.unlock,
        "AIRTS_TPERF_OUT": output.as_posix(),
        "AIRTS_MOV_DIAG": "" if args.diag == "0" else "1",
        "AIRTS_TPERF_EXP": args.exp or os.environ.get("AIRTS_TPERF_EXP", ""),
        "AIRTS_INSTANCE_STRICT_DCS": "0",
    }
    probe = Probe("client", "tperf", ports, log_dir=str(output), env_extra=env,
                  directory=str(instance_dir))
    samples = []
    stop = threading.Event()

    def sampler():
        log_path = output / "tperf.out.log"
        started = None
        game_pid = 0
        main_tid = 0
        last = None
        while not stop.is_set():
            if log_path.exists():
                text = log_path.read_text(encoding="utf-8", errors="replace")
                if main_tid == 0 and "MAIN_TID=" in text:
                    for line in text.splitlines():
                        if "MAIN_TID=" in line:
                            main_tid = int(line.split("MAIN_TID=", 1)[1].strip())
                record = probe.record()
                game_pid = int(record.get("pid", 0) or game_pid)
                if started is None and "SAMPLE_START" in text and game_pid:
                    started = time.perf_counter()
                    last = snapshot(game_pid)
                elif started is not None and last is not None and "SAMPLE_END" not in text:
                    now = snapshot(game_pid)
                    deltas = []
                    for tid, value in now.items():
                        delta = value - last.get(tid, value)
                        if delta > 0.001:
                            deltas.append((tid, delta))
                    deltas.sort(key=lambda item: item[1], reverse=True)
                    cpu = sum(item[1] for item in deltas)
                    top = deltas[0][1] if deltas else 0.0
                    samples.append({
                        "t": round(time.perf_counter() - started, 3),
                        "busy_threads_gt_20ms": sum(1 for _tid, delta in deltas if delta > 0.02),
                        "busy_threads_gt_5ms": sum(1 for _tid, delta in deltas if delta > 0.005),
                        "cpu_s": round(cpu, 4),
                        "hottest_cpu_s": round(top, 4),
                        "other_cpu_s": round(cpu - top, 4),
                        "top_threads": [
                            {"tid": tid, "cpu_s": round(delta, 4)} for tid, delta in deltas[:6]
                        ],
                        "main_tid_godot": main_tid,
                        "game_pid": game_pid,
                    })
                    last = now
            stop.wait(1.0)

    thread = threading.Thread(target=sampler, daemon=True)
    rc = 1
    try:
        probe.launch()
        thread.start()
        deadline = time.monotonic() + args.timeout
        while probe.process.poll() is None:
            if time.monotonic() >= deadline:
                print("WATCHDOG timeout; killing only this probe tree")
                probe.stop()
                rc = 5
                break
            time.sleep(0.3)
        else:
            rc = int(probe.process.returncode or 0)
        stop.set()
        thread.join(timeout=3)
        log_path = output / "tperf.out.log"
        text = log_path.read_text(encoding="utf-8", errors="replace") if log_path.exists() else ""
        err_path = output / "tperf.err.log"
        err = err_path.read_text(encoding="utf-8", errors="replace") if err_path.exists() else ""
        main_tid = 0
        for line in text.splitlines():
            if "MAIN_TID=" in line:
                main_tid = int(line.split("MAIN_TID=", 1)[1].strip())
        game_pid = int(probe.record().get("pid", 0))
        # Process may already be gone; the 1s slices are the CPU evidence.
        payload = {
            "rc": rc,
            "threads_mode": args.threads,
            "count": args.count,
            "scenario": args.mode,
            "diag": args.diag,
            "unlock": args.unlock,
            "main_tid": main_tid,
            "game_pid": game_pid,
            "slices": samples,
            "forbidden": [line for line in (text + "\n" + err).splitlines()
                          if line.startswith("SCRIPT ERROR") or line.startswith("Parse Error")
                          or line.startswith("ERROR:")],
        }
        if samples:
            busy = [row.get("busy_threads_gt_20ms", row.get("busy_threads", 0)) for row in samples]
            payload["busy_threads_p50"] = sorted(busy)[len(busy) // 2]
            payload["busy_threads_max"] = max(busy)
            payload["slice_cpu_sum_s"] = round(sum(row["cpu_s"] for row in samples), 4)
            if "hottest_cpu_s" in samples[0]:
                payload["hottest_cpu_sum_s"] = round(sum(row["hottest_cpu_s"] for row in samples), 4)
                payload["other_cpu_sum_s"] = round(sum(row["other_cpu_s"] for row in samples), 4)
        (output / "thread-slices.json").write_text(
            json.dumps(payload, indent=2), encoding="utf-8")
        print("probe rc", rc, "slices", len(samples), "out", output)
        return rc
    finally:
        stop.set()
        if probe.process is not None and probe.process.poll() is None:
            probe.stop()
        else:
            probe.stop()
        remove_override()
        after = (ROOT / "project.godot").read_bytes()
        if after != project_godot:
            print("WARNING: project.godot bytes changed during the probe")
        else:
            print("project.godot unchanged")
        if OVERRIDE.exists():
            print("WARNING: override.cfg still present")


if __name__ == "__main__":
    raise SystemExit(main())
