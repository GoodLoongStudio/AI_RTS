# -*- coding: utf-8 -*-
"""结构化日志测试：标准字段齐全、身份更新、JSONL UTF-8 落盘、sink 注入。"""

import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.structured_log import (
    JsonlFileSink, MemorySink, NullLogger, StructuredLogger,
)

BASE = {"match_id": "m-1", "player_id": "Player_1", "rules_version": "hash-1",
        "snapshot_id": 7}


class TestStructuredLogger(unittest.TestCase):

    def test_every_entry_carries_standard_fields(self):
        sink = MemorySink()
        logger = StructuredLogger(sink, base=BASE)
        entry = logger.log("command_receipt", status="Accepted", server_tick=42,
                           command_id="c-1", task_id="t-1", request_id="r-1",
                           plan_version="plan-a:v1")
        for field in ("event", "status", "reason", "server_tick", "match_id",
                      "player_id", "request_id", "plan_version", "task_id",
                      "command_id", "rules_version", "snapshot_id"):
            self.assertIn(field, entry)
        self.assertEqual(entry["command_id"], "c-1")
        self.assertEqual(entry["match_id"], "m-1")
        self.assertEqual(entry["server_tick"], 42)

    def test_missing_fields_default_not_missing(self):
        sink = MemorySink()
        logger = StructuredLogger(sink, base=BASE)
        entry = logger.log("strategy_request", server_tick=1)
        self.assertEqual(entry["command_id"], "")
        self.assertEqual(entry["task_id"], "")
        self.assertEqual(entry["request_id"], "")

    def test_update_identity_after_reconnect(self):
        sink = MemorySink()
        logger = StructuredLogger(sink, base=dict(BASE))
        logger.update_identity(rules_version="hash-2", snapshot_id=9)
        entry = logger.log("reconnected", server_tick=2)
        self.assertEqual(entry["rules_version"], "hash-2")
        self.assertEqual(entry["snapshot_id"], 9)
        self.assertEqual(entry["match_id"], "m-1")

    def test_extra_fields_do_not_override_standard(self):
        sink = MemorySink()
        logger = StructuredLogger(sink, base=BASE)
        entry = logger.log("plan_adoption", status="adopted", server_tick=3,
                           match_id="hijack")
        self.assertEqual(entry["match_id"], "m-1")


class TestSinks(unittest.TestCase):

    def test_jsonl_file_sink_utf8_roundtrip(self):
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "host", "events.jsonl")
            sink = JsonlFileSink(path)
            sink.log if False else None
            logger = StructuredLogger(sink, base=BASE)
            logger.log("command_receipt", status="PlayerOverride", server_tick=5,
                       command_id="命令-1", reason="玩家接管")
            with open(path, "r", encoding="utf-8") as handle:
                lines = [json.loads(line) for line in handle.read().splitlines()]
            self.assertEqual(len(lines), 1)
            self.assertEqual(lines[0]["command_id"], "命令-1")
            self.assertEqual(lines[0]["reason"], "玩家接管")

    def test_null_logger_returns_entry_without_sink(self):
        logger = NullLogger()
        entry = logger.log("tactics_request", status="issued", server_tick=9)
        self.assertEqual(entry["event"], "tactics_request")

    def test_memory_sink_find_filters_by_event(self):
        sink = MemorySink()
        logger = StructuredLogger(sink, base=BASE)
        logger.log("strategy_request", server_tick=1)
        logger.log("tactics_request", server_tick=2)
        self.assertEqual(len(sink.find("tactics_request")), 1)
        self.assertEqual(len(sink.find("strategy_request")), 1)


if __name__ == "__main__":
    unittest.main()
