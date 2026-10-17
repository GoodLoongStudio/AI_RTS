# -*- coding: utf-8 -*-
"""收缩战略模型职责的三个候选 provider（计划 §3 的 B / C / D）。

背景（2026-10-13 本轮实测）：完整战略接口让本机 2B 自由生成整份
`StrategicPlan`（嵌套 tasks、元数据全填），单次 6~11s，1280 token 预算下
多次因接近上限/超时失败；即使解析成功，也大量以 `maintain_current`
或 `control_generation` 陈旧被拒（实测一局 10 次请求、采纳 0）。

本模块把"战略决策"压缩成一次**极小的选择**：
- `TemplateStrategy`（B）：模型只回 `{"template":..}`；
- `ChoiceStrategy`（C）：程序先给出 ≤4 个已检查授权/能力前提的计划草案 + KEEP，
  模型只回 `{"choice":"C2"}`；
- `ScoringStrategy`（D）：程序按可解释评分直接选，只在歧义时才问模型；
  `ScoringOnlyStrategy` 是不调用模型的 D0 消融。

三条不变式（不许为了"跑通"破坏）：
1. **合法计划一律由程序生成**：模型永远拿不到单位 ID / 坐标 / 预算的写权限；
   模板与选项都来自当次给定的枚举，越界即回退到规则主线。
2. **不新增权威协议**：仍然返回既有 `StrategicPlan`，采纳/执行链一行不改。
3. **旧计划合法时保持**：选项 `KEEP` 只在确有 active_plan 时出现。
"""
from __future__ import annotations

import hashlib
import json
import time
import threading
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Sequence, Tuple

from .contracts import ContractError, PlanTask, StrategicPlan, parse_strategic_plan

#: 计划身份前缀（与规则主线的 `rules-*` 区分，便于版本历史与面板诊断）。
VARIANT_PLAN_PREFIX = "strat"

#: 模板词表（计划 §3.B 的初始六项）。
TEMPLATES: Tuple[str, ...] = ("economy", "recon", "defend", "prepare_attack",
                              "attack", "expand")

#: 模板 → 允许的 focus 枚举（模型只能从这里选）。
TEMPLATE_FOCUS: Dict[str, Tuple[str, ...]] = {
    "economy": ("gather", "worker", "refinery"),
    "recon": ("near", "far"),
    "defend": ("base", "worker"),
    "prepare_attack": ("rally_base", "rally_front"),
    "attack": ("known_enemy", "enemy_base"),
    "expand": ("near_ore", "far_ore"),
}

#: 模板 → 候选 ID（供 B 复用 C 的候选表，保证两条路生成同一份合法计划）。
TEMPLATE_TO_CANDIDATE: Dict[str, str] = {
    "economy": "C-ECO",
    "recon": "C-RECON",
    "defend": "C-DEFEND",
    "prepare_attack": "C-ASSAULT",
    "attack": "C-ATTACK",
    "expand": "C-EXPAND",
}


# --------------------------------------------------------------------- 事实与候选


@dataclass
class Facts:
    """从**当次权威上下文**提取的全局事实（只读，不新增扫描）。"""

    tick: int = 0
    snapshot: int = 0
    units: List[str] = field(default_factory=list)
    workers: List[str] = field(default_factory=list)
    builders: List[str] = field(default_factory=list)
    scouts: List[str] = field(default_factory=list)
    military: List[str] = field(default_factory=list)
    producers: Dict[str, str] = field(default_factory=dict)   # 生产者 id -> 类型
    enemy_intel: List[Any] = field(default_factory=list)
    base_threat: bool = False
    expansion: List[Any] = field(default_factory=list)
    routes: List[str] = field(default_factory=list)
    route_names: Dict[str, str] = field(default_factory=dict)
    frontier: str = ""
    phase: str = ""
    workers_total: int = 0
    refinery_built: int = 0
    refinery_delivered: int = 0
    has_active_plan: bool = False
    active_plan_id: str = ""
    active_plan_version: int = 0
    available_actions: List[str] = field(default_factory=list)
    unit_info: Dict[str, Dict[str, Any]] = field(default_factory=dict)
    worker_producers: List[str] = field(default_factory=list)
    worker_cost: Dict[str, int] = field(default_factory=dict)
    refinery_cost: Dict[str, int] = field(default_factory=dict)
    refinery_progress_source: str = "worker"
    budget: Dict[str, int] = field(default_factory=dict)
    resource_count: int = 0
    refinery_buildable: bool = False
    refinery_carriers: List[str] = field(default_factory=list)
    coverage: Dict[str, Any] = field(default_factory=dict)

    def spare_units(self) -> List[str]:
        """未被经济/侦察占用的可用单位（作战单位优先）。"""
        busy = set(self.workers) | set(self.builders) | set(self.scouts)
        spare = [u for u in self.units if u not in busy
                 and bool(self.unit_info.get(u, {}).get("movement"))]
        return spare

    def recon_units(self, limit: int = 2) -> List[str]:
        # Recon must not silently take the army when a scout track is stale.
        return self.scouts[:max(0, limit)]

    def combat_units(self) -> List[str]:
        return [u for u in self.units if self.unit_info.get(u, {}).get("combat")
                and self.unit_info.get(u, {}).get("movement")
                and u not in self.workers and u not in self.builders and u not in self.scouts]


def _as_list(value: Any) -> List[Any]:
    return list(value) if isinstance(value, (list, tuple)) else []


