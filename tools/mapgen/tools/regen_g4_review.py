"""重跑 G3 + G4（review 侧），产出装饰计划与场景，不触碰 AI_RTS 正式地图。

用法：python tools/regen_g4_review.py [seed]
只读 AI_RTS 素材包（存在性校验），只写 tools/mapgen/workbench_output 下产物。
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from rtsmap.contract import G3_DEFAULTS  # noqa: E402
from rtsmap.gates import g3_content, g4_export  # noqa: E402
from rtsmap.gates import g2_decor  # noqa: E402

RUNS = ROOT / "workbench_output" / "single_large_lake" / "runs"
OUT = ROOT / "workbench_output" / "g2_large_lake_kits" / "g4_export"
SEED = int(sys.argv[1]) if len(sys.argv) > 1 else 16


def main():
    g2_dir = RUNS / str(SEED) / "G2"
    spec = json.loads((g2_dir / "mapspec.json").read_text(encoding="utf-8"))
    assert spec["all_pass"], "G2 未通过，拒绝导出"
    zones, meta = g2_decor.load_hints(g2_dir)
    print("[1/3] G2 hints:", "OK" if zones is not None else "MISSING",
          {k: int(v.sum()) for k, v in (zones or {}).items() if getattr(v, "dtype", None) == bool})

    res3 = g3_content.run_one(SEED, RUNS, dict(G3_DEFAULTS), auto=True)
    # acceptance checks 落在写盘的 report.json（run_one 的 mapspec 里没有 checks 键），
    # 早先这里读 res3["mapspec"]["checks"] 会 KeyError。
    rep3 = json.loads((res3["run_dir"] / "report.json").read_text(encoding="utf-8"))
    acc3 = rep3.get("acceptance", {})
    print("[2/3] G3 all_pass:", acc3.get("all_pass"), "failed checks:",
          {k: v for k, v in (acc3.get("checks") or {}).items() if not v})

    params = dict(g4_export.G4_PARAMS_DEFAULTS)
    params["visual_profile"] = "natural"
    g2_params = spec.get("params") or {}
    map_id = g4_export.make_map_id(SEED, g2_params.get("terrain_seed", 0),
                                   {"controls": g2_params, "algo_version": spec.get("algo_version")})
    OUT.mkdir(parents=True, exist_ok=True)
    built = g4_export.build_scene_text(map_id, RUNS, SEED, OUT, params)
    visual = built["visual"]
    print("[3/3] map_id:", map_id)
    print("      tscn:", built["tscn"])
    print("      height_data:", built["height_data"])
    print("      visual stats:", json.dumps(visual["stats"], ensure_ascii=False))
    print("      visual checks:", json.dumps(visual["checks"], ensure_ascii=False))
    print("      warnings:", visual["warnings"])
    (OUT / "decoration_plan.json").write_text(
        json.dumps({"map_id": map_id, "visual_seed": built["visual"].get("visual_seed"),
                    "stats": visual["stats"], "checks": visual["checks"],
                    "warnings": visual["warnings"],
                    "g2_decoration_hints": (meta or {}).get("zones", {}),
                    "protection": (meta or {}).get("protection", {})},
                   ensure_ascii=False, indent=2), encoding="utf-8")
    print("      decoration_plan.json written")


if __name__ == "__main__":
    main()
