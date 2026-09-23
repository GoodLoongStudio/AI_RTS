# -*- coding: utf-8 -*-
"""P0 可行性验证：Laya 判别式决策引擎 vs 现有 2B 链路（真实对局日志回放）。

依据（`docs/程序文档/AI副官_Laya混合架构_执行提示词_2026-09-20.md` §P0）：

- 输入 = **真实采集的对局观测**（`tests/data/observations/real_*.jsonl`），逐条回放；
- 每个决策点用**生产同一条链路**（`squads.build_decision_frame`）构造 `DecisionFrame`，
  再转成 `state` + `questions`（问题即当时的候选菜单：任务类型 / 执行者 / 目标 / 参数·风险）；
- 记录：**单次延迟（ms）**、**Q1 任务类型选择 vs 当时实际执行**（`format_ab_both_*.json`
  里同一观测的 2B 真实输出）、**置信度**；
- 通过标准（写进报告，用数据说话）：
  - 单次延迟 GPU < 150ms（对比现在 2B 的秒级）；
  - 任务类型一致率 ≥ 70%（与"当时实际执行"或"规则层推荐"比）；
  - 若一致率 < 50% → 停下汇报（需先微调，不可硬上）。

v2 对照（测量有效性，防自欺）：

1. **token 预算**：state + 少样本前缀合计 ≤ ~950 token，超过就按优先级砍行 ——
   Laya 的序列上限 1024，超长会被**从头保留**地截断（`build_sequence` 取 `st[:room]`），
   前缀在前会挤掉当前状态的尾部，测出来的"一致"可能只是复读样例；
2. **选项轮换**：零样本恒定选菜单第一个选项（首轮实测 118/120 选 ATK，而 ATK 恰是
   `SKILL_ORDER` 第一项）→ 轮换菜单顺序后重测，区分"真懂"与"位置偏差"；
3. **跨文件少样本**：样例取自**另一个对局文件**，切断"上一拍决策 ≈ 这一拍决策"的
   时序泄漏；同文件相邻样例（fs_adjacent）仅作参考口径；
4. **规则层基线**：跑 `rules_fallback.development_intents`（模型关闭时的地板），
   按计划允许的"规则层推荐"口径对照；
5. **平凡基线**：恒选多数类（本数据集主导技能恒为 GAT）——任何配置若打不过它，
   一致率数字就没有意义。

用法：

    python -m adjutant_coordinator.deploy.laya_p0_feasibility \
        --ab logs/format_ab_both_20260912.json --mode fast \
        --out logs/laya_p0_<日期>.json
"""

from __future__ import annotations

import argparse
import json
import os
import random
import statistics
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))          # source/
sys.path.insert(0, ROOT)

from adjutant_coordinator.graph.squads import build_decision_frame  # noqa: E402
from adjutant_coordinator.graph.task_patch import (  # noqa: E402
    ACTOR_ALLOWED_SKILLS, MODE_FAST, SKILL_ALLOWED_TARGETS, SKILL_ORDER,
    SKILL_TITLE_CN,
)
from adjutant_coordinator.graph.task_patch_prompt import render_compact_text  # noqa: E402
from adjutant_coordinator.graph import rules_fallback  # noqa: E402

#: Laya 的已知限制（模型卡）：选项数 >20 明显退化 → 每问 ≤20，超出分两级。
MAX_OPTIONS_PER_QUESTION = 20

#: state + 前缀的 token 预算（留头给 [CLS]/问题/选项；多语言 max_len=1024）。
STATE_TOKEN_BUDGET = 950

#: 少样本样例数。
FEW_SHOT_N = 3

#: 规则层动作 → 四列技能（同一条权威链的映射，不新增语义）。
RULE_ACTION_TO_SKILL = {
    "gather": "GAT", "build": "BLD", "produce": "PROD", "attack": "ATK",
    "attack_move": "AMOV", "defend": "DEF", "retreat": "RET", "scout": "SCT",
    "regroup": "GRP", "move": "MOVE", "hold": "HOLD", "stop": "STOP",
}


# ---------------- 数据加载 ----------------

def load_observations(paths: List[str]) -> Tuple[Dict[str, Any], List[Dict[str, Any]]]:
    rules: Dict[str, Any] = {}
    observations: List[Dict[str, Any]] = []
    for path in paths:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                item = json.loads(line)
                if item.get("kind") == "rules":
                    if not rules:
                        rules = item.get("rules") or {}
                elif item.get("kind") == "observation":
                    item["_source"] = os.path.basename(path)
                    observations.append(item)
    return rules, observations


