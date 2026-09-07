# -*- coding: utf-8 -*-
"""Transport 测试：环回/假通道脚本行为、断线留证、重连身份校验、心跳、关闭幂等。"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.transport import (
    ConnectionState, FakeTransport, LoopbackTransport, ResilientTransport,
    TransportError,
)

IDENTITY = {"match_id": "m-1", "player_id": "Player_1", "rules_version": "hash-1"}
ENVELOPE = {"op": "adjutant_command", "command_id": "c-1"}


class TestLoopbackTransport(unittest.TestCase):

    def test_roundtrip_and_sent_log(self):
        seen = []

        def handler(envelope):
            seen.append(envelope["command_id"])
            return {"ok": True, "accepted": True, "status": "Accepted"}

        transport = LoopbackTransport(handler)
        receipt = transport.send_command(ENVELOPE)
        self.assertTrue(receipt["accepted"])
        self.assertEqual(seen, ["c-1"])

    def test_closed_transport_rejects(self):
        transport = LoopbackTransport(lambda e: {})
        transport.close()
        with self.assertRaises(TransportError):
            transport.send_command(ENVELOPE)


class TestFakeTransport(unittest.TestCase):

    def test_disconnect_behavior(self):
        transport = FakeTransport(script=["disconnect"])
        with self.assertRaises(TransportError):
            transport.send_command(ENVELOPE)
        self.assertEqual(transport.state, ConnectionState.DISCONNECTED)

    def test_empty_response(self):
        transport = FakeTransport(script=["empty"])
        self.assertEqual(transport.send_command(ENVELOPE), {})

    def test_invalid_json_structure(self):
        transport = FakeTransport(script=["invalid_json"])
        receipt = transport.send_command(ENVELOPE)
        self.assertNotIn("accepted", receipt)  # 异常结构交上层按格式错误处理

    def test_unknown_state(self):
        transport = FakeTransport(script=["unknown_state"])
        receipt = transport.send_command(ENVELOPE)
        self.assertEqual(receipt["status"], "MysteryStatus")

    def test_heartbeat_failure_budget(self):
        transport = FakeTransport(heartbeat_failures=2)
        self.assertFalse(transport.heartbeat())
        self.assertFalse(transport.heartbeat())
        self.assertTrue(transport.heartbeat())


class TestResilientTransport(unittest.TestCase):

    def make_resilient(self, script=None, probe_identity=None, probe_raises=False):
        inner = FakeTransport(script=script)
        def probe():
            if probe_raises:
                raise TransportError("probe unreachable")
            return dict(probe_identity or IDENTITY)
        return ResilientTransport(inner, IDENTITY, reconnect_probe=probe), inner

    def test_disconnect_keeps_unsent_evidence_then_reconnects(self):
        resilient, _ = self.make_resilient(script=["disconnect"])
        with self.assertRaises(TransportError):
            resilient.send_command(ENVELOPE, server_tick=10)
        # 断线留证：原命令不丢（待诊断信息保留）。
        self.assertEqual(len(resilient.unsent_log), 1)
        self.assertEqual(resilient.unsent_log[0].envelope["command_id"], "c-1")
        # 重连成功（身份一致）。
        self.assertTrue(resilient.state == ConnectionState.CONNECTED)
        receipt = resilient.send_command({"op": "adjutant_command", "command_id": "c-2"})
        self.assertTrue(receipt["accepted"])

    def test_identity_drift_blocks_reconnect(self):
        drifted = {"match_id": "m-OTHER", "player_id": "Player_1",
                   "rules_version": "hash-1"}
        resilient, _ = self.make_resilient(script=["disconnect"], probe_identity=drifted)
        with self.assertRaises(TransportError):
            resilient.send_command(ENVELOPE)
        self.assertEqual(resilient.state, ConnectionState.DISCONNECTED)
        self.assertIsNotNone(resilient.identity_drift)
        self.assertEqual(resilient.identity_drift["match_id"]["observed"], "m-OTHER")

    def test_probe_failure_keeps_disconnected(self):
        resilient, _ = self.make_resilient(script=["disconnect"], probe_raises=True)
        with self.assertRaises(TransportError):
            resilient.send_command(ENVELOPE)
        self.assertEqual(resilient.state, ConnectionState.DISCONNECTED)

    def test_disconnected_send_keeps_evidence_without_raising_loop(self):
        # probe 不可用 → 重连失败保持断开：期间再发只留证，不发旧通道。
        resilient, _ = self.make_resilient(script=["disconnect"], probe_raises=True)
        with self.assertRaises(TransportError):
            resilient.send_command(ENVELOPE)
        with self.assertRaises(TransportError):
            resilient.send_command({"op": "adjutant_command", "command_id": "c-3"})
        self.assertEqual(len(resilient.unsent_log), 2)

    def test_heartbeat_failure_counting(self):
        resilient, inner = self.make_resilient()
        inner.set_connected(False)
        self.assertFalse(resilient.heartbeat())
        self.assertEqual(resilient.heartbeat_failure_count, 1)
        self.assertEqual(resilient.state, ConnectionState.DISCONNECTED)

    def test_close_is_idempotent(self):
        resilient, inner = self.make_resilient()
        resilient.close()
        resilient.close()
        self.assertEqual(inner.state, ConnectionState.CLOSED)
        with self.assertRaises(TransportError):
            resilient.send_command(ENVELOPE)


if __name__ == "__main__":
    unittest.main()
