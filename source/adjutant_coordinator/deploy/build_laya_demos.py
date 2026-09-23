# -*- coding: utf-8 -*-
"""从**真实对局日志**构造 Laya 少样本示例库（P0 结论的落地：零样本不可用）。

依据（提示词 §1.4「必须用项目自己的数据做少样本提示或微调」+ P0 实测：
零样本一致率 0%，带样例后 54%~100%）：本工具把 `format_ab_both_*.json` 里
**当时真实执行**的四列输出（2B 链路的历史决策）与同一观测渲染出的紧凑 state
配对，写成 JSONL（每行 `{"state": "...", "rows": [[actor, skill, target, params]]}`），
供 `AIRTS_LAYA_DEMOS` 指向。

选择口径（确定性，不随机）：
- 覆盖两个观测文件（小帧/大帧）与全部出现过的技能组合（GAT+PROD / BLD / ATK）；
- 每类按 tick 升序取前 N 条，总量受 `--limit` 控制；
- **不**包含任何"未来"信息：state 只是当时的观测渲染，rows 是当时的真实输出。

用法：

    python -m adjutant_coordinator.deploy.build_laya_demos \
        --ab adjutant_coordinator/logs/format_ab_both_20260912.json \
        --out adjutant_coordinator/graph/laya_demos.jsonl
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any, Dict, List, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))          # source/
sys.path.insert(0, ROOT)

from adjutant_coordinator.graph.squads import build_decision_frame  # noqa: E402
from adjutant_coordinator.graph.task_patch import MODE_FAST  # noqa: E402
from adjutant_coordinator.graph.task_patch_prompt import (  # noqa: E402
    render_compact_text,
)

#: 每类技能组合取多少条（按 tick 升序）。
PER_GROUP = 6


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


def main(argv: List[str] = None) -> int:
    parser = argparse.ArgumentParser(description="构造 Laya 少样本示例库（真实日志）")
    parser.add_argument("--data", action="append", default=[])
    parser.add_argument("--ab", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--mode", default="fast", choices=("fast", "deep"))
    parser.add_argument("--per-group", type=int, default=PER_GROUP)
    args = parser.parse_args(argv)

    data_paths = args.data or [
        os.path.join(ROOT, "adjutant_coordinator", "tests", "data", "observations",
                     "real_20260912.jsonl"),
        os.path.join(ROOT, "adjutant_coordinator", "tests", "data", "observations",
                     "real_mass_20260912.jsonl"),
    ]
    rules, observations = load_observations(data_paths)
    with open(args.ab, "r", encoding="utf-8") as handle:
        ab = json.load(handle).get("records") or []
    by_key: Dict[Tuple[str, int, int, str], Dict[str, Any]] = {}
    for record in ab:
        key = (str(record.get("source")), int(record.get("seq", 0) or 0),
               int(record.get("tick", 0) or 0), str(record.get("mode")))
        by_key[key] = record

    # 按"实际执行的技能集合"分组，每组按 tick 升序取前 N 条（确定性）。
    groups: Dict[str, List[Tuple[int, Dict[str, Any], List[List[str]]]]] = {}
    for observation in observations:
        key = (str(observation.get("_source")), int(observation.get("seq", 0) or 0),
               int((observation.get("header") or {}).get("server_tick", 0) or 0),
               args.mode)
        record = by_key.get(key)
        if record is None:
            continue
        rows = [[str(c) for c in row]
                for row in ((record.get("new") or {}).get("sample") or [])]
        if not rows:
            continue
        signature = "+".join(sorted({row[1] for row in rows}))
        groups.setdefault(signature, []).append(
            (key[2], observation, rows))

    picked: List[Tuple[int, Dict[str, Any], List[List[str]]]] = []
    for signature in sorted(groups):
        entries = sorted(groups[signature], key=lambda item: item[0])
        picked.extend(entries[:max(0, args.per_group)])

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    written = 0
    with open(args.out, "w", encoding="utf-8") as handle:
        for tick, observation, rows in sorted(picked, key=lambda item: item[0]):
            header = observation.get("header") or {}
            tactical = observation.get("tactical") or {}
            own_units = [str(e.get("name")) for e in (tactical.get("entities") or [])
                         if str(e.get("kind")) == "unit_self" and e.get("name")]
            frame = build_decision_frame(
                match_id=str(header.get("match_id", "")),
                player_id=str(header.get("player_id", "")),
                rules_version=str(header.get("rules_version", "")),
                snapshot_id=int(header.get("snapshot_id", 0) or 0),
                server_tick=int(header.get("server_tick", 0) or 0),
                tactical=tactical, rules=rules, mode=args.mode,
                authorized_units=set(own_units), plan_version="ab:v1")
            state = render_compact_text(frame, balance=tactical.get("balance"))
            handle.write(json.dumps({"state": state, "rows": rows},
                                    ensure_ascii=False) + "\n")
            written += 1
    print("groups: %s" % {k: len(v) for k, v in sorted(groups.items())})
    print("written %d demos -> %s" % (written, args.out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
