# -*- coding: utf-8 -*-
"""副官双层改造第一阶段 E2E：本地双进程真实链路验证（禁止触碰云端默认局服）。

进程拓扑（每轮独立启动、独立回收；与 hermes_skill/validation/round_runner.py 同模式）：
  权威服  Godot --headless -- --server --port 24569 --debugport 24572
          --balance-config=res://config/balance/adjutant-e2e.balance.v1.json
          --assets-manifest=res://config/godot/adjutant-e2e.assets.v1.json
  客户端  Godot --headless -- -- --debugport 24570 --autojoin --autojoin-lobby
          --smokehost 127.0.0.1 --smokeport 24569（同样加载独立测试配置）

验证场景（delivery.md 第一阶段）：
  1. 动态规则：独立测试配置的新对局中，规则视图发现新增普通内容 scout
     与 tank 成本变更（500→555）；不读磁盘最新配置，只认当前对局 Catalog。
  2. 生产选择匹配动态生产关系：CommandCenter 生产 tank 被动态关系拒绝。
  3. 真实建造链：副官统一入口 build → 服务器直执行 → 战术快照出现 vehicle_factory。
  4. 真实生产链：vehicle_factory 生产 tank → PendingAuthority/终态复核 command_id。
  5. 幂等：同 command_id 同参数重放返回原回执，不重复下单不重复扣费。
  6. 玩家优先权：旧 op 路径手动命令后，副官再动同一单位被 PlayerOverride 拒绝。

判定纪律：PASS=实际执行且符合预期；FAIL=实际执行但结果错误；SKIP=条件不满足。
所有轮次产物写入独立 run_id 目录，不覆盖历史。
"""

import argparse
import json
import os
import socket
import subprocess
import sys
import time

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

HERE = os.path.dirname(os.path.abspath(__file__))
AI_RTS = r"G:\AIRTS\AI_RTS"
GODOT = (r"G:\AIRTS\godot_mono_471\Godot_v4.7.1-stable_mono_win64"
         r"\Godot_v4.7.1-stable_mono_win64_console.exe")

SERVER_PORT, SERVER_DBG, CLIENT_DBG = 24569, 24572, 24570
BALANCE = "res://config/balance/adjutant-e2e.balance.v1.json"
MANIFEST = "res://config/godot/adjutant-e2e.assets.v1.json"

_results = []


def log(message):
    print(message, flush=True)


def check(item, kind, detail=""):
    _results.append((item, kind, detail))
    log("  [%s] %s%s" % (kind, item, (" | " + detail) if detail else ""))


def expect(item, condition, detail="", fail_detail=""):
    if condition:
        check(item, "PASS", detail)
        return True
    check(item, "FAIL", fail_detail or detail)
    return False


def skip(item, reason):
    check(item, "SKIP", reason)


# ---------------- TCP JSON 帮助函数（与游戏调试端点同协议） ----------------

def tcp_call(port, payload, timeout=30.0):
    """与游戏调试端点同协议：逐行 JSON。

    注意：Godot StreamPeer.put_utf8_string 会先写 32 位长度前缀再写内容，
    解析时从第一个 '{' 起截取，兼容有无前缀两种对端。
    """
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as sock:
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
                line = buffer[start:end].decode("utf-8", errors="replace")
                return json.loads(line)
        raise TimeoutError("debug endpoint no response: op=%s" % payload.get("op"))


def wait_port(port, deadline_s):
    end = time.time() + deadline_s
    while time.time() < end:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1.0):
                return True
        except OSError:
            time.sleep(0.5)
    return False


def pids_on_port(port):
    output = subprocess.run(["netstat", "-ano", "-p", "TCP"],
                            capture_output=True, text=True).stdout or ""
    pids = set()
    for line in output.splitlines():
        parts = line.split()
        if len(parts) >= 5 and parts[1].endswith(":%d" % port) and parts[3] == "LISTENING":
            pids.add(parts[4])
    return pids


def kill_tree(pid):
    subprocess.run(["taskkill", "/F", "/T", "/PID", str(pid)], capture_output=True)


# ---------------- 场景 ----------------

def scene_worker(player_units):
    for unit in player_units:
        if str(unit.get("unit_type", "")) == "worker":
            return unit
    return None


