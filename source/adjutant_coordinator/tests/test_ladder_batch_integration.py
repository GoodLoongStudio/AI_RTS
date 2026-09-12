# -*- coding: utf-8 -*-
"""发展阶梯与**模型意图合并**的集成测试（"有兵无营"的最后一环）。

## 为什么必须有这个测试

实测背景：阶梯本身离线调用完全正常（能产出 `barracks` build），但真实对局里
一局 90s **一条 build 都到不了游戏**。把 `_log` 打通后发现断点不在阶梯算法，
而在 `node_tactical_agent` 的**合并规则**：

- 阶梯挑的建造者，恰恰是模型每轮都在派去采集的那批工人
  （工人是可被抢占的低优先单位，阶梯就是靠这一点腾出人的）；
- 而合并时原按"该单位已被本批意图占用 → 跳过"**无条件**去重；
- 于 是阶梯的 build **每一条都被丢掉**，整局只剩采集。

这是"并集判据饿死阶梯"的同类 bug 换了个位置，所以要用测试钉住：
**发展动作（build/produce/attack）必须能抢占模型下发的低优先动作
（gather/scout/move/hold），反过来则让位。**
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph.nodes import (
    GraphConfig, GraphServices, NodeContext, node_tactical_agent,
)
from adjutant_coordinator.graph.pydantic_agents import FakeStructuredModel
from adjutant_coordinator.graph.state import AdjutantGraphState

from graph_test_helpers import MATCH, PLAYER, RULES, make_batch, make_intent

#: 阶梯能识别的规则：barracks 必须同时出现在 unit_types/constructions 里
#: （`rules_scene_index` 用它们把 id 归一化成真实场景路径）。
LADDER_RULES = {
    "match_id": MATCH,
    "rules_version": {"content_hash": RULES, "version": 1},
    "unit_types": [
        {"id": "worker", "scene_path": "res://units/Worker.tscn"},
        {"id": "soldier", "scene_path": "res://units/Soldier.tscn"},
        {"id": "barracks", "scene_path": "res://buildings/Barracks.tscn"},
        {"id": "command_center", "scene_path": "res://buildings/CommandCenter.tscn"},
    ],
    "constructions": [
        {"id": "barracks", "blueprint_scene_path": "res://buildings/Barracks.tscn"},
    ],
    "productions": [
        {"product_type_id": "worker", "allowed_producer_type_ids": ["command_center"]},
        {"product_type_id": "soldier", "allowed_producer_type_ids": ["barracks"]},
    ],
}


def unit(name, utype, *, construct=False, gather=False, queue=False, pos=(0, 0, 0)):
    return {"kind": "unit_self", "name": name, "unit_type": utype,
            "construct": construct, "gather": gather, "queue": queue, "pos": list(pos)}


def enemy(name, pos=(20, 0, 20)):
    return {"kind": "unit_enemy", "name": name, "pos": list(pos), "confirmed_dead": False}


class LadderBatchIntegrationTest(unittest.TestCase):

    def _state_dict(self, active_intents=()):
        state = AdjutantGraphState(match_id=MATCH, player_id=PLAYER)
        state.rules_version = RULES
        state.ensure_units(["Unit_0", "Unit_2"])
        data = state.to_dict()
        data["server_tick"] = 1000
        data["latest_snapshot_id"] = 5
        # 与 node_ingest 同口径：AI 托管单位 = 自有 − 玩家接管 − 已归还。
        data["ai_controlled_units"] = ["Unit_0", "Unit_2"]
        data["active_intents"] = [dict(item) for item in active_intents]
        return data

    def _observation(self, tick=1000):
        return {
            "tactical": {"server_tick": tick, "snapshot_id": tick, "entities": [
                unit("Unit_0", "command_center", queue=True, pos=(10, 0, 7)),
                unit("Unit_2", "worker", construct=True, gather=True, pos=(11, 0, 7)),
            ]},
            "rules": LADDER_RULES,
        }

    def _tactics_model(self, intents):
        return FakeStructuredModel("tactics", [{
            "behavior": "completed",
            "intents": make_batch(intents, based_on_snapshot=5),
        }])

    def test_ladder_build_preempts_model_gather_on_same_worker(self):
        """模型"成功但只回 gather"，且派的正是唯一的建造者 → 阶梯仍必须建出 barracks。"""
        data = self._state_dict()
        model = self._tactics_model([make_intent(
            "i-gather-1", action="gather", units=["Unit_2"],
            target={"entity_id": "R_1", "pos": [20.0, 20.0]},
            expires_tick=100000, generation=0)])
        ctx = NodeContext(services=GraphServices(config=GraphConfig(),
                                                tactics_model=model),
                          observation=self._observation(), tick=1000)

        data = node_tactical_agent(data, ctx)
        actions = [str(item.get("action")) for item in data["candidate_intents"]]
        self.assertIn("build", actions,
                      "阶梯的 build 被「单位已被本批占用」的无条件去重丢掉了")

    def test_model_gather_on_other_worker_survives_alongside_build(self):
        """抢占只发生在**同一单位**上：别的工人的采集意图必须原样保留。"""
        state = AdjutantGraphState(match_id=MATCH, player_id=PLAYER)
        state.rules_version = RULES
        state.ensure_units(["Unit_0", "Unit_2", "Unit_3"])
        data = state.to_dict()
        data["server_tick"] = 1000
        data["latest_snapshot_id"] = 5
        data["ai_controlled_units"] = ["Unit_0", "Unit_2", "Unit_3"]
        data["active_intents"] = []
        observation = {
            "tactical": {"server_tick": 1000, "snapshot_id": 5, "entities": [
                unit("Unit_0", "command_center", queue=True, pos=(10, 0, 7)),
                unit("Unit_2", "worker", construct=True, gather=True, pos=(11, 0, 7)),
                unit("Unit_3", "worker", construct=True, gather=True, pos=(12, 0, 7)),
            ]},
            "rules": LADDER_RULES,
        }
        model = self._tactics_model([
            make_intent("i-gather-3", action="gather", units=["Unit_3"],
                        target={"entity_id": "R_1", "pos": [20.0, 20.0]},
                        expires_tick=100000, generation=0),
        ])
        ctx = NodeContext(services=GraphServices(config=GraphConfig(),
                                                tactics_model=model),
                          observation=observation, tick=1000)

        data = node_tactical_agent(data, ctx)
        by_unit = {}
        for item in data["candidate_intents"]:
            for name in item.get("unit_ids") or []:
                by_unit.setdefault(str(name), []).append(str(item.get("action")))
        # Unit_3 的采集没有被无谓打断（阶梯没有认领它）。
        self.assertIn("gather", by_unit.get("Unit_3", []),
                      "无关工人的采集意图被误伤")
        # 而建造者被阶梯认领（build），不再同时挂一条 gather。
        self.assertIn("build", by_unit.get("Unit_2", []))

    def test_outnumbered_retreat_preempts_model_attack(self):
        """劣势撤离（行为树，优先级最高）必须能顶掉模型给同一个兵下的 attack。

        为什么钉这条：行为树的纪律是"求生 > 交战"，但若合并时按"单位已被占用即跳过"，
        模型那条 attack 会让撤离**永远发不出去** —— 正是"拿 1 个兵硬冲 3 个敌人"的成因。
        """
        observation = {
            "tactical": {"server_tick": 1000, "snapshot_id": 5, "entities": [
                unit("Unit_0", "command_center", queue=True, pos=(10, 0, 7)),
                unit("Unit_4", "soldier", pos=(20, 0, 7)),
                enemy("Enemy_1", (30, 0, 20)),
                enemy("Enemy_2", (31, 0, 20)),
                enemy("Enemy_3", (32, 0, 20)),
            ]},
            "rules": LADDER_RULES,
        }
        state = AdjutantGraphState(match_id=MATCH, player_id=PLAYER)
        state.rules_version = RULES
        state.ensure_units(["Unit_0", "Unit_4"])
        data = state.to_dict()
        data["server_tick"] = 1000
        data["latest_snapshot_id"] = 5
        data["ai_controlled_units"] = ["Unit_0", "Unit_4"]
        data["active_intents"] = []
        model = self._tactics_model([make_intent(
            "i-attack-4", action="attack", units=["Unit_4"],
            target={"entity_id": "Enemy_1"},
            expires_tick=100000, generation=0)])
        ctx = NodeContext(services=GraphServices(config=GraphConfig(),
                                                tactics_model=model),
                          observation=observation, tick=1000)

        data = node_tactical_agent(data, ctx)
        actions = {str(item.get("action")) for item in data["candidate_intents"]
                   if "Unit_4" in [str(u) for u in (item.get("unit_ids") or [])]}
        self.assertEqual(actions, {"retreat"},
                         "劣势撤离被模型的 attack 挡住了（求生优先级失效）")

    def test_ladder_never_touches_non_ai_units(self):
        """安全边界不回退：不在 `ai_controlled_units` 里的单位永不出现在意图中。"""
        data = self._state_dict()
        data["ai_controlled_units"] = ["Unit_0"]   # Unit_2 视为玩家接管
        data["player_controlled_units"] = ["Unit_2"]
        model = self._tactics_model([make_intent(
            "i-gather-1", action="gather", units=["Unit_0"],
            target={"entity_id": "R_1", "pos": [20.0, 20.0]},
            expires_tick=100000, generation=0)])
        ctx = NodeContext(services=GraphServices(config=GraphConfig(),
                                                tactics_model=model),
                          observation=self._observation(), tick=1000)
        data = node_tactical_agent(data, ctx)
        touched = {str(u) for item in data["candidate_intents"]
                   for u in (item.get("unit_ids") or [])}
        self.assertNotIn("Unit_2", touched)


if __name__ == "__main__":
    unittest.main()
