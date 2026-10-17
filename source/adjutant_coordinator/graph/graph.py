# -*- coding: utf-8 -*-
"""LangGraph 图装配与等价内置执行器。

引擎策略（方案 §10、§14）：
- 安装 langgraph 时：`LangGraphRunner` 用真正的 StateGraph 编译图，
  checkpoint 由 MemorySaver 承载“暂停/恢复栈”，对局状态由 checkpoint.py 落盘；
  玩家打断使用 LangGraph 的 interrupt（interrupt_after）暂停图，下一 tick resume 继续。
- 未安装 langgraph 时：`FallbackRunner` 用同一批节点函数按同一拓扑顺序执行，
  并对“暂停/恢复”做等价模拟（节点与语义完全一致，只有调度器不同）。

两条路径共用 nodes.py 的节点函数，测试会对两者做行为等价断言。
"""

from __future__ import annotations

import math
import time
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, TypedDict

from . import interrupts as itr
from .nodes import (
    NODE_ADVANCE, NODE_ARBITRATE, NODE_CAMPAIGN, NODE_CLASSIFY, NODE_DISPATCH,
    NODE_INGEST, NODE_OBSERVE, NODE_PERSIST, NODE_RECONCILE, NODE_STRATEGIC,
    NODE_TACTICAL, NODE_WAIT,
    GraphServices, node_advance_milestones, node_arbitrate_intent, node_classify,
    node_dispatch_to_godot, node_ingest, node_observe_receipt, node_persist_checkpoint,
    node_reconcile_plan, node_strategic_agent, node_tactical_agent,
    node_update_campaign, node_wait,
)

ENGINE_LANGGRAPH = "langgraph"
ENGINE_FALLBACK = "fallback"


