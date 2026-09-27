# -*- coding: utf-8 -*-
"""把性能矩阵的逐 run JSON 聚合成对照表（交接提示词 §4.1）。

口径（与提示词一致）：
  fps_avg / fps_1pct_low / frame_ms_p95 / frame_ms_p99  -> 三次重复取【中位数】
  targeting_stats.query_calls / candidates_returned / scan_time_us / index_maintain_us
                                                         -> 每次已是累计值，跨重复取【均值】
  peak_frame_scan_us                                    -> 取【最大值】（尖峰看最坏）
  units_start / units_end                               -> 记录并做 A/B/C 同量级校验（>10% 判不可比）

同时打印逐 run 明细（报告第 4 节要的表）。
用法：python tests/perfgrid/summarize_grid.py [json_glob]
"""
import glob
import json
import os
import statistics
import sys

OUT = "G:/AIRTS/tmp_logs/perf_grid_20260926"
# 第一轮（g4*）与第二轮（r2g4*）的版本语义不同，按场景名前缀选标签；
# 场景/版本清单改为从数据里推导，避免每轮都改常量。
VERSION_DESC = {
    "": {"A": "basestats 旧全场扫描+无错峰", "B": "nostagger 仅空间网格",
         "C": "默认 空间网格+错峰"},
    "r2": {"A": "nomovinggrid 移动索敌回退全场扫描", "B": "默认 网格+错峰+移动网格"},
}
SCENARIOS = []
VERSIONS = []


def _parse_run_id(run_id):
    """g4idle200_A_r1_20260927 -> (scenario, version, rep)"""
    stem = run_id.rsplit("_", 1)[0]          # 去掉日期戳
    scenario, version, rep = stem.split("_")
    return scenario, version, int(rep.lstrip("r"))


def _labels_for(scenario):
    return VERSION_DESC["r2" if scenario.startswith("r2") else ""]


def load_runs(pattern):
    runs = []
    for path in sorted(glob.glob(pattern)):
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        scenario, version, rep = _parse_run_id(data["run_id"])
        stats = data.get("targeting_stats", {})
        runs.append({
            "run_id": data["run_id"], "scenario": scenario, "version": version, "rep": rep,
            "fps_avg": data["fps_avg"], "fps_1pct_low": data["fps_1pct_low"],
            "p50": data["frame_ms_p50"], "p95": data["frame_ms_p95"],
            "p99": data["frame_ms_p99"], "frames": data["frames"],
            "units_start": data["units_start"], "units_end": data["units_end"],
            "queries": stats.get("query_calls", 0),
            "candidates": stats.get("candidates_returned", 0),
            "scan_us": stats.get("scan_time_us", 0),
            "maintain_us": stats.get("index_maintain_us", 0),
            "peak_scan_us": stats.get("peak_frame_scan_us", 0),
            "use_grid": stats.get("use_grid"), "use_stagger": stats.get("use_stagger"),
            "generated_at": data.get("generated_at"),
        })
    return runs


def aggregate(runs):
    """按 场景×版本 聚合，返回 {(scenario, version): row}。"""
    agg = {}
    for scenario in SCENARIOS:
        for version in VERSIONS:
            group = [r for r in runs if r["scenario"] == scenario and r["version"] == version]
            if not group:
                continue
            agg[(scenario, version)] = {
                "scenario": scenario, "version": version, "runs": len(group),
                "run_ids": [r["run_id"] for r in group],
                "fps_avg": statistics.median([r["fps_avg"] for r in group]),
                "fps_1pct_low": statistics.median([r["fps_1pct_low"] for r in group]),
                "p95": statistics.median([r["p95"] for r in group]),
                "p99": statistics.median([r["p99"] for r in group]),
                "queries": sum(r["queries"] for r in group) / len(group),
                "candidates": sum(r["candidates"] for r in group) / len(group),
                "scan_ms": sum(r["scan_us"] for r in group) / len(group) / 1000.0,
                "maintain_ms": sum(r["maintain_us"] for r in group) / len(group) / 1000.0,
                "peak_scan_ms": max(r["peak_scan_us"] for r in group) / 1000.0,
                "units_start": sorted(set(r["units_start"] for r in group)),
                "units_end": sorted(set(r["units_end"] for r in group)),
                "use_grid": sorted(set(str(r["use_grid"]) for r in group)),
                "use_stagger": sorted(set(str(r["use_stagger"]) for r in group)),
            }
    return agg


def _pct(new, base):
    if base in (0, None):
        return "n/a"
    return "%+.1f%%" % ((new - base) / base * 100.0)


def comparability_flags(agg):
    """A/B/C 起止兵力差 >10% 的场景标出来（提示词 §10.4 负载一致性）。"""
    flags = []
    for scenario in SCENARIOS:
        for key in ("units_start", "units_end"):
            values = []
            for version in VERSIONS:
                row = agg.get((scenario, version))
                if not row:
                    continue
                values.append(max(row[key]) if row[key] else 0)
            if len(values) == len(VERSIONS) and min(values) > 0:
                spread = (max(values) - min(values)) / min(values)
                if spread > 0.10:
                    flags.append("%s.%s 版本间极差 %.0f%%（>10%%，该场景该指标不可比）"
                                 % (scenario, key, spread * 100.0))
    return flags


