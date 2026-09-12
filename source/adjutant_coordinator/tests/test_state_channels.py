# -*- coding: utf-8 -*-
"""状态**显式字段表**守卫：写进 working dict 的键必须能跨轮往返。

## 为什么单独钉这一条

`AdjutantGraphState.to_dict/from_dict` 是**显式字段表**，不是通用字典。任何没写进
字段表的键，在"图返回 dict → `from_dict` 装回对象"这一步会被**静默丢掉**：
功能看着写了、日志里甚至能看到，但它每轮归零。

本仓库已经因此踩过两次（`reserves`、`campaign_state`，两处都有注释），
2026-09-12 又踩第三次：P0 的 `fast_event_seq`、P1 的 `lane_cursor`/`lanes_last_served`。
所以这里用**通用往返测试**把这一类钉死：新增状态键忘了加字段表就会红。
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph.state import AdjutantGraphState  # noqa: E402

MATCH = "m-state"
PLAYER = "Player_1"

#: 必须跨轮保留的状态键（新增状态键时**往这里加一行**，忘加字段表就会红）。
REQUIRED_KEYS = (
    "campaign_state",
    "fast_event_seq",
    "lane_cursor",
    "lanes_last_served",
    "lanes",
    "nav_revision",
    "routes",
    "movement_stats",
    "movement_urgent",
)


class StateChannelRoundTripTest(unittest.TestCase):
    def test_required_keys_survive_round_trip(self):
        state = AdjutantGraphState(match_id=MATCH, player_id=PLAYER)
        state.campaign_state = {"phase": "立足"}
        state.fast_event_seq = 17
        state.lane_cursor = 3
        state.lanes_last_served = {"economy": 1200}
        state.lanes = {"economy": {"tasks": 2, "idle_ticks": 0}}
        state.nav_revision = 4
        state.routes = {"Unit_4": {"ok": True, "route_id": "route-abc"}}
        state.movement_stats = {"allowed": 2, "ungated": 0}
        state.movement_urgent = [{"kind": "enemy_on_route", "unit": "Unit_4"}]
        restored = AdjutantGraphState.from_dict(state.to_dict())
        for key in REQUIRED_KEYS:
            self.assertEqual(getattr(restored, key), getattr(state, key),
                             "状态键 %s 没能跨轮保留（字段表漏了？）" % key)

    def test_round_trip_is_stable_when_empty(self):
        state = AdjutantGraphState(match_id=MATCH, player_id=PLAYER)
        restored = AdjutantGraphState.from_dict(state.to_dict())
        self.assertEqual(restored.fast_event_seq, -1)
        self.assertEqual(restored.lane_cursor, 0)
        self.assertEqual(restored.lanes_last_served, {})


if __name__ == "__main__":
    unittest.main()
