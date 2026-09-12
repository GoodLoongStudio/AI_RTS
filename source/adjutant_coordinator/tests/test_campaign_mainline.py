# -*- coding: utf-8 -*-
"""整局主线（campaign_state）与决策地图接入的**类级**守门测试。

对应纠偏文档 `docs/程序文档/AI副官_长期主线与决策地图接入纠偏_2026-09-12.md`
的 8 条要求；每条测试都钉住"同类问题不再出现"的不变式，而不是某一次的具体现场：

1. 开局自动建立默认主线（摸底→立足→扩张→施压→收束）；
2. 里程碑完成**只认权威证据**（观测 + 回执），不认"生成了 plan/task"；
3. 规则中台在模型关闭时也沿主线推进（建造顺序 / 出击门槛由前沿决定）；
4. 紧急事件只压 `interrupt_stack`，处理完恢复原主线与四条 track；
5. 玩家局部接管只暂停受影响对象，不清空主线；
6. 模型超时/空输出/非法分支 → 主线、里程碑、已有任务继续执行；
7. 模型上下文含阶段/主线/四线/前沿/决策地图候选及其前置条件；
8. campaign_state 跨 tick 与 checkpoint 保留。
"""

from __future__ import annotations

import io
import os
import re
import unittest

from adjutant_coordinator.graph import campaign as cm
from adjutant_coordinator.graph import decision_map, rules_fallback as rf
from adjutant_coordinator.graph.state import AdjutantGraphState

MATCH = "m-campaign"
PLAYER = "Player_1"
RULES = "hash-campaign"

RULES_VIEW = {
    "match_id": MATCH,
    "rules_version": {"content_hash": RULES, "version": 1},
    "unit_types": [
        {"id": "worker", "scene_path": "res://units/Worker.tscn"},
        {"id": "soldier", "scene_path": "res://units/Soldier.tscn"},
        {"id": "tank", "scene_path": "res://units/Tank.tscn"},
        {"id": "barracks", "scene_path": "res://buildings/Barracks.tscn"},
        {"id": "vehicle_factory", "scene_path": "res://buildings/VehicleFactory.tscn"},
        {"id": "command_center", "scene_path": "res://buildings/CommandCenter.tscn"},
        {"id": "anti_ground_turret",
         "scene_path": "res://buildings/AntiGroundTurret.tscn"},
    ],
    "constructions": [
        {"id": "barracks", "blueprint_scene_path": "res://buildings/Barracks.tscn"},
        {"id": "vehicle_factory",
         "blueprint_scene_path": "res://buildings/VehicleFactory.tscn"},
        {"id": "command_center",
         "blueprint_scene_path": "res://buildings/CommandCenter.tscn"},
        {"id": "anti_ground_turret",
         "blueprint_scene_path": "res://buildings/AntiGroundTurret.tscn"},
    ],
    "productions": [
        {"product_type_id": "worker", "allowed_producer_type_ids": ["command_center"]},
        {"product_type_id": "soldier", "allowed_producer_type_ids": ["barracks"]},
        {"product_type_id": "tank", "allowed_producer_type_ids": ["vehicle_factory"]},
    ],
}


def unit(name, utype, *, pos=(0.0, 0.0, 0.0), gather=False, construct=False,
         queue=False, constructed=None, movement=True):
    entity = {"kind": "unit_self", "name": name, "unit_type": utype,
              "pos": list(pos), "hp": 100.0, "hp_max": 100.0,
              "movement": movement, "gather": gather, "construct": construct,
              "queue": queue}
    if constructed is not None:
        entity["constructed"] = constructed
    return entity


def resource(name, pos):
    return {"kind": "resource", "name": name, "pos": list(pos)}


def enemy(name, pos=(40.0, 0.0, 40.0)):
    return {"kind": "unit_enemy", "name": name, "unit_type": "tank",
            "pos": list(pos), "hp": 100.0, "hp_max": 100.0,
            "last_seen_tick": 0, "confirmed_dead": False}


def tactical(entities, *, tick=0, balance=None, outcome=None):
    return {"schema_version": 1, "match_id": MATCH, "player_id": PLAYER,
            "rules_version": RULES, "snapshot_id": tick, "server_tick": tick,
            "entities": list(entities), "balance": dict(balance or {"A": 50000}),
            "production": [], "truncated": False, "next_offset": -1,
            "outcome": dict(outcome or {"finished": False})}


def observation(entities, *, tick=0, events=None, balance=None, outcome=None):
    return {"header": {"match_id": MATCH, "player_id": PLAYER,
                       "rules_version": RULES, "snapshot_id": tick, "server_tick": tick},
            "tactical": tactical(entities, tick=tick, balance=balance, outcome=outcome),
            "strategic": {"map_bounds": [200.0, 200.0], "enemy_intel": []},
            "events": list(events or []),
            "rules": RULES_VIEW}


def base_state(tick=0, **overrides):
    state = {
        "match_id": MATCH, "player_id": PLAYER, "rules_version": RULES,
        "server_tick": tick, "latest_snapshot_id": tick,
        "active_intents": [], "active_tasks": {}, "command_receipts": [],
        "ai_controlled_units": [], "player_controlled_units": [], "released_units": [],
        "unit_generations": {}, "control_generation": 0,
        "pending_events": [], "pending_requests": {}, "degraded_reason": "",
        "map_bounds": [200.0, 200.0], "decision_log": [],
    }
    state.update(overrides)
    return state


# ---------------------------------------------------------------------------
# 1. 开局默认主线
# ---------------------------------------------------------------------------


class DefaultMainlineTest(unittest.TestCase):
    def test_first_update_builds_default_mainline(self):
        state = base_state()
        campaign = cm.update(state, observation([]), 0)
        self.assertEqual(campaign["mainline_id"], cm.MAINLINE_ID)
        self.assertEqual(set(campaign["milestones"]), set(cm.MILESTONE_ORDER))
        self.assertEqual(campaign["phase"], cm.PHASE_RECON)
        self.assertEqual(campaign["next_frontier"], cm.M01)
        # 四条线开局即并行存在（不是串行剧本）。
        self.assertEqual(set(campaign["tracks"]),
                         {cm.TRACK_ECONOMY, cm.TRACK_BUILD,
                          cm.TRACK_SCOUT, cm.TRACK_MILITARY})
        # 每个里程碑都带前置条件 / 成功证据 / 退出与失败 / 重试 / 优先级。
        for key, spec in cm.MILESTONES.items():
            self.assertIn("preconditions", spec, key)
            self.assertTrue(spec.get("success_evidence"), key)
            self.assertTrue(spec.get("exit"), key)
            self.assertTrue(spec.get("failure"), key)
            self.assertIn("max_attempts", spec.get("retry") or {}, key)
            self.assertIn("priority", spec, key)

    def test_phase_progression_follows_phase_table(self):
        order = [str(cm.MILESTONES[key]["phase"]) for key in cm.MILESTONE_ORDER]
        self.assertEqual(order, [cm.PHASE_RECON, cm.PHASE_FOOTHOLD, cm.PHASE_FOOTHOLD,
                                 cm.PHASE_EXPAND, cm.PHASE_EXPAND, cm.PHASE_PRESSURE,
                                 cm.PHASE_CONVERGE])


