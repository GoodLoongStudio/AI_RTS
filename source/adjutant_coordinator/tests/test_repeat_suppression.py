# -*- coding: utf-8 -*-
"""重复命令抑制（2026-09-12 用户反馈"工人采集下达一次就够了，行为树会自己循环"）。

背景与实测：微操层每轮都跑，而意图在被拒/拥塞后会被丢掉 → 仲裁的"活跃意图去重"随之失效
→ 下一轮把同一条命令重发 → 更拥塞（实测 LedgerFull 527 / Accepted 仅 3）。
因此需要一层**与意图存活无关**的"最近下发指纹窗口"：

1. 指纹本身：同单位+同动作+同目标才算同一条；坐标抖动（<1 米）不算变化；
2. 窗口：窗口内重复 → 抑制；窗口外 → 允许（任务生命周期结束后可以重派）；
3. 微操层集成：同一观测连跑两轮，第二轮不再重复补同一条意图；
4. 拥塞类回执（LedgerFull 等）→ 意图保留为 `retry_wait`（不是失败），并记录退避时刻。
"""

import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)

from adjutant_coordinator.graph import nodes  # noqa: E402
from adjutant_coordinator.graph.nodes import (  # noqa: E402
    CONGESTION_BACKOFF_TICKS, GraphConfig, GraphServices, NodeContext,
    ORDER_REPEAT_WINDOW_TICKS, _apply_receipt_to_state, _order_signature,
    _remember_order, _repeat_suppressed, _run_micro_layer,
)

from graph_test_helpers import MATCH, PLAYER, rules_view, tactical  # noqa: E402

OWN = [
    {"name": "Unit_0", "unit_type": "command_center", "movement": False,
     "queue": True, "pos": [0.0, 0.0, 0.0]},
    {"name": "Unit_2", "unit_type": "worker", "movement": True, "gather": True,
     "construct": True, "pos": [6.0, 0.0, 6.0]},
    {"name": "Unit_4", "unit_type": "drone", "movement": True, "pos": [8.0, 0.0, 8.0]},
]


def _services() -> GraphServices:
    return GraphServices(config=GraphConfig(strategy_interval_ticks=10 ** 9,
                                            tactics_interval_ticks=120))


def _context(tick: int) -> NodeContext:
    return NodeContext(services=_services(),
                       observation={"tactical": tactical(own=OWN, server_tick=tick),
                                    "rules": rules_view()},
                       tick=tick)


def _state(tick: int = 1000):
    return {
        "match_id": MATCH, "player_id": PLAYER, "server_tick": tick,
        "latest_snapshot_id": tick, "ai_controlled_units": [u["name"] for u in OWN],
        "unit_generations": {u["name"]: 1 for u in OWN},
        "candidate_intents": [], "recent_orders": {}, "decision_log": [],
    }


class SignatureTest(unittest.TestCase):

    def test_same_order_same_signature_ignores_sub_meter_jitter(self):
        first = {"unit_ids": ["Unit_2"], "action": "move",
                 "target": {"pos": [12.04, 3.02]}}
        second = {"unit_ids": ["Unit_2"], "action": "move",
                  "target": {"pos": [12.0, 3.0]}}
        self.assertEqual(_order_signature(first), _order_signature(second))

    def test_different_action_or_unit_differs(self):
        base = {"unit_ids": ["Unit_2"], "action": "move", "target": {"pos": [12, 3]}}
        other_action = {"unit_ids": ["Unit_2"], "action": "gather",
                        "target": {"pos": [12, 3]}}
        other_units = {"unit_ids": ["Unit_2", "Unit_4"], "action": "move",
                       "target": {"pos": [12, 3]}}
        self.assertNotEqual(_order_signature(base), _order_signature(other_action))
        self.assertNotEqual(_order_signature(base), _order_signature(other_units))

    def test_entity_target_wins_over_position(self):
        item = {"unit_ids": ["Unit_2"], "action": "gather",
                "target": {"entity_id": "ResourceA5", "pos": [1, 2]}}
        self.assertIn("ResourceA5", _order_signature(item))


