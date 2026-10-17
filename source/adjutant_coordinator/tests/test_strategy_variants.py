# -*- coding: utf-8 -*-
"""收缩战略接口（B/C/D/D0）的实质合同测试。

只测"这类错误不可能再出现"的东西，不复制实现：
1. 程序生成的候选计划**永远合法**（单位 ∈ 当次 ai_controlled_units、动作 ∈ ALLOWED_ACTIONS、
   task_id 不重复、KEEP 只在确有 active_plan 时出现）；
2. 模型输出**越界/非法**时回退到规则主线，绝不产出半个计划；
3. D0 消融**不调用模型**；D 只在歧义时调用；
4. 候选置换只改位置/ID，不改变语义（选中的仍是同一份合法计划）。
"""
import copy
import unittest

from adjutant_coordinator.graph import contracts as C
from adjutant_coordinator.graph import strategy_variants as SV


def sample_context(active_plan=None):
    return {
        "match_id": "m-1", "player_id": "Player_1", "rules_version": "r-1",
        "server_tick": 1000, "snapshot_id": 40,
        "ai_controlled_units": ["Unit_0", "Unit_1", "Unit_2", "Unit_3", "Unit_4"],
        "player_controlled_units": [],
        "unit_facts": {
            "Unit_0": {"type": "command_center", "movement": False, "queue": True, "constructed": True},
            "Unit_1": {"type": "drone", "movement": True, "combat": False},
            "Unit_2": {"type": "vehicle_factory", "movement": False, "queue": True, "constructed": True},
            "Unit_3": {"type": "worker", "movement": True, "gather": True, "construct": True},
            "Unit_4": {"type": "tank", "movement": True, "combat": True},
        },
        "budget": {"A": 5000}, "resource_count": 3,
        "strategy_productions": [{"product_type_id": "worker", "allowed_producer_type_ids": ["vehicle_factory"],
                                   "cost": [{"kind": "A", "amount": 200}]}],
        "strategy_buildables": [{"id": "ore_refinery", "construction_progress_source": "worker",
                                  "cost": [{"kind": "A", "amount": 900}]}],
        "current_plan": active_plan,
        "strategic_summary": {
            "available_actions": ["move", "attack_move", "attack", "gather", "stop",
                                  "produce", "build"],
            "enemy_intel": [],
            "production": [
                {"producer": "Unit_0", "producer_type": "command_center", "queue_size": 0},
                {"producer": "Unit_2", "producer_type": "vehicle_factory", "queue_size": 0},
            ],
        },
        "campaign": {
            "phase": "立足", "frontier_name": "首支作战队",
            "tracks": {"economy": {"units": ["Unit_3"]}, "build": {"units": ["Unit_4"]},
                       "scout": {"units": ["Unit_1"]}, "military": {"units": []}},
            "economy": {"workers": 2, "refinery_constructed": 0, "refinery_delivered": 0},
            "available_routes": ["D1", "D3", "D6"],
            "available_route_names": {"D1": "开工摸底", "D3": "推进发展阶梯", "D6": "开局散点探路"},
            "expansion_candidates": [[300.0, 120.0]],
            "interrupts": [],
        },
    }


class FakeChat:
    """按队列回文本的假模型（记录调用次数）。"""

    def __init__(self, replies):
        self.replies = list(replies)
        self.calls = 0

    def ask(self, system, user):
        self.calls += 1
        text = self.replies.pop(0) if self.replies else "{}"
        return text, 1.0