def run_e2e(run_dir):
    procs = []
    log_path_server = open(os.path.join(run_dir, "server.log"), "wb")
    log_path_client = open(os.path.join(run_dir, "client.log"), "wb")
    try:
        # 基线记录。
        baseline = subprocess.run(
            ["git", "-C", AI_RTS, "log", "-1", "--format=%H %ci %s"],
            capture_output=True, text=True, encoding="utf-8", errors="replace").stdout.strip()
        log("baseline commit: %s" % baseline)
        with open(os.path.join(run_dir, "baseline.txt"), "w", encoding="utf-8") as handle:
            handle.write(baseline + "\n")

        server_args = [GODOT, "--headless", "--path", AI_RTS, "--",
                       "--server", "--port", str(SERVER_PORT), "--debugport", str(SERVER_DBG),
                       "--balance-config=" + BALANCE, "--assets-manifest=" + MANIFEST]
        procs.append(subprocess.Popen(server_args, stdout=log_path_server,
                                      stderr=subprocess.STDOUT,
                                      creationflags=subprocess.CREATE_NO_WINDOW))
        client_args = [GODOT, "--headless", "--path", AI_RTS, "--",
                       "--debugport", str(CLIENT_DBG), "--autojoin", "--autojoin-lobby",
                       "--smokehost", "127.0.0.1", "--smokeport", str(SERVER_PORT),
                       "--balance-config=" + BALANCE, "--assets-manifest=" + MANIFEST]
        procs.append(subprocess.Popen(client_args, stdout=log_path_client,
                                      stderr=subprocess.STDOUT,
                                      creationflags=subprocess.CREATE_NO_WINDOW))

        if not expect("调试端口就绪",
                      wait_port(SERVER_DBG, 40) and wait_port(CLIENT_DBG, 40),
                      "server:%d client:%d" % (SERVER_DBG, CLIENT_DBG)):
            return

        # 安全闸门：确认客户端联网后才 start，避免误连云端。
        networked = False
        for _ in range(15):
            time.sleep(2)
            status = tcp_call(CLIENT_DBG, {"op": "status", "lite": True})
            if status.get("networked") is True:
                networked = True
                break
        expect("客户端联网（networked=true）", networked)
        if not networked:
            return
        start = tcp_call(CLIENT_DBG, {"op": "start", "with_ai": False})
        expect("开局指令已发出", start.get("ok") is True)

        # 等对局就绪（服务器 status.match）。
        ready = False
        for _ in range(20):
            time.sleep(2)
            status = tcp_call(SERVER_DBG, {"op": "status", "lite": True})
            if status.get("match") is True:
                ready = True
                break
        expect("对局已就绪", ready)

        # ---- 场景 1：动态规则发现（新增内容 + 成本变更） ----
        rules = tcp_call(SERVER_DBG, {"op": "rules"})
        expect("规则视图可导出", not rules.get("error"))
        types = {t["id"]: t for t in rules.get("unit_types", [])}
        expect("新增普通内容 scout 被规则视图发现", "scout" in types,
               "scout: %s" % json.dumps(types.get("scout", {}))[:120])
        productions = {p["id"]: p for p in rules.get("productions", [])}
        tank_cost = sum(c["amount"] for c in productions.get("tank", {}).get("cost", []))
        expect("tank 成本变更（555）被规则视图发现", tank_cost == 555,
               "实际 tank cost=%s" % tank_cost)
        scout_producers = productions.get("scout", {}).get("allowed_producer_type_ids", [])
        expect("scout 生产关系动态解析为 aircraft_factory",
               scout_producers == ["aircraft_factory"], str(scout_producers))
        rules_version = str(rules.get("rules_version", {}).get("content_hash", ""))
        match_id = str(rules.get("match_id", ""))
        expect("规则版本与对局身份非空", bool(rules_version) and bool(match_id))

        # ---- 场景 2：生产选择匹配动态生产关系 ----
        # 单位装载在导航异步烘焙之后：必须等 units 组 populated 再下命令。
        player_name = ""
        units = []
        for _ in range(25):
            time.sleep(2)
            status = tcp_call(SERVER_DBG, {"op": "status"})
            units = status.get("units", [])
            humans = [p for p in status.get("players", []) if p.get("human") is True]
            if units and humans:
                player_name = str(humans[0]["name"])
                break
        expect("对局单位已装载且解析到人类玩家", bool(units and player_name),
               "player=%s units=%d" % (player_name or "无", len(units)))
        if not (units and player_name):
            return
        worker = scene_worker(units)
        command_center = next((u for u in units
                               if str(u.get("unit_type", "")) == "command_center"), None)
        expect("开局存在 worker 与 command_center", worker is not None and command_center is not None)
        if worker is None or command_center is None:
            return
        tank_scene = types["tank"]["scene_path"]

        def command_envelope(command_id, action, params):
            return {"op": "adjutant_command", "command_id": command_id, "action": action,
                    "match_id": match_id, "player_id": player_name,
                    "rules_version": rules_version, "expires_tick": 99999999,
                    "params": params}

        bad = tcp_call(SERVER_DBG, command_envelope(
            "e2e-bad-producer", "produce",
            {"producer": str(command_center["name"]), "scene": tank_scene}))
        expect("CommandCenter 生产 tank 被动态关系拒绝",
               bad.get("status") in ("InvalidProducer", "ProductNotAllowed"),
               "status=%s reason=%s" % (bad.get("status"), str(bad.get("reason"))[:80]))

        # ---- 场景 3：真实建造链（服务器直执行） ----
        # 建造点依次尝试 worker 周围多个偏移，避开出生点与地形（位置合法性由权威判定）。
        build = {"accepted": False, "status": "NotAttempted", "reason": ""}
        for dx, dz in ((6.0, 6.0), (-6.0, 6.0), (6.0, -6.0), (-6.0, -6.0), (9.0, 0.0), (0.0, 9.0)):
            build = tcp_call(SERVER_DBG, command_envelope(
                "e2e-build-vf-%s" % ("x%+d_z%+d" % (dx, dz)).replace("-", "m"),
                "build",
                {"units": [str(worker["name"])],
                 "scene": types["vehicle_factory"]["scene_path"],
                 "pos": [float(worker["pos"][0]) + dx, float(worker["pos"][2]) + dz]}))
            if build.get("accepted") is True:
                break
            time.sleep(0.3)
        expect("副官 build 被权威接受",
               build.get("accepted") is True,
               "status=%s reason=%s" % (build.get("status"), str(build.get("reason"))[:80]))

        factory_name = ""
        constructed = False
        for _ in range(30):
            time.sleep(2)
            tactical = tcp_call(SERVER_DBG, {"op": "tactical", "as_player": player_name})
            for entity in tactical.get("entities", []):
                if entity.get("kind") == "unit_self" and \
                        entity.get("unit_type") == "vehicle_factory":
                    factory_name = str(entity.get("name", ""))
                    constructed = bool(entity.get("constructed", False))
                    break
            if factory_name and constructed:
                break
        expect("战术快照出现已建成的 vehicle_factory", bool(factory_name and constructed),
               "factory=%s constructed=%s" % (factory_name or "未出现", constructed))

        # ---- 场景 4：真实生产链（匹配动态关系）+ 终态复核 ----
        vf_scene = types["tank"]["scene_path"]
        produce = tcp_call(SERVER_DBG, command_envelope(
            "e2e-produce-tank", "produce",
            {"producer": factory_name, "scene": vf_scene}))
        expect("vehicle_factory 生产 tank 被接受（成本 555 从当前账本扣）",
               produce.get("accepted") is True,
               "status=%s reason=%s" % (produce.get("status"), str(produce.get("reason"))[:80]))
        command_receipts = tcp_call(SERVER_DBG, {"op": "commands", "command_id": "e2e-produce-tank"})
        entries = command_receipts.get("commands", [])
        expect("op=commands 按 command_id 复核到生产终态",
               bool(entries) and str(entries[0].get("status", "")) == "Accepted",
               "entries=%s" % json.dumps(entries)[:160])

        # ---- 场景 5：幂等重放不重复下单 ----
        replay = tcp_call(SERVER_DBG, command_envelope(
            "e2e-produce-tank", "produce",
            {"producer": factory_name, "scene": vf_scene}))
        expect("同 ID 同参数重放返回原回执且标记 idempotent_replay",
               replay.get("accepted") is True and replay.get("idempotent_replay") is True,
               "status=%s replay=%s" % (replay.get("status"), replay.get("idempotent_replay")))
        tactical = tcp_call(SERVER_DBG, {"op": "tactical", "as_player": player_name})
        factory = next((e for e in tactical.get("entities", [])
                        if str(e.get("name", "")) == factory_name), None)
        queue_size = -1
        if factory is not None:
            for view in tactical.get("production", []):
                if str(view.get("producer", "")) == factory_name:
                    queue_size = int(view.get("queue_size", -1))
        expect("重放后生产队列没有重复订单（不重复扣费）", queue_size == 1,
               "queue_size=%s（应为 1：一个 tank 订单）" % queue_size)

        # ---- 场景 6：玩家优先权（旧 op 路径 = 手动接管） ----
        manual = tcp_call(SERVER_DBG, {"op": "move", "as_player": player_name,
                                       "units": [str(worker["name"])],
                                       "dest": [float(worker["pos"][0]) + 2.0,
                                                float(worker["pos"][2]) + 2.0]})
        expect("玩家手动命令（旧 op 路径）成功", manual.get("accepted") is True)
        override = tcp_call(SERVER_DBG, command_envelope(
            "e2e-move-after-override", "move",
            {"units": [str(worker["name"])], "dest": [10.0, 10.0]}))
        expect("玩家接管后副官再动同一单位被 PlayerOverride 拒绝",
               override.get("status") == "PlayerOverride",
               "status=%s" % override.get("status"))
        override = command_envelope(
            "e2e-reacquire", "move",
            {"units": [str(worker["name"])], "dest": [10.0, 10.0], "reacquire": True})
        reacquired = tcp_call(SERVER_DBG, override)
        expect("显式 reacquire 授权后重新接管成功",
               reacquired.get("accepted") is True,
               "status=%s" % reacquired.get("status"))

    finally:
        for proc in procs:
            try:
                if proc.poll() is None:
                    kill_tree(proc.pid)
            except Exception:
                pass
        for port in (SERVER_PORT, SERVER_DBG, CLIENT_DBG):
            for pid in pids_on_port(port):
                kill_tree(pid)
        time.sleep(4.0)
        log_path_server.close()
        log_path_client.close()