class GraphStateDict(TypedDict, total=False):
    """LangGraph 状态的通道声明（与 AdjutantGraphState 字段一一对应）。"""

    match_id: str
    player_id: str
    rules_version: str
    server_tick: int
    latest_snapshot_id: int
    active_plan: Optional[Dict[str, Any]]
    plan_version: str
    plan_adopt_generation: int
    active_tasks: Dict[str, str]
    active_intents: List[Dict[str, Any]]
    ai_controlled_units: List[str]
    player_controlled_units: List[str]
    control_generation: int
    unit_generations: Dict[str, int]
    released_units: List[str]
    pending_events: List[Dict[str, Any]]
    pending_requests: Dict[str, Dict[str, Any]]
    command_receipts: List[Dict[str, Any]]
    degraded_reason: str
    last_strategy_tick: Optional[int]
    last_tactics_tick: Optional[int]
    model_errors: int
    last_model_error_tick: Optional[int]
    # 战略层缺省标志（计划 §6 阶段 A）。必须声明为通道：LangGraph 会把未声明的键
    # 在图入口 `_cleaned` 与节点输出两处过滤掉（2026-09-12 实测：漏声明时该标志
    # 永远传不进图，路由死锁在 strategic，真机 556/556 全 strategic、0 下发）。
    strategy_disabled: bool
    # 以下同样是被静默过滤过的节点间键（2026-09-12 排查 state[...]= 全量清单后补齐）：
    # patch_ready = 异步决策结果每轮收取后的节点间传递（漏声明 → 永远 applied=0）；
    # plan_version_history = 被替换计划版本（漏声明 → 旧版本回显防护失效）；
    # reserves* = 玩家资源预留（漏声明 → 预留额度不跨节点）；task_progress = HUD 进度。
    patch_ready: Optional[Dict[str, Any]]
    #: 规则中台本轮已生成 baseline 的 tick（`_ensure_baseline` 的幂等闸）：
    #: 漏声明会被 LangGraph 在图入口过滤掉 → 同一 tick 可能重复生成，或反过来
    #: 直接调用战术节点时拿不到地板。
    baseline_tick: int
    #: 地图边界 `[size_x, size_z]`（来自 `op=strategic` 的 `map_bounds`）。
    #: 规则层的**任何坐标产出**（建造落点/侦察航点/前压点）都必须知道它：
    #: 实测 160/169 条 build 回执是 `OutOfBounds`（落点 z=1.3 越过地图下边界），
    #: 阶梯被同两个坏点反复重试，整局发展停摆。
    map_bounds: List[float]
    plan_version_history: List[str]
    reserves: Dict[str, int]
    reserves_initialized: bool
    reserves_percent: int
    task_progress: Dict[str, Any]
    #: 连续行动监督（2026-10-07）：每个 AI 单位的停滞/闲置台账，以及本轮监督报告。
    #: 必须声明为通道：`progress.supervise_continuity` 每轮**读上一轮**的 `last_moved_tick`
    #: 来算"停了多久"，漏声明 → LangGraph 在图入口过滤掉它 → 每轮从零开始 →
    #: 停滞永远到不了 2s/5s/10s 阈值（功能写了、单测也过、真机每轮归零的典型）。
    continuity_units: Dict[str, Dict[str, Any]]
    continuity_supervision: Dict[str, Any]
    #: 整局主线（阶段/里程碑/四条 track/next_frontier/interrupt_stack）。
    #: **必须声明为通道**：漏声明会被 LangGraph 在图入口 `_cleaned` 处过滤掉 →
    #: 状态每轮"从零开始"（里程碑永远重来、中断栈永远为空），正是纠偏要修的病根。
    campaign_state: Dict[str, Any]
    #: 高频链路与五线路（计划 P0/P1，2026-09-12）。**必须声明为通道**：
    #: 漏声明就与上面 `campaign_state` 完全同病 —— 键在图入口被 `_cleaned` 静默过滤，
    #: 表现为"功能写了、单测也过，真机上每轮归零"：
    #: `fast_event_seq` = 增量事件游标；`lane_cursor`/`lanes_last_served` = 五线路
    #: 轮转与饿死账；`lanes` = 各线路任务数/到期/最后处理 tick（验收要读它）。
    fast_event_seq: int
    lane_cursor: int
    lanes_last_served: Dict[str, int]
    lanes: Dict[str, Any]
    #: 安全移动（计划 §7）：`nav_revision` = 当前导航网格版本（来自 fast_state）；
    #: `routes` = 每个单位最近一次安全路线记录（route_id/nav_revision/waypoints/
    #: threat_score/scout_confirmation/retreat_point/last_replan_tick）；
    #: `movement_stats` = 闸门统计（allowed/blocked_reasons/ungated/scout_first_coverage…）；
    #: `movement_urgent` = 遇敌/路径失败要送紧急线的事件。
    nav_revision: int
    routes: Dict[str, Any]
    movement_stats: Dict[str, Any]
    movement_urgent: List[Dict[str, Any]]
    #: 【2026-09-14 血泪】下面这五个字段曾经**漏声明**，于是每轮在 `_cleaned` 处被静默丢掉：
    #: - `production_ledger`：生产账本每轮归零（归档里"生产样本 0"的真因之一）；
    #: - `army_cap`：兵力上限的留档永远空（拦截本身有效，因为它每轮从观测重算）；
    #: - `combat_types`：作战单位口径表每轮归零（**曾被我误判成"验收局规则视图没有
    #:   capabilities"**，实测导出是齐的）；
    #: - `unattackable_targets` / `enemy_types`：**"打不了的目标"记忆每轮清空** →
    #:   同一条注定被拒的攻击命令每轮重发（`Unit_43` 被拒 10 次、一局 124 条被拒命令的真因），
    #:   而单测与图内决策日志都是正常的 —— 典型"单测过、真机归零"。
    #: 纪律：**新增 `AdjutantGraphState` 字段必须同步声明这里**；
    #: 守门测试 `tests/test_graph_state_channels.py` 会逐一比对，漏一个就红灯。
    production_ledger: Dict[str, Any]
    army_cap: Dict[str, Any]
    combat_types: List[str]
    unattackable_targets: Dict[str, int]
    #: **每轮**安全移动计数增量（`movement.note_round_delta` 写，随检查点持久化）。
    #: 累计值看不出"这一轮发生了什么"，而判"重规划是否挤占共享下发预算"只能看增量。
    movement_round_delta: Dict[str, Any]
    #: 算增量用的上一轮基线快照 `{"tick":…, "counts":{…}}`。
    movement_stats_snapshot: Dict[str, Any]
    #: 单位名 → 最近一次到达的 tick（军事轨据此把"刚到达的"排到前面）。
    unit_arrival_tick: Dict[str, int]
    #: 「这个单位现在采不了这个矿」的限时账（键 `"<unit>|<entity>"` → 记账 tick）。
    #: 权威回 `ResourceDepleted` 时写；采集轨据此**换矿**，900 tick 后自动失效
    #: （矿点会再生）。漏了它每轮归零 ⇒ 每轮往刚被拒的矿上撞。
    depleted_resources: Dict[str, int]
    #: 军事轨**轮转服务顺序**的游标。漏了它每轮从 0 开始 ⇒ 等于没有轮转。
    advance_cursor: int
    enemy_types: Dict[str, str]
    #: 我方单位名 → 类型：把"打不了"从个体升级到「单位类型 × 目标类型」的依据。
    own_unit_types: Dict[str, str]
    own_attack_domains: Dict[str, Any]
    enemy_domains: Dict[str, str]
    capability_version: str
    persistent_squads: List[Dict[str, Any]]
    engage_locks: Dict[str, str]
    seen_arrivals: Dict[str, int]
    #: 【U1/F01】探索前沿 + 访问记忆（`{"cells": {...}, "current": "cx,cz", "selected": n}`）。
    #: **必须声明**：这是"去过哪、下一个去哪"的跨轮记忆，漏声明就每轮清空 →
    #: 又回到"反复去同一个固定点"（审查 F01）。
    explore: Dict[str, Any]
    #: 【2026-09-22 D10】扩张前探退避记忆（连续探不出合法落点就停一段时间；
    #: 实测 det_17：300 秒 71 条前探令把部队全占住）。必须进图通道，否则每轮归零。
    expansion_probe_backoff: Dict[str, Any]
    #: 【2026-09-22 D13】侦察双保险跨 tick 记忆（轮转游标 + 每单位冷却）。
    scout_confirm: Dict[str, Any]
    #: 已侦察到的敌方位置（公开情报）：前压目标用它，小队才会真的走到敌人那儿去打。
    enemy_intel_points: List[Any]
    #: 【迭代2】一批"跨轮记忆"键：原先只在节点里 `state["x"] = …` 写，没进通道也没进 dataclass
    #: → **每轮归零**。实测症状：坏建造点被拒 12 次（计数恒 1）、已下发指纹清空（命令可每轮重发）、
    #: 拥塞退避失效（LedgerFull 猛发）。守门见 `tests/test_graph_state_channels.py` 的静态扫描。
    rejection_ledger: Dict[str, Any]
    blocked_build_spots: List[Any]
    build_home_anchor: List[float]
    build_backoff_until_tick: int
    build_reject_streak: int
    #: 【2026-09-21】战略层失败退避（同步调用一次超时堵 15s；runner 配成
    #: strategy_interval_ticks）。与 build_backoff 同一模式：必须进通道 + dataclass，
    #: 否则每轮归零、退避失效。
    strategy_backoff_until_tick: int
    measured_tick_hz: float
    tick_rate_anchor_tick: int
    tick_rate_anchor_mono: float
    strategy_epoch: int
    strategy_epoch_events: List[str]
    last_strategy_event_tick: int
    last_strategy_review_tick: int
    strategy_request: Dict[str, Any]
    strategy_metrics: Dict[str, Any]
    plan_commit_count: int
    plan_hold_count: int
    #: 本轮战略调度器是否还有在途或排队请求。每轮按 stats() 重算，不进 checkpoint。
    strategy_inflight: bool
    #: 退避等级（每次触发加倍：900→1800→3600→上限 7200 tick）：一片地形整体不可建时，
    #: "换点重试"会一直烧命令（实测一局 10 次 `SurfaceNotBuildable`）。
    build_backoff_level: int
    congestion_until_tick: int
    congestion_events: int
    recent_orders: Dict[str, int]
    decision_log: List[Dict[str, Any]]
    overrides: List[Dict[str, Any]]
    route: str
    paused: bool
    candidate_intents: List[Dict[str, Any]]
    #: 意图来源旁路账本 `{intent_id: baseline|behavior_tree|model}`（纠偏 §二要求可区分）。
    #: 必须声明为通道：漏声明会被 LangGraph 在图入口过滤 → 每轮都退回"无来源信息"，
    #: 于是"哪些是模型改的、哪些是规则跑的"在日志与指标里分不开。
    intent_origin: Dict[str, str]
    dispatch_pending: List[str]
    intent_arbitration: Dict[str, Any]
    last_checkpoint: Dict[str, Any]
    #: 决策追踪（第一阶段 · 修改 1）：会话 id 与轮次序号必须走通道 + dataclass，
    #: 否则 LangGraph 每轮把它们过滤掉 → 恢复后 session_id 归零、round_seq 撞号。
    trace_session: str
    trace_round_seq: int
    #: 任务闭环台账（第一阶段 · 修改 2）：跨轮记忆，漏声明 = 每轮归零
    #: （停滞判不出、重试预算永远满血——production_ledger 同类事故）。
    task_ledger: Dict[str, Any]
    task_ledger_feedback: Dict[str, Any]
    task_loop_report: Dict[str, Any]
    #: 闭环/经济评估配置（修改 2/3）：`node_ingest` 每轮从 GraphConfig 重算，
    #: 同轮内由 `campaign.update` 的经济异常评估读取。**必须声明为通道**：
    #: 漏声明会被 LangGraph 在节点间静默过滤（Fallback 不受影响），
    #: 表现为"langgraph 引擎下 --econ-* 配置不生效、只有默认值"。
    #: 不进 dataclass/checkpoint：每轮都新鲜，持久化反而会用上一个进程的配置快照。
    loop_config: Dict[str, Any]