def load_ab_records(path: str) -> Dict[Tuple[str, int, int, str], Dict[str, Any]]:
    """A/B 记录 → {(source, seq, tick, mode): record}（取 2B 的真实四列输出做基线）。"""
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    out: Dict[Tuple[str, int, int, str], Dict[str, Any]] = {}
    for record in data.get("records") or []:
        key = (str(record.get("source")), int(record.get("seq", 0) or 0),
               int(record.get("tick", 0) or 0), str(record.get("mode")))
        out[key] = record
    return out


def actual_rows(record: Optional[Dict[str, Any]]) -> List[List[str]]:
    """当时实际执行的四列行（2B 真实输出，已通过既有校验的那部分）。"""
    if not record:
        return []
    entry = record.get("new") or {}
    return [[str(c) for c in row] for row in (entry.get("sample") or [])]


# ---------------- 帧 → Laya 输入 ----------------

def frame_of(observation: Dict[str, Any], rules: Dict[str, Any],
             mode: str = MODE_FAST):
    header = observation.get("header") or {}
    tactical = observation.get("tactical") or {}
    own_units = [str(e.get("name")) for e in (tactical.get("entities") or [])
                 if str(e.get("kind")) == "unit_self" and e.get("name")]
    return build_decision_frame(
        match_id=str(header.get("match_id", "")),
        player_id=str(header.get("player_id", "")),
        rules_version=str(header.get("rules_version", "")),
        snapshot_id=int(header.get("snapshot_id", 0) or 0),
        server_tick=int(header.get("server_tick", 0) or 0),
        tactical=tactical, rules=rules, mode=mode,
        authorized_units=set(own_units), plan_version="ab:v1")


def rule_floor_skills(observation: Dict[str, Any],
                      rules: Dict[str, Any]) -> List[str]:
    """规则层推荐（模型关闭时的地板）：`development_intents` 的技能集合。"""
    header = observation.get("header") or {}
    tactical = observation.get("tactical") or {}
    own_units = [str(e.get("name")) for e in (tactical.get("entities") or [])
                 if str(e.get("kind")) == "unit_self" and e.get("name")]
    state = {
        "match_id": str(header.get("match_id", "")),
        "player_id": str(header.get("player_id", "")),
        "rules_version": str(header.get("rules_version", "")),
        "server_tick": int(header.get("server_tick", 0) or 0),
        "latest_snapshot_id": int(header.get("snapshot_id", 0) or 0),
        "build_backoff_until_tick": 0,
        "ai_controlled_units": list(own_units),
        "map_bounds": [50.0, 50.0],
    }
    try:
        intents = rules_fallback.development_intents(
            state, tactical=tactical, rules=rules,
            server_tick=int(header.get("server_tick", 0) or 0),
            snapshot_id=int(header.get("snapshot_id", 0) or 0))
    except Exception:  # noqa: BLE001 —— 规则层异常不影响实验继续
        return []
    return sorted({RULE_ACTION_TO_SKILL.get(str(i.get("action", "")), "")
                   for i in intents} - {""})


def feasible_skills(frame) -> List[str]:
    """本帧可行的任务类型（候选菜单 = 程序筛过的合法性粗筛，与现有链路同口径）。

    一个技能入选当且仅当：① 有执行者能做它；② 它需要的目标类别在本帧目标表里存在
    （HOLD/STOP 无目标，恒可选）。这样 Laya 的选项与 2B 看到的候选表同源，
    "模型只做选择，不能自造"的纪律在判别式路径上同样成立。
    """
    actors = list(frame.actors.values())
    out: List[str] = []
    for skill in SKILL_ORDER:
        kinds = [kind for kind, allowed in ACTOR_ALLOWED_SKILLS.items()
                 if skill in allowed]
        if not any(str(a.get("kind", "")) in kinds for a in actors):
            continue
        need = SKILL_ALLOWED_TARGETS.get(skill)
        if need is None:
            out.append(skill)
            continue
        if any(str(t.get("kind", "")) in need for t in frame.targets.values()):
            out.append(skill)
    if "HOLD" not in out:
        out.append("HOLD")
    return out