# ---------------------------------------------------------------------------
# 2. 里程碑完成只认权威证据
# ---------------------------------------------------------------------------


class MilestoneEvidenceTest(unittest.TestCase):
    def test_workers_gathering_requires_authoritative_receipt(self):
        state = base_state()
        entities = [unit("Unit_1", "worker", gather=True),
                    resource("R_1", (8.0, 0.0, 8.0))]
        # 只有观测、没有回执 → 不能判定完成（"派了活"不等于"权威接受了"）。
        cm.update(state, observation(entities), 0)
        self.assertNotEqual(state["campaign_state"]["milestones"][cm.M01]["status"],
                            "done")
        # 出现权威 Accepted 回执 → 完成，并记下证据。
        state["command_receipts"] = [{
            "status": "Accepted", "accepted": True, "action": "gather",
            "intent_id": "rule-gather-Unit_1-100"}]
        cm.update(state, observation(entities), 60)
        entry = state["campaign_state"]["milestones"][cm.M01]
        self.assertEqual(entry["status"], "done")
        self.assertTrue(entry["done_tick"])
        self.assertTrue(entry["last_evidence"])

    def test_generated_plan_or_task_does_not_complete_milestone(self):
        state = base_state()
        state["active_plan"] = {"plan_id": "p1", "tasks": [{"task_id": "t1"}]}
        state["active_tasks"] = {"t1": "running"}
        entities = [unit("Unit_1", "worker", gather=True),
                    resource("R_1", (8.0, 0.0, 8.0))]
        cm.update(state, observation(entities), 0)
        campaign = state["campaign_state"]
        self.assertEqual(campaign["milestones"][cm.M01]["status"], "pending")
        self.assertNotIn(cm.M01, campaign["milestones"][cm.M01].get("done_tick") and
                         [cm.M01] or [])

    def test_production_building_milestone_needs_observed_entity(self):
        state = base_state()
        # 工地已出现但未完工 → 不算完成。
        entities = [unit("Unit_0", "command_center", queue=True),
                    unit("Unit_1", "worker", gather=True, construct=True),
                    unit("Unit_9", "barracks", queue=True, constructed=False),
                    resource("R_1", (8.0, 0.0, 8.0))]
        cm.update(state, observation(entities), 0)
        self.assertNotEqual(
            state["campaign_state"]["milestones"][cm.M02]["status"], "done")
        # 完工 → 完成。
        entities[2] = unit("Unit_9", "barracks", queue=True, constructed=True)
        cm.update(state, observation(entities), 300)
        self.assertEqual(state["campaign_state"]["milestones"][cm.M02]["status"], "done")

    def test_second_base_milestone_needs_two_finished_command_centers(self):
        state = base_state()
        entities = [unit("Unit_0", "command_center", queue=True, constructed=True),
                    unit("Unit_1", "command_center", queue=True, constructed=False)]
        cm.update(state, observation(entities), 0)
        campaign = state["campaign_state"]
        # 直接满足 M04 的前置（M02）后，M05 仍不能因"在建"而完成。
        campaign["milestones"][cm.M02]["status"] = "done"
        campaign["milestones"][cm.M02]["done_tick"] = 1
        cm.update(state, observation(entities), 60)
        self.assertNotEqual(campaign["milestones"][cm.M05]["status"], "done")
        entities[1] = unit("Unit_1", "command_center", queue=True, constructed=True)
        cm.update(state, observation(entities), 120)
        self.assertEqual(campaign["milestones"][cm.M05]["status"], "done")
        self.assertIn("分基地已建成", campaign["milestones"][cm.M05]["last_evidence"])


# ---------------------------------------------------------------------------
# 3. 规则中台沿主线推进（模型关闭时也在发展）
# ---------------------------------------------------------------------------


