# -*- coding: utf-8 -*-
"""**打不了的目标不再派**（2026-09-13 用户："你下达命令不能瞎下达啊"）。

实测证据（真机档案，`archive_e4329752` 等）：一局 347 条命令里 **124 条**被同一条原因拒掉 ——
权威端原文："当前武器无法攻击该目标所处的域（地面/空中不匹配），请改打地面目标或用对空单位。"
而同一单位反复重发同一条（`Unit_43` 攻击命令被拒 **10** 次 ≈ 每 15 秒一次，正好撞上
`ORDER_REPEAT_WINDOW_TICKS` 的重发窗口）。

判定：**修正维度是"换目标"**（换个敌人就能打），不是换点、也不是停发前缀。
本文件钉住三件事：
① 拒因归类认得这条（`placement.REJECT_TARGET`）；
② 目标选择会把它剔除（`rules_fallback.attackable_enemies` / 行为树 `_attackable`）；
③ 回执结算时真的把记忆写进状态（`nodes._apply_receipt_to_state`）。
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph import nodes, placement, rules_fallback  # noqa: E402

AUTHORITY_REASON = ("当前武器无法攻击该目标所处的域（地面/空中不匹配），"
                    "请改打地面目标或用对空单位。")


def enemy(entity_id, unit_type="tank"):
    """观测里的敌方实体（带 `unit_type` —— 真机观测就是这个形状）。"""
    return {"name": entity_id, "unit_type": unit_type, "hp": 10.0}


class RejectClassificationTest(unittest.TestCase):
    def test_authority_text_is_classified_as_target_kind(self):
        """权威端的中文原文（真机回执）必须归到"目标"类 —— 新增原因只改 `placement`。"""
        self.assertEqual(placement.classify_rejection("Rejected " + AUTHORITY_REASON),
                         placement.REJECT_TARGET)
        self.assertEqual(placement.classify_rejection("Rejected WeaponCannotTargetDomain"),
                         placement.REJECT_TARGET)
        self.assertIn(placement.REJECT_TARGET, placement.TARGET_KINDS)


class AttackableEnemiesTest(unittest.TestCase):
    def test_banned_target_is_skipped_for_that_unit(self):
        state = {"server_tick": 1000}
        rules_fallback.ban_unattackable_target(state, ["Unit_43"], "E_air", 1000)
        enemies = [enemy("E_air"), enemy("E_ground")]
        self.assertEqual([rules_fallback.entity_id_of(e) for e in
                          rules_fallback.attackable_enemies(state, enemies, ["Unit_43"])],
                         ["E_ground"], "打不了的空中目标要被剔除，地面目标照打")

    def test_ban_is_per_unit_not_global(self):
        """按**单位×目标**记：防空单位打得了同一个目标，不该被地面单位的记忆误伤。"""
        state = {"server_tick": 1000}
        rules_fallback.ban_unattackable_target(state, ["Unit_43"], "E_air", 1000)
        enemies = [enemy("E_air")]
        self.assertEqual(len(rules_fallback.attackable_enemies(state, enemies, ["Unit_9"])), 1,
                         "别的单位不受影响（地空不匹配是武器属性）")

    def test_ban_by_type_stops_the_whole_class(self):
        """**按类型拉黑**：只按实体拉黑挡不住"下一轮换一个同类目标继续试"
        （实测 `Unit_43` 对空被拒 10 次 = 每轮换一个空中目标）——
        所以拒绝了空中目标后，**所有**空中目标都不再作为该单位的候选。"""
        state = {"server_tick": 1000, "enemy_types": {"E_air1": "helicopter",
                                                     "E_air2": "helicopter",
                                                     "E_ground": "tank"}}
        rules_fallback.ban_unattackable_target(state, ["Unit_43"], "E_air1", 1000,
                                              entity_type="helicopter")
        enemies = [enemy("E_air1", "helicopter"), enemy("E_air2", "helicopter"),
                   enemy("E_ground", "tank")]
        kept = [rules_fallback.entity_id_of(e) for e in
                rules_fallback.attackable_enemies(state, enemies, ["Unit_43"])]
        self.assertEqual(kept, ["E_ground"],
                         "同类目标（helicopter）全部剔除，地面目标照打")

    def test_ban_by_unit_type_teaches_the_whole_class(self):
        """**单位类型级**：一个士兵打不了无人机 → 所有士兵都不再被派去打无人机。

        【为什么必须再升一层（迭代实测）】武器域是**类型**的属性，不是个体的。
        只按个体学，就要为"每个单位 × 每种敌方类型"各付一次拒绝 ——
        实测 fix6 局在按个体+目标类型拉黑之后**仍残留 29 条**域不匹配（纯学习成本）。
        """
        state = {"server_tick": 1000,
                 "own_unit_types": {"Unit_24": "soldier", "Unit_25": "soldier",
                                    "Unit_30": "tank"},
                 "enemy_types": {"E_drone1": "drone", "E_drone2": "drone",
                                 "E_tank": "tank"}}
        rules_fallback.ban_unattackable_target(state, ["Unit_24"], "E_drone1", 1000,
                                              entity_type="drone")
        self.assertIn("type:soldier|type:drone", state["unattackable_targets"],
                      "要把『士兵打不了无人机』记成类型级事实")
        enemies = [enemy("E_drone1", "drone"), enemy("E_drone2", "drone"),
                   enemy("E_tank", "tank")]
        # 另一个**没被拒过**的士兵：也不该再被派去打无人机（学习成本归零的关键）
        self.assertEqual([rules_fallback.entity_id_of(e) for e in
                          rules_fallback.attackable_enemies(state, enemies, ["Unit_25"])],
                         ["E_tank"])
        # 坦克不受影响（类型不同）：它照样能打无人机（若有对空能力由权威判定）
        self.assertEqual(len(rules_fallback.attackable_enemies(state, enemies, ["Unit_30"])), 3,
                         "类型级拉黑不许跨类型误伤")

    def test_ban_expires(self):
        state = {"server_tick": 1000}
        rules_fallback.ban_unattackable_target(state, ["Unit_43"], "E_air", 1000)
        state["server_tick"] = 1000 + rules_fallback.TARGET_BAN_TICKS + 1
        self.assertEqual(len(rules_fallback.attackable_enemies(
            state, [enemy("E_air")], ["Unit_43"])), 1, "窗口过了允许再试（目标域可能变了）")

    def test_capability_filters_before_first_order(self):
        """F04：士兵对空事前剔除，不靠被拒一次才学。"""
        state = {"server_tick": 1000,
                 "own_unit_types": {"Unit_43": "soldier"},
                 "own_attack_domains": {"Unit_43": ["terrain"]}}
        enemies = [enemy("E_air", "drone"), enemy("E_ground", "tank")]
        enemies[0]["domain"] = "air"
        enemies[1]["domain"] = "terrain"
        kept = [rules_fallback.entity_id_of(item) for item in
                rules_fallback.attackable_enemies(state, enemies, ["Unit_43"])]
        self.assertEqual(kept, ["E_ground"],
                         "能力已知时首次下令就不能派士兵打空中目标")

    def test_ban_stays_until_capability_version_changes(self):
        """F04：能力未变时，1800 tick 后也不自动放行。"""
        state = {"server_tick": 1000, "capability_version": "hash-v1",
                 "rules_version": "hash-v1"}
        rules_fallback.ban_unattackable_target(state, ["Unit_43"], "E_air", 1000)
        state["server_tick"] = 1000 + rules_fallback.TARGET_BAN_TICKS + 1
        self.assertEqual(len(rules_fallback.attackable_enemies(
            state, [enemy("E_air")], ["Unit_43"])), 0,
            "同一能力版本不得靠时间遗忘")
        state["rules_version"] = "hash-v2"
        self.assertEqual(len(rules_fallback.attackable_enemies(
            state, [enemy("E_air")], ["Unit_43"])), 1,
            "能力版本变了才重新评估")

    def test_memory_is_bounded(self):
        state = {"server_tick": 1000}
        for index in range(400):
            rules_fallback.ban_unattackable_target(state, ["Unit_1"], "E_%d" % index, 1000)
        self.assertLessEqual(len(state["unattackable_targets"]), 256, "记忆必须有界")

    def test_attack_selection_picks_the_hittable_one(self):
        """出击选择（阶梯 3 口径）会跳过打不了的目标 —— 这是"别瞎下达"的落点。"""
        state = {"server_tick": 1000, "map_bounds": [80.0, 80.0],
                 "ai_controlled_units": ["Unit_4", "Unit_5"],
                 "nav_revision": 1}
        rules_fallback.ban_unattackable_target(state, ["Unit_4", "Unit_5"], "E_air", 1000)
        enemies = [enemy("E_air"), enemy("E_ground")]
        hittable = rules_fallback.attackable_enemies(state, enemies, ["Unit_4", "Unit_5"])
        self.assertEqual([rules_fallback.entity_id_of(e) for e in hittable], ["E_ground"])


class BehaviorTreeTargetTest(unittest.TestCase):
    def test_tree_skips_unattackable_enemy(self):
        from adjutant_coordinator.graph.behavior_tree import _attackable

        class FakeBlackboard(dict):
            pass

        bb = FakeBlackboard({"unit": "Unit_43", "server_tick": 1000,
                             "visible_enemies": ["E_air", "E_ground"],
                             "unattackable_targets": {"Unit_43|E_air": 1000}})
        self.assertEqual(_attackable(bb), ["E_ground"],
                         "树里选目标同样要先剔掉打不了的（否则命令刷屏、单位却打不出效果）")
        bb["server_tick"] = 1000 + rules_fallback.TARGET_BAN_TICKS + 1
        self.assertEqual(_attackable(bb), ["E_air", "E_ground"], "窗口过后重新允许")

    def test_tree_honours_type_ban(self):
        """树里也要认**目标类型**黑名单（与规则层同一实现）：同类目标全剔掉。"""
        from adjutant_coordinator.graph.behavior_tree import _attackable

        class FakeBlackboard(dict):
            pass

        bb = FakeBlackboard({"unit": "Unit_43", "server_tick": 1000,
                             "visible_enemies": ["E_air1", "E_air2", "E_ground"],
                             "enemy_types": {"E_air1": "helicopter", "E_air2": "helicopter",
                                             "E_ground": "tank"},
                             "unattackable_targets": {"Unit_43|type:helicopter": 1000}})
        self.assertEqual(_attackable(bb), ["E_ground"])

    def test_tree_honours_unit_type_ban(self):
        """树里也要认**单位类型级**黑名单（`type:soldier|type:drone`）。

        【迭代1 真机踩到】树这条路的 view 里漏了 `own_unit_types` → 类型键永远命不中，
        表现为"每个新单位各被拒一次"（一局 51 条域不匹配 ≈ 每单位一次），
        看起来像"按域拉黑没生效"。这条测试就是那道防线。
        """
        from adjutant_coordinator.graph.behavior_tree import _attackable

        class FakeBlackboard(dict):
            pass

        bb = FakeBlackboard({"unit": "Unit_102", "server_tick": 1000,
                             "visible_enemies": ["E_drone", "E_tank"],
                             "enemy_types": {"E_drone": "drone", "E_tank": "tank"},
                             "own_unit_types": {"Unit_102": "soldier"},
                             "unattackable_targets": {"type:soldier|type:drone": 1000}})
        self.assertEqual(_attackable(bb), ["E_tank"],
                         "没被拒过的士兵，也不该再被派去打无人机")


class ReceiptHookTest(unittest.TestCase):
    def _state_with_intent(self):
        return {
            "match_id": "m-1", "player_id": "Player_1", "server_tick": 1000,
            "active_intents": [{
                "intent_id": "rule-fill-attack-Unit_43", "action": "attack",
                "unit_ids": ["Unit_43"], "target": {"entity_id": "E_air"},
                "state": "active", "issued_tick": 1000, "expires_tick": 4000,
                "task_id": "rule-attack",
            }],
        }

    def test_domain_rejection_writes_the_memory(self):
        """回执说“武器域不匹配” → 写入记忆 + 留一条决策（**执行链闭环**）。"""
        data = self._state_with_intent()
        receipt = {"intent_id": "rule-fill-attack-Unit_43", "status": "Rejected",
                   "accepted": False, "reason": AUTHORITY_REASON,
                   "command_id": "c-1"}
        nodes._apply_receipt_to_state(data, "rule-fill-attack-Unit_43", receipt)
        self.assertIn("Unit_43|E_air", data.get("unattackable_targets") or {},
                      "拒绝必须变成『下次别再派』的记忆")
        kinds = [item.get("kind") for item in data.get("decision_log") or []]
        self.assertIn("target_unattackable", kinds, "必须留痕（否则复盘查不出为什么换目标）")

    def test_other_rejections_do_not_touch_target_memory(self):
        """别的拒因（几何/内容类）不许污染这张目标记忆（口径分叉一次就静默失效一次）。"""
        data = self._state_with_intent()
        receipt = {"intent_id": "rule-fill-attack-Unit_43", "status": "Rejected",
                   "accepted": False, "reason": "OutOfBounds", "command_id": "c-2"}
        nodes._apply_receipt_to_state(data, "rule-fill-attack-Unit_43", receipt)
        self.assertFalse(data.get("unattackable_targets"),
                         "几何类拒因不该拉黑目标")


class BuildBackoffEscalationTest(unittest.TestCase):
    """**升级退避**：连续建造被拒时窗口加倍（一片地形整体不可建时别一直换点烧命令）。

    实测（2026-09-14 迭代4）：固定 900 tick 的退避下，一局仍打出 10 次
    `SurfaceNotBuildable`（每 15 秒换一个新点再试，而这片地根本不可建）。
    """

    def _intent_id(self, tick):
        return "rule-build-barracks-Unit_16-%d" % tick

    def _reject_build(self, state, tick):
        """在同**一个** state 上结算一条 `SurfaceNotBuildable` 拒绝（模拟真实回写路径）。"""
        intent_id = self._intent_id(tick)
        state["server_tick"] = tick
        state["active_intents"] = [{
            "intent_id": intent_id, "action": "build", "unit_ids": ["Unit_16"],
            "target": {"pos": [10.0, 7.0]}, "state": "active",
            "issued_tick": tick, "expires_tick": tick + 3600}]
        nodes._apply_receipt_to_state(state, intent_id,
                                      {"intent_id": intent_id, "status": "Rejected",
                                       "accepted": False, "reason": "SurfaceNotBuildable",
                                       "command_id": "c"})
        return state

    def test_window_doubles_then_caps(self):
        state = {"server_tick": 1000}
        windows = []
        for round_index in range(4):
            for _ in range(3):                       # 每 3 次连续失败触发一次退避
                self._reject_build(state, 1000 + round_index * 10)
            windows.append(int(state["build_backoff_until_tick"]) - state["server_tick"])
        self.assertEqual(windows, [900, 1800, 3600, 7200],
                         "退避要逐级加倍并封顶 7200 tick（2 分钟）")

    def test_success_resets_the_level(self):
        state = {"server_tick": 1000}
        for _ in range(3):
            self._reject_build(state, 1000)
        self.assertEqual(state["build_backoff_level"], 1)
        # 某次建造成功 → 等级清零（否则后续偶发失败直接吃 2 分钟大退避）
        intent_id = self._intent_id(2000)
        state["server_tick"] = 2000
        state["active_intents"] = [{"intent_id": intent_id, "action": "build",
                                    "unit_ids": ["Unit_16"], "target": {"pos": [12.0, 7.0]},
                                    "state": "active", "issued_tick": 2000,
                                    "expires_tick": 5600}]
        nodes._apply_receipt_to_state(state, intent_id,
                                      {"intent_id": intent_id, "status": "Accepted",
                                       "accepted": True, "command_id": "c2", "result": {}})
        self.assertEqual(state["build_backoff_level"], 0)


class StateFieldTest(unittest.TestCase):
    def test_memory_survives_checkpoint_round_trip(self):
        """记忆必须随 checkpoint 往返（`state.py` 显式字段）—— 否则每轮被丢掉、形同虚设。"""
        from adjutant_coordinator.graph.state import AdjutantGraphState

        state = AdjutantGraphState(match_id="m-1", player_id="Player_1")
        state.unattackable_targets = {"Unit_43|E_air": 1000}
        restored = AdjutantGraphState.from_dict(state.to_dict())
        self.assertEqual(restored.unattackable_targets, {"Unit_43|E_air": 1000})

    def test_memory_survives_a_full_round_trip(self):
        """**活过一轮**：`to_dict`（图入口）→ 图内结算拒绝 → `from_dict`（图出口）→ 再用。

        这一条钉的是真机里最容易出问题的环节：图每一轮都是
        `state_dict = state.to_dict()` … `state = from_dict(out)`（`runtime.tick`），
        字段漏了就会"这轮写、下轮没"，表现是**同一条坏命令每轮重发**
        （实测 `Unit_43` 被拒 10 次）。
        """
        from adjutant_coordinator.graph.state import AdjutantGraphState

        state = AdjutantGraphState(match_id="m-1", player_id="Player_1")
        data = state.to_dict()                       # 图入口
        data["server_tick"] = 1000
        data["enemy_types"] = {"E_air": "helicopter"}
        data["active_intents"] = [{
            "intent_id": "rule-fill-attack-Unit_43", "action": "attack",
            "unit_ids": ["Unit_43"], "target": {"entity_id": "E_air"},
            "state": "active", "issued_tick": 1000, "expires_tick": 4000,
        }]
        nodes._apply_receipt_to_state(
            data, "rule-fill-attack-Unit_43",
            {"intent_id": "rule-fill-attack-Unit_43", "status": "Rejected",
             "accepted": False, "reason": AUTHORITY_REASON, "command_id": "c-1"})
        restored = AdjutantGraphState.from_dict(data)      # 图出口（runtime.tick 同一路径）
        self.assertIn("Unit_43|E_air", restored.unattackable_targets)
        self.assertIn("Unit_43|type:helicopter", restored.unattackable_targets,
                      "要按**类型**也记一条，否则下一轮换个同类目标继续试")
        # 下一轮：记忆还在，且目标选择已经看不到这一类目标
        next_round = restored.to_dict()
        next_round["server_tick"] = 1100
        kept = rules_fallback.attackable_enemies(
            next_round, [enemy("E_air2", "helicopter"), enemy("E_ground", "tank")],
            ["Unit_43"])
        self.assertEqual([rules_fallback.entity_id_of(e) for e in kept], ["E_ground"])


if __name__ == "__main__":
    unittest.main()