def _nonnegative_int(value: Any) -> int:
    try:
        return max(0, int(value or 0))
    except (TypeError, ValueError, OverflowError):
        return 0


def _alive(info: Dict[str, Any]) -> bool:
    if info.get("confirmed_dead"):
        return False
    if info.get("hp") is None:
        return True
    try:
        return float(info["hp"]) > 0
    except (TypeError, ValueError, OverflowError):
        return False


def _tracks(campaign: Dict[str, Any]) -> Dict[str, Any]:
    tracks = campaign.get("tracks")
    return tracks if isinstance(tracks, dict) else {}


def _track_units(campaign: Dict[str, Any], key: str) -> List[str]:
    entry = _tracks(campaign).get(key)
    if not isinstance(entry, dict):
        return []
    return [str(u) for u in (entry.get("units") or [])]


def build_facts(context: Dict[str, Any]) -> Facts:
    data = context if isinstance(context, dict) else {}
    campaign = data.get("campaign") if isinstance(data.get("campaign"), dict) else {}
    summary = data.get("strategic_summary") if isinstance(data.get("strategic_summary"), dict) else {}
    economy = campaign.get("economy") if isinstance(campaign.get("economy"), dict) else {}
    facts = Facts(
        tick=int(data.get("server_tick") or 0),
        snapshot=int(data.get("snapshot_id") or 0),
        units=[str(u) for u in (data.get("ai_controlled_units") or [])],
        workers=_track_units(campaign, "economy"),
        builders=_track_units(campaign, "build"),
        scouts=_track_units(campaign, "scout"),
        military=_track_units(campaign, "military"),
        enemy_intel=_as_list(summary.get("enemy_intel")),
        expansion=_as_list(campaign.get("expansion_candidates")),
        routes=[str(r) for r in (campaign.get("available_routes") or [])],
        route_names={str(k): str(v) for k, v in (campaign.get("available_route_names") or {}).items()},
        frontier=str(campaign.get("frontier_name") or campaign.get("frontier") or ""),
        phase=str(campaign.get("phase") or ""),
        workers_total=int(economy.get("workers") or 0),
        refinery_built=int(economy.get("refinery_constructed") or 0),
        refinery_delivered=int(economy.get("refinery_delivered") or 0),
        available_actions=[str(a) for a in (summary.get("available_actions") or [])],
    )
    for entry in _as_list(summary.get("production")):
        if not isinstance(entry, dict):
            continue
        producer = str(entry.get("producer") or "")
        ptype = str(entry.get("producer_type") or "")
        if producer:
            facts.producers[producer] = ptype
    # Campaign tracks describe intent, not capabilities or current permission.
    authorized = set(facts.units) - set(str(u) for u in _as_list(data.get("player_controlled_units")))
    table = data.get("unit_facts") if isinstance(data.get("unit_facts"), dict) else {}
    facts.unit_info = {str(name): dict(info) for name, info in table.items()
                       if str(name) in authorized and isinstance(info, dict)
                       and _alive(info)
                       and info.get("constructed") is not False}
    facts.units = [u for u in facts.units if u in facts.unit_info]
    facts.workers = [u for u in facts.units if facts.unit_info[u].get("gather")]
    # 建造者是执行层的硬能力：必须仍由 AI 控制、存活且明确报告
    # construct=true。移动工人没有 constructed 字段是正常情况；若单位明确
    # 报告 constructed=false，上面的 unit_info 过滤已将其排除。
    facts.builders = [u for u in facts.units if facts.unit_info[u].get("construct")]
    facts.scouts = [u for u in facts.units if facts.unit_info[u].get("movement")
                    and not facts.unit_info[u].get("combat")
                    and u not in facts.workers and u not in facts.builders]
    facts.military = [u for u in facts.military if u in facts.units and facts.unit_info[u].get("combat")]
    facts.producers = {u: kind for u, kind in facts.producers.items()
                       if u in facts.unit_info and facts.unit_info[u].get("queue")
                       and facts.unit_info[u].get("constructed") is True}
    facts.coverage = dict(data.get("unit_facts_coverage") or {})
    facts.resource_count = _nonnegative_int(data.get("resource_count"))
    raw_budget = data.get("budget")
    if isinstance(raw_budget, dict):
        facts.budget = {str(k).upper(): _nonnegative_int(v) for k, v in raw_budget.items()}
    relations = _as_list(data.get("strategy_productions") or summary.get("production_relations"))
    worker = next((r for r in relations if isinstance(r, dict)
                   and r.get("product_type_id") == "worker"), None)
    if worker is not None:
        facts.worker_cost = _cost(worker.get("cost"))
        allowed = set(str(t) for t in (worker.get("allowed_producer_type_ids") or []))
        idle = {str(r.get("producer")) for r in _as_list(summary.get("production"))
                if isinstance(r, dict) and r.get("queue_size") == 0}
        facts.worker_producers = [u for u, kind in facts.producers.items()
                                  if kind in allowed and u in idle]
    builds = _as_list(data.get("strategy_buildables") or summary.get("buildable"))
    refinery = next((r for r in builds if isinstance(r, dict) and r.get("id") == "ore_refinery"), None)
    if refinery is not None:
        facts.refinery_cost = _cost(refinery.get("cost"))
        facts.refinery_progress_source = str(refinery.get("construction_progress_source") or "worker")
        facts.refinery_carriers = _build_carriers(facts, facts.refinery_progress_source)
        facts.refinery_buildable = bool(facts.refinery_cost and facts.refinery_carriers)
    for item in _as_list(campaign.get("interrupts")):
        kind = ""
        if isinstance(item, dict):
            kind = str(item.get("kind") or "")
        elif isinstance(item, str):
            kind = item
        if "attack" in kind or "under_attack" in kind or "threat" in kind:
            facts.base_threat = True
    facts.enemy_intel = [item for item in facts.enemy_intel
                         if isinstance(item, dict) and not item.get("confirmed_dead")
                         and isinstance(item.get("pos"), (list, tuple)) and len(item["pos"]) >= 3]
    current = data.get("current_plan")
    facts.has_active_plan = _current_plan_valid(current, data, facts)
    if facts.has_active_plan:
        facts.active_plan_id = str(current["plan_id"])
        facts.active_plan_version = int(current["plan_version"])
    return facts


