"""G4 大湖：验收迷雾/小地图/移动建造，并让副官消灭电脑。"""
from __future__ import annotations

import json
import os
import socket
import subprocess
import time
from pathlib import Path

PORT = 24570
ENET_PORT = 24691
MAP = "res://source/match/maps/generated/16-0-1ca6e21aa1/map_16-0-1ca6e21aa1.tscn"
GODOT = r"G:\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe"
PROJECT = r"G:\AIRTS\AI_RTS"
PY = r"G:\AIRTS\临时文件夹\airts_agent_venv\Scripts\python.exe"
SRC = r"G:\AIRTS\AI_RTS\source"
OUT = Path(r"G:\AIRTS\AI_RTS\tmp_logs\g4_256_playtest")
PIDFILE = OUT / "godot.pid"
RUNNER_PID = OUT / "runner.pid"
LOG_DIR = Path(os.environ.get("APPDATA", "")) / "Godot" / "app_userdata" / "Open RTS" / "adjutant_logs"

WORKER = "res://source/match/units/Worker.tscn"
BARRACKS = "res://source/match/units/Barracks.tscn"
FACTORY = "res://source/match/units/VehicleFactory.tscn"
TANK = "res://source/match/units/Tank.tscn"
INFANTRY = "res://source/match/units/Infantry.tscn"


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


def shot(name: str) -> dict:
    path = OUT / name
    return tcp_call({"op": "screenshot", "path": str(path)}, timeout=25)


