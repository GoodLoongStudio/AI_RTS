"""Re-open G4 lake after production-deploy fix; sample long enough to catch the 10s cliff."""
from __future__ import annotations

import json
import os
import socket
import subprocess
import time
from datetime import datetime
from pathlib import Path

PORT = 24791
ENET_PORT = 24691
MAP = "res://source/match/maps/generated/16-0-1ca6e21aa1/map_16-0-1ca6e21aa1.tscn"
GODOT = r"G:\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe"
PROJECT = r"G:\AIRTS\AI_RTS"
OUT = Path(r"G:\AIRTS\AI_RTS\tmp_logs\g4_256_playtest")
SHOT = OUT / "match.png"
PIDFILE = OUT / "godot.pid"


def tcp_call(payload: dict, timeout: float = 8.0) -> dict:
    with socket.create_connection(("127.0.0.1", PORT), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall((json.dumps(payload) + "\n").encode("utf-8"))
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
        raise TimeoutError("no response op=%s" % payload.get("op"))


def compact_perf(sample: dict) -> dict:
    gov = sample.get("governor") or {}
    return {
        "t": datetime.now().strftime("%H:%M:%S"),
        "fps": sample.get("fps"),
        "process_ms": sample.get("process_ms"),
        "physics_ms": sample.get("physics_ms"),
        "physics_script_ms": sample.get("physics_script_ms"),
        "nav_ms": sample.get("nav_ms"),
        "units": sample.get("units"),
        "physics_nodes": sample.get("physics_nodes"),
        "scale": gov.get("scale"),
        "reason": gov.get("reason"),
    }


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    old = PIDFILE.read_text(encoding="utf-8").strip() if PIDFILE.exists() else ""
    if old.isdigit():
        subprocess.run(["taskkill", "/PID", old, "/T", "/F"], capture_output=True)
        time.sleep(1)
    env = os.environ.copy()
    env["AIRTS_ADJ_AUTO_TAKEOVER"] = "0"
    cmd = [
        GODOT, "--path", PROJECT, "--position", "80,80", "--",
        "--debugport", str(PORT), "--no-adjutant", "--port", str(ENET_PORT),
        "--play-fog", "--play-map=" + MAP,
    ]
    log = (OUT / "godot.out").open("w", encoding="utf-8")
    proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, env=env)
    PIDFILE.write_text(str(proc.pid), encoding="utf-8")
    print("PID", proc.pid, flush=True)
    samples = []
    try:
        for i in range(180):
            time.sleep(1)
            if proc.poll() is not None:
                print("Godot exited", proc.returncode, flush=True)
                return 1
            try:
                st = tcp_call({"op": "status", "lite": True}, timeout=3)
            except Exception as exc:
                if i % 5 == 0:
                    print("wait dcs", exc, flush=True)
                continue
            print("status match=", st.get("match"), flush=True)
            if st.get("match"):
                break
        else:
            print("match never started", flush=True)
            return 2
        full = tcp_call({"op": "status"}, timeout=20)
        workers = [
            u.get("name") for u in (full.get("units") or [])
            if u.get("mine") and ("worker" in str(u.get("unit_type") or "").lower() or "worker" in str(u.get("name") or "").lower())
        ]
        print("workers", workers, flush=True)
        if workers:
            print("GATHER", json.dumps(tcp_call({"op": "gather", "units": workers, "kind": "a"}, timeout=10), ensure_ascii=False)[:300], flush=True)
        movers = [u.get("name") for u in (full.get("units") or []) if u.get("mine") and u.get("movement")][:4]
        if movers:
            pos = (full.get("units") or [{}])[0].get("pos") or [0, 0, 0]
            tcp_call({"op": "move", "units": movers, "dest": [float(pos[0]) + 18.0, float(pos[2]) + 18.0]}, timeout=10)
        vp = full.get("viewport_size") or [882, 993]
        tcp_call({"op": "click", "x": float(vp[0]) - 144.0, "y": 150.0}, timeout=6)
        for _ in range(28):
            try:
                row = compact_perf(tcp_call({"op": "perf"}, timeout=6))
                samples.append(row)
                print("PERF", json.dumps(row, ensure_ascii=False), flush=True)
            except Exception as exc:
                print("perf fail", exc, flush=True)
            time.sleep(2)
        try:
            print("SHOT", json.dumps(tcp_call({"op": "screenshot", "path": str(SHOT)}, timeout=20), ensure_ascii=False)[:200], flush=True)
        except Exception as exc:
            print("shot fail", exc, flush=True)
        (OUT / "perf_samples.json").write_text(json.dumps(samples, ensure_ascii=False, indent=2), encoding="utf-8")
        late = [s for s in samples[6:] if s.get("fps")]
        fps_vals = [float(s["fps"]) for s in late]
        phys = [float(s["physics_ms"] or 0) for s in late]
        if fps_vals:
            print(
                "LATE n=%d min_fps=%.1f max_fps=%.1f last=%.1f max_physics=%.1f keep_pid=%s"
                % (len(fps_vals), min(fps_vals), max(fps_vals), fps_vals[-1], max(phys) if phys else -1, proc.pid),
                flush=True,
            )
            if min(fps_vals) < 40.0 or (phys and max(phys) > 20.0):
                print("FAIL smoothness", flush=True)
                return 3
            print("PASS smoothness", flush=True)
        return 0
    except Exception:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                proc.kill()
        raise


if __name__ == "__main__":
    raise SystemExit(main())