def print_tables(runs, agg):
    print("=" * 118)
    print("逐 run 明细（报告 §4 口径）")
    print("%-26s %-11s %3s %7s %7s %7s %7s %9s %13s %11s %10s %9s" % (
        "run_id", "scenario", "ver", "fpsAvg", "1%low", "P95ms", "P99ms",
        "索敌调用", "候选检查", "索敌ms", "索引ms", "峰值ms"))
    for run in sorted(runs, key=lambda r: (r["scenario"], r["version"], r["rep"])):
        print("%-26s %-11s %3s %7.1f %7.1f %7.2f %7.2f %9d %13d %11.0f %10.1f %9.1f" % (
            run["run_id"], run["scenario"], run["version"], run["fps_avg"],
            run["fps_1pct_low"], run["p95"], run["p99"], run["queries"],
            run["candidates"], run["scan_us"] / 1000.0, run["maintain_us"] / 1000.0,
            run["peak_scan_us"] / 1000.0))

    print("=" * 118)
    print("聚合（帧类取中位数 / 计数类取均值 / 峰值取最大）")
    print("%-12s %3s %4s %7s %7s %7s %7s %9s %13s %11s %10s %9s  %s" % (
        "scenario", "ver", "run", "fpsAvg", "1%low", "P95ms", "P99ms",
        "索敌调用", "候选检查", "索敌ms", "索引ms", "峰值ms", "兵力start->end"))
    for scenario in SCENARIOS:
        for version in VERSIONS:
            row = agg.get((scenario, version))
            if not row:
                continue
            print("%-12s %3s %4d %7.1f %7.1f %7.2f %7.2f %9.0f %13.0f %11.0f %10.1f %9.1f  %s->%s" % (
                scenario, version, row["runs"], row["fps_avg"], row["fps_1pct_low"],
                row["p95"], row["p99"], row["queries"], row["candidates"],
                row["scan_ms"], row["maintain_ms"], row["peak_scan_ms"],
                ",".join(str(v) for v in row["units_start"]),
                ",".join(str(v) for v in row["units_end"])))

    print("=" * 118)
    print("相对 A 基线的变化（B=仅网格，C=网格+错峰）")
    print("%-12s %s" % ("scenario", "指标".ljust(12) + "B 变化        C 变化"))
    for scenario in SCENARIOS:
        base = agg.get((scenario, "A"))
        if not base:
            continue
        for version in ("B", "C"):
            row = agg.get((scenario, version))
            if not row:
                continue
            deltas = []
            for label, key in (("候选检查", "candidates"), ("索敌总耗时", "scan_ms"),
                               ("单帧峰值", "peak_scan_ms"), ("索引维护", "maintain_ms"),
                               ("P99帧时", "p99"), ("平均FPS", "fps_avg")):
                deltas.append((label, _pct(row[key], base[key])))
            if version == "B":
                print("%-12s" % scenario, end="")
            print("   " + " | ".join("%s %s" % (k, v) for k, v in deltas))
    flags = comparability_flags(agg)
    if flags:
        print("=" * 118)
        print("可比性告警：")
        for flag in flags:
            print("  ! " + flag)


def main():
    pattern = sys.argv[1] if len(sys.argv) > 1 else os.path.join(OUT, "g4*_20260927.json")
    runs = load_runs(pattern)
    if not runs:
        print("没有匹配 %s 的数据" % pattern)
        return 1
    global SCENARIOS, VERSIONS
    SCENARIOS = sorted({r["scenario"] for r in runs})
    VERSIONS = sorted({r["version"] for r in runs})
    agg = aggregate(runs)
    print("数据源 %s -> %d 个 run（场景 %s / 版本 %s）"
          % (pattern, len(runs), ",".join(SCENARIOS), ",".join(VERSIONS)))
    # 抽查场景（各 1 次）不算未跑齐：按出现次数众数以外的场景单独列出。
    counts = {}
    for scenario in SCENARIOS:
        for version in VERSIONS:
            have = len([r for r in runs if r["scenario"] == scenario and r["version"] == version])
            if have:
                counts.setdefault(scenario, []).append(have)
    expected = max((max(v) for v in counts.values()), default=0)
    missing = ["%s_%s=%d/%d" % (scenario, version, have, expected)
               for scenario in SCENARIOS for version in VERSIONS
               for have in [len([r for r in runs if r["scenario"] == scenario and r["version"] == version])]
               if 0 < have < expected]
    if missing:
        print("矩阵未跑齐（期望每格 %d 次）：" % expected + ", ".join(missing))
    print_tables(runs, agg)
    with open(os.path.join(OUT, "aggregate_grid.json"), "w", encoding="utf-8") as fh:
        json.dump({"per_run": runs, "aggregated": {
            "%s_%s" % k: v for k, v in agg.items()}}, fh, indent=1, ensure_ascii=False)
    print("聚合结果已写入 %s" % os.path.join(OUT, "aggregate_grid.json"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