class RuleFloorFollowsMainlineTest(unittest.TestCase):
    def _state_with_frontier(self, milestone, tick=600):
        state = base_state(tick=tick)
        campaign = cm.ensure_campaign(state, tick)
        # 把目标节点之前的里程碑全部标成已完成（真实推进也是这个顺序），
        # 这样 `update()` 重算前沿时不会退回更早的节点。
        for key in cm.MILESTONE_ORDER:
            if key == milestone:
                break
            campaign["milestones"][key]["status"] = "done"
            campaign["milestones"][key]["done_tick"] = 1
        campaign["milestones"][milestone]["status"] = "pending"
        campaign["milestones"][milestone]["frontier_since"] = tick
        campaign["next_frontier"] = milestone
        campaign["phase"] = str(cm.MILESTONES[milestone]["phase"])
        return state, campaign

    def test_capacity_milestone_orders_barracks_first(self):
        state, _ = self._state_with_frontier(cm.M02)
        prefs = cm.frontier_preferences(state)
        self.assertEqual(prefs["build_order"][0], "barracks")
        self.assertFalse(prefs["allow_attack"],
                         "立足阶段不允许规则阶梯主动出击（手册：先集结再进攻）")

    def test_expansion_milestone_orders_command_center_first(self):
        state, _ = self._state_with_frontier(cm.M05)
        prefs = cm.frontier_preferences(state)
        self.assertEqual(prefs["build_order"][0], "command_center")

    def test_pressure_phase_allows_attack_and_keeps_turrets_first(self):
        state, _ = self._state_with_frontier(cm.M06)
        prefs = cm.frontier_preferences(state)
        self.assertTrue(prefs["allow_attack"])
        self.assertEqual(prefs["build_order"][0], "anti_air_turret")

    def test_no_campaign_state_keeps_legacy_ladder(self):
        # 直接调用阶梯（单测/回放）没有 campaign_state：必须保持既有语义不变。
        state = base_state()
        prefs = cm.frontier_preferences(state)
        self.assertFalse(prefs["active"])
        self.assertEqual(tuple(prefs["build_order"]), tuple(rf.BUILD_LADDER))
        self.assertTrue(prefs["allow_attack"])
        self.assertFalse(prefs["expand_probe"])

    def test_capacity_ladder_actually_builds_barracks_without_model(self):
        """无模型也能发展：前沿=产能建筑时，阶梯真的产出 barracks build 意图。"""
        state, campaign = self._state_with_frontier(cm.M02)
        campaign["milestones"][cm.M01]["status"] = "done"
        campaign["milestones"][cm.M01]["done_tick"] = 1
        state["ai_controlled_units"] = ["Unit_1"]
        state["unit_generations"] = {"Unit_1": 1}
        entities = [unit("Unit_0", "command_center", queue=True),
                    unit("Unit_1", "worker", gather=True, construct=True)]
        state["command_receipts"] = [{
            "status": "Accepted", "accepted": True, "action": "gather",
            "intent_id": "rule-gather-Unit_1-1"}]
        out = rf.development_intents(state, tactical=tactical(entities), rules=RULES_VIEW,
                                     server_tick=600)
        self.assertTrue(out, "规则阶梯没有产出任何意图（无模型僵局）")
        self.assertEqual(out[0]["action"], "build")
        self.assertEqual(out[0]["target"]["scene"],
                         RULES_VIEW["constructions"][0]["blueprint_scene_path"])

    def test_expansion_probe_when_no_candidate(self):
        """扩张选址没有合法落点时，规则中台派机动单位前探（否则主线永远卡住）。"""
        state, campaign = self._state_with_frontier(cm.M04)
        campaign["milestones"][cm.M01]["status"] = "done"
        campaign["milestones"][cm.M02]["status"] = "done"
        campaign["expansion_candidates"] = []
        state["ai_controlled_units"] = ["Unit_3"]
        state["unit_generations"] = {"Unit_3": 1}
        entities = [unit("Unit_0", "command_center", queue=True),
                    unit("Unit_3", "drone", pos=(5.0, 0.0, 5.0), movement=True)]
        # 远端矿点（>=30m）：候选落点算不出来（视野内无合法空位），但前探点应给出。
        far = [resource("R_far", (100.0, 0.0, 100.0))]
        cm.update(state, observation(entities + far), 600)
        prefs = cm.frontier_preferences(state)
        self.assertTrue(prefs["expand_probe"])
        out = rf.development_intents(state, tactical=tactical(entities + far),
                                    rules=RULES_VIEW, server_tick=600)
        self.assertTrue(out)
        self.assertEqual(out[0]["intent_id"].split("-")[1], "probe")


# ---------------------------------------------------------------------------
# 4. 紧急事件只进 interrupt_stack，处理完恢复原主线
# ---------------------------------------------------------------------------


class InterruptStackTest(unittest.TestCase):
    def test_emergency_pushes_stack_without_touching_mainline(self):
        state = base_state()
        entities = [unit("Unit_0", "command_center", queue=True),
                    unit("Unit_1", "worker", gather=True),
                    resource("R_1", (8.0, 0.0, 8.0))]
        cm.update(state, observation(entities), 0)
        before = cm.summary(state["campaign_state"])
        events = [{"event_id": "e1", "kind": "base_under_attack",
                   "server_tick": 100, "payload": {"subject": "Unit_2"}}]
        campaign = cm.update(state, observation(entities + [enemy("E_1", (5.0, 0.0, 5.0))],
                                                tick=100, events=events), 100)
        self.assertEqual(len(campaign["interrupt_stack"]), 1)
        entry = campaign["interrupt_stack"][0]
        self.assertEqual(entry["kind"], "base_under_attack")
        self.assertEqual(entry["status"], "active")
        # 恢复点必须与压栈前一致（不是"清空后的状态"）。
        self.assertEqual(entry["resume"]["next_frontier"], before["frontier"])
        # 主线与里程碑完全没被清空。
        after = cm.summary(campaign)
        self.assertEqual(after["phase"], before["phase"])
        self.assertEqual(after["milestones"], before["milestones"])
        self.assertEqual(set(after["tracks"]), set(before["tracks"]))

    def test_resolved_interrupt_restores_mainline(self):
        state = base_state()
        entities = [unit("Unit_0", "command_center", queue=True),
                    unit("Unit_1", "worker", gather=True),
                    resource("R_1", (8.0, 0.0, 8.0))]
        cm.update(state, observation(entities), 0)
        events = [{"event_id": "e1", "kind": "base_under_attack",
                   "server_tick": 100, "payload": {"subject": "Unit_2"}}]
        with_enemy = entities + [enemy("E_1", (5.0, 0.0, 5.0))]
        cm.update(state, observation(with_enemy, tick=100, events=events), 100)
        milestone_status = {key: str(value.get("status")) for key, value in
                            state["campaign_state"]["milestones"].items()}
        # 威胁消失 + 静默窗口过后：弹出，恢复四条 track（主线里程碑一个都没丢）。
        for tick in (200, 400, 800):
            cm.update(state, observation(entities, tick=tick), tick)
        campaign = state["campaign_state"]
        self.assertEqual(campaign["interrupt_stack"], [])
        self.assertGreaterEqual(campaign["interrupt_resolved"], 1)
        after = {key: str(value.get("status")) for key, value in
                 campaign["milestones"].items()}
        for key, value in milestone_status.items():
            if value == "done":
                self.assertEqual(after[key], "done",
                                 "中断处理结束后里程碑 %s 被重置了" % key)
        self.assertTrue(all(str((campaign["tracks"][name] or {}).get("status"))
                            in ("running", "suspended") for name in cm.TRACKS))

    def test_interrupt_expires_and_does_not_hang_mainline(self):
        state = base_state()
        entities = [unit("Unit_0", "command_center", queue=True),
                    unit("Unit_1", "worker", gather=True),
                    resource("R_1", (8.0, 0.0, 8.0))]
        cm.update(state, observation(entities), 0)
        events = [{"event_id": "e1", "kind": "base_under_attack",
                   "server_tick": 0, "payload": {"subject": "Unit_2"}}]
        # 敌人一直在基地旁边（威胁不消失）→ 只能靠超时弹出。
        stuck = entities + [enemy("E_1", (5.0, 0.0, 5.0))]
        cm.update(state, observation(stuck, tick=0, events=events), 0)
        cm.update(state, observation(stuck, tick=cm.INTERRUPT_MAX_TICKS + 10),
                  cm.INTERRUPT_MAX_TICKS + 10)
        campaign = state["campaign_state"]
        self.assertEqual(campaign["interrupt_stack"], [])
        self.assertEqual(campaign["resolved_interrupts"][0]["resolution"], "timeout")

    def test_defense_branch_only_when_interrupt_active(self):
        from adjutant_coordinator.graph import behavior_tree as bt
        state = {"ai_controlled_units": ["Unit_2"], "server_tick": 600,
                 "latest_snapshot_id": 1, "campaign_state": {}}
        entities = [unit("Unit_0", "command_center", queue=True),
                    unit("Unit_2", "soldier", pos=(6.0, 0.0, 6.0))]
        tac = tactical(entities, tick=600)
        plain = bt.micro_intents(state, tactical=tac)
        self.assertEqual({item["action"] for item in plain}, {"attack_move"},
                         "无中断时不应该出现回防")
        state["campaign_state"] = {
            "interrupt_stack": [{"kind": "base_under_attack", "status": "active",
                                 "units": ["Unit_0"]}]}
        defended = bt.micro_intents(state, tactical=tac)
        self.assertEqual({item["action"] for item in defended}, {"defend"})


