#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""短决策接口 A/B：旧 `DirectiveBatch` vs 新四列 `TaskPatchBatch`（计划 §7.A）。

测量口径（严格执行计划，不做美化）：
- 输入 = **真实采集的对局观测**（`capture_observations.py` 产物），逐条回放；
- 首次结构合法率 = **单次原始调用**（无重试、无纠错）产出能否通过契约校验；
- 语义合法率 = 解码/引用校验通过的**行**（旧格式为意图条数）占比；
- 实际 token 用响应里的 `usage.prompt_tokens / completion_tokens`（真实 tokenizer）；
- 延迟为端到端墙钟；冷启动单列；
- 额外检查"能否一次输出多个**不同**执行者的任务"（计划 §7.A 最后一条）。

用法：
    python -m adjutant_coordinator.deploy.format_ab_test \
        --data tests/data/observations/real_20260912.jsonl \
        --data tests/data/observations/real_mass_20260912.jsonl \
        --mode both --out logs/format_ab_YYYYMMDD.json
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import statistics
import sys
import time
import types
import urllib.error
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))          # source/
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.dirname(HERE))

from adjutant_coordinator.deploy.env_file import load_env_file  # noqa: E402
from adjutant_coordinator.graph import pydantic_agents as pa  # noqa: E402
from adjutant_coordinator.graph.contracts import (  # noqa: E402
    ALLOWED_ACTIONS, DirectiveBatch,
)
from adjutant_coordinator.graph.model_context import build_tactics_context  # noqa: E402
from adjutant_coordinator.graph.squads import build_decision_frame, skill_matrix  # noqa: E402
from adjutant_coordinator.graph.task_patch import (  # noqa: E402
    MODE_DEEP, MODE_FAST, MODE_LIMITS, SKILL_TO_ACTION, SKILL_TITLE_CN,
    TaskPatchBatch, decode_task_patch, effective_max_rows,
)

# ---------------- 新格式提示词（短、无冗余，受输出预算约束） ----------------

# 提示词与紧凑输入表只有一处实现（生产模块），A/B 工具直接复用，避免两套漂移。
from adjutant_coordinator.graph.task_patch_prompt import (  # noqa: E402
    NEW_SYSTEM_PROMPT, NEW_USER_TEMPLATE, normalize_json_text,
    render_compact_text,
)


