# -*- coding: utf-8 -*-
"""微操行为树单测。

覆盖重点不是"跑得通"，而是**钉住几条纪律**——它们每一条都对应一次真实事故：
- 玩家接管的单位绝不能被下发（安全边界）；
- 劣势必须撤离而不是硬冲；
- 一个单位同一批只能出现一次（结构性保证，不能靠提示词）；
- 降级时**不得**产生无依据的战场动作（凭空 scout 曾把金标准用例打挂）；
- 输出必须能过契约（`target` 是 dict，不是裸坐标）。
"""
import unittest

from adjutant_coordinator.graph import behavior_tree
from adjutant_coordinator.graph.contracts import parse_intent_batch

TICK = 1000
SNAPSHOT = 3


def _entity(kind, name=None, unit_type=None, pos=(0, 0, 0), **extra):
    out = {"kind": kind, "pos": list(pos)}
    if name is not None:
        out["name"] = name
    if unit_type is not None:
        out["unit_type"] = unit_type
    out.update(extra)
    return out


def _tactical(entities):
    return {"entities": entities}


class MicroTreeTest(unittest.TestCase):
    def setUp(self):
        self.state = {
            "server_tick": TICK,
            "latest_snapshot_id": SNAPSHOT,
            "ai_controlled_units": [],
            "player_controlled_units": [],
        }

    def _units(self, intents):
        return {str(u): it for it in intents for u in it["unit_ids"]}

    # -- 安全边界 ---------------------------------------------------------
    def test_player_controlled_unit_gets_nothing(self):
        """玩家接管 → 副官必须完全让权（一条意图都不能有）。"""
        self.state["ai_controlled_units"] = ["U_taken"]
        self.state["player_controlled_units"] = ["U_taken"]
        tac = _tactical([_entity("unit_self", "U_taken", "soldier",
                                 gather=True, construct=True)])
        self.assertEqual(behavior_tree.micro_intents(self.state, tactical=tac), [])

    def test_player_controlled_not_dispatchable_even_with_enemy(self):
        """有敌情也不能碰玩家单位：让权分支必须在交火分支**之前**。"""
        self.state["ai_controlled_units"] = ["U_taken"]
        self.state["player_controlled_units"] = ["U_taken"]
        tac = _tactical([
            _entity("unit_self", "U_taken", "soldier"),
            _entity("unit_enemy", entity_id="E_1"),
        ])
        self.assertEqual(behavior_tree.micro_intents(self.state, tactical=tac), [])

    # -- 威胁处置 ---------------------------------------------------------
    def test_outnumbered_combat_unit_retreats(self):
        """敌多于我 → 撤离（实测模型会拿 1 个兵硬冲 3 个敌人）。"""
        self.state["ai_controlled_units"] = ["U_s1"]
        tac = _tactical([
            _entity("unit_self", "U_s1", "soldier", pos=(10, 0, 10)),
            _entity("unit_self", "U_cc", "command_center", pos=(0, 0, 0)),
            _entity("unit_enemy", entity_id="E_1"),
            _entity("unit_enemy", entity_id="E_2"),
        ])
        intents = behavior_tree.micro_intents(self.state, tactical=tac)
        self.assertEqual(len(intents), 1)
        self.assertEqual(intents[0]["action"], "retreat")
        # target 必须是 dict（契约），且带坐标。
        self.assertIsInstance(intents[0]["target"], dict)
        self.assertIn("pos", intents[0]["target"])

    def test_not_outnumbered_engages_nearest_enemy(self):
        self.state["ai_controlled_units"] = ["U_s1", "U_s2"]
        tac = _tactical([
            _entity("unit_self", "U_s1", "soldier"),
            _entity("unit_self", "U_s2", "soldier"),
            _entity("unit_enemy", entity_id="E_1"),
        ])
        intents = self._units(behavior_tree.micro_intents(self.state, tactical=tac))
        self.assertEqual(intents["U_s1"]["action"], "attack")
        self.assertEqual(intents["U_s1"]["target"], {"entity_id": "E_1"})

    def test_ids_from_name_field_match_real_dcs_payload(self):
        """观测实体**只有 `name`**（游戏端真实导出形状）时，行为树仍必须看得见敌人与资源。

        回归守卫（2026-09-11 实锤）：`_adapt` 曾按 `entity_id` 取 enemy/resource 的 id，
        而 `DebugControlServer` 导出的这两类实体**只有 `name`**（全仓没有 `entity_id` 字段）
        → `visible_enemies` / `visible_resources` **恒为空**
        → 就近交火、劣势撤离、工人采集兜底**全部静默失效**：
        不报错、不降级，只表现为"副官从不打仗、工人也不兜底采集"，极难从日志看出。
        故这里刻意**不提供 entity_id**，与真实回包一致。
        """
        self.state["ai_controlled_units"] = ["U_s1", "U_w1"]
        tac = _tactical([
            _entity("unit_self", "U_s1", "soldier", pos=(0, 0, 0)),
            _entity("unit_self", "U_w1", "worker", gather=True, pos=(0, 0, 0)),
            _entity("unit_enemy", name="Enemy_1", pos=(20, 0, 20)),
            _entity("resource", name="ResourceA", pos=(5, 0, 5)),
        ])
        intents = self._units(behavior_tree.micro_intents(self.state, tactical=tac))
        self.assertEqual(intents["U_s1"]["action"], "attack")
        self.assertEqual(intents["U_s1"]["target"], {"entity_id": "Enemy_1"})
        self.assertEqual(intents["U_w1"]["action"], "gather")
        self.assertEqual(intents["U_w1"]["target"]["entity_id"], "ResourceA")

    # -- 职责 -------------------------------------------------------------
    def test_worker_gathers_nearest_resource(self):
        self.state["ai_controlled_units"] = ["U_w1"]
        tac = _tactical([
            _entity("unit_self", "U_w1", "worker", pos=(0, 0, 0), gather=True),
            _entity("resource", entity_id="R_far", pos=(90, 0, 90)),
            _entity("resource", entity_id="R_near", pos=(5, 0, 5)),
        ])
        intents = behavior_tree.micro_intents(self.state, tactical=tac)
        self.assertEqual(len(intents), 1)
        self.assertEqual(intents[0]["action"], "gather")
        self.assertEqual(intents[0]["target"]["entity_id"], "R_near")

    def test_building_gets_no_intent(self):
        """建筑无动作时应当静默，不能被兜底派去野外（曾把兵营派去 scout）。"""
        self.state["ai_controlled_units"] = ["U_b1"]
        tac = _tactical([_entity("unit_self", "U_b1", "barracks", queue=True)])
        self.assertEqual(behavior_tree.micro_intents(self.state, tactical=tac), [])

    # -- 降级纪律：不做无依据的动作 ---------------------------------------
    def test_idle_combat_unit_is_silent_by_default(self):
        """默认**不**做空闲集结：v1 没有探索/威胁模型，凭空游走比闲置更差。"""
        self.state["ai_controlled_units"] = ["U_s1"]
        tac = _tactical([_entity("unit_self", "U_s1", "soldier")])
        self.assertEqual(behavior_tree.micro_intents(self.state, tactical=tac), [])

    def test_idle_regroup_only_when_explicitly_enabled(self):
        self.state["ai_controlled_units"] = ["U_s1"]
        tac = _tactical([
            _entity("unit_self", "U_s1", "soldier", pos=(50, 0, 50)),
            _entity("unit_self", "U_cc", "command_center", pos=(0, 0, 0)),
        ])
        intents = behavior_tree.micro_intents(
            self.state, tactical=tac, config={"allow_idle_regroup": True})
        self.assertEqual(len(intents), 1)
        self.assertEqual(intents[0]["action"], "regroup")
        self.assertEqual(intents[0]["target"]["pos"], [0.0, 0.0])

    def test_scout_is_never_emitted(self):
        """回归守卫：任何情况下都不得再出现凭空坐标的 scout。"""
        self.state["ai_controlled_units"] = ["U_s1", "U_w1", "U_b1"]
        tac = _tactical([
            _entity("unit_self", "U_s1", "soldier"),
            _entity("unit_self", "U_w1", "worker", gather=True),
            _entity("unit_self", "U_b1", "barracks", queue=True),
        ])
        for config in ({}, {"allow_idle_regroup": True}):
            for intent in behavior_tree.micro_intents(
                    self.state, tactical=tac, config=config):
                self.assertNotEqual(intent["action"], "scout")

    # -- 结构性保证 -------------------------------------------------------
    def test_one_intent_per_unit(self):
        """一个单位同一批只能出现一次（不靠提示词，靠黑板的"读多写一"）。"""
        self.state["ai_controlled_units"] = ["U_w1", "U_s1", "U_s2", "U_b1"]
        tac = _tactical([
            _entity("unit_self", "U_w1", "worker", gather=True, pos=(0, 0, 0)),
            _entity("unit_self", "U_s1", "soldier"),
            _entity("unit_self", "U_s2", "soldier"),
            _entity("unit_self", "U_b1", "barracks", queue=True),
            _entity("resource", entity_id="R_1", pos=(3, 0, 3)),
            _entity("unit_enemy", entity_id="E_1"),
        ])
        intents = behavior_tree.micro_intents(self.state, tactical=tac)
        seen = [str(u) for it in intents for u in it["unit_ids"]]
        self.assertEqual(len(seen), len(set(seen)), "同一单位被重复下发：%s" % seen)

    def test_intent_id_carries_tick(self):
        """`intent_id` 必须带 tick：游戏按 intent_id 幂等缓存回执，
        固定 id 会让重试永远命中最早那次回执（实测"改了参数却毫无变化"的真凶）。"""
        self.state["ai_controlled_units"] = ["U_w1"]
        tac = _tactical([
            _entity("unit_self", "U_w1", "worker", gather=True),
            _entity("resource", entity_id="R_1", pos=(1, 0, 1)),
        ])
        first = behavior_tree.micro_intents(self.state, tactical=tac)[0]["intent_id"]
        self.state["server_tick"] = TICK + 1
        second = behavior_tree.micro_intents(self.state, tactical=tac)[0]["intent_id"]
        self.assertNotEqual(first, second)

    # -- 契约 -------------------------------------------------------------
    def test_output_passes_intent_contract(self):
        """行为树输出必须能过生产契约（`target` 是 dict —— 写成裸坐标曾被拒）。"""
        self.state["ai_controlled_units"] = ["U_w1", "U_s1"]
        tac = _tactical([
            _entity("unit_self", "U_w1", "worker", gather=True),
            _entity("unit_self", "U_s1", "soldier"),
            _entity("resource", entity_id="R_1", pos=(2, 0, 2)),
            _entity("unit_enemy", entity_id="E_1"),
        ])
        batch = behavior_tree.micro_batch(self.state, tactical=tac)
        batch.update({"match_id": "m-1", "player_id": "Player_0", "plan_version": "v1"})
        parsed = parse_intent_batch(batch)   # 不抛异常即通过契约
        self.assertEqual(len(parsed.intents), 2)