class CandidateLegalityTest(unittest.TestCase):
    def test_candidates_are_always_legal(self):
        for intel in ([], [{"name": "Enemy_0", "pos": [1.0, 0.0, 2.0], "last_seen_tick": 990}]):
            ctx = sample_context()
            ctx["strategic_summary"] = dict(ctx["strategic_summary"], enemy_intel=intel)
            candidates, facts = SV.generate_candidates(ctx)
            allowed_units = set(ctx["ai_controlled_units"])
            self.assertTrue(candidates)
            self.assertEqual(len([c for c in candidates if not c.maintain_current]) <= 4, True)
            for item in candidates:
                plan = SV.candidate_to_plan(item, ctx, "test")
                parsed = C.parse_strategic_plan(plan)      # 合同必须通过
                self.assertEqual(parsed.maintain_current, item.maintain_current)
                self.assertGreater(parsed.valid_until_tick, ctx["server_tick"])
                ids = [t.task_id for t in parsed.tasks]
                self.assertEqual(len(ids), len(set(ids)), "task_id 不得重复")
                for task in parsed.tasks:
                    self.assertTrue(set(task.allowed_actions) <= set(C.ALLOWED_ACTIONS))
                    self.assertTrue(set(task.units) <= allowed_units,
                                    "计划不得引用非受控单位：%s" % task.units)

    def test_attack_requires_confirmed_intel(self):
        ctx = sample_context()
        ctx["strategic_summary"] = dict(ctx["strategic_summary"], enemy_intel=[])
        ctx["campaign"] = dict(ctx["campaign"], tracks={"economy": {"units": ["Unit_3"]},
                                                      "military": {"units": ["Unit_4"]},
                                                      "scout": {"units": ["Unit_1"]}})
        ids = {c.candidate_id for c in SV.generate_candidates(ctx)[0]}
        self.assertNotIn("C-ATTACK", ids, "没有确认敌情时不得给出进攻候选")

    def test_keep_only_with_active_plan(self):
        ctx = sample_context()
        self.assertNotIn("KEEP", {c.candidate_id for c in SV.generate_candidates(ctx)[0]})
        plan = SV.candidate_to_plan(
            SV.candidate_by_id(SV.generate_candidates(ctx)[0], "C-ECO"), ctx, "seed")
        ctx["current_plan"] = plan.to_plan_dict()
        candidates = SV.generate_candidates(ctx)[0]
        keep = SV.candidate_by_id(candidates, "KEEP")
        self.assertIsNotNone(keep)
        self.assertTrue(keep.maintain_current)

    def test_static_buildings_and_unarmed_drone_never_become_army(self):
        ctx = sample_context()
        candidates, facts = SV.generate_candidates(ctx)
        self.assertEqual(facts.combat_units(), ["Unit_4"])
        self.assertEqual(facts.recon_units(), ["Unit_1"])
        for candidate in candidates:
            for task in candidate.tasks:
                if set(task["allowed_actions"]) & {"move", "scout", "regroup", "attack", "defend"}:
                    self.assertFalse(set(task["units"]) & {"Unit_0", "Unit_2"})

    def test_worker_production_uses_real_relation(self):
        ctx = sample_context()
        eco = SV.candidate_by_id(SV.generate_candidates(ctx)[0], "C-ECO")
        production = next(t for t in eco.tasks if "produce" in t["allowed_actions"])
        self.assertEqual(production["units"], ["Unit_2"])
        self.assertEqual(production["target_type"], "worker")

    def test_automatic_refinery_does_not_require_worker_builder(self):
        ctx = sample_context()
        ctx["unit_facts"]["Unit_3"].pop("construct", None)
        ctx["strategy_buildables"][0]["construction_progress_source"] = "automatic"
        candidates, facts = SV.generate_candidates(ctx)
        self.assertTrue(facts.refinery_buildable)
        eco = SV.candidate_by_id(candidates, "C-ECO")
        self.assertIsNotNone(eco)
        build = next(task for task in eco.tasks if "build" in task["allowed_actions"])
        self.assertEqual(build["target_type"], "ore_refinery")
        self.assertTrue(build["units"], "automatic construction still needs an authorized command carrier")
        plan = SV.candidate_to_plan(eco, ctx, "automatic-refinery")
        self.assertTrue(SV._current_plan_valid(plan.to_plan_dict(), ctx, facts))

    def test_missing_capabilities_and_player_takeover_remove_candidates(self):
        ctx = sample_context()
        ctx.pop("unit_facts")
        self.assertEqual(SV.generate_candidates(ctx)[0], [])
        ctx = sample_context()
        ctx["player_controlled_units"] = ctx["ai_controlled_units"][:]
        self.assertEqual(SV.generate_candidates(ctx)[0], [])

    def test_unauthorized_stale_tracks_and_producer_are_ignored(self):
        ctx = sample_context()
        ctx["player_controlled_units"] = ["Unit_1", "Unit_2", "Unit_3", "Unit_4"]
        self.assertEqual(SV.generate_candidates(ctx)[0], [])

    def test_unfinished_dead_and_busy_factory_cannot_produce(self):
        for field, value in (("constructed", False), ("constructed", None), ("hp", 0), ("confirmed_dead", True)):
            ctx = sample_context()
            ctx["unit_facts"]["Unit_2"][field] = value
            self.assertEqual(SV.build_facts(ctx).worker_producers, [], field)
        ctx = sample_context()
        ctx["strategic_summary"]["production"][1]["queue_size"] = 1
        self.assertEqual(SV.build_facts(ctx).worker_producers, [])

    def test_joint_budget_does_not_promise_both_build_and_production(self):
        ctx = sample_context()
        ctx["budget"] = {"A": 1000}
        eco = SV.candidate_by_id(SV.generate_candidates(ctx)[0], "C-ECO")
        self.assertIn("build", [a for t in eco.tasks for a in t["allowed_actions"]])
        self.assertNotIn("produce", [a for t in eco.tasks for a in t["allowed_actions"]])
        ctx["budget"] = {}
        eco = SV.candidate_by_id(SV.generate_candidates(ctx)[0], "C-ECO")
        self.assertEqual([a for t in eco.tasks for a in t["allowed_actions"]], ["gather"])

    def test_keep_rejects_expired_wrong_identity_future_and_player_tasks(self):
        ctx = sample_context()
        ctx["current_plan"] = SV.candidate_to_plan(
            SV.candidate_by_id(SV.generate_candidates(ctx)[0], "C-ECO"), ctx, "seed").to_plan_dict()
        for field, value in (("valid_until_tick", 1000), ("match_id", "other"), ("based_on_snapshot", 41)):
            case = copy.deepcopy(ctx)
            case["current_plan"][field] = value
            self.assertNotIn("KEEP", {c.candidate_id for c in SV.generate_candidates(case)[0]})
        ctx["player_controlled_units"] = ["Unit_3"]
        self.assertNotIn("KEEP", {c.candidate_id for c in SV.generate_candidates(ctx)[0]})

    def test_recon_never_borrows_entire_army(self):
        ctx = sample_context()
        ctx["ai_controlled_units"] = ["Unit_4"]
        self.assertNotIn("C-RECON", {c.candidate_id for c in SV.generate_candidates(ctx)[0]})

    def test_keep_rejects_wrong_product_but_preserves_valid_inflight_queue(self):
        ctx = sample_context()
        eco = SV.candidate_by_id(SV.generate_candidates(ctx)[0], "C-ECO")
        ctx["current_plan"] = SV.candidate_to_plan(eco, ctx, "seed").to_plan_dict()
        production = next(t for t in ctx["current_plan"]["tasks"] if "produce" in t["allowed_actions"])
        production["units"] = ["Unit_0"]
        self.assertNotIn("KEEP", {c.candidate_id for c in SV.generate_candidates(ctx)[0]})
        production["units"] = ["Unit_2"]
        ctx["strategic_summary"]["production"][1]["queue_size"] = 1
        self.assertIn("KEEP", {c.candidate_id for c in SV.generate_candidates(ctx)[0]})

    def test_player_returned_unit_is_authorized_again(self):
        ctx = sample_context()
        ctx["released_units"] = ["Unit_1"]
        self.assertIn("C-RECON", {c.candidate_id for c in SV.generate_candidates(ctx)[0]})


