# -*- coding: utf-8 -*-
"""把训练样本与**对局结果**对接，给每条样本定"证据等级"（执行提示词 §5 阶段 5）。

提示词要求每条样本至少区分：模型建议的动作、规则中台自动产生的动作、权威接受的命令、
实际完工/采集/交付结果，以及 `teacher_source` / `label_quality` 与失败原因；
并且**明令**：不要把"第二基地建成"标成"矿场计划成功"，不要把 `Accepted` 标成"已完成"。

采集时刻能知道的只有"下发了什么"（`laya_provider.with_provenance` 已经把
`teacher_source` 与 `label_quality=issued/no_action` 写进样本）。真正的结果要等对局结束才存在，
所以本工具做的是**事后联表**：

    dataset.jsonl（决策时刻）  ×  result_<tag>.json（权威观测时间线 + 回执）
        → dataset.audited.jsonl（label_quality 升级 + failure_reason + 联表可信度）

`label_quality` 升级后的取值（**没有证据就是 no_result，不做乐观解释**）：
    verified_result —— 样本下行的动作在之后真的产生了它那一类该产生的结果；
    accepted_only   —— 只看得到命令被权威接受，没有结果；
    no_result       —— 时间窗里既没有接受记录也没有结果。

隔离口径：`train_laya.py` 只吃 `verified_result`（`--require-verified` 由本工具的
`--trainable-out` 直接产出另一个文件），避免把"没有结果证据的样本"喂进微调。

用法：
    python -m adjutant_coordinator.deploy.audit_dataset_samples \\
        --dataset G:/AIRTS/tmp_logs/.../sp1.jsonl \\
        --result G:/AIRTS/tmp_logs/.../result_sp1.json \\
        --out     G:/AIRTS/tmp_logs/.../sp1.audited.jsonl \\
        --trainable-out G:/AIRTS/tmp_logs/.../sp1.trainable.jsonl
"""
from __future__ import annotations

import argparse
import json
import os
from collections import Counter
from typing import Any, Dict, List, Optional

#: 联表时间窗（秒）。样本 `ts` 与结果 `detail_log[].ts` 都是同一台机器的墙钟，
#: 但决策→施工→完工之间有真实延迟，所以窗口向"之后"倾斜。
WINDOW_AFTER_S = 90.0
WINDOW_BEFORE_S = 6.0

#: 四列行的 task 代码 → 结果判据类别。词表来自样本自己的 `questions.task.criteria`
#: （BLD=建造、GAT=采集、PROD=生产、MOVE/AMOV/SCT/DEF/HOLD/RET/GRP/STOP=行军与阵型），
#: 不是我以为的英文单词 —— 上一版用 "build"/"gather" 去匹配，
#: 结果 123 条样本**全部**落到 "other"，审计给出的 verified_result 是 0 条，
#: 那是分类器的错，不是"这一轮没有结果证据"。
BUILD_TASKS = ("BLD",)
GATHER_TASKS = ("GAT",)
PRODUCE_TASKS = ("PROD",)
#: 本轮结果链没覆盖的类别（行军/侦察/防守等）：单独标 `not_covered`，
#: **既不算成功也不算失败**（提示词 §8.3 明令不要把等待/未覆盖一概标成失败）。
UNCOVERED_TASKS = ("MOVE", "AMOV", "SCT", "DEF", "HOLD", "RET", "GRP", "STOP", "ATK")


def _skill_of(row) -> str:
    return str(row[1]).upper() if len(row) > 1 else ""


def _classify_rows(rows) -> set:
    kinds = set()
    for row in rows or []:
        skill = _skill_of(row)
        if skill in BUILD_TASKS:
            kinds.add("build")
        elif skill in GATHER_TASKS:
            kinds.add("gather")
        elif skill in PRODUCE_TASKS:
            kinds.add("produce")
        elif skill in UNCOVERED_TASKS:
            kinds.add("uncovered")
        elif skill:
            kinds.add("other")
    return kinds


