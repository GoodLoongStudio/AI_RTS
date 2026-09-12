# -*- coding: utf-8 -*-
"""**无模型连续运行**的端到端模拟：规则中台必须沿主线真实发展。

对应纠偏文档的最低验收 1：
> 无模型连续对局：阶段和里程碑真实推进，至少出现产能建筑、兵力增长、扩张候选；
> 满足条件后实际建成第二基地/分矿，不能只产生日志。

这里用一个**确定性世界模型**（会真的施工、真的出兵、真的移动）替换 Godot 权威端，
因此断言全部落在"游戏内客观事实"上（世界里有没有这座建筑、有没有这个单位），
而不是"生成了 plan / 生成了 task / 打了日志"。

真机验收另做（真实对局）；本文件是**防止规则侧退化的守门测试** ——
任何一次把"规则沿主线发展"改坏（阶梯顺序、施工串行、扩张落点、里程碑证据），
这里就会红。
"""

from __future__ import annotations

import unittest

from adjutant_coordinator.graph import campaign as cm
from adjutant_coordinator.graph.graph import FallbackRunner
from adjutant_coordinator.graph.nodes import GraphConfig, GraphServices
from adjutant_coordinator.graph.state import AdjutantGraphState

MATCH = "m-sim"
PLAYER = "Player_1"
RULES = "hash-sim"

BASE = (10.0, 10.0)
NEAR_RESOURCE = (14.0, 12.0)
FAR_RESOURCE = (70.0, 70.0)

BUILD_TICKS = 600          # 施工时长（60Hz → 10s）
PRODUCE_TICKS = 300        # 生产时长（→ 5s）
MOVE_SPEED = 1.0           # 米/tick

SCENE = {
    "command_center": "res://buildings/CommandCenter.tscn",
    "barracks": "res://buildings/Barracks.tscn",
    "vehicle_factory": "res://buildings/VehicleFactory.tscn",
    "aircraft_factory": "res://buildings/AircraftFactory.tscn",
    "anti_air_turret": "res://buildings/AntiAirTurret.tscn",
    "anti_ground_turret": "res://buildings/AntiGroundTurret.tscn",
    "worker": "res://units/Worker.tscn",
    "soldier": "res://units/Soldier.tscn",
    "tank": "res://units/Tank.tscn",
    "helicopter": "res://units/Helicopter.tscn",
    "drone": "res://units/Drone.tscn",
}
SCENE_TO_ID = {value: key for key, value in SCENE.items()}

RULES_VIEW = {
    "match_id": MATCH,
    "rules_version": {"content_hash": RULES, "version": 1},
    "unit_types": [{"id": key, "scene_path": value} for key, value in SCENE.items()],
    "constructions": [
        {"id": key, "blueprint_scene_path": SCENE[key],
         "cost": [{"kind": "A", "amount": 600}]}
        for key in ("barracks", "vehicle_factory", "aircraft_factory",
                    "anti_air_turret", "anti_ground_turret", "command_center")
    ],
    "productions": [
        {"product_type_id": "worker", "allowed_producer_type_ids": ["command_center"],
         "cost": [{"kind": "A", "amount": 200}]},
        {"product_type_id": "soldier", "allowed_producer_type_ids": ["barracks"],
         "cost": [{"kind": "A", "amount": 150}]},
        {"product_type_id": "tank", "allowed_producer_type_ids": ["vehicle_factory"],
         "cost": [{"kind": "A", "amount": 500}]},
    ],
}


