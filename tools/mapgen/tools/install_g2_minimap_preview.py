"""Write the current 256 lake G2 top-down into the game minimap slots.

Does not rerun G1-G4. Uses the existing G2 mapgrid.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from rtsmap import contract  # noqa: E402

contract.apply_map_extent(256.0)

from rtsmap.gates.g4_export import install_map  # noqa: E402
from rtsmap.grid import MapGrid, read_json  # noqa: E402
from rtsmap.viz.plots_g2 import write_minimap_preview  # noqa: E402

SEED = 16
MAP_ID = "16-0-1ca6e21aa1"
RUNS = ROOT / "review" / "G2" / "water_combos" / "single_large_lake_256" / "runs"
OUT = ROOT / "review" / "G4" / "g2_large_lake_256" / "g4_export"
G2 = RUNS / str(SEED) / "G2"


def main() -> int:
    grid = MapGrid.load(G2 / "mapgrid.npz")
    spec = read_json(G2 / "mapspec.json")
    preview = write_minimap_preview(
        OUT / "minimap_preview.png", grid, spec.get("bridges") or []
    )
    write_minimap_preview(G2 / "minimap_preview.png", grid, spec.get("bridges") or [])
    print("wrote", preview, flush=True)
    scene, files = install_map(OUT, MAP_ID)
    print("installed", scene, flush=True)
    for path in files:
        print(" ", path, flush=True)
    print("REPORT", json.dumps({"map_id": MAP_ID, "preview": str(preview)}), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