def _cost(raw: Any) -> Dict[str, int]:
    costs: Dict[str, int] = {}
    for entry in _as_list(raw):
        if isinstance(entry, dict) and entry.get("kind"):
            kind = str(entry["kind"]).upper()
            amount = _nonnegative_int(entry.get("amount"))
            if not amount:
                return {}  # An unknown/invalid price must never look free.
            costs[kind] = costs.get(kind, 0) + amount
    return costs


def _affordable(cost: Dict[str, int], budget: Dict[str, int]) -> bool:
    return bool(cost) and all(kind in budget and budget[kind] >= value for kind, value in cost.items())


def _build_carriers(facts: Facts, source: str) -> List[str]:
    if source == "worker":
        return list(facts.builders)
    if source not in ("automatic", "hybrid"):
        return []
    # A completed authorized HQ can carry automatic placement without taking
    # a gathering unit off its task. No arbitrary first-unit substitution.
    headquarters = [u for u in facts.units
                    if facts.unit_info[u].get("type") == "command_center"
                    and facts.unit_info[u].get("constructed") is True]
    return headquarters + [u for u in facts.builders if u not in headquarters]


def _current_plan_valid(current: Any, context: Dict[str, Any], facts: Facts) -> bool:
    if not isinstance(current, dict) or not facts.units:
        return False
    try:
        plan = parse_strategic_plan(current)
    except (ContractError, TypeError, ValueError):
        return False
    if plan.maintain_current or plan.valid_until_tick <= facts.tick or plan.based_on_snapshot > facts.snapshot:
        return False
    if any(str(getattr(plan, k)) != str(context.get(k) or "")
           for k in ("match_id", "player_id", "rules_version")):
        return False
    summary = context.get("strategic_summary") or {}
    relations = _as_list(context.get("strategy_productions") or summary.get("production_relations"))
    producer_types = {str(row.get("product_type_id")): set(_as_list(row.get("allowed_producer_type_ids")))
                      for row in relations if isinstance(row, dict)}
    builds = _as_list(context.get("strategy_buildables") or summary.get("buildable"))
    build_sources = {str(row.get("id")): str(row.get("construction_progress_source") or "worker")
                     for row in builds if isinstance(row, dict)}
    for task in plan.tasks:
        if "build" in task.allowed_actions and (not task.units or task.target_type not in build_sources):
            return False
        if any(u not in facts.unit_info for u in task.units):
            return False
        for u in task.units:
            info = facts.unit_info[u]
            for action in task.allowed_actions:
                if action in ("move", "scout", "regroup", "retreat", "attack_move") and not info.get("movement"):
                    return False
                if action in ("attack", "attack_move", "defend") and not info.get("combat"):
                    return False
                if action == "gather" and not info.get("gather"):
                    return False
                if action == "build" and u not in _build_carriers(facts, build_sources[task.target_type]):
                    return False
                if action == "produce" and u not in facts.producers:
                    return False
                if action == "produce" and facts.producers[u] not in producer_types.get(task.target_type, set()):
                    return False
        if task.target_type == "enemy_position" and not facts.enemy_intel:
            return False
    return True


@dataclass
class Candidate:
    """符合已知能力、授权和预算前提的计划草案；执行时仍需权威校验。"""

    candidate_id: str
    name: str
    summary: str
    tasks: List[Dict[str, Any]]
    route: str = ""
    cost: str = ""
    risk: str = ""
    maintain_current: bool = False
    score_notes: Dict[str, int] = field(default_factory=dict)

    def to_public(self) -> Dict[str, Any]:
        return {"id": self.candidate_id, "name": self.name, "summary": self.summary,
                "route": self.route, "cost": self.cost, "risk": self.risk}


def _task(task_id: str, priority: int, completion: str, units: Sequence[str],
          actions: Sequence[str], target_type: str = "",
          unit_constraint: str = "") -> Dict[str, Any]:
    return {"task_id": task_id, "priority": int(priority), "completion": completion,
            "units": [str(u) for u in units], "unit_constraint": unit_constraint,
            "target_type": target_type, "allowed_actions": [str(a) for a in actions]}


