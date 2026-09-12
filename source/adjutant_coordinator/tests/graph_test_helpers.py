# -*- coding: utf-8 -*-
"""图测试共用夹具：观测视图、计划/意图构造、可录音的权威通道桩。

所有数据都是确定性常量，不需要 API Key，不触碰网络。
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

MATCH = "m-graph-1"
PLAYER = "Player_1"
RULES = "hash-graph-1"
SCENE_TANK = "res://source/match/units/tank.tscn"


def header(server_tick: int, snapshot_id: Optional[int] = None,
           match_id: str = MATCH, player_id: str = PLAYER,
           rules_version: str = RULES) -> Dict[str, Any]:
    return {
        "schema_version": 1,
        "match_id": match_id,
        "player_id": player_id,
        "rules_version": rules_version,
        "snapshot_id": int(server_tick if snapshot_id is None else snapshot_id),
        "server_tick": int(server_tick),
    }


def rules_view(match_id: str = MATCH, rules_version: str = RULES) -> Dict[str, Any]:
    return {
        "match_id": match_id,
        "rules_version": {"content_hash": rules_version, "version": 1},
        "unit_types": [
            {"id": "tank", "scene_path": SCENE_TANK},
            {"id": "worker", "scene_path": "res://source/match/units/worker.tscn"},
            {"id": "vehicle_factory",
             "scene_path": "res://source/match/units/vehicle_factory.tscn"},
        ],
        "productions": [
            {"product_type_id": "tank", "cost": [{"kind": "a", "amount": 555}],
             "allowed_producer_type_ids": ["vehicle_factory"]},
        ],
        "constructions": [
            {"id": "vehicle_factory", "cost": [{"kind": "a", "amount": 600}],
             "blueprint_scene_path": "res://source/match/units/vehicle_factory.tscn"},
        ],
    }


def tactical(own: Optional[List[Dict[str, Any]]] = None,
             enemies: Optional[List[Dict[str, Any]]] = None,
             server_tick: int = 0, snapshot_id: int = 0,
             match_id: str = MATCH, player_id: str = PLAYER,
             rules_version: str = RULES) -> Dict[str, Any]:
    entities: List[Dict[str, Any]] = []
    for unit in own or [{"name": "Unit_1", "unit_type": "tank", "pos": [0.0, 0.0, 0.0]}]:
        entities.append({
            "kind": "unit_self", "name": unit["name"], "unit_type": unit.get("unit_type", "tank"),
            "pos": list(unit.get("pos", [0.0, 0.0, 0.0])), "hp": 100.0, "hp_max": 100.0,
            "movement": True, "attack": True, "queue": False, "gather": False, "construct": False,
        })
    for enemy in enemies or []:
        entities.append({
            "kind": "unit_enemy", "name": enemy["name"],
            "unit_type": enemy.get("unit_type", "tank"),
            "pos": list(enemy.get("pos", [20.0, 0.0, 20.0])), "hp": 50.0, "hp_max": 100.0,
            "last_seen_tick": int(enemy.get("last_seen_tick", server_tick)),
            "confirmed_dead": False,
        })
    return {
        "schema_version": 1, "match_id": match_id, "player_id": player_id,
        "rules_version": rules_version, "snapshot_id": int(snapshot_id),
        "server_tick": int(server_tick), "entities": entities,
        "covered": {"self": len(own or [1]), "enemy": len(enemies or [])},
        "totals": {"self": len(own or [1]), "enemy": len(enemies or [])},
        "truncated": False, "next_offset": -1,
        "balance": {"a": 1000, "b": 0}, "production": [],
        "outcome": {"finished": False},
    }


def strategic(server_tick: int = 0, match_id: str = MATCH,
              player_id: str = PLAYER, rules_version: str = RULES) -> Dict[str, Any]:
    return {
        "schema_version": 1, "match_id": match_id, "player_id": player_id,
        "rules_version": rules_version, "snapshot_id": int(server_tick),
        "server_tick": int(server_tick),
        "resources": {"a": 1000, "b": 0},
        "enemy_intel": [], "map_bounds": [200.0, 200.0],
        "available_actions": ["move", "attack", "attack_move", "produce", "build"],
        "production_relations": rules_view()["productions"],
        "buildable": rules_view()["constructions"],
        "production": [],
    }


def make_plan(plan_id: str = "plan-a", version: int = 1, units: Optional[List[str]] = None,
              valid_until_tick: int = 100000, task_id: str = "t-1",
              match_id: str = MATCH, player_id: str = PLAYER,
              rules_version: str = RULES, reserves: Optional[Dict[str, int]] = None,
              based_on_snapshot: int = 1) -> Dict[str, Any]:
    return {
        "plan_id": plan_id,
        "plan_version": version,
        "match_id": match_id,
        "player_id": player_id,
        "rules_version": rules_version,
        "based_on_snapshot": based_on_snapshot,
        "valid_until_tick": valid_until_tick,
        "phase_goal": "巩固基地并压制敌侦察",
        "tasks": [{
            "task_id": task_id,
            "priority": 1,
            "completion": "任务完成条件",
            "units": list(units if units is not None else ["Unit_1"]),
            "unit_constraint": "",
            "target_type": "",
            "allowed_actions": ["move", "attack_move", "hold"],
        }],
        "reserves": reserves or {},
        "rationale": "测试用计划",
        "abort_when": ["base_under_attack"],
    }


def make_intent(intent_id: str = "i-1", action: str = "move",
                units: Optional[List[str]] = None,
                plan_version: str = "plan-a:v1", task_id: str = "t-1",
                issued_tick: int = 0, expires_tick: int = 100000,
                generation: int = 0, target: Optional[Dict[str, Any]] = None,
                priority: int = 1, emergency: bool = False,
                based_on_snapshot: int = 1,
                match_id: str = MATCH, player_id: str = PLAYER) -> Dict[str, Any]:
    default_target = {"pos": [10.0, 10.0]} if action in ("move", "attack_move", "defend",
                                                        "retreat", "scout", "regroup") else {}
    return {
        "intent_id": intent_id,
        "plan_version": plan_version,
        "task_id": task_id,
        "unit_ids": list(units if units is not None else ["Unit_1"]),
        "action": action,
        "target": dict(target if target is not None else default_target),
        "priority": priority,
        "based_on_snapshot": based_on_snapshot,
        "issued_tick": issued_tick,
        "expires_tick": expires_tick,
        "generation": generation,
        "abort_when": [],
        "emergency": emergency,
        "rationale": "测试用意图",
    }


def make_batch(intents: List[Dict[str, Any]], plan_version: str = "plan-a:v1",
               match_id: str = MATCH, player_id: str = PLAYER,
               based_on_snapshot: int = 1, batch_id: str = "b-1") -> Dict[str, Any]:
    return {
        "batch_id": batch_id,
        "match_id": match_id,
        "player_id": player_id,
        "plan_version": plan_version,
        "based_on_snapshot": based_on_snapshot,
        "intents": list(intents),
    }


class RecordingTransport:
    """权威通道桩：记录命令包并按脚本/默认状态返回回执（不联网）。"""

    def __init__(self, default_status: str = "Accepted", accepted: bool = True,
                 script: Optional[List[Dict[str, Any]]] = None) -> None:
        self.default_status = default_status
        self.default_accepted = accepted
        self.script = list(script or [])
        self.sent: List[Dict[str, Any]] = []

    def send_command(self, envelope: Dict[str, Any]) -> Dict[str, Any]:
        self.sent.append(dict(envelope))
        if self.script:
            override = self.script.pop(0)
            receipt = dict(override)
        else:
            receipt = {"ok": self.default_accepted, "accepted": self.default_accepted,
                       "status": self.default_status}
        receipt.setdefault("command_id", str(envelope.get("command_id", "")))
        receipt.setdefault("intent_id", str(envelope.get("intent_id", "")))
        receipt.setdefault("result", {})
        return receipt

    def heartbeat(self) -> bool:
        return True

    def close(self) -> None:
        return None

    def describe(self) -> str:
        return "RecordingTransport(sent=%d)" % len(self.sent)

    def statuses(self) -> List[str]:
        return [str(item.get("status", "")) for item in self.sent]


def events_for(kind: str, units: List[str], server_tick: int,
               event_id: str = "") -> Dict[str, Any]:
    return {
        "event_id": event_id or "%s-%d" % (kind, server_tick),
        "kind": kind,
        "match_id": MATCH,
        "player_id": PLAYER,
        "server_tick": int(server_tick),
        "payload": {"subject": ",".join(units)},
    }
