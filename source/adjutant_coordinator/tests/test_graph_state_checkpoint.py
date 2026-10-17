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

    def test_roundtrip_preserves_learned_ledgers(self):
        """**新增的状态字段必须同时进 `to_dict`/`from_dict`**（2026-10-09 实测的静默丢失）。

        为什么单独立这一条：`to_dict` 是**逐字段挑着写**的，不是枚举 dataclass。
        加了 dataclass 字段却忘了补序列化 ⇒ 每轮归零，**而且声明类守门测试查不出来**
        （`test_graph_state_channels` 只扫"有没有声明"，不扫"序列化有没有带上"）。

        实测：`depleted_resources` / `advance_cursor` 就是这么漏的 ——
        它们分别支撑"换矿"与"轮转服务顺序"，一归零就等于那两个修复**从未生效**。
        是一条 `round-trip` 探针把它揪出来的，所以这里把它固化成测试。
        """
        state = make_state()
        state.depleted_resources = {"Unit_2|Res_A": 1234}
        state.advance_cursor = 7
        restored = AdjutantGraphState.from_checkpoint(state.to_checkpoint())
        self.assertEqual(restored.depleted_resources, {"Unit_2|Res_A": 1234},
                         "矿点拉黑账丢了 ⇒ 换矿记忆形同虚设（每轮往刚被拒的矿上撞）")
        self.assertEqual(restored.advance_cursor, 7,
                         "轮转游标丢了 ⇒ 每轮从 0 开始 = 没有轮转")

    def test_roundtrip_preserves_movement_round_delta(self):
        """每轮增量账与它的基线快照都必须跨轮活下来（2026-10-09，round-24 的教训）。

        第一版把基线放在 `agent_runner` 的**进程内字典**、按 `id(state)` 索引 ——
        结果**一条增量都没落盘**：`TickResult.state` 是 `summary()` 生成的**新字典**，
        而且 runner 每轮还会从检查点重建状态对象，`id()` 每次都不同。
        **这与 `to_dict` 漏字段是同一个病根**：把要跨轮活下来的东西放在不跨轮的地方。
        """
        state = make_state()
        state.movement_round_delta = {"planned": 8, "invalidations": 3}
        state.movement_stats_snapshot = {"tick": 200, "counts": {"planned": 18}}
        restored = AdjutantGraphState.from_checkpoint(state.to_checkpoint())
        self.assertEqual(restored.movement_round_delta, {"planned": 8, "invalidations": 3})
        self.assertEqual(restored.movement_stats_snapshot.get("tick"), 200,
                         "基线快照丢了 ⇒ 下一轮算不出增量")
        self.assertIn("movement_round_delta", state.summary(),
                      "**必须进 summary**：runner 从 summary 读，不进就等于没落盘"
                      "（`continuity_supervision` 踩过同一个坑）")

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

    def test_continuity_ledger_survives_the_checkpoint(self):
        """连续行动台账必须跨轮/跨 checkpoint 活下来（2026-10-07）。

        它是"停了多久"的唯一依据：丢了它每轮从零开始，停滞永远到不了 2s/5s/10s 阈值
        —— 正是本项目"功能写了、单测也过、真机每轮归零"那一类病。
        """
        store = JsonCheckpointStore(self.root, MATCH, PLAYER)
        state = make_state()
        state.continuity_units = {"Unit_4": {"last_moved_tick": 120, "stall_count": 4,
                                            "level": "recover", "waiting_reason": ""}}
        state.continuity_supervision = {"updated_tick": 300, "recoveries": 1,
                                        "levels": {"recover": 1}}
        self.assertTrue(store.save(state)["saved"])
        loaded = store.load()
        self.assertEqual(loaded.continuity_units["Unit_4"]["last_moved_tick"], 120)
        self.assertEqual(loaded.continuity_supervision["recoveries"], 1)
        # 也要能进 JSON（检查点落盘是 JSON，不是 pickle）。
        with open(store.path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
        self.assertEqual(payload["state"]["continuity_units"]["Unit_4"]["stall_count"], 4)


if __name__ == "__main__":
    unittest.main()
