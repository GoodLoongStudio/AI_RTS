"""从 water_combos 变体重跑 G4 并装机到 AI_RTS（不重跑 G3，避免内容漂移）。

与 tools/regen_g4_review.py 的区别：那个只写 review/ 下的产物、明确不碰 AI_RTS；
本脚本在同一个 runs 根上跑 build_scene_text，然后调 install_map
把 tscn / height_data.bin / terrain_masks.png 装到 generated/<map_id>/。
不调用 install_runtime_scripts，避免覆盖游戏内 GeneratedTerrain.gd。

用法：python tools/regen_and_install_g4.py [seed]
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from rtsmap.gates import g4_export  # noqa: E402

RUNS = ROOT / "workbench_output" / "single_large_lake" / "runs"
OUT = ROOT / "workbench_output" / "g2_large_lake_kits" / "g4_export"
SEED = int(sys.argv[1]) if len(sys.argv) > 1 else 16


def main():
    g2_dir = RUNS / str(SEED) / "G2"
    spec = json.loads((g2_dir / "mapspec.json").read_text(encoding="utf-8"))
    assert spec["all_pass"], "G2 未通过，拒绝导出"
    g2_params = spec.get("params") or {}
    map_id = g4_export.make_map_id(
        SEED, g2_params.get("terrain_seed", 0),
        {"controls": g2_params, "algo_version": spec.get("algo_version")})
    params = dict(g4_export.G4_PARAMS_DEFAULTS)
    params["visual_profile"] = "natural"
    OUT.mkdir(parents=True, exist_ok=True)

    built = g4_export.build_scene_text(map_id, RUNS, SEED, OUT, params)
    print("[1/3] map_id:", map_id)
    print("      tscn:", built["tscn"])
    print("      visual checks:", json.dumps(built["visual"]["checks"], ensure_ascii=False))
    print("      warnings:", built["visual"]["warnings"])

    print("[2/3] skip runtime scripts (keep game GeneratedTerrain.gd)")

    scene_res, files = g4_export.install_map(OUT, map_id)
    print("[3/3] installed map:", scene_res)
    for f in files:
        print("      ", f)


if __name__ == "__main__":
    main()
