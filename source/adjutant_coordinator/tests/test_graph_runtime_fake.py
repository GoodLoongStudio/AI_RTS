# -*- coding: utf-8 -*-
"""运行时测试（FakeModel，不需要 API Key）：

1. 战略计划 → 紧急战术意图 → 权威下发 → 回执；
2. 玩家打断立即生效、图暂停/恢复、旧意图不能抢回、显式归还后重新接管；
3. PendingAuthority 不重复下单，复核终态后结算；
4. checkpoint 恢复后不重复下单；
5. 模型超时/连续失败降级与冷却（Godot 不阻塞）；
6. LangGraph 引擎与内置执行器行为一致（未安装 langgraph 时跳过）。
"""

import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph.checkpoint import JsonCheckpointStore, MemoryCheckpointStore
from adjutant_coordinator.graph.graph import langgraph_available
from adjutant_coordinator.graph.pydantic_agents import FakeStructuredModel
from adjutant_coordinator.graph.runtime import AdjutantGraphRuntime, RuntimeConfig

from graph_test_helpers import (
    MATCH, PLAYER, RecordingTransport, events_for, header, make_batch, make_intent,
    make_plan, rules_view, strategic, tactical,
)

ENGINE_FALLBACK = "fallback"
ENGINE_LANGGRAPH = "langgraph"


def base_config(engine=ENGINE_FALLBACK, **overrides):
    config = RuntimeConfig(
        engine=engine,
        strategy_interval_ticks=100000,
        tactics_interval_ticks=1,
        emergency_min_interval_ticks=1,
        intent_ttl_ticks=600,
        emergency_intent_ttl_ticks=300,
        pending_timeout_ticks=1000,
        pause_on_player_interrupt=True,
    )
    for key, value in overrides.items():
        setattr(config, key, value)
    return config


def observation(tick, events=None, own=None, enemies=None, match_id=MATCH,
                rules_version=None):
    return {
        "header": header(tick, match_id=match_id,
                         rules_version=rules_version or None or "hash-graph-1"),
        "strategic": strategic(tick),
        "tactical": tactical(own=own, enemies=enemies, server_tick=tick),
        "rules": rules_view(),
        "events": list(events or []),
        "budget": {},
    }


class RuntimeFixture:
    """组装运行时：假模型 + 通道桩 + 内存 checkpoint。"""

    def __init__(self, strategy_script=None, tactics_script=None, transport=None,
                 config=None, store=None, recheck_fn=None):
        self.transport = transport or RecordingTransport()
        self.store = store or MemoryCheckpointStore()
        self.strategy = FakeStructuredModel("strategy", strategy_script or [])
        self.tactics = FakeStructuredModel("tactics", tactics_script or [])
        self.runtime = AdjutantGraphRuntime(
            MATCH, PLAYER, transport=self.transport,
            strategy_model=self.strategy, tactics_model=self.tactics,
            checkpoint_store=self.store, config=config or base_config(),
            recheck_fn=recheck_fn)
        self.runtime.restore()

    def tick(self, tick, events=None, own=None, enemies=None, match_id=MATCH):
        return self.runtime.tick(
            tick, observation(tick, events=events, own=own, enemies=enemies,
                              match_id=match_id))


#: 规则地板的下发前缀（见 model_sends 的理由）。
FLOOR_INTENT_PREFIXES = ("rule-", "bt-")


def is_floor_intent(intent_id) -> bool:
    return str(intent_id or "").startswith(FLOOR_INTENT_PREFIXES)


def model_sends(sent):
    """只挑**模型来源**的下发。

    2026-09-12 架构纠偏（§三-3）后规则地板每轮常驻，会另外下发 `rule-*` / `bt-*` 意图
    （这是设计要的：模型慢或缺席时 AI 照常指挥）。因此"模型不许自己乱发命令"这类
    契约必须按**来源**判，而不是数总条数 —— 数总条数会把地板的正常下发算成违规。
    """
    return [item for item in sent if not is_floor_intent(item.get("intent_id"))]


class PlanAndDispatchTest(unittest.TestCase):
    def test_strategy_plan_then_emergency_intent_is_dispatched(self):
        fixture = RuntimeFixture(
            strategy_script=[{"behavior": "completed", "plan": make_plan()}],
            tactics_script=[{"behavior": "completed", "intents": make_batch(
                [make_intent("i-1", issued_tick=5, expires_tick=605)])}])
        first = fixture.tick(0)
        self.assertEqual(first.route, "strategic")
        self.assertEqual(fixture.runtime.state.plan_version, "plan-a:v1")
        self.assertEqual(model_sends(fixture.transport.sent), [],
                         "只有计划被采纳、战术还没答话 → 不许有模型来源的命令")

        second = fixture.tick(5, events=[events_for("enemy_spotted", ["Unit_1"], 5)])
        self.assertEqual(second.route, "emergency_tactical")
        self.assertEqual(second.accepted_intents, ["i-1"])
        self.assertEqual(len(model_sends(fixture.transport.sent)), 1)
        envelope = model_sends(fixture.transport.sent)[0]
        self.assertEqual(envelope["op"], "adjutant_intent")
        self.assertEqual(envelope["generation"], fixture.runtime.state.generation_of("Unit_1"))
        self.assertEqual(second.receipts[0]["status"], "Accepted")
        self.assertEqual(fixture.runtime.state.task_state("t-1"), "running")

    def test_expired_window_is_recomputed_at_dispatch_with_fresh_tick(self):
        """真实模型慢：下发前按宿主提供的最新 tick 重算过期窗口（显式留痕）。"""
        fixture = RuntimeFixture(
            strategy_script=[{"behavior": "completed", "plan": make_plan()}],
            tactics_script=[{"behavior": "completed", "intents": make_batch(
                # 决策时的窗口：在模型耗时后已经过期（expires 远小于宿主最新 tick）
                [make_intent("i-1", issued_tick=5, expires_tick=10)])}])
        fixture.runtime._tick_provider = lambda: {"server_tick": 9000,
                                                 "snapshot_id": 120}
        fixture.tick(0)
        result = fixture.tick(5, events=[events_for("enemy_spotted", ["Unit_1"], 5)])
        self.assertEqual(result.accepted_intents, ["i-1"])
        envelope = fixture.transport.sent[-1]
        self.assertGreater(envelope["expires_tick"], 9000)
        self.assertEqual(result.receipts[0]["status"], "Accepted")
        kinds = [item["kind"] for item in fixture.runtime.state.decision_log]
        self.assertIn("intent_ttl_recomputed", kinds)

    def test_strategy_never_emits_commands_by_itself(self):
        fixture = RuntimeFixture(
            strategy_script=[{"behavior": "completed", "plan": make_plan()}],
            tactics_script=[])
        fixture.tick(0)
        self.assertEqual(model_sends(fixture.transport.sent), [],
                         "战略层不得自己下命令（规则地板的常驻下发不在此约束内）")
        self.assertEqual(fixture.runtime.state.active_tasks, {"t-1": "pending"})