# ---------------------------------------------------------------------------
# 5. 玩家局部接管只暂停受影响对象
# ---------------------------------------------------------------------------


class PlayerOverrideTest(unittest.TestCase):
    def test_override_suspends_only_affected_objects(self):
        state = base_state()
        campaign = cm.default_campaign(0)
        campaign["tracks"][cm.TRACK_ECONOMY]["current"] = {
            "intent_id": "i-1", "action": "gather", "units": ["Unit_1"],
            "since_tick": 0}
        campaign["milestones"][cm.M01]["status"] = "done"
        campaign["milestones"][cm.M01]["done_tick"] = 1
        state["campaign_state"] = campaign
        cm.note_player_override(campaign, ["Unit_1"], 120, "player_manual_command")
        self.assertEqual(campaign["suspended_objects"], ["Unit_1"])
        # 里程碑状态不动（未完成里程碑不丢失、不重置）。
        self.assertEqual(campaign["milestones"][cm.M01]["status"], "done")
        # 只有确实包含该对象的 track 被挂起。
        self.assertEqual(campaign["tracks"][cm.TRACK_ECONOMY]["status"], "suspended")
        self.assertEqual(campaign["tracks"][cm.TRACK_MILITARY]["status"], "running")
        # 归还后恢复。
        cm.note_player_release(campaign, ["Unit_1"], 240)
        self.assertEqual(campaign["suspended_objects"], [])
        self.assertEqual(campaign["tracks"][cm.TRACK_ECONOMY]["status"], "running")

    def test_suspended_units_are_not_given_new_work(self):
        state = base_state()
        campaign = cm.ensure_campaign(state, 0)
        campaign["suspended_objects"] = ["Unit_1"]
        state["ai_controlled_units"] = ["Unit_1", "Unit_2"]
        state["unit_generations"] = {"Unit_1": 1, "Unit_2": 1}
        entities = [unit("Unit_0", "command_center", queue=True),
                    unit("Unit_1", "worker", gather=True, construct=True),
                    unit("Unit_2", "worker", gather=True, construct=True)]
        out = rf.development_intents(state, tactical=tactical(entities), rules=RULES_VIEW,
                                     server_tick=60)
        for intent in out:
            self.assertNotIn("Unit_1", intent["unit_ids"])


# ---------------------------------------------------------------------------
# 6. 模型分支选择 / 模型失败不阻塞主线
# ---------------------------------------------------------------------------


class BranchSelectionTest(unittest.TestCase):
    def _state(self):
        state = base_state(tick=600)
        entities = [unit("Unit_0", "command_center", queue=True),
                    unit("Unit_1", "worker", gather=True, construct=True),
                    unit("Unit_2", "soldier"),
                    resource("R_1", (8.0, 0.0, 8.0))]
        state["ai_controlled_units"] = ["Unit_1", "Unit_2"]
        cm.update(state, observation(entities), 600)
        return state

    def test_valid_branch_is_adopted(self):
        state = self._state()
        campaign = state["campaign_state"]
        # D1（开工摸底）挂 M01，前置条件此时满足 → 采纳。
        self.assertIn("D1", campaign["decision_available"])
        result = cm.note_model_branch(state, "D1", 601)
        self.assertTrue(result["accepted"])
        self.assertEqual(campaign["mainline_branch"], cm.M01)
        self.assertEqual(campaign["branch_source"], "model")

    def test_unavailable_branch_is_ignored_and_mainline_kept(self):
        state = self._state()
        campaign = state["campaign_state"]
        before = cm.summary(campaign)
        # D12（进攻）要求"作战单位达集结规模 + 有可见敌人" → 此时不满足。
        self.assertNotIn("D12", campaign["decision_available"])
        result = cm.note_model_branch(state, "D12", 601)
        self.assertFalse(result["accepted"])
        self.assertEqual(result["reason"], "precondition_unmet")
        after = cm.summary(campaign)
        self.assertEqual(after["frontier"], before["frontier"])
        self.assertEqual(after["milestones"], before["milestones"])

    def test_unknown_branch_does_not_break_anything(self):
        state = self._state()
        campaign = state["campaign_state"]
        before = cm.summary(campaign)
        for ref in ("", "D999", "不存在的分支"):
            result = cm.note_model_branch(state, ref, 601)
            self.assertFalse(result["accepted"])
        self.assertEqual(cm.summary(campaign)["milestones"], before["milestones"])

    def test_branch_choice_biases_rule_ladder(self):
        state = self._state()
        # 让 D5（补防御塔）可用：把"曾受袭"标上。
        state["campaign_state"]["under_attack_total"] = 1
        state["campaign_state"]["milestones"][cm.M02]["status"] = "done"
        state["campaign_state"]["milestones"][cm.M02]["done_tick"] = 1
        cm.update(state, observation([unit("Unit_0", "command_center", queue=True),
                                      unit("Unit_1", "worker", gather=True,
                                           construct=True)],
                                     tick=700), 700)
        self.assertIn("D5", state["campaign_state"]["decision_available"])
        cm.note_model_branch(state, "D5", 700)
        prefs = cm.frontier_preferences(state)
        self.assertEqual(prefs["build_order"][:2],
                         ("anti_air_turret", "anti_ground_turret"))


