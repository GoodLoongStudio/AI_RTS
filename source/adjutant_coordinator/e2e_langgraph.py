# -*- coding: utf-8 -*-
"""LangGraph 副官图本地双进程 E2E（独立测试局服，禁止触碰线上局服）。

进程拓扑与 e2e_dual_layer.py 完全一致（复用其 TCP 帮助函数）：
  权威服  Godot --headless -- --server --port 24569 --debugport 24572
  客户端  Godot --headless -- -- --debugport 24570 --autojoin --autojoin-lobby
          --smokehost 127.0.0.1 --smokeport 24569

验证场景（方案 §10-Phase3、§8、§13）：
  1. 战略计划经图采纳，战略层本身不下发任何命令；
  2. 紧急战术意图经 op=adjutant_intent 被权威层接受，op=adjutant_leases 可查租约代际；
  3. 玩家手动命令（旧 op 路径）→ 图内旧意图失效，且不下发（第一道防线）；
  4. 权威层独立防线：绕过图直接提交的旧代际意图被 StaleGeneration / PlayerOverride 拒绝；
  5. 显式归还后 reacquire 意图被接受（重新接管），再提交旧代际意图仍被拒；
  6. 非法目标（错误生产者生产 tank）被权威规则视图拒绝（模型不能绕过规则）；
  7. checkpoint 恢复后不重复下单。

判定：PASS=实际执行且符合预期；FAIL=实际执行但结果错误；SKIP=条件不满足。
每次运行使用独立 run_id 目录，保留输入/状态/意图/回执/汇总与两侧进程日志。
"""

import argparse
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))

import e2e_dual_layer as base  # noqa: E402 —— 复用端口/进程/TCP 帮助函数

from adjutant_coordinator.graph.checkpoint import JsonCheckpointStore  # noqa: E402
from adjutant_coordinator.graph.contracts import intent_to_command_envelope  # noqa: E402
from adjutant_coordinator.graph.pydantic_agents import FakeStructuredModel  # noqa: E402
from adjutant_coordinator.graph.runtime import (  # noqa: E402
    AdjutantGraphRuntime, RuntimeConfig,
)

SERVER_DBG = base.SERVER_DBG
CLIENT_DBG = base.CLIENT_DBG
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


def tcp(payload, port=SERVER_DBG, timeout=30.0):
    return base.tcp_call(port, payload, timeout=timeout)


# ---------------- 通道适配 ----------------

class TcpIntentTransport:
    """把图下发的意图命令包直接投递到游戏权威调试端点（op=adjutant_intent）。"""

    def __init__(self, port):
        self.port = port
        self.sent = []

    def send_command(self, envelope):
        self.sent.append(dict(envelope))
        try:
            receipt = base.tcp_call(self.port, envelope, timeout=30.0)
        except Exception as exc:  # noqa: BLE001 —— 通道异常结构化，不炸图。
            return {"ok": False, "accepted": False, "status": "TransportError",
                    "reason": str(exc), "command_id": str(envelope.get("command_id", "")),
                    "intent_id": str(envelope.get("intent_id", "")), "result": {}}
        if not isinstance(receipt, dict):
            receipt = {"ok": False, "accepted": False, "status": "BadReceipt",
                       "reason": "非对象回执", "result": {}}
        receipt.setdefault("command_id", str(envelope.get("command_id", "")))
        receipt.setdefault("intent_id", str(envelope.get("intent_id", "")))
        receipt.setdefault("result", {})
        return receipt

    def heartbeat(self):
        return True

    def close(self):
        return None

    def describe(self):
        return "TcpIntentTransport(port=%d, sent=%d)" % (self.port, len(self.sent))


def make_recheck():
    """按 command_id 复核终态；PendingAuthority 继续等待（不重下单）。"""
    def recheck(command_id):
        if not command_id:
            return None
        result = tcp({"op": "commands", "command_id": command_id})
        entries = result.get("commands", []) or []
        if not entries:
            return None
        entry = entries[0]
        status = str(entry.get("status", ""))
        if status in ("", "Unknown", "PendingAuthority"):
            return None
        return {"command_id": command_id, "status": status,
                "accepted": bool(entry.get("accepted", False)),
                "reason": str(entry.get("reason", "")),
                "intent_id": str(entry.get("intent_id", ""))}
    return recheck