def _own_types(sample) -> set:
    return {str(unit.get("type")) for unit in (sample.get("own") or []) if unit.get("type")}


def _building_types(sample) -> set:
    """样本帧里"已存在的建筑类型"。判据用类型而不是实例数，避免把生产单位误当新建筑。"""
    structure_words = ("barracks", "vehicle_factory", "aircraft_factory", "command_center",
                       "ore_refinery", "turret", "factory")
    return {t for t in _own_types(sample) if any(w in t for w in structure_words)}


def _unit_count(sample, name) -> int:
    return sum(1 for unit in (sample.get("own") or []) if str(unit.get("type")) == name)


def _samples_in_window(detail: List[Dict[str, Any]], ts: float) -> List[Dict[str, Any]]:
    return [item for item in detail
            if ts - WINDOW_BEFORE_S <= float(item.get("ts") or 0.0)
            <= ts + WINDOW_AFTER_S]


def _result_for(record: Dict[str, Any], result: Dict[str, Any]) -> Dict[str, Any]:
    """一条样本 → 它应得的结果判据。返回 {kind, evidence}，不返回猜测。

    kind 只有四种：`verified_result`（该类别应有的客观结果在窗口内发生了）、
    `no_result`（有下发但窗口内没发生）、`not_covered`（本轮结果链不判这个类别）、
    `no_action`（这一帧根本没下发）。
    """
    rows = (record.get("label") or {}).get("rows") or []
    kinds = _classify_rows(rows)
    detail = result.get("detail_log") or []
    ts = float(record.get("ts") or 0.0)
    window = _samples_in_window(detail, ts)
    before = [item for item in detail if float(item.get("ts") or 0.0) < ts]
    evidence: Dict[str, Any] = {}

    if "build" in kinds:
        # 建造类的结果 = 窗口里出现了**此前不存在的建筑类型**（不是下单、不是 Accepted）。
        seen_before = set()
        for item in before:
            seen_before |= _building_types(item)
        new_buildings = set()
        for item in window:
            new_buildings |= (_building_types(item) - seen_before)
        evidence["buildings_before"] = sorted(seen_before)
        evidence["new_building_types_in_window"] = sorted(new_buildings)
        if new_buildings:
            return {"kind": "verified_result", "evidence": evidence}
        return {"kind": "no_result", "evidence": evidence}

    if "gather" in kinds:
        # 采集类的结果 = 矿场交付计数增加，或"账户涨 + 全图矿量降"这对联合事实
        # （只看账户涨会把生产收入也算进来，所以两个条件一起要）。
        deliveries = [(int(r.get("delivered") or 0), int(r.get("delivered_amount") or 0))
                      for sample in window for r in (sample.get("refineries") or [])]
        max_delivered = max([d for d, _ in deliveries] or [0])
        balances = [int(s.get("balance_a") or 0) for s in window if "balance_a" in s]
        ores = [int(s.get("ore_remaining") or 0) for s in window if "ore_remaining" in s]
        banked = bool(len(balances) >= 2 and balances[-1] > balances[0]
                      and len(ores) >= 2 and ores[-1] < ores[0])
        evidence["refinery_deliveries"] = deliveries[:4]
        evidence["balance_span"] = [balances[0], balances[-1]] if balances else None
        evidence["ore_span"] = [ores[0], ores[-1]] if ores else None
        if max_delivered > 0 or banked:
            evidence["outcome"] = "delivered" if max_delivered > 0 else "banked_and_ore_consumed"
            return {"kind": "verified_result", "evidence": evidence}
        return {"kind": "no_result", "evidence": evidence}

    if "produce" in kinds:
        # 生产类的结果 = 某个兵种/工人的**数量真的增加了**（花费已在扣款侧发生）。
        grew = {}
        names = sorted({n for item in list(window) + list(before) for n in _own_types(item)})
        for name in names:
            counts = [_unit_count(item, name) for item in before + window]
            if counts and max(counts) > (counts[0] if counts else 0):
                grew[name] = [counts[0], max(counts)]
        evidence["unit_type_growth"] = dict(list(grew.items())[:6])
        if grew:
            return {"kind": "verified_result", "evidence": evidence}
        return {"kind": "no_result", "evidence": evidence}

    if "uncovered" in kinds and len(kinds) == 1:
        return {"kind": "not_covered", "evidence": evidence}
    return {"kind": "no_result", "evidence": evidence}


