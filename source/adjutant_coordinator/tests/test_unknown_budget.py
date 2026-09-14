# -*- coding: utf-8 -*-
"""U3：unknown 必须限时对账，不能永久占用执行者。"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph.state import (  # noqa: E402
    AdjutantGraphState, INTENT_ACTIVE_UNKNOWN, INTENT_EXPIRED,
    UNKNOWN_BUDGET_TICKS,
)


def _unknown_intent(since=100, expires=10 ** 9):
    return {
        "intent_id": "i-unknown",
        "action": "gather",
        "unit_ids": ["Unit_2"],
        "state": INTENT_ACTIVE_UNKNOWN,
        "issued_tick": since,
        "unknown_since_tick": since,
        "expires_tick": expires,
    }


class UnknownBudgetTest(unittest.TestCase):
    def test_within_budget_keeps_occupancy(self):
        state = AdjutantGraphState(match_id="m", player_id="p")
        state.active_intents.append(_unknown_intent())
        expired = state.expire_intents(100 + UNKNOWN_BUDGET_TICKS - 1)
        self.assertEqual(expired, [])
        self.assertEqual(state.active_intents[0]["state"], INTENT_ACTIVE_UNKNOWN)

    def test_past_budget_releases_as_expired_not_failed(self):
        """预算到点：释放占用，标 expired，不标 failed（禁止据此重发同一条）。"""
        state = AdjutantGraphState(match_id="m", player_id="p")
        state.active_intents.append(_unknown_intent())
        expired = state.expire_intents(100 + UNKNOWN_BUDGET_TICKS)
        self.assertEqual(len(expired), 1)
        self.assertEqual(state.active_intents[0]["state"], INTENT_EXPIRED)
        self.assertEqual(state.active_intents[0]["drop_reason"], "unknown_budget_exceeded")
        self.assertNotEqual(state.active_intents[0]["state"], "failed")
        live = state.live_intents(100 + UNKNOWN_BUDGET_TICKS)
        self.assertEqual(live, [])