class ScoutTest(unittest.TestCase):
    """专职侦察（2026-09-11 新增）：验收项"侦察"此前**从未发生**。

    事故背景：空闲单位没有任何动作 → 无人机整局停在基地（实测 5 分钟对局里
    回执只有 gather/produce/build，没有一次 move）。没有侦察就没有敌情，
    后面的"交战 / 劣势撤离"根本无从触发。
    与已关闭的"空闲集结"（`allow_idle_regroup`）的区别：这里的航点由
    **观测到的主基地位置**推出，同一 tick 必然得到同一点，可复现、可单测，
    不是凭空游走。
    """

    def setUp(self):
        self.state = {
            "server_tick": TICK,
            "latest_snapshot_id": SNAPSHOT,
            "ai_controlled_units": ["U_d1"],
            "player_controlled_units": [],
        }

    def _tac(self):
        return _tactical([
            _entity("unit_self", "U_d1", "drone", pos=(40, 0, 40)),
            _entity("unit_self", "U_cc", "command_center", pos=(10, 0, 10)),
        ])

    def _one(self):
        intents = behavior_tree.micro_intents(self.state, tactical=self._tac())
        self.assertEqual(len(intents), 1)
        return intents[0]

    def test_scout_unit_pushes_waypoint_on_first_ring(self):
        intent = self._one()
        self.assertEqual(intent["action"], "scout")
        target = intent["target"]
        # `target` 必须是 dict（契约）—— 写成裸坐标会被契约校验拒绝。
        self.assertIsInstance(target, dict)
        self.assertIn("pos", target)
        slot = TICK // behavior_tree.SCOUT_HOLD_TICKS
        bearing = behavior_tree.SCOUT_BEARINGS[slot % len(behavior_tree.SCOUT_BEARINGS)]
        expected = behavior_tree.SCOUT_RING_STEP * (
            (bearing[0] ** 2 + bearing[1] ** 2) ** 0.5)
        x, z = target["pos"]
        distance = ((x - 10.0) ** 2 + (z - 10.0) ** 2) ** 0.5
        self.assertAlmostEqual(distance, expected, places=1,
                              msg="航点必须落在以观测到的基地为圆心的第一圈上")

    def test_waypoint_and_intent_id_are_stable_within_slot(self):
        """同一航点内重复上报必须给出**同一个 intent_id**（否则游戏每 tick 重下移动、
        单位会在半路反复改目标）。"""
        first = self._one()
        self.state["server_tick"] = TICK + 10
        same = self._one()
        self.assertEqual(first["target"], same["target"])
        self.assertEqual(first["intent_id"], same["intent_id"])

    def test_waypoint_advances_to_next_slot(self):
        """换槽位 = 换航点 = 新 intent_id（否则幂等回执会让无人机永远停在同一点）。"""
        first = self._one()
        self.state["server_tick"] = TICK + behavior_tree.SCOUT_HOLD_TICKS
        later = self._one()
        self.assertNotEqual(first["target"], later["target"])
        self.assertNotEqual(first["intent_id"], later["intent_id"])

    def test_no_home_anchor_means_no_scout(self):
        """拿不到基地坐标就**不动作**（宁可不发，也不凭空猜坐标）。"""
        tac = _tactical([_entity("unit_self", "U_d1", "drone", pos=(40, 0, 40))])
        self.assertEqual(behavior_tree.micro_intents(self.state, tactical=tac), [])

    def test_combat_unit_is_not_sent_scouting(self):
        """作战单位不许被派去侦察：让坦克满地图跑是无依据的战场动作。

        注（2026-09-11）：空闲集结默认开启后，作战单位会收到 `regroup`（回基地），
        所以这里断言的是"**动作绝不是 scout**"，而不是"没有任何意图"。
        """
        self.state["ai_controlled_units"] = ["U_s1"]
        tac = _tactical([
            _entity("unit_self", "U_s1", "soldier", pos=(20, 0, 20)),
            _entity("unit_self", "U_cc", "command_center", pos=(10, 0, 10)),
        ])
        intents = behavior_tree.micro_intents(self.state, tactical=tac)
        self.assertEqual({item["action"] for item in intents}, {"regroup"})