# ---------------------------------------------------------------------------
# 7. 模型上下文
# ---------------------------------------------------------------------------


class ModelContextTest(unittest.TestCase):
    def test_context_view_contains_required_fields(self):
        state = base_state()
        campaign = cm.update(state, observation([unit("Unit_1", "worker", gather=True),
                                                 resource("R_1", (8.0, 0.0, 8.0))]), 0)
        view = cm.context_view(campaign)
        for key in ("phase", "mainline_id", "frontier", "frontier_name",
                    "frontier_expects", "done", "done_names", "blocked", "pending",
                    "tracks", "interrupts", "available_routes", "decision_lines"):
            self.assertIn(key, view, key)
        self.assertEqual(set(view["tracks"]), set(cm.TRACKS))
        for name in cm.TRACKS:
            self.assertIn("status", view["tracks"][name])
            self.assertIn("task", view["tracks"][name])

    def test_compact_text_renders_mainline(self):
        from adjutant_coordinator.graph import squads, task_patch_prompt
        state = base_state()
        entities = [unit("Unit_0", "command_center", queue=True),
                    unit("Unit_1", "worker", gather=True, construct=True),
                    resource("R_1", (8.0, 0.0, 8.0))]
        cm.update(state, observation(entities), 0)
        state["ai_controlled_units"] = ["Unit_1"]
        frame = squads.build_decision_frame(
            match_id=MATCH, player_id=PLAYER, rules_version=RULES, snapshot_id=1,
            server_tick=60, tactical=tactical(entities, tick=60), rules=RULES_VIEW,
            authorized_units={"Unit_1"},
            campaign=cm.context_view(state["campaign_state"]))
        text = task_patch_prompt.render_compact_text(frame)
        self.assertIn("主线:", text)
        self.assertIn("阶段=", text)
        self.assertIn("可选路线:", text)
        self.assertIn("四线=", text)
        # 决策地图候选与前置条件都在上下文里（纠偏 §7）。
        self.assertIn("D1", text)

    def test_frame_context_exposes_campaign(self):
        from adjutant_coordinator.graph import squads
        state = base_state()
        cm.update(state, observation([unit("Unit_1", "worker", gather=True),
                                      resource("R_1", (8.0, 0.0, 8.0))]), 0)
        frame = squads.build_decision_frame(
            match_id=MATCH, player_id=PLAYER, rules_version=RULES, snapshot_id=1,
            server_tick=60, tactical=tactical([], tick=60), rules=RULES_VIEW,
            campaign=cm.context_view(state["campaign_state"]))
        self.assertEqual(frame.to_context()["campaign"]["phase"], cm.PHASE_RECON)


# ---------------------------------------------------------------------------
# 8. 跨 tick / checkpoint 保留
# ---------------------------------------------------------------------------


class PersistenceTest(unittest.TestCase):
    def test_campaign_survives_state_roundtrip(self):
        state = base_state()
        cm.update(state, observation([unit("Unit_1", "worker", gather=True),
                                      resource("R_1", (8.0, 0.0, 8.0))]), 120)
        state["campaign_state"]["milestones"][cm.M01]["status"] = "done"
        state["campaign_state"]["milestones"][cm.M01]["done_tick"] = 120
        graph_state = AdjutantGraphState.from_dict(state)
        payload = graph_state.to_checkpoint()
        restored = AdjutantGraphState.from_checkpoint(payload)
        self.assertEqual(restored.campaign_state["milestones"][cm.M01]["status"], "done")
        self.assertEqual(restored.campaign_state["next_frontier"],
                         state["campaign_state"]["next_frontier"])
        self.assertEqual(restored.summary()["campaign"]["phase"],
                         state["campaign_state"]["phase"])

    def test_campaign_survives_two_graph_ticks(self):
        from adjutant_coordinator.graph.graph import FallbackRunner
        from adjutant_coordinator.graph.nodes import GraphConfig, GraphServices
        from adjutant_coordinator.tests.graph_test_helpers import (
            RecordingTransport, header, rules_view, tactical as helper_tactical,
        )
        services = GraphServices(
            dispatch=RecordingTransport().send_command,
            config=GraphConfig(pause_on_player_interrupt=False))
        runner = FallbackRunner(services)
        # 用真实图状态（含 `active_plan` / `last_*_tick` 等路由必需字段）：
        # 只给测试字典会缺字段，`_StateView` 会抛 AttributeError（那是刻意的严格口径）。
        state = AdjutantGraphState(match_id=MATCH, player_id=PLAYER).to_dict()
        state["strategy_disabled"] = True
        own = [{"name": "Unit_0", "unit_type": "command_center",
                "pos": [0.0, 0.0, 0.0]},
               {"name": "Unit_1", "unit_type": "worker", "pos": [5.0, 0.0, 5.0]}]

        def _obs(tick, units):
            # 身份必须与图状态一致：不一致会被 ingest 判 `identity_drift` 并短路整轮
            # （这是刻意的安全边界 —— 绝不把命令发进别的对局）。
            return {"header": header(tick, match_id=MATCH, player_id=PLAYER,
                                     rules_version=RULES),
                    "tactical": helper_tactical(own=units, server_tick=tick,
                                                match_id=MATCH, player_id=PLAYER,
                                                rules_version=RULES),
                    "strategic": {"map_bounds": [200.0, 200.0], "enemy_intel": []},
                    "events": [], "rules": rules_view()}

        out = runner.run_tick(state, observation=_obs(60, own), tick=60)
        self.assertIn("update_campaign_state", runner.executed)
        self.assertIn("advance_milestones", runner.executed)
        self.assertNotEqual(out.get("degraded_reason"), "identity_drift")
        first = out["campaign_state"]
        self.assertEqual(first["next_frontier"], cm.M01)
        self.assertEqual(out["campaign_state"]["updated_tick"], 60)
        own2 = own + [{"name": "Unit_2", "unit_type": "worker", "pos": [6.0, 0.0, 6.0]}]
        out2 = runner.run_tick(out, observation=_obs(120, own2), tick=120)
        # 跨 tick 保留（不是每轮重建）。
        self.assertEqual(out2["campaign_state"]["created_tick"], 60)
        self.assertEqual(out2["campaign_state"]["updated_tick"], 120)


# ---------------------------------------------------------------------------
# 决策地图
# ---------------------------------------------------------------------------


