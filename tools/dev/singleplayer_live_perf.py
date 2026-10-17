"""Owned single-player session profiling without product or OS input changes."""

from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import threading
import time
import textwrap

import psutil

from match_instance import (Instance, allocate_ports, ensure_parent_lease,
                            is_pid_running, record_path, release_ports)

ROOT = Path(__file__).resolve().parents[2]
ENGINE = Path("G:/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64.exe")
FLAGS = 0x08000000
USER = ctypes.WinDLL("user32", use_last_error=True)
USER.GetForegroundWindow.restype = wintypes.HWND
USER.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
USER.GetWindowThreadProcessId.restype = wintypes.DWORD
USER.SetWindowPos.argtypes = [wintypes.HWND, wintypes.HWND, ctypes.c_int, ctypes.c_int,
                              ctypes.c_int, ctypes.c_int, wintypes.UINT]
USER.SetWindowPos.restype = wintypes.BOOL
USER.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
USER.GetWindowRect.restype = wintypes.BOOL
USER.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
USER.PostMessageW.restype = wintypes.BOOL
USER.IsIconic.argtypes = [wintypes.HWND]
USER.IsIconic.restype = wintypes.BOOL


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=True, indent=2), encoding="utf-8")


def bridge(port, command, params=None, timeout=15):
    request = {"id": str(time.time_ns()), "command": command, "params": params or {}}
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall((json.dumps(request) + "\n").encode())
        data = b""
        while b"\n" not in data:
            part = sock.recv(65536)
            if not part:
                raise RuntimeError("Bridge closed without a response")
            data += part
        result = json.loads(data.split(b"\n", 1)[0])
    if result.get("error"):
        raise RuntimeError(str(result))
    return result