class PhaseTimingTest(unittest.TestCase):
    """分段计时（2026-10-07）：协调轮必须能回答"慢在哪一段"。

    背景：上一轮审计拿到 167 轮 p50=227ms / p95=4956ms / max=41931ms，但**无法分段归因**
    —— `elapsed_ms` 只是总时长，看不出那 41.9 秒花在战略、战术、仲裁还是下发。
    这里钉住：每轮结果都带各阶段的本轮合计与历史 p50/p95/p99/max，且异常轮也计入。
    """

    def test_each_round_reports_phase_durations(self):
        fixture = RuntimeFixture(
            strategy_script=[{"behavior": "completed", "plan": make_plan()}],
            tactics_script=[{"behavior": "completed", "intents": make_batch(
                [make_intent("i-1", issued_tick=5, expires_tick=605)])}])
        first = fixture.tick(0)
        self.assertTrue(first.phases, "战略轮必须留下分段计时")
        self.assertIn("strategic_agent", first.phases,
                      "战略调用是最可疑的慢点，必须单独计量：%s" % sorted(first.phases))
        for name, stats in first.phases.items():
            self.assertGreaterEqual(stats["round_ms"], 0.0, name)
            self.assertGreaterEqual(stats["p95_ms"], 0.0, name)
            self.assertLessEqual(stats["p50_ms"], stats["p95_ms"] + 1e-9, name)
            self.assertLessEqual(stats["p95_ms"], stats["max_ms"] + 1e-9, name)
        self.assertGreaterEqual(first.phases["strategic_agent"]["samples"], 1)

        # 第二轮：`round_ms` 只算本轮，样本数累加（历史 p95 才有意义）。
        second = fixture.tick(5, events=[events_for("enemy_spotted", ["Unit_1"], 5)])
        self.assertIn("tactical_agent", second.phases)
        self.assertGreaterEqual(second.phases["strategic_agent"]["samples"], 1)
        self.assertTrue(second.to_dict()["phases"], "序列化结果必须带上分段计时（留档用）")

    def test_phase_stats_are_serializable_and_bounded(self):
        fixture = RuntimeFixture(strategy_script=[], tactics_script=[])
        for index in range(6):
            result = fixture.tick(index)
            self.assertIsInstance(result.to_dict()["phases"], dict)
        stats = fixture.runtime.runner.phase_stats()
        self.assertTrue(all(set(item) >= {"round_ms", "p50_ms", "p95_ms", "p99_ms",
                                          "max_ms", "samples"}
                            for item in stats.values()))
        limit = fixture.runtime.runner.PHASE_SAMPLE_LIMIT
        self.assertTrue(all(item["samples"] <= limit for item in stats.values()),
                        "计时样本必须有界（不许随对局时长无限增长）")

    def test_continuity_ledger_is_visible_to_the_tick_log(self):
        """连续行动台账必须出现在 `summary()` 里（2026-10-07 实测踩过）。

        runner 的 tick 日志读的是 `TickResult.state` = `state.summary()`。
        台账只加进 dataclass/to_dict、没进 `summary()` 时，日志里那一栏**永远是 0**，
        而同一局的 decisions 日志里其实有 255 条 `continuity_supervision`
        —— 埋点读错了路径，看起来像"监督没接线"。
        """
        fixture = RuntimeFixture(strategy_script=[], tactics_script=[])
        result = fixture.tick(0)
        self.assertIn("continuity_supervision", result.state,
                      "summary() 必须带监督报告：%s" % sorted(result.state)[:12])
        self.assertIn("continuity_units", result.state)
        state = fixture.runtime.state
        state.continuity_units = {"Unit_4": {"last_moved_tick": 60, "stop_seconds": 5.0}}
        state.continuity_supervision = {"updated_tick": 300, "recoveries": 1,
                                        "levels": {"recover": 1}}
        summary = state.summary()
        self.assertEqual(summary["continuity_units"]["Unit_4"]["stop_seconds"], 5.0)
        self.assertEqual(summary["continuity_supervision"]["recoveries"], 1)


