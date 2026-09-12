# -*- coding: utf-8 -*-
"""五条独立线路守门测试（计划 §5）。

钉住的不变式：

1. 分类是**唯一口径**（工人生产归经济、作战单位归军事、紧急进紧急线）；
2. **每一轮都走完每条线路**：紧急线可以排在最前，但不得把其它线路挤掉；
3. 轮转起点随 cursor 旋转（避免永远偏向第一条线）；
4. "有活却长期没被服务"必须能被**显式发现**（饿死账），而不是靠翻日志猜。
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph import lanes  # noqa: E402


def intent(intent_id, action, *, scene="", priority=3, tick=100, emergency=False):
    return {"intent_id": intent_id, "action": action, "priority": priority,
            "issued_tick": tick, "unit_ids": ["Unit_1"], "target": {"scene": scene},
            "emergency": emergency}


class LaneOfTest(unittest.TestCase):
    def test_action_mapping(self):
        cases = {
            "gather": lanes.LANE_ECONOMY,
            "build": lanes.LANE_BUILD,
            "scout": lanes.LANE_SCOUT,
            "attack": lanes.LANE_MILITARY,
            "attack_move": lanes.LANE_MILITARY,
            "retreat": lanes.LANE_MILITARY,
        }
        for action, expected in cases.items():
            self.assertEqual(lanes.lane_of(intent("i-%s" % action, action)), expected, action)

    def test_production_is_split_by_product(self):
        worker = intent("i-worker", "produce", scene="res://units/Worker.tscn")
        soldier = intent("i-soldier", "produce", scene="res://units/Soldier.tscn")
        self.assertEqual(lanes.lane_of(worker), lanes.LANE_ECONOMY)
        self.assertEqual(lanes.lane_of(soldier), lanes.LANE_MILITARY)

    def test_product_falls_back_to_task_id(self):
        self.assertEqual(
            lanes.product_of({"task_id": "rule-produce-worker", "target": {}}), "worker")

    def test_emergency_always_goes_to_urgent(self):
        self.assertEqual(lanes.lane_of(intent("i-e", "gather", emergency=True)),
                         lanes.LANE_URGENT)


class InterleaveTest(unittest.TestCase):
    def test_every_lane_is_served_in_each_round(self):
        """三条线各 3 条：轮转后**前三名必须来自三条不同的线**（不会被某一条垄断）。"""
        items = ([intent("eco-%d" % i, "gather") for i in range(3)]
                 + [intent("bld-%d" % i, "build") for i in range(3)]
                 + [intent("mil-%d" % i, "attack") for i in range(3)])
        ordered, trace = lanes.interleave(items, cursor=0)
        self.assertEqual(len(ordered), 9)
        first_round = {lanes.lane_of(item) for item in ordered[:3]}
        self.assertEqual(first_round,
                         {lanes.LANE_ECONOMY, lanes.LANE_BUILD, lanes.LANE_MILITARY},
                         "第一轮必须覆盖三条都有活的线路：%s" % (ordered[:3],))
        self.assertEqual(trace["total"], 9)

    def test_urgent_first_but_others_never_starved(self):
        """紧急线最多、其它线各 1 条：那一条也不能被挤掉（紧急有老化上限）。"""
        items = ([intent("u-%d" % i, "attack", emergency=True) for i in range(5)]
                 + [intent("eco-0", "gather")])
        ordered, _ = lanes.interleave(items, cursor=0)
        self.assertEqual(lanes.lane_of(ordered[0]), lanes.LANE_URGENT)
        self.assertEqual(lanes.lane_of(ordered[1]), lanes.LANE_ECONOMY)

    def test_cursor_rotates_the_starting_lane(self):
        items = [intent("eco-0", "gather"), intent("bld-0", "build")]
        ordered, trace = lanes.interleave(items, cursor=1)
        self.assertEqual(trace["next_cursor"], 2)
        self.assertNotEqual(trace["rotation"], list(lanes.LANE_ORDER),
                            "cursor 必须真的旋转起点，而不是永远从紧急线开始")


class LaneSnapshotTest(unittest.TestCase):
    def test_starvation_is_detected(self):
        items = [intent("eco-0", "gather")]
        view = lanes.lane_snapshot(items, tick=10_000,
                                   last_served={lanes.LANE_ECONOMY: 1_000},
                                   pending={lanes.LANE_ECONOMY: 2}, starve_ticks=900)
        self.assertTrue(view["starved"], "本轮有候选且 9000 tick 没被服务 → 必须报饿死")
        self.assertEqual(view["starved"][0]["lane"], lanes.LANE_ECONOMY)

    def test_no_starvation_when_recently_served(self):
        items = [intent("eco-0", "gather")]
        view = lanes.lane_snapshot(items, tick=10_000,
                                   last_served={lanes.LANE_ECONOMY: 9_900},
                                   pending={lanes.LANE_ECONOMY: 2})
        self.assertEqual(view["starved"], [])

    def test_running_tasks_are_not_starvation(self):
        """**正在执行**的长任务不等于饿死（2026-09-13 实测：5 分钟假报 383 次）。

        判据必须看"本轮有没有候选被挤掉"，而不是"这条线有没有活跃意图"——
        活跃意图的 TTL 是分钟级，一条长任务会让旧判据一直误报。
        """
        items = [intent("eco-0", "gather")]
        view = lanes.lane_snapshot(items, tick=10_000,
                                   last_served={lanes.LANE_ECONOMY: 1_000},
                                   pending={lanes.LANE_ECONOMY: 0})
        self.assertEqual(view["starved"], [], "本轮没有候选 → 不是饿死")
        self.assertEqual(view[lanes.LANE_ECONOMY]["tasks"], 1, "但任务数照报（诊断用）")

    def test_snapshot_reports_tasks_and_expiry(self):
        items = [dict(intent("eco-0", "gather"), expires_tick=20_000)]
        view = lanes.lane_snapshot(items, tick=10_000, last_served={})
        self.assertEqual(view[lanes.LANE_ECONOMY]["tasks"], 1)
        self.assertEqual(view[lanes.LANE_ECONOMY]["next_expiry_tick"], 20_000)

    def test_mark_served_is_pure(self):
        before = {}
        after = lanes.mark_served(before, [lanes.LANE_BUILD], 1234)
        self.assertEqual(before, {}, "不得原地改传入的字典")
        self.assertEqual(after[lanes.LANE_BUILD], 1234)


if __name__ == "__main__":
    unittest.main()
