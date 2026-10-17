# -*- coding: utf-8 -*-
"""把已经跑完的 `result_fs_*.json` 重新过一遍分析层，重渲染 §6 逐局表。

为什么单独有这个脚本：`run_fixed_seed_regression.py` 在每局跑完立刻调分析层，
所以**表的结构冻在启动那一刻**。中途给仪表加列（本轮加了
"曾耗尽矿点数 / 再生结算轮数 / 等待再生矿点数 / 每座矿场服务的矿点数"）以后，
老进程写出的表不会有这些列，但 result JSON 里有原始数据 ——
重算比重跑 15 局便宜得多，而且**用的是同一批对局**，不存在"换了数据凑结论"。

用法：
    python -m adjutant_coordinator.deploy.rerender_sweep \\
        --map res://source/match/maps/PlainAndSimple.tscn \\
        --tag fs_screen,fs_reg,fs_regen --out G:/AIRTS/AI_RTS/build/selfplay
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import match_metrics  # noqa: E402
from run_fixed_seed_regression import (COLUMNS, _barracks_time, _cell,
                            _selfplay_result_dir)  # noqa: E402


def row_for(result_path: str, driver_json: str) -> dict:
    with open(result_path, encoding="utf-8") as handle:
        result = json.load(handle)
    # 与 `run_one()` 走同一个分析入口（传路径），不在这里重实现任何口径。
    metrics = match_metrics.analyze(result_path) or {}
    economy = metrics.get("economy") or {}
    tag = os.path.basename(result_path)[len("result_"):-len(".json")]
    row = {"tag": tag, "map": result.get("map"), "seed": result.get("seed"),
           "verdict": result.get("verdict"),
           "duration_s": result.get("seconds"),
           "refinery_trigger": (result.get("refinery_receipt") or {}).get("stage")}
    for key in ("worker_seconds_on_construction", "constructing_workers_peak",
                "first_refinery_placed_t", "first_refinery_takeover_t",
                "first_refinery_delivery_t", "refinery_delivered_amount",
                "ore_nodes", "ore_remaining_first", "ore_remaining_last",
                "ore_depleted_nodes", "ore_depleted_ever_nodes",
                "ore_regen_cycles", "ore_regen_waiting_nodes",
                "entities_truncated", "balance_first", "balance_last",
                "balance_grew"):
        row[key] = economy.get(key)
    row["first_barracks_t"] = _barracks_time(result)
    row["first_attack_move_t"] = metrics.get("first_attack_move_t")
    return row


def main() -> int:
    parser = argparse.ArgumentParser(description="重渲染 §6 逐局表")
    parser.add_argument("--tags", default="fs_screen,fs_reg,fs_regen,fs_precheck,fs_verify1")
    parser.add_argument("--out", default=os.path.join(
        os.path.abspath(os.path.join(HERE, "..", "..", "..")), "build", "selfplay"))
    args = parser.parse_args()
    result_dir = _selfplay_result_dir()
    rows = []
    for tag_prefix in [t.strip() for t in args.tags.split(",") if t.strip()]:
        for path in sorted(glob.glob(os.path.join(result_dir, "result_%s*.json" % tag_prefix))):
            try:
                rows.append(row_for(path, ""))
            except Exception as exc:  # noqa: BLE001
                print("[rerender] %s 分析失败：%s" % (path, exc), flush=True)
    out_md = os.path.join(args.out.replace("\\", "/"), "sweep_rerendered.md")
    lines = ["# §6 逐局报告（重渲染，含再生与矿场服务仪表）", ""]
    lines.append("| " + " | ".join(label for _, label in COLUMNS) + " |")
    lines.append("|" + "|".join(["---"] * len(COLUMNS)) + "|")
    for row in rows:
        lines.append("| " + " | ".join(_cell(row.get(key)) for key, _ in COLUMNS) + " |")
    os.makedirs(os.path.dirname(out_md), exist_ok=True)
    with open(out_md, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    print("[rerender] %d 行 -> %s" % (len(rows), out_md), flush=True)
    return 0 if rows else 1


if __name__ == "__main__":
    raise SystemExit(main())