ROUTE_TO_NODE = {
    itr.ROUTE_PLAYER_INTERRUPT: NODE_RECONCILE,
    itr.ROUTE_EMERGENCY_TACTICAL: NODE_TACTICAL,
    itr.ROUTE_STRATEGIC: NODE_STRATEGIC,
    itr.ROUTE_TACTICAL: NODE_TACTICAL,
    itr.ROUTE_WAIT: NODE_WAIT,
}


def route_after_classify(state: Dict[str, Any]) -> str:
    """条件边：player_override_gate 的分支决策。"""
    return ROUTE_TO_NODE.get(str(state.get("route", "")), NODE_WAIT)


def route_after_reconcile(state: Dict[str, Any]) -> str:
    """玩家打断后：暂停（等 resume）或继续走仲裁/下发。"""
    return NODE_PERSIST if state.get("paused") else NODE_ARBITRATE


@dataclass
class _TickContext:
    """每 tick 注入节点上下文（图编译一次、上下文可复用更新）。"""

    services: GraphServices
    observation: Dict[str, Any] = field(default_factory=dict)
    tick: int = 0

    @property
    def config(self):
        return self.services.config


def langgraph_available() -> Dict[str, Any]:
    try:
        import langgraph  # noqa: F401
        from langgraph.graph import StateGraph  # noqa: F401
    except Exception as exc:  # noqa: BLE001
        return {"available": False, "reason": str(exc)}
    return {"available": True, "reason": ""}


