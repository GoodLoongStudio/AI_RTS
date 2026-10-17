# -*- coding: utf-8 -*-
"""资源分配：占用账 / 去冲突 / 自愈 的**类级守门测试**（2026-09-12 实机事故）。

用户现场：基地旁边一圈矿，4 个工人却有 3 个挤在同一个矿上，5~7 米外的矿一个都没人用，
而且**不会自己散开**（游戏侧 `CollectingResourcesSequentially` 是"认死一个矿"的循环）。

根因是**一类**结构性缺陷（不是一处 bug）：
① 账本只看得见局部：分配器只统计"本轮新派出去的人"，已上岗的人（busy）不在负载里；
② 同一规则被抄成多份：`_nearest_resource` / `RESOURCE_WORKERS_PER_NODE` 各有两份；
③ 没有反馈/自愈：分配错一次就永久错。

本文件锁死这三件事，防止同类问题再回来：
- 已在采的人必须计入负载（第 N+1 个工人不能进已满矿点）；
- 容量常量与分配算法**只有一处实现**（其他模块只能是 import 或 delegating wrapper）；
- 超员矿点能自愈，且**幂等**（不许 churn：连续两轮不得产生新的重派意图）。
"""

import unittest

from adjutant_coordinator.graph import resource_allocation as ra
from adjutant_coordinator.graph import rules_fallback as rf
from adjutant_coordinator.graph import task_patch as tp

NEAR = {"name": "Res_B", "kind": "B", "pos": [12.5, 0.0, 12.5]}
FAR = {"name": "Res_A", "kind": "A", "pos": [40.0, 0.0, 2.0]}


class ResourceDepletionFieldNamesTest(unittest.TestCase):
    """采空矿点**必须判成不可用** —— 字段名要与游戏实际发的一致（2026-10-09）。

    权威拒绝的是 `ResourceDepleted`。实测（`archive_8c4158d1`）：
    **gather 154 条里 140 条被拒（只有 14 条接受）**，同期 `attack_move` 接受率 98%。
    根因是字段名对不上：游戏发的是 `ore_remaining` / `ore_depleted`
    （见 `DebugControlServer` 的 `ore_entry`、`ResourceUnit.mark_depleted`），
    而旧实现只认 `remaining/amount/stock/left` 与 `depleted/exhausted` —— **一个都不命中**，
    于是落到 "缺存量字段就当可用" 的兜底，副官持续把工人派往已采空的矿点。
    """

    def test_game_field_names_are_honoured(self):
        from adjutant_coordinator.graph import observation_view as ov
        self.assertFalse(ov.resource_available({"kind": "resource", "ore_depleted": True,
                                                "ore_remaining": 0}),
                         "游戏发的 ore_depleted=True 必须判为不可用")
        self.assertFalse(ov.resource_available({"kind": "resource", "ore_remaining": 0}),
                         "ore_remaining=0 必须判为不可用（哪怕没有布尔位）")
        self.assertTrue(ov.resource_available({"kind": "resource", "ore_remaining": 5000,
                                               "ore_depleted": False}),
                        "有存量必须判为可用（矿点会再生）")

    def test_legacy_field_names_still_honoured(self):
        from adjutant_coordinator.graph import observation_view as ov
        for payload in ({"remaining": 0}, {"amount": 0}, {"depleted": True},
                        {"exhausted": True}):
            payload["kind"] = "resource"
            self.assertFalse(ov.resource_available(payload),
                             "旧字段名也要继续认：%s" % payload)

    def test_nearest_resource_fallback_does_not_reintroduce_depleted_nodes(self):
        """`cap` 满了退回兜底时，**不能把采空的矿重新引入**。

        "满了"（可以挤）与"空了"（派过去只会被拒）是两回事：旧兜底把整份
        `resources` 再喂一遍，绕过了 cap 的同时**也绕过了可用性**。
        """
        from adjutant_coordinator.graph import rules_fallback as rf
        unit = _worker()
        depleted = {"name": "Res_Empty", "kind": "A", "pos": [12.6, 0.0, 12.6],
                    "ore_depleted": True, "ore_remaining": 0}
        loaded = {"name": "Res_Full", "kind": "B", "pos": [12.4, 0.0, 12.4],
                  "ore_remaining": 900}
        picked = rf._nearest_resource(unit, [depleted, loaded],
                                      load={"Res_Full": 99}, cap=2)
        self.assertEqual(picked, loaded,
                         "满了可以挤，但**采空的必须排除**（否则权威回 ResourceDepleted）")
        self.assertIsNone(rf._nearest_resource(unit, [depleted], cap=2),
                          "唯一矿点采空 ⇒ 返回 None，让上层转岗/等待，而不是硬派")