class WindowTest(unittest.TestCase):

    def test_suppressed_within_window_then_allowed(self):
        state = {}
        item = {"unit_ids": ["Unit_2"], "action": "gather",
                "target": {"entity_id": "ResourceA5"}}
        _remember_order(state, item, 1000)
        self.assertTrue(_repeat_suppressed(state, item, 1000 + 10))
        self.assertTrue(_repeat_suppressed(state, item,
                                           1000 + ORDER_REPEAT_WINDOW_TICKS - 1))
        self.assertFalse(_repeat_suppressed(state, item,
                                            1000 + ORDER_REPEAT_WINDOW_TICKS))

    def test_old_entries_are_pruned(self):
        state = {}
        _remember_order(state, {"unit_ids": ["A"], "action": "move",
                                "target": {"pos": [1, 1]}}, 1000)
        _remember_order(state, {"unit_ids": ["B"], "action": "move",
                                "target": {"pos": [2, 2]}},
                        1000 + ORDER_REPEAT_WINDOW_TICKS + 1)
        self.assertEqual(len(state["recent_orders"]), 1, "过期指纹必须被清理")

    def test_finished_produce_is_not_suppressed_as_repeat(self):
        """T09：同一设施产完再下一单是接续，不能被 900 tick 窗口误伤。"""
        item = {"unit_ids": ["Unit_0"], "action": "produce",
                "target": {"scene": "res://source/match/units/Infantry.tscn",
                           "producer": "Unit_0"}}
        state = {
            "active_intents": [{
                "intent_id": "rule-produce-soldier-Unit_0-1000",
                "action": "produce", "unit_ids": ["Unit_0"],
                "state": "completed", "expires_tick": 100000,
                "target": dict(item["target"]),
            }],
        }
        _remember_order(state, item, 1000)
        self.assertFalse(_repeat_suppressed(state, item, 1040),
                         "上一单已完成：必须允许接续")

    def test_live_produce_is_still_suppressed(self):
        """还在产的同一条不得再发（接续不是『无视去重』）。"""
        item = {"unit_ids": ["Unit_0"], "action": "produce",
                "target": {"scene": "res://source/match/units/Infantry.tscn",
                           "producer": "Unit_0"}}
        state = {
            "active_intents": [{
                "intent_id": "rule-produce-soldier-Unit_0-1000",
                "action": "produce", "unit_ids": ["Unit_0"],
                "state": "active", "expires_tick": 100000,
                "target": dict(item["target"]),
            }],
        }
        _remember_order(state, item, 1000)
        self.assertTrue(_repeat_suppressed(state, item, 1040))

    def test_en_route_advance_is_suppressed_even_if_waypoint_changed(self):
        """前压点每轮重算：换坐标也不能再发（T13 / u4dev 重复下发）。"""
        state = {
            "server_tick": 1606, "nav_revision": 0,
            "routes": {"Unit_6": {
                "ok": True, "route_id": "r1", "nav_revision": 0,
                "last_replan_tick": 1367, "relay_point": [20.0, 7.0],
                "target": [40.0, 7.0],
            }},
        }
        item = {"unit_ids": ["Unit_6"], "action": "attack_move",
                "target": {"pos": [38.2, 12.4]}}
        self.assertTrue(_repeat_suppressed(state, item, 1606))

    def test_retreat_is_not_blocked_by_hop_hold(self):
        """求生必须能打断当前跳。"""
        state = {
            "server_tick": 1606, "nav_revision": 0,
            "routes": {"Unit_6": {
                "ok": True, "route_id": "r1", "nav_revision": 0,
                "last_replan_tick": 1367, "relay_point": [20.0, 7.0],
                "target": [40.0, 7.0],
            }},
        }
        item = {"unit_ids": ["Unit_6"], "action": "retreat",
                "target": {"pos": [8.0, 7.0]}}
        self.assertFalse(_repeat_suppressed(state, item, 1606))


