"""G4 对局实时监测。

优先读本机 DebugControlServer（24579），没有调试口时改读：
1) user://g4_live_perf.json（PerformanceGovernor 每 2 秒写）
2) 最新 Godot 日志里的 G4PERF / LARGE_MAP / [PERF]
3) 「Open RTS」进程的 CPU / 内存，避免完全盲看

用法：
  python tools/g4_perf_monitor.py
"""
from __future__ import annotations

import argparse
import json
import socket
import time
from datetime import datetime
from pathlib import Path

DEFAULT_PORT = 24579
LOG_PATH = Path(r"G:\AIRTS\tmp_logs\g4_perf_monitor.log")
GODOT_LOG_DIR = Path(r"C:\Users\Administrator\AppData\Roaming\Godot\app_userdata\Open RTS\logs")
LIVE_PERF_PATH = Path(
    r"C:\Users\Administrator\AppData\Roaming\Godot\app_userdata\Open RTS\g4_live_perf.json"
)
INTERESTING = (
    "G4PERF",
    "LARGE_MAP",
    "large_map_lock",
    "fog_runtime",
    "NAVDBG",
    "[PERF]",
    "TERRAIN",
)


def tcp_call(port: int, payload: dict, timeout: float = 3.0) -> dict:
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall((json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8"))
        buffer = b""
        deadline = time.time() + timeout
        while time.time() < deadline:
            chunk = sock.recv(65536)
            if not chunk:
                break
            buffer += chunk
            start = buffer.find(b"{")
            end = buffer.find(b"\n", start)
            if start >= 0 and end > start:
                return json.loads(buffer[start:end].decode("utf-8", errors="replace"))
        raise TimeoutError("no response for op=%s" % payload.get("op"))


def classify(fps: float, process_ms: float, physics_ms: float) -> str:
    if fps <= 2 or process_ms >= 400 or physics_ms >= 400:
        return "ALERT"
    if fps < 20 or process_ms >= 50 or physics_ms >= 50:
        return "WARN"
    return "OK"


def now_hms() -> str:
    return datetime.now().strftime("%H:%M:%S")


def emit(kind: str, text: str) -> str:
    line = f"[{now_hms()}] {kind} {text}"
    print(line, flush=True)
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with LOG_PATH.open("a", encoding="utf-8") as handle:
        handle.write(line + "\n")
    return line


def latest_godot_log() -> Path | None:
    if not GODOT_LOG_DIR.exists():
        return None
    files = sorted(GODOT_LOG_DIR.glob("godot*.log"), key=lambda p: p.stat().st_mtime, reverse=True)
    return files[0] if files else None


def read_live_perf() -> dict | None:
    if not LIVE_PERF_PATH.exists():
        return None
    age = time.time() - LIVE_PERF_PATH.stat().st_mtime
    if age > 8:
        return None
    try:
        return json.loads(LIVE_PERF_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def sample_game_process() -> str | None:
    try:
        import subprocess

        raw = subprocess.check_output(
            [
                "powershell",
                "-NoProfile",
                "-Command",
                (
                    "Get-Process | Where-Object { $_.MainWindowTitle -like '*Open RTS*' } | "
                    "Select-Object -First 1 Id, CPU, WorkingSet64, MainWindowTitle | "
                    "ConvertTo-Json -Compress"
                ),
            ],
            text=True,
            timeout=5,
        ).strip()
        if not raw:
            return None
        data = json.loads(raw)
        mb = int(data.get("WorkingSet64") or 0) / 1048576.0
        return (
            f"pid={data.get('Id')} cpu_sec={data.get('CPU')} mem={mb:.0f}MB "
            f"title={data.get('MainWindowTitle')}"
        )
    except Exception:
        return None


def follow_log(path: Path, offset: int) -> int:
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            handle.seek(offset)
            for line in handle:
                text = line.strip()
                if any(token in text for token in INTERESTING):
                    emit("LOG", text)
            return handle.tell()
    except OSError:
        return offset


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--interval", type=float, default=2.0)
    args = parser.parse_args()

    emit("WATCH", f"port={args.port} interval={args.interval}s log={LOG_PATH}")
    log_file = latest_godot_log()
    log_offset = log_file.stat().st_size if log_file and log_file.exists() else 0
    last_match = None
    last_lock = None
    while True:
        if log_file is None or not log_file.exists():
            log_file = latest_godot_log()
            log_offset = 0
        if log_file is not None:
            log_offset = follow_log(log_file, log_offset)

        dcs = None
        try:
            perf = tcp_call(args.port, {"op": "perf"})
            if perf.get("error") == "no match scene":
                status = tcp_call(args.port, {"op": "status", "lite": True})
                dcs = {"perf": {}, "status": status, "in_match": False}
            else:
                status = tcp_call(args.port, {"op": "status", "lite": True})
                dcs = {
                    "perf": perf,
                    "status": status,
                    "in_match": bool(status.get("match")),
                }
        except OSError:
            dcs = None
        except Exception as exc:
            emit("WAIT", f"调试口读失败：{exc}")
            dcs = None

        live = read_live_perf()
        if dcs is not None:
            in_match = bool(dcs["in_match"])
            perf = dcs["perf"]
            status = dcs["status"]
            fps = float(perf.get("fps") or 0)
            process_ms = float(perf.get("process_ms") or 0)
            physics_ms = float(perf.get("physics_ms") or 0)
            gov = perf.get("governor") if isinstance(perf.get("governor"), dict) else {}
            lock = bool(gov.get("large_map_lock"))
            if in_match != last_match:
                emit(
                    "MATCH" if in_match else "WAIT",
                    f"{'已进对局' if in_match else '还在大厅'} match_id={status.get('match_id')}",
                )
                last_match = in_match
            if lock != last_lock:
                emit("LOCK", f"large_map_lock={lock} reason={gov.get('reason')}")
                last_lock = lock
            if in_match:
                emit(
                    classify(fps, process_ms, physics_ms),
                    (
                        f"FPS={fps:.0f} cpu={process_ms:.1f}ms phy={physics_ms:.1f}ms "
                        f"units={perf.get('units')} nodes={perf.get('nodes')} "
                        f"lock={lock} tier={gov.get('tier_name')} reason={gov.get('reason')}"
                    ),
                )
            else:
                emit("WAIT", f"调试口在，大厅中 FPS={fps:.0f}")
        elif live:
            fps = float(live.get("fps") or 0)
            cpu_ms = float(live.get("cpu_ms") or 0)
            lock = bool(live.get("large_map_lock"))
            scene = str(live.get("scene") or "")
            if lock != last_lock:
                emit("LOCK", f"large_map_lock={lock} scene={scene} reason={live.get('reason')}")
                last_lock = lock
            in_match = scene.lower().startswith("match") or "match" in scene.lower()
            if in_match != last_match:
                emit("MATCH" if in_match else "WAIT", f"live_perf scene={scene}")
                last_match = in_match
            emit(
                classify(fps, cpu_ms, 0.0),
                (
                    f"FPS={fps:.0f} cpu={cpu_ms:.1f}ms units={live.get('units')} "
                    f"lock={lock} tier={live.get('tier_name')} scene={scene} "
                    f"reason={live.get('reason')}"
                ),
            )
        else:
            proc = sample_game_process()
            if proc:
                emit("WAIT", f"无调试口，进程还在：{proc}。进 G4 或 F5 重开后才能读到帧率")
            else:
                emit("WAIT", "没找到 Open RTS 窗口，也没有调试口")
        time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(main())
