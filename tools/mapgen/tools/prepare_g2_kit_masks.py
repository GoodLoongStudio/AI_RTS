"""Derive the material masks the G4 shader needs, without touching the accepted G2 geometry.

The accepted G4 fields (`fields.bin`, produced by ``prepare_g2_kit_render.py``) already
carry height, rock-blocking and in-water depth.  The terrain shader additionally needs
"how far is the land from the water" (to paint banks *outside* the water) and
"which water body is this" (so the lake gets a wide silt skirt and the river only a
narrow wet lip).  Both are pure functions of the frozen G2 rasters, so they are exported
into a separate file and never modify heights, water footprint, plateau outlines or
bridge placement.

Layout of ``masks.bin`` (float32 little endian, plane major, 1025 x 1025 each, row = z):
    0: shore_dist_m   distance from land to the nearest water pixel, metres, 0 in water
    1: lake_dist_m    signed distance to the lake polygons, metres, negative inside lake
    2: plateau_dist_m signed distance to the plateau outlines, metres, negative inside
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
from scipy import ndimage as ndi
from shapely import Polygon, contains, distance, points

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "review/G2/water_combos/single_large_lake/runs/16/G2"
OUT = ROOT / "review/G4/g2_large_lake_kits"
N = 1025
LOGICAL = 2000.0 / 512.0


def signed_distance_metres(polygons: list[dict], samples) -> np.ndarray:
    """Vectorised signed distance (metres) to the union of the given outlines."""
    inside_any = np.zeros(samples.shape, dtype=bool)
    nearest = np.full(samples.shape, np.inf, dtype=np.float64)
    for item in polygons:
        poly = Polygon(item["outline"])
        inside_any |= contains(poly, samples)
        nearest = np.minimum(nearest, distance(poly.exterior, samples))
    return np.where(inside_any, -nearest, nearest) * LOGICAL


def main() -> None:
    spec = json.loads((SOURCE / "mapspec.json").read_text(encoding="utf-8"))
    with np.load(SOURCE / "mapgrid.npz") as grid:
        water = grid["water_footprint"].astype(bool)
    assert water.shape == (512, 512), water.shape

    land_distance_px = ndi.distance_transform_edt(~water)
    padded = np.pad(land_distance_px, ((0, 1), (0, 1)), mode="edge")
    shore = ndi.zoom(padded, N / 513.0, order=1) * LOGICAL

    logical_axis = np.mgrid[:N, :N] * 0.5
    samples = points(logical_axis[1], logical_axis[0])
    lake = signed_distance_metres(spec["lakes"], samples)
    plateau = signed_distance_metres(spec["plateaus"], samples)

    masks = np.stack([shore, lake, plateau]).astype("<f4")
    masks.tofile(OUT / "masks.bin")
    (OUT / "masks.json").write_text(json.dumps({
        "vertex_size": N,
        "cell_m": 2000.0 / 1024.0,
        "planes": ["shore_dist_m", "lake_dist_m", "plateau_dist_m"],
        "lake_count": len(spec["lakes"]),
        "plateau_count": len(spec["plateaus"]),
        "source": str(SOURCE),
        "note": "Read-only derivative of the accepted G2 rasters; no geometry is regenerated.",
    }, ensure_ascii=False, indent=2), encoding="utf-8")

    land = shore[shore > 0]
    print("shore  land px %d  p50 %.2f m  p95 %.2f m  max %.2f m"
          % (land.size, np.percentile(land, 50), np.percentile(land, 95), land.max()))
    print("lake   inside px %d  min %.2f m" % ((lake < 0).sum(), lake.min()))
    print("plateau inside px %d  min %.2f m" % ((plateau < 0).sum(), plateau.min()))
    print("masks ->", OUT / "masks.bin")


if __name__ == "__main__":
    main()
