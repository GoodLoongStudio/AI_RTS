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

from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, TypedDict

from . import interrupts as itr
from .nodes import (
    NODE_ARBITRATE, NODE_CLASSIFY, NODE_DISPATCH, NODE_INGEST, NODE_OBSERVE,
    NODE_PERSIST, NODE_RECONCILE, NODE_STRATEGIC, NODE_TACTICAL, NODE_WAIT,
    GraphServices, node_arbitrate_intent, node_classify, node_dispatch_to_godot,
    node_ingest, node_observe_receipt, node_persist_checkpoint, node_reconcile_plan,
    node_strategic_agent, node_tactical_agent, node_wait,
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
    plan_version_history: List[str]
    reserves: Dict[str, int]
    reserves_initialized: bool
    reserves_percent: int
    task_progress: Dict[str, Any]
    decision_log: List[Dict[str, Any]]
    overrides: List[Dict[str, Any]]
    route: str
    paused: bool
    candidate_intents: List[Dict[str, Any]]
    dispatch_pending: List[str]
    intent_arbitration: Dict[str, Any]
    last_checkpoint: Dict[str, Any]


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

    def __init__(self, services: GraphServices) -> None:
        self.services = services
        self._ctx = _TickContext(services)
        self._paused = False

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
        state = self._node(NODE_PERSIST, node_persist_checkpoint, state)
        state["paused"] = False
        return state

    def _node(self, name: str, fn: Callable, state: Dict[str, Any]) -> Dict[str, Any]:
        self.executed.append(name)
        return fn(state, self._ctx)


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
        builder.add_node(NODE_INGEST, self._wrap(node_ingest))
        builder.add_node(NODE_CLASSIFY, self._wrap(node_classify))
        builder.add_node(NODE_RECONCILE, self._wrap(node_reconcile_plan))
        builder.add_node(NODE_STRATEGIC, self._wrap(node_strategic_agent))
        builder.add_node(NODE_TACTICAL, self._wrap(node_tactical_agent))
        builder.add_node(NODE_WAIT, self._wrap(node_wait))
        builder.add_node(NODE_ARBITRATE, self._wrap(node_arbitrate_intent))
        builder.add_node(NODE_DISPATCH, self._wrap(node_dispatch_to_godot))
        builder.add_node(NODE_OBSERVE, self._wrap(node_observe_receipt))
        builder.add_node(NODE_PERSIST, self._wrap(node_persist_checkpoint))

        builder.set_entry_point(NODE_INGEST)
        builder.add_edge(NODE_INGEST, NODE_CLASSIFY)
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
        builder.add_edge(NODE_OBSERVE, NODE_PERSIST)
        builder.add_edge(NODE_PERSIST, END)

        self.thread_id = thread_id
        self._app = builder.compile(checkpointer=MemorySaver(),
                                    interrupt_after=[NODE_RECONCILE])

    def _wrap(self, fn: Callable) -> Callable:
        ctx = self._ctx

        def _node(state: Dict[str, Any]) -> Dict[str, Any]:
            return fn(state, ctx)

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