def generate_candidates(context: Dict[str, Any]) -> Tuple[List[Candidate], Facts]:
    """生成 ≤4 个合法候选 + KEEP（KEEP 仅在确有 active_plan 时出现）。"""
    facts = build_facts(context)
    workers = facts.workers
    candidates: List[Candidate] = []

    # KEEP：只有确有可维持的计划时才合法。
    if facts.has_active_plan:
        candidates.append(Candidate(
            candidate_id="KEEP", name="维持现计划",
            summary="保持当前计划与在途任务不变（%s）" % facts.active_plan_id,
            tasks=[], maintain_current=True, risk="局面已变化时可能错过窗口",
            score_notes={"keep": 1}))

    # 经济：采集 + 补工人。
    if workers or facts.worker_producers or facts.refinery_buildable:
        tasks = []
        remaining = dict(facts.budget)
        if workers and facts.resource_count:
            tasks.append(_task("strat-economy", 10, "授权矿车持续采集并向完工矿场交付",
                               workers, ["gather"]))
        if facts.refinery_built == 0 and facts.refinery_buildable and _affordable(facts.refinery_cost, remaining):
            build_units = facts.refinery_carriers[:1]
            tasks.append(_task("strat-build-refinery", 10, "先建成矿场，接通矿车交付链",
                               build_units, ["build"], target_type="ore_refinery"))
            for kind, amount in facts.refinery_cost.items():
                remaining[kind] -= amount
        if max(facts.workers_total, len(workers)) < 6 and facts.worker_producers and _affordable(facts.worker_cost, remaining):
            tasks.append(_task("strat-production", 9, "授权且已完工的车厂按真实产线补矿车，最多 6 名",
                               facts.worker_producers[:1], ["produce"], target_type="worker"))
        if tasks:
            candidates.append(Candidate(
                candidate_id="C-ECO", name="经济优先",
                summary="维持采集、接通矿场，按合法产线补矿车（当前 %d）" % max(facts.workers_total, len(workers)),
                tasks=tasks, route="D1", cost="使用经济预算与可用生产队列",
                risk="军备延后", score_notes={"economy": 2}))

    # 侦察：少量单位探路。
    recon = facts.recon_units(2)
    if recon:
        candidates.append(Candidate(
            candidate_id="C-RECON", name="有限侦察",
            summary="派出 %d 个侦察单位做定点侦察，不调用主力" % len(recon),
            tasks=[_task("strat-recon", 3, "至少获得一处新敌情或确认无敌人",
                         recon, ["scout"])],
            route="D6", cost="侦察单位脱离基地支援",
            risk="小股侦察可能被歼", score_notes={"intel": 2}))

    # 防守：主力收拢守基地。
    combat = facts.combat_units()
    if combat:
        candidates.append(Candidate(
            candidate_id="C-DEFEND", name="基地防守",
            summary="%d 个作战单位回到基地外围布防，工人不停工" % len(combat),
            tasks=[_task("strat-defense", 8, "基地与工人未受损，来袭单位被拦下",
                         combat, ["defend", "hold"])],
            route="D10", cost="主力回撤，前线压力下降",
            risk="放弃既有推进", score_notes={"defense": 2}))

    # 备战/进攻：必须有作战单位；进攻另需已确认敌情。
    if combat:
        candidates.append(Candidate(
            candidate_id="C-ASSAULT", name="集结备战",
            summary="%d 个作战单位在基地外围集结待命，等确认敌情再推进" % len(combat),
            tasks=[_task("strat-assault", 6, "作战单位完成集结，保持队形",
                         combat, ["regroup", "move"])],
            route="D11", cost="部队离开生产点附近",
            risk="可能被各个击破", score_notes={"assemble": 2}))
        if facts.enemy_intel:
            candidates.append(Candidate(
                candidate_id="C-ATTACK", name="按已确认敌情进攻",
                summary="%d 个作战单位向已确认敌情位置推进（情报 %d 条）"
                        % (len(combat), len(facts.enemy_intel)),
                tasks=[_task("strat-attack", 5, "确认敌情位置的实际目标被击毁或掉血",
                             combat, ["attack_move", "attack"],
                             target_type="enemy_position")],
                route="D12", cost="主力进入敌方火力范围",
                risk="情报过期会扑空", score_notes={"attack": 3}))

    # 扩张：有可扩展矿点且至少有一名工人。
    if facts.expansion and facts.refinery_buildable and "D3" in facts.routes and _affordable(facts.refinery_cost, facts.budget):
        candidates.append(Candidate(
            candidate_id="C-EXPAND", name="扩张分矿",
            summary="用有建造能力的授权实体在已确认分矿候选处建矿场（%d 处）" % len(facts.expansion),
            tasks=[_task("strat-expand", 4, "已确认分矿位置的矿场完工后接通交付",
                         facts.refinery_carriers[:1], ["build"], target_type="ore_refinery")],
            route="D3", cost="矿场建造预算",
            risk="分矿可能受袭；最终落点仍须执行层校验", score_notes={"expand": 2}))

    # 程序只保留最多 4 个（按 score_notes 与局面优先级排序），KEEP 永远保留。
    keep = [c for c in candidates if c.maintain_current]
    rest = [c for c in candidates if not c.maintain_current]
    def rank(item: Candidate) -> Tuple[int, str]:
        weight, _ = score_candidate(item, facts)
        return (-weight, item.candidate_id)

    rest.sort(key=rank)
    return keep + rest[:4], facts


def candidate_by_id(candidates: Sequence[Candidate], candidate_id: str) -> Optional[Candidate]:
    for item in candidates:
        if item.candidate_id == str(candidate_id):
            return item
    return None


# --------------------------------------------------------------------- 程序评分（D）


