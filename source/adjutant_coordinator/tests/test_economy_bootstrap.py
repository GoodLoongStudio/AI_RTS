"""Opening failure recovery and shared budget invariants."""
import copy
import unittest

from adjutant_coordinator.graph import economy_bootstrap as boot, reserves
from adjutant_coordinator.graph import rules_fallback as rf
from adjutant_coordinator.graph.observation_view import normalized_units


SCENES = {kind: "res://" + kind + ".tscn" for kind in
          ("ore_refinery", "command_center", "vehicle_factory", "worker", "tank")}
RULES = {
    "unit_types": [{"id": kind, "scene_path": scene} for kind, scene in SCENES.items()],
    "constructions": [{"id": kind, "blueprint_scene_path": SCENES[kind],
                       "construction_progress_source": "automatic",
                       "cost": [{"kind": "A", "amount": amount}]}
                      for kind, amount in (("ore_refinery", 900),
                                           ("command_center", 600), ("vehicle_factory", 400))],
    "productions": [{"product_type_id": kind, "allowed_producer_type_ids": ["vehicle_factory"],
                     "cost": [{"kind": "A", "amount": amount}]}
                    for kind, amount in (("worker", 200), ("tank", 500))],
}


def intent(kind, action="build", name=None):
    return {"intent_id": name or kind, "action": action,
            "target": {"scene": SCENES[kind], "hint": [80.0, 40.0]}}


def unit(kind, **values):
    return dict(kind="unit_self", name=kind, unit_type=kind, constructed=True, **values)


def tac(*units):
    return {"entities": list(units), "production": []}


class OpeningPolicyTest(unittest.TestCase):
    def test_only_authority_site_exhaustion_requests_anchor(self):
        for reason in ("Budget", "ConstructionInProgress", "NotVisible", "", "NoValidSite"):
            state = {"server_tick": 60}
            boot.observe_build_receipt(state, intent("ore_refinery"),
                {"accepted": False, "reason": reason}, rules=RULES, tactical=tac())
            needed = boot.required_building(state, rules=RULES, by_name={}, tick=60)
            self.assertEqual(needed, "command_center" if reason == "NoValidSite" else "ore_refinery")

    def test_one_anchor_bounded_retry_and_same_hint(self):
        state = {"server_tick": 60}
        sequence = []
        def observe(kind, accepted):
            sequence.append(kind)
            boot.observe_build_receipt(state, intent(kind, name=str(len(sequence))),
                {"accepted": accepted, "reason": "" if accepted else "NoValidSite"},
                rules=RULES, tactical=tac())
        observe("ore_refinery", False)
        self.assertEqual(boot.opening_hint(state, "command_center"), [80.0, 40.0])
        observe("command_center", True)
        self.assertEqual(boot.required_building(state, rules=RULES, by_name={}, tick=60), "ore_refinery")
        self.assertEqual(boot.opening_hint(state, "ore_refinery"), [80.0, 40.0])
        observe("ore_refinery", False)
        self.assertIsNone(boot.required_building(state, rules=RULES, by_name={}, tick=959))
        self.assertEqual(boot.required_building(state, rules=RULES, by_name={}, tick=960), "ore_refinery")
        observe("ore_refinery", False)
        self.assertNotEqual(boot.required_building(state, rules=RULES, by_name={}, tick=1960), "command_center")

    def test_receipt_replay_does_not_cancel_pending_anchor(self):
        state = {"server_tick": 60}
        for _ in range(3):
            boot.observe_build_receipt(state, intent("ore_refinery"),
                {"accepted": False, "reason": "NoValidSite", "intent_replay": True},
                rules=RULES, tactical=tac())
        self.assertEqual(boot.required_building(state, rules=RULES, by_name={}, tick=60), "command_center")

    def test_pending_refinery_and_real_delivery_release_policy(self):
        state = {}
        pending = normalized_units(tac(unit("ore_refinery", refinery={"constructed": False})))
        self.assertIsNone(boot.required_building(state, rules=RULES, by_name=pending, tick=0))
        self.assertEqual(boot.worker_target(RULES, pending, 6), 1)
        delivered = normalized_units(tac(unit("ore_refinery", refinery={"constructed": True,
                                                          "delivered_count": 1})))
        self.assertEqual(boot.worker_target(RULES, delivered, 6), 6)
        self.assertEqual(boot.protected_costs(state, rules=RULES,
                                            tactical=tac(unit("ore_refinery", refinery={"delivered_count": 1}))), {})

    def test_legacy_unknown_rules_do_not_create_campaign(self):
        state = {}
        self.assertIsNone(boot.required_building(state, rules={}, by_name={}, tick=0))
        self.assertEqual(boot.protected_costs(state, rules={}, tactical=tac()), {})
        self.assertEqual(state, {})

    def test_combat_waits_for_delivery_facility_and_worker_not_defenses(self):
        self.assertFalse(rf.combat_production_allowed({}, tac(unit("worker")), 0, RULES))
        self.assertTrue(rf.combat_production_allowed({}, tac(unit("worker"),
            unit("ore_refinery", refinery={"constructed": True, "delivered_count": 0})), 0, RULES))


