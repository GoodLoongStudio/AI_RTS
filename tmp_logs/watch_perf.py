"""Background live-match sampler. Writes JSONL and prints DROP when FPS collapses."""
from __future__ import annotations

import json
import socket
import time
from datetime import datetime
from pathlib import Path

PORTS = (24579, 24568)
OUT = Path(__file__).with_name("perf_watch.jsonl")
LIVE_FILE = Path.home() / "AppData/Roaming/Godot/app_userdata/Open RTS/g4_live_perf.json"
INTERVAL_S = 2.0
DROP_FPS = 20.0
SMOOTH_FPS = 35.0


def query_perf() -> tuple[int, dict | None, str]:
    last_err = ""
    for port in PORTS:
        try:
            sock = socket.create_connection(("127.0.0.1", port), 1.5)
            sock.sendall(b'{"op":"perf"}\n')
            sock.settimeout(4)
            data = b""
            while True:
                try:
                    chunk = sock.recv(65536)
                except TimeoutError:
                    break
                if not chunk:
                    break
                data += chunk
                if b"\n" in data:
                    break
            sock.close()
            text = data.decode("utf-8", errors="replace").split("\n", 1)[0]
            payload = json.loads(text)
            if isinstance(payload, dict) and payload.get("ok"):
                return port, payload, ""
            last_err = f"port {port} bad payload"
        except Exception as exc:
            last_err = f"port {port} {exc}"
    return 0, None, last_err


def read_live_file() -> dict | None:
    try:
        if not LIVE_FILE.exists():
            return None
        payload = json.loads(LIVE_FILE.read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            return None
        return {
            "ok": True,
            "fps": payload.get("fps"),
            "process_ms": payload.get("cpu_ms"),
            "physics_ms": None,
            "nav_ms": None,
            "nav_static_obstacles": None,
            "physics_objects": None,
            "draw_primitives": None,
            "nodes": None,
            "objects": None,
            "memory_mb": None,
            "units": payload.get("units_all", payload.get("units")),
            "copies": None,
            "gpu": None,
            "physics_ticks": None,
            "governor": payload,
            "source": "file",
        }
    except Exception:
        return None


def row(sample: dict) -> dict:
    gov = sample.get("governor") or {}
    return {
        "t": datetime.now().strftime("%H:%M:%S"),
        "fps": sample.get("fps"),
        "process_ms": sample.get("process_ms"),
        "physics_ms": sample.get("physics_ms"),
        "nav_ms": sample.get("nav_ms"),
        "nav_static_obstacles": sample.get("nav_static_obstacles"),
        "physics_objects": sample.get("physics_objects"),
        "draw_calls": gov.get("draw_calls"),
        "draw_primitives": sample.get("draw_primitives"),
        "nodes": sample.get("nodes"),
        "objects": sample.get("objects"),
        "memory_mb": sample.get("memory_mb"),
        "units": sample.get("units"),
        "copies": sample.get("copies"),
        "gpu": sample.get("gpu"),
        "physics_ticks": sample.get("physics_ticks"),
        "scale": gov.get("scale"),
        "reason": gov.get("reason"),
        "large_map_lock": gov.get("large_map_lock"),
    }


def main() -> None:
    print("WATCH start", flush=True)
    seen_smooth = False
    last_fps = None
    misses = 0
    while True:
        port, sample, err = query_perf()
        if sample is None:
            sample = read_live_file()
            port = 0
        if sample is None:
            misses += 1
            print(f"WATCH wait {err}", flush=True)
            time.sleep(INTERVAL_S)
            continue
        if misses or last_fps is None:
            print("WATCH live connected", flush=True)
        misses = 0
        compact = row(sample)
        compact["port"] = port
        compact["source"] = sample.get("source", "tcp")
        OUT.open("a", encoding="utf-8").write(json.dumps(compact, ensure_ascii=False) + "\n")
        fps = float(compact.get("fps") or 0.0)
        line = (
            f"WATCH {compact['t']} fps={compact['fps']} "
            f"proc={compact['process_ms']} phys={compact['physics_ms']} "
            f"nav={compact['nav_ms']} obst={compact['nav_static_obstacles']} "
            f"nodes={compact['nodes']} obj={compact['objects']} "
            f"units={compact['units']} copies={compact['copies']} "
            f"prim={compact['draw_primitives']} gpu={compact['gpu']}"
        )
        print(line, flush=True)
        if fps >= SMOOTH_FPS:
            seen_smooth = True
        if seen_smooth and fps > 0 and fps <= DROP_FPS:
            print(
                f"DROP fps {last_fps} -> {fps} proc={compact['process_ms']} "
                f"phys={compact['physics_ms']} obst={compact['nav_static_obstacles']} "
                f"nodes={compact['nodes']} obj={compact['objects']} copies={compact['copies']}",
                flush=True,
            )
            seen_smooth = False
        last_fps = fps
        time.sleep(INTERVAL_S)


if __name__ == "__main__":
    main()
