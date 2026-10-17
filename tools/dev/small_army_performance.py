"""Replay a visible small army benchmark with managed instance ownership."""
import argparse
import json
import os
import re
import time
from pathlib import Path

from match_instance import Instance, allocate_ports, godot_exe


ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True)
    parser.add_argument("--equivalence", action="store_true")
    parser.add_argument("--count", type=int, default=46)
    parser.add_argument("--fps-cap", type=int, default=0)
    parser.add_argument("--min-fps", type=float, default=27.0,
                        help="Minimum valid-stage average FPS (27 = 90%% of production cap)")
    args = parser.parse_args()
    if args.count < 1 or args.fps_cap < 0 or args.min_fps < 0:
        parser.error("count must be positive; fps-cap and min-fps must be nonnegative")
    output = Path(args.out).resolve()
    output.mkdir(parents=True, exist_ok=True)

    class ProbeInstance(Instance):
        def argv(self):
            scene = "MovementPushEquivalence" if args.equivalence else "SmallArmyPerformanceProbe"
            return [godot_exe(), "--path", str(ROOT),
                    *(["--headless"] if args.equivalence else ["--position", "100,100"]),
                    "res://tests/performance/" + scene + ".tscn", "--",
                    "--debugport", str(self.ports["client_dcs"]),
                    "--perf-out=" + output.as_posix(), "--army-count=" + str(args.count),
                    "--fps-cap=" + str(args.fps_cap)]

    instance = ProbeInstance("client", "small-army-" + str(os.getpid()), allocate_ports(),
                             log_dir=str(output))
    instance.env_extra["GODOT_BRIDGE_PORT"] = str(instance.ports["game"])
    try:
        started = time.time()
        instance.launch()
        deadline = time.monotonic() + 180
        while instance.process.poll() is None:
            if time.monotonic() >= deadline:
                raise TimeoutError("Probe exceeded 180 seconds")
            for path in output.glob("*.err.log"):
                if path.stat().st_mtime >= started:
                    error_log = path.read_text(encoding="utf-8", errors="replace")
                    if re.search(r"SCRIPT ERROR:|Parse Error:|^ERROR:", error_log, re.MULTILINE):
                        raise RuntimeError("Godot reported an error; see " + str(path))
            time.sleep(0.2)
        rc = instance.process.returncode
        logs = "\n".join(path.read_text(encoding="utf-8", errors="replace")
                         for path in output.glob("*.log") if path.stat().st_mtime >= started)
        marker = ("Movement push equivalence completed: 0 failure(s)" if args.equivalence else
                  "Small army performance probe completed: 0 failure(s)")
        errors = re.findall(r"SCRIPT ERROR:|Parse Error:|^ERROR:", logs, re.MULTILINE)
        if rc != 0 or marker not in logs or errors:
            raise RuntimeError(f"Probe failed: rc={rc}, marker={marker in logs}, errors={errors}")
        if not args.equivalence:
            summary = output / "summary.json"
            screenshot = output / "army.png"
            if any(not p.exists() or p.stat().st_mtime < started for p in [summary, screenshot]):
                raise RuntimeError("No fresh summary/screenshot")
            data = json.loads(summary.read_text(encoding="utf-8"))
            print(json.dumps(data, ensure_ascii=False, indent=2))
            slow = [row for row in data["samples"]
                    if row["stage"] != "without_velocity_callback" and row["fps"] < args.min_fps]
            if slow:
                raise RuntimeError(f"FPS gate failed ({args.min_fps}): {slow}")
        print("Probe passed, rc=0; logs:", output)
        return 0
    finally:
        instance.stop()


if __name__ == "__main__":
    raise SystemExit(main())