class OpeningBudgetTest(unittest.TestCase):
    def budget(self, state, batch, balance, units, reserve=0):
        observation = {"tactical": dict(units, balance={"A": balance}, reserves={"A": reserve})}
        return reserves.apply_budget(state, batch, rules=RULES, observation=observation,
                                     live_states=("active", "pending_authority"))

    def test_parallel_military_cannot_consume_missing_facility_fund(self):
        kept, dropped = self.budget({}, [intent("tank", "produce")], 1200,
                                    tac(unit("worker"), unit("vehicle_factory")))
        self.assertFalse(kept)
        self.assertEqual(dropped[0]["economy_protection"], {"A": 900})

    def test_unit_and_blueprint_scene_have_same_authoritative_build_cost(self):
        rules = copy.deepcopy(RULES)
        rules["constructions"][0]["blueprint_scene_path"] = "res://geometry/refinery.tscn"
        self.assertEqual(reserves.intent_cost(intent("ore_refinery"), rules), {"A": 900})
        blueprint = intent("ore_refinery")
        blueprint["target"]["scene"] = "res://geometry/refinery.tscn"
        self.assertEqual(reserves.intent_cost(blueprint, rules), {"A": 900})

    def test_essential_first_and_same_batch_payment_not_double_reserved(self):
        batch = [intent("tank", "produce"), intent("ore_refinery")]
        kept, dropped = self.budget({}, batch, 1400, tac(unit("worker"), unit("vehicle_factory")))
        self.assertEqual([item["intent_id"] for item in kept], ["ore_refinery", "tank"])
        self.assertFalse(dropped)

    def test_hq_cannot_spend_its_future_facility_budget(self):
        state = {"campaign_state": {"economy_bootstrap": {"status": "anchor_needed"}}}
        kept, dropped = self.budget(state, [intent("command_center")], 1200,
                                    tac(unit("worker")))
        self.assertFalse(kept)
        self.assertEqual(dropped[0]["available"], {"A": 300})

    def test_player_reserves_always_apply_to_essential_projects(self):
        kept, _ = self.budget({}, [intent("ore_refinery")], 1000,
                              tac(unit("worker")), reserve=200)
        self.assertFalse(kept)

    def test_committed_projects_are_not_reserved_twice(self):
        pending = intent("ore_refinery")
        pending["state"] = "pending_authority"
        state = {"active_intents": [pending]}
        kept, dropped = self.budget(state, [intent("tank", "produce")], 1400,
                                    tac(unit("worker"), unit("vehicle_factory")))
        self.assertEqual(len(kept), 1)
        self.assertFalse(dropped)

    def test_accepted_paid_build_keeps_correct_identity_without_double_charge(self):
        paid = intent("ore_refinery")
        paid["state"] = "active"
        state = {"active_intents": [paid]}
        boot.observe_build_receipt(state, paid, {"accepted": True, "status": "Accepted"},
                                   rules=RULES, tactical=tac())
        self.assertEqual(paid["building_type"], "ore_refinery")
        kept, dropped = self.budget(state, [intent("tank", "produce")], 500,
                                    tac(unit("worker"), unit("vehicle_factory")))
        self.assertEqual(len(kept), 1)
        self.assertFalse(dropped)

    def test_worker_producer_cost_comes_from_real_relation(self):
        changed = copy.deepcopy(RULES)
        changed["constructions"][2]["id"] = "barracks"
        changed["productions"][0]["allowed_producer_type_ids"] = ["barracks"]
        projects = boot.protected_projects({}, rules=changed, tactical=tac())
        self.assertEqual(projects["build:barracks"], {"A": 400})
        self.assertNotIn("build:vehicle_factory", projects)


if __name__ == "__main__":
    unittest.main()
