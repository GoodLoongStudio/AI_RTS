"""Temporary owned Godot menu/window recording smoke controller (localhost only)."""

import ctypes
from ctypes import wintypes
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
from pathlib import Path
import subprocess
import sys
import time

import cv2

from match_instance import Instance, allocate_ports, ensure_parent_lease, release_ports, tcp_call
from record_playtest import WindowCapture, evidence_path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "agent" / "runs" / ("game-video-smoke-" + datetime.now().strftime("%Y%m%d-%H%M%S"))
ENGINE = "G:/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64.exe"


class MenuInstance(Instance):
    def argv(self):
        return [ENGINE, "--path", str(ROOT), "--windowed", "--audio-driver", "Dummy",
                "--resolution", "1280x720",
                "--position", "-4000,-4000", "--log-file", str(OUT / "godot.log"),
                "--", "--debugport", str(self.ports["client_dcs"])]


def main():
    OUT.mkdir(parents=True)
    ports = allocate_ports()
    lease = ensure_parent_lease(str(OUT / "instances"))
    game = MenuInstance("client", OUT.name, ports, log_dir=str(OUT), directory=str(OUT / "instances"))
    recorder_jobs = []
    events = OUT / "events"
    events.mkdir()
    event_number = 0
    stop = False
    window = None

    def event(payload, response):
        nonlocal event_number
        event_number += 1
        row = {"utc": datetime.now().astimezone().isoformat(),
               "monotonic_s": time.perf_counter(), "request": payload, "response": response}
        (events / f"event-{event_number:04d}.json").write_text(json.dumps(row, ensure_ascii=True), encoding="utf-8")

    def process(payload):
        nonlocal stop
        op = payload["op"]
        if op == "dcs":
            if payload["payload"].get("op") in ("click", "drag"):
                raise RuntimeError("Mouse synthesis disabled: may warp user cursor")
            return tcp_call(game.dcs_port, payload["payload"], timeout=4)
        if op == "image":
            path = evidence_path(str(OUT / payload["name"]))
            if path.exists():
                raise ValueError("Image exists")
            frame, foreground = window.grab()
            if not cv2.imwrite(str(path), frame):
                raise RuntimeError("Image write failed")
            return {"path": str(path), "foreground": foreground}
        if op in ("input", "focus"):
            raise RuntimeError("OS input/focus disabled while user uses computer")
        if op == "background":
            window.check()
            user = window.user
            user.SetWindowPos.argtypes = [wintypes.HWND, wintypes.HWND, ctypes.c_int,
                                          ctypes.c_int, ctypes.c_int, ctypes.c_int, wintypes.UINT]
            user.SetWindowPos.restype = wintypes.BOOL
            if not user.SetWindowPos(window.hwnd, 1, -4000, -4000, 0, 0, 0x11):
                raise RuntimeError("Non-activating background placement failed")
            return {"foreground": window.check()[2]}
        if op == "record":
            if payload.get("method", "printwindow") != "printwindow":
                raise RuntimeError("Screen capture disabled in non-disruptive mode")
            name = payload["name"]
            output = evidence_path(str(OUT / name))
            stdout = output.with_suffix(".stdout.log").open("x")
            stderr = output.with_suffix(".stderr.log").open("x")
            cmd = [sys.executable, str(ROOT / "tools/dev/record_playtest.py"), "record",
                   "--pid", str(game.game_pid), "--hwnd", str(window.hwnd),
                   "--seconds", str(payload.get("seconds", 20)), "--fps", str(payload.get("fps", 5)),
                   "--method", payload.get("method", "printwindow"), "--output", str(output)]
            child = subprocess.Popen(cmd, stdout=stdout, stderr=stderr, creationflags=0x08000000)
            recorder_jobs.append((child, stdout, stderr, output))
            return {"recorder_pid": child.pid, "output": str(output)}
        if op == "info":
            return {"pid": game.game_pid, "hwnd": window.hwnd, "window": window.check(),
                    "recorders": [{"pid": p.pid, "rc": p.poll(), "output": str(path)}
                                  for p, _, _, path in recorder_jobs]}
        if op == "finish":
            stop = True
            return {"stopping": True}
        raise ValueError("Unknown operation")

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            try:
                length = int(self.headers.get("Content-Length", 0))
                if not 0 < length < 8192:
                    raise ValueError("Invalid payload length")
                request = json.loads(self.rfile.read(length))
                response = process(request)
                event(request, response)
                code = 200
            except Exception as exc:
                response = {"error": str(exc)}
                event({"failed_request": True}, response)
                code = 400
            data = json.dumps(response, ensure_ascii=True).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *_):
            pass

    try:
        game.launch()
        identity = game.wait_controllable(timeout=80)
        deadline = time.monotonic() + 35
        while window is None:
            try:
                window = WindowCapture(game.game_pid, None, "printwindow")
            except RuntimeError as exc:
                if "0 visible windows" not in str(exc) or time.monotonic() >= deadline:
                    raise
                time.sleep(.5)
        process({"op": "background"})
        server = HTTPServer(("127.0.0.1", ports["server_dcs"]), Handler)
        server.timeout = .5
        info = {"run": str(OUT), "controller_port": ports["server_dcs"],
                "game_pid": game.game_pid, "hwnd": window.hwnd, "argv": game.argv(), "registry": identity}
        (OUT / "identity.json").write_text(json.dumps(info, indent=2), encoding="utf-8")
        print(json.dumps(info), flush=True)
        deadline = time.monotonic() + 720
        while not stop and time.monotonic() < deadline and game.process.poll() is None:
            server.handle_request()
        server.server_close()
    finally:
        for child, stdout, stderr, _ in recorder_jobs:
            if child.poll() is None:
                child.terminate()
            child.wait(timeout=5)
            stdout.close()
            stderr.close()
        cleanup = {"normal_menu_exit_verified": False, "window_close": False}
        if window is not None and game.process.poll() is None:
            window.user.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
            window.user.PostMessageW(window.hwnd, 0x10, 0, 0)
            try:
                game.process.wait(timeout=8)
                cleanup["window_close"] = True
            except subprocess.TimeoutExpired:
                pass
        cleanup["cleanup_ok"] = game.stop()
        cleanup["game_rc"] = game.process.poll() if game.process else None
        lease.stop()
        release_ports(ports)
        (OUT / "cleanup.json").write_text(json.dumps(cleanup, indent=2), encoding="utf-8")
        print(json.dumps(cleanup), flush=True)


if __name__ == "__main__":
    main()
