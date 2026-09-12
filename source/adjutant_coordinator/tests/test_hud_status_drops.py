# -*- coding: utf-8 -*-
"""副官面板文案：本轮**丢弃原因**必须可见（2026-09-12 实机回归）。

背景：副官的命令全部被判重丢弃（`duplicate_of_live_intent`）导致整局停摆，
而面板只显示"本轮没有新命令" —— 玩家看到的现象是"看不到 AI 副官指挥部队的信标"，
把表现层当成坏了，真正的静默失效藏在日志里。所以面板必须直接暴露丢弃统计。
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.deploy.agent_runner import AgentRunner  # noqa: E402


class DroppedReasonLabelTest(unittest.TestCase):
    """丢弃原因 → 中文标签的聚合（面板文案由 runner 统一保证说人话）。"""

    def test_known_reasons_are_aggregated_and_labeled(self):
        counts = AgentRunner._dropped_reason_counts([
            {"intent_id": "i-1",
             "reason": "duplicate_of_live_intent:bt-gather-Unit_2-71976"},
            {"intent_id": "i-2", "reason": "duplicate_of_live_intent:i-9"},
            {"intent_id": "i-3", "reason": "lease_owner_player:Unit_1"},
        ])
        self.assertEqual(counts, {"重复在途": 2, "玩家已接管": 1})

    def test_unknown_reason_falls_back_to_other(self):
        counts = AgentRunner._dropped_reason_counts([
            {"intent_id": "i-1", "reason": "brand_new_reason"},
            {"intent_id": "i-2", "reason": ""},
        ])
        self.assertEqual(counts, {"其他": 2})

    def test_no_drops_is_empty(self):
        self.assertEqual(AgentRunner._dropped_reason_counts(None), {})
        self.assertEqual(AgentRunner._dropped_reason_counts([]), {})

    def test_panel_suffix_mentions_reason(self):
        """面板文案拼装：没有下发命令时，必须带上丢弃条数与原因。"""
        counts = AgentRunner._dropped_reason_counts([
            {"intent_id": "i-%d" % index,
             "reason": "duplicate_of_live_intent:i-old"}
            for index in range(6)
        ])
        text = "本轮没有新命令"
        text += "（丢弃 %d 条：%s）" % (
            sum(counts.values()),
            "、".join("%s×%d" % (label, count) for label, count in counts.items()))
        self.assertEqual(text, "本轮没有新命令（丢弃 6 条：重复在途×6）")


if __name__ == "__main__":
    unittest.main()
