"""Start G4 256 lake, keep the window alive, sample perf, then A/B isolate physics nodes."""
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
        "physics_objects": sample.get("physics_objects"),
        "physics_pairs": sample.get("physics_pairs"),
        "physics_2d_objects": sample.get("physics_2d_objects"),
        "physics_2d_pairs": sample.get("physics_2d_pairs"),
        "physics_nodes": sample.get("physics_nodes"),
        "draw_calls": gov.get("draw_calls"),
        "draw_primitives": sample.get("draw_primitives"),
        "nodes": sample.get("nodes"),
        "units": sample.get("units"),
        "nav_static_obstacles": sample.get("nav_static_obstacles"),
        "gpu": sample.get("gpu"),
        "physics_ticks": sample.get("physics_ticks"),
        "max_physics_steps": sample.get("max_physics_steps"),
        "scale": gov.get("scale"),
        "reason": gov.get("reason"),
    }


def sample_n(n: int, gap: float, tag: str) -> list[dict]:
    rows = []
    for _ in range(n):
        try:
            row = compact_perf(tcp_call({"op": "perf"}, timeout=6))
            row["tag"] = tag
            rows.append(row)
            print("PERF", tag, json.dumps(row, ensure_ascii=False), flush=True)
        except Exception as exc:
            print("perf fail", tag, exc, flush=True)
        time.sleep(gap)
    return rows


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


def wait_match(proc: subprocess.Popen) -> dict:
    for i in range(180):
        time.sleep(1)
        if proc.poll() is not None:
            raise RuntimeError("Godot exited %s" % proc.returncode)
        try:
            st = tcp_call({"op": "status", "lite": True}, timeout=3)
        except Exception as exc:
            if i % 5 == 0:
                print("wait dcs", exc, flush=True)
            continue
        print("status match=", st.get("match"), flush=True)
        if st.get("match"):
            return st
    raise RuntimeError("match never started")


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
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
    log = (OUT / "godot.out").open("w", encoding="utf-8")
    proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, env=env)
    PIDFILE.write_text(str(proc.pid), encoding="utf-8")
    print("PID", proc.pid, flush=True)
    samples: list[dict] = []
    try:
        wait_match(proc)
        full = tcp_call({"op": "status"}, timeout=20)
        workers = worker_names(full)
        print("workers", workers, "unit_count", len(full.get("units") or []), flush=True)
        if workers:
            print("GATHER", json.dumps(tcp_call({"op": "gather", "units": workers, "kind": "a"}, timeout=10), ensure_ascii=False)[:400], flush=True)
        movers = [
            u.get("name")
            for u in (full.get("units") or [])
            if u.get("mine") and u.get("movement")
        ][:4]
        if movers:
            pos = (full.get("units") or [{}])[0].get("pos") or [0, 0, 0]
            dest = [float(pos[0]) + 18.0, float(pos[2]) + 18.0]
            print("MOVE", json.dumps(tcp_call({"op": "move", "units": movers, "dest": dest}, timeout=10), ensure_ascii=False)[:400], flush=True)
        vp = full.get("viewport_size") or [882, 993]
        print("CLICK", json.dumps(tcp_call({"op": "click", "x": float(vp[0]) - 144.0, "y": 150.0}, timeout=6), ensure_ascii=False)[:200], flush=True)

        samples += sample_n(8, 2.0, "baseline")
        hot = [s for s in samples if (s.get("physics_ms") or 0) >= 20]
        if hot:
            print("ISOLATE start physics_ms hot", flush=True)
            for node_name in ["CommandRuntime", "ProductionRuntime", "FogOfWar", "NetSync"]:
                iso = tcp_call({"op": "physics_isolate", "nodes": [node_name], "enabled": False}, timeout=6)
                print("ISOLATE off", node_name, json.dumps(iso, ensure_ascii=False)[:300], flush=True)
                samples += sample_n(3, 1.5, "off_" + node_name)
                on = tcp_call({"op": "physics_isolate", "nodes": [node_name], "enabled": True}, timeout=6)
                print("ISOLATE on", node_name, json.dumps(on, ensure_ascii=False)[:200], flush=True)
            mv = tcp_call({"op": "physics_isolate", "movements": True, "enabled": False}, timeout=6)
            print("ISOLATE off movements", json.dumps(mv, ensure_ascii=False)[:300], flush=True)
            samples += sample_n(3, 1.5, "off_movements")
            tcp_call({"op": "physics_isolate", "movements": True, "enabled": True}, timeout=6)
        else:
            print("physics stayed low; extra settle samples", flush=True)
            samples += sample_n(8, 2.0, "settle")

        try:
            print("SHOT", json.dumps(tcp_call({"op": "screenshot", "path": str(SHOT)}, timeout=20), ensure_ascii=False)[:300], flush=True)
        except Exception as exc:
            print("shot fail", exc, flush=True)
        (OUT / "perf_samples.json").write_text(
            json.dumps(samples, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        fps_vals = [float(s["fps"]) for s in samples if s.get("fps")]
        if fps_vals:
            print(
                "SUMMARY n=%d min=%.1f max=%.1f last=%.1f keep_pid=%s"
                % (len(fps_vals), min(fps_vals), max(fps_vals), fps_vals[-1], proc.pid),
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
