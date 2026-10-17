"""经济启动金必须留住（2026-09-29 真实局铁证）。

固定局（PlainAndSimple, seed 11/22, backend=off）里副官开局 60 秒把 9400 全花在
步兵与坦克上，车厂完工后阶梯 1.8 想发 `rule-produce-worker-*`（200/台）时余额只剩
100，预算闸门把 29 条工人意图全拦成 `insufficient_reserve:A` ⇒ 整局 `workers=0`、
没有矿场、余额永不增长。矿车是收入的唯一来源，所以补矿车的钱必须在同一批预算里
优先保留 —— 本组用例把这个规则钉住。
"""
from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph import rules_fallback as rf  # noqa: E402
from adjutant_coordinator.graph.rules_fallback import (  # noqa: E402
    WORKERS_PER_BASE, WORKER_TARGET, _production_cost_a, worker_bootstrap_reserve)

WORKER_COST_A = 200
TANK_COST_A = 1050

RULES = {
    "productions": [
        {"product_type_id": "worker", "allowed_producer_type_ids": ["vehicle_factory"],
         "cost": [{"kind": "A", "amount": WORKER_COST_A}]},
        {"product_type_id": "tank", "allowed_producer_type_ids": ["vehicle_factory"],
         "cost": [{"kind": "A", "amount": TANK_COST_A}]},
    ],
    "constructions": [],
}


def _by_name(**types):
    return {name: {"type": utype, "pos": [0.0, 0.0, 0.0]} for name, utype in types.items()}


class ProductionCostTest(unittest.TestCase):
    def test_cost_comes_from_rules_not_constants(self):
        self.assertEqual(_production_cost_a(RULES, "worker"), WORKER_COST_A)
        # 规则里查不到时返回 0：调用方据此"不设限"，绝不猜数值误杀生产。
        self.assertEqual(_production_cost_a(RULES, "ghost"), 0)


class WorkerBootstrapReserveTest(unittest.TestCase):
    def test_reserves_money_for_the_missing_trucks(self):
        """1 座车厂 + 0 矿车 → 必须留 max(WORKER_TARGET, 6) × 造价。"""
        reserve = worker_bootstrap_reserve(
            RULES, {"balance": {"A": 900}, "production": []}, {},
            _by_name(Unit_0="command_center", Unit_5="vehicle_factory"))
        self.assertEqual(reserve, max(WORKER_TARGET, 1 * WORKERS_PER_BASE) * WORKER_COST_A)

    def test_no_producer_no_reserve(self):
        """还没有车厂时不许凭空扣钱 —— 否则矿车没影，作战生产先被自己拦死。"""
        self.assertEqual(worker_bootstrap_reserve(
            RULES, {"balance": {"A": 900}, "production": []}, {},
            _by_name(Unit_0="command_center")), 0)

    def test_target_already_met_releases_the_money(self):
        """已补齐目标工人数（现有 + 队列中）后，启动金归零、作战生产照常。"""
        met = _by_name(Unit_0="command_center", Unit_5="vehicle_factory",
                       Unit_9="worker", Unit_10="worker", Unit_11="worker",
                       Unit_12="worker", Unit_13="worker", Unit_14="worker")
        self.assertEqual(worker_bootstrap_reserve(
            RULES, {"balance": {"A": 900}, "production": []}, {}, met), 0)
        # 队列里已有 5 台 + 在编 1 台 = 达标
        queued = _by_name(Unit_0="command_center", Unit_5="vehicle_factory", Unit_9="worker")
        tactical = {"balance": {"A": 900},
                    "production": [{"items": [{"definition_id": "worker"}] * 5}]}
        self.assertEqual(worker_bootstrap_reserve(RULES, tactical, {}, queued), 0)

    def test_in_flight_intent_counts_once(self):
        """在途的补矿车意图也算缺口的一部分（重复扣钱会把作战生产整轮饿死）。"""
        state = {"active_intents": [{
            "intent_id": "rule-produce-worker-Unit_5-900", "action": "produce",
            # 状态口径取 `rules_fallback.LIVE_INTENT_STATES`（在途才算缺口的一部分）
            "state": rf.LIVE_INTENT_STATES[0], "unit_ids": ["Unit_5"],
            "params": {"scene": "res://source/match/units/Worker.tscn"}}]}
        alone = worker_bootstrap_reserve(
            RULES, {"balance": {"A": 900}, "production": []}, {},
            _by_name(Unit_0="command_center", Unit_5="vehicle_factory"))
        with_flight = worker_bootstrap_reserve(
            RULES, {"balance": {"A": 900}, "production": []}, state,
            _by_name(Unit_0="command_center", Unit_5="vehicle_factory"))
        self.assertEqual(alone - with_flight, WORKER_COST_A)


class LadderOrderingTest(unittest.TestCase):
    """阶梯是"逐级 return"结构：建造不得把补矿车那一级饿死。"""

    def _observation(self, queue_size=0):
        def self_unit(name, utype, x, z):
            return {"kind": "unit_self", "name": name, "unit_type": utype,
                    "pos": [x, 0.0, z], "hp": 10.0, "hp_max": 10.0,
                    "movement": utype != "command_center", "queue": True,
                    "attack": False, "attack_range": 0.0, "gather": utype == "worker",
                    "construct": utype == "worker", "refinery": None, "domain": "terrain",
                    "attack_domains": [], "carried": [0, 0], "constructed": True,
                    "constructing": False, "radius": 2.0, "sight": 8.0}
        return {"server_tick": 1000, "snapshot_id": 5, "balance": {"A": 6000},
                "entities": [self_unit("Unit_0", "command_center", 40.0, 28.0),
                             self_unit("Unit_5", "vehicle_factory", 52.0, 28.0)],
                "production": [{"producer": "Unit_5", "queue_size": queue_size, "items": []}],
                "reserves": {"A": 1200}}

    def _state(self):
        return {"match_id": "m", "player_id": "Player_1", "server_tick": 1000,
                "latest_snapshot_id": 5, "rules_version": "r",
                "ai_controlled_units": ["Unit_0", "Unit_5"], "active_intents": []}

    def test_build_yields_to_the_first_truck(self):
        """0 矿车 + 完工车厂 → 让位判据成立（阶梯 1 的建造本轮不再 return，
        1.8 才有机会把 `rule-produce-worker-*` 发出去）。"""
        tactical = self._observation()
        self.assertTrue(rf.economy_unbootstrapped(RULES, tactical, self._state(),
                                                  rf._normalized_units(tactical)))

    def test_with_trucks_present_building_priority_returns(self):
        """已有矿车（哪怕 1 台）→ 让位条件不成立，建造优先级不变。"""
        tactical = self._observation()
        tactical["entities"].append({"kind": "unit_self", "name": "Unit_9",
                                     "unit_type": "worker", "pos": [45.0, 0.0, 28.0],
                                     "hp": 6.0, "hp_max": 6.0, "movement": True,
                                     "queue": False, "attack": False, "attack_range": 0.0,
                                     "gather": True, "construct": True, "refinery": None,
                                     "domain": "terrain", "attack_domains": [],
                                     "carried": [0, 0], "constructed": True,
                                     "constructing": False, "radius": 2.0, "sight": 5.0})
        self.assertFalse(rf.economy_unbootstrapped(RULES, tactical, self._state(),
                                                   rf._normalized_units(tactical)))


if __name__ == "__main__":
    unittest.main()
