# -*- coding: utf-8 -*-
"""副官运行指标采集器（Phase 1：只观察、不改架构）。

用途（对应执行提示词 §四"必须记录的指标"）：从**真实运行日志**里抽取可量化指标，
区分"模型输出 / 调度接受 / 实际执行 / 游戏结果"四层，禁止把"发出命令"当成"命令成功"。

数据来源（都是现有产物，不需要新埋点）：
- `runner.out`：runner 的结构化事件（decision/receipt）与打印行
- 游戏权威端 `op=commands`（真终态）、`op=tactical`（单位/队列/余额）

用法：
    python -m adjutant_coordinator.deploy.metrics_report --run-dir <run_dir> [--authority-port 24572]

输出：JSON（可入库对照）+ 人类可读摘要；**同时明确标注"本轮无法测出"的指标**，
避免用缺失数据冒充结论（规范 §12：只完成了哪一层就报告哪一层）。
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import re
import socket
import sys
import time
from typing import Any, Dict, List, Optional

DEVELOP_ACTIONS = {"build", "produce"}


def _tcp(port: int, payload: Dict[str, Any], timeout: float = 15.0) -> Dict[str, Any]:
    """极简只读 TCP 调用（与 e2e_dual_layer.tcp_call 同协议；这里内联避免依赖）。"""
    data = (json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8")
    with socket.create_connection(("127.0.0.1", int(port)), timeout=timeout) as sock:
        sock.sendall(data)
        sock.settimeout(timeout)
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = sock.recv(65536)
            if not chunk:
                break
            buf += chunk
    text = buf.decode("utf-8", "replace").strip()
    try:
        return json.loads(text) if text else {}
    except json.JSONDecodeError:
        return {"error": "bad_json", "raw": text[:200]}


def parse_runner_log(path: str) -> Dict[str, Any]:
    """从 runner.out 抽取：回执、决策、四列批次、微操、解析失败等计数。"""
    out: Dict[str, Any] = {
        "receipts": [], "decisions": collections.Counter(),
        "batches": collections.Counter(), "micro": collections.Counter(),
        "parse_errors": 0, "raw_lines": 0,
    }
    if not os.path.exists(path):
        out["missing_log"] = path
        return out
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            out["raw_lines"] += 1
            if "Traceback" in line or "ERROR" in line:
                out["parse_errors"] += 1
            if '"kind": "receipt"' in line:
                try:
                    obj = json.loads(line[line.index("{"):])
                except Exception:
                    continue
                receipt = obj.get("receipt") or {}
                out["receipts"].append({
                    "ts": obj.get("ts"),
                    "action": str(receipt.get("action", "")),
                    "status": str(receipt.get("status", "")),
                    "intent_id": str(receipt.get("intent_id", "")),
                })
                continue
            if '"kind": "decision"' in line:
                try:
                    obj = json.loads(line[line.index("{"):])
                except Exception:
                    continue
                decision = obj.get("decision") or {}
                out["decisions"][str(decision.get("kind", ""))] += 1
                continue
            if "micro_control" in line:
                match = re.search(r"added=(\d+) suppressed=(\d+)", line)
                if match:
                    out["micro"]["added=%s" % match.group(1)] += 1
                    out["micro"]["suppressed=%s" % match.group(2)] += 1
                continue
            if '"kind": "task_patch"' in line:
                match = re.search(r'"rows": (\d+).*?"accepted": (\d+)', line)
                if match:
                    out["batches"]["rows=%s/accepted=%s" % match.groups()] += 1
    return out


def collect(run_dir: str, authority_port: int, player: str) -> Dict[str, Any]:
    log = parse_runner_log(os.path.join(run_dir, "runner.out"))
    receipts = log["receipts"]
    if not receipts:
        return {"error": "no_receipts", "log": log["raw_lines"]}

    start_ts = next((r["ts"] for r in receipts if r["ts"]), None)
    end_ts = next((r["ts"] for r in reversed(receipts) if r["ts"]), None)
    elapsed = float(end_ts - start_ts) if (start_ts and end_ts) else 0.0

    # ① 单位→动作 计数（回执不带 unit_ids，从 intent_id 里取稳定前缀）
    per_unit_action: Dict[str, int] = collections.Counter()
    for r in receipts:
        key = re.sub(r"-\d+$", "", r["intent_id"]) or r["intent_id"]
        per_unit_action["%s|%s" % (key, r["action"])] += 1

    first_dev = next((i for i, r in enumerate(receipts) if r["action"] in DEVELOP_ACTIONS),
                     None)
    metrics: Dict[str, Any] = {
        # ① 时间
        "观测窗口秒": round(elapsed, 1),
        "回执总数": len(receipts),
        # ⑰ 每分钟有效命令
        "有效命令_每分钟": round(len(receipts) / elapsed * 60, 1) if elapsed else None,
        # ⑧ 同一单位重复命令（同一 intent 前缀出现 >1 次）
        "重复命令条数": sum(v - 1 for v in per_unit_action.values() if v > 1),
        "重复最多的5条": per_unit_action.most_common(5),
        # 首发展时延（本会话新增的验收口径）
        "首发展时延_第几条回执": (first_dev + 1) if first_dev is not None else None,
        # ② 任务状态分布（回执终态）
        "回执状态分布": dict(collections.Counter(r["status"] for r in receipts)),
        "动作分布": dict(collections.Counter(r["action"] for r in receipts)),
        # ⑮/⑯ 解析失败、过期/授权拒绝
        "日志解析失败行数": log["parse_errors"],
        "过期或授权拒绝次数": sum(
            1 for r in receipts if r["status"] in
            ("StaleGeneration", "RulesVersionStale", "SnapshotTooOld",
             "PlayerOverride", "IntentLedgerFull", "LedgerFull")),
        # 决策与批次（模型输出层）
        "决策计数": dict(log["decisions"]),
        "四列批次": dict(log["batches"]),
        "微操计数": dict(log["micro"]),
    }

    # ④ 任务失败原因（权威端真终态）与游戏侧结果
    commands = _tcp(authority_port, {"op": "commands"})
    rows = commands.get("commands") or commands.get("result") or []
    if isinstance(rows, list):
        metrics["权威端命令终态"] = dict(collections.Counter(
            str(r.get("status")) for r in rows if isinstance(r, dict)))
        metrics["权威端失败原因"] = dict(collections.Counter(
            str(r.get("reason"))[:40] for r in rows
            if isinstance(r, dict) and str(r.get("status")) != "Accepted"))
    tactical = _tcp(authority_port, {"op": "tactical", "as_player": player})
    own = [e for e in (tactical.get("entities") or [])
           if str(e.get("kind")) == "unit_self"]
    if own:
        metrics["单位构成"] = dict(collections.Counter(
            str(e.get("unit_type")) for e in own))
        metrics["余额"] = tactical.get("balance")
        # ⑦ 单位空闲（无当前动作的单位数；action 字段缺失时标记为不可测）
        unknown_action = [e for e in own if "action" not in e]
        metrics["动作字段缺失单位数"] = len(unknown_action)
        metrics["单位动作"] = dict(collections.Counter(
            os.path.basename(str(e.get("action", ""))) for e in own))
        # ⑩ 生产队列断档：已完工生产建筑里 items 为空的数量
        production = tactical.get("production") or []
        idle_producers = [p for p in production
                          if isinstance(p, dict) and not (p.get("items") or [])]
        metrics["空闲生产设施数"] = len(idle_producers)
        metrics["生产设施数"] = len(production)
    else:
        metrics["游戏侧不可用"] = str(tactical.get("error", "no_entities"))[:120]

    # 明确标注尚不可测的指标（不得用缺失数据冒充结论）
    metrics["本轮无法测得"] = [
        "③⑤⑥ 命令生成/接收/生效的绝对时间（现有日志无阶段打点）",
        "⑨ 被无意义打断的任务次数（任务生命周期未落盘为独立字段）",
        "⑪ 采矿/回矿/建造/战斗任务完成率（缺任务终态归集）",
        "⑫ 资源收入与浪费（需按 tick 采样余额差分）",
        "⑬ 有效战斗响应延迟（无敌人对局 + 无交火打点）",
        "⑱ 对局终局结果（对局未结束）",
    ]
    return metrics


def main() -> int:
    parser = argparse.ArgumentParser(description="副官运行指标采集（只读）")
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--authority-port", type=int, default=24572)
    parser.add_argument("--player", default="Player_0")
    parser.add_argument("--out", default="")
    args = parser.parse_args()

    metrics = collect(args.run_dir, args.authority_port, args.player)
    text = json.dumps(metrics, ensure_ascii=False, indent=2)
    print(text)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            json.dump({"ts": time.time(), "run_dir": args.run_dir, "metrics": metrics},
                      fh, ensure_ascii=False, indent=2)
        print("已写入 %s" % args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
