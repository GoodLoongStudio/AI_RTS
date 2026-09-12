# -*- coding: utf-8 -*-
"""战略上下文的事件**摘要**：钉住"不给战略模型原始事件"这条纪律。

依据（2026-09-11 实测，同一对局、同一本地 2B 模型 `minicpm5-adj-16k`）：

| 事件形态 | 结果 |
|---|---|
| 无事件 | OK 6.6s |
| **原始 1 条** | **FAIL** 26.9s（1 次调用 + 2 次重试） |
| 原始 5/10/30/60 条 | FAIL 18~28s |
| **摘要 10 条 / 60 条** | **OK 5.4s / 5.6s** |

失败与体积无关，与"喂了多少可照抄的身份字段"有关：原始事件带
`event_id / match_id / player_id / payload`，小模型会照抄或试图"处理事件"，
产出不匹配 `StrategyPlan` → `ModelInvalidOutput`。
"""
import unittest

from adjutant_coordinator.graph.model_context import summarize_events


def raw_event(index, kind="queue_idle", tick=100):
    return {"event_id": "evt-%d" % index, "kind": kind, "match_id": "m-1",
            "player_id": "Player_0", "server_tick": tick + index,
            "payload": {"subject": "Unit_2"}}


class SummarizeEventsTest(unittest.TestCase):

    def test_raw_identity_fields_are_dropped(self):
        summary = summarize_events([raw_event(0), raw_event(1)])
        self.assertEqual(len(summary), 1)
        item = summary[0]
        self.assertEqual(item["kind"], "queue_idle")
        self.assertEqual(item["count"], 2)
        # 身份/负载字段一个都不能出现：它们正是"可照抄的模板"。
        for forbidden in ("event_id", "match_id", "player_id", "payload", "subject"):
            self.assertNotIn(forbidden, item)

    def test_counts_and_last_tick_are_aggregated(self):
        summary = summarize_events([
            raw_event(0, tick=10), raw_event(1, tick=20), raw_event(2, tick=30),
        ])
        self.assertEqual(summary, [{"kind": "queue_idle", "count": 3, "last_tick": 32}])

    def test_more_recent_kind_comes_first(self):
        summary = summarize_events([
            raw_event(0, "queue_idle", tick=10),
            raw_event(1, "enemy_spotted", tick=90),
        ])
        self.assertEqual([item["kind"] for item in summary],
                         ["enemy_spotted", "queue_idle"])

    def test_kind_count_is_bounded(self):
        events = [raw_event(i, "kind_%d" % i) for i in range(30)]
        self.assertEqual(len(summarize_events(events, max_kinds=8)), 8)

    def test_tolerates_garbage_input(self):
        self.assertEqual(summarize_events(None), [])
        self.assertEqual(summarize_events([None, "x", {}, {"kind": ""}]), [])


if __name__ == "__main__":
    unittest.main()