# ---------------- 用例辅助 ----------------

def intent_batch(intent):
    return {"batch_id": "e2e-%s" % intent["intent_id"], "match_id": MATCH,
            "player_id": PLAYER, "plan_version": PLAN_VERSION,
            "based_on_snapshot": intent.get("based_on_snapshot", 0),
            "intents": [intent]}


def move_intent(intent_id, unit, dest, tick, snapshot, generation=0, reacquire=False,
                priority=2, task_id="t-move"):
    """意图的 based_on_snapshot 必须取自观测包头（不是 server_tick）。"""
    return {"intent_id": intent_id, "plan_version": PLAN_VERSION, "task_id": task_id,
            "unit_ids": [unit], "action": "move", "target": {"pos": [dest[0], dest[1]]},
            "priority": priority, "based_on_snapshot": int(snapshot), "issued_tick": tick,
            "expires_tick": tick + 240, "generation": generation, "abort_when": [],
            "emergency": False, "reacquire": reacquire, "rationale": "E2E 移动意图"}


def produce_intent(intent_id, producer, scene, tick, snapshot, task_id="t-build"):
    return {"intent_id": intent_id, "plan_version": PLAN_VERSION, "task_id": task_id,
            "unit_ids": [producer], "action": "produce",
            "target": {"scene": scene, "producer": producer},
            "priority": 3, "based_on_snapshot": int(snapshot), "issued_tick": tick,
            "expires_tick": tick + 240, "generation": 0, "abort_when": [],
            "emergency": False, "reacquire": False, "rationale": "E2E 生产意图"}


class Driver:
    """把本地图运行时的观测/事件/模型脚本串起来（每 tick 独立观测）。"""

    def __init__(self, run_dir, transport, player_name, worker_name):
        self.run_dir = run_dir
        self.transport = transport
        self.player_name = player_name
        self.worker_name = worker_name
        self.strategy = FakeStructuredModel("strategy", [])
        self.tactics = FakeStructuredModel("tactics", [])
        self.events = []
        self.last_tick = 0
        self.last_snapshot = 0
        self.states_path = open(os.path.join(run_dir, "graph_states.jsonl"), "w",
                                encoding="utf-8")
        self.intents_path = open(os.path.join(run_dir, "graph_intents.jsonl"), "w",
                                 encoding="utf-8")
        self.receipts_path = open(os.path.join(run_dir, "graph_receipts.jsonl"), "w",
                                  encoding="utf-8")
        self.runtime = AdjutantGraphRuntime(
            MATCH, PLAYER, transport=transport, strategy_model=self.strategy,
            tactics_model=self.tactics,
            checkpoint_store=JsonCheckpointStore(os.path.join(run_dir, "state"),
                                                 MATCH, PLAYER),
            config=RuntimeConfig(engine="fallback", strategy_interval_ticks=100000,
                                 tactics_interval_ticks=1, emergency_min_interval_ticks=1),
            recheck_fn=make_recheck())

    def close(self):
        for handle in (self.states_path, self.intents_path, self.receipts_path):
            try:
                handle.close()
            except Exception:
                pass

    def observation(self):
        tactical = tcp({"op": "tactical", "as_player": self.player_name})
        tick = int(tactical.get("server_tick", 0))
        self.last_tick = tick
        self.last_snapshot = int(tactical.get("snapshot_id", tick))
        return tick, {
            "header": {"schema_version": 1, "match_id": MATCH, "player_id": PLAYER,
                       "rules_version": RULES_VERSION,
                       "snapshot_id": int(tactical.get("snapshot_id", tick)),
                       "server_tick": tick},
            "strategic": None,
            "tactical": tactical,
            "rules": RULES_VIEW,
            "events": list(self.events),
            "budget": {},
        }

    def tick(self):
        tick, observation = self.observation()
        self.events = []
        sent_before = len(self.transport.sent)
        result = self.runtime.tick(tick, observation)
        self.states_path.write(json.dumps({
            "tick": tick, "route": result.route, "paused": result.paused,
            "accepted": result.accepted_intents,
            "dropped": result.dropped_intents,
            "degraded_reason": result.degraded_reason,
            "state": result.state}, ensure_ascii=False) + "\n")
        self.states_path.flush()
        self.intents_path.write(json.dumps({
            "tick": tick, "intents": self.runtime.state.active_intents},
            ensure_ascii=False) + "\n")
        self.intents_path.flush()
        for receipt in result.receipts:
            self.receipts_path.write(json.dumps(receipt, ensure_ascii=False) + "\n")
        self.receipts_path.flush()
        return tick, result