class RichOpeningParityTest(unittest.TestCase):
    """开局 5 万时的"富局纪律"：钱不是瓶颈，**并发**才是。

    2026-09-12 实测（`--model off` 5 分钟）：只花掉 9,550 / 50,000（19%），
    余额 40,450 闲置，第二座基地拖到第 7.5 分钟。根因不是执行，而是**规则档位按穷局标定**：
    整局规划（各 1 座建筑 + 2 基地 + 4 工人）只值 6,800 A = 5 万的 13.6%。
    """

    def _state(self):
        state = base_state(tick=600)
        campaign = cm.ensure_campaign(state, 600)
        for key in (cm.M01, cm.M02):
            campaign["milestones"][key]["status"] = "done"
            campaign["milestones"][key]["done_tick"] = 1
        campaign["milestones"][cm.M03]["status"] = "pending"
        campaign["milestones"][cm.M03]["frontier_since"] = 600
        campaign["next_frontier"] = cm.M03          # M03 = produce_first（先补兵）
        campaign["phase"] = cm.PHASE_FOOTHOLD
        state["ai_controlled_units"] = ["Unit_0", "Unit_4", "Unit_1"]
        state["unit_generations"] = {name: 1 for name in state["ai_controlled_units"]}
        return state

    def _tactical(self, bank_a):
        return {
            "entities": [
                unit("Unit_0", "command_center", queue=True, constructed=True),
                unit("Unit_4", "barracks", queue=True, constructed=True),
                # 专职建造者（不采集）：保证阶梯能走到"建造"这一级。
                unit("Unit_1", "worker", construct=True),
            ],
            "balance": {"a": bank_a, "b": bank_a},
        }

    def test_bank_reader_is_conservative(self):
        self.assertEqual(rf.bank_a({"balance": {"a": 50000}}), 50000)
        self.assertEqual(rf.bank_a({"balance": {"a": "50000"}}), 50000)
        # 取不到 → 0（按穷局处理），绝不把"未知余额"当成富局。
        self.assertEqual(rf.bank_a({"balance": None}), 0)
        self.assertEqual(rf.bank_a({}), 0)

    def test_poor_bank_keeps_produce_first_veto(self):
        """穷局纪律保留：钱只够一头时，先补兵、不铺新工地。"""
        out = rf.development_intents(self._state(), tactical=self._tactical(1000),
                                     rules=RULES_VIEW, server_tick=600, snapshot_id=5)
        self.assertNotIn("build", [item["action"] for item in out])

    def test_rich_bank_builds_and_produces_in_parallel(self):
        """富局**不二选一**：一边补兵一边继续铺产能/防御/分基地。"""
        out = rf.development_intents(self._state(), tactical=self._tactical(50000),
                                     rules=RULES_VIEW, server_tick=600, snapshot_id=5)
        actions = [item["action"] for item in out]
        self.assertIn("build", actions,
                      "余额 5 万时不该因为「先补兵」而停止扩张：%s" % (out,))

    def test_worker_queue_cap_opens_up_when_rich(self):
        self.assertEqual(rf._worker_queue_cap(1000, target=6, deployed=1), rf.WORKER_QUEUE_CAP)
        self.assertEqual(rf._worker_queue_cap(50000, target=6, deployed=1), 5)


class TraditionalAiParityTest(unittest.TestCase):
    """铁律"副官永不弱于传统 AI"必须是**可校验的数字**，不是口号。

    规则档位（工人/基地上限）如果低于游戏里原有的传统 AI，那么"钱花不出去"、
    "发展慢"就是**设计如此**——2026-09-12 实测正是如此（我们 4 工人/2 基地，
    传统 AI 6 工人/3 基地）。
    """

    GAME_AI = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "..", "..", "..", "source", "match", "players",
                           "simple-clairvoyant-ai", "SimpleClairvoyantAI.gd")

    def _exported_default(self, name):
        import io
        import re
        with io.open(os.path.abspath(self.GAME_AI), encoding="utf-8") as handle:
            text = handle.read()
        match = re.search(r"@export var %s\s*=\s*([0-9]+)" % name, text)
        self.assertIsNotNone(match, "传统 AI 里找不到 @export var %s" % name)
        return int(match.group(1))

    def test_workers_per_base_is_not_below_traditional_ai(self):
        theirs = self._exported_default("workers_per_command_center")
        self.assertGreaterEqual(rf.WORKERS_PER_BASE, theirs,
                                "副官每基地工人数低于传统 AI：%d < %d"
                                % (rf.WORKERS_PER_BASE, theirs))

    def test_command_center_limit_is_not_below_traditional_ai(self):
        theirs = self._exported_default("max_command_centers")
        ours = int(rf.BUILD_LIMITS.get("command_center", 1))
        self.assertGreaterEqual(ours, theirs,
                                "副官基地上限低于传统 AI：%d < %d" % (ours, theirs))


