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

import time
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, Tuple

from . import interrupts as itr
from .arbitration import arbitrate_intents
from .checkpoint import CheckpointStore, NullCheckpointStore
from .contracts import (
    ACTION_ATTACK_MOVE, ACTION_MOVE, ACTION_RETREAT, ACTION_SCOUT, ContractError,
    IntentBatch, StrategicPlan, intent_to_command_envelope, parse_intent_batch,
    parse_strategic_plan,
)
from . import behavior_tree
from . import campaign as campaign_mod
from . import lanes as lanes_mod
from . import movement as movement_mod
from . import decision_map
from . import placement
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
#: 整局主线推进（观测之后、路由/微操之前）：阶段、里程碑、四条 track、中断栈。
NODE_CAMPAIGN = "update_campaign_state"
#: 里程碑推进（回执结算之后）：让本轮回执证据**当轮**生效，并弹出已处理的中断。
NODE_ADVANCE = "advance_milestones"
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
    #: **权威路径查询**（计划 §7）：`nav_query(unit, target) -> {ok, reachable, nav_revision,
    #: waypoints, route_length, end_clamped, reason}`，由宿主接到游戏侧
    #: `op=adjutant_nav_path`。为 None 时**所有主力移动都被闸门拒绝**（拿不到路径就不走，
    #: 而不是"退化成直线"）—— 这是刻意选的失败方向。
    nav_query: Optional[Callable[[str, Any], Dict[str, Any]]] = None
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


def _decide(state: Dict[str, Any], kind: str, /, **payload: Any) -> Dict[str, Any]:
    """写一条决策日志。

    【`kind` 必须是**位置专用参数**（`/` 之后才是 `**payload`）】
    2026-09-12 真机踩过：`_decide(state, "campaign_interrupt_resolved", **item)`，
    而 `item` 里恰好带 `kind` 字段 → 调用时撞名 → `TypeError: got multiple values for
    argument 'kind'` → **整个 tick 抛异常** → 连续 20 轮后 runner 自杀退出
    （`--model on` 5 分钟对局跑到第 90 秒整条指挥链断掉，采样却在继续跑，很容易被误读成"发展慢"）。
    位置专用参数让"payload 里带 kind"从**致命错误**变成**无害数据**：
    规范 kind 永远以第一个参数为准（payload 里的同名字段不会覆盖它）。
    """
    entry = {**payload, "kind": kind, "server_tick": int(state.get("server_tick", 0))}
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


#: 快速事件 → 能证明"命令已生效"的映射（**故意保守**）。
#:
#: 【2026-09-13 补 `arrival`】以前移动没有到达证据（权威端不产该事件），只能标"未证明"；
#: 现在 `arrival` 由权威导航代理采样产出（`DebugControlServer._fast_sample_movement`），
#: 移动**终于有到达证据**。但纪律不变：到达只表示**移动段**完成，
#: 不自动表示侦察/防守/攻击任务完成（计划 §7 末句）。
#: 采集仍不在表里：工人采集不产生事件，宁可标"未证明"，也不把"发了命令"当"已生效"。
FAST_EFFECT_EVENTS: Dict[str, Tuple[str, ...]] = {
    "produce": ("production_started",),
    "build": ("construction_done",),
    "attack": ("damage",),
    "move": ("arrival",),
    "attack_move": ("arrival",),
    "scout": ("arrival",),
}


def _consume_fast_events(state: Dict[str, Any], ctx: NodeContext) -> None:
    """消费 10Hz 扫描层的增量事件（计划 §3.1/§4：runner 保存 event_seq，只消费新增）。

    两件事：

    1. **三级时间戳的第三级**：把"能证明命令生效"的事件盖到对应意图上
       （`effective_tick`）。`generated`/`received` 已有；缺了 `effective` 时，
       "命令发出去没生效 / 生效很慢"只能靠感觉猜。
    2. 留痕：按 `kind` 汇总计数进 decision_log（不逐条写，避免日志爆炸）。

    去重口径：事件自带全局递增 `seq`，消费游标只增不减 —— 重复投递不会重复计数。
    """
    events = (ctx.observation or {}).get("fast_events") or []
    if not events:
        return
    cursor = int(state.get("fast_event_seq", -1) or -1)
    fresh = [event for event in events
             if isinstance(event, dict) and int(event.get("seq", 0) or 0) > cursor]
    if not fresh:
        return
    state["fast_event_seq"] = max(int(event.get("seq", 0) or 0) for event in fresh)
    counts: Dict[str, int] = {}
    stamped: List[str] = []
    intents = state.get("active_intents") or []
    for event in fresh:
        kind = str(event.get("kind", ""))
        counts[kind] = counts.get(kind, 0) + 1
        unit = str(event.get("unit", ""))
        # 【P2 闭环：到达 / 路径失败】这两类事实以前**拿不到**（权威端不产出，被显式声明
        # 为"不支持"），于是"到达后重观测""路径失败停止推进"都只是写进注释的口号。
        # 现在 10Hz 采样能给出它们（见 `DebugControlServer._fast_sample_movement`），
        # 这里必须**用起来**：到达 → 作废路线逼出下一跳重规划；路径失败 → 停止推进 + 进紧急线。
        if unit and kind == "path_failed":
            movement_mod.invalidate_route(state, unit, reason="path_failed")
            _raise_movement_urgent(state, ctx, "path_failed", unit,
                                   int(state.get("server_tick", 0) or 0))
        elif unit and kind == "arrival":
            movement_mod.note_arrival(state, unit, int(state.get("server_tick", 0) or 0))
        if not unit:
            continue
        for record in intents:
            if not isinstance(record, dict) or record.get("effective_tick"):
                continue
            action = str(record.get("action", ""))
            if kind not in FAST_EFFECT_EVENTS.get(action, ()):
                continue
            # 事件里的单位可能**不是**受令单位：`construction_done` 报的是**建筑**名，
            # 而建造意图的 `unit_ids` 是**工人**。所以候选名要包含意图的全部角色
            # （受令单位 + 目标里的实体/生产者/工地）——否则一类事件永远匹配不上，
            # 表现就是"能证明生效的证据一条都没盖上"（实测：effective 恒为 0）。
            names = {str(u) for u in (record.get("unit_ids") or [])}
            target = record.get("target")
            if isinstance(target, dict):
                for key in ("entity_id", "producer", "site", "building"):
                    value = target.get(key)
                    if value:
                        names.add(str(value))
            if unit not in names:
                continue
            record["effective_tick"] = int(event.get("server_tick", 0) or 0)
            stamped.append(str(record.get("intent_id", "")))
    _decide(state, "fast_events_consumed", count=len(fresh), kinds=counts,
            effective=stamped[:8])


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

    # 10Hz 扫描层的增量事件：先消费，后续节点（含回执结算与进度）都看到最新证据。
    _consume_fast_events(state, ctx)
    # 导航网格版本（P2 安全移动）：路线记录必须绑定"当时是哪一版网格"，
    # 重烘之后旧路径一律作废。缺失/非法时**保持 -1（未知）**，不猜。
    fast_state = ctx.observation.get("fast_state")
    if isinstance(fast_state, dict) and fast_state.get("nav_revision") is not None:
        try:
            state["nav_revision"] = int(fast_state["nav_revision"])
        except (TypeError, ValueError):
            pass

    # 地图边界（`op=strategic` 提供，形如 `[size_x, size_z]`，原点在角上）：
    # 规则层产出的坐标必须**留在地图内**，否则权威端判 `OutOfBounds`。
    # 只进不出的"最后已知"语义：战略视图缺省时沿用上一轮的值，绝不猜。
    strategic = ctx.observation.get("strategic")
    bounds = strategic.get("map_bounds") if isinstance(strategic, dict) else None
    if isinstance(bounds, (list, tuple)) and len(bounds) >= 2:
        try:
            state["map_bounds"] = [float(bounds[0]), float(bounds[1])]
        except (TypeError, ValueError):
            pass
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