def score_candidate(item: Candidate, facts: Facts) -> Tuple[int, Dict[str, int]]:
    """可解释评分：每项贡献单独列出，便于审计"为什么选它"。"""
    parts: Dict[str, int] = {}
    if item.maintain_current:
        parts["keep:计划仍合法"] = 5
        if facts.base_threat:
            parts["keep:基地受袭时不宜维持"] = -20
        return sum(parts.values()), parts
    if "economy" in item.score_notes:
        gap = max(0, 6 - max(facts.workers_total, len(facts.workers)))
        parts["economy:工人缺口"] = 6 * gap
        if facts.refinery_built == 0:
            parts["economy:尚无矿场"] = 20
    if "intel" in item.score_notes:
        parts["intel:无确认敌情"] = 15 if not facts.enemy_intel else -5
    if "defense" in item.score_notes:
        parts["defense:基地威胁"] = 100 if facts.base_threat else -8
    if "attack" in item.score_notes:
        parts["attack:有确认敌情"] = 18 if facts.enemy_intel else -40
    if "assemble" in item.score_notes:
        parts["assemble:推进前置"] = 8
    if "expand" in item.score_notes:
        parts["expand:可扩矿点"] = 10 if facts.expansion else -10
    if item.route and item.route == (facts.routes[0] if facts.routes else ""):
        parts["route:与决策图首选一致"] = 3
    return sum(parts.values()), parts


# --------------------------------------------------------------------- 本地小模型调用


class LocalChat:
    """最小 OpenAI 兼容客户端（只允许本机端点；不复用/不改变任何远端配置）。"""

    def __init__(self, base_url: str, model: str, timeout: float = 15.0,
                 max_tokens: int = 96, api_key_resolver: Any = None) -> None:
        self.base_url = str(base_url or "").rstrip("/")
        self.model = str(model or "")
        self.timeout = float(timeout)
        self.max_tokens = int(max_tokens)
        self._api_key_resolver = api_key_resolver

    def _url(self) -> str:
        if self.base_url.endswith("/v1"):
            return self.base_url + "/chat/completions"
        return self.base_url + "/v1/chat/completions"

    def ask(self, system: str, user: str) -> Tuple[str, float]:
        body = {
            "model": self.model,
            "messages": [{"role": "system", "content": system},
                         {"role": "user", "content": user}],
            "temperature": 0,
            "max_tokens": self.max_tokens,
            "stream": False,
            "reasoning_effort": "none",
        }
        started = time.perf_counter()
        headers = {"Content-Type": "application/json"}
        if self._api_key_resolver is not None:
            api_key = self._api_key_resolver()
            if not api_key:
                raise ValueError("Enabled strategy role credential unavailable")
            headers["Authorization"] = "Bearer " + str(api_key)
        req = urllib.request.Request(self._url(), data=json.dumps(body).encode("utf-8"),
                                     headers=headers,
                                     method="POST")
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            payload = json.loads(resp.read().decode("utf-8", "replace"))
        latency_ms = (time.perf_counter() - started) * 1000.0
        choices = payload.get("choices") or [{}]
        text = str(((choices[0].get("message") or {}).get("content")) or "")
        return text, latency_ms


def _extract_json(text: str) -> Dict[str, Any]:
    """从模型正文里取第一个 JSON 对象（容忍 ``` 围栏与前后噪声）。"""
    raw = str(text or "").strip()
    if raw.startswith("```"):
        raw = raw.strip("`")
        if raw.lower().startswith("json"):
            raw = raw[4:]
    start = raw.find("{")
    end = raw.rfind("}")
    if start < 0 or end <= start:
        raise ValueError("模型输出里没有 JSON 对象")
    return json.loads(raw[start:end + 1])


# --------------------------------------------------------------------- 计划装配


def _identity(context: Dict[str, Any], plan_id: str, *, version: int = 1,
              maintain: bool = False) -> Dict[str, Any]:
    tick = int(context.get("server_tick") or 0)
    return {
        "plan_id": plan_id,
        "plan_version": max(1, int(version)),
        "match_id": str(context.get("match_id") or ""),
        "player_id": str(context.get("player_id") or ""),
        "rules_version": str(context.get("rules_version") or ""),
        "based_on_snapshot": max(0, int(context.get("snapshot_id") or 0)),
        "valid_until_tick": max(0, tick) + 6000,
        "maintain_current": bool(maintain),
    }


def candidate_to_plan(item: Candidate, context: Dict[str, Any],
                      rationale: str) -> StrategicPlan:
    if item.maintain_current:
        current = context.get("current_plan") if isinstance(context.get("current_plan"), dict) else {}
        plan_id = str(current.get("plan_id") or (VARIANT_PLAN_PREFIX + "-keep"))
        version = int(current.get("plan_version") or 1)
        return StrategicPlan(tasks=[], rationale=rationale, abort_when=[],
                             phase_goal=str(current.get("phase_goal") or "维持现计划"),
                             **_identity(context, plan_id, version=version, maintain=True))
    tasks = [PlanTask(**dict(task)) for task in item.tasks]
    return StrategicPlan(
        tasks=tasks, rationale=rationale, abort_when=[],
        phase_goal="%s：%s" % (item.name, item.summary),
        **_identity(context, "%s-%s" % (VARIANT_PLAN_PREFIX, item.candidate_id.lower())))