class FallbackTest(unittest.TestCase):
    def test_template_out_of_enum_falls_back_to_rules(self):
        provider = SV.TemplateStrategy(FakeChat(['{"template":"nuke"}']))
        plan = provider.propose_plan(sample_context())
        self.assertTrue(str(plan.plan_id).startswith("rules-"),
                        "越界模板必须回退规则主线，而不是产出非法计划")

    def test_choice_out_of_enum_falls_back_to_rules(self):
        provider = SV.ChoiceStrategy(FakeChat(['{"choice":"C999"}']))
        plan = provider.propose_plan(sample_context())
        self.assertTrue(str(plan.plan_id).startswith("rules-"))

    def test_no_model_falls_back(self):
        provider = SV.ChoiceStrategy(None)
        plan = provider.propose_plan(sample_context())
        self.assertTrue(str(plan.plan_id).startswith("rules-"))

    def test_choice_in_enum_maps_to_candidate(self):
        provider = SV.ChoiceStrategy(FakeChat(['{"choice":"C-RECON"}']))
        plan = provider.propose_plan(sample_context())
        self.assertEqual(plan.plan_id, "strat-c-recon")
        self.assertEqual([t.task_id for t in plan.tasks], ["strat-recon"])


class ScoringTest(unittest.TestCase):
    def test_emergency_defense_beats_economy_gap(self):
        ctx = sample_context()
        ctx["campaign"]["interrupts"] = [{"kind": "base_under_attack"}]
        plan = SV.ScoringOnlyStrategy().propose_plan(ctx)
        self.assertEqual(plan.plan_id, "strat-c-defend")
    def test_d0_never_calls_model(self):
        chat = FakeChat(['{"choice":"C-DEFEND"}'])
        provider = SV.ScoringOnlyStrategy(chat)
        plan = provider.propose_plan(sample_context())
        self.assertEqual(chat.calls, 0, "D0 消融不得调用模型")
        self.assertFalse(plan.maintain_current)

    def test_d_arbitrates_only_when_ambiguous(self):
        ctx = sample_context()
        # margin 0 → 任何分差都算不歧义 → 不调用模型
        tight = SV.ScoringStrategy(FakeChat(['{"choice":"C-DEFEND"}']), margin=0)
        tight.propose_plan(copy.deepcopy(ctx))
        self.assertEqual(tight.arbitrations, 0)
        # margin 巨大 → 一定歧义 → 请求模型仲裁
        loose = SV.ScoringStrategy(FakeChat(['{"choice":"C-RECON"}']), margin=10 ** 6)
        plan = loose.propose_plan(copy.deepcopy(ctx))
        self.assertEqual(loose.arbitrations, 1)
        self.assertEqual(plan.plan_id, "strat-c-recon")

    def test_arbitration_out_of_range_falls_back_to_program_top(self):
        loose = SV.ScoringStrategy(FakeChat(['{"choice":"NOPE"}']), margin=10 ** 6)
        plan = loose.propose_plan(sample_context())
        self.assertFalse(plan.maintain_current)
        self.assertTrue(str(plan.plan_id).startswith("strat-"))


