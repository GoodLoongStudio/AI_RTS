# -*- coding: utf-8 -*-
"""连续性验收口径的守门测试（`tools/continuity_report.py`）。

用户 2026-09-13 定的口径：**约 2Hz 只是参考节拍**，大规模战场允许约 2 秒一轮；
验收看的是"多个编队和生产设施同时持续工作、生产及时接续、已有任务不中断、
各线路不长期饿死、关键事件及时响应"，以及"只发变化意图、不为凑频率重复下令"。
**同时不许用"允许 2 秒"掩盖积压、断线或无故停产** —— 所以这个分析器必须两边都能判：
  ① 节奏慢但活干得对 → 通过；
  ② 节奏很快但任务被反复重下 / 线路饿死 / 停产 / 静默 → 不通过。
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "..", "tools"))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

import continuity_report as cont  # noqa: E402


def tick(index, *, ts=None, lanes=None, accepted=None, live=None, dropped=None,
         degraded="", elapsed_ms=250.0):
    record = {"kind": "tick", "server_tick": 600 + index * 30,
              "ts": (ts if ts is not None else 1789000000.0 + index * 0.5),
              "elapsed_ms": elapsed_ms, "observe_ms": 30,
              "degraded_reason": degraded, "accepted": list(accepted or []),
              "dropped": list(dropped or []), "live_intents": list(live or []),
              "lanes": lanes if lanes is not None else {
                  "economy": {"tasks": 3, "pending": 1, "idle_ticks": 30},
                  "build": {"tasks": 1, "pending": 1, "idle_ticks": 60},
                  "scout": {"tasks": 1, "pending": 0, "idle_ticks": 90},
                  "military": {"tasks": 4, "pending": 1, "idle_ticks": 30},
                  "urgent": {"tasks": 0, "pending": 0, "idle_ticks": 0}}}
    return record


def scan(index, *, producers=2, busy=1, items=1, latency=0.05):
    return {"kind": "fast_scan", "server_tick": 600 + index * 30,
            "fast_production_units": producers, "fast_production_busy": busy,
            "fast_production_items": items, "event_latency_p95": latency}


def healthy(rounds=40, *, producers=2, busy=1):
    records = []
    for index in range(rounds):
        records.append(tick(index, live=[{"intent_id": "i-%d" % index, "action": "gather",
                                          "unit_ids": ["Unit_1"], "state": "active"}]))
        records.append(scan(index, producers=producers, busy=busy))
    records.append({"kind": "decision", "server_tick": 700,
                    "decision": {"kind": "fast_events_consumed", "count": 2,
                                 "lag_max": 40, "lag_by_kind": {"damage": 40}}})
    return records


def series(rounds, *, producers=2, idle_from=None):
    """干净的时间序列构造器：每轮 tick + scan（`idle_from` 之后设施全空）。"""
    records = []
    for index in range(rounds):
        records.append(tick(index, live=[{"intent_id": "i-%d" % index, "action": "gather",
                                          "unit_ids": ["Unit_1"], "state": "active"}]))
        idle = idle_from is not None and index >= idle_from
        records.append(scan(index, producers=producers, busy=0 if idle else 1,
                            items=0 if idle else 1))
    return records


class ContinuityAcceptanceTest(unittest.TestCase):
    def test_slow_but_continuous_passes(self):
        """**核心口径**：2.2 秒一轮（远低于旧 1.6Hz 门槛）但活持续在干 → 通过。"""
        records = []
        for index in range(40):
            records.append(tick(index, ts=1789000000.0 + index * 2.2,
                                live=[{"intent_id": "i-%d" % index, "action": "gather",
                                       "unit_ids": ["Unit_1"], "state": "active"}]))
            records.append(scan(index))
        # 关键事件事实必须齐（否则按纪律算"无法判定"，见 `analyze` 的 unknowns）。
        records.append({"kind": "decision", "server_tick": 700,
                        "decision": {"kind": "fast_events_consumed", "count": 1,
                                     "lag_max": 30, "lag_by_kind": {"damage": 30}}})
        report = cont.analyze(records)
        self.assertLess(report["cadence"]["hz_avg"], 1.6, "这是慢节奏的局")
        self.assertGreater(report["cadence"]["hz_avg"], cont.MIN_COORD_HZ)
        self.assertEqual(report["problems"], [], "节奏慢但连续 → 不该报问题")

    def test_silent_gap_is_not_hidden_by_two_second_allowance(self):
        """**不许用"允许 2 秒"掩盖断线**：出现 8 秒静默 → 必须报出来。"""
        records = healthy()
        records.insert(20, tick(9, ts=1789000000.0 + 9 * 0.5 + 8.0))
        problems = cont.analyze(records)["problems"]
        self.assertTrue(any("静默" in item for item in problems), problems)

    def test_repeated_issuance_is_flagged(self):
        """**只发变化意图**：同一单位同动作同目标还在跑又下发 → 必须报出来。

        tick 日志里 `accepted` 是 intent_id 列表、内容在 `live_intents` 里 ——
        分析器按"id → 活跃意图内容"还原指纹，所以这里按真实形状构造。
        """
        records = healthy()
        running = {"intent_id": "i-live", "action": "attack_move", "unit_ids": ["Unit_4"],
                   "target": {"pos": [40.0, 40.0]}, "state": "active",
                   "issued_tick": 600, "expires_tick": 3600}      # 窗口还早
        records[10] = tick(5, live=[running])                     # 上一轮：这条路已经在跑
        records[12] = tick(6, live=[running, dict(running, intent_id="i-reissued")],
                           accepted=["i-reissued"])               # 又下发同一条
        report = cont.analyze(records)
        self.assertEqual(report["issuance"]["repeat_issued"], 1)
        self.assertTrue(any("重复下发" in item for item in report["problems"]))

    def test_new_production_item_is_not_a_repeat(self):
        """**生产接续不算重复下令**：同一兵营产完一个再产下一个，动作/单位/场景全一样，
        但生产项 id 不同 —— 这是本职接续（实测 2026-09-13：180 秒局被判 44 条"重复"，
        逐条核对全是 `rule-produce-soldier-Unit_13` 的接续单）。"""
        records = healthy()
        first = {"intent_id": "rule-produce-soldier-Unit_13-985", "action": "produce",
                 "unit_ids": ["Unit_13"], "target": {"producer": "Unit_13",
                                                     "scene": "res://source/match/units/Infantry.tscn"},
                 "state": "active", "issued_tick": 985, "expires_tick": 2185,
                 "item_id": "item-aaaa"}
        second = dict(first, intent_id="rule-produce-soldier-Unit_13-1105",
                      issued_tick=1105, expires_tick=2305, item_id="item-bbbb")
        records[10] = tick(5, live=[first])
        records[12] = tick(6, live=[second], accepted=["rule-produce-soldier-Unit_13-1105"])
        report = cont.analyze(records)
        self.assertEqual(report["issuance"]["repeat_issued"], 0)
        self.assertNotIn("重复下发", " ".join(report["problems"]))

    def test_new_site_vs_finish_site_is_not_a_repeat(self):
        """**新建工地 ≠ 续建同一工地**：动作与单位相同、对象不同 → 不是重复下令。"""
        records = healthy()
        building = {"intent_id": "rule-build-barracks-Unit_3-684", "action": "build",
                    "unit_ids": ["Unit_3"], "target": {"producer": "Unit_3",
                                                       "pos": [12.0, 12.0]},
                    "state": "active", "issued_tick": 684, "expires_tick": 4284}
        finishing = {"intent_id": "rule-finish-site-Unit_3-745", "action": "build",
                     "unit_ids": ["Unit_3"], "target": {"entity_id": "Unit_13", "site": "Unit_13"},
                     "state": "active", "issued_tick": 745, "expires_tick": 4345}
        records[10] = tick(5, live=[building])
        records[12] = tick(6, live=[building, finishing], accepted=["rule-finish-site-Unit_3-745"])
        report = cont.analyze(records)
        self.assertEqual(report["issuance"]["repeat_issued"], 0)

    def test_expiry_renewal_is_not_a_repeat(self):
        """**续期不算凑频率**：上一条已经过期再下发同一条，是生产接续/长任务续命的本职工作。

        实测（2026-09-13，180 秒真机局）：首版判据把这类判成"重复下发 83 条"，
        逐条核对发现绝大多数是 `fallback-hold-*` / `rule-produce-*` 的**窗口续期**
        （新一条的 issued 恰好等于上一条 expires+1）。
        """
        records = healthy()
        expired = {"intent_id": "i-old", "action": "hold", "unit_ids": ["Unit_9"],
                   "target": {}, "state": "active",
                   "issued_tick": 700, "expires_tick": 780}
        renewed = dict(expired, intent_id="i-new", issued_tick=780, expires_tick=1080)
        records[10] = tick(5, live=[expired])                     # tick=750
        records[12] = tick(6, live=[renewed], accepted=["i-new"])  # tick=780（上一轮恰好到期）
        report = cont.analyze(records)
        self.assertEqual(report["issuance"]["repeat_issued"], 0)
        self.assertGreaterEqual(report["issuance"]["renewals"], 0)
        self.assertNotIn("重复下发", " ".join(report["problems"]))

    def test_changed_target_is_not_a_repeat(self):
        """改了目标 = 变化意图 → 不算重复下发（否则"调整命令"会被误判成凑频率）。"""
        records = healthy()
        first = {"intent_id": "i-1", "action": "attack_move", "unit_ids": ["Unit_4"],
                 "target": {"pos": [40.0, 40.0]}, "state": "active"}
        moved = dict(first, intent_id="i-2", target={"pos": [60.0, 40.0]})
        records[10] = tick(5, live=[first])
        records[12] = tick(6, live=[moved], accepted=["i-2"])
        report = cont.analyze(records)
        self.assertEqual(report["issuance"]["repeat_issued"], 0)
        self.assertNotIn("重复下发", " ".join(report["problems"]))

    def test_blocked_repeats_are_evidence_not_violation(self):
        """重复下令**被仲裁层挡掉**是纪律生效的证据，不算违规（单独报）。"""
        records = healthy()
        records.append({"kind": "decision", "server_tick": 700,
                        "decision": {"kind": "intent_dropped", "intent_id": "i-9",
                                     "reason": "duplicate_of_live_intent:i-8"}})
        report = cont.analyze(records)
        self.assertEqual(report["interruptions"]["repeat_blocked"], 1)
        self.assertEqual(report["problems"], [])

    def test_unexplained_production_idle_is_flagged(self):
        """**不许无故停产**：有设施却长时间没有任何在产项 → 报。

        100 轮 × 30 tick/轮 = 每轮 0.5 秒；从第 10 轮起全空 → 后半程 50 × 0.5 = 25 秒空转。
        """
        report = cont.analyze(series(100, producers=2, idle_from=10))
        self.assertGreater(report["production"]["max_idle_s"], cont.MAX_PRODUCTION_IDLE_S)
        self.assertTrue(any("空转" in item or "在产" in item for item in report["problems"]))

    def test_lane_starvation_is_flagged(self):
        """**各线路不长期饿死**：有候选、该线又**没有活跃任务**、长期没被服务 → 必须报。

        注意口径（2026-09-13 修正）：`lane_starved` 单条只算观察项 —— 新纪律是
        "只发送变化意图"，正在跑任务的线本来就不该每轮下新命令（实测把这种报成违规
        就是假警报：economy 报 idle 1141 tick 时它其实有 2 个采集工在干活）。
        """
        records = healthy()
        records.append({"kind": "decision", "server_tick": 900,
                        "decision": {"kind": "lane_starved",
                                     "starved": [{"lane": "scout", "pending": 2,
                                                  "tasks": 0, "idle_ticks": 1200}]}})
        report = cont.analyze(records)
        self.assertEqual(report["lanes"]["starve_events"].get("scout"), 1)
        self.assertEqual(report["lanes"]["genuine_starvation"].get("scout"), 1)
        self.assertTrue(any("真的被饿死" in item for item in report["problems"]))

    def test_lane_without_new_orders_but_working_is_not_starvation(self):
        """有活在干、只是没下新命令 → **不算**饿死（否则和"只发变化意图"自相矛盾）。"""
        records = healthy()
        records.append({"kind": "decision", "server_tick": 900,
                        "decision": {"kind": "lane_starved",
                                     "starved": [{"lane": "economy", "pending": 1,
                                                  "tasks": 2, "idle_ticks": 1141}]}})
        report = cont.analyze(records)
        self.assertEqual(report["lanes"]["starve_events"].get("economy"), 1)
        self.assertEqual(report["lanes"].get("genuine_starvation"), {})
        self.assertFalse(any("真的被饿死" in item for item in report["problems"]))

    def test_idle_lane_with_work_to_do_is_flagged(self):
        """**线路空转**：后半程经济/建造/军事线长期没有活跃任务 → 报。"""
        records = []
        for index in range(40):
            records.append(tick(index, lanes={
                "economy": {"tasks": 0, "pending": 1, "idle_ticks": 1200},
                "build": {"tasks": 0, "pending": 1, "idle_ticks": 1200},
                "scout": {"tasks": 1, "pending": 0, "idle_ticks": 30},
                "military": {"tasks": 0, "pending": 1, "idle_ticks": 1200},
                "urgent": {"tasks": 0, "pending": 0, "idle_ticks": 0}}))
            records.append(scan(index))
        report = cont.analyze(records)
        self.assertLess(report["lanes"]["active_ratio_tail"]["economy"],
                        cont.MIN_LANE_ACTIVE_RATIO)
        self.assertTrue(any("线后半程只有" in item for item in report["problems"]), 
                        report["problems"])

    def test_batch_limit_backlog_is_flagged(self):
        """**不许用"2 秒一轮"掩盖积压**：批量截断/在途未结算出现 → 报。"""
        records = healthy()
        records.append({"kind": "decision", "server_tick": 800,
                        "decision": {"kind": "intent_dropped", "intent_id": "i-3",
                                     "reason": "batch_limit_exceeded"}})
        records.append({"kind": "decision", "server_tick": 830,
                        "decision": {"kind": "intent_dropped", "intent_id": "i-4",
                                     "reason": "pending_authority_unresolved"}})
        report = cont.analyze(records)
        self.assertEqual(report["interruptions"]["backlog"], 2)
        self.assertTrue(any("积压" in item for item in report["problems"]))

    def test_unjustified_task_drop_is_flagged(self):
        """**已有任务不中断**：紧急抢占/玩家接管之外的中途消失要报出来。"""
        records = healthy()
        records.append({"kind": "decision", "server_tick": 900,
                        "decision": {"kind": "intent_dropped", "intent_id": "i-77",
                                     "reason": "superseded_by_new_orders"}})
        report = cont.analyze(records)
        self.assertEqual(report["interruptions"]["unjustified"], 1)
        self.assertTrue(any("无故中断" in item for item in report["problems"]))

    def test_emergency_preemption_is_legitimate(self):
        """紧急抢占是计划 §5 明确允许的（"紧急线可以抢占"），不算任务中断。"""
        records = healthy()
        records.append({"kind": "decision", "server_tick": 900,
                        "decision": {"kind": "intent_dropped", "intent_id": "i-78",
                                     "reason": "preempted_by_emergency"}})
        records.append({"kind": "decision", "server_tick": 930,
                        "decision": {"kind": "intent_dropped", "intent_id": "i-79",
                                     "reason": "lease_owner_player:Unit_4"}})
        report = cont.analyze(records)
        self.assertEqual(report["interruptions"]["unjustified"], 0)
        self.assertEqual(report["problems"], [])

    def test_event_response_latency_is_measured(self):
        """**关键事件及时响应**：事件发生 → 本轮处理，p95 超阈值要报。"""
        records = healthy()
        records.append({"kind": "decision", "server_tick": 900,
                        "decision": {"kind": "fast_events_consumed", "count": 1,
                                     "lag_max": int(cont.MAX_EVENT_LAG_P95_S * cont.TICK_HZ) + 60,
                                     "lag_by_kind": {"unit_dead": 300}}})
        report = cont.analyze(records)
        self.assertGreater(report["events"]["event_to_round_max_s"],
                           cont.MAX_EVENT_LAG_P95_S)
        self.assertTrue(any("关键事件" in item for item in report["problems"]))

    def test_parallel_workstreams_required(self):
        """**多编队 + 多设施同时工作**：只有一条线在动 → 报。"""
        records = []
        for index in range(40):
            records.append(tick(index, lanes={
                "economy": {"tasks": 1, "pending": 0, "idle_ticks": 30},
                "build": {"tasks": 0, "pending": 0, "idle_ticks": 900},
                "scout": {"tasks": 0, "pending": 0, "idle_ticks": 900},
                "military": {"tasks": 0, "pending": 0, "idle_ticks": 900},
                "urgent": {"tasks": 0, "pending": 0, "idle_ticks": 0}}))
            records.append(scan(index, producers=0, busy=0, items=0))
        report = cont.analyze(records)
        self.assertLess(report["parallel"]["ratio_at_least_min"], cont.MIN_PARALLEL_RATIO)
        self.assertTrue(any("并行工作流" in item for item in report["problems"]))

    def test_empty_log_is_reported_not_passed(self):
        report = cont.analyze([])
        self.assertTrue(report["problems"])


if __name__ == "__main__":
    unittest.main()
