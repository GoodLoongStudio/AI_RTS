# -*- coding: utf-8 -*-
"""**生产闭环验收**：按 `item_id` 把"下单 → 开产 → 完成 → 任务结算 → 下一单"串起来。

为什么要单独一个工具（GPT 复盘计划 P1a 的验收要求）：
"生产接续"不能只看"有没有设施在产"——必须证明**每一个具体生产项**都有结果，
且完工后**下一次开产不等旧 TTL**。判据全部来自档案事实：

| 事实 | 来源 |
|---|---|
| 下单（含权威 item_id / definition_id） | `raw/agent_runner_*.jsonl` 里的生产回执 |
| 开产 / 完成 | `events.jsonl` 的 `production_started` / `production_finished`（带 item_id） |
| 任务结算 | `decisions.jsonl` 的 `task_progress`（意图 → 状态） |
| 下一单 | 同一生产者下一条 `production_started` |

用法：
    python tools/production_report.py <archive_... 目录> [--json out.json]
"""

import argparse
import glob
import io
import json
import os
import sys
from typing import Any, Dict, List

sys.stdout.reconfigure(encoding="utf-8")
TICK_HZ = 60.0


def _read_jsonl(path):
    out = []
    try:
        with io.open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if not line or not line.startswith("{"):
                    continue
                try:
                    out.append(json.loads(line))
                except ValueError:
                    continue
    except OSError:
        return []
    return out


def collect(archive: str, *, log_dir: str = "") -> Dict[str, Any]:
    events = _read_jsonl(os.path.join(archive, "events.jsonl"))
    decisions = _read_jsonl(os.path.join(archive, "decisions.jsonl"))
    receipts: List[Dict[str, Any]] = []
    # 回执来源：档案的 `raw/`（收档后），或**运行中的** `--log-dir`（还没收档时也能查）。
    sources = sorted(glob.glob(os.path.join(archive, "raw", "agent_runner_*.jsonl")))
    if log_dir:
        sources += sorted(glob.glob(os.path.join(log_dir, "agent_runner_*.jsonl")))
    for path in sources:
        for record in _read_jsonl(path):
            receipt = record.get("receipt")
            if isinstance(receipt, dict) and str(receipt.get("action")) == "produce":
                receipts.append(dict(receipt, _log_tick=record.get("server_tick")))

    items: Dict[str, Dict[str, Any]] = {}
    for receipt in receipts:
        result = receipt.get("result") if isinstance(receipt.get("result"), dict) else {}
        item = result.get("item") if isinstance(result.get("item"), dict) else {}
        item_id = str(result.get("item_id") or item.get("item_id") or "")
        if not item_id:
            continue
        entry = items.setdefault(item_id, {})
        entry.update({
            "item_id": item_id,
            "intent_id": str(receipt.get("intent_id", "")),
            "producer": str(result.get("producer") or ""),
            "product_id": str(item.get("definition_id") or ""),
            "scene": str(result.get("scene") or ""),
            "status": str(receipt.get("status") or ""),
            "ordered_tick": int(receipt.get("_log_tick") or receipt.get("server_tick") or 0),
            "authority_tick": int((receipt.get("result") or {}).get("server_tick")
                                  or receipt.get("server_tick") or 0),
        })
    for event in events:
        kind = str(event.get("kind", ""))
        item_id = str(event.get("item_id", ""))
        if not item_id:
            continue
        entry = items.setdefault(item_id, {"item_id": item_id, "intent_id": "",
                                           "producer": str(event.get("unit", "")),
                                           "product_id": "", "scene": "",
                                           "status": "", "ordered_tick": 0,
                                           "authority_tick": 0})
        tick = int(event.get("server_tick", 0) or 0)
        if kind == "production_started":
            entry["started_tick"] = tick
        elif kind == "production_finished":
            entry["finished_tick"] = tick
        elif kind == "unit_spawned":
            entry.setdefault("spawned_units", []).append(
                {"unit": str(event.get("unit", "")), "unit_type": str(event.get("unit_type", "")),
                 "tick": tick})

    # 任务结算：**以每轮档案里的意图状态为准**（`rounds.jsonl` 的 `intents` 字段）。
    # 注意 `decisions.jsonl` 的 `task_progress` 只记 `{"updated": N}`，没有逐意图状态 ——
    # 用它判"任务是否结算"会得出"全部未知"的假结论（实测踩过）。
    settled: Dict[str, str] = {}
    settled_tick: Dict[str, int] = {}
    terminal: Dict[str, str] = {}
    for record in _read_jsonl(os.path.join(archive, "rounds.jsonl")):
        tick = int(record.get("server_tick", 0) or 0)
        for intent in record.get("intents") or []:
            if not isinstance(intent, dict):
                continue
            intent_id = str(intent.get("id", ""))
            state = str(intent.get("state", ""))
            if not intent_id:
                continue
            settled[intent_id] = state or settled.get(intent_id, "")
            settled_tick[intent_id] = tick or settled_tick.get(intent_id, 0)
            # 终态只出现一次（之后意图就不在活跃表里了）→ 单独记下来，别被覆盖成空。
            if state in ("completed", "failed", "expired", "dropped"):
                terminal[intent_id] = state
    for intent_id, state in terminal.items():
        settled[intent_id] = state
    for record in decisions:
        if str(record.get("kind", "")) != "task_progress":
            continue
        intent_id = str(record.get("intent_id") or "")
        if intent_id and intent_id not in settled:
            settled[intent_id] = str(record.get("status") or record.get("intent_state") or "")
    for entry in items.values():
        entry["task_status_last"] = settled.get(str(entry.get("intent_id", "")), "")
        entry["task_status_tick"] = settled_tick.get(str(entry.get("intent_id", "")), 0)

    # 每个生产者的接续间隔：完成 → 下一次开产。
    starts: Dict[str, List[Dict[str, Any]]] = {}
    for entry in items.values():
        if entry.get("producer") and entry.get("started_tick"):
            starts.setdefault(entry["producer"], []).append(entry)
    gaps = []
    for producer, series in starts.items():
        series.sort(key=lambda entry: entry["started_tick"])
        for previous, following in zip(series, series[1:]):
            if previous.get("finished_tick"):
                gaps.append({
                    "producer": producer,
                    "from_item": previous["item_id"][:8],
                    "to_item": following["item_id"][:8],
                    "gap_ticks": int(following["started_tick"]) - int(previous["finished_tick"]),
                    "gap_s": round((int(following["started_tick"])
                                    - int(previous["finished_tick"])) / TICK_HZ, 2)})
    return {"items": sorted(items.values(), key=lambda entry: entry.get("ordered_tick", 0)),
            "gaps": gaps, "events": len(events), "receipts": len(receipts)}