def facts_brief(facts: Facts) -> str:
    """压缩事实摘要（B/C 共用；不给逐单位机械字段）。"""
    lines = [
        "阶段=%s 前沿=%s" % (facts.phase or "未知", facts.frontier or "未知"),
        "己方可控单位=%d 工人=%d 侦察=%d 作战=%d 生产者=%d"
        % (len(facts.units), max(facts.workers_total, len(facts.workers)),
           len(facts.scouts), len(facts.combat_units()), len(facts.producers)),
        "经济：矿场完工=%d 已交付=%d" % (facts.refinery_built, facts.refinery_delivered),
        "已确认敌情=%d 条%s" % (len(facts.enemy_intel),
                              "（基地受袭）" if facts.base_threat else ""),
        "可扩展矿点=%d 处" % len(facts.expansion),
        "决策图可选路线=%s" % ("、".join(
            "%s%s" % (r, ("（%s）" % facts.route_names.get(r, "")) if facts.route_names.get(r) else "")
            for r in facts.routes) or "无"),
        "当前计划=%s" % (facts.active_plan_id or "无"),
    ]
    return "\n".join(lines)



# --------------------------------------------------------------------- 请求内选择合同


@dataclass(frozen=True)
class SelectionOptions:
    """一次请求的显示策略；连续 n 轮循环使 n 项各占每个位置一次。"""

    rotation: int = 0
    relabel: bool = False
    request_id: str = ""

    def __post_init__(self) -> None:
        if type(self.rotation) is not int or self.rotation < 0:
            raise ValueError("rotation must be a nonnegative integer")
        if type(self.relabel) is not bool:
            raise ValueError("relabel must be boolean")
        if not isinstance(self.request_id, str) or len(self.request_id) > 128:
            raise ValueError("request_id must be bounded text")


@dataclass(frozen=True)
class FrozenCandidate:
    """语义身份与显示身份分离；任务只保留不可变序列化快照。"""

    candidate_id: str
    display_id: str
    name: str
    summary: str
    tasks_json: str = field(repr=False)
    route: str = ""
    cost: str = ""
    risk: str = ""
    maintain_current: bool = False
    total: int = 0
    parts: Tuple[Tuple[str, int], ...] = ()

    @property
    def tasks(self) -> List[Dict[str, Any]]:
        # 每次装配获得新副本，调用者无法修改仲裁将使用的原始候选。
        return json.loads(self.tasks_json)


@dataclass(frozen=True)
class SelectionRequest:
    request_id: str
    context_json: str = field(repr=False)
    candidates: Tuple[FrozenCandidate, ...]
    brief: str
    rotation: int
    relabel: bool

    def context(self) -> Dict[str, Any]:
        return json.loads(self.context_json)

    def by_display(self, display_id: str) -> Optional[FrozenCandidate]:
        return next((c for c in self.candidates if c.display_id == display_id), None)

    def by_semantic(self, candidate_id: str) -> Optional[FrozenCandidate]:
        return next((c for c in self.candidates if c.candidate_id == candidate_id), None)

    def meta(self) -> Dict[str, Any]:
        return {"request_id": self.request_id, "rotation": self.rotation,
                "relabel": self.relabel,
                "candidate_order": [{"display_id": c.display_id,
                                     "semantic_id": c.candidate_id} for c in self.candidates]}


def prepare_selection(context: Dict[str, Any],
                      options: Optional[SelectionOptions] = None) -> SelectionRequest:
    options = options or SelectionOptions()
    if not isinstance(options, SelectionOptions):
        raise TypeError("explicit SelectionOptions required")
    # 上下文本来就是 JSON 合同；不以 default=str 掩盖不支持的数据类型。
    context_json = json.dumps(context, ensure_ascii=False, sort_keys=True,
                              separators=(",", ":"), allow_nan=False)
    snapshot = json.loads(context_json)
    candidates, facts = generate_candidates(snapshot)  # 请求内唯一一次生成
    scored = [(c, *score_candidate(c, facts)) for c in candidates]
    count = len(scored)
    offset = options.rotation % count if count else 0
    ordered = scored[offset:] + scored[:offset]
    frozen = tuple(FrozenCandidate(
        candidate_id=c.candidate_id,
        display_id=("P%d" % (index + 1)) if options.relabel else c.candidate_id,
        name=c.name, summary=c.summary,
        tasks_json=json.dumps(c.tasks, ensure_ascii=False, sort_keys=True,
                              separators=(",", ":"), allow_nan=False),
        route=c.route, cost=c.cost, risk=c.risk, maintain_current=c.maintain_current,
        total=total, parts=tuple(sorted(parts.items())))
        for index, (c, total, parts) in enumerate(ordered))
    # 默认身份由完整冻结输入派生；显示顺序不参与语义请求身份。
    digest = hashlib.sha256(context_json.encode("utf-8")).hexdigest()[:24]
    return SelectionRequest(options.request_id or ("selection-" + digest), context_json,
                            frozen, facts_brief(facts), offset, options.relabel)


# --------------------------------------------------------------------- 三个 provider



@dataclass(frozen=True)
class OfflineChat:
    """唯一允许的 fake transport；固定正文返回，不含网络实现。"""

    reply: str = '{"choice":"P1"}'

    def ask(self, system: str, user: str) -> Tuple[str, float]:
        return self.reply, 0.0


