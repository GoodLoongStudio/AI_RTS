"""Smoke the in-repo pipeline: G1 + bake_playable + G4 install. Does not edit MAPS."""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tools"))

from regen_large_lake_256 import (  # noqa: E402
    AIRTS,
    OUT,
    RUNS,
    SEED,
    bake_playable,
    g1_params,
)
from rtsmap.gate import run_dir  # noqa: E402
from rtsmap.gates import g1_starts, g4_export  # noqa: E402


MAP_ID = "reloc-verify"


def main() -> int:
    RUNS.mkdir(parents=True, exist_ok=True)
    OUT.mkdir(parents=True, exist_ok=True)
    _rd, g1_spec = g1_starts.run_one(SEED, RUNS, g1_params())
    if not g1_spec.get("accepted"):
        raise SystemExit(f"G1 rejected: {g1_spec.get('reject_reason')}")
    starts = [tuple(s) for s in g1_spec["starts"]]
    spec = bake_playable(starts)
    g4p = dict(g4_export.G4_PARAMS_DEFAULTS)
    g4p["visual_profile"] = "natural"
    g4p["plateau_ramp_width"] = 12.0
    g4p["ramp_run_m"] = 18.0
    g4p["world_scale_m"] = 1.0
    built = g4_export.build_scene_text(MAP_ID, RUNS, SEED, OUT, g4p)
    scene_res, files = g4_export.install_map(OUT, MAP_ID)
    report = {
        "map_id": MAP_ID,
        "scene": scene_res,
        "baked": bool(spec.get("baked")),
        "tscn": str(built["tscn"]),
        "installed": files,
        "airts": str(AIRTS),
        "g2_dir": str(run_dir(RUNS, SEED, "G2")),
    }
    (OUT / "verify_reloc_report.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    print("VERIFY", json.dumps(report, ensure_ascii=False), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