class LadderRegressionTest(unittest.TestCase):
    """规则阶梯的两个"同类 bug"守门用例（都来自 2026-09-12 真机 5 分钟实测）。"""

    def _developed_state(self):
        state = base_state(tick=600)
        campaign = cm.ensure_campaign(state, 600)
        # 前沿 = 首支作战队（`produce_first`）且产能建筑已就位 → 阶梯应直接补兵。
        for key in (cm.M01, cm.M02):
            campaign["milestones"][key]["status"] = "done"
            campaign["milestones"][key]["done_tick"] = 1
        campaign["milestones"][cm.M03]["status"] = "pending"
        campaign["milestones"][cm.M03]["frontier_since"] = 600
        campaign["next_frontier"] = cm.M03
        campaign["phase"] = cm.PHASE_FOOTHOLD
        state["ai_controlled_units"] = ["Unit_0", "Unit_4", "Unit_1", "Unit_2",
                                        "Unit_3", "Unit_5"]
        state["unit_generations"] = {name: 1 for name in state["ai_controlled_units"]}
        return state

    def _entities(self):
        return [
            unit("Unit_0", "command_center", queue=True, constructed=True),
            unit("Unit_4", "barracks", queue=True, constructed=True),
            unit("Unit_1", "worker", gather=True, construct=True),
            unit("Unit_2", "worker", gather=True, construct=True),
            unit("Unit_3", "worker", gather=True, construct=True),
            unit("Unit_5", "worker", gather=True, construct=True),
        ]

    def test_finished_produce_intent_does_not_block_facility_forever(self):
        """终结态的生产意图**不能**让设施被永久判成"正在生产"。

        `active_intents` 是追加式历史：旧实现只看 `action == produce`，
        于是第一次生产结束后该设施再也不会被派活 —— 真机表现为"建筑全建完、
        整局只出 1 个兵、M03 卡 12000 tick 被超时阻塞"。
        """
        state = self._developed_state()
        state["active_intents"] = [{
            "intent_id": "rule-produce-soldier-Unit_4-100", "action": "produce",
            "unit_ids": ["Unit_4"], "state": "completed", "expires_tick": 100000,
            "target": {"scene": RULES_VIEW["constructions"][0]["blueprint_scene_path"],
                       "producer": "Unit_4"}}]
        # 余额刻意给 0：本用例只问"终结态的生产意图会不会把设施永久占住"，
        # 不该被"富局并行建造"（见 `RichOpeningParityTest`）的调度顺序干扰。
        out = rf.development_intents(state, tactical=tactical(self._entities(), balance={"A": 0}),
                                     rules=RULES_VIEW, server_tick=600)
        self.assertTrue(out, "已终结的生产意图把兵营永久占住了（整局不再出兵）")
        self.assertIn("produce", [item["action"] for item in out],
                      "终结态的生产意图仍然把兵营占着：%s" % (out,))

    def test_live_produce_intent_still_blocks_same_facility(self):
        """存活态的生产意图仍要挡住同一设施（不能把"去重"一起修没了）。"""
        state = self._developed_state()
        state["active_intents"] = [{
            "intent_id": "rule-produce-soldier-Unit_4-500", "action": "produce",
            "unit_ids": ["Unit_4"], "state": "active", "expires_tick": 100000,
            "target": {"scene": RULES_VIEW["constructions"][0]["blueprint_scene_path"],
                       "producer": "Unit_4"}}]
        out = rf.development_intents(state, tactical=tactical(self._entities()),
                                     rules=RULES_VIEW, server_tick=600)
        self.assertEqual([item for item in out if item["action"] == "produce"], [])

    def test_probe_never_targets_static_buildings(self):
        """扩张前探只能派**会动的**单位：静态建筑发 move 必被权威端拒。

        真机证据：6 条 `rule-probe-expansion-Unit_7`（炮塔）全部 `Rejected`
        → 扩张选址被误判成"命令连续失败"而阻塞。
        """
        state = base_state(tick=600)
        campaign = cm.ensure_campaign(state, 600)
        for key in (cm.M01, cm.M02, cm.M03):
            campaign["milestones"][key]["status"] = "done"
            campaign["milestones"][key]["done_tick"] = 1
        campaign["milestones"][cm.M04]["status"] = "pending"
        campaign["milestones"][cm.M04]["frontier_since"] = 600
        campaign["next_frontier"] = cm.M04
        campaign["phase"] = cm.PHASE_EXPAND
        campaign["expansion_candidates"] = []
        campaign["expansion_probe"] = [70.0, 70.0]
        entities = [
            unit("Unit_0", "command_center", queue=True, constructed=True),
            unit("Unit_7", "anti_air_turret", queue=False, movement=False),
            resource("R_far", (70.0, 70.0)),
        ]
        state["ai_controlled_units"] = ["Unit_7"]
        out = rf.development_intents(state, tactical=tactical(entities), rules=RULES_VIEW,
                                     server_tick=600)
        self.assertEqual([item for item in out if item["action"] == "move"], [],
                         "静态建筑被派去前探（权威端必然拒绝）")


class MilestoneRetryBudgetTest(unittest.TestCase):
    """里程碑的"重试预算"只该被**内容类**拒绝消耗。

    2026-09-12 真机 `--model on`：6 条 `build/Rejected`（几何类——落点那会儿不在视野里）
    就把 M05「分基地/分矿」整条判成 blocked。按既有纪律，几何类拒绝是"换个点就行"
    （由落点账本按点拉黑处理），不该升级成"这条主线走不通"。
    """

    def _state(self, receipts):
        state = base_state()
        state["command_receipts"] = receipts
        entities = [unit("Unit_0", "command_center", queue=True),
                    unit("Unit_1", "worker", gather=True, construct=True),
                    resource("R_1", (8.0, 0.0, 8.0))]
        cm.update(state, observation(entities), 600)
        return state

    def _rejections(self, reason, prefix="rule-build-command_center", count=6):
        return [{"status": "Rejected", "accepted": False, "reason": reason,
                 "action": "build",
                 "intent_id": "%s-Unit_1-%d" % (prefix, 1000 + i)}
                for i in range(count)]

    def test_geometry_rejections_do_not_block_milestone(self):
        state = self._state(self._rejections("NotVisible"))
        entry = state["campaign_state"]["milestones"][cm.M05]
        self.assertNotEqual(entry["status"], "blocked",
                            "几何类拒绝（视野外）不该把分基地节点判成走不通")
        self.assertEqual(entry["rejections"], 0)

    def test_content_rejections_block_milestone(self):
        state = self._state(self._rejections("NotAllowed: 该单位不能建造"))
        entry = state["campaign_state"]["milestones"][cm.M05]
        self.assertEqual(entry["status"], "blocked")
        self.assertIn(cm.M05, state["campaign_state"]["blocked_milestones"])

    def test_stall_still_blocks(self):
        """停滞窗口仍然有效（"根本没产生命令"也要能判定阻塞）。"""
        state = base_state(tick=0)
        entities = [unit("Unit_0", "command_center", queue=True),
                    unit("Unit_1", "worker", gather=True)]
        cm.update(state, observation(entities), 0)
        campaign = state["campaign_state"]
        # 把前沿钉到 M05 并把 M01–M04 标完成，然后跨过停滞窗口。
        for key in (cm.M01, cm.M02, cm.M03, cm.M04):
            campaign["milestones"][key]["status"] = "done"
            campaign["milestones"][key]["done_tick"] = 1
        campaign["milestones"][cm.M05]["status"] = "pending"
        campaign["milestones"][cm.M05]["frontier_since"] = 0
        campaign["next_frontier"] = cm.M05
        # `frontier_since == 0` 表示"还没记过起始时刻"，第一轮只做播种；
        # 因此必须跨两轮才谈得上"停滞"（这也是刻意的：不许把刚上任就当停滞）。
        cm.update(state, observation(entities), 100)
        self.assertEqual(campaign["next_frontier"], cm.M05)
        self.assertEqual(campaign["milestones"][cm.M05]["frontier_since"], 100)
        stall = int(cm.MILESTONES[cm.M05]["retry"]["stall_ticks"])
        cm.update(state, observation(entities), 100 + stall + 10)
        self.assertEqual(campaign["milestones"][cm.M05]["status"], "blocked")


