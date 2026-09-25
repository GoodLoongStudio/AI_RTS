# -*- coding: utf-8 -*-
"""固定场景对局指标分析（执行提示词 §8 验收指标的最小可复现口径）。

输入：`selfplay_match.py` 产出的 `result_<tag>.json`（含 forces_log / detail_log）
     + runner 日志 `state_<tag>/runner.out`（意图/回执/闸门账本）。

输出：首次有效出击/首次建筑伤害/首次建筑摧毁时间、伤害与战损、兵力组成、
     单位离家距离、闸门放行率、命令 churn 等。**只报实测，缺失写 None**。
"""
from __future__ import annotations

import argparse
import collections
import json
import math
import os
import re
import sys

#: 建筑类型（demo 平衡表 unitTypes 里的非机动结构）。
BUILDING_TYPES = {
    "command_center", "barracks", "vehicle_factory", "aircraft_factory",
    "anti_air_turret", "anti_ground_turret", "machine_gun_turret",
}
#: 作战单位类型。
COMBAT_TYPES = {"soldier", "tank", "heavy_tank", "rocketeer", "helicopter", "apc"}


def _load(path: str) -> dict:
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def _first_ts(samples, predicate):
    for sample in samples:
        if predicate(sample):
            return sample
    return None


def analyze(result_path: str, runner_log: str = "") -> dict:
    result = _load(result_path)
    tag = str(result.get("tag", "?"))
    out = {"tag": tag, "verdict": result.get("verdict"),
           "own_total": result.get("own_total"), "enemy_total": result.get("enemy_total")}
    if not result.get("samples"):
        out["error"] = "no samples"
        return out
    t0 = float(result["first"].get("ts") or 0.0)
    samples = result.get("detail_log") or []

    def elapsed(sample):
        return round(float(sample.get("ts", 0.0)) - t0, 1)

    # ---- 首次建筑伤害 / 摧毁（观测口径：敌方实体 hp < hp_max 且类型是建筑）----
    seen_buildings = {}
    first_damage = None
    destroyed = {}
    for sample in samples:
        for enemy in sample.get("enemies") or []:
            name = str(enemy.get("name", ""))
            etype = str(enemy.get("type", ""))
            if etype not in BUILDING_TYPES:
                continue
            hp, hp_max = float(enemy.get("hp", 0.0)), float(enemy.get("hp_max", 0.0))
            seen_buildings[name] = etype
            if first_damage is None and hp_max > 0 and 0 < hp < hp_max:
                first_damage = {"t": elapsed(sample), "name": name, "type": etype,
                                "hp": hp, "hp_max": hp_max}
            if hp <= 0:
                destroyed.setdefault(name, {"t": elapsed(sample), "type": etype})
    out["first_building_damage"] = first_damage
    out["buildings_destroyed"] = [
        {"name": name, "type": info["type"], "t": info["t"]}
        for name, info in sorted(destroyed.items(), key=lambda kv: kv[1]["t"])]
    out["enemy_buildings_seen"] = collections.Counter(
        str(e.get("type")) for e in (samples[-1].get("enemies") or [])
        if str(e.get("type")) in BUILDING_TYPES) if samples else {}

    # ---- 我方战斗单位是否出门（与己方基地的中位距离随时间变化）----
    travel = []
    for sample in samples:
        own = sample.get("own") or []
        bases = [e for e in own if e.get("type") == "command_center"]
        combat = [e for e in own if e.get("type") in COMBAT_TYPES]
        if not bases or not combat:
            continue
        bx = sum(float(e["pos"][0]) for e in bases) / len(bases)
        bz = sum(float(e["pos"][1]) for e in bases) / len(bases)
        dists = [math.hypot(float(e["pos"][0]) - bx, float(e["pos"][1]) - bz)
                 for e in combat]
        travel.append({"t": elapsed(sample), "n": len(combat),
                       "median_dist": round(sorted(dists)[len(dists) // 2], 1),
                       "max_dist": round(max(dists), 1)})
    out["combat_travel"] = travel
    if travel:
        out["combat_left_base"] = any(item["median_dist"] > 25.0 for item in travel)

    # ---- 兵力组成与资源（每 30s 抽样）----
    composition = []
    for index, sample in enumerate(result.get("forces_log") or []):
        forces = (sample.get("forces") or {}).get("Player_0") or {}
        composition.append({"t": round(float(sample.get("ts", 0.0)) - t0, 1),
                            "units": forces.get("units") or {},
                            "total": forces.get("total", 0)})
    out["composition"] = composition
    out["peak_balance"] = max([int((s.get("balance") or {}).get("a", 0) or 0)
                               for s in result.get("forces_log") or []] or [0])

    # ---- runner 日志：意图/回执/闸门 ----
    if runner_log and os.path.exists(runner_log):
        out.update(_runner_metrics(runner_log, t0))
    return out


def _runner_metrics(path: str, t0: float) -> dict:
    text_ts = []
    first_attack = None
    first_advance = None
    receipts = collections.Counter()
    actions = collections.Counter()
    gate = None
    fallbacks = collections.Counter()
    line_re = re.compile(r'"ts": ([0-9.]+)')
    with open(path, encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            match = line_re.search(line)
            ts = float(match.group(1)) if match else 0.0
            if '"kind": "receipt"' in line:
                try:
                    record = json.loads(line.split("] ", 1)[-1])
                except Exception:  # noqa: BLE001
                    continue
                receipt = record.get("receipt") or {}
                action = str(receipt.get("action", ""))
                if action:
                    actions[action] += 1
                result = receipt.get("result") or {}
                status = str(result.get("status", "")) if isinstance(result, dict) else ""
                receipts[(action, status)] += 1
                if action in ("attack", "attack_move") and status == "Accepted":
                    if action == "attack" and first_attack is None:
                        first_attack = round(ts - t0, 1)
                    if action == "attack_move" and first_advance is None:
                        first_advance = round(ts - t0, 1)
            if '"kind": "movement_gate"' in line:
                try:
                    record = json.loads(line.split("] ", 1)[-1])
                except Exception:  # noqa: BLE001
                    continue
                stats = (record.get("decision") or {}).get("stats") or {}
                if stats:
                    gate = {"planned": stats.get("planned"),
                            "allowed": stats.get("allowed"),
                            "blocked_reasons": stats.get("blocked_reasons"),
                            "fallbacks": stats.get("fallbacks"),
                            "threat_blocks": stats.get("threat_blocks"),
                            "arrivals": stats.get("arrivals"),
                            "squad_advances": stats.get("squad_advances")}
                    for key in (stats.get("fallback_reasons") or {}):
                        fallbacks[key] += int((stats.get("fallback_reasons") or {})[key])
    planned = int((gate or {}).get("planned") or 0)
    allowed = int((gate or {}).get("allowed") or 0)
    return {
        "first_attack_intent_t": first_attack,
        "first_attack_move_t": first_advance,
        "receipt_actions": dict(actions),
        "receipt_status": {("%s/%s" % k): v for k, v in receipts.items()},
        "gate": gate,
        "gate_allow_rate": round(allowed / float(planned), 3) if planned else None,
        "fallback_reasons_total": dict(fallbacks),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="固定场景对局指标")
    parser.add_argument("result", help="result_<tag>.json 路径")
    parser.add_argument("--runner-log", default="",
                        help="state_<tag>/runner.out（可选）")
    args = parser.parse_args()
    runner_log = args.runner_log
    if not runner_log:
        guess = os.path.join(os.path.dirname(args.result),
                             "state_%s" % _load(args.result).get("tag", ""),
                             "runner.out")
        runner_log = guess if os.path.exists(guess) else ""
    metrics = analyze(args.result, runner_log)
    print(json.dumps(metrics, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
