# -*- coding: utf-8 -*-
"""真实对局 × 真战斗 × 真截图：检测"敌方死亡建筑是否还在"（2026-09-23）。

按 .workbuddy/memory/2026-09-14 的"循环开局检测修复"方法学：
  清残留（按 PID）→ 起窗口化真对局（DCS 监听）→ 生产作战单位 →
  op=tactical 找敌方建筑 → op=attack 真打死 → op=screenshot 看画面 +
  op=tactical 看实体。不猜机制，直接在用户看到的那张画面上检测。
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = HERE
for _ in range(5):
    if (os.path.isdir(os.path.join(REPO, "AI_RTS"))
            and os.path.isdir(os.path.join(REPO, "godot_mono_471"))):
        break
    REPO = os.path.dirname(REPO)
AIRTS = os.path.join(REPO, "AI_RTS")
GODOT = os.path.join(REPO, "godot_mono_471", "Godot_v4.7.1-stable_mono_win64",
                     "Godot_v4.7.1-stable_mono_win64_console.exe")
OUT = os.path.join(REPO, "tmp_logs", "enemy_death_live")
PORT = int(os.environ.get("AIRTS_LIVE_PORT", "24580"))
DRONE_SCENE = "res://source/match/units/Drone.tscn"

os.makedirs(OUT, exist_ok=True)


def log(*a):
    print(" ".join(str(x) for x in a), flush=True)


def tcp_call(payload: dict, timeout: float = 8.0):
    import socket
    try:
        s = socket.create_connection(("127.0.0.1", PORT), timeout=timeout)
    except OSError:
        return {"_error": "connect failed"}
    try:
        s.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    except OSError as exc:
        return {"_error": str(exc)}
    finally:
        s.close()
    line = buf.split(b"\n")[0].decode("utf-8", "replace")
    if not line.strip():
        return {"_error": "empty response"}
    try:
        return json.loads(line)
    except Exception:
        return {"_raw": line[:400]}


def wait_port(seconds: float = 90.0) -> bool:
    import socket
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            s = socket.create_connection(("127.0.0.1", PORT), timeout=2)
            s.close()
            return True
        except OSError:
            time.sleep(1.0)
    return False


def status_until_ok(seconds: float = 180.0):
    """轮询 op=status 直到返回带 match 的有效结果（开局早期偶发 GDScript 报错要重试）。"""
    deadline = time.time() + seconds
    last = None
    while time.time() < deadline:
        last = tcp_call({"op": "status"})
        if isinstance(last, dict) and last.get("match"):
            return last
        time.sleep(2.0)
    return last


def kill_stale():
    ps = ("Get-CimInstance Win32_Process | Where-Object { $_.Name -like 'Godot*' -and "
          "$_.CommandLine -match 'LiveDcsMatchBoot' } | ForEach-Object { $_.ProcessId }")
    try:
        raw = subprocess.run(["powershell", "-NoProfile", "-Command", ps],
                             capture_output=True, timeout=30).stdout
        for pid in (raw or b"").decode("utf-8", "replace").split():
            subprocess.run(["taskkill", "/F", "/PID", pid.strip()],
                           capture_output=True, timeout=20)
            log("killed stale pid", pid.strip())
    except Exception as exc:  # noqa: BLE001
        log("kill stale skipped:", exc)


def main() -> int:
    kill_stale()
    log_path = os.path.join(OUT, "game.out")
    logf = open(log_path, "w", encoding="utf-8")
    proc = subprocess.Popen(
        [GODOT, "--path", AIRTS, "res://tests/automated/LiveDcsMatchBoot.tscn",
         "--", "--debugport", str(PORT)],
        stdout=logf, stderr=subprocess.STDOUT)
    log("game pid", proc.pid)
    if not wait_port():
        log("FAIL: DCS 端口未就绪")
        proc.kill()
        return 2

    # 等对局就绪
    st = status_until_ok()
    ready = bool(isinstance(st, dict) and st.get("match"))
    log("match ready:", ready)
    if not ready:
        log("FAIL: 对局未就绪，最后响应:", json.dumps(st, ensure_ascii=False)[:300])
        proc.kill()
        return 2
    with open(os.path.join(OUT, "status.json"), "w", encoding="utf-8") as f:
        json.dump(st, f, ensure_ascii=False, indent=1)
    log("status keys:", list(st.keys())[:20])

    # 找人类指挥中心并生产无人机（作战单位）
    units = st.get("units") or []
    human_cc = None
    for u in units:
        if isinstance(u, dict) and str(u.get("type", u.get("unit_type", ""))).find("command") >= 0:
            human_cc = u.get("name") or u.get("id")
            break
    log("human cc:", human_cc)
    if human_cc:
        for i in range(6):
            r = tcp_call({"op": "produce", "unit": human_cc, "scene": DRONE_SCENE})
            log("produce ->", json.dumps(r, ensure_ascii=False)[:200])
            time.sleep(0.5)

    # 等敌方建筑（规则 AI 自建）
    enemy_buildings = []
    deadline = time.time() + 240
    while time.time() < deadline:
        tac = tcp_call({"op": "tactical", "as_player": "Player_0"})
        if isinstance(tac, dict):
            ents = tac.get("entities") or []
            enemy_buildings = [
                e for e in ents
                if isinstance(e, dict) and e.get("side") in ("enemy", "adversary")
                and (e.get("is_structure") or str(e.get("type", "")).find("turret") >= 0
                     or "hp_max" in e and float(e.get("hp_max", 0)) > 500)
            ]
            if len(enemy_buildings) >= 2:
                break
        time.sleep(2.0)
    log("enemy buildings found:", len(enemy_buildings))
    with open(os.path.join(OUT, "tactical_before.json"), "w", encoding="utf-8") as f:
        json.dump(enemy_buildings, f, ensure_ascii=False, indent=1)
    for e in enemy_buildings[:8]:
        log("  enemy:", json.dumps(e, ensure_ascii=False)[:220])
    if not enemy_buildings:
        log("FAIL: 没有找到敌方建筑")
        proc.kill()
        return 3

    # 相机对准敌方基地（玩家视角）
    pos = enemy_buildings[0].get("pos") or enemy_buildings[0].get("position")
    if isinstance(pos, dict):
        pos = [pos.get("x", 0), pos.get("y", 0), pos.get("z", 0)]
    if pos:
        r = tcp_call({"op": "camera", "look_at": [float(pos[0]), 0.0, float(pos[-1])]})
        log("camera ->", json.dumps(r, ensure_ascii=False)[:200])
    time.sleep(2.0)

    # 我方无人机
    st = tcp_call({"op": "status"})
    drones = [u for u in (st.get("units") or [])
              if isinstance(u, dict) and str(u.get("type", u.get("unit_type", ""))) == "drone"]
    drone_names = [u.get("name") or u.get("id") for u in drones]
    log("drones:", drone_names)

    # 逐个攻击敌方建筑，直到打死
    killed = []
    for e in enemy_buildings[:3]:
        name = e.get("name") or e.get("id")
        for attempt in range(30):
            r = tcp_call({"op": "attack", "units": drone_names, "target": name})
            ok = isinstance(r, dict) and r.get("accepted")
            if not ok:
                log("attack rejected:", json.dumps(r, ensure_ascii=False)[:200])
                break
            time.sleep(2.0)
            tac = tcp_call({"op": "tactical", "as_player": "Player_0"})
            alive = [x for x in (tac.get("entities") or [])
                     if isinstance(x, dict) and (x.get("name") or x.get("id")) == name]
            if not alive:
                killed.append(name)
                log("KILLED", name)
                break
            hp = alive[0].get("hp")
            log("  attacking", name, "hp=", hp)
        else:
            log("  gave up on", name)

    time.sleep(3.0)
    shot = os.path.join(OUT, "after_kill.png")
    r = tcp_call({"op": "screenshot", "path": shot})
    log("screenshot ->", json.dumps(r, ensure_ascii=False)[:200])
    tac = tcp_call({"op": "tactical", "as_player": "Player_0"})
    with open(os.path.join(OUT, "tactical_after.json"), "w", encoding="utf-8") as f:
        json.dump(tac, f, ensure_ascii=False, indent=1)
    remaining = [x for x in (tac.get("entities") or [])
                 if isinstance(x, dict) and x.get("side") in ("enemy", "adversary")]
    log("enemy entities after kills:", len(remaining))
    log("killed:", killed)
    for x in remaining[:10]:
        log("  still:", json.dumps(x, ensure_ascii=False)[:200])

    proc.kill()
    logf.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
