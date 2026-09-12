# -*- coding: utf-8 -*-
"""JSONL 回放工具：用固定剧本驱动图运行时，落盘输入/状态/意图/回执/汇总。

用途（方案 §10-Phase2、§11）：
- 不需要 API Key：模型一律用 FakeStructuredModel（脚本来自 JSONL 步骤）；
- 覆盖敌袭、目标死亡、路径失败、玩家接管、模型超时等场景；
- 每次运行使用独立 run_id 目录，输入/状态/意图/回执/汇总全部留痕，
  汇总由 results 重算并与顶层/counts 交叉校验（不一致即视为本轮失败）。

JSONL 步骤字段（每行一个对象）：
    tick            : 服务器 tick（必填）
    model           : {"strategy": <行为脚本>, "tactics": <行为脚本>} 追加到假模型脚本
    player          : {"kind": "override"|"release", "unit_ids": [...], "reason": ""}
    observation     : {"own": [...], "enemies": [...], "events": [...], "strategic": bool}
    receipts        : [<回执 dict>] 逐条覆盖权威通道的默认回执（模拟 PendingAuthority 等）
    expect          : 断言（见 _evaluate_expectations）
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from typing import Any, Dict, List, Optional

from .checkpoint import JsonCheckpointStore
from .pydantic_agents import FakeStructuredModel
from .runtime import AdjutantGraphRuntime, RuntimeConfig

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_RUN_ROOT = os.path.join(HERE, "logs")
DEFAULT_MATCH = "m-replay"
DEFAULT_PLAYER = "Player_1"
DEFAULT_RULES = "hash-replay"
SCENE_TANK = "res://source/match/units/tank.tscn"

PASS, FAIL, SKIP = "PASS", "FAIL", "SKIP"


class ReplayTransport:
    """回放通道：记录命令包，按步骤脚本返回回执（默认 Accepted）。"""

    def __init__(self) -> None:
        self.sent: List[Dict[str, Any]] = []
        self.script: List[Dict[str, Any]] = []

    def send_command(self, envelope: Dict[str, Any]) -> Dict[str, Any]:
        self.sent.append(dict(envelope))
        if self.script:
            receipt = dict(self.script.pop(0))
        else:
            receipt = {"ok": True, "accepted": True, "status": "Accepted"}
        receipt.setdefault("command_id", str(envelope.get("command_id", "")))
        receipt.setdefault("intent_id", str(envelope.get("intent_id", "")))
        receipt.setdefault("result", {})
        return receipt

    def heartbeat(self) -> bool:
        return True

    def close(self) -> None:
        return None

    def describe(self) -> str:
        return "ReplayTransport(sent=%d)" % len(self.sent)


# ---------------- 观测构造（与游戏侧 views 同构） ----------------

def build_header(tick: int, match_id: str, player_id: str, rules_version: str,
                 snapshot_id: Optional[int] = None) -> Dict[str, Any]:
    return {
        "schema_version": 1, "match_id": match_id, "player_id": player_id,
        "rules_version": rules_version,
        "snapshot_id": int(tick if snapshot_id is None else snapshot_id),
        "server_tick": int(tick),
    }


def build_rules(rules_version: str) -> Dict[str, Any]:
    return {
        "match_id": "",
        "rules_version": {"content_hash": rules_version},
        "unit_types": [
            {"id": "tank", "scene_path": SCENE_TANK},
            {"id": "worker", "scene_path": "res://source/match/units/worker.tscn"},
        ],
        "productions": [{"product_type_id": "tank", "cost": [{"kind": "a", "amount": 555}],
                         "allowed_producer_type_ids": ["vehicle_factory"]}],
        "constructions": [{"id": "vehicle_factory", "cost": [{"kind": "a", "amount": 600}],
                           "blueprint_scene_path": "res://source/match/units/vehicle_factory.tscn"}],
    }


def build_tactical(spec: Dict[str, Any], tick: int, match_id: str, player_id: str,
                   rules_version: str) -> Dict[str, Any]:
    entities: List[Dict[str, Any]] = []
    own = spec.get("own") or [{"name": "Unit_1"}]
    for unit in own:
        entities.append({
            "kind": "unit_self", "name": unit["name"],
            "unit_type": unit.get("unit_type", "tank"),
            "pos": list(unit.get("pos", [0.0, 0.0, 0.0])),
            "hp": float(unit.get("hp", 100.0)), "hp_max": 100.0,
            "movement": True, "attack": True,
        })
    for enemy in spec.get("enemies") or []:
        entities.append({
            "kind": "unit_enemy", "name": enemy["name"],
            "unit_type": enemy.get("unit_type", "tank"),
            "pos": list(enemy.get("pos", [20.0, 0.0, 20.0])),
            "hp": float(enemy.get("hp", 100.0)), "hp_max": 100.0,
            "last_seen_tick": int(tick), "confirmed_dead": False,
        })
    return {
        "schema_version": 1, "match_id": match_id, "player_id": player_id,
        "rules_version": rules_version, "snapshot_id": int(tick), "server_tick": int(tick),
        "entities": entities,
        "covered": {"self": len(own), "enemy": len(spec.get("enemies") or [])},
        "totals": {"self": len(own), "enemy": len(spec.get("enemies") or [])},
        "truncated": bool(spec.get("truncated", False)),
        "next_offset": -1, "balance": {"a": 1000, "b": 0}, "production": [],
        "outcome": {"finished": False},
    }


def build_observation(step: Dict[str, Any], tick: int, match_id: str, player_id: str,
                      rules_version: str) -> Dict[str, Any]:
    spec = step.get("observation") or {}
    header = spec.get("header") or build_header(
        tick, match_id, player_id, rules_version,
        snapshot_id=spec.get("snapshot_id"))
    # own/enemies 允许直接写在 observation 下（也可嵌套在 observation.tactical）。
    tactical_spec = spec.get("tactical")
    if not isinstance(tactical_spec, dict):
        tactical_spec = {"own": spec.get("own"), "enemies": spec.get("enemies"),
                         "truncated": spec.get("truncated", False)}
    tactical_view = None
    if spec.get("tactical", True) is not False:
        tactical_view = build_tactical(tactical_spec, tick, match_id, player_id,
                                       rules_version)
    strategic_summary = spec.get("strategic_summary")
    if not isinstance(strategic_summary, dict):
        strategic_summary = ({"resources": {"a": 1000, "b": 0}, "enemy_intel": []}
                             if spec.get("strategic", True) else None)
    observation: Dict[str, Any] = {
        "header": header,
        "strategic": strategic_summary,
        "tactical": tactical_view,
        "rules": build_rules(rules_version) if spec.get("rules", True) is not False else None,
        "events": list(spec.get("events") or []),
        "budget": {},
    }
    return observation


# ---------------- 回放执行 ----------------

def load_steps(path: str) -> List[Dict[str, Any]]:
    steps: List[Dict[str, Any]] = []
    with open(path, "r", encoding="utf-8") as handle:
        for line_no, raw in enumerate(handle, start=1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            try:
                item = json.loads(line)
            except ValueError as exc:
                raise ValueError("%s 第 %d 行不是合法 JSON：%s" % (path, line_no, exc))
            if not isinstance(item, dict):
                raise ValueError("%s 第 %d 行必须是 JSON 对象" % (path, line_no))
            item.setdefault("_line", line_no)
            steps.append(item)
    return steps


def run_replay(fixture: str, run_id: str, engine: str = "fallback",
               run_root: Optional[str] = None, match_id: str = DEFAULT_MATCH,
               player_id: str = DEFAULT_PLAYER,
               rules_version: str = DEFAULT_RULES) -> Dict[str, Any]:
    """执行一次回放；返回 summary（同时写入 run 目录）。"""
    steps = load_steps(fixture)
    run_root = run_root or DEFAULT_RUN_ROOT
    run_dir = os.path.join(run_root, run_id)
    os.makedirs(run_dir, exist_ok=True)

    transport = ReplayTransport()
    strategy = FakeStructuredModel("strategy", [])
    tactics = FakeStructuredModel("tactics", [])
    runtime = AdjutantGraphRuntime(
        match_id, player_id, transport=transport,
        strategy_model=strategy, tactics_model=tactics,
        checkpoint_store=JsonCheckpointStore(os.path.join(run_dir, "state"),
                                             match_id, player_id),
        config=RuntimeConfig(engine=engine, strategy_interval_ticks=100000,
                             tactics_interval_ticks=1, emergency_min_interval_ticks=1,
                             intent_ttl_ticks=600, emergency_intent_ttl_ticks=300),
    )

    results: List[Dict[str, Any]] = []
    inputs_path = os.path.join(run_dir, "inputs.jsonl")
    states_path = os.path.join(run_dir, "states.jsonl")
    intents_path = os.path.join(run_dir, "intents.jsonl")
    receipts_path = os.path.join(run_dir, "receipts.jsonl")

    with open(inputs_path, "w", encoding="utf-8") as inputs_handle, \
            open(states_path, "w", encoding="utf-8") as states_handle, \
            open(intents_path, "w", encoding="utf-8") as intents_handle, \
            open(receipts_path, "w", encoding="utf-8") as receipts_handle:
        for index, step in enumerate(steps):
            tick = int(step.get("tick", 0))
            model_script = step.get("model") or {}
            if model_script.get("strategy"):
                strategy._script.append(model_script["strategy"])
            if model_script.get("tactics"):
                tactics._script.append(model_script["tactics"])
            player_action = step.get("player") or None
            if player_action:
                units = [str(u) for u in player_action.get("unit_ids", [])]
                if str(player_action.get("kind")) == "release":
                    runtime.on_player_release(units, tick, str(player_action.get("reason", "")))
                else:
                    runtime.on_player_command(units, tick, str(player_action.get("reason", "")))
            transport.script = list(step.get("receipts") or [])
            sent_before = len(transport.sent)

            observation = build_observation(step, tick, match_id, player_id, rules_version)
            result = runtime.tick(tick, observation)

            inputs_handle.write(json.dumps({
                "run_id": run_id, "step": index, "tick": tick,
                "model": model_script, "player": player_action,
                "observation": observation}, ensure_ascii=False, sort_keys=True) + "\n")
            states_handle.write(json.dumps({
                "step": index, "tick": tick, "route": result.route,
                "paused": result.paused, "engine": result.engine,
                "degraded_reason": result.degraded_reason,
                "state": result.state}, ensure_ascii=False, sort_keys=True) + "\n")
            intents_handle.write(json.dumps({
                "step": index, "tick": tick,
                "intents": runtime.state.active_intents}, ensure_ascii=False, sort_keys=True) + "\n")
            for envelope, receipt in zip(transport.sent[sent_before:],
                                         result.receipts):
                receipts_handle.write(json.dumps({
                    "step": index, "tick": tick, "envelope": envelope,
                    "receipt": receipt}, ensure_ascii=False, sort_keys=True) + "\n")

            results.extend(_evaluate_expectations(step, result, runtime, transport,
                                                  sent_before, index))

    passed = sum(1 for item in results if item["kind"] == PASS)
    failed = sum(1 for item in results if item["kind"] == FAIL)
    skipped = sum(1 for item in results if item["kind"] == SKIP)
    counts = {"PASS": passed, "FAIL": failed, "SKIP": skipped}
    summary = {
        "run_id": run_id, "fixture": os.path.basename(fixture), "engine": runtime.runner.engine,
        "steps": len(steps), **counts, "counts": counts, "results": results,
        "dispatch_total": len(transport.sent),
        "state": runtime.state.summary(),
    }
    with open(os.path.join(run_dir, "summary.json"), "w", encoding="utf-8") as handle:
        json.dump(summary, handle, ensure_ascii=False, indent=2, sort_keys=True)
    verify_summary(summary)
    return summary


def _evaluate_expectations(step: Dict[str, Any], result, runtime,
                           transport: ReplayTransport, sent_before: int,
                           index: int) -> List[Dict[str, Any]]:
    expect = step.get("expect") or {}
    checks: List[Dict[str, Any]] = []
    label = "step%d/tick%s" % (index, step.get("tick"))

    def record(item: str, kind: str, detail: str = "") -> None:
        checks.append({"step": index, "item": "%s %s" % (label, item),
                       "kind": kind, "detail": detail})

    if "route" in expect:
        record("route=%s" % expect["route"],
               PASS if result.route == expect["route"] else FAIL,
               "actual=%s" % result.route)
    if "paused" in expect:
        record("paused=%s" % expect["paused"],
               PASS if bool(result.paused) == bool(expect["paused"]) else FAIL,
               "actual=%s" % result.paused)
    if "accepted" in expect:
        actual = sorted(result.accepted_intents)
        wanted = sorted(expect["accepted"])
        record("accepted=%s" % wanted, PASS if actual == wanted else FAIL,
               "actual=%s" % actual)
    if "accepted_contains" in expect:
        missing = [item for item in expect["accepted_contains"]
                   if item not in result.accepted_intents]
        record("accepted_contains=%s" % expect["accepted_contains"],
               PASS if not missing else FAIL, "missing=%s" % missing)
    for intent_id, reason in (expect.get("dropped") or {}).items():
        dropped = {item["intent_id"]: item["reason"] for item in result.dropped_intents}
        actual = dropped.get(intent_id, "<未出现>")
        record("dropped[%s]=%s" % (intent_id, reason),
               PASS if actual == reason else FAIL, "actual=%s" % actual)
    if "degraded_contains" in expect:
        record("degraded 含 %s" % expect["degraded_contains"],
               PASS if expect["degraded_contains"] in result.degraded_reason else FAIL,
               "actual=%s" % result.degraded_reason)
    if "player_controlled" in expect:
        actual = sorted(runtime.state.player_controlled_units)
        wanted = sorted(expect["player_controlled"])
        record("player_controlled=%s" % wanted, PASS if actual == wanted else FAIL,
               "actual=%s" % actual)
    if "no_dispatch" in expect:
        dispatched = len(transport.sent) - sent_before
        record("本周无下发", PASS if (dispatched == 0) == bool(expect["no_dispatch"]) else FAIL,
               "dispatched=%d" % dispatched)
    if "intent_state" in expect:
        for intent_id, wanted in expect["intent_state"].items():
            record_ = runtime.state.find_intent(intent_id)
            actual = record_.get("state") if record_ else "<未出现>"
            record("intent_state[%s]=%s" % (intent_id, wanted),
                   PASS if actual == wanted else FAIL, "actual=%s" % actual)
    if "plan_version" in expect:
        record("plan_version=%s" % expect["plan_version"],
               PASS if runtime.state.plan_version == expect["plan_version"] else FAIL,
               "actual=%s" % runtime.state.plan_version)
    if "generation_increased" in expect:
        units = [str(u) for u in expect["generation_increased"]]
        ok = all(runtime.state.generation_of(unit) > 0 for unit in units)
        record("generation 已分配", PASS if ok else FAIL,
               "generations=%s" % {u: runtime.state.generation_of(u) for u in units})
    if not checks:
        record("步骤执行", PASS, "无断言（仅留痕）")
    return checks


def verify_summary(summary: Dict[str, Any]) -> Dict[str, int]:
    """重算 PASS/FAIL/SKIP 并与顶层/counts 交叉校验；不一致必须抛错。"""
    recomputed = {"PASS": 0, "FAIL": 0, "SKIP": 0}
    for item in summary.get("results", []):
        kind = str(item.get("kind", "")).upper()
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
    return recomputed


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="副官图 JSONL 回放")
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--run-id", default=time.strftime("replay_%Y%m%d_%H%M%S"))
    parser.add_argument("--engine", default="fallback", choices=("auto", "fallback", "langgraph"))
    parser.add_argument("--run-root", default=DEFAULT_RUN_ROOT)
    args = parser.parse_args(argv)
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass
    summary = run_replay(args.fixture, args.run_id, engine=args.engine,
                         run_root=args.run_root)
    print("run_id=%s fixture=%s engine=%s" % (summary["run_id"], summary["fixture"],
                                              summary["engine"]))
    for item in summary["results"]:
        print("  [%s] %s%s" % (item["kind"], item["item"],
                              (" | " + item["detail"]) if item["detail"] else ""))
    print("=== 回放汇总: PASS=%d FAIL=%d SKIP=%d ===" % (
        summary["PASS"], summary["FAIL"], summary["SKIP"]))
    return 0 if summary["FAIL"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