def call_raw(settings, system: str, user: str, *, max_tokens: int,
             timeout: float = 30.0) -> Tuple[float, str, Dict[str, Any], str]:
    """单次原始调用；返回 (秒, 文本, usage, 错误)。失败也记录，不重试。"""
    url = settings.base_url_for("tactics").rstrip("/") + "/chat/completions"
    body = {
        "model": settings.model_for("tactics"), "stream": False,
        "max_tokens": int(max_tokens), "temperature": 0,
        "reasoning_effort": "none",
        "response_format": {"type": "json_object"},
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": user}],
    }
    request = urllib.request.Request(
        url, data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json"})
    started = time.time()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as exc:
        return time.time() - started, "", {}, "HTTP %s: %s" % (
            exc.code, exc.read().decode("utf-8", "replace")[:200])
    except Exception as exc:  # noqa: BLE001
        return time.time() - started, "", {}, "%s: %s" % (type(exc).__name__, exc)
    elapsed = time.time() - started
    choice = (payload.get("choices") or [{}])[0]
    text = ((choice.get("message") or {}).get("content") or "")
    return elapsed, text, payload.get("usage") or {}, ""


# ---------------- 观测装载 ----------------

def load_observations(paths: Sequence[str]) -> Tuple[Dict[str, Any], List[Dict[str, Any]]]:
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


def state_view(header: Dict[str, Any], own_units: List[str], events: List[Dict[str, Any]]):
    return types.SimpleNamespace(
        match_id=str(header.get("match_id", "")), player_id=str(header.get("player_id", "")),
        rules_version=str(header.get("rules_version", "")),
        server_tick=int(header.get("server_tick", 0) or 0),
        latest_snapshot_id=int(header.get("snapshot_id", 0) or 0),
        plan_version="ab:v1", active_plan=None, active_tasks={}, active_intents=[],
        pending_requests={}, ai_controlled_units=list(own_units),
        player_controlled_units=[], released_units=[], degraded_reason="",
    )


# ---------------- 旧格式语义校验 ----------------

def old_semantic_problems(intents: List[Any], ctx: Dict[str, Any]) -> List[Tuple[int, str]]:
    """返回 [(意图序号, 原因)]；空列表 = 全部通过。"""
    own = {u["name"]: u for u in ctx.get("own_units") or []}
    res = {r["entity_id"] for r in ctx.get("visible_resources") or []}
    foes = set(ctx.get("visible_enemy_ids") or [])
    prod = {(str(o["producer"]), str(o["product"]))
            for o in ctx.get("production_options") or []}
    build = {(str(o["builder"]), str(o["building"]))
             for o in ctx.get("build_options") or []}
    moved = ("move", "attack_move", "defend", "retreat", "scout", "regroup")
    problems: List[Tuple[int, str]] = []
    for index, intent in enumerate(intents):
        def note(reason: str) -> None:
            problems.append((index, reason))

        action = str(intent.action)
        target = dict(intent.target or {})
        if action not in ALLOWED_ACTIONS:
            note("未知动作:%s" % action)
        if not intent.unit_ids:
            note("指令没有单位")
        for name in intent.unit_ids:
            if name not in own:
                note("单位不在观测:%s" % name)
            elif action == "gather" and not own[name].get("can_gather"):
                note("能力不匹配 gather:%s" % name)
            elif action == "produce" and not own[name].get("can_produce"):
                note("能力不匹配 produce:%s" % name)
            elif action == "build" and not own[name].get("can_build"):
                note("能力不匹配 build:%s" % name)
        entity = str(target.get("entity_id", ""))
        if action == "gather" and entity not in res:
            note("gather 目标不在可见资源:%s" % entity)
        if action == "attack" and entity not in foes:
            note("attack 目标不在可见敌人:%s" % entity)
        pos = target.get("pos")
        if action in moved and not pos:
            note("%s 缺坐标" % action)
        scene = str(target.get("scene", ""))
        producer = str(target.get("producer", ""))
        if action == "produce" and (producer, scene) not in prod:
            note("produce 组合不在选项:%s/%s" % (producer, scene))
        if action == "build" and (producer, scene) not in build:
            note("build 组合不在选项:%s/%s" % (producer, scene))
    return problems


# ---------------- 单条观测的两种格式 ----------------

def measure_one(observation: Dict[str, Any], rules: Dict[str, Any], settings,
                *, mode: str, want_old: bool = True, want_new: bool = True,
                timeout: float = 30.0) -> Dict[str, Any]:
    header = observation.get("header") or {}
    tactical = observation.get("tactical") or {}
    own_units = [str(e.get("name")) for e in (tactical.get("entities") or [])
                 if str(e.get("kind")) == "unit_self" and e.get("name")]
    events = [{"kind": "tick", "server_tick": int(header.get("server_tick", 0) or 0)}]
    state = state_view(header, own_units, events)
    record: Dict[str, Any] = {
        "source": observation.get("_source"), "seq": observation.get("seq"),
        "tick": int(header.get("server_tick", 0) or 0), "mode": mode,
        "own_units": len(own_units),
    }

    # ---- 旧格式：现有生产上下文 + TACTICS_SYSTEM_PROMPT ----
    if want_old:
        ctx = build_tactics_context(state, tactical=tactical, rules=rules, events=events)
        elapsed, text, usage, error = call_raw(
            settings, pa.TACTICS_SYSTEM_PROMPT,
            json.dumps(ctx, ensure_ascii=False, sort_keys=True),
            max_tokens=512, timeout=timeout)
        entry: Dict[str, Any] = {"seconds": elapsed, "error": error,
                                 "in": usage.get("prompt_tokens"),
                                 "out": usage.get("completion_tokens"),
                                 "chars_in": len(json.dumps(ctx, ensure_ascii=False)),
                                 "chars_out": len(text), "rows": 0,
                                 "structural_ok": False, "semantic_ok": 0,
                                 "squads": 0}
        try:
            entry["strict_ok"] = True
            json.loads(text)
        except Exception:  # noqa: BLE001
            entry["strict_ok"] = False
        try:
            batch = DirectiveBatch.model_validate(json.loads(normalize_json_text(text)))
            entry["structural_ok"] = True
            from adjutant_coordinator.graph.contracts import directives_to_intents
            intents = directives_to_intents(
                batch, plan_version="ab:v1",
                snapshot_id=int(header.get("snapshot_id", 0) or 0),
                server_tick=int(header.get("server_tick", 0) or 0),
                intent_ttl_ticks=600).intents
            entry["rows"] = len(intents)
            problems = old_semantic_problems(list(intents), ctx)
            entry["semantic_ok"] = max(0, len(intents) - len({i for i, _ in problems}))
            entry["problems"] = [reason for _, reason in problems][:4]
            entry["distinct_actors"] = len({u for i in intents for u in i.unit_ids})
            entry["sample"] = _sample_old(intents)
        except Exception as exc:  # noqa: BLE001
            entry["parse_error"] = "%s: %s" % (type(exc).__name__, str(exc)[:120])
            entry["sample"] = text[:120]
        record["old"] = entry

    # ---- 新格式：四列 ----
    if want_new:
        frame = build_decision_frame(
            match_id=str(header.get("match_id", "")),
            player_id=str(header.get("player_id", "")),
            rules_version=str(header.get("rules_version", "")),
            snapshot_id=int(header.get("snapshot_id", 0) or 0),
            server_tick=int(header.get("server_tick", 0) or 0),
            tactical=tactical, rules=rules, mode=mode, authorized_units=set(own_units),
            plan_version="ab:v1")
        user = NEW_USER_TEMPLATE % (
            render_compact_text(frame, balance=tactical.get("balance"),
                                deep=(mode == MODE_DEEP)),
            effective_max_rows(frame))
        elapsed, text, usage, error = call_raw(
            settings, NEW_SYSTEM_PROMPT, user,
            max_tokens=int(MODE_LIMITS[mode]["output_budget"]), timeout=timeout)
        entry = {"seconds": elapsed, "error": error, "in": usage.get("prompt_tokens"),
                 "out": usage.get("completion_tokens"), "chars_in": len(user),
                 "chars_out": len(text), "rows": 0, "structural_ok": False,
                 "semantic_ok": 0, "squads": 0, "actors": len(frame.actors),
                 "targets": len(frame.targets)}
        try:
            entry["strict_ok"] = True
            json.loads(text)
        except Exception:  # noqa: BLE001
            entry["strict_ok"] = False
        try:
            batch = TaskPatchBatch.model_validate(json.loads(normalize_json_text(text)))
            entry["structural_ok"] = True
            result = decode_task_patch(batch, frame)
            entry["rows"] = len(result.modifications) + len(result.rejections)
            entry["accepted"] = len(result.modifications)
            entry["semantic_ok"] = len(result.modifications)
            entry["reject_reasons"] = [r.reason for r in result.rejections][:8]
            entry["reject_rows"] = [r.row for r in result.rejections][:8]
            entry["distinct_actors"] = len({m.actor_ref for m in result.modifications})
            entry["skills"] = [m.skill for m in result.modifications][:6]
            entry["sample"] = [[m.actor_ref, m.skill, m.target_ref, m.params_ref]
                               for m in result.modifications][:6]
            entry["truncated"] = bool(text) and not text.rstrip().endswith("}")
        except Exception as exc:  # noqa: BLE001
            entry["parse_error"] = "%s: %s" % (type(exc).__name__, str(exc)[:120])
            entry["truncated"] = bool(text) and not text.rstrip().endswith("}")
            entry["sample"] = text[:120]
        record["new"] = entry
    return record


def _sample_old(intents: List[Any]) -> List[List[str]]:
    out = []
    for intent in intents[:4]:
        target = dict(intent.target or {})
        out.append([intent.action, ",".join(intent.unit_ids[:2]),
                    str(target.get("entity_id") or target.get("scene") or "")]
                   [:3])
    return out


# ---------------- 汇总 ----------------

def percentile(values: List[float], p: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(p / 100.0 * (len(ordered) - 1))))]


