"""Launch G4 256 lake playtest and sample op=perf after match starts."""
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
        "nav_ms": sample.get("nav_ms"),
        "physics_objects": sample.get("physics_objects"),
        "physics_pairs": sample.get("physics_pairs"),
        "draw_calls": gov.get("draw_calls"),
        "draw_objects": sample.get("draw_objects"),
        "draw_primitives": sample.get("draw_primitives"),
        "nodes": sample.get("nodes"),
        "units": sample.get("units"),
        "nav_static_obstacles": sample.get("nav_static_obstacles"),
        "gpu": sample.get("gpu"),
        "physics_ticks": sample.get("physics_ticks"),
        "max_physics_steps": sample.get("max_physics_steps"),
        "sample_ms": sample.get("sample_ms"),
        "scale": gov.get("scale"),
        "large_map_lock": gov.get("large_map_lock"),
        "reason": gov.get("reason"),
    }


def worker_names(status: dict) -> list[str]:
    names = []
    for unit in status.get("units") or []:
        if not unit.get("mine"):
            continue
        ut = str(unit.get("unit_type") or "").lower()
        name = str(unit.get("name") or "")
        if "worker" in ut or "worker" in name.lower() or "工人" in name:
            names.append(name)
    return names


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    log_path = OUT / "godot.out"
    env = os.environ.copy()
    env["AIRTS_ADJ_AUTO_TAKEOVER"] = "0"
    cmd = [
        GODOT,
        "--path",
        PROJECT,
        "--position",
        "80,80",
        "--",
        "--debugport",
        str(PORT),
        "--no-adjutant",
        "--port",
        str(ENET_PORT),
        "--play-fog",
        "--play-map=" + MAP,
    ]
    log = log_path.open("w", encoding="utf-8")
    proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, env=env)
    print("PID", proc.pid, flush=True)
    samples = []
    try:
        match_ready = False
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
            print(
                "status match=",
                st.get("match"),
                "scene_keys=",
                list(st.keys())[:8],
                flush=True,
            )
            if st.get("match"):
                match_ready = True
                break
        if not match_ready:
            print("match never started", flush=True)
            return 2
        try:
            full = tcp_call({"op": "status"}, timeout=20)
            workers = worker_names(full)
            print("workers", workers, "unit_count", len(full.get("units") or []), flush=True)
            if workers:
                g = tcp_call({"op": "gather", "units": workers, "kind": "a"}, timeout=10)
                print("GATHER", json.dumps(g, ensure_ascii=False)[:500], flush=True)
            movers = [
                u.get("name")
                for u in (full.get("units") or [])
                if u.get("mine") and u.get("movement")
            ][:4]
            if movers:
                dest = [120.0, 120.0]
                units0 = (full.get("units") or [{}])[0]
                pos = units0.get("pos") or [0, 0, 0]
                dest = [float(pos[0]) + 18.0, float(pos[2]) + 18.0]
                mv = tcp_call({"op": "move", "units": movers, "dest": dest}, timeout=10)
                print("MOVE", json.dumps(mv, ensure_ascii=False)[:500], flush=True)
            vp = full.get("viewport_size") or [882, 993]
            click = {
                "op": "click",
                "x": float(vp[0]) - 144.0,
                "y": 150.0,
            }
            print("CLICK minimap", json.dumps(tcp_call(click, timeout=6), ensure_ascii=False)[:300], flush=True)
        except Exception as exc:
            print("command fail", exc, flush=True)
        for _ in range(24):
            try:
                perf = tcp_call({"op": "perf"}, timeout=6)
                row = compact_perf(perf)
                samples.append(row)
                print("PERF", json.dumps(row, ensure_ascii=False), flush=True)
            except Exception as exc:
                print("perf fail", exc, flush=True)
            time.sleep(2)
        try:
            shot = tcp_call({"op": "screenshot", "path": str(SHOT)}, timeout=20)
            print("SHOT", json.dumps(shot, ensure_ascii=False)[:400], flush=True)
        except Exception as exc:
            print("shot fail", exc, flush=True)
        (OUT / "perf_samples.json").write_text(
            json.dumps(samples, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        fps_vals = [float(s["fps"]) for s in samples if s.get("fps")]
        if fps_vals:
            print(
                "SUMMARY n=%d min=%.1f max=%.1f last=%.1f"
                % (len(fps_vals), min(fps_vals), max(fps_vals), fps_vals[-1]),
                flush=True,
            )
        return 0
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                proc.kill()


if __name__ == "__main__":
    raise SystemExit(main())