class RegroupTest(unittest.TestCase):
    """空闲作战单位向主基地集结（2026-09-11 默认开启）。

    用户要求"要看到副官批量指挥部队"：全队**同一个目标**才会被仲裁层
    （`arbitration.merge_same_orders`）合并成**一条多单位命令**，
    屏幕上才是"整队一起动"，而不是十几个单位各自扭一下。
    """

    def setUp(self):
        self.state = {
            "server_tick": TICK,
            "latest_snapshot_id": SNAPSHOT,
            "ai_controlled_units": ["U_s1", "U_s2", "U_s3"],
            "player_controlled_units": [],
        }

    def _tac(self):
        return _tactical([
            _entity("unit_self", "U_s1", "soldier", pos=(30, 0, 30)),
            _entity("unit_self", "U_s2", "soldier", pos=(35, 0, 35)),
            _entity("unit_self", "U_s3", "tank", pos=(40, 0, 40)),
            _entity("unit_self", "U_cc", "command_center", pos=(10, 0, 10)),
        ])

    def test_combat_units_regroup_to_same_target_by_default(self):
        intents = behavior_tree.micro_intents(self.state, tactical=self._tac())
        self.assertEqual(len(intents), 3)
        self.assertEqual({item["action"] for item in intents}, {"regroup"})
        targets = [item["target"] for item in intents]
        self.assertEqual(targets[0], targets[1],
                         "全队必须同一目标，否则仲裁层合并不了、也就看不到批量指挥")
        self.assertEqual(targets[1], targets[2])
        self.assertEqual(targets[0]["pos"], [10.0, 10.0], "目标就是观测到的主基地位置")

    def test_can_be_disabled_explicitly(self):
        intents = behavior_tree.micro_intents(
            self.state, tactical=self._tac(), config={"allow_idle_regroup": False})
        self.assertEqual(intents, [], "显式关闭后空闲作战单位不下发任何命令")

    def test_no_base_anchor_means_no_regroup(self):
        """拿不到基地锚点就不动作（宁可不发）：这也是金标准用例 replay_model_timeout 的安全网。"""
        tac = _tactical([
            _entity("unit_self", "U_s1", "soldier", pos=(30, 0, 30)),
            _entity("unit_self", "U_s2", "soldier", pos=(35, 0, 35)),
            _entity("unit_self", "U_s3", "tank", pos=(40, 0, 40)),
        ])
        self.assertEqual(behavior_tree.micro_intents(self.state, tactical=tac), [])


if __name__ == "__main__":
    unittest.main()