def state_lines(frame, *, balance: Optional[Dict[str, Any]] = None) -> List[str]:
    """紧凑 state 的**行序列**（按决策重要性排序；token 超预算时从尾部砍）。"""
    text = render_compact_text(frame, balance=balance)
    return [line for line in text.split("\n") if line.strip()]


def budgeted_state(agent, lines: List[str], prefix: str,
                   budget: int = STATE_TOKEN_BUDGET) -> Tuple[str, int]:
    """前缀 + 状态行，合计 ≤ budget token（用 Laya 自己的 tokenizer 数）。

    砍行顺序 = 行序倒序（`state_lines` 已按重要性排好：执行者/资源/敌人在前，
    余额/阶段目标等在后）。保证**不发生截断**——截断会从头保留，把前缀留在上下文里、
    把当前状态尾部挤掉，测出的"一致"只是复读样例。
    """
    def n_tokens(s: str) -> int:
        return len(agent.tok(s, add_special_tokens=False)["input_ids"])

    used = n_tokens(prefix) if prefix else 0
    kept: List[str] = []
    for line in lines:
        cost = n_tokens(line + "\n")
        if used + cost > budget:
            break
        kept.append(line)
        used += cost
    return (prefix + "\n".join(kept)), used


def build_questions(frame, *, rotate: int = 0) -> Dict[str, Dict[str, Any]]:
    """四问（任务/执行者/目标粗类/参数）+ 风险打分；每问选项 ≤20。

    `rotate`：把任务菜单循环移位 rotate 位（诊断"恒定选第一个选项"的位置偏差）。
    目标细选依赖任务类型的选择结果（不同技能允许的目标类别不同），而 Laya 一次前向的
    选项必须预先定义 —— 因此目标问只问**粗类**（本帧出现的目标类别，≤5 项），
    细选在第二次前向里做（选项收敛到该类别内，仍遵守 ≤20）。
    """
    skills = feasible_skills(frame)
    if rotate:
        cut = rotate % len(skills)
        skills = skills[cut:] + skills[:cut]
    questions: Dict[str, Dict[str, Any]] = {
        "task": {
            "type": "choice",
            "instructions": "这一拍最该做的任务类型是什么？",
            "criteria": {skill: SKILL_TITLE_CN.get(skill, skill)
                         for skill in skills},
        },
        "actor": {
            "type": "choice",
            "instructions": "派哪个执行者去执行？",
            "criteria": {
                str(ref): "%s×%d" % (str(actor.get("kind", "")),
                                     int(actor.get("count", 0) or 0))
                for ref, actor in frame.actors.items()
            },
        },
        "target_kind": {
            "type": "choice",
            "instructions": "目标选哪一类？",
            "criteria": {
                kind: {"enemy": "敌人", "resource": "资源点", "location": "战场点位",
                       "anchor": "我方基点", "product": "可造/可产项目"}.get(kind, kind)
                for kind in sorted({str(t.get("kind", ""))
                                    for t in frame.targets.values()})
            },
        },
        "params": {
            "type": "choice",
            "instructions": "行军参数选哪一档？",
            "criteria": {
                "P1": "直线推进·纵队·常速", "P2": "正面压上·横队·快速",
                "P3": "侧翼迂回·疏散·常速", "P4": "经集结点·纵队·谨慎",
                "P5": "快速展开·疏散·快速", "P6": "固守待命·横队·不追击",
            },
        },
        "risk": {
            "type": "score",
            "instructions": "当前战场危险程度？",
            "criteria": ["安全", "警戒", "危急"],
        },
    }
    # 守门：任何一问超过 20 项都要在报告里暴露（模型卡：>20 明显退化）。
    for qid, qdef in questions.items():
        if qdef["type"] == "choice" and len(qdef["criteria"]) > MAX_OPTIONS_PER_QUESTION:
            raise AssertionError("question %r has %d options (>%d)"
                                 % (qid, len(qdef["criteria"]),
                                    MAX_OPTIONS_PER_QUESTION))
    return questions


def target_options(frame, kind: str) -> Dict[str, str]:
    """某目标类别内的细选项（≤20；超出按"离部队质心近"截断并记录）。"""
    points = [a["pos"] for a in frame.actors.values()
              if a.get("kind") in ("squad", "worker") and a.get("pos")]
    ox = sum(float(p[0]) for p in points) / len(points) if points else 0.0
    oz = sum(float(p[1]) for p in points) / len(points) if points else 0.0

    def dist(entry: Dict[str, Any]) -> float:
        pos = entry.get("pos") or [0.0, 0.0]
        return (float(pos[0]) - ox) ** 2 + (float(pos[1]) - oz) ** 2

    entries = [t for t in frame.targets.values() if str(t.get("kind", "")) == kind]
    entries.sort(key=dist)
    out: Dict[str, str] = {}
    for entry in entries[:MAX_OPTIONS_PER_QUESTION]:
        ref = str(entry.get("ref", ""))
        label = str(entry.get("cn") or entry.get("scene") or entry.get("entity_id")
                    or entry.get("kind", ""))
        out[ref] = label[:24]
    return out


