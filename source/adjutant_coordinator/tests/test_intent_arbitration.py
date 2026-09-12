# -*- coding: utf-8 -*-
"""意图仲裁测试：四类丢弃条件、TTL 夹紧、批次上限、PendingAuthority 去重。"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph.arbitration import (
    arbitrate_intents, fingerprint_of, merge_same_orders,
)
from adjutant_coordinator.graph.state import INTENT_ACTIVE, AdjutantGraphState

from graph_test_helpers import (
    MATCH, PLAYER, SCENE_TANK, make_intent,
)

RULES_VERSION = "hash-graph-1"
UNITS = {"Unit_1", "Unit_2"}
SCENES = {SCENE_TANK}


def make_state(units=("Unit_1", "Unit_2")) -> AdjutantGraphState:
    state = AdjutantGraphState(match_id=MATCH, player_id=PLAYER)
    state.plan_version = "plan-a:v1"
    state.latest_snapshot_id = 10
    state.active_plan = {"plan_id": "plan-a", "plan_version": 1,
                         "valid_until_tick": 100000, "tasks": []}
    state.ensure_units(list(units))
    return state


def arbitrate(state, intents, tick=10, max_batch=8, ttl=600, expected="plan-a:v1",
              known=None, scenes=None, allowed=None):
    return arbitrate_intents(
        state, intents, current_tick=tick,
        known_entities=known if known is not None else UNITS,
        scene_paths=scenes if scenes is not None else SCENES,
        allowed_units=allowed if allowed is not None else UNITS,
        max_batch=max_batch, intent_ttl_ticks=ttl, expected_plan_version=expected)


class ArbitrationTest(unittest.TestCase):
    def test_accepts_and_fills_generation(self):
        state = make_state()
        result = arbitrate(state, [make_intent("i-1", expires_tick=100)])
        self.assertEqual([item["intent_id"] for item in result.accepted], ["i-1"])
        self.assertEqual(result.accepted[0]["generation"], state.generation_of("Unit_1"))
        self.assertEqual(result.dropped, [])
        self.assertEqual(result.clamped, [])

    def test_expired_window_and_plan_echo_are_normalized_unknown_unit_dropped(self):
        state = make_state()
        result = arbitrate(state, [
            make_intent("i-expired", expires_tick=5),
            make_intent("i-plan", plan_version="plan-b:v2", expires_tick=100,
                        target={"pos": [20.0, 20.0]}),
            make_intent("i-unknown", units=["Unit_9"], expires_tick=100),
        ], tick=10)
        accepted = {item["intent_id"]: item for item in result.accepted}
        self.assertEqual(sorted(accepted), ["i-expired", "i-plan"])
        self.assertEqual(result.dropped_reasons["i-unknown"], "unit_not_in_observation:Unit_9")
        # 本轮刚产出的意图：过期窗口按“当前 tick + 窗口”重算并留痕（不是静默丢弃）。
        self.assertEqual(accepted["i-expired"]["expires_tick"], 10 + 600)
        # 计划版本回声归一化到当前生效版本，同样留痕。
        self.assertEqual(accepted["i-plan"]["plan_version"], "plan-a:v1")
        fields = {(item["intent_id"], item["field"]) for item in result.clamped}
        self.assertIn(("i-expired", "expires_tick"), fields)
        self.assertIn(("i-plan", "plan_version"), fields)

    def test_drops_units_taken_over_by_player(self):
        state = make_state()
        state.mark_player_override(["Unit_1"], 10, "manual")
        result = arbitrate(state, [
            make_intent("i-1", units=["Unit_1"], expires_tick=100),
            make_intent("i-2", units=["Unit_2"], expires_tick=100),
        ])
        self.assertEqual([item["intent_id"] for item in result.accepted], ["i-2"])
        self.assertEqual(result.dropped_reasons["i-1"], "lease_owner_player:Unit_1")

    def test_drops_generation_mismatch(self):
        state = make_state()
        result = arbitrate(state, [make_intent("i-1", generation=999, expires_tick=100)])
        self.assertEqual(result.dropped_reasons["i-1"], "generation_mismatch")

    def test_clamps_future_snapshot_to_known_snapshot(self):
        state = make_state()
        future = make_intent("i-future", expires_tick=100)
        future["based_on_snapshot"] = 999
        result = arbitrate(state, [future])
        self.assertEqual([item["intent_id"] for item in result.accepted], ["i-future"])
        self.assertEqual(result.accepted[0]["based_on_snapshot"], 10)
        self.assertEqual(result.clamped[0]["field"], "based_on_snapshot")
        # 负数快照属于非法结构：契约层直接拒绝（比夹紧更早、更明确）。
        negative = make_intent("i-neg", units=["Unit_2"], expires_tick=100)
        negative["based_on_snapshot"] = -1
        result = arbitrate(state, [negative])
        self.assertEqual(result.accepted, [])
        self.assertEqual(result.dropped_reasons["i-neg"], "contract_invalid")

    def test_clamps_ttl(self):
        state = make_state()
        result = arbitrate(state, [make_intent("i-1", expires_tick=10 ** 6)], tick=10, ttl=600)
        self.assertEqual(result.accepted[0]["expires_tick"], 610)
        self.assertIn("i-1", [item["intent_id"] for item in result.clamped])

    def test_batch_limit_keeps_higher_priority(self):
        # 注意（2026-09-11）：这里必须用**不同目标**，否则两条意图会被
        # `merge_same_orders` 合并成一条（同动作+同目标 = 同一条命令，占 1 条配额、
        # 两个单位都有活干），就测不到"配额不够时按优先级保留"这条纪律了。
        state = make_state()
        result = arbitrate(state, [
            make_intent("i-low", units=["Unit_1"], priority=1, expires_tick=100,
                        target={"pos": [1.0, 1.0]}),
            make_intent("i-high", units=["Unit_2"], priority=9, expires_tick=100,
                        target={"pos": [2.0, 2.0]}),
        ], max_batch=1)
        self.assertEqual([item["intent_id"] for item in result.accepted], ["i-high"])
        self.assertEqual(result.dropped_reasons["i-low"], "batch_limit_exceeded")

    def test_duplicate_fingerprint_dropped(self):
        state = make_state()
        result = arbitrate(state, [
            make_intent("i-1", units=["Unit_1"], expires_tick=100),
            make_intent("i-2", units=["Unit_1"], expires_tick=100),
        ])
        self.assertEqual([item["intent_id"] for item in result.accepted], ["i-1"])
        self.assertEqual(result.dropped_reasons["i-2"], "duplicate_of:i-1")

    def test_already_tracked_intent_dropped(self):
        state = make_state()
        state.add_intent(make_intent("i-1", expires_tick=100), "active")
        result = arbitrate(state, [make_intent("i-1", expires_tick=100)])
        self.assertEqual(result.dropped_reasons["i-1"], "intent_already_tracked")

    def test_pending_authority_is_not_resubmitted(self):
        state = make_state()
        pending = make_intent("i-1", units=["Unit_1"], expires_tick=100)
        state.pending_requests["i-1"] = {
            "intent_id": "i-1", "command_id": "cmd-1", "state": "pending_authority",
            "since_tick": 10, "task_id": pending["task_id"], "action": pending["action"],
            "unit_ids": pending["unit_ids"]}
        # 同指纹的新意图（不同 intent_id）也必须被拒：不允许重复下单。
        new_intent = make_intent("i-2", units=["Unit_1"], expires_tick=100)
        self.assertEqual(fingerprint_of(pending), fingerprint_of(new_intent))
        result = arbitrate(state, [new_intent])
        self.assertEqual(result.accepted, [])
        self.assertEqual(result.dropped_reasons["i-2"], "pending_authority_unresolved")

    def test_malformed_intent_is_reported_not_raised(self):
        state = make_state()
        result = arbitrate(state, [{"intent_id": "i-bad", "action": "teleport"}])
        self.assertEqual(result.accepted, [])
        self.assertEqual(result.dropped[0]["reason"], "contract_invalid")
        self.assertTrue(result.dropped[0]["errors"])

    def test_scene_must_come_from_rules(self):
        state = make_state()
        intent = make_intent("i-produce", action="produce",
                             target={"scene": "res://evil/factory.tscn",
                                     "producer": "Unit_1"})
        result = arbitrate(state, [intent])
        self.assertEqual(
            result.dropped_reasons["i-produce"],
            "scene_not_in_rules:res://evil/factory.tscn")

    def test_attack_target_must_be_visible(self):
        state = make_state()
        intent = make_intent("i-attack", action="attack",
                             target={"entity_id": "Unit_enemy_9"})
        result = arbitrate(state, [intent])
        self.assertEqual(result.dropped_reasons["i-attack"],
                         "entity_not_in_observation:Unit_enemy_9")
        visible = arbitrate(state, [make_intent("i-attack-2", action="attack",
                                               target={"entity_id": "Unit_enemy_1"})],
                            known=UNITS | {"Unit_enemy_1"})
        self.assertEqual([item["intent_id"] for item in visible.accepted], ["i-attack-2"])

    def test_emergency_sorts_first(self):
        state = make_state()
        result = arbitrate(state, [
            make_intent("i-normal", units=["Unit_1"], priority=9, expires_tick=100),
            make_intent("i-emergency", units=["Unit_2"], priority=0,
                        expires_tick=100, emergency=True),
        ])
        self.assertEqual([item["intent_id"] for item in result.accepted],
                         ["i-emergency", "i-normal"])

    def test_reacquire_requires_explicit_player_release(self):
        state = make_state()
        state.mark_player_override(["Unit_1"], 10, "manual")
        unauthorized = make_intent("i-reacquire", units=["Unit_1"], expires_tick=100)
        unauthorized["reacquire"] = True
        result = arbitrate(state, [unauthorized])
        self.assertEqual(result.accepted, [])
        # 玩家仍在控制该单位：最强理由是“玩家优先权”，reacquire 一律不放行。
        self.assertEqual(result.dropped_reasons["i-reacquire"], "lease_owner_player:Unit_1")

        # 未被玩家接管、也从未显式归还的单位：reacquire 无授权来源，明确拒绝。
        never_released = make_intent("i-reacquire-x", units=["Unit_2"], expires_tick=100)
        never_released["reacquire"] = True
        result = arbitrate(state, [never_released])
        self.assertEqual(result.dropped_reasons["i-reacquire-x"],
                         "reacquire_not_authorized:Unit_2")

        # 玩家显式归还后，同一条重新接管意图才被放行。
        state.release_units(["Unit_1"], 12, "player_release")
        authorized = make_intent("i-reacquire-2", units=["Unit_1"], expires_tick=100)
        authorized["reacquire"] = True
        result = arbitrate(state, [authorized])
        self.assertEqual([item["intent_id"] for item in result.accepted], ["i-reacquire-2"])

    def test_live_intent_with_same_target_is_not_reordered(self):
        state = make_state()
        first = make_intent("i-1", units=["Unit_1"], expires_tick=100)
        state.add_intent(first, "active")
        again = make_intent("i-2", units=["Unit_1"], expires_tick=100)
        result = arbitrate(state, [again])
        self.assertEqual(result.dropped_reasons["i-2"], "duplicate_of_live_intent:i-1")

    def test_expired_live_intent_does_not_block_new_order(self):
        """过期（TTL 已过）的在途意图不得再压制同目标的新意图。

        2026-09-12 实机回归：`active_unknown`（已送达但权威端未确认）的记录若
        `expires_tick` 早已过去，仍被当成"仍在途"，于是行为树每轮产出的同目标命令
        全被判 `duplicate_of_live_intent` 丢弃 —— 整局副官 0 命令（画面上表现为
        "看不到 AI 副官指挥部队的信标"），副官面板却显示"一切正常"；
        且这些记录随 graph_checkpoint.json 持久化，重启 runner 也无法自愈。
        """
        state = make_state()
        stale = make_intent("i-stale", units=["Unit_1"], expires_tick=20)
        state.add_intent(stale, "active_unknown")
        fresh = make_intent("i-fresh", units=["Unit_1"], expires_tick=100)
        # 当前 tick 已超过 i-stale 的 expires_tick（20）：它不再算在途。
        result = arbitrate(state, [fresh], tick=50)
        self.assertNotIn("i-fresh", result.dropped_reasons)
        self.assertEqual([item["intent_id"] for item in result.accepted], ["i-fresh"])

    def test_unexpired_live_intent_still_blocks_duplicate(self):
        """反向保护：还在 TTL 内的在途意图必须继续抑制重复下单（防抖）。"""
        state = make_state()
        live = make_intent("i-live", units=["Unit_1"], expires_tick=100)
        state.add_intent(live, "active_unknown")
        again = make_intent("i-again", units=["Unit_1"], expires_tick=100)
        result = arbitrate(state, [again], tick=50)
        self.assertEqual(result.dropped_reasons["i-again"], "duplicate_of_live_intent:i-live")

    def test_decision_log_records_arbitration(self):
        state = make_state()
        arbitrate(state, [make_intent("i-1", expires_tick=100)])
        kinds = [item["kind"] for item in state.decision_log]
        self.assertIn("intents_arbitrated", kinds)


class MergeSameOrdersTest(unittest.TestCase):
    """意图合并（2026-09-11）：同动作 + 同目标 → 一条多单位意图。

    实测背景：行为树是"每个单位一条意图"，给 12 个兵下令要占 12 条配额，
    而 `max_batch` 只有 8（AI 对局 5 分钟被 `batch_limit_exceeded` 截断 178 次）。
    合并后"12 个兵"只占 1 条配额 —— 这是提高"控制频率 / 可下令单位数"性价比最高的一步。
    """

    def test_merge_keeps_first_id_and_unions_units(self):
        merged, traces = merge_same_orders([
            make_intent("i-a", "move", units=["Unit_2"], target={"pos": [5.0, 5.0]}),
            make_intent("i-b", "move", units=["Unit_1"], target={"pos": [5.0, 5.0]}),
        ])
        self.assertEqual(len(merged), 1)
        # id 保留组内第一条（单单位场景 id 不变 → 不破坏金标准回放）。
        self.assertEqual(merged[0]["intent_id"], "i-a")
        self.assertEqual(merged[0]["unit_ids"], ["Unit_1", "Unit_2"])
        self.assertEqual(len(traces), 1)
        self.assertEqual(traces[0]["absorbed"], "i-b")

    def test_scene_actions_are_never_merged(self):
        """build/produce 不许合并：否则"排两个"会被压成"排一个"（改玩法语义）。"""
        merged, _ = merge_same_orders([
            make_intent("p-1", "produce", units=["Unit_1"],
                        target={"scene": SCENE_TANK, "producer": "Unit_1"}),
            make_intent("p-2", "produce", units=["Unit_1"],
                        target={"scene": SCENE_TANK, "producer": "Unit_1"}),
        ])
        self.assertEqual(len(merged), 2)

    def test_merges_across_generations_and_keeps_max(self):
        """代际**不参与匹配**，合并后取组内最大值。

        为什么不能"要求代际相同"：协调器是"每单位一个代际"、`ensure_units` 逐单位自增
        （Unit_1→1、Unit_2→2…），真实对局里几乎必然不等 → 要求相同等于**永不合并**
        （第一版就是这么写的，实测整局 0 次）。
        为什么要取 max、不能取 0：权威层 `_adjutant_generation_guard` 只有在
        `generation > 0` 时才检查"租约是否已被玩家取消"，取 0 会把这道玩家优先权守卫整个跳过。
        """
        merged, traces = merge_same_orders([
            make_intent("i-a", "move", units=["Unit_1"], generation=1),
            make_intent("i-b", "move", units=["Unit_2"], generation=2),
        ])
        self.assertEqual(len(merged), 1)
        self.assertEqual(merged[0]["unit_ids"], ["Unit_1", "Unit_2"])
        self.assertEqual(merged[0]["generation"], 2)
        self.assertEqual(merged[0]["merged_from"], ["i-a", "i-b"])
        self.assertEqual(traces[0]["generation"], 2)

    def test_different_target_is_not_merged(self):
        merged, _ = merge_same_orders([
            make_intent("i-a", "move", units=["Unit_1"], target={"pos": [1.0, 1.0]}),
            make_intent("i-b", "move", units=["Unit_2"], target={"pos": [2.0, 2.0]}),
        ])
        self.assertEqual(len(merged), 2)

    def test_arbitration_merges_and_frees_batch_quota(self):
        """最关键的一条：配额只占 1 条，两个单位都能拿到命令（不再被 max_batch 截掉）。"""
        state = make_state()
        result = arbitrate(state, [
            make_intent("i-a", "move", units=["Unit_1"]),
            make_intent("i-b", "move", units=["Unit_2"]),
        ], max_batch=1)
        self.assertEqual(len(result.accepted), 1)
        self.assertEqual(result.accepted[0]["unit_ids"], ["Unit_1", "Unit_2"])
        self.assertEqual([d for d in result.dropped if d["reason"] == "batch_limit_exceeded"], [])

    def test_merged_expires_tick_takes_minimum(self):
        """合并只能收窄意图寿命，绝不用合并延长（TTL 纪律）。"""
        state = make_state()
        result = arbitrate(state, [
            make_intent("i-a", "move", units=["Unit_1"], expires_tick=500),
            make_intent("i-b", "move", units=["Unit_2"], expires_tick=300),
        ])
        self.assertEqual(result.accepted[0]["expires_tick"], 300)

    def test_merged_order_suppresses_per_unit_resend(self):
        """合并意图覆盖的单位，下一轮"每单位一条"的同动作同目标意图必须被判重复。

        为什么必须钉：`merge_same_orders` 把多单位合成**一条**（细指纹里的 unit_ids 变成整组），
        而行为树下一轮仍按"每单位一条"产出 —— 若只比整条指纹，两者**永远对不上**，
        同一命令会被**每轮重发**：单位不停重下移动/采集、原地抖（合并引入的回归风险）。
        单位级判重（`live_unit_orders`）就是为此存在的。
        """
        state = make_state()
        first = arbitrate(state, [
            make_intent("i-a", "move", units=["Unit_1"]),
            make_intent("i-b", "move", units=["Unit_2"]),
        ])
        self.assertEqual(len(first.accepted), 1, "同目标的两条 move 应先合并成一条")
        record = dict(first.accepted[0])
        record["state"] = INTENT_ACTIVE
        state.active_intents.append(record)
        again = arbitrate(state, [
            make_intent("i-c", "move", units=["Unit_1"]),
            make_intent("i-d", "move", units=["Unit_2"]),
        ])
        self.assertEqual(again.accepted, [])
        self.assertTrue(all("duplicate_of_live_intent" in d["reason"] for d in again.dropped),
                        str(again.dropped))


if __name__ == "__main__":
    unittest.main()
