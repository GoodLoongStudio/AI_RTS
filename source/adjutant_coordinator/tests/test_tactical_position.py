import unittest

from adjutant_coordinator.tactical_position import rank_positions, score_position


class TacticalPositionTests(unittest.TestCase):
    def test_exposure_and_support_are_deterministic(self):
        result = score_position([5, 5], [0, 0],
                                [{"pos": [5, 6], "sight_range": 10}],
                                [{"pos": [4, 5]}], 10)
        self.assertEqual(result["enemy_los_count"], 1)
        self.assertEqual(result["cover_score"], None)
        self.assertGreater(result["friendly_fire_support"], 0)

    def test_cover_provider_is_explicitly_injected(self):
        result = score_position([5, 5], [0, 0],
                                [{"pos": [5, 6], "sight_range": 10}], [], 10,
                                lambda position, enemy: 0.8)
        self.assertEqual(result["cover_score"], 0.8)

    def test_rank_is_stable(self):
        result = rank_positions([[9, 9], [1, 1], [5, 5]], [0, 0], [], [], 10)
        self.assertEqual([row["position"] for row in result], [[1.0, 1.0], [5.0, 5.0], [9.0, 9.0]])

