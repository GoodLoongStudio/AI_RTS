# -*- coding: utf-8 -*-
"""经济恢复入口与里程碑测试（第一阶段 · 修改 3）。

按实施提示词的正反场景表逐项覆盖：
1. 原案例（6 工人、M01 done、矿场失败、零交货）→ 能进异常诊断，不被旧条件屏蔽；
2. 从未受袭但关键经济链失败 → 识别与恢复评估不依赖 under_attack_total；
3. 正常开局未首次交货但有进展 → 合理等待，不误报、不循环重建；
4. 收入支出同时发生、余额不变 → 按交货证据判断，不误判零收入；
5. 采集命令 Accepted 但无交货 → 任务分配成立，不等于经济链已建立；
6. 曾经交货后链中断 → 历史完成不篡改，当前异常仍触发恢复；
7. 受袭且工人不足 → 保留原恢复场景行为；
8. 零工人/无建造者/资源不足 → 不生成非法动作，给替代或明确受阻；
9. 恢复后实际交货且持续进展 → 异常解除，不每轮重复下单。
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph import campaign as cm
from adjutant_coordinator.graph import economy_recovery as er


def base_campaign(**overrides):
    campaign = cm.default_campaign(tick=0)
    campaign.update(overrides)
    return campaign


def facts(**overrides):
    data = {
        "workers": ["Unit_w%d" % i for i in range(6)],
        "builders": ["Unit_w0"], "producers": [], "resource_count": 2,
        "refinery_constructed": 0, "refinery_delivered": 0,
        "refinery_delivered_amount": 0,
        "constructed": {}, "counts": {},
        "balance": {"A": 100},
        "accepted_actions": {"gather": 1}, "accepted_prefixes": {"rule-gather": 1},
        "content_rejected_prefixes": {}, "rejected_prefixes": {},
    }
    data.update(overrides)
    return data


def state_with(**overrides):
    state = {"measured_tick_hz": 20.0, "task_ledger_feedback": {}}
    state.update(overrides)
    return state


def detect_rounds(campaign, data, ticks, config, state=None):
    """按轮次调用 detect（时间窗判据必须跨轮：第一轮记基线，窗口过后才判）。"""
    state = state or state_with()
    return [er.detect(campaign, data, state=state, tick=tick, config=config)
            for tick in ticks]


class OriginalCaseTest(unittest.TestCase):
    """原案例：6 工人、M01 done、矿场任务失败、零交货。"""

    def test_original_case_enters_diagnosis_not_blocked_by_old_condition(self):
        campaign = base_campaign()
        campaign["milestones"]["M01"]["status"] = "done"      # M01 已完成（旧样本）
        campaign["milestones"]["M01"]["done_tick"] = 914
        campaign["milestones"]["M08"]["status"] = "blocked"   # 矿场任务失败
        campaign["milestones"]["M08"]["blocked_reason"] = "rule-build-ore_refinery 连续被拒"
        # 关闭宽限与时间窗，让事实型异常立即可判。
        data = facts(refinery_constructed=1, refinery_delivered=0,
                     content_rejected_prefixes={"rule-build-ore_refinery": 2})
        config = {"econ_grace_seconds": 0.001, "econ_delivery_stall_seconds": 0.001}
        anomaly = detect_rounds(campaign, data, [100, 200], config)[-1]
        self.assertTrue(anomaly["active"], "原案例必须能进入经济异常诊断")
        self.assertIn(er.ANOMALY_TASK_FAILED, anomaly["kinds"])
        self.assertIn(er.ANOMALY_DELIVERY_STALL, anomaly["kinds"])
        # 旧两项条件（受袭/工人）不参与屏蔽：没有受袭也识别。
        self.assertEqual(anomaly["evidence"]["under_attack_total"], 0)
        plan = er.recovery_plan(campaign, data, state=state_with())
        self.assertTrue(plan["entry_open"])
        self.assertTrue(plan["actions"])
        executable = [item for item in plan["actions"] if item["preconditions_met"]]
        self.assertTrue(executable, "原案例应有可执行恢复分支（派工人去采矿）")


class NoAttackRequiredTest(unittest.TestCase):
    """从未受袭，但关键经济链失败。"""

    def test_unit_loss_without_attack_is_recognized(self):
        campaign = base_campaign()
        data = facts(workers=["Unit_w0"], resource_count=1)
        anomaly = er.detect(campaign, data, state=state_with(), tick=100000,
                            config={"econ_grace_seconds": 0.001})
        self.assertTrue(anomaly["active"])
        self.assertIn(er.ANOMALY_UNIT_LOSS, anomaly["kinds"])
        self.assertEqual(anomaly["evidence"]["under_attack_total"], 0)

    def test_content_rejection_without_attack_is_recognized(self):
        campaign = base_campaign()
        data = facts(content_rejected_prefixes={"rule-build-vehicle_factory": 3})
        anomaly = er.detect(campaign, data, state=state_with(), tick=10)
        self.assertTrue(anomaly["active"])
        self.assertIn(er.ANOMALY_TASK_FAILED, anomaly["kinds"])


class NormalOpeningTest(unittest.TestCase):
    """正常开局：尚未第一次交货但持续有进展。"""

    def test_opening_with_progress_is_not_anomaly(self):
        campaign = base_campaign()
        data = facts(refinery_constructed=0, refinery_delivered=0)
        # 开局早期（宽限内）+ 工地未出现：正常等待。
        anomaly = er.detect(campaign, data, state=state_with(), tick=10,
                            config={"econ_grace_seconds": 600.0})
        self.assertFalse(anomaly["active"])
        self.assertEqual(anomaly["evidence"]["in_grace"], True)

    def test_built_refinery_recently_is_not_stall(self):
        campaign = base_campaign()
        data = facts(refinery_constructed=1, refinery_delivered=0)
        anomaly = er.detect(campaign, data, state=state_with(), tick=10,
                            config={"econ_grace_seconds": 600.0,
                                    "econ_delivery_stall_seconds": 90.0})
        self.assertFalse(anomaly["active"], "刚完工的矿场必须给正常等待窗口")

    def test_construction_progress_resets_stall_window(self):
        campaign = base_campaign()
        state = state_with()
        config = {"econ_grace_seconds": 0.001, "econ_delivery_stall_seconds": 0.001}
        data = facts(refinery_constructed=1, refinery_delivered=0,
                     counts={"barracks": 1})
        # 第一轮记基线；第二轮窗口已过 → 停滞成立。
        results = detect_rounds(campaign, data, [100, 200], config, state)
        self.assertTrue(results[-1]["active"])
        self.assertIn(er.ANOMALY_DELIVERY_STALL, results[-1]["kinds"])
        # 施工进展变化（新工地出现）→ 停滞窗口刷新，不再判停滞。
        data2 = facts(refinery_constructed=1, refinery_delivered=0,
                      counts={"barracks": 1, "vehicle_factory": 1})
        anomaly = er.detect(campaign, data2, state=state, tick=210, config=config)
        self.assertNotIn(er.ANOMALY_DELIVERY_STALL, anomaly["kinds"])


class IncomeVersusBalanceTest(unittest.TestCase):
    """收入和支出同时发生，余额不变 → 按交货证据判断。"""

    def test_flat_balance_with_deliveries_is_healthy(self):
        campaign = base_campaign()
        state = state_with()
        data = facts(refinery_constructed=1, refinery_delivered=5,
                     balance={"A": 100})
        # 先记基线（上一轮同样余额）。
        er.detect(campaign, data, state=state, tick=1000,
                  config={"econ_grace_seconds": 0.001,
                          "econ_post_delivery_stall_seconds": 0.001})
        # 余额不变但交付计数在涨 → 健康（收入正在发生，只是同时在支出）。
        data2 = facts(refinery_constructed=1, refinery_delivered=6,
                      balance={"A": 100})
        anomaly = er.detect(campaign, data2, state=state, tick=1100,
                            config={"econ_grace_seconds": 0.001,
                                    "econ_post_delivery_stall_seconds": 0.001})
        self.assertFalse(anomaly["active"],
                         "交货计数在涨就不是零收入——余额不变是支出同时发生")

    def test_flat_delivery_and_balance_is_post_delivery_stall(self):
        campaign = base_campaign()
        state = state_with()
        config = {"econ_grace_seconds": 0.001, "econ_post_delivery_stall_seconds": 0.001}
        data = facts(refinery_constructed=1, refinery_delivered=5,
                     balance={"A": 100})
        # 第一轮记基线；第二轮起"三者都不变"开始累计；第三轮窗口已过。
        results = detect_rounds(campaign, data, [1000, 2000, 3000], config, state)
        anomaly = results[-1]
        self.assertTrue(anomaly["active"])
        self.assertIn(er.ANOMALY_POST_DELIVERY_STALL, anomaly["kinds"])


class AssignedVersusEstablishedTest(unittest.TestCase):
    """采集命令 Accepted ≠ 经济链已建立（M01 语义审计）。"""

    def test_m01_requires_delivery_not_gather_receipt(self):
        state = {"command_receipts": [{
            "status": "Accepted", "accepted": True, "action": "gather",
            "intent_id": "rule-gather-Unit_1-100"}]}
        campaign = cm.default_campaign(tick=0)
        data = facts(workers=["Unit_1"], resource_count=1)
        observation = {"tactical": {"entities": [
            {"kind": "unit_self", "name": "Unit_1", "unit_type": "worker",
             "pos": [1.0, 0.0, 1.0], "hp": 100.0, "hp_max": 100.0,
             "gather": True, "queue": False, "construct": False},
        ], "balance": {"a": 100}, "production": [], "outcome": {"finished": False}}}
        cm.update(state, observation, 60)
        entry = state["campaign_state"]["milestones"]["M01"]
        self.assertNotEqual(entry["status"], "done",
                            "采集命令被接受只证明任务已分配，不完成 M01")
        self.assertTrue(state["campaign_state"]["economy_assigned"])
        self.assertFalse(state["campaign_state"]["economy_established"])
        # 出现真实交付 → M01 完成，证据含"交付"。
        observation["tactical"]["entities"].append({
            "kind": "unit_self", "name": "Unit_ref", "unit_type": "ore_refinery",
            "pos": [8.0, 0.0, 8.0], "hp": 100.0, "hp_max": 100.0,
            "constructed": True, "queue": False, "gather": False, "construct": False,
            "refinery": {"constructed": True, "delivered_count": 1,
                         "delivered_amount": 50, "assigned": 1},
        })
        cm.update(state, observation, 180)
        entry = state["campaign_state"]["milestones"]["M01"]
        self.assertEqual(entry["status"], "done")
        self.assertIn("交付", entry["last_evidence"])

    def test_done_m01_is_not_rewritten_by_later_stall(self):
        """历史完成事实保留：M01 done 之后经济中断改的是异常/健康状态。"""
        state = {}
        campaign = cm.default_campaign(tick=0)
        campaign["milestones"]["M01"]["status"] = "done"
        campaign["milestones"]["M01"]["done_tick"] = 914
        data = facts(refinery_constructed=1, refinery_delivered=0)
        config = {"econ_grace_seconds": 0.001, "econ_delivery_stall_seconds": 0.001}
        anomaly = detect_rounds(campaign, data, [100, 200], config)[-1]
        # M01 done 不屏蔽后续经济中断（曾交货/已建成后的停滞仍可触发）。
        self.assertTrue(anomaly["active"])
        self.assertEqual(campaign["milestones"]["M01"]["status"], "done")


class AttackRecoveryPreservedTest(unittest.TestCase):
    """受袭且工人不足 → 保留原恢复场景的正确行为。"""

    def test_attack_condition_still_opens_recovery(self):
        campaign = base_campaign(under_attack_total=3)
        campaign["milestones"]["M01"]["status"] = "pending"
        data = facts(workers=["Unit_w0"])
        anomaly = er.detect(campaign, data, state=state_with(), tick=10)
        self.assertTrue(anomaly["active"])
        self.assertIn(er.ANOMALY_ATTACK, anomaly["kinds"])
        plan = er.recovery_plan(campaign, data, state=state_with())
        defend = [item for item in plan["actions"]
                  if item["action"] == "defend_and_regather"]
        self.assertTrue(defend, "受袭场景必须保留防守+恢复采集的动作")

    def test_attack_flag_recorded_for_compat(self):
        campaign = base_campaign(under_attack_total=1)
        campaign["milestones"]["M01"]["status"] = "pending"
        data = facts(workers=["Unit_w0"])
        er.detect(campaign, data, state=state_with(), tick=10)
        self.assertTrue(campaign["needs_recovery_attack"])


class BlockedAlternativesTest(unittest.TestCase):
    """零工人/无建造者/资源不足 → 不生成非法动作；替代或明确受阻。"""

    def test_zero_workers_blocks_with_missing_and_alternative(self):
        campaign = base_campaign()
        data = facts(workers=[], resource_count=0, producers=[])
        anomaly = er.detect(campaign, data, state=state_with(), tick=100000,
                            config={"econ_grace_seconds": 0.001})
        self.assertTrue(anomaly["active"])
        plan = er.recovery_plan(campaign, data, state=state_with())
        self.assertFalse(plan["executable"], "零工人零资源不得给出可执行动作")
        self.assertTrue(plan["blocked_missing"])
        self.assertIn("没有可执行恢复动作", plan["blocked_reason"])
        # 有产能建筑时给"生产工人"的替代路线。
        data2 = facts(workers=[], resource_count=0, producers=["Unit_f"])
        plan2 = er.recovery_plan(campaign, data2, state=state_with())
        actions = {item["action"] for item in plan2["actions"]}
        self.assertIn("produce_worker", actions)

    def test_no_builder_no_funds_blocks_rebuild(self):
        campaign = base_campaign()
        data = facts(builders=[], balance={"A": 0},
                     content_rejected_prefixes={"rule-build-ore_refinery": 1})
        anomaly = er.detect(campaign, data, state=state_with(), tick=10)
        plan = er.recovery_plan(campaign, data, state=state_with())
        rebuild = [item for item in plan["actions"]
                   if item["action"] == "rebuild_refinery"]
        self.assertTrue(rebuild)
        self.assertFalse(rebuild[0]["preconditions_met"])
        self.assertIn("没有可建造的工人", rebuild[0]["missing"])
        self.assertTrue(any("资金不足" in item for item in rebuild[0]["missing"]))

    def test_facility_loss_triggers_rebuild(self):
        campaign = base_campaign()
        state = state_with()
        config = {"econ_grace_seconds": 0.001}
        data = facts(refinery_constructed=1, refinery_delivered=3,
                     counts={"ore_refinery": 1})
        er.detect(campaign, data, state=state, tick=1000, config=config)
        data2 = facts(refinery_constructed=0, refinery_delivered=3, counts={})
        anomaly = er.detect(campaign, data2, state=state, tick=1100, config=config)
        self.assertIn(er.ANOMALY_FACILITY_LOSS, anomaly["kinds"])


class PersistentLossAndSpendingTest(unittest.TestCase):
    """R5/R6 返修回归（独立复核反例）。"""

    def test_unit_loss_stays_active_until_recovery(self):
        """R5：6→0→0 工人，损失必须持续到工人恢复，不能只报一轮。"""
        campaign = base_campaign()
        state = state_with()
        config = {"econ_grace_seconds": 0.001}
        lost = facts(workers=[], resource_count=1)
        results = detect_rounds(campaign, lost, [100, 101, 102, 103], config, state)
        for row in results:
            self.assertTrue(row["active"], "工人持续为 0 时异常必须保持激活")
            self.assertIn(er.ANOMALY_UNIT_LOSS, row["kinds"])
        # 工人恢复 → 解除。
        recovered = facts(workers=["Unit_w0", "Unit_w1"], resource_count=1)
        row = er.detect(campaign, recovered, state=state, tick=104, config=config)
        self.assertNotIn(er.ANOMALY_UNIT_LOSS, row["kinds"])

    def test_facility_loss_stays_active_until_rebuilt(self):
        """R5：矿场 1→0→0，损失持续到矿场重建。"""
        campaign = base_campaign()
        state = state_with()
        config = {"econ_grace_seconds": 0.001}
        before = facts(refinery_constructed=1, refinery_delivered=3,
                       counts={"ore_refinery": 1})
        er.detect(campaign, before, state=state, tick=1000, config=config)
        lost = facts(refinery_constructed=0, refinery_delivered=3, counts={})
        results = detect_rounds(campaign, lost, [1100, 1200, 1300], config, state)
        for row in results:
            self.assertIn(er.ANOMALY_FACILITY_LOSS, row["kinds"],
                          "矿场持续为 0 时设施损失必须保持")
        rebuilt = facts(refinery_constructed=1, refinery_delivered=3,
                        counts={"ore_refinery": 1})
        row = er.detect(campaign, rebuilt, state=state, tick=1400, config=config)
        self.assertNotIn(er.ANOMALY_FACILITY_LOSS, row["kinds"])

    def test_spending_does_not_mask_delivery_stall(self):
        """R6：持续花钱（余额下降）不得把收入中断洗成"有变化"。"""
        campaign = base_campaign()
        state = state_with()
        config = {"econ_grace_seconds": 0.001,
                  "econ_post_delivery_stall_seconds": 0.001}
        stalled = facts(refinery_constructed=1, refinery_delivered=3,
                        balance={"A": 1000})
        er.detect(campaign, stalled, state=state, tick=1000, config=config)
        # 之后每轮花 100：交付数与施工都不变，只有余额在降。
        for index, balance in enumerate((900, 800, 700, 600, 500)):
            spending = facts(refinery_constructed=1, refinery_delivered=3,
                             balance={"A": balance})
            row = er.detect(campaign, spending, state=state, tick=1100 + index * 10,
                            config=config)
        self.assertIn(er.ANOMALY_POST_DELIVERY_STALL, row["kinds"],
                      "持续支出但没有新交货：必须报收入中断")
        # 对照：交付数在涨 → 健康。
        earning = facts(refinery_constructed=1, refinery_delivered=4,
                        balance={"A": 500})
        row2 = er.detect(campaign, earning, state=state, tick=2000, config=config)
        self.assertNotIn(er.ANOMALY_POST_DELIVERY_STALL, row2["kinds"])


class RecoveryClearsTest(unittest.TestCase):
    """恢复后观察到实际交货和持续进展 → 异常解除，不每轮重复下单。"""

    def test_delivery_resumes_clears_anomaly(self):
        campaign = base_campaign()
        state = state_with()
        stalled = facts(refinery_constructed=1, refinery_delivered=0,
                        content_rejected_prefixes={"rule-build-ore_refinery": 2})
        er.detect(campaign, stalled, state=state, tick=100000,
                  config={"econ_grace_seconds": 0.001,
                          "econ_delivery_stall_seconds": 0.001})
        self.assertTrue(campaign["economy_anomaly"]["active"])
        # 恢复后：交付恢复 + 持续进展。
        recovered = facts(refinery_constructed=1, refinery_delivered=4)
        anomaly = er.detect(campaign, recovered, state=state, tick=100100,
                            config={"econ_grace_seconds": 0.001,
                                    "econ_delivery_stall_seconds": 0.001})
        self.assertFalse(anomaly["active"], "交货恢复后异常必须解除")
        self.assertEqual(campaign["anomaly_since"], 0)

    def test_anomaly_is_sticky_within_window_not_every_round(self):
        """停滞窗口内不闪烁：异常一旦激活，条件恢复前保持 active。"""
        campaign = base_campaign()
        state = state_with()
        data = facts(refinery_constructed=1, refinery_delivered=0)
        config = {"econ_grace_seconds": 0.001, "econ_delivery_stall_seconds": 90.0}
        er.detect(campaign, data, state=state, tick=100, config=config)
        self.assertFalse(campaign["economy_anomaly"]["active"])
        er.detect(campaign, data, state=state, tick=2000, config=config)
        self.assertTrue(campaign["economy_anomaly"]["active"])
        # 窗口内的后续轮不重复报（since_tick 保持首次激活点）。
        since = campaign["anomaly_since"]
        er.detect(campaign, data, state=state, tick=2100, config=config)
        self.assertEqual(campaign["anomaly_since"], since)


class LoopFeedbackTriggersAnomalyTest(unittest.TestCase):
    """闭环台账反馈（含诊断/恢复中）必须能打开经济异常入口。

    round-03 真机闸门实测：矿场任务 56 次无进展 + 3 次恢复尝试，反馈长期停在
    diagnosing，旧判据（只认 at_risk/blocked）漏报——经济链断了却进不了恢复。
    """

    def test_diagnosing_feedback_opens_anomaly(self):
        campaign = base_campaign()
        state = state_with(task_ledger_feedback={
            "M08": {"state": "diagnosing", "task_id": "rule-build-ore_refinery",
                    "reason_code": "no_progress_limit",
                    "reason_cn": "无进展已达期限（1218/1200 tick，指标 已完工 ore_refinery=0）"}})
        anomaly = er.detect(campaign, facts(), state=state, tick=3000)
        self.assertTrue(anomaly["active"])
        self.assertIn(er.ANOMALY_TASK_FAILED, anomaly["kinds"])
        self.assertIn("诊断中", anomaly["reasons_cn"][0])

    def test_recovering_feedback_opens_anomaly(self):
        campaign = base_campaign()
        state = state_with(task_ledger_feedback={
            "M01": {"state": "recovering", "task_id": "rule-gather",
                    "reason_code": "recovery_attempt", "reason_cn": "按预算恢复（第 2 次尝试）"}})
        anomaly = er.detect(campaign, facts(), state=state, tick=3000)
        self.assertTrue(anomaly["active"])

    def test_progressed_feedback_does_not_open_anomaly(self):
        campaign = base_campaign()
        state = state_with(task_ledger_feedback={
            "M08": {"state": "progressed", "task_id": "rule-build-ore_refinery",
                    "reason_code": "success_evidence", "reason_cn": "成功判据达成"}})
        anomaly = er.detect(campaign, facts(), state=state, tick=3000)
        self.assertFalse(anomaly["active"])

    def test_build_backoff_blocks_rebuild_action(self):
        """连续被拒的建造退避期内，重建动作必须判不可执行（缺项写明）。"""
        campaign = base_campaign()
        campaign["economy_anomaly"] = {"active": True, "kind": er.ANOMALY_TASK_FAILED,
                                       "kinds": [er.ANOMALY_TASK_FAILED],
                                       "reasons_cn": ["关键经济任务失败"]}
        state = state_with(server_tick=1000, build_backoff_until_tick=2800)
        plan = er.recovery_plan(campaign, facts(builders=["Unit_w"], balance={"A": 500}),
                                state=state)
        rebuild = [item for item in plan["actions"]
                   if item["action"] == "rebuild_refinery"][0]
        self.assertFalse(rebuild["preconditions_met"])
        self.assertTrue(any("建造退避" in item for item in rebuild["missing"]))


class ContextConsistencyTest(unittest.TestCase):
    """入口计算、候选列表、模型菜单、执行门禁、回放解释一致。"""

    def test_needs_recovery_opens_d2_in_retrieve(self):
        from adjutant_coordinator.graph import decision_map
        campaign = base_campaign()
        campaign["needs_recovery"] = True
        data = facts(workers=["Unit_w0", "Unit_w1"])
        retrieved = decision_map.retrieve(data, campaign)
        available = {str(item["id"]) for item in retrieved["available"]}
        self.assertIn("D2", available, "needs_recovery 且 has_worker 时 D2 必须可选")
        # 零工人 → D2 锁定，缺项写明。
        campaign_zero = base_campaign()
        campaign_zero["needs_recovery"] = True
        retrieved_zero = decision_map.retrieve(facts(workers=[]), campaign_zero)
        locked = {str(item["id"]): item for item in retrieved_zero["locked"]}
        self.assertIn("D2", locked)
        self.assertIn("有可用工人", locked["D2"]["unmet"])

    def test_condition_report_has_values_and_missing(self):
        from adjutant_coordinator.graph import decision_map
        campaign = base_campaign()
        report = decision_map.condition_report(decision_map.NODE_BY_ID["D2"],
                                               facts(), campaign)
        by_name = {item["name"]: item for item in report}
        self.assertIn("needs_recovery", by_name)
        self.assertIn("has_worker", by_name)
        for item in report:
            self.assertIn("value", item)
            self.assertIn("result", item)
            self.assertIn("missing", item)

    def test_model_context_carries_anomaly_and_plan(self):
        state = {}
        campaign = base_campaign()
        campaign["needs_recovery"] = True
        campaign["economy_anomaly"] = {"active": True, "kind": er.ANOMALY_DELIVERY_STALL,
                                       "kinds": [er.ANOMALY_DELIVERY_STALL],
                                       "reasons_cn": ["矿场已完工但零交付"]}
        campaign["economy_recovery_plan"] = {
            "entry_open": True, "executable": True,
            "actions": [{"action": "assign_gather", "skill": "GAT",
                         "target": "resource", "preconditions_met": True,
                         "missing": []}],
            "blocked_missing": []}
        state["campaign_state"] = campaign
        view = cm.context_view(campaign) if hasattr(cm, "context_view") else {}
        economy = view.get("economy") or {}
        self.assertTrue(economy.get("anomaly_active"))
        self.assertEqual(economy.get("anomaly_kind"), er.ANOMALY_DELIVERY_STALL)
        self.assertTrue(economy.get("recovery_executable"))
        self.assertEqual(economy.get("recovery_actions"), ["assign_gather"])
        self.assertTrue(economy.get("gather_assigned") in (True, False))


if __name__ == "__main__":
    unittest.main()
