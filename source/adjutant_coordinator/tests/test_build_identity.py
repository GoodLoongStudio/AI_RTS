"""Real failed-S1 boundaries: immutable command IDs and per-site completion."""
import copy
import unittest
from unittest.mock import patch

from adjutant_coordinator.graph import nodes, progress
from adjutant_coordinator.tests.test_task_progress import intent, own, observation, make_state
from adjutant_coordinator.tests.test_intent_arbitration import (
    make_state as arbitration_state, arbitrate, make_intent)

SCENE = "res://source/match/units/CommandCenter.tscn"
RULES = {"constructions": [{"id": "command_center", "blueprint_scene_path": SCENE}]}


class IntentIdentityTest(unittest.TestCase):
    def test_terminal_identity_cannot_be_adopted_again(self):
        for status in ("failed", "completed", "expired", "dropped"):
            state = arbitration_state()
            old = make_intent("same-id", expires_tick=100)
            old["state"] = status
            state.active_intents.append(old)
            result = arbitrate(state, [make_intent("same-id", expires_tick=100)])
            self.assertEqual(result.accepted, [])
            self.assertEqual(result.dropped_reasons["same-id"], "intent_already_tracked")

    def test_program_retry_survives_checkpoint_without_changing_observation(self):
        state = {"server_tick": 514, "match_id": "m", "player_id": "p"}
        known = {"rule-build-ore_refinery-Unit_0-514"}
        original = {"intent_id": next(iter(known)), "issued_tick": 514,
                    "based_on_snapshot": 92, "origin": nodes.ORIGIN_BASELINE}
        first = dict(original)
        nodes._fresh_baseline_identity(state, first, known)
        second = dict(original)
        nodes._fresh_baseline_identity(copy.deepcopy(state), second, known)
        self.assertNotEqual(first["intent_id"], original["intent_id"])
        self.assertNotEqual(first["intent_id"], second["intent_id"])
        self.assertEqual(first["issued_tick"], 514)
        self.assertEqual(first["based_on_snapshot"], 92)
        self.assertEqual(first["origin"], nodes.ORIGIN_BASELINE)


