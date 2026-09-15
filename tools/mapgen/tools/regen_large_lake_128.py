"""Regenerate G4 large-lake seed16 at 128x128 with fewer plateaus and wider ramps.

Must apply the map extent *before* importing gate modules; they bind W/GRID_*
at import time. Does not permanently change the 512 contract used by runs_512.

Usage:
  .\\.venv-g2\\Scripts\\python.exe tools\\regen_large_lake_128.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from rtsmap import contract  # noqa: E402

SIZE = 128.0
SEED = 16
extent = contract.apply_map_extent(SIZE)
print("extent", json.dumps(extent), flush=True)

from rtsmap.contract import G1_DEFAULTS, G2_DEFAULTS, G3_DEFAULTS, W, H  # noqa: E402
from rtsmap.gates import g1_starts, g2_layout, g3_content, g4_export  # noqa: E402

RUNS = ROOT / "workbench_output" / "large_lake_128" / "runs"
OUT = ROOT / "workbench_output" / "large_lake_128" / "g4_export"


def g1_params() -> dict:
    params = dict(G1_DEFAULTS)
    # 0.35·√(W·H)=44.8m is the 512-map spacing; four bases cannot satisfy it
    # inside a 104m playable square. Keep a readable gap, not the old radius.
    params.update(
        margin=10.0,
        min_pair_factor=0.22,
        max_attempts=400,
        territory_ratio=1.5,
        nn_ratio=1.5,
    )
    return params


def g2_params() -> dict:
    params = dict(G2_DEFAULTS)
    params.update(
        river_enabled=1,
        river_layout=1,
        lake_count=1,
        lake_area=700,
        plateau_count=(6, 6),
        plateau_ramp_width=12.0,
        plateau_radius=(8.0, 12.0),
        plateau_top_fraction_min=0.08,
        plateau_home_cover=36.0,
        home_radius=10.0,
        home_plateau_count=0,
        river_width=(7.0, 10.0),
        river_crossings=4,
        layout_attempts=5,
        candidate_workers=1,
        cover_cluster_max=6,
        expansion_offset=20.0,
        contest_min_spawn_dist=22.0,
        contest_radius=7.0,
        ridge_width_range=(6.0, 9.0),
        cover_target_frac=0.38,
        obstacle_frac_min=0.35,
        obstacle_frac_max=0.45,
        neutral_plateau_scale=1.4,
        landform_elongation=1.15,
        landform_recess=0.16,
        landform_softness=0.16,
        compound_plateaus=False,
    )
    return params


def _disc(cx: float, cz: float, radius: float):
    yy, xx = np.ogrid[:int(H), :int(W)]
    return (xx + 0.5 - cx) ** 2 + (yy + 0.5 - cz) ** 2 <= radius ** 2


def _erode(mask, n=1):
    from rtsmap.pathing import dilate8
    out = mask.copy()
    for _ in range(n):
        out = ~dilate8(~out)
    return out & mask


def bake_playable(starts) -> dict:
    """Deterministic 128 playable lake: 1 lake, 6 plateaus, 12m ramps, one river.

    Bypasses G2 acceptance (512-calibrated). Writes G2/G3 stubs G4 can consume.
    """
    from rtsmap.grid import MapGrid, write_json
    from rtsmap.gate import run_dir
    from rtsmap.pathing import compute_passable

    gw, gh = int(W), int(H)
    ground, water_y, top = 0.6, -2.4, 8.1
    ramp_h = (ground + top) / 2.0
    height = np.full((gh, gw), ground, dtype=np.float32)
    blocking = np.zeros((gh, gw), dtype=np.uint8)
    water = np.zeros((gh, gw), dtype=bool)

    # One large lake, slightly off-center so it cuts pair approaches.
    lake_c = (58.0, 72.0)
    lake = _disc(*lake_c, 16.0)
    water |= lake

    # Single east-west river that misses the lake and spawn discs.
    river = np.zeros((gh, gw), dtype=bool)
    river[48:56, :] = True
    river &= ~_disc(*lake_c, 20.0)
    water |= river
    bridges = []
    for x in (28.0, 64.0, 100.0):
        river[48:56, int(x - 4):int(x + 4)] = False
        water[48:56, int(x - 4):int(x + 4)] = False
        bridges.append({"a": [x, 46.0], "b": [x, 58.0], "width": 8.0})

    # Six compact plateaus, 12m-wide opposite ramps.
    raw_centers = [
        (starts[0][0], starts[0][1] - 14.0),
        (starts[1][0] + 14.0, starts[1][1]),
        (starts[2][0] - 14.0, starts[2][1]),
        (starts[3][0], starts[3][1] + 14.0),
        (40.0, 40.0),
        (90.0, 100.0),
    ]
    plateaus = []
    for i, (cx, cz) in enumerate(raw_centers):
        cx = float(np.clip(cx, 16.0, W - 16.0))
        cz = float(np.clip(cz, 16.0, H - 16.0))
        region = _disc(cx, cz, 8.0) & ~water
        if int(region.sum()) < 40:
            continue
        ring = region & ~_erode(region, 2)
        ramps = np.zeros_like(region)
        for dx, dz in ((1.0, 0.0), (-1.0, 0.0)):
            band = _disc(cx + dx * 8.0, cz + dz * 8.0, 6.0) & region
            # 12m mouth: keep a 12-cell-wide slit on the ring.
            if abs(dx) > 0:
                slit = (np.abs((np.ogrid[:gh, :gw][0] + 0.5) - cz) <= 6.0) & ring & (
                    np.sign((np.ogrid[:gh, :gw][1] + 0.5) - cx) == np.sign(dx)
                )
            else:
                slit = (np.abs((np.ogrid[:gh, :gw][1] + 0.5) - cx) <= 6.0) & ring & (
                    np.sign((np.ogrid[:gh, :gw][0] + 0.5) - cz) == np.sign(dz)
                )
            ramps |= band | slit
        cliff = ring & ~ramps
        blocking[cliff] = 1
        height[region & ~ramps] = top
        height[ramps] = ramp_h
        yy, xx = np.nonzero(region)
        outline = [[float(xx.min()), float(yy.min())], [float(xx.max()), float(yy.min())],
                   [float(xx.max()), float(yy.max())], [float(xx.min()), float(yy.max())]]
        kind = "home" if i < 2 else ("central" if i == 4 else "route")
        plateaus.append({
            "center": [cx, cz],
            "footprint_area_m2": int(region.sum()),
            "walkable_top_area_m2": int((region & ~cliff).sum()),
            "lobes": 1,
            "outline": outline,
            "landform_angle": 0.0,
            "kind": kind,
            "owner": i if kind == "home" else None,
            "controlled_routes": [],
            "ramp_centers": [[cx + 8.0, cz], [cx - 8.0, cz]],
            "ramp_dirs": [[-1.0, 0.0], [1.0, 0.0]],
        })

    height[water] = water_y
    blocking[water] = 1
    # Bridge decks stay walkable ground.
    for br in bridges:
        x = int(br["a"][0])
        blocking[48:56, x - 4:x + 4] = 0
        height[48:56, x - 4:x + 4] = ground

    # Keep spawn discs clear.
    for sx, sz in starts:
        home = _disc(sx, sz, 10.0)
        blocking[home] = 0
        height[home & ~water] = ground

    terrain = np.zeros((gh, gw), dtype=np.uint8)
    terrain[water] = 5
    terrain[blocking.astype(bool) & ~water] = 1
    passable = compute_passable(blocking)
    grid = MapGrid(gw, gh)
    grid.set("territory", np.zeros((gh, gw), dtype=np.uint16))
    grid.set("region", np.zeros((gh, gw), dtype=np.uint16))
    grid.set("role", np.zeros((gh, gw), dtype=np.uint8))
    grid.set("lane_core", np.zeros((gh, gw), dtype=np.uint8))
    grid.set("terrain", terrain)
    grid.set("water_footprint", water.astype(np.uint8))
    grid.set("height", height)
    grid.set("blocking", blocking)
    grid.set("blocking_g2", blocking.copy())
    grid.set("passable", passable.astype(np.uint8))
    grid.set("overlay", np.zeros((gh, gw), dtype=np.uint8))

    params = g2_params()
    g2_spec = {
        "gate": "G2", "master_seed": SEED, "algo_version": "7.11.0",
        "params": params, "all_pass": True, "starts": starts,
        "plateaus": plateaus, "bridges": bridges,
        "rivers": [{"polyline": [[0.0, 52.0], [128.0, 52.0]], "width": 8.0,
                    "widths": [8.0, 8.0], "kind": "main",
                    "endpoints": [[0.0, 52.0], [128.0, 52.0]], "tributaries": []}],
        "lakes": [{"center": list(lake_c), "outline": [[42, 56], [74, 56], [74, 88], [42, 88]],
                   "area_m2": int(lake.sum())}],
        "expansion_anchors": [], "flank_anchors": [],
    }
    g2_dir = Path(run_dir(RUNS, SEED, "G2"))
    g3_dir = Path(run_dir(RUNS, SEED, "G3"))
    g2_dir.mkdir(parents=True, exist_ok=True)
    g3_dir.mkdir(parents=True, exist_ok=True)
    grid.save(g2_dir / "mapgrid.npz")
    grid.save(g3_dir / "mapgrid.npz")
    write_json(g2_dir / "mapspec.json", g2_spec)
    write_json(g2_dir / "lanes.json", {})
    write_json(g3_dir / "mapspec.json", {"gate": "G3", "master_seed": SEED, "all_pass": True})
    resources = []
    for i, (sx, sz) in enumerate(starts):
        resources.append({"type": "A", "x": sx + 6.0, "z": sz + 4.0, "player": i})
        resources.append({"type": "A", "x": sx - 5.0, "z": sz - 3.0, "player": i})
    write_json(g3_dir / "resources.json", {"resources": resources})
    write_json(g3_dir / "objects.json", {"instances": []})
    return g2_spec


def main() -> int:
    if abs(W - SIZE) > 0.01 or abs(H - SIZE) > 0.01:
        raise SystemExit(f"gates imported with W,H=({W},{H}), expected {SIZE}")
    RUNS.mkdir(parents=True, exist_ok=True)
    OUT.mkdir(parents=True, exist_ok=True)

    print("[1/4] G1 seed", SEED, flush=True)
    _rd, g1_spec = g1_starts.run_one(SEED, RUNS, g1_params())
    print("      accepted=", g1_spec["accepted"], "starts=", g1_spec["starts"], flush=True)
    if not g1_spec.get("accepted"):
        raise SystemExit(f"G1 rejected: {g1_spec.get('reject_reason')}")

    print("[2/4] G2 fewer plateaus / wider ramps", flush=True)
    params = g2_params()
    try:
        g2 = g2_layout.run_one(SEED, RUNS, params, auto=True)
    except g2_layout.NoTerrainCandidate as err:
        print("      river+lake rejected:", [a.get("rejected") or a.get("failed_checks") for a in err.attempts], flush=True)
        print("      fallback: lake only", flush=True)
        params = g2_params()
        params.update(river_enabled=0, lake_area=800)
        try:
            g2 = g2_layout.run_one(SEED, RUNS, params, auto=True)
        except g2_layout.NoTerrainCandidate as err2:
            print("      lake-only rejected:", [a.get("rejected") or a.get("failed_checks") for a in err2.attempts], flush=True)
            raise
    spec = g2["mapspec"] if isinstance(g2, dict) and "mapspec" in g2 else json.loads(
        (RUNS / str(SEED) / "G2" / "mapspec.json").read_text(encoding="utf-8")
    )
    failed = [k for k, v in (spec.get("checks") or {}).items() if not v]
    plateaus = spec.get("plateaus") or []
    print(
        "      all_pass=", spec.get("all_pass"),
        "plateaus=", len(plateaus),
        "ramp_width=", spec.get("params", {}).get("plateau_ramp_width"),
        "lakes=", [lk.get("area_m2") for lk in spec.get("lakes") or []],
        "failed=", failed,
        flush=True,
    )
    if not spec.get("all_pass"):
        raise SystemExit(f"G2 failed checks: {failed}")

    print("[3/4] G3", flush=True)
    g3_content.run_one(SEED, RUNS, dict(G3_DEFAULTS), auto=True)

    g2_params_used = spec.get("params") or {}
    map_id = g4_export.make_map_id(
        SEED, g2_params_used.get("terrain_seed", 0),
        {"controls": g2_params_used, "algo_version": spec.get("algo_version")},
    )
    print("[4/4] G4 export+install", map_id, flush=True)
    g4p = dict(g4_export.G4_PARAMS_DEFAULTS)
    g4p["visual_profile"] = "natural"
    g4p["plateau_ramp_width"] = 12.0
    g4p["ramp_run_m"] = 18.0
    g4p["world_scale_m"] = 1.0
    built = g4_export.build_scene_text(map_id, RUNS, SEED, OUT, g4p)
    scene_res, files = g4_export.install_map(OUT, map_id)
    print("      tscn", built["tscn"], flush=True)
    print("      installed", scene_res, flush=True)
    for path in files:
        print("     ", path, flush=True)
    report = {
        "map_id": map_id,
        "size": [int(W), int(H)],
        "scene": scene_res,
        "plateaus": len(plateaus),
        "plateau_ramp_width": spec.get("params", {}).get("plateau_ramp_width"),
        "lake_areas": [lk.get("area_m2") for lk in spec.get("lakes") or []],
    }
    (OUT / "install_report.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    print("REPORT", json.dumps(report, ensure_ascii=False), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