class GraphRunner:
    """执行器基类：统一 run_tick / resume / paused 语义。"""

    engine = ENGINE_FALLBACK

    #: 每轮节点耗时的**有界**样本窗口（用于 p50/p95/p99）。
    PHASE_SAMPLE_LIMIT = 240

    def __init__(self, services: GraphServices) -> None:
        self.services = services
        self._ctx = _TickContext(services)
        self._paused = False
        self._phase_ms: Dict[str, List[float]] = {}
        self._phase_round_ms: Dict[str, float] = {}

    # ---- 分段计时（prompt §3-A：协调轮必须能分段归因） ----

    def begin_round_timing(self) -> None:
        """开始新一轮计时：清掉本轮累计（跨轮的 `phase_stats()` 仍保留历史样本）。"""
        self._phase_round_ms = {}

    def _time_phase(self, name: str) -> Callable[[], None]:
        """返回一个"停止计时"的闭包；异常也必须记时（否则慢轮会被漏掉）。

        【为什么不用装饰器/上下文管理器套在每个函数上】节点是图的一部分，
        行为必须逐字不变；这里只在**调用点**夹一层计时，不改任何节点语义。
        """
        started = time.monotonic()

        def _stop() -> None:
            elapsed_ms = (time.monotonic() - started) * 1000.0
            key = str(name)
            self._phase_round_ms[key] = self._phase_round_ms.get(key, 0.0) + elapsed_ms
            samples = self._phase_ms.setdefault(key, [])
            samples.append(elapsed_ms)
            if len(samples) > self.PHASE_SAMPLE_LIMIT:
                del samples[0:len(samples) - self.PHASE_SAMPLE_LIMIT]

        return _stop

    def phase_stats(self) -> Dict[str, Dict[str, Any]]:
        """每轮各阶段耗时：本轮合计 + 历史 p50/p95/p99/max（毫秒，一位小数）。

        验收要回答的问题只有两个：
        ① 这一轮为什么慢（哪个阶段）？→ `round_ms`
        ② 慢轮是常态还是尾巴？→ `p95/p99/max_ms`
        """
        out: Dict[str, Dict[str, Any]] = {}
        for name in sorted(set(self._phase_ms) | set(self._phase_round_ms)):
            samples = sorted(self._phase_ms.get(name) or [])

            def _pct(ratio: float) -> float:
                if not samples:
                    return 0.0
                index = min(len(samples) - 1, max(0, int(math.ceil(ratio * len(samples))) - 1))
                return round(samples[index], 1)

            out[name] = {
                "round_ms": round(float(self._phase_round_ms.get(name, 0.0)), 1),
                "p50_ms": _pct(0.50), "p95_ms": _pct(0.95), "p99_ms": _pct(0.99),
                "max_ms": round(samples[-1], 1) if samples else 0.0,
                "samples": len(samples),
            }
        return out

    # ---- 决策追踪（第一阶段 · 修改 1）----
    #
    # 追踪是**旁路**：录制失败只计数、绝不抛回调用方，也不改变任何节点语义。
    # 节点 enter/exit/error 与阶段耗时在同一处夹取（调用点包装，不改节点本身）。

    def _trace(self):
        """取追踪记录器；未注入/禁用时为 None（零成本直跑）。"""
        return getattr(self.services, "trace", None)

    def _run_node(self, name: str, fn: Callable, state: Dict[str, Any],
                  node_name: str = "") -> Dict[str, Any]:
        """执行一个节点并记录 span（enter/exit/error + 耗时）。

        两条执行器（LangGraph / Fallback）都走这里，保证追踪合同一致：
        - `span_id` 用 round_seq + 节点名构造（不用 tick：相同 tick 的多轮不串）；
        - 异常必须留 error span（"异常、超时、取消不能漏掉退出状态"）；
        - 记录失败只累加诊断计数，不影响本节点结果。

        `name` 是阶段计时键（历史口径），`node_name` 是追踪里的图节点名
        （拓扑常量）；两者只在这一层换算，节点函数本身零改动。
        """
        trace = self._trace()
        trace_node = str(node_name or name)
        if trace is None:
            stop = self._time_phase(name)
            try:
                return fn(state, self._ctx)
            finally:
                stop()
        span_id = "r%d-%s" % (int(getattr(trace, "round_seq", 0) or 0), trace_node)
        tick = int(self._ctx.tick)
        try:
            trace.node_enter(trace_node, span_id, server_tick=tick)
        except Exception:  # noqa: BLE001 —— 旁路永不拖垮指挥链
            pass
        stop = self._time_phase(name)
        try:
            out = fn(state, self._ctx)
        except Exception as exc:  # noqa: BLE001 —— 留 error span 后原样抛出
            stop()
            try:
                trace.node_error(trace_node, span_id,
                                 duration_ms=self._phase_round_ms.get(name, 0.0),
                                 error=repr(exc)[:300], server_tick=tick)
            except Exception:  # noqa: BLE001
                pass
            raise
        stop()
        try:
            trace.node_exit(trace_node, span_id,
                            duration_ms=self._phase_round_ms.get(name, 0.0),
                            server_tick=tick,
                            summary={"route": str(out.get("route", "")) if isinstance(out, dict) else ""})
        except Exception:  # noqa: BLE001
            pass
        return out

    # ---- 对外 API ----

    def run_tick(self, state: Dict[str, Any], observation: Optional[Dict[str, Any]] = None,
                 tick: Optional[int] = None) -> Dict[str, Any]:
        raise NotImplementedError

    def resume(self, state: Dict[str, Any],
               observation: Optional[Dict[str, Any]] = None,
               tick: Optional[int] = None) -> Dict[str, Any]:
        raise NotImplementedError

    @property
    def paused(self) -> bool:
        return self._paused

    def describe(self) -> str:
        return "%s(paused=%s)" % (type(self).__name__, self._paused)