def verify_summary(summary):
    """从 results 重算 PASS/FAIL/SKIP 并与顶层字段及 counts 比对。

    不一致必须抛错（自动复核不得基于失真汇总继续）；SKIP 不计入 PASS。
    """
    recomputed = {"PASS": 0, "FAIL": 0, "SKIP": 0}
    for entry in summary.get("results", []):
        kind = str(entry.get("kind", "")).upper()
        if kind not in recomputed:
            raise ValueError("summary 校验失败：未知结果类型 %r" % kind)
        recomputed[kind] += 1
    for key in ("PASS", "FAIL", "SKIP"):
        if int(summary.get(key, -1)) != recomputed[key]:
            raise ValueError("summary 校验失败：顶层 %s=%r 与重算 %d 不一致" % (
                key, summary.get(key), recomputed[key]))
        if int(summary.get("counts", {}).get(key, -1)) != recomputed[key]:
            raise ValueError("summary 校验失败：counts.%s=%r 与重算 %d 不一致" % (
                key, summary.get("counts", {}).get(key), recomputed[key]))
    if recomputed["PASS"] + recomputed["FAIL"] + recomputed["SKIP"] != \
            len(summary.get("results", [])):
        raise ValueError("summary 校验失败：计数总和与 results 条数不一致")
    return recomputed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-id", default=time.strftime("e2e_%Y%m%d_%H%M%S"))
    args = parser.parse_args()
    run_dir = os.path.join(HERE, "logs", args.run_id)
    os.makedirs(run_dir, exist_ok=True)
    log("run_id=%s run_dir=%s" % (args.run_id, run_dir))
    run_e2e(run_dir)

    passed = sum(1 for _, kind, _ in _results if kind == "PASS")
    failed = sum(1 for _, kind, _ in _results if kind == "FAIL")
    skipped = sum(1 for _, kind, _ in _results if kind == "SKIP")
    counts = {"PASS": passed, "FAIL": failed, "SKIP": skipped}
    summary = {
        "run_id": args.run_id,
        # 顶层与 counts 双格式并存：旧汇总脚本读顶层 PASS/FAIL/SKIP，
        # 新统一格式读 counts.*（2026-09-07 复核约定），避免自动复核解析分歧。
        **counts,
        "counts": counts,
        "results": [{"item": i, "kind": k, "detail": d} for i, k, d in _results],
    }
    with open(os.path.join(run_dir, "summary.json"), "w", encoding="utf-8") as handle:
        json.dump(summary, handle, ensure_ascii=False, indent=2)
    # 自校验：重算与写入内容必须一致（不一致视为本轮失败，不允许带病汇总）。
    verify_summary(summary)
    log("summary 自校验通过（results 重算与顶层/counts 一致；SKIP 不计入 PASS）")
    log("=== E2E 汇总: PASS=%d FAIL=%d SKIP=%d（SKIP 不计入通过）===" % (passed, failed, skipped))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
