# -*- coding: utf-8 -*-
"""离线复盘：截图那种「全堆在指挥中心」局面，副官实际会下什么令。"""
from __future__ import annotations

import math
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "source"
sys.path.insert(0, str(ROOT))

from adjutant_coordinator.graph import behavior_tree
from adjutant_coordinator.graph import campaign as cm
from adjutant_coordinator.graph import decision_map
from adjutant_coordinator.graph import rules_fallback as rf

HQ = (32.0, 32.0)
BOUNDS = [256.0, 256.0]
TICK = 1800

RULES = {
    "unit_types": [
        {"id": "worker", "capabilities": {"attack": False, "move": True, "gather": True}},
        {"id": "soldier", "capabilities": {"attack": True, "move": True}},
        {"id": "tank", "capabilities": {"attack": True, "move": True}},
        {"id": "apc", "capabilities": {"attack": True, "move": True}},
        {"id": "heavy_tank", "capabilities": {"attack": True, "move": True}},
        {"id": "helicopter", "capabilities": {"attack": True, "move": True}},
        {"id": "drone", "capabilities": {"attack": False, "move": True}},
        {"id": "command_center", "capabilities": {"attack": False, "move": False, "queue": True}},
        {"id": "barracks", "capabilities": {"attack": False, "move": False, "queue": True}},
        {"id": "vehicle_factory", "capabilities": {"attack": False, "move": False, "queue": True}},
    ],
}


def _ent(kind, name, utype, pos, **extra):
    out = {"kind": kind, "name": name, "unit_type": utype, "pos": [pos[0], 0.0, pos[1]]}
    out.update(extra)
    return out


def screenshot_entities(*, enemy=False, intel=False):
    """截图：指挥中心周围堆着装甲车/坦克/步兵。"""
    piled = [
        (30.0, 28.0), (34.0, 30.0), (28.0, 34.0), (36.0, 36.0),
        (32.0, 26.0), (26.0, 32.0), (38.0, 32.0), (33.0, 38.0),
        (29.0, 36.0), (35.0, 27.0),
    ]
    entities = [
        _ent("unit_self", "CC", "command_center", HQ, queue=True),
        _ent("unit_self", "W1", "worker", (28.0, 28.0), gather=True, construct=True),
        _ent("unit_self", "W2", "worker", (36.0, 28.0), gather=True, construct=True),
        _ent("unit_self", "Drone1", "drone", (40.0, 40.0)),
        _ent("resource", "ResA", (48.0, 28.0)),
    ]
    kinds = ["apc", "tank", "heavy_tank", "apc", "soldier", "soldier",
             "tank", "apc", "heavy_tank", "soldier"]
    for i, (kind, pos) in enumerate(zip(kinds, piled), 1):
        entities.append(_ent("unit_self", "U%d" % i, kind, pos))
    if enemy:
        entities.append(_ent("unit_enemy", "E1", "tank", (180.0, 180.0)))
    return entities


def state_of(entities, *, tick=TICK, combat=True, bounds=True, intel=None):
    names = [e["name"] for e in entities if e.get("kind") == "unit_self"]
    st = {
        "server_tick": tick,
        "latest_snapshot_id": tick,
        "ai_controlled_units": names,
        "player_controlled_units": [],
        "active_intents": [],
        "own_unit_types": {e["name"]: e["unit_type"] for e in entities
                           if e.get("kind") == "unit_self"},
    }
    if bounds:
        st["map_bounds"] = list(BOUNDS)
    if combat:
        st["combat_types"] = ["soldier", "tank", "apc", "heavy_tank", "helicopter"]
    if intel:
        st["enemy_intel_points"] = list(intel)
    return st


def summarize(intents, label, home=HQ):
    print("\n==== %s ====" % label)
    if not intents:
        print("  (无意图)")
        return
    actions = Counter(it["action"] for it in intents)
    print("  动作统计:", dict(actions))
    units = []
    for it in intents:
        for u in it.get("unit_ids") or []:
            units.append(u)
        pos = (it.get("target") or {}).get("pos")
        extra = ""
        if pos and len(pos) >= 2:
            d_home = math.hypot(pos[0] - home[0], pos[1] - home[1])
            extra = " pos=%s 距家=%.1f" % (pos, d_home)
        print("  %s %s%s  | %s" % (
            it["action"], it.get("unit_ids"), extra,
            (it.get("rationale") or "")[:80]))
    print("  覆盖单位数:", len(units), "去重:", len(set(units)))


def waypoint_probe():
    print("\n==== military_waypoint 单点探针 ====")
    for label, kwargs in (
        ("无地图", {"base": HQ, "bearing": (1, 1), "search": True}),
        ("有地图无情报 origin=家", {
            "base": HQ, "bounds": BOUNDS, "search": True,
            "state": {"own_unit_types": {"U1": "tank"}}, "unit": "U1"}),
        ("有地图 origin=家门口车", {
            "base": (34.0, 30.0), "bounds": BOUNDS, "search": True,
            "state": {"own_unit_types": {"U1": "tank"}}, "unit": "U1"}),
        ("有情报", {
            "base": (34.0, 30.0), "bounds": BOUNDS, "search": True,
            "intel": [[180.0, 180.0]],
            "state": {"own_unit_types": {"U1": "tank"}}, "unit": "U1"}),
        ("可见敌人", {
            "base": (34.0, 30.0), "bounds": BOUNDS, "search": True,
            "enemies": [{"pos": [180.0, 0.0, 180.0]}]}),
    ):
        pt = rf.military_waypoint(**kwargs)
        if not pt:
            print("  %-24s -> None" % label)
            continue
        origin = kwargs["base"]
        print("  %-24s -> %s  距原点=%.1f  距家=%.1f" % (
            label, pt,
            math.hypot(pt[0] - origin[0], pt[1] - origin[1]),
            math.hypot(pt[0] - HQ[0], pt[1] - HQ[1])))