class FallbackRunner(GraphRunner):
    """内置确定性执行器：节点与拓扑和 LangGraph 路径一致（无第三方依赖）。"""

    engine = ENGINE_FALLBACK

    def __init__(self, services: GraphServices) -> None:
        super().__init__(services)
        self.executed: List[str] = []

    def run_tick(self, state: Dict[str, Any], observation: Optional[Dict[str, Any]] = None,
                 tick: Optional[int] = None) -> Dict[str, Any]:
        self._ctx.observation = dict(observation or {})
        self._ctx.tick = int(tick if tick is not None else state.get("server_tick", 0))
        self.executed = []
        state = self._node(NODE_INGEST, node_ingest, state)
        # 整局主线推进必须在路由/微操之前：阶梯顺序、里程碑证据、中断栈都由它决定。
        state = self._node(NODE_CAMPAIGN, node_update_campaign, state)
        state = self._node(NODE_CLASSIFY, node_classify, state)
        route = str(state.get("route", itr.ROUTE_WAIT))
        if route == itr.ROUTE_PLAYER_INTERRUPT:
            state = self._node(NODE_RECONCILE, node_reconcile_plan, state)
        elif route in (itr.ROUTE_EMERGENCY_TACTICAL, itr.ROUTE_TACTICAL):
            state = self._node(NODE_TACTICAL, node_tactical_agent, state)
        elif route == itr.ROUTE_STRATEGIC:
            state = self._node(NODE_STRATEGIC, node_strategic_agent, state)
        else:
            state = self._node(NODE_WAIT, node_wait, state)
        # 与 LangGraph 的 interrupt_after 等价：暂停则不跑尾链，等 resume。
        self._paused = bool(self.services.config.pause_on_player_interrupt
                            and state.get("paused"))
        if self._paused:
            return state
        return self._tail(state)

    def resume(self, state: Dict[str, Any],
               observation: Optional[Dict[str, Any]] = None,
               tick: Optional[int] = None) -> Dict[str, Any]:
        """从暂停点继续（等价于 LangGraph 的 Command(resume=None)）。"""
        self._ctx.observation = dict(observation or {})
        self._ctx.tick = int(tick if tick is not None else state.get("server_tick", 0))
        self._paused = False
        return self._tail(state)

    def _tail(self, state: Dict[str, Any]) -> Dict[str, Any]:
        state = self._node(NODE_ARBITRATE, node_arbitrate_intent, state)
        state = self._node(NODE_DISPATCH, node_dispatch_to_godot, state)
        state = self._node(NODE_OBSERVE, node_observe_receipt, state)
        # 回执结算之后再判一次里程碑/中断恢复：本轮下发的命令产生的回执证据
        # 必须**当轮**生效，否则"完成"永远晚一轮（对局快节奏时表现为"反应迟钝"）。
        state = self._node(NODE_ADVANCE, node_advance_milestones, state)
        state = self._node(NODE_PERSIST, node_persist_checkpoint, state)
        state["paused"] = False
        return state

    def _node(self, name: str, fn: Callable, state: Dict[str, Any]) -> Dict[str, Any]:
        self.executed.append(name)
        return self._run_node(name, fn, state)