class DepletedResourceBanTest(unittest.TestCase):
    """被权威以 `ResourceDepleted` 拒过的矿，**对这个单位**要限时不再作候选。

    为什么还需要这一层：字段名修好之后 gather 接受率 9%→33%，**但仍有 105 条被拒**，
    且接受/拒绝随时间**交错**（翻转 55 次）—— 说明剩下的不是"挑错了矿"，
    而是**命令发出去之后矿被采空了**（多工人竞争 / 观测滞后）。
    这种情况重发同一条命令只会继续被拒，必须**换成别的矿**。

    与"工地不存在"的区别（`placement.SITE_BAN_TICKS` 几乎等于永久）：矿点**会再生**
    （`ResourceUnit`：ready → depleted → ready），所以这里必须**限时**。
    """

    def setUp(self):
        from adjutant_coordinator.graph import placement as pl
        from adjutant_coordinator.graph import rules_fallback as rf
        self.rf, self.pl = rf, pl
        self.resource = {"name": "R1", "kind": "resource", "ore_remaining": 100,
                         "pos": [1.0, 0.0, 1.0]}

    def test_ban_is_per_unit_and_time_limited(self):
        state = {"server_tick": 1000}
        self.assertTrue(self.rf.resource_usable_by(state, "Unit_2", self.resource),
                        "没被拒过的矿必须可用")
        self.rf.ban_depleted_resource(state, ["Unit_2"], "R1", 1000)
        self.assertFalse(self.rf.resource_usable_by(state, "Unit_2", self.resource),
                         "被拒过的矿对这个单位在窗口内不可用")
        self.assertTrue(self.rf.resource_usable_by(state, "Unit_9", self.resource),
                        "别人未必也采不了 ⇒ 按**单位 × 矿点**记账，不许全局拉黑")
        state["server_tick"] = 1000 + self.rf.RESOURCE_BAN_TICKS
        self.assertTrue(self.rf.resource_usable_by(state, "Unit_2", self.resource),
                        "窗口过期必须恢复（矿点会再生，永久拉黑会废掉一个本会恢复的矿）")

    def test_ban_ledger_is_bounded(self):
        state = {"server_tick": 1000}
        for index in range(400):
            self.rf.ban_depleted_resource(state, ["Unit_%d" % index], "R%d" % index, 1000)
        self.assertLessEqual(len(state["depleted_resources"]), 256,
                             "长局不许无限增长")

    def test_the_two_ban_constants_agree(self):
        """`rules_fallback` 不能 import `placement`（会成环），所以常量各留一份 —— 必须相等。"""
        self.assertEqual(self.rf.RESOURCE_BAN_TICKS, self.pl.RESOURCE_BAN_TICKS,
                         "两处拉黑时长必须一致，否则账本与筛选器的口径会分叉")

    def test_authority_error_code_is_classified(self):
        for text in ("Rejected ResourceDepleted", "Rejected ResourceTargetNotFound"):
            self.assertIn(self.pl.classify_rejection(text),
                          self.pl.RESOURCE_KINDS,
                          "%s 必须归到资源点类（修正维度 = 换矿）" % text)




def _worker(pos=(12.0, 0.0, 12.0)):
    return {"gather": True, "pos": list(pos)}


def _gather_intent(unit, target, tick, state="active"):
    return {"action": "gather", "state": state, "issued_tick": tick,
            "unit_ids": [unit], "target": {"entity_id": target}}


class OccupancyTest(unittest.TestCase):
    def test_mining_workers_count_toward_load(self):
        by_name = {"W0": _worker(), "W1": _worker(), "W2": _worker()}
        load, type_load, holders = ra.occupancy(
            by_name, [NEAR, FAR],
            [_gather_intent("W0", "Res_B", 10), _gather_intent("W1", "Res_B", 20)])
        self.assertEqual(load, {"Res_B": 2})
        self.assertEqual(type_load, {"B": 2})
        self.assertEqual(holders, {"W0": "Res_B", "W1": "Res_B"})

    def test_expired_intent_does_not_count(self):
        """过期在途意图不算占用（与仲裁的 TTL 口径一致，别让僵尸意图永久占位）。"""
        by_name = {"W0": _worker()}
        stale = _gather_intent("W0", "Res_B", 10, state="expired")
        load, _type_load, holders = ra.occupancy(by_name, [NEAR, FAR], [stale])
        self.assertEqual(load, {})
        self.assertEqual(holders, {})


