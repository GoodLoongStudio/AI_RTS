"""G4：活局过桥，单位必须站在桥面而不是穿进桥板/河床。"""
from __future__ import annotations

import json
import socket
import subprocess
import time
from pathlib import Path

PORT = 24572
ENET_PORT = 24692
MAP = "res://source/match/maps/generated/16-0-1ca6e21aa1/map_16-0-1ca6e21aa1.tscn"
GODOT = r"G:\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe"
PROJECT = r"G:\AIRTS\AI_RTS"
OUT = Path(r"G:\AIRTS\AI_RTS\tmp_logs\g4_256_playtest")
PIDFILE = OUT / "bridge_godot.pid"
DEST = (84.22, 54.60)
BRIDGE = (94.00, 78.74)


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


def mobile(st: dict) -> list:
    out = []
    for u in st.get("units") or []:
        if not u.get("mine"):
            continue
        blob = " ".join(str(u.get(k) or "") for k in ("unit_type", "name")).lower()
        if "command" in blob or "barrack" in blob or "factory" in blob or "drone" in blob:
            continue
        out.append(u)
    return out


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    old = PIDFILE.read_text(encoding="utf-8").strip() if PIDFILE.exists() else ""
    if old.isdigit():
        kill_pid(int(old))
        time.sleep(1)
    log = (OUT / "bridge_godot.out").open("w", encoding="utf-8")
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
    print("MOVE", tcp_call({"op": "move", "units": names, "dest": [DEST[0], DEST[1]]}, timeout=12).get("status"), flush=True)
    tcp_call({"op": "camera", "look_at": [94.0, 4.0, 79.0], "size": 28}, timeout=8)
    on_deck_ys: list[float] = []
    clipped = 0
    deadline = time.time() + 80
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
            db = dist(p, BRIDGE)
            if db < 18.0:
                on_deck_ys.append(y)
                if y < 0.55:
                    clipped += 1
            rows.append("%s(%.1f,%.1f,y=%.2f,bridge=%.1f)" % (u.get("name"), p[0], p[1], y, db))
        print("T", int(deadline - time.time()), "deck_n", len(on_deck_ys), "clip", clipped, " | ".join(rows[:5]), flush=True)
        if on_deck_ys and max(on_deck_ys) >= 1.15 and dist(xz(mobile(st)[0]), DEST) < 8.0:
            break
        time.sleep(2.0)
    tcp_call({"op": "screenshot", "path": str(OUT / "bridge_cross.png")}, timeout=20)
    max_y = max(on_deck_ys) if on_deck_ys else -99.0
    min_y = min(on_deck_ys) if on_deck_ys else -99.0
    ok = bool(on_deck_ys) and max_y >= 1.15 and clipped == 0
    print(
        "RESULT",
        json.dumps({
            "ok": ok,
            "on_deck_samples": len(on_deck_ys),
            "deck_y_min": round(min_y, 3),
            "deck_y_max": round(max_y, 3),
            "clipped_under_deck": clipped,
        }, ensure_ascii=False),
        flush=True,
    )
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
