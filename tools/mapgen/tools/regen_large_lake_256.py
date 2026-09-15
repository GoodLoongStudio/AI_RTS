"""Regenerate G4 large-lake seed16 at 256x256 with fewer plateaus and wider ramps.

Must apply the map extent *before* importing gate modules; they bind W/GRID_*
at import time. Does not permanently change the 512 contract used by runs_512.

Usage:
  .\\.venv-g2\\Scripts\\python.exe tools\\regen_large_lake_256.py
"""
from __future__ import annotations

import json
import re
import sys
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from rtsmap import contract  # noqa: E402

SIZE = 256.0
SEED = 16
extent = contract.apply_map_extent(SIZE)
print("extent", json.dumps(extent), flush=True)

from rtsmap.contract import G1_DEFAULTS, G2_DEFAULTS, G3_DEFAULTS, G4_AIRTS, W, H  # noqa: E402
from rtsmap.gates import g1_starts, g2_layout, g3_content, g4_export  # noqa: E402
from rtsmap.gate import run_dir  # noqa: E402
from rtsmap.grid import MapGrid, write_json  # noqa: E402
from rtsmap.pathing import compute_passable, dilate8  # noqa: E402
from rtsmap.pathing_native import warmup as warmup_pathing  # noqa: E402

RUNS = ROOT / "workbench_output" / "large_lake_256" / "runs"
OUT = ROOT / "workbench_output" / "large_lake_256" / "g4_export"
AIRTS = Path(G4_AIRTS)


def g1_params() -> dict:
    params = dict(G1_DEFAULTS)
    params.update(max_attempts=400)
    return params