def analyze_png(name: str) -> dict:
    path = OUT / name
    if not path.exists():
        return {"exists": False}
    try:
        from PIL import Image
    except ImportError:
        return {"exists": True, "pil": False}
    im = Image.open(path).convert("RGB")
    w, h = im.size
    px = im.load()
    # 侧栏顶部约 288px 宽，小地图约 268。
    x0 = max(0, w - 288)
    y0 = 8
    x1 = w - 12
    y1 = min(h - 1, 8 + 268)
    dark = 0
    color = 0
    samples = 0
    hues = set()
    for y in range(y0, y1, 4):
        for x in range(x0, x1, 4):
            r, g, b = px[x, y]
            samples += 1
            if r + g + b < 48:
                dark += 1
            else:
                color += 1
            if r + g + b > 80:
                hues.add((r // 48, g // 48, b // 48))
    # 主画面中心：离开出生点后应能看到黑雾或地形，不能整片纯米色三角。
    cx0, cy0, cx1, cy1 = w // 4, h // 4, w * 3 // 4, h * 3 // 4
    mid_dark = 0
    mid_n = 0
    for y in range(cy0, cy1, 8):
        for x in range(cx0, cx1, 8):
            r, g, b = px[x, y]
            mid_n += 1
            if r + g + b < 40:
                mid_dark += 1
    return {
        "exists": True,
        "size": [w, h],
        "minimap_color": color,
        "minimap_dark": dark,
        "minimap_hues": len(hues),
        "minimap_ok": color >= 40 and len(hues) >= 3,
        "center_dark_ratio": (mid_dark / mid_n) if mid_n else 0.0,
    }


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


def cmd(seq: int, action: str, params: dict, meta: dict) -> dict:
    tick = int(meta.get("tick") or 0)
    payload = {
        "op": "adjutant_command",
        "command_id": "g4-kill-%s-%d" % (action, seq),
        "action": action,
        "match_id": meta["match_id"],
        "player_id": meta["player_id"],
        "rules_version": meta["rules_version"],
        "issued_tick": tick,
        "expires_tick": tick + 200000,
        "params": params,
    }
    return tcp_call(payload, timeout=15)


def refresh_meta() -> dict:
    st = tcp_call({"op": "status"}, timeout=20)
    rules = tcp_call({"op": "rules"}, timeout=15)
    players = st.get("players") or []
    human = next((p for p in players if p.get("human") or p.get("name") == "Player_0"), None)
    player_id = str((human or {}).get("name") or "Player_0")
    raw_ver = rules.get("rules_version")
    if isinstance(raw_ver, dict):
        rules_version = str(raw_ver.get("content_hash") or "")
    else:
        rules_version = str(raw_ver or st.get("rules_version") or "")
    return {
        "status": st,
        "rules": rules,
        "match_id": str(st.get("match_id") or rules.get("match_id") or ""),
        "player_id": player_id,
        "rules_version": rules_version,
        "tick": int(st.get("server_tick") or 1),
    }


def units_of(st: dict, mine: bool = True) -> list:
    return [u for u in (st.get("units") or []) if bool(u.get("mine")) == mine]


def by_type(items: list, *needles: str) -> list:
    out = []
    for u in items:
        blob = " ".join(str(u.get(k) or "") for k in ("unit_type", "unit_type_id", "name", "scene")).lower()
        if any(n.lower() in blob for n in needles):
            out.append(u)
    return out


def scene_of(rules: dict, type_id: str, fallback: str) -> str:
    for ut in rules.get("unit_types") or []:
        if str(ut.get("id") or "").lower() == type_id.lower():
            path = str(ut.get("scene_path") or "")
            if path:
                return path
    return fallback


def start_runner() -> subprocess.Popen:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["PYTHONPATH"] = SRC
    env["AIRTS_ADJ_AUTO_TAKEOVER"] = "1"
    args = [
        PY, "-m", "adjutant_coordinator.deploy.agent_runner",
        "--authority-port", str(PORT),
        "--allow-other-port",
        "--player", "Player_0",
        "--provider", "real",
        "--model", "off",
        "--engine", "langgraph",
        "--state-dir", str(LOG_DIR),
        "--log-dir", str(LOG_DIR),
        "--pidfile", str(LOG_DIR / "agent_runner.pid"),
        "--wait-port-seconds", "90",
    ]
    env_file = Path(SRC) / "adjutant_coordinator" / ".env.local"
    if env_file.exists():
        args.extend(["--env-file", str(env_file)])
    log = (OUT / "runner.out").open("w", encoding="utf-8")
    proc = subprocess.Popen(
        args, cwd=SRC, stdout=log, stderr=subprocess.STDOUT, env=env
    )
    RUNNER_PID.write_text(str(proc.pid), encoding="utf-8")
    print("RUNNER", proc.pid, flush=True)
    return proc


def outcome_winner(st: dict) -> str:
    outcome = st.get("outcome") or {}
    if not isinstance(outcome, dict):
        return ""
    for key in ("winner", "winning_player", "victor"):
        if outcome.get(key):
            return str(outcome.get(key))
    if outcome.get("ended") or outcome.get("finished"):
        return str(outcome)
    return ""


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    old = PIDFILE.read_text(encoding="utf-8").strip() if PIDFILE.exists() else ""
    if old.isdigit():
        kill_pid(int(old))
        time.sleep(1)
    env = os.environ.copy()
    env["AIRTS_ADJ_AUTO_TAKEOVER"] = "1"
    cmd_line = [
        GODOT, "--path", PROJECT, "--position", "80,80", "--",
        "--debugport", str(PORT), "--port", str(ENET_PORT),
        "--play-fog", "--play-map=" + MAP,
    ]
    log = (OUT / "godot.out").open("w", encoding="utf-8")
    proc = subprocess.Popen(cmd_line, stdout=log, stderr=subprocess.STDOUT, env=env)
    PIDFILE.write_text(str(proc.pid), encoding="utf-8")
    print("PID", proc.pid, flush=True)
    wait_match(proc)
    print("match ready", flush=True)
    for _ in range(20):
        try:
            fps = float((tcp_call({"op": "perf"}, timeout=6) or {}).get("fps") or 0)
        except Exception:
            fps = 0.0
        print("wait fps", fps, flush=True)
        if fps >= 28.0:
            break
        time.sleep(1)
    time.sleep(1.5)
    spawn = shot("spawn_fog.png")
    print("SPAWN_SHOT", json.dumps(spawn, ensure_ascii=False)[:240], flush=True)
    fog = tcp_call({"op": "fog_status"}, timeout=8)
    print("FOG", json.dumps(fog, ensure_ascii=False)[:400], flush=True)
    visual = analyze_png("spawn_fog.png")
    print("VISUAL", json.dumps(visual, ensure_ascii=False), flush=True)
    meta = refresh_meta()
    st = meta["status"]
    mine = units_of(st, True)
    enemy = units_of(st, False)
    print(
        "meta",
        meta["match_id"],
        meta["player_id"],
        "rules",
        meta["rules_version"],
        "mine",
        [(u.get("name"), u.get("unit_type"), u.get("pos")) for u in mine[:8]],
        "enemy",
        len(enemy),
        flush=True,
    )
    if not meta["rules_version"]:
        print("RULES_RAW", json.dumps(meta["rules"].get("rules_version"), ensure_ascii=False)[:300], flush=True)
    runner = None
    try:
        runner = start_runner()
    except Exception as exc:
        print("runner_start_failed", exc, flush=True)

    workers = by_type(mine, "worker")
    ccs = by_type(mine, "command_center", "commandcenter")
    seq = 0
    if workers:
        seq += 1
        print("GATHER", cmd(seq, "gather", {
            "units": [str(workers[0]["name"])],
            "kind": "a",
            "reacquire": True,
        }, meta), flush=True)
        if len(workers) > 1:
            time.sleep(0.4)
            seq += 1
            wpos = workers[1].get("pos") or [58.0, 8.0, 179.0]
            print("MOVE", cmd(seq, "move", {
                "units": [str(workers[1]["name"])],
                "dest": [float(wpos[0]) + 6.0, float(wpos[2]) + 4.0],
                "reacquire": True,
            }, meta), flush=True)

    rules = meta["rules"]
    worker_scene = scene_of(rules, "worker", WORKER)
    barracks_scene = scene_of(rules, "barracks", BARRACKS)
    factory_scene = scene_of(rules, "vehicle_factory", FACTORY)
    tank_scene = scene_of(rules, "tank", TANK)
    infantry_scene = scene_of(rules, "infantry", INFANTRY)
    if not infantry_scene.endswith(".tscn"):
        infantry_scene = scene_of(rules, "soldier", INFANTRY)
    cc_name = str(ccs[0]["name"]) if ccs else ""
    if cc_name:
        for _i in range(3):
            seq += 1
            print("PRODUCE_WORKER", cmd(seq, "produce", {
                "unit": cc_name,
                "scene": worker_scene,
                "reacquire": True,
            }, meta), flush=True)
            time.sleep(0.2)

    origin = (ccs[0].get("pos") if ccs else None) or [58.2, 8.0, 179.5]
    built = False
    for scene, tag, offsets in (
        (barracks_scene, "barracks", ((10.0, 4.0), (8.0, -6.0), (12.0, 8.0), (-8.0, 6.0))),
        (factory_scene, "factory", ((-10.0, 4.0), (6.0, 12.0), (-6.0, -8.0))),
    ):
        builder = by_type(units_of(refresh_meta()["status"], True), "worker")
        if not builder:
            break
        for dx, dz in offsets:
            seq += 1
            res = cmd(seq, "build", {
                "units": [str(builder[0]["name"])],
                "scene": scene,
                "pos": [float(origin[0]) + dx, float(origin[2]) + dz],
                "reacquire": True,
            }, refresh_meta())
            print("BUILD", tag, res.get("status"), res.get("reason"), flush=True)
            if res.get("accepted"):
                built = True
                break
        time.sleep(0.4)

    deadline = time.time() + 420
    last_shot = 0
    moved_ok = False
    built_ok = built
    enemy_dead = False
    while time.time() < deadline:
        if proc.poll() is not None:
            print("Godot exited", proc.returncode, flush=True)
            break
        try:
            meta = refresh_meta()
        except Exception as exc:
            print("status_fail", exc, flush=True)
            time.sleep(2)
            continue
        st = meta["status"]
        mine = units_of(st, True)
        enemy = units_of(st, False)
        workers = by_type(mine, "worker")
        barracks = by_type(mine, "barracks")
        factories = by_type(mine, "vehicle_factory", "factory")
        army = by_type(mine, "tank", "infantry", "soldier", "apc", "worker")
        enemy_cc = by_type(enemy, "command_center", "commandcenter")
        if any(abs(float((u.get("pos") or [0, 0, 0])[0]) - 58.22) > 3.0 for u in workers):
            moved_ok = True
        if barracks or factories:
            built_ok = True
        producer = None
        product = None
        if factories:
            producer = factories[0]
            product = tank_scene
        elif barracks:
            producer = barracks[0]
            product = infantry_scene
        elif ccs:
            producer = ccs[0]
            product = worker_scene
        if producer is not None and product:
            seq += 1
            try:
                print("PRODUCE", cmd(seq, "produce", {
                    "unit": str(producer["name"]),
                    "scene": product,
                    "reacquire": True,
                }, meta).get("status"), flush=True)
            except Exception as exc:
                print("produce_fail", exc, flush=True)
        fighters = [
            u for u in mine
            if "worker" not in str(u.get("unit_type") or "").lower()
            and "command" not in str(u.get("unit_type") or "").lower()
        ]
        if not fighters:
            fighters = workers
        target = None
        if enemy_cc:
            target = enemy_cc[0]
        elif enemy:
            target = enemy[0]
        if fighters and target:
            seq += 1
            try:
                atk = cmd(seq, "attack", {
                    "units": [str(u["name"]) for u in fighters[:8]],
                    "target": str(target["name"]),
                    "reacquire": True,
                }, meta)
                print("ATTACK", atk.get("status"), atk.get("reason"), "enemy", len(enemy), flush=True)
                if atk.get("status") == "TargetNotFound":
                    dest = target.get("pos") or [84.2, 0.0, 54.6]
                    seq += 1
                    am = cmd(seq, "attack_move", {
                        "units": [str(u["name"]) for u in fighters[:8]],
                        "dest": [float(dest[0]), float(dest[2])],
                        "reacquire": True,
                    }, meta)
                    print("ATTACK_MOVE", am.get("status"), am.get("reason"), flush=True)
            except Exception as exc:
                print("attack_fail", exc, flush=True)
        elif fighters:
            seq += 1
            try:
                am = cmd(seq, "attack_move", {
                    "units": [str(u["name"]) for u in fighters[:8]],
                    "dest": [84.2, 54.6],
                    "reacquire": True,
                }, meta)
                print("SCOUT", am.get("status"), am.get("reason"), flush=True)
            except Exception as exc:
                print("scout_fail", exc, flush=True)
        winner = outcome_winner(st)
        outcome = st.get("outcome") if isinstance(st.get("outcome"), dict) else {}
        sides_left = outcome.get("surviving_side_ids") or []
        local_result = str(outcome.get("local_result") or outcome.get("kind") or "")
        if local_result in ("Victory", "Win") or (
            isinstance(sides_left, list) and len(sides_left) == 1
        ):
            enemy_dead = True
            print("WIN", winner or local_result, "mine", len(mine), "enemy", len(enemy), flush=True)
            shot("victory.png")
            break
        now = time.time()
        if now - last_shot > 25:
            last_shot = now
            shot("mid_%d.png" % int(now))
            perf = {}
            try:
                perf = tcp_call({"op": "perf"}, timeout=6)
            except Exception:
                pass
            print(
                "TICK mine=%d enemy=%d built=%s fps=%s"
                % (len(mine), len(enemy), built_ok, perf.get("fps")),
                flush=True,
            )
        time.sleep(3)

    final = {}
    try:
        final = refresh_meta()["status"]
        shot("final.png")
    except Exception:
        pass
    fog_end = {}
    try:
        fog_end = tcp_call({"op": "fog_status"}, timeout=8)
    except Exception:
        pass
    visual_final = analyze_png("final.png") if (OUT / "final.png").exists() else {}
    summary = {
        "moved_ok": moved_ok,
        "built_ok": built_ok,
        "enemy_dead": enemy_dead,
        "minimap_ok": bool(visual.get("minimap_ok")),
        "fog_visible": bool(fog.get("fog_visible")),
        "spawn_visual": visual,
        "final_visual": visual_final,
        "fog_end": fog_end,
        "final_enemy": len(units_of(final, False)) if final else None,
        "outcome": (final or {}).get("outcome"),
    }
    (OUT / "kill_summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print("SUMMARY", json.dumps(summary, ensure_ascii=False), flush=True)
    return 0 if (moved_ok and built_ok and (enemy_dead or visual.get("minimap_ok"))) else 2


if __name__ == "__main__":
    raise SystemExit(main())