def pids_on_port(port):
    """netstat 监听进程查询（显式 utf-8/replace：中文系统输出含非 UTF8 字节）。"""
    output = base.subprocess.run(["netstat", "-ano", "-p", "TCP"], capture_output=True,
                                 text=True, encoding="utf-8",
                                 errors="replace").stdout or ""
    pids = set()
    for line in output.splitlines():
        parts = line.split()
        if len(parts) >= 5 and parts[1].endswith(":%d" % port) and parts[3] == "LISTENING":
            pids.add(parts[4])
    return pids


def free_test_ports():
    """启动前清空本地测试端口占用（只碰 24569/24570/24572，不碰线上局服）。"""
    for port in (base.SERVER_PORT, base.SERVER_DBG, CLIENT_DBG):
        for pid in pids_on_port(port):
            log("清理端口 %d 上的残留进程 %s" % (port, pid))
            base.kill_tree(pid)
    time.sleep(2.0)


def run_e2e(run_dir, run_id):
    global MATCH, PLAYER, RULES_VERSION, RULES_VIEW, PLAN_VERSION
    procs = []
    driver = None
    free_test_ports()
    log_path_server = open(os.path.join(run_dir, "server.log"), "wb")
    log_path_client = open(os.path.join(run_dir, "client.log"), "wb")
    try:
        baseline = base.subprocess.run(
            ["git", "-C", base.AI_RTS, "log", "-1", "--format=%H %ci %s"],
            capture_output=True, text=True, encoding="utf-8", errors="replace").stdout.strip()
        log("baseline commit: %s" % baseline)
        with open(os.path.join(run_dir, "baseline.txt"), "w", encoding="utf-8") as handle:
            handle.write(baseline + "\n")

        server_args = [base.GODOT, "--headless", "--path", base.AI_RTS, "--",
                       "--server", "--port", str(base.SERVER_PORT),
                       "--debugport", str(base.SERVER_DBG),
                       "--balance-config=" + base.BALANCE,
                       "--assets-manifest=" + base.MANIFEST]
        procs.append(base.subprocess.Popen(server_args, stdout=log_path_server,
                                           stderr=base.subprocess.STDOUT,
                                           creationflags=base.subprocess.CREATE_NO_WINDOW))
        client_args = [base.GODOT, "--headless", "--path", base.AI_RTS, "--",
                       "--debugport", str(CLIENT_DBG), "--autojoin", "--autojoin-lobby",
                       "--smokehost", "127.0.0.1", "--smokeport", str(base.SERVER_PORT),
                       "--balance-config=" + base.BALANCE,
                       "--assets-manifest=" + base.MANIFEST]
        procs.append(base.subprocess.Popen(client_args, stdout=log_path_client,
                                          stderr=base.subprocess.STDOUT,
                                          creationflags=base.subprocess.CREATE_NO_WINDOW))

        if not expect("调试端口就绪",
                      base.wait_port(base.SERVER_DBG, 40) and base.wait_port(CLIENT_DBG, 40),
                      "server:%d client:%d" % (base.SERVER_DBG, CLIENT_DBG)):
            return
        # 解析脚本自身是否被引擎接受（parse error 会直接写进日志）。
        time.sleep(1.0)
        parse_error = _scan_parse_error(os.path.join(run_dir, "server.log"))
        expect("DebugControlServer.gd 无解析错误", not parse_error,
               "未发现 Parse Error" if not parse_error else parse_error[:200])

        networked = False
        client_error = ""
        for _ in range(15):
            time.sleep(2)
            try:
                status = tcp({"op": "status", "lite": True}, port=CLIENT_DBG)
            except Exception as exc:  # noqa: BLE001 —— 客户端端点不可达：明确失败，不静默。
                client_error = str(exc)
                continue
            if status.get("networked") is True:
                networked = True
                break
        expect("客户端联网（networked=true）", networked,
               fail_detail="客户端调试端点不可达或未联网：%s" % client_error)
        if not networked:
            return
        start = tcp({"op": "start", "with_ai": False}, port=CLIENT_DBG)
        expect("开局指令已发出", start.get("ok") is True)
        ready = False
        for _ in range(20):
            time.sleep(2)
            try:
                if tcp({"op": "status", "lite": True}).get("match") is True:
                    ready = True
                    break
            except Exception:  # noqa: BLE001
                continue
        expect("对局已就绪", ready)
        if not ready:
            return

        rules = tcp({"op": "rules"})
        expect("规则视图可导出", not rules.get("error"))
        MATCH = str(rules.get("match_id", ""))
        RULES_VERSION = str(rules.get("rules_version", {}).get("content_hash", ""))
        types = {t["id"]: t for t in rules.get("unit_types", [])}
        PLAN_VERSION = "e2e-plan:v1"
        RULES_VIEW = rules

        players = []
        units = []
        for _ in range(25):
            time.sleep(2)
            status = tcp({"op": "status"})
            units = status.get("units", [])
            humans = [p for p in status.get("players", []) if p.get("human") is True]
            if units and humans:
                players = humans
                break
        expect("对局单位已装载且解析到人类玩家", bool(units and players))
        if not (units and players):
            return
        PLAYER = str(players[0]["name"])
        worker = next((u for u in units if str(u.get("unit_type", "")) == "worker"), None)
        command_center = next((u for u in units
                               if str(u.get("unit_type", "")) == "command_center"), None)
        if not expect("存在 worker 与 command_center", worker is not None and
                      command_center is not None):
            return
        worker_name = str(worker["name"])
        cc_name = str(command_center["name"])

        transport = TcpIntentTransport(base.SERVER_DBG)
        driver = Driver(run_dir, transport, PLAYER, worker_name)
        worker_pos = [float(worker["pos"][0]), float(worker["pos"][2])]

        # ---- 场景 1：战略计划（图内）不下发命令 ----
        driver.strategy._script.append({"behavior": "completed", "plan": {
            "plan_id": "e2e-plan", "plan_version": 1, "match_id": MATCH,
            "player_id": PLAYER, "rules_version": RULES_VERSION,
            "based_on_snapshot": 0, "valid_until_tick": 10 ** 7,
            "phase_goal": "E2E：工人前压并建立生产",
            "tasks": [{"task_id": "t-move", "priority": 1,
                       "completion": "工人抵达前压点", "units": [worker_name],
                       "unit_constraint": "", "target_type": "",
                       "allowed_actions": ["move"]}],
            "reserves": {}, "rationale": "E2E", "abort_when": ["base_under_attack"]}})
        driver.tick()
        expect("战略节点采纳计划", driver.runtime.state.plan_version == PLAN_VERSION,
               "plan_version=%s" % driver.runtime.state.plan_version)
        expect("战略层本身不下发命令", len(transport.sent) == 0,
               "sent=%d" % len(transport.sent))

        # ---- 场景 2：紧急战术意图被权威层接受 ----
        dest = [worker_pos[0] + 6.0, worker_pos[1] + 6.0]
        driver.events.append({"event_id": "e2e-evt-spot", "kind": "enemy_spotted",
                              "server_tick": 0, "payload": {"subject": worker_name}})
        pre_tick = int(tcp({"op": "tactical", "as_player": PLAYER}).get("server_tick", 0))
        driver.tactics._script.append({"behavior": "completed", "intents": intent_batch(
            move_intent("i-move-1", worker_name, dest, pre_tick, driver.last_snapshot))})
        tick2, second = driver.tick()
        expect("紧急意图被仲裁接受", second.accepted_intents == ["i-move-1"],
               "accepted=%s dropped=%s" % (second.accepted_intents, second.dropped_intents))
        expect("权威层接受移动意图（Accepted）",
               bool(second.receipts) and str(second.receipts[0].get("status")) == "Accepted",
               "receipt=%s" % json.dumps(second.receipts)[:200])

        leases = tcp({"op": "adjutant_leases", "player_id": PLAYER})
        lease = (leases.get("leases") or {}).get(worker_name, {})
        expect("op=adjutant_leases 可查租约与意图登记",
               bool(lease) and bool(leases.get("intents")),
               "lease=%s" % json.dumps(lease)[:160])
        intent_gen = int(driver.runtime.state.generation_of(worker_name))
        game_lease_gen = int(lease.get("generation", 0) or 0)
        # 跨进程一致性判据：游戏侧意图登记里记录的代际必须等于图内控制代际
        # （两个计数器各自独立递增，不能直接比较绝对数值）。
        registered = (leases.get("intents") or {}).get("i-move-1", {})
        expect("游戏侧意图登记记录的控制代际与图内一致",
               int(registered.get("generation", -1)) == intent_gen,
               "game_registered=%s graph=%s" % (registered.get("generation"), intent_gen))

        # ---- 场景 3：玩家手动命令 → 图内旧意图失效且不下发 ----
        manual = tcp({"op": "move", "as_player": PLAYER, "units": [worker_name],
                      "dest": [worker_pos[0] + 2.0, worker_pos[1] + 2.0]})
        expect("玩家手动命令（旧 op 路径）成功", manual.get("accepted") is True,
               "status=%s" % manual.get("status"))
        driver.runtime.on_player_command([worker_name], server_tick=tick2)
        expect("玩家接管立即失效旧意图",
               (driver.runtime.state.find_intent("i-move-1") or {}).get("state") == "dropped")
        sent_before_override = len(transport.sent)
        _, paused = driver.tick()
        expect("玩家打断使图暂停（LangGraph interrupt 语义）", paused.paused is True)
        driver.tick()
        expect("恢复后不补发旧意图", len(transport.sent) == sent_before_override,
               "sent=%d" % len(transport.sent))

        # ---- 场景 4：权威层独立防线（绕过图直接提交旧代际意图） ----
        stale = tcp({"op": "adjutant_intent", "command_id": "e2e-stale-probe",
                     "intent_id": "i-stale-probe", "match_id": MATCH, "player_id": PLAYER,
                     "rules_version": RULES_VERSION, "plan_version": PLAN_VERSION,
                     "task_id": "t-move", "based_on_snapshot": driver.last_snapshot,
                     "issued_tick": tick2, "expires_tick": tick2 + 240,
                     "generation": game_lease_gen, "action": "move",
                     "params": {"units": [worker_name], "dest": dest}})
        expect("权威层拒绝玩家接管后的旧意图",
               str(stale.get("status")) in ("PlayerOverride", "StaleGeneration"),
               "status=%s reason=%s" % (stale.get("status"), str(stale.get("reason"))[:80]))

        # ---- 场景 5：显式归还 + reacquire 重新接管 ----
        release_tick = int(tcp({"op": "tactical", "as_player": PLAYER}).get("server_tick", 0))
        driver.runtime.on_player_release([worker_name], server_tick=release_tick)
        driver.tick()   # 玩家归还 → 暂停
        driver.tick()   # 恢复
        driver.events.append({"event_id": "e2e-evt-idle", "kind": "queue_idle",
                              "server_tick": release_tick, "payload": {"subject": worker_name}})
        reacquire_tick = int(tcp({"op": "tactical",
                                  "as_player": PLAYER}).get("server_tick", 0))
        driver.tactics._script.append({"behavior": "completed", "intents": intent_batch(
            move_intent("i-reacquire", worker_name,
                        [worker_pos[0] - 5.0, worker_pos[1] + 3.0], reacquire_tick,
                        driver.last_snapshot, reacquire=True))})
        _, fifth = driver.tick()
        expect("显式归还后 reacquire 意图被接受",
               fifth.accepted_intents == ["i-reacquire"],
               "accepted=%s dropped=%s" % (fifth.accepted_intents, fifth.dropped_intents))
        expect("reacquire 被权威层接受（Accepted）",
               bool(fifth.receipts) and str(fifth.receipts[0].get("status")) == "Accepted",
               "receipt=%s" % json.dumps(fifth.receipts)[:200])
        leases = tcp({"op": "adjutant_leases", "player_id": PLAYER})
        new_gen = int((leases.get("leases") or {}).get(worker_name, {}).get("generation", -1))
        expect("重新接管后租约代际更新", new_gen > game_lease_gen,
               "old=%s new=%s" % (game_lease_gen, new_gen))

        # 旧代际意图（严格落后于新租约代际）必须被权威层显式拒绝。
        stale2 = tcp({"op": "adjutant_intent", "command_id": "e2e-stale-gen-2",
                      "intent_id": "i-stale-gen-2", "match_id": MATCH,
                      "player_id": PLAYER, "rules_version": RULES_VERSION,
                      "plan_version": PLAN_VERSION, "task_id": "t-move",
                      "based_on_snapshot": driver.last_snapshot,
                      "issued_tick": reacquire_tick, "expires_tick": reacquire_tick + 240,
                      "generation": game_lease_gen, "action": "move",
                      "params": {"units": [worker_name], "dest": dest}})
        expect("旧代际意图被权威层拒绝（StaleGeneration）",
               str(stale2.get("status")) == "StaleGeneration",
               "status=%s reason=%s" % (stale2.get("status"),
                                        str(stale2.get("reason"))[:100]))

        # ---- 场景 6：非法目标被权威规则视图拒绝 ----
        illegal_scene = str(types.get("tank", {}).get("scene_path", ""))
        illegal_tick = int(tcp({"op": "tactical",
                                "as_player": PLAYER}).get("server_tick", 0))
        illegal = tcp({"op": "adjutant_intent", "command_id": "e2e-illegal-produce",
                       "intent_id": "i-illegal-produce", "match_id": MATCH,
                       "player_id": PLAYER, "rules_version": RULES_VERSION,
                       "plan_version": PLAN_VERSION, "task_id": "t-build",
                       "based_on_snapshot": driver.last_snapshot, "issued_tick": illegal_tick,
                       "expires_tick": illegal_tick + 240, "generation": 0,
                       "action": "produce",
                       "params": {"units": [cc_name], "producer": cc_name,
                                  "scene": illegal_scene}})
        expect("模型无法绕过规则（CommandCenter 生产 tank 被拒）",
               str(illegal.get("status")) in ("InvalidProducer", "ProductNotAllowed",
                                              "UntrustedScene"),
               "status=%s reason=%s" % (illegal.get("status"),
                                        str(illegal.get("reason"))[:100]))

        # ---- 场景 7：checkpoint 恢复不重复下单 ----
        saved = driver.runtime.checkpoint()
        expect("checkpoint 已写入（按对局隔离）", bool(saved.get("saved")),
               json.dumps(saved)[:160])
        restarted_transport = TcpIntentTransport(base.SERVER_DBG)
        restarted = AdjutantGraphRuntime(
            MATCH, PLAYER, transport=restarted_transport,
            strategy_model=FakeStructuredModel("strategy", []),
            tactics_model=FakeStructuredModel("tactics", []),
            checkpoint_store=JsonCheckpointStore(os.path.join(run_dir, "state"),
                                                 MATCH, PLAYER),
            config=RuntimeConfig(engine="fallback", strategy_interval_ticks=100000,
                                 tactics_interval_ticks=1, emergency_min_interval_ticks=1))
        restore = restarted.restore()
        expect("重启后可从 checkpoint 恢复", bool(restore.get("restored")),
               json.dumps(restore)[:200])
        expect("恢复后保留计划与活跃意图",
               restarted.state.plan_version == PLAN_VERSION and
               any(i.get("state") == "active" for i in restarted.state.active_intents),
               "plan=%s intents=%s" % (restarted.state.plan_version,
                                       [i.get("intent_id") for i in restarted.state.active_intents]))
        tick_after = int(tcp({"op": "tactical", "as_player": PLAYER}).get("server_tick", 0))
        observation = driver.observation()[1]
        observation["events"] = []
        restarted_result = restarted.tick(tick_after, observation)
        expect("恢复后不重复下单", len(restarted_transport.sent) == 0,
               "sent=%d accepted=%s" % (len(restarted_transport.sent),
                                        restarted_result.accepted_intents))
        with open(os.path.join(run_dir, "graph_restart_state.json"), "w",
                  encoding="utf-8") as handle:
            json.dump(restarted.state.to_dict(), handle, ensure_ascii=False, indent=2)
    except Exception as exc:  # noqa: BLE001 —— 任何步骤异常都必须留下 FAIL 证据再清理进程。
        check("E2E 执行异常（已记录并清理进程）", "FAIL",
              "%s: %s" % (type(exc).__name__, exc))
    finally:
        if driver is not None:
            driver.close()
        for proc in procs:
            try:
                if proc.poll() is None:
                    base.kill_tree(proc.pid)
            except Exception:
                pass
        for port in (base.SERVER_PORT, base.SERVER_DBG, CLIENT_DBG):
            for pid in pids_on_port(port):
                base.kill_tree(pid)
        time.sleep(4.0)
        log_path_server.close()
        log_path_client.close()