def summarize(records: List[Dict[str, Any]], key: str) -> Dict[str, Any]:
    entries = [r[key] for r in records if key in r]
    if not entries:
        return {}
    latencies = [e["seconds"] for e in entries if not e.get("error")]
    structural = sum(1 for e in entries if e.get("structural_ok"))
    strict = sum(1 for e in entries if e.get("strict_ok"))
    rows = sum(int(e.get("rows", 0)) for e in entries)
    semantic = sum(int(e.get("semantic_ok", 0)) for e in entries)
    empty = sum(1 for e in entries if e.get("structural_ok") and not e.get("rows"))
    multi = sum(1 for e in entries if int(e.get("distinct_actors", 0)) >= 2)
    errors = sum(1 for e in entries if e.get("error"))
    trunc = sum(1 for e in entries if e.get("truncated"))
    inputs = [e["in"] for e in entries if e.get("in")]
    outputs = [e["out"] for e in entries if e.get("out") is not None]
    return {
        "n": len(entries), "errors": errors, "truncated": trunc,
        "structural_ok": structural,
        "structural_rate": round(100.0 * structural / len(entries), 1),
        "strict_ok": strict,
        "strict_rate": round(100.0 * strict / len(entries), 1),
        "rows": rows, "semantic_ok": semantic,
        "semantic_rate": round(100.0 * semantic / rows, 1) if rows else None,
        "empty_batches": empty,
        "multi_actor_batches": multi,
        "latency_p50": round(percentile(latencies, 50), 3),
        "latency_p95": round(percentile(latencies, 95), 3),
        "latency_max": round(max(latencies), 3) if latencies else None,
        "in_tokens_p50": percentile(inputs, 50) if inputs else None,
        "in_tokens_max": max(inputs) if inputs else None,
        "out_tokens_p50": percentile(outputs, 50) if outputs else None,
        "out_tokens_max": max(outputs) if outputs else None,
        "chars_in_p50": percentile([e["chars_in"] for e in entries], 50),
    }


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="短决策接口 A/B（旧 vs 四列）")
    parser.add_argument("--data", action="append", default=[])
    parser.add_argument("--limit", type=int, default=0, help="每个文件最多取多少条（0=全部）")
    parser.add_argument("--mode", default="both", choices=("fast", "deep", "both"))
    parser.add_argument("--only", default="both", choices=("both", "old", "new"))
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--env-file", default=os.path.join(
        ROOT, "adjutant_coordinator", ".env.local"))
    parser.add_argument("--out", default=os.path.join(
        ROOT, "adjutant_coordinator", "logs",
        time.strftime("format_ab_%Y%m%d_%H%M%S.json")))
    args = parser.parse_args(argv)

    load_env_file(args.env_file)
    settings = pa.GraphModelSettings.from_env()
    paths = args.data or sorted(glob.glob(os.path.join(
        ROOT, "adjutant_coordinator", "tests", "data", "observations", "*.jsonl")))
    if not paths:
        print("没有观测数据：先跑 capture_observations.py", file=sys.stderr)
        return 2
    rules, observations = load_observations(paths)
    if args.limit:
        grouped: Dict[str, List[Dict[str, Any]]] = {}
        for item in observations:
            grouped.setdefault(str(item.get("_source")), []).append(item)
        observations = [item for items in grouped.values() for item in items[:args.limit]]
    modes = [MODE_FAST, MODE_DEEP] if args.mode == "both" else [args.mode]
    print("模型=%s 端点=%s 观测=%d 条（%d 文件）模式=%s"
          % (settings.model_for("tactics"), settings.base_url_for("tactics"),
             len(observations), len(paths), modes))

    want_old, want_new = args.only in ("both", "old"), args.only in ("both", "new")
    records: List[Dict[str, Any]] = []
    cold: Dict[str, float] = {}
    started_all = time.time()
    for mode in modes:
        for index, observation in enumerate(observations):
            if want_new and ("new:" + mode) not in cold:
                measure_one(observation, rules, settings, mode=mode,
                            want_old=False, timeout=args.timeout)   # 预热（不计成绩）
                cold["new:" + mode] = 0.0
            if want_old and "old" not in cold:
                measure_one(observation, rules, settings, mode=mode,
                            want_new=False, timeout=args.timeout)
                cold["old"] = 0.0
            record = measure_one(observation, rules, settings, mode=mode,
                                 want_old=want_old, want_new=want_new,
                                 timeout=args.timeout)
            records.append(record)
            if index == 0 and want_new:
                cold["new_seconds:" + mode] = record.get("new", {}).get("seconds")
            if index == 0 and want_old:
                cold["old_seconds"] = record.get("old", {}).get("seconds")
            if want_new and index == 0:
                first = record.get("new", {})
                print("冷启动(%s) 新格式: %.2fs in=%s out=%s 结构=%s"
                      % (mode, first.get("seconds", 0), first.get("in"),
                         first.get("out"), first.get("structural_ok")))
            if (index + 1) % 20 == 0:
                print("  ... %d/%d（%.0fs）" % (index + 1, len(observations),
                                               time.time() - started_all))

    summary = {
        "model": settings.model_for("tactics"),
        "endpoint": settings.base_url_for("tactics"),
        "observations": len(observations), "data_files": [os.path.basename(p) for p in paths],
        "cold_start_seconds": cold,
        "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "summary": {mode: {"old": summarize([r for r in records if r["mode"] == mode], "old"),
                           "new": summarize([r for r in records if r["mode"] == mode], "new")}
                    for mode in modes},
        "records": records,
    }
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(summary, handle, ensure_ascii=False, indent=2)

    for mode in modes:
        print("\n===== %s（N=%d）=====" % (mode, len(observations)))
        for key in ("old", "new"):
            block = summary["summary"][mode][key]
            if not block:
                continue
            print("  [%s] 结构合法 %.1f%%（严格 %.1f%%）| 语义合法 %s | 行数 %d | 空批次 %d | "
                  "多执行者 %d | P50 %.2fs P95 %.2fs | in P50 %s out P50 %s (max %s)"
                  % (key, block["structural_rate"], block["strict_rate"],
                     block["semantic_rate"], block["rows"],
                     block["empty_batches"], block["multi_actor_batches"],
                     block["latency_p50"], block["latency_p95"], block["in_tokens_p50"],
                     block["out_tokens_p50"], block["out_tokens_max"]))
            if block["errors"] or block["truncated"]:
                print("      错误 %d 截断 %d" % (block["errors"], block["truncated"]))
    print("\n结果文件：%s（用时 %.0fs）" % (args.out, time.time() - started_all))
    return 0


if __name__ == "__main__":
    sys.exit(main())
