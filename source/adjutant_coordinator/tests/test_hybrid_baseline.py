# -*- coding: utf-8 -*-
"""混合架构纠偏的回归：**规则中台常驻**，模型只做稀疏覆盖。

对应 `docs/程序文档/AI副官_混合架构纠偏提示词_2026-09-12.md` 的第三/五节：
- 模型关闭、超时、空批次、非法输出，都不得让本轮 baseline 消失（§三-2）；
- `route` 不得成为规则/行为树的运行门控，同一周期**不重复生成**（§三-3、§五-4）；
- `origin=baseline / behavior_tree / model` 必须可区分（§二）。

这些性质以前只在"模型成功"分支之外是偶然成立的（地板挂在缺口判据上），
所以必须有回归钉住 —— 否则很容易再次退化成"模型一有状况就整局不动"。
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph import squads  # noqa: E402
from adjutant_coordinator.graph import task_patch_bridge  # noqa: E402
from adjutant_coordinator.graph.task_patch import decode_task_patch  # noqa: E402
from adjutant_coordinator.graph.pydantic_agents import (  # noqa: E402
    ModelInvalidOutput, ModelTimeout,
)
from adjutant_coordinator.graph.rules_fallback import (  # noqa: E402
    in_map_bounds, pick_build_spot,
)
from adjutant_coordinator.graph.runtime import (  # noqa: E402
    AdjutantGraphRuntime, RuntimeConfig,
)

MATCH = "m-hybrid"
PLAYER = "Player_1"
RULES = {
    "rules_version": {"content_hash": "hash-hybrid", "version": 1},
    "unit_types": [
        {"id": "worker", "scene_path": "res://units/Worker.tscn"},
        {"id": "command_center", "scene_path": "res://units/CommandCenter.tscn"},
    ],
    "constructions": [
        {"id": "barracks", "blueprint_scene_path": "res://buildings/Barracks.tscn"},
    ],
    "productions": [
        {"product_type_id": "worker", "allowed_producer_type_ids": ["command_center"]},
    ],
}


class RecorderTransport:
    """记录下发的命令包（回执恒 Accepted，避免把权威行为混进本组断言）。"""

    def __init__(self):
        self.sent = []

    def __call__(self, envelope):
        self.sent.append(dict(envelope))
        return {"ok": True, "accepted": True, "status": "Accepted",
                "command_id": "cmd-%s" % envelope.get("intent_id", ""),
                "intent_id": str(envelope.get("intent_id", "")),
                "action": str(envelope.get("action", "")), "reason": "", "result": {}}


class Recorder:
    """结构化日志记录器（`GraphServices.logger` 的桩）。"""

    def __init__(self):
        self.events = []

    def log(self, event, **fields):
        self.events.append((str(event), dict(fields)))

    def kinds(self):
        return [name for name, _ in self.events]

    def of(self, kind):
        return [fields for name, fields in self.events if name == kind]


class _StubModel:
    """只暴露 `propose_task_patch`（四列接口），行为由构造参数决定。"""

    mode = "fast"

    def __init__(self, behavior):
        self.behavior = behavior
        self.inner = self

    def propose_task_patch(self, frame):
        if self.behavior == "timeout":
            raise ModelTimeout("stub timeout")
        if self.behavior == "invalid":
            raise ModelInvalidOutput("stub invalid")
        return None          # "empty"：模型成功但空批次


def observation(tick):
    return {
        "header": {"match_id": MATCH, "player_id": PLAYER,
                   "rules_version": "hash-hybrid",
                   "server_tick": tick, "snapshot_id": tick},
        "tactical": {"server_tick": tick, "snapshot_id": tick, "entities": [
            {"kind": "unit_self", "name": "Unit_0", "unit_type": "command_center",
             "queue": True, "construct": False, "gather": False, "pos": [10, 0, 7]},
            {"kind": "unit_self", "name": "Unit_2", "unit_type": "worker",
             "queue": False, "construct": True, "gather": True, "pos": [11, 0, 7]},
            {"kind": "resource", "name": "R_1", "pos": [14, 0, 9]},
        ]},
        "rules": RULES,
    }


def build(behavior):
    transport = RecorderTransport()
    recorder = Recorder()
    model = None if behavior == "off" else _StubModel(behavior)
    runtime = AdjutantGraphRuntime(
        MATCH, PLAYER, transport=transport, strategy_model=None,
        tactics_model=model, logger=recorder,
        config=RuntimeConfig(engine="fallback"),
    )
    return runtime, transport, recorder


class BaselineAlwaysOnTest(unittest.TestCase):
    """§三-2 / §三-3：模型任何状态都不能让 baseline 消失。"""

    def _assert_keeps_operating(self, behavior):
        runtime, transport, recorder = build(behavior)
        for tick in (1000, 1060):
            runtime.tick(tick, observation(tick))
        dispatched = [str(item.get("action", "")) for item in transport.sent]
        self.assertTrue(
            dispatched,
            "模型状态=%s 时 baseline 完全没有下发（副官变成'什么都不做'）：%s"
            % (behavior, dispatched))
        # 不写死具体动作：地盘上只有一个工人时，发展阶梯会优先认领他去建造
        # （`build` 是正确行为），此时他不采集。这里只要求"确实有运营动作下发"。
        self.assertTrue(
            set(dispatched) & {"gather", "build", "produce", "scout", "regroup", "move"},
            "模型状态=%s 时下发的都不是运营动作：%s" % (behavior, dispatched))
        floor = recorder.of("rule_floor")
        self.assertEqual(len(floor), 2,
                         "规则中台应当每 tick 恰好生成一次（两 tick = 2 次）：%d"
                         % len(floor))
        self.assertEqual(sorted({int(item.get("tick", -1)) for item in floor}),
                         [1000, 1060],
                         "规则中台被 route 门控了（不是每 tick 都跑）")

    def test_model_off_keeps_operating(self):
        self._assert_keeps_operating("off")

    def test_model_timeout_keeps_operating(self):
        self._assert_keeps_operating("timeout")

    def test_model_empty_keeps_operating(self):
        self._assert_keeps_operating("empty")

    def test_model_invalid_keeps_operating(self):
        self._assert_keeps_operating("invalid")

    def test_origins_are_distinguishable(self):
        runtime, transport, recorder = build("empty")
        runtime.tick(1000, observation(1000))
        arbitration = recorder.of("intent_arbitration")
        self.assertTrue(arbitration, "缺少 intent_arbitration 打点")
        origins = arbitration[-1].get("origins") or {}
        self.assertTrue(origins, "被采纳的意图没有来源标记")
        for intent_id, origin in origins.items():
            self.assertIn(origin, ("baseline", "behavior_tree", "model"),
                          "来源标记非法：%s=%s" % (intent_id, origin))
        self.assertTrue(any(origin in ("baseline", "behavior_tree")
                            for origin in origins.values()),
                        "模型空批次时，采纳的命令应当来自规则中台/行为树：%s" % origins)

    def test_symbol_named_origin_never_reaches_the_wire(self):
        """来源旁路账本不得污染协议载荷（`origin` 进契约会整条被拒）。"""
        runtime, transport, recorder = build("empty")
        runtime.tick(1000, observation(1000))
        for envelope in transport.sent:
            self.assertNotIn("origin", envelope,
                             "内部来源字段泄漏进了命令包：%s" % sorted(envelope))


class BuildSpotWithinVisionTest(unittest.TestCase):
    """模型侧建造落点必须落在**视野安全半径**内。

    实测依据（2026-09-12 晚，`model=on` 5 分钟局）：候选半径原本是 20/32m，结果
    213 条命令里 **172 条 `build` 被 `NotVisible` 拒** —— 权威端只接受己方视野内的落点，
    视野半径是 5m 量级（历史事实："基地+5m"能建成兵营，8/12/16m 全被拒）。
    把落点推到视野外只会换来清一色拒绝，还白抽走工人。
    """

    def test_frame_build_spots_stay_within_vision(self):
        obs = observation(1)
        frame = squads.build_decision_frame(
            match_id=MATCH, player_id=PLAYER, rules_version="h",
            snapshot_id=1, server_tick=1, tactical=obs["tactical"], rules=obs["rules"],
            map_bounds=[60.0, 60.0])
        self.assertTrue(frame.build_spots, "没有建造候选 = 模型无从下手")
        # 视野判据 = "离**某个己方实体**不超过安全半径"（与生成侧同一口径；
        # 不是"离基地不超过"——远处的士兵/工人同样提供视野）。
        points = [(float(entity["pos"][0]), float(entity["pos"][2]))
                  for entity in obs["tactical"]["entities"]
                  if "unit_self" in str(entity.get("kind", ""))
                  and len(entity.get("pos") or []) >= 3]
        self.assertTrue(points, "夹具里没有己方实体")
        for spot in frame.build_spots:
            self.assertLessEqual(squads.placement.first_own_distance(spot, points),
                                 squads.VISION_SAFE_RADIUS_M + 0.05,
                                 "落点超出视野安全半径（必被 NotVisible 拒）：%s" % (spot,))


class BuildSpotInsideMapTest(unittest.TestCase):
    """落点必须在**地图内**。

    实测依据（2026-09-12 晚，`model=off` 5 分钟真实局）：169 条回执里 163 条是
    `Rejected: OutOfBounds`，落点只有 `(4.3,1.3)` 与 `(10.0,-1.0)` 两个 ——
    都在地图外，于是阶梯在同一个坏点上来回重试，兵营之后**再也建不出任何东西**。
    """

    BOUNDS = [20.0, 20.0]

    def _by_name(self, x, z):
        return {"Unit_0": {"type": "command_center", "queue": True, "pos": [x, 0.0, z]},
                "Unit_2": {"type": "worker", "gather": True, "construct": True,
                           "pos": [x + 1.0, 0.0, z + 1.0]}}

    def test_base_near_edge_stays_inside(self):
        spot = pick_build_spot(self._by_name(10.0, 7.0), [], (10.0, 7.0),
                               bounds=self.BOUNDS)
        self.assertTrue(in_map_bounds(spot, self.BOUNDS), "落点越界：%s" % (spot,))

    def test_corner_base_stays_inside(self):
        spot = pick_build_spot(self._by_name(2.0, 2.0), [], (2.0, 2.0),
                               bounds=self.BOUNDS)
        self.assertTrue(in_map_bounds(spot, self.BOUNDS), "落点越界：%s" % (spot,))

    def test_all_ring_blocked_does_not_return_a_bad_point(self):
        blocked = [[6.0, 2.0], [2.0, 6.0], [3.9, 5.9], [0.1, 3.9],
                   [0.1, 0.1], [3.9, 0.1], [5.9, 3.9], [3.9, 3.9]]
        spot = pick_build_spot(self._by_name(2.0, 2.0), [], (2.0, 2.0),
                               blocked=blocked, bounds=self.BOUNDS)
        self.assertTrue(in_map_bounds(spot, self.BOUNDS), "落点越界：%s" % (spot,))
        self.assertFalse(
            any(((spot[0] - float(b[0])) ** 2 + (spot[1] - float(b[1])) ** 2) < 1.0
                for b in blocked), "兜底点又回到了已知坏点：%s" % (spot,))

    def test_no_bounds_keeps_legacy_behaviour(self):
        # 拿不到 bounds 时不猜地图形状，行为与改造前一致（长度 2 的 [x, z]）。
        spot = pick_build_spot(self._by_name(10.0, 7.0), [], (10.0, 7.0))
        self.assertEqual(len(spot), 2)

    def test_radii_stay_within_vision_and_candidates_stay_in_map(self):
        """半径环不得越出视野；小地图上**逐点**筛掉越界候选（而不是统一收缩半径）。

        统一收缩是错的：它会把"朝地图内侧、本来合法"的候选一起杀掉，
        贴边基地时甚至把整圈清空（表现成"基地一贴边就再也建不出东西"）。
        """
        radii = squads._placement_radii(10.0, 7.0, self.BOUNDS)
        self.assertTrue(all(radius <= squads.VISION_SAFE_RADIUS_M for radius in radii),
                        "半径环越出视野安全半径：%s" % (radii,))
        spots = squads.placement.candidate_spots(
            10.0, 7.0, bounds=self.BOUNDS, own_points=[(10.0, 7.0)],
            radii=radii, slots=squads.BUILD_PLACEMENT_SLOTS)
        self.assertTrue(spots, "小地图上不该一个候选都没有")
        for spot in spots:
            self.assertTrue(in_map_bounds(spot, self.BOUNDS),
                            "逐点筛选漏掉了越界候选：%s" % (spot,))


class OneBuilderPerSiteTest(unittest.TestCase):
    """同一工地本轮只许 **1 个** 建造者：其余工人必须继续采矿。

    用户 2026-09-12 晚："建造 1 个建筑就让一堆工人上，那矿不采了？"
    根因：候选表里同一集群的 N 个工人都能选到同一座建筑 → 模型发 N 条 `BLD`
    **完全合理**（候选即允许）→ 全队停工盖房、采集线停摆，
    违反决策手册 01 §3"四条线同时推进"。
    """

    def _frame(self, far=True):
        """`far=True` → 第二个工人放到远处（另一个集群）；False → 同集群。"""
        obs = observation(1000)
        # 【必须带 movement】`derive_squads` 会把"不可移动又不生产"的对象整个过滤掉
        # （防炮塔之类静态物进入执行者候选）—— 真实 `op=tactical` 里工人有 movement，
        # 夹具漏了它就会得到一个"没有工人执行者"的 frame（第一版就是这么假失败）。
        for entity in obs["tactical"]["entities"]:
            if str(entity.get("unit_type")) == "worker":
                entity["movement"] = True
        obs["tactical"]["entities"].append(
            {"kind": "unit_self", "name": "Unit_7", "unit_type": "worker",
             "pos": [60, 0, 40] if far else [12, 0, 9],
             "gather": True, "construct": True, "movement": True})
        state = {"match_id": MATCH, "player_id": PLAYER,
                 "ai_controlled_units": ["Unit_0", "Unit_2", "Unit_7"],
                 "unit_generations": {}}
        return task_patch_bridge.frame_from_state(state, obs)

    def test_build_options_rotate_one_worker_per_building(self):
        rules = {"constructions": [{"id": "barracks"}, {"id": "vehicle_factory"},
                                   {"id": "aircraft_factory"}]}
        options = squads._build_options(rules, {"W1", "W2"})
        self.assertEqual(len(options), 3, "每座建筑各有一条候选")
        # 同一建筑不得同时挂给多个工人（这是"一堆工人上同一个工地"的源头）。
        self.assertEqual(len({(o["building"], o["builder"]) for o in options}), 3)
        self.assertEqual(len({o["builder"] for o in options}), 2,
                         "应轮转分配，不能全压在同一个工人身上")

    def test_build_intent_uses_single_builder_from_cluster(self):
        """集群里有多名工人时，一条 `BLD` 只能派**一个人**去工地。

        （这就是"一堆工人上同一个工地"的真正机制：工人执行者是按位置聚合的**集群**，
        `unit_ids` 若直接取整个集群，一条建造令就等于"全队上工地"。）
        """
        frame = self._frame(far=False)
        worker = next(ref for ref, entry in frame.actors.items()
                      if str(entry.get("kind")) == "worker" and entry.get("buildings"))
        self.assertGreaterEqual(len(frame.actors[worker]["units"]), 2,
                                "本用例需要集群里至少两个工人")
        site = next(ref for ref, entry in frame.targets.items()
                    if str(entry.get("kind")) == "product"
                    and str(entry.get("category")) == "building")
        result = decode_task_patch([[worker, "BLD", site, "P0"]], frame)
        batch = task_patch_bridge.modifications_to_intents(result, frame)
        self.assertEqual(len(batch.intents), 1)
        self.assertEqual(len(batch.intents[0].unit_ids), 1,
                         "建造只能派 1 个工人（其余必须继续采矿）")

    def test_second_builder_for_same_site_is_rejected(self):
        """两个**不同**执行者抢同一工地：第二个必须被拒（`duplicate_build_site`）。"""
        frame = self._frame()
        workers = [ref for ref, entry in frame.actors.items()
                   if str(entry.get("kind")) == "worker" and entry.get("buildings")]
        self.assertGreaterEqual(len(workers), 2, "本用例需要两个能建造的执行者（不同集群）")
        site = next(ref for ref, entry in frame.targets.items()
                    if str(entry.get("kind")) == "product"
                    and str(entry.get("category")) == "building")
        result = decode_task_patch([[workers[0], "BLD", site, "P0"],
                                    [workers[1], "BLD", site, "P0"]], frame)
        self.assertEqual(len(result.modifications), 1)
        self.assertIn("duplicate_build_site",
                      [item.reason for item in result.rejections])


if __name__ == "__main__":
    unittest.main()
