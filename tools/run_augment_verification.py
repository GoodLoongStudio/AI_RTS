"""Isolated real-Match augment probes; hidden consoles, owned PIDs and raw evidence."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def port(udp: bool = False) -> int:
    with socket.socket(type=socket.SOCK_DGRAM if udp else socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--mode", choices=("effects", "network", "regression"), default="effects")
    parser.add_argument("--ids", default="")
    parser.add_argument("--rendered", action="store_true", help="Render on an isolated Windows desktop, never switch the user's desktop")
    args = parser.parse_args()
    output = Path(args.out).resolve()
    output.mkdir(parents=True, exist_ok=False)
    specs = [("effects", "res://tests/automated/MatchAugmentEffectsTest.tscn", "Match augment effects test completed: 0 failure(s)")]
    if args.mode == "network":
        specs = [(role, "res://tests/automated/MatchAugmentNetworkTest.tscn", "Match augment network test completed: 0 failure(s)") for role in ("server", "client")]
    suite = json.loads((ROOT / "config/full_regression_suite.json").read_text(encoding="utf-8"))
    if args.mode == "regression":
        ids = args.ids.split(",")
        specs = [(test["id"], test["scene"], test["expected_marker"]) for test in suite["godot_tests"] if test["id"] in ids]
        if len(specs) != len(ids):
            raise ValueError("Unknown or duplicate regression IDs")
    network_port = port(udp=True)
    children = []
    results = []
    desktop = None
    startup = None
    if args.rendered:
        if os.name != "nt":
            raise ValueError("Private desktop rendering is Windows-only")
        import ctypes
        from ctypes import wintypes
        user32 = ctypes.WinDLL("user32", use_last_error=True)
        user32.CreateDesktopW.argtypes = [wintypes.LPCWSTR, wintypes.LPCWSTR, ctypes.c_void_p,
                                         wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p]
        user32.CreateDesktopW.restype = wintypes.HANDLE
        user32.CloseDesktop.argtypes = [wintypes.HANDLE]
        desktop_name = f"AIRTS_Augment_{os.getpid()}"
        desktop = user32.CreateDesktopW(desktop_name, None, None, 0, 0x10000000, None)
        if not desktop:
            raise ctypes.WinError(ctypes.get_last_error())
        startup = subprocess.STARTUPINFO()
        startup.lpDesktop = desktop_name
    try:
        for name, scene, marker in specs:
            env = dict(os.environ, AIRTS_INSTANCE_DIR="", AIRTS_INSTANCE_STRICT_DCS="0",
                       GODOT_BRIDGE_PORT=str(port()), AIRTS_AUGMENT_ROLE=name,
                       AIRTS_AUGMENT_PORT=str(network_port), AIRTS_AUGMENT_OUTPUT=str(output / f"{name}.json"))
            if args.rendered:
                env["AIRTS_AUGMENT_SHOTS"] = str(output)
            render_args = ["--rendering-method", "gl_compatibility"] if args.rendered else ["--headless"]
            command = [args.godot, *render_args, "--path", str(ROOT), "--quit-after", "12000",
                       scene, "--", "--debugport", str(port())]
            log = (output / f"{name}.log").open("wb")
            process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                                       creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
                                       startupinfo=startup)
            item = {"process": process, "log": log, "name": name, "marker": marker,
                    "command": command, "start": time.time()}
            children.append(item)
            if args.mode != "network":
                collect(item, output, results, suite)
            else:
                time.sleep(0.3)
        if args.mode == "network":
            for item in children:
                collect(item, output, results, suite)
    finally:
        for item in children:
            process = item["process"]
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)
            item["log"].close()
        (output / "summary.json").write_text(json.dumps({"results": results,
            "cleanup_ok": all(item["process"].poll() is not None for item in children)}, indent=2), encoding="utf-8")
        if desktop:
            user32.CloseDesktop(desktop)
    print(json.dumps(results, ensure_ascii=True, indent=2))
    return 0 if all(row["passed"] and row["forbidden_output_clean"] and not row["unexpected_engine_errors"] for row in results) else 1


def collect(item: dict, output: Path, results: list, suite: dict) -> None:
    import re
    process = item["process"]
    try:
        code = process.wait(timeout=max(1, 150 - (time.time() - item["start"])))
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=10)
        code = -9
    item["log"].close()
    text = (output / f"{item['name']}.log").read_text(encoding="utf-8", errors="replace")
    hits = [pattern for pattern in suite["forbidden_output_patterns"] if re.search(pattern, text)]
    errors = re.findall(r"^ERROR:.*$", text, flags=re.MULTILINE)
    dummy_count = len(re.findall(r'ERROR: Parameter "t" is null\.\r?\n\s+at: texture_2d_get \(\./servers/rendering/dummy/storage/texture_storage.h:110\)', text))
    unexpected = list(errors)
    for _ in range(dummy_count):
        unexpected.remove('ERROR: Parameter "t" is null.')
    results.append({"id": item["name"], "pid": process.pid, "rc": code,
        "passed": code == 0 and item["marker"] in text, "log_clean": not hits and not errors,
        "forbidden_output_clean": not hits, "known_headless_dummy_texture_errors": dummy_count,
        "unexpected_engine_errors": unexpected,
        "forbidden_hits": hits, "command": item["command"], "wall_seconds": round(time.time() - item["start"], 2)})


if __name__ == "__main__":
    raise SystemExit(main())