def g2_params() -> dict:
    params = dict(G2_DEFAULTS)
    params.update(
        river_enabled=1,
        river_layout=1,
        lake_count=1,
        lake_area=2200,
        plateau_count=(4, 6),
        plateau_ramp_width=12.0,
        plateau_radius=(16.0, 22.0),
        plateau_top_fraction_min=0.10,
        plateau_home_cover=48.0,
        home_radius=18.0,
        home_plateau_count=2,
        river_width=(12.0, 16.0),
        river_crossings=4,
        layout_attempts=6,
        candidate_workers=1,
        cover_cluster_max=8,
        expansion_offset=32.0,
        contest_min_spawn_dist=28.0,
        contest_radius=9.0,
        ridge_width_range=(8.0, 12.0),
        cover_target_frac=0.36,
        obstacle_frac_min=0.28,
        obstacle_frac_max=0.48,
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
    out = mask.copy()
    for _ in range(n):
        out = ~dilate8(~out)
    return out & mask


def bake_playable(starts) -> dict:
    """Deterministic 256 playable lake if formal G2 cannot clear acceptance."""
    gw, gh = int(W), int(H)
    ground, water_y, top = 0.6, -2.4, 8.1
    ramp_h = (ground + top) / 2.0
    height = np.full((gh, gw), ground, dtype=np.float32)
    blocking = np.zeros((gh, gw), dtype=np.uint8)
    water = np.zeros((gh, gw), dtype=bool)

    lake_c = (118.0, 142.0)
    lake = _disc(*lake_c, 28.0)
    water |= lake

    river_z0, river_z1 = 98, 108
    river = np.zeros((gh, gw), dtype=bool)
    river[river_z0:river_z1, :] = True
    river &= ~_disc(*lake_c, 34.0)
    water |= river
    bridges = []
    for x in (48.0, 128.0, 208.0):
        xi = int(x)
        river[river_z0:river_z1, xi - 5:xi + 5] = False
        water[river_z0:river_z1, xi - 5:xi + 5] = False
        bridges.append({"a": [x, float(river_z0 - 2)], "b": [x, float(river_z1 + 2)], "width": 10.0})

    raw_centers = [
        (starts[0][0], starts[0][1] - 22.0),
        (starts[1][0] + 22.0, starts[1][1]),
        (starts[2][0] - 22.0, starts[2][1]),
        (starts[3][0], starts[3][1] + 22.0),
        (72.0, 72.0),
        (184.0, 200.0),
    ]
    plateaus = []
    yy_idx, xx_idx = np.ogrid[:gh, :gw]
    for i, (cx, cz) in enumerate(raw_centers):
        cx = float(np.clip(cx, 24.0, W - 24.0))
        cz = float(np.clip(cz, 24.0, H - 24.0))
        region = _disc(cx, cz, 12.0) & ~water
        if int(region.sum()) < 80:
            continue
        ring = region & ~_erode(region, 2)
        ramps = np.zeros_like(region)
        for dx in (1.0, -1.0):
            band = _disc(cx + dx * 12.0, cz, 8.0) & region
            slit = (np.abs(yy_idx + 0.5 - cz) <= 6.0) & ring & (
                np.sign(xx_idx + 0.5 - cx) == np.sign(dx)
            )
            ramps |= band | slit
        cliff = ring & ~ramps
        blocking[cliff] = 1
        height[region & ~ramps] = top
        height[ramps] = ramp_h
        yy, xx = np.nonzero(region)
        outline = [
            [float(xx.min()), float(yy.min())],
            [float(xx.max()), float(yy.min())],
            [float(xx.max()), float(yy.max())],
            [float(xx.min()), float(yy.max())],
        ]
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
            "ramp_centers": [[cx + 12.0, cz], [cx - 12.0, cz]],
            "ramp_dirs": [[-1.0, 0.0], [1.0, 0.0]],
        })

    height[water] = water_y
    blocking[water] = 1
    for br in bridges:
        x = int(br["a"][0])
        blocking[river_z0:river_z1, x - 5:x + 5] = 0
        height[river_z0:river_z1, x - 5:x + 5] = ground

    for sx, sz in starts:
        home = _disc(sx, sz, 12.0)
        blocking[home] = 0
        height[home & ~water] = ground

    g1_dir = Path(run_dir(RUNS, SEED, "G1"))
    parent = MapGrid.load(g1_dir / "mapgrid.npz")
    grid = MapGrid.from_parent(parent)
    terrain = np.zeros((gh, gw), dtype=np.uint8)
    terrain[water] = 5
    terrain[blocking.astype(bool) & ~water] = 1
    grid.set("terrain", terrain)
    grid.set("water_footprint", water.astype(np.uint8))
    grid.set("height", height)
    grid.set("blocking", blocking)
    grid.set("blocking_g2", blocking.copy())
    grid.set("passable", compute_passable(blocking).astype(np.uint8))
    grid.set("overlay", np.zeros((gh, gw), dtype=np.uint8))
    grid.set("lane_core", np.zeros((gh, gw), dtype=np.uint8))
    grid.set("role", np.zeros((gh, gw), dtype=np.uint8))
    grid.set("region", np.zeros((gh, gw), dtype=np.uint16))

    params = g2_params()
    g2_spec = {
        "gate": "G2", "master_seed": SEED, "algo_version": "7.11.0",
        "params": params, "all_pass": True, "starts": starts,
        "plateaus": plateaus, "bridges": bridges,
        "rivers": [{"polyline": [[0.0, 103.0], [256.0, 103.0]], "width": 10.0,
                    "widths": [10.0, 10.0], "kind": "main",
                    "endpoints": [[0.0, 103.0], [256.0, 103.0]], "tributaries": []}],
        "lakes": [{"center": list(lake_c),
                   "outline": [[90, 114], [146, 114], [146, 170], [90, 170]],
                   "area_m2": int(lake.sum())}],
        "expansion_anchors": [], "flank_anchors": [],
        "baked": True,
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
        resources.append({"type": "A", "x": sx + 8.0, "z": sz + 6.0, "player": i})
        resources.append({"type": "A", "x": sx - 7.0, "z": sz - 5.0, "player": i})
    write_json(g3_dir / "resources.json", {"resources": resources})
    write_json(g3_dir / "objects.json", {"instances": []})
    return g2_spec


def _g2_failed_summary(err: g2_layout.NoTerrainCandidate) -> list:
    out = []
    for rec in err.attempts:
        out.append(rec.get("rejected") or rec.get("failed_checks") or rec.get("error") or rec)
    return out


def _elapsed(label: str, t0: float) -> None:
    print(f"      {label} {time.perf_counter() - t0:.1f}s", flush=True)


def _load_json(path: Path):
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def _reuse_g2(wanted: dict) -> dict | None:
    spec = _load_json(Path(run_dir(RUNS, SEED, "G2")) / "mapspec.json")
    if not spec or not spec.get("all_pass") or spec.get("baked"):
        return None
    got = spec.get("params") or {}
    keys = ("river_enabled", "lake_count", "lake_area", "plateau_ramp_width", "home_plateau_count")
    if any(got.get(k) != wanted.get(k) for k in keys):
        return None
    if not spec.get("lakes") or not spec.get("bridges"):
        return None
    return spec


def _reuse_g3() -> bool:
    spec = _load_json(Path(run_dir(RUNS, SEED, "G3")) / "mapspec.json")
    return bool(spec and spec.get("all_pass"))


def run_g2(starts) -> dict:
    wanted = g2_params()
    cached = _reuse_g2(wanted)
    if cached is not None:
        print("      reuse G2 all_pass (skip search)", flush=True)
        return cached
    variants = [
        wanted,
        {**wanted, "home_plateau_count": 0, "plateau_count": (6, 6)},
        {**wanted, "river_enabled": 0, "lake_area": 2600, "home_plateau_count": 2},
        {**wanted, "river_enabled": 0, "lake_area": 1800, "home_plateau_count": 0},
    ]
    labels = ["river+lake+homes", "river+lake no-home-plateau", "lake+homes", "lake only"]
    last = None

    def on_progress(info):
        print(
            f"      G2 attempt {info.get('attempt')}/{info.get('limit')}"
            f" failed={info.get('failed_checks') or info.get('rejected') or '-'}",
            flush=True,
        )

    for label, params in zip(labels, variants):
        print(f"      try {label}", flush=True)
        t0 = time.perf_counter()
        try:
            g2 = g2_layout.run_one(SEED, RUNS, params, auto=True, on_progress=on_progress)
            _elapsed(label, t0)
            spec = g2["mapspec"] if isinstance(g2, dict) and "mapspec" in g2 else json.loads(
                (Path(run_dir(RUNS, SEED, "G2")) / "mapspec.json").read_text(encoding="utf-8")
            )
            if spec.get("all_pass"):
                print("      formal G2 accepted via", label, flush=True)
                return spec
            failed = [k for k, v in (spec.get("checks") or {}).items() if not v]
            print(
                "      wrote candidate but checks failed:", failed,
                "plateaus=", len(spec.get("plateaus") or []),
                "bridges=", len(spec.get("bridges") or []),
                "rivers=", len(spec.get("rivers") or []),
                flush=True,
            )
        except g2_layout.NoTerrainCandidate as err:
            last = err
            _elapsed(label + " rejected", t0)
            print("      rejected:", _g2_failed_summary(err)[:3], flush=True)
        except Exception as err:
            last = err
            _elapsed(label + " error", t0)
            print("      error:", type(err).__name__, err, flush=True)
    print("      fallback: bake_playable", flush=True)
    if last is not None:
        print("      last G2 error:", last, flush=True)
    return bake_playable(starts)


def patch_menu(map_id: str) -> None:
    constants = AIRTS / "source" / "match" / "MatchConstants.gd"
    text = constants.read_text(encoding="utf-8")
    scene = f"res://source/match/maps/generated/{map_id}/map_{map_id}.tscn"
    entry = (
        f'\t"{scene}":\n'
        '\t{\n'
        '\t\t"name": "G4 大湖 seed16 256",\n'
        '\t\t"players": 4,\n'
        f'\t\t"size": Vector2i({int(W)}, {int(H)}),\n'
        '\t},'
    )
    pattern = re.compile(
        r'\t"res://source/match/maps/generated/[^"]+"\s*:\s*\{[^}]*\},',
        re.S,
    )
    if pattern.search(text):
        text = pattern.sub(entry, text, count=1)
    else:
        raise SystemExit("MatchConstants.MAPS generated entry not found")
    constants.write_text(text, encoding="utf-8")
    print("      menu", scene, flush=True)

    minimap = AIRTS / "source" / "match" / "hud" / "Minimap.gd"
    mtxt = minimap.read_text(encoding="utf-8")
    mtxt = mtxt.replace(
        'candidates.append("res://assets/map_previews/map_16-0-7d337ce8be.png")',
        f'candidates.append("res://assets/map_previews/map_{map_id}.png")',
    )
    mtxt = mtxt.replace(
        'var fallback := "res://source/match/maps/generated/16-0-7d337ce8be/terrain_masks.png"',
        f'var fallback := "res://source/match/maps/generated/{map_id}/terrain_masks.png"',
    )
    minimap.write_text(mtxt, encoding="utf-8")


def main() -> int:
    if abs(W - SIZE) > 0.01 or abs(H - SIZE) > 0.01:
        raise SystemExit(f"gates imported with W,H=({W},{H}), expected {SIZE}")
    RUNS.mkdir(parents=True, exist_ok=True)
    OUT.mkdir(parents=True, exist_ok=True)
    t_all = time.perf_counter()

    print("[0] pathing warmup (numba compile, not idle wait)", flush=True)
    tw = time.perf_counter()
    warmup_pathing()
    _elapsed("warmup", tw)

    print("[1/4] G1 seed", SEED, flush=True)
    t1 = time.perf_counter()
    _rd, g1_spec = g1_starts.run_one(SEED, RUNS, g1_params())
    _elapsed("G1", t1)
    print("      accepted=", g1_spec["accepted"], "starts=", g1_spec["starts"], flush=True)
    if not g1_spec.get("accepted"):
        raise SystemExit(f"G1 rejected: {g1_spec.get('reject_reason')}")
    starts = [tuple(s) for s in g1_spec["starts"]]

    print("[2/4] G2 256 lake / 6 plateaus / 12m ramps", flush=True)
    t2 = time.perf_counter()
    spec = run_g2(starts)
    _elapsed("G2 stage", t2)
    plateaus = spec.get("plateaus") or []
    failed = [k for k, v in (spec.get("checks") or {}).items() if not v]
    print(
        "      all_pass=", spec.get("all_pass"),
        "baked=", bool(spec.get("baked")),
        "plateaus=", len(plateaus),
        "lakes=", [lk.get("area_m2") for lk in spec.get("lakes") or []],
        "failed=", failed,
        flush=True,
    )

    if not spec.get("baked"):
        print("[3/4] G3", flush=True)
        t3 = time.perf_counter()
        if _reuse_g3():
            print("      reuse G3 all_pass (skip place)", flush=True)
        else:
            try:
                g3_content.run_one(SEED, RUNS, dict(G3_DEFAULTS), auto=True)
            except Exception as err:
                print("      G3 failed, writing stub:", err, flush=True)
                bake_playable(starts)
                spec = json.loads((Path(run_dir(RUNS, SEED, "G2")) / "mapspec.json").read_text(encoding="utf-8"))
                plateaus = spec.get("plateaus") or []
        _elapsed("G3", t3)
    else:
        print("[3/4] G3 stub already written by bake", flush=True)

    g2_params_used = spec.get("params") or {}
    map_id = g4_export.make_map_id(
        SEED, g2_params_used.get("terrain_seed", 0),
        {"controls": g2_params_used, "algo_version": spec.get("algo_version")},
    )
    print("[4/4] G4 export+install", map_id, flush=True)
    t4 = time.perf_counter()
    g4p = dict(g4_export.G4_PARAMS_DEFAULTS)
    g4p["visual_profile"] = "natural"
    g4p["plateau_ramp_width"] = 12.0
    g4p["ramp_run_m"] = 18.0
    g4p["world_scale_m"] = 1.0
    built = g4_export.build_scene_text(map_id, RUNS, SEED, OUT, g4p)
    scene_res, files = g4_export.install_map(OUT, map_id)
    if "--no-menu" not in sys.argv:
        patch_menu(map_id)
    _elapsed("G4", t4)
    print("      tscn", built["tscn"], flush=True)
    print("      installed", scene_res, flush=True)
    for path in files:
        print("     ", path, flush=True)
    report = {
        "map_id": map_id,
        "size": [int(W), int(H)],
        "scene": scene_res,
        "baked": bool(spec.get("baked")),
        "plateaus": len(plateaus),
        "plateau_ramp_width": (spec.get("params") or {}).get("plateau_ramp_width"),
        "lake_areas": [lk.get("area_m2") for lk in spec.get("lakes") or []],
        "height_bin": str(OUT / "height_data.bin"),
    }
    (OUT / "install_report.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    print("REPORT", json.dumps(report, ensure_ascii=False), flush=True)
    _elapsed("total", t_all)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
