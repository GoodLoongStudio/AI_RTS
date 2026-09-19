# -*- coding: utf-8 -*-
"""前线集结点 / 脱离点唯一口径。"""
import math
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))))

from adjutant_coordinator.graph import rules_fallback as rf  # noqa: E402


class ForwardRallyTest(unittest.TestCase):
    def test_never_returns_command_center(self):
        point = rf.forward_rally_point(
            (0.0, 0.0), bounds=[200.0, 200.0],
            combat_positions=[(40.0, 40.0)])
        self.assertIsNotNone(point)
        self.assertGreater(math.hypot(point[0], point[1]), 12.0)

    def test_aims_at_enemy_not_home(self):
        point = rf.forward_rally_point(
            (0.0, 0.0), enemies=[{"pos": [80.0, 0.0, 0.0]}],
            combat_positions=[(20.0, 0.0)])
        self.assertIsNotNone(point)
        self.assertGreater(point[0], 12.0)
        self.assertLess(point[0], 80.0)

    def test_no_evidence_returns_none(self):
        self.assertIsNone(rf.forward_rally_point((0.0, 0.0)))

    def test_home_garrison_does_not_pull_rally_home(self):
        point = rf.forward_rally_point(
            (0.0, 0.0), combat_positions=[(2.0, 2.0), (80.0, 80.0)])
        self.assertIsNotNone(point)
        self.assertGreater(math.hypot(point[0], point[1]), 40.0)

    def test_single_unit_is_not_scattered(self):
        self.assertFalse(rf.combat_scattered([(10.0, 10.0)]))

    def test_far_pair_is_scattered(self):
        self.assertTrue(rf.combat_scattered([(0.0, 0.0), (80.0, 80.0)]))

    def test_home_garrison_plus_one_field_unit_is_not_scattered(self):
        self.assertFalse(rf.combat_scattered(
            [(2.0, 2.0), (3.0, 3.0), (80.0, 80.0)], home=(0.0, 0.0)))

    def test_two_field_units_far_apart_are_scattered(self):
        self.assertTrue(rf.combat_scattered(
            [(50.0, 50.0), (90.0, 10.0)], home=(0.0, 0.0)))


class DisengageTest(unittest.TestCase):
    def test_moves_away_from_enemy_and_off_home(self):
        point = rf.disengage_point(
            (10.0, 10.0), home=(0.0, 0.0),
            enemies=[{"pos": [0.0, 0.0, 0.0]}])
        self.assertIsNotNone(point)
        self.assertGreater(math.hypot(point[0], point[1]), 12.0)
        self.assertGreater(math.hypot(point[0], point[1]),
                           math.hypot(10.0, 10.0) - 0.1)

    def test_reads_2d_enemy_pos_from_behavior_tree_facts(self):
        point = rf.disengage_point(
            (20.0, 20.0), home=(0.0, 0.0),
            enemies=[{"pos": [40.0, 20.0]}])
        self.assertIsNotNone(point)
        self.assertLess(point[0], 20.0)

    def test_clamp_does_not_send_into_the_enemy(self):
        point = rf.disengage_point(
            (10.0, 7.0), home=(5.0, 5.0),
            enemies=[{"pos": [14.0, 0.0, 7.0]}],
            bounds=[50.0, 50.0])
        self.assertIsNotNone(point)
        self.assertGreater(math.hypot(point[0] - 14.0, point[1] - 7.0), 4.0)
        self.assertGreater(math.hypot(point[0] - 5.0, point[1] - 5.0), 12.0)


if __name__ == "__main__":
    unittest.main()