class _VariantBase:
    name = "variant"
    requires_unit_facts = True

    def __init__(self, chat: Optional[LocalChat] = None, logger: Any = None,
                 selection_options: Optional[SelectionOptions] = None,
                 model_source: str = "model_native") -> None:
        if model_source not in ("model_native", "fake"):
            raise ValueError("unsupported model source")
        if model_source == "fake" and type(chat) is not OfflineChat:
            raise TypeError("fake source requires exact offline transport")
        if type(chat) is OfflineChat and model_source != "fake":
            raise ValueError("offline transport must be marked fake")
        self.chat = chat
        self.logger = logger
        self.selection_options = selection_options or SelectionOptions()
        self.model_source = model_source
        self.last_meta: Dict[str, Any] = {}
        self._counter_lock = threading.Lock()

    def describe(self) -> str:
        return "%s(chat=%s)" % (self.name, bool(self.chat))

    def _begin(self, context: Dict[str, Any], options: Optional[SelectionOptions]
               ) -> Tuple[SelectionRequest, Dict[str, Any]]:
        # 整个请求只改局部 meta；last_meta 仅在完成时发布，不作为决策输入。
        try:
            request = prepare_selection(context, options or self.selection_options)
        except Exception as exc:
            # 无可用JSON上下文时无法安全组装规则计划，明确传播输入错误，
            # 但不得把上一次成功决策留给诊断读取者。
            self.last_meta = {"variant": self.name, "source": "rules_fallback",
                              "model_called": False, "native_valid": False,
                              "latency_ms": 0.0, "chosen": "", "plan_id": "",
                              "request_valid": False,
                              "fallback": "context_error:%s" % type(exc).__name__}
            raise
        meta = {"variant": self.name, "source": "rules_fallback",
                "model_called": False, "native_valid": False, "latency_ms": 0.0,
                "chosen": "", "plan_id": "", **request.meta()}
        return request, meta

    def _publish(self, plan: StrategicPlan, meta: Dict[str, Any]) -> StrategicPlan:
        # 完整快照一次赋值；日志接收自己的副本，不污染 last_meta。
        self.last_meta = json.loads(json.dumps(meta, ensure_ascii=False, allow_nan=False))
        self._log(kind="variant_choice", **json.loads(json.dumps(meta, ensure_ascii=False)))
        return plan

    def _fallback(self, context: Dict[str, Any], reason: str,
                  meta: Dict[str, Any]) -> StrategicPlan:
        from .campaign import rules_safe_plan
        plan = rules_safe_plan(context)
        meta.update(source="rules_fallback", fallback=reason, native_valid=False,
                    chosen="RULES", plan_id=plan.plan_id)
        return plan

    def _log(self, **payload: Any) -> None:
        if self.logger is not None:
            try:
                self.logger(payload)
            except Exception:
                pass

    def _ask(self, system: str, prompt: str, meta: Dict[str, Any]) -> Dict[str, Any]:
        # 在调用边界复核实际transport，公开属性被替换也不能让fake出网。
        transport = self.chat
        if self.model_source == "fake" and type(transport) is not OfflineChat:
            raise TypeError("fake source requires exact offline transport")
        if type(transport) is OfflineChat and self.model_source != "fake":
            raise ValueError("offline transport must be marked fake")
        meta["model_called"] = True
        started = time.perf_counter()
        try:
            text, _reported_latency = transport.ask(system, prompt)
            payload = _extract_json(text)
            if not isinstance(payload, dict):
                raise ValueError("response must be object")
            return payload
        finally:
            meta["latency_ms"] = round((time.perf_counter() - started) * 1000.0, 3)

    def _selected(self, request: SelectionRequest, item: FrozenCandidate,
                  rationale: str, source: str, meta: Dict[str, Any]) -> StrategicPlan:
        plan = candidate_to_plan(item, request.context(), rationale)
        meta.update(source=source, chosen=item.candidate_id, chosen_display_id=item.display_id,
                    plan_id=plan.plan_id, native_valid=source == "model_native")
        return plan


TEMPLATE_SYSTEM = (
    "你是 RTS 副官的战略选择器。禁止输出单位命令、坐标、预算或元数据。"
    "只输出一行 JSON：{\"template\":\"<模板>\"}，只能选给出的模板。"
)
CHOICE_SYSTEM = (
    "你是 RTS 副官的战略选择器。下面是程序已生成并验证前提的候选方案。"
    "禁止输出单位命令、坐标、预算或元数据。"
    "只输出一行 JSON：{\"choice\":\"<显示ID>\"}，只能选给出的显示ID。"
)



class TemplateStrategy(_VariantBase):
    """模型只选实际可用模板；未实现的 focus 明确回退。"""

    name = "template"

    def propose_plan(self, context: Dict[str, Any], *,
                     options: Optional[SelectionOptions] = None) -> StrategicPlan:
        request, meta = self._begin(context, options)
        available = [(template, request.by_semantic(TEMPLATE_TO_CANDIDATE[template]))
                     for template in TEMPLATES]
        available = [(template, item) for template, item in available if item is not None]
        def fallback(reason: str) -> StrategicPlan:
            return self._publish(self._fallback(request.context(), reason, meta), meta)
        if not available or self.chat is None:
            return fallback("no_usable_template" if not available else "no_model")
        prompt = "可选模板：\n" + "\n".join(
            "- %s：%s" % (template, item.summary) for template, item in available)
        prompt += "\n\n当前事实：\n" + request.brief
        try:
            payload = self._ask(TEMPLATE_SYSTEM, prompt, meta)
            if set(payload) != {"template"} or not isinstance(payload.get("template"), str):
                return fallback("unsupported_focus" if "focus" in payload else "response_schema")
            template = payload["template"].strip()
            item = next((item for key, item in available if key == template), None)
            if item is None:
                return fallback("template_out_of_enum")
            meta["template"] = template
            plan = self._selected(request, item, "template:%s" % template, self.model_source, meta)
            return self._publish(plan, meta)
        except Exception as exc:
            return fallback("error:%s" % type(exc).__name__)