class MicroLayerSuppressionTest(unittest.TestCase):

    def test_second_round_does_not_reissue_same_orders(self):
        state = _state(1000)
        first = _context(1000)
        _run_micro_layer(state, first)
        added_first = len(state.get("candidate_intents") or [])
        self.assertGreater(added_first, 0, "第一轮必须真的补了意图")
        # 模拟"下发成功"（真实链路上由 node_dispatch_to_godot 记录指纹）
        for item in state["candidate_intents"]:
            _remember_order(state, item, 1000)

        state["server_tick"] = 1040          # 40 tick 后、仍在抑制窗口内
        state["candidate_intents"] = []
        logged_before = len(state["decision_log"])   # 只看第二轮新产生的留痕
        _run_micro_layer(state, _context(1040))
        self.assertEqual(state.get("candidate_intents") or [], [],
                         "窗口内不得重复补同一条意图")
        kinds = [entry.get("kind") for entry in state["decision_log"][logged_before:]]
        self.assertNotIn("micro_control_added", kinds)

    def test_after_window_orders_are_allowed_again(self):
        state = _state(1000)
        _run_micro_layer(state, _context(1000))
        for item in state["candidate_intents"]:
            _remember_order(state, item, 1000)
        later = 1000 + ORDER_REPEAT_WINDOW_TICKS + 5
        state["server_tick"] = later
        state["candidate_intents"] = []
        _run_micro_layer(state, _context(later))
        self.assertGreater(len(state.get("candidate_intents") or []), 0,
                           "窗口过后应允许重新派活（任务可能已结束）")


class CongestionReceiptTest(unittest.TestCase):

    def test_congestion_is_retry_wait_not_failure(self):
        state = {"server_tick": 5000, "active_intents": [
            {"intent_id": "i-1", "state": "pending_authority", "action": "produce",
             "unit_ids": ["Unit_0"], "task_id": "t-1"}],
            "active_tasks": {"t-1": "running"}, "decision_log": []}
        _apply_receipt_to_state(state, "i-1", {
            "status": "LedgerFull", "accepted": False,
            "reason": "意图登记表已满"})
        record = state["active_intents"][0]
        self.assertEqual(record["state"], "retry_wait")
        self.assertEqual(record["drop_reason"], "")
        self.assertEqual(int(record["retry_after_tick"]),
                         5000 + CONGESTION_BACKOFF_TICKS)
        self.assertGreater(int(state["congestion_until_tick"]), 5000)
        self.assertEqual(state["congestion_events"], 1)
        # 任务状态不得被拥塞拒绝误判为失败
        self.assertEqual(state["active_tasks"]["t-1"], "running")

    def test_stale_match_receipt_is_ignored(self):
        """T16：旧局回执不得结算当前局意图。"""
        state = {"match_id": "match-now", "server_tick": 5000, "active_intents": [
            {"intent_id": "i-3", "state": "pending_authority", "action": "produce",
             "unit_ids": ["Unit_0"], "task_id": "t-3"}],
            "active_tasks": {"t-3": "running"}, "decision_log": []}
        _apply_receipt_to_state(state, "i-3", {
            "match_id": "match-old", "status": "Accepted", "accepted": True,
            "result": {"item_id": "ghost", "item": {"definition_id": "soldier"}}})
        record = state["active_intents"][0]
        self.assertEqual(record["state"], "pending_authority")
        self.assertNotIn("production", record)
        kinds = [item.get("kind") for item in state.get("decision_log") or []]
        self.assertIn("receipt_ignored_stale_match", kinds)

    def test_real_failure_still_drops(self):
        state = {"server_tick": 5000, "active_intents": [
            {"intent_id": "i-2", "state": "pending_authority", "action": "move",
             "unit_ids": ["Unit_4"], "task_id": "t-2"}],
            "active_tasks": {"t-2": "running"}, "decision_log": []}
        _apply_receipt_to_state(state, "i-2", {
            "status": "StaleGeneration", "accepted": False, "reason": "代际过期"})
        self.assertEqual(state["active_intents"][0]["state"], "dropped")


if __name__ == "__main__":
    unittest.main()