def few_shot_prefix(examples: List[Dict[str, Any]]) -> str:
    """少样本前缀：历史决策点的"状态 → 当时实际选择"（标签 = 2B 真实输出）。"""
    if not examples:
        return ""
    lines = ["参考样例（同一副官的历史决策）:"]
    for item in examples:
        rows = item.get("rows") or []
        if not rows:
            continue
        picks = " ".join("%s→%s%s" % (r[0], r[1], r[2] if r[2] != "-" else "")
                         for r in rows[:3])
        lines.append("[状态] %s ⇒ 决策: %s" % (item.get("state", ""), picks))
    return "\n".join(lines) + "\n"


# ---------------- 测量 ----------------

def percentile(values: List[float], p: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(p / 100.0 * (len(ordered) - 1))))]


def dominant_skill(rows: List[List[str]]) -> str:
    """当时实际执行的主导任务类型（出现最多；并列取先出现者）。"""
    if not rows:
        return ""
    counts: Dict[str, int] = {}
    for row in rows:
        skill = str(row[1])
        counts[skill] = counts.get(skill, 0) + 1
    return max(counts.items(), key=lambda kv: kv[1])[0]


def agreement(pairs: List[Tuple[str, Dict[str, Any]]]) -> Dict[str, Any]:
    """pairs = [(Laya 选择, 该点事实)] → 各口径一致率。

    事实字段：actual_skills / dominant / rule_skills / has_dev（实际含发展类任务）。
    """
    n = len(pairs)
    if not n:
        return {}
    agree_set = sum(1 for pick, fact in pairs if pick in fact["actual_skills"])
    agree_dom = sum(1 for pick, fact in pairs if pick == fact["dominant"])
    agree_rule = sum(1 for pick, fact in pairs
                     if fact.get("rule_skills") and pick in fact["rule_skills"])
    # 判别性口径：实际做了发展决策（PROD/BLD）的点上，Laya 是否也选发展类；
    # 以及 Laya 选发展类时的精确率（避免"无脑 GAT"刷高一致率）。
    dev_points = [(pick, fact) for pick, fact in pairs if fact["has_dev"]]
    dev_hit = sum(1 for pick, fact in dev_points if pick in ("PROD", "BLD"))
    dev_picks = [(pick, fact) for pick, fact in pairs if pick in ("PROD", "BLD")]
    dev_prec = sum(1 for pick, fact in dev_picks if fact["has_dev"])
    return {
        "n": n,
        "agree_set": agree_set, "agree_set_rate": round(100.0 * agree_set / n, 1),
        "agree_dominant": agree_dom,
        "agree_dominant_rate": round(100.0 * agree_dom / n, 1),
        "agree_rule": agree_rule,
        "agree_rule_rate": (round(100.0 * agree_rule / n, 1)
                            if any(f.get("rule_skills") for _, f in pairs) else None),
        "dev_points": len(dev_points),
        "dev_hit_rate": (round(100.0 * dev_hit / len(dev_points), 1)
                         if dev_points else None),
        "dev_picks": len(dev_picks),
        "dev_precision": (round(100.0 * dev_prec / len(dev_picks), 1)
                          if dev_picks else None),
    }


def latency_of(records: List[Dict[str, Any]], field: str) -> Dict[str, Any]:
    def ms_of(record: Dict[str, Any]) -> Optional[float]:
        value = record.get(field)
        if isinstance(value, dict):
            value = value.get("ms")
        return float(value) if value else None

    values = [v for v in (ms_of(r) for r in records) if v is not None]
    if not values:
        return {}
    return {
        "n": len(values),
        "p50_ms": round(percentile(values, 50), 1),
        "p95_ms": round(percentile(values, 95), 1),
        "max_ms": round(max(values), 1),
        "mean_ms": round(statistics.mean(values), 1),
    }