def campaign_probe(entities):
    print("\n==== 决策图检索 ====")
    names = [e["name"] for e in entities if e.get("kind") == "unit_self"]
    st = state_of(entities)
    obs = {
        "header": {"match_id": "sim", "player_id": "P0",
                   "rules_version": "sim", "snapshot_id": TICK, "server_tick": TICK},
        "tactical": {"entities": entities, "balance": {"A": 40000},
                     "production": [], "truncated": False, "outcome": {"finished": False}},
        "strategic": {"map_bounds": BOUNDS, "enemy_intel": []},
        "events": [],
        "rules": RULES,
    }
    campaign = cm.update(st, obs, TICK)
    facts = cm.build_facts(st, obs, TICK)
    retrieved = decision_map.retrieve(facts, campaign, limit=12)
    avail = [(x["id"], x.get("name"), x.get("priority")) for x in retrieved["available"]]
    print("  phase=%s frontier=%s allow_attack=%s combat=%s scattered=%s" % (
        campaign.get("phase"), campaign.get("next_frontier"),
        cm.frontier_preferences(st, tick=TICK).get("allow_attack"),
        facts.get("combat_count"), facts.get("units_scattered")))
    print("  可选:", avail)
    print("  军事相关:", [x for x in avail if str(x[0]) in ("D11", "D12", "D14", "D15")])


def step_units(entities, intents, step=18.0):
    by = {e["name"]: e for e in entities}
    for it in intents:
        pos = (it.get("target") or {}).get("pos")
        if not pos or len(pos) < 2:
            continue
        if it.get("action") not in ("attack_move", "move", "scout", "regroup", "retreat"):
            continue
        for name in it.get("unit_ids") or []:
            ent = by.get(name)
            if not ent:
                continue
            xyz = ent["pos"]
            dx, dz = pos[0] - xyz[0], pos[1] - xyz[2]
            dist = math.hypot(dx, dz)
            if dist < 1e-3:
                continue
            take = min(step, dist)
            xyz[0] += dx / dist * take
            xyz[2] += dz / dist * take


def pile_radius(entities):
    combat = [e for e in entities if e.get("unit_type") in
              ("soldier", "tank", "apc", "heavy_tank", "helicopter")]
    if not combat:
        return 0.0
    xs = [e["pos"][0] for e in combat]
    zs = [e["pos"][2] for e in combat]
    cx, cz = sum(xs) / len(xs), sum(zs) / len(zs)
    spread = max(math.hypot(e["pos"][0] - cx, e["pos"][2] - cz) for e in combat)
    home = max(math.hypot(e["pos"][0] - HQ[0], e["pos"][2] - HQ[1]) for e in combat)
    mean = sum(math.hypot(e["pos"][0] - HQ[0], e["pos"][2] - HQ[1]) for e in combat) / len(combat)
    return spread, home, mean, len(combat)


def main():
    waypoint_probe()

    entities = screenshot_entities()
    st = state_of(entities)
    tac = {"entities": entities}

    summarize(behavior_tree.micro_intents(st, tactical=tac, rules=RULES),
              "微操树 无地图? wait 有bounds")
    st_nobounds = state_of(entities, bounds=False)
    summarize(behavior_tree.micro_intents(st_nobounds, tactical=tac, rules=RULES),
              "微操树 无 map_bounds（旧单测形状）")

    ladder, tree = behavior_tree.micro_parts(st, tactical=tac, rules=RULES)
    summarize(ladder, "阶梯+并行填充")
    summarize(tree, "行为树剩余（阶梯已认领后）")

    campaign_probe(entities)

    print("\n==== 多 tick 推演（阶梯+树，单位朝目标走）====")
    live = screenshot_entities()
    st2 = state_of(live)
    for i in range(12):
        st2["server_tick"] = TICK + i * 120
        intents = behavior_tree.micro_intents(st2, tactical={"entities": live}, rules=RULES)
        actions = Counter(it["action"] for it in intents)
        dists = []
        for it in intents:
            pos = (it.get("target") or {}).get("pos")
            if pos:
                dists.append(math.hypot(pos[0] - HQ[0], pos[1] - HQ[1]))
        spread, farthest, mean, n = pile_radius(live)
        print("  t+%d  令=%s  目标距家min/max=%s  部队距家均值/最远=%.1f/%.1f  散布=%.1f  n=%d" % (
            i * 120, dict(actions),
            ("%.1f/%.1f" % (min(dists), max(dists)) if dists else "-"),
            mean, farthest, spread, n))
        if any(it["action"] == "regroup" for it in intents):
            print("    !! 出现集结")
        step_units(live, intents, step=20.0)

    print("\n==== 见敌 180,180 ====")
    foes = screenshot_entities(enemy=True)
    st3 = state_of(foes)
    summarize(behavior_tree.micro_intents(st3, tactical={"entities": foes}, rules=RULES),
              "微操树 可见远敌")
    campaign_probe(foes)

    print("\n==== 只有情报点、看不见人 ====")
    st4 = state_of(entities, intel=[[180.0, 180.0]])
    summarize(behavior_tree.micro_intents(st4, tactical=tac, rules=RULES),
              "微操树 仅情报")
    print("  waypoint+intel:", rf.military_waypoint(
        (34.0, 30.0), bounds=BOUNDS, search=True, intel=[[180.0, 180.0]],
        state={"own_unit_types": {"U1": "tank"}}, unit="U1"))


if __name__ == "__main__":
    main()