class ChoiceStrategy(_VariantBase):
    """返回本请求的结果和独立 metadata，Score 不读取共享 last_meta。"""

    name = "choice"

    def propose_plan(self, context: Dict[str, Any], *,
                     options: Optional[SelectionOptions] = None) -> StrategicPlan:
        request, _meta = self._begin(context, options)
        return self.choose_request(request)

    def choose_request(self, request: SelectionRequest) -> StrategicPlan:
        plan, meta = self.select_request(request)
        return self._publish(plan, meta)

    def select_request(self, request: SelectionRequest
                       ) -> Tuple[StrategicPlan, Dict[str, Any]]:
        meta = {"variant": self.name, "source": "rules_fallback",
                "model_called": False, "native_valid": False, "latency_ms": 0.0,
                "chosen": "", "plan_id": "", **request.meta()}
        def fallback(reason: str) -> Tuple[StrategicPlan, Dict[str, Any]]:
            return self._fallback(request.context(), reason, meta), meta
        if self.chat is None or not request.candidates:
            return fallback("no_candidates" if not request.candidates else "no_model")
        prompt = "候选方案（只能选下面出现的显示ID）：\n" + "\n".join(
            "- %s %s：%s；代价 %s；风险 %s" %
            (c.display_id, c.name, c.summary, c.cost or "-", c.risk or "-")
            for c in request.candidates)
        prompt += "\n\n当前事实：\n" + request.brief
        try:
            payload = self._ask(CHOICE_SYSTEM, prompt, meta)
            if set(payload) != {"choice"} or not isinstance(payload.get("choice"), str):
                return fallback("response_schema")
            item = request.by_display(payload["choice"].strip())
            if item is None:
                return fallback("choice_out_of_enum")
            return self._selected(request, item, "choice:%s" % item.candidate_id,
                                  self.model_source, meta), meta
        except Exception as exc:
            return fallback("error:%s" % type(exc).__name__)


class ScoringStrategy(_VariantBase):
    """评分和模型仲裁共用冻结候选及独立的请求 metadata。"""

    name = "score"

    def __init__(self, chat: Optional[LocalChat] = None, logger: Any = None,
                 margin: int = 8, ask_when_ambiguous: bool = True,
                 selection_options: Optional[SelectionOptions] = None,
                 model_source: str = "model_native") -> None:
        super().__init__(chat, logger, selection_options, model_source)
        self.margin = int(margin)
        self.ask_when_ambiguous = bool(ask_when_ambiguous)
        self._chooser = ChoiceStrategy(chat, None, selection_options, model_source)
        self.arbitrations = 0
        self.decisions = 0

    def propose_plan(self, context: Dict[str, Any], *,
                     options: Optional[SelectionOptions] = None) -> StrategicPlan:
        request, meta = self._begin(context, options)
        if not request.candidates:
            return self._publish(self._fallback(request.context(), "no_candidates", meta), meta)
        scored = sorted(request.candidates, key=lambda c: (-c.total, c.candidate_id))
        with self._counter_lock:
            self.decisions += 1
        top = scored[0]
        gap = top.total - scored[1].total if len(scored) > 1 else None
        ambiguous = gap is not None and gap < self.margin
        meta.update(scores=[{"id": c.candidate_id, "total": c.total,
                             "parts": dict(c.parts)} for c in scored],
                    gap=gap, ambiguous=ambiguous, arbitrated=False)
        if ambiguous and self.ask_when_ambiguous and self.chat is not None:
            with self._counter_lock:
                self.arbitrations += 1
            plan, chosen_meta = self._chooser.select_request(request)
            item = request.by_semantic(chosen_meta.get("chosen", ""))
            meta.update(arbitrated=True, model_called=chosen_meta.get("model_called", False),
                        latency_ms=chosen_meta.get("latency_ms", 0.0))
            if item is not None and chosen_meta.get("source") in ("model_native", "fake"):
                meta.update(chosen_meta, variant=self.name, arbitrated=True, chosen_score=item.total)
                return self._publish(plan, meta)
            meta["fallback"] = chosen_meta.get("fallback", "arbitration_invalid")
            plan = self._selected(request, top, "score:%s(仲裁失败程序直选)" % top.candidate_id,
                                  "program_direct", meta)
            return self._publish(plan, meta)
        plan = self._selected(request, top, "score:%s(%d分,程序直选)" % (top.candidate_id, top.total),
                              "program_direct", meta)
        return self._publish(plan, meta)


class ScoringOnlyStrategy(ScoringStrategy):
    name = "score_only"

    def __init__(self, chat: Optional[LocalChat] = None, logger: Any = None,
                 margin: int = 8, selection_options: Optional[SelectionOptions] = None) -> None:
        super().__init__(chat=None, logger=logger, margin=margin, ask_when_ambiguous=False,
                         selection_options=selection_options)


__all__ = [
    "TEMPLATES", "TEMPLATE_TO_CANDIDATE", "VARIANT_PLAN_PREFIX",
    "OfflineChat", "Candidate", "FrozenCandidate", "SelectionOptions", "SelectionRequest",
    "ChoiceStrategy", "Facts", "LocalChat", "ScoringOnlyStrategy",
    "ScoringStrategy", "TemplateStrategy", "build_facts", "candidate_by_id",
    "candidate_to_plan", "facts_brief", "generate_candidates", "prepare_selection", "score_candidate",
]
