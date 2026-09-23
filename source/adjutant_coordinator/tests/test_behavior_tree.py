# -*- coding: utf-8 -*-
"""微操行为树单测。

覆盖重点不是"跑得通"，而是**钉住几条纪律**——它们每一条都对应一次真实事故：
- 玩家接管的单位绝不能被下发（安全边界）；
- 劣势必须撤离而不是硬冲；
- 一个单位同一批只能出现一次（结构性保证，不能靠提示词）；
- 降级时**不得**产生无依据的战场动作（凭空 scout 曾把金标准用例打挂）；
- 输出必须能过契约（`target` 是 dict，不是裸坐标）。
"""
import math
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
        """野外敌多于我 → 撤离（实测模型会拿 1 个兵硬冲 3 个敌人）。

        敌人必须离开己方建筑，否则会走「基地受袭回防」，不是这条野外撤离。
        """
        self.state["ai_controlled_units"] = ["U_s1"]
        tac = _tactical([
            _entity("unit_self", "U_s1", "soldier", pos=(80, 0, 80)),
            _entity("unit_self", "U_cc", "command_center", pos=(0, 0, 0)),
            _entity("unit_enemy", entity_id="E_1", pos=(82, 0, 82)),
            _entity("unit_enemy", entity_id="E_2", pos=(84, 0, 84)),
        ])
        intents = behavior_tree.micro_intents(self.state, tactical=tac)
        self.assertEqual(len(intents), 1)
        self.assertEqual(intents[0]["action"], "retreat")
        # target 必须是 dict（契约），且带坐标。
        self.assertIsInstance(intents[0]["target"], dict)
        self.assertIn("pos", intents[0]["target"])
        self.assertNotEqual(intents[0]["target"]["pos"], [0.0, 0.0],
                            "撤离不得再把主基地当落点")

    def test_empty_home_recalls_nearest_when_base_is_raided(self):
        """家里没作战单位、敌人贴着指挥中心 → 最近的野外兵必须回防，不能继续前压。"""
        self.state["ai_controlled_units"] = ["U_far"]
        tac = _tactical([
            _entity("unit_self", "U_far", "soldier", pos=(80, 0, 80)),
            _entity("unit_self", "U_cc", "command_center", pos=(0, 0, 0)),
            _entity("unit_enemy", entity_id="E_raid", pos=(5, 0, 5)),
        ])
        intents = behavior_tree.micro_intents(self.state, tactical=tac)
        self.assertEqual(len(intents), 1)
        self.assertEqual(intents[0]["action"], "defend")
        self.assertEqual(intents[0]["target"]["pos"], [0.0, 0.0])

    def test_raid_recall_beats_outnumbered_retreat(self):
        """家里被打、野外只有 1 兵面对多名敌人：仍回防，不许往脱离点跑。"""
        self.state["ai_controlled_units"] = ["U_far"]
        tac = _tactical([
            _entity("unit_self", "U_far", "soldier", pos=(80, 0, 80)),
            _entity("unit_self", "U_cc", "command_center", pos=(0, 0, 0)),
            _entity("unit_enemy", entity_id="E_1", pos=(4, 0, 4)),
            _entity("unit_enemy", entity_id="E_2", pos=(6, 0, 6)),
        ])
        intents = behavior_tree.micro_intents(self.state, tactical=tac)
        self.assertEqual(len(intents), 1)
        self.assertEqual(intents[0]["action"], "defend")

    def test_far_line_keeps_task_when_base_is_raided(self):
        """【2026-09-22 振荡事故回归】受袭只召回**必要局部兵力**，远处战线不得清空。

        实测（backend=off 基线局 base_off_2，240s 纯规则层）两个缺陷叠加：
        ① 回防**响应**半径曾与判定半径同用 40m，军事轨前压点长期落在 20~40m
           → 整局泡在回防圈里；
        ② `defense_recall_names` 每 tick 把圈内人数补满到配额（传送带式召回），
           近处的赶到家后下一 tick 又召下一批。
        合计 `bt-defend` 286 条 vs `bt-attack_move` 122 条，大军在家与 40m 外
        来回振荡、前 180 秒几乎零输出（手册明令"一条线的威胁不得升级为全军回防"）。
        现在：响应半径 20m；圈内有人 → 不召任何野外单位；圈内真空 → 只召 ≤3 个。
        """
        self.state["ai_controlled_units"] = ["U_near", "U_far"]
        tac = _tactical([
            _entity("unit_self", "U_near", "soldier", pos=(12, 0, 0)),
            _entity("unit_self", "U_far", "soldier", pos=(35, 0, 0)),
            _entity("unit_self", "U_cc", "command_center", pos=(0, 0, 0)),
            _entity("unit_enemy", entity_id="E_raid", pos=(5, 0, 5)),
        ])
        intents = behavior_tree.micro_intents(self.state, tactical=tac)
        by_unit = self._units(intents)
        # 圈内单位必须响应这一仗（回防或就地打都算，不许闲着）。
        self.assertIn(by_unit["U_near"]["action"], ("defend", "attack"),
                      "圈内单位必须响应受袭")
        # 圈外单位：**不许**被召回守家（圈内已经有人打了）。
        self.assertIn("U_far", by_unit, "远处战线必须继续有任务，不得被清空")
        self.assertNotEqual(by_unit["U_far"]["action"], "defend",
                            "圈内已有作战单位时不得再召回野外的")
        # 回防兵力有界：这一仗只有圈内那一个。
        defenders = [it for it in intents if it["action"] == "defend"]
        self.assertEqual(len(defenders), 1, "受袭响应只限圈内必要兵力")

    def test_recall_only_when_home_circle_is_empty(self):
        """【2026-09-22 传送带召回回归】圈内有人 → 一个都不召；真空 → 只召最近 3 个。"""
        from adjutant_coordinator.graph import rules_fallback as rf

        by_name = {
            "U_home": {"type": "soldier", "pos": [10.0, 0.0, 0.0]},
            "U_f1": {"type": "soldier", "pos": [40.0, 0.0, 0.0]},
            "U_f2": {"type": "soldier", "pos": [50.0, 0.0, 0.0]},
            "U_f3": {"type": "soldier", "pos": [60.0, 0.0, 0.0]},
            "U_f4": {"type": "soldier", "pos": [70.0, 0.0, 0.0]},
            "U_cc": {"type": "command_center", "pos": [0.0, 0.0, 0.0]},
        }
        combat = ["U_home", "U_f1", "U_f2", "U_f3", "U_f4"]
        # 圈内（20m）有 U_home → 不召任何野外单位（传送带就此断开）。
        self.assertEqual(rf.defense_recall_names(combat, by_name, (0.0, 0.0)), [])
        # 圈内真空 → 只召最近的 3 个（配额上限），不是全部。
        self.assertEqual(
            rf.defense_recall_names(["U_f1", "U_f2", "U_f3", "U_f4"], by_name,
                                    (0.0, 0.0)),
            ["U_f1", "U_f2", "U_f3"])
        # 配额可显式调小（评测/实验用），但不许变成负数语义。
        self.assertEqual(
            rf.defense_recall_names(["U_f1", "U_f2", "U_f3", "U_f4"], by_name,
                                    (0.0, 0.0), quota=1),
            ["U_f1"])

    def test_respond_radius_covers_max_weapon_range(self):
        """响应半径必须覆盖当前平衡表的最大武器射程（反地炮塔 16m）——否则
        "圈内"单位够不着贴楼的敌人，回防形同虚设。这是常量之间的关系，不许谁单改。"""
        import json
        import os

        from adjutant_coordinator.graph import rules_fallback as rf

        balance_path = os.path.join(
            os.path.dirname(rf.__file__), "..", "..", "..", "config", "balance",
            "demo.balance.v1.json")
        max_range = 0.0
        try:
            with open(os.path.normpath(balance_path), encoding="utf-8") as handle:
                balance = json.load(handle)
            for weapon in balance.get("weapons") or []:
                max_range = max(max_range, float(weapon.get("rangeMeters") or 0.0))
        except OSError:
            self.skipTest("平衡配置不可读：%s" % balance_path)
        self.assertGreaterEqual(rf.DEFEND_RESPOND_RADIUS_M, max_range,
                                "响应半径小于最大武器射程时回防够不着敌人")
        # 响应半径必须显著小于判定半径，否则又变成"整局泡在回防圈"。
        self.assertLess(rf.DEFEND_RESPOND_RADIUS_M, rf.DEFENSE_RADIUS_M)

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
    def test_idle_combat_unit_pushes_forward_by_default(self):
        """无可见敌人时作战单位**前压探索**（不再原地待命/只回基地）。

        契约变更依据（2026-09-12 晚，用户带截图质问"部队为什么只会停下来等待，
        40000 块不派兵去探索"）：决策手册 01 §3 军事线要求"集结 → **前压** → 进攻"
        持续推进；传统 AI 铁律"兜底推进绝不站桩"。
        旧行为（本用例曾断言"空闲即静默"）导致 13 个单位、46800 余额全部杵在基地。
        """
        self.state["ai_controlled_units"] = ["U_s1"]
        tac = _tactical([
            _entity("unit_self", "U_s1", "soldier", pos=(50, 0, 50)),
            _entity("unit_self", "U_cc", "command_center", pos=(0, 0, 0)),
        ])
        intents = behavior_tree.micro_intents(self.state, tactical=tac)
        self.assertEqual(len(intents), 1)
        self.assertEqual(intents[0]["action"], "attack_move")
        point = intents[0]["target"]["pos"]
        self.assertEqual(len(point), 2)
        self.assertGreater(max(abs(point[0]), abs(point[1])), 0.0,
                           "前压航点必须离开基地（不能原地不动）")
        self.assertGreaterEqual(math.hypot(point[0] - 50.0, point[1] - 50.0), 14.0,
                                "前压必须从单位自己往外走，不能再围着主基地转圈")

    def test_forward_advance_is_deterministic(self):
        """同一 tick 必然得到同一航点（可复现、可单测；不是凭空游走）。"""
        self.state["ai_controlled_units"] = ["U_s1"]
        tac = _tactical([
            _entity("unit_self", "U_s1", "soldier", pos=(50, 0, 50)),
            _entity("unit_self", "U_cc", "command_center", pos=(0, 0, 0)),
        ])
        first = behavior_tree.micro_intents(self.state, tactical=tac)[0]["target"]["pos"]
        second = behavior_tree.micro_intents(self.state, tactical=tac)[0]["target"]["pos"]
        self.assertEqual(first, second)

    def test_forward_advance_disabled_falls_back_to_regroup(self):
        """关掉前压后仍可回退到前线集结（目标不是主基地）。"""
        self.state["ai_controlled_units"] = ["U_s1"]
        tac = _tactical([
            _entity("unit_self", "U_s1", "soldier", pos=(50, 0, 50)),
            _entity("unit_self", "U_cc", "command_center", pos=(0, 0, 0)),
        ])
        intents = behavior_tree.micro_intents(
            self.state, tactical=tac,
            config={"allow_forward_advance": False, "allow_idle_regroup": True})
        self.assertEqual(len(intents), 1)
        self.assertEqual(intents[0]["action"], "regroup")
        point = intents[0]["target"]["pos"]
        self.assertGreater(math.hypot(point[0], point[1]), 12.0,
                           "关掉前压时的集结点也不得落在主基地门口，实际 %s" % point)

    def test_scattered_units_explore_instead_of_regroup(self):
        """散开的空闲作战单位必须前压，不能被拉回去集合。"""
        self.state["ai_controlled_units"] = ["U_s1", "U_s2", "U_s3"]
        tac = _tactical([
            _entity("unit_self", "U_s1", "soldier", pos=(60, 0, 60)),
            _entity("unit_self", "U_s2", "soldier", pos=(80, 0, 20)),
            _entity("unit_self", "U_s3", "tank", pos=(90, 0, 90)),
            _entity("unit_self", "U_cc", "command_center", pos=(10, 0, 10)),
        ])
        intents = behavior_tree.micro_intents(self.state, tactical=tac)
        self.assertEqual({item["action"] for item in intents}, {"attack_move"})
        self.assertEqual([it for it in intents if it["action"] == "regroup"], [])

    def test_field_units_do_not_regroup_to_command_center(self):
        """野外空闲作战单位必须前压，不能被叫回主基地。"""
        self.state["ai_controlled_units"] = ["U_s%d" % i for i in range(1, 6)]
        tac = _tactical(
            [_entity("unit_self", "U_s%d" % i, "soldier", pos=(50, 0, 50))
             for i in range(1, 6)]
            + [_entity("unit_self", "U_cc", "command_center", pos=(0, 0, 0))])
        intents = behavior_tree.micro_intents(self.state, tactical=tac)
        regroup = [it for it in intents if it["action"] == "regroup"]
        home_bound = [it for it in intents if it["action"] == "regroup"
                      and it.get("target", {}).get("pos") == [0.0, 0.0]]
        advance = sorted(u for it in intents if it["action"] == "attack_move"
                         for u in it["unit_ids"])
        self.assertEqual(home_bound, [], "不得 regroup 到主基地坐标")
        self.assertEqual(regroup, [], "挤在一起的野外部队应前压，不应再集结")
        self.assertEqual(advance, ["U_s1", "U_s2", "U_s3", "U_s4", "U_s5"])

    def test_units_already_at_base_leave_with_field_units(self):
        """空闲时家里的作战单位也出门前压，不再原地 hold。"""
        self.state["ai_controlled_units"] = ["U_home1", "U_home2", "U_field"]
        tac = _tactical([
            _entity("unit_self", "U_home1", "soldier", pos=(2, 0, 2)),
            _entity("unit_self", "U_home2", "soldier", pos=(3, 0, 3)),
            _entity("unit_self", "U_field", "soldier", pos=(80, 0, 80)),
            _entity("unit_self", "U_cc", "command_center", pos=(0, 0, 0)),
        ])
        intents = self._units(behavior_tree.micro_intents(self.state, tactical=tac))
        self.assertEqual(intents["U_home1"]["action"], "attack_move")
        self.assertEqual(intents["U_home2"]["action"], "attack_move")
        self.assertEqual(intents["U_field"]["action"], "attack_move")

    def test_home_units_fight_or_defend_when_base_is_raided(self):
        """建筑附近见敌：圈内单位必须交火或回防，不许 hold / 出门前压。"""
        self.state["ai_controlled_units"] = ["U_home1", "U_home2"]
        tac = _tactical([
            _entity("unit_self", "U_home1", "soldier", pos=(2, 0, 2)),
            _entity("unit_self", "U_home2", "soldier", pos=(3, 0, 3)),
            _entity("unit_self", "U_cc", "command_center", pos=(0, 0, 0)),
            _entity("unit_enemy", entity_id="E_raid", pos=(4, 0, 4)),
        ])
        intents = self._units(behavior_tree.micro_intents(self.state, tactical=tac))
        for name in ("U_home1", "U_home2"):
            action = intents[name]["action"]
            self.assertIn(action, ("defend", "attack"), name)
            self.assertNotEqual(action, "hold")
            self.assertNotEqual(action, "attack_move")

    def test_combat_unit_has_no_enemy_but_no_anchor_stays_silent(self):
        """拿不到基地锚点时不动作（宁可不发，不能凭空造坐标）。"""
        self.state["ai_controlled_units"] = ["U_s1"]
        tac = _tactical([_entity("unit_self", "U_s1", "soldier")])
        self.assertEqual(behavior_tree.micro_intents(self.state, tactical=tac), [])

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
        # 航点距圆心 = `SCOUT_RING_STEP × 圈数`（**与方位无关**）。
        # 2026-09-15 起：方位随圈数旋转；且方位做了归一化（对角方位不再把半径放大 √2）。
        # 旧断言"自己按 slot 推方位再算期望"会与旋转后的实现脱节，故改为按圈数断言。
        slots = TICK // behavior_tree.SCOUT_HOLD_TICKS
        ring = 1 + slots // len(behavior_tree.SCOUT_BEARINGS)
        x, z = target["pos"]
        distance = ((x - 10.0) ** 2 + (z - 10.0) ** 2) ** 0.5
        self.assertAlmostEqual(distance, behavior_tree.SCOUT_RING_STEP * ring, places=1,
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

    def test_combat_unit_pushes_forward_not_scouting(self):
        """作战单位不占用**专职侦察**分支，而是走"前压探索"（`attack_move`）。

        契约变更（2026-09-12 晚，用户要求"有钱就该派兵去探索"）：
        旧断言是"作战单位只能 regroup 回基地" —— 那正是"部队只会停下来等待"的来源；
        现在无可见敌人时它们必须向外前压。这里钉住两点：
        ① 不能用 `scout`（专职侦察航点是给无人机的，半径小、绕圈）；
        ② 必须真的给出一条向外推进的移动命令。
        """
        self.state["ai_controlled_units"] = ["U_s1"]
        tac = _tactical([
            _entity("unit_self", "U_s1", "soldier", pos=(20, 0, 20)),
            _entity("unit_self", "U_cc", "command_center", pos=(10, 0, 10)),
        ])
        intents = behavior_tree.micro_intents(self.state, tactical=tac)
        self.assertEqual({item["action"] for item in intents}, {"attack_move"})


class RegroupTest(unittest.TestCase):
    """散开的作战单位向前线集结点靠拢（不再回主基地）。"""

    def setUp(self):
        self.state = {
            "server_tick": TICK,
            "latest_snapshot_id": SNAPSHOT,
            "ai_controlled_units": ["U_s1", "U_s2", "U_s3"],
            "player_controlled_units": [],
        }

    def _tac(self):
        return _tactical([
            _entity("unit_self", "U_s1", "soldier", pos=(60, 0, 60)),
            _entity("unit_self", "U_s2", "soldier", pos=(80, 0, 20)),
            _entity("unit_self", "U_s3", "tank", pos=(90, 0, 90)),
            _entity("unit_self", "U_cc", "command_center", pos=(10, 0, 10)),
        ])

    def test_combat_units_regroup_to_same_target_when_advance_disabled(self):
        """关掉前压后，空闲作战单位集结到同一个前线点（不是主基地）。"""
        intents = behavior_tree.micro_intents(
            self.state, tactical=self._tac(),
            config={"allow_forward_advance": False, "allow_idle_regroup": True})
        self.assertEqual(len(intents), 3)
        self.assertEqual({item["action"] for item in intents}, {"regroup"})
        targets = [item["target"] for item in intents]
        self.assertEqual(targets[0], targets[1],
                         "全队必须同一目标，否则仲裁层合并不了、也就看不到批量指挥")
        self.assertEqual(targets[1], targets[2])
        self.assertNotEqual(targets[0]["pos"], [10.0, 10.0], "集结点不得再是主基地")
        point = targets[0]["pos"]
        self.assertGreater(math.hypot(point[0] - 10.0, point[1] - 10.0), 12.0)

    def test_can_be_disabled_explicitly(self):
        intents = behavior_tree.micro_intents(
            self.state, tactical=self._tac(),
            config={"allow_forward_advance": False, "allow_idle_regroup": False})
        self.assertEqual(intents, [], "两个兜底都显式关闭后，空闲作战单位不下发任何命令")

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


class DefendQuotaTest(unittest.TestCase):
    """【2026-09-22 D17 回防配额】受袭只放行"来犯之敌+余量"个单位回防。

    实测（det_55）：EASY 反复搔扰我家，`bt-defend`（优先级 92）把回防圈内**所有**
    单位摁在家里——56 个作战单位 50 个堆在离家 15m 内，前探令（优先级 2）永远被压，
    用户截图"攻击移动 3 个单位"。用户指令："生产部队只留少部分在家，其他都去
    探索和进攻。"配额外的单位必须落回交火/前压分支。
    """

    def _tac(self, near=1, far=1, enemies=1):
        entities = [_entity("unit_self", "U_cc", "command_center", pos=(0, 0, 0),
                            movement=False, queue=True)]
        names = []
        for i in range(near):
            name = "U_near%d" % i
            entities.append(_entity("unit_self", name, "soldier", pos=(6 + i, 0, 6)))
            names.append(name)
        for i in range(far):
            name = "U_far%d" % i
            entities.append(_entity("unit_self", name, "soldier", pos=(30 + i, 0, 30)))
            names.append(name)
        for i in range(enemies):
            entities.append(_entity("unit_enemy", "E_%d" % i, unit_type="soldier",
                                    pos=(10 + i, 0, 8)))
        return {"entities": entities}, names

    def _run(self, tac, units):
        state = {"server_tick": 1000, "latest_snapshot_id": 3,
                 "ai_controlled_units": units, "player_controlled_units": []}
        intents = behavior_tree.micro_intents(state, tactical=tac)
        out = {}
        for item in intents:
            for u in item["unit_ids"]:
                out[str(u)] = item
        return out

    def test_quota_limits_defenders(self):
        """圈内 4 个、来犯 1 个 → 回防数 ≤ 配额（敌+2=3），且**必须有人去打仗**。

        不写死"恰好 3 个"：阶梯骨架会先认领一个单位去出击（rule-attack），
        真正要钉的不变式是"不全军蹲守"——至少一个单位在手上来犯之敌交战。
        """
        tac, names = self._tac(near=4, far=0, enemies=1)
        out = self._run(tac, names)
        defenders = [u for u, it in out.items() if it["action"] == "defend"]
        fighters = [u for u, it in out.items()
                    if it["action"] in ("attack", "attack_move")]
        self.assertLessEqual(len(defenders), 3,
                             "回防数不得超过配额（来犯1+余量2）：%d" % len(defenders))
        self.assertTrue(fighters, "必须有人去打仗，不许全军蹲守：%s" % out)

    def test_quota_grows_with_attackers(self):
        """来犯 6 个 → 配额 8（上限 10）：圈内 10 个单位不能全回防。"""
        tac, names = self._tac(near=10, far=0, enemies=6)
        out = self._run(tac, names)
        defenders = [u for u, it in out.items() if it["action"] == "defend"]
        self.assertLessEqual(len(defenders), 8,
                             "配额应随来犯规模增长但受限（上限 10）：%d" % len(defenders))
        self.assertGreater(len(defenders), 3,
                           "来犯多时回防力量也要够：%d" % len(defenders))

    def test_far_units_never_defend(self):
        """远处的单位永远不进回防配额（它们该去探索/进攻）。"""
        tac, names = self._tac(near=2, far=3, enemies=2)
        out = self._run(tac, names)
        for name in names:
            if name.startswith("U_far"):
                self.assertNotEqual(out[name]["action"], "defend",
                                    "远处单位不该被召回守家：%s" % out[name])


if __name__ == "__main__":
    unittest.main()