class ArrivalDedupTest(unittest.TestCase):
    """到达事件**不许被永久键吃掉**（2026-10-07 实测 bug，C2 门禁 p95 尾巴的根因）。

    旧去重用永久键 `"<unit>|<target>"`：单位**再次回到同一个目标点**时，第二次到达
    直接命中同一个 key → 整段 `continue`（既不 `note_arrival` 也不做侦察段 COMPLETED）。
    后果是链条式的：到达不记账 → 路线缓存不作废 → `unit_en_route` 恒真 →
    `rules_fallback._parallel_intents` 里 `if _en_route(name): continue` **每轮跳过它** →
    直到 `HOP_HOLD_MAX_TICKS`(1800 tick ≈ 30 秒) 才放行。

    实测证据（对照档案 `archive_edf8bd9a`）：522 条 arrival 里 **48 条（9.2%）** 被吃掉；
    工人 `Unit_19` 的 37 次到点里 **14 次**被吃掉（基地↔矿区往返，目标点反复相同）。
    """

    def _ctx(self, events):
        from adjutant_coordinator.graph.nodes import (GraphConfig, GraphServices,
                                                     NodeContext)
        services = GraphServices(config=GraphConfig())
        observation = {"tactical": {"entities": [], "production": [], "truncated": False},
                       "strategic": {"enemy_intel": []},
                       "fast_events": list(events)}
        return NodeContext(services=services, observation=observation, tick=0)

    def _arrival(self, unit, target, tick, seq):
        return {"kind": "arrival", "unit": unit, "target": list(target),
                "pos": [0.0, 0.0, 0.0], "server_tick": tick, "seq": seq,
                "navigation_finished": True}

    def _state_with_route(self, unit, tick):
        from adjutant_coordinator.graph import movement as mv
        state = {"server_tick": tick, "active_intents": [], "active_tasks": {},
                 "routes": {}, "pending_events": []}
        mv.record_route(state, mv.RoutePlan(
            unit=unit, ok=True, relay_point=[14.0, 7.0], target=[30.0, 7.0],
            nav_revision=1, last_replan_tick=tick,
            route_id="route-%s" % unit))
        return state

    def test_second_arrival_at_the_same_target_still_invalidates_the_route(self):
        from adjutant_coordinator.graph import movement as mv
        from adjutant_coordinator.graph import nodes

        state = self._state_with_route("Unit_19", 1000)
        self.assertTrue(state["routes"]["Unit_19"]["ok"])
        # 第一次到达（worker 回到基地，目标点固定）
        nodes._consume_fast_events(state, self._ctx(
            [self._arrival("Unit_19", [14.0, 7.0], 1000, 1)]))
        self.assertFalse(state["routes"]["Unit_19"]["ok"], "第一次到达必须作废路线")
        # 重新批准一跳（模拟下一轮重规划），然后再回到**同一个点**
        mv.record_route(state, mv.RoutePlan(
            unit="Unit_19", ok=True, relay_point=[14.0, 7.0], target=[30.0, 7.0],
            nav_revision=1, last_replan_tick=1100, route_id="route-2"))
        state["server_tick"] = 1200
        nodes._consume_fast_events(state, self._ctx(
            [self._arrival("Unit_19", [14.0, 7.0], 1200, 2)]))
        self.assertFalse(state["routes"]["Unit_19"]["ok"],
                         "**再次**到达同一个目标点也必须作废路线"
                         "（旧实现被永久键吃掉，于是单位被当作'还在路上'跳过 30 秒）")

    def test_arrival_closes_the_movement_intent_and_frees_the_unit(self):
        """到达必须**结束移动意图**，否则单位留在 `busy` 里出不来。

        `note_arrival` 只作废**路线缓存**；意图本身若还活着，单位就在
        `busy_units` 里（= `active_intents` 里 `state ∈ INTENT_LIVE_STATES` 的单位），
        而规则地板军事轨的第一道出口是 `_free(name)` ⇒ **每轮被跳过**直到 TTL 到期。

        实测（round-15，`archive_72501fe6`）：军事轨挡掉的单位里 **73.8% 是 `busy`**
        （1232 次），与 round-14 观测到的"到达后 20~30 秒生成侧一条推进意图都不产出"对上。

        原先只有侦察段这么做；同样的死锁对 `move` / `attack_move` 一样成立。
        """
        from adjutant_coordinator.graph import nodes, rules_fallback as rf
        state = self._state_with_route("Unit_19", 1000)
        state["active_intents"] = [
            {"intent_id": "rule-fill-advance-Unit_19-1000", "state": "active",
             "action": nodes.ACTION_ATTACK_MOVE, "unit_ids": ["Unit_19"]},
            # 点攻击驻留**不**该被到达结掉（它的语义是停在射程内持续输出）
            {"intent_id": "rule-fill-attack-Unit_20", "state": "active",
             "action": nodes.ACTION_ATTACK, "unit_ids": ["Unit_20"]},
        ]
        self.assertIn("Unit_19", rf.busy_units(state), "前提：移动意图活着 ⇒ 单位算忙")
        nodes._consume_fast_events(state, self._ctx(
            [self._arrival("Unit_19", [14.0, 7.0], 1000, 1)]))
        self.assertNotIn("Unit_19", rf.busy_units(state),
                         "到达后必须释放单位（否则军事轨每轮跳过它直到 TTL）")
        self.assertEqual(state["active_intents"][0]["state"], nodes.INTENT_COMPLETED)
        self.assertEqual(state["active_intents"][0]["drop_reason"], "arrival")
        self.assertIn("Unit_20", rf.busy_units(state),
                      "点攻击驻留不能被到达结掉（否则单位打一下就走）")

    def test_every_arrival_is_accounted_by_counters_not_by_log(self):
        """到达账必须**每个出口都有计数**，且不依赖会被挤掉的决策日志。

        round-28 的教训：该局 `arrival_events == arrival_note`（764 = 764）、
        `arrival_deduped = 0`，**按计数看"每条到达都记了账"**，
        但逐例追踪时 `Unit_18` 在 t=2458 的到达**根本没有 `arrival_seen` 记录**
        —— 因为 `arrival_seen` 是 `_decide` 写的、**受 `MAX_DECISION_LOG` 上限约束**，
        会被后续条目挤掉。所以"用日志条目或对不上口径的计数去证没有漏处理"是无效的。

        本测试钉住口径：**`arrival_events == arrival_deduped + arrival_note`
        （+ `arrival_no_unit`）**，覆盖全部出口，且都写在不受上限影响的
        `movement_stats` 里。
        """
        from adjutant_coordinator.graph import nodes
        state = {"server_tick": 1000, "active_intents": [], "active_tasks": {},
                 "routes": {}, "pending_events": [], "movement_stats": {}}
        # ① 正常到达（有路线）
        state = self._state_with_route("Unit_19", 1000)
        state["active_intents"] = []
        state["movement_stats"] = {}
        nodes._consume_fast_events(state, self._ctx(
            [self._arrival("Unit_19", [14.0, 7.0], 1000, 1)]))
        stats = state["movement_stats"]
        self.assertEqual(stats.get("arrival_events"), 1)
        self.assertEqual(stats.get("arrival_note"), 1)
        self.assertIsNone(stats.get("arrival_deduped"),
                          "正常路径不该被记成去重")
        # ② 无 `unit` 的到达：必须被计数，而不是静默消失
        state2 = {"server_tick": 1000, "active_intents": [], "active_tasks": {},
                  "routes": {}, "pending_events": [], "movement_stats": {}}
        nodes._consume_fast_events(state2, self._ctx(
            [{"kind": "arrival", "target": [1.0, 2.0], "server_tick": 1000,
              "seq": 1}]))
        self.assertEqual(state2["movement_stats"].get("arrival_events"), 1,
                         "无 unit 的到达也必须计入 arrival_events")
        self.assertEqual(state2["movement_stats"].get("arrival_no_unit"), 1,
                         "无 unit 的到达必须单独计数（旧条件会整条跳过它）")

    def test_arrival_releases_the_intent_even_without_a_route(self):
        """**无路线**的到达也必须结束移动意图（round-23 实测的 `Unit_16` 30 秒停滞）。

        `movement.note_arrival` 在 `previous_route` 为空时**直接 early-return**
        （`if not entry: return`）—— 路线没作废，而"结束意图"原先**内联在到达分支尾部**、
        挂在 `note_arrival` 之后。于是"路线早被别的原因作废"的到达**什么都不做**，
        意图继续活着、单位继续留在 `busy_units` 里被军事轨每轮跳过。

        实测（`archive_353bf7a3`）：`Unit_16` 到达 t=2129（dist=0.22）之后
        `rule-fill-advance-Unit_16-2121` 连续挡它 **26 轮（30.75 秒）**，
        而该局 `arrival_note == arrival_events`（798=798）证明到达**都记了账**
        —— 所以问题不在投递，在**释放动作没覆盖这条路径**。
        """
        from adjutant_coordinator.graph import nodes, rules_fallback as rf
        state = {"server_tick": 1000, "active_intents": [], "active_tasks": {},
                 "routes": {}, "pending_events": [], "movement_stats": {}}
        # 关键：**不**建路线（模拟"路线已被别的原因作废"）
        state["active_intents"] = [
            {"intent_id": "rule-fill-advance-Unit_16-2121", "state": "active",
             "action": nodes.ACTION_ATTACK_MOVE, "unit_ids": ["Unit_16"]},
        ]
        self.assertIn("Unit_16", rf.busy_units(state), "前提：意图活着 ⇒ 单位算忙")
        nodes._consume_fast_events(state, self._ctx(
            [self._arrival("Unit_16", [36.09, 54.27], 1000, 7)]))
        self.assertNotIn("Unit_16", rf.busy_units(state),
                         "无路线的到达也必须释放单位"
                         "（否则它被 busy 挡到意图 TTL 到期 = 30 秒级停滞）")
        self.assertEqual(state["active_intents"][0]["state"], nodes.INTENT_COMPLETED)

    def test_deduped_arrival_also_releases_the_intent(self):
        """被 1 秒去重窗口挡掉的到达**也要**释放 —— 旧实现在那个 `continue` 之前就返回了。

        ⚠ 注意与"同一条事件重复投递"区分：后者由 `fast_event_seq` 游标挡掉
        （那是**事件级**去重，在进入到达分支之前就 `return` 了，本条覆盖不到）。
        这里模拟的是**两条不同的到达事件**（不同 `seq`）落在同一个 `unit|target`
        键的 1 秒窗口内 —— 那才会走到到达分支里的 `deduped` 出口。
        """
        from adjutant_coordinator.graph import nodes, rules_fallback as rf
        state = {"server_tick": 1000, "active_intents": [], "active_tasks": {},
                 "routes": {}, "pending_events": [], "movement_stats": {}}
        # 第一条（seq=7）走正常路径，把 `unit|target` 写进去重表
        nodes._consume_fast_events(state, self._ctx(
            [self._arrival("Unit_16", [36.09, 54.27], 1000, 7)]))
        # 挂一条活的移动意图，然后 **20 tick 后**再来一条同 key 的到达（seq=8）
        state["active_intents"] = [
            # The duplicate can release an older unfinished segment. A newly
            # issued next hop is covered separately in test_fast_scan.
            {"intent_id": "rule-fill-advance-Unit_16-990", "state": "active",
             "action": nodes.ACTION_ATTACK_MOVE, "unit_ids": ["Unit_16"],
             "issued_tick": 990, "target": {"pos": [36.09, 54.27]}},
        ]
        state["server_tick"] = 1020
        nodes._consume_fast_events(state, self._ctx(
            [self._arrival("Unit_16", [36.09, 54.27], 1020, 8)]))
        self.assertNotIn("Unit_16", rf.busy_units(state),
                         "去重分支不许绕过释放（否则同样是 30 秒级停滞）")

    def test_double_delivery_of_one_event_is_still_deduplicated(self):
        """去重仍要挡住"同一条事件被投递两次"（这是它原本存在的理由）。"""
        from adjutant_coordinator.graph import nodes

        state = self._state_with_route("Unit_19", 1000)
        event = self._arrival("Unit_19", [14.0, 7.0], 1000, 1)
        nodes._consume_fast_events(state, self._ctx([event]))
        arrivals_after_first = state["movement_stats"]["arrivals"]
        nodes._consume_fast_events(state, self._ctx([event]))
        self.assertEqual(state["movement_stats"]["arrivals"], arrivals_after_first,
                         "同一条事件重复投递不许重复计数")

    def test_seen_arrivals_is_bounded(self):
        """去重表必须有界（旧实现是长度 64 的 list；新实现按时间窗清理）。"""
        from adjutant_coordinator.graph import nodes

        state = self._state_with_route("Unit_19", 0)
        for index in range(40):
            state["server_tick"] = index * 200        # 远超去重窗口
            nodes._consume_fast_events(state, self._ctx(
                [self._arrival("Unit_%d" % index, [float(index), 0.0],
                               index * 200, index + 1)]))
        seen = state.get("seen_arrivals")
        self.assertIsInstance(seen, dict, "新格式是 dict（携带时间戳）")
        self.assertLessEqual(len(seen), 4,
                             "过期键必须被清掉（窗口 60 tick，200 tick 间隔 → 只留最新）")