class LangGraphRunner(GraphRunner):
    """LangGraph 执行器：真实 StateGraph + MemorySaver + interrupt/resume。

    - 图编译一次；每 tick 通过共享 _TickContext 注入观测；
    - 玩家打断：reconcile_plan 之后 interrupt_after 暂停图（状态由 MemorySaver 保存），
      下一次 tick 用 Command(resume=None) 恢复并完成仲裁/下发/回执/持久化；
    - 对局状态持久化仍由 checkpoint.py 负责（MemorySaver 只是图内暂停栈）。
    """

    engine = ENGINE_LANGGRAPH

    def __init__(self, services: GraphServices, thread_id: str = "default") -> None:
        super().__init__(services)
        availability = langgraph_available()
        if not availability["available"]:
            raise RuntimeError("langgraph 不可用：%s" % availability["reason"])
        from langgraph.checkpoint.memory import MemorySaver
        from langgraph.graph import END, StateGraph

        builder = StateGraph(GraphStateDict)
        builder.add_node(NODE_INGEST, self._wrap(node_ingest, NODE_INGEST))
        builder.add_node(NODE_CAMPAIGN, self._wrap(node_update_campaign, NODE_CAMPAIGN))
        builder.add_node(NODE_ADVANCE, self._wrap(node_advance_milestones, NODE_ADVANCE))
        builder.add_node(NODE_CLASSIFY, self._wrap(node_classify, NODE_CLASSIFY))
        builder.add_node(NODE_RECONCILE, self._wrap(node_reconcile_plan, NODE_RECONCILE))
        builder.add_node(NODE_STRATEGIC, self._wrap(node_strategic_agent, NODE_STRATEGIC))
        builder.add_node(NODE_TACTICAL, self._wrap(node_tactical_agent, NODE_TACTICAL))
        builder.add_node(NODE_WAIT, self._wrap(node_wait, NODE_WAIT))
        builder.add_node(NODE_ARBITRATE, self._wrap(node_arbitrate_intent, NODE_ARBITRATE))
        builder.add_node(NODE_DISPATCH, self._wrap(node_dispatch_to_godot, NODE_DISPATCH))
        builder.add_node(NODE_OBSERVE, self._wrap(node_observe_receipt, NODE_OBSERVE))
        builder.add_node(NODE_PERSIST, self._wrap(node_persist_checkpoint, NODE_PERSIST))

        builder.set_entry_point(NODE_INGEST)
        builder.add_edge(NODE_INGEST, NODE_CAMPAIGN)
        builder.add_edge(NODE_CAMPAIGN, NODE_CLASSIFY)
        builder.add_conditional_edges(NODE_CLASSIFY, route_after_classify, {
            NODE_RECONCILE: NODE_RECONCILE,
            NODE_STRATEGIC: NODE_STRATEGIC,
            NODE_TACTICAL: NODE_TACTICAL,
            NODE_WAIT: NODE_WAIT,
        })
        builder.add_conditional_edges(NODE_RECONCILE, route_after_reconcile, {
            NODE_ARBITRATE: NODE_ARBITRATE,
            NODE_PERSIST: NODE_PERSIST,
        })
        for node in (NODE_STRATEGIC, NODE_TACTICAL, NODE_WAIT):
            builder.add_edge(node, NODE_ARBITRATE)
        builder.add_edge(NODE_ARBITRATE, NODE_DISPATCH)
        builder.add_edge(NODE_DISPATCH, NODE_OBSERVE)
        builder.add_edge(NODE_OBSERVE, NODE_ADVANCE)
        builder.add_edge(NODE_ADVANCE, NODE_PERSIST)
        builder.add_edge(NODE_PERSIST, END)

        self.thread_id = thread_id
        self._app = builder.compile(checkpointer=MemorySaver(),
                                    interrupt_after=[NODE_RECONCILE])

    def _wrap(self, fn: Callable, node_name: str = "") -> Callable:
        ctx = self._ctx
        phase_name = str(getattr(fn, "__name__", "node"))
        # 追踪里的节点名用图拓扑常量（ingest_observation…），与 FallbackRunner 一致；
        # 阶段计时键保持历史名字（fn.__name__），不改既有 phases 日志口径。
        trace_name = str(node_name or phase_name)

        def _node(state: Dict[str, Any]) -> Dict[str, Any]:
            return self._run_node(phase_name, lambda inner, context: fn(inner, context),
                                  state, node_name=trace_name)

        _node.__name__ = fn.__name__
        return _node

    def _config(self) -> Dict[str, Any]:
        return {"configurable": {"thread_id": self.thread_id}}

    def run_tick(self, state: Dict[str, Any], observation: Optional[Dict[str, Any]] = None,
                 tick: Optional[int] = None) -> Dict[str, Any]:
        self._ctx.observation = dict(observation or {})
        self._ctx.tick = int(tick if tick is not None else state.get("server_tick", 0))
        out = _strip_internal(self._app.invoke(_cleaned(state), config=self._config()))
        self._paused = bool(self.services.config.pause_on_player_interrupt
                            and out.get("paused"))
        return out

    def resume(self, state: Dict[str, Any],
               observation: Optional[Dict[str, Any]] = None,
               tick: Optional[int] = None) -> Dict[str, Any]:
        from langgraph.types import Command

        self._ctx.observation = dict(observation or {})
        self._ctx.tick = int(tick if tick is not None else state.get("server_tick", 0))
        self._paused = False
        # resume 载荷只用于解除暂停；图内节点不消费该值（决策依据一律来自状态）。
        out = _strip_internal(self._app.invoke(
            Command(resume={"resumed": True}), config=self._config()))
        merged = _merge_missing(out, state)
        merged["paused"] = False
        return merged


