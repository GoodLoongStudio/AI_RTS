# -*- coding: utf-8 -*-
"""runner 的"对局是否进行中"判据（`agent_runner.match_active`）守门测试。

真机背景（2026-09-12）：DCS 是裸 TCP + 一行 JSON，同机并发查询时可能收到**串台载荷**。
runner 连续 6 次读到"没有 `match` 键"的响应 → 判 `match_active=false` →
以 `no_active_match` **正常退出**（不是报错，看着像"对局结束了"），
而同一对局几十秒后仍然 `match=True`。
验收脚本因此在两轮里只看到"M01/M02 完成"，差点被当成规则退化。

纪律：**异常响应不等于事实**。只有"确实是 status 响应、且其中没有 match"才允许
判定对局结束；串台载荷一律保持常驻，下一轮再判。
"""
from __future__ import annotations

import unittest

from adjutant_coordinator.deploy import agent_runner


class MatchProbeTest(unittest.TestCase):
    def setUp(self):
        self._original = agent_runner.tcp_json

    def tearDown(self):
        agent_runner.tcp_json = self._original

    def _stub(self, payload):
        agent_runner.tcp_json = lambda port, request, timeout=0.0: payload

    def test_running_match_is_active(self):
        self._stub({"match": {"id": "m-1"}, "players": [{"name": "Player_0"}]})
        self.assertTrue(agent_runner.match_active(24582))

    def test_status_without_match_means_match_over(self):
        self._stub({"players": [{"name": "Player_0"}], "is_server": True,
                    "camera": {"pos": [0, 0, 0]}})
        self.assertFalse(agent_runner.match_active(24582))

    def test_foreign_payload_is_not_treated_as_match_over(self):
        # 串台载荷：战术视图（没有 match、也没有 status 独有字段）。
        self._stub({"entities": [], "balance": {"a": 1}, "server_tick": 10,
                    "truncated": False})
        self.assertTrue(agent_runner.match_active(24582),
                        "串台响应被误判成'对局结束'（runner 会静默退出）")

    def test_non_dict_payload_is_not_treated_as_match_over(self):
        self._stub(["unexpected"])
        self.assertTrue(agent_runner.match_active(24582))
        self._stub(None)
        self.assertTrue(agent_runner.match_active(24582))

    def test_explicit_false_match_wins(self):
        self._stub({"match": None, "players": [], "is_server": True})
        self.assertFalse(agent_runner.match_active(24582))


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