class DecisionLogRobustnessTest(unittest.TestCase):
    """决策日志必须能容忍"payload 里带 `kind`"（真机致命 bug 的守门用例）。

    2026-09-12 真机（`--model on` 5 分钟）：中断恢复日志写成
    `_decide(state, "campaign_interrupt_resolved", **item)`，而 `item` 自带 `kind`
    → 调用时撞名 → `TypeError` → **整个 tick 抛异常** → 连续 20 轮后 runner 自杀退出。
    位置专用参数（`/`）让这类数据从"致命错误"退化成"无害字段"。
    """

    def test_payload_kind_does_not_raise(self):
        from adjutant_coordinator.graph import nodes
        state = {"server_tick": 7, "decision_log": []}
        entry = nodes._decide(state, "campaign_interrupt_resolved",
                              kind="path_failed", interrupt_kind="path_failed")
        self.assertEqual(entry["kind"], "campaign_interrupt_resolved")
        self.assertEqual(entry["interrupt_kind"], "path_failed")
        self.assertEqual(state["decision_log"][-1]["kind"],
                         "campaign_interrupt_resolved")

    def test_state_decide_tolerates_kind_payload(self):
        state = AdjutantGraphState(match_id=MATCH, player_id=PLAYER)
        state.server_tick = 3
        entry = state.decide("campaign_x", kind="payload_kind", other=1)
        self.assertEqual(entry["kind"], "campaign_x")
        self.assertEqual(entry["other"], 1)

    def test_resolved_interrupt_is_logged_through_the_node(self):
        """整条链路：紧急事件入栈 → 静默窗口后由节点弹出并写决策日志（不抛异常）。"""
        from adjutant_coordinator.graph import nodes
        from adjutant_coordinator.graph.nodes import GraphConfig, GraphServices, NodeContext
        state = base_state()
        entities = [unit("Unit_0", "command_center", queue=True),
                    unit("Unit_1", "worker", gather=True),
                    resource("R_1", (8.0, 0.0, 8.0))]
        events = [{"event_id": "e1", "kind": "path_failed",
                   "server_tick": 0, "payload": {"subject": "Unit_1"}}]
        cm.update(state, observation(entities, tick=0, events=events), 0)
        self.assertEqual(len(state["campaign_state"]["interrupt_stack"]), 1)
        state["server_tick"] = 600
        ctx = NodeContext(services=GraphServices(config=GraphConfig()),
                          observation=observation(entities, tick=600), tick=600)
        nodes.node_advance_milestones(state, ctx)     # 修复前：这里抛 TypeError
        kinds = [str(item.get("kind")) for item in state["decision_log"]]
        self.assertIn("campaign_interrupt_resolved", kinds)
        self.assertEqual(state["campaign_state"]["interrupt_stack"], [])


class ObservationParserSingleSourceTest(unittest.TestCase):
    """观测解析必须**全仓唯一实现**（同类问题不许再换皮复发）。

    2026-09-12 真机教训：`rules_fallback._normalized_units` 曾是 `observation_view`
    的**副本**，`movement` 只加在后者上 → 前探挑中不会动的炮塔 → `move` 被权威端拒 →
    里程碑被误判为"命令连续失败"而阻塞。所以这里钉死"两份视图必须逐字段一致"。
    """

    def test_both_views_are_identical(self):
        from adjutant_coordinator.graph import observation_view as ov
        entities = [
            unit("Unit_0", "command_center", queue=True, constructed=True),
            unit("Unit_1", "worker", gather=True, construct=True),
            unit("Unit_2", "anti_air_turret", queue=False, movement=False),
            unit("Unit_3", "drone", movement=True),
        ]
        tac = tactical(entities)
        self.assertEqual(rf._normalized_units(tac), ov.normalized_units(tac))
        self.assertIn("movement", ov.normalized_units(tac)["Unit_3"])
        self.assertFalse(ov.normalized_units(tac)["Unit_2"]["movement"])


class DecisionMapTest(unittest.TestCase):
    def test_every_node_has_preconditions_and_is_linked_to_manual(self):
        manual_ids = {str(node["node"]) for node in decision_map.DECISION_NODES}
        for expected in ("ECO-01", "ECO-02", "BLD-01", "BLD-02", "BLD-03",
                         "SCT-01", "SCT-02", "SCT-03",
                         "ARM-01", "DEF-01", "ATK-01", "ATK-02", "RET-01", "REG-01"):
            self.assertIn(expected, manual_ids, expected)
        for node in decision_map.DECISION_NODES:
            self.assertTrue(node.get("preconditions"), node["id"])
            for name in node["preconditions"]:
                self.assertIn(name, decision_map.PRECONDITIONS, name)
                self.assertIn(name, decision_map.PRECONDITION_TEXT, name)

    def test_retrieve_reports_locked_with_missing_requirements(self):
        state = base_state()
        entities = [unit("Unit_0", "command_center", queue=True),
                    unit("Unit_1", "worker", gather=True, construct=True),
                    resource("R_1", (8.0, 0.0, 8.0))]
        campaign = cm.update(state, observation(entities), 0)
        facts = cm.build_facts(state, observation(entities), 0)
        # `limit` 放大只是为了让断言看到全部节点（生产默认 6 条）。
        retrieved = decision_map.retrieve(facts, campaign, limit=len(
            decision_map.DECISION_NODES))
        available = {item["id"] for item in retrieved["available"]}
        locked = {item["id"]: item for item in retrieved["locked"]}
        self.assertIn("D1", available)
        self.assertIn("D3", available)
        self.assertIn("D12", locked)
        self.assertTrue(locked["D12"]["unmet"])

    def test_under_attack_unlocks_defense_node(self):
        state = base_state()
        entities = [unit("Unit_0", "command_center", queue=True),
                    unit("Unit_2", "soldier"),
                    enemy("E_1", (5.0, 0.0, 5.0))]
        cm.update(state, observation(entities, events=[
            {"event_id": "e1", "kind": "base_under_attack", "server_tick": 0,
             "payload": {"subject": "Unit_0"}}]), 0)
        facts = cm.build_facts(state, observation(entities), 0)
        facts["enemy_positions"] = [[5.0, 5.0]]
        retrieved = decision_map.retrieve(facts, state["campaign_state"])
        available = {item["id"] for item in retrieved["available"]}
        self.assertIn("D10", available)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