def _cleaned(state: Dict[str, Any]) -> Dict[str, Any]:
    """只把图状态通道喂给 LangGraph（其他键不进入通道，避免被静默丢弃误解）。"""
    return {key: value for key, value in state.items() if key in GraphStateDict.__annotations__}


def _strip_internal(state: Dict[str, Any]) -> Dict[str, Any]:
    return {key: value for key, value in state.items() if not str(key).startswith("__")}


def _merge_missing(out: Dict[str, Any], source: Dict[str, Any]) -> Dict[str, Any]:
    """恢复后补齐 LangGraph 通道未覆盖的键（保证状态字段不丢）。"""
    merged = dict(out)
    for key, value in source.items():
        if key not in merged:
            merged[key] = value
    return merged


def build_runner(services: GraphServices, engine: str = "auto",
                 thread_id: str = "default") -> GraphRunner:
    """按可用性选择执行器；engine=langgraph 时不可用则明确报错（不静默降级）。"""
    if engine == ENGINE_LANGGRAPH:
        return LangGraphRunner(services, thread_id=thread_id)
    if engine == ENGINE_FALLBACK:
        return FallbackRunner(services)
    availability = langgraph_available()
    if availability["available"]:
        return LangGraphRunner(services, thread_id=thread_id)
    return FallbackRunner(services)