def main():
    parser = argparse.ArgumentParser(description="生产闭环验收（按 item_id 串证据链）")
    parser.add_argument("archive")
    parser.add_argument("--json", default="")
    parser.add_argument("--log-dir", default="",
                        help="runner 的 --log-dir（跑动中还没收档时也能查回执）")
    args = parser.parse_args()
    report = collect(args.archive, log_dir=args.log_dir)
    items = report["items"]
    print("== 生产项 %d 个（回执 %d 条）==" % (len(items), report["receipts"]))
    for entry in items:
        print("  %s  产品=%-10s 生产者=%-8s 下单=%-6s 开产=%-6s 完成=%-6s 任务=%-16s 场景=%s"
              % (entry["item_id"][:8], entry.get("product_id") or "?",
                 entry.get("producer") or "?", entry.get("ordered_tick") or "?",
                 entry.get("started_tick") or "-", entry.get("finished_tick") or "-",
                 entry.get("task_status_last") or "?", (entry.get("scene") or "")[:48]))
    finished = [entry for entry in items if entry.get("finished_tick")]
    completed = [entry for entry in items
                 if str(entry.get("task_status_last", "")).startswith("completed")]
    print("\n== 汇总 ==")
    print("  有完成事件的生产项：%d / %d" % (len(finished), len(items)))
    print("  任务状态 settlement=completed 的意图：%d" % len(completed))
    print("  完工→下一次开产的间隔：%s" % (
        ", ".join("%s %ss" % (gap["producer"], gap["gap_s"]) for gap in report["gaps"])
        or "无（本局没有连续两单）"))
    if report["gaps"]:
        worst = max(gap["gap_s"] for gap in report["gaps"])
        print("  最长接续间隔：%.2fs（旧问题：要等旧意图 TTL 过期 ≈19s）" % worst)
    if args.json:
        with io.open(args.json, "w", encoding="utf-8") as handle:
            json.dump(report, handle, ensure_ascii=False, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
