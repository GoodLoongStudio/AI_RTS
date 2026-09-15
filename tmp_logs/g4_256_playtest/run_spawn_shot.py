"""Open G4 lake with fog, wait for camera/fog, screenshot the spawn view."""
from __future__ import annotations

import json
import os
import socket
import subprocess
import time
from pathlib import Path

PORT = 24791
ENET_PORT = 24691
MAP = "res://source/match/maps/generated/16-0-1ca6e21aa1/map_16-0-1ca6e21aa1.tscn"
GODOT = r"G:\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe"
PROJECT = r"G:\AIRTS\AI_RTS"
OUT = Path(r"G:\AIRTS\AI_RTS\tmp_logs\g4_256_playtest")
SHOT = OUT / "spawn_view.png"
LAKE_SHOT = OUT / "lake_view.png"
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
            if st.get("match"):
                print("match ready", flush=True)
                break
        else:
            print("match never started", flush=True)
            return 2
        time.sleep(3)
        for _wait in range(12):
            try:
                perf0 = tcp_call({"op": "perf"}, timeout=6)
            except Exception:
                time.sleep(1)
                continue
            fps0 = float(perf0.get("fps") or 0)
            print("wait fps", fps0, flush=True)
            if fps0 >= 40.0:
                break
            time.sleep(1)
        full = tcp_call({"op": "status"}, timeout=20)
        mine = [u for u in (full.get("units") or []) if u.get("mine")]
        print("mine_units", [(u.get("name"), u.get("pos"), u.get("unit_type")) for u in mine[:8]], flush=True)
        cam = (full.get("camera") or {})
        print("camera", json.dumps(cam, ensure_ascii=False)[:400], flush=True)
        shot = tcp_call({"op": "screenshot", "path": str(SHOT)}, timeout=20)
        print("SHOT", json.dumps(shot, ensure_ascii=False)[:300], flush=True)
        fog = tcp_call({"op": "fog", "enabled": False}, timeout=8)
        print("FOG_OFF", json.dumps(fog, ensure_ascii=False)[:200], flush=True)
        cam_move = tcp_call(
            {"op": "camera", "look_at": [128.0, 8.0, 128.0], "size": 48.0},
            timeout=8,
        )
        print("CAM", json.dumps(cam_move, ensure_ascii=False)[:300], flush=True)
        time.sleep(0.8)
        lake = tcp_call({"op": "screenshot", "path": str(LAKE_SHOT)}, timeout=20)
        print("LAKE", json.dumps(lake, ensure_ascii=False)[:300], flush=True)
        bridge = tcp_call(
            {"op": "camera", "look_at": [36.0, 1.3, 108.0], "size": 28.0},
            timeout=8,
        )
        print("BRIDGE_CAM", json.dumps(bridge, ensure_ascii=False)[:300], flush=True)
        time.sleep(0.8)
        bridge_shot = tcp_call(
            {"op": "screenshot", "path": str(OUT / "bridge_view.png")},
            timeout=20,
        )
        print("BRIDGE", json.dumps(bridge_shot, ensure_ascii=False)[:300], flush=True)
        perf = tcp_call({"op": "perf"}, timeout=6)
        print(
            "PERF fps=", perf.get("fps"),
            "physics_ms=", perf.get("physics_ms"),
            "process_ms=", perf.get("process_ms"),
            "units=", perf.get("units"),
            flush=True,
        )
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
