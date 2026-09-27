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
    # 矿场是本次主线新增的可建造建筑；漏登记会让分析层完全看不见它的存在，
    # "没有矿场"与"有矿场但没统计到"就无法区分（2026-09-27 阶段 0 断点 G）。
    "ore_refinery",
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

    # ---- 经济闭环三张账（提示词 §6 逐局报告表）----
    # 只用 detail_log 里透传的观测原值求"首次时刻/累计量"，不推断、不补零：
    # 缺项一律 None，读报告的人才能分清"没发生"和"没测到"。
    out["economy"] = _economy_metrics(samples, elapsed)

    # ---- runner 日志：意图/回执/闸门 ----
    if runner_log and os.path.exists(runner_log):
        out.update(_runner_metrics(runner_log, t0))
    return out


def _economy_metrics(samples, elapsed) -> dict:
    """零工人施工 / 矿场接管交付 / 矿点消耗与再生 的逐局实测。"""
    metrics: dict = {
        "worker_seconds_on_construction": None,
        "first_refinery_placed_t": None,
        "first_refinery_takeover_t": None,
        "first_refinery_delivery_t": None,
        "refinery_delivered_amount": None,
        "ore_nodes": None,
        "ore_remaining_first": None,
        "ore_remaining_last": None,
        "ore_depleted_nodes": None,
        "entities_truncated": None,
    }
    if not any("ore_nodes" in sample for sample in samples):
        metrics["error"] = "no economy fields sampled (harness too old or op=tactical failed)"
        return metrics

    def peak(key: str) -> float:
        values = [float((sample.get("cw_seconds") or {}).get("Player_0", 0.0) or 0.0)
                  for sample in samples if key in sample]
        # 仪表是**累计秒数**，单调不减；取末值即整局总量，取峰值防中途玩家改名。
        return max(values) if values else 0.0

    metrics["worker_seconds_on_construction"] = round(peak("cw_seconds"), 1)
    metrics["constructing_workers_peak"] = max(
        [int(sample.get("constructing") or 0) for sample in samples
         if "constructing" in sample] or [0])

    first_refinery = None
    first_takeover = None
    first_delivery = None
    delivered_amount = 0
    for sample in samples:
        if "ore_nodes" not in sample:
            continue
        for refinery in sample.get("refineries") or []:
            if first_refinery is None and refinery.get("constructed"):
                first_refinery = elapsed(sample)
            if first_takeover is None and refinery.get("takeovers", 0) > 0:
                first_takeover = elapsed(sample)
            if first_delivery is None and refinery.get("delivered", 0) > 0:
                first_delivery = elapsed(sample)
            delivered_amount = max(delivered_amount, int(refinery.get("delivered_amount") or 0))
    metrics["first_refinery_placed_t"] = first_refinery
    metrics["first_refinery_takeover_t"] = first_takeover
    metrics["first_refinery_delivery_t"] = first_delivery
    metrics["refinery_delivered_amount"] = delivered_amount if first_delivery is not None else None

    sampled = [sample for sample in samples if "ore_nodes" in sample]
    metrics["ore_nodes"] = max(int(s.get("ore_nodes") or 0) for s in sampled)
    metrics["ore_remaining_first"] = int(sampled[0].get("ore_remaining") or 0)
    metrics["ore_remaining_last"] = int(sampled[-1].get("ore_remaining") or 0)
    metrics["ore_depleted_nodes"] = max(int(s.get("ore_depleted") or 0) for s in sampled)
    # 窗口截断 ⇒ 上面的"全图矿量"只是部分和，禁止当耗尽证据引用（提示词 §5 反假证据）。
    metrics["entities_truncated"] = any(bool(s.get("truncated")) for s in sampled)

    # 账户余额增长（§7 要的是"钱真的到账"，不是"矿被采出"）。旧 `peak_balance` 读的是
    # `forces_log` 里从来不存在的 `balance` 字段，所以恒为 0——这一列才是可用口径。
    balances = [int(s.get("balance_a") or 0) for s in sampled if "balance_a" in s]
    metrics["balance_first"] = balances[0] if balances else None
    metrics["balance_last"] = balances[-1] if balances else None
    metrics["balance_peak"] = max(balances) if balances else None
    metrics["balance_grew"] = (balances[-1] > balances[0]) if len(balances) >= 2 else None
    return metrics


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