class PlanVersionEchoTest(unittest.TestCase):
    """真实模型常把 plan_version 写成 plan_id / 版本号：可归一化，但历史版本必须仍被拒。"""

    def test_normalize_semantics(self):
        from adjutant_coordinator.graph.nodes import _normalize_plan_version

        state = {"plan_version": "plan-b:v2", "plan_version_history": ["plan-a:v1"],
                 "active_plan": {"plan_id": "plan-b", "plan_version": 2}}
        self.assertEqual(_normalize_plan_version("plan-a:v1", state), "plan-a:v1")
        self.assertEqual(_normalize_plan_version("plan-b", state), "plan-b:v2")
        self.assertEqual(_normalize_plan_version("2", state), "plan-b:v2")
        self.assertEqual(_normalize_plan_version("v2", state), "plan-b:v2")
        self.assertEqual(_normalize_plan_version("随便写的", state), "plan-b:v2")
        self.assertEqual(_normalize_plan_version("", state), "plan-b:v2")

    def test_echo_written_wrong_is_still_accepted(self):
        fixture = RuntimeFixture(
            strategy_script=[{"behavior": "completed", "plan": make_plan(plan_id="plan-a")}],
            tactics_script=[{"behavior": "completed", "intents": make_batch(
                [make_intent("i-1", plan_version="1", issued_tick=5, expires_tick=605)],
                plan_version="1")}])
        fixture.tick(0)
        result = fixture.tick(5, events=[events_for("enemy_spotted", ["Unit_1"], 5)])
        self.assertEqual(result.accepted_intents, ["i-1"])
        record = fixture.runtime.state.find_intent("i-1")
        self.assertEqual(record["plan_version"], "plan-a:v1")
        self.assertEqual(result.receipts[0]["status"], "Accepted")