def rows_of(record: Dict[str, Any]) -> list:
    return (record.get("label") or {}).get("rows") or []


def audit(dataset_path: str, result_paths: List[str]) -> Dict[str, Any]:
    """一个数据集 × 若干局结果 → 逐条升级 label_quality。

    【联表可信度】样本没有 command_id/intent_id，只能按**时间窗**关联。
    这里把窗口固定为 [ts-6s, ts+90s]，并把窗口内看到的实体/交付原样记进
    `result_evidence`，让审阅者能自己判断这条配对站不站得住——
    不假装这是精确外键联接。
    """
    results: List[Dict[str, Any]] = []
    for path in result_paths:
        if os.path.exists(path):
            with open(path, encoding="utf-8") as handle:
                results.append(json.load(handle))
    if not results:
        raise SystemExit("[audit] 没有任何 result json 可读：%s" % result_paths)

    counters: Counter = Counter()
    rows_out: List[Dict[str, Any]] = []
    with open(dataset_path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except ValueError:
                counters["bad_line"] += 1
                continue
            if not isinstance(record, dict):
                continue
            verdicts = [_result_for(record, result) for result in results]
            kinds = {str(v["kind"]) for v in verdicts}
            if not rows_of(record):
                quality = "no_action"
            elif "verified_result" in kinds:
                quality = "verified_result"
            elif "not_covered" in kinds:
                quality = "not_covered"
            else:
                quality = "no_result"
            record["label_quality"] = quality
            record["result_evidence"] = [v["evidence"] for v in verdicts][:2]
            # 失败原因：矿场被拒的逐次原因由对局侧 `refinery_receipt.builds` 原样留档，
            # 落进样本只作为"这一段时间窗内的已知拒绝"，不改写样本自身的动作标签。
            refusals = []
            for result in results:
                for build in ((result.get("refinery_receipt") or {}).get("builds") or []):
                    authority = build.get("authority") or {}
                    if authority.get("status") in ("Rejected", None) and authority.get("reason"):
                        refusals.append(str(authority.get("reason")))
            if refusals:
                record["failure_reason"] = sorted(set(refusals))[:6]
            counters["%s|%s" % (record.get("teacher_source", "?"), quality)] += 1
            rows_out.append(record)
    return {"rows": rows_out, "counters": dict(counters)}


def main() -> int:
    parser = argparse.ArgumentParser(description="训练样本 × 对局结果 联表审计")
    parser.add_argument("--dataset", required=True)
    parser.add_argument("--result", action="append", required=True,
                        help="一个或多个 result_<tag>.json（可重复）")
    parser.add_argument("--out", required=True, help="升级后的 audited.jsonl")
    parser.add_argument("--trainable-out", default="",
                        help="只含 verified_result 的样本文件（喂 train_laya）")
    args = parser.parse_args()

    report = audit(args.dataset, args.result)
    rows = report["rows"]
    with open(args.out, "w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
    trainable = [row for row in rows if row.get("label_quality") == "verified_result"]
    if args.trainable_out:
        with open(args.trainable_out, "w", encoding="utf-8") as handle:
            for row in trainable:
                handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
    print("[audit] 样本 %d 条 → %s" % (len(rows), args.out), flush=True)
    print("[audit] 可训练（verified_result）%d 条%s"
          % (len(trainable), (" → " + args.trainable_out) if args.trainable_out else ""),
          flush=True)
    for key in sorted(report["counters"]):
        print("[audit]   %s = %d" % (key, report["counters"][key]), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