class AssignTest(unittest.TestCase):
    def test_new_worker_goes_to_free_node(self):
        by_name = {"W0": _worker(), "W1": _worker(), "W2": _worker()}
        intents = [_gather_intent("W0", "Res_B", 10), _gather_intent("W1", "Res_B", 20)]
        load, type_load, holders = ra.occupancy(by_name, [NEAR, FAR], intents)
        assigned = ra.assign(by_name, [NEAR, FAR], sorted(by_name),
                             existing_load=load, existing_type_load=type_load,
                             skip=set(holders))
        self.assertEqual(assigned, {"W2": "Res_A"})

    def test_without_skip_it_reproduces_the_bug(self):
        """反例固化：算进占用账但**忘了排除已在岗的人**（少传 `skip`），
        已在岗的人会再占一遍名额 → 真正待分配的人"无矿可分" —— 这就是"越派越挤"的机制。
        （正确用法见 `test_new_worker_goes_to_free_node` 与
        `test_rules_fallback_wrapper_fills_occupancy_from_intents`。）"""
        by_name = {"W0": _worker(), "W1": _worker(), "W2": _worker()}
        intents = [_gather_intent("W0", "Res_B", 10), _gather_intent("W1", "Res_B", 20)]
        load, type_load, _holders = ra.occupancy(by_name, [NEAR, FAR], intents)
        assigned = ra.assign(by_name, [NEAR, FAR], sorted(by_name),
                             existing_load=load, existing_type_load=type_load)
        self.assertNotIn("W2", assigned)
        self.assertEqual(assigned, {"W0": "Res_A", "W1": "Res_A"})

    def test_rules_fallback_wrapper_fills_occupancy_from_intents(self):
        """`rf.assign_resources(..., intents=)` 必须自动补占用账（正确用法即默认用法）。"""
        by_name = {"W0": _worker(), "W1": _worker(), "W2": _worker()}
        assigned = rf.assign_resources(
            by_name, [NEAR, FAR], sorted(by_name),
            intents=[_gather_intent("W0", "Res_B", 10), _gather_intent("W1", "Res_B", 20)])
        self.assertEqual(assigned, {"W2": "Res_A"})


class RebalanceTest(unittest.TestCase):
    def test_moves_latest_issued_worker_to_free_node(self):
        by_name = {"W0": _worker(), "W1": _worker(), "W2": _worker()}
        intents = [_gather_intent("W0", "Res_B", 10), _gather_intent("W1", "Res_B", 20),
                   _gather_intent("W2", "Res_B", 30)]
        self.assertEqual(ra.rebalance(by_name, [NEAR, FAR], intents), [("W2", "Res_A")])

    def test_no_overload_no_moves(self):
        """未超员时不许产生任何改派（防 churn：每轮都重派会让工人来回走）。"""
        by_name = {"W0": _worker(), "W1": _worker()}
        intents = [_gather_intent("W0", "Res_B", 10), _gather_intent("W1", "Res_B", 20)]
        self.assertEqual(ra.rebalance(by_name, [NEAR, FAR], intents), [])

    def test_no_free_node_no_moves(self):
        """所有矿点都满时不折腾（宁可挤，也不让工人闲置）。"""
        by_name = {"W0": _worker(), "W1": _worker(), "W2": _worker()}
        intents = [_gather_intent(u, "Res_B", t) for u, t in
                   (("W0", 10), ("W1", 20), ("W2", 30))]
        self.assertEqual(ra.rebalance(by_name, [NEAR], intents), [])


class SingleSourceOfTruthTest(unittest.TestCase):
    """类的守门：同一个规则不许再出现第二份定义。"""

    def test_capacity_constant_is_shared(self):
        self.assertIs(rf.RESOURCE_WORKERS_PER_NODE, ra.RESOURCE_WORKERS_PER_NODE)
        self.assertIs(tp.RESOURCE_WORKERS_PER_NODE, ra.RESOURCE_WORKERS_PER_NODE)

    def test_assign_resources_delegates_to_single_implementation(self):
        by_name = {"W0": _worker()}
        self.assertEqual(rf.assign_resources(by_name, [NEAR], ["W0"]),
                         ra.assign(by_name, [NEAR], ["W0"]))

    def test_depleted_node_is_not_assigned(self):
        """T10：存量 0 的矿点不许再派人。"""
        empty = {"name": "Res_B", "kind": "B", "pos": [12.5, 0.0, 12.5], "remaining": 0}
        assigned = ra.assign({"W0": _worker()}, [empty, FAR], ["W0"])
        self.assertEqual(assigned, {"W0": "Res_A"})

    def test_observation_parsing_is_single_source(self):
        """观测解析也不许有第二份（`observation_view` 是唯一实现，`rules_fallback` 只是再导出）。"""
        from adjutant_coordinator.graph import observation_view as ov
        tactical = {"entities": [
            {"kind": "unit_self", "name": "U0", "unit_type": "worker", "gather": True,
             "pos": [1.0, 0.0, 2.0]},
            {"kind": "resource", "name": "R0", "pos": [3.0, 0.0, 4.0]},
        ]}
        self.assertEqual([rf.entity_id_of(e) for e in rf._resources(tactical)],
                         [ov.entity_id_of(e) for e in ov.resources(tactical)])
        self.assertEqual(rf._pos2d(tactical["entities"][1]),
                         ov.pos2d(tactical["entities"][1]))


if __name__ == "__main__":
    unittest.main()