class PlayerInterruptRuntimeTest(unittest.TestCase):
    def make_fixture(self, engine=ENGINE_FALLBACK):
        return RuntimeFixture(
            strategy_script=[{"behavior": "completed", "plan": make_plan()}],
            tactics_script=[
                {"behavior": "completed", "intents": make_batch(
                    [make_intent("i-1", issued_tick=5, expires_tick=605)])},
                {"behavior": "completed", "intents": make_batch(
                    [make_intent("i-2", issued_tick=10, expires_tick=605)])},
                {"behavior": "completed", "intents": make_batch(
                    [make_intent("i-3", issued_tick=21, expires_tick=605)])},
            ],
            config=base_config(engine))

    def test_player_override_pauses_graph_and_blocks_old_intent(self):
        fixture = self.make_fixture()
        fixture.tick(0)
        fixture.tick(5, events=[events_for("enemy_spotted", ["Unit_1"], 5)])
        self.assertEqual(len(model_sends(fixture.transport.sent)), 1)

        record = fixture.runtime.on_player_command(["Unit_1"], server_tick=8)
        self.assertEqual(fixture.runtime.state.find_intent("i-1")["state"], "dropped")
        self.assertEqual(record["dropped_intents"], ["i-1"])
        self.assertTrue(fixture.runtime.state.is_unit_player_controlled("Unit_1"))

        paused = fixture.tick(8)
        self.assertEqual(paused.route, "player_interrupt")
        self.assertTrue(paused.paused)
        # 暂停期间图不下发命令（等宿主/玩家决定后再恢复）。
        self.assertEqual(len(model_sends(fixture.transport.sent)), 1)

        resumed = fixture.tick(9)
        self.assertFalse(resumed.paused)
        self.assertEqual(len(model_sends(fixture.transport.sent)), 1)

        # 旧模型响应（同一个单位的旧代际）不能抢回控制。
        after = fixture.tick(10, events=[events_for("queue_idle", ["Unit_1"], 10)])
        dropped = {item["intent_id"]: item["reason"] for item in after.dropped_intents}
        self.assertEqual(dropped.get("i-2"), "lease_owner_player:Unit_1")
        self.assertEqual(len(model_sends(fixture.transport.sent)), 1)
        self.assertEqual(fixture.runtime.state.player_controlled_units, ["Unit_1"])

    def test_release_then_ai_can_control_again(self):
        fixture = self.make_fixture()
        fixture.tick(0)
        fixture.tick(5, events=[events_for("enemy_spotted", ["Unit_1"], 5)])
        fixture.runtime.on_player_command(["Unit_1"], server_tick=8)
        fixture.tick(8)
        fixture.tick(9)
        fixture.tick(10, events=[events_for("queue_idle", ["Unit_1"], 10)])

        fixture.runtime.on_player_release(["Unit_1"], server_tick=20)
        self.assertFalse(fixture.runtime.state.is_unit_player_controlled("Unit_1"))
        fixture.tick(20)                     # 玩家打断：暂停
        result = fixture.tick(21, events=[events_for("queue_idle", ["Unit_1"], 21)])
        self.assertEqual(result.accepted_intents, ["i-3"])
        # 只数模型来源：地板在第 0 轮已发过一次 fill-advance 且之后不再重复（实测），
        # 按总条数判会把那条地板命令错算成"玩家归还后又下了一单"。
        sent_by_model = model_sends(fixture.transport.sent)
        self.assertEqual(len(sent_by_model), 2)
        self.assertEqual(sent_by_model[1]["intent_id"], "i-3")
        self.assertEqual(result.receipts[0]["status"], "Accepted")

    def test_reacquire_intent_carries_flag_to_authority(self):
        fixture = RuntimeFixture(
            strategy_script=[{"behavior": "completed", "plan": make_plan()}],
            tactics_script=[{"behavior": "completed", "intents": make_batch(
                [make_intent("i-1", issued_tick=5, expires_tick=605)])}])
        fixture.tick(0)
        fixture.tick(5, events=[events_for("enemy_spotted", ["Unit_1"], 5)])
        fixture.runtime.on_player_command(["Unit_1"], server_tick=8)
        fixture.tick(8)
        fixture.tick(9)
        fixture.runtime.on_player_release(["Unit_1"], server_tick=20)
        fixture.tick(20)
        reacquire = make_intent("i-reacquire", issued_tick=21, expires_tick=605)
        reacquire["reacquire"] = True
        fixture.tactics._script.append({"behavior": "completed",
                                        "intents": make_batch([reacquire])})
        result = fixture.tick(21, events=[events_for("queue_idle", ["Unit_1"], 21)])
        self.assertEqual(result.accepted_intents, ["i-reacquire"])
        self.assertTrue(fixture.transport.sent[-1]["params"]["reacquire"],
                        "显式重新接管标记必须随命令包送到权威层")

    def test_local_override_keeps_strategy_plan(self):
        fixture = self.make_fixture()
        fixture.tick(0)
        before_plan = fixture.runtime.state.plan_version
        fixture.runtime.on_player_command(["Unit_1"], server_tick=8)
        fixture.tick(8)
        self.assertEqual(fixture.runtime.state.plan_version, before_plan)
        self.assertIsNotNone(fixture.runtime.state.active_plan)


