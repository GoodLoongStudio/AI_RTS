"""把 G4 review 导出的场景安装到 AI_RTS，并驱动 nav_check.gd 做导航验收。

只做两件事，且都不覆盖既有地图：
  1. install_map() 写入 AI_RTS/source/match/maps/generated/<map_id>/（唯一 ID）；
  2. 以该场景为 --map 运行 tools/godot/nav_check.gd，产出 nav_check.json。

用法：
  ./.venv-g2/Scripts/python.exe tools/check_ai_rts_nav.py [--no-install] [--seed=16]
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from rtsmap.contract import G4_AIRTS, G4_GODOT_MONO  # noqa: E402
from rtsmap.gates import g4_export  # noqa: E402

GODOT = Path(G4_GODOT_MONO) if G4_GODOT_MONO else Path()
NATIVE = GODOT.with_name(GODOT.name.replace("_console.exe", ".exe")) if GODOT.name else Path()
AI_RTS = Path(G4_AIRTS)
EXPORT = ROOT / "workbench_output" / "g2_large_lake_kits" / "g4_export"
OUT_JSON = ROOT / "workbench_output" / "g2_large_lake_kits" / "nav_check.json"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=16)
    ap.add_argument("--no-install", action="store_true",
                    help="只用 run 目录里已有的 nav_targets，不复制场景到 AI_RTS")
    args = ap.parse_args()

    plan_path = EXPORT / "decoration_plan.json"
    if not plan_path.exists():
        print(f"X 缺少 {plan_path}（先跑 tools/regen_g4_review.py）")
        return 2
    map_id = json.loads(plan_path.read_text(encoding="utf-8"))["map_id"]
    tscn = EXPORT / f"map_{map_id}.tscn"
    nav_targets = EXPORT / "nav_targets.json"
    for p in (tscn, nav_targets):
        if not p.exists():
            print(f"X 缺少 {p}")
            return 2

    if not args.no_install:
        scene_res, installed = g4_export.install_map(EXPORT, map_id, airts_root=AI_RTS)
        print(f"[1/2] installed {len(installed)} file(s) for map_id={map_id}")
        for f in installed:
            print(f"      + {f}")
    else:
        scene_res = (f"res://source/match/maps/generated/{map_id}"
                     f"/map_{map_id}.tscn")

    exe = GODOT if GODOT.exists() else NATIVE
    # nav_check.gd 必须在 AI_RTS 工程内才能被 res:// 加载（它读 AI_RTS 的
    # Match.tscn / MatchSettings.gd）。原先直接传 res://tools/godot/nav_check.gd
    # 会 File not found —— 那个路径只存在于 RTS_Map_Tool。这里幂等安装一份。
    script_dst = AI_RTS / "tools" / "nav_check.gd"
    script_src = ROOT / "tools" / "godot" / "nav_check.gd"
    script_dst.parent.mkdir(parents=True, exist_ok=True)
    if not script_dst.exists() or script_dst.read_bytes() != script_src.read_bytes():
        script_dst.write_bytes(script_src.read_bytes())
        print(f"[2/2] installed {script_dst}")
    cmd = [str(exe), "--rendering-driver", "opengl3", "--path", str(AI_RTS),
           "--script", "res://tools/nav_check.gd", "--",
           f"--map={scene_res}", f"--targets={nav_targets}", f"--out={OUT_JSON}"]
    print(f"[2/2] running nav_check.gd ... (log: tools/check_ai_rts_nav.log)")
    log_path = ROOT / "tools" / "check_ai_rts_nav.log"
    with open(log_path, "w", encoding="utf-8", errors="replace") as log:
        proc = subprocess.run(cmd, cwd=str(AI_RTS), stdout=log,
                              stderr=subprocess.STDOUT, text=True)
    print(f"      nav_check exit={proc.returncode}")
    if OUT_JSON.exists():
        data = json.loads(OUT_JSON.read_text(encoding="utf-8"))
        print(f"      all_pass={data.get('all_pass')} "
              f"bake_wait_s={data.get('bake_wait_s')} "
              f"targets={len(data.get('targets', []))} "
              f"paths={len(data.get('paths', []))} "
              f"forbidden={len(data.get('forbidden', []))}")
    else:
        print(f"      X nav_check.json 未产出；见 {log_path}")
    return proc.returncode


if __name__ == "__main__":
    raise SystemExit(main())