def pick_distribution(records: List[Dict[str, Any]], field: str) -> Dict[str, int]:
    out: Dict[str, int] = {}
    for r in records:
        pick = r.get(field)
        if pick:
            out[pick] = out.get(pick, 0) + 1
    return dict(sorted(out.items(), key=lambda kv: -kv[1]))


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Laya P0 可行性验证（真实日志回放）")
    parser.add_argument("--data", action="append", default=[])
    parser.add_argument("--ab", required=True, help="format_ab_both_*.json（2B 真实输出基线）")
    parser.add_argument("--mode", default="fast", choices=("fast", "deep"))
    parser.add_argument("--limit", type=int, default=0, help="最多回放多少条（0=全部）")
    parser.add_argument("--few-shot", type=int, default=FEW_SHOT_N)
    parser.add_argument("--warmup", type=int, default=3)
    parser.add_argument("--out", default="")
    args = parser.parse_args(argv)

    data_paths = args.data or [
        os.path.join(ROOT, "adjutant_coordinator", "tests", "data", "observations",
                     "real_20260912.jsonl"),
        os.path.join(ROOT, "adjutant_coordinator", "tests", "data", "observations",
                     "real_mass_20260912.jsonl"),
    ]
    rules, observations = load_observations(data_paths)
    ab = load_ab_records(args.ab)
    print("observations=%d ab_records=%d mode=%s" % (len(observations), len(ab), args.mode))

    import laya  # 延迟导入：没有 laya 时本工具明确失败，不拖垮其它路径
    agent = laya.load("convaiinnovations/laya", subfolder="multilingual")
    print("laya device:", agent.device)

    # 预热（CUDA kernel 初始化不计入延迟统计）。
    warm_state = "单位: W1(worker×2)\n资源点: R1"
    warm_q = {"task": {"type": "choice", "instructions": "任务？",
                       "criteria": {"GAT": "采集", "HOLD": "维持"}}}
    for _ in range(max(0, args.warmup)):
        agent.predict(warm_state, warm_q)

    # ---- 第一遍：构造全部决策点（帧 / state 行 / 实际选择 / 规则层推荐）----
    points: List[Dict[str, Any]] = []
    for observation in observations:
        if args.limit and len(points) >= args.limit:
            break
        key = (str(observation.get("_source")), int(observation.get("seq", 0) or 0),
               int((observation.get("header") or {}).get("server_tick", 0) or 0),
               args.mode)
        record = ab.get(key)
        if record is None:
            continue
        rows = actual_rows(record)
        if not rows:
            continue
        frame = frame_of(observation, rules, mode=args.mode)
        balance = (observation.get("tactical") or {}).get("balance")
        points.append({
            "source": key[0], "seq": key[1], "tick": key[2],
            "frame": frame, "lines": state_lines(frame, balance=balance),
            "rows": rows,
            "actual_skills": sorted({r[1] for r in rows}),
            "dominant": dominant_skill(rows),
            "rule_skills": rule_floor_skills(observation, rules),
            "has_dev": any(r[1] in ("PROD", "BLD") for r in rows),
        })
    print("decision points:", len(points))

    # 少样本池：同文件相邻（泄漏口径）与跨文件（对照口径）。
    by_source: Dict[str, List[Dict[str, Any]]] = {}
    for point in points:
        by_source.setdefault(point["source"], []).append(point)
    sources = sorted(by_source)
    rng = random.Random(20260920)

    def examples_for(index: int, point: Dict[str, Any], kind: str
                     ) -> List[Dict[str, Any]]:
        # cross=3 例 / mixed8=8 例，均取自**其它文件**（切断本局时序泄漏）；
        # adjacent=同文件前 n 个点（泄漏口径，仅作参考）。
        n = 8 if kind == "mixed8" else max(0, args.few_shot)
        if n == 0:
            return []
        if kind == "adjacent":
            pool = by_source[point["source"]]
            pos = pool.index(point)
            return pool[max(0, pos - n):pos]
        others = [p for s in sources if s != point["source"] for p in by_source[s]]
        return rng.sample(others, min(n, len(others))) if others else []

    # ---- 第二遍：逐配置回放 ----
    configs = [
        ("zero", {"prefix": "none", "rotate": 0}),
        ("zero_rot", {"prefix": "none", "rotate": 1}),
        ("fs_adjacent", {"prefix": "adjacent", "rotate": 0}),
        ("fs_adjacent_rot", {"prefix": "adjacent", "rotate": 1}),
        ("fs_cross", {"prefix": "cross", "rotate": 0}),
        ("fs_cross_rot", {"prefix": "cross", "rotate": 1}),
        ("fs_mixed8", {"prefix": "mixed8", "rotate": 0}),
        ("fs_mixed8_rot", {"prefix": "mixed8", "rotate": 1}),
    ]
    results: Dict[str, List[Dict[str, Any]]] = {name: [] for name, _ in configs}
    for index, point in enumerate(points):
        for name, cfg in configs:
            prefix = ""
            if cfg["prefix"] != "none":
                prefix = few_shot_prefix(examples_for(index, point, cfg["prefix"]))
            state, used = budgeted_state(agent, point["lines"], prefix)
            questions = build_questions(point["frame"], rotate=int(cfg["rotate"]))
            t0 = time.perf_counter()
            res = agent.predict(state, questions)
            ms = (time.perf_counter() - t0) * 1000.0
            answer = (res["answers"].get("task") or {})
            entry = {
                "source": point["source"], "seq": point["seq"], "tick": point["tick"],
                "ms": round(ms, 1), "task": answer.get("choice"),
                "confidence": answer.get("confidence"),
                "input_tokens": (res.get("usage") or {}).get("input_tokens"),
                "state_tokens": used,
                "actual_skills": point["actual_skills"],
                "dominant": point["dominant"],
                "rule_skills": point["rule_skills"],
                "has_dev": point["has_dev"],
            }
            results[name].append(entry)
        if (index + 1) % 20 == 0:
            print("  ... %d/%d points" % (index + 1, len(points)))

    # ---- 目标细选延迟（第二次前向，选项收敛到粗类内）----
    fine_latency: List[Dict[str, Any]] = []
    for point in points[:40]:
        state, _ = budgeted_state(agent, point["lines"], "")
        questions = build_questions(point["frame"])
        zero = agent.predict(state, questions)
        kind = (zero["answers"].get("target_kind") or {}).get("choice")
        if not kind:
            continue
        fine = dict(questions)
        fine["target"] = {"type": "choice", "instructions": "目标选哪个？",
                          "criteria": target_options(point["frame"], str(kind))}
        if not fine["target"]["criteria"]:
            continue
        t0 = time.perf_counter()
        agent.predict(state, fine)
        fine_latency.append({"latency": {"ms": round((time.perf_counter() - t0) * 1000.0, 1)}})

    # ---------------- 汇总 ----------------
    actual_dist: Dict[str, int] = {}
    for point in points:
        for skill in point["actual_skills"]:
            actual_dist[skill] = actual_dist.get(skill, 0) + 1
    majority = max(actual_dist.items(), key=lambda kv: kv[1])[0] if actual_dist else ""
    majority_pairs = [(majority, {"actual_skills": p["actual_skills"],
                                  "dominant": p["dominant"],
                                  "rule_skills": p["rule_skills"],
                                  "has_dev": p["has_dev"]}) for p in points]

    summary: Dict[str, Any] = {
        "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "mode": args.mode,
        "decision_points": len(points),
        "device": str(agent.device),
        "configs": {},
        "majority_baseline": {
            "skill": majority,
            **agreement(majority_pairs),
        },
        "actual_distribution": dict(sorted(actual_dist.items(), key=lambda kv: -kv[1])),
        "target_fine_latency": latency_of(fine_latency, "latency"),
    }
    for name, _ in configs:
        records = results[name]
        pairs = [(r["task"], r) for r in records if r.get("task")]
        confidences = [float(r["confidence"]) for r in records if r.get("confidence")]
        summary["configs"][name] = {
            "agreement": agreement(pairs),
            "latency": latency_of(records, "ms"),
            "pick_distribution": pick_distribution(records, "task"),
            "mean_confidence": round(statistics.mean(confidences), 4) if confidences else None,
            "state_tokens_max": max([int(r.get("state_tokens") or 0) for r in records] or [0]),
            "input_tokens_max": max([int(r.get("input_tokens") or 0) for r in records] or [0]),
        }
    payload = {"summary": summary,
               "records": {name: results[name] for name, _ in configs}}
    out = args.out or os.path.join(
        ROOT, "adjutant_coordinator", "logs",
        "laya_p0_%s.json" % time.strftime("%Y%m%d_%H%M%S"))
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=1)
    print(json.dumps(summary, ensure_ascii=False, indent=1))
    print("written:", out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
