"""G4 大湖：活局验证占用格绕行，部队不得卡死在河谷。"""
from __future__ import annotations

import json
import socket
import subprocess
import time
from pathlib import Path

PORT = 24570
ENET_PORT = 24691
MAP = "res://source/match/maps/generated/16-0-1ca6e21aa1/map_16-0-1ca6e21aa1.tscn"
GODOT = r"G:\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe"
PROJECT = r"G:\AIRTS\AI_RTS"
OUT = Path(r"G:\AIRTS\AI_RTS\tmp_logs\g4_256_playtest")
PIDFILE = OUT / "godot.pid"
DEST = (84.22, 54.60)
SPAWN = (58.22, 179.48)
VALLEY = (70.76, 106.92)
BRIDGES = ((35.06, 96.49), (94.00, 78.74), (163.84, 104.14))


def tcp_call(payload: dict, timeout: float = 12.0) -> dict:
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


def kill_pid(pid: int) -> None:
    if pid <= 0:
        return
    subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True)


def xz(u: dict) -> tuple[float, float]:
    pos = u.get("pos") or [0, 0, 0]
    return float(pos[0]), float(pos[2])


def y_of(u: dict) -> float:
    pos = u.get("pos") or [0, 0, 0]
    return float(pos[1]) if len(pos) > 1 else 0.0


def dist(a: tuple[float, float], b: tuple[float, float]) -> float:
    return ((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2) ** 0.5


def line_dev(p: tuple[float, float]) -> float:
    sx, sz = SPAWN
    dx, dz = DEST[0] - sx, DEST[1] - sz
    length = (dx * dx + dz * dz) ** 0.5
    if length < 0.001:
        return 0.0
    t = max(0.0, min(1.0, ((p[0] - sx) * dx + (p[1] - sz) * dz) / (length * length)))
    return dist(p, (sx + dx * t, sz + dz * t))


def wait_match(proc: subprocess.Popen, seconds: int = 180) -> dict:
    last = {}
    for i in range(seconds):
        if proc.poll() is not None:
            raise RuntimeError("Godot exited %s" % proc.returncode)
        try:
            last = tcp_call({"op": "status", "lite": True}, timeout=4)
        except Exception as exc:
            if i % 8 == 0:
                print("wait dcs", exc, flush=True)
            time.sleep(1)
            continue
        if last.get("match"):
            return last
        time.sleep(1)
    raise RuntimeError("match never started")


def mine_units(st: dict) -> list:
    return [u for u in (st.get("units") or []) if u.get("mine")]


def mobile(st: dict) -> list:
    out = []
    for u in mine_units(st):
        blob = " ".join(str(u.get(k) or "") for k in ("unit_type", "name")).lower()
        if "command" in blob or "barrack" in blob or "factory" in blob:
            continue
        out.append(u)
    return out


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    old = PIDFILE.read_text(encoding="utf-8").strip() if PIDFILE.exists() else ""
    if old.isdigit():
        kill_pid(int(old))
        time.sleep(1)
    log = (OUT / "godot.out").open("w", encoding="utf-8")
    proc = subprocess.Popen(
        [
            GODOT, "--path", PROJECT, "--position", "80,80", "--",
            "--debugport", str(PORT), "--port", str(ENET_PORT),
            "--no-fog", "--play-map=" + MAP,
        ],
        stdout=log,
        stderr=subprocess.STDOUT,
    )
    PIDFILE.write_text(str(proc.pid), encoding="utf-8")
    print("PID", proc.pid, flush=True)
    wait_match(proc)
    print("match ready", flush=True)
    st = tcp_call({"op": "status"}, timeout=20)
    movers = mobile(st)
    names = [str(u.get("name")) for u in movers]
    print("movers", [(u.get("name"), u.get("unit_type"), u.get("pos")) for u in movers], flush=True)
    if not names:
        print("FAIL no mobile units", flush=True)
        return 2
    moved = tcp_call({"op": "move", "units": names, "dest": [DEST[0], DEST[1]]}, timeout=12)
    print("MOVE", moved.get("status"), moved.get("reason"), moved.get("moved"), flush=True)
    tcp_call({"op": "camera", "look_at": [70.0, 8.0, 120.0], "size": 55}, timeout=8)
    tcp_call({"op": "screenshot", "path": str(OUT / "path_start.png")}, timeout=20)
    valley_hits = 0
    submerged_hits = 0
    max_dev = 0.0
    min_goal = 1e9
    near_bridge = False
    left_spawn = False
    samples = []
    deadline = time.time() + 75
    while time.time() < deadline:
        if proc.poll() is not None:
            print("Godot exited", proc.returncode, flush=True)
            return 3
        try:
            st = tcp_call({"op": "status"}, timeout=10)
        except Exception as exc:
            print("status_fail", exc, flush=True)
            time.sleep(1)
            continue
        rows = []
        for u in mobile(st):
            p = xz(u)
            y = y_of(u)
            d_goal = dist(p, DEST)
            d_val = dist(p, VALLEY)
            d_sp = dist(p, SPAWN)
            dev = line_dev(p)
            max_dev = max(max_dev, dev)
            min_goal = min(min_goal, d_goal)
            if d_sp > 8.0:
                left_spawn = True
            if d_val < 6.0 and y < 0.0:
                valley_hits += 1
            if y < -0.2:
                submerged_hits += 1
            if any(dist(p, b) < 12.0 for b in BRIDGES):
                near_bridge = True
            rows.append("%s(%.1f,%.1f,y=%.1f,goal=%.0f,dev=%.1f)" % (
                u.get("name"), p[0], p[1], y, d_goal, dev
            ))
        samples.append(rows)
        print("T", int(deadline - time.time()), "dev", round(max_dev, 1), "goal", round(min_goal, 1),
              "bridge", near_bridge, "valley", valley_hits, "wet", submerged_hits, " | ".join(rows[:6]), flush=True)
        time.sleep(2.5)
    tcp_call({"op": "camera", "look_at": [90.0, 4.0, 90.0], "size": 70}, timeout=8)
    tcp_call({"op": "screenshot", "path": str(OUT / "path_mid.png")}, timeout=20)
    ok = left_spawn and max_dev >= 6.0 and valley_hits <= 2 and min_goal < 110.0
    print(
        "RESULT",
        json.dumps({
            "ok": ok,
            "left_spawn": left_spawn,
            "max_dev": round(max_dev, 2),
            "min_goal": round(min_goal, 2),
            "near_bridge": near_bridge,
            "valley_hits": valley_hits,
            "submerged_hits": submerged_hits,
        }, ensure_ascii=False),
        flush=True,
    )
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
