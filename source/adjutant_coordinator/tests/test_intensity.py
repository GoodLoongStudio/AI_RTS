# -*- coding: utf-8 -*-
"""副官强度等级守门：等级 → 规则地板参数的映射、默认值必须等于历史行为。

为什么要有这组测试（2026-09-15）：
- 面板上新增了"保守 / 标准 / 激进"三个等级按钮，按钮必须真的改变玩法；
- 而"默认 standard 必须等于改造前的行为"是**不把副官链路搞坏**的底线：
  不带 `--intensity` 启动的 runner 必须仍然用出击阈值 2；
- 映射一旦在别处又被写一份（历史事故全是这一类），这两个断言会立刻变红。
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph import campaign as campaign_mod  # noqa: E402
from adjutant_coordinator.graph import intensity as intensity_mod  # noqa: E402


class IntensityMappingTest(unittest.TestCase):

    def setUp(self):
        intensity_mod.reset_for_tests()
        self.addCleanup(intensity_mod.reset_for_tests)

    def test_default_level_is_standard_and_matches_legacy_threshold(self):
        """默认等级 = standard，出击阈值 = 2（改造前 `default_campaign` 的硬编码值）。"""
        self.assertEqual(intensity_mod.active(), intensity_mod.LEVEL_STANDARD)
        self.assertEqual(intensity_mod.army_threshold(), 2)
        self.assertEqual(campaign_mod.default_campaign()["army_threshold"], 2)

    def test_profiles_are_ordered_conservative_to_aggressive(self):
        """三个等级必须单调：越激进出击越早（阈值递减），否则 UI 语义是反的。"""
        thresholds = [intensity_mod.army_threshold(level) for level in intensity_mod.LEVELS]
        self.assertEqual(thresholds, sorted(thresholds, reverse=True))
        self.assertGreater(thresholds[0], thresholds[-1])
        self.assertEqual(len(set(thresholds)), len(intensity_mod.LEVELS))

    def test_unknown_level_falls_back_to_standard(self):
        """非法/空值一律回落 standard，绝不抛错（命令行拼错不许把 runner 起不来）。"""
        for bad in ("", "  ", None, "brutal", "STANDARDX", 7):
            self.assertEqual(intensity_mod.normalize(bad), intensity_mod.LEVEL_STANDARD)
        self.assertEqual(intensity_mod.set_active("brutal"), intensity_mod.LEVEL_STANDARD)

    def test_level_is_case_insensitive(self):
        self.assertEqual(intensity_mod.normalize("Agressive"), intensity_mod.LEVEL_STANDARD)
        self.assertEqual(intensity_mod.normalize("Aggressive"), intensity_mod.LEVEL_AGGRESSIVE)

    def test_describe_carries_level_label_threshold_hint(self):
        info = intensity_mod.describe(intensity_mod.LEVEL_AGGRESSIVE)
        self.assertEqual(info["level"], intensity_mod.LEVEL_AGGRESSIVE)
        self.assertEqual(info["army_threshold"], 1)
        self.assertTrue(info["label"])
        self.assertTrue(info["hint"])


class IntensityEffectTest(unittest.TestCase):

    def setUp(self):
        intensity_mod.reset_for_tests()
        self.addCleanup(intensity_mod.reset_for_tests)

    def test_new_campaign_uses_active_level(self):
        intensity_mod.set_active(intensity_mod.LEVEL_CONSERVATIVE)
        campaign = campaign_mod.default_campaign()
        self.assertEqual(campaign["army_threshold"], 4)
        self.assertEqual(campaign["intensity"], intensity_mod.LEVEL_CONSERVATIVE)

    def test_existing_campaign_follows_level_change(self):
        """同一局（旧 checkpoint）换了等级后重启 runner，阈值必须跟着变。

        否则玩家在面板上点了"激进"，重开副官却还是老阈值 —— 表现为"改了没反应"。
        """
        state = {}
        first = campaign_mod.ensure_campaign(state, tick=0)
        self.assertEqual(first["army_threshold"], 2)
        intensity_mod.set_active(intensity_mod.LEVEL_AGGRESSIVE)
        again = campaign_mod.ensure_campaign(state, tick=10)
        self.assertIs(again, first, "同局必须复用同一份 campaign 对象")
        self.assertEqual(again["army_threshold"], 1)
        self.assertEqual(again["intensity"], intensity_mod.LEVEL_AGGRESSIVE)

    def test_decision_map_preconditions_read_campaign_threshold(self):
        """出击前置条件读的就是 campaign 的阈值（强度 → 决策图这条链不许断）。"""
        from adjutant_coordinator.graph import decision_map as decision_map_mod

        facts = {"combat_count": 2}
        intensity_mod.set_active(intensity_mod.LEVEL_STANDARD)
        campaign = campaign_mod.default_campaign()
        self.assertTrue(decision_map_mod.PRECONDITIONS["combat_ready"](facts, campaign))
        self.assertFalse(decision_map_mod.PRECONDITIONS["below_army"](facts, campaign))

        intensity_mod.set_active(intensity_mod.LEVEL_CONSERVATIVE)
        campaign = campaign_mod.default_campaign()
        self.assertFalse(decision_map_mod.PRECONDITIONS["combat_ready"](facts, campaign))
        self.assertTrue(decision_map_mod.PRECONDITIONS["below_army"](facts, campaign))


if __name__ == "__main__":
    unittest.main()
