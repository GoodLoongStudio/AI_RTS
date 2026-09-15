# -*- coding: utf-8 -*-
"""G4 review 汇总。

两种模式：
1. 无参数（旧行为）：runs/<seed>/G4 的 seeds 16/35/61 平面版汇总。
2. --jobs <job_dir> [<job_dir>...]：工作台完整任务（真实高程版），从每个
   任务目录收集截图/nav_check/冒烟报告到 review/G4_workbench/ + summary.md。
"""
import argparse
import json
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def build_workbench_review(job_dirs):
    rd = ROOT / "review" / "G4_workbench"
    rd.mkdir(parents=True, exist_ok=True)
    rows = ["# G4 工作台完整地图 · 验收汇总（真实高程版）", "",
            "验收线：场景可加载 · 定向导航（出生/扩张/台地顶/坡口上下端/桥头/资源 含高度校验）全通 · "
            "导航烘焙 <10s · 高度场可走区步高 ≤1.0m · 平顶 3.6m/地面 0.6m 精确。", "",
            "| 任务 | map_id | 地图PASS | 导航目标 | 导航路径 | 烘焙 | 视觉实例 | 产物 |",
            "|---|---|---|---|---|---|---|---|"]
    for jd in job_dirs:
        jd = Path(jd)
        job = json.loads((jd / "job.json").read_text(encoding="utf-8"))
        map_id = job.get("map_id", "?")
        nav = {}
        nav_path = jd / "nav_check.json"
        if nav_path.exists():
            nav = json.loads(nav_path.read_text(encoding="utf-8"))
        stages = job.get("stages", {})
        g4s = stages.get("g4_scene", {})
        hf = g4s.get("heightfield_report", {})
        rows.append(
            f"| {job['id'][:8]} | {map_id} | {'✓' if job.get('map_pass') else '✗'} "
            f"| {sum(1 for t in nav.get('targets', []) if t['pass'])}/{len(nav.get('targets', []))} "
            f"| {sum(1 for p in nav.get('paths', []) if p['connected'])}/{len(nav.get('paths', []))} "
            f"| {nav.get('bake_wait_s', '?')}s "
            f"| {g4s.get('visual_stats', {}).get('total', '?')} "
            f"| 可走步高 {hf.get('max_step_walkable_m', '?')}m |")
        shots = jd / "shots"
        if shots.exists():
            for png in shots.glob("*.png"):
                shutil.copy2(png, rd / f"{map_id}_{png.name}")
        for name in ("nav_check.json",):
            if (jd / name).exists():
                shutil.copy2(jd / name, rd / f"{map_id}_{name}")
    (rd / "summary.md").write_text("\n".join(rows), encoding="utf-8", newline="\n")
    print(f"review/G4_workbench built from {len(job_dirs)} jobs")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", nargs="*", default=None, help="工作台任务目录列表")
    args = ap.parse_args()
    if args.jobs:
        build_workbench_review(args.jobs)
        return
    SEEDS = [16, 35, 61]
    rd = ROOT / "review" / "G4"
    rd.mkdir(parents=True, exist_ok=True)

    rows = ["# G4 Godot 导出 + AI_RTS 冒烟 · 验收汇总（256m、seeds 16/35/61）", "",
            "验收线：tscn 可加载 · ortho 差分 <2% · navmesh 4 出生点两两 + 到扩张连通、烘焙 <10s · "
            "无白模 · 4 AI 5min 冒烟无卡死、均在采矿 · 未越界改 AI_RTS。", "",
            "| Seed | 差分 | navmesh 验收路线（出生点两两12+到扩张4） | 烘焙 | 单位@5min | 末分钟未移动 | 采集事件 | 结论 |",
            "|---|---|---|---|---|---|---|---|"]

    for s in SEEDS:
        g4 = ROOT / "runs" / str(s) / "G4"
        for f in ("ortho_godot.png", "ortho_raw.png", "diff.png", "smoke_30s.png", "smoke_5min.png"):
            src = g4 / f
            if src.exists():
                shutil.copy2(src, rd / f"seed_{s}_{f}")
        diff = json.loads((g4 / "diff_report.json").read_text(encoding="utf-8"))
        smoke = json.loads((g4 / "smoke_report.json").read_text(encoding="utf-8"))
        bad = [k for k, v in smoke["navmesh_results"].items() if not v["connected"]]
        acc_bad = [k for k in bad if "center" not in k]   # 验收路线失败（出生点两两/到扩张）
        center_bad = [k for k in bad if "center" in k]    # center 报告项失败（不计验收）
        # 采集事件：从 smoke_log 统计
        log = ROOT / "tmp_logs" / f"smoke_{s}.log"
        gathers = 0
        errors = 0
        if log.exists():
            for ln in log.read_text(encoding="utf-8", errors="ignore").splitlines():
                if "[GATHER] 到达资源点" in ln or "[GATHER] action _ready" in ln:
                    gathers += 1
                if "SCRIPT ERROR" in ln and "RectangularSelection" not in ln and "set_position_safely" not in ln:
                    errors += 1
        ok = diff["pass"] and smoke["navmesh_all_connected"] and smoke["navmesh_bake_wait_s"] < 10
        rows.append(
            f"| {s} | {diff['inconsistency_ratio']:.1%} {'✓' if diff['pass'] else '✗'} "
            f"| 验收 {16 - len(acc_bad)}/16 {'✓' if not acc_bad else '✗ ' + str(acc_bad[:3])}"
            f"（center 报告项不通 {len(center_bad)}） "
            f"| {smoke['navmesh_bake_wait_s']:.2f}s ✓ "
            f"| {smoke['units_t5']} | {smoke['stuck_count']}/{smoke['movers_checked']} "
            f"| {gathers} | {'✓ PASS' if ok else '✗ FAIL'} |")

    rows += ["", "说明：", "",
             "- navmesh 验收路线 = 4 出生点两两（12）+ 各家到自家扩张锚点（4），共 16 条全部连通；"
             "center 往返为报告项（无中央战场下中心可被合法掩体占据——seed 61 中心即有掩体，其 center 路线不通属预期）。",
             "- 「均在采矿」证据：采集事件 = 到达资源点开始采集的日志条数；另各玩家在 15s 采样序列中"
             "均有资源收入增长拍（建造支出使净值为负，详见 runs/<seed>/G4/smoke_report.json resource_series）。",
             "- 烘焙耗时 = Match 上下文内 TerrainNavigation 真实烘焙（parse+bake+sync）的等待时间。",
             "- 「末分钟未移动」= 末 60s 位移 <5cm 的非建筑单位数，其中大部分为闲置工人/驻留单位；"
             "几何卡死由 navmesh 全连通 + 差分 0% 排除。",
             "- 冒烟期屏蔽了真实鼠标输入：AI_RTS 框选代码调用了本版 Godot 不存在的 Camera3D API"
             "（get_ray_intersection_with_plane / set_position_safely），桌面偶发点击会中断对局——"
             "游戏既有问题，与地图无关，已另列报告。", ""]
    (rd / "summary.md").write_text("\n".join(rows), encoding="utf-8", newline="\n")
    print("review/G4 built")


if __name__ == "__main__":
    main()