def evaluate(port, code, timeout=15):
    # The bridge prefixes every line with a tab; normalize our nested indentation.
    lines = textwrap.dedent(code).strip("\n").splitlines()
    normalized = []
    for line in lines:
        spaces = len(line) - len(line.lstrip(" "))
        if spaces % 4:
            raise ValueError("GDScript snippet indentation must use four spaces")
        normalized.append("\t" * (spaces // 4) + line[spaces:])
    result = bridge(port, "eval", {"code": "\n".join(normalized)}, timeout)
    if result.get("result") is None:
        raise RuntimeError("Eval returned null, not verified execution")
    return result["result"]


def window_info(hwnd):
    rect = wintypes.RECT()
    USER.GetWindowRect(hwnd, ctypes.byref(rect))
    return {"foreground": USER.GetForegroundWindow() == hwnd,
            "minimized": bool(USER.IsIconic(hwnd)),
            "rect": [rect.left, rect.top, rect.right, rect.bottom]}


def find_window(pid):
    found = []
    callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def callback(hwnd, _):
        owner = wintypes.DWORD()
        USER.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == pid:
            rect = wintypes.RECT()
            USER.GetWindowRect(hwnd, ctypes.byref(rect))
            found.append(((rect.right - rect.left) * (rect.bottom - rect.top), hwnd))
        return True
    callback_fn = callback_type(callback)
    USER.EnumWindows.argtypes = [callback_type, wintypes.LPARAM]
    USER.EnumWindows.restype = wintypes.BOOL
    USER.EnumWindows(callback_fn, 0)
    return max(found)[1] if found else None


class Solo(Instance):
    def argv(self):
        return [str(ENGINE), "--path", str(ROOT), "--windowed", "--audio-driver", "Dummy",
                "--position", "-4000,-4000", "res://source/main-menu/Play.tscn", "--",
                "--port", str(self.ports["game"]),
                "--debugport", str(self.ports["client_dcs"])]

    def launch(self):
        os.makedirs(self.log_dir, exist_ok=True)
        os.makedirs(self.directory, exist_ok=True)
        ensure_parent_lease(self.directory)
        if Path(record_path(self.name, self.directory)).exists():
            raise RuntimeError("Existing instance record, refusing to overwrite")
        self._out = open(Path(self.log_dir) / "game.out.log", "x", encoding="utf-8")
        self._err = open(Path(self.log_dir) / "game.err.log", "x", encoding="utf-8")
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = 4  # SW_SHOWNOACTIVATE, console remains suppressed.
        self.process = subprocess.Popen(self.argv(), cwd=ROOT, env=self.env(),
                                        stdout=self._out, stderr=self._err,
                                        creationflags=FLAGS, startupinfo=startup)
        return self


FRAME_CODE = r'''
var tree = get_tree()
var scene = tree.current_scene
var main_vp = tree.root
var viewports: Array = [main_vp]
for vp in main_vp.find_children("*", "SubViewport", true, false):
    viewports.append(vp)
for vp in viewports:
    RenderingServer.viewport_set_measure_render_time(vp.get_viewport_rid(), true)
var info = {"pid": OS.get_process_id(), "engine_thread_id": OS.get_thread_caller_id(), "map": str(scene.map.scene_file_path), "max_fps": Engine.max_fps, "ticks": Engine.physics_ticks_per_second, "max_steps": Engine.max_physics_steps_per_frame, "time_scale": Engine.time_scale, "window_size": [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y], "vsync": DisplayServer.window_get_vsync_mode(), "render_method": RenderingServer.get_current_rendering_method(), "viewports": []}
for vp in viewports:
    info["viewports"].append({"path": str(vp.get_path()), "size": [vp.size.x, vp.size.y]})
var camera = main_vp.get_camera_3d()
if camera != null:
    info["camera"] = {"pos": [camera.global_position.x, camera.global_position.y, camera.global_position.z], "size": camera.size, "projection": camera.projection, "far": camera.far}
var buckets = load("res://source/match/PerfBuckets.gd")
var ai = load("res://source/match/players/simple-clairvoyant-ai/AiPerfStats.gd")
var mov = load("res://source/match/units/traits/Movement.gd")
var query_runtime = scene.get_node_or_null("WorldQueryRuntime")
var query_before = query_runtime.GetQueryPerfStats() if query_runtime != null and query_runtime.has_method("GetQueryPerfStats") else {"available": false}
var before_b = buckets.buckets.duplicate(true)
var before_n = buckets.bucket_n.duplicate(true)
var before_ai = ai.snapshot()
var before_mov = mov.agg_line()
var rows: Array = []
var snapshots: Array = []
var ai_prev = ai.snapshot()
var ai_events: Array = []
await RenderingServer.frame_post_draw
var start = Time.get_ticks_usec()
var last = start
var last_phys = Engine.get_physics_frames()
var initial_phys = last_phys
var next_snap = start
while Time.get_ticks_usec() - start < SECONDS * 1000000:
    await RenderingServer.frame_post_draw
    var now = Time.get_ticks_usec()
    var phys = Engine.get_physics_frames()
    var row: Array = [now - last, phys - last_phys]
    for vp in viewports:
        row.append(RenderingServer.viewport_get_measured_render_time_cpu(vp.get_viewport_rid()))
        row.append(RenderingServer.viewport_get_measured_render_time_gpu(vp.get_viewport_rid()))
    if CORRELATE:
        for key in ai._buckets:
            var slot = ai._buckets[key]
            var prev = ai_prev.get(key, {"calls": 0, "total_us": 0})
            if slot[0] != prev["calls"]:
                ai_events.append({"frame": rows.size(), "wall_us": now - start, "bucket": key, "calls": slot[0] - prev["calls"], "us": slot[1] - prev["total_us"]})
                ai_prev[key] = {"calls": slot[0], "total_us": slot[1]}
    row.append(tree.paused)
    row.append(scene.process_mode)
    rows.append(row)
    if now >= next_snap:
        next_snap = now + 1000000
        snapshots.append({"wall_us": now - start, "tree_paused": tree.paused, "scene_process_mode": scene.process_mode, "physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, "process_monitor_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, "nav_ms": Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0, "objects_drawn": Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME), "primitives": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME), "draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), "nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT), "memory_bytes": Performance.get_monitor(Performance.MEMORY_STATIC), "entities": tree.get_nodes_in_group("units").size(), "gpu": RenderingServer.get_video_adapter_name(), "governor": get_node("/root/PerformanceGovernor").stats()})
    row.append(Time.get_ticks_usec() - now)
    last = now
    last_phys = phys
for vp in viewports:
    RenderingServer.viewport_set_measure_render_time(vp.get_viewport_rid(), false)
var query_after = query_runtime.GetQueryPerfStats() if query_runtime != null and query_runtime.has_method("GetQueryPerfStats") else {"available": false}
return {"info": info, "elapsed_us": Time.get_ticks_usec() - start, "physics_steps": Engine.get_physics_frames() - initial_phys, "rows_columns": "frame_wall_us, physics_steps, cpu_ms/gpu_ms for each info.viewport, tree_paused, scene_process_mode, collector_us", "rows": rows, "snapshots": snapshots, "ai_events": ai_events, "query_before": query_before, "query_after": query_after, "buckets_before": before_b, "buckets_after": buckets.buckets.duplicate(true), "bucket_n_before": before_n, "bucket_n_after": buckets.bucket_n.duplicate(true), "ai_before": before_ai, "ai_after": ai.snapshot(), "movement_before": before_mov, "movement_after": mov.agg_line()}
'''


def quantiles(values):
    values = sorted(values)
    if not values:
        return {"available": False}
    def q(p):
        return values[min(len(values) - 1, int((len(values) - 1) * p))]
    return {"n": len(values), "mean": sum(values) / len(values),
            "p50": q(.5), "p95": q(.95), "p99": q(.99), "max": values[-1]}


def summarize(raw):
    rows = raw["rows"]
    wall = [r[0] / 1000 for r in rows]
    result = {"info": raw["info"], "frame_ms": quantiles(wall),
              "average_fps": len(rows) * 1e6 / sum(r[0] for r in rows),
              "hitches_over_33ms": sum(v > 33.333 for v in wall),
              "hitches_over_100ms": sum(v > 100 for v in wall),
              "engine_physics_tick_wall_ratio": raw["physics_steps"] / raw["info"]["ticks"] / (raw["elapsed_us"] / 1e6),
              "tree_paused_frames": sum(r[2 + 2 * len(raw["info"]["viewports"])] for r in rows),
              "collector_us": quantiles([r[-1] for r in rows]),
              "viewports": [], "buckets": {}, "ai": {},
              "snapshots": raw["snapshots"]}
    for i, vp in enumerate(raw["info"]["viewports"]):
        gpu = [r[3 + i * 2] for r in rows]
        result["viewports"].append({**vp, "cpu_ms": quantiles([r[2 + i * 2] for r in rows]),
                                   "gpu_ms": quantiles(gpu) if any(gpu) else {"available": False, "reason": "only zero values"}})
    for k, value in raw["buckets_after"].items():
        us = value - raw["buckets_before"].get(k, 0)
        calls = raw["bucket_n_after"].get(k, 0) - raw["bucket_n_before"].get(k, 0)
        result["buckets"][k] = {"total_ms": us / 1000, "calls": calls, "per_render_frame_ms": us / 1000 / len(rows), "per_call_ms": us / 1000 / calls if calls else None}
    for k, value in raw["ai_after"].items():
        before = raw["ai_before"].get(k, {})
        us = value["total_us"] - before.get("total_us", 0)
        calls = value["calls"] - before.get("calls", 0)
        result["ai"][k] = {"total_ms": us / 1000, "calls": calls, "per_render_frame_ms": us / 1000 / len(rows), "per_call_ms": us / 1000 / calls if calls else None}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True)
    parser.add_argument("--correlate-only", action="store_true")
    args = parser.parse_args()
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=False)
    ports = allocate_ports()
    game = Solo("client", out.name, ports, log_dir=str(out), directory=str(out / "instances"),
                env_extra={"GODOT_BRIDGE_PORT": str(ports["server_dcs"]), "AIRTS_AI_PERF_STATS": "1"})
    hashes = {}
    for name in ["project.godot", "source/PerformanceGovernor.gd", "source/match/maps/generated/GeneratedTerrain.gd", "source/match/units/traits/Movement.gd", "source/net/DebugControlServer.gd"]:
        hashes[name] = hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
    save(out / "source-before.json", hashes)
    stop = threading.Event()
    telemetry_thread = None
    gpu = None
    hwnd = None
    cleanup = {}
    try:
        game.launch()
        record = game.wait_controllable(90)
        identity = bridge(ports["server_dcs"], "get_instance_info")
        identity.pop("token", None)
        if identity.get("pid") != game.game_pid or identity.get("project_abs", "").rstrip("/") != ROOT.as_posix():
            raise RuntimeError("Instance identity mismatch")
        hwnd = find_window(game.game_pid)
        if not hwnd:
            raise RuntimeError("No owned game window")
        if not USER.SetWindowPos(hwnd, 1, -4000, -4000, 0, 0, 0x11):
            raise RuntimeError("Nonactivating window placement failed")
        window_pid = wintypes.DWORD()
        main_tid = USER.GetWindowThreadProcessId(hwnd, ctypes.byref(window_pid))
        info = {"identity": identity, "record": record, "argv": game.argv(), "window": window_info(hwnd), "main_win32_thread": main_tid, "started": datetime.now().astimezone().isoformat()}
        save(out / "identity.json", info)
        print(json.dumps(info), flush=True)
        if info["window"]["foreground"]:
            raise RuntimeError("Engine activated the owned window during startup; refusing a background performance run")
        started = evaluate(ports["server_dcs"], '''
var page = get_tree().current_scene
if not page.has_method("_on_start_button_pressed"):
    return {"error": "not Play page"}
for i in range(page._slot_selects.size()):
    var id = Constants.PlayerType.NONE
    if i == 0:
        id = Constants.PlayerType.HUMAN
    elif i == 1:
        id = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
    page._slot_selects[i].select(page._slot_selects[i].get_item_index(id))
var index = page._map_paths.find("res://source/match/maps/PlainAndSimple.tscn")
if index < 0:
    return {"error": "map not registered"}
page._map_select.select(index)
page._on_start_button_pressed()
return {"started": true, "map_index": index}
''')
        save(out / "start.json", started)
        if not started.get("started"):
            raise RuntimeError(str(started))
        deadline = time.monotonic() + 100
        while time.monotonic() < deadline:
            state = game.dcs({"op": "status", "lite": True}, timeout=5)
            if state.get("match") and state.get("counts", {}).get("mine", 0) > 0:
                break
            time.sleep(1)
        else:
            raise TimeoutError("Single-player Match did not become ready")
        # Scene transitions may recenter this window; one nonactivating placement.
        USER.SetWindowPos(hwnd, 1, -4000, -4000, 0, 0, 0x11)
        save(out / "status-start.json", state)
        print("Real single-player Match ready; warming up 10 seconds", flush=True)
        time.sleep(10)

        def telemetry():
            previous = {}
            last_time = time.perf_counter()
            with (out / "external.jsonl").open("x", encoding="utf-8") as handle:
                while not stop.is_set():
                    now = time.perf_counter()
                    processes = {}
                    for proc in psutil.process_iter(["pid", "name", "cpu_times"]):
                        try:
                            times = proc.info["cpu_times"]
                            if proc.pid != 0:
                                processes[proc.pid] = {"name": proc.info["name"], "cpu_s": times.user + times.system}
                        except (psutil.Error, AttributeError):
                            pass
                    costs = []
                    for pid, row in processes.items():
                        if pid in previous:
                            costs.append({"pid": pid, "name": row["name"], "core_percent": max(0, row["cpu_s"] - previous[pid]["cpu_s"]) * 100 / max(.001, now - last_time)})
                    costs.sort(key=lambda r: r["core_percent"], reverse=True)
                    try:
                        threads = [{"id": t.id, "cpu_s": t.user_time + t.system_time} for t in psutil.Process(game.game_pid).threads()]
                    except psutil.Error:
                        threads = []
                    handle.write(json.dumps({"monotonic_s": now, "threads": threads, "top_processes": costs[:10], "window": window_info(hwnd)}) + "\n")
                    handle.flush()
                    previous, last_time = processes, now
                    stop.wait(1)

        telemetry_thread = threading.Thread(target=telemetry, daemon=True)
        telemetry_thread.start()
        gpu_path = Path("C:/Windows/System32/nvidia-smi.exe")
        if gpu_path.exists():
            gpu_log = (out / "gpu.csv").open("x", encoding="utf-8")
            gpu = subprocess.Popen([str(gpu_path), "--query-gpu=timestamp,name,utilization.gpu,utilization.memory,clocks.gr,clocks.mem,power.draw,temperature.gpu", "--format=csv", "-l", "1"], stdout=gpu_log, stderr=subprocess.DEVNULL, creationflags=FLAGS)

        phases = []
        for phase in (("correlated",) if args.correlate_only else ("early", "detailed", "later")):
            if phase in ("detailed", "correlated"):
                evaluate(ports["server_dcs"], '''
var b = load("res://source/match/PerfBuckets.gd")
b.enabled = true
var m = load("res://source/match/units/traits/Movement.gd")
m._diag_cached = 1
return {"enabled": b.enabled, "movement_diag": m._diag_cached}
''')
            elif phase == "later":
                print("Waiting 25 seconds for normal AI development", flush=True)
                time.sleep(25)
            raw = evaluate(ports["server_dcs"], FRAME_CODE.replace("SECONDS", "30" if args.correlate_only else "25").replace("CORRELATE", "true" if args.correlate_only else "false"), timeout=45)
            raw["external_begin_monotonic_s"] = time.perf_counter() - raw["elapsed_us"] / 1e6
            save(out / ("raw-" + phase + ".json"), raw)
            summary = summarize(raw)
            phases.append({"phase": phase, **summary})
            save(out / "summary.json", phases)
            print(json.dumps({"phase": phase, "fps": summary["average_fps"], "frame_ms": summary["frame_ms"], "viewports": summary["viewports"], "buckets": summary["buckets"], "ai": summary["ai"], "entities": [s["entities"] for s in summary["snapshots"]]}), flush=True)
            save(out / ("dcs-" + phase + ".json"), game.dcs({"op": "perf"}, timeout=5))
        save(out / "status-end.json", game.dcs({"op": "status"}, timeout=5))
        evaluate(ports["server_dcs"], '''
load("res://source/match/PerfBuckets.gd").enabled = false
load("res://source/match/units/traits/Movement.gd")._diag_cached = 0
return {"profiling_restored": true}
''')
        print("Sampling complete", flush=True)
    finally:
        stop.set()
        if telemetry_thread:
            telemetry_thread.join(3)
        if gpu:
            gpu.terminate()
            gpu.wait(timeout=5)
            gpu_log.close()
        owned_pid = game.game_pid
        if hwnd and game.process and game.process.poll() is None:
            USER.PostMessageW(hwnd, 0x10, 0, 0)
            try:
                game.process.wait(timeout=8)
                cleanup["window_close"] = True
            except subprocess.TimeoutExpired:
                cleanup["window_close"] = False
        cleanup["stop_result"] = game.stop()
        cleanup["game_pid_alive"] = is_pid_running(owned_pid)
        cleanup["record_exists"] = Path(record_path(game.name, game.directory)).exists()
        cleanup["game_rc"] = game.process.poll() if game.process else None
        cleanup["cleanup_ok"] = not cleanup["game_pid_alive"] and not cleanup["record_exists"]
        release_ports(ports)
        ensure_parent_lease(game.directory).stop()
        save(out / "cleanup.json", cleanup)
        after = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in hashes}
        save(out / "source-after.json", after)
        print(json.dumps(cleanup), flush=True)


if __name__ == "__main__":
    main()
