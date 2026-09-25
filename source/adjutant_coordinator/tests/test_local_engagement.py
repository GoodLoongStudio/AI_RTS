# -*- coding: utf-8 -*-
"""局部战力判断取代"遇敌即停"（计划 §4.1 / U2；审查 F03、F05 的正面断言）。

要钉住的四条（都是**行为级**判据，不是"函数返回非空"）：
① **工人不是威胁**：路径上放一个敌方工人 → 允许推进（旧口径它与一辆坦克同分、同样拦停）；
② **劣势不硬打**：己方 1 个兵、敌方 3 个兵在接触圈内 → 拦停（`threat_too_high`）；
③ **优势可接敌**：己方 4 个兵、敌方 1 个兵 → 放行（"优势进攻允许沿合法路径进入交战距离"）；
④ **远方友军不算支援**：把 3 个"友军"放在 200m 外，局部仍算劣势 → 依然拦停。
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph import movement as mv  # noqa: E402
from adjutant_coordinator.tests.test_safe_movement import nav_ok, tactical, unit  # noqa: E402

COMBAT = ("soldier", "tank", "helicopter", "apc", "heavy_tank")
TARGET = [24.0, 7.0]


def plan_with(entities, *, role=mv.ROLE_MAIN, state_extra=None):
    state = {"map_bounds": [50, 50], "server_tick": 600,
             "combat_types": list(COMBAT)}
    state.update(state_extra or {})
    return mv.plan_safe_route(state, tactical(entities), unit="Unit_1", target=TARGET,
                              tick=600, role=role,
                              nav_query=nav_ok([[10, 7], [17, 7], [24, 7]]))


def own(name, unit_type, pos, **flags):
    entry = unit(name, unit_type, pos)
    entry.update(flags)
    return entry


def foe(name, pos, unit_type="soldier", hp=100.0, hp_max=100.0):
    """敌方实体（`op=tactical` 的形状：`kind=unit_enemy` 且带 hp/hp_max）。"""
    return {"kind": "unit_enemy", "name": name, "unit_type": unit_type,
            "pos": [float(pos[0]), 0.0, float(pos[1])], "hp": float(hp),
            "hp_max": float(hp_max), "confirmed_dead": False}


class LocalEngagementTest(unittest.TestCase):
    def test_enemy_worker_is_not_a_threat(self):
        """无武器目标不按等价战斗单位计数 → 优势方不该被一个工人逼停。"""
        entities = [own("Unit_1", "soldier", (10, 7))]
        entities += [own("Unit_%d" % (10 + i), "soldier", (11 + i, 7)) for i in range(3)]
        entities.append(foe("E_worker", (18, 7), unit_type="worker"))
        plan = plan_with(entities)
        self.assertTrue(plan.ok, "工人不该拦停推进（拒绝原因=%s）" % plan.reason)
        self.assertEqual(plan.local_enemy, 0.0, "工人不计入敌方战力")

    def test_local_disadvantage_blocks(self):
        """局部劣势（1 对 3）→ 不推进（`threat_too_high`，交由降级动作撤离/集结）。"""
        entities = [own("Unit_1", "soldier", (10, 7))]
        entities += [foe("E_%d" % i, (18 + i, 7), unit_type="soldier") for i in range(3)]
        plan = plan_with(entities)
        self.assertFalse(plan.ok)
        self.assertEqual(plan.reason, mv.REJECT_THREAT)
        self.assertGreater(plan.local_enemy, plan.local_own)

    def test_local_advantage_allows_engagement(self):
        """优势（4 对 1）→ 允许沿合法路径进入交战距离。"""
        entities = [own("Unit_%d" % i, "soldier", (10 + i, 7)) for i in range(4)]
        entities.append(foe("E_1", (18, 7), unit_type="soldier"))
        plan = plan_with(entities)
        self.assertTrue(plan.ok, "4 打 1 还被逼停（原因=%s）" % plan.reason)
        self.assertGreaterEqual(plan.local_own / max(0.001, plan.local_enemy),
                                mv.ENGAGE_ADVANTAGE_RATIO)

    def test_distant_friendlies_do_not_count_as_support(self):
        """远方友军不算即时支援：200m 外的 3 个兵救不了眼前的 1 对 2。"""
        entities = [own("Unit_1", "soldier", (10, 7))]
        entities += [own("Far_%d" % i, "soldier", (210 + i, 210)) for i in range(3)]
        entities += [foe("E_%d" % i, (18 + i, 7), unit_type="soldier") for i in range(2)]
        plan = plan_with(entities)
        self.assertFalse(plan.ok, "远方友军被当成了即时支援")
        self.assertLessEqual(plan.local_own, 1.0)

    def test_scout_avoids_losing_fight(self):
        """【2026-09-22 D14 重新钉】侦察不再"见敌就停"，但**明显以卵击石仍然拦**。

        用户明确要求"很快发现敌家位置"——旧口径"路径上有任何敌人就停"让侦察
        永远摸不到敌家（敌家本就在防御圈里），v6 轮 5 局只有 1 局看见敌家。
        新纪律：局部战力 ≥ `SCOUT_ENGAGE_RATIO`（0.5）即放行，用一条便宜单位
        换情报；只有对面有我方两倍以上战力才撤。
        """
        entities = [own("Unit_1", "soldier", (10, 7))]
        entities += [foe("E_%d" % i, (18 + i, 7), unit_type="soldier") for i in range(3)]
        plan = plan_with(entities, role=mv.ROLE_SCOUT)
        self.assertFalse(plan.ok, "1 个侦察撞 3 个敌兵仍必须拦（保命）")
        self.assertEqual(plan.reason, mv.REJECT_THREAT)

    def test_scout_passes_when_not_outmatched(self):
        """D14：不是明显劣势 → 侦察放行（"看见敌家"是它的职责）。"""
        entities = [own("Unit_1", "soldier", (10, 7))]
        entities += [own("Unit_%d" % i, "soldier", (11 + i, 7)) for i in range(3)]
        entities.append(foe("E_1", (18, 7), unit_type="soldier"))
        plan = plan_with(entities, role=mv.ROLE_SCOUT)
        self.assertTrue(plan.ok, "4 打 1 的局面侦察必须能摸过去：%s" % plan.reason)

    def test_scout_passes_static_only_threat(self):
        """D14：路径上只有静态威胁（炮塔/建筑，foe=0）→ 一律放行。

        炮塔不会追击，而"看见敌家"正是侦察的职责——旧口径把它们当成
        "路径附近有敌人"把侦察拦在门外。
        """
        entities = [own("Unit_1", "drone", (10, 7))]
        entities.append(foe("E_turret", (18, 7), unit_type="anti_ground_turret"))
        plan = plan_with(entities, role=mv.ROLE_SCOUT)
        self.assertTrue(plan.ok, "只有炮塔挡路时侦察必须能过去：%s" % plan.reason)

    def test_worker_then_threat_combo_flips(self):
        """T05：先遇工人放行，换成有威胁组合后按战力拦停。"""
        own_side = [own("Unit_%d" % i, "soldier", (10 + i, 7)) for i in range(4)]
        worker_plan = plan_with(own_side + [foe("E_worker", (18, 7), unit_type="worker")])
        self.assertTrue(worker_plan.ok, "无武器工人不该逼退优势小队")
        threat_plan = plan_with([own("Unit_1", "soldier", (10, 7))] + [
            foe("E_%d" % i, (18 + i, 7), unit_type="soldier") for i in range(3)])
        self.assertFalse(threat_plan.ok)
        self.assertEqual(threat_plan.reason, mv.REJECT_THREAT)

    def test_reinforcements_entering_radius_flip_decision(self):
        """T06：远方友军不算支援；进入接触圈后局部战力翻转。"""
        entities = [own("Unit_1", "soldier", (10, 7))]
        entities += [own("Far_%d" % i, "soldier", (210 + i, 210)) for i in range(3)]
        entities += [foe("E_%d" % i, (18 + i, 7), unit_type="soldier") for i in range(2)]
        far = plan_with(entities)
        self.assertFalse(far.ok)
        near = [own("Unit_1", "soldier", (10, 7))]
        near += [own("Near_%d" % i, "soldier", (12 + i, 7)) for i in range(3)]
        near += [foe("E_%d" % i, (18 + i, 7), unit_type="soldier") for i in range(2)]
        close = plan_with(near)
        self.assertTrue(close.ok, "援军进入接触圈后应能接敌：%s" % close.reason)

    def test_no_enemy_still_allows_advance(self):
        """对照组：没有敌人时照旧放行（别把闸门改成"永远不放行"）。"""
        entities = [own("Unit_1", "soldier", (10, 7))]
        plan = plan_with(entities)
        self.assertTrue(plan.ok)

    def test_committed_reinforcements_flip_decision(self):
        """T07（2026-09-21 集结修复）：受命开往这一仗的单位算即时战力。

        没有这一条时大军会被逐个评估：每个单位只看得见**已经进圈**的战友，
        永远凑不齐 `ENGAGE_ADVANTAGE_RATIO`，整支部队卡在威胁圈外缘
        （v11 实测 413 次推进只放行 56 次、`threat_too_high` 拦 222 次，
        90:31 的优势兵力超时亡）。路线台账里 target 落在战区敌人接触圈内的
        单位就是"正在赶来打这一仗"的部队，必须计入。
        """
        entities = [own("Unit_1", "soldier", (10, 7))]
        entities += [foe("E_%d" % i, (18 + i, 7), unit_type="soldier") for i in range(2)]
        # 3 个战友人还在 50m 外（**不在**接触圈内），但受命开往敌人所在处。
        routes = {}
        for i in range(3):
            name = "Ref_%d" % i
            routes[name] = {"ok": True, "target": [18.0 + i, 7.0]}
            entities.append(own(name, "soldier", (60 + i, 60)))
        plan = plan_with(entities, state_extra={"routes": routes})
        self.assertTrue(plan.ok, "受命赶来的援军应让局部战力翻转：%s" % plan.reason)
        self.assertGreaterEqual(plan.local_own, 3.0)

    def test_routed_elsewhere_still_not_support(self):
        """T08：有路线但 target 不在战区 → 仍然不算支援（别把"赶来"搞成"存在就算"）。"""
        entities = [own("Unit_1", "soldier", (10, 7))]
        entities += [foe("E_%d" % i, (18 + i, 7), unit_type="soldier") for i in range(2)]
        routes = {}
        for i in range(3):
            name = "Elsewhere_%d" % i
            routes[name] = {"ok": True, "target": [80.0 + i, 80.0]}
            entities.append(own(name, "soldier", (60 + i, 60)))
        plan = plan_with(entities, state_extra={"routes": routes})
        self.assertFalse(plan.ok, "开往别处的部队不该算这一仗的支援")
        self.assertEqual(plan.reason, mv.REJECT_THREAT)


if __name__ == "__main__":
    unittest.main()