class PendingAuthorityTest(unittest.TestCase):
    def test_pending_authority_is_not_resubmitted_and_resolves_by_receipt(self):
        # 回执脚本按 intent_id 精确匹配：地板那条命令也在同一局里下发，
        # 位置式脚本会让它先吃掉 "PendingAuthority"，模型命令反而拿到 Accepted。
        transport = RecordingTransport(
            script=[{"intent_id": "i-1", "accepted": False, "status": "PendingAuthority"}])
        recheck = lambda command_id: {"command_id": command_id, "intent_id": "i-1",
                                      "status": "Accepted", "accepted": True, "result": {}}
        fixture = RuntimeFixture(
            strategy_script=[{"behavior": "completed", "plan": make_plan()}],
            tactics_script=[{"behavior": "completed", "intents": make_batch(
                [make_intent("i-1", issued_tick=5, expires_tick=605)])}],
            transport=transport, recheck_fn=recheck)
        fixture.tick(0)
        result = fixture.tick(5, events=[events_for("enemy_spotted", ["Unit_1"], 5)])
        self.assertEqual(result.receipts[0]["status"], "PendingAuthority")
        self.assertIn("i-1", fixture.runtime.state.pending_requests)
        self.assertEqual(len(model_sends(transport.sent)), 1)

        # 在途未复核：**路由不再被全局压制**（2026-09-12 晚修正：原来这里断言
        # route=="wait"、tactics 只调 1 次，导致主循环 0.58 秒/轮却每 4.7 秒才思考一次），
        # 但"不对同一单位重复下单"这条保证仍然成立 —— 由仲裁层的
        # `pending_authority_unresolved` 指纹去重拦下，**模型发送计数不变**。
        again = fixture.tick(6, events=[events_for("queue_idle", ["Unit_1"], 6)])
        self.assertGreaterEqual(again.server_tick, 6)
        self.assertEqual(len(model_sends(transport.sent)), 1,
                         "在途未复核的命令不得重复下发（仲裁层应拦下同一指纹）")

        # 复核终态：pending 结算，意图进入 active，不需要重下单。
        resolved = fixture.tick(7)
        self.assertEqual(fixture.runtime.state.pending_requests, {})
        self.assertEqual(fixture.runtime.state.find_intent("i-1")["state"], "active")
        self.assertEqual(len(model_sends(transport.sent)), 1)
        kinds = [item["kind"] for item in fixture.runtime.state.decision_log]
        self.assertIn("pending_resolved", kinds)
        self.assertGreaterEqual(resolved.server_tick, 7)


class DegradeTest(unittest.TestCase):
    def test_model_timeout_degrades_without_blocking(self):
        fixture = RuntimeFixture(
            strategy_script=[{"behavior": "timeout"},
                             {"behavior": "completed", "plan": make_plan()}],
            tactics_script=[{"behavior": "timeout"}])
        first = fixture.tick(0)
        self.assertEqual(first.route, "strategic")
        self.assertIn("strategy_model_ModelTimeout", first.degraded_reason)
        self.assertIsNone(fixture.runtime.state.active_plan)

        # 战略失败不阻塞后续：下一轮成功采纳计划并清除降级。
        second = fixture.tick(1)
        self.assertEqual(fixture.runtime.state.plan_version, "plan-a:v1")
        self.assertEqual(second.degraded_reason, "")

        # 战术超时：既有计划保留，图不抛异常；降级原因必须保留可见——
        # 否则分不清"模型恢复"与"兜底顶上"。
        # 模型这条线确实一条没发（timeout），但**规则地板照常指挥**：观测里有敌军
        # 就顶上进攻（2026-09-12 架构纠偏 §三-3：模型缺席时 AI 不能整轮静默）。
        third = fixture.tick(
            5, events=[events_for("enemy_spotted", ["Unit_1"], 5)],
            enemies=[{"name": "Enemy_1", "unit_type": "tank", "pos": [30.0, 0.0, 30.0]}])
        self.assertIn("tactics_model_ModelTimeout", third.degraded_reason)
        self.assertIsNotNone(fixture.runtime.state.active_plan)
        self.assertEqual(model_sends(fixture.transport.sent), [])
        floor = [item for item in fixture.transport.sent
                 if is_floor_intent(item.get("intent_id"))]
        self.assertEqual(len(floor), 1, "模型超时时规则地板必须顶上，而不是整轮零下发")
        self.assertIn("Unit_1", floor[0]["params"]["units"])

    def test_model_cooldown_after_repeated_failures(self):
        fixture = RuntimeFixture(
            strategy_script=[{"behavior": "timeout"}, {"behavior": "timeout"},
                             {"behavior": "timeout"}],
            config=base_config(model_error_limit=2, model_retry_cooldown_ticks=60))
        fixture.tick(0)
        fixture.tick(1)
        skipped = fixture.tick(2)
        self.assertEqual(skipped.route, "strategic")
        kinds = [(item["kind"], item.get("reason"))
                 for item in fixture.runtime.state.decision_log]
        self.assertIn(("strategy_skipped", "model_cooldown"), kinds)
        self.assertEqual(fixture.strategy.call_count, 2)
        # 冷却结束后允许再次调用（不会永久降级）。
        fixture.tick(62)
        self.assertEqual(fixture.strategy.call_count, 3)

    def test_identity_drift_blocks_dispatch(self):
        fixture = RuntimeFixture(
            strategy_script=[{"behavior": "completed", "plan": make_plan()}],
            tactics_script=[{"behavior": "completed", "intents": make_batch(
                [make_intent("i-1", issued_tick=5, expires_tick=605)])}])
        fixture.tick(0)
        # 这条要钉的性质是"**漂移轮起，一条都不许多发**"（绝不把命令送进别的对局），
        # 不是"整局累计零条"：规则地板自 2026-09-12 架构纠偏后每轮常驻，
        # 漂移之前的那一轮本就允许有下发（那是**本局**的命令，不是泄漏）。
        # 因此以漂移前的下发数为基线，只要求漂移轮及其后不再增长。
        sent_before_drift = len(fixture.transport.sent)
        drifted = fixture.tick(5, events=[events_for("enemy_spotted", ["Unit_1"], 5)],
                              match_id="other-match")
        self.assertEqual(drifted.degraded_reason, "identity_drift")
        self.assertEqual(len(fixture.transport.sent), sent_before_drift,
                         "身份漂移轮不得新增任何下发（漂移前 %d 条，现在 %d 条）" % (
                             sent_before_drift, len(fixture.transport.sent)))
        # 且已下发的每一条都必须仍归属**绑定的那个对局**，不能漂到别的局。
        for envelope in fixture.transport.sent:
            self.assertEqual(envelope["match_id"], fixture.runtime.state.match_id)


class CheckpointRestoreTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="adjutant-runtime-")
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)

    def test_restore_resumes_without_duplicate_orders(self):
        store = JsonCheckpointStore(self.root, MATCH, PLAYER)
        first = RuntimeFixture(
            strategy_script=[{"behavior": "completed", "plan": make_plan()}],
            tactics_script=[{"behavior": "completed", "intents": make_batch(
                [make_intent("i-1", issued_tick=5, expires_tick=605)])}],
            store=store)
        first.tick(0)
        first.tick(5, events=[events_for("enemy_spotted", ["Unit_1"], 5)])
        self.assertEqual(len(model_sends(first.transport.sent)), 1,
                         "恢复检查点后模型意图只许重放一次（幂等）")
        command_ids = [str(item.get("command_id", "")) for item in first.transport.sent]
        self.assertEqual(len(command_ids), len(set(command_ids)),
                         "恢复后不得重复下发同一条命令：%s" % command_ids)
        saved = first.runtime.checkpoint()
        self.assertTrue(saved["saved"], saved)

        # 模拟进程重启：新运行时、新通道、新的空脚本模型。
        transport = RecordingTransport()
        restarted = RuntimeFixture(transport=transport, store=store)
        outcome = restarted.runtime.restore()
        self.assertTrue(outcome["restored"], outcome)
        state = restarted.runtime.state
        self.assertEqual(state.plan_version, "plan-a:v1")
        # 恢复的是**模型意图** i-1。规则地板每轮常驻，它的 `rule-*` 意图同样会进
        # active_intents（见 model_sends 的理由），所以按来源挑出来再比。
        self.assertEqual([item["intent_id"] for item in state.active_intents
                          if not is_floor_intent(item.get("intent_id"))], ["i-1"])
        self.assertEqual(state.generation_of("Unit_1"), first.runtime.state.generation_of("Unit_1"))
        self.assertEqual(state.active_tasks, first.runtime.state.active_tasks)

        # 恢复后继续 tick：不会重放已接受的模型意图（不重复下单）；
        # 规则地板这一轮照常下发，那不是"重放"。
        result = restarted.tick(30)
        self.assertEqual(model_sends(transport.sent), [])
        self.assertEqual(result.accepted_intents, [])

    def test_restore_refuses_rules_version_drift(self):
        store = JsonCheckpointStore(self.root, MATCH, PLAYER)
        fixture = RuntimeFixture(
            strategy_script=[{"behavior": "completed", "plan": make_plan()}],
            store=store)
        fixture.tick(0)
        fixture.runtime.checkpoint()
        restarted = RuntimeFixture(store=store)
        outcome = restarted.runtime.restore(expect_rules_version="another-hash")
        self.assertFalse(outcome["restored"])
        self.assertEqual(outcome["reason"], "rules_version_mismatch")


@unittest.skipUnless(langgraph_available()["available"],
                     "langgraph 未安装；LanguageGraph 引擎专项测试跳过")
class LangGraphEngineTest(unittest.TestCase):
    """真实 LangGraph 引擎：同一批节点 + checkpoint + interrupt/resume。"""

    def make_fixture(self):
        return RuntimeFixture(
            strategy_script=[{"behavior": "completed", "plan": make_plan()}],
            tactics_script=[
                {"behavior": "completed", "intents": make_batch(
                    [make_intent("i-1", issued_tick=5, expires_tick=605)])},
                {"behavior": "completed", "intents": make_batch(
                    [make_intent("i-2", issued_tick=10, expires_tick=605)])},
            ],
            config=base_config(ENGINE_LANGGRAPH))

    def test_langgraph_dispatch_and_interrupt_resume(self):
        fixture = self.make_fixture()
        self.assertEqual(fixture.runtime.runner.engine, ENGINE_LANGGRAPH)
        first = fixture.tick(0)
        self.assertEqual(first.route, "strategic")
        self.assertEqual(fixture.runtime.state.plan_version, "plan-a:v1")

        second = fixture.tick(5, events=[events_for("enemy_spotted", ["Unit_1"], 5)])
        self.assertEqual(second.accepted_intents, ["i-1"])
        # 与 fallback 侧同口径：只数模型来源（地板第 0 轮已发过 fill-advance，见 model_sends）。
        self.assertEqual(len(model_sends(fixture.transport.sent)), 1)

        fixture.runtime.on_player_command(["Unit_1"], server_tick=8)
        paused = fixture.tick(8)
        self.assertEqual(paused.route, "player_interrupt")
        self.assertTrue(paused.paused, "LangGraph 应在 reconcile_plan 后暂停图")

        resumed = fixture.tick(9)
        self.assertFalse(resumed.paused)
        self.assertEqual(len(model_sends(fixture.transport.sent)), 1)

        after = fixture.tick(10, events=[events_for("queue_idle", ["Unit_1"], 10)])
        dropped = {item["intent_id"]: item["reason"] for item in after.dropped_intents}
        self.assertEqual(dropped.get("i-2"), "lease_owner_player:Unit_1")

    def test_langgraph_and_fallback_agree_on_route_and_intents(self):
        def run(engine):
            fixture = RuntimeFixture(
                strategy_script=[{"behavior": "completed", "plan": make_plan()}],
                tactics_script=[{"behavior": "completed", "intents": make_batch(
                    [make_intent("i-1", issued_tick=5, expires_tick=605)])}],
                config=base_config(engine))
            results = [fixture.tick(0),
                       fixture.tick(5, events=[events_for("enemy_spotted", ["Unit_1"], 5)])]
            return results

        fallback = run(ENGINE_FALLBACK)
        langgraph = run(ENGINE_LANGGRAPH)
        for left, right in zip(fallback, langgraph):
            self.assertEqual(left.route, right.route)
            self.assertEqual(left.accepted_intents, right.accepted_intents)
            self.assertEqual(left.paused, right.paused)
            self.assertEqual([r["status"] for r in left.receipts],
                             [r["status"] for r in right.receipts])