class BuildSiteIdentityTest(unittest.TestCase):
    def _start(self):
        item = intent("new-hq", "build", ["Unit_0"],
                      {"producer": "Unit_0", "scene": SCENE})
        before = observation([own("Unit_0", unit_type="command_center", constructed=True)])
        progress.prepare_build_identity(item, before, RULES)
        return item, make_state([item]), before

    def test_actual_nested_receipt_binds_site_and_old_hq_never_completes_it(self):
        item, state, before = self._start()
        original_target = copy.deepcopy(item["target"])
        progress.capture_build_site(item, {"accepted": True, "status": "Accepted",
            "result": {"result": {"structure": "Unit_2:<Area3D#101>"}}})
        self.assertEqual(item["building_site"], "Unit_2")
        self.assertEqual(item["target"], original_target)
        report = progress.track_task_progress(state, observation=before, tick=515)
        self.assertNotEqual(report["intents"]["new-hq"]["status"], "completed")
        # Automatic construction is judged by the site even if the carrier vanishes.
        for tick, constructed in ((520, False), (600, True)):
            view = observation([own("Unit_2", unit_type="command_center", constructed=constructed)])
            report = progress.track_task_progress(state, observation=view, tick=tick)
            self.assertEqual(report["intents"]["new-hq"]["status"],
                             "completed" if constructed else "in_progress")

    def test_summary_missing_site_does_not_infer_unique_new_building(self):
        item, state, before = self._start()
        report = progress.track_task_progress(state, observation=before, tick=515)
        self.assertNotEqual(report["intents"]["new-hq"]["status"], "completed")
        view = observation(before["tactical"]["entities"] + [
            own("Unit_2", unit_type="command_center", constructed=False)])
        report = progress.track_task_progress(state, observation=view, tick=520)
        self.assertNotIn("building_site", item)
        self.assertEqual(report["intents"]["new-hq"]["status"], "unknown")

    def test_multiple_new_sites_stay_unknown(self):
        item, state, before = self._start()
        view = observation(before["tactical"]["entities"] + [
            own(name, unit_type="command_center", constructed=True)
            for name in ("Unit_2", "Unit_3")])
        report = progress.track_task_progress(state, observation=view, tick=520)
        self.assertEqual(report["intents"]["new-hq"]["status"], "unknown")
        self.assertNotIn("building_site", item)

    def test_worker_site_target_never_uses_another_finished_instance(self):
        item = intent("finish", "build", ["worker"],
                      {"producer": "worker", "entity_id": "pending", "scene": SCENE})
        item["building_type"] = "command_center"
        report = progress.track_task_progress(make_state([item]), observation=observation([
            own("old", unit_type="command_center", constructed=True)]), tick=10)
        self.assertNotEqual(report["intents"]["finish"]["status"], "completed")

    def test_receipt_site_with_wrong_type_stays_unknown(self):
        item, state, before = self._start()
        progress.capture_build_site(item, {"accepted": True,
            "result": {"result": {"structure": "worker:<Area3D#102>"}}})
        view = observation([own("worker", unit_type="worker", constructed=True)])
        report = progress.track_task_progress(state, observation=view, tick=520)
        self.assertEqual(report["intents"]["new-hq"]["status"], "unknown")

    def test_truncated_and_legacy_observations_never_infer_site(self):
        for truncated in (True, False, None):
            item, state, before = self._start()
            item["building_sites_before"] = []  # Old checkpoint metadata is not proof.
            view = observation([own("old-hq", unit_type="command_center", constructed=True)],
                               truncated=truncated)
            report = progress.track_task_progress(state, observation=view, tick=520)
            self.assertEqual(report["intents"]["new-hq"]["status"], "unknown")
            self.assertNotIn("building_site", item)

    def test_parallel_summary_intents_cannot_share_an_inferred_site(self):
        first, _, _ = self._start()
        second = copy.deepcopy(first)
        second["intent_id"] = "second"
        state = make_state([first, second])
        report = progress.track_task_progress(state, observation=observation([
            own("one-new-site", unit_type="command_center", constructed=True)]), tick=520)
        self.assertTrue(all(row["status"] == "unknown" for row in report["intents"].values()))

    def test_exact_worker_continuation_can_share_existing_site(self):
        items = [intent(name, "build", [name], {"producer": name,
                 "entity_id": "existing-site", "scene": SCENE}) for name in ("worker-a", "worker-b")]
        report = progress.track_task_progress(make_state(items), observation=observation([
            own("existing-site", unit_type="command_center", constructed=True)]), tick=520)
        self.assertTrue(all(row["status"] == "completed" for row in report["intents"].values()))


class RunnerRecheckIdentityTest(unittest.TestCase):
    def test_pending_recheck_preserves_authority_site_and_match(self):
        from adjutant_coordinator.deploy import agent_runner as ar
        runner = ar.AgentRunner.__new__(ar.AgentRunner)
        runner.port = 49100
        authority = {"command_id": "cmd", "status": "Accepted", "accepted": True,
                     "match_id": "m", "result": {"result": {"structure": "Unit_2:<Area3D#103>"}}}
        with patch.object(ar, "tcp_json", return_value={"commands": [authority]}):
            receipt = runner._recheck("cmd")
        item = intent("new-hq", "build", ["Unit_0"], {"scene": SCENE})
        progress.capture_build_site(item, receipt)
        self.assertEqual(item["building_site"], "Unit_2")
        self.assertEqual(receipt["match_id"], "m")

    def test_legacy_authority_build_artifact_identity_is_preserved(self):
        from adjutant_coordinator.deploy import agent_runner as ar
        runner = ar.AgentRunner.__new__(ar.AgentRunner)
        runner.port = 49100
        authority = {"command_id": "cmd", "status": "Accepted", "op": "build", "artifact_id": "Unit_2"}
        with patch.object(ar, "tcp_json", return_value={"commands": [authority]}):
            receipt = runner._recheck("cmd")
        item = intent("new-hq", "build", ["Unit_0"], {"scene": SCENE})
        progress.capture_build_site(item, receipt)
        self.assertEqual(item["building_site"], "Unit_2")


if __name__ == "__main__":
    unittest.main()