class SimWorld:
    """确定性世界模型：真的施工 / 真的出兵 / 真的移动（不是"回执恒 Accepted"的桩）。"""

    def __init__(self) -> None:
        self.tick = 0
        self.balance = {"A": 50000}
        self.units: dict = {}
        self.resources = {"R_near": list(NEAR_RESOURCE), "R_far": list(FAR_RESOURCE)}
        self._seq = 0
        self._sites = []      # (完成 tick, 名称)
        self._orders = []     # (完成 tick, 生产者, 产物)
        self._moves = {}      # 单位 → [x, z]
        self.accepted = []
        self.rejected = []
        # 真实开局编队：主基地 + 2 工人（采集/建造）+ 1 无人机（侦察）。
        self._add("Unit_0", "command_center", BASE, queue=True, constructed=True)
        self._add("Unit_1", "worker", (BASE[0] + 2.0, BASE[1] + 2.0),
                  gather=True, construct=True)
        self._add("Unit_2", "worker", (BASE[0] + 3.0, BASE[1] - 1.0),
                  gather=True, construct=True)
        self._add("Unit_3", "drone", (BASE[0] - 1.0, BASE[1] + 3.0), movement=True)

    # ---- 世界演化 ----

    def _add(self, name, unit_type, pos, **flags):
        self.units[name] = {
            "kind": "unit_self", "name": name, "unit_type": unit_type,
            "pos": [float(pos[0]), 0.0, float(pos[1])], "hp": 100.0, "hp_max": 100.0,
            "movement": bool(flags.get("movement", unit_type in
                                       ("worker", "soldier", "tank", "helicopter",
                                        "drone"))),
            "gather": bool(flags.get("gather", False)),
            "construct": bool(flags.get("construct", False)),
            "queue": bool(flags.get("queue", False)),
            "constructed": bool(flags.get("constructed", True)),
        }
        return name

    def _next_name(self, unit_type):
        self._seq += 1
        return "%s_%d" % (unit_type, self._seq)

    def advance(self, ticks: int) -> None:
        self.tick += ticks
        for name, target in list(self._moves.items()):
            unit = self.units.get(name)
            if unit is None:
                self._moves.pop(name, None)
                continue
            x, z = unit["pos"][0], unit["pos"][2]
            dx, dz = target[0] - x, target[1] - z
            distance = (dx * dx + dz * dz) ** 0.5
            if distance <= MOVE_SPEED * ticks:
                unit["pos"] = [float(target[0]), 0.0, float(target[1])]
                self._moves.pop(name, None)
                continue
            unit["pos"] = [x + dx / distance * MOVE_SPEED * ticks, 0.0,
                           z + dz / distance * MOVE_SPEED * ticks]
        for site in list(self._sites):
            if self.tick >= site[0]:
                name = site[1]
                if name in self.units:
                    self.units[name]["constructed"] = True
                self._sites.remove(site)
        for order in list(self._orders):
            if self.tick >= order[0]:
                self._orders.remove(order)
                self._add(self._next_name(order[2]), order[2], order[1])

    # ---- 权威端 ----

    def dispatch(self, envelopes):
        receipts = []
        for envelope in envelopes:
            action = str(envelope.get("action", ""))
            params = dict(envelope.get("params") or {})
            status, reason = self._apply(action, params)
            receipt = {"command_id": str(envelope.get("command_id", "")),
                       "intent_id": str(envelope.get("intent_id", "")),
                       "action": action, "status": status, "reason": reason,
                       "accepted": status == "Accepted", "result": {}}
            receipts.append(receipt)
            (self.accepted if receipt["accepted"] else self.rejected).append(receipt)
        return receipts

    def _apply(self, action, params):
        units = [str(u) for u in (params.get("units") or []) if str(u) in self.units]
        if not units:
            return "Rejected", "unknown units"
        if action == "build":
            scene = str(params.get("scene", ""))
            building = SCENE_TO_ID.get(scene)
            pos = params.get("pos") or [0.0, 0.0]
            if not building:
                return "Rejected", "NotBuildable"
            name = self._next_name(building)
            self._add(name, building, (float(pos[0]), float(pos[1])),
                      queue=building != "worker", constructed=False)
            self._sites.append((self.tick + BUILD_TICKS, name))
            return "Accepted", ""
        if action == "produce":
            scene = str(params.get("scene", ""))
            product = SCENE_TO_ID.get(scene)
            producer = str(params.get("producer", ""))
            if not product or producer not in self.units:
                return "Rejected", "ProductNotAllowed"
            if self.units[producer].get("constructed") is False:
                return "Rejected", "ProducerNotConstructed"
            self._orders.append((self.tick + PRODUCE_TICKS, list(
                self.units[producer]["pos"])[::2], product))
            return "Accepted", ""
        if action in ("move", "attack_move", "scout", "defend", "regroup", "retreat"):
            dest = params.get("dest")
            if not isinstance(dest, (list, tuple)) or len(dest) < 2:
                return "Rejected", "missing dest"
            for unit in units:
                self._moves[unit] = [float(dest[0]), float(dest[1])]
            return "Accepted", ""
        if action in ("gather", "attack", "hold", "stop"):
            return "Accepted", ""
        return "Rejected", "unsupported:%s" % action

    # ---- 观测 ----

    def entities(self):
        out = [dict(unit) for unit in self.units.values()]
        for name, pos in self.resources.items():
            out.append({"kind": "resource", "name": name,
                        "pos": [pos[0], 0.0, pos[1]]})
        return out

    def observation(self, tick):
        header = {"schema_version": 1, "match_id": MATCH, "player_id": PLAYER,
                  "rules_version": RULES, "snapshot_id": tick, "server_tick": tick}
        tactical = {"schema_version": 1, "match_id": MATCH, "player_id": PLAYER,
                    "rules_version": RULES, "snapshot_id": tick, "server_tick": tick,
                    "entities": self.entities(), "balance": dict(self.balance),
                    "production": [], "truncated": False, "next_offset": -1,
                    "outcome": {"finished": False}}
        strategic = {"map_bounds": [200.0, 200.0], "enemy_intel": [],
                     "resources": dict(self.balance)}
        return {"header": header, "tactical": tactical, "strategic": strategic,
                "events": [], "rules": RULES_VIEW}

    # ---- 查询 ----

    def built(self, unit_type):
        return [name for name, unit in self.units.items()
                if unit["unit_type"] == unit_type and unit.get("constructed") is not False]

    def count(self, unit_type):
        return len(self.built(unit_type))


