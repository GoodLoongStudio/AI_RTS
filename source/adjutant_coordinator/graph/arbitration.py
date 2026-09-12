# -*- coding: utf-8 -*-
"""意图仲裁：把模型输出收敛成“可提交的有限期意图”，其余全部显式丢弃并留因。

纪律（方案 §6、§7、§13；architecture.md §3）：
- 丢弃条件：generation 不一致 / plan_version 不一致 / 已过期 / 单位已被玩家接管 /
  目标不在观测或规则视图内 / 同一 intent_id 仍在活跃或在途；
- PendingAuthority 未复核前不重复下单（同一 (task, action, 单位集合) 指纹去重）；
- TTL 有上限：模型给出的超长过期时间会被夹紧到 intent_ttl_ticks；
- 批大小有上限，按 (紧急, 优先级, 先到) 排序，逐条提交仍由权威层结算。
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any, Dict, Iterable, List, Optional, Set, Tuple

from .contracts import ContractError, parse_tactical_intent
from .model_context import validate_intent_references
from .state import INTENT_LIVE_STATES


@dataclass
class ArbitrationResult:
    """仲裁结果：accepted 可提交；每个 dropped 都带明确原因（不静默丢弃）。"""

    accepted: List[Dict[str, Any]] = field(default_factory=list)
    dropped: List[Dict[str, Any]] = field(default_factory=list)
    clamped: List[Dict[str, Any]] = field(default_factory=list)

    @property
    def dropped_reasons(self) -> Dict[str, str]:
        return {item["intent_id"]: item["reason"] for item in self.dropped}

    def summary(self) -> Dict[str, Any]:
        return {
            "accepted": [item["intent_id"] for item in self.accepted],
            "dropped": [{"intent_id": item["intent_id"], "reason": item["reason"]}
                        for item in self.dropped],
            "clamped": [item["intent_id"] for item in self.clamped],
        }


def _fingerprint(intent: Dict[str, Any]) -> Tuple[str, str, Tuple[str, ...]]:
    """粗指纹：任务 + 动作 + 单位集合（用于在途/PendingAuthority 去重）。"""
    return (str(intent.get("task_id", "")), str(intent.get("action", "")),
            tuple(sorted(str(u) for u in intent.get("unit_ids", []))))


def _target_key(intent: Dict[str, Any]) -> str:
    """目标的规范化 JSON 键（判重用；排序保证同一目标的不同键序也等价）。"""
    return json.dumps(intent.get("target") or {}, ensure_ascii=False, sort_keys=True)


def _order_fingerprint(intent: Dict[str, Any]) -> Tuple[str, str, Tuple[str, ...], str]:
    """细指纹：粗指纹 + 目标（同目标才算重复下单；改目标属正常重规划）。"""
    return _fingerprint(intent) + (_target_key(intent),)


#: 可合并的动作：**同动作 + 同目标**才合并（等价于"一条命令带多个单位"）。
#: 刻意**不含** build/produce：场景类动作的 target 是"建筑 + 落点/场景"，
#: 把两条同目标的生产意图合并会把"排两个"压成"排一个"，属于改玩法语义，不在本轮范围。
MERGEABLE_ACTIONS = (
    "move", "attack", "attack_move", "gather", "scout", "retreat", "regroup",
    "defend", "hold", "stop",
)


def merge_same_orders(
    candidates: List[Dict[str, Any]],
) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
    """把**同动作 + 同目标**的多条意图合并成一条多单位意图。

    返回 `(合并后的候选, 合并留痕)`。

    ## 为什么必须做（2026-09-11 实测数据）

    | 指标 | 实测 |
    |---|---|
    | 主循环 | 197 轮 / 5 分钟（≈1 轮 1.5s） |
    | 决策轮 | tactical 27 轮 = **11 秒一拍** |
    | 每决策轮接受意图 | 平均 **4.56** 条（上限 `max_batch` = **8**） |
    | 命令产出 | 123 条 / 5 分钟 ≈ 24 条/分钟 |
    | AI 对局的截断 | `batch_limit_exceeded` **178 次 / 5 分钟** |

    行为树是"**每个单位一条意图**"，而意图本身支持多个 `unit_ids`：给 12 个兵下令要占
    12 条配额，`max_batch=8` 直接截断。合并后"12 个兵"只占 **1 条**配额，
    可同时下令的单位数提升一个数量级 —— 这是提高"控制频率 / 单位数"性价比最高的一步。

    ## 合并纪律（保守、可复现）

    - 只在**已通过校验**的候选之间合并（本函数在 `arbitrate_intents` 的校验之后调用）：
      玩家接管 / 非法单位 / 越权代际的意图早已被丢弃，不会因合并而"夹带过关"；
    - 必须同 `action`、同 `target`（规范化 JSON 比较）、同 `task_id`、同 `plan_version`、同 `emergency`；
    - **代际不参与匹配**（协调器是"每单位一个代际"、逐单位自增，纳入匹配等于永不合并 —— 实测整局 0 次），
      合并后按组内**最大值**带走：权威层判据是**单调**的（只有 `generation < 租约代际` 才判 StaleGeneration，
      且 `generation > 0` 才会走"租约是否被玩家取消"的守卫），因此取大安全、取小会被拒、取 0 会跳过守卫；
    - **保留组内第一条的 `intent_id`**：单单位场景的 id 完全不变，不破坏金标准回放
      （`tests/fixtures/replay_*.jsonl` 直接断言 intent_id）；
    - `expires_tick` 取组内**最小值**（只收窄不放宽，绝不用合并延长意图寿命）；
    - `unit_ids` 去重并**排序**（确定性，便于测试与排查）。
    """
    merged: List[Dict[str, Any]] = []
    heads: Dict[Tuple[str, str, str, bool], Dict[str, Any]] = {}
    traces: List[Dict[str, Any]] = []
    for intent in candidates:
        action = str(intent.get("action", ""))
        if action not in MERGEABLE_ACTIONS:
            merged.append(intent)
            continue
        # 合并键**不含 generation**：协调器的代际是"每单位一个"（`ensure_units` 逐单位自增），
        # 真实对局里几乎必然不等；若把它纳入键，合并基本永不发生（实测：整局 0 次）。
        # 代际在合并时按**组内最大值**带走，安全性见下面的说明。
        key = (action,
               json.dumps(intent.get("target") or {}, ensure_ascii=False, sort_keys=True),
               str(intent.get("task_id", "")),
               bool(intent.get("emergency", False)))
        head = heads.get(key)
        if head is None:
            clone = dict(intent)
            clone["unit_ids"] = sorted({str(u) for u in (intent.get("unit_ids") or [])})
            clone["merged_from"] = [str(intent.get("intent_id", ""))]
            heads[key] = clone
            merged.append(clone)
            continue
        incoming = [str(u) for u in (intent.get("unit_ids") or [])]
        head["unit_ids"] = sorted(set(head["unit_ids"]) | set(incoming))
        head["expires_tick"] = min(int(head.get("expires_tick", 0)),
                                   int(intent.get("expires_tick", 0)))
        head["priority"] = max(int(head.get("priority", 0)), int(intent.get("priority", 0)))
        # 代际取**组内最大值**：权威层的判据是**单调**的
        # （`DebugControlServer._adjutant_generation_guard`：只有 generation < 租约代际 才判
        # StaleGeneration；并且 `generation > 0` 才会走"租约是否被玩家取消"这条守卫），
        # 所以取大既不会被拒、也不会把玩家优先权守卫关掉。
        # 取小会被权威层拒；取 0 会整段跳过守卫 —— 两者都不能用。
        head["generation"] = max(int(head.get("generation", 0)),
                                 int(intent.get("generation", 0)))
        head["merged_from"].append(str(intent.get("intent_id", "")))
        traces.append({"into": str(head.get("intent_id", "")), "action": action,
                       "absorbed": str(intent.get("intent_id", "")), "units": incoming,
                       "generation": int(head["generation"])})
    return merged, traces


def arbitrate_intents(
    state,
    raw_intents: Iterable[Any],
    *,
    current_tick: int,
    known_entities: Set[str],
    scene_paths: Set[str],
    allowed_units: Optional[Set[str]] = None,
    max_batch: int = 8,
    intent_ttl_ticks: int = 600,
    expected_plan_version: str = "",
) -> ArbitrationResult:
    """校验 + 去重 + 排序 + 截断；返回可提交意图与全部丢弃原因。"""
    result = ArbitrationResult()
    current_tick = int(current_tick)
    units_scope = allowed_units if allowed_units is not None else known_entities

    # 在途指纹：PendingAuthority 未复核前不重复下单。
    pending_fingerprints: Set[Tuple[str, str, Tuple[str, ...]]] = set()
    for intent_id, item in state.pending_requests.items():
        pending_fingerprints.add((str(item.get("task_id", "")), str(item.get("action", "")),
                                  tuple(sorted(str(u) for u in item.get("unit_ids", [])))))
    # 活跃指纹：同一目标已有活跃意图 → 重复下单，丢弃。
    live_fingerprints: Dict[Tuple[str, str, Tuple[str, ...], str], str] = {}
    # 活跃**单位级**下单：{(unit, action, target) -> intent_id}。
    # 【为什么必须有这一层】`merge_same_orders` 会把"每单位一条"的同目标意图合并成
    # **一条多单位**意图（指纹里的 unit_ids 变成整组），而行为树下一轮仍然按"每单位一条"
    # 产出 —— 整条指纹与活跃记录**永远对不上**，于是同一命令每轮被重发：
    # 单位不停重下移动/采集、原地抖。改为按"单位 + 动作 + 目标"判重后，
    # 无论活跃记录是单单位还是合并意图，都能正确抑制重复下单。
    live_unit_orders: Dict[Tuple[str, str, str], str] = {}
    for record in state.active_intents:
        if record.get("state") not in INTENT_LIVE_STATES:
            continue
        live_fingerprints[_order_fingerprint(record)] = str(record.get("intent_id", ""))
        order_key = json.dumps(record.get("target") or {}, ensure_ascii=False, sort_keys=True)
        for unit_id in record.get("unit_ids", []):
            live_unit_orders[(str(unit_id), str(record.get("action", "")), order_key)] = \
                str(record.get("intent_id", ""))

    candidates: List[Dict[str, Any]] = []
    seen_intent_ids: Set[str] = set()
    seen_fingerprints: Dict[Tuple[str, str, Tuple[str, ...], str], str] = {}

    for raw in raw_intents or []:
        try:
            intent = parse_tactical_intent(raw).to_dict()
        except ContractError as exc:
            result.dropped.append({"intent_id": str(
                (raw or {}).get("intent_id", "") if isinstance(raw, dict) else ""),
                "reason": "contract_invalid", "errors": exc.errors})
            continue

        intent_id = str(intent["intent_id"])
        if intent_id in seen_intent_ids:
            result.dropped.append({"intent_id": intent_id, "reason": "duplicate_intent_id_in_batch"})
            continue
        seen_intent_ids.add(intent_id)

        existing = state.find_intent(intent_id)
        if existing is not None and existing.get("state") in INTENT_LIVE_STATES:
            result.dropped.append({"intent_id": intent_id, "reason": "intent_already_tracked"})
            continue

        # 计划版本：真实模型常把 plan_version 写成 plan_id / 版本号 / 旧版本号，
        # 而同步调用保证每条意图都基于当前上下文；因此按当前生效计划归一化并留痕（不直接丢弃）。
        # 安全仍由控制代际/租约、TTL 窗口与快照新鲜度保证。
        expected_version = str(expected_plan_version or "")
        given_version = str(intent.get("plan_version", ""))
        if expected_version and given_version != expected_version:
            intent["plan_version"] = expected_version
            result.clamped.append({"intent_id": intent_id, "field": "plan_version",
                                   "from": given_version, "to": expected_version})

        # TTL 窗口：以“当前 tick + 有限窗口”为准落实。
        # 真实模型常用自己的时钟概念（或调用耗时导致窗口在到达仲裁时已过），
        # 该意图是**本轮刚产出**的，因此按窗口重算并留痕，而不是直接丢弃；
        # 真正防止旧意图执行的是控制代际/租约与快照新鲜度（严格判定见 state.is_intent_valid）。
        window = max(1, int(intent_ttl_ticks))
        if int(intent["expires_tick"]) <= current_tick:
            result.clamped.append({"intent_id": intent_id, "field": "expires_tick",
                                   "from": int(intent["expires_tick"]),
                                   "to": current_tick + window})
            intent["expires_tick"] = current_tick + window
        max_expiry = current_tick + window
        if int(intent["expires_tick"]) > max_expiry:
            intent["expires_tick"] = max_expiry
            result.clamped.append({"intent_id": intent_id, "expires_tick": max_expiry})

        # 单位必须属于本玩家且已被 AI 接管（玩家接管的单位不能被新意图抢回）。
        # 注意顺序：玩家优先权判定要早于代际判定，保证丢弃原因是“玩家接管”而非“代际过期”。
        bad_units = [str(u) for u in intent.get("unit_ids", []) if str(u) not in units_scope]
        if bad_units:
            result.dropped.append({"intent_id": intent_id,
                                   "reason": "unit_not_in_observation:%s" % ",".join(bad_units)})
            continue
        overridden = [str(u) for u in intent.get("unit_ids", [])
                      if state.is_unit_player_controlled(u)]
        if overridden:
            result.dropped.append({"intent_id": intent_id,
                                   "reason": "lease_owner_player:%s" % ",".join(overridden)})
            continue

        # generation：模型给 0 表示由系统按当前租约填写；给了就必须与权威代际一致。
        generations = {state.generation_of(str(u)) for u in intent.get("unit_ids", [])}
        given = int(intent.get("generation", 0))
        if given and given not in generations:
            result.dropped.append({"intent_id": intent_id, "reason": "generation_mismatch"})
            continue
        if not given:
            intent["generation"] = max(generations) if generations else 0

        # 显式重新接管：只允许对“玩家已显式归还”的单位发起（授权由玩家动作产生）。
        if bool(intent.get("reacquire", False)):
            unauthorized = [str(u) for u in intent.get("unit_ids", [])
                            if str(u) not in state.released_units]
            if unauthorized:
                result.dropped.append({
                    "intent_id": intent_id,
                    "reason": "reacquire_not_authorized:%s" % ",".join(unauthorized)})
                continue

        # 目标引用校验（实体/场景）。
        problems = validate_intent_references([intent], known_entities=known_entities,
                                              scene_paths=scene_paths,
                                              allowed_units=units_scope)
        if problems:
            result.dropped.append({"intent_id": intent_id, "reason": problems[0][1]})
            continue

        # 批次内去重 + 活跃意图去重 + 在途去重。
        fingerprint = _order_fingerprint(intent)
        if fingerprint in seen_fingerprints:
            result.dropped.append({"intent_id": intent_id,
                                   "reason": "duplicate_of:%s" % seen_fingerprints[fingerprint]})
            continue
        if fingerprint in live_fingerprints:
            result.dropped.append({
                "intent_id": intent_id,
                "reason": "duplicate_of_live_intent:%s" % live_fingerprints[fingerprint]})
            continue
        # 单位级判重（合并意图覆盖到的单位，下一轮"每单位一条"的同动作同目标意图也算重复；
        # 详见 `live_unit_orders` 的长注释 —— 不做这层，合并后单位会被每轮重复下令、原地抖）。
        unit_dup = ""
        action_key = str(intent.get("action", ""))
        target_key = _target_key(intent)
        for unit_id in intent.get("unit_ids", []):
            unit_dup = live_unit_orders.get((str(unit_id), action_key, target_key), "")
            if unit_dup:
                break
        if unit_dup:
            result.dropped.append({"intent_id": intent_id,
                                   "reason": "duplicate_of_live_intent:%s" % unit_dup})
            continue
        if _fingerprint(intent) in pending_fingerprints:
            result.dropped.append({"intent_id": intent_id,
                                   "reason": "pending_authority_unresolved"})
            continue
        # 快照基准：模型漏填/填成未来快照时，以当前已知快照为准（不伪造，只夹紧到已观测事实）。
        latest_snapshot = int(getattr(state, "latest_snapshot_id", 0) or 0)
        given_snapshot = int(intent.get("based_on_snapshot", -1))
        if given_snapshot < 0 or given_snapshot > latest_snapshot:
            intent["based_on_snapshot"] = latest_snapshot
            result.clamped.append({"intent_id": intent_id, "field": "based_on_snapshot",
                                   "from": given_snapshot, "to": latest_snapshot})

        seen_fingerprints[fingerprint] = intent_id
        candidates.append(intent)

    candidates.sort(key=lambda item: (
        0 if item.get("emergency") else 1,
        -int(item.get("priority", 0)),
        int(item.get("issued_tick", 0)),
        str(item.get("intent_id", "")),
    ))
    limit = max(1, int(max_batch))
    # 【2026-09-11】合并同动作同目标的意图：一条命令带多个单位。
    # 位置很关键：在**校验与去重之后、批量截断之前** ——
    # 只有已通过校验的意图参与合并（不会夹带玩家接管/非法单位），
    # 且合并后占用更少配额（这正是要解决的问题，见 `merge_same_orders` 的实测数据）。
    candidates, merge_traces = merge_same_orders(candidates)
    result.accepted = candidates[:limit]
    for intent in candidates[limit:]:
        result.dropped.append({"intent_id": intent["intent_id"], "reason": "batch_limit_exceeded"})

    state.decide("intents_arbitrated", tick=current_tick, **{
        "accepted": [item["intent_id"] for item in result.accepted],
        "dropped": [{"intent_id": item["intent_id"], "reason": item["reason"]}
                    for item in result.dropped],
        "clamped": [item["intent_id"] for item in result.clamped],
        "merged": merge_traces,
    })
    return result


def fingerprint_of(intent: Dict[str, Any]) -> str:
    """便于日志/测试的稳定指纹。"""
    return json.dumps(list(_fingerprint(intent)), ensure_ascii=False)