# ---------------- 整局主线（campaign_state） ----------------
#
# 纠偏文档要求图的长期状态**跨 tick / checkpoint 保留整局主线**，而不是只保留
# 最后一批意图。这两个节点就是"主线"的读写口：
#   `update_campaign_state`  —— 观测之后（微操之前）推进阶段/里程碑/中断栈；
#   `advance_milestones`     —— 回执结算之后再判一次（本轮回执证据当轮生效）。
# 二者调用同一实现（`campaign.update`），并且按 tick 幂等，重复调用不会重复计数。

def _run_campaign_stage(state: Dict[str, Any], ctx: NodeContext, stage: str) -> None:
    tick = int(state.get("server_tick", 0))
    try:
        campaign = campaign_mod.update(state, ctx.observation, tick)
    except Exception as exc:  # noqa: BLE001 —— 主线推进异常绝不允许拖垮指挥链
        _log(ctx, state, "campaign_error", stage=stage, error=repr(exc)[:200])
        # 至少保证"主线存在"：缺了它，规则阶梯会退回默认顺序（不是致命，但会丢主线语义）。
        campaign = campaign_mod.ensure_campaign(state, tick)
        return
    for event in campaign.get("new_transitions") or []:
        payload = {key: value for key, value in event.items() if key != "kind"}
        _decide(state, "campaign_%s" % str(event.get("kind", "transition")), **payload)
    for item in campaign.get("resolved_interrupts") or []:
        # 中断条目自带 `kind`（事件类型）：这里显式改名，避免与决策 kind 混淆
        # （`_decide` 已按位置专用参数加固，但日志字段也该干净可读）。
        payload = {key: value for key, value in item.items() if key != "kind"}
        payload["interrupt_kind"] = str(item.get("kind", ""))
        _decide(state, "campaign_interrupt_resolved", **payload)
    summary = campaign_mod.summary(campaign)
    # 结构化日志每轮一条（复盘用），决策日志只记变迁（面板/验收用）。
    _log(ctx, state, "campaign", stage=stage, phase=summary.get("phase"),
         frontier=summary.get("frontier"), frontier_name=summary.get("frontier_name"),
         done=",".join(summary.get("done") or []),
         blocked=",".join(item.get("id", "") for item in summary.get("blocked") or []),
         tracks=",".join("%s=%s" % (k, v) for k, v in
                         (summary.get("tracks") or {}).items()),
         interrupts=summary.get("interrupts"),
         expansion=",".join(str(item) for item in
                            (summary.get("expansion_candidates") or [])[:1]))


def node_update_campaign(state: Dict[str, Any], ctx: NodeContext) -> Dict[str, Any]:
    """整局主线推进：阶段 / 里程碑 / 四条 track / next_frontier / interrupt_stack。"""
    _run_campaign_stage(state, ctx, "update")
    return state


def node_advance_milestones(state: Dict[str, Any], ctx: NodeContext) -> Dict[str, Any]:
    """里程碑推进（回执结算后）：权威证据当轮生效 + 中断恢复。"""
    _run_campaign_stage(state, ctx, "advance")
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
            # `value` 是 pydantic `TaskPatchBatch`（LangGraph 可序列化）；
            # `decode` 必须**先摘要成 dict**：DecodeResult 是 dataclass，放进
            # LangGraph state 会在 checkpoint 的 msgpack 序列化处抛
            # `TypeError: Type is not msgpack serializable: DecodeResult`，
            # 从而每若干个 tick 就整轮异常（回执结算、下发全部丢失）。
            "value": outcome.value,
            "decode": task_patch_bridge.summarize_decode(outcome.decode),
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
    # 【规则中台常驻】**无条件**跑一轮 baseline（纠偏 §三-3：route 是模型调度节拍，
    # 不能成为规则/行为树的运行门控）。此前它被 `if route not in (tactical, ...)`
    # 与 `node_tactical_agent` 内的模型分支切成两半 → 两条路径的语义还不一致，
    # 且模型在途时那一半直接 `return` 掉，整轮没有 baseline。
    # 现在单点生成：每 tick 恰好生成一次，后续节点只做"模型稀疏覆盖"。
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
            campaign = campaign_mod.ensure_campaign(state, tick)
            if kind == itr.EVT_PLAYER_OVERRIDE:
                campaign_mod.note_player_override(campaign, units, tick,
                                                  str(payload.get("reason", "")))
            else:
                campaign_mod.note_player_release(campaign, units, tick)
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
    campaign = campaign_mod.ensure_campaign(state, tick)
    campaign_summary = campaign_mod.summary(campaign)
    _decide(state, "plan_reconciled",
            handled=[{"kind": r["kind"], "units": r["unit_ids"]} for r in handled_records],
            plan_preserved=state.get("active_plan") is not None,
            # 【主线未被清空】的显式证据：玩家局部接管后，阶段/前沿/里程碑原样保留。
            campaign_preserved=bool(campaign_summary),
            campaign_phase=campaign_summary.get("phase", ""),
            campaign_frontier=campaign_summary.get("frontier", ""),
            campaign_suspended=campaign_summary.get("suspended_objects", []))
    _log(ctx, state, "graph_reconcile", handled=len(handled_records),
         player_units=state.get("player_controlled_units", []),
         campaign_frontier=campaign_summary.get("frontier", ""),
         campaign_suspended=len(campaign_summary.get("suspended_objects") or []))
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
    # 【主线纪律】玩家局部接管**只暂停受影响对象**，不清空主线：
    # 里程碑状态、next_frontier、四条 track 的当前任务一律保留（纠偏 §紧急事件/接管语义）。
    campaign = campaign_mod.ensure_campaign(state, tick)
    campaign_mod.note_player_override(campaign, units, tick, reason)
    _decide(state, "campaign_player_override", units=[str(u) for u in units],
            suspended=len(campaign.get("suspended_objects") or []),
            frontier=str(campaign.get("next_frontier", "")))
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
    campaign = campaign_mod.ensure_campaign(state, tick)
    campaign_mod.note_player_release(campaign, units, tick)
    _decide(state, "campaign_player_release", units=[str(u) for u in units],
            suspended=len(campaign.get("suspended_objects") or []),
            frontier=str(campaign.get("next_frontier", "")))
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
        # 保留本轮 baseline（纠偏 §三-2/3）：战略模型缺席不是"这轮谁都不动"的理由。
        _keep_baseline(state)
        return state
    if not model_calls_allowed(state, ctx, "strategy"):
        _decide(state, "strategy_skipped", reason="model_cooldown")
        _keep_baseline(state)
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
        _keep_baseline(state)
        return state
    except Exception as exc:  # noqa: BLE001 —— 未知异常也归入降级，不炸图。
        _on_model_failure(state, ctx, "strategy", exc)
        _keep_baseline(state)
        return state

    if plan is None:
        state["last_strategy_tick"] = tick
        state["model_errors"] = 0
        _consume_events(state, itr.STRATEGIC_EVENT_KINDS)
        _decide(state, "strategy_empty", tick=tick)
        _keep_baseline(state)
        return state
    try:
        parsed: StrategicPlan = parse_strategic_plan(plan)
    except ContractError as exc:
        _on_model_failure(state, ctx, "strategy", ModelInvalidOutput("; ".join(exc.errors)))
        _keep_baseline(state)
        return state
    if str(parsed.match_id) != str(state.get("match_id", "")) or \
            str(parsed.player_id) != str(state.get("player_id", "")):
        _on_model_failure(state, ctx, "strategy",
                          ModelInvalidOutput("计划身份与当前对局不一致"))
        _keep_baseline(state)
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
        _keep_baseline(state)
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
    _keep_baseline(state)
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