class NoModelDevelopmentTest(unittest.TestCase):
    def _run(self, ticks=7200, step=60, model_kind=None):
        world = SimWorld()
        tactics_model = None
        if model_kind:
            # 与 runner `--model timeout|empty|invalid` 走的是**同一个**故障注入类
            # （生产代码路径），因此这里测的就是生产链路。
            from adjutant_coordinator.deploy.agent_runner import FaultTacticsModel
            tactics_model = FaultTacticsModel(model_kind)
        services = GraphServices(dispatch=world.dispatch, tactics_model=tactics_model,
                                 config=GraphConfig(pause_on_player_interrupt=False))
        runner = FallbackRunner(services)
        state = AdjutantGraphState(match_id=MATCH, player_id=PLAYER).to_dict()
        state["strategy_disabled"] = True
        trace = {"ever_candidate": False, "ever_probe": False, "phases": []}
        for tick in range(step, ticks + 1, step):
            world.advance(step)
            state = runner.run_tick(state, observation=world.observation(tick), tick=tick)
            campaign = state["campaign_state"]
            # 扩张候选是**每 tick 重算的视图**（不是历史），所以要看"是否出现过"。
            if campaign.get("expansion_candidates"):
                trace["ever_candidate"] = True
            if campaign.get("expansion_probe"):
                trace["ever_probe"] = True
            phase = str(campaign.get("phase", ""))
            if not trace["phases"] or trace["phases"][-1] != phase:
                trace["phases"].append(phase)
        return world, state, trace

    def test_rule_floor_develops_along_mainline_without_model(self):
        world, state, trace = self._run()
        campaign = state["campaign_state"]
        summary = cm.summary(campaign)
        done = set(summary.get("done") or [])
        # 1) 阶段真的推进（不是停在"摸底"）。
        self.assertNotIn(summary["phase"], ("", cm.PHASE_RECON),
                         "无模型跑了 2 分钟还停在摸底阶段：规则中台没有沿主线推进")
        # 2) 产能建筑**真的在游戏里建成**（不是"发过 build"）。
        production = [name for key in ("barracks", "vehicle_factory", "aircraft_factory")
                      for name in world.built(key)]
        self.assertTrue(production, "整局没有任何产能建筑完工")
        self.assertIn(cm.M02, done)
        # 3) 兵力真的增长（世界里的作战单位数）。
        combat = sum(world.count(key) for key in ("soldier", "tank", "helicopter"))
        self.assertGreaterEqual(combat, 2, "兵力没有增长（作战单位 %d）" % combat)
        self.assertIn(cm.M03, done)
        # 4) 扩张候选真的被算出来（满足条件后进入分基地链）。
        self.assertTrue(trace["ever_candidate"],
                        "整局没有算出任何扩张候选落点（主线卡在扩张选址）")
        self.assertIn(cm.M04, done)
        # 阶段轨迹必须真的推进（摸底 → …），而不是原地打转。
        self.assertGreaterEqual(len(trace["phases"]), 3,
                                "阶段几乎没有变化：%s" % trace["phases"])
        # 5) **实际建成第二基地/分矿**（世界里的实体，不是日志）。
        self.assertGreaterEqual(world.count("command_center"), 2,
                                "第二座指挥中心没有真的建成")
        self.assertIn(cm.M05, done)

    def test_no_model_run_never_starves_economy(self):
        """发展不能以"工人全去盖房子、矿不采了"为代价（四条线同时推进）。"""
        world, state, _ = self._run(ticks=3600)
        gather_orders = [item for item in world.accepted if item["action"] == "gather"]
        build_orders = [item for item in world.accepted if item["action"] == "build"]
        self.assertTrue(gather_orders, "整局没有任何采集命令被接受")
        self.assertTrue(build_orders, "整局没有任何建造命令被接受")
        workers = sum(1 for unit in world.units.values()
                      if unit["unit_type"] == "worker")
        self.assertGreaterEqual(workers, 2, "工人数量掉到 2 以下（经济线被抽干）")

    def test_model_failure_injection_does_not_stall_development(self):
        """模型 timeout / 空输出 / 非法输出时，主线与已有任务照常推进（纠偏 §5）。"""
        for kind in ("timeout", "empty", "invalid"):
            with self.subTest(kind=kind):
                world, state, trace = self._run(ticks=5400, model_kind=kind)
                done = set(cm.summary(state["campaign_state"]).get("done") or [])
                self.assertIn(cm.M01, done, kind)
                production = [name for key in ("barracks", "vehicle_factory")
                              for name in world.built(key)]
                self.assertTrue(production, "模型档 %s：产能建筑没有真的建成" % kind)
                combat = sum(world.count(key) for key in ("soldier", "tank",
                                                          "helicopter"))
                self.assertGreaterEqual(combat, 1,
                                        "模型档 %s：兵力没有增长" % kind)
                self.assertTrue(trace["ever_candidate"],
                                "模型档 %s：扩张链没有推进" % kind)

    def test_campaign_state_grows_monotonically(self):
        """里程碑只增不减：任何时刻都不允许把已完成的节点退回 pending。"""
        world = SimWorld()
        services = GraphServices(dispatch=world.dispatch,
                                 config=GraphConfig(pause_on_player_interrupt=False))
        runner = FallbackRunner(services)
        state = AdjutantGraphState(match_id=MATCH, player_id=PLAYER).to_dict()
        state["strategy_disabled"] = True
        seen: set = set()
        for tick in range(60, 3600 + 1, 60):
            world.advance(60)
            state = runner.run_tick(state, observation=world.observation(tick), tick=tick)
            milestones = state["campaign_state"]["milestones"]
            done = {key for key, value in milestones.items()
                    if str(value.get("status")) == "done"}
            self.assertTrue(seen <= done, "里程碑被退回：%s" % sorted(seen - done))
            seen = done


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
