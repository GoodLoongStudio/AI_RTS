# -*- coding: utf-8 -*-
"""图节点实现（LangGraph 与内置确定性执行器共用同一批函数）。

节点拓扑（方案 §4）：
    ingest_observation
        ↓
    classify_event
        ↓
    player_override_gate（由 classify_event 的路由体现）
        ├─ player_interrupt     → reconcile_plan
        ├─ emergency_tactical   → tactical_agent
        ├─ strategic_due        → strategic_agent
        ├─ tactical_due         → tactical_agent
        └─ wait                 → wait
        ↓
    arbitrate_intent → dispatch_to_godot → observe_receipt → persist_checkpoint

纪律：
- 节点函数只改状态与产出候选意图；真正发命令只在 dispatch_to_godot，
  且必须经过注入的权威通道（Godot CommandRuntime / 兼容协调器）；
- 模型不可用/超时/非法输出：节点记录降级并继续，绝不阻塞；
- 节点返回完整 state dict（LangGraph 直接合并，内置执行器直接使用）。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, Tuple

from . import interrupts as itr
from .arbitration import arbitrate_intents
from .checkpoint import CheckpointStore, NullCheckpointStore
from .contracts import (
    ACTION_RETREAT, ContractError, IntentBatch, StrategicPlan,
    intent_to_command_envelope, parse_intent_batch, parse_strategic_plan,
)
from . import behavior_tree
from . import rules_fallback
from . import task_patch_bridge
from .async_scheduler import KIND_EMERGENCY, KIND_NORMAL, STATUS_ERROR, STATUS_OK
from .task_patch import MODE_FAST
from .model_context import (
    build_strategy_context, build_tactics_context, known_entity_ids,
    own_unit_ids, rules_scene_index, rules_scene_paths,
)
from .pydantic_agents import ModelInvalidOutput, ModelTimeout, ModelUnavailable
from . import reserves as reserves_mod
from .progress import track_task_progress
from .state import (
    INTENT_DROPPED, INTENT_LIVE_STATES, MAX_DECISION_LOG, TASK_RUNNING, TASK_UNKNOWN,
)

# 路由名称（与 graph.py 的条件边一致）。
NODE_INGEST = "ingest_observation"
NODE_CLASSIFY = "classify_event"
NODE_RECONCILE = "reconcile_plan"
NODE_STRATEGIC = "strategic_agent"
NODE_TACTICAL = "tactical_agent"
NODE_ARBITRATE = "arbitrate_intent"
NODE_DISPATCH = "dispatch_to_godot"
NODE_OBSERVE = "observe_receipt"
NODE_PERSIST = "persist_checkpoint"
NODE_WAIT = "wait"


@dataclass
class GraphConfig:
    """图配置：全部间隔/预算配置化（数值是起点，以实测为准）。"""

    strategy_interval_ticks: int = 3600       # 60s @60Hz
    tactics_interval_ticks: int = 30          # 0.5s @60Hz
    emergency_min_interval_ticks: int = 6     # 紧急战术最小间隔（防事件风暴）
    intent_ttl_ticks: int = 600               # 普通意图 TTL 上限
    emergency_intent_ttl_ticks: int = 300     # 紧急意图 TTL 上限
    max_batch: int = 8                        # 每轮最多提交意图数
    model_error_limit: int = 3                # 连续模型失败上限
    model_retry_cooldown_ticks: int = 60      # 达到上限后的冷却
    pending_timeout_ticks: int = 240          # PendingAuthority 复核超时（不重下单）
    recheck_pending: bool = True              # 每轮按 command_id 复核在途命令
    pause_on_player_interrupt: bool = True    # 玩家打断时暂停图（LangGraph interrupt）


@dataclass
class GraphServices:
    """图依赖的服务集合（全部可注入，测试用 FakeModel/内存 checkpoint）。"""

    strategy_model: Any = None                # propose_plan(context) -> StrategicPlan|None
    tactics_model: Any = None                 # propose_intents(context) -> IntentBatch|None
    #: 有界异步调度器（`async_scheduler.DecisionScheduler`）；None = 同步调用（legacy 回退）。
    tactics_scheduler: Any = None
    dispatch: Optional[Callable[[List[Dict[str, Any]]], List[Dict[str, Any]]]] = None
    recheck: Optional[Callable[[str], Optional[Dict[str, Any]]]] = None
    adoption: Optional[Callable[[Dict[str, Any], int], Tuple[bool, str]]] = None
    player_event_hook: Optional[Callable[[Dict[str, Any]], None]] = None
    checkpoint_store: CheckpointStore = field(default_factory=NullCheckpointStore)
    config: GraphConfig = field(default_factory=GraphConfig)
    logger: Any = None

    def log(self, event: str, **fields: Any) -> None:
        if self.logger is None:
            return
        try:
            self.logger.log(event, **fields)
        except Exception:  # 日志失败不改变决策路径（留证权在宿主）。
            pass


@dataclass
class NodeContext:
    """单 tick 的上下文：服务 + 本次观测 + 服务器 tick。"""

    services: GraphServices
    observation: Dict[str, Any]
    tick: int

    @property
    def config(self) -> GraphConfig:
        return self.services.config


def _normalize_plan_version(given: Any, state: Dict[str, Any]) -> str:
    """把模型常见的 plan_version 等价写法归一化到当前生效版本；其余不一致仍会被丢弃。

    等价写法：plan_id、纯版本号、"v1"、 "<plan_id>:v1" 等（真实模型常把 plan_id 当版本号）。
    """
    active = str(state.get("plan_version", "") or "")
    text = str(given or "")
    if not text or text == active:
        return active or text
    history = {str(item) for item in (state.get("plan_version_history") or [])}
    if text in history:
        # 明确回显了已被替换的历史计划版本 → 保持原样，交由仲裁按“真·过期计划”丢弃。
        return text
    plan = state.get("active_plan") or {}
    plan_id = str(plan.get("plan_id", "") or "")
    version_int = int(plan.get("plan_version", 0) or 0)
    equivalents = {plan_id, str(version_int), "v%d" % version_int}
    if plan_id and version_int:
        equivalents.add("%s:v%d" % (plan_id, version_int))
        equivalents.add("%s:1" % plan_id)
    equivalents.discard("")
    # 模型把 plan_id / 版本号 / "v1" 等当作 plan_version 回显：按当前生效版本归一化
    # （真实模型常见笔误；旧的“历史版本”已在上面单独放行给仲裁丢弃）。
    return active or text


def _fill_batch_echo(batch: Any, state: Dict[str, Any], default_ttl: int = 600) -> Any:
    """把模型省略/留空的“回声字段”按上下文补齐（match/player/plan_version/快照/tick）。

    只补缺失或空值；模型给出非空但不一致的值仍会被契约与节点校验拒绝，
    因此不放松任何身份约束，只降低真实模型的结构化输出失败率。
    """
    if not isinstance(batch, dict):
        return batch
    filled = dict(batch)
    filled["match_id"] = str(filled.get("match_id") or state.get("match_id", ""))
    filled["player_id"] = str(filled.get("player_id") or state.get("player_id", ""))
    filled["plan_version"] = _normalize_plan_version(filled.get("plan_version"), state)
    if not int(filled.get("based_on_snapshot", 0) or 0):
        filled["based_on_snapshot"] = int(state.get("latest_snapshot_id", 0) or 0)
    server_tick = int(state.get("server_tick", 0) or 0)
    window = max(1, int(default_ttl or 600))
    intents: List[Any] = []
    for item in filled.get("intents", []) or []:
        if not isinstance(item, dict):
            intents.append(item)
            continue
        entry = dict(item)
        entry["plan_version"] = str(entry.get("plan_version") or filled["plan_version"])
        if entry["plan_version"] != filled["plan_version"]:
            entry["plan_version"] = _normalize_plan_version(entry["plan_version"], state)
        if not int(entry.get("based_on_snapshot", 0) or 0):
            entry["based_on_snapshot"] = int(filled["based_on_snapshot"] or 0)
        if not int(entry.get("issued_tick", 0) or 0):
            entry["issued_tick"] = server_tick
        # 过期窗口按“未指定”处理：真实模型常用自己的时钟概念，导致窗口已经过期。
        # 这里按当前 tick + 窗口填写；下发前还会按最新 tick 再核一次（runtime.tick_provider）。
        if int(entry.get("expires_tick", 0) or 0) <= server_tick:
            entry["expires_tick"] = server_tick + window
        intents.append(entry)
    filled["intents"] = intents
    return filled


def _consume_events(state: Dict[str, Any], kinds: Optional[tuple] = None) -> int:
    """消费（清空）已处理事件；kinds=None 表示消费全部。

    事件是“有界队列 + 快照可恢复”的语义：消费只表示本轮已处理，
    模型失败/跳过时保留事件（下一轮重试），不静默丢弃。
    """
    if kinds is None:
        consumed = len(state.get("pending_events", []))
        state["pending_events"] = []
        return consumed
    kept = []
    consumed = 0
    for event in state.get("pending_events", []):
        if str(event.get("kind", "")) in kinds:
            consumed += 1
        else:
            kept.append(event)
    state["pending_events"] = kept
    return consumed


def _decide(state: Dict[str, Any], kind: str, **payload: Any) -> Dict[str, Any]:
    entry = {"kind": kind, "server_tick": int(state.get("server_tick", 0)), **payload}
    log = state.setdefault("decision_log", [])
    log.append(entry)
    while len(log) > MAX_DECISION_LOG:
        log.pop(0)
    return entry


def _log(ctx: NodeContext, state: Dict[str, Any], event: str, **fields: Any) -> None:
    ctx.services.log(event, match_id=state.get("match_id", ""),
                     player_id=state.get("player_id", ""),
                     server_tick=state.get("server_tick", 0), **fields)


# ---------------- 观测与分类 ----------------

def _sync_lease_generations(state: Dict[str, Any], ctx: NodeContext) -> None:
    """把权威租约代际对齐进本地 `unit_generations`（只升不降）。

    `max` 规则的边界：本地高于权威（玩家接管镜像 +1）→ 保留本地（权威守卫只拒
    "落后"，超前无害）；权威高于本地（跨对局累加的租约计数）→ 采纳权威，否则该
    单位之后所有命令都被 StaleGeneration 白拒。这只影响**未来的**新意图：在途
    DecisionFrame 的代际在发起时已冻结，真正的过期结果仍会被权威端拒绝（不续期）。
    """
    tactical = ctx.observation.get("tactical") or {}
    if not isinstance(tactical, dict):
        return
    lease_generations = tactical.get("lease_generations") or {}
    if not isinstance(lease_generations, dict) or not lease_generations:
        return
    gens = state.setdefault("unit_generations", {})
    corrected: Dict[str, str] = {}
    highest = 0
    for unit_name, value in lease_generations.items():
        try:
            gen = int(value)
        except (TypeError, ValueError):
            continue
        key = str(unit_name)
        old = int(gens.get(key, 0) or 0)
        highest = max(highest, gen)
        if gen > old:
            gens[key] = gen
            corrected[key] = "%d->%d" % (old, gen)
    if not corrected:
        return
    state["control_generation"] = max(int(state.get("control_generation", 0) or 0), highest)
    _decide(state, "lease_generation_synced", corrected=corrected)


def node_ingest(state: Dict[str, Any], ctx: NodeContext) -> Dict[str, Any]:
    """消费观测包头与事件：校验身份漂移，推进 tick/snapshot，入队事件，过期清理。

    本节点同时把“每轮字段”（候选意图/待下发/仲裁结果）重置为本轮空值，
    避免上一轮的仲裁结果被误读为本轮结果（恢复 checkpoint 后尤其重要）。
    """
    state["candidate_intents"] = []
    state["dispatch_pending"] = []
    state["intent_arbitration"] = {"accepted": [], "dropped": [], "clamped": []}
    header = ctx.observation.get("header") or {}
    drift: Dict[str, Any] = {}
    for key in ("match_id", "player_id"):
        bound = str(state.get(key, ""))
        seen = str(header.get(key, ""))
        if bound and seen and seen != bound:
            drift[key] = {"bound": bound, "observed": seen}
    seen_rules = str(header.get("rules_version", ""))
    if state.get("rules_version") and seen_rules and seen_rules != state["rules_version"]:
        drift["rules_version"] = {"bound": state["rules_version"], "observed": seen_rules}
    if drift:
        # 身份漂移：保持断开/降级，不发任何命令（绝不把命令发进别的对局）。
        state["degraded_reason"] = "identity_drift"
        _decide(state, "identity_drift", drift=drift)
        _log(ctx, state, "graph_identity_drift", drift=str(drift))
        return state

    state["server_tick"] = max(int(state.get("server_tick", 0)), int(header.get("server_tick", 0)))
    state["latest_snapshot_id"] = max(int(state.get("latest_snapshot_id", 0)),
                                      int(header.get("snapshot_id", 0)))
    if seen_rules:
        state["rules_version"] = seen_rules
    # 控制代际以权威为准（设计 §3）：op=tactical 每轮回传权威租约代际，落后即对齐。
    # 不对齐的后果：权威计数器跨对局累加而本地每轮重算，单位第一次命令后租约代际
    # 永远领先本地 → 之后所有命令被 StaleGeneration 白拒（实测 5 分钟 336 条）。
    _sync_lease_generations(state, ctx)

    # AI 可控单位以观测为事实来源：本玩家自有单位 - 玩家接管 - 已归还待接管。
    # 这样战略层才能把任务指派给真实存在的单位（否则首次战略 tick 无单位可指派）。
    tactical = ctx.observation.get("tactical")
    observed_own = sorted(own_unit_ids(tactical)) if isinstance(tactical, dict) else []
    if observed_own:
        _ensure_units(state, observed_own)
        player_units = set(str(u) for u in state.get("player_controlled_units", []))
        released = set(str(u) for u in state.get("released_units", []))
        state["ai_controlled_units"] = [u for u in observed_own
                                        if u not in player_units and u not in released]

    events = list(ctx.observation.get("events") or [])
    accepted = 0
    for event in events:
        if not isinstance(event, dict):
            continue
        if state_push_event(state, event):
            accepted += 1
    expired = _mark_expired(state)
    # 观测驱动的任务进度（方案 §4：与命令回执分离）。
    # 放在 ingest 里是因为这里每轮都有新鲜观测，且早于路由——
    # 这样"任务已完成/已失败"能立刻影响本轮的战术决策，而不是等下一圈。
    # 任何异常都只记录不抛出：进度监督失效绝不允许拖垮指挥链。
    try:
        progress = track_task_progress(state, observation=ctx.observation,
                                       tick=int(state.get("server_tick", 0)),
                                       config=_config_dict(ctx.config))
        if progress.get("intents"):
            _decide(state, "task_progress", updated=len(progress["intents"]))
    except Exception as exc:  # noqa: BLE001
        _log(ctx, state, "graph_progress_error", error=str(exc)[:200])
    if accepted or expired:
        _decide(state, "observation_ingested", new_events=accepted, expired_intents=expired)
    _log(ctx, state, "graph_observation", snapshot_id=state.get("latest_snapshot_id", 0),
         new_events=accepted, expired_intents=expired)
    return state


def state_push_event(state: Dict[str, Any], event: Dict[str, Any]) -> bool:
    """有界事件队列 + event_id 去重（与 AdjutantGraphState.push_event 同语义）。"""
    event_id = str(event.get("event_id", ""))
    queue = state.setdefault("pending_events", [])
    if event_id:
        for existing in queue:
            if existing.get("event_id") == event_id:
                return False
    queue.append(dict(event))
    while len(queue) > 256:
        queue.pop(0)
    return True


def _mark_expired(state: Dict[str, Any]) -> List[str]:
    tick = int(state.get("server_tick", 0))
    expired: List[str] = []
    for intent in state.get("active_intents", []):
        if intent.get("state") not in ("active", "pending_authority"):
            continue
        if int(intent.get("expires_tick", 0)) < tick:
            intent["state"] = "expired"
            intent["drop_reason"] = "expires_tick < server_tick"
            expired.append(str(intent.get("intent_id", "")))
    return expired


def _intake_patch_outcome(state: Dict[str, Any], ctx: NodeContext) -> bool:
    """**每轮**收取异步决策结果（而不是等到下一次战术路由）。

    实测依据（2026-09-12，真实对局）：只在下一次战术路由取结果时，结果要等约 26s 才被取走，
    远超 fast 模式 1.5s 的本地接收期限 → 6 次请求 **6 次 expired**，副官一条命令都发不出去
    （模型其实只用 250ms 就回了）。异步调度的意义就是"返回即用"，所以收取必须发生在
    每一轮流水线上，与"何时请求下一次"解耦。
    """
    scheduler = getattr(ctx.services, "tactics_scheduler", None)
    if scheduler is None:
        return False
    # 先重置再收取：patch_ready 是**同 tick 交接键**。LangGraph 通道是"最后值持久"
    # 语义（节点 pop 只删本地键，通道旧值留存到下一 tick），不重置会把上一次的
    # 结果当新结果反复应用（实测 63s 内 1 次提交却被"应用"33 次、新请求永不提交）。
    state["patch_ready"] = None
    outcome = scheduler.poll(current_generations=_live_generations(state),
                             current_tick=int(state.get("server_tick", 0) or 0))
    if outcome is None:
        return False
    if outcome.status == STATUS_OK:
        state["patch_ready"] = {
            "value": outcome.value, "decode": outcome.decode,
            "request_id": outcome.request_id, "latency_ms": outcome.latency_ms,
            "waited_ms": outcome.waited_ms, "merged": outcome.merged,
        }
        _decide(state, "task_patch_result", status=outcome.status,
                request_id=outcome.request_id, latency_ms=outcome.latency_ms,
                waited_ms=outcome.waited_ms, merged=outcome.merged)
        _log(ctx, state, "task_patch_result", **outcome.to_dict())
        return True
    if outcome.status == STATUS_ERROR:
        # 失败 → 记降级与退避（保守降级由战术节点决定，这里只标记）。
        _on_model_failure(state, ctx, "tactics", ModelTimeout(outcome.reason))
    _decide(state, "task_patch_result_rejected", status=outcome.status,
            reason=outcome.reason, request_id=outcome.request_id)
    _log(ctx, state, "task_patch_result", **outcome.to_dict())
    return False


def node_classify(state: Dict[str, Any], ctx: NodeContext) -> Dict[str, Any]:
    """事件分类与路由（player_override_gate 分支决策）。"""
    events = list(state.get("pending_events", []))
    patch_ready = _intake_patch_outcome(state, ctx)
    route = itr.classify_route(_StateView(state), events, int(state.get("server_tick", 0)),
                               _config_dict(ctx.config))
    if patch_ready and route in (itr.ROUTE_WAIT, itr.ROUTE_STRATEGIC):
        # 已有可用决策结果：本轮直接走战术节点把任务落地（进度不因等待路由节拍而丢）。
        route = itr.ROUTE_TACTICAL
    state["route"] = route
    _decide(state, "event_classified", route=route, event_kinds=[
        str(e.get("kind", "")) for e in events])
    _log(ctx, state, "graph_route", route=route, event_count=len(events))
    # 【微操与模型解耦】非战术轮也要跑微操（见 `_run_micro_layer` 的实测依据）。
    # 战术轮由 `node_tactical_agent` 自带那段（它还要和本轮模型意图比优先级），
    # 所以这里只补**非战术轮**，避免同一轮跑两遍。
    if route not in (itr.ROUTE_TACTICAL, itr.ROUTE_EMERGENCY_TACTICAL):
        _run_micro_layer(state, ctx)
    return state


class _StateView:
    """dict 状态 → “状态对象协议”适配器（interrupts / arbitration 复用同一套逻辑）。

    只读属性走字段直读；方法（代际、租约、意图查找、决策留痕）在 dict 上实现，
    保证图节点与独立状态对象两条路径的判定语义完全一致。
    """

    def __init__(self, data: Dict[str, Any]) -> None:
        self._data = data

    def __getattr__(self, name: str) -> Any:
        data = object.__getattribute__(self, "_data")
        if name in data:
            return data[name]
        raise AttributeError(name)

    # ---- 方法（arbitration 使用） ----

    def generation_of(self, unit_id: str) -> int:
        return int(self._data.get("unit_generations", {}).get(str(unit_id), 0))

    def is_unit_player_controlled(self, unit_id: str) -> bool:
        return str(unit_id) in self._data.get("player_controlled_units", [])

    def find_intent(self, intent_id: str) -> Optional[Dict[str, Any]]:
        for intent in self._data.get("active_intents", []):
            if str(intent.get("intent_id", "")) == str(intent_id):
                return intent
        return None

    def live_intents(self, current_tick: int) -> List[Dict[str, Any]]:
        """与 `AdjutantGraphState.live_intents` 同口径（微操守卫/仲裁复用）。"""
        return [r for r in self._data.get("active_intents", [])
                if r.get("state") in INTENT_LIVE_STATES
                and int(r.get("expires_tick", 0)) >= int(current_tick)]

    def decide(self, kind: str, **payload: Any) -> Dict[str, Any]:
        return _decide(self._data, kind, **payload)


def _config_dict(config: GraphConfig) -> Dict[str, Any]:
    return {
        "strategy_interval_ticks": config.strategy_interval_ticks,
        "tactics_interval_ticks": config.tactics_interval_ticks,
        "emergency_min_interval_ticks": config.emergency_min_interval_ticks,
    }


# ---------------- 玩家打断 / 计划调整 ----------------

def node_reconcile_plan(state: Dict[str, Any], ctx: NodeContext) -> Dict[str, Any]:
    """玩家打断：撤销相关 lease、失效相关意图、任务标记局部接管；计划保留。"""
    events = list(state.get("pending_events", []))
    control_events = [e for e in events if itr.classify_event_kind(str(e.get("kind", ""))) == "control"]
    handled_records: List[Dict[str, Any]] = []
    tick = int(state.get("server_tick", 0))
    for event in control_events:
        kind = str(event.get("kind", ""))
        payload = event.get("payload") or {}
        units = _units_of_payload(payload)
        if not units:
            continue
        if bool(payload.get("already_applied", False)):
            # 宿主已在收到玩家输入的那一刻立即应用（代际/租约已更新），此处只留痕。
            handled_records.append({
                "kind": kind, "unit_ids": [str(u) for u in units],
                "server_tick": tick, "reason": "already_applied_by_host",
                "generation": int(state.get("control_generation", 0)),
                "dropped_intents": [],
            })
            continue
        if kind == itr.EVT_PLAYER_OVERRIDE:
            record = _apply_override(state, units, tick, str(payload.get("reason", "")))
        else:
            record = _apply_release(state, units, tick, str(payload.get("reason", "")))
        handled_records.append(record)
        if ctx.services.player_event_hook is not None:
            try:
                ctx.services.player_event_hook(record)
            except Exception:  # 兼容层异常不改变图内控制权结论。
                _log(ctx, state, "player_event_hook_failed", kind=kind)
    state["pending_events"] = [e for e in events if e not in control_events]
    state["paused"] = bool(ctx.config.pause_on_player_interrupt and handled_records)
    _decide(state, "plan_reconciled",
            handled=[{"kind": r["kind"], "units": r["unit_ids"]} for r in handled_records],
            plan_preserved=state.get("active_plan") is not None)
    _log(ctx, state, "graph_reconcile", handled=len(handled_records),
         player_units=state.get("player_controlled_units", []))
    return state


def _units_of_payload(payload: Dict[str, Any]) -> List[str]:
    raw = payload.get("subject", "")
    if isinstance(raw, str):
        return [item.strip() for item in raw.split(",") if item.strip()]
    if isinstance(raw, (list, tuple)):
        return [str(item) for item in raw if str(item)]
    return []


def _apply_override(state: Dict[str, Any], units: List[str], tick: int,
                    reason: str) -> Dict[str, Any]:
    gens = state.setdefault("unit_generations", {})
    counter = int(state.get("control_generation", 0))
    record = {"kind": "player_override", "unit_ids": [str(u) for u in units],
              "server_tick": tick, "reason": reason, "generation": 0,
              "dropped_intents": []}
    for unit_id in units:
        key = str(unit_id)
        counter += 1
        gens[key] = counter
        record["generation"] = counter
        if key in state.get("ai_controlled_units", []):
            state["ai_controlled_units"].remove(key)
        if key not in state.get("player_controlled_units", []):
            state["player_controlled_units"].append(key)
        if key in state.get("released_units", []):
            state["released_units"].remove(key)
        for intent in state.get("active_intents", []):
            if intent.get("state") not in ("active", "pending_authority"):
                continue
            if key in [str(u) for u in intent.get("unit_ids", [])]:
                intent["state"] = INTENT_DROPPED
                intent["drop_reason"] = "player_override"
                record["dropped_intents"].append(intent.get("intent_id"))
        state.get("pending_requests", {}).pop(key, None)
    state["control_generation"] = counter
    for intent_id in [item for item in list(state.get("pending_requests", {}).keys())
                      if set(state["pending_requests"][item].get("unit_ids", [])) & set(units)]:
        state["pending_requests"].pop(intent_id, None)
    _mark_tasks_for_units(state, units, "partially_overridden")
    state.setdefault("overrides", []).append(record)
    return record


def _apply_release(state: Dict[str, Any], units: List[str], tick: int,
                   reason: str) -> Dict[str, Any]:
    gens = state.setdefault("unit_generations", {})
    counter = int(state.get("control_generation", 0))
    record = {"kind": "player_release", "unit_ids": [str(u) for u in units],
              "server_tick": tick, "reason": reason, "generation": 0}
    for unit_id in units:
        key = str(unit_id)
        if key in state.get("player_controlled_units", []):
            state["player_controlled_units"].remove(key)
        counter += 1
        gens[key] = counter
        record["generation"] = counter
        if key not in state.get("released_units", []):
            state["released_units"].append(key)
        if key not in state.get("ai_controlled_units", []):
            state["ai_controlled_units"].append(key)
    state["control_generation"] = counter
    for task_id, value in list(state.get("active_tasks", {}).items()):
        if value in ("waiting_for_player", "partially_overridden"):
            state["active_tasks"][task_id] = TASK_RUNNING
    state.setdefault("overrides", []).append(record)
    return record


def _mark_tasks_for_units(state: Dict[str, Any], units: List[str], new_state: str) -> None:
    wanted = {str(u) for u in units}
    plan = state.get("active_plan") or {}
    tasks = plan.get("tasks") or []
    touched = False
    for task in tasks:
        task_units = {str(u) for u in (task.get("units") or [])}
        if task_units & wanted:
            task_id = str(task.get("task_id", ""))
            if task_id:
                state.setdefault("active_tasks", {})[task_id] = new_state
                touched = True
    if not touched and not tasks:
        for task_id, value in list(state.get("active_tasks", {}).items()):
            if value in (TASK_RUNNING, "pending", TASK_UNKNOWN):
                state["active_tasks"][task_id] = new_state


# ---------------- 战略 ----------------

def node_strategic_agent(state: Dict[str, Any], ctx: NodeContext) -> Dict[str, Any]:
    """战略节点：低频生成 StrategicPlan；不直接产生单位命令。"""
    events = list(state.get("pending_events", []))
    if _model_missing(ctx.services.strategy_model):
        _decide(state, "strategy_skipped", reason="no_strategy_model")
        # 立标志让 classify_route 跳过战略分支：active_plan 恒 None 时 is_strategy_due
        # 恒真，路由会卡死在 strategic，战术节点永远轮不到（实测 0 下发）。覆盖两类
        # 场景：--strategy-mode off，以及配置为 plan 但模型装配失败/从旧 checkpoint 恢复。
        state["strategy_disabled"] = True
        state["candidate_intents"] = []
        return state
    if not model_calls_allowed(state, ctx, "strategy"):
        _decide(state, "strategy_skipped", reason="model_cooldown")
        state["candidate_intents"] = []
        return state
    tick = int(state.get("server_tick", 0))
    context = build_strategy_context(
        _StateView(state), strategic=ctx.observation.get("strategic"),
        rules=ctx.observation.get("rules"), events=events,
        budget=ctx.observation.get("budget"),
    )
    ctx.services.log("strategy_request", status="issued",
                     match_id=state.get("match_id", ""), server_tick=tick)
    try:
        plan = ctx.services.strategy_model.propose_plan(context)
    except (ModelTimeout, ModelUnavailable, ModelInvalidOutput) as exc:
        _on_model_failure(state, ctx, "strategy", exc)
        state["candidate_intents"] = []
        return state
    except Exception as exc:  # noqa: BLE001 —— 未知异常也归入降级，不炸图。
        _on_model_failure(state, ctx, "strategy", exc)
        state["candidate_intents"] = []
        return state

    if plan is None:
        state["last_strategy_tick"] = tick
        state["model_errors"] = 0
        _consume_events(state, itr.STRATEGIC_EVENT_KINDS)
        _decide(state, "strategy_empty", tick=tick)
        state["candidate_intents"] = []
        return state
    try:
        parsed: StrategicPlan = parse_strategic_plan(plan)
    except ContractError as exc:
        _on_model_failure(state, ctx, "strategy", ModelInvalidOutput("; ".join(exc.errors)))
        state["candidate_intents"] = []
        return state
    if str(parsed.match_id) != str(state.get("match_id", "")) or \
            str(parsed.player_id) != str(state.get("player_id", "")):
        _on_model_failure(state, ctx, "strategy",
                          ModelInvalidOutput("计划身份与当前对局不一致"))
        state["candidate_intents"] = []
        return state

    plan_dict = parsed.to_plan_dict()
    accepted, reason = True, "adopted"
    if ctx.services.adoption is not None:
        accepted, reason = ctx.services.adoption(plan_dict, tick)
    if not accepted:
        # 旧计划输出不能覆盖已采纳计划：保留当前计划，记录拒绝原因。
        state["model_errors"] = int(state.get("model_errors", 0)) + 1
        state["degraded_reason"] = "plan_rejected:%s" % reason
        _decide(state, "plan_rejected", reason=reason, tick=tick)
        _log(ctx, state, "plan_adoption", status="rejected", reason=reason)
        state["candidate_intents"] = []
        return state

    previous_version = str(state.get("plan_version", "") or "")
    if previous_version and previous_version != "%s:v%d" % (parsed.plan_id, parsed.plan_version):
        # 记录被替换的历史版本：模型若回显历史版本号 = 真·旧计划意图，仲裁会丢弃。
        history = list(state.get("plan_version_history", []) or [])
        if previous_version not in history:
            history.append(previous_version)
        state["plan_version_history"] = history[-16:]
    state["active_plan"] = plan_dict
    state["plan_version"] = "%s:v%d" % (parsed.plan_id, parsed.plan_version)
    state["plan_adopt_generation"] = int(state.get("plan_adopt_generation", 0)) + 1
    for task in plan_dict["tasks"]:
        task_id = str(task.get("task_id", ""))
        if task_id and task_id not in state.get("active_tasks", {}):
            state.setdefault("active_tasks", {})[task_id] = "pending"
        units = [str(u) for u in (task.get("units") or [])]
        _ensure_units(state, units)
    state["last_strategy_tick"] = tick
    state["model_errors"] = 0
    state["degraded_reason"] = ""
    _consume_events(state, itr.STRATEGIC_EVENT_KINDS)
    # 计划调整后，玩家仍控制的单位保持玩家控制（新计划不能抢回）。
    for unit in list(state.get("player_controlled_units", [])):
        if unit in state.get("ai_controlled_units", []):
            state["ai_controlled_units"].remove(unit)
    _decide(state, "plan_adopted", plan_id=parsed.plan_id,
            plan_version=state["plan_version"], reason=reason, tick=tick)
    _log(ctx, state, "plan_adoption", status="adopted", plan_version=state["plan_version"])
    state["candidate_intents"] = []
    return state


def _ensure_units(state: Dict[str, Any], units: List[str]) -> None:
    gens = state.setdefault("unit_generations", {})
    for unit_id in units:
        key = str(unit_id)
        if key in gens or key in state.get("player_controlled_units", []):
            continue
        state["control_generation"] = int(state.get("control_generation", 0)) + 1
        gens[key] = state["control_generation"]
        if key not in state.get("ai_controlled_units", []):
            state["ai_controlled_units"].append(key)


# ---------------- 战术 ----------------

# ---------------- 重复命令抑制（2026-09-12 用户反馈"一直在重复命令"）----------------
# 实测数据（无 AI 5 分钟）：微操层每轮都跑，回执里 produce 238 / gather 321 / move 217，
# 状态 **LedgerFull 527** / StaleGeneration 217 / Accepted 仅 3。
# 链路：意图被拒 → 运行时把它丢掉 → 仲裁的去重表（只看"活跃意图"）随之变空 →
# 下一轮微操层又把同一条命令补一次 → 更拥塞。这是正反馈，必须用**与意图存活无关**的
# "最近下发指纹"来兜底：同一「单位集合 + 动作 + 目标」在一个窗口内只下发一次。
ORDER_REPEAT_WINDOW_TICKS = 900

#: 拥塞类拒绝后的静默窗口（不新发命令；既有任务继续执行，行为树自己循环）。
CONGESTION_BACKOFF_TICKS = 300
CONGESTION_STATUSES = ("LedgerFull", "Busy", "Throttled", "TransportError",
                       "Timeout", "QueueFull")


def _order_signature(item: Dict[str, Any]) -> str:
    """「单位集合 + 动作 + 目标」指纹（坐标取整到米：同一目标点的抖动不算变化）。"""
    units = ",".join(sorted(str(u) for u in (item.get("unit_ids") or [])))
    action = str(item.get("action", ""))
    target = dict(item.get("target") or {})
    key = str(target.get("entity_id") or target.get("resource")
              or target.get("scene") or "")
    if not key:
        pos = target.get("pos")
        if isinstance(pos, (list, tuple)) and len(pos) >= 2:
            try:
                key = "%.0f,%.0f" % (float(pos[0]), float(pos[1]))
            except (TypeError, ValueError):
                key = ""
    return "%s|%s|%s" % (units, action, key)


def _repeat_suppressed(state: Dict[str, Any], item: Dict[str, Any], tick: int) -> bool:
    """该意图是否在"最近下发窗口"内已经发过（发过就不该再发）。"""
    stamp = (state.get("recent_orders") or {}).get(_order_signature(item))
    if stamp is None:
        return False
    return int(tick) - int(stamp) < ORDER_REPEAT_WINDOW_TICKS


def _remember_order(state: Dict[str, Any], item: Dict[str, Any], tick: int) -> None:
    """记下已下发的指纹，并清理过期项（避免状态无限增长）。"""
    recent = state.setdefault("recent_orders", {})
    recent[_order_signature(item)] = int(tick)
    cutoff = int(tick) - ORDER_REPEAT_WINDOW_TICKS
    for key in [k for k, v in recent.items() if int(v) < cutoff]:
        recent.pop(key, None)


def _may_displace(action: str, from_ladder: bool,
                  conflicts: List[Dict[str, Any]]) -> bool:
    """微操意图能否顶掉**同单位**的既有（模型）意图。两条显式规则：

    1. **求生（retreat）永远可以打断** —— 这是行为树存在的理由之一：
       实测模型会拿 1 个兵硬冲 3 个敌人，微操必须能把它撤下来。
    2. **阶梯**的发展动作（build/produce/attack）可以顶掉模型下发的**低优先**动作
       （gather/scout/move/hold）。实测（"有兵无营"的最后一环，已由
       `tests/test_ladder_batch_integration.py` 钉住）：阶梯挑的建造者恰恰是模型
       每轮派去采集的那批工人（工人是低优先单位，阶梯正是靠这点腾人），
       若按"该单位已被本批占用 → 跳过"无条件去重，阶梯的 build **每条都会被丢掉**，
       整局只剩采集 —— 这是"并集判据饿死阶梯"换了个位置复发。

    行为树的**其余**自主动作不顶模型意图：模型意图优先是金标准
    （`replay_player_takeover.jsonl` 明确钉住"模型下发 move 必须被接受"），
    行为树只负责模型没管的单位（见 `behavior_tree.micro_parts` 文档）。

    胜负用 `action_rank`（跨产者抢占序）判，**不能**比各自的 `priority` 字段
    （两套产者量纲不同：阶梯 2~4 / 行为树 30~95）。平局与拿不准一律让既有意图胜出：
    不做无依据的打断。
    """
    if not conflicts:
        return True
    if not from_ladder and action != ACTION_RETREAT:
        return False
    rank = rules_fallback.action_rank(action)
    return all(rules_fallback.action_rank(c.get("action", "")) < rank
               for c in conflicts)


def _run_micro_layer(state: Dict[str, Any], ctx: NodeContext) -> None:
    """微操层独立跑一轮：发展阶梯 + 行为树 → 候选意图（**每轮都跑**）。

    ## 为什么必须独立出来（2026-09-11 实测，用户反馈"没看到副官批量指挥部队"）

    微操原先只挂在战术分支里（`route ∈ {tactical, emergency_tactical}`），而战术分支被
    "事件间隔 + 模型耗时"门控：5 分钟一局里战术分支只跑了 **2~5 次**（同局 `strategy_request`
    却有 18~28 次）→ 微操跟着被饿死：整局 0 生产、屏幕上几乎看不到任何批量指挥。
    用户方针本来就是"微操靠行为树、LLM 慢不要紧"，所以微操必须每轮都跑。

    ## 与 `node_tactical_agent` 里那段的语义差别（有意为之）

    - 战术轮**有**本轮模型意图：那里按"模型已产出的类别"过滤阶梯，并按 `_may_displace`
      与模型意图比优先级；
    - 这里**没有**本轮模型意图（战略轮/等待轮）：阶梯补它缺的全部类别、行为树补它负责的单位。
      重复下发由仲裁层的"单位级活跃判重"（`arbitration.live_unit_orders`）拦住 ——
      同一单位 + 同动作 + 同目标在活跃期内不会重发，所以每轮跑不会造成抖动。

    异常一律吞掉并留痕：微操失败绝不允许拖垮指挥链。
    """
    tick = int(state.get("server_tick", 0))
    candidates = list(state.get("candidate_intents") or [])
    try:
        ladder_extras, tree_extras = behavior_tree.micro_parts(
            state, tactical=ctx.observation.get("tactical"),
            rules=ctx.observation.get("rules"),
            ttl_ticks=int(ctx.config.intent_ttl_ticks), server_tick=tick,
            snapshot_id=int(state.get("latest_snapshot_id", 0) or 0))
    except Exception as exc:  # noqa: BLE001
        _log(ctx, state, "micro_error", error=repr(exc)[:200])
        return
    added: List[str] = []
    # 【活跃意图守卫】非战术轮的微操不得顶掉仍在执行中的任务（两处实测依据：
    # ① replay_base_attack tick6 —— 行为树 bt-attack 顶掉模型的 attack_move 回防；
    # ② 设计 §3「模型的新任务与已有规则不得形成两个互相抢控制权的指挥中心」）。
    # 行为树只负责**没有活跃任务**的单位；阶梯可顶更低优先的活跃动作（与
    # `_may_displace` 同一抢占序）；求生（retreat）永远放行。
    live_by_unit: Dict[str, Dict[str, Any]] = {}
    for live in _StateView(state).live_intents(tick):
        for unit_id in live.get("unit_ids") or []:
            live_by_unit.setdefault(str(unit_id), live)
    suppressed = 0
    for item, from_ladder in ([(it, True) for it in ladder_extras]
                              + [(it, False) for it in tree_extras]):
        # 与"最近下发窗口"比对（与意图存活无关）：同单位+同动作+同目标刚发过就不再发。
        # 只靠"活跃意图去重"不够——被拒/超时的意图会被丢掉，去重表随之变空 → 正反馈重发。
        if _repeat_suppressed(state, item, tick):
            suppressed += 1
            continue
        act = str(item.get("action", ""))
        units = {str(u) for u in (item.get("unit_ids") or [])}
        occupied = False
        for unit_id in units:
            live = live_by_unit.get(unit_id)
            if live is None:
                continue
            if act == ACTION_RETREAT:
                continue  # 求生永远可以打断
            if not from_ladder:
                occupied = True
                break
            if rules_fallback.action_rank(act) <= rules_fallback.action_rank(
                    str(live.get("action", ""))):
                occupied = True
                break
        if occupied:
            continue
        conflicts = [c for c in candidates
                     if units & {str(u) for u in (c.get("unit_ids") or [])}]
        if not _may_displace(act, from_ladder, conflicts):
            continue
        for conflict in conflicts:
            candidates.remove(conflict)
        candidates.append(item)
        added.append(str(item.get("intent_id", "")))
    if added:
        state["candidate_intents"] = candidates
        _decide(state, "micro_control_added", intents=added, tick=tick)
        _log(ctx, state, "micro_control", added=len(added), suppressed=suppressed,
             route=str(state.get("route", "")))


def _model_missing(model: Any) -> bool:
    """模型层是否不可用：`None`，或包装器里层为 `None`（runner 关掉某层时会这样包）。"""
    return model is None or getattr(model, "inner", model) is None


def _live_generations(state: Dict[str, Any]) -> Dict[str, int]:
    """当前权威逐对象代际（用于判定模型结果是否已被玩家/新指令超出）。"""
    out: Dict[str, int] = {}
    for key, value in (state.get("unit_generations") or {}).items():
        try:
            out[str(key)] = int(value or 0)
        except (TypeError, ValueError):
            continue
    return out


def _tactical_via_task_patch(state: Dict[str, Any], ctx: NodeContext,
                             events: List[Dict[str, Any]], tick: int,
                             emergency: bool) -> Dict[str, Any]:
    """四列接口路径：模型只做"任务修改"，程序展开并复用既有权威链。

    与旧路径的关键差别（设计 §2.2/§7.2、§8.8）：
    - `StrategicPlan` **不再**是下令前置：任务由模型选中的模板展开，身份/版本由程序给；
    - 模型正常时，程序**不**补任何它没选的战略任务（旧"发展阶梯"退到只在降级路径使用），
      避免出现"两个互相抢控制权的指挥中心"；
    - 逐行解码结果（接受/拒绝原因）落进结构化日志，供逐项回执与验收核对。
    """
    mode = str(getattr(ctx.services.tactics_model, "mode", MODE_FAST) or MODE_FAST)
    scheduler = getattr(ctx.services, "tactics_scheduler", None)
    fallback_used = ""
    batch = None
    decode = None
    if scheduler is not None:
        # ---- 有界异步路径（默认）----
        # 结果由 `node_classify` 每轮即时收取（`patch_ready`），这里只负责落地或提交新请求。
        ready = state.pop("patch_ready", None)
        # 显式清空通道：pop 只删本地键，LangGraph 通道旧值会留存（见 _intake_patch_outcome）。
        state["patch_ready"] = None
        if ready is not None:
            batch, decode = ready.get("value"), ready.get("decode")
            _log(ctx, state, "task_patch_applied", request_id=ready.get("request_id"),
                 latency_ms=ready.get("latency_ms"), waited_ms=ready.get("waited_ms"),
                 merged=ready.get("merged"))
            _decide(state, "task_patch_applied", request_id=ready.get("request_id"),
                    latency_ms=ready.get("latency_ms"), tick=tick)
        else:
            frame = task_patch_bridge.frame_from_state(state, ctx.observation, mode=mode)
            accepted, why = scheduler.submit(
                frame,
                kind=KIND_EMERGENCY if emergency else KIND_NORMAL,
                live_generations=frame.generations)
            _log(ctx, state, "task_patch_submitted", accepted=accepted, reason=why,
                 mode=mode, actors=len(frame.actors), emergency=emergency,
                 **scheduler.stats())
            # 同时写进状态决策日志：面板与验收都从这里读（结构化日志只落 runner jsonl）。
            _decide(state, "task_patch_submitted", accepted=accepted, reason=why,
                    tick=tick, emergency=emergency)
            # 没有新结果：**相关单位继续执行既有任务**（不清空活跃任务，不推断状态）。
            state["candidate_intents"] = []
            state["last_tactics_tick"] = tick
            _consume_events(state)
            return state
    else:
        # ---- 同步路径（legacy 回退 / 无调度器时）----
        frame = task_patch_bridge.frame_from_state(state, ctx.observation, mode=mode)
        ctx.services.log("tactics_request", status="issued", interface="task_patch",
                         match_id=state.get("match_id", ""), server_tick=tick,
                         emergency=emergency, mode=mode, actors=len(frame.actors))
        try:
            batch = ctx.services.tactics_model.propose_task_patch(frame)
        except (ModelTimeout, ModelUnavailable, ModelInvalidOutput) as exc:
            _on_model_failure(state, ctx, "tactics", exc)
            fallback_used = "rules_fallback"
        except Exception as exc:  # noqa: BLE001 —— 未知异常同样降级，不阻塞指挥链
            _on_model_failure(state, ctx, "tactics", exc)
            fallback_used = "rules_fallback"
        decode = getattr(ctx.services.tactics_model, "last_decode", None)
    # 审计：把"模型原始输出"一起落盘。此前只落解码摘要，而异步路径的 decode 恒为 None
    # （调度器只带 IntentBatch），于是日志打出误导性的 rows=0/0/0，谁也看不出"模型回了空"。
    _log(ctx, state, "task_patch", mode=mode, fallback=fallback_used,
         raw=str(getattr(ctx.services.tactics_model, "last_raw_text", "") or "")[:400],
         **task_patch_bridge.summarize_decode(decode))
    if batch is None and not fallback_used:
        _decide(state, "tactics_empty", tick=tick)
        fallback_used = "rules_fallback_empty"
    if fallback_used:
        # 只有降级时才用确定性兜底（保守降级，明确标记，供验收区分模型/规则）。
        batch = _rules_fallback_batch(state, ctx)
    try:
        parsed: IntentBatch = parse_intent_batch(batch)
    except ContractError as exc:
        _on_model_failure(state, ctx, "tactics", ModelInvalidOutput("; ".join(exc.errors)))
        state["candidate_intents"] = []
        return state
    if (parsed.match_id and str(parsed.match_id) != str(state.get("match_id", ""))) or \
            (parsed.player_id and str(parsed.player_id) != str(state.get("player_id", ""))):
        _on_model_failure(state, ctx, "tactics",
                          ModelInvalidOutput("意图批次身份与当前对局不一致"))
        state["candidate_intents"] = []
        return state
    parsed.match_id = str(state.get("match_id", ""))
    parsed.player_id = str(state.get("player_id", ""))
    parsed.plan_version = parsed.plan_version or str(state.get("plan_version", ""))
    candidates: List[Dict[str, Any]] = []
    for intent in parsed.intents:
        item = intent.to_dict()
        # 模型可能复述"我上次发过的任务"（它没有记忆）：与最近下发窗口比对拦下来。
        # 这是 `unchanged`（与当前任务相同）之外的第二道闸：即使任务因拥塞被拒、
        # 运行时没留下"当前任务"，重复命令也不会再发出去。
        if _repeat_suppressed(state, item, tick):
            _decide(state, "intent_repeat_suppressed",
                    intent_id=str(item.get("intent_id", "")),
                    action=str(item.get("action", "")), tick=tick)
            continue
        candidates.append(item)
    if fallback_used:
        # 降级路径：用发展阶梯/行为树的骨架补明显缺口（模型没产出时的保命手段）。
        try:
            ladder_extras, tree_extras = behavior_tree.micro_parts(
                state, tactical=ctx.observation.get("tactical"),
                rules=ctx.observation.get("rules"),
                ttl_ticks=int(ctx.config.intent_ttl_ticks), server_tick=tick,
                snapshot_id=int(state.get("latest_snapshot_id", 0) or 0))
        except Exception as exc:  # noqa: BLE001
            ladder_extras, tree_extras = [], []
            _log(ctx, state, "micro_error", error=repr(exc)[:200])
        added: List[str] = []
        for item, from_ladder in ([(it, True) for it in ladder_extras]
                                  + [(it, False) for it in tree_extras]):
            units = {str(u) for u in (item.get("unit_ids") or [])}
            conflicts = [c for c in candidates
                         if units & {str(u) for u in (c.get("unit_ids") or [])}]
            if not _may_displace(str(item.get("action", "")), from_ladder, conflicts):
                continue
            for conflict in conflicts:
                candidates.remove(conflict)
            candidates.append(item)
            added.append(str(item.get("intent_id", "")))
        if added:
            _decide(state, "behavior_tree_added", intents=added, degraded=True)
    else:
        # 【结果层缺口修正 2026-09-12】**模型成功时也必须补骨架**。
        #
        # 用户提的问题是从结果反推的："过去半分钟了副官还没发展，只让工人采矿，不反常吗？"
        # 证据：`runner.out` 里**一条 `micro_ladder` 打点都没有** → 说明"按类别补骨架"
        # 的那段代码在四列路径下**从未执行过**（它只挂在降级分支）。后果就是：
        # 2B 每轮"成功返回"一条采集（它确实成功了），程序就不再补任何发展动作 →
        # 有钱、有闲工人、缺关键建筑，整局零发展。
        #
        # 语义与旧路径保持一致（逐类别判断 + 优先级抢占 + 不抢模型已批准任务的单位），
        # 但对骨架动作打 `origin=skeleton`，验收时可把"模型决策"与"程序骨架"分开统计。
        # 边界：只补**事实可判定**的骨架（缺什么/谁能造/买得起），不做目标推理、不换兵种、
        # 不改全局战略；预留由下游 `reserves.apply_budget` 统一拦。
        missing = set(rules_fallback.DEVELOPMENT_ACTIONS) - {
            str(item.get("action", "")) for item in candidates}
        if missing:
            try:
                ladder_extras, tree_extras = behavior_tree.micro_parts(
                    state, tactical=ctx.observation.get("tactical"),
                    rules=ctx.observation.get("rules"),
                    ttl_ticks=int(ctx.config.intent_ttl_ticks), server_tick=tick,
                    snapshot_id=int(state.get("latest_snapshot_id", 0) or 0))
            except Exception as exc:  # noqa: BLE001
                ladder_extras, tree_extras = [], []
                _log(ctx, state, "micro_error", error=repr(exc)[:200])
            # 诊断打点：把"喂给阶梯的输入"与"它产出什么"一起落盘 ——
            # 没有这行，就只能对着"为什么不发展"反复猜（本次就是这么绕出来的）。
            try:
                ladder_diag = rules_fallback.ladder_inputs(
                    state, tactical=ctx.observation.get("tactical"),
                    rules=ctx.observation.get("rules"))
            except Exception as exc:  # noqa: BLE001
                ladder_diag = {"error": str(exc)[:200]}
            _log(ctx, state, "micro_ladder", interface="task_patch",
                 missing=sorted(missing),
                 produced=[str(i.get("action", ""))
                           for i in (list(ladder_extras) + list(tree_extras))],
                 **ladder_diag)
            added = []
            for item, from_ladder in ([(it, True) for it in ladder_extras]
                                      + [(it, False) for it in tree_extras]):
                act = str(item.get("action", ""))
                if act in rules_fallback.DEVELOPMENT_ACTIONS and act not in missing:
                    continue
                units = {str(u) for u in (item.get("unit_ids") or [])}
                conflicts = [c for c in candidates
                             if units & {str(u) for u in (c.get("unit_ids") or [])}]
                if not _may_displace(act, from_ladder, conflicts):
                    continue
                for conflict in conflicts:
                    candidates.remove(conflict)
                item = dict(item)
                item["origin"] = "skeleton"
                candidates.append(item)
                added.append(str(item.get("intent_id", "")))
            if added:
                _decide(state, "development_skeleton_added", intents=added,
                        missing=sorted(missing))
    state["candidate_intents"] = candidates
    state["candidate_intents"] = candidates
    state["last_tactics_tick"] = tick
    _consume_events(state)
    if not fallback_used:
        state["model_errors"] = 0
        state["degraded_reason"] = ""
    _decide(state, "tactics_proposed", interface="task_patch",
            intent_ids=[intent.intent_id for intent in parsed.intents],
            emergency=emergency)
    if fallback_used:
        _decide(state, "tactics_rules_fallback_used", reason=fallback_used,
                intents=len(parsed.intents))
    return state


def node_tactical_agent(state: Dict[str, Any], ctx: NodeContext) -> Dict[str, Any]:
    """战术节点：事件驱动生成有限期意图（只写候选，不下发）。"""
    events = list(state.get("pending_events", []))
    tick = int(state.get("server_tick", 0))
    emergency = itr.has_emergency_event(events)
    if emergency:
        preempted = _preempt_for_emergency(state, events, tick)
        if preempted:
            _log(ctx, state, "emergency_preempted", intents=preempted)
    if _model_missing(ctx.services.tactics_model):
        _decide(state, "tactics_skipped", reason="no_tactics_model")
        state["candidate_intents"] = []
        return state
    if not model_calls_allowed(state, ctx, "tactics"):
        _decide(state, "tactics_skipped", reason="model_cooldown")
        state["candidate_intents"] = []
        return state
    # 决策接口选择（设计 §2「合并为一个模型决策入口」）：
    # agent 暴露 `propose_task_patch` 即走四列接口（默认）；旧 DirectiveBatch 路径保留，
    # 供 A/B 对照与显式回退（runner `--interface legacy`）。
    if hasattr(ctx.services.tactics_model, "propose_task_patch"):
        return _tactical_via_task_patch(state, ctx, events, tick, emergency)
    context = build_tactics_context(
        _StateView(state), tactical=ctx.observation.get("tactical"),
        rules=ctx.observation.get("rules"), events=events,
        strategic=ctx.observation.get("strategic"),
        # 把真实 TTL 窗口写进提示词：真实模型据此填 expires_tick。
        config={"intent_ttl_ticks": int(ctx.config.intent_ttl_ticks),
                "emergency_ttl_ticks": int(ctx.config.emergency_intent_ttl_ticks)},
    )
    ctx.services.log("tactics_request", status="issued",
                     match_id=state.get("match_id", ""), server_tick=tick,
                     emergency=emergency)
    fallback_used = ""
    try:
        batch = ctx.services.tactics_model.propose_intents(context)
    except (ModelTimeout, ModelUnavailable, ModelInvalidOutput) as exc:
        _on_model_failure(state, ctx, "tactics", exc)
        # 模型不可用不能让部队空转：改用确定性兜底（工人采集 + 基地补工人）。
        # 兜底只做事实可判定的事，目标推理仍归模型（见 rules_fallback 模块说明）。
        batch = _rules_fallback_batch(state, ctx)
        fallback_used = "rules_fallback"
    except Exception as exc:  # noqa: BLE001
        _on_model_failure(state, ctx, "tactics", exc)
        batch = _rules_fallback_batch(state, ctx)
        fallback_used = "rules_fallback"

    if batch is None:
        # 模型给了空响应（非致命）：同样不能让部队空转，改走确定性兜底，
        # 并继续走下面的回声补齐 / 契约校验 / 仲裁流程。
        _decide(state, "tactics_empty", tick=tick)
        batch = _rules_fallback_batch(state, ctx)
        fallback_used = "rules_fallback_empty"
    # 模型可以省略/留空“回声字段”，由系统按上下文补齐；给出非空值时仍必须一致（下方校验）。
    batch = _fill_batch_echo(batch, state, ctx.config.intent_ttl_ticks)
    try:
        parsed: IntentBatch = parse_intent_batch(batch)
    except ContractError as exc:
        _on_model_failure(state, ctx, "tactics", ModelInvalidOutput("; ".join(exc.errors)))
        state["candidate_intents"] = []
        return state
    if (parsed.match_id and str(parsed.match_id) != str(state.get("match_id", ""))) or \
            (parsed.player_id and str(parsed.player_id) != str(state.get("player_id", ""))):
        # 意图批次身份与当前对局不一致：拒绝（绝不把意图下进别的对局）。
        _on_model_failure(state, ctx, "tactics",
                          ModelInvalidOutput("意图批次身份与当前对局不一致"))
        state["candidate_intents"] = []
        return state
    parsed.match_id = str(state.get("match_id", ""))
    parsed.player_id = str(state.get("player_id", ""))
    parsed.plan_version = parsed.plan_version or str(state.get("plan_version", ""))
    candidates = [intent.to_dict() for intent in parsed.intents]
    # 发展阶梯（决策手册 BLD-01）：模型这一批若**不含任何发展动作**
    # （build / produce / attack），而事实是"缺建筑 / 有闲产能 / 已可出击"，
    # 则由确定性阶梯补上骨架。
    # 为什么必须在这里补（实测）：worker 全被派去采集后，2B 模型每轮只回 gather，
    # 整局不造建筑、不出兵、不打仗；而 rules_fallback 只在**模型失败**时触发，
    # 模型"成功但只回 gather"时兜底根本不会被调用。
    # 边界：只补事实可判定的骨架，目标推理仍归模型；费用与预留由下游
    # reserves.apply_budget 统一拦；玩家接管单位不在 ai_units 里，天然不会出现。
    # 注意：**两条路径都要补**。实测最常见的是"模型超时 → 走兜底"，
    # 而兜底 `batch_from_rules` 按设计只做采集/补工人；若只挂在"模型成功"分支，
    # 阶梯在最需要它的场景下根本不会触发（第一次闭环验证就是这么失败的）。
    actions = {str(item.action) for item in parsed.intents}
    # 【关键修正 2026-09-11】按**类别**补齐，不能用并集判据。
    # 旧写法 `if not actions & set(DEVELOPMENT_ACTIONS)` 是并集判断：
    # 只要这批出现了 build/produce/attack 中**任意一个**，整条阶梯就被跳过。
    # 后果（实测）：模型一旦正常返回 `produce`（造兵），**建造阶梯就永远不触发** ——
    # 整局只有兵没有兵营。而上次能建出兵营，恰恰是因为当时模型在失败、走的是兜底路径。
    # 也就是说：**模型修好反而把建造饿死了**。改成逐类别判断后，
    # 模型产它的兵，阶梯同时补它缺的建筑，二者互不阻塞。
    missing = set(rules_fallback.DEVELOPMENT_ACTIONS) - actions
    if missing:
        # 阶梯与行为树**分开取**：两段的合并语义不同（见 behavior_tree.micro_parts）。
        ladder_extras, tree_extras = behavior_tree.micro_parts(
            state, tactical=ctx.observation.get("tactical"),
            rules=ctx.observation.get("rules"),
            ttl_ticks=int(ctx.config.intent_ttl_ticks), server_tick=tick,
            snapshot_id=int(state.get("latest_snapshot_id", 0) or 0),
        )
        extras = list(ladder_extras) + list(tree_extras)
        # 诊断打点（**每轮都打，不是只在空产出时打**）：
        # 交接时的血泪教训是"阶梯离线能产出 barracks build，运行时却一条 build
        # 都到不了游戏"，断点在**喂给阶梯的 state**，不在算法。
        # 只有把输入与产出一起落盘，才能用日志判定是
        #   (a) 压根没生成（输入不对，如 idle_builders 为空）
        #   (b) 生成了但被仲裁丢弃 / 已过期（见同 tick 的 intent_arbitration）
        # 而不是继续猜（此前已经因为没打点绕了三圈）。
        # 注意用 try：打点失败绝不允许影响指挥链（`_log` 的 sink 会吞异常，
        # 但计算输入本身也可能抛）。
        try:
            ladder_diag = rules_fallback.ladder_inputs(
                state, tactical=ctx.observation.get("tactical"),
                rules=ctx.observation.get("rules"))
        except Exception as exc:  # noqa: BLE001
            ladder_diag = {"error": str(exc)[:200]}
        _log(ctx, state, "micro_ladder", missing=sorted(missing),
             produced=[str(item.get("action", "")) for item in (extras or [])],
             **ladder_diag)
        if extras:
            added: List[str] = []
            for item, from_ladder in ([(it, True) for it in ladder_extras]
                                      + [(it, False) for it in tree_extras]):
                act = str(item.get("action", ""))
                # 模型已经产出的类别不再重复补，避免两套决策打架。
                if act in rules_fallback.DEVELOPMENT_ACTIONS and act not in missing:
                    continue
                units = {str(u) for u in (item.get("unit_ids") or [])}
                conflicts = [c for c in candidates
                             if units & {str(u) for u in (c.get("unit_ids") or [])}]
                # "一个单位同一批只出现一次"仍是结构性保证：这里要么**整组替换**，
                # 要么**整组放弃**，不会出现一个单位两条意图。
                if not _may_displace(act, from_ladder, conflicts):
                    continue
                for conflict in conflicts:
                    candidates.remove(conflict)
                candidates.append(item)
                added.append(str(item.get("intent_id", "")))
            if added:
                _decide(state, "behavior_tree_added", intents=added,
                        missing=sorted(missing))
    state["candidate_intents"] = candidates
    state["last_tactics_tick"] = tick
    _consume_events(state)
    if not fallback_used:
        state["model_errors"] = 0
        state["degraded_reason"] = ""
    # 兜底时**保留** degraded_reason 与 model_errors：这批意图是规则产出而非模型决策，
    # 抹掉标记会让诊断与验收分不清"模型恢复"和"兜底顶上"，也会让冷却重试失效。
    _decide(state, "tactics_proposed", intent_ids=[
        intent.intent_id for intent in parsed.intents], emergency=emergency)
    if fallback_used:
        # 明确留痕：这一批是规则兜底产出的，不是模型决策（验收时可据此区分）。
        _decide(state, "tactics_rules_fallback_used", reason=fallback_used,
                intents=len(parsed.intents))
    return state


def _preempt_for_emergency(state: Dict[str, Any], events: List[Dict[str, Any]],
                           tick: int) -> List[str]:
    units = itr.event_units(events, itr.EMERGENCY_EVENT_KINDS)
    preempted: List[str] = []
    for intent in state.get("active_intents", []):
        if intent.get("state") not in ("active", "pending_authority"):
            continue
        if intent.get("emergency"):
            continue
        if not (set(str(u) for u in intent.get("unit_ids", [])) & units):
            continue
        intent["state"] = INTENT_DROPPED
        intent["drop_reason"] = "preempted_by_emergency"
        preempted.append(str(intent.get("intent_id", "")))
        task_id = str(intent.get("task_id", ""))
        if task_id and state.get("active_tasks", {}).get(task_id) in ("running", "pending", "unknown"):
            state["active_tasks"][task_id] = "reassigned"
    return preempted


# ---------------- 仲裁 / 下发 / 回执 / 持久化 ----------------

def node_arbitrate_intent(state: Dict[str, Any], ctx: NodeContext) -> Dict[str, Any]:
    """意图仲裁：校验、去重、TTL 夹紧、批大小截断，并把结果写入状态。"""
    tick = int(state.get("server_tick", 0))
    candidates = list(state.get("candidate_intents") or [])
    state["candidate_intents"] = []
    if not candidates:
        return state
    tactical = ctx.observation.get("tactical")
    rules = ctx.observation.get("rules")
    entities = known_entity_ids(tactical)
    scenes = rules_scene_paths(rules)
    # 提示词允许模型用产品/建造 id 填 target.scene，而权威层只认场景路径。
    # 在仲裁前把 id 归一化为路径：合法的照常通过，非法引用仍会被 scene_not_in_rules 拒。
    scene_index = rules_scene_index(rules)
    for candidate in candidates:
        target = candidate.get("target")
        if isinstance(target, dict):
            scene = target.get("scene")
            if isinstance(scene, str) and scene in scene_index:
                target["scene"] = scene_index[scene]
    allowed = own_unit_ids(tactical) or entities
    emergency = itr.has_emergency_event(state.get("pending_events", []))
    ttl = ctx.config.emergency_intent_ttl_ticks if emergency else ctx.config.intent_ttl_ticks
    result = arbitrate_intents(
        _StateView(state), candidates, current_tick=tick, known_entities=entities,
        scene_paths=scenes, allowed_units=allowed, max_batch=ctx.config.max_batch,
        intent_ttl_ticks=ttl,
        expected_plan_version=str(state.get("plan_version", "")),
    )
    # 玩家资源预留（方案 §6）：权威端在**采纳前**检查余额、预留与已承诺成本。
    # 预留是玩家设定（首次开启时为余额的 20%，之后玩家可改），不是模型 plan.reserves。
    # 只拦"确有成本且超出可花费额度"的意图；规则里查不到成本时一律放行（不猜数值、不误杀）。
    kept, over_budget = reserves_mod.apply_budget(
        state, result.accepted, rules=rules, observation=ctx.observation,
        live_states=INTENT_LIVE_STATES,
        percent=int(getattr(ctx.config, "reserve_percent",
                            reserves_mod.DEFAULT_RESERVE_PERCENT)))
    if over_budget:
        result.accepted = kept
        result.dropped.extend(over_budget)
        _decide(state, "reserve_blocked",
                blocked=[item["intent_id"] for item in over_budget],
                reserves=dict(state.get("reserves") or {}))
    for intent in result.accepted:
        intent["state"] = "active"
        intent["drop_reason"] = ""
        intent["attempts"] = 0
        intent["command_id"] = ""
        state.setdefault("active_intents", []).append(intent)
        _ensure_units(state, [str(u) for u in intent.get("unit_ids", [])])
        if intent.get("reacquire"):
            # 归还授权是一次性的：被这次重新接管消费掉。
            for unit_id in intent.get("unit_ids", []):
                key = str(unit_id)
                if key in state.get("released_units", []):
                    state["released_units"].remove(key)
    dispatched: List[Dict[str, Any]] = []
    for item in result.dropped:
        _decide(state, "intent_dropped", intent_id=item.get("intent_id"),
                reason=item.get("reason"), errors=item.get("errors"))
        dispatched.append({"intent_id": item.get("intent_id"), "reason": item.get("reason")})
    state["intent_arbitration"] = {
        "accepted": [item["intent_id"] for item in result.accepted],
        "dropped": dispatched,
        "clamped": [item["intent_id"] for item in result.clamped],
    }
    state["dispatch_pending"] = [intent["intent_id"] for intent in result.accepted]
    _log(ctx, state, "intent_arbitration", **state["intent_arbitration"])
    return state


def node_dispatch_to_godot(state: Dict[str, Any], ctx: NodeContext) -> Dict[str, Any]:
    """下发节点：把本轮采纳的意图转成命令包，经权威通道逐条提交。"""
    pending_ids = list(state.get("dispatch_pending") or [])
    state["dispatch_pending"] = []
    if not pending_ids:
        return state
    if state.get("degraded_reason") == "identity_drift":
        _decide(state, "dispatch_skipped", reason="identity_drift", intent_ids=pending_ids)
        return state
    if ctx.services.dispatch is None:
        _decide(state, "dispatch_skipped", reason="no_transport", intent_ids=pending_ids)
        return state
    # 拥塞闸门：权威端登记表满（LedgerFull）时不新发命令——继续发只会把登记表越灌越满，
    # 而每条都被拒 → 单位"没被占用" → 微操层下一轮重发（正反馈）。
    # 【2026-09-12 实测】同局 `LedgerFull` 273/275 条、0 接受，就是因为没有这道闸门。
    congestion_until = int(state.get("congestion_until_tick", 0) or 0)
    if int(state.get("server_tick", 0)) < congestion_until:
        _decide(state, "dispatch_skipped", reason="congestion_backoff",
                until_tick=congestion_until, intent_ids=pending_ids)
        _log(ctx, state, "dispatch_congestion_skip", until_tick=congestion_until,
             pending=len(pending_ids))
        return state

    envelopes: List[Dict[str, Any]] = []
    intents_by_id: Dict[str, Dict[str, Any]] = {}
    for intent_id in pending_ids:
        record = _find_intent(state, intent_id)
        if record is None:
            continue
        attempt = int(record.get("attempts", 0)) + 1
        intents_by_id[intent_id] = record
        envelopes.append(intent_to_command_envelope(
            _IntentProxy(record), match_id=str(state.get("match_id", "")),
            player_id=str(state.get("player_id", "")),
            rules_version=str(state.get("rules_version", "")),
            command_id="%s:%s:%d" % (state.get("match_id", ""), intent_id, attempt),
            request_id="graph-%s-%s-%d" % (state.get("match_id", ""), intent_id, attempt),
            attempt=attempt,
        ))
    if not envelopes:
        return state
    try:
        receipts = ctx.services.dispatch(envelopes)
    except Exception as exc:  # noqa: BLE001 —— 通道异常：写降级，不阻塞图。
        state["degraded_reason"] = "transport_error:%s" % exc
        _decide(state, "dispatch_failed", reason=str(exc), intent_ids=pending_ids)
        _log(ctx, state, "dispatch_failed", reason=str(exc))
        return state
    for envelope, receipt in zip(envelopes, receipts):
        intent_id = str(envelope["intent_id"])
        record = intents_by_id.get(intent_id)
        if record is not None:
            record["attempts"] = int(record.get("attempts", 0)) + 1
            record["command_id"] = str(receipt.get("command_id", envelope["command_id"]))
        state.setdefault("command_receipts", []).append(dict(receipt))
        if record is not None:
            # 记下"已下发指纹"：微操层下一轮再想发同一条会被窗口挡住（治重复命令）。
            _remember_order(state, record, int(state.get("server_tick", 0)))
        _apply_receipt_to_state(state, intent_id, receipt)
    _decide(state, "dispatch_done", receipts=[
        {"intent_id": str(e["intent_id"]), "status": str(r.get("status", ""))}
        for e, r in zip(envelopes, receipts)])
    return state


class _IntentProxy:
    """把状态里的意图 dict 包成契约对象所需的属性访问形式。"""

    def __init__(self, record: Dict[str, Any]) -> None:
        self._record = record
        for key in ("intent_id", "plan_version", "task_id", "action", "rationale"):
            setattr(self, key, str(record.get(key, "")))
        self.unit_ids = [str(u) for u in record.get("unit_ids", [])]
        self.target = dict(record.get("target") or {})
        self.priority = int(record.get("priority", 0))
        self.based_on_snapshot = int(record.get("based_on_snapshot", 0))
        self.issued_tick = int(record.get("issued_tick", 0))
        self.expires_tick = int(record.get("expires_tick", 0))
        self.generation = int(record.get("generation", 0))
        self.abort_when = [str(item) for item in record.get("abort_when", [])]
        self.emergency = bool(record.get("emergency", False))
        # 显式重新接管申请必须原样带到命令包（否则权威层按“玩家接管”拒绝）。
        self.reacquire = bool(record.get("reacquire", False))


def _find_intent(state: Dict[str, Any], intent_id: str) -> Optional[Dict[str, Any]]:
    for intent in state.get("active_intents", []):
        if str(intent.get("intent_id", "")) == str(intent_id):
            return intent
    return None


def _apply_receipt_to_state(state: Dict[str, Any], intent_id: str,
                            receipt: Dict[str, Any]) -> None:
    record = _find_intent(state, intent_id)
    if record is None:
        return
    status = str(receipt.get("status", ""))
    accepted = bool(receipt.get("accepted", False))
    state.setdefault("command_receipts", [])
    if status == "PendingAuthority":
        record["state"] = "pending_authority"
        record["drop_reason"] = ""
        state.setdefault("pending_requests", {})[intent_id] = {
            "intent_id": intent_id,
            "command_id": str(receipt.get("command_id", "")),
            "state": "pending_authority",
            "since_tick": int(state.get("server_tick", 0)),
            "task_id": str(record.get("task_id", "")),
            "action": str(record.get("action", "")),
            "unit_ids": [str(u) for u in record.get("unit_ids", [])],
        }
        return
    state.get("pending_requests", {}).pop(intent_id, None)
    # 【三级时间戳 · 接收】(2026-09-12，按 GPT 顺序第 3 条)
    # `generated` 用意图自带的 `issued_tick`（程序在生成时就写了）；
    # 这里补 `received`（权威端回执到达）；`effective` 由观测证据在 progress 里补。
    # 三者齐全，"命令不生效 / 生效慢"才能被证明而不是靠感觉。
    tick_now = int(state.get("server_tick", 0))
    if not record.get("received_tick"):
        record["received_tick"] = tick_now
        record["received_ts"] = time.time()
        _log(ctx, state, "command_timing", intent_id=intent_id,
             generated_tick=int(record.get("issued_tick", 0) or 0),
             received_tick=tick_now, action=str(record.get("action", "")),
             status=str(status))
    if accepted:
        # 建造成功 → 清空连续失败计数（退避只针对"连续被拒"）。
        if str(record.get("action", "")) == "build":
            state["build_reject_streak"] = 0
        record["state"] = "active" if status == "Accepted" else (
            "completed" if status == "Completed" else record.get("state", "active"))
        task_id = str(record.get("task_id", ""))
        if task_id and state.get("active_tasks", {}).get(task_id) in ("pending", "unknown"):
            state["active_tasks"][task_id] = TASK_RUNNING
        if status == "Completed" and task_id:
            state["active_tasks"][task_id] = "completed"
        return
    # 拥塞类拒绝（LedgerFull/Busy/TransportError…）：**不是任务失败，是"稍后重试"**。
    # 实测（2026-09-12）：一旦拥塞，若把意图丢掉，仲裁的去重表就空了 → 下一轮重复下发同一条
    # 命令 → 拥塞更重（LedgerFull 527 / Accepted 仅 3）。保留意图 + 退避才能自愈。
    if status in CONGESTION_STATUSES:
        record["state"] = "retry_wait"
        record["drop_reason"] = ""
        retry_at = int(state.get("server_tick", 0)) + CONGESTION_BACKOFF_TICKS
        record["retry_after_tick"] = retry_at
        state["congestion_until_tick"] = max(int(state.get("congestion_until_tick", 0)),
                                            retry_at)
        state["congestion_events"] = int(state.get("congestion_events", 0)) + 1
        return
    # 拒绝：按原因归类（玩家优先权 → 不再抢回；进程代际过期 → 丢弃）。
    record["drop_reason"] = "receipt_%s" % status
    if status == "PlayerOverride":
        state.setdefault("overrides", []).append({
            "kind": "authority_player_override",
            "unit_ids": [str(u) for u in record.get("unit_ids", [])],
            "server_tick": int(state.get("server_tick", 0)),
            "reason": str(receipt.get("reason", "")),
        })
        _override_units_silently(state, [str(u) for u in record.get("unit_ids", [])])
        record["state"] = INTENT_DROPPED
    elif status in ("StaleGeneration", "Expired", "StalePlan"):
        record["state"] = INTENT_DROPPED if status == "StaleGeneration" else "expired"
    else:
        record["state"] = "failed"
    # 建造落点被拒 → **记住这个点，下一轮换位置**。
    # 依据：GPT 在 Q6 明确要求"不得用无限重试掩盖 Rejected/Occupied"；
    # 实测 2026-09-12 同一落点被连续拒 31 次（原因全 NotVisible），缺换点机制是直接原因之一。
    if str(record.get("action", "")) == "build":
        reason_text = "%s %s" % (status, receipt.get("reason", ""))
        if any(key in reason_text for key in ("NotVisible", "Occupied", "OutOfBounds",
                                              "SurfaceNotBuildable", "NotBuildable")):
            pos = (record.get("target") or {}).get("pos")
            if isinstance(pos, (list, tuple)) and len(pos) >= 2:
                blocked = state.setdefault("blocked_build_spots", [])
                point = [round(float(pos[0]), 1), round(float(pos[1]), 1)]
                if point not in blocked:
                    blocked.append(point)
                    del blocked[:-8]        # 有界：只记最近 8 个坏点
                _decide(state, "build_spot_blocked", pos=point, status=str(status),
                        reason=str(receipt.get("reason", ""))[:40])
            # **连续失败退避**：建造被连续拒绝 3 次后，停止尝试 15 秒（900 tick），
            # 只保留生产/采集等其它骨架（GPT Q6：不得用无限重试掩盖 Rejected）。
            # 实测 2026-09-12：同一类落点被连拒 58 次，纯噪音且占满权威账本。
            streak = int(state.get("build_reject_streak", 0)) + 1
            state["build_reject_streak"] = streak
            if streak >= 3:
                state["build_backoff_until_tick"] = int(state.get("server_tick", 0)) + 900
                state["build_reject_streak"] = 0
                _decide(state, "build_backoff", until_tick=state["build_backoff_until_tick"])
    task_id = str(record.get("task_id", ""))
    if task_id and state.get("active_tasks", {}).get(task_id) in ("running", "pending", "unknown"):
        state["active_tasks"][task_id] = TASK_UNKNOWN


def _override_units_silently(state: Dict[str, Any], units: List[str]) -> None:
    gens = state.setdefault("unit_generations", {})
    counter = int(state.get("control_generation", 0))
    for unit_id in units:
        key = str(unit_id)
        counter += 1
        gens[key] = counter
        if key in state.get("ai_controlled_units", []):
            state["ai_controlled_units"].remove(key)
        if key not in state.get("player_controlled_units", []):
            state["player_controlled_units"].append(key)
    state["control_generation"] = counter


def node_observe_receipt(state: Dict[str, Any], ctx: NodeContext) -> Dict[str, Any]:
    """回执观察：复核 PendingAuthority（按 command_id 查询，绝不重复下单）。"""
    pending = dict(state.get("pending_requests") or {})
    if not pending:
        return state
    tick = int(state.get("server_tick", 0))
    for intent_id, item in pending.items():
        if int(item.get("since_tick", -1)) >= tick:
            # 本轮刚提交的命令不与自己竞争复核（下一轮才复核）。
            continue
        if ctx.config.recheck_pending and ctx.services.recheck is not None:
            try:
                receipt = ctx.services.recheck(str(item.get("command_id", "")))
            except Exception as exc:  # noqa: BLE001 —— 复核失败保留 pending（未知不重下单）。
                _decide(state, "receipt_recheck_failed", intent_id=intent_id, reason=str(exc))
                receipt = None
            if receipt:
                state.setdefault("command_receipts", []).append(dict(receipt))
                _apply_receipt_to_state(state, intent_id, receipt)
                _decide(state, "pending_resolved", intent_id=intent_id,
                        status=str(receipt.get("status", "")))
                continue
        if tick - int(item.get("since_tick", tick)) > ctx.config.pending_timeout_ticks:
            # 超时不重下单，**也不当作失败**：保留占用（`active_unknown`），等复核/对账。
            # 【2026-09-12 实测】旧写法把超时标成 dropped → 单位"变空闲" → 微操层下一轮
            # 重发同一条命令（`pending_timeout` 33 次、`Unit_2|gather` 下发 76 次），
            # 而计划明确禁止"用推理/等待超时推断单位或任务状态"。
            state["pending_requests"].pop(intent_id, None)
            record = _find_intent(state, intent_id)
            if record is not None and record.get("state") == "pending_authority":
                record["state"] = "active_unknown"
                record["drop_reason"] = ""
                record["unknown_since_tick"] = tick
            _decide(state, "pending_timeout", intent_id=intent_id,
                    command_id=item.get("command_id"), action="keep_occupied_no_resubmit")
    return state


def node_persist_checkpoint(state: Dict[str, Any], ctx: NodeContext) -> Dict[str, Any]:
    """持久化节点：按 (match, player) 落 checkpoint（陈旧写被拒绝）。"""
    payload = {
        "checkpoint_version": 1,
        "saved_tick": int(state.get("server_tick", 0)),
        "state": {key: value for key, value in state.items()
                  if key not in ("intent_arbitration", "dispatch_pending")},
    }
    store = ctx.services.checkpoint_store
    try:
        # 直接走存储的 dict 通道（避免为节点再包一层 dataclass）。
        result = _save_raw(store, payload)
    except Exception as exc:  # noqa: BLE001 —— checkpoint 失败不阻塞执行链。
        result = {"saved": False, "reason": "checkpoint_error:%s" % exc}
    state["last_checkpoint"] = result
    if not result.get("saved") and result.get("reason") not in ("checkpoint_disabled",):
        _decide(state, "checkpoint_failed", reason=result.get("reason"))
    _log(ctx, state, "checkpoint", saved=bool(result.get("saved")),
         reason=result.get("reason", ""))
    return state


def _save_raw(store: CheckpointStore, payload: Dict[str, Any]) -> Dict[str, Any]:
    writer = getattr(store, "save_raw", None)
    if callable(writer):
        return writer(payload)
    from .state import AdjutantGraphState
    return store.save(AdjutantGraphState.from_dict(payload["state"]))


def node_wait(state: Dict[str, Any], ctx: NodeContext) -> Dict[str, Any]:
    """等待节点：本 tick 无**模型**决策；事件仍被消费（避免下轮重复触发）。

    注意**不得**在这里清 `candidate_intents`：非战术轮的微操候选（发展阶梯 +
    行为树）正是在 `node_classify` 里加入、经 WAIT→ARBITRATE 边送仲裁的。
    2026-09-12 实测（战略层关闭后 wait 轮占 420/526）：这里清空让微操候选
    全部饿死——仲裁 accepted/dropped 恒为空、整局 sent=0、基地纹丝不动。
    仲裁节点消费后会自行把 candidate_intents 清空，此处清空既重复又有害。
    """
    events = state.get("pending_events", [])
    if events:
        _decide(state, "events_consumed_without_decision", count=len(events),
                kinds=[str(e.get("kind", "")) for e in events])
    state["pending_events"] = []
    state["intent_arbitration"] = {"accepted": [], "dropped": [], "clamped": []}
    return state


# ---------------- 模型失败降级 ----------------

def _rules_fallback_batch(state: Dict[str, Any], ctx: NodeContext) -> Dict[str, Any]:
    """模型不可用/空响应时的确定性兜底意图批次。

    2026-09-11 起改由**微操行为树**产出（`behavior_tree.micro_batch`）：
    原 `rules_fallback.batch_from_rules` 只会"采集 + 补工人 + 发展阶梯"，
    没有避战、没有就近交火、没有侦察不空转 —— 实测表现为"只会造兵/只会采集"。
    行为树补齐了这些，同时仍复用 `development_intents` 决定"造什么/产什么"，
    因此原有契约与落点修复都不会丢。
    """
    return behavior_tree.micro_batch(
        state,
        tactical=ctx.observation.get("tactical"),
        rules=ctx.observation.get("rules"),
        ttl_ticks=int(ctx.config.intent_ttl_ticks),
        server_tick=int(state.get("server_tick", 0) or 0),
        snapshot_id=int(state.get("latest_snapshot_id", 0) or 0),
    )


def _on_model_failure(state: Dict[str, Any], ctx: NodeContext, role: str,
                      exc: BaseException) -> None:
    """模型超时/断线/非法输出：记录降级，保留既有计划与意图，不阻塞。"""
    state["model_errors"] = int(state.get("model_errors", 0)) + 1
    state["last_model_error_tick"] = int(state.get("server_tick", 0))
    kind = type(exc).__name__
    # 带异常摘要：只有类型名（如 tactics_model_ModelUnavailable）无法区分
    # "连接被拒 / 参数不支持 / 校验失败"，排查时会被迫反复试探（2026-09-11 实测教训）。
    state["degraded_reason"] = "%s_model_%s: %s" % (role, kind, str(exc)[:200])
    if role == "strategy":
        # 战略失败保留当前计划（不清空任务），战术层与 Godot 继续工作。
        # （连续失败进冷却后由 `interrupts.strategy_in_cooldown` 让位给战术，
        #  避免 active_plan 为空时战略永久独占路由。）
        _decide(state, "strategy_degraded", reason=str(exc),
                plan_preserved=state.get("active_plan") is not None,
                model_errors=state["model_errors"])
    else:
        _decide(state, "tactics_degraded", reason=str(exc),
                live_intents=len([i for i in state.get("active_intents", [])
                                  if i.get("state") in ("active", "pending_authority")]),
                model_errors=state["model_errors"])
    _log(ctx, state, "model_degraded", role=role, error=kind, reason=str(exc),
         model_errors=state["model_errors"])


def model_calls_allowed(state: Dict[str, Any], ctx: NodeContext, role: str) -> bool:
    """连续失败达上限后的冷却判定（冷却期内不再调用模型，走规则 AI）。"""
    errors = int(state.get("model_errors", 0))
    if errors < int(ctx.config.model_error_limit):
        return True
    last = state.get("last_model_error_tick")
    if last is None:
        return True
    return int(state.get("server_tick", 0)) - int(last) >= int(ctx.config.model_retry_cooldown_ticks)