def _scan_parse_error(path):
    try:
        with open(path, "rb") as handle:
            text = handle.read().decode("utf-8", errors="replace")
    except OSError:
        return ""
    for line in text.splitlines():
        if "Parse Error" in line or "Failed to load script" in line:
            return line
    return ""


MATCH = ""
PLAYER = ""
RULES_VERSION = ""
RULES_VIEW = {}
PLAN_VERSION = "e2e-plan:v1"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-id", default=time.strftime("e2e_langgraph_%Y%m%d_%H%M%S"))
    args = parser.parse_args()
    run_dir = os.path.join(HERE, "logs", args.run_id)
    os.makedirs(run_dir, exist_ok=True)
    log("run_id=%s run_dir=%s" % (args.run_id, run_dir))
    run_e2e(run_dir, args.run_id)

    passed = sum(1 for _, kind, _ in _results if kind == "PASS")
    failed = sum(1 for _, kind, _ in _results if kind == "FAIL")
    skipped = sum(1 for _, kind, _ in _results if kind == "SKIP")
    counts = {"PASS": passed, "FAIL": failed, "SKIP": skipped}
    summary = {
        "run_id": args.run_id,
        "engine": "fallback",
        "match_id": MATCH,
        "player_id": PLAYER,
        "rules_version": RULES_VERSION,
        **counts,
        "counts": counts,
        "results": [{"item": item, "kind": kind, "detail": detail}
                    for item, kind, detail in _results],
    }
    with open(os.path.join(run_dir, "summary.json"), "w", encoding="utf-8") as handle:
        json.dump(summary, handle, ensure_ascii=False, indent=2)
    base.verify_summary(summary)
    log("summary 自校验通过（results 重算与顶层/counts 一致；SKIP 不计入 PASS）")
    log("=== LangGraph E2E 汇总: PASS=%d FAIL=%d SKIP=%d ===" % (passed, failed, skipped))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
