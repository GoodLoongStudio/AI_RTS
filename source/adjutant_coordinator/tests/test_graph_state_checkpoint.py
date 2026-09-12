# -*- coding: utf-8 -*-
"""图状态与 checkpoint 测试：序列化、隔离、陈旧写保护、损坏文件不静默重建。"""

import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph.checkpoint import (
    CHECKPOINT_VERSION, JsonCheckpointStore, MemoryCheckpointStore, NullCheckpointStore,
)
from adjutant_coordinator.graph.state import AdjutantGraphState

from graph_test_helpers import MATCH, PLAYER, RULES, make_intent, make_plan


def make_state() -> AdjutantGraphState:
    state = AdjutantGraphState(match_id=MATCH, player_id=PLAYER)
    state.rules_version = RULES
    state.server_tick = 42
    state.latest_snapshot_id = 7
    state.active_plan = make_plan()
    state.plan_version = "plan-a:v1"
    state.register_task("t-1", "running")
    state.ensure_units(["Unit_1", "Unit_2"])
    state.add_intent(make_intent("i-1", generation=state.generation_of("Unit_1")), "active")
    state.decide("test_marker", note="状态序列化")
    return state


class StateSerializationTest(unittest.TestCase):
    def test_roundtrip_preserves_control_semantics(self):
        state = make_state()
        payload = state.to_checkpoint()
        self.assertEqual(payload["checkpoint_version"], CHECKPOINT_VERSION)
        restored = AdjutantGraphState.from_checkpoint(payload)
        self.assertEqual(restored.plan_version, state.plan_version)
        self.assertEqual(restored.active_tasks, state.active_tasks)
        self.assertEqual(restored.unit_generations, state.unit_generations)
        self.assertEqual(restored.control_generation, state.control_generation)
        self.assertEqual([item["intent_id"] for item in restored.active_intents], ["i-1"])
        self.assertEqual(restored.decision_log[-1]["kind"], "test_marker")
        self.assertEqual(restored.summary()["route"], state.route)

    def test_checkpoint_version_mismatch_is_rejected(self):
        payload = make_state().to_checkpoint()
        payload["checkpoint_version"] = CHECKPOINT_VERSION + 99
        with self.assertRaises(ValueError):
            AdjutantGraphState.from_checkpoint(payload)

    def test_player_override_and_release_generations(self):
        state = make_state()
        gen_before = state.generation_of("Unit_1")
        record = state.mark_player_override(["Unit_1"], 50, "manual move")
        self.assertGreater(state.generation_of("Unit_1"), gen_before)
        self.assertEqual(record["generation"], state.control_generation)
        self.assertEqual(record["dropped_intents"], ["i-1"])
        self.assertTrue(state.is_unit_player_controlled("Unit_1"))
        self.assertIn("Unit_1", state.player_controlled_units)
        live, reason = state.is_intent_valid(
            {"unit_ids": ["Unit_1"], "generation": gen_before, "expires_tick": 1000}, 50)
        self.assertFalse(live)
        self.assertEqual(reason, "lease_owner_player")

        release = state.release_units(["Unit_1"], 60, "explicit release")
        self.assertFalse(state.is_unit_player_controlled("Unit_1"))
        self.assertIn("Unit_1", state.released_units)
        self.assertGreaterEqual(release["generation"], record["generation"])

    def test_intent_validity_drop_conditions(self):
        state = make_state()
        state.plan_version = "plan-a:v1"
        base = {"unit_ids": ["Unit_2"], "generation": state.generation_of("Unit_2"),
                "plan_version": "plan-a:v1", "expires_tick": 1000}
        ok, reason = state.is_intent_valid(base, 100)
        self.assertTrue(ok, reason)
        self.assertFalse(state.is_intent_valid({**base, "expires_tick": 10}, 100)[0])
        self.assertEqual(state.is_intent_valid({**base, "expires_tick": 10}, 100)[1], "expired")
        self.assertEqual(
            state.is_intent_valid({**base, "plan_version": "plan-b:v2"}, 100)[1],
            "plan_version_mismatch")
        self.assertEqual(
            state.is_intent_valid({**base, "generation": 999}, 100)[1],
            "generation_mismatch")

    def test_event_queue_is_bounded_and_deduplicated(self):
        state = make_state()
        self.assertTrue(state.push_event({"event_id": "e-1", "kind": "enemy_spotted"}))
        self.assertFalse(state.push_event({"event_id": "e-1", "kind": "enemy_spotted"}))
        for index in range(300):
            state.push_event({"event_id": "e-%d" % index, "kind": "queue_idle"})
        self.assertLessEqual(len(state.pending_events), 256)


class MemoryCheckpointStoreTest(unittest.TestCase):
    def test_save_load_and_stale_refusal(self):
        store = MemoryCheckpointStore()
        state = make_state()
        self.assertFalse(store.exists())
        first = store.save(state)
        self.assertTrue(first["saved"])
        self.assertTrue(store.exists())
        loaded = store.load()
        self.assertEqual(loaded.server_tick, state.server_tick)

        older = make_state()
        older.server_tick = 10
        result = store.save(older)
        self.assertFalse(result["saved"])
        self.assertEqual(result["reason"], "stale_checkpoint_refused")
        self.assertEqual(store.load().server_tick, state.server_tick)

    def test_null_store_is_explicit(self):
        store = NullCheckpointStore()
        result = store.save(make_state())
        self.assertFalse(result["saved"])
        self.assertEqual(result["reason"], "checkpoint_disabled")
        self.assertIsNone(store.load())


class JsonCheckpointStoreTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="adjutant-graph-")
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)

    def test_roundtrip_and_isolation(self):
        store = JsonCheckpointStore(self.root, MATCH, PLAYER)
        state = make_state()
        result = store.save(state)
        self.assertTrue(result["saved"], result)
        self.assertTrue(os.path.exists(store.path))
        loaded = store.load()
        self.assertEqual(loaded.plan_version, "plan-a:v1")
        # 目录按 (match, player) 隔离：其他玩家读不到这份 checkpoint。
        other = JsonCheckpointStore(self.root, MATCH, "Player_2")
        self.assertIsNone(other.load())

    def test_stale_write_refused(self):
        store = JsonCheckpointStore(self.root, MATCH, PLAYER)
        store.save(make_state())
        older = make_state()
        older.server_tick = 1
        result = store.save(older)
        self.assertFalse(result["saved"])
        self.assertEqual(result["reason"], "stale_checkpoint_refused")
        self.assertEqual(store.load().server_tick, 42)

    def test_corrupt_file_returns_none_without_rebuilding(self):
        store = JsonCheckpointStore(self.root, MATCH, PLAYER)
        store.save(make_state())
        with open(store.path, "w", encoding="utf-8") as handle:
            handle.write("{ not json")
        self.assertIsNone(store.load())
        self.assertFalse(store.exists())
        # 现场保留：不静默重建覆盖证据。
        with open(store.path, "r", encoding="utf-8") as handle:
            self.assertEqual(handle.read(), "{ not json")

    def test_checkpoint_payload_is_json_serializable(self):
        store = JsonCheckpointStore(self.root, MATCH, PLAYER)
        store.save(make_state())
        with open(store.path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
        self.assertEqual(payload["state"]["match_id"], MATCH)


if __name__ == "__main__":
    unittest.main()
