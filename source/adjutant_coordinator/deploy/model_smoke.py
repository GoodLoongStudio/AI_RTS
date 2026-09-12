# -*- coding: utf-8 -*-
"""真实模型冒烟：用真实 Provider 各跑一次战略/战术节点，测延迟并校验契约与引用。

用途（方案 §10-Phase5/6 的入口验证）：
- 确认 Provider/模型/Key 可用，PydanticAI 结构化输出被模型接受；
- 校验模型输出能否通过契约（StrategicPlan / IntentBatch）与引用校验
  （unit_ids 必须来自观测、scene 必须来自规则视图）；
- 输出 JSON：每次调用耗时、结果、错误原因；不做任何游戏命令下发。

用法（服务器）：
  LLM_* 环境变量来自 /opt/airts-agent/.env
  .venv/bin/python deploy/model_smoke.py --authority-port 24572 --as-player Player_0
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from typing import Any, Dict, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))  # source/ 目录
sys.path.insert(0, HERE)  # deploy/ 自身（godot_tcp）

from godot_tcp import assert_allowed, PortNotAllowed, tcp_json  # noqa: E402
from env_file import load_env_file  # noqa: E402
from adjutant_coordinator.graph.contracts import (  # noqa: E402
    ContractError, parse_intent_batch, parse_strategic_plan,
)
from adjutant_coordinator.graph.model_context import (  # noqa: E402
    build_strategy_context, build_tactics_context, known_entity_ids, own_unit_ids,
    rules_scene_paths, validate_intent_references,
)
from adjutant_coordinator.graph.pydantic_agents import (  # noqa: E402
    GraphModelSettings, ModelInvalidOutput, ModelTimeout, ModelUnavailable,
    PydanticAIStrategyAgent, PydanticAITacticsAgent, pydantic_ai_available,
)
from adjutant_coordinator.graph.state import AdjutantGraphState  # noqa: E402



def canned_rules() -> Dict[str, Any]:
    """离线兜底规则视图（与游戏 unit_types 结构一致，仅用于无对局时的冒烟）。"""
    return {
        "match_id": "smoke-match",
        "rules_version": {"content_hash": "smoke-rules"},
        "unit_types": [
            {"id": "worker", "scene_path": "res://source/match/units/worker.tscn"},
            {"id": "command_center",
             "scene_path": "res://source/match/units/command_center.tscn"},
        ],
        "productions": [],
        "constructions": [],
    }


def canned_tactical(rules: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "schema_version": 1, "match_id": "smoke-match", "player_id": "Player_0",
        "rules_version": "smoke-rules", "snapshot_id": 10, "server_tick": 100,
        "entities": [
            {"kind": "unit_self", "name": "Unit_1", "unit_type": "worker",
             "pos": [8.0, 0.0, 8.0], "hp": 100.0, "hp_max": 100.0,
             "movement": True, "attack": False, "queue": False},
            {"kind": "unit_self", "name": "Unit_2", "unit_type": "command_center",
             "pos": [6.0, 0.0, 6.0], "hp": 2000.0, "hp_max": 2000.0,
             "movement": False, "attack": False, "queue": False},
        ],
        "covered": {"self": 2, "enemy": 0}, "totals": {"self": 2, "enemy": 0},
        "truncated": False, "next_offset": -1,
        "balance": {"a": 1000, "b": 0}, "production": [],
        "outcome": {"finished": False},
    }


def canned_strategic() -> Dict[str, Any]:
    return {"schema_version": 1, "match_id": "smoke-match", "player_id": "Player_0",
            "server_tick": 100, "snapshot_id": 10, "resources": {"a": 1000, "b": 0},
            "enemy_intel": [], "map_bounds": [200.0, 200.0],
            "available_actions": ["move", "attack", "attack_move", "produce", "build"],
            "production_relations": [], "buildable": [], "production": []}


def _safe_read(port: int, payload: Dict[str, Any]) -> Dict[str, Any]:
    try:
        return tcp_json(port, payload)
    except OSError as exc:  # 端点未启动：返回结构化错误，交给兜底路径
        return {"error": "unreachable", "reason": str(exc)}


def fetch_views(port: int, as_player: str) -> Dict[str, Any]:
    """从本机权威端点读规则/战术/战略视图；不可达时回落到兜底视图（明确标注）。"""
    sources: Dict[str, str] = {}
    rules = _safe_read(port, {"op": "rules"})
    rules_reason = rules.get("error") or ("" if rules.get("unit_types") else "no-unit-types")
    if rules_reason:
        rules = canned_rules()
        sources["rules"] = "canned(%s)" % rules_reason
    else:
        sources["rules"] = "live"
    tactical = _safe_read(port, {"op": "tactical", "as_player": as_player})
    tactical_reason = tactical.get("error") or ("" if tactical.get("entities")
                                                else "no-entities")
    if tactical_reason:
        tactical = canned_tactical(rules)
        sources["tactical"] = "canned(%s)" % tactical_reason
    else:
        sources["tactical"] = "live"
    strategic = _safe_read(port, {"op": "strategic", "as_player": as_player})
    if strategic.get("error"):
        sources["strategic"] = "canned(%s)" % strategic["error"]
        strategic = canned_strategic()
    else:
        sources["strategic"] = "live"
    return {"rules": rules, "tactical": tactical, "strategic": strategic,
            "sources": sources}


def _jsonable(value: Any) -> Any:
    """把契约对象转成可 JSON 化结构（pydantic 模型 / 自定义 to_dict）。"""
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, (list, tuple)):
        return [_jsonable(item) for item in value]
    if isinstance(value, dict):
        return {str(key): _jsonable(item) for key, item in value.items()}
    for method in ("to_dict", "model_dump"):
        if hasattr(value, method):
            try:
                return _jsonable(getattr(value, method)())
            except TypeError:
                return _jsonable(getattr(value, method)(mode="json"))
    return str(value)


def timed(callable_obj, *args, **kwargs):
    start = time.time()
    try:
        value = callable_obj(*args, **kwargs)
        return {"ok": True, "value": value, "latency_s": round(time.time() - start, 3),
                "error": ""}
    except (ModelTimeout, ModelUnavailable, ModelInvalidOutput) as exc:
        return {"ok": False, "value": None, "latency_s": round(time.time() - start, 3),
                "error": "%s: %s" % (type(exc).__name__, exc)}
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "value": None, "latency_s": round(time.time() - start, 3),
                "error": "%s: %s" % (type(exc).__name__, exc)}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="真实模型冒烟（战略+战术各一次）")
    parser.add_argument("--authority-port", type=int, default=24572)
    parser.add_argument("--as-player", default="")
    parser.add_argument("--out", default="")
    parser.add_argument("--env-file", default="",
                        help="模型配置 env 文件（默认 /opt/airts-agent/.env 或 AIRTS_AGENT_ENV）")
    args = parser.parse_args(argv)

    try:
        assert_allowed(args.authority_port)
    except PortNotAllowed as exc:
        print(str(exc))
        return 2

    loaded = load_env_file(getattr(args, "env_file", ""))
    print("== 已加载环境变量键名（不打印取值）: %s" % (sorted(loaded) or "（无）"))
    availability = pydantic_ai_available()
    settings = GraphModelSettings.from_env()
    report: Dict[str, Any] = {
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "pydantic_ai": availability,
        "settings": settings.safe_dict(),
        "authority_port": args.authority_port,
        "checks": {},
    }
    print("== pydantic-ai 可用性 ==")
    print(json.dumps(availability, ensure_ascii=False))
    print("== Provider 配置（脱敏） ==")
    print(json.dumps(settings.safe_dict(), ensure_ascii=False, indent=2))
    if not availability["available"]:
        report["verdict"] = "FAIL_DEP_MISSING"
        _write(args.out, report)
        return 1

    views = fetch_views(args.authority_port, args.as_player)
    report["view_sources"] = views["sources"]
    rules = views["rules"]
    tactical = views["tactical"]
    strategic = views["strategic"]
    match_id = str(rules.get("match_id", "") or "smoke-match")
    player_id = args.as_player or str(tactical.get("player_id", "") or "Player_0")
    state = AdjutantGraphState(match_id=match_id, player_id=player_id)
    state.rules_version = str(rules.get("rules_version", {}).get("content_hash", ""))
    state.server_tick = int(tactical.get("server_tick", 0) or 0)
    state.latest_snapshot_id = int(tactical.get("snapshot_id", 0) or 0)
    state.ensure_units(sorted(own_unit_ids(tactical)))

    scene_paths = rules_scene_paths(rules)
    known = known_entity_ids(tactical)
    print("== 观测 ==")
    print("own_unit_ids=%s scene_paths=%d match=%s player=%s tick=%s" % (
        sorted(own_unit_ids(tactical)), len(scene_paths), match_id, player_id,
        state.server_tick))

    # ---- 战略调用 ----
    strategy_agent = timed(PydanticAIStrategyAgent, settings)
    if not strategy_agent["ok"]:
        report["checks"]["strategy_agent_construct"] = strategy_agent
        report["verdict"] = "FAIL_AGENT_CONSTRUCT"
        _write(args.out, report)
        print("战略 Agent 装配失败：", strategy_agent["error"])
        return 1
    strategy_context = build_strategy_context(
        state, strategic=strategic, rules=rules,
        events=[{"kind": "match_started"}],
        budget={"a": int(strategic.get("resources", {}).get("a", 0) or 0)},
    )
    strategy_call = timed(strategy_agent["value"].propose_plan, strategy_context)
    strategy_ok, strategy_errors = False, []
    if strategy_call["ok"]:
        plan = strategy_call["value"]
        raw_plan = plan.to_plan_dict() if hasattr(plan, "to_plan_dict") else plan
        from adjutant_coordinator.protocol import validate_plan
        plan_errors = validate_plan(raw_plan if isinstance(raw_plan, dict) else {},
                                    {"match_id": match_id, "player_id": player_id,
                                     "rules_version": state.rules_version})
        strategy_errors = list(plan_errors)
        if not isinstance(raw_plan, dict):
            try:
                parse_strategic_plan(raw_plan)
            except ContractError as exc:
                strategy_errors.extend(exc.errors)
        # 计划任务里的单位必须来自观测。
        if isinstance(raw_plan, dict):
            for task in raw_plan.get("tasks", []) or []:
                for unit in task.get("units", []) or []:
                    if str(unit) not in known:
                        strategy_errors.append("task_unit_not_in_observation:%s" % unit)
        strategy_ok = not strategy_errors
        report["strategy_plan"] = _jsonable(raw_plan)
    report["checks"]["strategy_call"] = {
        "ok": strategy_call["ok"], "latency_s": strategy_call["latency_s"],
        "error": strategy_call["error"], "valid": strategy_ok,
        "validation_errors": strategy_errors[:10]}

    # ---- 战术调用 ----
    tactics_agent = timed(PydanticAITacticsAgent, settings)
    if not tactics_agent["ok"]:
        report["checks"]["tactics_agent_construct"] = tactics_agent
        report["verdict"] = "FAIL_AGENT_CONSTRUCT"
        _write(args.out, report)
        print("战术 Agent 装配失败：", tactics_agent["error"])
        return 1
    if strategy_call["ok"] and isinstance(report.get("strategy_plan"), dict):
        state.active_plan = report["strategy_plan"]
        state.plan_version = "%s:v%s" % (report["strategy_plan"].get("plan_id", "plan"),
                                         report["strategy_plan"].get("plan_version", 1))
        state.last_strategy_tick = state.server_tick
        for task in report["strategy_plan"].get("tasks", []) or []:
            if task.get("task_id"):
                state.register_task(str(task["task_id"]), "pending")
    events = []
    if known - own_unit_ids(tactical):
        events.append({"kind": "enemy_spotted", "server_tick": state.server_tick,
                       "payload": {"subject": sorted(own_unit_ids(tactical))[:1]}})
    else:
        events.append({"kind": "queue_idle", "server_tick": state.server_tick,
                       "payload": {"subject": sorted(own_unit_ids(tactical))[:1]}})
    tactics_context = build_tactics_context(
        state, tactical=tactical, rules=rules, events=events, strategic=strategic)
    tactics_call = timed(tactics_agent["value"].propose_intents, tactics_context)
    tactic_ok, tactic_errors, inteq = False, [], []
    if tactics_call["ok"]:
        batch = tactics_call["value"]
        raw_batch = batch.to_dict() if hasattr(batch, "to_dict") else batch
        try:
            parsed = parse_intent_batch(raw_batch)
            inteq = [intent.to_dict() for intent in parsed.intents]
            tactic_errors = [reason for _, reason in validate_intent_references(
                inteq, known_entities=known, scene_paths=scene_paths,
                allowed_units=own_unit_ids(tactical))]
            bad_versions = [i["intent_id"] for i in inteq
                            if str(i.get("plan_version")) != str(state.plan_version)]
            tactic_errors.extend("plan_version_mismatch:%s" % i for i in bad_versions)
            tactic_ok = not tactic_errors
        except ContractError as exc:
            tactic_errors = list(exc.errors)
        report["intent_batch"] = _jsonable(raw_batch)
    report["checks"]["tactics_call"] = {
        "ok": tactics_call["ok"], "latency_s": tactics_call["latency_s"],
        "error": tactics_call["error"], "valid": tactic_ok,
        "validation_errors": tactic_errors[:10], "intent_count": len(inteq)}

    total_ok = bool(report["checks"]["strategy_call"]["ok"] and
                    report["checks"]["tactics_call"]["ok"])
    report["verdict"] = ("PASS_REAL_MODEL" if total_ok and strategy_ok and tactic_ok else
                         "PARTIAL" if total_ok else "FAIL")
    _write(args.out, report)
    print("== 结果 ==")
    print(json.dumps({"strategy": report["checks"]["strategy_call"],
                      "tactics": report["checks"]["tactics_call"],
                      "verdict": report["verdict"]},
                     ensure_ascii=False, indent=2)[:4000])
    return 0 if report["verdict"] == "PASS_REAL_MODEL" else 1


def _write(path: Optional[str], report: Dict[str, Any]) -> None:
    if not path:
        return
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(report, handle, ensure_ascii=False, indent=2)
    print("saved:", path)


if __name__ == "__main__":
    sys.exit(main())
