"""Bounded background-only sequence for one already-owned video smoke instance."""

import argparse
from datetime import datetime
import json
from pathlib import Path
import statistics
import time
from urllib.request import Request, urlopen

from match_instance import tcp_call
from record_playtest import evidence_path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--identity", required=True)
    parser.add_argument("--mcp-port", type=int, default=9090)
    args = parser.parse_args()
    identity_file = evidence_path(args.identity)
    identity = json.loads(identity_file.read_text(encoding="utf-8"))
    out = identity_file.parent / ("sequence-" + datetime.now().strftime("%H%M%S"))
    out.mkdir()
    events, phase = [], "qualify"
    expected_pid = identity["game_pid"]
    mcp_info = tcp_call(args.mcp_port, {"command": "get_instance_info"}, timeout=4)
    if mcp_info.get("pid") != expected_pid:
        raise RuntimeError("MCP belongs to another instance")

    def save(request, response, started):
        row = {"phase": phase, "start_monotonic_s": started, "end_monotonic_s": time.perf_counter(),
               "request": request, "response": response}
        events.append(row)
        (out / f"event-{len(events):03d}.json").write_text(json.dumps(row), encoding="utf-8")
        return response

    def controller(payload):
        started = time.perf_counter()
        req = Request(f"http://127.0.0.1:{identity['controller_port']}",
                      data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
        with urlopen(req, timeout=8) as reply:
            return save(payload, json.load(reply), started)

    def mcp(payload):
        started = time.perf_counter()
        return save(payload, tcp_call(args.mcp_port, payload, timeout=4), started)

    def perf_samples(label, seconds):
        nonlocal phase
        phase = label
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            controller({"op": "dcs", "payload": {"op": "perf"}})
            time.sleep(1)

    def status():
        return controller({"op": "dcs", "payload": {"op": "status"}})

    before = status()
    drone = next(u for u in before["units"] if u.get("movement") and u.get("mine"))
    perf_samples("off-before", 5)
    phase = "recording"
    controller({"op": "record", "name": "background-actions.mp4", "seconds": 20, "fps": 5})
    time.sleep(.8)
    mcp({"command": "click", "params": {"x": drone["screen"][0], "y": drone["screen"][1]}})
    selected = status()
    mcp({"command": "click", "params": {"x": 790, "y": 600, "button": 2}})
    time.sleep(3)
    moving = status()
    mcp({"command": "key_press", "params": {"key": "escape"}})
    time.sleep(2)
    mcp({"command": "key_press", "params": {"key": "escape"}})
    perf_samples("recording", 10)
    time.sleep(3)
    after = status()
    perf_samples("off-after", 5)
    info = controller({"op": "info"})
    summary = {"pid": expected_pid, "mcp_identity": mcp_info, "before": before,
               "selected": selected, "moving": moving, "after": after, "controller": info}
    for label in ("off-before", "recording", "off-after"):
        samples = [e["response"] for e in events if e["phase"] == label
                   and e["request"].get("payload", {}).get("op") == "perf"]
        summary[label] = {"samples": len(samples), "fps_median": statistics.median(s["fps"] for s in samples),
                          "process_ms_median": statistics.median(s["process_ms"] for s in samples)}
    (out / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps({"out": str(out), "perf": {k: summary[k] for k in ("off-before", "recording", "off-after")},
                      "foreground": info["window"][2]}))


if __name__ == "__main__":
    main()
