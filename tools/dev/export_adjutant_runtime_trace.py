#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""副官运行时追踪导出：真实对局的 `trace.jsonl` + 留档 → 中文时间表 + 交互 HTML。

用途（第一阶段 · 修改 1 的验收要求"新日志回放"）：
- 读一次真实对局的运行目录（`adjutant_observe.py` 的产物），把**运行时追踪**
  （节点 span / 选边 / 候选条件 / 任务 / 命令 / 模型调用）与留档（世界事实 /
  决策 / 回执 / 事件）按轮次对齐；
- 产出完整中文 Markdown 时间表与可交互 HTML：按时间、任务或节点检查实际路径，
  区分成功 / 正常等待 / 失败·超时 / 受阻 / 未知，显示最后进展与等待时长、
  选边原因；模型输入/输出给全文与原件链接，不伪造内部推理；
- manifest 记录输入哈希与计数；拒绝覆盖已有产物（重导出用新输出路径）。

用法：
    python tools/dev/export_adjutant_runtime_trace.py --run <对局目录> --output <报告名>

输入目录约定（缺项明确标"缺失"，不猜）：
    trace.jsonl                      运行时追踪（graph/trace.py 的合同）
    runner-logs/archive_*/rounds.jsonl / decisions.jsonl / commands.jsonl / events.jsonl
    attempts/*.context.json|*.result.json   模型输入/输出全文
    http.jsonl                       实际 HTTP 请求/响应（旁路记录）
    world.jsonl / summary.json       世界采样与运行摘要
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

SCHEMA = "airts-adjutant-runtime-trace-export"
VERSION = 1

ROUTE_CN = {
    "strategic": "战略分支",
    "tactical": "战术分支",
    "emergency_tactical": "紧急战术分支",
    "wait": "等待（不发新决策）",
    "player_interrupt": "玩家打断协调",
}

TASK_EVENT_CN = {
    "created": "任务建立",
    "progress": "进展更新",
    "waiting": "等待玩家",
    "succeeded": "成功关闭",
    "failed": "失败",
    "timeout": "超时",
    "blocked": "受阻",
    "diagnose": "进入诊断",
    "recovering": "恢复尝试",
    "reassigned": "改派",
    "interrupted": "中断（可恢复）",
    "expired": "过期",
    "unknown": "未知（证据不足）",
    "changed": "状态变化",
}

COMMAND_EVENT_CN = {
    "receipt": "命令回执",
    "recheck": "回执复核",
    "dropped": "仲裁丢弃（未下发）",
    "timeout": "等待超时（保持占用）",
}

MODEL_ROLE_CN = {"strategy": "战略模型", "tactics": "战术适配器"}

STATUS_CN = {
    "Accepted": "已接受",
    "Completed": "已完成",
    "Rejected": "被拒绝",
    "PendingAuthority": "等待权威确认",
    "Expired": "已过期",
    "StaleGeneration": "代际过期",
    "PlayerOverride": "玩家接管",
    "LedgerFull": "登记表已满",
    "Busy": "繁忙",
    "TransportError": "通道异常",
    "NoTransport": "无通道",
    "ok": "成功",
    "expired": "过期结果被拒",
    "stale_snapshot": "观测过旧被拒",
    "stale_generation": "代际过期被拒",
    "error": "调用异常",
    "dropped": "已丢弃",
}


def cn_status(status: str) -> str:
    return STATUS_CN.get(str(status or ""), str(status or ""))


def read_jsonl(path: str) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    if not os.path.exists(path):
        return rows
    with open(path, "r", encoding="utf-8") as handle:
        for line_no, raw in enumerate(handle, start=1):
            line = raw.strip()
            if not line:
                continue
            try:
                item = json.loads(line)
            except ValueError:
                continue
            if isinstance(item, dict):
                item.setdefault("_line", line_no)
                rows.append(item)
    return rows


def sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def find_archive(run_dir: str) -> str:
    logs = os.path.join(run_dir, "runner-logs")
    if not os.path.isdir(logs):
        return ""
    archives = sorted(
        (os.path.join(logs, name) for name in os.listdir(logs)
         if name.startswith("archive_")))
    return archives[0] if archives else ""


def load_run(run_dir: str) -> Dict[str, Any]:
    """读入一次运行的全部证据（缺项记 missing，不猜）。"""
    run: Dict[str, Any] = {"run_dir": run_dir, "missing": []}
    trace_path = ""
    for candidate in (os.path.join(run_dir, "trace.jsonl"),
                      os.path.join(run_dir, "runner-logs", "trace.jsonl")):
        if os.path.exists(candidate):
            trace_path = candidate
            break
    run["trace_path"] = trace_path
    run["trace"] = read_jsonl(trace_path) if trace_path else []
    if not run["trace"]:
        run["missing"].append("trace.jsonl（运行时追踪；旧样本没有它）")
    archive = find_archive(run_dir)
    run["archive"] = archive
    for name in ("rounds", "decisions", "commands", "events"):
        rows = read_jsonl(os.path.join(archive, "%s.jsonl" % name)) if archive else []
        run[name] = rows
        if archive and not rows:
            run["missing"].append("archive/%s.jsonl" % name)
    attempts_dir = os.path.join(run_dir, "attempts")
    run["attempts"] = {}
    if os.path.isdir(attempts_dir):
        for name in sorted(os.listdir(attempts_dir)):
            if name.endswith(".context.json"):
                attempt_id = name[: -len(".context.json")]
                context_path = os.path.join(attempts_dir, name)
                result_path = os.path.join(attempts_dir, attempt_id + ".result.json")
                entry: Dict[str, Any] = {"context_path": context_path}
                if os.path.exists(result_path):
                    entry["result_path"] = result_path
                    try:
                        with open(result_path, "r", encoding="utf-8") as handle:
                            entry["result"] = json.load(handle)
                    except ValueError:
                        entry["result"] = None
                run["attempts"][attempt_id] = entry
    else:
        run["missing"].append("attempts/（模型输入输出全文）")
    run["attempt_ends"] = [row for row in read_jsonl(os.path.join(run_dir, "attempts.jsonl"))
                           if row.get("kind") == "attempt_end"]
    run["http"] = read_jsonl(os.path.join(run_dir, "http.jsonl"))
    run["world"] = read_jsonl(os.path.join(run_dir, "world.jsonl"))
    summary_path = os.path.join(run_dir, "summary.json")
    run["summary"] = {}
    if os.path.exists(summary_path):
        try:
            with open(summary_path, "r", encoding="utf-8") as handle:
                run["summary"] = json.load(handle)
        except ValueError:
            run["summary"] = {}
    else:
        run["missing"].append("summary.json")
    return run


# ---------------------------------------------------------------------------
# 轮次视图：把追踪事件按 round_seq 归组，并与留档/模型调用对齐
# ---------------------------------------------------------------------------


def build_rounds(run: Dict[str, Any]) -> List[Dict[str, Any]]:
    rounds: Dict[int, Dict[str, Any]] = {}
    order: List[int] = []
    for entry in run["trace"]:
        seq = int(entry.get("round_seq", 0) or 0)
        if seq not in rounds:
            rounds[seq] = {"round_seq": seq, "server_tick": 0, "events": [],
                           "spans": [], "edges": [], "candidates": [], "tasks": [],
                           "commands": [], "models": [], "notes": []}
            order.append(seq)
        bucket = rounds[seq]
        bucket["events"].append(entry)
        if int(entry.get("server_tick", 0) or 0) > bucket["server_tick"]:
            bucket["server_tick"] = int(entry.get("server_tick", 0) or 0)
        kind = str(entry.get("kind", ""))
        if kind == "round" and entry.get("phase") == "begin":
            bucket["begin"] = entry
        elif kind == "round" and entry.get("phase") == "end":
            bucket["end"] = entry
        elif kind == "node_span":
            bucket["spans"].append(entry)
        elif kind == "edge":
            bucket["edges"].append(entry)
        elif kind == "candidate_eval":
            bucket["candidates"].append(entry)
        elif kind == "task":
            bucket["tasks"].append(entry)
        elif kind == "command":
            bucket["commands"].append(entry)
        elif kind == "model_call":
            bucket["models"].append(entry)
        elif kind == "note":
            bucket["notes"].append(entry)
    out = [rounds[seq] for seq in sorted(order)]
    # 世界事实（rounds.jsonl 按 ts/server_tick 就近对齐——只做展示对齐，
    # 追踪事件本身的顺序一律按 seq，不靠时间戳猜因果）。
    world_rows = run.get("rounds") or []
    for bucket in out:
        tick = bucket["server_tick"]
        nearest = None
        best = None
        for row in world_rows:
            delta = abs(int(row.get("server_tick", 0) or 0) - tick)
            if best is None or delta < best:
                best, nearest = delta, row
        bucket["world"] = nearest
    return out


def match_attempts_to_rounds(run: Dict[str, Any], rounds: List[Dict[str, Any]],
                             slack_seconds: float = 20.0) -> None:
    """模型调用 → 轮次：按 attempt 起止时间窗包含 round 开始时间匹配。

    跨轮异步返回不按"最近一次"猜：attempt_end 的 started_at/latency 给出
    真实时间窗，round 的 ts_mono 落在窗内才关联；窗外的不关联（标未匹配）。
    """
    starts = {row.get("attempt_id"): row for row in run["attempt_ends"]}
    for bucket in rounds:
        begin = bucket.get("begin") or {}
        round_ts = float(begin.get("ts_wall", 0) or 0)
        bucket["attempts"] = []
        if not round_ts:
            continue
        for attempt_id, end in starts.items():
            started = float(end.get("started_at", 0) or 0)
            latency = float(end.get("latency_s", 0) or 0)
            if started and started - slack_seconds <= round_ts <= started + latency + slack_seconds:
                bucket["attempts"].append({"attempt_id": attempt_id, "end": end})
    # 每个 round 的模型输入/输出全文（attempts 目录）
    for bucket in rounds:
        for item in bucket["attempts"]:
            entry = run["attempts"].get(item["attempt_id"])
            if entry:
                item["context_path"] = entry.get("context_path", "")
                item["result_path"] = entry.get("result_path", "")
                item["result"] = entry.get("result")


# ---------------------------------------------------------------------------
# 汇总指标
# ---------------------------------------------------------------------------


def build_metrics(run: Dict[str, Any], rounds: List[Dict[str, Any]]) -> Dict[str, Any]:
    trace = run["trace"]
    metrics: Dict[str, Any] = {}
    metrics["rounds"] = len(rounds)
    metrics["trace_events"] = len(trace)
    metrics["node_spans"] = sum(1 for e in trace if e.get("kind") == "node_span")
    metrics["edges"] = sum(1 for e in trace if e.get("kind") == "edge")
    metrics["candidate_evals"] = sum(1 for e in trace if e.get("kind") == "candidate_eval")
    metrics["task_events"] = sum(1 for e in trace if e.get("kind") == "task")
    metrics["command_events"] = sum(1 for e in trace if e.get("kind") == "command")
    metrics["model_calls"] = sum(1 for e in trace if e.get("kind") == "model_call")
    metrics["notes"] = sum(1 for e in trace if e.get("kind") == "note")
    metrics["diagnostic_errors"] = sum(
        1 for e in trace if e.get("kind") == "note" and e.get("note") == "diagnostic_error")
    # 路由分布
    routes: Dict[str, int] = {}
    for entry in trace:
        if entry.get("kind") == "edge":
            route = str(entry.get("route", ""))
            routes[route] = routes.get(route, 0) + 1
    metrics["routes"] = routes
    # 任务终态分布
    task_events: Dict[str, int] = {}
    for entry in trace:
        if entry.get("kind") == "task":
            key = str(entry.get("event", ""))
            task_events[key] = task_events.get(key, 0) + 1
    metrics["task_event_counts"] = task_events
    # 命令回执状态分布
    statuses: Dict[str, int] = {}
    for entry in trace:
        if entry.get("kind") == "command":
            key = str(entry.get("status", ""))
            statuses[key] = statuses.get(key, 0) + 1
    metrics["command_status_counts"] = statuses
    # 模型调用结果分布
    model_results: Dict[str, int] = {}
    for entry in trace:
        if entry.get("kind") == "model_call" and entry.get("phase") == "result":
            key = str(entry.get("status", ""))
            model_results[key] = model_results.get(key, 0) + 1
    metrics["model_result_counts"] = model_results
    # 每轮事件数（追踪开销）
    per_round = [len(bucket["events"]) for bucket in rounds]
    metrics["events_per_round_avg"] = round(sum(per_round) / max(1, len(per_round)), 1)
    metrics["events_per_round_max"] = max(per_round) if per_round else 0
    if run["trace_path"]:
        metrics["trace_file_bytes"] = os.path.getsize(run["trace_path"])
    # 世界事实：余额轨迹与首次交货（策略上下文里的经济事实）
    balances = [(row.get("ts"), row.get("balance")) for row in run.get("rounds") or []
                if row.get("balance") is not None]
    metrics["balance_samples"] = len(balances)
    metrics["balance_first"] = balances[0][1] if balances else None
    metrics["balance_last"] = balances[-1][1] if balances else None
    first_delivery = find_first_delivery(run)
    metrics["first_delivery"] = first_delivery
    # 闭环指标：最长无进展、失败→诊断延迟、恢复尝试与重复失败（全部从追踪事件算）。
    task_rows = [e for e in trace if e.get("kind") == "task"]
    stalled = [_as_int(e.get("stalled_ticks")) for e in task_rows
               if e.get("stalled_ticks") is not None]
    metrics["longest_no_progress_ticks"] = max(stalled) if stalled else 0
    metrics["recovery_attempts"] = sum(1 for e in task_rows
                                       if e.get("reason_code") == "recovery_attempt")
    metrics["budget_exhausted"] = sum(1 for e in task_rows
                                      if e.get("reason_code") == "retry_budget_exhausted")
    metrics["deadline_timeouts"] = sum(1 for e in task_rows
                                       if e.get("reason_code") == "total_deadline")
    metrics["no_progress_edges"] = sum(1 for e in task_rows
                                       if e.get("reason_code") == "no_progress_limit")
    metrics["success_closures"] = sum(1 for e in task_rows
                                      if e.get("reason_code") == "success_evidence")
    # 里程碑推进（strategy-state 的 campaign 采样）
    metrics["milestones"] = milestone_timeline(run)
    # 等待/失败时长
    metrics["longest_wait"] = longest_wait(rounds)
    return metrics


def _as_int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def find_first_delivery(run: Dict[str, Any]) -> Dict[str, Any]:
    """首次交货证据：只认策略上下文/经济事实里的 delivered>0（不拿余额推断）。"""
    best: Dict[str, Any] = {}
    for attempt_id, entry in sorted(run["attempts"].items()):
        # 上下文在 context 文件里；读它的 economy 段（若存在）。
        path = entry.get("context_path", "")
        if not path or not os.path.exists(path):
            continue
        try:
            with open(path, "r", encoding="utf-8") as handle:
                context = json.load(handle)
        except ValueError:
            continue
        economy = None
        campaign = context.get("campaign") if isinstance(context, dict) else None
        if isinstance(campaign, dict):
            economy = campaign.get("economy")
        if isinstance(economy, dict) and int(economy.get("refinery_delivered", 0) or 0) > 0:
            best = {"attempt_id": attempt_id, "context": path,
                    "refinery_delivered": int(economy.get("refinery_delivered", 0) or 0),
                    "refinery_constructed": int(economy.get("refinery_constructed", 0) or 0)}
            break
    return best or {"attempt_id": "", "context": "", "refinery_delivered": 0,
                    "refinery_constructed": 0, "note": "未观测到首次交货证据"}


def milestone_timeline(run: Dict[str, Any]) -> List[Dict[str, Any]]:
    """里程碑状态变化时间线（来自 runner 的 campaign 采样；缺样本标缺失）。

    采样里的 `milestones` 有两种历史形状：`{key: status}` 与 `{key: {status: …}}`，
    两种都认（旧留档不得因形状变化读不出来）。
    """
    path = os.path.join(run["run_dir"], "strategy-state.jsonl")
    rows = read_jsonl(path)
    out: List[Dict[str, Any]] = []
    previous: Dict[str, str] = {}
    for row in rows:
        campaign = row.get("campaign") if isinstance(row.get("campaign"), dict) else {}
        milestones = campaign.get("milestones") if isinstance(campaign, dict) else {}
        if not isinstance(milestones, dict):
            continue
        for key, value in sorted(milestones.items()):
            if isinstance(value, dict):
                status = str(value.get("status", ""))
            else:
                status = str(value or "")
            if status and previous.get(key) != status:
                out.append({"server_tick": row.get("server_tick"), "milestone": key,
                            "status": status, "previous": previous.get(key, "")})
                previous[key] = status
    return out


def longest_wait(rounds: List[Dict[str, Any]]) -> Dict[str, Any]:
    """最长无命令轮次（展示"正常等待"的形态；不等于无进展判定）。"""
    best = {"round_seq": 0, "server_tick": 0, "route": "", "since_previous": 0.0}
    previous_ts = None
    for bucket in rounds:
        begin = bucket.get("begin") or {}
        ts = float(begin.get("ts_wall", 0) or 0)
        if previous_ts is not None and ts > previous_ts:
            gap = ts - previous_ts
            if gap > best["since_previous"]:
                best = {"round_seq": bucket["round_seq"],
                        "server_tick": bucket["server_tick"],
                        "route": str((bucket["edges"] or [{}])[0].get("route", ""))
                        if bucket["edges"] else "",
                        "since_previous": round(gap, 3)}
        if ts:
            previous_ts = ts
    return best


# ---------------------------------------------------------------------------
# Markdown 渲染
# ---------------------------------------------------------------------------


def fmt_ts(ts: Any, base: float = 0.0) -> str:
    try:
        value = float(ts or 0)
    except (TypeError, ValueError):
        return "-"
    if base and value >= base:
        return "%06.1fs" % (value - base)
    return time.strftime("%H:%M:%S", time.localtime(value))


def rel(path: str, run_dir: str) -> str:
    try:
        return os.path.relpath(path, run_dir).replace("\\", "/")
    except ValueError:
        return path


def build_branch_graph(run: Dict[str, Any], rounds: List[Dict[str, Any]]) -> str:
    """从**实际追踪**生成分支图（mermaid）：节点流转 + 选边计数 + 失败/恢复标注。

    不是静态图：每条边都是本局真实发生过的路由；失败/超时/受阻的任务单独列出，
    回答"每个失败场景在哪里发生、为何选边、最终落在哪里"。
    """
    edges: Dict[Tuple[str, str], int] = {}
    routes: Dict[str, int] = {}
    for bucket in rounds:
        for edge in bucket["edges"]:
            key = (str(edge.get("from", "")), str(edge.get("to", "")))
            edges[key] = edges.get(key, 0) + 1
            route = str(edge.get("route", ""))
            routes[route] = routes.get(route, 0) + 1
    task_rows = [e for e in run["trace"] if e.get("kind") == "task"]
    failure_tasks: Dict[str, Dict[str, Any]] = {}
    for entry in task_rows:
        event = str(entry.get("event", ""))
        if event in ("failed", "timeout", "blocked", "diagnose", "recovering"):
            task_id = str(entry.get("task_id", ""))
            row = failure_tasks.setdefault(task_id, {"events": [], "last": entry})
            row["events"].append(event)
            row["last"] = entry
    lines = ["```mermaid", "flowchart TD"]
    nodes = sorted({node for key in edges for node in key})
    for node in nodes:
        lines.append("    %s[%s]" % (_mermaid_id(node), node))
    for (src, dst), count in sorted(edges.items(), key=lambda item: -item[1]):
        lines.append("    %s -->|%d 轮| %s" % (_mermaid_id(src), count, _mermaid_id(dst)))
    if failure_tasks:
        lines.append("    subgraph 失败与恢复")
        for task_id, row in sorted(failure_tasks.items()):
            last = row["last"]
            label = "%s：%s（%s）" % (task_id, "→".join(row["events"][-4:]),
                                    str(last.get("reason_cn", ""))[:40])
            lines.append("        %s[%s]" % (_mermaid_id("task-" + task_id), label))
        lines.append("    end")
    lines.append("```")
    return "\n".join(lines)


def _mermaid_id(name: str) -> str:
    return "n_" + "".join(ch if ch.isalnum() else "_" for ch in str(name))


def render_markdown(run: Dict[str, Any], rounds: List[Dict[str, Any]],
                    metrics: Dict[str, Any], out_path: str) -> str:
    summary = run["summary"]
    base_ts = float(summary.get("observation_start", 0) or 0)
    lines: List[str] = []
    lines.append("# AI 副官运行时追踪：真实对局时间表（修改 1 交付）")
    lines.append("")
    lines.append("本报告由 `tools/dev/export_adjutant_runtime_trace.py` 从**真实对局**的运行时追踪生成。")
    lines.append("追踪合同：`graph/trace.py`（schema=%s v%d）。" % (SCHEMA, VERSION))
    lines.append("")
    lines.append("## 运行身份")
    lines.append("")
    lines.append("| 项目 | 值 |")
    lines.append("|---|---|")
    lines.append("| 对局目录 | `%s` |" % run["run_dir"])
    lines.append("| 状态 | %s |" % summary.get("status", "unknown"))
    lines.append("| 观察秒数（墙钟） | %s |" % summary.get("observed_seconds", "-"))
    lines.append("| 入口 | %s |" % summary.get("entry", "-"))
    lines.append("| 引擎 / 战术 | %s / %s |" % (summary.get("engine", "-"),
                                              summary.get("tactics", "-")))
    model = summary.get("model") or {}
    lines.append("| 模型 | %s |" % model.get("model", "-"))
    lines.append("| 模型参数 SHA-256 | %s |" % str(model.get("manifest_sha256", "-"))[:16])
    lines.append("| 端口 | %s |" % json.dumps(summary.get("ports", {}), ensure_ascii=False))
    lines.append("| 源码变更 | %s |" % ("无" if not summary.get("source_changed")
                                        else json.dumps(summary.get("source_changed"),
                                                        ensure_ascii=False)))
    lines.append("")
    lines.append("## 汇总指标")
    lines.append("")
    lines.append("| 指标 | 值 |")
    lines.append("|---|---:|")
    for key in ("rounds", "trace_events", "node_spans", "edges", "candidate_evals",
                "task_events", "command_events", "model_calls", "notes",
                "diagnostic_errors", "events_per_round_avg", "events_per_round_max",
                "trace_file_bytes", "balance_samples",
                "longest_no_progress_ticks", "no_progress_edges", "deadline_timeouts",
                "recovery_attempts", "budget_exhausted", "success_closures"):
        lines.append("| %s | %s |" % (key, metrics.get(key, "-")))
    lines.append("| 余额 首→末 | %s → %s |" % (metrics.get("balance_first"),
                                              metrics.get("balance_last")))
    lines.append("")
    lines.append("路由分布：%s" % json.dumps(
        {ROUTE_CN.get(k, k): v for k, v in (metrics.get("routes") or {}).items()},
        ensure_ascii=False))
    lines.append("")
    lines.append("任务事件分布：%s" % json.dumps(
        {TASK_EVENT_CN.get(k, k): v for k, v in (metrics.get("task_event_counts") or {}).items()},
        ensure_ascii=False))
    lines.append("")
    lines.append("命令状态分布：%s" % json.dumps(
        {cn_status(k): v for k, v in (metrics.get("command_status_counts") or {}).items()},
        ensure_ascii=False))
    lines.append("")
    lines.append("模型结果分布：%s" % json.dumps(
        {cn_status(k): v for k, v in (metrics.get("model_result_counts") or {}).items()},
        ensure_ascii=False))
    lines.append("")
    delivery = metrics.get("first_delivery") or {}
    lines.append("首次交货证据：%s" % (
        "未观测到（上下文 %s）" % delivery.get("attempt_id", "-")
        if not delivery.get("refinery_delivered") else
        "%s：矿场完工 %s、累计交货 %s（原件 %s）" % (
            delivery.get("attempt_id"), delivery.get("refinery_constructed"),
            delivery.get("refinery_delivered"), rel(delivery.get("context", ""), run["run_dir"]))))
    lines.append("")
    lines.append("最长已记录轮次间隔（不表示连续采样或正常等待）：%s" % json.dumps(
        metrics.get("longest_wait", {}), ensure_ascii=False))
    lines.append("")
    lines.append("### 里程碑时间线")
    lines.append("")
    lines.append("| tick | 里程碑 | 状态 | 之前 |")
    lines.append("|---:|---|---|---|")
    for item in (metrics.get("milestones") or [])[:40]:
        lines.append("| %s | %s | %s | %s |" % (
            item.get("server_tick"), item.get("milestone"), item.get("status"),
            item.get("previous") or "-"))
    if not metrics.get("milestones"):
        lines.append("| - | （无 campaign 采样） | - | - |")
    lines.append("")
    if run["missing"]:
        lines.append("### 缺失项（明确标注，不补造）")
        lines.append("")
        for item in run["missing"]:
            lines.append("- %s" % item)
        lines.append("")
    # ---- 逐轮时间表 ----
    lines.append("## 实际分支图（由本局追踪生成）")
    lines.append("")
    lines.append("边上的数字是本局**真实发生**的轮次数；失败/超时/受阻/恢复的任务单列。")
    lines.append("")
    lines.append(build_branch_graph(run, rounds))
    lines.append("")
    lines.append("## 逐轮时间表")
    lines.append("")
    lines.append("每轮一行：轮次（round_seq，不用 tick 构造）/ tick / 墙钟 / 路由与选边原因 /")
    lines.append("节点 span 数 / 候选评估 / 任务事件 / 命令事件 / 模型调用。")
    lines.append("")
    lines.append("| 轮 | tick | 墙钟 | 选边（原因） | span | 候选 | 任务 | 命令 | 模型 |")
    lines.append("|---:|---:|---|---|---:|---:|---:|---:|---:|")
    for bucket in rounds:
        begin = bucket.get("begin") or {}
        edge = (bucket["edges"] or [{}])[0]
        route = ROUTE_CN.get(str(edge.get("route", "")), str(edge.get("route", "")) or "-")
        reason = str(edge.get("reason_cn", ""))[:40]
        lines.append("| %d | %s | %s | %s（%s） | %d | %d | %d | %d | %d |" % (
            bucket["round_seq"], bucket["server_tick"], fmt_ts(begin.get("ts_wall"), base_ts),
            route, reason, len(bucket["spans"]), len(bucket["candidates"]),
            len(bucket["tasks"]), len(bucket["commands"]), len(bucket["models"])))
    lines.append("")
    # ---- 任务链 ----
    lines.append("## 任务链（成功 / 等待 / 失败·超时 / 受阻 / 未知）")
    lines.append("")
    task_events = [e for e in run["trace"] if e.get("kind") == "task"]
    by_task: Dict[str, List[Dict[str, Any]]] = {}
    for entry in task_events:
        by_task.setdefault(str(entry.get("task_id", "")), []).append(entry)
    lines.append("| 任务 | 目标 | 事件序列（按 seq） |")
    lines.append("|---|---|---|")
    for task_id in sorted(by_task):
        rows = sorted(by_task[task_id], key=lambda item: int(item.get("seq", 0)))
        goal = next((str(r.get("goal_id", "")) for r in rows if r.get("goal_id")), "")
        chain = " → ".join("%s@r%s" % (TASK_EVENT_CN.get(str(r.get("event", "")),
                                                       str(r.get("event", ""))),
                                       r.get("round_seq"))
                           for r in rows[-12:])
        lines.append("| `%s` | %s | %s |" % (task_id, goal or "-", chain))
    if not by_task:
        lines.append("| - | - | 本局无任务事件 |")
    lines.append("")
    # ---- 命令链 ----
    lines.append("## 命令链（提交 → 回执 → 复核 → 结果）")
    lines.append("")
    command_events = [e for e in run["trace"] if e.get("kind") == "command"]
    by_intent: Dict[str, List[Dict[str, Any]]] = {}
    for entry in command_events:
        by_intent.setdefault(str(entry.get("intent_id", "")), []).append(entry)
    lines.append("| 意图 | 命令 | 尝试 | 链（按 seq） |")
    lines.append("|---|---|---:|---|")
    for intent_id in sorted(by_intent):
        rows = sorted(by_intent[intent_id], key=lambda item: int(item.get("seq", 0)))
        command_id = next((str(r.get("command_id", "")) for r in rows
                           if r.get("command_id")), "")
        attempts = max(int(r.get("attempt", 0) or 0) for r in rows)
        chain = " → ".join("%s(%s)" % (COMMAND_EVENT_CN.get(str(r.get("event", "")),
                                                         str(r.get("event", ""))),
                                       cn_status(r.get("status", "")))
                           for r in rows[-8:])
        lines.append("| `%s` | `%s` | %d | %s |" % (intent_id, command_id, attempts, chain))
    if not by_intent:
        lines.append("| - | - | - | 本局无命令事件 |")
    lines.append("")
    # ---- 模型输入/输出全文索引 ----
    lines.append("## 模型调用（完整可观测输入/输出）")
    lines.append("")
    lines.append("原文可展开/链接；不记录也不推测隐藏推理。")
    lines.append("")
    lines.append("| 调用 | 角色 | 开始(墙钟) | 耗时s | 结果 | 输入全文 | 输出全文 |")
    lines.append("|---|---|---:|---:|---|---|---|")
    for end in run["attempt_ends"]:
        attempt_id = str(end.get("attempt_id", ""))
        entry = run["attempts"].get(attempt_id) or {}
        context_rel = rel(entry.get("context_path", ""), run["run_dir"])
        result_rel = rel(entry.get("result_path", ""), run["run_dir"])
        lines.append("| %s | %s | %s | %s | %s | %s | %s |" % (
            attempt_id, MODEL_ROLE_CN.get(str(end.get("role", "")), str(end.get("role", ""))),
            fmt_ts(end.get("started_at"), base_ts),
            end.get("latency_s", "-"),
            "成功" if end.get("ok") else "异常：%s" % str(end.get("error_type", "")),
            "[context](%s)" % context_rel if context_rel else "缺失",
            "[result](%s)" % result_rel if result_rel else "缺失"))
    if not run["attempt_ends"]:
        lines.append("| - | - | - | - | - | 缺失 | 缺失 |")
    lines.append("")
    # ---- 关键轮次详情 ----
    lines.append("## 关键轮次详情（失败/超时/受阻/恢复）")
    lines.append("")
    notable = [b for b in rounds
               if any(str(e.get("event")) in ("failed", "timeout", "blocked", "diagnose",
                                              "recovering")
                      for e in b["tasks"])
               or any(str(e.get("event")) in ("timeout", "dropped") for e in b["commands"])
               or any(str(e.get("status")) in ("Rejected", "error", "expired")
                      for e in b["commands"])]
    for bucket in notable[:40]:
        begin = bucket.get("begin") or {}
        lines.append("### 轮 %d（tick %s，%s）" % (
            bucket["round_seq"], bucket["server_tick"], fmt_ts(begin.get("ts_wall"), base_ts)))
        lines.append("")
        for edge in bucket["edges"]:
            lines.append("- 选边：%s → `%s`（%s；判据码 `%s`）" % (
                edge.get("from"), edge.get("to"), edge.get("reason_cn"),
                edge.get("reason_code")))
        for entry in bucket["tasks"]:
            lines.append("- 任务 `%s`：%s（%s；%s）" % (
                entry.get("task_id"), TASK_EVENT_CN.get(str(entry.get("event")),
                                                      str(entry.get("event"))),
                entry.get("reason_cn", ""), entry.get("state", "")))
        for entry in bucket["commands"]:
            lines.append("- 命令 `%s` 尝试 %s：%s（%s）%s" % (
                entry.get("intent_id"), entry.get("attempt"),
                COMMAND_EVENT_CN.get(str(entry.get("event")), str(entry.get("event"))),
                cn_status(entry.get("status", "")),
                ("；" + str(entry.get("reason", ""))[:120]) if entry.get("reason") else ""))
        for entry in bucket["models"]:
            lines.append("- 模型（%s）%s：%s（%s，耗时 %sms）" % (
                MODEL_ROLE_CN.get(str(entry.get("role", "")), entry.get("role", "")),
                entry.get("phase"), cn_status(entry.get("status", "")),
                str(entry.get("reason", ""))[:80], entry.get("latency_ms", "-")))
        for entry in bucket["notes"]:
            lines.append("- 留痕 %s：%s" % (entry.get("note"),
                                           json.dumps({k: v for k, v in entry.items()
                                                       if k not in ("schema", "version", "seq",
                                                                    "session_id", "run_id",
                                                                    "match_id", "player_id",
                                                                    "round_seq", "server_tick",
                                                                    "ts_mono", "ts_wall", "kind",
                                                                    "phase", "note")},
                                                      ensure_ascii=False)[:300]))
        lines.append("")
    if not notable:
        lines.append("本局没有失败/超时/受阻/恢复轮次（正常局只有等待与推进）。")
        lines.append("")
    lines.append("## 证据边界")
    lines.append("")
    lines.append("- 追踪事件顺序按 `seq`（记录器单调序号），不按 tick、不按墙钟猜因果；")
    lines.append("  相同 tick 的多轮靠 `round_seq` 区分。")
    lines.append("- 世界事实（余额/单位）来自留档 rounds.jsonl，按 tick 就近对齐仅供展示；")
    lines.append("  判定结论一律以追踪事件与权威回执为准。")
    lines.append("- 旧样本没有 `trace.jsonl`：按旧证据能力显示，不补造 node span 或因果 ID。")
    lines.append("- 未采集字段标 `unknown`/缺失；不用空值、0 或邻近事件冒充已测事实。")
    lines.append("")
    text = "\n".join(lines)
    with open(out_path, "w", encoding="utf-8") as handle:
        handle.write(text)
    return text


# ---------------------------------------------------------------------------
# HTML 渲染（交互：轮次导航 + 过滤 + 原文展开）
# ---------------------------------------------------------------------------

HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>__TITLE__</title>
<style>
body{font-family:"Microsoft YaHei",system-ui,sans-serif;margin:0;background:#111;color:#eee}
header{padding:12px 16px;background:#1b1b22;border-bottom:1px solid #333}
#controls{padding:8px 16px;background:#16161c;position:sticky;top:0;z-index:5}
button{background:#2a2a35;color:#eee;border:1px solid #444;border-radius:4px;padding:4px 10px;margin-right:6px;cursor:pointer}
button.active{background:#3f6ad8;border-color:#3f6ad8}
#round{padding:12px 16px}
.card{background:#1b1b22;border:1px solid #2c2c38;border-radius:6px;padding:10px 12px;margin:8px 0}
.card h3{margin:0 0 6px 0;font-size:14px;color:#9ecbff}
table{border-collapse:collapse;width:100%;font-size:12px}
th,td{border:1px solid #2c2c38;padding:3px 6px;text-align:left;vertical-align:top}
th{background:#22222c}
pre{background:#0d0d12;border:1px solid #2c2c38;border-radius:4px;padding:8px;overflow:auto;max-height:420px;font-size:11px;white-space:pre-wrap}
.tag{display:inline-block;background:#2a2a35;border-radius:3px;padding:1px 6px;margin:1px;font-size:11px}
.tag.ok{background:#1d4d2b}.tag.warn{background:#6b4d1d}.tag.bad{background:#6b1d1d}
.muted{color:#888}
</style>
</head>
<body>
<header><b>__TITLE__</b><div class="muted" id="identity"></div></header>
<div id="controls">
  <button data-filter="all" class="active">全部</button>
  <button data-filter="success">成功</button>
  <button data-filter="wait">正常等待</button>
  <button data-filter="fail">失败/超时</button>
  <button data-filter="blocked">受阻</button>
  <button data-filter="unknown">未知</button>
  <button data-filter="model">模型调用</button>
  <button data-filter="command">命令</button>
  <span style="margin-left:12px">
  <button id="prev">上一轮</button>
  <input id="roundno" type="number" min="1" style="width:70px">
  <button id="next">下一轮</button>
  <span class="muted" id="roundinfo"></span>
  </span>
</div>
<div id="round"></div>
<script>
const DATA = __DATA__;
let filter = "all";
let index = 0;
function esc(s){return String(s==null?"":s).replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]))}
function roundTags(b){
  const tags=[];
  // 失败/超时只认**真失败**：任务 failed/timeout/blocked、命令 Rejected/error/expired、
  // 等待超时。仲裁丢弃（dropped：预留不足/去重/同单位冲突…）是正常门禁结果，
  // 不算失败——把 dropped 计进去会让"失败/超时"过滤器失去意义
  const hasFail=b.events.some(e=>e.kind==="task"&&["failed","timeout","blocked"].includes(e.event))
    ||b.events.some(e=>e.kind==="command"&&e.event==="timeout")
    ||b.events.some(e=>e.kind==="command"&&["Rejected","error","expired"].includes(e.status));
  const hasUnknown=b.events.some(e=>e.kind==="task"&&e.event==="unknown")
    ||b.events.some(e=>e.kind==="command"&&e.status==="PendingAuthority");
  const hasModel=b.models.length>0;
  const hasCommand=b.commands.length>0;
  const hasSuccess=b.events.some(e=>e.kind==="task"&&e.event==="succeeded");
  const hasBlocked=b.events.some(e=>e.kind==="task"&&(e.event==="blocked"||e.state==="blocked"));
  const isWait=(b.edges[0]&&b.edges[0].route==="wait");
  const cls=hasFail?"fail":(hasUnknown?"unknown":(hasSuccess?"success":(isWait?"wait":"all")));
  return {cls:cls,hasFail:hasFail,hasUnknown:hasUnknown,hasModel:hasModel,hasCommand:hasCommand,hasSuccess:hasSuccess,hasBlocked:hasBlocked};
}
function pass(b){
  const t=roundTags(b);
  if(filter==="all")return true;
  if(filter==="fail")return t.hasFail;
  if(filter==="unknown")return t.hasUnknown;
  if(filter==="model")return t.hasModel;
  if(filter==="command")return t.hasCommand;
  if(filter==="success")return t.hasSuccess;
  if(filter==="blocked")return t.hasBlocked;
  if(filter==="wait")return !t.hasFail&&!t.hasUnknown&&(b.edges[0]&&b.edges[0].route==="wait");
  return true;
}
function render(){
  const visible=DATA.rounds.filter(pass);
  if(index>=visible.length)index=Math.max(0,visible.length-1);
  const b=visible[index]||{events:[],spans:[],edges:[],candidates:[],tasks:[],commands:[],models:[],notes:[]};
  document.getElementById("roundno").max=Math.max(1,visible.length);
  document.getElementById("roundno").value=index+1;
  document.getElementById("roundinfo").textContent="/ "+visible.length+" 轮（过滤后）";
  let h="";
  h+='<div class="card"><h3>轮 '+esc(b.round_seq)+' · tick '+esc(b.server_tick)+' · '+esc(b.wall)+'</h3>';
  h+='<div>'+b.events.map(e=>'<span class="tag">'+esc(e.kind)+'</span>').join("")+'</div>';
  h+='<div class="muted">节点 span '+esc(b.span_count)+' 个 · 合计 '+esc(b.span_ms)+'ms</div></div>';
  b.edges.forEach(e=>{h+='<div class="card"><h3>选边：'+esc(e.from)+' → '+esc(e.to)+'</h3><div>route='+esc(e.route)+' · '+esc(e.reason_cn)+' · 判据码 <code>'+esc(e.reason_code)+'</code></div><pre>'+esc(JSON.stringify(e.detail||{},null,1))+'</pre></div>';});
  if(b.candidates.length){h+='<div class="card"><h3>候选入口条件（逐项 值/结果/缺项）</h3><table><tr><th>节点</th><th>可选</th><th>条件</th></tr>'+b.candidates.map(c=>'<tr><td>'+esc(c.node)+' '+esc(c.name)+'</td><td>'+(c.available?"是":"否")+'</td><td>'+(c.conditions||[]).map(k=>'<span class="tag'+(k.missing?" bad":" ok")+'">'+esc(k.text)+'='+esc(k.value)+'</span>').join("")+'</td></tr>').join("")+'</table></div>';}
  if(b.tasks.length){h+='<div class="card"><h3>任务事件</h3><table><tr><th>任务</th><th>事件</th><th>状态</th><th>原因</th></tr>'+b.tasks.map(t=>'<tr><td>'+esc(t.task_id)+'</td><td>'+esc(t.event)+'</td><td>'+esc(t.state)+'</td><td>'+esc(t.reason_cn)+'</td></tr>').join("")+'</table></div>';}
  if(b.commands.length){h+='<div class="card"><h3>命令事件</h3><table><tr><th>意图</th><th>事件</th><th>尝试</th><th>动作</th><th>状态</th><th>原因</th></tr>'+b.commands.map(c=>'<tr><td>'+esc(c.intent_id)+'</td><td>'+esc(c.event)+'</td><td>'+esc(c.attempt)+'</td><td>'+esc(c.action)+'</td><td>'+esc(c.status)+'</td><td>'+esc(c.reason)+'</td></tr>').join("")+'</table></div>';}
  if(b.models.length){h+='<div class="card"><h3>模型调用</h3>'+b.models.map(m=>'<div>'+esc(m.role)+' '+esc(m.phase)+' '+esc(m.status)+' 请求#'+esc(m.request_id)+' 耗时'+esc(m.latency_ms)+'ms<pre>'+esc(JSON.stringify(m.frame||{},null,1))+'</pre></div>').join("")+'</div>';}
  if(b.attempts&&b.attempts.length){h+='<div class="card"><h3>本轮模型调用（输入/输出全文链接）</h3>'+b.attempts.map(a=>'<div>'+esc(a.attempt_id)+'（'+esc(a.role)+'，'+(a.ok?"成功":"异常")+'，'+esc(a.latency_s)+'s） <a href="'+esc(a.context_path)+'">输入全文</a>'+(a.result_path?' <a href="'+esc(a.result_path)+'">输出全文</a>':'')+'</div>').join("")+'</div>';}
  b.notes.forEach(n=>{h+='<div class="card"><h3>留痕 '+esc(n.note)+'</h3><div>'+esc(n.reason_cn||"")+'</div></div>';});
  document.getElementById("round").innerHTML=h;
}
document.querySelectorAll("#controls button[data-filter]").forEach(btn=>{
  btn.onclick=()=>{document.querySelectorAll("#controls button[data-filter]").forEach(b=>b.classList.remove("active"));btn.classList.add("active");filter=btn.dataset.filter;index=0;render();};
});
document.getElementById("prev").onclick=()=>{if(index>0){index--;render();}};
document.getElementById("next").onclick=()=>{index++;render();};
document.getElementById("roundno").onchange=(e)=>{index=Math.max(0,parseInt(e.target.value||"1",10)-1);render();};
document.getElementById("identity").textContent=DATA.identity;
render();
</script>
</body>
</html>
"""


def render_html(run: Dict[str, Any], rounds: List[Dict[str, Any]],
                metrics: Dict[str, Any], out_path: str) -> None:
    """交互 HTML：轮次导航 + 过滤 + 原文链接。

    **载荷刻意压缩**：600 秒局有 ~2000 轮，全量内嵌（含世界事实与模型输出全文）
    会把 HTML 撑到几十 MB。这里每轮只留导航与判定需要字段；模型输入/输出全文
    走 attempts 目录链接（MD 时间表同样给链接），不复制正文。
    """
    summary = run["summary"]
    base_ts = float(summary.get("observation_start", 0) or 0)
    payload_rounds = []
    for bucket in rounds:
        begin = bucket.get("begin") or {}
        span_ms = sum(float(e.get("duration_ms", 0) or 0) for e in bucket["spans"])
        payload_rounds.append({
            "round_seq": bucket["round_seq"], "server_tick": bucket["server_tick"],
            "wall": fmt_ts(begin.get("ts_wall"), base_ts),
            "events": [{"kind": e.get("kind"), "event": e.get("event"),
                        "status": e.get("status"), "phase": e.get("phase")}
                       for e in bucket["events"]],
            "span_count": len(bucket["spans"]), "span_ms": round(span_ms, 1),
            "edges": [{"from": e.get("from"), "to": e.get("to"), "route": e.get("route"),
                       "reason_cn": e.get("reason_cn"), "reason_code": e.get("reason_code"),
                       "detail": e.get("detail")} for e in bucket["edges"]],
            "candidates": [{"node": e.get("node"), "name": e.get("name"),
                            "available": e.get("available"),
                            "conditions": [{"text": c.get("text"), "value": c.get("value"),
                                            "missing": c.get("missing")}
                                           for c in (e.get("conditions") or [])]}
                           for e in bucket["candidates"]],
            "tasks": [{"task_id": e.get("task_id"), "event": e.get("event"),
                       "state": e.get("state"), "reason_cn": e.get("reason_cn"),
                       "goal_id": e.get("goal_id")} for e in bucket["tasks"]],
            "commands": [{"intent_id": e.get("intent_id"), "event": e.get("event"),
                          "attempt": e.get("attempt"), "status": e.get("status"),
                          "action": e.get("action"), "reason": e.get("reason")}
                         for e in bucket["commands"]],
            "models": [{"role": e.get("role"), "phase": e.get("phase"),
                        "status": e.get("status"), "request_id": e.get("request_id"),
                        "latency_ms": e.get("latency_ms"), "reason": e.get("reason"),
                        "frame": e.get("frame")} for e in bucket["models"]],
            "notes": [{"note": e.get("note"),
                       "reason_cn": e.get("reason_cn", "")} for e in bucket["notes"]],
            "attempts": [{"attempt_id": item.get("attempt_id"),
                          "context_path": rel(item.get("context_path", ""), run["run_dir"]),
                          "result_path": rel(item.get("result_path", ""), run["run_dir"]),
                          "ok": (item.get("end") or {}).get("ok"),
                          "latency_s": (item.get("end") or {}).get("latency_s"),
                          "role": (item.get("end") or {}).get("role")}
                         for item in bucket.get("attempts") or []],
        })
    identity = "对局 %s · 观察 %s 秒 · 轮次 %d · 追踪事件 %d" % (
        summary.get("status", "?"), summary.get("observed_seconds", "?"),
        metrics.get("rounds", 0), metrics.get("trace_events", 0))
    data = json.dumps({"rounds": payload_rounds, "identity": identity},
                      ensure_ascii=False, default=str, separators=(",", ":"))
    page = (HTML_TEMPLATE.replace("__TITLE__", "副官运行时追踪回放")
            .replace("__DATA__", data))
    with open(out_path, "w", encoding="utf-8") as handle:
        handle.write(page)


def write_manifest(run: Dict[str, Any], metrics: Dict[str, Any],
                   outputs: List[str], out_path: str) -> None:
    manifest = {
        "schema": SCHEMA, "version": VERSION,
        "generated_at": time.time(),
        "run_dir": run["run_dir"],
        "inputs": {}, "outputs": {}, "metrics": metrics,
        "missing": run["missing"],
    }
    candidates = [run["trace_path"], os.path.join(run["run_dir"], "attempts.jsonl"),
                  os.path.join(run["run_dir"], "http.jsonl"),
                  os.path.join(run["run_dir"], "world.jsonl"),
                  os.path.join(run["run_dir"], "summary.json"),
                  os.path.join(run["run_dir"], "strategy-state.jsonl")]
    if run["archive"]:
        for name in ("rounds", "decisions", "commands", "events"):
            candidates.append(os.path.join(run["archive"], "%s.jsonl" % name))
    for path in candidates:
        if path and os.path.exists(path):
            manifest["inputs"][rel(path, run["run_dir"])] = {
                "sha256": sha256(path), "bytes": os.path.getsize(path)}
    for path in outputs:
        manifest["outputs"][os.path.basename(path)] = {
            "sha256": sha256(path), "bytes": os.path.getsize(path)}
    with open(out_path, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, ensure_ascii=False, indent=2, sort_keys=True)


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", required=True, help="对局证据目录（adjutant_observe 的 --output）")
    parser.add_argument("--output", required=True, help="报告基名（.md/.html/.manifest.json）")
    args = parser.parse_args(argv)
    run_dir = os.path.abspath(args.run)
    if not os.path.isdir(run_dir):
        print("对局目录不存在：%s" % run_dir, file=sys.stderr)
        return 2
    out_base = os.path.abspath(args.output)
    for suffix in (".md", ".html", ".manifest.json"):
        if os.path.exists(out_base + suffix):
            print("产物已存在（不覆盖，用新 --output）：%s" % (out_base + suffix),
                  file=sys.stderr)
            return 2
    run = load_run(run_dir)
    if not run["trace"]:
        print("未找到 trace.jsonl：旧样本没有运行时追踪，不能补造。", file=sys.stderr)
        return 2
    rounds = build_rounds(run)
    match_attempts_to_rounds(run, rounds)
    metrics = build_metrics(run, rounds)
    md_path = out_base + ".md"
    html_path = out_base + ".html"
    manifest_path = out_base + ".manifest.json"
    render_markdown(run, rounds, metrics, md_path)
    render_html(run, rounds, metrics, html_path)
    write_manifest(run, metrics, [md_path, html_path], manifest_path)
    print(json.dumps({"rounds": metrics.get("rounds"),
                      "trace_events": metrics.get("trace_events"),
                      "diagnostic_errors": metrics.get("diagnostic_errors"),
                      "md": md_path, "html": html_path,
                      "manifest": manifest_path}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