class PermutationTest(unittest.TestCase):
    def test_relabel_keeps_semantics(self):
        ctx = sample_context()
        baseline = SV.prepare_selection(ctx)
        shuffled = SV.prepare_selection(
            ctx, SV.SelectionOptions(rotation=7, relabel=True))
        semantic_ids = [c.candidate_id for c in baseline.candidates]
        offset = 7 % len(semantic_ids)
        self.assertEqual([c.candidate_id for c in shuffled.candidates],
                         semantic_ids[offset:] + semantic_ids[:offset])
        self.assertEqual([c.display_id for c in shuffled.candidates],
                         ["P%d" % i for i in range(1, len(shuffled.candidates) + 1)])
        self.assertEqual(shuffled.request_id, baseline.request_id)
        baseline_by_id = {c.candidate_id: c for c in baseline.candidates}
        for item in shuffled.candidates:
            original = baseline_by_id[item.candidate_id]
            self.assertEqual(item.name, original.name)
            self.assertEqual(item.tasks, original.tasks)
            plan = SV.candidate_to_plan(item, shuffled.context(), "test")
            expected = SV.candidate_to_plan(original, baseline.context(), "test")
            self.assertEqual(plan.to_plan_dict(), expected.to_plan_dict())
            C.parse_strategic_plan(plan)


if __name__ == "__main__":
    unittest.main()