class StrategyDisabledRoutingTest(unittest.TestCase):
    """战略层缺省（--strategy-mode off / 模型缺失）时的路由回归钉（2026-09-12）。

    死锁机制：active_plan 恒为 None → is_strategy_due 恒真 → 路由永远 strategic；
    战略层关闭后不再报错（也就不进冷却让位）→ 战术节点永远轮不到 →
    task_patch_submitted=0、整局 0 下发（实测 556/556 全 strategic、own=4 全程不变）。
    修复：strategy_disabled 立标志后，classify_route 跳过战略分支，战术分支成为
    单一决策入口（计划 §6 阶段 A：省略高层、状态里标注高层意图缺省）。
    """

    def _runtime_without_strategy(self, tactics_script):
        transport = RecordingTransport()
        runtime = AdjutantGraphRuntime(
            MATCH, PLAYER, transport=transport,
            strategy_model=None,
            tactics_model=FakeStructuredModel("tactics", tactics_script),
            checkpoint_store=MemoryCheckpointStore(), config=base_config())
        runtime.restore()
        return runtime, transport

    def test_runtime_marks_strategy_disabled_at_construction(self):
        runtime, _ = self._runtime_without_strategy([])
        self.assertTrue(runtime.state.strategy_disabled)

    def test_strategy_model_present_keeps_flag_false(self):
        fixture = RuntimeFixture(
            strategy_script=[{"behavior": "completed", "plan": make_plan()}],
            tactics_script=[])
        self.assertFalse(fixture.runtime.state.strategy_disabled)

    def test_no_event_without_strategy_routes_wait_not_strategic(self):
        runtime, _ = self._runtime_without_strategy([])
        first = runtime.tick(0)
        self.assertEqual(first.route, "wait")
        kinds = [str(entry.get("kind", ""))
                 for entry in runtime.state.decision_log]
        self.assertNotIn("strategy_skipped", kinds)

    def test_tactical_entry_dispatches_intents_without_strategy(self):
        runtime, transport = self._runtime_without_strategy(
            [{"behavior": "completed", "intents": make_batch(
                [make_intent("i-1", issued_tick=5, expires_tick=605)])}])
        second = runtime.tick(5, observation(
            5, events=[events_for("queue_idle", ["Unit_1"], 5)],
            own=[{"name": "Unit_1"}]))
        self.assertEqual(second.route, "tactical")
        self.assertEqual(second.accepted_intents, ["i-1"])
        self.assertEqual(len(transport.sent), 1)
        self.assertEqual(transport.sent[0]["op"], "adjutant_intent")

    def test_wait_node_preserves_micro_candidates_for_arbitration(self):
        """wait 轮微操候选必须能到达仲裁（WAIT→ARBITRATE 边）。

        node_wait 曾无条件清空 candidate_intents：战略层关闭后 wait 轮占绝大多数，
        微操候选全部饿死（仲裁恒空、整局 sent=0、基地纹丝不动，2026-09-12 实测）。
        """
        from adjutant_coordinator.graph.nodes import node_wait
        candidate = {"intent_id": "bt-gather-Unit_3-1", "action": "gather",
                     "unit_ids": ["Unit_3"]}
        state = {"pending_events": [{"kind": "queue_idle", "payload": {}}],
                 "candidate_intents": [candidate], "intent_arbitration": {}}
        out = node_wait(state, None)
        self.assertEqual(out["candidate_intents"], [candidate])

    def test_lease_generation_sync_adopts_authority_and_never_regresses(self):
        """控制代际以权威为准（StaleGeneration 白拒回归钉，2026-09-12）。

        权威租约计数跨对局累加而本地每轮重算：单位第一次命令后权威代际就永久领先，
        之后所有命令被 StaleGeneration 拒（实测 5 分钟 336 条、每单位只吃得到一条）。
        对齐规则：权威领先 → 采纳；本地领先（玩家接管镜像 +1）→ 保留（守卫只拒落后）。
        """
        runtime, _ = self._runtime_without_strategy([])
        runtime.state.unit_generations = {"Unit_1": 3}
        obs = observation(5, events=[events_for("queue_idle", ["Unit_1"], 5)],
                          own=[{"name": "Unit_1"}])
        obs["tactical"]["lease_generations"] = {"Unit_1": 340, "Unit_9": 341}
        runtime.tick(5, obs)
        self.assertEqual(runtime.state.generation_of("Unit_1"), 340)
        self.assertEqual(runtime.state.generation_of("Unit_9"), 341)
        synced = [e for e in runtime.state.decision_log
                  if str(e.get("kind", "")) == "lease_generation_synced"]
        self.assertTrue(synced)
        runtime.state.unit_generations["Unit_1"] = 500
        obs2 = observation(6, own=[{"name": "Unit_1"}])
        obs2["tactical"]["lease_generations"] = {"Unit_1": 340}
        runtime.tick(6, obs2)
        self.assertEqual(runtime.state.generation_of("Unit_1"), 500)


@unittest.skipUnless(langgraph_available()["available"],
                     "langgraph 未安装，跳过 langgraph 引擎测试")
class StrategyDisabledLangGraphTest(unittest.TestCase):
    """langgraph 引擎下的同一回归钉。

    LangGraph StateGraph 只认 GraphStateDict 声明的通道：漏声明的键在图入口
    `_cleaned` 与节点输出两处被过滤。strategy_disabled 漏声明时，构造期与
    节点内立的标志全部失效 → 路由死锁在 strategic（真机 556/556 全 strategic）。
    patch_ready 漏声明时，异步结果收得到（task_patch_result）却落不了地
    （task_patch_applied 恒 0）。
    """

    def test_flag_survives_channel_and_routes_tactical(self):
        transport = RecordingTransport()
        runtime = AdjutantGraphRuntime(
            MATCH, PLAYER, transport=transport,
            strategy_model=None,
            tactics_model=FakeStructuredModel(
                "tactics", [{"behavior": "completed", "intents": make_batch(
                    [make_intent("i-1", issued_tick=5, expires_tick=605)])}]),
            checkpoint_store=MemoryCheckpointStore(),
            config=base_config(ENGINE_LANGGRAPH))
        runtime.restore()
        self.assertEqual(runtime.runner.engine, ENGINE_LANGGRAPH)
        self.assertTrue(runtime.state.strategy_disabled)
        second = runtime.tick(5, observation(
            5, events=[events_for("queue_idle", ["Unit_1"], 5)],
            own=[{"name": "Unit_1"}]))
        self.assertEqual(second.route, "tactical")
        self.assertEqual(second.accepted_intents, ["i-1"])
        self.assertEqual(len(transport.sent), 1)

    def test_patch_ready_key_is_a_declared_channel(self):
        from adjutant_coordinator.graph.graph import GraphStateDict
        declared = set(GraphStateDict.__annotations__)
        for key in ("strategy_disabled", "patch_ready", "plan_version_history",
                    "reserves", "reserves_initialized", "reserves_percent",
                    "task_progress"):
            self.assertIn(key, declared)


if __name__ == "__main__":
    unittest.main()