#: 候选来源标记。纠偏 §二 要求 `origin=baseline / model / behavior_tree` 可区分 ——
#: 日志与指标必须能分开统计"规则中台做的"和"模型改的"，否则无法证明模型增量。
ORIGIN_BASELINE = "baseline"
ORIGIN_BEHAVIOR_TREE = "behavior_tree"
ORIGIN_MODEL = "model"
BASELINE_ORIGINS = (ORIGIN_BASELINE, ORIGIN_BEHAVIOR_TREE)
#: 来源**旁路账本**：`{intent_id: origin}`。
#: 为什么不能把 `origin` 直接写进意图 dict（2026-09-12 实测）：
#: 意图契约是 `extra=forbid` 的严格模型，多一个字段整条意图就被判
#: `contract_invalid: origin: Extra inputs are not permitted` → 模型意图**全军覆没**。
#: 所以来源只在这里记账，下发/仲裁的载荷保持干净（纠偏 §二 只要求"可区分"，
#: 不要求把它塞进协议）。
ORIGIN_KEY = "intent_origin"


def _origin_of(state: Dict[str, Any], item: Dict[str, Any]) -> str:
    return str((state.get(ORIGIN_KEY) or {}).get(str(item.get("intent_id", "")), ""))


def _strip_origin(items: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """去掉意图里的内部字段（`origin`），保证送进契约校验的载荷是干净的。"""
    return [{key: value for key, value in item.items() if key != "origin"}
            for item in items]


def _record_origins(state: Dict[str, Any], items: List[Dict[str, Any]]) -> None:
    table = state.setdefault(ORIGIN_KEY, {})
    for item in items:
        origin = str(item.get("origin", "") or "")
        key = str(item.get("intent_id", "") or "")
        if origin and key:
            table[key] = origin


def _baseline_only(state: Dict[str, Any]) -> List[Dict[str, Any]]:
    """只保留规则中台/行为树产出的候选（丢掉上一轮残留的临时模型候选）。"""
    return [dict(item) for item in (state.get("candidate_intents") or [])
            if isinstance(item, dict)
            and _origin_of(state, item) in BASELINE_ORIGINS]


def _ensure_baseline(state: Dict[str, Any], ctx: NodeContext) -> List[Dict[str, Any]]:
    """保证**本轮** baseline 已生成，并返回它（幂等：同一 tick 只生成一次）。

    为什么要有这一层而不是直接依赖 `node_classify` 先跑：真实图里 classify 一定在
    战术节点之前，所以"每 tick 一次"是自然成立的；但集成测试/回放会**直接调用**
    战术节点，若此时 baseline 为空，模型候选就会在"没有地板"的真空里被合并 ——
    表现成"规则层又变成可选"。用 `baseline_tick` 做周期闸，既保证兜底，又保证
    同一周期不重复生成（纠偏 §五-4）。
    """
    tick = int(state.get("server_tick", 0))
    if int(state.get("baseline_tick", -1) or -1) != tick:
        _run_micro_layer(state, ctx)
    return _baseline_only(state)


def _keep_baseline(state: Dict[str, Any]) -> None:
    """模型路径提前退出时**保留**本轮规则候选，而不是清空。

    纠偏 §三-2 明确要求：模型缺失、冷却、超时、异常或非法输出**不得吞掉**本轮合法
    baseline 候选。此前这些分支一律 `state["candidate_intents"] = []`，于是
    "模型一有状况 → 本轮谁都不动"（外部表现就是整局零发展）。
    """
    state["candidate_intents"] = _baseline_only(state)


def _protected_baseline(origin: str, action: str) -> bool:
    """该 baseline 动作是否**受保护**（模型不能把它挤掉）。

    按**来源**区分，而不是只看动作名 —— 这一点被三条既有回归用例同时钉死：
    - `retreat`：任何来源都是求生，模型不得顶掉
      （`test_outnumbered_retreat_preempts_model_attack`）；
    - **阶梯**（`origin=baseline`）的 `build/produce/attack`：这是"程序自己的发展骨架"，
      模型"每轮只回 gather"时**不得**把发展饿死
      （`test_ladder_build_preempts_model_gather_on_same_worker`，
       = 纠偏 §一"不得让模型一条采集永远饿死建设"）；
    - **行为树**（`origin=behavior_tree`）的交火/采集/侦察/集结：只是"默认打杂"，
      模型一旦显式指定该执行者就得让位 —— 否则"模型下发 move 必须被接受"这条金标准
      会被地板的"就近交火"顶掉（`replay_player_takeover` 明确钉住）。
    """
    if action == ACTION_RETREAT:
        return True
    return origin == ORIGIN_BASELINE and action in rules_fallback.DEVELOPMENT_ACTIONS


def _merge_model_over_baseline(
        baseline: List[Dict[str, Any]], model_items: List[Dict[str, Any]],
        origins: Dict[str, str],
) -> Tuple[List[Dict[str, Any]], List[str]]:
    """模型候选**稀疏覆盖** baseline：只动它显式指定的执行者。

    返回 `(合并结果, 被顶掉的 baseline intent_id)`。
    纪律（纠偏 §四）：模型没提到的单位继续跑 baseline 或既有任务；模型显式指定的执行者，
    除受保护的地板动作（见 `_protected_baseline`）外一律以模型为准。
    """
    out = list(baseline)
    displaced: List[str] = []
    for item in model_items:
        units = {str(u) for u in (item.get("unit_ids") or [])}
        # **只和地板冲突**：模型内部两条同单位的候选（例如"打旧目标"+"转移位置"）
        # 属于同一批 patch 内部的问题，必须留给**仲裁层**逐条判定并给出拒绝原因
        # （`replay_target_dead` 明确钉住 `dropped[i-attack-stale]=entity_not_in_observation`）。
        # 合并层若顺手把它们互相顶掉，那些拒绝原因就永远消失了。
        conflicts = [c for c in out
                     if units & {str(u) for u in (c.get("unit_ids") or [])}
                     and str(origins.get(str(c.get("intent_id", "")), ""))
                     in BASELINE_ORIGINS]
        item_rank = rules_fallback.action_rank(str(item.get("action", "")))
        if any(_protected_baseline(
                   str(origins.get(str(c.get("intent_id", "")), "")),
                   str(c.get("action", "")))
               and rules_fallback.action_rank(str(c.get("action", ""))) >= item_rank
               for c in conflicts):
            continue
        for conflict in conflicts:
            out.remove(conflict)
            displaced.append(str(conflict.get("intent_id", "")))
        out.append(item)
    return out, displaced


def _run_micro_layer(state: Dict[str, Any], ctx: NodeContext) -> None:
    """**规则中台常驻一轮**：发展阶梯 + 行为树 → baseline 候选（每 tick 都跑）。

    ## 为什么必须独立出来（2026-09-11 实测，用户反馈"没看到副官批量指挥部队"）

    微操原先只挂在战术分支里（`route ∈ {tactical, emergency_tactical}`），而战术分支被
    "事件间隔 + 模型耗时"门控：5 分钟一局里战术分支只跑了 **2~5 次**（同局 `strategy_request`
    却有 18~28 次）→ 微操跟着被饿死：整局 0 生产、屏幕上几乎看不到任何批量指挥。
    用户方针本来就是"微操靠行为树、LLM 慢不要紧"，所以微操必须每轮都跑。

    ## 调用位置（2026-09-12 晚 架构纠偏后）

    由 `node_classify` **无条件**调用：`route` 只是"模型调度节拍"，不能成为规则与
    行为树的运行门控（纠偏 §三-3）。模型在途 / 缺失 / 冷却 / 超时 / 空批次 / 非法输出
    都不影响本函数 —— 本轮 baseline 候选永远由本函数独立重建。

    模型侧的职责只是**在 baseline 之上做稀疏覆盖**（见 `_merge_model_over_baseline`）：
    它没提到的执行者继续按 baseline 跑。**不再**存在"模型成功时按缺口过滤阶梯"那套
    被动语义 —— 那正是"规则退化成 fallback"的根源。

    来源标记：阶梯（经济/建造/生产/进攻骨架）→ `origin=baseline`；
    行为树的单位级动作（采集兜底/侦察/集结/就近交火/撤离）→ `origin=behavior_tree`。

    重复下发由三层拦住：① "最近下发窗口"（`_repeat_suppressed`）；
    ② 活跃意图守卫（正在执行且未终止的任务不被无条件重下）；③ 仲裁层单位级判重。

    异常一律吞掉并留痕：规则中台失败绝不允许拖垮指挥链。
    """
    tick = int(state.get("server_tick", 0))
    candidates = _baseline_only(state)
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
        entry = dict(item)
        # 来源标记（纠偏 §二）：阶梯 = 规则中台的基础策略；行为树 = 单位级持续执行。
        # 只进**旁路账本**，不进意图载荷（见 ORIGIN_KEY 说明）。
        entry["origin"] = (ORIGIN_BASELINE if from_ladder
                           else ORIGIN_BEHAVIOR_TREE)
        _record_origins(state, [entry])
        candidates.append(_strip_origin([entry])[0])
        added.append(str(entry.get("intent_id", "")))
    # **无条件回写**：即使本轮没新增，也要把"上一轮残留的模型候选"清掉，
    # 保证后续节点看到的候选集 = 纯 baseline（模型候选只能由本轮模型结果重新引入）。
    state["candidate_intents"] = _strip_origin(candidates)
    # 来源账本剪枝：只保留仍在"本轮候选 ∪ 活跃意图"里的 id，避免无限增长。
    keep = {str(c.get("intent_id", "")) for c in state["candidate_intents"]}
    keep |= {str(i.get("intent_id", ""))
             for i in (state.get("active_intents") or [])}
    state[ORIGIN_KEY] = {key: value
                         for key, value in (state.get(ORIGIN_KEY) or {}).items()
                         if key in keep}
    state["baseline_tick"] = tick
    try:
        ladder_diag = rules_fallback.ladder_inputs(
            state, tactical=ctx.observation.get("tactical"),
            rules=ctx.observation.get("rules"))
    except Exception as exc:  # noqa: BLE001
        ladder_diag = {"error": str(exc)[:200]}
    _log(ctx, state, "rule_floor", interface="task_patch", tick=tick,
         route=str(state.get("route", "")), produced=len(added),
         suppressed=suppressed,
         baseline=sum(1 for c in candidates
                      if str(c.get("origin")) == ORIGIN_BASELINE),
         behavior_tree=sum(1 for c in candidates
                           if str(c.get("origin")) == ORIGIN_BEHAVIOR_TREE),
         **ladder_diag)
    if added:
        _decide(state, "micro_control_added", intents=added, tick=tick,
                origin="baseline_policy")
        _log(ctx, state, "micro_control", added=len(added), suppressed=suppressed,
             route=str(state.get("route", "")))


def _apply_model_branch(state: Dict[str, Any], ctx: NodeContext, decode: Any,
                        tick: int) -> None:
    """模型用四列输出的 `g` 字段选择**主线分支**（低频、可校验）。

    纪律（纠偏 §"小模型只选择主线分支和参数，不负责重新生成整张任务表"）：
    模型没给 `g` / 给的条件不满足 / 给的是不存在的分支 → **沿用当前主线**，
    不做任何清空（空输出绝不解释成"无战略"）。
    """
    ref = ""
    if isinstance(decode, dict):
        ref = str(decode.get("goal_ref", "") or "")
    elif decode is not None:
        ref = str(getattr(decode, "goal_ref", "") or "")
    if not ref:
        return
    try:
        result = campaign_mod.note_model_branch(state, ref, tick)
    except Exception as exc:  # noqa: BLE001 —— 分支选择失败不影响本轮任务落地
        _decide(state, "campaign_branch_ignored", ref=ref, reason="error:%s" % str(exc)[:60])
        return
    if bool(result.get("accepted")):
        payload = {key: value for key, value in result.items() if key != "reason"}
        _decide(state, "campaign_branch_adopted", ref=ref, **payload)
    else:
        _decide(state, "campaign_branch_ignored", ref=ref, reason=result.get("reason"))
    _log(ctx, state, "campaign_branch", ref=ref, accepted=bool(result.get("accepted")),
         reason=result.get("reason", ""))


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
    """四列接口路径：模型对 baseline 候选表做**稀疏 patch**；程序展开并复用既有权威链。

    与旧语义的关键差别（2026-09-12 晚 架构纠偏 §三/§四）：
    - baseline（规则中台 + 行为树）由 `node_classify` **每 tick 无条件**生成，本函数
      **不再**是规则的运行门控：模型在途 / 缺失 / 冷却 / 超时 / 空批次 / 非法输出
      一律**保留** baseline 候选（此前一律 `candidate_intents = []` → 整轮谁都不动）；
    - 模型只覆盖它**显式指定且有权限**的执行者（`_merge_model_over_baseline`），
      没提到的单位继续跑 baseline 或既有任务；
    - 程序拒绝非法/过期/冲突/预算不足的 patch，但**不因拒绝一个 patch 而清掉 baseline**；
    - 不再有"模型成功时按缺口补骨架"那套被动语义 —— 那是"规则退化成 fallback"的根源。
    """
    mode = str(getattr(ctx.services.tactics_model, "mode", MODE_FAST) or MODE_FAST)
    scheduler = getattr(ctx.services, "tactics_scheduler", None)
    fallback_used = ""
    batch = None
    decode = None
    # 本轮 baseline 由 `node_classify` **无条件**生成（`origin=baseline/behavior_tree`）；
    # `_ensure_baseline` 只做"同一 tick 幂等"兜底（集成测试/回放会直接调用本函数）。
    # 这里只负责"把模型的稀疏 patch 叠上去"，任何提前退出都必须把它**原样保留**。
    baseline = _ensure_baseline(state, ctx)
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
            # 模型若在 `g` 里选了主线分支，这里落地（校验前置条件，不满足则沿用主线）。
            _apply_model_branch(state, ctx, decode, tick)
            # 【曾试过"落地轮顺便提交下一轮"的流水线，已回退】它能把思考间隔从
            # 2.6 秒压到 1 秒级，但会让**同一个 intent_id 被下发两次**
            # （`test_result_applied_once_then_fresh_submissions_continue` 抓到：
            # 单调的 stub 模型回同一批 → 第二次结果又走一遍下发）。
            # 纪律：宁可慢一点，也不能重新引入"重复命令"——那正是用户此前明确否定的。
            # 真要做流水线，必须先在**下发前**按 `intent_id + (执行者,动作,目标)` 去重。
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
            # 【纠偏 §三-1】模型在途**不得**跳过本轮规则地板，也不得清空候选：
            # 相关单位继续执行既有任务，baseline 候选照常进仲裁。
            state["candidate_intents"] = baseline
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
        _apply_model_branch(state, ctx, decode, tick)
    # 审计：把"模型原始输出"一起落盘。此前只落解码摘要，而异步路径的 decode 恒为 None
    # （调度器只带 IntentBatch），于是日志打出误导性的 rows=0/0/0，谁也看不出"模型回了空"。
    _log(ctx, state, "task_patch", mode=mode, fallback=fallback_used,
         raw=str(getattr(ctx.services.tactics_model, "last_raw_text", "") or "")[:400],
         **task_patch_bridge.summarize_decode(decode))
    if batch is None and not fallback_used:
        _decide(state, "tactics_empty", tick=tick)
        fallback_used = "model_empty"
    if batch is None:
        # 空批次 / 降级：baseline 照常执行。**不再**回头再跑一次规则层 ——
        # 它已经在 `node_classify` 跑过，这里再跑就是同一周期的重复生成
        # （纠偏 §五-4 明确要求"同一周期不重复生成"）。
        # 但必须**明确留痕**这一轮是规则在扛：否则事后无法区分
        # "模型给了空批次" 与 "模型根本没跑"（纠偏 §五-4 要求的可审计性）。
        _decide(state, "tactics_rules_fallback_used",
                reason=fallback_used or "model_empty",
                intents=0, origin=ORIGIN_BASELINE)
        state["candidate_intents"] = baseline
        state["last_tactics_tick"] = tick
        _consume_events(state)
        return state
    try:
        parsed: IntentBatch = parse_intent_batch(batch)
    except ContractError as exc:
        _on_model_failure(state, ctx, "tactics", ModelInvalidOutput("; ".join(exc.errors)))
        state["candidate_intents"] = baseline
        return state
    if (parsed.match_id and str(parsed.match_id) != str(state.get("match_id", ""))) or \
            (parsed.player_id and str(parsed.player_id) != str(state.get("player_id", ""))):
        _on_model_failure(state, ctx, "tactics",
                          ModelInvalidOutput("意图批次身份与当前对局不一致"))
        state["candidate_intents"] = baseline
        return state
    parsed.match_id = str(state.get("match_id", ""))
    parsed.player_id = str(state.get("player_id", ""))
    parsed.plan_version = parsed.plan_version or str(state.get("plan_version", ""))
    model_items: List[Dict[str, Any]] = []
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
        item["origin"] = ORIGIN_MODEL
        model_items.append(item)
    # 【模型稀疏覆盖 baseline】(纠偏 §四)：模型只动它**显式指定且有权限**的执行者，
    # 没提到的单位继续跑 baseline 或既有任务；抢占序更高的 baseline 动作（求生 retreat）
    # 不被一条模型 gather 顶掉。
    # 这里**不再**回头调用规则层 —— baseline 已由 `node_classify` 每 tick 生成一次，
    # 本函数再生成就是"同一周期重复生成"（纠偏 §五-4 明令禁止）。
    _record_origins(state, model_items)
    merged, displaced = _merge_model_over_baseline(
        baseline, model_items, state.get(ORIGIN_KEY) or {})
    _log(ctx, state, "task_patch_merge", interface="task_patch",
         model=len(model_items), baseline=len(baseline),
         merged=len(merged), displaced=displaced)
    if displaced:
        _decide(state, "baseline_displaced_by_model", intents=displaced,
                model_intents=len(model_items))
    state["candidate_intents"] = _strip_origin(merged)
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
        # 【纠偏 §三-2】模型关掉/缺席**不得**吞掉本轮 baseline：保留候选继续进仲裁。
        _decide(state, "tactics_skipped", reason="no_tactics_model")
        _keep_baseline(state)
        return state
    if not model_calls_allowed(state, ctx, "tactics"):
        _decide(state, "tactics_skipped", reason="model_cooldown")
        _keep_baseline(state)
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
    baseline = _ensure_baseline(state, ctx)
    batch = None
    try:
        batch = ctx.services.tactics_model.propose_intents(context)
    except (ModelTimeout, ModelUnavailable, ModelInvalidOutput) as exc:
        _on_model_failure(state, ctx, "tactics", exc)
        fallback_used = "model_error"
    except Exception as exc:  # noqa: BLE001
        _on_model_failure(state, ctx, "tactics", exc)
        fallback_used = "model_error"

    if batch is None:
        # 空响应 / 模型失败：**baseline 照常执行**（已在 `node_classify` 生成一次）。
        # 不再走 `_rules_fallback_batch` —— 那是同一周期里的第二次规则生成，
        # 违反"同一周期不重复生成"（纠偏 §五-4），且来源标记会与 baseline 混淆。
        _decide(state, "tactics_empty", tick=tick, degraded=fallback_used)
        _decide(state, "tactics_rules_fallback_used",
                reason=fallback_used or "model_empty",
                intents=0, origin=ORIGIN_BASELINE)
        state["candidate_intents"] = baseline
        state["last_tactics_tick"] = tick
        _consume_events(state)
        return state
    # 模型可以省略/留空“回声字段”，由系统按上下文补齐；给出非空值时仍必须一致（下方校验）。
    batch = _fill_batch_echo(batch, state, ctx.config.intent_ttl_ticks)
    try:
        parsed: IntentBatch = parse_intent_batch(batch)
    except ContractError as exc:
        _on_model_failure(state, ctx, "tactics", ModelInvalidOutput("; ".join(exc.errors)))
        _keep_baseline(state)
        return state
    if (parsed.match_id and str(parsed.match_id) != str(state.get("match_id", ""))) or \
            (parsed.player_id and str(parsed.player_id) != str(state.get("player_id", ""))):
        # 意图批次身份与当前对局不一致：拒绝（绝不把意图下进别的对局）。
        _on_model_failure(state, ctx, "tactics",
                          ModelInvalidOutput("意图批次身份与当前对局不一致"))
        _keep_baseline(state)
        return state
    parsed.match_id = str(state.get("match_id", ""))
    parsed.player_id = str(state.get("player_id", ""))
    parsed.plan_version = parsed.plan_version or str(state.get("plan_version", ""))
    # legacy 路径这里只可能拿到模型批次（模型失败/空响应已在上方提前返回）。
    candidates = [dict(intent.to_dict(), origin=ORIGIN_MODEL)
                  for intent in parsed.intents]
    # 【模型稀疏覆盖 baseline】(纠偏 §四)：与四列路径**同一语义** —— baseline 常驻，
    # 模型只覆盖它显式指定且有权限的执行者，没提到的单位继续跑 baseline 或既有任务。
    # 这里**删除了**旧的"按 DEVELOPMENT_ACTIONS 缺口补骨架"逻辑：
    #   ① 它只在"模型这批恰好缺某个动作名"时才触发 —— 被动 fallback，正是纠偏要废弃的形态；
    #   ② 它会**第二次**调用 `behavior_tree.micro_parts`，与 `node_classify` 的常驻生成
    #      重复，违反"同一周期不重复生成"（纠偏 §五-4）。
    _record_origins(state, candidates)
    merged, displaced = _merge_model_over_baseline(
        baseline, candidates, state.get(ORIGIN_KEY) or {})
    _log(ctx, state, "task_patch_merge", interface="legacy",
         model=len(candidates), baseline=len(baseline),
         merged=len(merged), displaced=displaced, fallback=fallback_used)
    if displaced:
        _decide(state, "baseline_displaced_by_model", intents=displaced,
                model_intents=len(candidates))
    state["candidate_intents"] = _strip_origin(merged)
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

#: 需要过安全闸门的动作（"在野外移动"这一类）。其它动作不走这条路：
#: 采集/建造在基地附近、生产在建筑里，都不涉及野外行军。
GATED_MOVE_ACTIONS = (ACTION_ATTACK_MOVE, ACTION_MOVE, ACTION_SCOUT)

#: `movement_urgent` 保留条数（有界，避免长局无限增长）。
MOVEMENT_URGENT_LIMIT = 32
#: 同一单位同一种紧急事件的抑制窗口（tick）：避免"一直走不通"每轮刷一条。
MOVEMENT_URGENT_SUPPRESS_TICKS = 600


def _raise_movement_urgent(state: Dict[str, Any], ctx: NodeContext, kind: str,
                           unit: str, tick: int) -> None:
    """把"遇敌 / 受阻 / 路径失败"送进**紧急线**（计划 §7）。

    两件事都要做，缺一不可：

    1. 记进 `state["movement_urgent"]`（有界，供验收读"遇敌停止/重规划延迟"）；
    2. 推进 `state["pending_events"]` —— 这样 `has_emergency_event` 才会为真、
       图才会路由到紧急战术分支。**只记不推事件等于没进紧急线**（这条踩过：
       `path_failed` 原本只是个词表常量，不在紧急集合里，所以"路走不通"永远不打断推进）。
    """
    entry = {"kind": str(kind), "unit": str(unit), "tick": int(tick)}
    items = state.setdefault("movement_urgent", [])
    items.append(entry)
    if len(items) > MOVEMENT_URGENT_LIMIT:
        del items[:-MOVEMENT_URGENT_LIMIT]
    # 抑制窗口：同一单位同一类事件在窗口内只推一次（否则每轮一条 → 事件风暴）。
    for old in items[:-1]:
        if (str(old.get("kind")) == str(kind) and str(old.get("unit")) == str(unit)
                and int(tick) - int(old.get("tick", 0)) < MOVEMENT_URGENT_SUPPRESS_TICKS):
            return
    state.setdefault("pending_events", []).append({
        "event_id": "movement-%s-%s-%d" % (kind, unit, tick),
        "kind": str(kind),
        "match_id": str(state.get("match_id", "")),
        "player_id": str(state.get("player_id", "")),
        "server_tick": int(tick),
        "payload": {"subject": str(unit), "source": "movement_gate"},
    })
    _decide(state, "movement_urgent", tick=int(tick), kind=str(kind), unit=str(unit))


def _gate_movement(state: Dict[str, Any], ctx: NodeContext,
                   candidates: List[Dict[str, Any]]
                   ) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
    """**安全移动硬闸门**（计划 §7）：候选里的野外移动意图逐条过闸门。

    通过 → 目标被改写成**安全中继点**（一跳），路线证据落在 `state["routes"]`；
    不通过 → 直接从候选里摘掉，给出可统计的原因 `movement_gated:<reason>`。

    这就是"**没有有效路径的主力移动数为 0**"的实现方式：不是事后统计发现，
    而是**结构上**根本没有未经验证的移动意图能走到下发（同一处收口，无法绕过）。

    为什么放在仲裁前：仲裁是通往下发的**唯一咽喉**（`candidates → arbitrate → dispatch`），
    闸门放这里就不必给每个生产者各写一遍（写多份必然漏，本项目已有先例）。
    """
    if not candidates:
        return candidates, []
    nav_query = getattr(getattr(ctx, "services", None), "nav_query", None)
    tactical = ctx.observation.get("tactical")
    tick = int(state.get("server_tick", 0))
    if nav_query is None:
        # 【宿主没接权威寻路时的显式降级】生产环境由 runner 接 `op=adjutant_nav_path`；
        # 没接时闸门**无法判定**，此时不静默放行、也不硬拦（硬拦会让所有离线回放全挂），
        # 而是：原样放行 + **显式计数** `ungated` + 留一条决策日志。
        # 这样"无路径移动数"这个验收指标依然诚实：凡是没经过验证的移动都会被计上。
        movable = [item for item in candidates
                   if str(item.get("action", "")) in GATED_MOVE_ACTIONS]
        if movable:
            stats = state.setdefault("movement_stats", {})
            stats["ungated"] = int(stats.get("ungated", 0)) + len(movable)
            _decide(state, "movement_gate_unavailable", tick=tick,
                    ungated=len(movable),
                    note="未接入权威寻路，移动意图未经安全闸门（生产必须接上）")
        return candidates, []
    kept: List[Dict[str, Any]] = []
    blocked: List[Dict[str, Any]] = []
    queries = 0
    for intent in candidates:
        action = str(intent.get("action", ""))
        target = intent.get("target")
        position = (target or {}).get("pos") if isinstance(target, dict) else None
        if action not in GATED_MOVE_ACTIONS or not isinstance(position, (list, tuple)) \
                or len(position) < 2:
            kept.append(intent)
            continue
        units = [str(item) for item in (intent.get("unit_ids") or [])]
        if not units:
            kept.append(intent)
            continue
        # 角色按**单位类型**判，而不是按动作名/意图 id：
        # 专职侦察单位（drone/scout）本来就要走进未探区扩大视野，用主力的
        # "中继点必须在己方视野内"去卡它，等于永远不许它出门 ——
        # 实测后果：扩张前探被 `movement_gated:no_relay` 卡死 → `expansion_candidate` 变 False
        # （M04 直接走不过去）。主力（士兵/坦克）才需要中继点 + 侦察确认。
        # 编队里**只要有一个主力**，整队按主力规则处理（保守优先）。
        by_name = movement_mod._by_name(tactical)
        role = (movement_mod.ROLE_SCOUT
                if all(str((by_name.get(member) or {}).get("type", ""))
                       in rules_fallback.PROBE_TYPES for member in units)
                and action != ACTION_MOVE
                else movement_mod.ROLE_MAIN)
        if action == ACTION_SCOUT:
            role = movement_mod.ROLE_SCOUT
        goal = [float(position[0]), float(position[1])]
        revision = int((state.get("nav_revision", -1) if state.get("nav_revision")
                        is not None else -1))
        # 【小队语义】每个成员都要有**自己**的合法路线：不许"能走的先走、剩下的留在原地"。
        squad_plans: List[Any] = []
        member_block: Optional[Dict[str, Any]] = None
        for member in units:
            cached = movement_mod.previous_route(state, member)
            reuse = (bool(cached.get("ok"))
                     and not movement_mod.needs_replan(state, member, goal, revision, tick)
                     and len(cached.get("relay_point") or []) >= 2)
            if reuse:
                relay = cached.get("relay_point") or []
                plan = movement_mod.RoutePlan(
                    ok=True, unit=member, squad=list(units),
                    route_id=str(cached.get("route_id", "")),
                    nav_revision=int(cached.get("nav_revision", -1) or -1),
                    relay_point=[float(relay[0]), float(relay[1])])
            elif queries + 1 > movement_mod.NAV_QUERIES_PER_TICK:
                # 配额不够验证**整队** → 本轮不推进（"验了一半就走"比不走更危险）。
                member_block = {"intent_id": str(intent.get("intent_id", "")),
                                "reason": "movement_gated:%s" % movement_mod.REJECT_SQUAD_UNVERIFIED,
                                "unit": member, "squad": list(units)}
                break
            else:
                queries += 1
                plan = movement_mod.plan_safe_route(
                    state, tactical, unit=member, target=goal, tick=tick,
                    nav_query=nav_query, role=role)
                plan.squad = list(units)
                movement_mod.record_route(state, plan)
                if not plan.ok:
                    # 单人意图照旧报它自己的原因（统计口径稳定）；多人才标 `squad_blocked`：
                    # 语义是"**队里有人走不通 → 全队不走**"，而不是这人自己有问题。
                    blocked_reason = (plan.reason if len(units) == 1
                                      else "%s:%s" % (movement_mod.REJECT_SQUAD_BLOCKED,
                                                      plan.reason))
                    member_block = {
                        "intent_id": str(intent.get("intent_id", "")),
                        "reason": "movement_gated:%s" % blocked_reason,
                        "unit": member, "squad": list(units)}
                    if plan.urgent_event:
                        _raise_movement_urgent(state, ctx, plan.urgent_event, member, tick)
                    break
            squad_plans.append(plan)
        if member_block is not None:
            blocked.append(member_block)
            continue
        # 全队只认**一个**中继点 = 各成员中最保守的那一跳；队形散了就先集结。
        positions = {member: movement_mod._pos2d(by_name.get(member) or {}) or []
                     for member in units}
        relay, scatter = movement_mod.squad_hop(squad_plans, positions)
        if scatter:
            blocked.append({"intent_id": str(intent.get("intent_id", "")),
                            "reason": "movement_gated:%s" % scatter,
                            "unit": units[0], "squad": list(units)})
            continue
        target["pos"] = list(relay)
        # 小队路线留痕（供验收读"小队推进"，不占新的状态键：挂在 `routes` 下加前缀）。
        state.setdefault("routes", {})["squad|%s" % "|".join(sorted(units))] = {
            "ok": True, "squad": list(units), "relay_point": list(relay),
            "nav_revision": revision, "last_replan_tick": tick,
            "route_id": str(squad_plans[0].route_id if squad_plans else ""),
            "target": list(goal),
        }
        squad_stats = state.setdefault("movement_stats", {})
        squad_stats["squad_advances"] = int(squad_stats.get("squad_advances", 0)) + 1
        if len(units) > 1:
            squad_stats["squad_multi"] = int(squad_stats.get("squad_multi", 0)) + 1
        kept.append(intent)
    if blocked or queries:
        _decide(state, "movement_gate", tick=tick, planned=queries,
                kept=len(kept), blocked=blocked[:6],
                stats=movement_mod.movement_stats(state))
    return kept, blocked


def node_arbitrate_intent(state: Dict[str, Any], ctx: NodeContext) -> Dict[str, Any]:
    """意图仲裁：校验、去重、TTL 夹紧、批大小截断，并把结果写入状态。"""
    tick = int(state.get("server_tick", 0))
    candidates = list(state.get("candidate_intents") or [])
    state["candidate_intents"] = []
    # 【五条线路账】必须在"本轮无候选"的提前返回**之前**刷新：否则没有新意图的那些轮
    # 会让 `lanes` 停在旧值/空值，验收时"某条线多久没被服务"就看不到（实测踩过）。
    lane_view = lanes_mod.lane_snapshot(
        list(state.get("active_intents") or []), tick=tick,
        last_served=state.get("lanes_last_served") or {},
        # 饿死判据用**本轮候选**（见 `lane_snapshot` 注释：用"活跃意图数"会假报）。
        pending=lanes_mod.count_by_lane(candidates))
    state["lanes"] = {key: value for key, value in lane_view.items() if key != "starved"}
    if lane_view.get("starved"):
        _decide(state, "lane_starved", tick=tick, starved=lane_view["starved"])
    if not candidates:
        return state
    # 【安全移动硬闸门】任何野外移动意图都必须在这里过审：通过 → 目标改写成安全中继点；
    # 不通过 → 直接摘掉（`movement_gated:<reason>`）。这是"没有有效路径的主力移动数 = 0"
    # 的实现位置：仲裁是通往下发的唯一咽喉，绕过它就没有别的路能发出移动命令。
    candidates, _gated = _gate_movement(state, ctx, candidates)
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
        lane_cursor=int(state.get("lane_cursor", 0) or 0),
    )
    # 【五条线路账】（计划 §5）：轮转起点 + 本轮服务到的线路 + 饿死判据。
    # 只在这里写状态（单写者），仲裁层保持纯函数。
    state["lane_cursor"] = int(result.lane_trace.get("next_cursor", 0) or 0)
    served_lanes = lanes_mod.lanes_of(result.accepted)
    state["lanes_last_served"] = lanes_mod.mark_served(
        state.get("lanes_last_served") or {}, served_lanes, tick)
    state["lanes_served_this_tick"] = served_lanes
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
    # 来源可区分（纠偏 §二）：被采纳的命令要能追到"规则跑的 / 行为树跑的 / 模型改的"，
    # 否则"模型增量"与"地板保底"在指标里分不开。
    origin_table = state.get(ORIGIN_KEY) or {}
    origins = {str(item["intent_id"]): str(origin_table.get(str(item["intent_id"]), ""))
               for item in result.accepted}
    state["intent_arbitration"] = {
        "accepted": [item["intent_id"] for item in result.accepted],
        "dropped": dispatched,
        "clamped": [item["intent_id"] for item in result.clamped],
        "origins": origins,
        "origin_counts": {name: sum(1 for value in origins.values() if value == name)
                          for name in sorted(set(origins.values())) if name},
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
        _apply_receipt_to_state(state, intent_id, receipt, ctx)
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
                            receipt: Dict[str, Any],
                            ctx: Optional[NodeContext] = None) -> None:
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
        # `ctx` 是可选入参：脱离图直接调用（单测/离线回放）时没有 NodeContext，
        # 此时落到 `state.decision_log`（runner 的 `_log_decision_delta` 会捞出来），
        # 而不是引用一个不存在的名字把整条回执结算路径打断
        # （2026-09-12 实测：`_log(ctx, …)` 里的 `ctx` 未定义 → 每 tick NameError →
        #  回执永远结算不了 → 任务状态/占用全部停在提交瞬间）。
        if ctx is not None:
            _log(ctx, state, "command_timing", intent_id=intent_id,
                 generated_tick=int(record.get("issued_tick", 0) or 0),
                 received_tick=tick_now, action=str(record.get("action", "")),
                 status=str(status))
        else:
            _decide(state, "command_timing", intent_id=intent_id,
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
    # 拒绝反馈 → **有限类别** → **按类修正维度**（归类入口唯一：`placement`）。
    #
    # 为什么不再"匹配几个字符串就存点"（2026-09-12 同类问题反复换皮的根因）：
    #   - 几何/视野/占用类（`OutOfBounds`/`NotVisible`/`Occupied`）：**换个点就能解决**
    #     → 只拉黑**这个点**（旧实现是全局 `build_backoff`：一个坏点让整局建造停 15 秒，
    #     实测把"改完落点后本该继续发展"的局也一起停住了）；
    #   - 契约/能力类（scene 不对 / 单位没这个能力）：**换点换单位都没用**
    #     → 拉黑**意图前缀**（如 `rule-produce-worker`），从源头停止产出这一类
    #     （否则就是同一条坏命令刷屏 976 次）；
    #   - 过期/代际类：链路问题，由上面的状态机处理，不入账本。
    reason_text = "%s %s" % (status, receipt.get("reason", ""))
    reject_kind = placement.classify_rejection(reason_text)
    tick_now = int(state.get("server_tick", 0) or 0)
    ledger = placement.ledger_from_state(state)
    if reject_kind in placement.GEOMETRY_KINDS:
        pair = placement.plane_point((record.get("target") or {}).get("pos"))
        if pair is not None:
            point = [round(pair[0], 1), round(pair[1], 1)]
            count = ledger.add(reject_kind, placement.spot_key(pair), tick_now)
            # 兼容镜像：诊断与旧调用仍能看到"坏点"（有界，只留最近 8 个）。
            blocked = state.setdefault("blocked_build_spots", [])
            if point not in blocked:
                blocked.append(point)
                del blocked[:-8]
            _decide(state, "spot_rejected", pos=point, kind=reject_kind,
                    status=str(status), count=count,
                    reason=str(receipt.get("reason", ""))[:40])
    elif reject_kind in placement.PREFIX_BAN_KINDS:
        # 含 `REJECT_UNSPECIFIED`（只有 status、没有原因）：链路没给信息时，
        # 重发同一条命令是纯噪音 → 同样按前缀停发（但**不触发全局退避**：
        # 全局冻结留给"确知的内容类错误"，不让一个说不清原因的拒绝停住整局建造）。
        prefix = placement.intent_prefix(record.get("intent_id", ""))
        if prefix:
            count = ledger.add(reject_kind, prefix, tick_now)
            _decide(state, "intent_kind_rejected", intent_prefix=prefix,
                    kind=reject_kind, count=count,
                    reason=str(receipt.get("reason", ""))[:40])
        # 内容类问题会影响所有意图 → 保留**全局退避**这个安全阀
        # （GPT Q6：不得用无限重试掩盖 Rejected）。几何类不走这条路（已按点自愈）。
        streak = int(state.get("build_reject_streak", 0)) + 1
        state["build_reject_streak"] = streak
        if streak >= 3:
            state["build_backoff_until_tick"] = tick_now + 900
            state["build_reject_streak"] = 0
            _decide(state, "build_backoff", until_tick=state["build_backoff_until_tick"])
    placement.ledger_to_state(ledger, state)
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
                _apply_receipt_to_state(state, intent_id, receipt, ctx)
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
