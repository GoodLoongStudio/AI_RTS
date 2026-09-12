# -*- coding: utf-8 -*-
"""P0 高频扫描链路守门测试（计划《高频扫描、多线并行与安全行军》§3.1/§4/§8-P0）。

钉住的不变式：

1. 扫描层**只读、只入队**：快照队列有界且丢旧值，不阻塞、不写状态；
2. 增量事件**按 seq 去重**：重复投递不重复计数，游标只增不减；
3. `effective_tick`（三级时间戳第三级）**只在能证明时**写入 ——
   采集/移动没有证据就不许标"已生效"（不许把"发了命令"当"已生效"）。
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.deploy.fast_scan import (  # noqa: E402
    FastScanner, plausible_age,
)
from adjutant_coordinator.graph import nodes  # noqa: E402


class _FakeContext:
    def __init__(self, observation):
        self.observation = observation


def _payload(seq_from, events, tick=1000):
    return {
        "ok": True,
        "state": {"server_tick": tick, "sampled_at": 1.0, "snapshot_id": seq_from,
                  "event_seq": seq_from, "map_bounds": [60.0, 60.0], "nav_revision": 3,
                  "units": [], "visible_enemies": [], "production": []},
        "events": events,
        "next_event_seq": seq_from,
    }


class FastScannerTest(unittest.TestCase):
    def _scanner(self, responses, queue_size=2):
        calls = []

        def fake_tcp(port, payload, timeout=None):
            calls.append(payload)
            index = min(len(calls) - 1, len(responses) - 1)
            return responses[index]

        scanner = FastScanner(24579, "Player_0", tcp_json=fake_tcp,
                              interval=0.02, queue_size=queue_size)
        scanner._poll_once(0.0)   # 不启线程，直接跑一次轮询（确定性）
        return scanner, calls

    def test_queue_is_bounded_and_keeps_latest(self):
        scanner, calls = self._scanner([_payload(1, [], 1001), _payload(2, [], 1002)])
        scanner._poll_once(0.0)
        scanner._poll_once(0.0)
        # 队列有界（2）：旧快照被丢掉，`latest()` 一定是最后一份。
        self.assertEqual(scanner.stats()["queued_snapshots"], 2)
        self.assertEqual(scanner.latest()["server_tick"], 1002)
        # 扫描只读：请求体里永远是 fast_state + 增量游标，不带任何写操作。
        self.assertTrue(all(item["op"] == "adjutant_fast_state" for item in calls))

    def test_events_are_deduped_by_seq(self):
        events = [{"seq": 5, "kind": "receipt", "sampled_at": 1.0},
                  {"seq": 6, "kind": "damage", "sampled_at": 1.0}]
        scanner, _ = self._scanner([_payload(6, events)])
        first = scanner.drain_events()
        self.assertEqual([item["seq"] for item in first], [5, 6])
        # 同一批事件再投递（上游重发）不得重复消费。
        scanner._poll_once(0.0)
        self.assertEqual(scanner.drain_events(), [])

    def test_stats_expose_age_and_rate(self):
        scanner, _ = self._scanner([_payload(1, [])])
        stats = scanner.stats()
        for key in ("scan_hz", "snapshot_age_p50", "snapshot_age_p95", "snapshot_age_max",
                    "event_latency_p95", "event_seq", "consumed_seq"):
            self.assertIn(key, stats)
        self.assertEqual(stats["scan_errors"], 0)


class PlausibleAgeTest(unittest.TestCase):
    """跨进程时间戳必须做合理性校验：**宁可标未知，也不上报假指标**。

    实测踩过：游戏侧用 `Time.get_ticks_msec()`（引擎运行时长）当 epoch 秒上报，
    Python 侧用 `time.time()` 相减 → `snapshot_age_p50 = 1789227830s`。
    这种假数字会让"快照年龄"这个验收指标彻底失去意义。
    """

    def test_normal_age(self):
        self.assertAlmostEqual(plausible_age(1000.5, 1000.2), 0.3, places=3)

    def test_engine_uptime_is_rejected_as_unknown(self):
        # 引擎运行时长（几万秒）与 epoch 秒（17 亿）口径不同 → 必须判为未知。
        self.assertIsNone(plausible_age(1789227830.9, 12345.6))
        self.assertIsNone(plausible_age(1789227830.9, 0))

    def test_missing_or_bad_values_are_unknown(self):
        self.assertIsNone(plausible_age(1000.0, None))
        self.assertIsNone(plausible_age(1000.0, "abc"))

    def test_scanner_counts_unknown_age_separately(self):
        scanner = FastScanner(24579, "Player_0",
                              tcp_json=lambda port, payload, timeout=None: {
                                  "ok": True,
                                  "state": {"server_tick": 1, "sampled_at": 12345.6},
                                  "events": [], "next_event_seq": 0},
                              interval=0.02)
        scanner._poll_once(0.0)
        stats = scanner.stats()
        self.assertEqual(stats["snapshot_age_samples"], 0)
        self.assertEqual(stats["snapshot_age_unknown"], 1,
                         "口径不一致必须显式计数，不能让它看起来像 0 秒")


class ConsumeFastEventsTest(unittest.TestCase):
    def _state(self):
        return {
            "server_tick": 1000,
            "active_intents": [
                {"intent_id": "rule-produce-soldier-Unit_4-900", "action": "produce",
                 "unit_ids": ["Unit_4"], "state": "active"},
                {"intent_id": "rule-fill-gather-Unit_7-900", "action": "gather",
                 "unit_ids": ["Unit_7"], "state": "active"},
            ],
        }

    def test_produce_effect_is_stamped_from_production_started(self):
        state = self._state()
        nodes._consume_fast_events(state, _FakeContext({"fast_events": [
            {"seq": 1, "kind": "production_started", "unit": "Unit_4", "server_tick": 1010}]}))
        record = state["active_intents"][0]
        self.assertEqual(record.get("effective_tick"), 1010)
        self.assertEqual(state["fast_event_seq"], 1)

    def test_gather_is_never_stamped_without_evidence(self):
        """采集没有可用的证据事件 → 必须保持"未证明"，不许拿别的动作当证据。"""
        state = self._state()
        nodes._consume_fast_events(state, _FakeContext({"fast_events": [
            {"seq": 1, "kind": "damage", "unit": "Unit_7", "server_tick": 1010}]}))
        self.assertIsNone(state["active_intents"][1].get("effective_tick"))

    def test_replay_does_not_double_count(self):
        state = self._state()
        events = [{"seq": 4, "kind": "damage", "unit": "Unit_4", "server_tick": 1010}]
        nodes._consume_fast_events(state, _FakeContext({"fast_events": events}))
        nodes._consume_fast_events(state, _FakeContext({"fast_events": events}))
        consumed = [item for item in state.get("decision_log", [])
                    if item.get("kind") == "fast_events_consumed"]
        self.assertEqual(len(consumed), 1, "同一 seq 重复投递不得重复计数")
        self.assertEqual(state["fast_event_seq"], 4)

    def test_no_events_is_a_noop(self):
        state = self._state()
        nodes._consume_fast_events(state, _FakeContext({}))
        self.assertNotIn("fast_event_seq", state)


if __name__ == "__main__":
    unittest.main()
