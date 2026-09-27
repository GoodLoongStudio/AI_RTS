# -*- coding: utf-8 -*-
"""第二轮性能矩阵（目标提示词 §7.2）。

本轮唯一变量 = GroundAttackMoving（attack-move 索敌）是否走空间网格：
  A = AIRTS_TARGETING=nomovinggrid  移动索敌回退全场扫描（待机索敌仍走网格）
  B = （默认）                      网格 + 错峰 + 移动网格 = 本轮交付形态

场景安排：受影响的 g4battle200 / g4move200 各 3 次 A→B 交错；
idle 两场景本轮无改动，各跑 1 次 B 作抽查（对照直接引用第一轮 JSON）。

run_id 前缀 `r2`：驱动按"已存在的 run_id JSON 跳过"续跑，而第一轮数据也是今天
生成的（同名会撞成 skip，跑不出新数据），故必须换前缀。

用法：python tests/perfgrid/run_perf_grid_r2.py [max_runs] [scenario_filter]
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_perf_grid as rp

MAIN_SCENARIOS = ["g4battle200", "g4amove200"]
# g4move200 各跑 1 次即可：它给单位下 HoldFire，_pick_target() 不会被调用，
# A/B 必然同值 —— 用它证伪"移动场景有未计量扫描"的第一轮推断，不必占 3 个重复。
SINGLE_SCENARIOS = ["g4move200"]
SPOT_SCENARIOS = ["g4idle200", "g4idle400"]
REPS = 3
VERSIONS_R2 = {"A": "nomovinggrid", "B": None}
SPOT_VERSIONS = ["B"]

rp.VERSIONS = VERSIONS_R2  # 复用 run_one 的 env 映射，只换本轮的档位语义


def main():
    max_runs = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    scenario_filter = sys.argv[2] if len(sys.argv) > 2 else None
    stamp = time.strftime("%Y%m%d")
    ran = 0
    rows = []
    plan = [("r2" + s, s, ["A", "B"], REPS) for s in MAIN_SCENARIOS]
    plan += [("r2" + s, s, ["A", "B"], 1) for s in SINGLE_SCENARIOS]
    plan += [("r2" + s, s, SPOT_VERSIONS, 1) for s in SPOT_SCENARIOS]
    for id_prefix, scenario, versions, reps in plan:
        if scenario_filter and scenario != scenario_filter:
            continue
        for rep in range(1, reps + 1):
            for version in versions:  # A→B 交错，减弱时间漂移
                run_id = "%s_%s_r%d_%s" % (id_prefix, version, rep, stamp)
                rows.append(_one(run_id, scenario, version, max_runs, rows))
                if rows and rows[-1] is None:
                    print("[max-runs %d reached]" % max_runs, flush=True)
                    rp._dump([r for r in rows if r])
                    return
                ran += 1
    rp._dump([r for r in rows if r])


def _one(run_id, scenario, version, max_runs, rows):
    import json
    result_path = os.path.join(rp.OUT, run_id + ".json")
    if os.path.exists(result_path):
        print("[skip done] %s" % run_id, flush=True)
        with open(result_path, encoding="utf-8") as fh:
            result = json.load(fh)
    else:
        if max_runs and len([r for r in rows if r]) >= max_runs:
            return None
        print("[%s] %s" % (version, run_id), flush=True)
        result = rp.run_one(run_id, scenario, version)
    if not result:
        return None
    stats = result["targeting_stats"]
    return {
        "run_id": run_id, "scenario": scenario, "version": version,
        "fps_avg": result["fps_avg"], "fps_1pct_low": result["fps_1pct_low"],
        "p50": result["frame_ms_p50"], "p95": result["frame_ms_p95"],
        "p99": result["frame_ms_p99"],
        "render_cpu_avg": result["render_cpu_ms_avg"],
        "render_gpu_avg": result["render_gpu_ms_avg"],
        "queries": stats.get("query_calls", 0),
        "candidates": stats.get("candidates_returned", 0),
        "scan_us": stats.get("scan_time_us", 0),
        "maintain_us": stats.get("index_maintain_us", 0),
        "peak_scan_us": stats.get("peak_frame_scan_us", 0),
        "units_start": result["units_start"], "units_end": result["units_end"],
    }


if __name__ == "__main__":
    main()
